import Foundation

/// Which light the walker is after.
public enum RoutePreference: String, Sendable, CaseIterable {
    case sun, shade
}

/// One walkable path through the corridor, timed by the pace model and lit by the timeline.
public struct Route: Sendable {
    public var nodes: [Int32]
    /// Graph edge ids in walking order.
    public var edges: [Int32]
    /// Parallel to `edges`: index into `corridor.edges`.
    public var corridorIndex: [Int]
    public var metres: Double
    public var seconds: Double
    /// Seconds of the walk in effective sun (geometric sun × beam), whatever the preference.
    public var sunSeconds: Double
    /// The objective the search minimised.
    public var cost: Double
    /// Parallel to `edges`: effective sun 0…1 when the walker is on it.
    public var edgeSun: [Float]
    /// Parallel to `edges`: local timeline slot the walker is in on it.
    public var edgeSlot: [Int]
    /// Parallel to `nodes`: seconds after departure the walker reaches each node.
    public var arrivalSeconds: [Double]
    public var sunWeight: Double
    public var labelsExpanded: Int
    public var maxLabelsAtANode: Int
    public var capHits: Int
    public var computeMs: Double

    public var sunFraction: Double { seconds > 0 ? sunSeconds / seconds : 0 }
    public var isEmpty: Bool { edges.isEmpty }
}

public enum RouteError: Error, LocalizedError {
    case noRoute
    public var errorDescription: String? { "No route inside the corridor." }
}

/// Picks one route inside the corridor (PLAN.md §1.3).
///
/// Cost of an edge entered `τ` s after departure: `seconds · (1 − w · sun(edge, slot(τ)))`
/// with `w = maxSunWeight · λ`. λ = 0 is the fastest path; λ = 1 minimises shade-seconds.
/// The search is Dijkstra over the corridor's edges with Pareto labels (cost, metres) per
/// node, pruned by `metres + dTo[v] ≤ D·(1+slack)`, so the route never leaves the corridor
/// or its bound. Sun depends on arrival time, so the cost is time-dependent and not FIFO:
/// labels only dominate each other within the same time slot.
public enum RouteEngine {
    /// < 1 keeps time counting even on a fully sunny edge, so no edge is free (free edges
    /// tie, and ties flicker between fixes).
    public static let maxSunWeight = 0.9

    struct Local {
        var nodeOf: [Int32: Int32] = [:]
        var nodes: [Int32] = []
        var adjStart: [Int] = []
        var adjTo: [Int32] = []           // local node
        var adjEdge: [Int] = []           // corridor-local edge index
        var adjForward: [Bool] = []       // walking edgeA → edgeB
    }

    static func localGraph(graph: PedestrianGraph, corridor: Corridor) -> Local {
        var L = Local()
        func id(_ n: Int32) -> Int32 {
            if let i = L.nodeOf[n] { return i }
            let i = Int32(L.nodes.count); L.nodeOf[n] = i; L.nodes.append(n); return i
        }
        var deg: [Int] = []
        var pairs: [(Int32, Int32, Int, Bool)] = []
        pairs.reserveCapacity(corridor.edges.count * 2)
        for (i, e) in corridor.edges.enumerated() {
            let a = id(graph.edgeA[Int(e)]), b = id(graph.edgeB[Int(e)])
            pairs.append((a, b, i, true)); pairs.append((b, a, i, false))
        }
        deg = [Int](repeating: 0, count: L.nodes.count + 1)
        for p in pairs { deg[Int(p.0) + 1] += 1 }
        for i in 1..<deg.count { deg[i] += deg[i - 1] }
        L.adjStart = deg
        var fill = deg
        L.adjTo = [Int32](repeating: 0, count: pairs.count)
        L.adjEdge = [Int](repeating: 0, count: pairs.count)
        L.adjForward = [Bool](repeating: false, count: pairs.count)
        for p in pairs {
            let k = fill[Int(p.0)]; fill[Int(p.0)] += 1
            L.adjTo[k] = p.1; L.adjEdge[k] = p.2; L.adjForward[k] = p.3
        }
        return L
    }

    @inline(__always)
    static func sunOn(_ timeline: SunTimeline?, edge i: Int, enteringAt t: Double, seconds s: Double) -> (Float, Int) {
        guard let timeline else { return (0, 0) }
        let k = timeline.slot(atSeconds: t + s / 2)
        return (timeline.effectiveSun(edge: i, slot: k), k)
    }

    /// Only sidewalk time is discounted for light. A crossing (road surface plus the wait
    /// at the kerb) always costs its full seconds: discounting it let a λ = 1 route in SoMa
    /// cross the street 15 times in 650 m to stay on the lit side (LEARNINGS §11).
    @inline(__always)
    static func edgeCost(seconds s: Double, sun: Float, weight w: Double, prefer: RoutePreference,
                         crossing: Bool) -> Double {
        if crossing { return s }
        let light = Double(prefer == .sun ? sun : 1 - sun)
        return s * (1 - w * light)
    }

    public static func route(graph: PedestrianGraph, corridor: Corridor, labels: DestinationLabels,
                             origin: Int32, timeline: SunTimeline?, edgeSeconds: EdgeSeconds,
                             sunWeight: Double, prefer: RoutePreference = .sun,
                             maxLabelsPerNode: Int = 16) throws -> Route {
        let t0 = CFAbsoluteTimeGetCurrent()
        let L = localGraph(graph: graph, corridor: corridor)
        guard let start = L.nodeOf[origin], let goal = L.nodeOf[labels.destNode] else { throw RouteError.noRoute }
        let bound = corridor.distance * (1 + corridor.slack) + 1e-6
        let w = maxSunWeight * min(max(sunWeight, 0), 1)
        let dTo = labels.dTo

        // Flat label store.
        var lNode: [Int32] = [], lCost: [Double] = [], lDist: [Double] = [], lSec: [Double] = []
        var lPred: [Int32] = [], lEdge: [Int32] = [], lAdj: [Int32] = [], lSlot: [Int32] = []
        var lSun: [Float] = [], lDead: [Bool] = []
        var atNode = [[Int32]](repeating: [], count: L.nodes.count)
        var heap = MinHeap()
        heap.reserve(1024)
        var expanded = 0, capHits = 0, maxAt = 1

        func add(_ node: Int32, _ cost: Double, _ dist: Double, _ sec: Double, _ pred: Int32,
                 _ edge: Int32, _ adj: Int32, _ sun: Float) {
            let slot = Int32(timeline?.slot(atSeconds: sec) ?? 0)
            var list = atNode[Int(node)]
            for j in list where !lDead[Int(j)] && lSlot[Int(j)] == slot {
                if lCost[Int(j)] <= cost + 1e-9 && lDist[Int(j)] <= dist + 1e-9 { return }
            }
            for j in list where !lDead[Int(j)] && lSlot[Int(j)] == slot {
                if cost <= lCost[Int(j)] && dist <= lDist[Int(j)] { lDead[Int(j)] = true }
            }
            list.removeAll { lDead[Int($0)] }
            if list.count >= maxLabelsPerNode {
                capHits += 1
                // Full: replace the costliest label if this one is cheaper.
                guard let worst = list.max(by: { lCost[Int($0)] < lCost[Int($1)] }),
                      lCost[Int(worst)] > cost else { atNode[Int(node)] = list; return }
                lDead[Int(worst)] = true
                list.removeAll { $0 == worst }
            }
            let id = Int32(lNode.count)
            lNode.append(node); lCost.append(cost); lDist.append(dist); lSec.append(sec)
            lPred.append(pred); lEdge.append(edge); lAdj.append(adj); lSlot.append(slot)
            lSun.append(sun); lDead.append(false)
            list.append(id)
            maxAt = max(maxAt, list.count)
            atNode[Int(node)] = list
            heap.push(cost, id)
        }

        add(start, 0, 0, 0, -1, -1, -1, 0)
        var found: Int32 = -1
        while let (c, id) = heap.pop() {
            if lDead[Int(id)] || c > lCost[Int(id)] { continue }
            let u = lNode[Int(id)]
            if u == goal { found = id; break }
            expanded += 1
            let du = lDist[Int(id)], su = lSec[Int(id)]
            let cameBy = lEdge[Int(id)]
            for k in L.adjStart[Int(u)]..<L.adjStart[Int(u) + 1] {
                let i = L.adjEdge[k]
                if Int32(i) == cameBy { continue }                  // no U-turns
                let v = L.adjTo[k]
                let e = Int(corridor.edges[i])
                let nd = du + graph.edgeLen[e]
                let h = dTo[Int(L.nodes[Int(v)])]
                if !h.isFinite || nd + h > bound { continue }
                let s = L.adjForward[k] ? edgeSeconds.forward[i] : edgeSeconds.backward[i]
                let (sun, _) = sunOn(timeline, edge: i, enteringAt: su, seconds: s)
                add(v, c + edgeCost(seconds: s, sun: sun, weight: w, prefer: prefer, crossing: graph.isCrossing(e)), nd, su + s,
                    id, Int32(i), Int32(k), sun)
            }
        }
        guard found >= 0 else { throw RouteError.noRoute }

        // Walk the predecessors back.
        var chain: [Int32] = []
        var cur = found
        while cur >= 0 { chain.append(cur); cur = lPred[Int(cur)] }
        chain.reverse()
        var r = Route(nodes: [], edges: [], corridorIndex: [], metres: 0, seconds: 0, sunSeconds: 0,
                      cost: lCost[Int(found)], edgeSun: [], edgeSlot: [], arrivalSeconds: [],
                      sunWeight: sunWeight, labelsExpanded: expanded, maxLabelsAtANode: maxAt,
                      capHits: capHits, computeMs: 0)
        for (n, id) in chain.enumerated() {
            r.nodes.append(L.nodes[Int(lNode[Int(id)])])
            r.arrivalSeconds.append(lSec[Int(id)])
            guard n > 0 else { continue }
            let i = Int(lEdge[Int(id)])
            let s = lSec[Int(id)] - lSec[Int(chain[n - 1])]
            r.edges.append(corridor.edges[i]); r.corridorIndex.append(i)
            r.edgeSun.append(lSun[Int(id)])
            r.edgeSlot.append(timeline?.slot(atSeconds: lSec[Int(chain[n - 1])] + s / 2) ?? 0)
            r.sunSeconds += s * Double(lSun[Int(id)])
        }
        r.metres = lDist[Int(found)]
        r.seconds = lSec[Int(found)]
        r.computeMs = (CFAbsoluteTimeGetCurrent() - t0) * 1000
        return r
    }

    /// Times and lights a given edge sequence walked from `origin` (hysteresis: what is the
    /// rest of the previous route worth now?). Nil if it leaves the corridor, breaks, or
    /// exceeds the bound.
    public static func evaluate(edges: [Int32], from origin: Int32, graph: PedestrianGraph,
                                corridor: Corridor, timeline: SunTimeline?, edgeSeconds: EdgeSeconds,
                                sunWeight: Double, prefer: RoutePreference = .sun) -> Route? {
        var index: [Int32: Int] = [:]
        for (i, e) in corridor.edges.enumerated() { index[e] = i }
        let w = maxSunWeight * min(max(sunWeight, 0), 1)
        let bound = corridor.distance * (1 + corridor.slack) + 1e-6
        var r = Route(nodes: [origin], edges: [], corridorIndex: [], metres: 0, seconds: 0, sunSeconds: 0,
                      cost: 0, edgeSun: [], edgeSlot: [], arrivalSeconds: [0], sunWeight: sunWeight,
                      labelsExpanded: 0, maxLabelsAtANode: 0, capHits: 0, computeMs: 0)
        var at = origin
        for e in edges {
            guard let i = index[e] else { return nil }
            let a = graph.edgeA[Int(e)], b = graph.edgeB[Int(e)]
            guard at == a || at == b else { return nil }
            let forward = at == a
            let next = forward ? b : a
            let s = forward ? edgeSeconds.forward[i] : edgeSeconds.backward[i]
            let (sun, k) = sunOn(timeline, edge: i, enteringAt: r.seconds, seconds: s)
            r.cost += edgeCost(seconds: s, sun: sun, weight: w, prefer: prefer, crossing: graph.isCrossing(Int(e)))
            r.sunSeconds += s * Double(sun)
            r.seconds += s
            r.metres += graph.edgeLen[Int(e)]
            r.edges.append(e); r.corridorIndex.append(i); r.edgeSun.append(sun); r.edgeSlot.append(k)
            r.nodes.append(next); r.arrivalSeconds.append(r.seconds)
            at = next
        }
        guard r.metres <= bound else { return nil }
        return r
    }

    /// Routes across λ values, deduplicated by edge sequence, kept only if Pareto-optimal
    /// on (seconds, sunSeconds), sorted fastest first.
    public static func ladder(graph: PedestrianGraph, corridor: Corridor, labels: DestinationLabels,
                              origin: Int32, timeline: SunTimeline?, edgeSeconds: EdgeSeconds,
                              prefer: RoutePreference = .sun,
                              weights: [Double] = stride(from: 0.0, through: 1.0, by: 0.1).map { $0 }) -> [Route] {
        var seen = Set<[Int32]>()
        var routes: [Route] = []
        for w in weights {
            guard let r = try? route(graph: graph, corridor: corridor, labels: labels, origin: origin,
                                     timeline: timeline, edgeSeconds: edgeSeconds, sunWeight: w,
                                     prefer: prefer),
                  seen.insert(r.edges).inserted else { continue }
            routes.append(r)
        }
        let light: (Route) -> Double = { prefer == .sun ? $0.sunSeconds : $0.seconds - $0.sunSeconds }
        let pareto = routes.filter { r in
            !routes.contains { o in
                o.seconds <= r.seconds + 1e-9 && light(o) >= light(r) - 1e-9 &&
                (o.seconds < r.seconds - 1e-9 || light(o) > light(r) + 1e-9)
            }
        }
        return pareto.sorted { $0.seconds < $1.seconds }
    }

    /// Keep the walker's current route unless the new optimum is clearly better: the
    /// remaining previous route costs at most `1 + tolerance` times the candidate.
    public static func shouldKeep(previous: Route, candidate: Route, tolerance: Double = 0.05) -> Bool {
        previous.cost <= candidate.cost * (1 + tolerance)
    }
}
