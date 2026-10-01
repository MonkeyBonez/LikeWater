import XCTest
@testable import LikeWaterEngine

private struct Vector: Decodable {
    let site: String, lat: Double, lon: Double, utc: String
    let elevation: Double, azimuth: Double
}

final class SolarTests: XCTestCase {

    private func vectors() throws -> [Vector] {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "solar_vectors",
                                                  withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try JSONDecoder().decode([Vector].self, from: Data(contentsOf: url))
    }

    private static let formatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// The PRD asks for agreement with NOAA to within 0.5 degrees. The oracle here is
    /// pvlib's NREL SPA implementation, which is accurate to ~0.0003 degrees, so this
    /// is a stricter check than comparing against NOAA's own published table.
    func testMatchesNRELSolarPositionAlgorithm() throws {
        var worstElevation = 0.0
        var worstAzimuth = 0.0
        for v in try vectors() {
            let date = try XCTUnwrap(Self.formatter.date(from: v.utc))
            let p = Solar.position(latitude: v.lat, longitude: v.lon, date: date)

            let dElevation = abs(p.elevation - v.elevation)
            worstElevation = max(worstElevation, dElevation)
            XCTAssertLessThan(dElevation, 0.5,
                              "elevation off at \(v.site) \(v.utc): got \(p.elevation), want \(v.elevation)")

            // Azimuth is meaningless when the sun is near the zenith or well below
            // the horizon; compare it only where it can be read off a map.
            if v.elevation > 3 && v.elevation < 87 {
                var dAzimuth = abs(p.azimuth - v.azimuth).truncatingRemainder(dividingBy: 360)
                if dAzimuth > 180 { dAzimuth = 360 - dAzimuth }
                worstAzimuth = max(worstAzimuth, dAzimuth)
                XCTAssertLessThan(dAzimuth, 0.5,
                                  "azimuth off at \(v.site) \(v.utc): got \(p.azimuth), want \(v.azimuth)")
            }
        }
        print("worst elevation error \(worstElevation)°, worst azimuth error \(worstAzimuth)°")
    }

    /// At an equinox the sun's peak elevation equals 90 - |latitude| to within a
    /// fraction of a degree, anywhere on earth. Scan the day rather than assuming
    /// when solar noon falls.
    func testPeakElevationAtEquinoxMatchesLatitude() throws {
        let midnight = try XCTUnwrap(Self.formatter.date(from: "2026-03-20T00:00:00Z"))
        for (lat, lon) in [(37.7749, -122.4194), (51.5072, -0.1276), (-33.8688, 151.2093)] {
            var best = SolarPosition(elevation: -90, azimuth: 0, declination: 0, equationOfTime: 0)
            for minute in stride(from: 0, to: 1440, by: 1) {
                let p = Solar.position(latitude: lat, longitude: lon,
                                       date: midnight.addingTimeInterval(Double(minute) * 60))
                if p.elevation > best.elevation { best = p }
            }
            XCTAssertEqual(best.elevation, 90 - abs(lat), accuracy: 0.7,
                           "peak elevation at latitude \(lat)")
            // Peak sun is due south in the north, due north in the south.
            let expected: Double = lat >= 0 ? 180 : 0
            var delta = abs(best.azimuth - expected).truncatingRemainder(dividingBy: 360)
            if delta > 180 { delta = 360 - delta }
            XCTAssertLessThan(delta, 1.5, "peak azimuth at latitude \(lat)")
        }
    }

    func testSunIsDownAtNightAndUpAtNoon() {
        let night = Self.formatter.date(from: "2026-12-21T09:00:00Z")!   // 1 am in SF
        let noon = Self.formatter.date(from: "2026-12-21T20:10:00Z")!    // about solar noon
        XCTAssertFalse(Solar.position(latitude: 37.7749, longitude: -122.4194, date: night).isUp)
        XCTAssertTrue(Solar.position(latitude: 37.7749, longitude: -122.4194, date: noon).isUp)
    }

    /// The raw UTC-day window can sit entirely on the wrong side of an evening instant
    /// in San Francisco; the bracketing helper has to fix that.
    func testDaylightWindowBracketsTheInstantOrLooksForward() throws {
        let lat = 37.7749, lon = -122.4194
        for stamp in ["2026-09-23T17:30:00Z",     // 10:30 am PDT, daytime
                      "2026-09-24T02:00:00Z",     // 7:00 pm PDT, just before sunset
                      "2026-09-24T04:42:00Z"] {   // 9:42 pm PDT, after sunset
            let instant = try XCTUnwrap(Self.formatter.date(from: stamp))
            let window = try XCTUnwrap(Solar.daylightWindow(latitude: lat, longitude: lon,
                                                            containing: instant))
            XCTAssertLessThan(window.sunrise, window.sunset)
            let brackets = instant >= window.sunrise && instant <= window.sunset
            let isNext = window.sunrise > instant
            XCTAssertTrue(brackets || isNext,
                          "window \(window) neither brackets nor follows \(stamp)")
            if Solar.position(latitude: lat, longitude: lon, date: instant).isUp {
                XCTAssertTrue(brackets, "daytime instant \(stamp) must be inside its own window")
            }
            // The window is a real day's worth of light, not a degenerate sliver.
            let hours = window.sunset.timeIntervalSince(window.sunrise) / 3600
            XCTAssertEqual(hours, 12.0, accuracy: 0.6)
        }
    }

    func testSunriseAndSunsetBracketTheDaylightHours() throws {
        let noon = Self.formatter.date(from: "2026-09-23T19:00:00Z")!
        let pair = try XCTUnwrap(Solar.sunriseSunset(latitude: 37.7749, longitude: -122.4194, on: noon))
        XCTAssertLessThan(pair.sunrise, pair.sunset)

        // Elevation crosses zero at both ends.
        for (instant, sign) in [(pair.sunrise, 1.0), (pair.sunset, -1.0)] {
            let before = Solar.position(latitude: 37.7749, longitude: -122.4194,
                                        date: instant.addingTimeInterval(-600 * sign))
            let after = Solar.position(latitude: 37.7749, longitude: -122.4194,
                                       date: instant.addingTimeInterval(600 * sign))
            XCTAssertLessThan(before.elevation, 0.9)
            XCTAssertGreaterThan(after.elevation, -0.9)
        }
        // Late September in SF: roughly a 12 hour day.
        let hours = pair.sunset.timeIntervalSince(pair.sunrise) / 3600
        XCTAssertEqual(hours, 12.1, accuracy: 0.4)
    }
}
