import Foundation

@inline(__always)
public func haversineMeters(_ lat1: Double, _ lon1: Double, _ lat2: Double, _ lon2: Double) -> Double {
    let R = 6_371_008.8
    let p = Double.pi / 180
    let dLat = (lat2 - lat1) * p
    let dLon = (lon2 - lon1) * p
    let sLat = sin(dLat / 2), sLon = sin(dLon / 2)
    let a = sLat * sLat + cos(lat1 * p) * cos(lat2 * p) * sLon * sLon
    return 2 * R * asin(min(1, a.squareRoot()))
}

public struct BBox: Equatable, Codable, Sendable {
    public var minLat: Double, minLon: Double, maxLat: Double, maxLon: Double

    public init(minLat: Double, minLon: Double, maxLat: Double, maxLon: Double) {
        self.minLat = minLat; self.minLon = minLon
        self.maxLat = maxLat; self.maxLon = maxLon
    }

    public var centerLat: Double { (minLat + maxLat) / 2 }
    public var centerLon: Double { (minLon + maxLon) / 2 }

    public static func around(_ points: [(lat: Double, lon: Double)], paddingMeters: Double) -> BBox {
        var b = BBox(minLat: points[0].lat, minLon: points[0].lon,
                     maxLat: points[0].lat, maxLon: points[0].lon)
        for p in points.dropFirst() {
            b.minLat = min(b.minLat, p.lat); b.maxLat = max(b.maxLat, p.lat)
            b.minLon = min(b.minLon, p.lon); b.maxLon = max(b.maxLon, p.lon)
        }
        let dLat = paddingMeters / 111_320.0
        let dLon = paddingMeters / (111_320.0 * max(0.2, cos(b.centerLat * .pi / 180)))
        b.minLat -= dLat; b.maxLat += dLat
        b.minLon -= dLon; b.maxLon += dLon
        return b
    }

    public func contains(lat: Double, lon: Double, insetMeters: Double = 0) -> Bool {
        let dLat = insetMeters / 111_320.0
        let dLon = insetMeters / (111_320.0 * max(0.2, cos(centerLat * .pi / 180)))
        return lat >= minLat + dLat && lat <= maxLat - dLat
            && lon >= minLon + dLon && lon <= maxLon - dLon
    }
}

/// Equirectangular projection to metres, anchored at one point. Over a city-sized
/// area the distortion is far below the resolution the shadow model cares about,
/// and it keeps all the geometry in cheap flat arithmetic.
public struct LocalPlane: Sendable {
    public let originLat: Double
    public let originLon: Double
    public let metresPerDegreeLat: Double
    public let metresPerDegreeLon: Double

    public init(originLat: Double, originLon: Double) {
        self.originLat = originLat
        self.originLon = originLon
        metresPerDegreeLat = 111_132.92 - 559.82 * cos(2 * originLat * .pi / 180)
            + 1.175 * cos(4 * originLat * .pi / 180)
        metresPerDegreeLon = 111_412.84 * cos(originLat * .pi / 180)
            - 93.5 * cos(3 * originLat * .pi / 180)
    }

    /// East/north metres from the origin.
    @inline(__always)
    public func project(lat: Double, lon: Double) -> (x: Double, y: Double) {
        ((lon - originLon) * metresPerDegreeLon, (lat - originLat) * metresPerDegreeLat)
    }

    @inline(__always)
    public func unproject(x: Double, y: Double) -> (lat: Double, lon: Double) {
        (originLat + y / metresPerDegreeLat, originLon + x / metresPerDegreeLon)
    }
}
