import XCTest
@testable import LikeWaterEngine

/// What changed to make New York, Los Angeles and Seattle work: tiles that stitch,
/// shadows as long as the tallest tower, mountains outside the loaded tiles,
/// islands that stay walkable, and a corridor that doesn't allocate the city per fix.
final class ScaleTests: XCTestCase {

    // MARK: - Stitching

    /// A lattice cut into tiles exactly as the pipeline cuts it (each edge to the tile
    /// of its midpoint, end nodes carried with global ids) must stitch back into the
    /// same graph: same node and edge counts, same shortest distance corner to corner.
    func testTilesStitchBackIntoTheSameGraph() throws {
        let rows = 24, cols = 24
        var lat: [Double] = [], lon: [Double] = []
        for i in 0..<rows { for j in 0..<cols { lat.append(40.70 + Double(i) * 0.0009); lon.append(-74.00 + Double(j) * 0.0012) } }
        var a: [Int32] = [], b: [Int32] = [], len: [Double] = []
        for i in 0..<rows {
            for j in 0..<cols {
                let n = Int32(i * cols + j)
                if j + 1 < cols { a.append(n); b.append(n + 1); len.append(100 + Double((i * 7 + j) % 5)) }
                if i + 1 < rows { a.append(n); b.append(n + Int32(cols)); len.append(100 + Double((i + j * 3) % 7)) }
            }
        }
        let box = BBox(minLat: lat.min()!, minLon: lon.min()!, maxLat: lat.max()!, maxLon: lon.max()!)
        let whole = PedestrianGraph(nodeLat: lat, nodeLon: lon, edgeA: a, edgeB: b, edgeLen: len, bbox: box)

        // Cut on a 0.006° lattice (4 x 4 tiles here).
        let tLat = 0.006, tLon = 0.008
        var groups: [String: [Int]] = [:]
        for e in 0..<a.count {
            let mLat = (lat[Int(a[e])] + lat[Int(b[e])]) / 2, mLon = (lon[Int(a[e])] + lon[Int(b[e])]) / 2
            groups["\(Int(floor(mLat / tLat)))_\(Int(floor(mLon / tLon)))", default: []].append(e)
        }
        XCTAssertGreaterThan(groups.count, 4)
        var tiles: [RawBundle] = []
        for (_, edges) in groups {
            let gids = Array(Set(edges.flatMap { [a[$0], b[$0]] })).sorted()
            let local = Dictionary(uniqueKeysWithValues: gids.enumerated().map { ($1, Int32($0)) })
            let tl = gids.map { lat[Int($0)] }, tn = gids.map { lon[Int($0)] }
            tiles.append(RawBundle(
                version: 3, bbox: BBox(minLat: tl.min()!, minLon: tn.min()!, maxLat: tl.max()!, maxLon: tn.max()!),
                nodeLat: tl, nodeLon: tn, nodeGlobalId: gids.map { UInt32($0) },
                adjStart: [], adjNode: [], adjEdge: [],
                edgeA: edges.map { local[a[$0]]! }, edgeB: edges.map { local[b[$0]]! },
                edgeLen: edges.map { len[$0] },
                edgeFlags: [UInt8](repeating: 0, count: edges.count),
                edgeInterest: [UInt8](repeating: 0, count: edges.count),
                bldStart: [0], bldLat: [], bldLon: [], bldHeight: [], bldGround: [], terrain: nil))
        }
        let stitched = try TileStitcher.stitch(tiles.shuffled())
        let g = stitched.graph
        XCTAssertEqual(g.nodeCount, whole.nodeCount)
        XCTAssertEqual(g.edgeCount, whole.edgeCount)
        XCTAssertEqual(g.componentSizes.count, 1, "stitching must not leave seams")

        func distance(_ graph: PedestrianGraph, from: (Double, Double), to: (Double, Double)) throws -> Double {
            let o = graph.nearestNode(lat: from.0, lon: from.1)!, d = graph.nearestNode(lat: to.0, lon: to.1)!
            return try CorridorEngine.labels(graph: graph, destination: d, origin: o, slack: 0).seedDistance
        }
        let p = (lat[0], lon[0]), q = (lat[lat.count - 1], lon[lon.count - 1])
        XCTAssertEqual(try distance(g, from: p, to: q), try distance(whole, from: p, to: q), accuracy: 1e-6)
    }

    func testStitchingRefusesSingleCityBundles() throws {
        let url = try XCTUnwrap(Bundle.module.url(forResource: "tiny", withExtension: "lwbundle", subdirectory: "Fixtures"))
        XCTAssertThrowsError(try TileStitcher.stitch([try RawBundle(contentsOf: url)]))
    }

    /// Two tile grids on one lattice mosaic by integer offsets; a gap between them is
    /// filled from the far-field grid rather than left at zero.
    func testTerrainMosaicAlignsAndFillsGapsFromTheFarField() throws {
        let sLat = 10 / 111_320.0, sLon = 10 / (111_320.0 * cos(40.7 * .pi / 180))
        func grid(row: Int, col: Int, rows: Int, cols: Int, value: Int16) -> TerrainGrid {
            TerrainGrid(rows: rows, cols: cols, originLat: Double(row) * sLat, originLon: Double(col) * sLon,
                        stepLat: sLat, stepLon: sLon, elevation: [Int16](repeating: value, count: rows * cols))
        }
        let r0 = Int(40.70 / sLat), c0 = Int(-74.00 / sLon)
        let left = grid(row: r0, col: c0, rows: 10, cols: 10, value: 5)
        let right = grid(row: r0, col: c0 + 20, rows: 10, cols: 10, value: 7)
        let far = TerrainGrid(rows: 3, cols: 3, originLat: 40.6, originLon: -74.1, stepLat: 0.2, stepLon: 0.2,
                              elevation: [Int16](repeating: 42, count: 9))
        let m = try XCTUnwrap(TileStitcher.mosaic([left, right], far: far))
        XCTAssertEqual(m.cols, 30); XCTAssertEqual(m.rows, 10)
        XCTAssertEqual(m.elevation(lat: Double(r0 + 5) * sLat, lon: Double(c0 + 5) * sLon), 5, accuracy: 1e-6)
        XCTAssertEqual(m.elevation(lat: Double(r0 + 5) * sLat, lon: Double(c0 + 25) * sLon), 7, accuracy: 1e-6)
        XCTAssertEqual(m.elevation(lat: Double(r0 + 5) * sLat, lon: Double(c0 + 15) * sLon), 42, accuracy: 1e-6,
                       "the gap between tiles is water or missing data: far field, not zero")
    }

    // MARK: - Shadow reach

    private static let plane = LocalPlane(originLat: 40.75, originLon: -73.98)
    private func box(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double, height: Float,
                     terrain: TerrainGrid? = nil) -> BuildingStore {
        var lat: [Double] = [], lon: [Double] = []
        for (x, y) in [(x0, y0), (x1, y0), (x1, y1), (x0, y1)] {
            let p = Self.plane.unproject(x: x, y: y); lat.append(p.lat); lon.append(p.lon)
        }
        let bb = BBox(minLat: 40.70, minLon: -74.05, maxLat: 40.80, maxLon: -73.91)
        return BuildingStore(start: [0, 4], lat: lat, lon: lon, height: [height], ground: [0],
                             terrain: terrain, bbox: bb)
    }

    /// A 430 m tower (Central Park Tower-sized) 600 m south of a point, sun due south
    /// at 30°: 430/600 = 0.72 > tan 30° = 0.58, so the point is in its shadow. The old
    /// fixed 100 m search stopped at 173 m and called it sunny.
    func testSupertallShadowReachesHundredsOfMetres() {
        let store = box(-20, -620, 20, -600, height: 430)
        let origin = Self.plane.project(lat: 40.75, lon: -73.98)
        var v = [Int32](repeating: -1, count: 1)
        let tan30 = tan(30 * Double.pi / 180)
        XCTAssertTrue(store.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180, tanElevation: tan30,
                                     visited: &v, stamp: 1))
        XCTAssertFalse(store.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180, tanElevation: tan30,
                                      maxHeight: 100, visited: &v, stamp: 2),
                       "capping the search at 100 m reproduces the old miss")
        XCTAssertFalse(store.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180,
                                      tanElevation: tan(40 * Double.pi / 180), visited: &v, stamp: 3),
                       "at 40° the same tower falls short (0.72 < 0.84)")
    }

    /// Flat 10 m tiles around the walker; a 900 m ridge 8 km south exists only in the
    /// far-field grid. With the sun at 5° (tan = 0.087; 900/8000 = 0.11) the ridge
    /// shades; without the far field it cannot, and the old 3 km cap never looked.
    func testMountainOutsideTheTilesShadesThroughTheFarField() {
        let sLat = 10 / 111_320.0, sLon = 10 / (111_320.0 * cos(40.75 * .pi / 180))
        let fine = TerrainGrid(rows: 200, cols: 200, originLat: 40.75 - 100 * sLat, originLon: -73.98 - 100 * sLon,
                               stepLat: sLat, stepLon: sLon, elevation: [Int16](repeating: 0, count: 40_000))
        let fLat = 100 / 111_320.0, fLon = 100 / (111_320.0 * cos(40.75 * .pi / 180))
        var cells = [Int16](repeating: 0, count: 200 * 200)
        let farOriginLat = 40.75 - 100 * fLat
        for r in 0..<200 {
            let lat = farOriginLat + Double(r) * fLat
            let southMetres = (40.75 - lat) * 111_320
            if southMetres > 7_900 && southMetres < 8_300 { for c in 0..<200 { cells[r * 200 + c] = 900 } }
        }
        let far = TerrainGrid(rows: 200, cols: 200, originLat: farOriginLat, originLon: -73.98 - 100 * fLon,
                              stepLat: fLat, stepLon: fLon, elevation: cells)
        let origin = Self.plane.project(lat: 40.75, lon: -73.98)
        let tan5 = tan(5 * Double.pi / 180)
        var v = [Int32](repeating: -1, count: 1)

        fine.fallback = far
        let withFar = box(5000, 5000, 5010, 5010, height: 5, terrain: fine)
        XCTAssertTrue(withFar.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180, tanElevation: tan5,
                                       visited: &v, stamp: 1))
        XCTAssertFalse(withFar.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180,
                                        tanElevation: tan(8 * Double.pi / 180), visited: &v, stamp: 2),
                       "at 8° the ridge (0.11 < 0.14) is below the sun line")

        let flatOnly = TerrainGrid(rows: 200, cols: 200, originLat: fine.originLat, originLon: fine.originLon,
                                   stepLat: sLat, stepLon: sLon, elevation: [Int16](repeating: 0, count: 40_000))
        let without = box(5000, 5000, 5010, 5010, height: 5, terrain: flatOnly)
        XCTAssertFalse(without.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180, tanElevation: tan5,
                                        visited: &v, stamp: 3))
    }

    /// Past the edge of every grid there is no ground: a high last row must not be
    /// extended into a plateau that shades from kilometres away.
    func testNoPhantomPlateauPastTheGridEdge() {
        let sLat = 10 / 111_320.0, sLon = 10 / (111_320.0 * cos(40.75 * .pi / 180))
        var cells = [Int16](repeating: 0, count: 100 * 100)
        for c in 0..<500 { cells[c] = 60 }          // southern 5 rows at 60 m, 450-500 m away
        let g = TerrainGrid(rows: 100, cols: 100, originLat: 40.75 - 50 * sLat, originLon: -73.98 - 50 * sLon,
                            stepLat: sLat, stepLon: sLon, elevation: cells)
        let store = box(5000, 5000, 5010, 5010, height: 5, terrain: g)
        let origin = Self.plane.project(lat: 40.75, lon: -73.98)
        var v = [Int32](repeating: -1, count: 1)
        // 60 m at ~460 m is tan 0.13 (~7.4°). At 4° it genuinely shades; at 8° it does not,
        // and a clamped edge would have kept "seeing" 60 m out to 3 km and beyond.
        XCTAssertTrue(store.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180,
                                     tanElevation: tan(4 * Double.pi / 180), visited: &v, stamp: 1))
        XCTAssertFalse(store.isShaded(x: origin.x, y: origin.y, azimuthDegrees: 180,
                                      tanElevation: tan(8 * Double.pi / 180), visited: &v, stamp: 2))
        XCTAssertNil(g.sample(x: origin.x, y: origin.y - 2_000))
    }

    // MARK: - Graph

    /// An island of 400 nodes (Staten Island in miniature) is a street network of its
    /// own: a walker there snaps onto it, not onto the bigger component 5 km away.
    func testWalkerOnAnIslandSnapsToTheIsland() {
        var lat: [Double] = [], lon: [Double] = [], a: [Int32] = [], b: [Int32] = [], len: [Double] = []
        func chain(count: Int, lat0: Double, lon0: Double) {
            let base = Int32(lat.count)
            for k in 0..<count { lat.append(lat0); lon.append(lon0 + Double(k) * 0.0001) }
            for k in 0..<(count - 1) { a.append(base + Int32(k)); b.append(base + Int32(k) + 1); len.append(8.4) }
        }
        chain(count: 1000, lat0: 40.70, lon0: -74.00)       // "Brooklyn"
        chain(count: 400, lat0: 40.60, lon0: -74.10)        // "Staten Island"
        let box = BBox(minLat: 40.59, minLon: -74.11, maxLat: 40.71, maxLon: -73.89)
        let g = PedestrianGraph(nodeLat: lat, nodeLon: lon, edgeA: a, edgeB: b, edgeLen: len, bbox: box)
        XCTAssertEqual(g.componentSizes.sorted(), [400, 1000])
        let n = g.nearestConnectedNode(lat: 40.6001, lon: -74.09)
        XCTAssertNotNil(n)
        XCTAssertGreaterThanOrEqual(Int(n!), 1000, "snapped onto the island")
    }

    /// Reusing scratch memory across location updates gives exactly the same corridor.
    func testCorridorScratchReuseMatchesFreshRuns() throws {
        var lat: [Double] = [], lon: [Double] = [], a: [Int32] = [], b: [Int32] = [], len: [Double] = []
        let n = 30
        for i in 0..<n { for j in 0..<n { lat.append(40.7 + Double(i) * 0.0009); lon.append(-74 + Double(j) * 0.0012) } }
        for i in 0..<n { for j in 0..<n {
            let k = Int32(i * n + j)
            if j + 1 < n { a.append(k); b.append(k + 1); len.append(100 + Double((i + 2 * j) % 3)) }
            if i + 1 < n { a.append(k); b.append(k + Int32(n)); len.append(100 + Double((2 * i + j) % 4)) }
        } }
        let box = BBox(minLat: 40.7, minLon: -74, maxLat: 40.75, maxLon: -73.96)
        let g = PedestrianGraph(nodeLat: lat, nodeLon: lon, edgeA: a, edgeB: b, edgeLen: len, bbox: box)
        let dest = Int32(n * n - 1)
        let labels = try CorridorEngine.labels(graph: g, destination: dest, origin: 0, slack: 0.5)
        let scratch = CorridorScratch(graph: g)
        for origin in [Int32(0), 31, 62, 5, 400, 0] {
            let fresh = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: 0.2)
            let reused = try CorridorEngine.corridor(graph: g, labels: labels, origin: origin, slack: 0.2, scratch: scratch)
            XCTAssertEqual(Set(fresh.edges), Set(reused.edges), "origin \(origin)")
            XCTAssertEqual(fresh.distance, reused.distance)
            XCTAssertEqual(fresh.choicesHere, reused.choicesHere)
        }
    }

    /// The sun field scores what is on screen: every edge touching the box, none far outside.
    func testEdgesInABoxAreExactlyThoseTouchingIt() {
        var lat: [Double] = [], lon: [Double] = [], a: [Int32] = [], b: [Int32] = [], len: [Double] = []
        let n = 40
        for i in 0..<n { for j in 0..<n { lat.append(40.7 + Double(i) * 0.0009); lon.append(-74 + Double(j) * 0.0012) } }
        for i in 0..<n { for j in 0..<n {
            let k = Int32(i * n + j)
            if j + 1 < n { a.append(k); b.append(k + 1); len.append(100) }
            if i + 1 < n { a.append(k); b.append(k + Int32(n)); len.append(100) }
        } }
        let g = PedestrianGraph(nodeLat: lat, nodeLon: lon, edgeA: a, edgeB: b, edgeLen: len,
                                bbox: BBox(minLat: 40.7, minLon: -74, maxLat: 40.74, maxLon: -73.95))
        let box = BBox(minLat: 40.705, minLon: -73.99, maxLat: 40.72, maxLon: -73.975)   // tall, narrow
        let got = Set(g.edges(in: box))
        let want = Set((0..<a.count).filter { e in
            [a[e], b[e]].contains { box.contains(lat: lat[Int($0)], lon: lon[Int($0)]) }
        }.map { Int32($0) })
        XCTAssertEqual(got, want)
        XCTAssertGreaterThan(got.count, 100)
    }
}
