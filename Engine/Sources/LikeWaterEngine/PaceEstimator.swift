import Foundation

/// Learns how fast this walker actually walks (PLAN.md §1.7.8).
///
/// Fed every real GPS fix. The clock starts on the first fix that has moved from the
/// start (studying the map before setting off is not walking), and progress is the
/// distance walked between consecutive fixes — never the length of the route, which
/// changes whenever the slider, slack or hysteresis picks another one. Once the walker
/// has covered `minMetres` over at least `minSeconds`, the measured pace is blended
/// 50/50 with the setting for the remaining ETA. At arrival the walk's pace updates
/// `learned` (exponential average across walks), which the app persists and uses as the
/// default pace — that is what makes the second walk's ETA closer.
public struct PaceEstimator: Sendable {
    public static let minMetres = 300.0
    public static let minSeconds = 180.0
    /// Weight of the newest walk in the cross-walk average.
    public static let learningRate = 0.3
    /// A fix closer than this to the previous one is noise; farther than `maxStepMetres`
    /// is a jump (tunnel, bad fix) and counts nothing.
    public static let minStepMetres = 3.0
    public static let maxStepMetres = 150.0

    public var learned: Double?
    public private(set) var predictedSeconds: Double = 0
    public private(set) var startedAt: Date?
    public private(set) var walkedMetres: Double = 0
    public private(set) var lastAt: Date?
    private var lastFix: (lat: Double, lon: Double)?
    private var walking = false

    public init(learned: Double? = nil) { self.learned = learned }

    /// A new walk: the model predicts `seconds` for it. The clock starts at the first move.
    public mutating func start(seconds: Double, at date: Date) {
        predictedSeconds = seconds
        startedAt = nil; walkedMetres = 0; lastAt = nil; lastFix = nil; walking = true
    }

    public var isWalking: Bool { walking }

    /// A real GPS fix.
    public mutating func observe(lat: Double, lon: Double, at date: Date) {
        guard walking else { return }
        guard let prev = lastFix else { lastFix = (lat, lon); lastAt = date; return }
        let step = haversineMeters(prev.lat, prev.lon, lat, lon)
        guard step >= Self.minStepMetres else {
            // Still standing: the clock will start from the last fix before the first move.
            if startedAt == nil { lastAt = date }
            return
        }
        lastFix = (lat, lon)
        guard step <= Self.maxStepMetres else { lastAt = date; return }
        if startedAt == nil { startedAt = lastAt ?? date }
        walkedMetres += step
        lastAt = date
    }

    public var elapsed: Double { guard let s = startedAt, let l = lastAt else { return 0 }; return l.timeIntervalSince(s) }

    /// Measured pace so far, once there is enough walk to trust it.
    public var measured: Double? {
        guard walkedMetres >= Self.minMetres, elapsed >= Self.minSeconds else { return nil }
        return walkedMetres / elapsed
    }

    /// Remaining seconds from the pace model, rescaled by the walker's measured pace.
    public func remainingSeconds(model seconds: Double, settingPace: Double) -> Double {
        guard let m = measured, m > 0.2 else { return seconds }
        let blended = 0.5 * m + 0.5 * settingPace
        return seconds * settingPace / blended
    }

    /// Ends the walk: folds its pace into `learned` and returns predicted vs actual seconds
    /// (actual from the first move to arrival); nil when the walk never started.
    @discardableResult
    public mutating func arrive(at date: Date) -> (predicted: Double, actual: Double)? {
        defer { walking = false; startedAt = nil; lastFix = nil }
        guard let s = startedAt else { return nil }
        // The walk's pace is over the time spent moving; the seconds spent standing at the
        // door before the app noticed count against the prediction, not the walker.
        if let m = measured {
            learned = learned.map { (1 - Self.learningRate) * $0 + Self.learningRate * m } ?? m
        }
        lastAt = date
        return (predictedSeconds, date.timeIntervalSince(s))
    }
}
