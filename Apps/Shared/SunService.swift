import Foundation
import CoreLocation
import MapKit
import LikeWaterEngine

struct SunEdge: Sendable {
    var a: CLLocationCoordinate2D
    var b: CLLocationCoordinate2D
    var bucket: SunBucket
}

/// One scored tile of the sun field: a street-detail tile holds edges, a block tile cells.
struct SunTile: Sendable {
    var key: SunTileKey
    var edges: [SunEdge]
    var cells: [SunCell]
    var scoredEdges: Int
    var computeMs: Double
    var sunnyCount: Int
    var mixedCount: Int
    var shadedCount: Int
    /// The metro tile isn't on the phone (and couldn't be fetched now): nothing to show.
    var missing = false
    var fromCache = false
    /// Identifies the content (place build, tile, slot): the map replaces a tile's overlays
    /// when its stamp changes, e.g. after a scrub to another 15-minute slot.
    var stamp = ""
}

struct SunField: Sendable {
    var city: String
    var detail: SunDetail
    var tiles: [SunTile]
    var sun: SolarPosition
    var center: CLLocationCoordinate2D
    var date: Date
    /// The sky over the map centre at `date`; nil when no forecast could be had.
    var sky: SkyCondition?
    /// Spread of beam strength across the sampled cells, for "two weathers" wording.
    var skySpread: (min: Double, max: Double)?
    /// Where the sky came from: "forecast", a preset name, or "override".
    var skySource: String
    /// The city's own time zone, so a Californian looking at Manhattan sees New York time.
    var timeZone: TimeZone?
    /// Metro tiles stitched for the street-detail graph (0 for a single-file city).
    var stitchedTiles: Int = 0
    var downloaded: Int = 0
    /// `.partial` when part of the screen is outside the place's data.
    var coverage: CoverageState = .covered
    /// The metro build painted (nil for a single-file city), and the on-disk cache size.
    var built: String?
    var cacheBytes: Int = 0
    var prefetched: Int = 0
    /// True while tiles are still arriving (the field was published mid-way).
    var inProgress = false
    /// Names the stitched tile set ("1189_-2448…1190_-2446"); changes when a pan needs a new stitch.
    var stitchID: String = "-"

    var keys: Set<SunTileKey> { Set(tiles.map(\.key)) }
    var edges: [SunEdge] { tiles.flatMap(\.edges) }
    var cells: [SunCell] { tiles.flatMap(\.cells) }
    var scoredEdges: Int { tiles.reduce(0) { $0 + $1.scoredEdges } }
    var computeMs: Double { tiles.reduce(0) { $0 + $1.computeMs } }
    var sunnyCount: Int { tiles.reduce(0) { $0 + $1.sunnyCount } }
    var mixedCount: Int { tiles.reduce(0) { $0 + $1.mixedCount } }
    var shadedCount: Int { tiles.reduce(0) { $0 + $1.shadedCount } }
    var cachedTiles: Int { tiles.filter(\.fromCache).count }
    var missingTiles: Int { tiles.filter(\.missing).count }
    var cellCount: Int { tiles.reduce(0) { $0 + $1.cells.count } }
}

/// Nothing built here, or too far out. The sky and the sun still work anywhere, so they come along.
enum SunServiceError: Error, LocalizedError {
    case notCovered(CoverageState, sky: SkyCondition?, sun: SolarPosition, timeZone: TimeZone?)
    case tooFarOut

    var errorDescription: String? {
        switch self {
        case .notCovered: return "No sun data here yet."
        case .tooFarOut: return "Zoom in to see sun data."
        }
    }
}

/// How the user wants the sky handled.
enum SkyMode: String, CaseIterable, Identifiable {
    case auto = "Auto", clear = "Sunny", partly = "Partly", overcast = "Cloudy"
    var id: String { rawValue }

    var preset: WeatherService.Preset? {
        switch self {
        case .auto: return nil
        case .clear: return .clear
        case .partly: return .partly
        case .overcast: return .overcast
        }
    }
}

/// What part of the map gets a sun field: everything on screen plus a margin, so a small
/// pan doesn't expose an unpainted edge — capped, so a zoomed-out view stays interactive.
enum SunArea {
    /// Past this the screen is a region, not a map; nothing is scored.
    static let maxSideMetres = SunLattice.maxSideMetres
    /// Street-detail fields are scored this much past the screen edge; blocks get a ring of tiles.
    static let margin = 0.15

    static func box(_ region: MKCoordinateRegion) -> BBox {
        BBox(minLat: region.center.latitude - region.span.latitudeDelta / 2,
             minLon: region.center.longitude - region.span.longitudeDelta / 2,
             maxLat: region.center.latitude + region.span.latitudeDelta / 2,
             maxLon: region.center.longitude + region.span.longitudeDelta / 2)
    }

    static func around(_ c: CLLocationCoordinate2D, metres: Double) -> BBox {
        BBox.around([(c.latitude, c.longitude)], paddingMeters: metres)
    }

    /// The longer side of a box, metres.
    static func sideMetres(_ box: BBox) -> Double {
        let h = (box.maxLat - box.minLat) * 111_320
        let w = (box.maxLon - box.minLon) * 111_320 * max(0.2, cos(box.centerLat * .pi / 180))
        return max(h, w)
    }

    /// Detail for a screen, or nil when zoomed out past `maxSideMetres`.
    static func detail(for visible: BBox) -> SunDetail? { SunLattice.detail(forSide: sideMetres(visible)) }

    /// What to score for a screen: the detail its size calls for, the box (the screen plus
    /// a margin at street detail) and the score tiles that box needs. Nil when too far out.
    struct Plan: Equatable {
        var detail: SunDetail
        /// What is on screen: coverage ("only part of this screen…") is judged on this.
        var visible: BBox
        /// What is scored: the screen plus a margin at street detail.
        var box: BBox
        var keys: [SunTileKey]
        var keySet: Set<SunTileKey> { Set(keys) }
    }

    static func plan(for visible: BBox) -> Plan? {
        guard let detail = detail(for: visible) else { return nil }
        let m = detail.isBlocks ? 0 : margin
        let halfH = (visible.maxLat - visible.minLat) / 2 * (1 + 2 * m)
        let halfW = (visible.maxLon - visible.minLon) / 2 * (1 + 2 * m)
        let box = BBox(minLat: visible.centerLat - halfH, minLon: visible.centerLon - halfW,
                       maxLat: visible.centerLat + halfH, maxLon: visible.centerLon + halfW)
        return Plan(detail: detail, visible: visible, box: box, keys: SunLattice.keys(in: box, detail: detail))
    }

    /// Recompute when the screen wants a tile the field doesn't have, or a different detail.
    static func needsRecompute(visible: BBox, scored: Plan?) -> Bool {
        guard let scored else { return true }
        guard let wanted = plan(for: visible) else { return true }
        return wanted.detail != scored.detail || !wanted.keySet.isSubset(of: scored.keySet)
    }
}

/// Nothing built here, or too far out. The sky and the sun still work anywhere, so they come along.
actor SunService {
    static let slotSeconds = 900.0
    static let cacheLimit = 320
    /// Metro tiles fetched for one zoomed-out field (Wi-Fi only); the rest show up next time.
    static let maxTileDownloadsPerField = 8

    private var cache: [String: SunTile] = [:]
    private var cacheOrder: [String] = []
    /// One scorer per stitched city: a metro re-stitches as you move, and keeping a scorer
    /// (a building-count scratch array) per stitch would leak.
    private var scorer: (id: String, scorer: SunScorer)?

    private func cacheKey(_ place: String, _ key: SunTileKey, slot: Int) -> String { "\(place)|\(key)|\(slot)" }

    private func cached(_ k: String) -> SunTile? {
        guard var t = cache[k] else { return nil }
        cacheOrder.removeAll { $0 == k }; cacheOrder.append(k)
        t.fromCache = true
        return t
    }

    private func store(_ tile: SunTile, as k: String) {
        var t = tile; t.stamp = k
        cache[k] = t; cacheOrder.append(k)
        while cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
    }

    func field(around center: CLLocationCoordinate2D, radius: Double, at date: Date,
               skyMode: SkyMode = .auto) async throws -> SunField {
        try await field(in: SunArea.around(center, metres: radius), at: date, skyMode: skyMode)
    }

    func field(in box: BBox, at date: Date, skyMode: SkyMode = .auto) async throws -> SunField {
        guard let plan = SunArea.plan(for: box) else { throw SunServiceError.tooFarOut }
        return try await field(plan, at: date, skyMode: skyMode)
    }

    /// Scores every score tile a plan needs. `progress` sees the field grow as tiles finish.
    func field(_ plan: SunArea.Plan, at date: Date, skyMode: SkyMode = .auto,
               progress: (@Sendable (SunField) -> Void)? = nil) async throws -> SunField {
        let detail = plan.detail, box = plan.box
        let center = CLLocationCoordinate2D(latitude: box.centerLat, longitude: box.centerLon)
        let slot = Int((date.timeIntervalSince1970 / Self.slotSeconds).rounded(.down))
        let slotDate = Date(timeIntervalSince1970: Double(slot) * Self.slotSeconds)
        let sun = Solar.position(latitude: center.latitude, longitude: center.longitude, date: date)

        // Weather and geometry are independent; fetch the sky while scoring.
        let skyTask = Task<(SkyField?, String), Never> {
            if let preset = skyMode.preset {
                return (WeatherService.field(for: preset, around: center, at: date), "override")
            }
            let field = await WeatherService.shared.sky(around: center, for: date)
            return (field, WeatherService.launchPreset()?.rawValue ?? "forecast")
        }

        let places: [Place]
        do {
            places = try await resolvePlaces(box: box, detail: detail)
        } catch CityCatalogError.noCoverage, CityCatalogError.noServer {
            // Not built here: say so calmly, with the sky and sun that work anywhere.
            let (skyField, _) = await skyTask.value
            let sky = skyField?.condition(latitude: center.latitude, longitude: center.longitude,
                                          at: date, sunElevation: sun.elevation)
            let state = await CityCatalog.shared.coverageState(for: box)
            throw SunServiceError.notCovered(state.hasData ? .notBuilt(nearest: nil, km: nil) : state,
                                             sky: sky, sun: sun, timeZone: nil)
        }
        try Task.checkCancellation()
        guard let main = places.first else { throw SunServiceError.notCovered(.notBuilt(nearest: nil, km: nil), sky: nil, sun: sun, timeZone: nil) }

        var field = SunField(city: main.name + (places.count > 1 ? " +\(places.count - 1)" : ""), detail: detail, tiles: [],
                             sun: sun, center: center, date: date, sky: nil, skySpread: nil, skySource: "",
                             timeZone: main.timeZone, stitchedTiles: main.stitchedTiles, downloaded: main.downloaded,
                             coverage: places.contains { $0.bounds.contains(plan.visible) } ? .covered : .partial,
                             built: main.built, cacheBytes: await CityStore.shared.cachedBytes,
                             prefetched: await CityStore.shared.prefetched, inProgress: true,
                             stitchID: main.stitchID)
        let keys = plan.keys
        var pending: [(SunTileKey, [Place])] = []
        for key in keys {
            let here = places.filter { $0.bounds.intersects(key.box) }
            guard !here.isEmpty else { continue }
            let hits = here.compactMap { cached(cacheKey($0.id, key, slot: slot)) }
            if hits.count == here.count { field.tiles.append(Self.merge(hits)) } else { pending.append((key, here)) }
        }
        var lastPublish = CFAbsoluteTimeGetCurrent()
        var downloads = 0
        for (key, here) in pending {
            try Task.checkCancellation()
            var parts: [SunTile] = []
            for place in here {
                let k = cacheKey(place.id, key, slot: slot)
                if let hit = cached(k) { parts.append(hit); continue }
                let tile: SunTile
                switch detail {
                case .streets:
                    tile = scoreStreets(place: place, key: key, sun: Solar.position(latitude: key.box.centerLat, longitude: key.box.centerLon, date: slotDate))
                case .blocks(let level):
                    let (t, fetched) = try await scoreBlocks(place: place, key: key, level: level, slotDate: slotDate,
                                                             download: downloads < Self.maxTileDownloadsPerField)
                    if fetched { downloads += 1 }
                    tile = t
                }
                var stamped = tile; stamped.stamp = k
                if !tile.missing { store(tile, as: k) }
                parts.append(stamped)
            }
            field.tiles.append(Self.merge(parts))
            let now = CFAbsoluteTimeGetCurrent()
            if let progress, now - lastPublish > 0.12, field.tiles.count < keys.count {
                lastPublish = now
                progress(field)
            }
        }

        let (skyField, source) = await skyTask.value
        field.sky = skyField?.condition(latitude: center.latitude, longitude: center.longitude,
                                        at: date, sunElevation: sun.elevation)
        field.skySpread = skyField?.beamSpread(at: date, sunElevation: sun.elevation)
        field.skySource = source
        field.inProgress = false
        return field
    }

    /// Scores the ring of street tiles around a box at low priority, so the next pan has them.
    func prefetch(_ plan: SunArea.Plan, at date: Date, ring: Int = 1) async {
        guard case .streets = plan.detail else { return }
        let detail = plan.detail, box = plan.box
        let outer = SunLattice.keys(in: box, detail: detail, ring: ring)
        let inner = plan.keySet
        let slot = Int((date.timeIntervalSince1970 / Self.slotSeconds).rounded(.down))
        let slotDate = Date(timeIntervalSince1970: Double(slot) * Self.slotSeconds)
        guard let place = try? await resolvePlaces(box: box, detail: detail).first else { return }
        for key in outer where !inner.contains(key) {
            if Task.isCancelled { return }
            let k = cacheKey(place.id, key, slot: slot)
            // Only a tile the stitched graph fully covers: a half-covered one would be cached
            // as if complete and show up half empty on the next pan.
            guard cache[k] == nil, key.box.intersects(place.bounds),
                  place.validBox.map({ $0.contains(key.box) }) ?? true else { continue }
            let tile = scoreStreets(place: place, key: key, sun: Solar.position(latitude: key.box.centerLat, longitude: key.box.centerLon, date: slotDate))
            store(tile, as: k)
            await Task.yield()
        }
    }

    /// One score tile from the parts several places contributed to it.
    static func merge(_ parts: [SunTile]) -> SunTile {
        guard parts.count > 1, var out = parts.first else { return parts[0] }
        for p in parts.dropFirst() {
            out.edges += p.edges; out.cells += p.cells
            out.scoredEdges += p.scoredEdges; out.computeMs += p.computeMs
            out.sunnyCount += p.sunnyCount; out.mixedCount += p.mixedCount; out.shadedCount += p.shadedCount
            out.missing = out.missing || p.missing
            out.fromCache = out.fromCache && p.fromCache
            out.stamp += "+" + p.stamp
        }
        return out
    }

    // MARK: - Places

    /// What a field is scored from: a stitched/loaded city (street detail), or a metro whose
    /// tiles are scored one file at a time (blocks).
    private enum Place {
        case city(LoadedCity)
        case metro(MetroDescriptor)
        case single(LoadedCity)

        var id: String {
            switch self {
            case .city(let c): return c.metroID.map { "\($0)@\(MetroIndex.buildKey(c.built))" } ?? c.id
            case .single(let c): return c.id
            case .metro(let m): return "\(m.id)@\(m.buildKey)"
            }
        }
        var name: String { switch self { case .city(let c), .single(let c): return c.name; case .metro(let m): return m.name } }
        var timeZone: TimeZone? { switch self { case .city(let c), .single(let c): return c.timeZone; case .metro(let m): return m.timeZone } }
        var bounds: BBox { switch self { case .city(let c), .single(let c): return c.extent; case .metro(let m): return m.index.bbox } }
        var validBox: BBox? { if case .city(let c) = self { return c.validBox }; return nil }
        var built: String? { switch self { case .city(let c), .single(let c): return c.built; case .metro(let m): return m.index.built } }
        var stitchedTiles: Int { if case .city(let c) = self { return c.tiles.count }; return 0 }
        var stitchID: String {
            guard case .city(let c) = self, let lo = c.tiles.min(), let hi = c.tiles.max() else { return "-" }
            return lo + "…" + hi
        }
        var downloaded: Int { if case .city(let c) = self { return c.downloaded }; return 0 }
        func coverage(of box: BBox) -> CoverageState { bounds.contains(box) ? .covered : .partial }
    }

    /// Street detail: the one stitched/loaded city for the screen. Blocks: every metro
    /// (scored a tile at a time) and every single-file city under the screen, most
    /// overlap first — a Bay Area view paints San Francisco and Berkeley both.
    private func resolvePlaces(box: BBox, detail: SunDetail) async throws -> [Place] {
        let corners = [CLLocationCoordinate2D(latitude: box.centerLat, longitude: box.centerLon),
                       CLLocationCoordinate2D(latitude: box.minLat, longitude: box.minLon),
                       CLLocationCoordinate2D(latitude: box.minLat, longitude: box.maxLon),
                       CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.minLon),
                       CLLocationCoordinate2D(latitude: box.maxLat, longitude: box.maxLon)]
        if case .streets = detail {
            return [.city(try await CityStore.shared.city(covering: corners))]
        }
        var out: [(Place, Double)] = []
        for m in await CityCatalog.shared.metros(intersecting: box) {
            out.append((.metro(m), m.index.bbox.overlapArea(box)))
        }
        for d in await CityCatalog.shared.localCities(intersecting: box) {
            guard let c = try? await CityStore.shared.load(d) else { continue }
            out.append((.single(c), d.bbox.overlapArea(box)))
        }
        guard !out.isEmpty else { throw CityCatalogError.noCoverage }
        return out.sorted { $0.1 > $1.1 }.map(\.0)
    }

    // MARK: - Scoring one tile

    private func takeScorer(for city: LoadedCity) -> SunScorer {
        let s = (scorer?.id == city.id ? scorer?.scorer : nil) ?? SunScorer(buildings: city.bundle.buildings)
        scorer = nil
        return s
    }

    private func scoreStreets(place: Place, key: SunTileKey, sun: SolarPosition) -> SunTile {
        guard case .city(let city) = place else { return SunTile(key: key, edges: [], cells: [], scoredEdges: 0, computeMs: 0, sunnyCount: 0, mixedCount: 0, shadedCount: 0, missing: true) }
        let graph = city.bundle.graph
        var scorer = takeScorer(for: city)
        let t0 = CFAbsoluteTimeGetCurrent()
        let box = key.box
        // An edge belongs to the tile holding its midpoint, so tile borders draw it once.
        let ids = graph.edges(in: box).filter { e in
            let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
            return box.contains(lat: (graph.nodeLat[a] + graph.nodeLat[b]) / 2, lon: (graph.nodeLon[a] + graph.nodeLon[b]) / 2)
        }
        let scores = scorer.score(graph: graph, edges: ids, sun: sun)
        self.scorer = (city.id, scorer)
        var out: [SunEdge] = []
        out.reserveCapacity(ids.count)
        var sunny = 0, mixed = 0, shaded = 0
        for (i, e) in ids.enumerated() {
            let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
            let bucket = sun.isUp ? SunBucket(fraction: scores[i]) : .shaded
            switch bucket { case .sunny: sunny += 1; case .mixed: mixed += 1; case .shaded: shaded += 1 }
            out.append(SunEdge(a: CLLocationCoordinate2D(latitude: graph.nodeLat[a], longitude: graph.nodeLon[a]),
                               b: CLLocationCoordinate2D(latitude: graph.nodeLat[b], longitude: graph.nodeLon[b]),
                               bucket: bucket))
        }
        return SunTile(key: key, edges: out, cells: [], scoredEdges: ids.count,
                       computeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                       sunnyCount: sunny, mixedCount: mixed, shadedCount: shaded)
    }

    /// Returns the tile and whether a metro tile was downloaded for it.
    private func scoreBlocks(place: Place, key: SunTileKey, level: Int, slotDate: Date,
                             download: Bool) async throws -> (SunTile, Bool) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let empty = SunTile(key: key, edges: [], cells: [], scoredEdges: 0, computeMs: 0, sunnyCount: 0, mixedCount: 0, shadedCount: 0)
        let graph: PedestrianGraph, buildings: BuildingStore
        var fetched = false
        switch place {
        case .metro(let m):
            guard let t = m.index.tiles.first(where: { $0.i == key.i && $0.j == key.j }) else { return (empty, false) }
            let loaded = try await CityStore.shared.tileBundle(m, t, download: download)
            guard let bundle = loaded.bundle else {
                var missing = empty; missing.missing = true
                return (missing, false)
            }
            fetched = loaded.downloaded
            graph = bundle.graph; buildings = bundle.buildings
        case .city(let c), .single(let c):
            graph = c.bundle.graph; buildings = c.bundle.buildings
        }
        let cell = SunLattice.cellSize(level: level)
        let picked = SunSampler.sample(graph: graph, edges: graph.edges(in: key.box), cellLat: cell.lat, cellLon: cell.lon)
        let sun = Solar.position(latitude: key.box.centerLat, longitude: key.box.centerLon, date: slotDate)
        var scorer = SunScorer(buildings: buildings)
        let scores = scorer.score(graph: graph, edges: picked.edges, sun: sun)
        var cells = SunSampler.cells(graph: graph, sampled: picked.edges, cellKeys: picked.cells, scores: scores,
                                     cellLat: cell.lat, cellLon: cell.lon)
        if !sun.isUp { for i in cells.indices { cells[i].sun = 0 } }
        var sunny = 0, mixed = 0, shaded = 0
        for c in cells {
            switch SunBucket(fraction: c.sun) { case .sunny: sunny += 1; case .mixed: mixed += 1; case .shaded: shaded += 1 }
        }
        return (SunTile(key: key, edges: [], cells: cells, scoredEdges: picked.edges.count,
                        computeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                        sunnyCount: sunny, mixedCount: mixed, shadedCount: shaded), fetched)
    }

    func daylightWindow(at center: CLLocationCoordinate2D, on date: Date) -> (sunrise: Date, sunset: Date)? {
        Solar.daylightWindow(latitude: center.latitude, longitude: center.longitude, containing: date)
    }
}
