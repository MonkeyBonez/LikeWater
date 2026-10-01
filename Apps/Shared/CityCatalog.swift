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
        var bbox: BBox { BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }
    }
    var cities: [City]
    var metros: [Metro]?
}

/// `<metro>/metro.json`, written by `Pipeline/build_metro.py`.
struct MetroIndex: Codable, Sendable {
    struct Tile: Codable, Sendable, Hashable {
        var i: Int
        var j: Int
        var file: String
        var bytes: Int
        var nodes: Int?
        var edges: Int?
        var buildings: Int?
    }
    struct FileRef: Codable, Sendable {
        var file: String
        var bytes: Int
    }
    var id: String
    var name: String
    var timezone: String?
    var tileLat: Double
    var tileLon: Double
    var minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    var demo: [Double]?
    var far: FileRef?
    var bytes: Int
    var tiles: [Tile]

    var bbox: BBox { BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }

    func tileBox(_ t: Tile) -> BBox {
        BBox(minLat: Double(t.i) * tileLat, minLon: Double(t.j) * tileLon,
             maxLat: Double(t.i + 1) * tileLat, maxLon: Double(t.j + 1) * tileLon)
    }

    /// The tile holding a point, if the metro has one there (tiles exist only where
    /// the city has streets, so this is also the coverage test).
    func tile(containing c: CLLocationCoordinate2D) -> Tile? {
        let i = Int((c.latitude / tileLat).rounded(.down)), j = Int((c.longitude / tileLon).rounded(.down))
        return tiles.first { $0.i == i && $0.j == j }
    }

    /// Every tile intersecting a box.
    func tiles(intersecting box: BBox) -> [Tile] {
        let i0 = Int((box.minLat / tileLat).rounded(.down)), i1 = Int((box.maxLat / tileLat).rounded(.down))
        let j0 = Int((box.minLon / tileLon).rounded(.down)), j1 = Int((box.maxLon / tileLon).rounded(.down))
        return tiles.filter { $0.i >= i0 && $0.i <= i1 && $0.j >= j0 && $0.j <= j1 }
    }
}

/// A metro the app knows about: its index plus where its files live.
struct MetroDescriptor: Sendable {
    var index: MetroIndex
    /// Directory holding the tiles locally (downloads land here too).
    var localDirectory: URL
    /// Server directory for the tiles, when a bundle server is configured.
    var remoteDirectory: URL?
    var id: String { index.id }
    var name: String { index.name }
    var timeZone: TimeZone? { index.timezone.flatMap(TimeZone.init(identifier:)) }
    func covers(_ c: CLLocationCoordinate2D) -> Bool { index.tile(containing: c) != nil }
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
                  let u = URL(string: raw) {
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

    func localCity(covering c: CLLocationCoordinate2D) -> CityDescriptor? {
        // Prefer a downloaded (fresher) copy over a shipped one; then the smallest box,
        // which is the most specific city when two boxes overlap.
        local().filter { $0.covers(c) }.sorted {
            if $0.isBundled != $1.isBundled { return !$0.isBundled }
            return area($0.bbox) < area($1.bbox)
        }.first
    }

    private func area(_ b: BBox) -> Double { (b.maxLat - b.minLat) * (b.maxLon - b.minLon) }

    /// Metros on this device: `<id>/metro.json` under Application Support/Cities
    /// (downloaded or sideloaded) or inside the app bundle.
    func localMetros() -> [MetroDescriptor] {
        if let metroCache { return metroCache }
        var out: [MetroDescriptor] = []
        var roots = [Self.downloadsDirectory]
        if let resources = Bundle.main.resourceURL { roots.append(resources) }
        for root in roots {
            let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
            for dir in dirs {
                let indexURL = dir.appendingPathComponent("metro.json")
                guard let data = try? Data(contentsOf: indexURL),
                      let index = try? JSONDecoder().decode(MetroIndex.self, from: data),
                      !out.contains(where: { $0.id == index.id }) else { continue }
                let local = Self.downloadsDirectory.appendingPathComponent(index.id, isDirectory: true)
                out.append(MetroDescriptor(index: index, localDirectory: root == Self.downloadsDirectory ? dir : local,
                                           remoteDirectory: baseURL?.appendingPathComponent(index.id, isDirectory: true)))
            }
        }
        metroCache = out
        return out
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
        if let hit = localMetros().first(where: { $0.covers(c) }) { return hit }
        guard let baseURL, let manifest = try? await manifest() else { return nil }
        for entry in manifest.metros ?? [] where entry.bbox.contains(lat: c.latitude, lon: c.longitude) {
            let metro: MetroDescriptor
            if let cached = remoteMetroCache[entry.id] {
                metro = cached
            } else {
                guard let (data, _) = try? await URLSession.shared.data(from: baseURL.appendingPathComponent(entry.index)),
                      let index = try? JSONDecoder().decode(MetroIndex.self, from: data) else { continue }
                let local = Self.downloadsDirectory.appendingPathComponent(index.id, isDirectory: true)
                try? FileManager.default.createDirectory(at: local, withIntermediateDirectories: true)
                try? data.write(to: local.appendingPathComponent("metro.json"))
                metro = MetroDescriptor(index: index, localDirectory: local,
                                        remoteDirectory: baseURL.appendingPathComponent(index.id, isDirectory: true))
                remoteMetroCache[entry.id] = metro
                metroCache = nil
            }
            if metro.covers(c) { return metro }
        }
        return nil
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
