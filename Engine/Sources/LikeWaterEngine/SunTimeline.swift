import Foundation

// MARK: - Pace: how long each corridor edge takes to walk

/// A walker's flat-ground speed.
public struct WalkingPace: Sendable, Equatable, Hashable {
    public var metresPerSecond: Double
    public init(metresPerSecond: Double) { self.metresPerSecond = metresPerSecond }

    public static let relaxed = WalkingPace(metresPerSecond: 1.1)
    /// 1.4 m/s ≈ 5 km/h, the flat-walking assumption everyone uses.
    public static let normal = WalkingPace(metresPerSecond: 1.4)
    public static let brisk = WalkingPace(metresPerSecond: 1.7)
}

/// Seconds to walk each corridor edge in each direction. Slope makes the two differ
/// (uphill is slow, gentle downhill is slightly fast), so a route needs the direction.
public struct EdgeSeconds: Sendable {
    /// Parallel to `corridor.edges`: walking edgeA → edgeB.
    public var forward: [Double]
    /// Parallel to `corridor.edges`: walking edgeB → edgeA.
    public var backward: [Double]
    public init(forward: [Double], backward: [Double]) { self.forward = forward; self.backward = backward }
    public var count: Int { forward.count }
    /// Average seconds per metre of the corridor relative to flat walking at `pace`
    /// (≥ 1 in hills or with many crossings); stretches metre windows into time windows.
    public func stretch(lengths: [Double], pace: WalkingPace) -> Double {
        var flat = 0.0, actual = 0.0
        for i in forward.indices {
            flat += lengths[i] / pace.metresPerSecond
            actual += (forward[i] + backward[i]) / 2
        }
        return flat > 0 ? max(1, actual / flat) : 1
    }
}

/// The ETA model (PLAN.md §1.7.8): base pace × Tobler's hiking function for slope (from
/// the bundle's terrain), a wait at every marked crossing, stairs slower. Routing cost and
/// the displayed ETA use these same seconds, so "+2 min vs fastest" means minutes.
public struct PaceModel: Sendable {
    public var pace: WalkingPace
    public var crossingWaitSeconds: Double
    /// Stairs are walked at this fraction of the flat pace.
    public var stepsFactor: Double
    /// Terrain is 10 m; grades from very short edges or across bridges are noise.
    public static let maxGrade = 0.25
    public static let minGradeRun = 10.0

    public init(pace: WalkingPace = .normal, crossingWaitSeconds: Double = 12, stepsFactor: Double = 0.6) {
        self.pace = pace; self.crossingWaitSeconds = crossingWaitSeconds; self.stepsFactor = stepsFactor
    }

    /// Tobler's hiking function normalised to 1.0 on the flat: +10 % → 0.70, −5 % → 1.19
    /// (the fastest grade), −15 % → 0.84.
    public static func tobler(grade g: Double) -> Double {
        exp(-3.5 * abs(g + 0.05)) / exp(-0.175)
    }

    public func seconds(length: Double, rise: Double, flags: UInt8) -> Double {
        let grade = max(-Self.maxGrade, min(Self.maxGrade, rise / max(length, Self.minGradeRun)))
        var speed = pace.metresPerSecond * Self.tobler(grade: grade)
        if flags & EdgeFlag.steps != 0 { speed = pace.metresPerSecond * stepsFactor }
        var s = length / max(speed, 0.05)
        if flags & EdgeFlag.crossing != 0 { s += crossingWaitSeconds }
        return s
    }

    /// Per-direction seconds for `edges` (nil terrain → flat).
    public func edgeSeconds(graph: PedestrianGraph, edges: [Int32], terrain: TerrainGrid?) -> EdgeSeconds {
        var fwd = [Double](repeating: 0, count: edges.count)
        var bwd = [Double](repeating: 0, count: edges.count)
        let useTerrain = terrain.map { !$0.isEmpty || $0.fallback != nil } ?? false
        for (i, e) in edges.enumerated() {
            let ei = Int(e)
            let a = Int(graph.edgeA[ei]), b = Int(graph.edgeB[ei])
            var rise = 0.0
            if useTerrain, let terrain {
                rise = terrain.elevation(lat: graph.nodeLat[b], lon: graph.nodeLon[b])
                     - terrain.elevation(lat: graph.nodeLat[a], lon: graph.nodeLon[a])
            }
            let len = graph.edgeLen[ei], flags = graph.edgeFlags[ei]
            fwd[i] = seconds(length: len, rise: rise, flags: flags)
            bwd[i] = seconds(length: len, rise: -rise, flags: flags)
        }
        return EdgeSeconds(forward: fwd, backward: bwd)
    }
}

// MARK: - Sun by time of arrival

/// Sun scores per corridor edge per 15-minute slot of the absolute clock, for only the
/// slots in which a walker could be on that edge (PLAN.md §1.5).
public struct SunTimeline: Sendable {
    public var departure: Date
    public var slotSeconds: Double
    /// Absolute slot index (`floor(unixTime / slotSeconds)`) of `sun[0]`.
    public var firstSlot: Int
    /// Slot-major; corridor-local edge index; `.nan` = not reachable in that slot (unscored).
    public var sun: [[Float]]
    /// Fraction of the clear-sky beam per slot, read from the sky along the walk.
    public var beam: [Float]
    public var sunUp: [Bool]
    /// Sunset if it falls inside the walk.
    public var sunset: Date?
    public var scoredPairs: Int
    public var cacheHits: Int
    public var computeMs: Double

    public var slotCount: Int { sun.count }

    public init(departure: Date, slotSeconds: Double, firstSlot: Int, sun: [[Float]], beam: [Float],
                sunUp: [Bool], sunset: Date? = nil, scoredPairs: Int = 0, cacheHits: Int = 0,
                computeMs: Double = 0) {
        self.departure = departure; self.slotSeconds = slotSeconds; self.firstSlot = firstSlot
        self.sun = sun; self.beam = beam; self.sunUp = sunUp; self.sunset = sunset
        self.scoredPairs = scoredPairs; self.cacheHits = cacheHits; self.computeMs = computeMs
    }

    /// A timeline whose every slot shows the same per-edge sun (a test fake, and the
    /// departure-only baseline that ignores time of arrival).
    public init(constant sun: [Float], departure: Date, slots: Int, beam: Float = 1, slotSeconds: Double = 900) {
        self.init(departure: departure, slotSeconds: slotSeconds,
                  firstSlot: Int((departure.timeIntervalSince1970 / slotSeconds).rounded(.down)),
                  sun: Array(repeating: sun, count: max(1, slots)),
                  beam: Array(repeating: beam, count: max(1, slots)),
                  sunUp: Array(repeating: true, count: max(1, slots)))
    }

    /// Local slot index for `seconds` after departure, clamped into the timeline.
    public func slot(atSeconds seconds: Double) -> Int {
        let absolute = Int(((departure.timeIntervalSince1970 + seconds) / slotSeconds).rounded(.down))
        return min(max(absolute - firstSlot, 0), slotCount - 1)
    }

    /// Start of local slot `k`.
    public func slotStart(_ k: Int) -> Date {
        Date(timeIntervalSince1970: Double(firstSlot + k) * slotSeconds)
    }

    /// Effective sun on corridor-local edge `edge` in local slot `slot`: geometric sun ×
    /// beam. An unscored slot borrows the nearest scored one within two slots, else 0.5.
    public func effectiveSun(edge: Int, slot: Int) -> Float {
        guard slotCount > 0 else { return 0 }
        let k = min(max(slot, 0), slotCount - 1)
        guard sunUp[k] else { return 0 }
        var s = sun[k][edge]
        if s.isNaN {
            s = 0.5
            for d in 1...2 {
                if k - d >= 0, !sun[k - d][edge].isNaN { s = sun[k - d][edge]; break }
                if k + d < slotCount, !sun[k + d][edge].isNaN { s = sun[k + d][edge]; break }
            }
        }
        return s * beam[k]
    }

    /// Departure-only baseline: every slot replaced by the departure slot's scores and
    /// beam (what the app did before time-of-arrival; PLAN Part 3 #1).
    public func departureOnly() -> SunTimeline {
        var t = self
        t.sun = Array(repeating: sun[0].map { $0.isNaN ? 0.5 : $0 }, count: slotCount)
        t.beam = Array(repeating: beam[0], count: slotCount)
        t.sunUp = Array(repeating: sunUp[0], count: slotCount)
        return t
    }
}

/// Edge scores by (absolute slot, graph edge), kept across GPS fixes and departure-time
/// scrubbing so a fix 10 s later only scores the few edges whose windows moved.
public final class SunSlotCache: @unchecked Sendable {
    private var values: [Int64: Float] = [:]
    public init() {}
    @inline(__always) static func key(slot: Int, edge: Int32) -> Int64 { (Int64(slot) << 32) | Int64(UInt32(bitPattern: edge)) }
    public subscript(slot: Int, edge: Int32) -> Float? {
        get { values[Self.key(slot: slot, edge: edge)] }
        set { values[Self.key(slot: slot, edge: edge)] = newValue }
    }
    public var count: Int { values.count }
    public func drop(before slot: Int) { values = values.filter { ($0.key >> 32) >= Int64(slot) } }
    public func removeAll() { values.removeAll(keepingCapacity: true) }
}

public enum SunTimelineBuilder {
    /// Scores each corridor edge only for the slots its arrival window can fall in: the
    /// metre window [fromOrigin, latestFromOrigin + length] turned into seconds at the
    /// corridor's average pace (`stretch` covers hills and crossing waits), widened by one
    /// slot each side.
    public static func build(graph: PedestrianGraph, corridor: Corridor,
                             origin: (lat: Double, lon: Double), destination: (lat: Double, lon: Double),
                             departure: Date, pace: WalkingPace, edgeSeconds: EdgeSeconds,
                             slotSeconds: Double = 900, scorer: inout SunScorer,
                             cache: SunSlotCache, sky: SkyField?) -> SunTimeline {
        let t0 = CFAbsoluteTimeGetCurrent()
        let n = corridor.edges.count
        let lengths = corridor.edges.map { graph.edgeLen[Int($0)] }
        let stretch = edgeSeconds.stretch(lengths: lengths, pace: pace)
        let v = pace.metresPerSecond / stretch
        let dep = departure.timeIntervalSince1970
        let firstSlot = Int((dep / slotSeconds).rounded(.down))
        var lo = [Int](repeating: 0, count: n), hi = [Int](repeating: 0, count: n)
        var lastSlot = firstSlot
        for i in 0..<n {
            let a = dep + corridor.fromOrigin[i] / v
            let b = dep + (corridor.latestFromOrigin[i] + lengths[i]) / v
            lo[i] = max(firstSlot, Int((a / slotSeconds).rounded(.down)) - 1)
            hi[i] = Int((b / slotSeconds).rounded(.down)) + 1
            lastSlot = max(lastSlot, hi[i])
        }
        let slotCount = lastSlot - firstSlot + 1
        var sun = [[Float]](repeating: [Float](repeating: .nan, count: n), count: slotCount)
        var beam = [Float](repeating: 1, count: slotCount)
        var up = [Bool](repeating: false, count: slotCount)
        var scored = 0, hits = 0

        for k in 0..<slotCount {
            let absolute = firstSlot + k
            let centre = Date(timeIntervalSince1970: (Double(absolute) + 0.5) * slotSeconds)
            let p = Solar.position(latitude: origin.lat, longitude: origin.lon, date: centre)
            up[k] = p.isUp
            guard p.isUp else { continue }
            // Beam from the sky where the walker roughly is in this slot.
            let f = min(1, (Double(k) + 0.5) / Double(slotCount))
            let lat = origin.lat + f * (destination.lat - origin.lat)
            let lon = origin.lon + f * (destination.lon - origin.lon)
            if let c = sky?.condition(latitude: lat, longitude: lon, at: centre, sunElevation: p.elevation) {
                beam[k] = Float(c.beamStrength)
            }
            var todo: [Int32] = [], todoIndex: [Int] = []
            for i in 0..<n where lo[i] <= absolute && absolute <= hi[i] {
                let e = corridor.edges[i]
                if let cached = cache[absolute, e] { sun[k][i] = cached; hits += 1 }
                else { todo.append(e); todoIndex.append(i) }
            }
            if !todo.isEmpty {
                let scores = scorer.score(graph: graph, edges: todo, sun: p)
                for (j, i) in todoIndex.enumerated() {
                    sun[k][i] = scores[j]
                    cache[absolute, todo[j]] = scores[j]
                }
                scored += todo.count
            }
        }
        var sunset: Date?
        if let w = Solar.daylightWindow(latitude: origin.lat, longitude: origin.lon, containing: departure),
           w.sunset > departure, w.sunset.timeIntervalSince1970 < Double(lastSlot + 1) * slotSeconds {
            sunset = w.sunset
        }
        return SunTimeline(departure: departure, slotSeconds: slotSeconds, firstSlot: firstSlot,
                           sun: sun, beam: beam, sunUp: up, sunset: sunset, scoredPairs: scored,
                           cacheHits: hits, computeMs: (CFAbsoluteTimeGetCurrent() - t0) * 1000)
    }
}
