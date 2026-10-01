import Foundation

public enum StitchError: Error, LocalizedError {
    case noTiles
    case notTiles
    case terrainLatticeMismatch

    public var errorDescription: String? {
        switch self {
        case .noTiles: return "No map tiles to stitch."
        case .notTiles: return "Only version 3 tile bundles can be stitched."
        case .terrainLatticeMismatch: return "Tiles do not share one terrain lattice."
        }
    }
}

/// Joins neighbouring metro tiles into one `CityBundle`.
///
/// The pipeline puts every edge in exactly one tile (the one holding its midpoint)
/// and ships each edge's end nodes with their metro-wide ids, so an edge that crosses
/// a tile boundary has one end node present in both tiles. Stitching is therefore a
/// union of nodes by id and a concatenation of edges and buildings — no geometry is
/// matched, nothing can be duplicated, and the result is exactly the metro graph
/// restricted to the chosen tiles. Terrain grids sit on one shared lattice and are
/// mosaicked by integer offsets; any cell no tile covers (open water) falls back to
/// the coarse far-field grid.
public enum TileStitcher {

    public static func stitch(_ tiles: [RawBundle], farTerrain: TerrainGrid? = nil) throws -> CityBundle {
        guard !tiles.isEmpty else { throw StitchError.noTiles }
        guard tiles.allSatisfy({ $0.version >= 3 }) else { throw StitchError.notTiles }

        var bbox = tiles[0].bbox
        for t in tiles.dropFirst() {
            bbox.minLat = min(bbox.minLat, t.bbox.minLat); bbox.minLon = min(bbox.minLon, t.bbox.minLon)
            bbox.maxLat = max(bbox.maxLat, t.bbox.maxLat); bbox.maxLon = max(bbox.maxLon, t.bbox.maxLon)
        }

        // --- nodes, by global id -----------------------------------------------------
        let totalNodes = tiles.reduce(0) { $0 + $1.nodeCount }
        var index = [UInt32: Int32](minimumCapacity: totalNodes)
        var nodeLat: [Double] = []; nodeLat.reserveCapacity(totalNodes)
        var nodeLon: [Double] = []; nodeLon.reserveCapacity(totalNodes)
        var localToStitched: [[Int32]] = []
        for t in tiles {
            var map = [Int32](repeating: 0, count: t.nodeCount)
            for i in 0..<t.nodeCount {
                let gid = t.nodeGlobalId[i]
                if let existing = index[gid] {
                    map[i] = existing
                } else {
                    let n = Int32(nodeLat.count)
                    index[gid] = n
                    nodeLat.append(t.nodeLat[i]); nodeLon.append(t.nodeLon[i])
                    map[i] = n
                }
            }
            localToStitched.append(map)
        }

        // --- edges ------------------------------------------------------------------------
        let totalEdges = tiles.reduce(0) { $0 + $1.edgeCount }
        var edgeA: [Int32] = [], edgeB: [Int32] = [], edgeLen: [Double] = []
        var edgeFlags: [UInt8] = [], edgeInterest: [UInt8] = []
        edgeA.reserveCapacity(totalEdges); edgeB.reserveCapacity(totalEdges)
        edgeLen.reserveCapacity(totalEdges); edgeFlags.reserveCapacity(totalEdges)
        edgeInterest.reserveCapacity(totalEdges)
        for (k, t) in tiles.enumerated() {
            let map = localToStitched[k]
            for e in 0..<t.edgeCount {
                edgeA.append(map[Int(t.edgeA[e])]); edgeB.append(map[Int(t.edgeB[e])])
            }
            edgeLen += t.edgeLen; edgeFlags += t.edgeFlags; edgeInterest += t.edgeInterest
        }

        // --- buildings ----------------------------------------------------------------------
        var bldStart: [Int32] = [0]
        var bldLat: [Double] = [], bldLon: [Double] = []
        var bldHeight: [Float] = [], bldGround: [Float] = []
        for t in tiles {
            let base = Int32(bldLat.count)
            for b in 1..<t.bldStart.count { bldStart.append(base + t.bldStart[b]) }
            bldLat += t.bldLat; bldLon += t.bldLon
            bldHeight += t.bldHeight; bldGround += t.bldGround
        }

        // --- terrain --------------------------------------------------------------------------
        let terrain = try mosaic(tiles.compactMap(\.terrain), far: farTerrain)

        let graph = PedestrianGraph(nodeLat: nodeLat, nodeLon: nodeLon,
                                    edgeA: edgeA, edgeB: edgeB, edgeLen: edgeLen,
                                    edgeFlags: edgeFlags, edgeInterest: edgeInterest, bbox: bbox)
        let buildings = BuildingStore(start: bldStart, lat: bldLat, lon: bldLon,
                                      height: bldHeight, ground: bldGround,
                                      terrain: terrain, bbox: bbox)
        return CityBundle(graph: graph, buildings: buildings, terrain: terrain, bbox: bbox, version: 3)
    }

    /// One grid over all tile grids, which must share step and lattice.
    static func mosaic(_ grids: [TerrainGrid], far: TerrainGrid?) throws -> TerrainGrid? {
        guard let first = grids.first else { return far }
        let sLat = first.stepLat, sLon = first.stepLon
        for g in grids where abs(g.stepLat - sLat) > 1e-12 || abs(g.stepLon - sLon) > 1e-12 {
            throw StitchError.terrainLatticeMismatch
        }
        func row(_ g: TerrainGrid) -> Int { Int((g.originLat / sLat).rounded()) }
        func col(_ g: TerrainGrid) -> Int { Int((g.originLon / sLon).rounded()) }
        let r0 = grids.map(row).min()!, c0 = grids.map(col).min()!
        let r1 = grids.map { row($0) + $0.rows - 1 }.max()!
        let c1 = grids.map { col($0) + $0.cols - 1 }.max()!
        let rows = r1 - r0 + 1, cols = c1 - c0 + 1
        let originLat = Double(r0) * sLat, originLon = Double(c0) * sLon

        let missing = Int16.min
        var cells = [Int16](repeating: missing, count: rows * cols)
        for g in grids {
            let gr = row(g) - r0, gc = col(g) - c0
            g.cells.withUnsafeBufferPointer { src in
                for r in 0..<g.rows {
                    let dst = (gr + r) * cols + gc
                    for c in 0..<g.cols { cells[dst + c] = src[r * g.cols + c] }
                }
            }
        }
        // Cells no tile covers: sample the far field (or sea level).
        if cells.contains(missing) {
            for r in 0..<rows {
                for c in 0..<cols where cells[r * cols + c] == missing {
                    let lat = originLat + Double(r) * sLat, lon = originLon + Double(c) * sLon
                    cells[r * cols + c] = Int16(clamping: Int((far?.elevation(lat: lat, lon: lon) ?? 0).rounded()))
                }
            }
        }
        let grid = TerrainGrid(rows: rows, cols: cols, originLat: originLat, originLon: originLon,
                               stepLat: sLat, stepLon: sLon, elevation: cells)
        grid.fallback = far
        return grid
    }
}
