import XCTest
@testable import LikeWaterEngine

final class SunTests: XCTestCase {

    private static let anchorLat = 37.7800
    private static let anchorLon = -122.4000
    private static let plane = LocalPlane(originLat: anchorLat, originLon: anchorLon)

    /// Builds a store from metre coordinates so the geometry in a test reads clearly.
    private func store(_ footprints: [(corners: [(x: Double, y: Double)], height: Float)]) -> BuildingStore {
        var start: [Int32] = [0]
        var lat: [Double] = [], lon: [Double] = [], height: [Float] = []
        for f in footprints {
            for c in f.corners {
                let p = Self.plane.unproject(x: c.x, y: c.y)
                lat.append(p.lat); lon.append(p.lon)
            }
            start.append(Int32(lat.count))
            height.append(f.height)
        }
        let box = BBox(minLat: Self.anchorLat - 0.01, minLon: Self.anchorLon - 0.01,
                       maxLat: Self.anchorLat + 0.01, maxLon: Self.anchorLon + 0.01)
        return BuildingStore(start: start, lat: lat, lon: lon, height: height, bbox: box)
    }

    /// A 20 m box centred on the origin, spanning -10..10 in both directions.
    private func singleBox(height: Float = 20) -> BuildingStore {
        store([(corners: [(-10, -10), (10, -10), (10, 10), (-10, 10)], height: height)])
    }

    private func shaded(_ buildings: BuildingStore, x: Double, y: Double,
                        azimuth: Double, elevationDegrees: Double) -> Bool {
        var scratch = [Int32](repeating: -1, count: max(1, buildings.count))
        return buildings.isShaded(x: x, y: y, azimuthDegrees: azimuth,
                                  tanElevation: tan(elevationDegrees * .pi / 180),
                                  visited: &scratch, stamp: 1)
    }

    /// Standing 20 m south of a 20 m wall with the sun due north: the wall subtends
    /// exactly 45 degrees, so the point is shaded below that elevation and lit above it.
    func testShadowLengthFollowsTheElevationAngle() {
        let b = singleBox(height: 20)
        let point = (x: 0.0, y: -30.0)       // 20 m clear of the south wall at y = -10

        XCTAssertTrue(shaded(b, x: point.x, y: point.y, azimuth: 0, elevationDegrees: 20))
        XCTAssertTrue(shaded(b, x: point.x, y: point.y, azimuth: 0, elevationDegrees: 40))
        XCTAssertFalse(shaded(b, x: point.x, y: point.y, azimuth: 0, elevationDegrees: 50))
        XCTAssertFalse(shaded(b, x: point.x, y: point.y, azimuth: 0, elevationDegrees: 70))
    }

    func testFacingAwayFromTheBuildingIsAlwaysLit() {
        let b = singleBox(height: 60)
        // Sun due south: the ray leaves the building behind.
        XCTAssertFalse(shaded(b, x: 0, y: -30, azimuth: 180, elevationDegrees: 10))
        XCTAssertFalse(shaded(b, x: 0, y: -30, azimuth: 180, elevationDegrees: 40))
    }

    func testTallerBuildingsShadeFurther() {
        let short = singleBox(height: 10)
        let tall = singleBox(height: 60)
        // 40 m clear of the wall, sun at 35 degrees (tan ~ 0.70, so reach ~ 28 m for the
        // short building and ~ 85 m for the tall one).
        XCTAssertFalse(shaded(short, x: 0, y: -50, azimuth: 0, elevationDegrees: 35))
        XCTAssertTrue(shaded(tall, x: 0, y: -50, azimuth: 0, elevationDegrees: 35))
    }

    /// The point of keeping both sides of a street: one side is lit while the other is not.
    func testOppositeSidesOfAStreetDisagree() {
        let b = singleBox(height: 25)
        let south = (x: 0.0, y: -20.0)       // 10 m clear of the south wall
        let north = (x: 0.0, y: 20.0)        // 10 m clear of the north wall
        // Sun in the north-east quadrant, low: shades the south side, not the north side.
        XCTAssertTrue(shaded(b, x: south.x, y: south.y, azimuth: 0, elevationDegrees: 30))
        XCTAssertFalse(shaded(b, x: north.x, y: north.y, azimuth: 0, elevationDegrees: 30))
    }

    func testEdgeScoreIsTheFractionOfSampledPointsInSun() {
        // Wall 40 m wide along x, 20 m tall, sitting north of the edge we score.
        let b = store([(corners: [(-20, 0), (20, 0), (20, 20), (-20, 20)], height: 20)])
        var scorer = SunScorer(buildings: b, samplesPerEdge: 5)

        // An edge running east-west at y = -10, from x = 0 to x = 80. Its first half sits
        // behind the wall; past x = 20 the wall no longer blocks a ray heading due north.
        let a = Self.plane.unproject(x: 0, y: -10)
        let c = Self.plane.unproject(x: 80, y: -10)
        let sun = SolarPosition(elevation: 30, azimuth: 0, declination: 0, equationOfTime: 0)
        let score = scorer.score(aLat: a.lat, aLon: a.lon, bLat: c.lat, bLon: c.lon,
                                 sun: sun, stamp: 1)
        // Samples at x = 8, 24, 40, 56, 72: only the first is behind the wall.
        XCTAssertEqual(score, 0.8, accuracy: 0.001)
        XCTAssertEqual(SunBucket(fraction: score), .sunny)
    }

    func testSunBelowTheHorizonScoresZero() {
        var scorer = SunScorer(buildings: singleBox())
        let down = SolarPosition(elevation: -3, azimuth: 250, declination: 0, equationOfTime: 0)
        let a = Self.plane.unproject(x: 0, y: -40)
        let b = Self.plane.unproject(x: 50, y: -40)
        XCTAssertEqual(scorer.score(aLat: a.lat, aLon: a.lon, bLat: b.lat, bLon: b.lon,
                                    sun: down, stamp: 1), 0)
        XCTAssertFalse(down.isUp)
    }

    /// Hills shade too. Flat ground at 5 m with a 40 m rise about 90 m to the north-east:
    /// the rise subtends ~24 degrees, so a low north-east sun is blocked and a high one is not.
    func testHillsShadeAtLowSunAngles() {
        let step = 60.0
        let stepLat = step / 111_320.0
        let stepLon = step / (111_320.0 * cos(Self.anchorLat * .pi / 180))
        // Grid origin 60 m south-west of the anchor so the anchor sits at cell (1,1).
        let origin = Self.plane.unproject(x: -step, y: -step)
        var cells = [Int16](repeating: 5, count: 16)
        for (r, c) in [(2, 3), (3, 2), (3, 3)] { cells[r * 4 + c] = 45 }
        let terrain = TerrainGrid(rows: 4, cols: 4, originLat: origin.lat, originLon: origin.lon,
                                  stepLat: stepLat, stepLon: stepLon, elevation: cells)
        let box = BBox(minLat: Self.anchorLat - 0.01, minLon: Self.anchorLon - 0.01,
                       maxLat: Self.anchorLat + 0.01, maxLon: Self.anchorLon + 0.01)
        let empty = BuildingStore(start: [0], lat: [], lon: [], height: [], ground: [],
                                  terrain: terrain, bbox: box)
        // Standing at the anchor (cell 1,1, flat ground).
        XCTAssertTrue(shaded(empty, x: 0, y: 0, azimuth: 45, elevationDegrees: 12), "low NE sun blocked by the hill")
        XCTAssertFalse(shaded(empty, x: 0, y: 0, azimuth: 45, elevationDegrees: 40), "high NE sun clears the hill")
        XCTAssertFalse(shaded(empty, x: 0, y: 0, azimuth: 225, elevationDegrees: 12), "SW sun: hill is behind you")
    }

    /// A building's roof is ground + height. A 20 m building on a 30 m knoll shades a
    /// walker on the flat; the same building 30 m below the walker does not.
    func testBuildingGroundLevelMatters() {
        let box = BBox(minLat: Self.anchorLat - 0.01, minLon: Self.anchorLon - 0.01,
                       maxLat: Self.anchorLat + 0.01, maxLon: Self.anchorLon + 0.01)
        func store(ground: Float) -> BuildingStore {
            var lat: [Double] = [], lon: [Double] = []
            for (x, y) in [(-10.0, -10.0), (10.0, -10.0), (10.0, 10.0), (-10.0, 10.0)] {
                let p = Self.plane.unproject(x: x, y: y); lat.append(p.lat); lon.append(p.lon)
            }
            return BuildingStore(start: [0, 4], lat: lat, lon: lon, height: [20], ground: [ground],
                                 terrain: nil, bbox: box)
        }
        // 20 m clear of the wall, sun at 45 degrees: with the building level with the
        // walker this is the exact 45-degree boundary tested elsewhere (shaded at <45).
        XCTAssertTrue(shaded(store(ground: 30), x: 0, y: -30, azimuth: 0, elevationDegrees: 45))
        XCTAssertFalse(shaded(store(ground: -30), x: 0, y: -30, azimuth: 0, elevationDegrees: 20))
    }

    func testBucketBoundaries() {
        XCTAssertEqual(SunBucket(fraction: 0.0), .shaded)
        XCTAssertEqual(SunBucket(fraction: 0.29), .shaded)
        XCTAssertEqual(SunBucket(fraction: 0.3), .mixed)
        XCTAssertEqual(SunBucket(fraction: 0.7), .mixed)
        XCTAssertEqual(SunBucket(fraction: 0.71), .sunny)
        XCTAssertEqual(SunBucket(fraction: 1.0), .sunny)
    }
}
