import XCTest

/// Drives the real app against the bundled San Francisco graph.
final class CorridorUITests: XCTestCase {

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

    private var readout: XCUIElement { app.staticTexts["readout"] }
    private var subtitle: XCUIElement { app.staticTexts["subtitle"] }

    /// Union Square. The SoMa default start is 3rd & Howard.
    private static let unionSquare = "37.78805,-122.40755"
    private static let soma = "37.78415,-122.40060"
    private static let ferryBuilding = "37.79555,-122.39365"
    private static let caltrain = "37.77639,-122.39466"

    private func launch(_ arguments: [String]) {
        app = XCUIApplication()
        app.launchArguments = arguments
        app.launch()
    }

    private func waitForCorridor(timeout: TimeInterval = 120) {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if subtitle.exists, subtitle.label.contains("corridor of") { return }
            usleep(400_000)
        }
        shoot("FAILURE-no-corridor")
        XCTFail("corridor never rendered; subtitle = \(subtitle.exists ? subtitle.label : "missing")")
    }

    private func metresRemaining() -> Int? {
        guard subtitle.exists, let range = subtitle.label.range(of: " to go") else { return nil }
        let parts = subtitle.label[subtitle.label.startIndex..<range.lowerBound].split(separator: " ")
        guard let value = Double(parts.first?.replacingOccurrences(of: ",", with: "") ?? "") else { return nil }
        return parts.last == "km" ? Int(value * 1000) : Int(value)
    }

    private func segmentCount() -> Int? {
        guard subtitle.exists, let range = subtitle.label.range(of: "corridor of ") else { return nil }
        let digits = subtitle.label[range.upperBound...].prefix { $0.isNumber || $0 == "," }
        return Int(digits.replacingOccurrences(of: ",", with: ""))
    }

    // MARK: - Tests

    /// PRD states 1 and 2: no destination, then real MapKit search sets one.
    func testSearchSetsADestinationAndPaintsTheCorridor() throws {
        launch(["-uiTestStart", Self.unionSquare, "-uiTestDebug", "1"])
        XCTAssertTrue(app.buttons["whereToButton"].waitForExistence(timeout: 30))
        XCTAssertFalse(app.segmentedControls["layerPicker"].exists, "layer control is hidden with no destination")
        shoot("01-no-destination")

        app.buttons["whereToButton"].tap()
        let field = app.searchFields.firstMatch
        XCTAssertTrue(field.waitForExistence(timeout: 10))
        field.tap()
        field.typeText("Ferry Building San Francisco")

        let first = app.cells.firstMatch
        if first.waitForExistence(timeout: 25) {
            shoot("02-search-suggestions")
            first.tap()
        } else {
            app.typeText("\n")
        }
        waitForCorridor()
        shoot("03-corridor-crossings-layer")
        XCTAssertTrue(app.segmentedControls["layerPicker"].exists)
    }

    /// PRD's three layers, same corridor.
    func testEachLayerPaintsTheCorridor() throws {
        launch(["-uiTestStart", Self.soma, "-uiTestDestination", Self.caltrain,
                "-uiTestDestinationName", "SF Caltrain", "-uiTestDebug", "1",
                "-uiTestDate", "2026-09-23T17:30:00Z"])
        waitForCorridor()
        let picker = app.segmentedControls["layerPicker"]
        XCTAssertTrue(picker.waitForExistence(timeout: 20))

        for (index, name) in ["Crossings", "Interest", "Sun"].enumerated() {
            picker.buttons[name].tap()
            usleep(1_500_000)
            shoot(String(format: "10-%d-layer-%@", index, name.lowercased()))
            XCTAssertTrue(subtitle.label.contains("corridor of"), "layer \(name) lost the corridor")
        }
        // The sun layer brings its own controls, and the pinned morning time has sun.
        XCTAssertTrue(app.staticTexts["sunReadout"].exists)
        XCTAssertTrue(app.staticTexts["sunReadout"].label.contains("el "),
                      "expected a sun position, got \(app.staticTexts["sunReadout"].label)")
        XCTAssertTrue(app.sliders["timeScrubber"].exists)
    }

    /// PRD: the time scrubber moves the sun and the corridor recolours.
    func testSunScrubberMovesTheSun() throws {
        launch(["-uiTestStart", Self.soma, "-uiTestDestination", Self.caltrain,
                "-uiTestDestinationName", "SF Caltrain", "-uiTestLayer", "Sun",
                "-uiTestDate", "2026-09-23T17:30:00Z", "-uiTestDebug", "1"])
        waitForCorridor()
        let sun = app.staticTexts["sunReadout"]
        XCTAssertTrue(sun.waitForExistence(timeout: 20))
        let before = sun.label
        XCTAssertTrue(before.contains("el "), "pinned morning time should have the sun up, got \(before)")
        shoot("20-sun-morning")

        let scrubber = app.sliders["timeScrubber"]
        XCTAssertTrue(scrubber.waitForExistence(timeout: 10))
        scrubber.adjust(toNormalizedSliderPosition: 0.9)
        usleep(2_000_000)
        shoot("21-sun-late-afternoon")
        XCTAssertNotEqual(sun.label, before, "scrubbing must move the sun")

        app.buttons["nowButton"].tap()
        usleep(1_500_000)
        shoot("22-sun-now")
    }

    /// PRD: slack runs 0 to 60%, Direct to Wander.
    func testSlackFromDirectToWander() throws {
        var counts: [Int] = []
        for (index, slack) in [0.0, 0.05, 0.10, 0.30, 0.60].enumerated() {
            launch(["-uiTestStart", Self.unionSquare, "-uiTestDestination", Self.caltrain,
                    "-uiTestDestinationName", "SF Caltrain", "-uiTestDebug", "1",
                    "-uiTestSlack", "\(slack)"])
            waitForCorridor()
            shoot(String(format: "30-%d-slack-%02d", index, Int(slack * 100)))
            counts.append(try XCTUnwrap(segmentCount()))
            app.terminate()
        }
        XCTAssertEqual(counts, counts.sorted(), "widening slack must never shrink the corridor: \(counts)")
        XCTAssertLessThan(counts.first!, 400, "s = 0 should be close to a single line")
        XCTAssertGreaterThan(counts.last!, counts.first! * 5, "s = 60% should open up: \(counts)")
    }

    /// PRD states 4 and 5: the corridor shrinks as you walk, then arrival clears it.
    func testWalkingShrinksTheCorridorAndArrivalResets() throws {
        launch(["-uiTestStart", Self.unionSquare, "-uiTestDestination", Self.ferryBuilding,
                "-uiTestDestinationName", "Ferry Building", "-uiTestDebug", "1"])
        waitForCorridor()
        shoot("40-00-start")

        var previous = try XCTUnwrap(metresRemaining())
        var regressions = 0
        var arrived = false

        for step in 1...22 {
            guard app.buttons["stepButton"].exists else { arrived = true; break }
            app.buttons["stepButton"].tap()
            usleep(650_000)
            if step % 4 == 0 { shoot(String(format: "40-%02d-walking", step)) }
            guard let now = metresRemaining() else { arrived = true; break }
            if now > previous { regressions += 1 }
            previous = now
        }
        shoot("41-arrival")
        XCTAssertEqual(regressions, 0, "distance must never grow while walking the corridor")
        XCTAssertTrue(arrived || previous < 120, "should have reached the destination; \(previous) m left")
        // State 5: the corridor is cleared and the layer control is gone again.
        XCTAssertFalse(app.segmentedControls["layerPicker"].exists)
    }

    /// The product's central claim, under test.
    func testRandomFreeChoicesNeverCostDistance() throws {
        launch(["-uiTestStart", Self.unionSquare, "-uiTestDestination", Self.ferryBuilding,
                "-uiTestDestinationName", "Ferry Building", "-uiTestDebug", "1"])
        waitForCorridor()
        var previous = try XCTUnwrap(metresRemaining())
        shoot("50-0-random-start")
        for step in 1...10 {
            guard app.buttons["randomButton"].exists else { break }
            app.buttons["randomButton"].tap()
            usleep(650_000)
            if step % 3 == 0 { shoot("50-\(step)-random") }
            guard let now = metresRemaining() else { break }
            XCTAssertLessThanOrEqual(now, previous, "a free choice inside the corridor must not add distance")
            previous = now
        }
        shoot("51-random-end")
    }

    /// Settings is one control, per the PRD.
    func testSettingsSlackControl() throws {
        launch(["-uiTestStart", Self.soma, "-uiTestDestination", Self.caltrain,
                "-uiTestDestinationName", "SF Caltrain", "-uiTestDebug", "1"])
        waitForCorridor()
        let before = try XCTUnwrap(segmentCount())
        app.buttons["settingsButton"].tap()
        let slider = app.sliders["slackSlider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 10))
        shoot("60-settings")
        slider.adjust(toNormalizedSliderPosition: 0.9)
        usleep(1_200_000)
        app.buttons["settingsDone"].tap()
        usleep(1_500_000)
        shoot("61-after-wander")
        XCTAssertGreaterThan(try XCTUnwrap(segmentCount()), before)
    }
}
