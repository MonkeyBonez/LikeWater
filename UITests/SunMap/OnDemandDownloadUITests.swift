import XCTest

/// The on-demand path end to end: the app is told to ignore its shipped Berkeley bundle,
/// is placed in Berkeley, and must find the city in the server's manifest, download it,
/// load it, and paint the sun field — all through the same code a real server would hit.
///
/// Run with a local server on the Resources folder:
///     cd Server && python3 -m http.server 8765
final class OnDemandDownloadUITests: XCTestCase {

    private func shoot(_ app: XCUIApplication, _ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    func testDownloadsBerkeleyOnDemand() throws {
        // Skip cleanly if nothing is serving; the rest of the suite must not depend on it.
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/manifest.json")!)
        request.timeoutInterval = 3
        let reachable = expectation(description: "server")
        var ok = false
        URLSession.shared.dataTask(with: request) { data, _, _ in ok = data != nil; reachable.fulfill() }.resume()
        wait(for: [reachable], timeout: 5)
        try XCTSkipUnless(ok, "no bundle server on 127.0.0.1:8765")

        let app = XCUIApplication()
        app.launchArguments = [
            "-bundleBaseURL", "http://127.0.0.1:8765/",
            "-uiTestIgnoreBundled", "berkeley",
            "-uiTestCenter", "37.8716,-122.2727",          // Downtown Berkeley BART
            "-uiTestDate", "2026-09-23T20:00:00Z",
        ]
        app.launch()

        // The download banner appears, then the field renders and names the city.
        let banner = app.staticTexts["cityLoadStatus"]
        _ = banner.waitForExistence(timeout: 15)
        if banner.exists { shoot(app, "70-downloading-berkeley") }

        let stats = app.staticTexts["sunStats"]
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline && !(stats.exists && stats.label.contains("edges scored")) { usleep(400_000) }
        XCTAssertTrue(stats.exists && stats.label.contains("edges scored"), "field never rendered after download")
        XCTAssertTrue(stats.label.hasPrefix("Berkeley"), "expected the Berkeley bundle, got: \(stats.label)")
        shoot(app, "71-berkeley-sun-after-download")

        // Second launch: the downloaded copy is on disk, no server needed.
        app.terminate()
        app.launchArguments = ["-uiTestIgnoreBundled", "berkeley",
                               "-uiTestCenter", "37.8716,-122.2727",
                               "-uiTestDate", "2026-09-23T20:00:00Z"]
        app.launch()
        let deadline2 = Date().addingTimeInterval(60)
        while Date() < deadline2 && !(stats.exists && stats.label.contains("edges scored")) { usleep(400_000) }
        XCTAssertTrue(stats.label.hasPrefix("Berkeley"), "downloaded bundle should persist: \(stats.label)")
        shoot(app, "72-berkeley-from-disk")
    }
}
