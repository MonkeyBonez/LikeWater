import Foundation

/// Distance-to-destination labels for the loaded graph.
///
/// These are the expensive part, and they are *invariant while the user walks*:
/// `dTo[n]` does not depend on where the user is, only on the destination and the graph.
/// So they are computed once per destination and reused for every location update.
public struct DestinationLabels {
    public let destNode: Int32
    /// dTo[n] = walking distance from n to the destination (.infinity if unreached).
    public let dTo: [Double]
    /// Distance from the origin the labels were seeded against, used to bound the search.
    public let seedDistance: Double
    /// The slack these labels were expanded for: `dTo` is only valid out to
    /// `seedDistance * (1 + coveredSlack)`. Asking for a wider corridor than this would
    /// silently truncate it, so `corridor(...)` refuses instead.
    public let coveredSlack: Double
    public let settledNodes: Int
    public let computeMs: Double
}

public struct Corridor {
    /// Shortest walking distance from the current node to the destination.
    public var distance: Double
    public var slack: Double
    /// Edge indices that lie on some path within `distance * (1 + slack)`.
    public var edges: [Int32]
    /// Parallel to `edges`: extra metres this edge costs versus the shortest path.
    public var excess: [Double]
    /// Subset of `edges` tagged as marked crossings.
    public var crossingEdges: [Int32]
    /// Free choices at the next real decision point. A GPS fix usually snaps to a mid-block
    /// sidewalk vertex where there is only one way forward, so reporting the count at that
    /// node is useless; this walks forward through forced steps to the first node that
    /// actually offers a choice.
    public var choicesHere: Int
    /// Metres to that decision point (0 when the user is standing on it).
    public var metersToDecision: Double
    /// Nodes touched by the forward flood (a cost measure, ~ corridor size, not graph size).
    public var nodesExplored: Int
    public var computeMs: Double
    /// True when there is no free choice: a single line to follow.
    public var isCollapsed: Bool { choicesHere <= 1 }
}

public enum CorridorError: Error, LocalizedError {
    case destinationUnreachable
    case originOffGraph
    case labelsTooNarrow(covered: Double, requested: Double)

    public var errorDescription: String? {
        switch self {
        case .destinationUnreachable: return "No walking route to that destination in the loaded area."
        case .originOffGraph: return "Could not snap your position to a walkable street."
        case .labelsTooNarrow(let covered, let requested):
            return "Destination labels cover slack \(covered) but \(requested) was requested."
        }
    }
}

/// Per-graph working memory for `corridor`, reused across calls so a location update
/// costs what the corridor touches rather than an allocation the size of the city
/// (three full arrays per GPS fix was ~25 MB in New York).
public final class CorridorScratch {
    fileprivate var g: [Double]
    fileprivate var closed: [Bool]
    fileprivate var edgeExcess: [Double]
    fileprivate var touchedNodes: [Int32] = []
    public let nodeCount: Int
    public let edgeCount: Int

    public init(graph: PedestrianGraph) {
        nodeCount = graph.nodeCount; edgeCount = graph.edgeCount
        g = [Double](repeating: .infinity, count: graph.nodeCount)
        closed = [Bool](repeating: false, count: graph.nodeCount)
        edgeExcess = [Double](repeating: .infinity, count: graph.edgeCount)
    }

    fileprivate func fits(_ graph: PedestrianGraph) -> Bool {
        graph.nodeCount == nodeCount && graph.edgeCount == edgeCount
    }
}

/// Computes the corridor: the set of street segments lying on *some* path to the
/// destination no longer than `distance * (1 + slack)`.
///
/// Rather than the naive "two full Dijkstras per destination", this runs:
///
///  1. **One backward Dijkstra from the destination**, bounded: it stops expanding once the
///     popped distance exceeds `D * (1 + slack)`, where `D` is learned the moment the
///     origin is settled. This yields `dTo[]` and is done once per destination.
///
///  2. **A forward flood from the user that is A\* with `dTo` as its heuristic.** Because
///     `dTo` is the *exact* remaining distance, the heuristic is perfect and consistent:
///     `f = g + dTo` is non-decreasing, and the search expands exactly the nodes whose
///     best path through them is within the slack bound. So the per-location-update cost
///     is proportional to the size of the corridor, not the size of the graph — which is
///     what makes it cheap enough to rerun on *every* GPS fix rather than only on
///     corridor exit. The result is exact for any slack, not an approximation.
public enum CorridorEngine {

    /// Step 1 — backward Dijkstra from the destination, bounded once the origin is reached.
    public static func labels(graph: PedestrianGraph, destination: Int32, origin: Int32, slack: Double) throws -> DestinationLabels {
        let t0 = CFAbsoluteTimeGetCurrent()
        let n = graph.nodeCount
        var dTo = [Double](repeating: .infinity, count: n)
        var heap = MinHeap()
        heap.reserve(1024)
        dTo[Int(destination)] = 0
        heap.push(0, destination)

        var limit = Double.infinity
        var seed = Double.infinity
        var settled = 0

        graph.adjStart.withUnsafeBufferPointer { start in
        graph.adjNode.withUnsafeBufferPointer { nbr in
        graph.adjEdge.withUnsafeBufferPointer { eid in
        graph.edgeLen.withUnsafeBufferPointer { len in
            while let (d, u) = heap.pop() {
                if d > dTo[Int(u)] { continue }
                if d > limit { break }
                settled += 1
                if u == origin && seed == .infinity {
                    seed = d
                    // Everything the corridor can reference lies within D * (1 + slack).
                    limit = d * (1 + slack) + 1e-6
                }
                let lo = Int(start[Int(u)]), hi = Int(start[Int(u) + 1])
                for k in lo..<hi {
                    let v = Int(nbr[k])
                    let nd = d + len[Int(eid[k])]
                    if nd < dTo[v] {
                        dTo[v] = nd
                        heap.push(nd, Int32(v))
                    }
                }
            }
        }}}}

        guard seed.isFinite else { throw CorridorError.destinationUnreachable }
        return DestinationLabels(destNode: destination, dTo: dTo, seedDistance: seed,
                                 coveredSlack: slack, settledNodes: settled,
                                 computeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// Step 2 — forward A* flood from the user's node, bounded by the slack envelope.
    public static func corridor(graph: PedestrianGraph, labels: DestinationLabels,
                         origin: Int32, slack: Double, scratch: CorridorScratch? = nil) throws -> Corridor {
        let t0 = CFAbsoluteTimeGetCurrent()
        let dTo = labels.dTo
        let D = dTo[Int(origin)]
        guard D.isFinite else { throw CorridorError.destinationUnreachable }
        let bound = D * (1 + slack) + 1e-6
        // dTo is only valid inside the radius the backward search was bounded to.
        guard bound <= labels.seedDistance * (1 + labels.coveredSlack) + 1e-6 else {
            throw CorridorError.labelsTooNarrow(covered: labels.coveredSlack, requested: slack)
        }

        let work = (scratch.map { $0.fits(graph) } ?? false) ? scratch! : CorridorScratch(graph: graph)
        // Reset only what the previous call touched.
        for u in work.touchedNodes { work.g[Int(u)] = .infinity; work.closed[Int(u)] = false }
        work.touchedNodes.removeAll(keepingCapacity: true)
        var heap = MinHeap()
        heap.reserve(1024)
        work.g[Int(origin)] = 0
        work.touchedNodes.append(origin)
        heap.push(dTo[Int(origin)], origin)

        var settled: [Int32] = []
        settled.reserveCapacity(2048)
        var explored = 0

        while let (f, u) = heap.pop() {
            if f > bound { break }            // f is monotone: safe global cut-off
            if work.closed[Int(u)] { continue }
            work.closed[Int(u)] = true
            settled.append(u)
            explored += 1
            let gu = work.g[Int(u)]
            let lo = Int(graph.adjStart[Int(u)]), hi = Int(graph.adjStart[Int(u) + 1])
            for k in lo..<hi {
                let v = Int(graph.adjNode[k])
                let nd = gu + graph.edgeLen[Int(graph.adjEdge[k])]
                let h = dTo[v]
                if !h.isFinite || nd + h > bound { continue }
                if nd < work.g[v] {
                    if work.g[v].isInfinite { work.touchedNodes.append(Int32(v)) }
                    work.g[v] = nd
                    heap.push(nd + h, Int32(v))
                }
            }
        }

        // Collect corridor edges. Every corridor edge has its A-end settled above
        // (dTo[A] <= L + dTo[B] implies f(A) <= bound), so sweeping the settled nodes'
        // out-edges is exhaustive. Two passes keep it O(edges in corridor).
        var touchedEdges: [Int32] = []
        touchedEdges.reserveCapacity(2048)

        for u in settled {
            let gu = work.g[Int(u)]
            let lo = Int(graph.adjStart[Int(u)]), hi = Int(graph.adjStart[Int(u) + 1])
            for k in lo..<hi {
                let v = Int(graph.adjNode[k])
                let e = Int(graph.adjEdge[k])
                let h = dTo[v]
                guard h.isFinite else { continue }
                // PRD filter: d_from[A] + L + d_to[B] <= D * (1 + s), checked in both
                // orientations because each undirected edge is visited from both ends.
                let total = gu + graph.edgeLen[e] + h
                guard total <= bound else { continue }
                if work.edgeExcess[e].isInfinite { touchedEdges.append(Int32(e)) }
                work.edgeExcess[e] = min(work.edgeExcess[e], total - D)
            }
        }

        var edges: [Int32] = []
        var excess: [Double] = []
        var crossings: [Int32] = []
        edges.reserveCapacity(touchedEdges.count)
        excess.reserveCapacity(touchedEdges.count)
        for e in touchedEdges {
            edges.append(e)
            excess.append(work.edgeExcess[Int(e)])
            work.edgeExcess[Int(e)] = .infinity
            if graph.isCrossing(Int(e)) { crossings.append(e) }
        }

        let decision = nextDecision(graph: graph, dTo: dTo, g: work.g, origin: origin, bound: bound)

        return Corridor(distance: D, slack: slack, edges: edges, excess: excess,
                        crossingEdges: crossings, choicesHere: decision.choices,
                        metersToDecision: decision.meters,
                        nodesExplored: explored,
                        computeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }

    /// Walks forward through forced (single-option) corridor steps and reports the number of
    /// free choices at the first node that offers more than one, plus how far away it is.
    private static func nextDecision(graph: PedestrianGraph, dTo: [Double], g: [Double],
                                     origin: Int32, bound: Double) -> (choices: Int, meters: Double) {
        var current = origin
        var walked = 0.0
        for _ in 0..<64 {
            var count = 0
            var onlyNext: Int32 = -1
            var onlyLength = 0.0
            let lo = Int(graph.adjStart[Int(current)]), hi = Int(graph.adjStart[Int(current) + 1])
            let here = dTo[Int(current)]
            for k in lo..<hi {
                let v = Int(graph.adjNode[k])
                let h = dTo[v]
                guard h.isFinite, h < here else { continue }        // must make progress
                let L = graph.edgeLen[Int(graph.adjEdge[k])]
                guard g[Int(current)] + L + h <= bound else { continue }
                count += 1
                if count == 1 { onlyNext = Int32(v); onlyLength = L }
            }
            if count != 1 { return (count, walked) }
            walked += onlyLength
            current = onlyNext
            if walked > 400 { return (1, walked) }
        }
        return (1, walked)
    }
}
