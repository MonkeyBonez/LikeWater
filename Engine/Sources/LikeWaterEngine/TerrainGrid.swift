import Foundation

/// Ground elevation on a regular lat/lon grid, sampled bilinearly in the same
/// metre plane the building store uses, so a shadow ray can walk it cheaply.
///
/// A grid can have a coarser `fallback` behind it: in a stitched metro the fine
/// (10 m) grid covers only the loaded tiles, and a 100 m grid covers the metro plus
/// 25 km, so a mountain range well outside the tiles still casts its shadow. Past
/// the edge of both, there is no ground — a ray stops rather than seeing the last
/// row extended forever (which invented plateaus).
public final class TerrainGrid {
    public let rows: Int
    public let cols: Int
    public let originLat: Double
    public let originLon: Double
    public let stepLat: Double
    public let stepLon: Double
    let cells: [Int16]
    /// Highest point in this grid, metres.
    public let maxElevation: Double
    /// Coarser grid consulted outside this one's extent.
    public var fallback: TerrainGrid?

    // Plane-space equivalents, filled in by `bind(to:)`.
    private var originX = 0.0, originY = 0.0, stepX = 1.0, stepY = 1.0

    public init(rows: Int, cols: Int, originLat: Double, originLon: Double,
                stepLat: Double, stepLon: Double, elevation: [Int16]) {
        self.rows = rows; self.cols = cols
        self.originLat = originLat; self.originLon = originLon
        self.stepLat = stepLat; self.stepLon = stepLon
        self.cells = elevation
        self.maxElevation = Double(elevation.max() ?? 0)
    }

    public var isEmpty: Bool { rows < 2 || cols < 2 }

    /// Highest ground anywhere this grid or its fallback could report.
    public var maxElevationIncludingFallback: Double {
        max(maxElevation, fallback?.maxElevationIncludingFallback ?? -.infinity)
    }

    public var bbox: BBox {
        BBox(minLat: originLat, minLon: originLon,
             maxLat: originLat + Double(rows - 1) * stepLat, maxLon: originLon + Double(cols - 1) * stepLon)
    }

    func bind(to plane: LocalPlane) {
        let o = plane.project(lat: originLat, lon: originLon)
        originX = o.x; originY = o.y
        stepX = stepLon * plane.metresPerDegreeLon
        stepY = stepLat * plane.metresPerDegreeLat
        fallback?.bind(to: plane)
    }

    @inline(__always)
    private func bilinear(_ c: Double, _ r: Double) -> Double {
        let c0 = Int(c), r0 = Int(r)
        let fc = c - Double(c0), fr = r - Double(r0)
        let i = r0 * cols + c0
        let e00 = Double(cells[i]), e01 = Double(cells[i + 1])
        let e10 = Double(cells[i + cols]), e11 = Double(cells[i + cols + 1])
        return e00 * (1 - fc) * (1 - fr) + e01 * fc * (1 - fr) + e10 * (1 - fc) * fr + e11 * fc * fr
    }

    /// Ground elevation at plane coordinates, from this grid or its fallback; nil past both.
    @inline(__always)
    public func sample(x: Double, y: Double) -> Double? {
        if !isEmpty {
            let c = (x - originX) / stepX
            let r = (y - originY) / stepY
            if c >= 0, r >= 0, c <= Double(cols) - 1.001, r <= Double(rows) - 1.001 {
                return bilinear(c, r)
            }
        }
        return fallback?.sample(x: x, y: y)
    }

    /// Ground elevation in metres at plane coordinates; clamps at the grid edge when
    /// nothing covers the point (used for a walker's own feet, which are always inside).
    @inline(__always)
    public func elevation(x: Double, y: Double) -> Double {
        if let v = sample(x: x, y: y) { return v }
        guard !isEmpty else { return 0 }
        let c = min(max((x - originX) / stepX, 0), Double(cols) - 1.001)
        let r = min(max((y - originY) / stepY, 0), Double(rows) - 1.001)
        return bilinear(c, r)
    }

    public func elevation(lat: Double, lon: Double) -> Double {
        guard !isEmpty else { return fallback?.elevation(lat: lat, lon: lon) ?? 0 }
        let cRaw = (lon - originLon) / stepLon, rRaw = (lat - originLat) / stepLat
        if (cRaw < 0 || rRaw < 0 || cRaw > Double(cols) - 1.001 || rRaw > Double(rows) - 1.001), let fallback {
            return fallback.elevation(lat: lat, lon: lon)
        }
        let c = min(max(cRaw, 0), Double(cols) - 1.001)
        let r = min(max(rRaw, 0), Double(rows) - 1.001)
        return bilinear(c, r)
    }
}
