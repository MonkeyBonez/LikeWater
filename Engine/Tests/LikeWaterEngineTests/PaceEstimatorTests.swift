import XCTest
@testable import LikeWaterEngine

final class PaceEstimatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func testNoOpinionUntilEnoughWalk() {
        var p = PaceEstimator()
        p.start(metres: 2000, seconds: 1430, at: t0)
        p.observe(remainingMetres: 1800, at: t0.addingTimeInterval(150))   // 200 m, 2.5 min
        XCTAssertNil(p.measured)
        XCTAssertEqual(p.remainingSeconds(model: 1000, settingPace: 1.4), 1000)
    }

    func testASlowWalkerStretchesTheRemainingEtaHalfway() {
        var p = PaceEstimator()
        p.start(metres: 2000, seconds: 1430, at: t0)
        p.observe(remainingMetres: 1500, at: t0.addingTimeInterval(500))   // 500 m in 500 s = 1.0 m/s
        XCTAssertEqual(p.measured!, 1.0, accuracy: 1e-9)
        // Blend 0.5·1.0 + 0.5·1.4 = 1.2 → 1.4/1.2 longer.
        XCTAssertEqual(p.remainingSeconds(model: 1071, settingPace: 1.4), 1071 * 1.4 / 1.2, accuracy: 1e-6)
    }

    func testArrivalTeachesTheNextWalk() {
        var p = PaceEstimator()
        p.start(metres: 1400, seconds: 1000, at: t0)
        p.observe(remainingMetres: 200, at: t0.addingTimeInterval(1000))   // 1.2 m/s
        let result = p.arrive(at: t0.addingTimeInterval(1170))
        XCTAssertEqual(result?.predicted, 1000)
        XCTAssertEqual(result?.actual, 1170)
        XCTAssertEqual(p.learned!, 1400.0 / 1170.0, accuracy: 1e-9)
        p.start(metres: 1000, seconds: 700, at: t0.addingTimeInterval(5000))
        p.observe(remainingMetres: 0, at: t0.addingTimeInterval(5500))     // 2.0 m/s
        let before = p.learned!
        p.arrive(at: t0.addingTimeInterval(5500))
        XCTAssertEqual(p.learned!, 0.7 * before + 0.3 * 2.0, accuracy: 1e-9)
    }
}
