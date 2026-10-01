import MapKit
import LikeWaterEngine

/// The sidewalks of one score tile in one bucket (street detail).
final class SunLinesOverlay: MKMultiPolyline {
    var tile = SunTileKey(detail: .streets, i: 0, j: 0)
    var bucket = SunBucket.shaded
    convenience init(_ lines: [MKPolyline], tile: SunTileKey, bucket: SunBucket) {
        self.init(lines); self.tile = tile; self.bucket = bucket
    }
}

/// The blocks of one score tile at one sun level (zoomed out).
final class SunCellsOverlay: MKMultiPolygon {
    static let levels = 8
    var tile = SunTileKey(detail: .streets, i: 0, j: 0)
    var level = 0
    convenience init(_ polygons: [MKPolygon], tile: SunTileKey, level: Int) {
        self.init(polygons); self.tile = tile; self.level = level
    }
    var fraction: Double { (Double(level) + 0.5) / Double(Self.levels) }
}

/// Builds and diffs the per-tile overlays of a sun field: a pan adds the tiles that came
/// into view and removes the ones that left, nothing else is touched.
enum SunOverlays {
    static func make(_ tile: SunTile) -> [MKOverlay] {
        var out: [MKOverlay] = []
        if !tile.edges.isEmpty {
            var lines: [SunBucket: [MKPolyline]] = [:]
            for e in tile.edges {
                var pair = [e.a, e.b]
                lines[e.bucket, default: []].append(MKPolyline(coordinates: &pair, count: 2))
            }
            for bucket in [SunBucket.shaded, .mixed, .sunny] {
                if let l = lines[bucket] { out.append(SunLinesOverlay(l, tile: tile.key, bucket: bucket)) }
            }
        }
        if !tile.cells.isEmpty {
            var polys: [Int: [MKPolygon]] = [:]
            for c in tile.cells {
                // Grown by 3 % so neighbours overlap: separate polygons otherwise leave
                // hairline seams of bare map between them.
                let dLat = (c.box.maxLat - c.box.minLat) * 0.03, dLon = (c.box.maxLon - c.box.minLon) * 0.03
                var ring = [CLLocationCoordinate2D(latitude: c.box.minLat - dLat, longitude: c.box.minLon - dLon),
                            CLLocationCoordinate2D(latitude: c.box.minLat - dLat, longitude: c.box.maxLon + dLon),
                            CLLocationCoordinate2D(latitude: c.box.maxLat + dLat, longitude: c.box.maxLon + dLon),
                            CLLocationCoordinate2D(latitude: c.box.maxLat + dLat, longitude: c.box.minLon - dLon)]
                polys[c.level(of: SunCellsOverlay.levels), default: []].append(MKPolygon(coordinates: &ring, count: 4))
            }
            for (level, p) in polys.sorted(by: { $0.key < $1.key }) {
                out.append(SunCellsOverlay(p, tile: tile.key, level: level))
            }
        }
        return out
    }

    /// What the map shows for one score tile: the content stamp it was built from.
    struct Shown { var stamp: String; var overlays: [MKOverlay] }

    /// Updates `map` so it shows `field`'s tiles. `shown` is the caller's record.
    static func sync(_ map: MKMapView, field: SunField?, shown: inout [SunTileKey: Shown]) {
        let wanted = field?.keys ?? []
        // While tiles are still streaming in, what is on the map stays (a scrub would
        // otherwise blank the screen and refill it); the complete field tidies up.
        if !(field?.inProgress ?? false) {
            for (key, old) in shown where !wanted.contains(key) {
                map.removeOverlays(old.overlays); shown[key] = nil
            }
        }
        for tile in field?.tiles ?? [] {
            if let old = shown[tile.key] {
                if old.stamp == tile.stamp { continue }
                map.removeOverlays(old.overlays)
            }
            let overlays = make(tile)
            map.addOverlays(overlays, level: .aboveRoads)
            shown[tile.key] = Shown(stamp: tile.stamp, overlays: overlays)
        }
    }
}
