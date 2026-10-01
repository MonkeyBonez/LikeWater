import XCTest
@testable import LikeWaterEngine

private func emptyScorer(_ g: PedestrianGraph) -> SunScorer {
    SunScorer(buildings: BuildingStore(start: [0], lat: [], lon: [], height: [], bbox: g.bbox))
}

/// Corridor + flat per-direction seconds for a grid walk.
private func setup(_ g: PedestrianGraph, from o: Int32, to d: Int32, slack: Double,
                   pace: WalkingPace = .normal) throws -> (DestinationLabels, Corridor, EdgeSeconds) {
    let labels = try CorridorEngine.labels(graph: g, destination: d, origin: o, slack: max(slack, 0.5))
    let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: o, slack: slack)
    let secs = PaceModel(pace: pace).edgeSeconds(graph: g, edges: c.edges, terrain: nil)
    return (labels, c, secs)
}

final class PaceModelTests: XCTestCase {
    func testToblerIsOneOnTheFlatAndSlowerUphill() {
        XCTAssertEqual(PaceModel.tobler(grade: 0), 1, accuracy: 1e-12)
        XCTAssertEqual(PaceModel.tobler(grade: 0.10), 0.7047, accuracy: 1e-3)
        XCTAssertEqual(PaceModel.tobler(grade: -0.15), 0.8395, accuracy: 1e-3)   // steep downhill: 0.84×
        XCTAssertGreaterThan(PaceModel.tobler(grade: -0.05), 1.18)
    }

    func testUphillCrossingsAndStairs() {
        let m = PaceModel(pace: .normal)
        let flat = m.seconds(length: 100, rise: 0, flags: 0)
        XCTAssertEqual(flat, 100 / 1.4, accuracy: 1e-9)
        XCTAssertEqual(m.seconds(length: 100, rise: 10, flags: 0), flat / PaceModel.tobler(grade: 0.1), accuracy: 1e-9)
        XCTAssertEqual(m.seconds(length: 100, rise: 0, flags: EdgeFlag.crossing), flat + 12, accuracy: 1e-9)
        XCTAssertEqual(m.seconds(length: 30, rise: 6, flags: EdgeFlag.steps), 30 / (1.4 * 0.6), accuracy: 1e-9)
        // A 3 m edge with 2 m of terrain noise is not a 67 % grade.
        XCTAssertEqual(m.seconds(length: 3, rise: 2, flags: 0), 3 / (1.4 * PaceModel.tobler(grade: 0.2)), accuracy: 1e-9)
    }

    func testTerrainMakesDirectionsDiffer() {
        let g = gridGraph(rows: 1, cols: 2)
        // A 2×2 terrain grid rising 10 m west → east across the edge.
        let lats = g.nodeLat, lons = g.nodeLon
        let terrain = TerrainGrid(rows: 2, cols: 2, originLat: lats[0] - 0.001, originLon: lons[0],
                                  stepLat: 0.002, stepLon: lons[1] - lons[0], elevation: [0, 10, 0, 10])
        let s = PaceModel().edgeSeconds(graph: g, edges: [0], terrain: terrain)
        XCTAssertGreaterThan(s.forward[0], s.backward[0])
        // Edge 0 of the grid is a marked crossing: +12 s either way.
        XCTAssertEqual(s.forward[0], 100 / (1.4 * PaceModel.tobler(grade: 0.1)) + 12, accuracy: 0.5)
    }
}

final class SunTimelineTests: XCTestCase {
    // Noon PDT, 2026-09-23, near the grid (SF).
    let noon = ISO8601DateFormatter().date(from: "2026-09-23T19:00:00Z")!

    func testOnlyReachableSlotsAreScored() throws {
        let g = gridGraph(rows: 12, cols: 12, spacing: 400)    // D = 8.8 km ≈ 105 min
        let (_, c, secs) = try setup(g, from: 0, to: 143, slack: 0.1)
        var scorer = emptyScorer(g)
        let t = SunTimelineBuilder.build(graph: g, corridor: c, origin: g.coordinate(0), destination: g.coordinate(143),
                                         departure: noon, pace: .normal, edgeSeconds: secs, scorer: &scorer,
                                         cache: SunSlotCache(), sky: nil)
        XCTAssertGreaterThanOrEqual(t.slotCount, 7)
        for i in c.edges.indices {
            let slots = (0..<t.slotCount).filter { !t.sun[$0][i].isNaN }.count
            XCTAssertGreaterThanOrEqual(slots, 1)
            XCTAssertLessThanOrEqual(slots, 4, "edge \(i) scored in \(slots) slots")
        }
        XCTAssertLessThan(t.scoredPairs, c.edges.count * t.slotCount / 2)
        // No buildings: everything scored is fully sunny at noon.
        XCTAssertEqual(t.effectiveSun(edge: 0, slot: t.slot(atSeconds: 0)), 1)
    }

    func testAbsoluteSlotsAreReusedByTheNextFix() throws {
        let g = gridGraph(rows: 12, cols: 12, spacing: 400)
        let (_, c, secs) = try setup(g, from: 0, to: 143, slack: 0.1)
        var scorer = emptyScorer(g)
        let cache = SunSlotCache()
        let first = SunTimelineBuilder.build(graph: g, corridor: c, origin: g.coordinate(0), destination: g.coordinate(143),
                                             departure: noon, pace: .normal, edgeSeconds: secs, scorer: &scorer,
                                             cache: cache, sky: nil)
        let second = SunTimelineBuilder.build(graph: g, corridor: c, origin: g.coordinate(0), destination: g.coordinate(143),
                                              departure: noon.addingTimeInterval(10), pace: .normal, edgeSeconds: secs,
                                              scorer: &scorer, cache: cache, sky: nil)
        XCTAssertEqual(first.cacheHits, 0)
        XCTAssertGreaterThan(second.cacheHits, 0)
        XCTAssertLessThanOrEqual(Double(second.scoredPairs), 0.1 * Double(second.cacheHits + second.scoredPairs))
    }

    func testSlotsAfterSunsetAreNotScored() throws {
        let g = gridGraph(rows: 12, cols: 12, spacing: 400)
        let (_, c, secs) = try setup(g, from: 0, to: 143, slack: 0.1)
        var scorer = emptyScorer(g)
        let sunset = Solar.daylightWindow(latitude: g.nodeLat[0], longitude: g.nodeLon[0], containing: noon)!.sunset
        let t = SunTimelineBuilder.build(graph: g, corridor: c, origin: g.coordinate(0), destination: g.coordinate(143),
                                         departure: sunset.addingTimeInterval(-1800), pace: .normal, edgeSeconds: secs,
                                         scorer: &scorer, cache: SunSlotCache(), sky: nil)
        XCTAssertNotNil(t.sunset)
        XCTAssertTrue(t.sunUp.first!)
        XCTAssertFalse(t.sunUp.last!)
        for k in 0..<t.slotCount where !t.sunUp[k] {
            XCTAssertTrue(t.sun[k].allSatisfy { $0.isNaN })
            XCTAssertEqual(t.effectiveSun(edge: 0, slot: k), 0)
        }
    }

    func testBeamFollowsFogWestAlongTheWalk() throws {
        let g = gridGraph(rows: 12, cols: 12, spacing: 400)
        let (_, c, secs) = try setup(g, from: 0, to: 143, slack: 0.1)
        var scorer = emptyScorer(g)
        let o = g.coordinate(0), d = g.coordinate(143)
        let fog = SkyField.uniform(.fog, latitude: o.lat, longitude: o.lon, from: noon.addingTimeInterval(-3600), to: noon.addingTimeInterval(4 * 3600))
        let sun = SkyField.uniform(.clear, latitude: d.lat, longitude: d.lon, from: noon.addingTimeInterval(-3600), to: noon.addingTimeInterval(4 * 3600))
        let t = SunTimelineBuilder.build(graph: g, corridor: c, origin: o, destination: d, departure: noon, pace: .normal,
                                         edgeSeconds: secs, scorer: &scorer, cache: SunSlotCache(),
                                         sky: SkyField(samples: fog.samples + sun.samples))
        XCTAssertLessThan(t.beam.first!, 0.5)
        XCTAssertGreaterThan(t.beam.last!, 0.5)
    }
}

final class RouteTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 900 * 2_000_000)

    /// Sun per corridor edge: 1 where both ends are in `row`, else `other`.
    func rowSun(_ g: PedestrianGraph, _ c: Corridor, cols: Int, row: Int, other: Float = 0) -> [Float] {
        c.edges.map { e in
            let a = Int(g.edgeA[Int(e)]) / cols, b = Int(g.edgeB[Int(e)]) / cols
            return a == row && b == row ? 1 : other
        }
    }

    func testFastestIsTheShortestPath() throws {
        let g = gridGraph(rows: 6, cols: 6)
        let (labels, c, secs) = try setup(g, from: 0, to: 35, slack: 0.3)
        let r = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: nil,
                                      edgeSeconds: secs, sunWeight: 0)
        XCTAssertEqual(r.metres, c.distance, accuracy: 1e-6)
        XCTAssertEqual(r.nodes.first, 0); XCTAssertEqual(r.nodes.last, 35)
        XCTAssertEqual(r.arrivalSeconds.last!, r.seconds, accuracy: 1e-9)
    }

    func testASunnyDetourIsTakenOnlyInsideTheSlack() throws {
        let cols = 5
        let g = gridGraph(rows: 2, cols: cols, crossings: false)   // row 0 shaded, row 1 sunny
        for (slack, takesDetour) in [(0.5, true), (0.4, false)] {
            let (labels, c, secs) = try setup(g, from: 0, to: 4, slack: slack)
            let tl = SunTimeline(constant: rowSun(g, c, cols: cols, row: 1), departure: t0, slots: 4)
            let r = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl,
                                          edgeSeconds: secs, sunWeight: 1)
            XCTAssertEqual(r.nodes.contains(Int32(cols + 2)), takesDetour, "slack \(slack)")
            XCTAssertLessThanOrEqual(r.metres, c.distance * (1 + slack) + 1e-6)
            // Shade preference flips the choice back to the shaded row.
            let shade = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl,
                                              edgeSeconds: secs, sunWeight: 1, prefer: .shade)
            XCTAssertFalse(shade.nodes.contains(Int32(cols + 2)))
            XCTAssertEqual(shade.sunSeconds, 0, accuracy: 1e-9)
        }
    }

    func testRoutesNeverLeaveTheCorridorOrItsBound() throws {
        let n = 12
        let g = gridGraph(rows: n, cols: n)
        var rng = SystemRandomNumberGenerator()
        for slack in [0.1, 0.3] {
            let (labels, c, secs) = try setup(g, from: 0, to: Int32(n * n - 1), slack: slack)
            let members = Set(c.edges)
            for trial in 0..<5 {
                _ = trial
                let sun = c.edges.map { _ in Float.random(in: 0...1, using: &rng) }
                let tl = SunTimeline(constant: sun, departure: t0, slots: 6)
                for w in stride(from: 0.0, through: 1.0, by: 0.25) {
                    let r = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl,
                                                  edgeSeconds: secs, sunWeight: w)
                    XCTAssertTrue(r.edges.allSatisfy(members.contains))
                    XCTAssertLessThanOrEqual(r.metres, c.distance * (1 + slack) + 1e-6)
                    XCTAssertEqual(r.nodes.last, Int32(n * n - 1))
                    // evaluate() reproduces the search's own accounting.
                    let e = RouteEngine.evaluate(edges: r.edges, from: 0, graph: g, corridor: c, timeline: tl,
                                                 edgeSeconds: secs, sunWeight: w)!
                    XCTAssertEqual(e.cost, r.cost, accuracy: 1e-6)
                    XCTAssertEqual(e.seconds, r.seconds, accuracy: 1e-6)
                    XCTAssertEqual(e.sunSeconds, r.sunSeconds, accuracy: 1e-6)
                }
                let ladder = RouteEngine.ladder(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl, edgeSeconds: secs)
                XCTAssertFalse(ladder.isEmpty)
                for (a, b) in zip(ladder, ladder.dropFirst()) {
                    XCTAssertLessThan(a.seconds, b.seconds + 1e-9)
                    XCTAssertLessThan(a.sunSeconds, b.sunSeconds)        // pay time only for more sun
                }
            }
        }
    }

    func testAnEdgeSunnyOnlyLaterIsChosenOnlyWhenReachedLater() throws {
        let cols = 5
        let g = gridGraph(rows: 2, cols: cols)              // two equal 500 m paths 0 → 9
        let (labels, c, secs) = try setup(g, from: 0, to: Int32(2 * cols - 1), slack: 0.05)
        let row0 = rowSun(g, c, cols: cols, row: 0).map { $0 * 0.1 }       // dimly lit always
        let row1 = rowSun(g, c, cols: cols, row: 1)                          // lit only in slot 1
        let firstSlot = 2_000_000
        let tl = { (dep: Date) in
            SunTimeline(departure: dep, slotSeconds: 900, firstSlot: firstSlot,
                        sun: [row0, zip(row0, row1).map { max($0, $1) }], beam: [1, 1], sunUp: [true, true])
        }
        // Leaving 1 s before slot 1: row 1 is lit when reached.
        let late = Date(timeIntervalSince1970: Double(firstSlot + 1) * 900 - 1)
        let r1 = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl(late),
                                       edgeSeconds: secs, sunWeight: 1)
        XCTAssertTrue(r1.nodes.contains(Int32(cols + 2)))
        // Leaving at the start of slot 0: the walk ends before row 1 lights up.
        let early = Date(timeIntervalSince1970: Double(firstSlot) * 900)
        let r0 = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl(early),
                                       edgeSeconds: secs, sunWeight: 1)
        XCTAssertTrue(r0.nodes.contains(2))
        XCTAssertFalse(r0.nodes.contains(Int32(cols + 2)))
    }

    func testCrossingTimeIsNeverDiscountedForSun() throws {
        // Same detour, but every other row-1 segment is a crosswalk: sun on the road surface
        // and the kerb wait must not buy the detour (the SoMa zig-zag, LEARNINGS §11).
        let cols = 5
        let g = gridGraph(rows: 2, cols: cols)
        let (labels, c, secs) = try setup(g, from: 0, to: 4, slack: 0.5)
        let tl = SunTimeline(constant: rowSun(g, c, cols: cols, row: 1), departure: t0, slots: 4)
        let r = try RouteEngine.route(graph: g, corridor: c, labels: labels, origin: 0, timeline: tl,
                                      edgeSeconds: secs, sunWeight: 1)
        XCTAssertFalse(r.nodes.contains(Int32(cols + 2)))
    }

    func testHysteresisKeepsANearlyAsGoodRoute() {
        func r(_ cost: Double) -> Route {
            Route(nodes: [], edges: [], corridorIndex: [], metres: 0, seconds: 0, sunSeconds: 0, cost: cost,
                  edgeSun: [], edgeSlot: [], arrivalSeconds: [], sunWeight: 0, labelsExpanded: 0,
                  maxLabelsAtANode: 0, capHits: 0, computeMs: 0)
        }
        XCTAssertTrue(RouteEngine.shouldKeep(previous: r(104), candidate: r(100)))
        XCTAssertFalse(RouteEngine.shouldKeep(previous: r(106), candidate: r(100)))
    }
}
