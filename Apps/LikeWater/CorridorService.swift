import Foundation
import CoreLocation
import LikeWaterEngine

enum MapLayer: String, CaseIterable, Identifiable, Sendable {
    case crossings = "Crossings"
    case interest = "Interest"
    case sun = "Sun"
    var id: String { rawValue }
}

struct CorridorEdgeView: Sendable {
    var a: CLLocationCoordinate2D
    var b: CLLocationCoordinate2D
    var excess: Double
    var isCrossing: Bool
    /// 0, 1, or 2 — the PRD's three interest brightness buckets.
    var interestBucket: Int
    /// 0, 1, or 2 for shaded / mixed / sunny; nil when the sun layer is not active.
    var sunBucket: Int?
}

struct CorridorSnapshot: Sendable {
    var edges: [CorridorEdgeView]
    var crossingNodes: [CLLocationCoordinate2D]
    var snapped: CLLocationCoordinate2D
    var destination: CLLocationCoordinate2D
    var distance: Double
    var slack: Double
    var layer: MapLayer
    var choicesHere: Int
    var metersToDecision: Double
    var edgeCount: Int
    var crossingCount: Int
    var nodesExplored: Int
    var labelMs: Double
    var corridorMs: Double
    var layerMs: Double
    var rebuiltLabels: Bool
    var sun: SolarPosition?
    var hasArrived: Bool
    var city: String
    var timeZone: TimeZone?
    /// The sky over the walker when the Sun layer is on; nil otherwise or with no forecast.
    var sky: SkyCondition?
}

enum ServiceError: Error, LocalizedError {
    case noDestination
    var errorDescription: String? { "Set a destination first." }
}

/// Owns the bundled graph and the destination labels off the main actor.
actor CorridorService {
    private var city: LoadedCity?
    private var scorer: SunScorer?
    private var scratch: CorridorScratch?
    private var labels: DestinationLabels?
    private var destinationCoordinate: CLLocationCoordinate2D?
    private var destinationNode: Int32?
    private var lastLabelMs: Double = 0

    /// PRD: arrival is within 20 m of the destination node.
    static let arrivalRadius: Double = 20

    /// Picks the city covering the user and the destination, loading, downloading or
    /// stitching as needed. A change of city drops the destination labels, which
    /// belong to the old graph.
    func prepare(for coordinate: CLLocationCoordinate2D) async throws {
        let points = [coordinate] + (destinationCoordinate.map { [$0] } ?? [])
        let wanted = try await CityStore.shared.city(covering: points)
        if let city, city === wanted { return }
        city = wanted
        scorer = SunScorer(buildings: wanted.bundle.buildings)
        scratch = CorridorScratch(graph: wanted.bundle.graph)
        labels = nil
        destinationNode = nil
    }

    var cityName: String? { city?.name }

    func setDestination(_ coordinate: CLLocationCoordinate2D) {
        destinationCoordinate = coordinate
        labels = nil
        destinationNode = nil
    }

    func clear() {
        destinationCoordinate = nil
        labels = nil
        destinationNode = nil
    }

    func update(user: CLLocationCoordinate2D, slack: Double,
                layer: MapLayer, date: Date) async throws -> CorridorSnapshot {
        try await prepare(for: user)
        guard let city, var scorer else { throw ServiceError.noDestination }
        self.scorer = nil      // held locally while mutating, so its scratch isn't copied
        defer { self.scorer = scorer }
        let graph = city.bundle.graph
        guard let destinationCoordinate else { throw ServiceError.noDestination }

        // Snap the user to the main network, then snap the destination to the user's
        // component so a pin on a disconnected pier still routes.
        guard let origin = graph.nearestConnectedNode(lat: user.latitude, lon: user.longitude) else {
            throw CorridorError.originOffGraph
        }
        if destinationNode == nil {
            destinationNode = graph.nearestNode(lat: destinationCoordinate.latitude,
                                                lon: destinationCoordinate.longitude,
                                                inComponent: graph.component[Int(origin)])
        }
        guard let destinationNode else { throw CorridorError.destinationUnreachable }

        // Labels only get rebuilt when the current position plus slack needs distances
        // beyond the radius they were bounded to.
        var rebuilt = false
        if let existing = labels {
            let needed = existing.dTo[Int(origin)] * (1 + slack)
            let covered = existing.seedDistance * (1 + existing.coveredSlack)
            if !existing.dTo[Int(origin)].isFinite || needed > covered { labels = nil }
        }
        if labels == nil {
            labels = try CorridorEngine.labels(graph: graph, destination: destinationNode,
                                               origin: origin, slack: max(slack, 0.35) + 0.15)
            lastLabelMs = labels!.computeMs
            rebuilt = true
        }
        guard let labels else { throw CorridorError.destinationUnreachable }

        let corridor = try CorridorEngine.corridor(graph: graph, labels: labels,
                                                   origin: origin, slack: slack, scratch: scratch)

        // Layer scoring.
        let t0 = CFAbsoluteTimeGetCurrent()
        var sun: SolarPosition?
        var sunScores: [Float] = []
        var sky: SkyCondition?
        if layer == .sun {
            let p = Solar.position(latitude: user.latitude, longitude: user.longitude, date: date)
            sun = p
            // Same forecast Sun Map uses: under cloud the geometry is still right, but
            // there is no beam to be in or out of, and the colours must say so.
            let field: SkyField?
            if let preset = WeatherService.launchPreset() {
                field = WeatherService.field(for: preset, around: user, at: date)
            } else {
                field = await WeatherService.shared.sky(around: user, for: date)
            }
            sky = field?.condition(latitude: user.latitude, longitude: user.longitude,
                                   at: date, sunElevation: p.elevation)
            sunScores = scorer.score(graph: graph, edges: corridor.edges, sun: p)
        }
        let layerMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        var edges: [CorridorEdgeView] = []
        edges.reserveCapacity(corridor.edges.count)
        var crossingNodes: [CLLocationCoordinate2D] = []
        var seenCrossingNode = Set<Int32>()

        for (i, e) in corridor.edges.enumerated() {
            let index = Int(e)
            let a = Int(graph.edgeA[index]), b = Int(graph.edgeB[index])
            let crossing = graph.isCrossing(index)
            if crossing {
                for n in [graph.edgeA[index], graph.edgeB[index]] where seenCrossingNode.insert(n).inserted {
                    crossingNodes.append(CLLocationCoordinate2D(latitude: graph.nodeLat[Int(n)],
                                                                longitude: graph.nodeLon[Int(n)]))
                }
            }
            let interest = graph.edgeInterest[index]
            edges.append(CorridorEdgeView(
                a: CLLocationCoordinate2D(latitude: graph.nodeLat[a], longitude: graph.nodeLon[a]),
                b: CLLocationCoordinate2D(latitude: graph.nodeLat[b], longitude: graph.nodeLon[b]),
                excess: corridor.excess[i],
                isCrossing: crossing,
                interestBucket: interest == 0 ? 0 : (interest <= 3 ? 1 : 2),
                sunBucket: layer == .sun ? (sun?.isUp == true ? SunBucket(fraction: sunScores[i]).rawValue : 0) : nil))
        }

        let destinationPoint = graph.coordinate(destinationNode)
        let arrived = haversineMeters(user.latitude, user.longitude,
                                      destinationPoint.lat, destinationPoint.lon) <= Self.arrivalRadius

        return CorridorSnapshot(
            edges: edges, crossingNodes: crossingNodes,
            snapped: CLLocationCoordinate2D(latitude: graph.nodeLat[Int(origin)],
                                            longitude: graph.nodeLon[Int(origin)]),
            destination: destinationCoordinate,
            distance: corridor.distance, slack: slack, layer: layer,
            choicesHere: corridor.choicesHere, metersToDecision: corridor.metersToDecision,
            edgeCount: corridor.edges.count, crossingCount: corridor.crossingEdges.count,
            nodesExplored: corridor.nodesExplored,
            labelMs: lastLabelMs, corridorMs: corridor.computeMs, layerMs: layerMs,
            rebuiltLabels: rebuilt, sun: sun, hasArrived: arrived, city: city.name,
            timeZone: city.timeZone, sky: sky)
    }

    func daylightWindow(at coordinate: CLLocationCoordinate2D, on date: Date) -> (sunrise: Date, sunset: Date)? {
        Solar.daylightWindow(latitude: coordinate.latitude, longitude: coordinate.longitude,
                             containing: date)
    }

    enum StepStrategy { case shortest, random }

    /// Walks forward inside the corridor for roughly `meters`. `.random` picks any free
    /// choice, which is the claim the product makes: inside the corridor, choice is free.
    func step(from user: CLLocationCoordinate2D, meters: Double, slack: Double,
              strategy: StepStrategy) -> CLLocationCoordinate2D? {
        guard let graph = city?.bundle.graph, let labels,
              var current = graph.nearestConnectedNode(lat: user.latitude, lon: user.longitude) else { return nil }
        let dTo = labels.dTo
        var walked = 0.0
        var guardCounter = 0
        while walked < meters && guardCounter < 400 {
            guardCounter += 1
            let D = dTo[Int(current)]
            guard D.isFinite, D > 1 else { break }
            let bound = D * (1 + slack) + 1e-6
            var options: [(node: Int32, length: Double, excess: Double)] = []
            for k in Int(graph.adjStart[Int(current)])..<Int(graph.adjStart[Int(current) + 1]) {
                let v = Int(graph.adjNode[k])
                let h = dTo[v]
                guard h.isFinite, h < D else { continue }
                let L = graph.edgeLen[Int(graph.adjEdge[k])]
                guard L + h <= bound else { continue }
                options.append((Int32(v), L, L + h - D))
            }
            guard !options.isEmpty else { break }
            let chosen = strategy == .shortest ? options.min { $0.excess < $1.excess }! : options.randomElement()!
            walked += chosen.length
            current = chosen.node
        }
        return CLLocationCoordinate2D(latitude: graph.nodeLat[Int(current)],
                                      longitude: graph.nodeLon[Int(current)])
    }
}
