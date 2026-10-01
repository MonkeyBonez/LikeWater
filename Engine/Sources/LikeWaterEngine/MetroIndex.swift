import Foundation

/// `<metro>/metro.json`, written by `Pipeline/build_metro.py`: the tile lattice of one
/// build of a metro. Shared by the apps, `lwtool` and the tests.
public struct MetroIndex: Codable, Sendable, Equatable {
    public struct Tile: Codable, Sendable, Hashable {
        public var i: Int
        public var j: Int
        public var file: String
        public var bytes: Int
        public var nodes: Int?
        public var edges: Int?
        public var buildings: Int?
        public init(i: Int, j: Int, file: String, bytes: Int, nodes: Int? = nil, edges: Int? = nil, buildings: Int? = nil) {
            self.i = i; self.j = j; self.file = file; self.bytes = bytes
            self.nodes = nodes; self.edges = edges; self.buildings = buildings
        }
    }
    public struct FileRef: Codable, Sendable, Equatable {
        public var file: String
        public var bytes: Int
    }
    public var format: Int?
    public var id: String
    public var name: String
    public var timezone: String?
    /// ISO 8601 build time. Node ids are row numbers of one build, so tiles from two
    /// builds must never be stitched together; this names the build.
    public var built: String?
    public var overture: String?
    public var source: String?
    public var tileLat: Double
    public var tileLon: Double
    public var minLat: Double, minLon: Double, maxLat: Double, maxLon: Double
    public var demo: [Double]?
    public var far: FileRef?
    public var bytes: Int
    public var tiles: [Tile]

    public var bbox: BBox { BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon) }

    /// A filesystem-safe name for the build ("20260930065716"); "legacy" for old indexes.
    public var buildKey: String { Self.buildKey(built) }

    public static func buildKey(_ built: String?) -> String {
        guard let built else { return "legacy" }
        let digits = built.prefix(19).filter(\.isNumber)
        return digits.isEmpty ? "legacy" : String(digits)
    }

    /// Is this build newer than `other`'s? Builds without a time are oldest.
    public func isNewer(than other: MetroIndex) -> Bool { Self.isNewer(buildKey, than: other.buildKey) }

    /// Build-key order: dated keys (same-length digit strings) sort as times; "legacy" is oldest.
    public static func isNewer(_ a: String, than b: String) -> Bool {
        if a == "legacy" { return false }
        if b == "legacy" { return true }
        return a > b
    }

    public func tileBox(_ t: Tile) -> BBox {
        BBox(minLat: Double(t.i) * tileLat, minLon: Double(t.j) * tileLon,
             maxLat: Double(t.i + 1) * tileLat, maxLon: Double(t.j + 1) * tileLon)
    }

    /// The tile holding a point, if the metro has one there (tiles exist only where the
    /// city has streets).
    public func tile(containingLat lat: Double, lon: Double) -> Tile? {
        let i = Int((lat / tileLat).rounded(.down)), j = Int((lon / tileLon).rounded(.down))
        return tiles.first { $0.i == i && $0.j == j }
    }

    /// Every tile intersecting a box.
    public func tiles(intersecting box: BBox) -> [Tile] {
        let i0 = Int((box.minLat / tileLat).rounded(.down)), i1 = Int((box.maxLat / tileLat).rounded(.down))
        let j0 = Int((box.minLon / tileLon).rounded(.down)), j1 = Int((box.maxLon / tileLon).rounded(.down))
        return tiles.filter { $0.i >= i0 && $0.i <= i1 && $0.j >= j0 && $0.j <= j1 }
    }

    /// Does the box reach outside the metro's bounds? Inside them a cell without a tile is
    /// water or has no streets, which is coverage, not a gap.
    public func extendsBeyond(_ box: BBox) -> Bool {
        box.minLat < minLat - 1e-9 || box.maxLat > maxLat + 1e-9 ||
        box.minLon < minLon - 1e-9 || box.maxLon > maxLon + 1e-9
    }

    /// Does the box overlap the metro at all?
    public func intersects(_ box: BBox) -> Bool { bbox.intersects(box) }

    public static func load(from url: URL) throws -> MetroIndex {
        try JSONDecoder().decode(MetroIndex.self, from: Data(contentsOf: url))
    }
}

extension BBox {
    public func intersects(_ o: BBox) -> Bool {
        !(o.maxLat < minLat || o.minLat > maxLat || o.maxLon < minLon || o.minLon > maxLon)
    }

    public func contains(_ o: BBox) -> Bool {
        o.minLat >= minLat && o.maxLat <= maxLat && o.minLon >= minLon && o.maxLon <= maxLon
    }

    /// Overlap area in square degrees (0 when disjoint): picks the city most of a screen is in.
    public func overlapArea(_ o: BBox) -> Double {
        let h = min(maxLat, o.maxLat) - max(minLat, o.minLat)
        let w = min(maxLon, o.maxLon) - max(minLon, o.minLon)
        return h > 0 && w > 0 ? h * w : 0
    }
}
