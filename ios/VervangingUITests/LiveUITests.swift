import XCTest

/// The live screen (#102): Wissel through a whole match, the minutes at a glance and in the table, undo, a double tap
/// that counts once, the match restored after a force-quit, long names above the Wissel bar, the screen kept awake
/// only while the match runs, and the question before a new Start replaces a running match.
///
/// Every test gives the app its own storage folder through `VERVANGING_STORAGE_DIR` and a fixed first seed through
/// `VERVANGING_SEED` (both read by debug builds only). The checks wait for elements instead of reading them at once.
final class LiveUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!
    /// When the last Wissel tap was sent: taps are kept more than 600 ms apart, so none is taken as a double tap.
    private var lastWissel = Date.distantPast

    private let names = ["Lotte", "Fien", "Mila", "Noor", "Lien", "Anna", "Elise", "Hanne", "Jade", "Lore", "Marie", "Zoë",
                         "Roos", "Kato", "Nina"]
    private let numbers = ["4", "7", "8", "10", "11", "12", "13", "14", "15", "21", "23", "5", "6", "9", "17"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
        app.launchEnvironment["VERVANGING_SEED"] = "7"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    // MARK: - A whole match

    @MainActor
    func testElevenWisselsInAnEqualMatchWithTwelvePlayersEndWithEveryoneAtSixteenForty() throws {
        try plantRoster(12)
        try startMatch(basisvijf: ["4", "7", "8", "10", "11"])
        XCTAssertTrue(waitFor(awakeProbe(), value: "on"), "the screen stays on during the match")
        XCTAssertEqual(subTime(), "Wissel op 6:40")
        for number in numbers.prefix(12) {
            XCTAssertEqual(minutes(overviewCell(number)), "0:00", "only finished blocks count at tip-off (#54)")
        }

        for block in 2...12 { tapWissel(expecting: "Blok \(block) van 12") }
        XCTAssertEqual(subTime(), "Laatste blok")
        XCTAssertEqual(wisselButton().label, "Einde match")
        XCTAssertTrue(waitFor(awakeProbe(), value: "on"))

        tapWissel(expecting: "Einde match")
        XCTAssertTrue(app.staticTexts["Minuten per speler"].waitForExistence(timeout: 5))
        for number in numbers.prefix(12) {
            let row = tableRow(number)
            reveal(row)
            XCTAssertEqual(minutes(row), "16:40", "#\(number)")
        }
        XCTAssertTrue(waitFor(awakeProbe(), value: "off"), "the screen may dim and lock again after the end")

        // Undo of the end goes back to the last block and keeps the screen on again.
        tapReveal(app.buttons["live.undo"])
        XCTAssertTrue(app.staticTexts["Blok 12 van 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(awakeProbe(), value: "on"))
        tapWissel(expecting: "Einde match")

        tapReveal(app.buttons["live.newMatch"])
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(awakeProbe(), value: "off"))
        XCTAssertFalse(app.buttons["setup.backToMatch"].waitForExistence(timeout: 1), "the match has ended")
    }

    // MARK: - Force-quit

    @MainActor
    func testForceQuittingMidMatchAndReopeningShowsTheSameBlockPlayersAndMinutes() throws {
        try plantRoster(10)
        try startMatch(basisvijf: ["4", "7", "8", "10", "11"])
        for block in 2...4 { tapWissel(expecting: "Blok \(block) van 12") }
        let court = labels("live.court.")
        let off = labels("live.off.")
        let on = labels("live.on.")
        let overview = numbers.prefix(10).map { minutes(overviewCell($0)) }
        XCTAssertEqual(court.count, 5)
        XCTAssertEqual(overview.compactMap { $0 }.count, 10)

        let file = try JSONSerialization.jsonObject(with: Data(contentsOf: storageDir.appendingPathComponent("match.json")))
        XCTAssertEqual((file as? [String: Any])?["version"] as? Int, 1)

        app.terminate()
        app.launch()
        XCTAssertTrue(app.staticTexts["Blok 4 van 12"].waitForExistence(timeout: 10), "the app opens on the match")
        XCTAssertTrue(wisselButton().waitForExistence(timeout: 5))
        XCTAssertEqual(labels("live.court."), court)
        XCTAssertEqual(labels("live.off."), off)
        XCTAssertEqual(labels("live.on."), on)
        XCTAssertEqual(numbers.prefix(10).map { minutes(overviewCell($0)) }, overview)
        XCTAssertTrue(waitFor(awakeProbe(), value: "on"))
    }

    // MARK: - Double tap and undo

    @MainActor
    func testADoubleTapOnWisselCountsOnceAndUndoTakesBackExactlyTheLastAction() throws {
        try plantRoster(12)
        try startMatch(basisvijf: ["4", "7", "8", "10", "11"])
        XCTAssertFalse(app.buttons["live.undo"].isEnabled, "nothing to undo yet")

        wisselButton().doubleTap()
        lastWissel = Date()
        XCTAssertTrue(app.staticTexts["Blok 2 van 12"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["Blok 3 van 12"].waitForExistence(timeout: 2), "the second tap is ignored (#49)")
        XCTAssertTrue(message()?.hasPrefix("Wissel gedaan: blok 2. Erin: ") == true, message() ?? "no message")
        let courtInTwo = labels("live.court.")

        tapWissel(expecting: "Blok 3 van 12")
        app.buttons["live.undo"].tap()
        XCTAssertTrue(app.staticTexts["Blok 2 van 12"].waitForExistence(timeout: 5), "back one block, not two")
        XCTAssertEqual(message(), "Ongedaan gemaakt.")
        XCTAssertEqual(labels("live.court."), courtInTwo)
        XCTAssertTrue(waitFor(app.buttons["live.undo"], enabled: false), "one step only")
        XCTAssertFalse(app.staticTexts["Blok 1 van 12"].exists)
    }

    // MARK: - Long names (#77)

    @MainActor
    func testThreeLineNamesOnAThreePlayerChangeStayAboveTheWisselBarAfterAWissel() throws {
        // Three-word names of 20 characters (the longest the roster takes). At the default text size they take at most
        // two lines in the half-width Eruit and Erin columns, so the app runs one text size up (XL): there they wrap
        // to three ("Wassim / Mohammed / AmAa") and stay on one line in the full-width Op het veld list.
        let long = (0..<15).map { "Wassim Mohammed Am\(String(UnicodeScalar(UInt8(65 + $0))))\(String(UnicodeScalar(UInt8(97 + $0))))" }
        try plantRoster(15, names: long)
        app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryXL"]
        try startMatch(basisvijf: ["4", "7", "8", "10", "11"])
        // Wissel at least once, until three players go off at the next change: the confirmation line is then on screen.
        var block = 1
        repeat {
            block += 1
            XCTAssertLessThan(block, 12, "no change of three players in this plan")
            tapWissel(expecting: "Blok \(block) van 12")
        } while labels("live.off.").count < 3
        XCTAssertTrue(message()?.hasPrefix("Wissel gedaan: blok \(block).") == true, message() ?? "no message")

        let bar = app.descendants(matching: .any)["live.actions"]
        XCTAssertTrue(bar.waitForExistence(timeout: 5))
        let barTop = bar.frame.minY
        // A one-line row: the same names fit on one line in the full-width Op het veld list.
        let oneLine = try XCTUnwrap(elements("live.court.").map { $0.frame.height }.max())
        let whole = Set((0..<15).map { "#\(numbers[$0]) \(long[$0])" })
        let rows = elements("live.off.") + elements("live.on.")
        XCTAssertEqual(elements("live.off.").count, 3)
        XCTAssertGreaterThanOrEqual(rows.count, 4)
        for row in rows {
            let frame = row.frame
            XCTAssertTrue(row.isHittable, row.label)
            XCTAssertGreaterThanOrEqual(frame.height, 2.4 * oneLine,
                                        "\(row.label) wraps to three lines (\(frame.height) pt; one line is \(oneLine) pt)")
            XCTAssertLessThanOrEqual(frame.maxY, barTop, "\(row.label): the whole row sits above the Wissel bar")
            XCTAssertTrue(whole.contains(row.label), "\(row.label) is the whole name")
        }
    }

    // MARK: - A running match and a new Start

    @MainActor
    func testSetupLeadsBackToARunningMatchAndAsksBeforeANewStartReplacesIt() throws {
        try plantRoster(8)
        try startMatch(basisvijf: ["4", "7", "8", "10", "11"])
        tapWissel(expecting: "Blok 2 van 12")

        goBackToSetup()
        XCTAssertTrue(waitFor(awakeProbe(), value: "off"), "the screen may dim on setup")
        tapReveal(app.buttons["setup.backToMatch"])
        XCTAssertTrue(app.staticTexts["Blok 2 van 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(waitFor(awakeProbe(), value: "on"))

        goBackToSetup()
        tapReveal(app.buttons["setup.start"])
        let alert = app.alerts["De lopende match stoppen en een nieuwe beginnen?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Annuleren"].tap()
        tapReveal(app.buttons["setup.backToMatch"])
        XCTAssertTrue(app.staticTexts["Blok 2 van 12"].waitForExistence(timeout: 5), "Annuleren keeps the match")

        goBackToSetup()
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Nieuwe match"].tap()
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5), "a new match at block 1")
        XCTAssertFalse(app.buttons["live.undo"].isEnabled)
    }

    // MARK: - Helpers

    private func plantRoster(_ count: Int, names: [String]? = nil) throws {
        let names = names ?? self.names
        let players = (0..<count).map { ["id": $0 + 1, "name": names[$0], "number": numbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": count + 1, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
    }

    /// Opens setup, picks the basisvijf and taps Start: the live screen opens at block 1.
    private func startMatch(basisvijf: [String]) throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        let tab = app.buttons["Match"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        for number in basisvijf { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(wisselButton().waitForExistence(timeout: 5))
    }

    private func goBackToSetup() {
        let back = app.navigationBars.buttons["Match"].firstMatch
        XCTAssertTrue(back.waitForExistence(timeout: 5))
        back.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
    }

    private func wisselButton() -> XCUIElement { app.buttons["live.wissel"] }

    /// Taps Wissel (or Einde match) more than 600 ms after the last tap, and waits for the next block's title.
    private func tapWissel(expecting title: String) {
        let wait = 0.7 - Date().timeIntervalSince(lastWissel)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let button = wisselButton()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        lastWissel = Date()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
    }

    private func subTime() -> String? {
        let text = app.staticTexts["live.subTime"]
        return text.waitForExistence(timeout: 5) ? text.label : nil
    }

    private func message() -> String? {
        let text = app.staticTexts["live.message"]
        return text.waitForExistence(timeout: 5) ? text.label : nil
    }

    private func overviewCell(_ number: String) -> XCUIElement {
        app.descendants(matching: .any)["live.overview.\(number)"]
    }

    private func tableRow(_ number: String) -> XCUIElement {
        app.descendants(matching: .any)["live.minutes.\(number)"]
    }

    /// A cell's or row's value is "3:20" or "3:20, op het veld".
    private func minutes(_ element: XCUIElement) -> String? {
        guard element.waitForExistence(timeout: 5), let value = element.value as? String else { return nil }
        return value.split(separator: ",").first.map(String.init)
    }

    private func elements(_ prefix: String) -> [XCUIElement] {
        app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex
    }

    private func labels(_ prefix: String) -> [String] {
        XCTAssertTrue(app.staticTexts["live.subTime"].waitForExistence(timeout: 5))
        return elements(prefix).map { $0.label }
    }

    private func awakeProbe() -> XCUIElement { app.descendants(matching: .any)["debug.screenAwake"] }

    /// The Wissel bar's own controls, which lie inside the bar by design.
    private let barControls: Set<String> = ["live.undo", "live.wissel", "live.newMatch"]

    /// Whether the element can be tapped where it is: on screen and, on the live screen, wholly above the Wissel bar (a
    /// tap on a row under the bar would land on Wissel; `isHittable` alone counts such a row as reachable). Only the
    /// bar's own controls, found by identifier, are accepted inside the bar; they only need to be hittable.
    private func isReachable(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let bar = app.descendants(matching: .any)["live.actions"]
        guard bar.exists else { return true }
        if barControls.contains(element.identifier) { return true }
        return element.frame.maxY <= bar.frame.minY + 1
    }

    /// Scrolls until the element is reachable: down first, then back up.
    private func reveal(_ element: XCUIElement) {
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

    private func tapReveal(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func waitFor(_ element: XCUIElement, value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitFor(_ element: XCUIElement, enabled: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
