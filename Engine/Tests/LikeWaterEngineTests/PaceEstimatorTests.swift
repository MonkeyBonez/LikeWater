import XCTest
@testable import LikeWaterEngine

final class PaceEstimatorTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    /// Walking east along 37.78° at `metres` per step.
    func fix(_ metresEast: Double) -> (Double, Double) { (37.78, -122.40 + metresEast / (111_320 * cos(37.78 * .pi / 180))) }

    func testTheClockStartsOnTheFirstMoveNotWhenTheDestinationIsSet() {
        var p = PaceEstimator()
        p.start(seconds: 1430, at: t0)
        let (lat, lon) = fix(0)
        p.observe(lat: lat, lon: lon, at: t0)                       // standing still, reading the map
        p.observe(lat: lat, lon: lon, at: t0.addingTimeInterval(90))
        XCTAssertNil(p.startedAt)
        for i in 1...50 {                                            // then 10 m every 7 s = 1.43 m/s
            let (la, lo) = fix(Double(i) * 10)
            p.observe(lat: la, lon: lo, at: t0.addingTimeInterval(90 + Double(i) * 7))
        }
        XCTAssertEqual(p.walkedMetres, 500, accuracy: 1)
        XCTAssertEqual(p.elapsed, 350, accuracy: 0.001)
        XCTAssertEqual(p.measured!, 1.43, accuracy: 0.01)
    }

    func testNoOpinionUntilEnoughWalkAndJumpsDontCount() {
        var p = PaceEstimator()
        p.start(seconds: 1000, at: t0)
        for i in 0...20 { let (la, lo) = fix(Double(i) * 10); p.observe(lat: la, lon: lo, at: t0.addingTimeInterval(Double(i) * 7)) }
        XCTAssertNil(p.measured, "200 m is not enough")
        XCTAssertEqual(p.remainingSeconds(model: 800, settingPace: 1.4), 800)
        let before = p.walkedMetres
        let (la, lo) = fix(2_000)                                    // a 1.8 km jump: bad fix
        p.observe(lat: la, lon: lo, at: t0.addingTimeInterval(150))
        XCTAssertEqual(p.walkedMetres, before)
    }

    func testASlowWalkerStretchesTheRemainingEtaHalfway() {
        var p = PaceEstimator()
        p.start(seconds: 1430, at: t0)
        for i in 0...50 { let (la, lo) = fix(Double(i) * 10); p.observe(lat: la, lon: lo, at: t0.addingTimeInterval(Double(i) * 10)) }  // 1.0 m/s
        XCTAssertEqual(p.measured!, 1.0, accuracy: 0.01)
        // Blend 0.5·1.0 + 0.5·1.4 = 1.2 → 1.4/1.2 longer.
        XCTAssertEqual(p.remainingSeconds(model: 1071, settingPace: 1.4), 1071 * 1.4 / 1.2, accuracy: 1)
    }

    func testArrivalTeachesTheNextWalk() {
        var p = PaceEstimator()
        p.start(seconds: 1000, at: t0)
        for i in 0...120 { let (la, lo) = fix(Double(i) * 10); p.observe(lat: la, lon: lo, at: t0.addingTimeInterval(Double(i) * 8.333)) }  // 1.2 m/s
        let result = p.arrive(at: t0.addingTimeInterval(1170))
        XCTAssertEqual(result?.predicted, 1000)
        XCTAssertEqual(result?.actual ?? 0, 1170, accuracy: 0.001)
        XCTAssertEqual(p.learned!, 1.2, accuracy: 0.01)
        XCTAssertFalse(p.isWalking)
        p.start(seconds: 700, at: t0.addingTimeInterval(5000))
        for i in 0...100 { let (la, lo) = fix(Double(i) * 10); p.observe(lat: la, lon: lo, at: t0.addingTimeInterval(5000 + Double(i) * 5)) }  // 2.0 m/s
        let before = p.learned!
        p.arrive(at: t0.addingTimeInterval(5500))
        XCTAssertEqual(p.learned!, 0.7 * before + 0.3 * 2.0, accuracy: 0.01)
    }
}
