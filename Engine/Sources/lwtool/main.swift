import Foundation
import LikeWaterEngine

// Dumps what the engine computes as GeoJSON, so the Folium check in
// Pipeline/check_maps.py renders exactly the app's own numbers rather than a
// second implementation that could agree by luck.
//
//   lwtool corridor --from LAT,LON --to LAT,LON --slack 0.1 --out file.geojson
//   lwtool sun      --center LAT,LON --radius 400 --at 2026-09-23T17:00:00Z --out file.geojson

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func option(_ name: String) -> String? {
    guard let i = CommandLine.arguments.firstIndex(of: "--\(name)"),
          i + 1 < CommandLine.arguments.count else { return nil }
    return CommandLine.arguments[i + 1]
}

func coordinate(_ raw: String?, _ label: String) -> (lat: Double, lon: Double) {
    guard let parts = raw?.split(separator: ",").compactMap({ Double($0.trimmingCharacters(in: .whitespaces)) }),
          parts.count == 2 else { fail("--\(label) needs LAT,LON") }
    return (parts[0], parts[1])
}

// `lwtool sky` needs no bundle: it asks Open-Meteo for the cells around a point and
// prints what the app would say, so a forecast claim can be checked from the terminal.
//   lwtool sky --center LAT,LON [--at ISO8601] [--json file]
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "sky" {
    let c = coordinate(option("center"), "center")
    let when: Date = {
        guard let raw = option("at") else { return Date() }
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        guard let d = f.date(from: raw) else { fail("--at needs ISO 8601, e.g. 2026-09-23T20:00:00Z") }
        return d
    }()
    let points = OpenMeteoSky.latticePoints(around: c.lat, longitude: c.lon)
    let field: SkyField
    if let path = option("json") {
        field = try OpenMeteoSky.decode(try Data(contentsOf: URL(fileURLWithPath: path)))
    } else {
        let url = OpenMeteoSky.requestURL(points: points)
        print("GET \(url.absoluteString)")
        let t0 = Date()
        let sem = DispatchSemaphore(value: 0)
        var got: Data?; var status = -1; var failure: Error?
        var request = URLRequest(url: url); request.setValue("lwtool/0.1", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: request) { data, response, error in
            got = data; failure = error; status = (response as? HTTPURLResponse)?.statusCode ?? -1
            sem.signal()
        }.resume()
        sem.wait()
        guard let data = got else { fail("fetch failed: \(failure.map { "\($0)" } ?? "?")") }
        print("HTTP \(status), \(data.count) bytes, \(Int(Date().timeIntervalSince(t0) * 1000)) ms")
        field = try OpenMeteoSky.decode(data)
    }
    let sun = Solar.position(latitude: c.lat, longitude: c.lon, date: when)
    print("cells: \(field.samples.count) distinct of \(points.count) requested; \(field.samples.first?.times.count ?? 0) 15-min steps each")
    if !sun.isUp { print("note: sun is below the horizon at that time; beam is 0 regardless of cloud") }
    print(String(format: "sun at %@: az %.1f° el %.1f°  clear-sky DNI %.0f W/m²",
                 ISO8601DateFormatter().string(from: when), sun.azimuth, sun.elevation,
                 ClearSky.directNormal(elevation: sun.elevation)))
    for s in field.samples.sorted(by: { haversineMeters(c.lat, c.lon, $0.latitude, $0.longitude) < haversineMeters(c.lat, c.lon, $1.latitude, $1.longitude) }) {
        let d = haversineMeters(c.lat, c.lon, s.latitude, s.longitude)
        if let cond = s.condition(at: when, sunElevation: sun.elevation) {
            print(String(format: "  cell %.4f,%.4f  %4.0f m  dni %4.0f dif %4.0f cloud %3.0f%% low %3.0f%%  beam %.2f  %@",
                         s.latitude, s.longitude, d, cond.directNormal, cond.diffuse,
                         cond.cloudCover * 100, cond.lowCloud * 100, cond.beamStrength, cond.summary))
        } else {
            print(String(format: "  cell %.4f,%.4f  %4.0f m  (no data at that time)", s.latitude, s.longitude, d))
        }
    }
    if let here = field.condition(latitude: c.lat, longitude: c.lon, at: when, sunElevation: sun.elevation) {
        print(String(format: "here: beam %.2f -> %@", here.beamStrength, here.summary))
    }
    if let spread = field.beamSpread(at: when, sunElevation: sun.elevation) {
        print(String(format: "spread across cells: %.2f … %.2f%@", spread.min, spread.max,
                     spread.max - spread.min >= 0.4 ? "  (two weathers)" : ""))
    }
    exit(0)
}

/// A single bundle (`--bundle`), or a metro (`--metro Server/nyc`) stitched from the
/// tiles within `--reach` metres (default 2500, as the app does) of the points given.
/// `--no-far` drops the far-field terrain, the baseline for "what do distant hills add".
func loadCity() throws -> CityBundle {
    if let dir = option("metro") {
        let base = URL(fileURLWithPath: dir)
        guard let data = try? Data(contentsOf: base.appendingPathComponent("metro.json")),
              let index = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tLat = index["tileLat"] as? Double, let tLon = index["tileLon"] as? Double,
              let tiles = index["tiles"] as? [[String: Any]] else { fail("no metro.json in \(dir)") }
        let pts = ["center", "from", "to"].compactMap { option($0) }.map { coordinate($0, "point") }
        guard !pts.isEmpty else { fail("--metro needs --center or --from/--to") }
        let reach = Double(option("reach") ?? "2500") ?? 2500
        let box = BBox.around(pts.map { ($0.lat, $0.lon) }, paddingMeters: reach)
        let i0 = Int((box.minLat / tLat).rounded(.down)), i1 = Int((box.maxLat / tLat).rounded(.down))
        let j0 = Int((box.minLon / tLon).rounded(.down)), j1 = Int((box.maxLon / tLon).rounded(.down))
        let chosen = tiles.filter {
            let i = $0["i"] as! Int, j = $0["j"] as! Int
            return i >= i0 && i <= i1 && j >= j0 && j <= j1
        }
        guard !chosen.isEmpty else { fail("no tiles near those points") }
        let t0 = CFAbsoluteTimeGetCurrent()
        let raws = try chosen.map { try RawBundle(contentsOf: base.appendingPathComponent($0["file"] as! String)) }
        let t1 = CFAbsoluteTimeGetCurrent()
        var far: TerrainGrid? = nil
        if !CommandLine.arguments.contains("--no-far"), let f = index["far"] as? [String: Any], let file = f["file"] as? String {
            far = try RawBundle(contentsOf: base.appendingPathComponent(file)).terrain
        }
        let city = try TileStitcher.stitch(raws, farTerrain: far)
        let t2 = CFAbsoluteTimeGetCurrent()
        let bytes = chosen.reduce(0) { $0 + ($1["bytes"] as! Int) }
        FileHandle.standardError.write(Data(String(format: "stitched %d tiles (%.1f MB): %d nodes, %d edges, %d buildings; read %.0f ms, stitch %.0f ms\n",
            chosen.count, Double(bytes) / 1e6, city.graph.nodeCount, city.graph.edgeCount,
            city.buildings.count, (t1 - t0) * 1000, (t2 - t1) * 1000).utf8))
        return city
    }
    let bundlePath = option("bundle") ?? FileManager.default.currentDirectoryPath + "/Resources/sanfrancisco.lwbundle"
    guard FileManager.default.fileExists(atPath: bundlePath) else { fail("no bundle at \(bundlePath)") }
    return try CityBundle(contentsOf: URL(fileURLWithPath: bundlePath))
}

let city = try loadCity()
let graph = city.graph
/// `--max-height 100` reproduces the old fixed shadow search, for before/after diffs.
let maxHeightOption = option("max-height").flatMap(Double.init)

struct Feature { var coords: [(lat: Double, lon: Double)]; var properties: [String: Any] }

func writeGeoJSON(_ features: [Feature], meta: [String: Any], to path: String) {
    var objects: [[String: Any]] = []
    for f in features {
        objects.append([
            "type": "Feature",
            "geometry": ["type": "LineString",
                         "coordinates": f.coords.map { [$0.lon, $0.lat] }],
            "properties": f.properties,
        ])
    }
    let root: [String: Any] = ["type": "FeatureCollection", "features": objects, "meta": meta]
    let data = try! JSONSerialization.data(withJSONObject: root, options: [])
    try! data.write(to: URL(fileURLWithPath: path))
    print("wrote \(path): \(features.count) features")
}

func edgeFeature(_ e: Int32, properties: [String: Any]) -> Feature {
    let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
    var props = properties
    props["crossing"] = graph.isCrossing(Int(e))
    props["sidewalk"] = graph.isSidewalk(Int(e))
    props["synthetic"] = graph.isSynthetic(Int(e))
    props["private"] = graph.isPrivate(Int(e))
    props["interest"] = Int(graph.edgeInterest[Int(e)])
    return Feature(coords: [(graph.nodeLat[a], graph.nodeLon[a]),
                            (graph.nodeLat[b], graph.nodeLon[b])], properties: props)
}

let command = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : ""
let out = option("out") ?? "out.geojson"

switch command {
case "corridor":
    let from = coordinate(option("from"), "from")
    let to = coordinate(option("to"), "to")
    let slack = Double(option("slack") ?? "0.1") ?? 0.1
    guard let origin = graph.nearestConnectedNode(lat: from.lat, lon: from.lon) else { fail("origin off graph") }
    guard let dest = graph.nearestNode(lat: to.lat, lon: to.lon, inComponent: graph.component[Int(origin)]) else {
        fail("destination off graph")
    }
    let labels = try CorridorEngine.labels(graph: graph, destination: dest, origin: origin,
                                           slack: max(slack, 0.35) + 0.15)
    let corridor = try CorridorEngine.corridor(graph: graph, labels: labels, origin: origin, slack: slack)
    let features = corridor.edges.enumerated().map { i, e in
        edgeFeature(e, properties: ["excess": corridor.excess[i]])
    }
    writeGeoJSON(features, meta: [
        "distance": corridor.distance, "slack": slack,
        "edges": corridor.edges.count, "crossings": corridor.crossingEdges.count,
        "choicesHere": corridor.choicesHere, "metersToDecision": corridor.metersToDecision,
        "labelMs": labels.computeMs, "corridorMs": corridor.computeMs,
        "origin": [graph.nodeLat[Int(origin)], graph.nodeLon[Int(origin)]],
        "destination": [graph.nodeLat[Int(dest)], graph.nodeLon[Int(dest)]],
    ], to: out)

case "sun":
    let center = coordinate(option("center"), "center")
    let radius = Double(option("radius") ?? "400") ?? 400
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    let sun: SolarPosition
    if let az = option("azimuth").flatMap(Double.init), let el = option("elevation").flatMap(Double.init) {
        // Experiments: aim the sun by hand instead of by clock.
        sun = SolarPosition(elevation: el, azimuth: az, declination: 0, equationOfTime: 0)
    } else {
        guard let at = formatter.date(from: option("at") ?? "") else { fail("--at needs an ISO 8601 UTC time, or --azimuth/--elevation") }
        sun = Solar.position(latitude: center.lat, longitude: center.lon, date: at)
    }
    city.buildings.useTerrain = !CommandLine.arguments.contains("--no-terrain")
    var scorer = SunScorer(buildings: city.buildings, maxBuildingHeight: maxHeightOption)
    let ids = graph.edges(near: center.lat, lon: center.lon, radius: radius)
    let t0 = CFAbsoluteTimeGetCurrent()
    let scores = scorer.score(graph: graph, edges: ids, sun: sun)
    let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
    let features = ids.enumerated().map { i, e in
        edgeFeature(e, properties: ["sun": Double(scores[i]),
                                    "bucket": SunBucket(fraction: scores[i]).rawValue])
    }
    writeGeoJSON(features, meta: [
        "azimuth": sun.azimuth, "elevation": sun.elevation, "isUp": sun.isUp,
        "at": option("at") ?? "manual", "center": [center.lat, center.lon], "radius": radius,
        "edges": ids.count, "computeMs": ms,
    ], to: out)
    var buckets = [0, 0, 0]
    for v in scores { buckets[SunBucket(fraction: v).rawValue] += 1 }
    print(String(format: "sun az %.0f el %.1f · %d edges in %.0f ms · shaded %d / mixed %d / sunny %d",
                 sun.azimuth, sun.elevation, ids.count, ms, buckets[0], buckets[1], buckets[2]))

case "sunbias":
    // Does scoring a road centreline stand in for its kerbs, or is the middle of the
    // road systematically sunnier? Takes every centreline we KNOW has sidewalks
    // (tagged sidewalk=both/left/right) and compares its own sun score against the
    // score at points offset perpendicular to it, where the kerbs actually are.
    let center = coordinate(option("center"), "center")
    let radius = Double(option("radius") ?? "600") ?? 600
    let offset = Double(option("offset") ?? "8") ?? 8
    let formatter = ISO8601DateFormatter()
    formatter.formatOptions = [.withInternetDateTime]
    guard let at = formatter.date(from: option("at") ?? "") else { fail("--at needs an ISO 8601 UTC time") }
    let sun = Solar.position(latitude: center.lat, longitude: center.lon, date: at)
    var scorer = SunScorer(buildings: city.buildings, maxBuildingHeight: maxHeightOption)
    let plane = city.buildings.plane

    var pairs = 0
    var centreTotal = 0.0, kerbTotal = 0.0
    var disagreeBothKerbs = 0, kerbsDisagreeWithEachOther = 0
    var stamp: Int32 = 0

    for e in graph.edges(near: center.lat, lon: center.lon, radius: radius)
    where graph.isStreetWithSidewalkTag(Int(e)) {
        let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
        let pa = plane.project(lat: graph.nodeLat[a], lon: graph.nodeLon[a])
        let pb = plane.project(lat: graph.nodeLat[b], lon: graph.nodeLon[b])
        let dx = pb.x - pa.x, dy = pb.y - pa.y
        let length = (dx * dx + dy * dy).squareRoot()
        guard length > 12 else { continue }
        let nx = -dy / length * offset, ny = dx / length * offset   // perpendicular

        func score(_ ox: Double, _ oy: Double) -> Float {
            let ca = plane.unproject(x: pa.x + ox, y: pa.y + oy)
            let cb = plane.unproject(x: pb.x + ox, y: pb.y + oy)
            stamp = stamp &+ 16
            return scorer.score(aLat: ca.lat, aLon: ca.lon, bLat: cb.lat, bLon: cb.lon,
                                sun: sun, stamp: stamp)
        }

        let centre = score(0, 0)
        let left = score(nx, ny)
        let right = score(-nx, -ny)
        let kerbs = (left + right) / 2

        pairs += 1
        centreTotal += Double(centre)
        kerbTotal += Double(kerbs)
        if SunBucket(fraction: centre) != SunBucket(fraction: left)
            && SunBucket(fraction: centre) != SunBucket(fraction: right) { disagreeBothKerbs += 1 }
        if SunBucket(fraction: left) != SunBucket(fraction: right) { kerbsDisagreeWithEachOther += 1 }
    }

    guard pairs > 0 else { fail("no tagged centrelines in range") }
    print(String(format: "sun az %.0f el %.0f · %d tagged centrelines · kerb offset %.0f m",
                 sun.azimuth, sun.elevation, pairs, offset))
    print(String(format: "  centreline mean sun   %.3f", centreTotal / Double(pairs)))
    print(String(format: "  kerb mean sun         %.3f", kerbTotal / Double(pairs)))
    print(String(format: "  centreline bias       %+.3f (%+.1f%% of an edge in sun)",
                 (centreTotal - kerbTotal) / Double(pairs),
                 100 * (centreTotal - kerbTotal) / Double(pairs)))
    print(String(format: "  centreline bucket disagrees with BOTH kerbs: %d of %d (%.0f%%)",
                 disagreeBothKerbs, pairs, 100 * Double(disagreeBothKerbs) / Double(pairs)))
    print(String(format: "  the two kerbs disagree with each other:      %d of %d (%.0f%%)",
                 kerbsDisagreeWithEachOther, pairs, 100 * Double(kerbsDisagreeWithEachOther) / Double(pairs)))

case "coverage":
    // What kind of edges are around a point: the per-side sidewalk share is the number
    // that decides whether the sun layer can say which side of the street is lit.
    let center = coordinate(option("center"), "center")
    let radius = Double(option("radius") ?? "600") ?? 600
    // Length-weighted, and only over the two kinds of edge that compete for the same
    // street frontage: a sidewalk on one side, or the bare road centreline.
    var sidewalkM = 0.0, syntheticM = 0.0, streetM = 0.0
    var sidewalkN = 0, streetN = 0
    for e in graph.edges(near: center.lat, lon: center.lon, radius: radius) {
        let i = Int(e); let L = graph.edgeLen[i]
        if graph.isSidewalk(i) { sidewalkM += L; sidewalkN += 1; if graph.isSynthetic(i) { syntheticM += L } }
        else if graph.isStreetCentreline(i) { streetM += L; streetN += 1 }
    }
    // Two sidewalks serve one street, so compare sidewalk metres against twice the bare
    // centreline metres: the share of kerb-metres that actually have a sidewalk edge.
    let kerbShare = sidewalkM / max(sidewalkM + 2 * streetM, 1)
    let label = option("label") ?? String(format: "%.4f,%.4f", center.lat, center.lon)
    print(String(format: "%-32@ sidewalk %6.1f km (%d edges, %.0f%% synthesised) · bare street %5.1f km (%d edges) · kerbs with a sidewalk edge: %3.0f%%",
                 label as NSString, sidewalkM / 1000, sidewalkN, 100 * syntheticM / max(sidewalkM, 1),
                 streetM / 1000, streetN, 100 * kerbShare))

default:
    fail("usage: lwtool corridor|sun|sunbias|coverage|sky [options]")
}
