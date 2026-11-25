import XCTest

/// The tab bar after turning the phone (#151): the owner saw the selected tab's glass highlight sit too high in the
/// side tab bar after a few turns on the iPhone Duo simulator. This test turns the phone ten times (left, right and
/// back upright) and checks after every turn that the selected tab is still selected and hittable, that the other tab
/// is not selected, and that each tab button is back where it was in the same orientation. With `VERVANGING_SHOTS`
/// set (as `TEST_RUNNER_VERVANGING_SHOTS` on the xcodebuild command line) it saves a screenshot after every turn.
///
/// ⚠ XCUITest cannot see the glass highlight itself: it is drawn by the system's tab bar and is not an accessibility
/// element. Whether it sits on the selected tab is only visible on the screenshots.
/// ⚠ The Duo simulator's outer screen does not turn (seen on 24 Nov 2026) and its inner screen cannot be unfolded from
/// a test, so there the turns change nothing; the test then still checks the tabs, upright only.
final class TabBarUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("tabbar-\(UUID().uuidString)", isDirectory: true)
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

    /// Ten turns on Spelers, then the same on Match: the selected tab stays selected, hittable and in its place.
    @MainActor
    func testTheSelectedTabStaysSelectedAndInPlaceAfterTurning() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
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

        tab("Match").tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        for number in ["4", "7", "8", "10", "11"] { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        var last = Date.distantPast
        for _ in 1...12 {
            let wait = 0.7 - Date().timeIntervalSince(last)
            if wait > 0 { Thread.sleep(forTimeInterval: wait) }
            let wissel = app.buttons["live.wissel"]
            XCTAssertTrue(wissel.waitForExistence(timeout: 5))
            wissel.tap()
            last = Date()
        }
        let newMatch = app.buttons["live.newMatch"]
        XCTAssertTrue(newMatch.waitForExistence(timeout: 5))
        newMatch.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        tab("Spelers").tap()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 5))
        settle()
        save("after-match-01-spelers")
        XCTAssertTrue(tab("Spelers").isSelected, "Spelers is selected after the match")
        assertSame(tab("Spelers").frame, spelersBefore, "Spelers sits where it sat before the match")
        assertSame(tab("Match").frame, matchBefore, "Match sits where it sat before the match")
        try turnTenTimes(selected: "Spelers", other: "Match", label: "after-match")
    }

    // MARK: - Helpers

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
        func shown() -> Bool { element.exists && element.isHittable }
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
            XCUIDevice.shared.orientation = orientation
            settle()
            let name = String(format: "%@-%02d-%@", label, index + 1, key(orientation))
            save(name)
            XCTAssertTrue(tab(selected).isSelected, "\(selected) is still selected after turn \(index + 1)")
            XCTAssertFalse(tab(other).isSelected, "\(other) is not selected after turn \(index + 1)")
            XCTAssertTrue(tab(selected).isHittable, "\(selected) is hittable after turn \(index + 1)")
            XCTAssertTrue(tab(other).isHittable, "\(other) is hittable after turn \(index + 1)")
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

    /// Waits until the window has followed the turn and the tab bar's animation has ended: the selected tab's frame
    /// reads the same twice in a row.
    @MainActor private func settle() {
        var last = CGRect.null
        _ = waitUntil(timeout: 5) {
            let frame = self.tab("Spelers").frame
            defer { last = frame }
            return frame == last
        }
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
