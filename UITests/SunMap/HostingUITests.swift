import XCTest

/// The apps against what `publish.py` produces, served locally (PLAN.md §2 D), and the
/// "Request this area" button against the Worker under `wrangler dev`:
///     cd build/publish && python3 -m http.server 8770      # publish.py --dry-run (Pages layout)
///     cd build/s3-layout && python3 -m http.server 8771    # publish.py --target s3 --local-dir build/s3-layout
///     cd Worker && npx wrangler dev --local --port 8787    # with .dev.vars from .dev.vars.example
final class HostingUITests: XCTestCase {
    private var app: XCUIApplication!

    override func setUpWithError() throws { continueAfterFailure = false }

    private func get(_ url: String, token: String? = nil) -> Data? {
        var request = URLRequest(url: URL(string: url)!)
        request.timeoutInterval = 3
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "authorization") }
        let done = expectation(description: url)
        var out: Data?
        URLSession.shared.dataTask(with: request) { data, response, _ in
            if (response as? HTTPURLResponse)?.statusCode == 200 { out = data }
            done.fulfill()
        }.resume()
        wait(for: [done], timeout: 5)
        return out
    }

    private func seattleDownloads(from base: String) {
        app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", base, "-uiTestCenter", "47.6062,-122.3321",
                               "-uiTestDate", "2026-09-23T20:00:00Z", "-uiTestSky", "clear",
                               "-uiTestFreshDownloads", "1", "-uiTestNoPrefetch", "1"]
        app.launch()
        let stats = app.staticTexts["sunStats"]
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline, !(stats.exists && stats.label.contains("Seattle (")) { usleep(400_000) }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(stats.label.contains("downloaded"), stats.exists ? stats.label : "no field")
    }

    func testTheStagedPagesSiteServesTheApp() throws {
        try XCTSkipIf(get("http://127.0.0.1:8770/manifest.json") == nil, "staged Pages site not served on 8770")
        seattleDownloads(from: "http://127.0.0.1:8770/")
    }

    func testTheS3BuildKeyedLayoutServesTheApp() throws {
        try XCTSkipIf(get("http://127.0.0.1:8771/manifest.json") == nil, "S3 layout not served on 8771")
        seattleDownloads(from: "http://127.0.0.1:8771/")
    }

    /// Boise isn't built: the banner offers the request, the tap reaches the Worker, and the
    /// Worker's export counts the cell.
    func testRequestThisAreaReachesTheWorker() throws {
        try XCTSkipIf(get("http://127.0.0.1:8787/health") == nil, "Worker not running on 8787")
        app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", "http://127.0.0.1:8765/", "-uiTestCenter", "43.6150,-116.2023",
                               "-uiTestSky", "clear", "-uiTestDate", "2026-09-23T19:00:00Z",
                               "-coverageRequestURL", "http://127.0.0.1:8787/coverage-request"]
        app.launch()
        let button = app.buttons["requestCoverageButton"]
        XCTAssertTrue(button.waitForExistence(timeout: 30), "the request button needs the banner and an endpoint")
        button.tap()
        let thanks = app.buttons["Requested — thanks"]
        XCTAssertTrue(thanks.waitForExistence(timeout: 10), "the Worker should accept the request")
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
        let export = try XCTUnwrap(get("http://127.0.0.1:8787/coverage-requests", token: "local-export-token"))
        let cells = try XCTUnwrap((try JSONSerialization.jsonObject(with: export) as? [String: Any])?["cells"] as? [String: Int])
        XCTAssertGreaterThanOrEqual(cells["43.6,-116.2"] ?? 0, 1, "\(cells)")
    }
}
