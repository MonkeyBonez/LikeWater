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
    /// The whole place's bounds (the metro's, or the single bundle's), for coverage.
    let extent: BBox
    /// The metro build the tiles came from; nil for a single-file city.
    let built: String?

    init(id: String, name: String, bundle: CityBundle, loadMs: Double, timeZone: TimeZone?,
         validBox: BBox, tiles: Set<String> = [], metroID: String? = nil, downloaded: Int = 0,
         extent: BBox? = nil, built: String? = nil) {
        self.id = id; self.name = name; self.bundle = bundle; self.loadMs = loadMs
        self.timeZone = timeZone; self.validBox = validBox; self.tiles = tiles; self.metroID = metroID
        self.downloaded = downloaded; self.extent = extent ?? validBox; self.built = built
    }

    /// Covered, or partial when the box reaches past the place's own bounds.
    func coverage(of box: BBox) -> CoverageState { extent.contains(box) ? .covered : .partial }

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

    /// A session that stays off cellular and low-data connections, for anything not asked for.
    private static let unexpensiveSession: URLSession = {
        let c = URLSessionConfiguration.default
        c.allowsExpensiveNetworkAccess = false
        c.allowsConstrainedNetworkAccess = false
        return URLSession(configuration: c)
    }()

    func download(_ source: URL, to destination: URL, expensive: Bool = true) async throws {
        let key = destination.path
        if let running = fileDownloads[key] { return try await running.value }
        let session = expensive ? URLSession.shared : Self.unexpensiveSession
        let task = Task<Void, Error> { try await CityCatalog.fetch(source, to: destination, session: session) }
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

    /// The city for a set of points (a walk's two ends, or a screen's centre and corners),
    /// chosen by the box they span — the place most of it falls in — not by the first
    /// point, so a screen half outside a city still gets the half that has data. For a
    /// metro this stitches every tile the box needs.
    func city(covering points: [CLLocationCoordinate2D]) async throws -> LoadedCity {
        guard !points.isEmpty else { throw CityCatalogError.noCoverage }
        if let metro, points.allSatisfy({ metro.covers($0) }) { return metro }
        if let hit = singles.values.first(where: { c in points.allSatisfy { c.covers($0) } }) { return hit }
        let box = BBox.around(points.map { ($0.latitude, $0.longitude) }, paddingMeters: 0)

        let m = await CityCatalog.shared.metro(covering: box)
        let single = await CityCatalog.shared.localCity(covering: box)
        // A shipped single city wins where it covers more of the box than the metro does.
        if let m, single.map({ $0.bbox.overlapArea(box) <= m.index.bbox.overlapArea(box) }) ?? true {
            do {
                return try await loadMetro(m, around: points)
            } catch let error as CityCatalogError {
                switch error {
                case .downloadFailed where m.fallback != nil:
                    // A newer build that can't be fetched (offline): keep serving the old one.
                    return try await loadMetro(m.fallback!, around: points)
                case .noCoverage, .walkTooLong:
                    // The metro has no tiles here (or the walk spans too many): a shipped
                    // single city covering the box still can.
                    if let single { return try await load(single) }
                    throw error
                default:
                    throw error
                }
            } catch let error as URLError {
                guard let older = m.fallback else { throw error }
                return try await loadMetro(older, around: points)
            }
        }
        if let single { return try await load(single) }
        guard let remote = try await CityCatalog.shared.remoteCity(covering: box) else {
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
        touch(descriptor.url)
        return try await load(descriptor)
    }

    func covers(_ coordinate: CLLocationCoordinate2D) async -> Bool {
        if metro?.covers(coordinate) == true { return true }
        if singles.values.contains(where: { $0.covers(coordinate) }) { return true }
        if await CityCatalog.shared.localCity(covering: coordinate) != nil { return true }
        return await CityCatalog.shared.localMetros().contains { $0.covers(coordinate) }
    }

    // MARK: - Single-file cities

    func load(_ descriptor: CityDescriptor) async throws -> LoadedCity {
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
                                  timeZone: descriptor.timeZone, validBox: descriptor.bbox,
                                  extent: descriptor.bbox)
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
        // The build is part of the key: tiles of two builds never share a stitch.
        let key = m.id + "@" + m.buildKey + ":" + wanted.map { "\($0.i)_\($0.j)" }.joined(separator: ",")
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
        if await CityCatalog.shared.markReady(metro: m.id, directory: m.localDirectory) { forgetMissingFiles() }
        evictIfNeeded()
        saveLedger()
        prefetchRing(m, around: wanted)
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
                        await self.touch(m.localDirectory.appendingPathComponent(file))
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
                          downloaded: missing.count, extent: m.index.bbox, built: m.index.built)
    }

    /// Parsed tiles are keyed by build as well as file: after a rebuild the same file name
    /// holds a different graph, and a stitch must never mix two builds' node ids.
    private func rawTile(_ m: MetroDescriptor, _ t: MetroIndex.Tile) throws -> RawBundle {
        let key = m.id + "@" + m.buildKey + "/" + t.file
        if let hit = tileCache[key] {
            tileOrder.removeAll { $0 == key }; tileOrder.append(key)
            return hit
        }
        let url = m.localDirectory.appendingPathComponent(t.file)
        let raw = try RawBundle(contentsOf: url)
        touch(url)
        tileCache[key] = raw
        tileOrder.append(key)
        while tileOrder.count > Self.tileCacheLimit { tileCache[tileOrder.removeFirst()] = nil }
        return raw
    }

    /// The metro's coarse far-field terrain; nil when the metro has none or the file is not
    /// on the phone (hills beyond the tiles then cast no shadow — a degraded field, not an error).
    private func farTerrain(_ m: MetroDescriptor) throws -> TerrainGrid? {
        let key = m.id + "@" + m.buildKey
        if let hit = farCache[key] { return hit }
        guard let far = m.index.far else { return nil }
        let url = m.localDirectory.appendingPathComponent(far.file)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let grid = try RawBundle(contentsOf: url).terrain
        touch(url)
        farCache[key] = grid
        return grid
    }

    // MARK: - On-disk cache: ledger, eviction, prefetch (PLAN.md §2 C6)

    /// Downloaded files past this are evicted, least recently used first.
    static var capBytes: Int {
        let mb = UserDefaults.standard.integer(forKey: "uiTestCacheCapMB")
        return (mb > 0 ? mb : 400) * 1_000_000
    }
    private var ledger: [String: CacheEntry]?
    private var ledgerDirty = 0
    /// Tiles fetched ahead of need by the last prefetch ring, for the debug line.
    private(set) var prefetched = 0
    private var prefetchTask: Task<Void, Never>?

    private static var ledgerURL: URL { CityCatalog.downloadsDirectory.appendingPathComponent("ledger.json") }

    private func relative(_ url: URL) -> String {
        let base = CityCatalog.downloadsDirectory.standardizedFileURL.path
        let path = url.standardizedFileURL.path
        return path.hasPrefix(base) ? String(path.dropFirst(base.count + 1)) : path
    }

    /// The ledger, reconciled with what is really under Cities/ every time it is first
    /// read in a session: files on disk it doesn't know (sideloads, an older app version,
    /// a download the app was killed after) are added by their modification time, and
    /// entries whose file is gone (`markReady` deleted an old build) are dropped — so the
    /// cap counts real bytes, never ghosts.
    private func loadLedger() -> [String: CacheEntry] {
        if let ledger { return ledger }
        var known: [String: CacheEntry] = [:]
        if let data = try? Data(contentsOf: Self.ledgerURL),
           let entries = try? JSONDecoder().decode([CacheEntry].self, from: data) {
            for e in entries { known[e.key] = e }
        }
        var out: [String: CacheEntry] = [:]
        if let walker = FileManager.default.enumerator(at: CityCatalog.downloadsDirectory,
                                                       includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey]) {
            for case let url as URL in walker where url.pathExtension == "lwbundle" {
                let key = relative(url)
                let v = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
                let bytes = v?.fileSize ?? 0
                if let e = known[key], e.bytes == bytes {
                    out[key] = e
                } else {
                    out[key] = CacheEntry(key: key, bytes: bytes,
                                          lastUsed: known[key]?.lastUsed ?? v?.contentModificationDate ?? .distantPast)
                }
            }
        }
        ledger = out
        return out
    }

    private func saveLedger() {
        guard let ledger, let data = try? JSONEncoder().encode(Array(ledger.values)) else { return }
        try? data.write(to: Self.ledgerURL, options: .atomic)
        ledgerDirty = 0
    }

    /// Drops ledger entries whose files are gone (after `markReady` removed an old build).
    func forgetMissingFiles() {
        var l = loadLedger()
        for key in l.keys where !FileManager.default.fileExists(atPath: CityCatalog.downloadsDirectory.appendingPathComponent(key).path) {
            l[key] = nil
        }
        ledger = l
        saveLedger()
    }

    /// Records a use of a file under Cities/ (bundled files are ignored).
    func touch(_ url: URL) {
        guard url.standardizedFileURL.path.hasPrefix(CityCatalog.downloadsDirectory.standardizedFileURL.path) else { return }
        var l = loadLedger()
        let key = relative(url)
        var bytes = l[key]?.bytes ?? 0
        if bytes == 0 { bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0 }
        l[key] = CacheEntry(key: key, bytes: bytes, lastUsed: Date())
        ledger = l
        ledgerDirty += 1
    }

    /// Total bytes the ledger knows about (debug, tests).
    var cachedBytes: Int { loadLedger().values.reduce(0) { $0 + $1.bytes } }

    /// Past the cap, delete the least recently used downloads — but only when a server can
    /// give them back: with no server, sideloaded tiles are the only copy.
    private func evictIfNeeded() {
        guard CityCatalog.shared.baseURLIsSet else { return }
        var l = loadLedger()
        var protected = Set<String>()
        if let metro, let id = metro.metroID {
            for t in metro.tiles { protected.formUnion(l.keys.filter { $0.hasPrefix(id + "/") && $0.hasSuffix("t_\(t).lwbundle") }) }
        }
        // Far-field terrain is small (~1 MB) and every stitch of its metro needs it.
        protected.formUnion(l.keys.filter { $0.hasSuffix("far.lwbundle") })
        for single in singles.values { protected.insert(single.id) }
        for path in fileDownloads.keys { protected.insert(relative(URL(fileURLWithPath: path))) }
        let gone = CachePolicy.evictions(Array(l.values), capBytes: Self.capBytes, protected: protected)
        for key in gone {
            try? FileManager.default.removeItem(at: CityCatalog.downloadsDirectory.appendingPathComponent(key))
            l[key] = nil
            for (k, _) in tileCache where k.hasSuffix("/" + (key as NSString).lastPathComponent) { tileCache[k] = nil }
            tileOrder.removeAll { !tileCache.keys.contains($0) }
        }
        ledger = l
        if !gone.isEmpty { saveLedger(); Task { await CityCatalog.shared.invalidate() } }
    }

    /// The ring of tiles just outside a fresh stitch, fetched in the background on Wi-Fi
    /// only, so a short pan or walk doesn't wait on the network.
    private func prefetchRing(_ m: MetroDescriptor, around wanted: [MetroIndex.Tile]) {
        guard let remote = m.remoteDirectory, !wanted.isEmpty,
              UserDefaults.standard.string(forKey: "uiTestNoPrefetch") == nil else { return }
        let i0 = wanted.map(\.i).min()! - 1, i1 = wanted.map(\.i).max()! + 1
        let j0 = wanted.map(\.j).min()! - 1, j1 = wanted.map(\.j).max()! + 1
        let inner = Set(wanted.map { "\($0.i)_\($0.j)" })
        let ring = m.index.tiles.filter { $0.i >= i0 && $0.i <= i1 && $0.j >= j0 && $0.j <= j1 && !inner.contains("\($0.i)_\($0.j)") }
        let fm = FileManager.default
        let missing = ring.filter { !fm.fileExists(atPath: m.localDirectory.appendingPathComponent($0.file).path) }
        guard !missing.isEmpty else { return }
        prefetchTask?.cancel()
        prefetchTask = Task.detached(priority: .background) {
            var got = 0
            for t in missing {
                if Task.isCancelled { break }
                let dest = m.localDirectory.appendingPathComponent(t.file)
                // The same deduped download a stitch uses, on the Wi-Fi-only session: a
                // stitch that wants this tile meanwhile joins it instead of fetching twice.
                if (try? await CityStore.shared.download(remote.appendingPathComponent(t.file), to: dest, expensive: false)) != nil {
                    got += 1
                    await CityStore.shared.touch(dest)
                }
            }
            await CityStore.shared.finishPrefetch(got)
        }
    }

    private func finishPrefetch(_ n: Int) {
        prefetched = n
        saveLedger()
        evictIfNeeded()
    }

    /// One metro tile as a bundle of its own (its graph, buildings and the far terrain), for
    /// scoring a zoomed-out view a file at a time. Not kept: the caller keeps its results.
    /// `bundle` is nil when the tile isn't on the phone and `download` is false (or the
    /// fetch, Wi-Fi only, failed); `downloaded` says whether this call fetched it.
    func tileBundle(_ m: MetroDescriptor, _ t: MetroIndex.Tile, download allowDownload: Bool) async throws -> (bundle: CityBundle?, downloaded: Bool) {
        let url = m.localDirectory.appendingPathComponent(t.file)
        var fetched = false
        if !FileManager.default.fileExists(atPath: url.path) {
            guard allowDownload, let remote = m.remoteDirectory else { return (nil, false) }
            try? FileManager.default.createDirectory(at: m.localDirectory, withIntermediateDirectories: true)
            do {
                try await download(remote.appendingPathComponent(t.file), to: url, expensive: false)
                fetched = true
            } catch {
                return (nil, false)
            }
        }
        if let far = m.index.far, let remote = m.remoteDirectory, allowDownload {
            let farURL = m.localDirectory.appendingPathComponent(far.file)
            if !FileManager.default.fileExists(atPath: farURL.path) {
                try? await download(remote.appendingPathComponent(far.file), to: farURL, expensive: false)
            }
        }
        let raw: RawBundle
        if let hit = tileCache[m.id + "@" + m.buildKey + "/" + t.file] { raw = hit } else { raw = try RawBundle(contentsOf: url) }
        touch(url)
        if fetched { saveLedger() }
        let far = try farTerrain(m)
        return (try TileStitcher.stitch([raw], farTerrain: far), fetched)
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
