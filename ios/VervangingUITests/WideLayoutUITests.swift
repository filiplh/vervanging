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
        XCTAssertTrue(isPhoneLive(), "the minutes table sits below the court")
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
        XCTAssertTrue(waitUntil { self.isPhoneLive() }, "the minutes table sits below the court again")
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

    /// The turned wide live screen puts the coming wissel and the court on the left, the minutes on the right, both from
    /// the top: the minutes at a glance above the table, and the table in two halves side by side, so 15 players take
    /// eight rows.
    @MainActor
    func testTheTurnedWideLiveScreenPutsTheWisselLeftAndTheMinutesRight() throws {
        try plantRoster(15)
        app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x0"
        launchOnSetup()
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        tapWissel(expecting: "Blok 2 van 12")
        try turnToLandscape()
        XCTAssertTrue(waitUntil { self.isWideLive() }, "the minutes table sits beside the court")
        save("live-wide-turned-15")

        let left = span(wisselAndCourt()), right = span(minutesElements())
        XCTAssertLessThanOrEqual(left.maxX, right.minX, "the coming wissel and the court sit left of the minutes")
        XCTAssertLessThan(abs(left.minY - right.minY), 30, "both columns start at the top")
        let sorted = (numbers + extraNumbers).sorted { Int($0)! < Int($1)! }
        let first = tableRow(sorted[0]).frame, secondHalf = tableRow(sorted[8]).frame
        XCTAssertGreaterThan(secondHalf.minX, first.maxX, "the table's second half sits beside the first")
        XCTAssertLessThan(abs(secondHalf.minY - first.minY), 4, "both halves start level")
        XCTAssertLessThanOrEqual(span(elements("live.overview.")).maxY, first.minY, "the minutes at a glance sit above")
    }

    // MARK: - The inner screen's sizes, in the debug canvas (#143)

    /// ⚠ The inner screen turned, 951 × 669 pt, with the safe area measured on the owner's screenshot of #140: the
    /// status bar sits in a column of about 83 pt on the right (with the time and the back button), so the navigation
    /// bar starts at the top (its title about 38 pt down, the page about 89 pt), and the Wissel bar ends about 31 pt
    /// above the bottom edge.
    private static let turnedCanvas = "951x669@0,0,31,83"
    /// ⚠ The inner screen upright, 669 × 951 pt; its safe area (a status bar and a home indicator) is a guess.
    private static let uprightCanvas = "669x951@50,0,20,0"

    /// Turned, 12 players: everything the coach needs during a match is in view at once, without scrolling, and nothing
    /// sits under the Wissel bar, also with In the zone chosen (Op de bank, Extra minuten and the note) and with a
    /// player uit (Terug and who came on). Every Uit and Terug is a target of its own of at least 44 × 44 pt.
    @MainActor
    func testTheTurnedInnerScreenShowsEveryStateWithoutScrollingFor12Players() throws {
        try checkInnerScreen(Self.turnedCanvas, players: 12, name: "turned-12")
    }

    @MainActor
    func testTheTurnedInnerScreenShowsEveryStateWithoutScrollingFor15Players() throws {
        try checkInnerScreen(Self.turnedCanvas, players: 15, name: "turned-15")
    }

    @MainActor
    func testTheUprightInnerScreenShowsEveryStateWithoutScrollingFor12Players() throws {
        try checkInnerScreen(Self.uprightCanvas, players: 12, name: "upright-12")
    }

    @MainActor
    func testTheUprightInnerScreenShowsEveryStateWithoutScrollingFor15Players() throws {
        try checkInnerScreen(Self.uprightCanvas, players: 15, name: "upright-15")
    }

    /// Lays the live screen out at the inner screen's size in the debug canvas (`VERVANGING_CANVAS`, debug builds), and
    /// checks the states one after the other.
    @MainActor private func checkInnerScreen(_ canvasSpec: String, players: Int, name: String) throws {
        try plantRoster(players)
        app.launchEnvironment["VERVANGING_CANVAS"] = canvasSpec
        if let shots = ProcessInfo.processInfo.environment["VERVANGING_CANVAS_SHOTS"] {
            app.launchEnvironment["VERVANGING_CANVAS_SHOTS"] = "\(shots)/\(name)"
        }
        launchOnSetup()
        for number in numbers.prefix(5) { tapReveal(app.buttons["setup.basis.\(number)"]) }
        // The turned canvas on a turned phone, so the phone's status bar does not take room at its top (the Duo has its
        // status bar on the side); the upright canvas on an upright phone. See `DebugCanvas`.
        tapReveal(app.buttons["setup.start"])
        let canvas = app.windows["debug.canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: 10), "the debug canvas shows the live screen")
        let width = Double(canvasSpec.prefix { $0 != "x" })!
        if canvasSpec.hasPrefix(Self.turnedCanvas.prefix(7)) {
            XCUIDevice.shared.orientation = .landscapeLeft
            // Turned, the phone is 874 × 402 pt: the canvas is scaled to 402 / 669 of its size.
            XCTAssertTrue(waitUntil { abs(canvas.frame.height - 402) < 2 }, "the canvas fills the turned phone's height")
        }
        let scale = canvas.frame.width / width
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertTrue(waitUntil { self.isWideLive() }, "the inner screen takes the wide layout")

        // During a match: the time, the change with In the zone, the confirmation, the court, the minutes.
        assertWholeMatchInView(canvas, scale: scale, also: [], "\(name), during a match")
        save("inner-\(name)-match")

        // In the zone chosen, with Extra minuten: Op de bank, the switch and the note come in.
        let keep = try XCTUnwrap(elements("live.off.").first?.label)
        pick(keep, in: "live.zone.keep")
        let note = app.descendants(matching: .any)["live.zone.note"]
        XCTAssertTrue(note.waitForExistence(timeout: 5), "In the zone chosen")
        let extra = app.switches["live.zone.extra"]
        XCTAssertTrue(extra.waitForExistence(timeout: 5))
        extra.switches.firstMatch.tap()
        XCTAssertTrue(waitUntil { note.label.contains("extra blok") }, "Extra minuten on: \(note.label)")
        assertWholeMatchInView(canvas, scale: scale, also: ["live.zone.bench", "live.zone.extra", "live.zone.note"],
                               "\(name), In the zone with Extra minuten")
        save("inner-\(name)-zone")
        pick("Niemand", in: "live.zone.keep")
        XCTAssertTrue(waitUntil { !note.exists }, "In the zone cancelled")

        // A player on court uit: Terug in the table and who came on for the player under the court.
        let starter = try XCTUnwrap(elements("live.court.").first?.label)
        let number = String(starter.dropFirst().prefix { $0 != " " })
        let uit = app.buttons["live.uit.\(number)"]
        XCTAssertTrue(uit.waitForExistence(timeout: 5))
        uit.tap()
        let terug = app.buttons["live.terug.\(number)"]
        XCTAssertTrue(terug.waitForExistence(timeout: 5), "Terug for \(starter)")
        XCTAssertTrue(app.staticTexts["live.replaced.\(number)"].waitForExistence(timeout: 5), "who came on for \(starter)")
        assertWholeMatchInView(canvas, scale: scale, also: ["live.terug.\(number)", "live.replaced.\(number)"],
                               "\(name), a player uit")
        assertFullSizeTargets(scale: scale, name)
        save("inner-\(name)-uit")

        // The targets take their own taps: Terug answers.
        terug.tap()
        XCTAssertTrue(waitUntil { self.app.staticTexts["live.message"].label.contains("terug vanaf het volgende blok") },
                      "Terug was tapped")
    }

    /// Every element the coach needs is on the screen, inside the canvas and wholly above the Wissel bar, so nothing
    /// needs scrolling and nothing is covered.
    @MainActor private func assertWholeMatchInView(_ canvas: XCUIElement, scale: CGFloat, also ids: [String],
                                                   _ context: String) {
        let bar = app.descendants(matching: .any)["live.actions"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let bounds = canvas.frame.insetBy(dx: -0.5, dy: -0.5)
        var all = matchElements()
        for id in ids {
            let element = app.descendants(matching: .any)[id]
            XCTAssertTrue(element.exists, "\(context): \(id) is there")
            all.append(element)
        }
        XCTAssertTrue(app.staticTexts["Blok 2 van 12"].isHittable, "\(context): the block is in view")
        for element in all {
            let frame = element.frame
            XCTAssertTrue(bounds.contains(frame), "\(context): \(element.identifier) is inside the screen: \(frame)")
            XCTAssertLessThanOrEqual(frame.maxY, bar.frame.minY + 0.5,
                                     "\(context): \(element.identifier) sits above the Wissel bar (\(frame.maxY) > \(bar.frame.minY))")
        }
        for button in elements("live.uit.") + elements("live.terug.") {
            XCTAssertTrue(button.isHittable, "\(context): \(button.identifier) can be tapped")
        }
    }

    /// Every Uit and Terug is at least 44 × 44 pt on the inner screen, and no two overlap.
    @MainActor private func assertFullSizeTargets(scale: CGFloat, _ context: String) {
        let frames = (elements("live.uit.") + elements("live.terug.")).map { ($0.identifier, $0.frame) }
        XCTAssertFalse(frames.isEmpty)
        for (id, frame) in frames {
            XCTAssertGreaterThanOrEqual(frame.width / scale, 43.5, "\(context): \(id) is \(frame.width / scale) pt wide")
            XCTAssertGreaterThanOrEqual(frame.height / scale, 43.5, "\(context): \(id) is \(frame.height / scale) pt tall")
        }
        for (i, a) in frames.enumerated() {
            for b in frames[(i + 1)...] {
                let overlap = a.1.intersection(b.1)
                XCTAssertTrue(overlap.isNull || overlap.width * overlap.height < 0.5, "\(context): \(a.0) and \(b.0) overlap")
            }
        }
    }

    /// Picks an option in one of the zone's menus.
    @MainActor private func pick(_ option: String, in id: String) {
        let menu = app.buttons[id]
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        menu.tap()
        let item = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", option, id)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(option) in the menu")
        item.tap()
    }

    // MARK: - Start always in view (#150)

    /// ⚠ On the phone layout with 15 players with long names, Start sits in a bar pinned above the tab bar: in view
    /// without scrolling at the top of the setup, and the list scrolls its last plan row fully above the bar. Start
    /// keeps its rules: off without a basisvijf, on with one, and it opens the live screen.
    @MainActor
    func testStartStaysInViewOnThePhoneWithFifteenLongNames() throws {
        try plantLongNameRoster()
        launchOnSetup()
        try XCTSkipIf(isWideScreen(), "the Duo's inner screen takes the wide layout")
        let start = app.buttons["setup.start"]
        let bar = app.descendants(matching: .any)["setup.actions"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable, "Start is in view without scrolling")
        XCTAssertFalse(start.isEnabled, "no basisvijf yet")
        let tabBar = app.tabBars.firstMatch
        if tabBar.exists { XCTAssertLessThanOrEqual(bar.frame.maxY, tabBar.frame.minY + 1, "the bar sits above the tabs") }
        let list = app.collectionViews.firstMatch
        for number in ["4", "5", "6", "7", "8"] {
            let basis = app.buttons["setup.basis.\(number)"]
            bringIntoClearView(basis, in: list, above: bar.frame.minY)
            basis.tap()
        }

        // Down to the end of the list: the whole plan sits above the bar.
        for _ in 0..<12 { app.swipeUp(velocity: .fast) }
        let grid = app.descendants(matching: .any)["setup.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { grid.frame.maxY <= bar.frame.minY }, "the last plan row scrolls fully above the bar")
        XCTAssertEqual(planRows().count, 15)
        let lastRow = try XCTUnwrap(planRows().max { $0.frame.maxY < $1.frame.maxY })
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, bar.frame.minY, "\(lastRow.label) sits above the bar")
        save("setup-phone-start-bar-end")

        // Back to the top: Start is still in view, now on.
        for _ in 0..<12 { app.swipeDown(velocity: .fast) }
        let firstRow = app.buttons["setup.present.\(longNumbers.sorted { Int($0)! < Int($1)! }[0])"]
        XCTAssertTrue(waitUntil { firstRow.isHittable }, "back at the top of the setup")
        XCTAssertTrue(start.isHittable, "Start is in view at the top")
        XCTAssertTrue(start.isEnabled, "Start is on with a basisvijf")
        save("setup-phone-start-bar-top")
        start.tap()
        XCTAssertTrue(app.buttons["live.wissel"].waitForExistence(timeout: 5), "Start opens the live screen")
    }

    /// ⚠ The same on the wide layout (a turned iPhone 17 Pro with the threshold lowered, as the Duo's inner screen):
    /// Start sits in a bar under the plan column, in view without scrolling, and the plan scrolls fully above it.
    @MainActor
    func testStartStaysInViewInTheWideLayoutWithFifteenLongNames() throws {
        try plantLongNameRoster()
        app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x0"
        launchOnSetup()
        try turnToLandscape()
        XCTAssertTrue(waitUntil { self.app.collectionViews.count == 2 }, "the wide setup has its two lists")
        let lists = app.collectionViews.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let setupList = try XCTUnwrap(lists.first), planList = try XCTUnwrap(lists.last)
        let start = app.buttons["setup.start"]
        let bar = app.descendants(matching: .any)["setup.actions"]
        XCTAssertTrue(start.waitForExistence(timeout: 5))
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        XCTAssertTrue(start.isHittable, "Start is in view without scrolling")
        XCTAssertFalse(start.isEnabled, "no basisvijf yet")
        XCTAssertGreaterThanOrEqual(bar.frame.minX, setupList.frame.maxX - 1, "the bar sits under the plan column")
        for number in ["4", "5", "6", "7", "8"] {
            let basis = app.buttons["setup.basis.\(number)"]
            bringIntoClearView(basis, in: setupList, above: clearBottom(for: basis))
            basis.tap()
        }
        XCTAssertTrue(waitUntil { start.isEnabled }, "Start is on with a basisvijf")
        XCTAssertTrue(start.isHittable, "Start is still in view")
        save("setup-wide-start-bar-top")

        for _ in 0..<12 { planList.swipeUp(velocity: .fast) }
        let grid = app.descendants(matching: .any)["setup.grid"]
        XCTAssertTrue(grid.waitForExistence(timeout: 5))
        XCTAssertTrue(waitUntil { grid.frame.maxY <= bar.frame.minY }, "the last plan row scrolls fully above the bar")
        let lastRow = try XCTUnwrap(planRows().max { $0.frame.maxY < $1.frame.maxY })
        XCTAssertLessThanOrEqual(lastRow.frame.maxY, bar.frame.minY, "\(lastRow.label) sits above the bar")
        XCTAssertTrue(start.isHittable, "Start is in view at the end of the plan")
        save("setup-wide-start-bar-end")
        start.tap()
        XCTAssertTrue(app.buttons["live.wissel"].waitForExistence(timeout: 5), "Start opens the live screen")
    }

    /// Drags the list in small steps until the element sits wholly between the navigation bar and `limit`. `isHittable`
    /// does not see the Start bar or the tab bar floating over a row, so a tap there would land on the bar instead.
    @MainActor private func bringIntoClearView(_ element: XCUIElement, in list: XCUIElement, above limit: CGFloat) {
        XCTAssertTrue(element.waitForExistence(timeout: 5), "\(element) exists")
        let top = app.navigationBars["Match"].frame.maxY
        for _ in 0..<30 {
            let frame = element.frame
            if element.exists, frame.minY >= top, frame.maxY <= limit { return }
            let middle = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let up = !element.exists || frame.maxY > limit
            middle.press(forDuration: 0.05, thenDragTo: middle.withOffset(CGVector(dx: 0, dy: up ? -100 : 100)),
                         withVelocity: .slow, thenHoldForDuration: 0.2)
        }
        save("clear-view-failed")
        XCTFail("could not bring \(element) into clear view: \(element.frame), top \(top), limit \(limit)")
    }

    /// The top of the tab bar where it floats over the element's column, or the window's bottom.
    @MainActor private func clearBottom(for element: XCUIElement) -> CGFloat {
        let tabBar = app.tabBars.firstMatch
        guard tabBar.exists, tabBar.frame.minX < element.frame.maxX, tabBar.frame.maxX > element.frame.minX else {
            return window().frame.maxY
        }
        return tabBar.frame.minY
    }

    @MainActor private func planRows() -> [XCUIElement] {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'setup.row.'")).allElementsBoundByIndex
    }

    // MARK: - The keyboard for Tegenstander (#143)

    /// On the phone layout, Klaar above the keyboard hides it and keeps what was typed, and dragging the setup down
    /// hides it too.
    @MainActor
    func testKlaarAndScrollingHideTheOpponentKeyboardOnThePhone() throws {
        try checkOpponentKeyboard(wide: false)
    }

    /// The same on the wide layout, where Tegenstander sits in the left list.
    @MainActor
    func testKlaarAndScrollingHideTheOpponentKeyboardInTheWideLayout() throws {
        try checkOpponentKeyboard(wide: true)
    }

    @MainActor private func checkOpponentKeyboard(wide: Bool) throws {
        try plantRoster(12)
        if wide { app.launchEnvironment["VERVANGING_WIDE_LAYOUT_MIN"] = "500x0" }
        launchOnSetup()
        if wide {
            try turnToLandscape()
            XCTAssertTrue(waitUntil { self.app.collectionViews.count == 2 }, "the wide setup has its two lists")
        }
        // The list Tegenstander sits in: the only one on the phone, the left one on the wide layout.
        let lists = app.collectionViews.allElementsBoundByIndex.sorted { $0.frame.minX < $1.frame.minX }
        let list = try XCTUnwrap(lists.first)
        let field = app.textFields["setup.opponent"]
        let keyboard = app.keyboards.firstMatch
        let done = app.buttons["setup.keyboardDone"]

        reveal(field, in: list)
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the keyboard is up")
        field.typeText("Ajax")
        XCTAssertTrue(done.waitForExistence(timeout: 5), "Klaar sits above the keyboard")
        // The Start bar steps aside while typing, so it never sits on Klaar's toolbar (#150).
        let start = app.buttons["setup.start"]
        XCTAssertTrue(waitUntil { !start.exists }, "the Start bar leaves while typing")
        save(wide ? "setup-wide-keyboard-typing" : "setup-phone-keyboard-typing")
        XCTAssertTrue(done.isHittable, "Klaar is free to tap")
        done.tap()
        XCTAssertTrue(waitUntil { !keyboard.exists }, "Klaar hides the keyboard")
        XCTAssertTrue(waitUntil { start.exists && start.isHittable }, "the Start bar is back")
        XCTAssertEqual(field.value as? String, "Ajax", "what was typed stays")
        save(wide ? "setup-wide-keyboard-klaar" : "setup-phone-keyboard-klaar")

        reveal(field, in: list)
        field.tap()
        XCTAssertTrue(keyboard.waitForExistence(timeout: 5), "the keyboard is up again")
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
        from.press(forDuration: 0.05, thenDragTo: to)
        XCTAssertTrue(waitUntil { !keyboard.exists }, "dragging the setup down hides the keyboard")
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
        for element in matchElements() {
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
                          // From the table, whose rows always exist; the minutes at a glance are a lazy grid,
                          // whose cells are only there while in view.
                          minutes: numbers.map { "\($0) \((tableRow($0).value as? String) ?? "?")" })
    }

    /// The phone layout: the minutes table below the court, in the same column. (The minutes at a glance are left out
    /// of these checks: they are a lazy grid, whose cells are only there while in view.)
    @MainActor private func isPhoneLive() -> Bool {
        guard let (court, table) = courtAndTable() else { return false }
        return table.minY >= court.maxY && abs(table.minX - court.minX) < 40
    }

    /// The wide layout (either way round): the minutes table in a column beside the court.
    @MainActor private func isWideLive() -> Bool {
        guard let (court, table) = courtAndTable() else { return false }
        return table.minX >= court.maxX - 1
    }

    @MainActor private func courtAndTable() -> (CGRect, CGRect)? {
        let table = app.descendants(matching: .any)["live.minutes.\(numbers[0])"]
        guard table.waitForExistence(timeout: 5), let court = elements("live.court.").first else { return nil }
        return (court.frame, table.frame)
    }

    /// The coming wissel and the court: the time, the change, In the zone, the last action, who is on court and who
    /// came on for a player uit.
    @MainActor private func wisselAndCourt() -> [XCUIElement] {
        ([app.staticTexts["live.subTime"]] + elements("live.off.") + elements("live.on.")
            + [app.descendants(matching: .any)["live.zone.keep"], app.staticTexts["live.message"]]
            + elements("live.court.") + elements("live.replaced.")).filter(\.exists)
    }

    /// The minutes: at a glance, and the table with Uit and Terug.
    @MainActor private func minutesElements() -> [XCUIElement] {
        elements("live.overview.") + elements("live.minutes.") + elements("live.uit.") + elements("live.terug.")
    }

    /// Everything the coach needs during a match (#143).
    @MainActor private func matchElements() -> [XCUIElement] { wisselAndCourt() + minutesElements() }

    @MainActor private func tableRow(_ number: String) -> XCUIElement {
        app.descendants(matching: .any)["live.minutes.\(number)"]
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

    /// Fifteen players with names of about 20 letters (#150, #152).
    private let longNames = ["Anne-Sophie Vermeulen", "Charlotte Vandenberghe", "Marie-Louise Peeters", "Elisabeth Van Damme",
                             "Josephine Verstraeten", "Alexandra De Clercq", "Margaretha Willems", "Christina Janssens",
                             "Gabriella Van Acker", "Wilhelmina Claessens", "Evangeline De Smedt", "Valentina Goossens",
                             "Francesca Van Hoecke", "Annabelle Wouters", "Florentina Maes"]
    private let longNumbers = ["4", "7", "8", "10", "11", "12", "13", "14", "15", "21", "23", "5", "6", "9", "17"]

    @MainActor private func plantLongNameRoster() throws {
        let players = longNames.indices.map { ["id": $0 + 1, "name": longNames[$0], "number": longNumbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": longNames.count + 1, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
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

    /// Whether the element can be tapped where it is: hittable and, unless it is one of the Start bar's own buttons,
    /// clear of that bar (#150). `isHittable` alone counts a row under the bar as reachable, and a tap there lands on
    /// Start.
    @MainActor private func isReachable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        // Only controls get tapped; a tall element such as the plan grid only needs to be on screen.
        guard [.button, .switch, .textField].contains(element.elementType) else { return true }
        if ["setup.start", "setup.anotherPlan"].contains(element.identifier) { return true }
        let bar = app.descendants(matching: .any)["setup.actions"]
        return !bar.exists || !element.frame.intersects(bar.frame)
    }

    /// Scrolls until the element is on screen and hittable: down first, then back up.
    @MainActor private func reveal(_ element: XCUIElement) {
        for i in 0..<12 {
            if i == 0 ? element.waitForExistence(timeout: 2) : element.exists, isReachable(element) { return }
            app.swipeUp(velocity: .slow)
        }
        for _ in 0..<16 {
            if isReachable(element) { return }
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(isReachable(element), "could not scroll to \(element)")
    }

    /// Scrolls one list (the wide setup has two) until the element is on screen and hittable.
    @MainActor private func reveal(_ element: XCUIElement, in list: XCUIElement) {
        for i in 0..<12 {
            if i == 0 ? element.waitForExistence(timeout: 2) : element.exists, isReachable(element) { return }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(isReachable(element), "could not scroll to \(element)")
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
