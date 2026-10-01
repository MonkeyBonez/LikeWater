import XCTest
import CoreLocation

/// Before there is a walk, Like Water's map paints the sun on the sidewalks around
/// whatever you are looking at; a destination swaps that for the corridor, and clearing
/// the destination brings it back.
final class AmbientSunUITests: XCTestCase {

    private var app: XCUIApplication!

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private var stats: XCUIElement { app.staticTexts["ambientStats"] }

    private func waitForStats(containing text: String, timeout: TimeInterval = 120,
                              changedFrom previous: String? = nil) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stats.exists, stats.label.contains(text), stats.label != previous { return true }
            usleep(400_000)
        }
        return false
    }

    func testSunAroundTheMapBeforeAWalk() throws {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestStart", "37.78415,-122.40060", "-uiTestDate", "2026-09-23T20:00:00Z"]
        app.launch()
        XCTAssertTrue(waitForStats(containing: "San Francisco"), "no sun field without a destination")
        sleep(2)
        shoot("ambient-10-soma-no-destination")
        XCTAssertTrue(app.staticTexts["ambientTitle"].exists)
        XCTAssertTrue(app.staticTexts["scrubTime"].exists, "the time scrubber is there before a walk")
        let before = stats.label

        // Pan the map: the field follows what you are looking at.
        let map = app.maps.firstMatch
        XCTAssertTrue(map.waitForExistence(timeout: 5))
        map.swipeLeft(); map.swipeLeft()
        XCTAssertTrue(waitForStats(containing: "San Francisco", timeout: 60, changedFrom: before),
                      "panning must redraw the field: still \(stats.label)")
        shoot("ambient-11-after-pan")

    }

    func testClearingTheDestinationBringsTheSunBack() throws {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestStart", "37.78415,-122.40060", "-uiTestDate", "2026-09-23T20:00:00Z",
                               "-uiTestDestination", "37.79555,-122.39365", "-uiTestDestinationName", "Ferry Building"]
        app.launch()
        let subtitle = app.staticTexts["subtitle"]
        XCTAssertTrue(subtitle.waitForExistence(timeout: 120), "corridor first")
        XCTAssertFalse(stats.exists, "the corridor replaces the ambient field")
        app.buttons["clearButton"].tap()
        XCTAssertTrue(waitForStats(containing: "San Francisco", timeout: 60), "clearing must bring the sun back")
        shoot("ambient-12-after-clear")
    }

    /// In a metro, the same thing with stitched tiles (needs `cd Server && python3 -m http.server 8765`).
    func testSunAroundTheMapInNewYork() throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/nyc/metro.json")!)
        request.timeoutInterval = 3
        let reachable = expectation(description: "server")
        var ok = false
        URLSession.shared.dataTask(with: request) { data, _, _ in ok = data != nil; reachable.fulfill() }.resume()
        wait(for: [reachable], timeout: 5)
        try XCTSkipUnless(ok, "no New York tiles served on 127.0.0.1:8765")

        app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", "http://127.0.0.1:8765/",
                               "-uiTestStart", "40.7690,-73.9760", "-uiTestDate", "2026-12-21T17:00:00Z"]
        app.launch()
        XCTAssertTrue(waitForStats(containing: "New York (", timeout: 180), "no New York field: \(stats.exists ? stats.label : "missing")")
        sleep(2)
        shoot("ambient-20-central-park-south-december-noon")
        XCTAssertEqual(app.staticTexts["scrubTime"].label, "12:00 PM EST")
    }

    // MARK: - Weather

    /// Overcast with no walk: the field still draws, and says there is no direct sun.
    func testOvercastReachesTheNoWalkSunView() throws {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestStart", "37.78415,-122.40060", "-uiTestDate", "2026-09-23T20:00:00Z",
                               "-uiTestSky", "overcast"]
        app.launch()
        XCTAssertTrue(waitForStats(containing: "San Francisco"))
        let sky = app.staticTexts["skyStatus"]
        XCTAssertTrue(sky.waitForExistence(timeout: 10))
        XCTAssertEqual(sky.label, "Overcast · no direct sun")
        sleep(2)
        shoot("ambient-30-overcast-no-walk")
    }

    /// Overcast on the corridor's Sun layer: same forecast, same wording.
    func testOvercastReachesTheCorridorSunLayer() throws {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestStart", "37.78415,-122.40060", "-uiTestDate", "2026-09-23T20:00:00Z",
                               "-uiTestDestination", "37.79555,-122.39365", "-uiTestDestinationName", "Ferry Building",
                               "-uiTestLayer", "Sun", "-uiTestSky", "overcast"]
        app.launch()
        XCTAssertTrue(app.staticTexts["subtitle"].waitForExistence(timeout: 120))
        let sky = app.staticTexts["skyStatus"]
        XCTAssertTrue(sky.waitForExistence(timeout: 20))
        XCTAssertEqual(sky.label, "Overcast · no direct sun")
        sleep(3)
        shoot("ambient-31-overcast-corridor")
        app.terminate()

        // Clear sky: same walk, the status flips.
        app.launchArguments = app.launchArguments.map { $0 == "overcast" ? "clear" : $0 }
        app.launch()
        XCTAssertTrue(app.staticTexts["subtitle"].waitForExistence(timeout: 120))
        XCTAssertTrue(app.staticTexts["skyStatus"].waitForExistence(timeout: 20))
        XCTAssertEqual(app.staticTexts["skyStatus"].label, "Clear sky")
    }

    /// The app opens where the user is. The fix lands a moment after launch — after the
    /// map has already reported its starting demo region, which used to count as "the
    /// user has a position" and pinned the app to SoMa for good.
    func testStartsAtTheUsersLocation() throws {
        XCUIDevice.shared.location = XCUILocation(location: CLLocation(latitude: 37.7589, longitude: -122.4214))
        app = XCUIApplication()
        app.launchArguments = ["-uiTestDate", "2026-09-23T20:00:00Z"]
        app.launch()
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(stats.value as? String ?? "").hasPrefix("37.75") { usleep(500_000) }
        sleep(2)
        shoot("ambient-40-starts-at-user")
        XCTAssertTrue((stats.value as? String ?? "").hasPrefix("37.75"), "not at the user: \(stats.value ?? "")")
    }

    /// Zoomed out, the no-walk map shows sun by block over everything on screen with data,
    /// instead of a scored square in the middle.
    func testZoomedOutShowsSunByBlock() throws {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestStart", "37.78415,-122.40060", "-uiTestDate", "2026-09-23T20:00:00Z", "-uiTestSky", "clear"]
        app.launch()
        XCTAssertTrue(waitForStats(containing: "San Francisco"))
        let title = app.staticTexts["ambientTitle"]
        XCTAssertEqual(title.label, "Sun around here")
        app.maps.firstMatch.pinch(withScale: 0.25, velocity: -1.5)
        let deadline = Date().addingTimeInterval(60)
        while Date() < deadline, !(stats.exists && stats.label.contains("blocks") && !stats.label.contains("scoring")) { usleep(300_000) }
        shoot("ambient-20-sun-by-block")
        XCTAssertTrue(stats.label.contains("blocks"), stats.label)
        XCTAssertTrue(title.label.hasPrefix("Sun by block"), title.label)
        let blocks = Int(stats.label.components(separatedBy: " blocks")[0].split(separator: " ").last?.replacingOccurrences(of: ",", with: "") ?? "") ?? 0
        XCTAssertGreaterThan(blocks, 300, stats.label)
    }
}
