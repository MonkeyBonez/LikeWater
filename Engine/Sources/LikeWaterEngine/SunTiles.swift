import Foundation

/// How much of the sidewalk network a sun field shows, by zoom.
public enum SunDetail: Hashable, Sendable, CustomStringConvertible {
    /// Every sidewalk edge, coloured by its own sun (screens up to ~2 km).
    case streets
    /// Sun by block: cells of `SunLattice.blockDivs[level]` per metro tile side, coloured
    /// by the sunny share of the sidewalk metres sampled in them.
    case blocks(level: Int)

    public var isBlocks: Bool { if case .blocks = self { return true }; return false }
    public var description: String {
        switch self {
        case .streets: return "streets"
        case .blocks(let l): return "blocks\(l)"
        }
    }
}

/// A fixed lattice the sun is scored on, so panning reuses what is already scored and
/// two phones (or two zooms) agree on where a block begins. It is the metro tile lattice
/// (`Pipeline/build_metro.py`: 0.04° × 0.05°) and subdivisions of it.
public enum SunLattice {
    public static let metroTileLat = 0.04
    public static let metroTileLon = 0.05
    /// Street-detail score tiles are 1/8 of a metro tile: ~550 × 490 m.
    public static let streetDiv = 8
    /// Cells per metro tile side at each block level: ~70 m, 140 m, 280 m, 560 m, 1.1 km,
    /// 2.2 km, 4.4 km (a whole metro tile).
    public static let blockDivs = [64, 32, 16, 8, 4, 2, 1]
    /// Street detail up to this screen side (the visible map, not the scored margin);
    /// blocks beyond; nothing past `maxSideMetres`.
    public static let streetsMaxSideMetres = 2_500.0
    public static let maxSideMetres = 160_000.0
    /// The finest block level with at most this many cells across the screen (so 36–72).
    public static let maxCellsAcross = 72.0

    /// Degrees per score tile at a detail level: street tiles, or whole metro tiles for blocks.
    public static func tileSize(_ detail: SunDetail) -> (lat: Double, lon: Double) {
        switch detail {
        case .streets: return (metroTileLat / Double(streetDiv), metroTileLon / Double(streetDiv))
        case .blocks: return (metroTileLat, metroTileLon)
        }
    }

    /// Degrees per cell of a block level.
    public static func cellSize(level: Int) -> (lat: Double, lon: Double) {
        let d = Double(blockDivs[min(max(level, 0), blockDivs.count - 1)])
        return (metroTileLat / d, metroTileLon / d)
    }

    public static func cellMetres(level: Int, atLatitude lat: Double) -> Double {
        cellSize(level: level).lat * 111_320
    }

    /// The detail for a screen `sideMetres` across; nil when zoomed out too far to show.
    public static func detail(forSide sideMetres: Double) -> SunDetail? {
        if sideMetres <= streetsMaxSideMetres { return .streets }
        guard sideMetres <= maxSideMetres else { return nil }
        for level in blockDivs.indices where cellMetres(level: level, atLatitude: 0) >= sideMetres / maxCellsAcross {
            return .blocks(level: level)
        }
        return .blocks(level: blockDivs.count - 1)
    }

    public static func key(_ detail: SunDetail, lat: Double, lon: Double) -> SunTileKey {
        let s = tileSize(detail)
        return SunTileKey(detail: detail, i: Int((lat / s.lat).rounded(.down)), j: Int((lon / s.lon).rounded(.down)))
    }

    /// Every score tile intersecting a box.
    public static func keys(in box: BBox, detail: SunDetail) -> [SunTileKey] {
        let s = tileSize(detail)
        let i0 = Int((box.minLat / s.lat).rounded(.down)), i1 = Int((box.maxLat / s.lat).rounded(.down))
        let j0 = Int((box.minLon / s.lon).rounded(.down)), j1 = Int((box.maxLon / s.lon).rounded(.down))
        var out: [SunTileKey] = []
        for i in i0...i1 { for j in j0...j1 { out.append(SunTileKey(detail: detail, i: i, j: j)) } }
        return out
    }

    /// `keys(in:)` widened by `ring` tiles on every side: what to score ahead of a pan.
    public static func keys(in box: BBox, detail: SunDetail, ring: Int) -> [SunTileKey] {
        let s = tileSize(detail)
        let wide = BBox(minLat: box.minLat - Double(ring) * s.lat, minLon: box.minLon - Double(ring) * s.lon,
                        maxLat: box.maxLat + Double(ring) * s.lat, maxLon: box.maxLon + Double(ring) * s.lon)
        return keys(in: wide, detail: detail)
    }
}

/// One score tile of one detail level.
public struct SunTileKey: Hashable, Sendable, CustomStringConvertible {
    public var detail: SunDetail
    public var i: Int
    public var j: Int
    public init(detail: SunDetail, i: Int, j: Int) { self.detail = detail; self.i = i; self.j = j }

    public var box: BBox {
        let s = SunLattice.tileSize(detail)
        return BBox(minLat: Double(i) * s.lat, minLon: Double(j) * s.lon,
                    maxLat: Double(i + 1) * s.lat, maxLon: Double(j + 1) * s.lon)
    }
    /// The metro tile this score tile lies in (itself, for block tiles).
    public var metroTile: (i: Int, j: Int) {
        switch detail {
        case .streets: return (Int((Double(i) / Double(SunLattice.streetDiv)).rounded(.down)),
                               Int((Double(j) / Double(SunLattice.streetDiv)).rounded(.down)))
        case .blocks: return (i, j)
        }
    }
    public var description: String { "\(detail)/\(i)/\(j)" }
}

/// One block of a zoomed-out sun field.
public struct SunCell: Sendable, Equatable {
    public var box: BBox
    /// Sunny share of the sidewalk metres sampled in the cell, 0…1.
    public var sun: Float
    public var sampled: Int
    public var metres: Double
    public init(box: BBox, sun: Float, sampled: Int, metres: Double) {
        self.box = box; self.sun = sun; self.sampled = sampled; self.metres = metres
    }
    /// 0…levels−1, for grouping cells of one colour into one overlay.
    public func level(of levels: Int) -> Int { min(levels - 1, Int(sun * Float(levels))) }
}

/// Picks the edges that stand for a block: the longest few per cell, which is close to
/// length-weighted sampling and deterministic, so a redraw never flickers.
public enum SunSampler {
    public static let perCell = 12

    /// Returns the sampled edge ids and, parallel, each one's cell key `(row << 32 | col)`.
    public static func sample(graph: PedestrianGraph, edges: [Int32], cellLat: Double, cellLon: Double,
                              perCell: Int = perCell, cap: Int = 6_000) -> (edges: [Int32], cells: [Int64]) {
        var top: [Int64: [(len: Double, e: Int32)]] = [:]
        for e in edges {
            let ei = Int(e)
            let a = Int(graph.edgeA[ei]), b = Int(graph.edgeB[ei])
            let lat = (graph.nodeLat[a] + graph.nodeLat[b]) / 2, lon = (graph.nodeLon[a] + graph.nodeLon[b]) / 2
            let key = cellKey(row: Int((lat / cellLat).rounded(.down)), col: Int((lon / cellLon).rounded(.down)))
            let len = graph.edgeLen[ei]
            var list = top[key] ?? []
            if list.count < perCell {
                list.append((len, e)); list.sort { $0.len > $1.len }
            } else if len > list[list.count - 1].len {
                list[list.count - 1] = (len, e); list.sort { $0.len > $1.len }
            } else { continue }
            top[key] = list
        }
        var outEdges: [Int32] = [], outCells: [Int64] = []
        // Over the cap: fewer per cell, every cell still represented.
        let total = top.values.reduce(0) { $0 + $1.count }
        let keep = total > cap ? max(2, perCell * cap / max(total, 1)) : perCell
        for (key, list) in top.sorted(by: { $0.key < $1.key }) {
            for (_, e) in list.prefix(keep) { outEdges.append(e); outCells.append(key) }
        }
        return (outEdges, outCells)
    }

    @inline(__always) public static func cellKey(row: Int, col: Int) -> Int64 {
        (Int64(row) << 32) | Int64(UInt32(truncatingIfNeeded: col))
    }

    public static func cellRowCol(_ key: Int64) -> (row: Int, col: Int) {
        (Int(key >> 32), Int(Int32(truncatingIfNeeded: key & 0xffff_ffff)))
    }

    /// Length-weighted mean sun per cell from the sampled edges' scores.
    public static func cells(graph: PedestrianGraph, sampled: [Int32], cellKeys: [Int64], scores: [Float],
                             cellLat: Double, cellLon: Double) -> [SunCell] {
        var acc: [Int64: (sun: Double, metres: Double, n: Int)] = [:]
        for k in sampled.indices {
            let len = graph.edgeLen[Int(sampled[k])]
            var a = acc[cellKeys[k]] ?? (0, 0, 0)
            a.sun += Double(scores[k]) * len; a.metres += len; a.n += 1
            acc[cellKeys[k]] = a
        }
        return acc.sorted { $0.key < $1.key }.map { key, a in
            let (row, col) = cellRowCol(key)
            return SunCell(box: BBox(minLat: Double(row) * cellLat, minLon: Double(col) * cellLon,
                                     maxLat: Double(row + 1) * cellLat, maxLon: Double(col + 1) * cellLon),
                           sun: Float(a.metres > 0 ? a.sun / a.metres : 0), sampled: a.n, metres: a.metres)
        }
    }
}
