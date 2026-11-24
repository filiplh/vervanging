import XCTest

/// The end of the match and the team history (#104): after a full match the end screen shows each player's minutes
/// (blocks × block length), the match is saved into the history once, the Spelers screen shows the same minutes as
/// season totals over "1 bewaarde match", Wis geschiedenis asks first and then resets the totals to 0, and the next
/// setup with the history switch on plans with that history (catch-up, decision #28).
///
/// Every test gives the app its own storage folder through `VERVANGING_STORAGE_DIR` and a fixed first seed through
/// `VERVANGING_SEED` (both read by debug builds only). The checks wait for elements instead of reading them at once.
final class EndUITests: XCTestCase {
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
            .appendingPathComponent("end-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
        app.launchEnvironment["VERVANGING_SEED"] = "7"
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    // MARK: - The end and the season totals

    @MainActor
    func testAFullMatchShowsTheMinutesAndAddsThemToTheSeasonTotals() throws {
        try plantRoster(12)
        try startMatch()
        for next in 2...12 { tapWissel(expecting: "Blok \(next) van 12") }
        tapWissel(expecting: "Einde match")
        XCTAssertTrue(app.staticTexts["Minuten per speler"].waitForExistence(timeout: 5))

        // 12 players, 12 blocks of 3:20 with five on court: every player 5 blocks, 16:40.
        for number in numbers {
            let row = element("live.minutes.\(number)")
            reveal(row)
            XCTAssertEqual(row.value as? String, "16:40", "#\(number) on the end screen")
        }
        let history = try storedHistory()
        XCTAssertEqual(history["version"] as? Int, 1)
        let matches = try XCTUnwrap(history["matches"] as? [[String: Any]])
        XCTAssertEqual(matches.count, 1, "the match is saved once")
        XCTAssertEqual((matches[0]["seconds"] as? [String: Int])?.values.sorted(), Array(repeating: 1000, count: 12))

        // Nieuwe match: setup counts the saved match.
        let newMatch = app.buttons["live.newMatch"]
        XCTAssertTrue(newMatch.waitForExistence(timeout: 5))
        newMatch.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
        let note = app.staticTexts["setup.historyNote"]
        reveal(note)
        XCTAssertTrue(waitFor(note, labelContaining: "1 match bewaard."))

        // The Spelers screen shows the same minutes as season totals.
        openSpelers()
        XCTAssertTrue(waitFor(element("spelers.season"), label: "Speeltijd dit seizoen, over 1 bewaarde match."))
        for number in numbers {
            let total = element("spelers.total.\(number)")
            reveal(total)
            XCTAssertEqual(total.label, "speeltijd 16:40 min", "#\(number) season total")
        }

        // A relaunch on the end screen counts nothing twice.
        app.terminate()
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(element("spelers.season"), label: "Speeltijd dit seizoen, over 1 bewaarde match."))
        XCTAssertEqual((try storedHistory()["matches"] as? [Any])?.count, 1)
    }

    @MainActor
    func testUndoOfTheEndTakesTheMatchOutOfTheHistory() throws {
        try plantRoster(12)
        try startMatch()
        for next in 2...12 { tapWissel(expecting: "Blok \(next) van 12") }
        tapWissel(expecting: "Einde match")
        XCTAssertEqual((try storedHistory()["matches"] as? [Any])?.count, 1)

        let undo = app.buttons["live.undo"]
        XCTAssertTrue(waitFor(undo, enabled: true))
        undo.tap()
        XCTAssertTrue(app.staticTexts["Blok 12 van 12"].waitForExistence(timeout: 5))
        XCTAssertEqual((try storedHistory()["matches"] as? [Any])?.count, 0)
        tapWissel(expecting: "Einde match")
        XCTAssertEqual((try storedHistory()["matches"] as? [Any])?.count, 1, "ending again counts it once")
    }

    // MARK: - Wis geschiedenis

    @MainActor
    func testWisGeschiedenisAsksFirstThenResetsTheTotals() throws {
        try plantRoster(12)
        try plantHistory(["1": 1000, "2": 4000, "3": 600])
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitFor(element("spelers.season"), label: "Speeltijd dit seizoen, over 1 bewaarde match."))
        XCTAssertEqual(element("spelers.total.4").label, "speeltijd 16:40 min")
        XCTAssertEqual(element("spelers.total.7").label, "speeltijd 1:06:40 min", "h:mm:ss from an hour on")
        XCTAssertEqual(element("spelers.total.5").label, "speeltijd 0:00 min", "a player in no saved match")

        // Annuleren keeps everything.
        let clear = app.buttons["spelers.clearHistory"]
        reveal(clear)
        clear.tap()
        let alert = app.alerts["De geschiedenis van alle vorige matchen wissen?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "asks first")
        alert.buttons["Annuleren"].tap()
        XCTAssertTrue(waitForGone(alert))
        reveal(element("spelers.total.4"))
        XCTAssertEqual(element("spelers.total.4").label, "speeltijd 16:40 min")
        XCTAssertEqual((try storedHistory()["matches"] as? [Any])?.count, 1)

        // Wis geschiedenis empties it.
        reveal(clear)
        clear.tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Wis geschiedenis"].tap()
        XCTAssertTrue(waitForGone(alert))
        XCTAssertTrue(waitFor(element("spelers.historyMessage"), label: "Geschiedenis gewist."))
        XCTAssertTrue(waitFor(clear, enabled: false), "nothing left to clear")
        for number in numbers.reversed() {
            let total = element("spelers.total.\(number)")
            reveal(total)
            XCTAssertEqual(total.label, "speeltijd 0:00 min", "#\(number) back to 0")
        }
        let season = element("spelers.season")
        reveal(season)
        XCTAssertTrue(waitFor(season, label: "Speeltijd dit seizoen: nog geen matchen bewaard."))
        let history = try storedHistory()
        XCTAssertEqual((history["matches"] as? [Any])?.count, 0)
        XCTAssertNotNil(history["clearedAt"] as? String)

        // The Match screen agrees.
        openSetupTab()
        let note = app.staticTexts["setup.historyNote"]
        reveal(note)
        XCTAssertTrue(waitFor(note, label: "Nog geen matchen bewaard."))
    }

    // MARK: - The next setup

    @MainActor
    func testTheNextSetupWithTheSwitchOnUsesTheHistory() throws {
        // 11 players: 60 places leave five uneven places (6 blocks instead of 5). The five who played least before
        // (#12, #13, #14, #15, #21, ids 6 to 10) get them.
        try plantRoster(11)
        var seconds: [String: Int] = [:]
        for id in 1...11 { seconds[String(id)] = (6...10).contains(id) ? 0 : 1200 }
        try plantHistory(seconds)
        let setup: [String: Any] = ["version": 1, "useHistory": true, "startingFive": [1, 2, 3, 4, 5]]
        try JSONSerialization.data(withJSONObject: setup).write(to: storageDir.appendingPathComponent("setup.json"))

        app.launch()
        openSetupTab()
        let note = app.staticTexts["setup.historyNote"]
        reveal(note)
        XCTAssertTrue(waitFor(note, labelContaining: "1 match bewaard."))
        XCTAssertEqual(app.switches["setup.useHistory"].value as? String, "1")
        for number in ["12", "13", "14", "15", "21"] {
            let row = element("setup.row.\(number)")
            reveal(row)
            XCTAssertTrue((row.value as? String)?.hasPrefix("6 blokken") == true, "#\(number) catches up: \(row.value ?? "")")
        }
        for number in ["4", "7", "8", "10", "11", "23"] {
            let row = element("setup.row.\(number)")
            reveal(row)
            XCTAssertTrue((row.value as? String)?.hasPrefix("5 blokken") == true, "#\(number): \(row.value ?? "")")
        }
    }

    // MARK: - Helpers

    private func element(_ id: String) -> XCUIElement { app.descendants(matching: .any)[id].firstMatch }

    private func plantRoster(_ count: Int) throws {
        let players = (0..<count).map { ["id": $0 + 1, "name": names[$0], "number": numbers[$0]] as [String: Any] }
        let object: [String: Any] = ["version": 1, "nextId": count + 1, "players": players]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("roster.json"))
    }

    private func plantHistory(_ seconds: [String: Int]) throws {
        let object: [String: Any] = ["version": 1, "useHistory": false, "clearedAt": NSNull(),
                                     "matches": [["id": "2026-11-01T10:00:00.000Z", "seconds": seconds]]]
        try JSONSerialization.data(withJSONObject: object).write(to: storageDir.appendingPathComponent("history.json"))
    }

    private func storedHistory() throws -> [String: Any] {
        let data = try Data(contentsOf: storageDir.appendingPathComponent("history.json"))
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    /// Opens setup, picks the basisvijf and taps Start: the live screen opens at block 1.
    private func startMatch() throws {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
        openSetupTab()
        for number in basisvijf { tapReveal(app.buttons["setup.basis.\(number)"]) }
        tapReveal(app.buttons["setup.start"])
        XCTAssertTrue(app.staticTexts["Blok 1 van 12"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["live.wissel"].waitForExistence(timeout: 5))
    }

    private func openSetupTab() {
        let tab = app.buttons["Match"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Match"].waitForExistence(timeout: 5))
    }

    private func openSpelers() {
        let tab = app.buttons["Spelers"].firstMatch
        XCTAssertTrue(tab.waitForExistence(timeout: 10))
        tab.tap()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 5))
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

    /// Scrolls until the element is on screen, and on the live screen clear of the Wissel bar: down first, then up.
    private func reveal(_ element: XCUIElement) {
        func shown() -> Bool {
            guard element.exists, element.isHittable else { return false }
            // The Start bar on setup floats over rows too (#150): a tap there would land on Start. Only its own buttons
            // lie inside it.
            let startBar = app.descendants(matching: .any)["setup.actions"]
            if startBar.exists, !["setup.start", "setup.anotherPlan"].contains(element.identifier),
               element.frame.intersects(startBar.frame) { return false }
            let bar = app.descendants(matching: .any)["live.actions"]
            return !bar.exists || element.frame.maxY <= bar.frame.minY
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

    private func wait(_ element: XCUIElement, _ predicate: NSPredicate) -> Bool {
        XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: element)], timeout: 5) == .completed
    }

    private func waitFor(_ element: XCUIElement, label: String) -> Bool {
        wait(element, NSPredicate(format: "label == %@", label))
    }

    private func waitFor(_ element: XCUIElement, labelContaining text: String) -> Bool {
        wait(element, NSPredicate(format: "label CONTAINS %@", text))
    }

    private func waitFor(_ element: XCUIElement, enabled: Bool) -> Bool {
        wait(element, NSPredicate(format: "enabled == %@", NSNumber(value: enabled)))
    }

    private func waitForGone(_ element: XCUIElement) -> Bool {
        wait(element, NSPredicate(format: "exists == false"))
    }
}
