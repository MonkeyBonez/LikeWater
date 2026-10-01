import Foundation
@testable import LikeWaterEngine

/// Builds a rows x cols lattice with exact 100 m edges so corridor sets are exactly predictable.
func gridGraph(rows: Int, cols: Int, spacing: Double = 100) -> PedestrianGraph {
    var lat: [Double] = [], lon: [Double] = []
    for i in 0..<rows {
        for j in 0..<cols {
            lat.append(37.7800 + Double(i) * 0.0009)
            lon.append(-122.4100 + Double(j) * 0.00114)
        }
    }
    func idx(_ i: Int, _ j: Int) -> Int32 { Int32(i * cols + j) }
    var a: [Int32] = [], b: [Int32] = [], len: [Double] = [], crossing: [Bool] = []
    for i in 0..<rows {
        for j in 0..<cols {
            if j + 1 < cols {
                a.append(idx(i, j)); b.append(idx(i, j + 1)); len.append(spacing); crossing.append(j % 2 == 0)
            }
            if i + 1 < rows {
                a.append(idx(i, j)); b.append(idx(i + 1, j)); len.append(spacing); crossing.append(false)
            }
        }
    }
    let box = BBox(minLat: lat.min()!, minLon: lon.min()!, maxLat: lat.max()!, maxLon: lon.max()!)
    return PedestrianGraph(nodeLat: lat, nodeLon: lon, edgeA: a, edgeB: b,
                           edgeLen: len, edgeFlags: crossing.map { $0 ? EdgeFlag.crossing : 0 }, bbox: box)
}

