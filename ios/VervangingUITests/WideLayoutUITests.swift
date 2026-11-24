import XCTest

/// The wide layout for the iPhone Duo's inner screen (#105, #143, plan decision #41): the setup shows the plan grid in
/// its own column beside the rest of the setup, and the live screen puts the match side by side in columns (two with the
/// inner screen upright, three with it turned), so it needs no scrolling. A screen takes it from its window's size (at
/// least 600 × 500 pt), never from the device model, so the iPhone 17 Pro and the Duo's outer screen keep the phone
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
    /// Three more, for a full 15-player match.
    private let extraNames = ["Fleur", "Roos", "Saar"]
    private let extraNumbers = ["16", "17", "18"]

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

    // MARK: - The wide arrangement (#143)

    /// The turned wide live screen puts the match in three columns that all start at the top: the coming wissel (its
    /// time, the change, In the zone and the last action) on the left, the minutes at a glance and the court in the
    /// middle, the minutes table with Uit on the right. Each column is short enough for the room the turned inner screen
    /// leaves between the bars, so on it the whole match is in view without scrolling.
    @MainActor
    func testTheTurnedWideLiveScreenPutsTheMatchInThreeColumns() throws {
        try checkThreeColumns(players: 12)
    }

    /// The same with the most players a match takes, 15: the table's rows are shorter still.
    @MainActor
    func testTheTurnedWideLiveScreenFitsFifteenPlayers() throws {
        try checkThreeColumns(players: 15)
    }

    @MainActor private func checkThreeColumns(players: Int) throws {
        try plantRoster(players)
        app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x0"
        launchOnSetup()
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        tapWissel(expecting: "Blok 2 van 12")
        try turnToLandscape()
        XCTAssertTrue(waitUntil { self.isWideLive() }, "the minutes table sits beside the court")
        save("live-wide-turned-\(players)")
        XCTAssertTrue(app.descendants(matching: .any)["live.zone.keep"].exists, "In the zone is on the screen")
        XCTAssertTrue(app.staticTexts["live.message"].exists, "the confirmation line is on the screen")

        let left = leftColumn(), middle = middleColumn(), right = rightColumn()
        for (name, column) in [("left", left), ("middle", middle), ("right", right)] {
            XCTAssertFalse(column.isEmpty, "the \(name) column has its elements")
        }
        XCTAssertLessThanOrEqual(span(left).maxX, span(middle).minX, "the coming wissel sits left of the court")
        XCTAssertLessThanOrEqual(span(middle).maxX, span(right).minX, "the minutes table sits right of the court")
        let tops = [left, middle, right].map { span($0).minY }
        XCTAssertLessThan(tops.max()! - tops.min()!, 30, "the three columns start at the top, level: \(tops)")
        for (name, column) in [("left", left), ("middle", middle), ("right", right)] {
            XCTAssertLessThanOrEqual(span(column).height, Self.turnedInnerRoom,
                                     "the \(name) column fits between the bars of the turned inner screen")
        }
        XCTAssertEqual(elements("live.uit.").count, players, "every row of the table has Uit")
    }

    /// The layout is taken from the window, so it does not change while the page scrolls (on the inner screen the
    /// navigation bar shrank mid-scroll and the live screen swapped layouts, #143). The threshold sits between the
    /// room between the bars (about 270 pt on a turned phone) and the window (402 pt): measured on the window, the wide
    /// layout holds at the top and all through the scroll.
    @MainActor
    func testScrollingKeepsTheLayout() throws {
        try plantRoster(12)
        app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x380"
        launchOnSetup()
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        try turnToLandscape()
        XCTAssertTrue(waitUntil { self.isWideLive() }, "a window taller than the threshold takes the wide layout")
        for _ in 0..<3 {
            app.swipeUp(velocity: .slow)
            XCTAssertTrue(isWideLive(), "the wide layout holds while scrolling down")
        }
        for _ in 0..<3 {
            app.swipeDown(velocity: .slow)
            XCTAssertTrue(isWideLive(), "the wide layout holds while scrolling back up")
        }
    }

    /// The wide setup sets its two columns apart and starts both at the top: a clear gap between the attendance card
    /// and the plan card, and the plan's heading level with the attendance heading, right under a small title.
    @MainActor
    func testTheWideSetupSetsItsColumnsApartAndStartsThePlanAtTheTop() throws {
        try plantRoster(12)
        app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x0"
        launchOnSetup()
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        try turnToLandscape()
        let grid = app.descendants(matching: .any)["setup.grid"]
        let basis = app.buttons["setup.basis.4"]
        XCTAssertTrue(waitUntil { grid.exists && basis.exists && grid.frame.minX >= basis.frame.maxX },
                      "the plan grid sits beside the attendance list")
        save("setup-wide-turned")
        // The plan card's edge sits 10 pt left of the grid, the attendance card's about 20 pt right of Basis; the cards
        // touched before #143, with the grid about 29 pt from Basis.
        XCTAssertGreaterThanOrEqual(grid.frame.minX - basis.frame.maxX, 44, "a clear gap between the two cards")
        let plan = app.staticTexts["Plan"].firstMatch
        let attendance = app.staticTexts["Aanwezig en basisvijf"].firstMatch
        XCTAssertTrue(plan.waitForExistence(timeout: 5))
        XCTAssertTrue(attendance.waitForExistence(timeout: 5))
        XCTAssertLessThan(abs(plan.frame.minY - attendance.frame.minY), 12, "the plan starts level with the left column")
        let bar = app.navigationBars["Match"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertLessThan(plan.frame.minY - bar.frame.maxY, 60, "no empty band between the title and the plan")
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
        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertTrue(waitUntil { self.isWideLive() }, "the minutes table sits beside the court")
        save("live-wide-inner")
        // ⚠ #143: the whole match in view at once, without scrolling, and nothing under the Wissel bar.
        let bar = app.descendants(matching: .any)["live.actions"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Blok 2 van 12"].isHittable, "the block is in view")
        for element in leftColumn() + middleColumn() + rightColumn() {
            XCTAssertTrue(element.isHittable, "\(element.identifier) is in view")
            XCTAssertLessThanOrEqual(element.frame.maxY, bar.frame.minY, "\(element.identifier) sits above the Wissel bar")
        }
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

    /// The phone layout: the minutes at a glance above the court, the minutes table below it, all in one column.
    @MainActor private func isPhoneLive() -> Bool {
        guard let (cell, court, table) = overviewCourtAndTable() else { return false }
        return cell.maxY <= court.minY && abs(cell.minX - court.minX) < 40 && table.minY >= court.maxY
    }

    /// The wide layout (either way round): the minutes table in a column beside the court.
    @MainActor private func isWideLive() -> Bool {
        guard let (_, court, table) = overviewCourtAndTable() else { return false }
        return table.minX >= court.maxX - 1
    }

    @MainActor private func overviewCourtAndTable() -> (CGRect, CGRect, CGRect)? {
        let cell = overviewCell(numbers[0])
        let table = app.descendants(matching: .any)["live.minutes.\(numbers[0])"]
        guard cell.waitForExistence(timeout: 5), table.waitForExistence(timeout: 5),
              let court = elements("live.court.").first else { return nil }
        return (cell.frame, court.frame, table.frame)
    }

    /// ⚠ The room between the bars on the turned inner screen (951 × 669 pt), about 473 pt as measured on the owner's
    /// screenshot of #140 (the page starts about 89 pt from the top, the Wissel bar about 568 pt), less a margin.
    private static let turnedInnerRoom: CGFloat = 460

    /// The coming wissel: its time, the change, In the zone and the last action.
    @MainActor private func leftColumn() -> [XCUIElement] {
        ([app.staticTexts["live.subTime"]] + elements("live.off.") + elements("live.on.")
            + [app.descendants(matching: .any)["live.zone.keep"], app.staticTexts["live.message"]]).filter(\.exists)
    }

    /// The minutes at a glance and who is on court.
    @MainActor private func middleColumn() -> [XCUIElement] {
        elements("live.overview.") + elements("live.court.")
    }

    /// The minutes table with Uit.
    @MainActor private func rightColumn() -> [XCUIElement] {
        [app.staticTexts["live.table.heading"]].filter(\.exists) + elements("live.minutes.") + elements("live.uit.")
    }

    /// The frame around these elements.
    @MainActor private func span(_ column: [XCUIElement]) -> CGRect {
        column.map(\.frame).reduce(CGRect.null) { $0.union($1) }
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
        let allNames = names + extraNames, allNumbers = numbers + extraNumbers
        let players = (0..<count).map { ["id": $0 + 1, "name": allNames[$0], "number": allNumbers[$0]] as [String: Any] }
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
