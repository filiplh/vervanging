import XCTest

/// The tab bar after turning the phone (#151): the owner saw the selected tab's glass highlight sit too high in the
/// side tab bar after a few turns on the iPhone Duo simulator. These tests turn the phone ten times (left, right and
/// back upright), wait after every turn between upright and landscape until the window has really turned (a turn
/// from one landscape side to the other keeps the window's shape, so geometry cannot confirm it; those turns only
/// wait for the screen to settle), and check that the selected tab is still
/// selected and hittable, that the other tab is not selected, and that each tab button is back where it was in the
/// same orientation. With `VERVANGING_SHOTS` set (as `TEST_RUNNER_VERVANGING_SHOTS` on the xcodebuild command line)
/// they save a screenshot after every turn.
///
/// ⚠ XCUITest cannot see the glass highlight itself: it is drawn by the system's tab bar and is not an accessibility
/// element. Whether it sits on the selected tab is only visible on the screenshots.
/// ⚠ The Duo simulator's outer screen does not turn (seen on 24 Nov 2026) and its inner screen cannot be unfolded from
/// a test. Each test runs its upright checks first and then skips the turns, with a reason, on a screen that does not
/// turn; they run on a phone that turns, such as the iPhone 17 Pro.
final class TabBarUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!

    @MainActor override func setUp() async throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabbar-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
        app.launchEnvironment["VERVANGING_SEED"] = "7"
    }

    @MainActor override func tearDown() async throws {
        XCUIDevice.shared.orientation = .portrait
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    /// Ten turns on Spelers, then the same on Match: the selected tab stays selected, hittable and in its place.
    @MainActor
    func testTheSelectedTabStaysSelectedAndInPlaceAfterTurning() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        checkTabs(selected: "Spelers", other: "Match", "upright on Spelers")
        tab("Match").tap()
        XCTAssertTrue(waitUntil { self.tab("Match").isSelected }, "Match is selected after tapping it")
        checkTabs(selected: "Match", other: "Spelers", "upright on Match")
        tab("Spelers").tap()
        XCTAssertTrue(waitUntil { self.tab("Spelers").isSelected }, "Spelers is selected after tapping it")

        try skipUnlessTheScreenTurns()
        try turnTenTimes(selected: "Spelers", other: "Match", label: "spelers")
        tab("Match").tap()
        XCTAssertTrue(waitUntil { self.tab("Match").isSelected }, "Match is selected after tapping it")
        try turnTenTimes(selected: "Match", other: "Spelers", label: "match")
    }

    /// The owner's path before the glitch (#151): a played match (the live screen hides the tab bar), Nieuwe match
    /// (the tab bar comes back), then Spelers and ten turns. The tab bar hiding and coming back must not move it.
    @MainActor
    func testTheTabsStayInPlaceAfterAMatchHidTheTabBar() throws {
        try plantRoster()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        let spelersBefore = tab("Spelers").frame, matchBefore = tab("Match").frame
        save("after-match-00-before")

        startMatch()
        playToTheEnd()
        newMatch()
        tab("Spelers").tap()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 5))
        settle()
        save("after-match-01-spelers")
        checkTabs(selected: "Spelers", other: "Match", "after the match")
        assertSame(tab("Spelers").frame, spelersBefore, "Spelers sits where it sat before the match")
        assertSame(tab("Match").frame, matchBefore, "Match sits where it sat before the match")

        try skipUnlessTheScreenTurns()
        try turnTenTimes(selected: "Spelers", other: "Match", label: "after-match")
    }

    /// Turning while the live screen hides the tab bar (#151, review of #157): ten turns mid-match, the match played
    /// to the end, then Nieuwe match shows the tab bar again. Upright and turned to the left, both tabs sit where they
    /// sat before the match, Match stays selected, and Spelers can still be picked.
    @MainActor
    func testTheTabsComeBackInPlaceAfterTurningWhileTheTabBarWasHidden() throws {
        try plantRoster()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        checkTabs(selected: "Spelers", other: "Match", "upright before the match")
        try skipUnlessTheScreenTurns()
        tab("Match").tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        let upright = (tab("Match").frame, tab("Spelers").frame)
        try turn(to: .landscapeLeft)
        let left = (tab("Match").frame, tab("Spelers").frame)
        try turn(to: .portrait)

        startMatch()
        save("hidden-00-live")
        XCTAssertTrue(waitUntil { !self.tabBarShows() }, "the live screen hides the tab bar")
        for (index, orientation) in turns.enumerated() {
            try turn(to: orientation)
            save(String(format: "hidden-%02d-%@", index + 1, key(orientation)))
            XCTAssertTrue(app.staticTexts["Blok 1 van 12"].exists, "the live screen stays at block 1 after turn \(index + 1)")
            XCTAssertFalse(tabBarShows(), "the tab bar stays hidden after turn \(index + 1)")
        }
        playToTheEnd()
        newMatch()
        settle()
        save("hidden-11-shown-portrait")
        checkTabs(selected: "Match", other: "Spelers", "after the tab bar came back")
        assertSame(tab("Match").frame, upright.0, "Match sits where it sat upright before the match")
        assertSame(tab("Spelers").frame, upright.1, "Spelers sits where it sat upright before the match")
        try turn(to: .landscapeLeft)
        save("hidden-12-shown-left")
        checkTabs(selected: "Match", other: "Spelers", "turned left after the tab bar came back")
        assertSame(tab("Match").frame, left.0, "Match sits where it sat turned left before the match")
        assertSame(tab("Spelers").frame, left.1, "Spelers sits where it sat turned left before the match")
        try turn(to: .portrait)
        tab("Spelers").tap()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 5))
        checkTabs(selected: "Spelers", other: "Match", "Spelers picked after the tab bar came back")
    }

    // MARK: - Helpers

    /// Opens Match, picks the basisvijf and taps Start: the live screen opens at block 1, without the tab bar.
    @MainActor private func startMatch() {
        tab("Match").tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        for number in ["4", "7", "8", "10", "11"] { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
    }

    /// Taps Wissel twelve times, more than 600 ms apart so none is taken as a double tap: the match ends.
    @MainActor private func playToTheEnd() {
        var last = Date.distantPast
        for _ in 1...12 {
            let wait = 0.7 - Date().timeIntervalSince(last)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let wissel = app.buttons["live.wissel"]
            XCTAssertTrue(wissel.waitForExistence(timeout: 5))
            wissel.tap()
            last = Date()
        }
    }

    /// Taps Nieuwe match on the end screen: setup opens with the tab bar back.
    @MainActor private func newMatch() {
        let button = app.buttons["live.newMatch"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
    }

    /// The selected tab is selected and the other is not, and both are hittable.
    @MainActor private func checkTabs(selected: String, other: String, _ when: String) {
        XCTAssertTrue(tab(selected).isSelected, "\(selected) is selected \(when)")
        XCTAssertFalse(tab(other).isSelected, "\(other) is not selected \(when)")
        XCTAssertTrue(tab(selected).isHittable, "\(selected) is hittable \(when)")
        XCTAssertTrue(tab(other).isHittable, "\(other) is hittable \(when)")
    }

    private func plantRoster() throws {
        let names = ["Lotte", "Fien", "Mila", "Noor", "Lien", "Anna", "Elise", "Hanne", "Jade", "Lore", "Marie", "Zoë"]
        let numbers = ["4", "7", "8", "10", "11", "12", "13", "14", "15", "21", "23", "5"]
        let players = (0..<12).map { ["id": $0 + 1, "name": names[$0], "number": numbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": 13, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
    }

    /// Scrolls until the element is on screen (down first, then up) and taps it, as the other UI tests do: setup's
    /// rows are made only when they scroll into view.
    @MainActor private func tapReveal(_ element: XCUIElement) {
        _ = element.waitForExistence(timeout: 2)
        func shown() -> Bool {
            guard element.exists, element.isHittable else { return false }
            // The Start bar on setup floats over rows (#150): a tap there would land on Start. Only its own buttons
            // lie inside it.
            let startBar = app.descendants(matching: .any)["setup.actions"]
            return !startBar.exists || ["setup.start", "setup.anotherPlan"].contains(element.identifier)
                || !element.frame.intersects(startBar.frame)
        }
        for _ in 0..<12 where !shown() { app.swipeUp(velocity: .slow) }
        for _ in 0..<16 where !shown() { app.swipeDown(velocity: .slow) }
        XCTAssertTrue(shown(), "could not scroll to \(element)")
        element.tap()
    }

    private let turns: [UIDeviceOrientation] = [
        .landscapeLeft, .portrait, .landscapeRight, .portrait, .landscapeLeft,
        .landscapeRight, .portrait, .landscapeRight, .landscapeLeft, .portrait,
    ]

    /// Turns the phone ten times and checks the tabs after each turn. The first time the phone stands in an
    /// orientation, the tab frames are remembered; every later visit to that orientation must give the same frames.
    @MainActor private func turnTenTimes(selected: String, other: String, label: String) throws {
        var frames: [String: (CGRect, CGRect)] = [:]
        frames[key(.portrait)] = (tab(selected).frame, tab(other).frame)
        save("\(label)-00-portrait")
        for (index, orientation) in turns.enumerated() {
            try turn(to: orientation)
            let name = String(format: "%@-%02d-%@", label, index + 1, key(orientation))
            save(name)
            checkTabs(selected: selected, other: other, "after turn \(index + 1)")
            let now = (tab(selected).frame, tab(other).frame)
            if let before = frames[key(orientation)] {
                assertSame(now.0, before.0, "\(selected) sits where it sat before in \(key(orientation)), turn \(index + 1)")
                assertSame(now.1, before.1, "\(other) sits where it sat before in \(key(orientation)), turn \(index + 1)")
            } else {
                frames[key(orientation)] = now
            }
        }
    }

    /// The tab bar button with that title. iOS 27's tab bar shows each tab as a button with the tab's title.
    @MainActor private func tab(_ title: String) -> XCUIElement {
        app.tabBars.buttons[title].exists ? app.tabBars.buttons[title] : app.buttons[title].firstMatch
    }

    private func key(_ orientation: UIDeviceOrientation) -> String {
        switch orientation {
        case .landscapeLeft: "left"
        case .landscapeRight: "right"
        default: "portrait"
        }
    }

    /// Whether the Spelers tab can be tapped: false while the live screen hides the tab bar. Only Spelers: the live
    /// screen's back button is called "Match" too.
    @MainActor private func tabBarShows() -> Bool {
        tab("Spelers").exists && tab("Spelers").isHittable
    }

    @MainActor private func window() -> XCUIElement { app.windows.firstMatch }

    /// Whether the window stands in that orientation: wider than high when turned, higher than wide upright.
    @MainActor private func windowIs(_ orientation: UIDeviceOrientation) -> Bool {
        let frame = window().frame
        return orientation.isLandscape ? frame.width > frame.height : frame.height > frame.width
    }

    /// Turns the phone, fails unless the window has the new orientation's shape within 5 s, then waits for the turn to
    /// settle. From one landscape side to the other the shape does not change, so that check passes at once there.
    @MainActor private func turn(to orientation: UIDeviceOrientation) throws {
        XCUIDevice.shared.orientation = orientation
        XCTAssertTrue(waitUntil { self.windowIs(orientation) }, "the window turned to \(key(orientation))")
        settle()
    }

    /// Skips the rest of the test, with the reason, when the screen does not turn (the Duo's outer screen in the
    /// simulator): turns it to the left, and back upright when it did turn.
    @MainActor private func skipUnlessTheScreenTurns() throws {
        XCTAssertTrue(window().waitForExistence(timeout: 5))
        XCUIDevice.shared.orientation = .landscapeLeft
        let turned = waitUntil { self.windowIs(.landscapeLeft) }
        XCUIDevice.shared.orientation = .portrait
        try XCTSkipUnless(turned, "this screen does not turn to landscape in the simulator (the Duo's outer screen); "
                          + "the upright checks ran, the turns are left to a phone that turns")
        XCTAssertTrue(waitUntil { self.windowIs(.portrait) }, "the window turned back upright")
        settle()
    }

    /// Waits until the turn's animation has ended, and fails when it does not within 5 s: the window's frame and, when
    /// the tab bar shows, the Spelers tab's frame read the same twice in a row.
    @MainActor private func settle() {
        var last: [CGRect] = []
        let settled = waitUntil(timeout: 5) {
            var now = [self.window().frame]
            let spelers = self.tab("Spelers")
            if spelers.exists { now.append(spelers.frame) }
            defer { last = now }
            return now == last
        }
        XCTAssertTrue(settled, "the screen settled after turning")
        Thread.sleep(forTimeInterval: 0.5)
    }

    private func assertSame(_ a: CGRect, _ b: CGRect, _ message: String) {
        XCTAssertEqual(a.midX, b.midX, accuracy: 1, message)
        XCTAssertEqual(a.midY, b.midY, accuracy: 1, message)
        XCTAssertEqual(a.width, b.width, accuracy: 1, message)
        XCTAssertEqual(a.height, b.height, accuracy: 1, message)
    }

    @MainActor private func waitUntil(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(timeout)
        while Date() < end {
            if condition() { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        return condition()
    }

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
