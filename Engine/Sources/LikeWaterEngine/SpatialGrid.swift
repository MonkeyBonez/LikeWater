import Foundation

/// Uniform lat/lon bucket grid for nearest-node lookup. Cell edge ~= `cellMeters`.
struct SpatialGrid {
    fileprivate let originLat: Double
    fileprivate let originLon: Double
    fileprivate let latStep: Double
    fileprivate let lonStep: Double
    fileprivate var buckets: [Int64: [Int32]]

    fileprivate let cellMeters: Double

    init(lat: [Double], lon: [Double], bbox: BBox, cellMeters: Double = 60) {
        self.cellMeters = cellMeters
        let midLat = (bbox.minLat + bbox.maxLat) / 2
        originLat = bbox.minLat
        originLon = bbox.minLon
        latStep = cellMeters / 111_320.0
        lonStep = cellMeters / (111_320.0 * max(0.2, cos(midLat * .pi / 180)))
        var b = [Int64: [Int32]](minimumCapacity: lat.count / 2 + 1)
        for i in 0..<lat.count {
            let key = SpatialGrid.key(row: Int(((lat[i] - originLat) / latStep).rounded(.down)),
                                      col: Int(((lon[i] - originLon) / lonStep).rounded(.down)))
            b[key, default: []].append(Int32(i))
        }
        buckets = b
    }

    @inline(__always)
    fileprivate static func key(row: Int, col: Int) -> Int64 {
        (Int64(row) &* 1_000_003) &+ Int64(col)
    }

    /// Nearest node index, or nil if nothing within `maxMeters`.
    func nearest(lat: Double, lon: Double, nodeLat: [Double], nodeLon: [Double],
                 maxMeters: Double = 400, where predicate: ((Int32) -> Bool)? = nil) -> Int32? {
        let row = Int(((lat - originLat) / latStep).rounded(.down))
        let col = Int(((lon - originLon) / lonStep).rounded(.down))
        var best: Int32? = nil
        var bestDist = Double.infinity
        var ring = 0
        while true {
            // Once the closest possible point in the next ring is farther than what we have, stop.
            if best != nil && Double(ring - 1) * cellMeters > bestDist { break }
            if Double(ring) * cellMeters > maxMeters { break }
            for r in (row - ring)...(row + ring) {
                for c in (col - ring)...(col + ring) {
                    // only the perimeter of the ring
                    if ring > 0 && abs(r - row) != ring && abs(c - col) != ring { continue }
                    guard let bucket = buckets[SpatialGrid.key(row: r, col: c)] else { continue }
                    for n in bucket {
                        if let predicate, !predicate(n) { continue }
                        let d = haversineMeters(lat, lon, nodeLat[Int(n)], nodeLon[Int(n)])
                        if d < bestDist { bestDist = d; best = n }
                    }
                }
            }
            ring += 1
        }
        return bestDist <= maxMeters ? best : nil
    }
}

extension SpatialGrid {
    /// All node indices within `radius` metres of a point.
    func nodes(near lat: Double, lon: Double, radius: Double,
               nodeLat: [Double], nodeLon: [Double]) -> [Int32] {
        let row = Int(((lat - originLat) / latStep).rounded(.down))
        let col = Int(((lon - originLon) / lonStep).rounded(.down))
        let reach = Int((radius / cellMeters).rounded(.up)) + 1
        var out: [Int32] = []
        for r in (row - reach)...(row + reach) {
            for c in (col - reach)...(col + reach) {
                guard let bucket = buckets[SpatialGrid.key(row: r, col: c)] else { continue }
                for n in bucket where haversineMeters(lat, lon, nodeLat[Int(n)], nodeLon[Int(n)]) <= radius {
                    out.append(n)
                }
            }
        }
        return out
    }
}
