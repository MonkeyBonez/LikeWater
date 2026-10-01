import XCTest
@testable import LikeWaterEngine

/// The sky model: clear-sky reference, the fog-day fixture, spatial and time interpolation.
final class SkyTests: XCTestCase {

    private func fixture() throws -> SkyField {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "sky_sf_fog_2026-09-15", withExtension: "json",
                                                  subdirectory: "Fixtures"))
        return try OpenMeteoSky.decode(try Data(contentsOf: url))
    }

    private let oceanBeach = (lat: 37.7599, lon: -122.5094)
    private let mission = (lat: 37.7599, lon: -122.4148)
    /// 2026-09-15 14:00 PDT = 21:00 UTC.
    private let fogAfternoon = Date(timeIntervalSince1970: 1_789_506_000)

    /// Meinel's clear-sky beam should track the model's own clear afternoons: the
    /// 2026-09-29 forecast had 885–915 W/m² at ~50° elevation and 586–640 at ~20°.
    func testClearSkyReferenceMatchesModelClearDays() {
        XCTAssertEqual(ClearSky.directNormal(elevation: 50), 890, accuracy: 40)
        XCTAssertEqual(ClearSky.directNormal(elevation: 20), 640, accuracy: 60)
        XCTAssertEqual(ClearSky.directNormal(elevation: 0), 0)
        XCTAssertGreaterThan(ClearSky.directNormal(elevation: 60), ClearSky.directNormal(elevation: 30))
    }

    /// Six requested points, five model cells: Pacific Heights and the Financial District
    /// snap to the same ~3 km cell and must be counted once.
    func testDecodesDistinctCells() throws {
        let field = try fixture()
        XCTAssertEqual(field.samples.count, 5)
        for s in field.samples {
            XCTAssertEqual(s.times.count, 96, "one day of 15-minute steps")
            XCTAssertEqual(s.hourlyTimes.count, 24)
            XCTAssertEqual(s.directNormal.count, 96)
            XCTAssertEqual(s.lowCloud.count, 24)
        }
    }

    /// The whole point: on Sept 15 the model had the fog sitting on Ocean Beach at
    /// 2 pm while the Mission was in full sun. One number for the city would be wrong
    /// for half of it.
    func testFogDayGradientAcrossTheCity() throws {
        let field = try fixture()
        let el = Solar.position(latitude: mission.lat, longitude: mission.lon, date: fogAfternoon).elevation
        XCTAssertGreaterThan(el, 40)
        let coast = try XCTUnwrap(field.condition(latitude: oceanBeach.lat, longitude: oceanBeach.lon,
                                                  at: fogAfternoon, sunElevation: el))
        let inland = try XCTUnwrap(field.condition(latitude: mission.lat, longitude: mission.lon,
                                                   at: fogAfternoon, sunElevation: el))
        XCTAssertLessThan(coast.beamStrength, 0.1, "coast: \(coast)")
        XCTAssertGreaterThan(inland.beamStrength, 0.8, "inland: \(inland)")
        XCTAssertEqual(coast.regime, .overcast)
        XCTAssertEqual(inland.regime, .clear)
        XCTAssertFalse(coast.shadowsMatter)
        XCTAssertTrue(inland.shadowsMatter)
        XCTAssertEqual(coast.summary, "Fog · no direct sun", "low cloud at 100% reads as fog")

        let spread = try XCTUnwrap(field.beamSpread(at: fogAfternoon, sunElevation: el))
        XCTAssertGreaterThan(spread.max - spread.min, 0.6)
    }

    /// Walking from the coast cell to the Mission cell the blend stays between the two
    /// and climbs overall. (It is not strictly monotonic: the Twin Peaks and Park Merced
    /// cells also pull on the inverse-distance weights, by ~0.01 — measured, and fine.)
    func testSpatialInterpolationStaysBoundedAndRisesInland() throws {
        let field = try fixture()
        let el = 45.0
        var values: [Double] = []
        for i in 0...10 {
            let f = Double(i) / 10
            let lon = oceanBeach.lon + (mission.lon - oceanBeach.lon) * f
            let c = try XCTUnwrap(field.condition(latitude: mission.lat, longitude: lon,
                                                  at: fogAfternoon, sunElevation: el))
            values.append(c.beamStrength)
        }
        let coast = values.first!, inland = values.last!
        for (i, v) in values.enumerated() {
            XCTAssertGreaterThanOrEqual(v, coast - 0.02, "step \(i)")
            XCTAssertLessThanOrEqual(v, inland + 0.02, "step \(i)")
        }
        XCTAssertLessThan(values[1], values[9] - 0.4, "coast stays in fog, inland clears: \(values)")
        XCTAssertGreaterThan(values[8], values[7], "the climb starts before the Mission cell: \(values)")
    }

    func testTimeInterpolationBetweenStepsAndOutsideRange() throws {
        let field = try fixture()
        let s = field.samples[1]   // Mission cell
        let t0 = s.times[56], t1 = s.times[57]
        let a = try XCTUnwrap(s.condition(at: Date(timeIntervalSince1970: t0), sunElevation: 45)).directNormal
        let b = try XCTUnwrap(s.condition(at: Date(timeIntervalSince1970: t1), sunElevation: 45)).directNormal
        let mid = try XCTUnwrap(s.condition(at: Date(timeIntervalSince1970: (t0 + t1) / 2), sunElevation: 45)).directNormal
        XCTAssertEqual(mid, (a + b) / 2, accuracy: 1e-6)
        XCTAssertNil(s.condition(at: Date(timeIntervalSince1970: s.times[0] - 1), sunElevation: 45))
        XCTAssertNil(s.condition(at: Date(timeIntervalSince1970: s.times[95] + 1), sunElevation: 45))
        XCTAssertNil(field.condition(latitude: 37.76, longitude: -122.45,
                                     at: Date(timeIntervalSince1970: s.times[95] + 3600), sunElevation: 45))
    }

    func testRegimesAndSummaries() {
        XCTAssertEqual(SkyCondition.clear.regime, .clear)
        XCTAssertEqual(SkyCondition.partly.regime, .hazy)
        XCTAssertEqual(SkyCondition.overcast.regime, .overcast)
        XCTAssertEqual(SkyCondition.overcast.summary, "Overcast · no direct sun")
        XCTAssertEqual(SkyCondition.fog.summary, "Fog · no direct sun")
        XCTAssertEqual(SkyCondition.partly.summary, "Thin cloud · sun at 55%")
        let broken = SkyCondition(directNormal: 200, diffuse: 200, cloudCover: 0.7, lowCloud: 0.1, sunElevation: 50)
        XCTAssertEqual(broken.regime, .broken)
        XCTAssertTrue(broken.summary.hasPrefix("Broken cloud"))
        // Night: no clear-sky beam, so strength is 0 rather than a division by zero.
        let night = SkyCondition(directNormal: 0, diffuse: 0, cloudCover: 0, lowCloud: 0, sunElevation: -10)
        XCTAssertEqual(night.beamStrength, 0)
    }

    func testUniformFieldAndLattice() throws {
        let from = Date(timeIntervalSince1970: 1_789_500_000), to = from.addingTimeInterval(7200)
        let field = SkyField.uniform(.overcast, latitude: 37.78, longitude: -122.40, from: from, to: to)
        let c = try XCTUnwrap(field.condition(latitude: 37.70, longitude: -122.50,
                                              at: from.addingTimeInterval(3000), sunElevation: 40))
        XCTAssertEqual(c.beamStrength, 0)
        XCTAssertEqual(c.cloudCover, 1, accuracy: 1e-9)

        let pts = OpenMeteoSky.latticePoints(around: 37.78415, longitude: -122.40060)
        XCTAssertEqual(pts.count, 9)
        let again = OpenMeteoSky.latticePoints(around: 37.78500, longitude: -122.40500)
        XCTAssertEqual(pts.map { "\($0.latitude),\($0.longitude)" }, again.map { "\($0.latitude),\($0.longitude)" },
                       "nearby points share the same lattice cells so the cache hits")
        let url = OpenMeteoSky.requestURL(points: pts)
        XCTAssertTrue(url.absoluteString.contains("minutely_15=direct_normal_irradiance,diffuse_radiation"))
        XCTAssertTrue(url.absoluteString.contains("timeformat=unixtime"))
    }
}
