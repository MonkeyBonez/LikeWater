import XCTest
@testable import LikeWaterEngine

final class SunTilesTests: XCTestCase {
    func testDetailFollowsTheScreenSide() {
        XCTAssertEqual(SunLattice.detail(forSide: 900), .streets)
        XCTAssertEqual(SunLattice.detail(forSide: 2_500), .streets)
        XCTAssertEqual(SunLattice.detail(forSide: 2_600), .blocks(level: 0))     // 70 m cells, 37 across
        XCTAssertEqual(SunLattice.detail(forSide: 5_000), .blocks(level: 0))     // 72 across
        XCTAssertEqual(SunLattice.detail(forSide: 8_000), .blocks(level: 1))     // 139 m, 57 across
        XCTAssertEqual(SunLattice.detail(forSide: 30_000), .blocks(level: 3))    // 556 m, 54 across
        XCTAssertEqual(SunLattice.detail(forSide: 80_000), .blocks(level: 4))    // 1.1 km, 72 across
        XCTAssertEqual(SunLattice.detail(forSide: 160_000), .blocks(level: 5))   // 2.2 km, 72 across
        XCTAssertNil(SunLattice.detail(forSide: 170_000))
        // Between 36 and 72 cells across at every zoom.
        for side in stride(from: 2_501.0, through: 160_000, by: 997) {
            guard case .blocks(let l) = SunLattice.detail(forSide: side)! else { return XCTFail() }
            XCTAssertGreaterThanOrEqual(side / SunLattice.cellMetres(level: l, atLatitude: 0), 30, "\(side)")
            XCTAssertLessThanOrEqual(side / SunLattice.cellMetres(level: l, atLatitude: 0), 72, "\(side)")
        }
    }

    func testKeysAreAlignedToTheLatticeNotToTheScreen() {
        let a = BBox(minLat: 37.780, minLon: -122.420, maxLat: 37.790, maxLon: -122.405)
        let b = BBox(minLat: 37.782, minLon: -122.418, maxLat: 37.792, maxLon: -122.403)   // a small pan
        let ka = Set(SunLattice.keys(in: a, detail: .streets)), kb = Set(SunLattice.keys(in: b, detail: .streets))
        XCTAssertFalse(ka.isDisjoint(with: kb), "a small pan must reuse most score tiles")
        XCTAssertGreaterThan(ka.intersection(kb).count * 2, ka.count)
        for k in ka {
            XCTAssertEqual(k.box.maxLat - k.box.minLat, 0.005, accuracy: 1e-12)
            XCTAssertEqual(k.metroTile.i, Int((k.box.centerLat / 0.04).rounded(.down)))
        }
        XCTAssertEqual(SunLattice.keys(in: a, detail: .streets, ring: 1).count,
                       (Set(SunLattice.keys(in: a, detail: .streets).map(\.i)).count + 2) *
                       (Set(SunLattice.keys(in: a, detail: .streets).map(\.j)).count + 2))
        let blocks = SunLattice.keys(in: a, detail: .blocks(level: 1))
        XCTAssertEqual(blocks.count, 1, "a 1 km screen sits in one metro tile")
        XCTAssertEqual(blocks[0].box.maxLon - blocks[0].box.minLon, 0.05, accuracy: 1e-12)
    }

    func testSamplerKeepsTheLongestEdgesPerCellAndWeightsByLength() {
        // A 12×12 grid of 100 m edges, plus one 500 m edge in the first cell.
        let g = gridGraph(rows: 12, cols: 12, spacing: 100)
        let all = Array(0..<Int32(g.edgeCount))
        let cell = SunLattice.cellSize(level: 1)                       // ~139 m
        let picked = SunSampler.sample(graph: g, edges: all, cellLat: cell.lat, cellLon: cell.lon, perCell: 3)
        XCTAssertEqual(picked.edges.count, picked.cells.count)
        let perCell = Dictionary(grouping: picked.cells, by: { $0 }).mapValues(\.count)
        XCTAssertTrue(perCell.values.allSatisfy { $0 <= 3 })
        XCTAssertGreaterThan(perCell.count, 20)
        // Determinism: the same input gives the same sample.
        XCTAssertEqual(picked.edges, SunSampler.sample(graph: g, edges: all, cellLat: cell.lat, cellLon: cell.lon, perCell: 3).edges)
        // The cap lowers the per-cell count but keeps every cell.
        let capped = SunSampler.sample(graph: g, edges: all, cellLat: cell.lat, cellLon: cell.lon, perCell: 3, cap: perCell.count * 2)
        XCTAssertEqual(Set(capped.cells).count, perCell.count)
        XCTAssertLessThanOrEqual(capped.edges.count, perCell.count * 2)
        // Cells: a 100 m sunny edge and a 100 m shaded one average 0.5; lengths weight it.
        let scores = picked.edges.map { Float(Int($0) % 2) }
        let cells = SunSampler.cells(graph: g, sampled: picked.edges, cellKeys: picked.cells, scores: scores,
                                     cellLat: cell.lat, cellLon: cell.lon)
        XCTAssertEqual(cells.count, perCell.count)
        for c in cells {
            XCTAssertGreaterThanOrEqual(c.sun, 0); XCTAssertLessThanOrEqual(c.sun, 1)
            XCTAssertEqual(c.box.maxLat - c.box.minLat, cell.lat, accuracy: 1e-12)
        }
        XCTAssertEqual(SunCell(box: cells[0].box, sun: 0.99, sampled: 1, metres: 1).level(of: 8), 7)
        XCTAssertEqual(SunCell(box: cells[0].box, sun: 0.0, sampled: 1, metres: 1).level(of: 8), 0)
    }
}
