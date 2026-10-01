import XCTest

/// A walk in a tiled metro: Times Square to Union Square, New York. The start and the
/// destination sit in different tiles; the app downloads and stitches what the walk
/// needs and paints the corridor.
///
/// Needs:  cd Server && python3 -m http.server 8765
final class MetroCorridorUITests: XCTestCase {

    func testNewYorkCorridorAcrossTiles() throws {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/nyc/metro.json")!)
        request.timeoutInterval = 3
        let reachable = expectation(description: "server")
        var ok = false
        URLSession.shared.dataTask(with: request) { data, _, _ in ok = data != nil; reachable.fulfill() }.resume()
        wait(for: [reachable], timeout: 5)
        try XCTSkipUnless(ok, "no New York tiles served on 127.0.0.1:8765")

        let app = XCUIApplication()
        app.launchArguments = [
            "-bundleBaseURL", "http://127.0.0.1:8765/", "-uiTestFreshDownloads", "1",
            "-uiTestStart", "40.7580,-73.9855",                      // Times Square
            "-uiTestDestination", "40.7359,-73.9911",                // Union Square
            "-uiTestDestinationName", "Union Square",
            "-uiTestDate", "2026-09-23T16:00:00Z", "-uiTestDebug", "1", "-uiTestLayer", "Sun",
        ]
        app.launch()
        let subtitle = app.staticTexts["subtitle"]
        let deadline = Date().addingTimeInterval(240)
        while Date() < deadline, !(subtitle.exists && subtitle.label.contains("corridor of")) { usleep(500_000) }
        sleep(4)   // let the map fit the corridor and draw its overlays
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = "metro-40-nyc-times-square-to-union-square"; shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(subtitle.label.contains("corridor of"), subtitle.exists ? subtitle.label : "no subtitle")
        let debug = app.staticTexts["debugStats"]
        XCTAssertTrue(debug.waitForExistence(timeout: 5))
        XCTAssertTrue(debug.label.hasPrefix("New York"), debug.label)
        XCTAssertTrue(app.staticTexts["scrubTime"].label.hasSuffix("EDT"), app.staticTexts["scrubTime"].label)
    }
}
