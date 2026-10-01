import XCTest

/// Big cities end to end: the app starts with nothing downloaded, finds the metro in the
/// bundle server's manifest, downloads only the tiles around the map centre, stitches
/// them, and paints the sun field — with times in the city's own time zone.
///
/// Needs a server on the pipeline's output:
///     cd Server && python3 -m http.server 8765
final class MetroUITests: XCTestCase {

    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = true
        var request = URLRequest(url: URL(string: "http://127.0.0.1:8765/manifest.json")!)
        request.timeoutInterval = 3
        let reachable = expectation(description: "server")
        var metros: [String] = []
        URLSession.shared.dataTask(with: request) { data, _, _ in
            if let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let list = json["metros"] as? [[String: Any]] {
                metros = list.compactMap { $0["id"] as? String }
            }
            reachable.fulfill()
        }.resume()
        wait(for: [reachable], timeout: 5)
        try XCTSkipIf(metros.isEmpty, "no metro server on 127.0.0.1:8765")
        available = Set(metros)
    }

    private var available: Set<String> = []

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private var stats: XCUIElement { app.staticTexts["sunStats"] }

    private func launch(center: String, date: String, fresh: Bool = true) {
        app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", "http://127.0.0.1:8765/",
                               "-uiTestCenter", center, "-uiTestDate", date, "-uiTestSky", "clear"]
        if fresh { app.launchArguments += ["-uiTestFreshDownloads", "1"] }
        app.launch()
    }

    private func waitForField(containing text: String, timeout: TimeInterval = 180) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var sawBanner = false
        while Date() < deadline {
            if app.staticTexts["cityLoadStatus"].exists { sawBanner = true }
            if stats.exists, stats.label.contains(text) { return sawBanner }
            usleep(400_000)
        }
        shoot("FAILURE-\(text)")
        XCTFail("field for \(text) never rendered; stats = \(stats.exists ? stats.label : "missing")")
        return sawBanner
    }

    func testSeattleDownloadsItsTilesAndPaints() throws {
        try XCTSkipUnless(available.contains("seattle"))
        launch(center: "47.6062,-122.3321", date: "2026-09-23T20:00:00Z")   // 1 pm PDT
        _ = waitForField(containing: "Seattle (")
        shoot("metro-10-seattle")
        XCTAssertTrue(stats.label.contains("downloaded)"), "a fresh install must download tiles: \(stats.label)")
        XCTAssertEqual(app.staticTexts["sunTime"].label, "1:00 PM", "Seattle shares the simulator's zone")
        app.terminate()

        // Relaunch without wiping: the tiles are on disk now, so no banner this time.
        launch(center: "47.6062,-122.3321", date: "2026-09-23T20:00:00Z", fresh: false)
        _ = waitForField(containing: "Seattle (", timeout: 60)
        XCTAssertTrue(stats.label.contains("tiles)"), stats.label)
        XCTAssertFalse(stats.label.contains("downloaded"), "second launch must reuse the tiles on disk: \(stats.label)")
    }

    func testNewYorkShowsEasternTimeAndMidtownShadows() throws {
        try XCTSkipUnless(available.contains("nyc"))
        launch(center: "40.7536,-73.9832", date: "2026-12-21T17:00:00Z")    // noon EST
        _ = waitForField(containing: "New York (")
        shoot("metro-20-nyc-midtown-december-noon")
        XCTAssertEqual(app.staticTexts["sunTime"].label, "12:00 PM EST",
                       "a Californian looking at Manhattan sees New York time")
    }

    func testLosAngelesDowntownPaints() throws {
        try XCTSkipUnless(available.contains("la"))
        launch(center: "34.0505,-118.2551", date: "2026-09-23T23:00:00Z")   // 4 pm PDT
        _ = waitForField(containing: "Los Angeles (")
        shoot("metro-30-la-downtown")
    }

    /// The first place built by `build_places.py` (PLAN F): Portland downloads and paints.
    func testPortlandBuiltByThePipelinePaints() throws {
        try XCTSkipUnless(available.contains("portland"))
        launch(center: "45.5231,-122.6765", date: "2026-09-23T20:00:00Z")   // 1 pm PDT
        _ = waitForField(containing: "Portland (")
        shoot("metro-40-portland")
        XCTAssertTrue(stats.label.contains("downloaded)"), stats.label)
        XCTAssertEqual(app.staticTexts["sunTime"].label, "1:00 PM")
        XCTAssertTrue(app.staticTexts["sunReadout"].label.contains("el "))
    }
}
