import XCTest

/// Ours-only routing: a walk in a place with no tiles gets a calm banner and the request
/// option, not a red error and not someone else's route.
final class LikeWaterCoverageUITests: XCTestCase {
    func testDestinationInAnUnbuiltPlaceShowsTheBanner() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-bundleBaseURL", "http://127.0.0.1:8765/",
                               "-uiTestStart", "39.7392,-104.9903", "-uiTestDestination", "39.7525,-104.9995",
                               "-uiTestDestinationName", "Union Station Denver", "-uiTestSky", "clear",
                               "-uiTestDate", "2026-09-23T19:00:00Z"]
        app.launch()
        let banner = app.otherElements["coverageBanner"]
        XCTAssertTrue(banner.waitForExistence(timeout: 40))
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot()); shot.lifetime = .keepAlways; add(shot)
        XCTAssertTrue(app.staticTexts["No sun data here yet"].exists)
        XCTAssertFalse(app.staticTexts["routeReadout"].exists, "no route without tiles")
        XCTAssertFalse(app.staticTexts.containing(NSPredicate(format: "label CONTAINS 'No map data for this area'")).firstMatch.exists,
                       "the old red error must be gone")
    }
}
