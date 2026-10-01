import XCTest

/// The phone's cache across server rebuilds and over time (PLAN.md §2 C5, C6).
/// Needs three servers:
///     cd Server && python3 -m http.server 8765
///     cd Pipeline && python3 fake_rebuild_server.py --port 8766            # Seattle rebuilt
///     cd Pipeline && python3 fake_rebuild_server.py --port 8767 --broken   # rebuilt, tiles missing
final class BuildPinningUITests: XCTestCase {
    private var app: XCUIApplication!
    static let seattle = "47.6062,-122.3321"
    static let oldBuild = "build 20260930065716"
    static let newBuild = "build 20261001065716"

    private func reachable(_ port: Int) -> Bool {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/manifest.json")!)
        request.timeoutInterval = 3
        let done = expectation(description: "server \(port)")
        var ok = false
        URLSession.shared.dataTask(with: request) { data, _, _ in ok = data != nil; done.fulfill() }.resume()
        wait(for: [done], timeout: 5)
        return ok
    }

    override func setUpWithError() throws { continueAfterFailure = false }

    private func shoot(_ name: String) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }

    private var stats: XCUIElement { app.staticTexts["sunStats"] }

    @discardableResult
    private func open(port: Int, center: String = seattle, fresh: Bool = false, extra: [String] = [],
                      expecting text: String) -> String {
        app?.terminate()
        app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", "http://127.0.0.1:\(port)/", "-uiTestCenter", center,
                               "-uiTestDate", "2026-09-23T20:00:00Z", "-uiTestSky", "clear"] + extra
        if fresh { app.launchArguments += ["-uiTestFreshDownloads", "1"] }
        app.launch()
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if stats.exists, stats.label.contains(text) { return stats.label }
            usleep(400_000)
        }
        shoot("FAILURE-\(text)")
        XCTFail("never saw \(text); stats = \(stats.exists ? stats.label : "missing")")
        return ""
    }

    /// A newer server build is fetched into its own directory and used; the server
    /// going back to the older build never downgrades the phone.
    func testANewerBuildReplacesTheOldOneAndIsNeverDowngraded() throws {
        try XCTSkipUnless(reachable(8765) && reachable(8766), "needs servers on 8765 and 8766")
        let first = open(port: 8765, fresh: true, extra: ["-uiTestNoPrefetch", "1"], expecting: Self.oldBuild)
        XCTAssertTrue(first.contains("downloaded"), first)
        let rebuilt = open(port: 8766, extra: ["-uiTestNoPrefetch", "1"], expecting: Self.newBuild)
        XCTAssertTrue(rebuilt.contains("downloaded"), "a new build needs its own tiles: \(rebuilt)")
        shoot("pinning-new-build")
        let back = open(port: 8765, extra: ["-uiTestNoPrefetch", "1"], expecting: "Seattle (")
        XCTAssertTrue(back.contains(Self.newBuild), "must not downgrade: \(back)")
        XCTAssertFalse(back.contains("downloaded"), "the new build is complete on the phone: \(back)")
    }

    /// The server lists a newer build whose tiles aren't there (upload half done, or
    /// offline): the old build keeps serving instead of an error.
    func testABrokenNewBuildFallsBackToTheOldOne() throws {
        try XCTSkipUnless(reachable(8765) && reachable(8767), "needs servers on 8765 and 8767")
        open(port: 8765, fresh: true, extra: ["-uiTestNoPrefetch", "1"], expecting: Self.oldBuild)
        let fallback = open(port: 8767, extra: ["-uiTestNoPrefetch", "1"], expecting: "Seattle (")
        shoot("pinning-fallback")
        XCTAssertTrue(fallback.contains(Self.oldBuild), fallback)
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'Download failed'")).firstMatch.exists)
    }

    /// With a 30 MB cap, visiting three metros keeps the cache under the cap (the current
    /// stitch is protected), and the least recently used metro is the one that goes.
    func testTheCacheStaysUnderItsCap() throws {
        try XCTSkipUnless(reachable(8765), "needs the server on 8765")
        let cap = ["-uiTestCacheCapMB", "30", "-uiTestNoPrefetch", "1"]
        open(port: 8765, fresh: true, extra: cap, expecting: "Seattle (")
        open(port: 8765, center: "34.0505,-118.2551", extra: cap, expecting: "Los Angeles (")
        let nyc = open(port: 8765, center: "40.7536,-73.9832", extra: cap, expecting: "New York (")
        shoot("cache-after-three-metros")
        let mb = Int(nyc.components(separatedBy: "cache ").last?.split(separator: " ").first ?? "") ?? -1
        XCTAssertGreaterThanOrEqual(mb, 0, nyc)
        XCTAssertLessThanOrEqual(mb, 30, "cache over its cap: \(nyc)")
        let seattleAgain = open(port: 8765, extra: cap, expecting: "Seattle (")
        XCTAssertTrue(seattleAgain.contains("downloaded"), "Seattle was least recently used, so it was evicted: \(seattleAgain)")
    }

    /// After a stitch the next ring of tiles comes down in the background, so a pan of a
    /// screen or so needs no download.
    func testPrefetchedTilesMakeAPanFree() throws {
        try XCTSkipUnless(reachable(8765), "needs the server on 8765")
        let first = open(port: 8765, fresh: true, expecting: "Seattle (")
        let firstTiles = first.components(separatedBy: " tiles")[0]
        sleep(10)                                 // let the background ring finish
        // Pan ~2 km north, out of the stitch's valid box, so a new stitch is needed.
        for _ in 0..<3 { app.maps.firstMatch.swipeDown(); usleep(600_000) }
        let deadline = Date().addingTimeInterval(40)
        var label = stats.label
        while Date() < deadline {
            label = stats.label
            if label.components(separatedBy: " tiles")[0] != firstTiles || !label.contains("downloaded") { break }
            usleep(400_000)
        }
        XCTAssertNotEqual(label.components(separatedBy: " tiles")[0], firstTiles, "the pan should have needed a new stitch: \(label)")
        shoot("prefetch-pan")
        XCTAssertFalse(label.contains("downloaded"), "the pan should have found its tiles prefetched: \(label)")
    }
}
