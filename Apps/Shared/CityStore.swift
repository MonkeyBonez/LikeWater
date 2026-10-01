import Foundation
import CoreLocation
import LikeWaterEngine

/// A loaded city with a stable identity, so services can cache per-city state.
/// For a metro it is a stitched set of tiles, valid inside `validBox`.
final class LoadedCity {
    let id: String
    let name: String
    let bundle: CityBundle
    let loadMs: Double
    let timeZone: TimeZone?
    /// Where this graph can be trusted: the whole bundle for a single city; the tile set
    /// shrunk by a margin for a metro (except where the metro itself ends), so a walker
    /// near the edge of the loaded tiles triggers a reload before shadows get cut off.
    let validBox: BBox
    /// Metro tiles in this stitch, as "i_j"; empty for a single-file city.
    let tiles: Set<String>
    let metroID: String?
    /// Files fetched from the server to build this city (0 when all were on the phone).
    let downloaded: Int

    init(id: String, name: String, bundle: CityBundle, loadMs: Double, timeZone: TimeZone?,
         validBox: BBox, tiles: Set<String> = [], metroID: String? = nil, downloaded: Int = 0) {
        self.id = id; self.name = name; self.bundle = bundle; self.loadMs = loadMs
        self.timeZone = timeZone; self.validBox = validBox; self.tiles = tiles; self.metroID = metroID
        self.downloaded = downloaded
    }

    func covers(_ c: CLLocationCoordinate2D) -> Bool {
        validBox.contains(lat: c.latitude, lon: c.longitude)
    }
}

/// Main-actor mirror of what the store is doing, for the two apps' status lines.
@MainActor
final class CityLoadState: ObservableObject {
    static let shared = CityLoadState()
    @Published var message: String? = nil
    @Published var progress: Double? = nil
    @Published var cityName: String? = nil
}

/// Loads cities off the main actor, choosing by location: a single bundle shipped with
/// the app or downloaded earlier, or a metro's tiles around the user (downloaded on
/// demand and stitched into one graph).
actor CityStore {
    static let shared = CityStore()

    /// Single-file cities, kept once loaded (the three shipped ones total ~50 MB).
    private var singles: [String: LoadedCity] = [:]
    /// At most one stitched metro at a time; moving on replaces it.
    private var metro: LoadedCity?
    private var inFlight: [String: Task<LoadedCity, Error>] = [:]
    /// Parsed tiles, so re-stitching after a short walk re-reads nothing from disk.
    private var tileCache: [String: RawBundle] = [:]
    private var tileOrder: [String] = []
    private var farCache: [String: TerrainGrid] = [:]
    /// One download per file, shared: a walk's tile set and the start's tile set overlap,
    /// and two loads racing on one file used to fail the second.
    private var fileDownloads: [String: Task<Void, Error>] = [:]

    private func download(_ source: URL, to destination: URL) async throws {
        let key = destination.path
        if let running = fileDownloads[key] { return try await running.value }
        let task = Task<Void, Error> { try await CityCatalog.fetch(source, to: destination) }
        fileDownloads[key] = task
        defer { fileDownloads[key] = nil }
        try await task.value
    }
    static let tileCacheLimit = 16

    /// How far around the user a metro stitch reaches. Buildings within this distance can
    /// shade the map; at 2.5 km a 400 m tower's shadow is covered down to ~9° sun.
    static let reachMetres = 2_500.0
    /// A stitch is reused while the point stays this far inside it.
    static let marginMetres = 1_000.0
    /// A walk whose tile box needs more tiles than this is refused as too long.
    static let maxTiles = 42

    /// The city covering a coordinate. Throws `CityCatalogError.noCoverage` when nothing
    /// local or remote covers it.
    func city(covering coordinate: CLLocationCoordinate2D) async throws -> LoadedCity {
        try await city(covering: [coordinate])
    }

    /// A city covering every point (a walk's start and destination). For a metro this
    /// stitches every tile the walk's box needs.
    func city(covering points: [CLLocationCoordinate2D]) async throws -> LoadedCity {
        guard let first = points.first else { throw CityCatalogError.noCoverage }
        if let metro, points.allSatisfy({ metro.covers($0) }) { return metro }
        if let hit = singles.values.first(where: { c in points.allSatisfy { c.covers($0) } }) { return hit }

        if let m = await CityCatalog.shared.metro(covering: first) {
            return try await loadMetro(m, around: points)
        }
        if let local = await CityCatalog.shared.localCity(covering: first) {
            return try await load(local)
        }
        guard let remote = try await CityCatalog.shared.remoteCity(covering: first) else {
            throw CityCatalogError.noCoverage
        }
        let mb = Double(remote.bytes) / 1e6
        await MainActor.run {
            CityLoadState.shared.cityName = remote.name
            CityLoadState.shared.message = String(format: "Downloading %@ (%.0f MB)…", remote.name, mb)
            CityLoadState.shared.progress = 0
        }
        defer { Task { @MainActor in
            CityLoadState.shared.message = nil
            CityLoadState.shared.progress = nil
        } }
        let descriptor = try await CityCatalog.shared.download(remote) { fraction in
            Task { @MainActor in CityLoadState.shared.progress = fraction }
        }
        return try await load(descriptor)
    }

    func covers(_ coordinate: CLLocationCoordinate2D) async -> Bool {
        if metro?.covers(coordinate) == true { return true }
        if singles.values.contains(where: { $0.covers(coordinate) }) { return true }
        if await CityCatalog.shared.localCity(covering: coordinate) != nil { return true }
        return await CityCatalog.shared.localMetros().contains { $0.covers(coordinate) }
    }

    // MARK: - Single-file cities

    private func load(_ descriptor: CityDescriptor) async throws -> LoadedCity {
        if let hit = singles[descriptor.id] { return hit }
        if let task = inFlight[descriptor.id] { return try await task.value }
        let task = Task<LoadedCity, Error> {
            await MainActor.run {
                CityLoadState.shared.cityName = descriptor.name
                CityLoadState.shared.message = "Loading \(descriptor.name)…"
            }
            let t0 = CFAbsoluteTimeGetCurrent()
            let bundle = try CityBundle(contentsOf: descriptor.url)
            let city = LoadedCity(id: descriptor.id, name: descriptor.name, bundle: bundle,
                                  loadMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                                  timeZone: descriptor.timeZone, validBox: descriptor.bbox)
            await MainActor.run { CityLoadState.shared.message = nil }
            return city
        }
        inFlight[descriptor.id] = task
        defer { inFlight[descriptor.id] = nil }
        let city = try await task.value
        singles[descriptor.id] = city
        return city
    }

    // MARK: - Metros

    /// Tiles for a set of points: every tile within `reachMetres` of the box around them.
    static func tiles(for points: [CLLocationCoordinate2D], in index: MetroIndex) -> [MetroIndex.Tile] {
        let box = BBox.around(points.map { ($0.latitude, $0.longitude) }, paddingMeters: reachMetres)
        return index.tiles(intersecting: box).sorted { ($0.i, $0.j) < ($1.i, $1.j) }
    }

    private func loadMetro(_ m: MetroDescriptor, around points: [CLLocationCoordinate2D]) async throws -> LoadedCity {
        let wanted = Self.tiles(for: points, in: m.index)
        guard !wanted.isEmpty else { throw CityCatalogError.noCoverage }
        guard wanted.count <= Self.maxTiles else { throw CityCatalogError.walkTooLong }
        let key = m.id + ":" + wanted.map { "\($0.i)_\($0.j)" }.joined(separator: ",")
        if let metro, metro.id == key { return metro }
        if let task = inFlight[key] { return try await task.value }

        // Detached from the caller: a map pan that cancels the caller's recompute must
        // not cancel a 40 MB download half way.
        let task = Task<LoadedCity, Error>.detached(priority: .userInitiated) { [points] in
            try await CityStore.shared.buildMetro(m, tiles: wanted, key: key, points: points)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        let city = try await task.value
        metro = city
        return city
    }

    private func buildMetro(_ m: MetroDescriptor, tiles wanted: [MetroIndex.Tile], key: String,
                            points: [CLLocationCoordinate2D]) async throws -> LoadedCity {
        let fm = FileManager.default
        try? fm.createDirectory(at: m.localDirectory, withIntermediateDirectories: true)
        var files = wanted.map(\.file)
        if let far = m.index.far { files.append(far.file) }
        let missing = files.filter { !fm.fileExists(atPath: m.localDirectory.appendingPathComponent($0).path) }
        if !missing.isEmpty {
            guard let remote = m.remoteDirectory else { throw CityCatalogError.noServer }
            let sizes = Dictionary(uniqueKeysWithValues: m.index.tiles.map { ($0.file, $0.bytes) })
            let total = missing.reduce(0) { $0 + (sizes[$1] ?? m.index.far?.bytes ?? 0) }
            await MainActor.run {
                CityLoadState.shared.cityName = m.name
                CityLoadState.shared.message = String(format: "Downloading %@ (%d tiles, %.0f MB)…",
                                                      m.name, missing.count, Double(total) / 1e6)
                CityLoadState.shared.progress = 0
            }
            let done = Counter()
            try await withThrowingTaskGroup(of: Void.self) { group in
                var queue = missing[...]
                func next() {
                    guard let file = queue.popFirst() else { return }
                    group.addTask {
                        try await self.download(remote.appendingPathComponent(file),
                                                to: m.localDirectory.appendingPathComponent(file))
                        let fraction = await done.add(sizes[file] ?? 0, of: max(total, 1))
                        await MainActor.run { CityLoadState.shared.progress = fraction }
                    }
                }
                for _ in 0..<4 { next() }
                while try await group.next() != nil { next() }
            }
        }
        await MainActor.run {
            CityLoadState.shared.cityName = m.name
            CityLoadState.shared.message = "Loading \(m.name)…"
            CityLoadState.shared.progress = nil
        }
        defer { Task { @MainActor in CityLoadState.shared.message = nil } }

        let t0 = CFAbsoluteTimeGetCurrent()
        var raws: [RawBundle] = []
        for t in wanted {
            raws.append(try rawTile(m, t))
        }
        let far = try farTerrain(m)
        let bundle = try TileStitcher.stitch(raws, farTerrain: far)

        // Valid inside the tile set, less a margin — except along the metro's own edge,
        // where there is nothing further to load.
        var box = m.index.tileBox(wanted[0])
        for t in wanted.dropFirst() {
            let b = m.index.tileBox(t)
            box.minLat = min(box.minLat, b.minLat); box.minLon = min(box.minLon, b.minLon)
            box.maxLat = max(box.maxLat, b.maxLat); box.maxLon = max(box.maxLon, b.maxLon)
        }
        let dLat = Self.marginMetres / 111_320
        let dLon = Self.marginMetres / (111_320 * max(0.2, cos(box.centerLat * .pi / 180)))
        let whole = m.index.bbox
        var valid = box
        if box.minLat > whole.minLat + 1e-9 { valid.minLat += dLat }
        if box.maxLat < whole.maxLat - 1e-9 { valid.maxLat -= dLat }
        if box.minLon > whole.minLon + 1e-9 { valid.minLon += dLon }
        if box.maxLon < whole.maxLon - 1e-9 { valid.maxLon -= dLon }
        // Never smaller than what was asked for.
        for p in points {
            valid.minLat = min(valid.minLat, p.latitude); valid.maxLat = max(valid.maxLat, p.latitude)
            valid.minLon = min(valid.minLon, p.longitude); valid.maxLon = max(valid.maxLon, p.longitude)
        }
        return LoadedCity(id: key, name: m.name, bundle: bundle,
                          loadMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000,
                          timeZone: m.timeZone, validBox: valid,
                          tiles: Set(wanted.map { "\($0.i)_\($0.j)" }), metroID: m.id,
                          downloaded: missing.count)
    }

    private func rawTile(_ m: MetroDescriptor, _ t: MetroIndex.Tile) throws -> RawBundle {
        let key = m.id + "/" + t.file
        if let hit = tileCache[key] {
            tileOrder.removeAll { $0 == key }; tileOrder.append(key)
            return hit
        }
        let raw = try RawBundle(contentsOf: m.localDirectory.appendingPathComponent(t.file))
        tileCache[key] = raw
        tileOrder.append(key)
        while tileOrder.count > Self.tileCacheLimit { tileCache[tileOrder.removeFirst()] = nil }
        return raw
    }

    private func farTerrain(_ m: MetroDescriptor) throws -> TerrainGrid? {
        if let hit = farCache[m.id] { return hit }
        guard let far = m.index.far else { return nil }
        let grid = try RawBundle(contentsOf: m.localDirectory.appendingPathComponent(far.file)).terrain
        farCache[m.id] = grid
        return grid
    }

    func stats(for city: LoadedCity) -> (nodes: Int, edges: Int, buildings: Int, tiles: Int, loadMs: Double) {
        (city.bundle.graph.nodeCount, city.bundle.graph.edgeCount, city.bundle.buildings.count,
         city.tiles.count, city.loadMs)
    }
}

private actor Counter {
    var bytes = 0
    func add(_ n: Int, of total: Int) -> Double {
        bytes += n
        return min(1, Double(bytes) / Double(total))
    }
}
