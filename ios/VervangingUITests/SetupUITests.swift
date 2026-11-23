import XCTest

/// The match setup screen (#101): attendance and basisvijf, the schema, the history switch, the plan grid with swaps,
/// the web app's refusals before Start, and the last match's attendance and basisvijf pre-ticked on the next setup.
///
/// Every test gives the app its own storage folder through `VERVANGING_STORAGE_DIR` and a fixed first seed through
/// `VERVANGING_SEED` (both read by debug builds only), so the roster is known and the plan is the same every run. The
/// checks do not depend on the seed's plan beyond what the planner guarantees.
final class SetupUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!

    private var setupFile: URL { storageDir.appendingPathComponent("setup.json") }

    /// Numbers in roster order; the screen lists them by number.
    private let names = ["Lotte", "Fien", "Mila", "Noor", "Lien", "Anna", "Elise", "Hanne", "Jade", "Lore", "Marie", "Zoë",
                         "Roos", "Kato", "Nina"]
    private let numbers = ["4", "7", "8", "10", "11", "12", "13", "14", "15", "21", "23", "5", "6", "9", "17"]

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("setup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
        app.launchEnvironment["VERVANGING_SEED"] = "7"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    // MARK: - 12 players, gelijke minuten: a 12 × 12 grid, 5 blocks each

    @MainActor
    func testTwelvePlayersEqualMinutesGiveATwelveByTwelveGridWithFiveBlocksEach() throws {
        try plantRoster(12)
        openSetup()
        XCTAssertTrue(counts().waitForExistence(timeout: 5))
        XCTAssertEqual(countsText(), "Aanwezig: 12 · Basisvijf: 0 van 5", "everyone is ticked before the first match")
        XCTAssertEqual(note(), "Kies precies 5 spelers voor de basisvijf om het plan te zien.")

        pickBasisvijf(["4", "7", "8", "10", "11"])
        let equal = app.buttons["Gelijke minuten"]
        reveal(equal)
        XCTAssertTrue(equal.isSelected, "gelijke minuten is the default schema")
        XCTAssertEqual(countsText(), "Aanwezig: 12 · Basisvijf: 5 van 5")

        reveal(app.descendants(matching: .any)["setup.grid"])
        for b in 1...12 {
            XCTAssertTrue(app.staticTexts["setup.block.\(b)"].waitForExistence(timeout: 5), "block column \(b)")
        }
        XCTAssertFalse(app.staticTexts["setup.block.13"].exists)
        let rows = gridRows()
        XCTAssertEqual(rows.count, 12)
        for row in rows {
            XCTAssertTrue(blocks(row).count == 5, "\(row.label): \(row.value as? String ?? "")")
            XCTAssertEqual(minutes(row), "16:40", row.label)
        }
        // The basisvijf rows come first.
        XCTAssertEqual(rows.prefix(5).map(\.label), ["#4 Lotte", "#7 Fien", "#8 Mila", "#10 Noor", "#11 Lien"])
        for row in rows.prefix(5) { XCTAssertEqual(blocks(row).first, 1, "\(row.label) starts") }
        reveal(app.buttons["setup.start"])
        XCTAssertTrue(app.buttons["setup.start"].isEnabled)
    }

    @MainActor
    func testFiveMinuteBlocksGiveEightColumns() throws {
        try plantRoster(10)
        openSetup()
        pickBasisvijf(["4", "7", "8", "10", "11"])
        tapReveal(app.buttons["Blokken van 5 minuten"])
        reveal(app.descendants(matching: .any)["setup.grid"])
        XCTAssertTrue(app.staticTexts["setup.block.8"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["setup.block.9"].exists)
        for row in gridRows() {
            XCTAssertEqual(blocks(row).count, 4, row.label)
            XCTAssertEqual(minutes(row), "20:00", row.label)
        }
    }

    // MARK: - Swaps

    @MainActor
    func testSwappingTwoPlayersUpdatesTheGridAndTheMinutes() throws {
        // 9 players in blocks of 5 minutes: 40 places, so 4 players get 5 blocks (25:00) and 5 get 4 (20:00).
        try plantRoster(9)
        openSetup()
        pickBasisvijf(["4", "7", "8", "10", "11"])
        tapReveal(app.buttons["Blokken van 5 minuten"])
        reveal(app.descendants(matching: .any)["setup.grid"])
        XCTAssertTrue(app.staticTexts["setup.block.8"].waitForExistence(timeout: 5))

        let bench = gridRows().dropFirst(5)
        var pair: (XCUIElement, XCUIElement)?
        for a in bench { for b in bench where minutes(a) != minutes(b) && pair == nil { pair = (a, b) } }
        let (a, b) = try XCTUnwrap(pair, "two bench players with different minutes")
        let aLabel = a.label, bLabel = b.label
        let aBefore = a.value as? String, bBefore = b.value as? String

        a.tap()
        XCTAssertEqual(message(), "\(aLabel) gekozen. Tik de speler aan om mee te ruilen.")
        XCTAssertTrue(a.isSelected)
        b.tap()
        XCTAssertEqual(message(), "\(name(aLabel)) en \(name(bLabel)) geruild.")
        let aAfter = row(aLabel), bAfter = row(bLabel)
        XCTAssertEqual(aAfter.value as? String, bBefore, "the rows are swapped, blocks and minutes")
        XCTAssertEqual(bAfter.value as? String, aBefore)
        XCTAssertNotEqual(minutes(aAfter), aBefore.flatMap(minutes(of:)), "the minutes changed")

        // A starter and a bench player cannot swap, with the web app's message.
        let starter = gridRows()[0]
        let starterLabel = starter.label
        let starterBefore = starter.value as? String
        starter.tap()
        row(aLabel).tap()
        XCTAssertEqual(message(), "Wissel \(starterLabel) en \(aLabel) kan niet: de ene staat in de basisvijf en de andere niet.")
        XCTAssertEqual(row(starterLabel).value as? String, starterBefore)
    }

    // MARK: - Start refused

    @MainActor
    func testStartIsRefusedWithTooFewPresentOrAnIncompleteBasisvijf() throws {
        try plantRoster(6)
        openSetup()

        // Basisvijf incomplete.
        pickBasisvijf(["4", "7", "8", "10"])
        XCTAssertEqual(note(), "Kies precies 5 spelers voor de basisvijf om het plan te zien.")
        reveal(app.buttons["setup.start"])
        XCTAssertFalse(app.buttons["setup.start"].isEnabled)
        XCTAssertFalse(app.descendants(matching: .any)["setup.grid"].exists)

        // Fewer than 5 present.
        tapReveal(present("11"))
        tapReveal(present("12"))
        XCTAssertEqual(note(), "Vink minstens 5 aanwezige spelers aan.")
        XCTAssertEqual(countsText(), "Aanwezig: 4 · Basisvijf: 4 van 5")
        reveal(app.buttons["setup.start"])
        XCTAssertFalse(app.buttons["setup.start"].isEnabled)
        XCTAssertFalse(basis("11").isEnabled, "an absent player cannot be in the basisvijf")
        XCTAssertFalse(FileManager.default.fileExists(atPath: setupFile.path), "nothing is saved without a start")
    }

    @MainActor
    func testFewerThanFivePlayersOnTheRosterLeadsToSpelers() throws {
        try plantRoster(4)
        openSetup()
        let tooFew = app.staticTexts["setup.tooFew"]
        XCTAssertTrue(tooFew.waitForExistence(timeout: 5))
        XCTAssertEqual(tooFew.label, "Voeg eerst minstens 5 spelers toe bij Spelers.")
        app.buttons["setup.toSpelers"].tap()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 5))
    }

    // MARK: - The last match's attendance and basisvijf (#56)

    @MainActor
    func testLastAttendanceAndBasisvijfArePreTickedOnTheNextSetup() throws {
        try plantRoster(8)
        openSetup()
        tapReveal(present("13"))   // Elise is absent
        pickBasisvijf(["4", "7", "11", "12", "14"])
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.buttons["live.wissel"].waitForExistence(timeout: 5), "Start opens the live screen (#102)")

        let stored = try storedSetup()
        XCTAssertEqual(stored["version"] as? Int, 1)
        XCTAssertEqual(stored["attendance"] as? [Int], [1, 2, 3, 4, 5, 6, 8])
        XCTAssertEqual(stored["startingFive"] as? [Int], [1, 2, 5, 6, 8])

        // Force-quit and open setup again.
        app.terminate()
        app.launch()
        openSetupTab()
        XCTAssertTrue(counts().waitForExistence(timeout: 5))
        XCTAssertEqual(countsText(), "Aanwezig: 7 · Basisvijf: 5 van 5")
        XCTAssertFalse(present("13").isSelected, "Elise stays unticked")
        for number in ["4", "7", "8", "10", "11", "12", "14"] {
            XCTAssertTrue(present(number).isSelected, "#\(number) present")
        }
        for number in ["4", "7", "11", "12", "14"] { XCTAssertTrue(basis(number).isSelected, "#\(number) in the basisvijf") }
        reveal(app.descendants(matching: .any)["setup.grid"])
        XCTAssertEqual(gridRows().count, 7, "the plan is shown at once")
    }

    @MainActor
    func testTheHistorySwitchIsRemembered() throws {
        try plantRoster(6)
        openSetup()
        let toggle = app.switches["setup.useHistory"]
        reveal(toggle)
        XCTAssertEqual(toggle.value as? String, "0")
        XCTAssertEqual(app.staticTexts["setup.historyNote"].label, "Nog geen matchen bewaard.")
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.92, dy: 0.5)).tap()
        XCTAssertTrue(waitFor(toggle, value: "1"))
        XCTAssertEqual(try storedSetup()["useHistory"] as? Bool, true)

        app.terminate()
        app.launch()
        openSetupTab()
        reveal(app.switches["setup.useHistory"])
        XCTAssertEqual(app.switches["setup.useHistory"].value as? String, "1")
    }

    // MARK: - Helpers

    private func plantRoster(_ count: Int) throws {
        let players = (0..<count).map { ["id": $0 + 1, "name": names[$0], "number": numbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": count + 1, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
    }

    private func openSetup() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        openSetupTab()
    }

    /// The Match tab: in the tab bar on the iPhone 17 Pro, in the system's side rail on the iPhone Duo's outer screen.
    private func openSetupTab() {
        let tab = app.buttons["Match"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
    }

    private func counts() -> XCUIElement { app.staticTexts["setup.counts"] }

    /// The counts line under the attendance heading, scrolled back to the top of the list first.
    private func countsText() -> String? {
        let text = counts()
        for _ in 0..<16 where !(text.exists && text.isHittable) { app.swipeDown(velocity: .fast) }
        return text.exists ? text.label : nil
    }
    private func present(_ number: String) -> XCUIElement { app.buttons["setup.present.\(number)"] }
    private func basis(_ number: String) -> XCUIElement { app.buttons["setup.basis.\(number)"] }
    private func row(_ label: String) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'setup.row.' AND label == %@", label)).firstMatch
    }

    private func gridRows() -> [XCUIElement] {
        let query = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'setup.row.'"))
        XCTAssertTrue(query.firstMatch.waitForExistence(timeout: 5))
        return query.allElementsBoundByIndex
    }

    private func note() -> String? {
        let text = app.staticTexts["setup.note"]
        reveal(text)
        return text.exists ? text.label : nil
    }

    private func message() -> String? {
        let text = app.staticTexts["setup.message"]
        return text.waitForExistence(timeout: 5) ? text.label : nil
    }

    private func pickBasisvijf(_ numbers: [String]) {
        for number in numbers { tapReveal(basis(number)) }
    }

    /// A row's value is "5 blokken: 1, 2, 5, 6, 9 · 16:40".
    private func blocks(_ row: XCUIElement) -> [Int] {
        guard let value = row.value as? String, let colon = value.firstIndex(of: ":"),
              let dot = value.range(of: " · ") else { return [] }
        return value[value.index(after: colon)..<dot.lowerBound].split(separator: ",")
            .compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private func minutes(_ row: XCUIElement) -> String? { (row.value as? String).flatMap(minutes(of:)) }
    private func minutes(of value: String) -> String? {
        value.range(of: " · ").map { String(value[$0.upperBound...]) }
    }

    /// "#7 Fien" → "Fien".
    private func name(_ label: String) -> String {
        label.split(separator: " ", maxSplits: 1).last.map(String.init) ?? label
    }

    /// Scrolls the list until the element is on screen: down first, then back up.
    private func reveal(_ element: XCUIElement) {
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

    private func tapReveal(_ element: XCUIElement) {
        reveal(element)
        element.tap()
    }

    private func waitFor(_ element: XCUIElement, value: String) -> Bool {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate(format: "value == %@", value), object: element)
        return XCTWaiter().wait(for: [expectation], timeout: 5) == .completed
    }

    private func storedSetup() throws -> [String: Any] {
        let data = try Data(contentsOf: setupFile)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }
}
