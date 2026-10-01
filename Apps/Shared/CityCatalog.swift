import Foundation
import CoreLocation
import LikeWaterEngine

/// A single-file city bundle the app can use: shipped inside the app, or downloaded earlier.
struct CityDescriptor: Identifiable, Sendable, Equatable {
    var name: String
    var url: URL
    var bbox: BBox
    var bytes: Int
    var isBundled: Bool
    var timeZone: TimeZone?
    var id: String { url.lastPathComponent }

    func covers(_ c: CLLocationCoordinate2D) -> Bool {
        bbox.contains(lat: c.latitude, lon: c.longitude)
    }
}

/// What `manifest.json` next to the bundles on a server says is available.
struct RemoteManifest: Codable, Sendable {
    struct City: Codable, Sendable {
        var name: String
        var file: String
        var minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
        var bytes: Int
        var timezone: String?
        var bbox: BBox { BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }
    }
    /// A tiled metro: the entry points at its own index, which lists the tiles.
    struct Metro: Codable, Sendable {
        var id: String
        var name: String
        var index: String
        var timezone: String?
        var minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
        var bytes: Int
        var tiles: Int?
        /// The build this entry points at (`MetroIndex.built`).
        var built: String?
        var bbox: BBox { BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }
        var buildKey: String { MetroIndex.buildKey(built) }
    }
    var cities: [City]
    var metros: [Metro]?
}

extension MetroIndex {
    func tile(containing c: CLLocationCoordinate2D) -> Tile? { tile(containingLat: c.latitude, lon: c.longitude) }
}

/// How much of a box (a screen, or a walk's two ends) has sun data.
enum CoverageState: Equatable, Sendable {
    case covered
    /// Part of the box is outside the place's bounds.
    case partial
    /// Nothing built here; the nearest built place, if any is known.
    case notBuilt(nearest: String?, km: Double?)
    /// Nothing on the phone covers it and no bundle server is configured to ask.
    case noServer

    var hasData: Bool { self == .covered || self == .partial }
}

/// A metro the app knows about: its index plus where its files live.
struct MetroDescriptor: Sendable {
    var index: MetroIndex
    /// Directory holding the tiles locally (downloads land here too).
    var localDirectory: URL
    /// Server directory for the tiles, when a bundle server is configured.
    var remoteDirectory: URL?
    /// An older build of the same metro that is complete on the phone: what keeps serving
    /// if this (newer) build can't be fetched.
    var fallbackDirectory: URL?
    var fallbackIndex: MetroIndex?
    var id: String { index.id }
    var name: String { index.name }
    var buildKey: String { index.buildKey }
    var timeZone: TimeZone? { index.timezone.flatMap(TimeZone.init(identifier:)) }
    func covers(_ c: CLLocationCoordinate2D) -> Bool { index.tile(containing: c) != nil }
    /// nil when the box misses the metro entirely.
    func coverage(of box: BBox) -> CoverageState? {
        guard index.intersects(box) else { return nil }
        return index.extendsBeyond(box) ? .partial : .covered
    }
    var fallback: MetroDescriptor? {
        guard let dir = fallbackDirectory, let idx = fallbackIndex else { return nil }
        return MetroDescriptor(index: idx, localDirectory: dir, remoteDirectory: nil)
    }
}

extension CityDescriptor {
    func coverage(of box: BBox) -> CoverageState? {
        guard bbox.intersects(box) else { return nil }
        return bbox.contains(box) ? .covered : .partial
    }
}

/// "Request this area": counts a 0.1° cell on the owner's coverage endpoint. Sends nothing
/// unless `LWCoverageRequestURL` (or `-coverageRequestURL`) is configured.
enum CoverageRequest {
    static var url: URL? {
        if let raw = UserDefaults.standard.string(forKey: "coverageRequestURL"), let u = URL(string: raw) { return u }
        guard let raw = Bundle.main.object(forInfoDictionaryKey: "LWCoverageRequestURL") as? String,
              !raw.isEmpty, let u = URL(string: raw) else { return nil }
        return u
    }

    static func cell(_ c: CLLocationCoordinate2D) -> String {
        String(format: "%.1f,%.1f", (c.latitude * 10).rounded() / 10, (c.longitude * 10).rounded() / 10)
    }

    /// Returns true when the endpoint accepted it.
    static func send(_ c: CLLocationCoordinate2D) async -> Bool {
        // Kept locally too: the input for Pipeline/requests_to_places.py before a Worker exists.
        var asked = UserDefaults.standard.stringArray(forKey: "requestedCells") ?? []
        asked.append(cell(c)); UserDefaults.standard.set(asked, forKey: "requestedCells")
        guard let url else { return false }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try? JSONSerialization.data(withJSONObject: ["cell": cell(c)])
        request.timeoutInterval = 10
        guard let (_, response) = try? await URLSession.shared.data(for: request) else { return false }
        return (response as? HTTPURLResponse).map { (200..<300).contains($0.statusCode) } ?? false
    }
}

enum CityCatalogError: Error, LocalizedError {
    case noCoverage
    case noServer
    case badManifest
    case downloadFailed(String)
    case walkTooLong

    var errorDescription: String? {
        switch self {
        case .noCoverage: return "No map data for this area yet."
        case .noServer: return "No bundle server configured, and this area is not on the phone."
        case .badManifest: return "The bundle server's manifest could not be read."
        case .downloadFailed(let m): return "Download failed: \(m)"
        case .walkTooLong: return "That destination is too far to walk from here."
        }
    }
}

/// Finds what covers a location — a single city bundle (shipped or downloaded), or a
/// tiled metro (downloaded, sideloaded, or on the bundle server). The file format is
/// the same in every case, so "on demand" is nothing more than the pipeline's output
/// served over HTTP.
actor CityCatalog {
    static let shared = CityCatalog()

    /// Configured by `-bundleBaseURL` (tests, dev) or the `LWBundleBaseURL` Info.plist key.
    let baseURL: URL?
    /// Bundled cities to pretend are absent, so the download path can be tested.
    private let ignoredBundled: Set<String>

    private var localCache: [CityDescriptor]?
    private var metroCache: [MetroDescriptor]?
    private var manifestCache: (manifest: RemoteManifest, at: Date)?
    private var remoteMetroCache: [String: MetroDescriptor] = [:]
    static let manifestTTL: TimeInterval = 600

    init() {
        let defaults = UserDefaults.standard
        if let raw = defaults.string(forKey: "bundleBaseURL"), let u = URL(string: raw) {
            baseURL = u
        } else if let raw = Bundle.main.object(forInfoDictionaryKey: "LWBundleBaseURL") as? String,
                  !raw.isEmpty, let u = URL(string: raw) {
            baseURL = u
        } else {
            baseURL = nil
        }
        // UI tests: start with nothing downloaded, so the download path really runs.
        if defaults.string(forKey: "uiTestFreshDownloads") != nil {
            try? FileManager.default.removeItem(at: Self.downloadsDirectory)
        }
        ignoredBundled = Set((defaults.string(forKey: "uiTestIgnoreBundled") ?? "")
            .split(separator: ",").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty })
    }

    static var downloadsDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Cities", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        var values = URLResourceValues(); values.isExcludedFromBackup = true
        var url = base; try? url.setResourceValues(values)
        return base
    }

    /// Display names and time zones for shipped bundles come from the manifest the
    /// pipeline writes next to them.
    private lazy var shipped: [String: RemoteManifest.City] = {
        guard let url = Bundle.main.url(forResource: "manifest", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let manifest = try? JSONDecoder().decode(RemoteManifest.self, from: data) else { return [:] }
        return Dictionary(uniqueKeysWithValues: manifest.cities.map { ($0.file, $0) })
    }()

    nonisolated var baseURLIsSet: Bool { baseURL != nil }

    /// Forget cached listings (after a download).
    func invalidate() { localCache = nil; metroCache = nil }

    /// Every single-file city on this device, reading only the 64-byte header of each.
    func local() -> [CityDescriptor] {
        if let localCache { return localCache }
        var out: [CityDescriptor] = []
        let bundled = Bundle.main.urls(forResourcesWithExtension: "lwbundle", subdirectory: nil) ?? []
        let downloaded = (try? FileManager.default.contentsOfDirectory(
            at: Self.downloadsDirectory, includingPropertiesForKeys: [.fileSizeKey]))?
            .filter { $0.pathExtension == "lwbundle" } ?? []
        for (urls, isBundled) in [(bundled, true), (downloaded, false)] {
            for url in urls {
                let stem = url.deletingPathExtension().lastPathComponent
                if isBundled && ignoredBundled.contains(stem) { continue }
                guard let header = try? BundleHeader.read(from: url), header.version < 3 else { continue }
                let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                let entry = shipped[url.lastPathComponent]
                out.append(CityDescriptor(name: entry?.name ?? stem.capitalized, url: url, bbox: header.bbox,
                                          bytes: bytes, isBundled: isBundled,
                                          timeZone: entry?.timezone.flatMap(TimeZone.init(identifier:))))
            }
        }
        localCache = out
        return out
    }

    /// The single city most of a box falls in (prefer downloaded, then most overlap).
    func localCity(covering box: BBox) -> CityDescriptor? {
        local().filter { $0.bbox.intersects(box) }.sorted {
            if $0.isBundled != $1.isBundled { return !$0.isBundled }
            let a = $0.bbox.overlapArea(box), b = $1.bbox.overlapArea(box)
            return a != b ? a > b : area($0.bbox) < area($1.bbox)
        }.first
    }

    func localCity(covering c: CLLocationCoordinate2D) -> CityDescriptor? {
        // Prefer a downloaded (fresher) copy over a shipped one; then the smallest box,
        // which is the most specific city when two boxes overlap.
        local().filter { $0.covers(c) }.sorted {
            if $0.isBundled != $1.isBundled { return !$0.isBundled }
            return area($0.bbox) < area($1.bbox)
        }.first
    }

    private func area(_ b: BBox) -> Double { (b.maxLat - b.minLat) * (b.maxLon - b.minLon) }

    /// Metros on this device, newest usable build per id. Layouts:
    ///   Cities/<id>/metro.json              sideloaded by install_phone.sh (always complete)
    ///   Cities/<id>/<buildKey>/metro.json   fetched from the server; `.ready` once a stitch
    ///                                       from it succeeded
    /// A build without `.ready` is only used when no ready build exists.
    func localMetros() -> [MetroDescriptor] {
        if let metroCache { return metroCache }
        struct Found { var index: MetroIndex; var dir: URL; var ready: Bool }
        var found: [String: [Found]] = [:]
        let fm = FileManager.default
        func consider(_ dir: URL, ready: Bool) {
            guard let index = try? MetroIndex.load(from: dir.appendingPathComponent("metro.json")) else { return }
            found[index.id, default: []].append(Found(index: index, dir: dir, ready: ready))
        }
        for idDir in (try? fm.contentsOfDirectory(at: Self.downloadsDirectory, includingPropertiesForKeys: nil)) ?? [] {
            consider(idDir, ready: true)
            for build in (try? fm.contentsOfDirectory(at: idDir, includingPropertiesForKeys: nil)) ?? [] {
                consider(build, ready: fm.fileExists(atPath: build.appendingPathComponent(".ready").path))
            }
        }
        if let resources = Bundle.main.resourceURL {
            for dir in (try? fm.contentsOfDirectory(at: resources, includingPropertiesForKeys: nil)) ?? [] {
                guard let index = try? MetroIndex.load(from: dir.appendingPathComponent("metro.json")) else { continue }
                let local = Self.downloadsDirectory.appendingPathComponent(index.id).appendingPathComponent(index.buildKey)
                found[index.id, default: []].append(Found(index: index, dir: local, ready: true))
            }
        }
        var out: [MetroDescriptor] = []
        for (_, builds) in found {
            let sorted = builds.sorted { $0.index.isNewer(than: $1.index) }
            guard let pick = sorted.first(where: \.ready) ?? sorted.first else { continue }
            out.append(MetroDescriptor(index: pick.index, localDirectory: pick.dir,
                                       remoteDirectory: baseURL?.appendingPathComponent(pick.index.id, isDirectory: true)))
        }
        metroCache = out.sorted { $0.id < $1.id }
        return metroCache!
    }

    /// After a stitch from `buildKey` succeeded: mark it ready and delete every other build
    /// of the metro (sibling build directories and a flat sideloaded copy), never the one
    /// in use.
    func markReady(metro id: String, directory: URL) {
        let fm = FileManager.default
        let idDir = Self.downloadsDirectory.appendingPathComponent(id, isDirectory: true)
        guard directory.standardizedFileURL.deletingLastPathComponent() == idDir.standardizedFileURL else { return }
        let marker = directory.appendingPathComponent(".ready")
        guard !fm.fileExists(atPath: marker.path) else { return }
        fm.createFile(atPath: marker.path, contents: Data())
        for item in (try? fm.contentsOfDirectory(at: idDir, includingPropertiesForKeys: [.isDirectoryKey])) ?? [] {
            if item.standardizedFileURL == directory.standardizedFileURL { continue }
            let isDir = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
            if isDir || item.pathExtension == "lwbundle" || item.lastPathComponent == "metro.json" {
                try? fm.removeItem(at: item)
            }
        }
        metroCache = nil
    }

    func manifest() async throws -> RemoteManifest {
        guard let baseURL else { throw CityCatalogError.noServer }
        if let cached = manifestCache, Date().timeIntervalSince(cached.at) < Self.manifestTTL {
            return cached.manifest
        }
        var request = URLRequest(url: baseURL.appendingPathComponent("manifest.json"))
        request.timeoutInterval = 10
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw CityCatalogError.badManifest
        }
        let manifest = try JSONDecoder().decode(RemoteManifest.self, from: data)
        manifestCache = (manifest, Date())
        return manifest
    }

    func remoteCity(covering c: CLLocationCoordinate2D) async throws -> RemoteManifest.City? {
        try await manifest().cities.first { $0.bbox.contains(lat: c.latitude, lon: c.longitude) }
    }

    /// Any metro covering a point: on the device first, then the server's.
    func metro(covering c: CLLocationCoordinate2D) async -> MetroDescriptor? {
        guard let m = await metro(covering: BBox(minLat: c.latitude, minLon: c.longitude,
                                                 maxLat: c.latitude, maxLon: c.longitude)),
              m.covers(c) else { return nil }
        return m
    }

    /// The metro most of a box falls in. The phone's copy wins unless the server lists a
    /// newer build, which is then fetched into its own directory with the phone's copy
    /// kept as the fallback.
    func metro(covering box: BBox) async -> MetroDescriptor? {
        let locals = localMetros().filter { $0.index.intersects(box) }
            .sorted { $0.index.bbox.overlapArea(box) > $1.index.bbox.overlapArea(box) }
        guard let baseURL, let manifest = try? await manifest() else { return locals.first }
        let entries = (manifest.metros ?? []).filter { $0.bbox.intersects(box) }
            .sorted { $0.bbox.overlapArea(box) > $1.bbox.overlapArea(box) }
        guard let entry = entries.first else { return locals.first }
        // Tiles live next to the index the manifest names: `<id>/` on Pages,
        // `metros/<id>/<buildKey>/` on an S3 layout.
        let remoteFolder = baseURL.appendingPathComponent((entry.index as NSString).deletingLastPathComponent, isDirectory: true)
        if var local = locals.first(where: { $0.id == entry.id }),
           !MetroIndex.isNewer(entry.buildKey, than: local.buildKey) {
            if local.buildKey == entry.buildKey { local.remoteDirectory = remoteFolder }
            return local
        }
        if let local = locals.first, local.id != entry.id,
           local.index.bbox.overlapArea(box) >= entry.bbox.overlapArea(box) {
            return local
        }
        let cacheKey = entry.id + "@" + entry.buildKey
        if let cached = remoteMetroCache[cacheKey] { return cached }
        guard let (data, response) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent(entry.index)),
              (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true,
              let index = try? JSONDecoder().decode(MetroIndex.self, from: data) else { return locals.first }
        let dir = Self.downloadsDirectory.appendingPathComponent(index.id, isDirectory: true)
            .appendingPathComponent(index.buildKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? data.write(to: dir.appendingPathComponent("metro.json"))
        let older = locals.first { $0.id == index.id && $0.localDirectory.standardizedFileURL != dir.standardizedFileURL }
        let metro = MetroDescriptor(index: index, localDirectory: dir, remoteDirectory: remoteFolder,
                                    fallbackDirectory: older?.localDirectory, fallbackIndex: older?.index)
        remoteMetroCache[cacheKey] = metro
        metroCache = nil
        return metro
    }

    func remoteCity(covering box: BBox) async throws -> RemoteManifest.City? {
        try await manifest().cities.filter { $0.bbox.intersects(box) }
            .max { $0.bbox.overlapArea(box) < $1.bbox.overlapArea(box) }
    }

    /// Why a box has no data, and the nearest place that has some.
    func coverageState(for box: BBox) async -> CoverageState {
        var places: [(String, BBox)] = local().map { ($0.name, $0.bbox) } + localMetros().map { ($0.name, $0.index.bbox) }
        let manifest = try? await manifest()
        places += (manifest?.metros ?? []).map { ($0.name, $0.bbox) } + (manifest?.cities ?? []).map { ($0.name, $0.bbox) }
        if places.contains(where: { $0.1.intersects(box) }) {
            return places.contains(where: { $0.1.contains(box) }) ? .covered : .partial
        }
        if baseURL == nil && places.isEmpty { return .noServer }
        let c = (box.centerLat, box.centerLon)
        func distance(_ b: BBox) -> Double {
            let lat = min(max(c.0, b.minLat), b.maxLat), lon = min(max(c.1, b.minLon), b.maxLon)
            return haversineMeters(c.0, c.1, lat, lon)
        }
        let nearest = places.min { distance($0.1) < distance($1.1) }
        let state = CoverageState.notBuilt(nearest: nearest?.0, km: nearest.map { distance($0.1) / 1000 })
        return baseURL == nil && manifest == nil ? (nearest == nil ? .noServer : state) : state
    }

    /// Does anything, here or on the server, cover this point? Cheap after the first call.
    func anyCoverage(_ c: CLLocationCoordinate2D) async -> Bool {
        if localCity(covering: c) != nil { return true }
        if await metro(covering: c) != nil { return true }
        return (try? await remoteCity(covering: c)) != nil
    }

    /// Downloads one city into Application Support and returns its descriptor.
    func download(_ city: RemoteManifest.City,
                  progress: @escaping @Sendable (Double) -> Void) async throws -> CityDescriptor {
        guard let baseURL else { throw CityCatalogError.noServer }
        let destination = Self.downloadsDirectory.appendingPathComponent(city.file)
        try await Self.fetch(baseURL.appendingPathComponent(city.file), to: destination, progress: progress)
        invalidate()
        let header = try BundleHeader.read(from: destination)
        return CityDescriptor(name: city.name, url: destination, bbox: header.bbox,
                              bytes: city.bytes, isBundled: false,
                              timeZone: city.timezone.flatMap(TimeZone.init(identifier:)))
    }

    static func fetch(_ source: URL, to destination: URL,
                      progress: (@Sendable (Double) -> Void)? = nil) async throws {
        let (temp, response) = try await URLSession.shared.download(from: source,
                                                                    delegate: progress.map(ProgressRelay.init))
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? true else {
            throw CityCatalogError.downloadFailed("HTTP \((response as? HTTPURLResponse)?.statusCode ?? 0) for \(source.lastPathComponent)")
        }
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: temp, to: destination)
        } catch where FileManager.default.fileExists(atPath: destination.path) {
            // Someone else finished the same file first; theirs is as good as ours.
            try? FileManager.default.removeItem(at: temp)
        }
    }
}

/// Forwards URLSession download progress to a closure.
final class ProgressRelay: NSObject, URLSessionTaskDelegate, URLSessionDownloadDelegate {
    let progress: @Sendable (Double) -> Void
    init(_ progress: @escaping @Sendable (Double) -> Void) { self.progress = progress }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {}
}
