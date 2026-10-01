import XCTest
@testable import LikeWaterEngine

/// Tests against the real San Francisco bundle. Skipped when the bundle has not
/// been built yet (`Pipeline/build_bundle.py`), so a clean checkout still passes.
final class RealCityTests: XCTestCase {

    private static var cached: CityBundle?

    private func city() throws -> CityBundle {
        if let c = Self.cached { return c }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/sanfrancisco.lwbundle")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("San Francisco bundle not built yet")
        }
        let t0 = CFAbsoluteTimeGetCurrent()
        let c = try CityBundle(contentsOf: url)
        print("bundle load: \(String(format: "%.0f", (CFAbsoluteTimeGetCurrent() - t0) * 1000)) ms")
        Self.cached = c
        return c
    }

    /// The pipeline is city-agnostic: a second bundle, built with no city-specific
    /// width survey, must load, synthesise, and carry terrain — Berkeley's hills top 500 m.
    func testSecondCityBundleIsComplete() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/berkeley.lwbundle")
        guard FileManager.default.fileExists(atPath: url.path) else { throw XCTSkip("Berkeley bundle not built") }
        let header = try BundleHeader.read(from: url)
        XCTAssertEqual(header.version, 2)
        let c = try CityBundle(contentsOf: url)
        XCTAssertGreaterThan(c.graph.nodeCount, 30_000)
        let synthesised = c.graph.edgeFlags.filter { $0 & EdgeFlag.synthetic != 0 && $0 & EdgeFlag.sidewalk != 0 }.count
        XCTAssertGreaterThan(synthesised, 20_000, "synthesis must work without a width survey")
        let terrain = try XCTUnwrap(c.terrain)
        XCTAssertGreaterThan(terrain.elevation(lat: 37.8816, lon: -122.2450), 150, "Berkeley hills above campus")
        XCTAssertLessThan(terrain.elevation(lat: 37.8716, lon: -122.2727), 60, "downtown is near sea level")
        XCTAssertEqual(c.graph.componentSizes.count, 1, "largest component only")
        // Downtown Berkeley at 8:30 am: a field renders and is not degenerate.
        var scorer = SunScorer(buildings: c.buildings)
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime]
        let sun = Solar.position(latitude: 37.8716, longitude: -122.2727, date: f.date(from: "2026-09-23T15:30:00Z")!)
        let ids = c.graph.edges(near: 37.8716, lon: -122.2727, radius: 400)
        let scores = scorer.score(graph: c.graph, edges: ids, sun: sun)
        let sunny = scores.filter { $0 > 0.7 }.count
        XCTAssertGreaterThan(ids.count, 500)
        XCTAssertGreaterThan(sunny, 50); XCTAssertLessThan(sunny, ids.count - 50)
    }

    func testBundleShape() throws {
        let c = try city()
        XCTAssertGreaterThan(c.graph.nodeCount, 100_000)
        XCTAssertGreaterThan(c.buildings.count, 100_000)
        let crossings = c.graph.edgeFlags.filter { $0 & EdgeFlag.crossing != 0 }.count
        let sidewalks = c.graph.edgeFlags.filter { $0 & EdgeFlag.sidewalk != 0 }.count
        let tagged = c.graph.edgeFlags.filter { $0 & EdgeFlag.streetSidewalkTag != 0 }.count
        print("nodes \(c.graph.nodeCount) edges \(c.graph.edgeCount) crossings \(crossings) sidewalk-ways \(sidewalks) tagged-centrelines \(tagged) buildings \(c.buildings.count)")
        // The two must never overlap: an edge is either its own sidewalk or a
        // centreline that merely mentions one.
        for f in c.graph.edgeFlags {
            XCTAssertFalse(f & EdgeFlag.sidewalk != 0 && f & EdgeFlag.streetSidewalkTag != 0)
        }
        XCTAssertGreaterThan(tagged, 1_000)
        print("components \(c.graph.componentSizes.count), largest \(c.graph.componentSizes.max()!)")
        XCTAssertGreaterThan(crossings, 10_000)
        XCTAssertGreaterThan(sidewalks, 10_000)
    }

    func testExploreHowardStreetSidewalks() throws {
        let c = try city()
        let howardAndThird = (lat: 37.78475, lon: -122.40105)
        let ids = c.graph.edges(near: howardAndThird.lat, lon: howardAndThird.lon, radius: 60)
        var scorer = SunScorer(buildings: c.buildings)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let decNoon = formatter.date(from: "2026-12-15T20:10:00Z")!   // 12:10 pm PST
        let decFour = formatter.date(from: "2026-12-15T00:00:00Z")!   // 4:00 pm PST on Dec 14
        let sunNoon = Solar.position(latitude: howardAndThird.lat, longitude: howardAndThird.lon, date: decNoon)
        let sunFour = Solar.position(latitude: howardAndThird.lat, longitude: howardAndThird.lon, date: decFour)
        print("Dec noon sun: az \(String(format: "%.1f", sunNoon.azimuth)) el \(String(format: "%.1f", sunNoon.elevation))")
        print("Dec 4pm  sun: az \(String(format: "%.1f", sunFour.azimuth)) el \(String(format: "%.1f", sunFour.elevation))")

        var reported = 0
        for e in ids where c.graph.isSidewalk(Int(e)) {
            let a = Int(c.graph.edgeA[Int(e)]), b = Int(c.graph.edgeB[Int(e)])
            let noon = scorer.score(aLat: c.graph.nodeLat[a], aLon: c.graph.nodeLon[a],
                                    bLat: c.graph.nodeLat[b], bLon: c.graph.nodeLon[b],
                                    sun: sunNoon, stamp: Int32(reported * 20 + 1))
            let four = scorer.score(aLat: c.graph.nodeLat[a], aLon: c.graph.nodeLon[a],
                                    bLat: c.graph.nodeLat[b], bLon: c.graph.nodeLon[b],
                                    sun: sunFour, stamp: Int32(reported * 20 + 11))
            print(String(format: "edge %6d  (%.5f,%.5f)-(%.5f,%.5f)  len %5.1f  noon %.1f  4pm %.1f",
                         Int(e), c.graph.nodeLat[a], c.graph.nodeLon[a],
                         c.graph.nodeLat[b], c.graph.nodeLon[b],
                         c.graph.edgeLen[Int(e)], noon, four))
            reported += 1
            if reported >= 24 { break }
        }
        print("sidewalk edges near Howard & 3rd: \(reported)")
    }

    /// Every edge in the bundle is routed over and sun-scored; nothing is filtered by
    /// flag. The question this pins down is whether that is *sound* for the 34% of edges
    /// that are road centrelines rather than per-side sidewalks.
    ///
    /// For each centreline OSM tells us has sidewalks, compare its own score against
    /// points offset to where the kerbs are. The centreline is only mildly optimistic,
    /// but the two kerbs land in different buckets about half the time — which is the
    /// measured case for per-side geometry, and the reason a centreline cannot answer
    /// "is *my* side sunny".
    func testCentrelinesCannotAnswerWhichSideIsSunny() throws {
        let c = try city()
        let center = (lat: 37.78415, lon: -122.40060)
        var scorer = SunScorer(buildings: c.buildings)
        let plane = c.buildings.plane
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let sun = Solar.position(latitude: center.lat, longitude: center.lon,
                                 date: formatter.date(from: "2026-09-23T20:00:00Z")!)

        var pairs = 0, kerbsDisagree = 0, centreWrongForBoth = 0
        var centreTotal = 0.0, kerbTotal = 0.0
        var stamp: Int32 = 0

        for e in c.graph.edges(near: center.lat, lon: center.lon, radius: 600)
        where c.graph.isStreetWithSidewalkTag(Int(e)) {
            let a = Int(c.graph.edgeA[Int(e)]), b = Int(c.graph.edgeB[Int(e)])
            let pa = plane.project(lat: c.graph.nodeLat[a], lon: c.graph.nodeLon[a])
            let pb = plane.project(lat: c.graph.nodeLat[b], lon: c.graph.nodeLon[b])
            let dx = pb.x - pa.x, dy = pb.y - pa.y
            let length = (dx * dx + dy * dy).squareRoot()
            guard length > 12 else { continue }
            let nx = -dy / length * 8, ny = dx / length * 8

            func score(_ ox: Double, _ oy: Double) -> Float {
                let ca = plane.unproject(x: pa.x + ox, y: pa.y + oy)
                let cb = plane.unproject(x: pb.x + ox, y: pb.y + oy)
                stamp = stamp &+ 16
                return scorer.score(aLat: ca.lat, aLon: ca.lon, bLat: cb.lat, bLon: cb.lon,
                                    sun: sun, stamp: stamp)
            }
            let centre = score(0, 0), left = score(nx, ny), right = score(-nx, -ny)
            pairs += 1
            centreTotal += Double(centre)
            kerbTotal += Double((left + right) / 2)
            if SunBucket(fraction: left) != SunBucket(fraction: right) { kerbsDisagree += 1 }
            if SunBucket(fraction: centre) != SunBucket(fraction: left)
                && SunBucket(fraction: centre) != SunBucket(fraction: right) { centreWrongForBoth += 1 }
        }

        // Synthesis removes most of these centrelines; the test still runs wherever
        // enough survive to say something, and stands aside otherwise.
        if pairs < 20 { throw XCTSkip("only \(pairs) side-less centrelines left near SoMa after synthesis") }
        let bias = (centreTotal - kerbTotal) / Double(pairs)
        let disagreeRate = Double(kerbsDisagree) / Double(pairs)
        print(String(format: "centreline bias %+.3f · kerbs disagree %.0f%% (%d/%d) · centreline wrong for both %d",
                     bias, 100 * disagreeRate, kerbsDisagree, pairs, centreWrongForBoth))

        // The middle of the road is sunnier than its kerbs, but only mildly: the shadow
        // reach at a midday sun dwarfs an 8 m offset.
        XCTAssertGreaterThan(bias, 0, "the middle of the road should not be darker than its kerbs")
        XCTAssertLessThan(bias, 0.25, "centreline bias should be modest, got \(bias)")
        // The headline: on a large share of streets the sides genuinely differ.
        XCTAssertGreaterThan(disagreeRate, 0.25,
                             "if the sides rarely disagreed, per-side geometry would not matter")
    }

    func testSunFieldPerformanceForASoMaBlock() throws {
        let c = try city()
        let center = (lat: 37.78415, lon: -122.40060)
        var scorer = SunScorer(buildings: c.buildings)
        let ids = c.graph.edges(near: center.lat, lon: center.lon, radius: 400)
        XCTAssertGreaterThan(ids.count, 500)

        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        // A low sun means long rays; a high sun means short ones. Sweep the day so the
        // budget is checked against the worst case rather than a convenient one.
        let samples: [(String, String)] = [
            ("Jun 13:10", "2026-06-21T20:10:00Z"),
            ("Jun 09:00", "2026-06-21T16:00:00Z"),
            ("Dec 12:10", "2026-12-15T20:10:00Z"),
            ("Dec 15:00", "2026-12-15T23:00:00Z"),
            ("Sep 17:30", "2026-09-23T00:30:00Z"),
        ]
        var worst = 0.0
        for (label, stamp) in samples {
            let sun = Solar.position(latitude: center.lat, longitude: center.lon,
                                     date: formatter.date(from: stamp)!)
            let t0 = CFAbsoluteTimeGetCurrent()
            let scores = scorer.score(graph: c.graph, edges: ids, sun: sun)
            let ms = (CFAbsoluteTimeGetCurrent() - t0) * 1000
            worst = max(worst, ms)
            let sunny = scores.filter { $0 > 0.7 }.count
            print(String(format: "%@  el %5.1f  %4d edges  %6.1f ms  %4d sunny",
                         label, sun.elevation, ids.count, ms, sunny))
        }
        print("worst \(String(format: "%.1f", worst)) ms for \(ids.count) edges")
        // The PRD's 200 ms is for the shipped (release) build; `swift test` is debug and
        // roughly 40x slower on this inner loop, so hold it to a proportionate bound.
        #if DEBUG
        let budget = 800.0
        #else
        let budget = 200.0
        #endif
        XCTAssertLessThan(worst, budget, "sun scoring over budget for a ~2000 edge corridor")
    }
}
