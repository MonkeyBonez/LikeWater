import XCTest

/// The suggested route inside the corridor: slider, ETA, sun strip, sunset, hysteresis
/// (PLAN.md A10). Runs against the bundled San Francisco graph; no network.
final class RouteUITests: XCTestCase {
    private var app: XCUIApplication!

    private static let soma = "37.78415,-122.40060"
    private static let somaWest = "37.7785,-122.3990"
    private static let caltrain = "37.77639,-122.39466"
    private static let unionSquare = "37.78805,-122.40755"
    private static let ferryBuilding = "37.79555,-122.39365"

    override func setUpWithError() throws { continueAfterFailure = true }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    private var routeReadout: XCUIElement { app.staticTexts["routeReadout"] }
    private var eta: XCUIElement { app.staticTexts["etaText"] }

    @discardableResult
    private func waitForRoute(timeout: TimeInterval = 90) -> String {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if routeReadout.exists, routeReadout.label.contains("min") { return routeReadout.label }
            usleep(300_000)
        }
        shoot("FAILURE-no-route")
        XCTFail("no route readout")
        return ""
    }

    /// "9 min · 42% sun · +1 min vs fastest" → (9, 42).
    private func parse(_ readout: String) -> (minutes: Int, sun: Int)? {
        let parts = readout.components(separatedBy: " · ")
        guard let m = Int(parts.first?.split(separator: " ").first ?? ""),
              let s = parts.first(where: { $0.hasSuffix("% sun") }).flatMap({ Int($0.dropLast(5)) }) else { return nil }
        return (m, s)
    }

    private func routeArgs(_ weight: Double, slack: Double, extra: [String] = []) -> [String] {
        ["-uiTestStart", Self.somaWest, "-uiTestDestination", Self.caltrain, "-uiTestDestinationName", "SF Caltrain",
         "-uiTestLayer", "Sun", "-uiTestDate", "2026-09-23T16:00:00Z", "-uiTestSky", "clear",
         "-uiTestSunWeight", String(weight), "-uiTestSlack", String(slack), "-uiTestPace", "1.4",
         "-uiTestPrefer", "sun"] + extra
    }

    /// Fastest vs Sunniest: the sunny end costs time and buys sun (9 am, low sun from the
    /// east, SoMa's one-sided shade).
    func testSunWeightChangesTheRoute() throws {
        var results: [(Int, Int)] = []
        for w in [0.0, 1.0] {
            launch(routeArgs(w, slack: 0.1))
            let text = waitForRoute()
            shoot("route-weight-\(w)")
            results.append(try XCTUnwrap(parse(text), "unreadable: \(text)"))
            app.terminate()
        }
        let (fast, sunny) = (results[0], results[1])
        XCTAssertGreaterThanOrEqual(sunny.0, fast.0, "sunniest can't be faster than fastest")
        XCTAssertGreaterThan(sunny.1, fast.1, "sunniest must buy sun: \(results)")
    }

    /// Dragging the slider re-routes without recomputing the corridor.
    func testSliderDetentsMoveTheReadout() throws {
        launch(routeArgs(0, slack: 0.1, extra: ["-uiTestDebug", "1"]))
        let before = waitForRoute()
        let slider = app.sliders["sunWeightSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        XCTAssertTrue(before.hasSuffix("fastest"), before)
        slider.adjust(toNormalizedSliderPosition: 1.0)
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, routeReadout.label == before { usleep(200_000) }
        shoot("slider-at-sunniest")
        XCTAssertNotEqual(routeReadout.label, before)
        XCTAssertFalse(routeReadout.label.hasSuffix("· fastest"), routeReadout.label)
        XCTAssertTrue(app.otherElements["sunStrip"].exists || app.images["sunStrip"].exists
                      || app.descendants(matching: .any)["sunStrip"].exists)
    }

    /// Leave Union Square at 6:50 pm; SF's sun sets at 7:07 pm, inside a 25-minute walk.
    func testSunsetMidWalkIsAnnounced() throws {
        launch(["-uiTestStart", Self.unionSquare, "-uiTestDestination", Self.ferryBuilding,
                "-uiTestDestinationName", "Ferry Building", "-uiTestLayer", "Sun",
                "-uiTestDate", "2026-09-24T01:50:00Z", "-uiTestSky", "clear", "-uiTestSunWeight", "0.5"])
        waitForRoute()
        let note = app.staticTexts["sunsetNote"]
        XCTAssertTrue(note.waitForExistence(timeout: 10))
        shoot("sunset-mid-walk")
        XCTAssertTrue(note.label.contains("into your walk"), note.label)
        XCTAssertTrue(note.label.contains("Sun sets 7:0"), note.label)
        let strip = app.descendants(matching: .any)["sunStrip"].firstMatch
        XCTAssertTrue(strip.exists)
        XCTAssertTrue((strip.value as? String ?? "").contains("sunset at"), "\(strip.value ?? "nil")")
    }

    /// The ETA is a product readout now, not a Sun-layer extra.
    func testEtaIsShownOnEveryLayer() throws {
        launch(["-uiTestStart", Self.soma, "-uiTestDestination", Self.caltrain,
                "-uiTestDestinationName", "SF Caltrain", "-uiTestDate", "2026-09-23T17:30:00Z", "-uiTestSky", "clear"])
        waitForRoute()
        let picker = app.segmentedControls["layerPicker"]
        for name in ["Crossings", "Interest", "Sun"] {
            picker.buttons[name].tap()
            usleep(1_200_000)
            XCTAssertTrue(eta.waitForExistence(timeout: 10), "no ETA on \(name)")
            XCTAssertTrue(eta.label.contains("min · arrive"), "\(name): \(eta.label)")
        }
        // ~1.3 km at 1.4 m/s plus crossings: 15–25 min.
        let minutes = Int(eta.label.components(separatedBy: " · ")[1].split(separator: " ")[0]) ?? 0
        XCTAssertTrue((12...25).contains(minutes), eta.label)
        shoot("eta-sun-layer")
    }

    /// Walking the suggested route keeps it (hysteresis) and counts the minutes down.
    func testRouteStaysWhileWalkingIt() throws {
        launch(["-uiTestStart", Self.unionSquare, "-uiTestDestination", Self.ferryBuilding,
                "-uiTestDestinationName", "Ferry Building", "-uiTestLayer", "Sun",
                "-uiTestDate", "2026-09-23T20:00:00Z", "-uiTestSky", "clear", "-uiTestSunWeight", "1",
                "-uiTestDebug", "1"])
        waitForRoute()
        let stats = app.staticTexts["routeStats"]
        XCTAssertTrue(stats.waitForExistence(timeout: 10))
        func minutesLeft() -> Int { Int(eta.label.components(separatedBy: " · ")[1].split(separator: " ")[0]) ?? -1 }
        var last = minutesLeft()
        var kept = 0
        for step in 0..<6 {
            let before = eta.label
            app.buttons["stepButton"].tap()
            let deadline = Date().addingTimeInterval(10)
            while Date() < deadline, eta.label == before { usleep(200_000) }
            usleep(300_000)
            let now = minutesLeft()
            XCTAssertLessThan(now, last, "step \(step): \(eta.label)")
            last = now
            if (stats.value as? String) == "kept" { kept += 1 }
        }
        shoot("after-six-steps")
        XCTAssertGreaterThanOrEqual(kept, 4, "route should stay put while it is being walked")
    }
}
