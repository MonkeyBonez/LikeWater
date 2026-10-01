import XCTest
import CoreLocation

/// Drives the real Sun Map app: loads the bundled city, scores the sidewalks around
/// a SoMa corner, and moves through the day.
final class SunMapUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        app = XCUIApplication()
    }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
    }

    private var stats: XCUIElement { app.staticTexts["sunStats"] }
    private var readout: XCUIElement { app.staticTexts["sunReadout"] }
    private var timeLabel: XCUIElement { app.staticTexts["sunTime"] }

    private func waitForField(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if stats.exists, stats.label.contains("edges scored") { return }
            usleep(400_000)
        }
        shoot("FAILURE-no-sun-field")
        XCTFail("sun field never rendered")
    }

    private func launch(at coordinate: String, date: String, sky: String? = nil) {
        app = XCUIApplication()
        app.launchArguments = ["-uiTestCenter", coordinate, "-uiTestDate", date]
        if let sky { app.launchArguments += ["-uiTestSky", sky] }
        app.launch()
    }

    private var skyStatus: XCUIElement { app.staticTexts["skyStatus"] }

    private func waitForSky(timeout: TimeInterval = 20) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if skyStatus.exists, !skyStatus.label.isEmpty { return }
            usleep(300_000)
        }
        shoot("FAILURE-no-sky-status")
        XCTFail("sky status never appeared")
    }

    /// 3rd & Howard through the day: morning, midday, late afternoon.
    func testSoMaSunThroughTheDay() throws {
        let stops: [(String, String)] = [
            ("09-00am", "2026-09-23T16:00:00Z"),
            ("10-10am", "2026-09-23T17:00:00Z"),
            ("11-01pm", "2026-09-23T20:00:00Z"),
            ("12-04pm", "2026-09-23T23:00:00Z"),
            ("13-06pm", "2026-09-24T01:00:00Z"),
        ]
        var seen: [String] = []
        for (label, stamp) in stops {
            launch(at: "37.78415,-122.40060", date: stamp)
            waitForField()
            shoot("sunmap-\(label)")
            seen.append(stats.label)
            XCTAssertTrue(readout.exists)
            XCTAssertTrue(stats.label.hasPrefix("San Francisco"), "city name from the manifest: \(stats.label)")
            app.terminate()
        }
        XCTAssertGreaterThan(Set(seen).count, 1, "sun field never changed: \(seen)")
    }

    func testSunDownShowsTheMessage() throws {
        launch(at: "37.78415,-122.40060", date: "2026-09-24T07:00:00Z")   // midnight PDT
        waitForField()
        shoot("sunmap-20-night")
        XCTAssertTrue(app.staticTexts["sunStatus"].waitForExistence(timeout: 10))
        XCTAssertEqual(app.staticTexts["sunStatus"].label, "Sun is down.")
        XCTAssertEqual(readout.label, "Sun is down.")
    }

    /// The scrubber's 15-minute steps, driven through the step buttons (XCUITest cannot
    /// reliably drag a SwiftUI slider), then "Now" leaves the pinned time.
    func testScrubberMovesTheSun() throws {
        launch(at: "37.78415,-122.40060", date: "2026-09-23T17:00:00Z")   // 10:00 am PDT
        waitForField()
        let readoutBefore = readout.label
        let timeBefore = timeLabel.label
        shoot("sunmap-30-before-scrub")

        let forward = app.buttons["stepForward"]
        XCTAssertTrue(forward.waitForExistence(timeout: 10))
        for _ in 0..<12 { forward.tap() }                       // +3 hours
        usleep(2_500_000)
        shoot("sunmap-31-after-scrub")
        let timeAfter = timeLabel.label
        XCTAssertNotEqual(timeAfter, timeBefore, "stepping must move the time")
        XCTAssertNotEqual(readout.label, readoutBefore, "stepping must move the sun")

        app.buttons["nowButton"].tap()
        usleep(2_000_000)
        shoot("sunmap-32-back-to-now")
        XCTAssertNotEqual(timeLabel.label, timeAfter, "Now must leave the stepped time")
    }

    // MARK: - Weather

    /// Under overcast there is no beam: the status says so and the palette is flat.
    func testOvercastFlattensTheSky() throws {
        launch(at: "37.78415,-122.40060", date: "2026-09-23T20:00:00Z", sky: "overcast")
        waitForField(); waitForSky()
        shoot("sunmap-40-overcast")
        XCTAssertEqual(skyStatus.label, "Overcast · no direct sun")
        XCTAssertTrue(stats.label.contains("sky 0.00 overcast"), stats.label)
    }

    /// Two weathers at once: fog on the west side, sun in the Mission, and the app
    /// says which one you are standing in.
    func testFogWestSplitsTheCity() throws {
        launch(at: "37.7605,-122.4950", date: "2026-09-23T20:00:00Z", sky: "fog-west")   // Sunset, Judah & 40th
        waitForField(); waitForSky()
        shoot("sunmap-41-fog-west-sunset")
        let west = skyStatus.label
        XCTAssertEqual(west, "Fog · no direct sun here · sun nearby")
        app.terminate()

        launch(at: "37.7599,-122.4148", date: "2026-09-23T20:00:00Z", sky: "fog-west")   // Mission, 20th & Valencia
        waitForField(); waitForSky()
        shoot("sunmap-42-fog-west-mission")
        let east = skyStatus.label
        XCTAssertEqual(east, "Clear sky here · fog nearby")
        XCTAssertNotEqual(west, east)
    }

    /// The picker overrides the forecast: "what if it clears up" and back.
    func testSkyPickerOverridesTheForecast() throws {
        launch(at: "37.78415,-122.40060", date: "2026-09-23T20:00:00Z", sky: "clear")
        waitForField(); waitForSky()
        XCTAssertEqual(skyStatus.label, "Clear sky")
        let picker = app.segmentedControls["skyPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 10))
        picker.buttons["Cloudy"].tap()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, !skyStatus.label.contains("set by you") { usleep(300_000) }
        shoot("sunmap-43-picker-cloudy")
        XCTAssertEqual(skyStatus.label, "Overcast · no direct sun (set by you)")
        XCTAssertTrue(stats.label.contains("sky 0.00 override"), stats.label)
        picker.buttons["Auto"].tap()
        let back = Date().addingTimeInterval(15)
        while Date() < back, skyStatus.label.contains("set by you") { usleep(300_000) }
        XCTAssertEqual(skyStatus.label, "Clear sky")
    }

    // MARK: - The whole screen, and the user's own location

    private func scoredEdges() -> Int {
        guard let r = stats.label.range(of: " edges scored") else { return 0 }
        let head = stats.label[..<r.lowerBound]
        return Int(head.split(separator: " ").last?.replacingOccurrences(of: ",", with: "") ?? "") ?? 0
    }

    /// The field covers the visible map (portrait, ~900 m wide), not a 400 m square:
    /// the old square scored 2,231 edges here. Zooming well out is capped and says so.
    func testFieldCoversTheWholeScreen() throws {
        launch(at: "37.78415,-122.40060", date: "2026-09-23T20:00:00Z")
        waitForField()
        let screen = scoredEdges()
        shoot("sunmap-50-whole-screen")
        XCTAssertGreaterThan(screen, 3_500, stats.label)

        let map = app.maps.firstMatch
        map.pinch(withScale: 0.25, velocity: -1.5)
        let status = app.staticTexts["sunStatus"]
        XCTAssertTrue(status.waitForExistence(timeout: 30), "zoomed out past the cap should say so")
        XCTAssertEqual(status.label, "Zoom in to see the sun on every street")
        sleep(2)
        shoot("sunmap-51-zoomed-out-capped")
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
        shoot("sunmap-52-starts-at-user")
        XCTAssertTrue((stats.value as? String ?? "").hasPrefix("37.75"), "not at the user: \(stats.value ?? "")")
    }
}
