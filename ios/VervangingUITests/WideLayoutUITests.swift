import XCTest

/// The wide layout for the iPhone Duo's inner screen (#105, plan decision #41): the setup shows the plan grid beside the
/// rest of the setup, and the live screen shows the minutes beside the court. A screen takes it from the room it has
/// (at least 600 × 500 pt), never from the device model, so the iPhone 17 Pro and the Duo's outer screen keep the phone
/// layout.
///
/// ⚠ The Duo simulator boots folded, and its inner screen stays black (plan assumption A6): no simctl, Xcode or XCTest
/// call unfolds it, and its outer screen does not turn to landscape either. So the test that switches layouts lowers the
/// threshold through `VERVANGING_WIDE_LAYOUT_MIN` (debug builds only) and turns a phone that does turn (the iPhone 17
/// Pro) to landscape: the app then changes size mid-match the way an unfold does, and takes the wide layout from the
/// size it measures. Tests that need a turn or the real inner screen skip themselves where they cannot run.
///
/// Each test has its own storage folder (`VERVANGING_STORAGE_DIR`) and a fixed first seed (`VERVANGING_SEED`). With
/// `TEST_RUNNER_VERVANGING_SHOTS` set to a folder on the Mac, the tests save screenshots there. The checks wait for
/// elements instead of reading them at once.
final class WideLayoutUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!
    private var lastWissel = Date.distantPast

    private let names = ["Lotte", "Fien", "Mila", "Noor", "Lien", "Anna", "Elise", "Hanne", "Jade", "Lore", "Marie", "Zoë"]
    private let numbers = ["4", "7", "8", "10", "11", "12", "13", "14", "15", "21", "23", "5"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("wide-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
        app.launchEnvironment["VERVANGING_SEED"] = "7"
    }

    override func tearDownWithError() throws {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    // MARK: - The phone layout

    /// On a phone-sized screen (the iPhone 17 Pro, the Duo's outer screen) the plan grid sits under the setup at full
    /// width and the minutes sit above the court, as before #105. Also saves the screenshots for the PR.
    @MainActor
    func testAPhoneSizedScreenKeepsThePhoneLayout() throws {
        try plantRoster(12)
        launchOnSetup()
        try XCTSkipIf(isWideScreen(), "the Duo's inner screen takes the wide layout")
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        save("setup-phone-top")
        let row = app.buttons["setup.present.4"]
        reveal(row)
        let rowFrame = row.frame
        let grid = app.descendants(matching: .any)["setup.grid"]
        reveal(grid)
        save("setup-phone-grid")
        XCTAssertLessThan(abs(grid.frame.minX - rowFrame.minX), 40, "the grid sits in the same column as the setup")
        XCTAssertGreaterThan(grid.frame.width, 0.7 * window().frame.width, "the grid takes the whole width")

        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        tapWissel(expecting: "Blok 2 van 12")
        save("live-phone")
        XCTAssertTrue(isPhoneLive(), "the minutes sit above the court")
    }

    // MARK: - Switching mid-match

    /// Turning the phone to landscape with the threshold lowered gives the app a wide window mid-match, as unfolding
    /// the Duo does: the live screen puts the minutes beside the court, the setup puts the plan grid beside the rest,
    /// and turning back gives the phone layout again. The block, the players and the minutes stay as they were.
    @MainActor
    func testASizeChangeMidMatchSwitchesTheLayoutAndKeepsTheMatch() throws {
        try plantRoster(12)
        app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x0"
        launchOnSetup()
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        for block in 2...4 { tapWissel(expecting: "Blok \(block) van 12") }
        XCTAssertTrue(isPhoneLive())
        let before = matchState()
        XCTAssertEqual(before.court.count, 5)

        // Wide: the minutes beside the court.
        try turnToLandscape()
        let isWide = waitUntil { self.isWideLive() }
        save("live-wide-landscape")
        XCTAssertTrue(isWide, "the minutes sit beside the court in a wide window")
        XCTAssertEqual(matchState(), before, "the same block, players and minutes after the switch")

        // The match goes on in the wide layout.
        tapWissel(expecting: "Blok 5 van 12")
        let afterWissel = matchState()
        XCTAssertNotEqual(afterWissel, before)

        // The setup in the wide layout: the plan grid beside the attendance list.
        let back = app.navigationBars.buttons["Match"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.buttons["setup.backToMatch"].waitForExistence(timeout: 5))
        let grid = app.descendants(matching: .any)["setup.grid"]
        let present = app.buttons["setup.present.4"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5), "the plan grid is in view without scrolling")
        XCTAssertTrue(present.waitForExistence(timeout: 5))
        XCTAssertGreaterThanOrEqual(grid.frame.minX, present.frame.maxX - 1, "the grid sits beside the attendance list")
        save("setup-wide-landscape")
        app.buttons["setup.backToMatch"].tap()
        XCTAssertTrue(app.staticTexts["Blok 5 van 12"].waitForExistence(timeout: 5))

        // Back to a phone-sized window: the phone layout, the same match.
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(waitUntil { self.isPhoneLive() }, "the minutes sit above the court again")
        XCTAssertEqual(matchState(), afterWissel, "the same block, players and minutes after switching back")
    }

    /// Without the lowered threshold, a phone turned to landscape keeps the phone layout: the window is wide but not
    /// tall enough for the wide layout.
    @MainActor
    func testALandscapePhoneKeepsThePhoneLayout() throws {
        try plantRoster(12)
        launchOnSetup()
        try XCTSkipIf(isWideScreen(), "the Duo's inner screen takes the wide layout")
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        try turnToLandscape()
        XCTAssertTrue(waitUntil { self.isPhoneLive() }, "a landscape phone keeps the minutes above the court")
    }

    // MARK: - The Duo's inner screen

    /// ⚠ On the Duo's inner screen itself (669 × 951 pt), the whole 12 × 12 plan grid and Start are in view at once,
    /// without scrolling, and the live screen shows the minutes beside the court. Skipped on a phone-sized screen, so
    /// it only runs where the simulator shows the inner screen; it never has so far (plan assumption A6).
    @MainActor
    func testTheInnerScreenShowsTheWholePlanGridAndTheMinutesBesideTheCourt() throws {
        try plantRoster(12)
        launchOnSetup()
        try XCTSkipUnless(isWideScreen(), "needs the iPhone Duo's inner screen; the simulator shows only the outer one")
        let basis = app.buttons["setup.basis.4"]
        XCTAssertTrue(basis.waitForExistence(timeout: 5))
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        let tabBar = app.tabBars.firstMatch
        let bottom = tabBar.exists ? tabBar.frame.minY : window().frame.maxY
        for number in numbers {
            let row = app.buttons["setup.row.\(number)"]
            XCTAssertTrue(row.waitForExistence(timeout: 5), "row #\(number)")
            XCTAssertTrue(row.isHittable, "row #\(number) is in view")
            XCTAssertLessThanOrEqual(row.frame.maxY, bottom, "row #\(number) sits above the tab bar")
        }
        XCTAssertTrue(app.buttons["setup.start"].isHittable, "Start is in view")
        save("setup-wide-inner")
        app.buttons["setup.start"].tap()
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { self.isWideLive() }, "the minutes sit beside the court")
        save("live-wide-inner")
    }

    // MARK: - Helpers

    /// What must survive a switch: the block, the next wissel's time, who is on court and every player's minutes.
    private struct MatchState: Equatable {
        var title: String
        var subTime: String
        var court: [String]
        var minutes: [String]
    }

    @MainActor private func matchState() -> MatchState {
        let subTime = app.staticTexts["live.subTime"]
        XCTAssertTrue(subTime.waitForExistence(timeout: 5))
        let title = app.staticTexts.matching(NSPredicate(format: "label BEGINSWITH 'Blok ' AND label CONTAINS ' van '"))
            .firstMatch
        XCTAssertTrue(title.waitForExistence(timeout: 5))
        return MatchState(title: title.label, subTime: subTime.label,
                          court: elements("live.court.").map { $0.label }.sorted(),
                          minutes: numbers.map { "\($0) \((overviewCell($0).value as? String) ?? "?")" })
    }

    /// The phone layout: the minutes at a glance above the court, in the same column.
    @MainActor private func isPhoneLive() -> Bool {
        guard let (cell, court) = overviewAndCourt() else { return false }
        return cell.maxY <= court.minY && abs(cell.minX - court.minX) < 40
    }

    /// The wide layout: the minutes at a glance in a column beside the court.
    @MainActor private func isWideLive() -> Bool {
        guard let (cell, court) = overviewAndCourt() else { return false }
        return cell.minX >= court.maxX - 1
    }

    @MainActor private func overviewAndCourt() -> (CGRect, CGRect)? {
        let cell = overviewCell(numbers[0])
        guard cell.waitForExistence(timeout: 5), let court = elements("live.court.").first else { return nil }
        return (cell.frame, court.frame)
    }

    /// Whether the app runs on a screen big enough for the wide layout without the lowered threshold: the Duo's inner
    /// screen, 669 × 951 pt.
    @MainActor private func isWideScreen() -> Bool {
        XCTAssertTrue(window().waitForExistence(timeout: 5))
        let frame = window().frame
        return min(frame.width, frame.height) >= 600
    }

    @MainActor private func window() -> XCUIElement { app.windows.firstMatch }

    /// Turns the phone to landscape and waits for the window to follow. ⚠ The Duo simulator's outer screen does not
    /// turn (seen on 24 Nov 2026), so there the test skips: it runs on a phone that turns, such as the iPhone 17 Pro.
    @MainActor private func turnToLandscape() throws {
        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = waitUntil { self.window().frame.width > self.window().frame.height }
        try XCTSkipUnless(turned, "this screen does not turn to landscape in the simulator (the Duo's outer screen)")
    }

    @MainActor private func plantRoster(_ count: Int) throws {
        let players = (0..<count).map { ["id": $0 + 1, "name": names[$0], "number": numbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": count + 1, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
    }

    @MainActor private func launchOnSetup() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        let tab = app.buttons["Match"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
    }

    /// Taps Wissel more than 600 ms after the last tap, so it is never taken as a double tap, and waits for the block.
    @MainActor private func tapWissel(expecting title: String) {
        let wait = 0.7 - Date().timeIntervalSince(lastWissel)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let button = app.buttons["live.wissel"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        lastWissel = Date()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
    }

    @MainActor private func overviewCell(_ number: String) -> XCUIElement {
        app.descendants(matching: .any)["live.overview.\(number)"]
    }

    @MainActor private func elements(_ prefix: String) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
    }

    /// Polls a condition for up to five seconds: a layout switch is animated.
    @MainActor private func waitUntil(_ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.25))
        }
        return condition()
    }

    /// Scrolls until the element is on screen and hittable: down first, then back up.
    @MainActor private func reveal(_ element: XCUIElement) {
        for i in 0..<12 {
            if i == 0 ? element.waitForExistence(timeout: 2) : element.exists, element.isHittable { return }
            app.swipeUp(velocity: .slow)
        }
        for _ in 0..<16 {
            if element.exists, element.isHittable { return }
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(element.exists && element.isHittable, "could not scroll to \(element)")
    }

    @MainActor private func tapReveal(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    /// Keeps a screenshot with the test result, and writes it to `TEST_RUNNER_VERVANGING_SHOTS` when that is set.
    @MainActor private func save(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        guard let folder = ProcessInfo.processInfo.environment["VERVANGING_SHOTS"], !folder.isEmpty else { return }
        let url = URL(fileURLWithPath: folder, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? shot.pngRepresentation.write(to: url.appendingPathComponent("\(name).png"))
    }
}
