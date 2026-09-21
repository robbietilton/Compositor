import XCTest

final class CompositorUITests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }

    @MainActor
    func testEnglishSettingsMenuAppearsImmediatelyAfterLaunch() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-app.language.v1", "english"]
        app.launch()

        app.menuBars.menuBarItems["Compositor"].click()
        XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 1))
        app.menuItems["Settings…"].click()
        XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testEnglishAppMenuContainsSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-app.language.v1", "english"]
        app.launch()

        XCTAssertTrue(app.windows.firstMatch.waitForExistence(timeout: 5))
        Thread.sleep(forTimeInterval: 4)
        app.menuBars.menuBarItems["Compositor"].click()
        XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Настройки…"].waitForNonExistence(timeout: 2))
        app.menuItems["Settings…"].click()
        XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testRussianAppMenuContainsOnlyRussianSettings() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-app.language.v1", "russian"]
        app.launch()

        app.menuBars.menuBarItems["Compositor"].click()
        XCTAssertTrue(app.menuItems["Настройки…"].waitForExistence(timeout: 2))
        XCTAssertFalse(app.menuItems["Settings…"].exists)
        app.menuItems["Настройки…"].click()
        XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testLanguageChangeAppliesAfterRestart() throws {
        let app = XCUIApplication()
        app.launchArguments = ["-app.language.v1", "russian"]
        app.launch()

        app.menuBars.menuBarItems["Compositor"].click()
        XCTAssertTrue(app.menuItems["Настройки…"].waitForExistence(timeout: 2))
        app.menuItems["Настройки…"].click()

        let languagePicker = app.popUpButtons.firstMatch
        XCTAssertTrue(languagePicker.waitForExistence(timeout: 2))
        languagePicker.click()
        languagePicker.menuItems["English"].click()

        app.terminate()
        app.launchArguments = []
        app.launch()
        app.menuBars.menuBarItems["Compositor"].click()
        XCTAssertTrue(app.menuItems["Settings…"].waitForExistence(timeout: 2))
        XCTAssertTrue(app.menuItems["Настройки…"].waitForNonExistence(timeout: 2))
        app.menuItems["Settings…"].click()
        XCTAssertTrue(app.popUpButtons.firstMatch.waitForExistence(timeout: 2))
    }

    @MainActor
    func testCreateCanvasAndNavigation() throws {
        let app = XCUIApplication()
        app.launch()
        app.buttons["newCanvasWelcome"].click()
        let width = app.textFields["widthInput"]
        width.click()
        width.typeKey("a", modifierFlags: .command)
        width.typeText("0")
        XCTAssertFalse(app.buttons["createCanvas"].isEnabled)
        width.typeKey("a", modifierFlags: .command)
        width.typeText("1200")
        let height = app.textFields["heightInput"]
        height.click()
        height.typeKey("a", modifierFlags: .command)
        height.typeText("800")
        app.buttons["createCanvas"].click()
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
        app.buttons["actualPixels"].click()
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "100%")
        app.typeKey("=", modifierFlags: .command)
        XCTAssertEqual(app.staticTexts["zoomStatus"].value as? String, "125%")
        app.buttons["fitCanvas"].click()
        let screenshot = XCTAttachment(screenshot: app.screenshot())
        screenshot.name = "Editor foundation"
        screenshot.lifetime = .keepAlways
        add(screenshot)
        app.typeKey("n", modifierFlags: .command)
        app.typeKey(.escape, modifierFlags: [])
        XCTAssertEqual(app.staticTexts["canvasDimensions"].value as? String, "1,200 × 800 px")
    }

    @MainActor
    func testLaunchPerformance() throws {
        // Explicit macOS baseline: includes XCTest launch/idle/accessibility overhead.
        let app = XCUIApplication()
        var samples: [Double] = []
        for _ in 0..<5 {
            app.terminate()
            let start = ProcessInfo.processInfo.systemUptime
            app.launch()
            XCTAssertTrue(app.buttons["newCanvasWelcome"].waitForExistence(timeout: 5))
            samples.append(ProcessInfo.processInfo.systemUptime - start)
        }
        print("LAUNCH_TO_READY_SECONDS: \(samples)")
        print("LAUNCH_TO_READY_MEDIAN: \(samples.sorted()[2])")
    }
}
