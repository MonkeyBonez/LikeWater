import Foundation

/// Building footprints projected once into a flat metre plane, with a uniform grid
/// so a shadow ray only tests the polygons it could actually cross.
public final class BuildingStore {
    public let plane: LocalPlane
    public let count: Int

    private let start: [Int32]          // count + 1 offsets into vx/vy
    private let vx: [Float]
    private let vy: [Float]
    private let height: [Float]
    /// Ground elevation under each footprint; a building's top is ground + height.
    private let ground: [Float]
    /// Optional terrain, so hills can shade as well as buildings.
    public let terrain: TerrainGrid?
    /// Diagnostic switch: score as if the city were flat, to measure what terrain adds.
    public var useTerrain = true

    private let minX: [Float], minY: [Float], maxX: [Float], maxY: [Float]

    private let cellMetres: Double
    private let buckets: [Int64: [Int32]]
    /// Tallest roof (ground + height) touching each cell: a ray skips a cell whose
    /// tallest roof is already below the sun line where the ray enters it.
    private let cellMaxRoof: [Int64: Float]
    /// Tallest roof and tallest building anywhere, which bound how far a ray must go.
    public let maxRoof: Double
    public let maxHeight: Double

    public convenience init(start: [Int32], lat: [Double], lon: [Double], height: [Float],
                            bbox: BBox, cellMetres: Double = 100) {
        self.init(start: start, lat: lat, lon: lon, height: height,
                  ground: [Float](repeating: 0, count: height.count), terrain: nil,
                  bbox: bbox, cellMetres: cellMetres)
    }

    public init(start: [Int32], lat: [Double], lon: [Double], height: [Float],
                ground: [Float], terrain: TerrainGrid?,
                bbox: BBox, cellMetres: Double = 100) {
        let plane = LocalPlane(originLat: bbox.centerLat, originLon: bbox.centerLon)
        self.plane = plane
        self.start = start
        self.height = height
        self.ground = ground
        self.terrain = terrain
        terrain?.bind(to: plane)
        self.count = height.count
        self.cellMetres = cellMetres

        var xs = [Float](repeating: 0, count: lat.count)
        var ys = [Float](repeating: 0, count: lat.count)
        for i in 0..<lat.count {
            let p = plane.project(lat: lat[i], lon: lon[i])
            xs[i] = Float(p.x); ys[i] = Float(p.y)
        }
        self.vx = xs
        self.vy = ys

        var bMinX = [Float](repeating: 0, count: count)
        var bMinY = [Float](repeating: 0, count: count)
        var bMaxX = [Float](repeating: 0, count: count)
        var bMaxY = [Float](repeating: 0, count: count)
        var grid = [Int64: [Int32]](minimumCapacity: count / 2 + 1)
        var roofs = [Int64: Float](minimumCapacity: count / 2 + 1)
        var tallestRoof: Float = 0, tallest: Float = 0

        for b in 0..<count {
            let lo = Int(start[b]), hi = Int(start[b + 1])
            guard hi > lo else { continue }
            var x0 = xs[lo], x1 = xs[lo], y0 = ys[lo], y1 = ys[lo]
            for v in lo..<hi {
                x0 = min(x0, xs[v]); x1 = max(x1, xs[v])
                y0 = min(y0, ys[v]); y1 = max(y1, ys[v])
            }
            bMinX[b] = x0; bMaxX[b] = x1; bMinY[b] = y0; bMaxY[b] = y1

            let c0 = Int((Double(x0) / cellMetres).rounded(.down))
            let c1 = Int((Double(x1) / cellMetres).rounded(.down))
            let r0 = Int((Double(y0) / cellMetres).rounded(.down))
            let r1 = Int((Double(y1) / cellMetres).rounded(.down))
            let roof = ground[b] + height[b]
            tallestRoof = max(tallestRoof, roof); tallest = max(tallest, height[b])
            for r in r0...r1 {
                for c in c0...c1 {
                    let k = BuildingStore.key(r, c)
                    grid[k, default: []].append(Int32(b))
                    roofs[k] = max(roofs[k] ?? -.infinity, roof)
                }
            }
        }
        self.minX = bMinX; self.maxX = bMaxX; self.minY = bMinY; self.maxY = bMaxY
        self.buckets = grid
        self.cellMaxRoof = roofs
        self.maxRoof = Double(tallestRoof)
        self.maxHeight = Double(tallest)
    }

    @inline(__always)
    private static func key(_ row: Int, _ col: Int) -> Int64 {
        (Int64(row) &* 1_000_003) &+ Int64(col)
    }

    public func heightOf(_ building: Int) -> Float { height[building] }
    public func groundOf(_ building: Int) -> Float { ground[building] }

    /// Terrain rays are walked out to where even the highest ground in the grid (or its
    /// far-field fallback) could no longer reach the sun line, capped here. A fixed
    /// 300 m / 3 km reach missed the San Gabriels from downtown Los Angeles entirely.
    public static let maxTerrainReachMetres = 30_000.0
    /// Building rays are capped too: past this, a shadow is too thin and too long to matter.
    public static let maxBuildingReachMetres = 6_000.0
    static let terrainStepMetres = 25.0

    /// True when a building or the ground blocks the sun from a point on the plane.
    ///
    /// Walks the grid along the ray toward the sun (Amanatides–Woo), and for each
    /// candidate footprint takes the nearest crossing distance `d`: the building
    /// shades the point when `h / d > tan(elevation)`. The ray is as long as the
    /// tallest roof in the store requires — a 470 m tower at 30° shades 800 m away —
    /// and `maxHeight`, when given, caps that (the old fixed 100 m behaviour).
    public func isShaded(x: Double, y: Double, azimuthDegrees: Double,
                         tanElevation: Double, maxHeight: Double? = nil,
                         visited: inout [Int32], stamp: Int32) -> Bool {
        guard tanElevation > 1e-6 else { return true }
        let a = azimuthDegrees * .pi / 180
        let dx = sin(a), dy = cos(a)                // east, north
        if abs(dx) < 1e-12 && abs(dy) < 1e-12 { return false }

        // Ground under the walker. Building tops and hills are compared against this.
        let z0 = useTerrain ? (terrain?.elevation(x: x, y: y) ?? 0) : 0

        // Hills first: march the ray and see whether the ground ever rises above the
        // sun line. Steps grow with distance (2% of it) once past a few hundred metres,
        // which matches the far-field grid's resolution and keeps a 30 km ray ~200 samples.
        if useTerrain, let terrain {
            let relief = terrain.maxElevationIncludingFallback - z0
            if relief > tanElevation * BuildingStore.terrainStepMetres {
                let reach = min(relief / tanElevation, BuildingStore.maxTerrainReachMetres)
                var t = BuildingStore.terrainStepMetres
                while t <= reach {
                    guard let zt = terrain.sample(x: x + dx * t, y: y + dy * t) else { break }
                    if zt - z0 > tanElevation * t { return true }
                    t += max(BuildingStore.terrainStepMetres, t * 0.02)
                }
            }
        }

        let tallest = useTerrain ? maxRoof - z0 : self.maxHeight
        let reachHeight = maxHeight.map { min($0, tallest) } ?? tallest
        guard reachHeight > 0 else { return false }
        let maxDistance = min(reachHeight / tanElevation, BuildingStore.maxBuildingReachMetres)

        var cellX = Int((x / cellMetres).rounded(.down))
        var cellY = Int((y / cellMetres).rounded(.down))
        let stepX = dx > 0 ? 1 : -1
        let stepY = dy > 0 ? 1 : -1

        func boundary(_ cell: Int, _ step: Int) -> Double {
            Double(step > 0 ? cell + 1 : cell) * cellMetres
        }
        var tMaxX = abs(dx) < 1e-12 ? Double.infinity : (boundary(cellX, stepX) - x) / dx
        var tMaxY = abs(dy) < 1e-12 ? Double.infinity : (boundary(cellY, stepY) - y) / dy
        let tDeltaX = abs(dx) < 1e-12 ? Double.infinity : cellMetres / abs(dx)
        let tDeltaY = abs(dy) < 1e-12 ? Double.infinity : cellMetres / abs(dy)

        var travelled = 0.0
        var guardCounter = 0
        while travelled <= maxDistance && guardCounter < 1024 {
            guardCounter += 1
            let cellKey = BuildingStore.key(cellY, cellX)
            // Nothing in this cell is tall enough to reach the sun line here.
            let roofHere = useTerrain ? Double(cellMaxRoof[cellKey] ?? -.infinity) - z0
                                      : Double(cellMaxRoof[cellKey] ?? -.infinity)
            if roofHere > tanElevation * max(0, travelled - cellMetres * 1.5),
               let bucket = buckets[cellKey] {
                for b in bucket {
                    let index = Int(b)
                    if visited[index] == stamp { continue }
                    visited[index] = stamp
                    // Height of the roof above the walker's feet, not above the ground
                    // under the building: a tall building downhill may not shade at all.
                    let h = (useTerrain ? Double(ground[index]) : 0) + Double(height[index]) - z0
                    if h <= 0 { continue }
                    // Even at the closest possible approach this building is too short.
                    if h <= tanElevation * max(0.5, distanceToBox(x: x, y: y, index: index)) { continue }
                    if let d = nearestCrossing(x: x, y: y, dx: dx, dy: dy,
                                               maxDistance: maxDistance, index: index),
                       d > 0.5, h / d > tanElevation {
                        return true
                    }
                }
            }
            if tMaxX < tMaxY {
                travelled = tMaxX; tMaxX += tDeltaX; cellX += stepX
            } else {
                travelled = tMaxY; tMaxY += tDeltaY; cellY += stepY
            }
        }
        return false
    }

    @inline(__always)
    private func distanceToBox(x: Double, y: Double, index: Int) -> Double {
        let ddx = max(Double(minX[index]) - x, 0, x - Double(maxX[index]))
        let ddy = max(Double(minY[index]) - y, 0, y - Double(maxY[index]))
        return (ddx * ddx + ddy * ddy).squareRoot()
    }

    /// Distance along the ray to the first footprint edge it crosses.
    private func nearestCrossing(x: Double, y: Double, dx: Double, dy: Double,
                                 maxDistance: Double, index: Int) -> Double? {
        let lo = Int(start[index]), hi = Int(start[index + 1])
        guard hi - lo >= 3 else { return nil }
        var best = Double.infinity
        var j = hi - 1
        for i in lo..<hi {
            defer { j = i }
            let ax = Double(vx[j]), ay = Double(vy[j])
            let bx = Double(vx[i]), by = Double(vy[i])
            let ex = bx - ax, ey = by - ay
            let denominator = dx * ey - dy * ex
            if abs(denominator) < 1e-12 { continue }
            let t = ((ax - x) * ey - (ay - y) * ex) / denominator   // along the ray
            let u = ((ax - x) * dy - (ay - y) * dx) / denominator   // along the segment
            if t >= 0, t <= maxDistance, u >= 0, u <= 1, t < best { best = t }
        }
        return best.isFinite ? best : nil
    }
}
