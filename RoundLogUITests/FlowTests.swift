import XCTest

@MainActor final class FlowTests: XCTestCase {
    override func setUpWithError() throws { continueAfterFailure = false }
    private func launch(screen: String? = nil, reset: Bool = true) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["--ui-testing"] + (reset ? ["--reset-demo"] : [])
        if let screen { app.launchArguments += ["--screen", screen] }
        app.launch()
        if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
        return app
    }
    func testChatPersistsAndNavigationReturnsHome() {
        let app = launch()
        app.buttons["friends-room"].tap()
        XCTAssertTrue(app.buttons["chat"].waitForExistence(timeout: 10))
        app.buttons["chat"].tap()
        let field = app.textFields["message-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if app.buttons["Continue"].waitForExistence(timeout: 1) { app.buttons["Continue"].tap() }
        field.typeText("Meet me at six")
        let typed = expectation(for: NSPredicate(format: "value == %@", "Meet me at six"), evaluatedWith: field)
        wait(for: [typed], timeout: 5)
        app.buttons["send-message"].tap()
        XCTAssertTrue(app.staticTexts["Meet me at six"].waitForExistence(timeout: 3))
        app.terminate()
        let relaunched = launch(reset: false)
        XCTAssertTrue(relaunched.buttons["friends-room"].waitForExistence(timeout: 10))
        relaunched.buttons["friends-room"].tap()
        XCTAssertTrue(relaunched.buttons["chat"].waitForExistence(timeout: 10))
        relaunched.buttons["chat"].tap()
        XCTAssertTrue(relaunched.staticTexts["Meet me at six"].waitForExistence(timeout: 5))
        relaunched.buttons["back"].tap(); relaunched.buttons["back"].tap()
        XCTAssertTrue(relaunched.buttons["profile"].waitForExistence(timeout: 5))
    }
    func testPillPressesChatReturnAndBlankCamera() {
        let app = launch()
        let camera = app.buttons["tab-camera"]
        let logs = app.buttons["tab-logs"]
        XCTAssertTrue(camera.waitForExistence(timeout: 10))
        let tabFrame = camera.frame
        XCTAssertTrue(logs.isSelected)
        let cameraCenter = camera.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        cameraCenter.press(forDuration: 0.7, thenDragTo: cameraCenter.withOffset(CGVector(dx: 0, dy: -100)))
        XCTAssertTrue(logs.isSelected)
        for index in 0..<2 {
            if index == 0 { camera.press(forDuration: 0.7) } else { camera.tap() }
            XCTAssertTrue(camera.isSelected)
            XCTAssertTrue(app.otherElements["camera-preview"].exists)
            XCTAssertFalse(app.buttons["friends-room"].isHittable)
            XCTAssertEqual(camera.frame.minX, tabFrame.minX, accuracy: 1)
            XCTAssertEqual(camera.frame.minY, tabFrame.minY, accuracy: 1)
            logs.press(forDuration: 0.7)
            XCTAssertTrue(logs.isSelected)
            XCTAssertTrue(app.buttons["friends-room"].isHittable)
        }
        app.scrollViews["home-content"].swipeRight()
        let cameraSelected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: camera)
        wait(for: [cameraSelected], timeout: 5)
        XCTAssertTrue(app.otherElements["camera-preview"].exists)
        app.otherElements["camera-preview"].swipeLeft()
        let logsSelected = expectation(for: NSPredicate(format: "selected == true"), evaluatedWith: logs)
        wait(for: [logsSelected], timeout: 5)
        XCTAssertTrue(app.buttons["friends-room"].isHittable)
        app.buttons["friends-room"].tap()
        let chat = app.buttons["chat"]
        let calendar = app.buttons["calendar"]
        XCTAssertTrue(chat.waitForExistence(timeout: 10))
        let chatFrame = chat.frame
        let calendarFrame = calendar.frame
        for index in 0..<3 {
            if index == 0 { chat.tap() } else { chat.press(forDuration: 0.7) }
            XCTAssertTrue(app.textFields["message-input"].waitForExistence(timeout: 5))
            app.buttons["back"].tap()
            XCTAssertTrue(chat.waitForExistence(timeout: 5))
            XCTAssertTrue(calendar.isHittable)
            XCTAssertEqual(chat.frame, chatFrame)
            XCTAssertEqual(calendar.frame, calendarFrame)
        }
        calendar.press(forDuration: 0.7)
        let day = app.buttons["date-15"]
        XCTAssertTrue(day.waitForExistence(timeout: 5)); day.tap()
        XCTAssertTrue(chat.waitForExistence(timeout: 5))
    }
    func testCreateRoomAndEditCaption() {
        let app = launch(screen: "create")
        let field = app.textFields["room-name-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("Weekend")
        app.buttons["confirm-create"].tap()
        XCTAssertTrue(app.buttons["room-settings"].waitForExistence(timeout: 5))
        app.buttons["log-options"].firstMatch.tap()
        app.buttons["edit caption"].tap()
        let editor = app.textViews["caption-input"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5)); editor.tap(); editor.typeText("a good day")
        app.buttons["save-caption"].tap()
        XCTAssertTrue(app.staticTexts["a good day"].waitForExistence(timeout: 5))
    }
    func testInvalidJoinAndAppearancePersistence() {
        let app = launch(screen: "join")
        let field = app.textFields["join-code-input"]
        XCTAssertTrue(field.waitForExistence(timeout: 5)); field.tap(); field.typeText("invalid")
        app.buttons["confirm-join"].tap()
        XCTAssertTrue(app.staticTexts["join-error"].waitForExistence(timeout: 3))
        app.terminate()
        let profile = launch(screen: "profile")
        profile.buttons["color-3"].tap()
        profile.terminate()
        let relaunched = launch(screen: "profile", reset: false)
        XCTAssertTrue(relaunched.buttons["color-3"].isSelected)
    }
    func testTimelineSwipeCrossesToPreviousDay() {
        let app = launch(screen: "room")
        let timeline = app.scrollViews["timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 10))
        timeline.swipeRight()
        XCTAssertTrue(app.staticTexts["12:00"].firstMatch.waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["hour-12"].exists)
    }
    func testSheetDragRecoveryCalendarAndLayout() {
        let app = launch(screen: "profile")
        let close = app.buttons["Close settings"]
        XCTAssertTrue(close.waitForExistence(timeout: 10))
        let initialY = close.frame.minY
        let header = app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.13))
        header.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.154)))
        let settled = expectation(for: NSPredicate { element, _ in
            guard let button = element as? XCUIElement else { return false }
            return button.exists && abs(button.frame.minY - initialY) < 2
        }, evaluatedWith: close)
        wait(for: [settled], timeout: 5)
        header.press(forDuration: 0.1, thenDragTo: app.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.65)))
        XCTAssertTrue(app.buttons["friends-room"].waitForExistence(timeout: 5))
        app.buttons["friends-room"].tap()
        XCTAssertTrue(app.buttons["calendar"].waitForExistence(timeout: 10))
        app.buttons["calendar"].tap()
        XCTAssertTrue(app.buttons["date-15"].waitForExistence(timeout: 5))
        app.buttons["date-15"].tap()
        XCTAssertTrue(app.staticTexts["12:00"].firstMatch.waitForExistence(timeout: 5))
        guard let react = app.buttons.matching(identifier: "React to log").allElementsBoundByIndex.first(where: \.isHittable) else {
            XCTFail("The selected history page has no reachable reaction control")
            return
        }
        react.tap()
        XCTAssertTrue(app.buttons["✨"].waitForExistence(timeout: 5))
        app.buttons["✨"].tap()
        XCTAssertTrue(app.buttons["room-settings"].waitForExistence(timeout: 5))
        app.buttons["room-settings"].tap()
        let layout = app.buttons.containing(.staticText, identifier: "layout").firstMatch
        for _ in 0..<3 where !layout.isHittable { app.swipeUp() }
        XCTAssertTrue(layout.isHittable)
        layout.tap()
        let grid = app.buttons.containing(.staticText, identifier: "grid").firstMatch
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        grid.tap()
        for _ in 0..<3 where !layout.isHittable { app.swipeUp() }
        XCTAssertTrue(app.staticTexts["grid"].exists)
    }
    func testPersistentActivityAndPinnedHomeHeader() {
        let app = launch()
        let activity = app.buttons["activity"]
        XCTAssertTrue(activity.waitForExistence(timeout: 10))
        let origin = activity.frame
        XCTAssertEqual(origin.midY, app.buttons["creation-menu"].frame.midY, accuracy: 2)
        activity.tap()
        let close = app.buttons["Close activity"]
        XCTAssertTrue(close.waitForExistence(timeout: 5))
        XCTAssertEqual(app.buttons.matching(identifier: "activity").count, 1)
        XCTAssertEqual(close.frame.midX, origin.midX, accuracy: 1)
        XCTAssertEqual(close.frame.midY, origin.midY, accuracy: 1)
        close.tap()
        XCTAssertTrue(app.buttons["Activity"].waitForExistence(timeout: 5))
        XCTAssertEqual(activity.frame.midY, origin.midY, accuracy: 1)

        // Real local room creation makes the home list long enough to scroll.
        for index in 1...3 {
            app.buttons["creation-menu"].tap()
            let create = app.buttons["create-room"]
            XCTAssertTrue(create.waitForExistence(timeout: 5)); create.tap()
            let name = app.textFields["room-name-input"]
            XCTAssertTrue(name.waitForExistence(timeout: 5)); name.tap(); name.typeText("Review \(index)")
            app.buttons["confirm-create"].tap()
            XCTAssertTrue(app.buttons["back"].waitForExistence(timeout: 5)); app.buttons["back"].tap()
            XCTAssertTrue(app.buttons["profile"].waitForExistence(timeout: 5))
        }
        let profile = app.buttons["profile"]
        let wordmark = app.images["wordmark"]
        let profileY = profile.frame.minY
        let wordmarkY = wordmark.frame.minY
        let rowY = app.buttons["friends-room"].frame.minY
        app.scrollViews["home-content"].swipeUp()
        XCTAssertEqual(profile.frame.minY, profileY, accuracy: 1)
        XCTAssertEqual(wordmark.frame.minY, wordmarkY, accuracy: 1)
        XCTAssertLessThan(app.buttons["friends-room"].frame.minY, rowY - 30)
    }

}
