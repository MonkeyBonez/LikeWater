import Foundation

/// Learns how fast this walker actually walks (PLAN.md §1.7.8).
///
/// Fed with the remaining route length on every real GPS fix. Once the walker has covered
/// `minMetres` over at least `minSeconds`, the measured pace (progress ÷ elapsed) is
/// blended 50/50 with the setting for the remaining ETA. At arrival the walk's measured
/// pace updates `learned` (exponential average across walks), which the app persists and
/// uses as the default pace — that is what makes the second walk's ETA closer.
public struct PaceEstimator: Sendable, Equatable {
    public static let minMetres = 300.0
    public static let minSeconds = 180.0
    /// Weight of the newest walk in the cross-walk average.
    public static let learningRate = 0.3

    public var learned: Double?
    public private(set) var startedAt: Date?
    public private(set) var startMetres: Double = 0
    public private(set) var predictedSeconds: Double = 0
    public private(set) var lastRemaining: Double = 0
    public private(set) var lastAt: Date?

    public init(learned: Double? = nil) { self.learned = learned }

    /// A new walk: the route is `metres` long and the model predicts `seconds`.
    public mutating func start(metres: Double, seconds: Double, at date: Date) {
        startedAt = date; startMetres = metres; predictedSeconds = seconds
        lastRemaining = metres; lastAt = date
    }

    public mutating func observe(remainingMetres: Double, at date: Date) {
        guard startedAt != nil else { return }
        lastRemaining = remainingMetres; lastAt = date
    }

    public var walkedMetres: Double { max(0, startMetres - lastRemaining) }
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

    /// Ends the walk: folds its pace into `learned` and returns predicted vs actual seconds.
    @discardableResult
    public mutating func arrive(at date: Date) -> (predicted: Double, actual: Double)? {
        guard let s = startedAt else { return nil }
        let actual = date.timeIntervalSince(s)
        lastRemaining = 0; lastAt = date
        if let m = measured {
            learned = learned.map { (1 - Self.learningRate) * $0 + Self.learningRate * m } ?? m
        }
        let result = (predictedSeconds, actual)
        startedAt = nil
        return result
    }
}
