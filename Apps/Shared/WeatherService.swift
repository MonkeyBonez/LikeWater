import Foundation
import CoreLocation
import LikeWaterEngine

/// Live sky for the area around a point: the nine ~2.5 km model cells around it from
/// Open-Meteo (HRRR under the hood in the US), cached for half an hour per cell.
///
/// This is the one thing the apps fetch at runtime, because it is the one thing that
/// cannot be built ahead of time. Offline or refused, it returns nil and the map falls
/// back to pure geometry — the state the app was in before weather existed.
actor WeatherService {
    static let shared = WeatherService()

    /// The override and test hooks. `-uiTestSky <preset>` freezes the sky; presets:
    /// clear, partly, overcast, fog, fog-west (west cells fogged, east cells clear).
    enum Preset: String, CaseIterable {
        case clear, partly, overcast, fog
        case fogWest = "fog-west"
    }

    private struct CacheEntry {
        var field: SkyField
        var fetchedAt: Date
        var key: String
    }

    private var cache: [String: CacheEntry] = [:]
    private var inFlight: [String: Task<SkyField, Error>] = [:]
    static let cacheTTL: TimeInterval = 30 * 60

    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        return URLSession(configuration: config)
    }()

    /// Sky field around a point, or nil when unavailable. Never throws: weather is a
    /// garnish on the geometry, not a prerequisite.
    func sky(around center: CLLocationCoordinate2D, for date: Date) async -> SkyField? {
        if let preset = Self.launchPreset() {
            return Self.field(for: preset, around: center, at: date)
        }
        let points = OpenMeteoSky.latticePoints(around: center.latitude, longitude: center.longitude)
        let key = points.map { "\($0.latitude),\($0.longitude)" }.joined(separator: ";")
        if let hit = cache[key], Date().timeIntervalSince(hit.fetchedAt) < Self.cacheTTL {
            return hit.field
        }
        if let task = inFlight[key] {
            return try? await task.value
        }
        let task = Task<SkyField, Error> { [session] in
            let url = OpenMeteoSky.requestURL(points: points)
            var request = URLRequest(url: url)
            request.setValue("LikeWater/0.1 iOS", forHTTPHeaderField: "User-Agent")
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                throw URLError(.badServerResponse)
            }
            return try OpenMeteoSky.decode(data)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }
        do {
            let field = try await task.value
            cache[key] = CacheEntry(field: field, fetchedAt: Date(), key: key)
            return field
        } catch {
            // Keep a stale entry rather than nothing.
            return cache[key]?.field
        }
    }

    // MARK: - Presets (override picker and UI tests)

    nonisolated static func launchPreset() -> Preset? {
        guard let raw = UserDefaults.standard.string(forKey: "uiTestSky") else { return nil }
        return Preset(rawValue: raw)
    }

    /// A preset field covering a day either side of `date`, so a scrubbed or pinned
    /// time is inside it (a range around "now" left the UI tests' fixed dates outside).
    nonisolated static func field(for preset: Preset, around center: CLLocationCoordinate2D,
                                  at date: Date) -> SkyField {
        let from = date.addingTimeInterval(-86_400)
        let to = date.addingTimeInterval(86_400)
        switch preset {
        case .clear:
            return .uniform(.clear, latitude: center.latitude, longitude: center.longitude, from: from, to: to)
        case .partly:
            return .uniform(.partly, latitude: center.latitude, longitude: center.longitude, from: from, to: to)
        case .overcast:
            return .uniform(.overcast, latitude: center.latitude, longitude: center.longitude, from: from, to: to)
        case .fog:
            return .uniform(.fog, latitude: center.latitude, longitude: center.longitude, from: from, to: to)
        case .fogWest:
            // Two weathers: the San Francisco pattern, fog west of ~Twin Peaks, sun east.
            let west = SkyField.uniform(.fog, latitude: center.latitude, longitude: -122.49, from: from, to: to)
            let east = SkyField.uniform(.clear, latitude: center.latitude, longitude: -122.41, from: from, to: to)
            return SkyField(samples: west.samples + east.samples)
        }
    }
}
