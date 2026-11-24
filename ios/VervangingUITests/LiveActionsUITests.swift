import XCTest

/// The live actions (#103): In the zone (with the proposed sitter, which the coach can change) keeps a player on and
/// gives the block back later, Extra minuten keeps it without give-back, Uit on court brings a replacement on at once
/// and on the bench takes the player out of later blocks, Terug brings them back from the next block, a refusal says
/// why, and each of these is undone by one tap. The line under the last action comes into view after a Wissel, an undo
/// or a failed save, also when the coach had scrolled down the minutes table (PR #130 review).
///
/// Every test gives the app its own storage folder through `VERVANGING_STORAGE_DIR` and a fixed first seed through
/// `VERVANGING_SEED` (both read by debug builds only). The checks wait for elements instead of reading them at once.
final class LiveActionsUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!
    /// When the last Wissel tap was sent: taps are kept more than 600 ms apart, so none is taken as a double tap.
    private var lastWissel = Date.distantPast

    private let names = ["Lotte", "Fien", "Mila", "Noor", "Lien", "Anna", "Elise", "Hanne", "Jade", "Lore", "Marie", "Zoë"]
    private let numbers = ["4", "7", "8", "10", "11", "12", "13", "14", "15", "21", "23", "5"]
    private let basisvijf = ["4", "7", "8", "10", "11"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("live-actions-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
        app.launchEnvironment["VERVANGING_SEED"] = "7"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    // MARK: - In the zone and Extra minuten

    @MainActor
    func testInTheZoneKeepsThePlayerOnWithTheChosenSitterAndGivesTheBlockBackLater() throws {
        try plantRoster(12)
        try startMatch()
        let off = labels("live.off.")
        let on = labels("live.on.")
        let keep = try XCTUnwrap(off.first)

        chooseZone(keep)
        let proposed = try XCTUnwrap(sitter(), "the note names the proposed sitter")
        XCTAssertTrue(on.contains(proposed), "the proposal is a player due on: \(proposed)")
        XCTAssertEqual(zoneNote(), "\(keep) blijft in the zone op het veld, \(proposed) blijft op de bank.")

        // The coach picks another sitter.
        let other = try XCTUnwrap(on.first { $0 != proposed })
        chooseBench(other)
        XCTAssertEqual(zoneNote(), "\(keep) blijft in the zone op het veld, \(other) blijft op de bank.")

        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertTrue(message()?.hasPrefix("Wissel gedaan: blok 2.") == true, message() ?? "no message")
        XCTAssertTrue(labels("live.court.").contains(keep), "\(keep) stays on")
        XCTAssertFalse(labels("live.court.").contains(other), "\(other) stays on the bench")
        XCTAssertTrue(labels("live.court.").contains(proposed), "the proposed sitter came on after all")
        XCTAssertFalse(zoneControl("live.zone.note").exists, "the choice was applied and cleared")

        // The zone block shows in the minutes once played, and is given back later: everyone ends at 16:40.
        tapWissel(expecting: "Blok 3 van 12")
        XCTAssertEqual(minutes(overviewCell(number(keep))), "6:40", "two blocks played")
        XCTAssertEqual(minutes(overviewCell(number(other))), "0:00", "the sitter's block went to \(keep)")
        playToTheEnd(from: 3)
        for number in numbers {
            let row = tableRow(number)
            reveal(row)
            XCTAssertEqual(minutes(row), "16:40", "#\(number): the block was given back")
        }
    }

    @MainActor
    func testExtraMinutenKeepsTheBlockWithoutGivingItBack() throws {
        try plantRoster(12)
        try startMatch()
        let keep = try XCTUnwrap(labels("live.off.").first)
        chooseZone(keep)
        let bench = try XCTUnwrap(sitter())
        setExtra(true)
        XCTAssertEqual(zoneNote(), "\(keep) speelt een extra blok (extra minuten, niet teruggegeven), \(bench) blijft op de bank.")
        setExtra(false)
        XCTAssertEqual(zoneNote(), "\(keep) blijft in the zone op het veld, \(bench) blijft op de bank.",
                       "switching back keeps the sitter")
        setExtra(true)

        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertTrue(labels("live.court.").contains(keep))
        XCTAssertFalse(labels("live.court.").contains(bench))
        playToTheEnd(from: 2)
        let row = tableRow(number(keep))
        reveal(row)
        XCTAssertEqual(minutes(row), "20:00", "planned 16:40 plus the extra block, not given back")
    }

    // MARK: - Uit and terug

    @MainActor
    func testUitOnCourtBringsOnAPlayerDueOnAndTerugBringsThemBackFromTheNextBlock() throws {
        try plantRoster(12)
        try startMatch()
        let dueOn = labels("live.on.")
        let player = try XCTUnwrap(labels("live.court.").first)

        tapReveal(app.buttons["live.uit.\(number(player))"])
        let line = try XCTUnwrap(message())
        let replacement = try XCTUnwrap(dueOn.first { line == "\(player) uit, \($0) erin." },
                                        "\(line): a player due on at the next wissel comes on")
        XCTAssertTrue(waitForVisible(app.staticTexts["live.message"]), "the line comes into view after Uit")
        XCTAssertTrue(labels("live.court.").contains(replacement))
        XCTAssertFalse(labels("live.court.").contains(player))
        let note = app.staticTexts["live.replaced.\(number(player))"]
        XCTAssertTrue(note.waitForExistence(timeout: 5))
        XCTAssertEqual(note.label, "\(replacement) kwam erin voor \(player) (uit). Het blok telt voor \(player).")
        XCTAssertEqual(rowValue(number(player)), "0:00, uit")
        XCTAssertTrue(waitFor(overviewCell(number(player)), value: "0:00, uit"))

        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertEqual(minutes(overviewCell(number(player))), "3:20", "the block counts for the starter")
        tapReveal(app.buttons["live.terug.\(number(player))"])
        XCTAssertEqual(message(), "\(player) terug vanaf het volgende blok.")
        XCTAssertEqual(rowValue(number(player)), "3:20", "no longer uit")
        XCTAssertFalse(labels("live.court.").contains(player), "not back in the current block")

        var block = 2
        while !labels("live.court.").contains(player) {
            block += 1
            XCTAssertLessThanOrEqual(block, 12, "\(player) never came back on")
            tapWissel(expecting: "Blok \(block) van 12")
        }
    }

    @MainActor
    func testUitOnTheBenchTakesThePlayerOutOfLaterBlocksAndBelowFiveSaysWhy() throws {
        try plantRoster(6)
        try startMatch()
        let court = labels("live.court.")
        let benched = try XCTUnwrap(names.prefix(6).indices.map { "#\(numbers[$0]) \(names[$0])" }
            .first { !court.contains($0) })

        tapReveal(app.buttons["live.uit.\(number(benched))"])
        XCTAssertEqual(message(), "\(benched) uit.")
        XCTAssertEqual(labels("live.court."), court, "nobody changes on court")

        tapReveal(app.buttons["live.uit.\(number(try XCTUnwrap(court.first)))"])
        XCTAssertEqual(message(), "Dat kan nu niet: er moeten minstens 5 spelers overblijven.")
        XCTAssertTrue(waitForVisible(app.staticTexts["live.message"]), "the reason comes into view")
        XCTAssertEqual(labels("live.court."), court, "refused: nothing changed")

        playToTheEnd(from: 1)
        let row = tableRow(number(benched))
        reveal(row)
        XCTAssertEqual(minutes(row), "0:00", "\(benched) played no later block")
    }

    // MARK: - Undo

    @MainActor
    func testEachActionIsUndoneByOneTap() throws {
        try plantRoster(12)
        try startMatch()
        tapWissel(expecting: "Blok 2 van 12")
        let court = labels("live.court.")
        let off = labels("live.off.")
        let on = labels("live.on.")

        // In the zone.
        chooseZone(try XCTUnwrap(off.first))
        tapWissel(expecting: "Blok 3 van 12")
        undo(expecting: "Blok 2 van 12")
        XCTAssertEqual(labels("live.court."), court)
        XCTAssertEqual(labels("live.off."), off, "the plan is as before")
        XCTAssertEqual(labels("live.on."), on)

        // Extra minuten.
        chooseZone(try XCTUnwrap(off.first))
        setExtra(true)
        tapWissel(expecting: "Blok 3 van 12")
        undo(expecting: "Blok 2 van 12")
        XCTAssertEqual(labels("live.off."), off)
        XCTAssertEqual(labels("live.on."), on)

        // Uit on court.
        let player = try XCTUnwrap(court.first)
        let played = try XCTUnwrap(minutes(tableRow(number(player))))
        tapReveal(app.buttons["live.uit.\(number(player))"])
        XCTAssertFalse(labels("live.court.").contains(player))
        undo(expecting: "Blok 2 van 12")
        XCTAssertEqual(labels("live.court."), court, "\(player) is back on")
        XCTAssertEqual(rowValue(number(player)), "\(played), op het veld")
        XCTAssertFalse(app.staticTexts["live.replaced.\(number(player))"].exists)

        // Terug.
        tapReveal(app.buttons["live.uit.\(number(player))"])
        tapReveal(app.buttons["live.terug.\(number(player))"])
        XCTAssertEqual(message(), "\(player) terug vanaf het volgende blok.")
        undo(expecting: "Blok 2 van 12")
        XCTAssertEqual(rowValue(number(player)), "\(played), uit", "undo of Terug leaves the player uit")
        XCTAssertTrue(app.buttons["live.terug.\(number(player))"].exists)
    }

    // MARK: - The line comes into view (PR #130 review)

    @MainActor
    func testTheLineUnderTheChangeComesIntoViewAfterAWisselAnUndoOrAFailedSave() throws {
        try plantRoster(12)
        try startMatch()

        scrollToTheBottom()
        let line = app.staticTexts["live.message"]
        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertTrue(message()?.hasPrefix("Wissel gedaan: blok 2.") == true)
        XCTAssertTrue(waitForVisible(line), "after Wissel")

        scrollToTheBottom()
        XCTAssertFalse(isVisible(line), "scrolled away from the line")
        app.buttons["live.undo"].tap()
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        XCTAssertEqual(message(), "Ongedaan gemaakt.")
        XCTAssertTrue(waitForVisible(line), "after Ongedaan maken")

        // A folder where the match file should be: the next write fails.
        let file = storageDir.appendingPathComponent("match.json")
        try FileManager.default.removeItem(at: file)
        try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
        scrollToTheBottom()
        XCTAssertFalse(isVisible(line))
        tapWissel(expecting: "Blok 2 van 12")
        XCTAssertEqual(message(), "Opslaan lukte niet: de telefoon weigert opslag.")
        XCTAssertTrue(waitForVisible(line), "after a failed save")
    }

    // MARK: - Helpers

    private func plantRoster(_ count: Int) throws {
        let players = (0..<count).map { ["id": $0 + 1, "name": names[$0], "number": numbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": count + 1, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
    }

    /// Opens setup, picks the basisvijf and taps Start: the live screen opens at block 1.
    private func startMatch() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        let tab = app.buttons["Match"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        for number in basisvijf { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live.wissel"].waitForExistence(timeout: 5))
    }

    /// "#10 Noor" → "10".
    private func number(_ label: String) -> String {
        String(label.dropFirst().prefix { $0 != " " })
    }

    private func zoneControl(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id] }

    /// Picks an option in one of the zone's menus.
    private func pick(_ option: String, in id: String) {
        let menu = app.buttons[id]
        tapReveal(menu)
        let item = app.buttons.matching(NSPredicate(format: "label == %@ AND identifier != %@", option, id)).firstMatch
        XCTAssertTrue(item.waitForExistence(timeout: 5), "\(option) in the menu")
        item.tap()
    }

    private func chooseZone(_ player: String) {
        pick(player, in: "live.zone.keep")
        XCTAssertTrue(zoneControl("live.zone.note").waitForExistence(timeout: 5), "In the zone chosen")
    }

    private func chooseBench(_ player: String) {
        pick(player, in: "live.zone.bench")
        XCTAssertTrue(waitFor(zoneControl("live.zone.note"), labelContaining: "\(player) blijft op de bank"))
    }

    private func setExtra(_ on: Bool) {
        let toggle = app.switches["live.zone.extra"]
        reveal(toggle)
        if (toggle.value as? String == "1") != on { toggle.switches.firstMatch.tap() }
        XCTAssertTrue(waitFor(toggle, value: on ? "1" : "0"))
    }

    private func zoneNote() -> String? {
        let note = zoneControl("live.zone.note")
        return note.waitForExistence(timeout: 5) ? note.label : nil
    }

    /// The player the note says stays on the bench.
    private func sitter() -> String? {
        guard let note = zoneNote(), let comma = note.range(of: ", ", options: .backwards),
              let end = note.range(of: " blijft op de bank.") else { return nil }
        return String(note[comma.upperBound..<end.lowerBound])
    }

    /// Taps Wissel (or Einde match) more than 600 ms after the last tap, and waits for the next block's title.
    private func tapWissel(expecting title: String) {
        let wait = 0.7 - Date().timeIntervalSince(lastWissel)
        if wait > 0 { Thread.sleep(forTimeInterval: wait) }
        let button = app.buttons["live.wissel"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        button.tap()
        lastWissel = Date()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
    }

    /// Wissel from `block` up to and including Einde match.
    private func playToTheEnd(from block: Int) {
        if block < 12 { for next in (block + 1)...12 { tapWissel(expecting: "Blok \(next) van 12") } }
        tapWissel(expecting: "Einde match")
        XCTAssertTrue(app.staticTexts["Minuten per speler"].waitForExistence(timeout: 5))
    }

    private func undo(expecting title: String) {
        let button = app.buttons["live.undo"]
        XCTAssertTrue(waitFor(button, enabled: true))
        button.tap()
        XCTAssertTrue(app.staticTexts[title].waitForExistence(timeout: 5), title)
        XCTAssertEqual(message(), "Ongedaan gemaakt.")
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

    /// A row's whole value: "3:20", "3:20, op het veld" or "3:20, uit".
    private func rowValue(_ number: String) -> String? {
        let row = tableRow(number)
        guard row.waitForExistence(timeout: 5) else { return nil }
        return row.value as? String
    }

    /// A cell's or row's minutes: "3:20" from "3:20, op het veld".
    private func minutes(_ element: XCUIElement) -> String? {
        guard element.waitForExistence(timeout: 5), let value = element.value as? String else { return nil }
        return value.split(separator: ",").first.map(String.init)
    }

    private func labels(_ prefix: String) -> [String] {
        XCTAssertTrue(app.staticTexts["live.subTime"].waitForExistence(timeout: 5))
        return app.descendants(matching: .any).matching(NSPredicate(format: "identifier BEGINSWITH %@", prefix))
            .allElementsBoundByIndex.map { $0.label }
    }

    /// Whether the element sits wholly between the navigation bar and the Wissel bar.
    private func isVisible(_ element: XCUIElement) -> Bool {
        guard element.exists, element.isHittable else { return false }
        let bar = app.descendants(matching: .any)["live.actions"]
        let frame = element.frame
        let top = app.navigationBars.firstMatch.frame.maxY
        return frame.minY >= top - 1 && frame.maxY <= bar.frame.minY + 1
    }

    private func waitForVisible(_ element: XCUIElement) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        repeat {
            if isVisible(element) { return true }
            Thread.sleep(forTimeInterval: 0.2)
        } while Date() < deadline
        return false
    }

    private func scrollToTheBottom() {
        let last = tableRow(numbers[numbers.count - 1])
        for _ in 0..<12 where !(last.exists && last.isHittable) { app.swipeUp(velocity: .fast) }
        app.swipeUp(velocity: .fast)
        XCTAssertTrue(last.exists && last.isHittable, "the end of the minutes table is on screen")
    }

    /// Scrolls until the element is on screen, and on the live screen clear of the navigation bar and the Wissel bar (a
    /// tap on a row under the bar would land on Wissel): down first, then back up.
    private func reveal(_ element: XCUIElement) {
        func shown() -> Bool {
            guard element.exists, element.isHittable else { return false }
            // The Start bar on setup floats over rows too (#150): a tap there would land on Start. Only its own buttons
            // lie inside it.
            let startBar = app.descendants(matching: .any)["setup.actions"]
            if startBar.exists, !["setup.start", "setup.anotherPlan"].contains(element.identifier),
               element.frame.intersects(startBar.frame) { return false }
            return !app.descendants(matching: .any)["live.actions"].exists || isVisible(element)
        }
        _ = element.waitForExistence(timeout: 2)
        for _ in 0..<12 {
            if shown() { return }
            app.swipeUp(velocity: .slow)
        }
        for _ in 0..<16 {
            if shown() { return }
            app.swipeDown(velocity: .slow)
        }
        XCTAssertTrue(shown(), "could not scroll to \(element)")
    }

    private func tapReveal(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func waitFor(_ element: XCUIElement, value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "label CONTAINS %@", text),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func waitFor(_ element: XCUIElement, enabled: Bool) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "enabled == %@", NSNumber(value: enabled)),
                                                    object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }
}
