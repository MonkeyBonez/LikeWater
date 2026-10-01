import XCTest
@testable import LikeWaterEngine


final class CorridorTests: XCTestCase {

    func testGridCorridorIsExactlyTheRectangle() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let origin = Int32(0)                       // (0,0)
        let dest = Int32(3 * cols + 2)              // (3,2)

        let labels = try CorridorEngine.labels(graph: g, destination: dest, origin: origin, slack: 0)
        XCTAssertEqual(labels.seedDistance, 500, accuracy: 0.001)

        let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: 0)
        XCTAssertEqual(c.distance, 500, accuracy: 0.001)
        // 8 horizontal + 9 vertical monotone edges inside the 4x3 rectangle.
        XCTAssertEqual(c.edges.count, 17)
        XCTAssertEqual(c.choicesHere, 2)
        XCTAssertEqual(c.metersToDecision, 0, accuracy: 1e-6, "origin is itself a decision point")
        XCTAssertFalse(c.isCollapsed)
        for e in c.excess { XCTAssertEqual(e, 0, accuracy: 1e-6) }

        // Every corridor edge stays inside the rectangle spanned by origin and destination.
        for e in c.edges {
            for n in [g.edgeA[Int(e)], g.edgeB[Int(e)]] {
                let i = Int(n) / cols, j = Int(n) % cols
                XCTAssertTrue(i <= 3 && j <= 2, "edge leaves the rectangle at (\(i),\(j))")
            }
        }
    }

    func testForwardFloodExploresOnlyTheCorridorNotTheGraph() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let labels = try CorridorEngine.labels(graph: g, destination: Int32(3 * cols + 2), origin: 0, slack: 0)
        let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: 0, slack: 0)
        XCTAssertEqual(g.nodeCount, 25)
        // Exactly the 4x3 block of nodes satisfies g + dTo <= D.
        XCTAssertEqual(c.nodesExplored, 12)
    }

    func testSlackWidensTheCorridorAndRecordsExcess() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let labels = try CorridorEngine.labels(graph: g, destination: Int32(3 * cols + 2), origin: 0, slack: 0.5)

        let tight = try CorridorEngine.corridor(graph: g, labels: labels, origin: 0, slack: 0)
        let loose = try CorridorEngine.corridor(graph: g, labels: labels, origin: 0, slack: 0.4)
        XCTAssertGreaterThan(loose.edges.count, tight.edges.count)
        XCTAssertGreaterThan(loose.nodesExplored, tight.nodesExplored)

        // Slack edges cost exactly one 200 m detour on a unit lattice.
        let extra = zip(loose.edges, loose.excess).filter { $0.1 > 1e-6 }
        XCTAssertFalse(extra.isEmpty)
        for (_, excess) in extra {
            XCTAssertEqual(excess, 200, accuracy: 1e-6)
            XCTAssertLessThanOrEqual(excess, 500 * 0.4 + 1e-6)
        }
    }

    func testCorridorShrinksAsTheWalkerAdvances() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let dest = Int32(4 * cols + 4)
        let labels = try CorridorEngine.labels(graph: g, destination: dest, origin: 0, slack: 0)

        var previous = Int.max
        // Walk the diagonal; the corridor must strictly shrink each block.
        for k in 0..<4 {
            let node = Int32(k * cols + k)
            let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: node, slack: 0)
            XCTAssertLessThan(c.edges.count, previous)
            previous = c.edges.count
        }
        // Last block before the destination: one edge, no free choice.
        let last = try CorridorEngine.corridor(graph: g, labels: labels, origin: Int32(4 * cols + 3), slack: 0)
        XCTAssertEqual(last.edges.count, 1)
        XCTAssertTrue(last.isCollapsed)

        // A forced run of blocks reports the choice count at the far end, not at the feet.
        let corner = try CorridorEngine.corridor(graph: g, labels: labels, origin: Int32(4 * cols + 0), slack: 0)
        XCTAssertEqual(corner.choicesHere, 0, "bottom edge is a single forced line to the corner")
        XCTAssertEqual(corner.metersToDecision, 400, accuracy: 1e-6)
    }

    func testCrossingEdgesAreTagged() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let labels = try CorridorEngine.labels(graph: g, destination: Int32(3 * cols + 2), origin: 0, slack: 0)
        let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: 0, slack: 0)
        XCTAssertFalse(c.crossingEdges.isEmpty)
        for e in c.crossingEdges { XCTAssertTrue(g.isCrossing(Int(e))) }
        XCTAssertTrue(Set(c.crossingEdges).isSubset(of: Set(c.edges)))
    }

    func testAskingForMoreSlackThanTheLabelsCoverIsRefusedNotTruncated() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let narrow = try CorridorEngine.labels(graph: g, destination: Int32(3 * cols + 2), origin: 0, slack: 0.1)
        XCTAssertEqual(narrow.coveredSlack, 0.1, accuracy: 1e-9)
        XCTAssertNoThrow(try CorridorEngine.corridor(graph: g, labels: narrow, origin: 0, slack: 0.1))
        XCTAssertThrowsError(try CorridorEngine.corridor(graph: g, labels: narrow, origin: 0, slack: 0.4)) { error in
            guard case CorridorError.labelsTooNarrow = error else {
                return XCTFail("expected labelsTooNarrow, got \(error)")
            }
        }
    }

    func testUnreachableDestinationThrows() throws {
        // Two disconnected 2x2 lattices.
        let lat = [37.78, 37.781, 37.79, 37.791]
        let lon = [-122.41, -122.41, -122.40, -122.40]
        let g = PedestrianGraph(nodeLat: lat, nodeLon: lon,
                                edgeA: [0, 2], edgeB: [1, 3], edgeLen: [100, 100],
                                edgeFlags: [0, 0],
                                bbox: BBox(minLat: 37.77, minLon: -122.42, maxLat: 37.80, maxLon: -122.39))
        XCTAssertThrowsError(try CorridorEngine.labels(graph: g, destination: 3, origin: 0, slack: 0))
    }

    func testNearestNodeSnapping() {
        let g = gridGraph(rows: 5, cols: 5)
        let target = 2 * 5 + 3
        let snapped = g.nearestNode(lat: g.nodeLat[target] + 0.00005, lon: g.nodeLon[target] - 0.00005)
        XCTAssertEqual(snapped, Int32(target))
        XCTAssertNil(g.nearestNode(lat: 38.5, lon: -122.41, maxMeters: 300))
    }

    func testPerformanceOnACityScaleLattice() throws {
        // 200 x 200 = 40k nodes, ~80k edges: same order as a dense SF download.
        let g = gridGraph(rows: 200, cols: 200)
        let origin = Int32(20 * 200 + 20)
        let dest = Int32(120 * 200 + 140)

        let t0 = CFAbsoluteTimeGetCurrent()
        let labels = try CorridorEngine.labels(graph: g, destination: dest, origin: origin, slack: 0.1)
        let labelMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        let t1 = CFAbsoluteTimeGetCurrent()
        let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: 0.1)
        let corridorMs = (CFAbsoluteTimeGetCurrent() - t1) * 1000

        print("labels \(labelMs) ms over \(labels.settledNodes) nodes; corridor \(corridorMs) ms over \(c.nodesExplored) nodes, \(c.edges.count) edges")
        XCTAssertLessThan(labelMs, 1500)
        XCTAssertLessThan(corridorMs, 400)
        XCTAssertLessThan(c.nodesExplored, g.nodeCount)
    }

    func testArrivalWindowsBracketEveryCorridorEdge() throws {
        let cols = 5
        let g = gridGraph(rows: 5, cols: cols)
        let origin = Int32(0), dest = Int32(3 * cols + 2)
        let slack = 0.4
        let labels = try CorridorEngine.labels(graph: g, destination: dest, origin: origin, slack: slack)
        let c = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: slack)
        XCTAssertEqual(c.fromOrigin.count, c.edges.count)
        XCTAssertEqual(c.latestFromOrigin.count, c.edges.count)
        let D = c.distance
        for i in c.edges.indices {
            XCTAssertLessThanOrEqual(c.fromOrigin[i], c.latestFromOrigin[i] + 1e-6)
            XCTAssertGreaterThanOrEqual(c.latestFromOrigin[i] - c.fromOrigin[i], D * slack - c.excess[i] - 1e-5)
            if c.excess[i] < 1e-6 {
                XCTAssertEqual(c.latestFromOrigin[i] - c.fromOrigin[i], D * slack, accuracy: 1e-4)
            }
        }
        // The first edge out of the origin starts at 0 m.
        XCTAssertEqual(c.fromOrigin.min() ?? -1, 0, accuracy: 1e-9)

        // Reusing the scratch must not leak windows from the previous call.
        let scratch = CorridorScratch(graph: g)
        _ = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: slack, scratch: scratch)
        let again = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: slack, scratch: scratch)
        XCTAssertEqual(again.fromOrigin, c.fromOrigin)
        XCTAssertEqual(again.latestFromOrigin, c.latestFromOrigin)
    }
}
