import Foundation

public enum BundleError: Error, LocalizedError {
    case unreadable(String)
    case badMagic
    case badVersion(UInt32)
    case truncated(section: String)

    public var errorDescription: String? {
        switch self {
        case .unreadable(let p): return "Could not read the city bundle at \(p)."
        case .badMagic: return "That file is not a Like Water city bundle."
        case .badVersion(let v): return "City bundle version \(v) is not supported."
        case .truncated(let s): return "City bundle is truncated in section \(s)."
        }
    }
}

/// Just the 64-byte header: enough to know what a bundle covers without loading it.
public struct BundleHeader: Sendable, Equatable {
    public let version: UInt32
    public let nodeCount: Int
    public let edgeCount: Int
    public let buildingCount: Int
    public let bbox: BBox
    /// Version 3 only: the tile's (row, col) on its metro's lattice.
    public let tileRow: Int32
    public let tileCol: Int32

    public static func read(from url: URL) throws -> BundleHeader {
        guard let handle = try? FileHandle(forReadingFrom: url),
              let data = try? handle.read(upToCount: 64), data.count == 64 else {
            throw BundleError.unreadable(url.path)
        }
        return try BundleHeader(data: data)
    }

    public init(data: Data) throws {
        guard data.count >= 64 else { throw BundleError.truncated(section: "header") }
        let magic = [UInt8](data[0..<4])
        guard magic == CityBundle.magic else { throw BundleError.badMagic }
        func u32(_ o: Int) -> UInt32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func i32(_ o: Int) -> Int32 { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Int32.self) } }
        func f64(_ o: Int) -> Double { data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: Double.self) } }
        version = u32(4)
        guard CityBundle.supportedVersions.contains(version) else { throw BundleError.badVersion(version) }
        nodeCount = Int(u32(8)); edgeCount = Int(u32(12)); buildingCount = Int(u32(16))
        bbox = BBox(minLat: f64(24), minLon: f64(32), maxLat: f64(40), maxLon: f64(48))
        tileRow = version >= 3 ? i32(56) : 0
        tileCol = version >= 3 ? i32(60) : 0
    }
}

/// Every array in a bundle file, decoded but not yet turned into a graph. A single
/// city bundle becomes a `CityBundle` directly; metro tiles are stitched first.
public struct RawBundle {
    public var version: UInt32
    public var bbox: BBox
    public var tileRow: Int32 = 0
    public var tileCol: Int32 = 0
    public var nodeLat: [Double]
    public var nodeLon: [Double]
    /// Metro-wide node ids (version 3); empty for a single-city bundle.
    public var nodeGlobalId: [UInt32]
    public var adjStart: [Int32]
    public var adjNode: [Int32]
    public var adjEdge: [Int32]
    public var edgeA: [Int32]
    public var edgeB: [Int32]
    public var edgeLen: [Double]
    public var edgeFlags: [UInt8]
    public var edgeInterest: [UInt8]
    public var bldStart: [Int32]
    public var bldLat: [Double]
    public var bldLon: [Double]
    public var bldHeight: [Float]
    public var bldGround: [Float]
    public var terrain: TerrainGrid?

    public var nodeCount: Int { nodeLat.count }
    public var edgeCount: Int { edgeA.count }
    public var buildingCount: Int { bldHeight.count }

    public init(version: UInt32, bbox: BBox, tileRow: Int32 = 0, tileCol: Int32 = 0,
                nodeLat: [Double], nodeLon: [Double], nodeGlobalId: [UInt32],
                adjStart: [Int32], adjNode: [Int32], adjEdge: [Int32],
                edgeA: [Int32], edgeB: [Int32], edgeLen: [Double], edgeFlags: [UInt8], edgeInterest: [UInt8],
                bldStart: [Int32], bldLat: [Double], bldLon: [Double], bldHeight: [Float], bldGround: [Float],
                terrain: TerrainGrid?) {
        self.version = version; self.bbox = bbox; self.tileRow = tileRow; self.tileCol = tileCol
        self.nodeLat = nodeLat; self.nodeLon = nodeLon; self.nodeGlobalId = nodeGlobalId
        self.adjStart = adjStart; self.adjNode = adjNode; self.adjEdge = adjEdge
        self.edgeA = edgeA; self.edgeB = edgeB; self.edgeLen = edgeLen
        self.edgeFlags = edgeFlags; self.edgeInterest = edgeInterest
        self.bldStart = bldStart; self.bldLat = bldLat; self.bldLon = bldLon
        self.bldHeight = bldHeight; self.bldGround = bldGround; self.terrain = terrain
    }

    public init(contentsOf url: URL) throws {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else {
            throw BundleError.unreadable(url.path)
        }
        try self.init(data: data)
    }

    public init(data: Data) throws {
        guard data.count >= 64 else { throw BundleError.truncated(section: "header") }

        var cursor = 0
        func readHeader<T>(_ type: T.Type) -> T {
            let value = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: T.self) }
            cursor += MemoryLayout<T>.size
            return value
        }

        let magic = [readHeader(UInt8.self), readHeader(UInt8.self),
                     readHeader(UInt8.self), readHeader(UInt8.self)]
        guard magic == CityBundle.magic else { throw BundleError.badMagic }
        let version = readHeader(UInt32.self)
        guard CityBundle.supportedVersions.contains(version) else { throw BundleError.badVersion(version) }

        let nodeCount = Int(readHeader(UInt32.self))
        let edgeCount = Int(readHeader(UInt32.self))
        let buildingCount = Int(readHeader(UInt32.self))
        let vertexCount = Int(readHeader(UInt32.self))
        let minLat = readHeader(Double.self), minLon = readHeader(Double.self)
        let maxLat = readHeader(Double.self), maxLon = readHeader(Double.self)
        let tileRow = readHeader(Int32.self), tileCol = readHeader(Int32.self)
        cursor = 64

        func align() { if cursor % 8 != 0 { cursor += 8 - cursor % 8 } }

        func read<T>(_ type: T.Type, count: Int, label: String) throws -> [T] {
            align()
            let bytes = count * MemoryLayout<T>.stride
            guard cursor + bytes <= data.count else { throw BundleError.truncated(section: label) }
            let out = [T](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    if count > 0 {
                        memcpy(buffer.baseAddress!, raw.baseAddress!.advanced(by: cursor), bytes)
                    }
                }
                initialized = count
            }
            cursor += bytes
            return out
        }
        /// u32 on disk, Int32 in memory, converted in one pass without an intermediate copy.
        func readIndex(count: Int, label: String) throws -> [Int32] {
            align()
            let bytes = count * 4
            guard cursor + bytes <= data.count else { throw BundleError.truncated(section: label) }
            let base = cursor
            cursor += bytes
            return [Int32](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    for i in 0..<count {
                        buffer[i] = Int32(bitPattern: raw.loadUnaligned(fromByteOffset: base + 4 * i, as: UInt32.self))
                    }
                }
                initialized = count
            }
        }
        func readCoordinates(count: Int, label: String) throws -> [Double] {
            align()
            let bytes = count * 4
            guard cursor + bytes <= data.count else { throw BundleError.truncated(section: label) }
            let base = cursor
            cursor += bytes
            return [Double](unsafeUninitializedCapacity: count) { buffer, initialized in
                data.withUnsafeBytes { raw in
                    for i in 0..<count {
                        buffer[i] = Double(raw.loadUnaligned(fromByteOffset: base + 4 * i, as: Int32.self)) * 1e-7
                    }
                }
                initialized = count
            }
        }

        self.version = version
        self.bbox = BBox(minLat: minLat, minLon: minLon, maxLat: maxLat, maxLon: maxLon)
        self.tileRow = version >= 3 ? tileRow : 0
        self.tileCol = version >= 3 ? tileCol : 0
        nodeLat = try readCoordinates(count: nodeCount, label: "nodeLat")
        nodeLon = try readCoordinates(count: nodeCount, label: "nodeLon")
        adjStart = try readIndex(count: nodeCount + 1, label: "adjStart")
        adjNode = try readIndex(count: 2 * edgeCount, label: "adjNode")
        adjEdge = try readIndex(count: 2 * edgeCount, label: "adjEdge")
        edgeA = try readIndex(count: edgeCount, label: "edgeA")
        edgeB = try readIndex(count: edgeCount, label: "edgeB")
        edgeLen = try read(Float.self, count: edgeCount, label: "edgeLen").map(Double.init)
        edgeFlags = try read(UInt8.self, count: edgeCount, label: "edgeFlags")
        edgeInterest = try read(UInt8.self, count: edgeCount, label: "edgeInterest")
        bldStart = try readIndex(count: buildingCount + 1, label: "bldStart")
        bldLat = try readCoordinates(count: vertexCount, label: "bldLat")
        bldLon = try readCoordinates(count: vertexCount, label: "bldLon")
        bldHeight = try read(Float.self, count: buildingCount, label: "bldHeight")

        bldGround = [Float](repeating: 0, count: buildingCount)
        terrain = nil
        nodeGlobalId = []
        if version >= 2 {
            bldGround = try read(Float.self, count: buildingCount, label: "bldGround")
            align()
            guard cursor + 40 <= data.count else { throw BundleError.truncated(section: "terrainHeader") }
            let rows = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor, as: UInt32.self) })
            let cols = Int(data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 4, as: UInt32.self) })
            let oLat = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 8, as: Double.self) }
            let oLon = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 16, as: Double.self) }
            let sLat = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 24, as: Double.self) }
            let sLon = data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: cursor + 32, as: Double.self) }
            cursor += 40
            if rows > 1 && cols > 1 {
                let cells = try read(Int16.self, count: rows * cols, label: "terrain")
                terrain = TerrainGrid(rows: rows, cols: cols, originLat: oLat, originLon: oLon,
                                      stepLat: sLat, stepLon: sLon, elevation: cells)
            }
        }
        if version >= 3 {
            nodeGlobalId = try read(UInt32.self, count: nodeCount, label: "nodeGlobalId")
        }
    }
}

/// Reader for the binary bundle produced by `Pipeline/build_bundle.py` (one city) or
/// `Pipeline/build_metro.py` (a metro's tiles, stitched here). Sections are 8-byte
/// aligned and read with `memcpy`, so alignment of the mapped file never matters.
public struct CityBundle {
    public let graph: PedestrianGraph
    public let buildings: BuildingStore
    public let terrain: TerrainGrid?
    public let bbox: BBox
    public let version: UInt32

    public static let magic: [UInt8] = Array("LWB1".utf8)
    public static let supportedVersions: ClosedRange<UInt32> = 1...3

    public init(contentsOf url: URL) throws {
        try self.init(raw: try RawBundle(contentsOf: url))
    }

    public init(data: Data) throws {
        try self.init(raw: try RawBundle(data: data))
    }

    /// One self-contained bundle, using the adjacency the pipeline already built.
    public init(raw: RawBundle, farTerrain: TerrainGrid? = nil) {
        bbox = raw.bbox
        version = raw.version
        let t = raw.terrain ?? farTerrain
        if let t, let farTerrain, t !== farTerrain { t.fallback = farTerrain }
        terrain = t
        graph = PedestrianGraph(nodeLat: raw.nodeLat, nodeLon: raw.nodeLon,
                                edgeA: raw.edgeA, edgeB: raw.edgeB, edgeLen: raw.edgeLen,
                                edgeFlags: raw.edgeFlags, edgeInterest: raw.edgeInterest,
                                adjStart: raw.adjStart, adjNode: raw.adjNode, adjEdge: raw.adjEdge,
                                bbox: raw.bbox)
        buildings = BuildingStore(start: raw.bldStart, lat: raw.bldLat, lon: raw.bldLon,
                                  height: raw.bldHeight, ground: raw.bldGround,
                                  terrain: t, bbox: raw.bbox)
    }

    /// Built from already-assembled parts (the stitcher).
    init(graph: PedestrianGraph, buildings: BuildingStore, terrain: TerrainGrid?, bbox: BBox, version: UInt32) {
        self.graph = graph; self.buildings = buildings; self.terrain = terrain
        self.bbox = bbox; self.version = version
    }
}
