import Foundation

public enum SunBucket: Int, Sendable, CaseIterable {
    case shaded, mixed, sunny

    public init(fraction: Float) {
        if fraction < 0.3 { self = .shaded }
        else if fraction <= 0.7 { self = .mixed }
        else { self = .sunny }
    }
}

/// Fraction of an edge standing in direct sunlight at a given instant.
public struct SunScorer {
    public let buildings: BuildingStore
    public let samplesPerEdge: Int
    /// Caps the shadow search height; nil searches as far as the tallest roof requires.
    public let maxBuildingHeight: Double?

    private var scratch: [Int32]

    public init(buildings: BuildingStore, samplesPerEdge: Int = 5, maxBuildingHeight: Double? = nil) {
        self.buildings = buildings
        self.samplesPerEdge = samplesPerEdge
        self.maxBuildingHeight = maxBuildingHeight
        self.scratch = [Int32](repeating: -1, count: max(1, buildings.count))
    }

    /// 0 = fully shaded, 1 = fully sunlit. Returns 0 for a sun below the horizon.
    public mutating func score(aLat: Double, aLon: Double, bLat: Double, bLon: Double,
                               sun: SolarPosition, stamp: Int32) -> Float {
        guard sun.isUp else { return 0 }
        let tanElevation = tan(sun.elevation * .pi / 180)
        guard tanElevation > 1e-6 else { return 0 }

        let a = buildings.plane.project(lat: aLat, lon: aLon)
        let b = buildings.plane.project(lat: bLat, lon: bLon)

        var lit = 0
        var currentStamp = stamp
        for i in 0..<samplesPerEdge {
            let t = (Double(i) + 0.5) / Double(samplesPerEdge)
            let x = a.x + (b.x - a.x) * t
            let y = a.y + (b.y - a.y) * t
            currentStamp = currentStamp &+ 1
            let shaded = buildings.isShaded(x: x, y: y,
                                            azimuthDegrees: sun.azimuth,
                                            tanElevation: tanElevation,
                                            maxHeight: maxBuildingHeight,
                                            visited: &scratch, stamp: currentStamp)
            if !shaded { lit += 1 }
        }
        return Float(lit) / Float(samplesPerEdge)
    }

    /// Scores a set of graph edges. Returns values parallel to `edges`.
    public mutating func score(graph: PedestrianGraph, edges: [Int32],
                               sun: SolarPosition) -> [Float] {
        guard sun.isUp else { return [Float](repeating: 0, count: edges.count) }
        var out = [Float](repeating: 0, count: edges.count)
        var stamp: Int32 = 0
        for (i, e) in edges.enumerated() {
            let a = Int(graph.edgeA[Int(e)]), b = Int(graph.edgeB[Int(e)])
            stamp = stamp &+ Int32(samplesPerEdge) &+ 1
            if stamp > Int32.max - 64 { scratch = [Int32](repeating: -1, count: scratch.count); stamp = 0 }
            out[i] = score(aLat: graph.nodeLat[a], aLon: graph.nodeLon[a],
                           bLat: graph.nodeLat[b], bLon: graph.nodeLon[b],
                           sun: sun, stamp: stamp)
        }
        return out
    }
}
