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
    /// Scored for when the walker would first reach the edge heading straight there.
    var sunBucket: Int?
    /// Fraction of the clear-sky beam at that time and place (fades the colour).
    var beam: Float = 1
}

/// One stretch of the sun strip under the slider: seconds after departure.
struct StripSegment: Sendable, Equatable {
    var start: Double
    var end: Double
    var bucket: Int
    var beam: Float
}

/// The suggested route, ready to draw and read out.
struct RouteView: Sendable {
    var coordinates: [CLLocationCoordinate2D]
    /// Per edge: 0/1/2 shaded/mixed/sunny when the walker is on it; empty without sun.
    var edgeBuckets: [Int]
    var edgeBeams: [Float]
    var seconds: Double
    var metres: Double
    var sunFraction: Double
    var fastestSeconds: Double
    var fastestSunFraction: Double
    var sunniestSeconds: Double?
    var sunniestSunFraction: Double?
    var strip: [StripSegment]
    /// Seconds into the walk at which the sun sets, when it does.
    var sunsetSeconds: Double?
    var sunsetAt: Date?
    /// True when hysteresis kept the route the walker was already on.
    var kept: Bool
    var hasSun: Bool
    var sunWeight: Double
    var routeMs: Double
    var labelsExpanded: Int
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
    var route: RouteView?
    var departure: Date
    var arrival: Date?
    var timelineMs: Double = 0
    var scoredPairs: Int = 0
    var cacheHits: Int = 0
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
    private var slotCache = SunSlotCache()

    /// What the last update computed, so a slider move re-runs only the route search.
    private struct Context {
        var corridor: Corridor
        var labels: DestinationLabels
        var origin: Int32
        var timeline: SunTimeline?
        var seconds: EdgeSeconds
        var departure: Date
    }
    private var context: Context?
    private var lastRoute: Route?
    private var lastPrefer: RoutePreference = .sun
    /// `update` suspends twice (city load, weather). The actor is reentrant at those
    /// points, so a later call can overtake an earlier one; the earlier one must then
    /// drop its result rather than write a stale (or other-graph) context back.
    private var updateGeneration = 0

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
        slotCache = SunSlotCache()
        labels = nil
        destinationNode = nil
        context = nil
        lastRoute = nil
    }

    var cityName: String? { city?.name }

    func setDestination(_ coordinate: CLLocationCoordinate2D) {
        destinationCoordinate = coordinate
        labels = nil
        destinationNode = nil
        context = nil
        lastRoute = nil
    }

    func clear() {
        destinationCoordinate = nil
        labels = nil
        destinationNode = nil
        context = nil
        lastRoute = nil
    }

    func update(user: CLLocationCoordinate2D, slack: Double,
                layer: MapLayer, date: Date, pace: WalkingPace = .normal,
                sunWeight: Double = 0.5, prefer: RoutePreference = .sun) async throws -> CorridorSnapshot {
        updateGeneration += 1
        let generation = updateGeneration
        try await prepare(for: user)
        try Task.checkCancellation()
        guard generation == updateGeneration else { throw CancellationError() }
        guard let city else { throw ServiceError.noDestination }
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

        // Pace and the sun timeline: both the route and the Sun layer use them, so the
        // colours, the route and the ETA agree on when the walker gets where.
        let t0 = CFAbsoluteTimeGetCurrent()
        let seconds = PaceModel(pace: pace).edgeSeconds(graph: graph, edges: corridor.edges,
                                                        terrain: city.bundle.buildings.terrain)
        // The timeline is built on every layer: the route's sun %, the slider and the ETA
        // are product readouts everywhere (PLAN "Route + ETA everywhere"), and after the
        // first fix the slot cache makes it cheap.
        let p = Solar.position(latitude: user.latitude, longitude: user.longitude, date: date)
        let sun: SolarPosition? = p
        // Same forecast Sun Map uses: under cloud the geometry is still right, but
        // there is no beam to be in or out of, and the colours must say so.
        let field: SkyField?
        if let preset = WeatherService.launchPreset() {
            field = WeatherService.field(for: preset, around: user, at: date)
        } else {
            field = await WeatherService.shared.sky(around: user, for: date)
        }
        try Task.checkCancellation()
        guard generation == updateGeneration, self.city === city else { throw CancellationError() }
        let sky = field?.condition(latitude: user.latitude, longitude: user.longitude,
                                   at: date, sunElevation: p.elevation)
        // Keep every slot from now on: scrubbing the departure back and forth stays cached.
        slotCache.drop(before: Int((min(date, Date()).timeIntervalSince1970 / 900).rounded(.down)) - 1)
        // The scorer is taken out of the actor only around this synchronous block, so its
        // scratch buffer is uniquely referenced (no copy) and no suspension can interleave.
        var scorer = self.scorer ?? SunScorer(buildings: city.bundle.buildings)
        self.scorer = nil
        let timeline: SunTimeline? = SunTimelineBuilder.build(
            graph: graph, corridor: corridor, origin: graph.coordinate(origin),
            destination: graph.coordinate(destinationNode), departure: date, pace: pace,
            edgeSeconds: seconds, scorer: &scorer, cache: slotCache, sky: field)
        self.scorer = scorer
        let layerMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000

        context = Context(corridor: corridor, labels: labels, origin: origin, timeline: timeline,
                          seconds: seconds, departure: date)
        let route = makeRoute(graph: graph, sunWeight: sunWeight, prefer: prefer, hysteresis: true)

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
                sunBucket: layer == .sun ? timeline.map {
                    SunBucket(fraction: $0.geometricSun(edge: i, slot: $0.slot(atSeconds: corridor.fromOrigin[i] / pace.metresPerSecond))).rawValue
                } ?? 0 : nil,
                beam: timeline.map { $0.beam[$0.slot(atSeconds: corridor.fromOrigin[i] / pace.metresPerSecond)] } ?? 1))
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
            rebuiltLabels: rebuilt, sun: layer == .sun ? sun : nil, hasArrived: arrived, city: city.name,
            timeZone: city.timeZone, sky: layer == .sun ? sky : nil, route: route, departure: date,
            arrival: route.map { date.addingTimeInterval($0.seconds) },
            timelineMs: timeline?.computeMs ?? 0, scoredPairs: timeline?.scoredPairs ?? 0,
            cacheHits: timeline?.cacheHits ?? 0)
    }

    /// The slider moved: one route search over the last corridor and timeline.
    func reroute(sunWeight: Double, prefer: RoutePreference) -> RouteView? {
        guard let graph = city?.bundle.graph else { return nil }
        return makeRoute(graph: graph, sunWeight: sunWeight, prefer: prefer, hysteresis: false)
    }

    private func makeRoute(graph: PedestrianGraph, sunWeight: Double, prefer: RoutePreference,
                           hysteresis: Bool) -> RouteView? {
        guard let ctx = context else { return nil }
        func run(_ w: Double) -> Route? {
            try? RouteEngine.route(graph: graph, corridor: ctx.corridor, labels: ctx.labels, origin: ctx.origin,
                                   timeline: ctx.timeline, edgeSeconds: ctx.seconds, sunWeight: w, prefer: prefer)
        }
        guard let fresh = run(sunWeight) else { lastRoute = nil; return nil }
        var chosen = fresh
        var kept = false
        // Hysteresis: the walker is on the previous route and the rest of it is still
        // within 5 % of the new optimum — keep it, so the line doesn't flicker per fix.
        if hysteresis, let prev = lastRoute, prev.sunWeight == sunWeight, lastPrefer == prefer,
           let at = prev.nodes.firstIndex(of: ctx.origin), at < prev.edges.count,
           let rest = RouteEngine.evaluate(edges: Array(prev.edges[at...]), from: ctx.origin, graph: graph,
                                           corridor: ctx.corridor, timeline: ctx.timeline,
                                           edgeSeconds: ctx.seconds, sunWeight: sunWeight, prefer: prefer),
           rest.edges != chosen.edges, RouteEngine.shouldKeep(previous: rest, candidate: chosen) {
            var r = rest
            r.computeMs = chosen.computeMs; r.labelsExpanded = chosen.labelsExpanded
            chosen = r; kept = true
        } else if hysteresis, let prev = lastRoute, let at = prev.nodes.firstIndex(of: ctx.origin),
                  Array(prev.edges[at...]) == chosen.edges {
            kept = true
        }
        lastRoute = chosen; lastPrefer = prefer
        // The slider's end labels describe the optima, even when hysteresis kept a route
        // a few per cent off them.
        let fastest = sunWeight == 0 ? fresh : (run(0) ?? fresh)
        let sunniest = ctx.timeline == nil ? nil : (sunWeight == 1 ? fresh : run(1))
        return view(of: chosen, fastest: fastest, sunniest: sunniest, timeline: ctx.timeline,
                    departure: ctx.departure, graph: graph, kept: kept)
    }

    private func view(of r: Route, fastest: Route, sunniest: Route?, timeline: SunTimeline?,
                      departure: Date, graph: PedestrianGraph, kept: Bool) -> RouteView {
        var buckets: [Int] = [], beams: [Float] = [], strip: [StripSegment] = []
        if let timeline {
            for k in r.edges.indices {
                let slot = r.edgeSlot[k]
                let bucket = SunBucket(fraction: timeline.geometricSun(edge: r.corridorIndex[k], slot: slot)).rawValue
                let beam = timeline.beam[slot]
                buckets.append(bucket); beams.append(beam)
                let a = r.arrivalSeconds[k], b = r.arrivalSeconds[k + 1]
                // Daylight shade under a lit sky vs. no beam at all read the same on the strip.
                let shown = beam < 0.15 ? 0 : bucket
                if var last = strip.last, last.bucket == shown, abs(last.beam - beam) < 0.1 {
                    last.end = b; strip[strip.count - 1] = last
                } else {
                    strip.append(StripSegment(start: a, end: b, bucket: shown, beam: beam))
                }
            }
        }
        var sunsetSeconds: Double?
        if let s = timeline?.sunset {
            let t = s.timeIntervalSince(departure)
            if t > 0 && t < r.seconds { sunsetSeconds = t }
        }
        return RouteView(
            coordinates: r.nodes.map { let c = graph.coordinate($0); return CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon) },
            edgeBuckets: buckets, edgeBeams: beams, seconds: r.seconds, metres: r.metres,
            sunFraction: r.sunFraction, fastestSeconds: fastest.seconds, fastestSunFraction: fastest.sunFraction,
            sunniestSeconds: sunniest?.seconds, sunniestSunFraction: sunniest?.sunFraction,
            strip: strip, sunsetSeconds: sunsetSeconds, sunsetAt: sunsetSeconds.map { departure.addingTimeInterval($0) },
            kept: kept, hasSun: timeline != nil, sunWeight: r.sunWeight, routeMs: r.computeMs,
            labelsExpanded: r.labelsExpanded)
    }

    func daylightWindow(at coordinate: CLLocationCoordinate2D, on date: Date) -> (sunrise: Date, sunset: Date)? {
        Solar.daylightWindow(latitude: coordinate.latitude, longitude: coordinate.longitude,
                             containing: date)
    }

    enum StepStrategy { case shortest, random, route }

    /// Walks forward inside the corridor for roughly `meters`. `.random` picks any free
    /// choice, which is the claim the product makes: inside the corridor, choice is free.
    func step(from user: CLLocationCoordinate2D, meters: Double, slack: Double,
              strategy: StepStrategy) -> CLLocationCoordinate2D? {
        guard let graph = city?.bundle.graph, let labels,
              var current = graph.nearestConnectedNode(lat: user.latitude, lon: user.longitude) else { return nil }
        if strategy == .route, let route = lastRoute, let at = route.nodes.firstIndex(of: current) {
            // Follow the suggested route, the way a walker who trusts it would.
            var walked = 0.0, k = at
            while k < route.edges.count && walked < meters {
                walked += graph.edgeLen[Int(route.edges[k])]; k += 1
            }
            current = route.nodes[k]
            return CLLocationCoordinate2D(latitude: graph.nodeLat[Int(current)], longitude: graph.nodeLon[Int(current)])
        }
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
