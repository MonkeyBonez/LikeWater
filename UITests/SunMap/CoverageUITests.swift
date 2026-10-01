import XCTest
import CoreLocation

/// Load-anywhere behaviour (PLAN.md §2 C): coverage decided by the whole screen, a calm
/// "not built yet" state with the sky kept, partial coverage at a metro's edge, and the
/// demo-area status that must not outlive a pan. Needs `cd Server && python3 -m http.server 8765`.
final class CoverageUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/manifest.json")!)
        request.timeoutInterval = 3
        let done = expectation(description: "server")
        var ok = false
        URLSession.shared.dataTask(with: request) { data, _, _ in ok = data != nil; done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        try XCTSkipUnless(ok, "no bundle server on 127.0.0.1:8765")
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func launch(_ extra: [String]) {
        app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", "http://127.0.0.1:8765/", "-uiTestSky", "clear",
                               "-uiTestDate", "2026-09-23T19:00:00Z"] + extra
        app.launch()
    }

    private var banner: XCUIElement { app.otherElements["coverageBanner"] }
    private var status: XCUIElement { app.staticTexts["sunStatus"] }

    /// Denver: nothing built. The banner says so, names the nearest built place, keeps the
    /// sky and sun (they work anywhere), and shows no request button without an endpoint.
    func testUncoveredAreaShowsTheBannerAndTheSky() throws {
        let t0 = Date()
        launch(["-uiTestCenter", "39.7392,-104.9903"])
        XCTAssertTrue(banner.waitForExistence(timeout: 30), "no coverage banner")
        let seconds = Date().timeIntervalSince(t0)
        shoot("denver-not-built")
        XCTAssertTrue(app.staticTexts["No sun data here yet"].exists)
        XCTAssertTrue(app.staticTexts.containing(NSPredicate(format: "label BEGINSWITH 'Nearest with sun data'")).firstMatch.exists)
        XCTAssertEqual(app.staticTexts["skyStatus"].label, "Clear sky")
        XCTAssertTrue(app.staticTexts["sunReadout"].label.contains("el "), app.staticTexts["sunReadout"].label)
        XCTAssertFalse(app.buttons["requestCoverageButton"].exists, "no endpoint configured, so no button")
        XCTAssertFalse(app.staticTexts["sunStats"].exists, "nothing to paint")
        print("time to banner: \(String(format: "%.1f", seconds)) s")
    }

    /// Seattle's north edge: half the screen is outside the metro; the half inside paints.
    func testPartialCoverageAtTheMetroEdge() throws {
        launch(["-uiTestCenter", "47.757,-122.33"])
        let stats = app.staticTexts["sunStats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 120), "the covered half must still paint")
        XCTAssertTrue(stats.label.contains("Seattle"), stats.label)
        let deadline = Date().addingTimeInterval(20)
        while Date() < deadline, !(status.exists && status.label.contains("Only part")) { usleep(300_000) }
        shoot("seattle-north-edge")
        XCTAssertEqual(status.label, "Only part of this screen has sun data")
        XCTAssertFalse(banner.exists)
    }

    /// The fix is somewhere unbuilt, so the demo area shows and says so; once the user pans
    /// the map, that status must go (it used to stick: "showing SoMa" after leaving SoMa).
    func testPanningClearsTheDemoStatus() throws {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 39.7392, longitude: -104.9903))
        launch([])
        let deadline = Date().addingTimeInterval(40)
        while Date() < deadline, !(status.exists && status.label.contains("showing SoMa")) { usleep(300_000) }
        shoot("demo-area")
        XCTAssertTrue(status.exists && status.label.contains("showing SoMa"), status.exists ? status.label : "no status")
        app.maps.firstMatch.swipeLeft()
        let after = Date().addingTimeInterval(15)
        while Date() < after, status.exists, status.label.contains("showing SoMa") { usleep(300_000) }
        shoot("after-pan")
        XCTAssertFalse(status.exists && status.label.contains("showing SoMa"), "stale demo status after a pan")
    }
}
