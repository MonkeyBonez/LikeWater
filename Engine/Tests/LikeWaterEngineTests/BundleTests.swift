import XCTest
@testable import LikeWaterEngine

/// Contract test for the binary bundle: the fixture is written by the real Python
/// writer in Pipeline/, so this checks the two sides of the format agree.
final class BundleTests: XCTestCase {

    private func tinyBundle() throws -> CityBundle {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tiny", withExtension: "lwbundle",
                                                  subdirectory: "Fixtures"))
        return try CityBundle(contentsOf: url)
    }

    func testReadsWhatThePipelineWrote() throws {
        let bundle = try tinyBundle()
        let g = bundle.graph
        XCTAssertEqual(g.nodeCount, 4)
        XCTAssertEqual(g.edgeCount, 4)
        XCTAssertEqual(bundle.buildings.count, 1)
        XCTAssertEqual(bundle.buildings.heightOf(0), 30, accuracy: 0.001)

        // Fixed-point coordinates survive the round trip to 1e-7 degrees.
        XCTAssertEqual(g.nodeLat[0], 37.7800, accuracy: 1e-7)
        XCTAssertEqual(g.nodeLon[0], -122.4100, accuracy: 1e-7)

        XCTAssertEqual(g.edgeLen[0], 60, accuracy: 0.01)
        XCTAssertTrue(g.isSidewalk(0))
        XCTAssertFalse(g.isCrossing(0))
        XCTAssertTrue(g.isCrossing(1))
        XCTAssertEqual(g.edgeInterest, [0, 4, 9, 255])
    }

    func testCSRAdjacencyIsUsableForTraversal() throws {
        let g = try tinyBundle().graph
        // Square: every node has exactly two neighbours and one component.
        for n in 0..<g.nodeCount {
            let degree = Int(g.adjStart[n + 1] - g.adjStart[n])
            XCTAssertEqual(degree, 2, "node \(n)")
        }
        XCTAssertEqual(g.componentSizes, [4])

        let labels = try CorridorEngine.labels(graph: g, destination: 2, origin: 0, slack: 0.5)
        XCTAssertEqual(labels.seedDistance, 120, accuracy: 0.01)
        let corridor = try CorridorEngine.corridor(graph: g, labels: labels, origin: 0, slack: 0.0)
        // Both ways round the square are exactly 120 m, so both are in the corridor.
        XCTAssertEqual(corridor.edges.count, 4)
        XCTAssertEqual(corridor.choicesHere, 2)
        XCTAssertEqual(corridor.crossingEdges, [1])
    }

    func testVersion2CarriesTerrainAndBuildingGround() throws {
        let bundle = try tinyBundle()
        XCTAssertEqual(bundle.version, 2)
        let terrain = try XCTUnwrap(bundle.terrain)
        XCTAssertEqual(terrain.rows, 4)
        XCTAssertEqual(terrain.cols, 4)
        // Flat at 5 m in the south-west, a 45 m hill in the north-east corner.
        XCTAssertEqual(terrain.elevation(lat: 37.7790, lon: -122.4110), 5, accuracy: 0.01)
        let ne = (lat: 37.7790 + 3 * terrain.stepLat, lon: -122.4110 + 3 * terrain.stepLon)
        XCTAssertEqual(terrain.elevation(lat: ne.lat, lon: ne.lon), 45, accuracy: 0.01)
        // Halfway up the hill flank interpolates.
        let mid = terrain.elevation(lat: 37.7790 + 2.5 * terrain.stepLat, lon: -122.4110 + 2.5 * terrain.stepLon)
        XCTAssertGreaterThan(mid, 5); XCTAssertLessThan(mid, 45)
        XCTAssertEqual(bundle.buildings.groundOf(0), 5, accuracy: 0.001)
    }

    func testRejectsGarbage() {
        XCTAssertThrowsError(try CityBundle(data: Data(repeating: 0, count: 64))) { error in
            guard case BundleError.badMagic = error else { return XCTFail("got \(error)") }
        }
        XCTAssertThrowsError(try CityBundle(data: Data("LWB1".utf8))) { error in
            guard case BundleError.truncated = error else { return XCTFail("got \(error)") }
        }
    }
}
