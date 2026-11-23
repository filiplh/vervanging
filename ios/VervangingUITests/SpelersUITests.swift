import XCTest

/// The Spelers screen (#100): add, edit and remove players, the web app's refusals and the 15-player limit, and the
/// roster file that is written after every change and read again on launch.
///
/// Every test gives the app its own empty storage folder through `VERVANGING_STORAGE_DIR` (read by debug builds only),
/// so the tests start from a known roster and can read and plant the JSON file the app uses.
final class SpelersUITests: XCTestCase {
    private var storageDir: URL!
    private var app: XCUIApplication!

    private var rosterFile: URL { storageDir.appendingPathComponent("roster.json") }

    override func setUpWithError() throws {
        continueAfterFailure = false
        storageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spelers-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storageDir, withIntermediateDirectories: true)
        app = XCUIApplication()
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = storageDir.path
    }

    override func tearDownWithError() throws {
        app?.terminate()
        if let storageDir { try? FileManager.default.removeItem(at: storageDir) }
    }

    // MARK: - Add, and the roster kept after a force-quit

    @MainActor
    func testAddedPlayerIsShownAndStillThereAfterForceQuit() throws {
        launch()
        XCTAssertTrue(app.staticTexts["spelers.empty"].exists)
        XCTAssertTrue(app.staticTexts["0 van 15"].exists)

        add("Lotte", "7")

        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        XCTAssertTrue(row("7").label.contains("Lotte"))
        XCTAssertFalse(app.staticTexts["spelers.empty"].exists)
        XCTAssertTrue(app.staticTexts["1 van 15"].exists)
        XCTAssertEqual(field("spelers.name").value as? String, "Voornaam", "the form is cleared after adding")

        // Written at once, with a version field.
        let stored = try storedRoster()
        XCTAssertEqual(stored["version"] as? Int, 1)
        let players = try XCTUnwrap(stored["players"] as? [[String: Any]])
        XCTAssertEqual(players.count, 1)
        XCTAssertEqual(players.first?["name"] as? String, "Lotte")
        XCTAssertEqual(players.first?["number"] as? String, "7")

        // Force-quit and open again.
        app.terminate()
        launch()
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        XCTAssertTrue(row("7").label.contains("Lotte"))
        XCTAssertTrue(app.staticTexts["1 van 15"].exists)
    }

    @MainActor
    func testPlayersAreListedByNumber() throws {
        launch()
        add("Fien", "12")
        add("Lotte", "7")
        add("Mila", "07")
        XCTAssertTrue(row("07").waitForExistence(timeout: 5))
        let order = ["7", "07", "12"].map { row($0).frame.minY }
        XCTAssertEqual(order, order.sorted(), "rows sorted by number, 7 before 07 (as the web app)")
    }

    // MARK: - Edit

    @MainActor
    func testEditChangesNameAndNumberAndIsSaved() throws {
        launch()
        add("Lotte", "7")
        app.buttons["spelers.edit.7"].tap()

        XCTAssertTrue(app.buttons["Bewaren"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["Annuleren"].exists)
        XCTAssertEqual(field("spelers.name").value as? String, "Lotte")
        XCTAssertEqual(field("spelers.number").value as? String, "7")

        replace(field("spelers.name"), with: "Fien")
        replace(field("spelers.number"), with: "8")
        app.buttons["Bewaren"].tap()

        XCTAssertTrue(row("8").waitForExistence(timeout: 5))
        XCTAssertTrue(row("8").label.contains("Fien"))
        XCTAssertFalse(row("7").exists)
        XCTAssertTrue(app.buttons["Toevoegen"].exists, "back to adding after saving")
        XCTAssertTrue(app.staticTexts["1 van 15"].exists)

        app.terminate()
        launch()
        XCTAssertTrue(row("8").waitForExistence(timeout: 5))
        XCTAssertTrue(row("8").label.contains("Fien"))
    }

    @MainActor
    func testEditKeepsOwnNumberAndCancelLeavesPlayerAsIs() throws {
        launch()
        add("Lotte", "7")

        // Saving with the player's own number is fine (the number is not "taken" by herself).
        app.buttons["spelers.edit.7"].tap()
        replace(field("spelers.name"), with: "Lotje")
        app.buttons["Bewaren"].tap()
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        XCTAssertTrue(row("7").label.contains("Lotje"))
        XCTAssertFalse(app.staticTexts["spelers.message"].exists)

        // Annuleren drops the change.
        app.buttons["spelers.edit.7"].tap()
        replace(field("spelers.name"), with: "Iemand")
        app.buttons["Annuleren"].tap()
        XCTAssertTrue(app.buttons["Toevoegen"].waitForExistence(timeout: 5))
        XCTAssertTrue(row("7").label.contains("Lotje"))
        XCTAssertEqual(field("spelers.name").value as? String, "Voornaam")
    }

    // MARK: - Remove

    @MainActor
    func testRemoveAsksFirstAndIsSaved() throws {
        launch()
        add("Lotte", "7")
        add("Fien", "12")

        // "Annuleren" keeps her.
        app.buttons["spelers.remove.7"].tap()
        let alert = app.alerts["#7 Lotte verwijderen?"]
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Annuleren"].tap()
        XCTAssertTrue(row("7").exists)
        XCTAssertTrue(app.staticTexts["2 van 15"].exists)

        // "Verwijder" removes her.
        app.buttons["spelers.remove.7"].tap()
        XCTAssertTrue(alert.waitForExistence(timeout: 5))
        alert.buttons["Verwijder"].tap()
        XCTAssertTrue(row("7").waitForNonExistence(timeout: 5))
        XCTAssertTrue(row("12").exists)
        XCTAssertTrue(app.staticTexts["1 van 15"].exists)

        app.terminate()
        launch()
        XCTAssertTrue(row("12").waitForExistence(timeout: 5))
        XCTAssertFalse(row("7").exists)
    }

    // MARK: - Refusals, as the web app refuses them

    @MainActor
    func testEmptyNameTakenNumberAndBadNumberAreRefusedWithTheWebAppsMessages() throws {
        launch()
        add("Lotte", "7")

        // An empty name (spaces only count as empty).
        add("   ", "8")
        XCTAssertEqual(message(), "Vul een voornaam in.")
        XCTAssertFalse(row("8").exists)

        // A number already taken.
        replace(field("spelers.name"), with: "Fien")
        replace(field("spelers.number"), with: "7")
        app.buttons["Toevoegen"].tap()
        XCTAssertEqual(message(), "Rugnummer 7 is al van Lotte.")
        XCTAssertEqual(field("spelers.name").value as? String, "Fien", "a refused entry stays in the form")

        // No number.
        replace(field("spelers.number"), with: "")
        app.buttons["Toevoegen"].tap()
        XCTAssertEqual(message(), "Vul een rugnummer van 0 tot 99 in.")

        XCTAssertTrue(app.staticTexts["1 van 15"].exists)
        let players = try XCTUnwrap(try storedRoster()["players"] as? [[String: Any]])
        XCTAssertEqual(players.count, 1, "nothing refused was saved")

        // A good entry clears the message.
        replace(field("spelers.number"), with: "8")
        app.buttons["Toevoegen"].tap()
        XCTAssertTrue(row("8").waitForExistence(timeout: 5))
        XCTAssertFalse(app.staticTexts["spelers.message"].exists)
    }

    @MainActor
    func testNameIsKeptAsTyped() throws {
        // Autocorrect (and with it spellcheck) is off for the name, as in the web app (#61). With autocorrect on,
        // the space after "Teh" would let the keyboard replace it.
        launch()
        add("Teh Lien", "3")
        XCTAssertTrue(row("3").waitForExistence(timeout: 5))
        XCTAssertTrue(row("3").label.contains("Teh Lien"), "got \(row("3").label)")
        let players = try XCTUnwrap(try storedRoster()["players"] as? [[String: Any]])
        XCTAssertEqual(players.first?["name"] as? String, "Teh Lien")
    }

    // MARK: - The 15-player limit

    @MainActor
    func testFifteenthPlayerFillsTheRosterAndASixteenthCannotBeAdded() throws {
        try plant(players: (1...14).map { (id: $0, name: "Speler\($0)", number: String($0 + 10)) })
        launch()
        XCTAssertTrue(app.staticTexts["14 van 15"].waitForExistence(timeout: 5))

        add("Lotte", "7")
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["15 van 15"].exists)

        // Full: the form gives way to the web app's message, so a 16th cannot be entered.
        let full = app.staticTexts["spelers.full"]
        XCTAssertTrue(full.waitForExistence(timeout: 5))
        XCTAssertEqual(
            full.label, "Maximaal 15 spelers. Verwijder eerst een speler om er een toe te voegen."
        )
        XCTAssertFalse(field("spelers.name").exists)
        XCTAssertFalse(app.buttons["Toevoegen"].exists)

        // Still full after a restart.
        app.terminate()
        launch()
        XCTAssertTrue(app.staticTexts["spelers.full"].waitForExistence(timeout: 5))
        XCTAssertFalse(field("spelers.name").exists)

        // Editing a player is still possible on a full roster.
        app.buttons["spelers.edit.7"].tap()
        XCTAssertTrue(app.buttons["Bewaren"].waitForExistence(timeout: 5))
        app.buttons["Annuleren"].tap()

        // Removing one makes room again.
        app.buttons["spelers.remove.7"].tap()
        app.alerts["#7 Lotte verwijderen?"].buttons["Verwijder"].tap()
        XCTAssertTrue(field("spelers.name").waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["14 van 15"].exists)
    }

    // MARK: - A missing or unreadable file

    @MainActor
    func testMissingFileStartsAnEmptyRoster() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: rosterFile.path))
        launch()
        XCTAssertTrue(app.staticTexts["spelers.empty"].exists)
        XCTAssertTrue(app.staticTexts["0 van 15"].exists)
        XCTAssertFalse(FileManager.default.fileExists(atPath: rosterFile.path), "nothing is written before a change")
    }

    @MainActor
    func testUnreadableFileStartsAnEmptyRosterAndIsReplacedOnTheNextChange() throws {
        try Data("{ dit is geen JSON".utf8).write(to: rosterFile)
        launch()
        XCTAssertTrue(app.staticTexts["spelers.empty"].exists)
        XCTAssertTrue(app.staticTexts["0 van 15"].exists)

        add("Lotte", "7")
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        XCTAssertEqual(try storedRoster()["version"] as? Int, 1)
    }

    @MainActor
    func testUnknownVersionAndDamagedPlayersAreNotShown() throws {
        // A file from a later version is not guessed at.
        try JSONSerialization.data(withJSONObject: [
            "version": 99, "nextId": 2, "players": [["id": 1, "name": "Lotte", "number": "7"]],
        ]).write(to: rosterFile)
        launch()
        XCTAssertTrue(app.staticTexts["spelers.empty"].exists)
        app.terminate()

        // One damaged player is dropped, the others stay (as the web app's normaliseRoster).
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "nextId": 4, "players": [
                ["id": 1, "name": "Lotte", "number": "7"],
                ["id": 2, "name": "", "number": "8"],
                ["id": 3, "name": "Fien", "number": "123"],
                "geen speler",
            ],
        ]).write(to: rosterFile)
        launch()
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        XCTAssertFalse(row("8").exists)
        XCTAssertFalse(row("123").exists)
        XCTAssertTrue(app.staticTexts["1 van 15"].exists)
    }

    // MARK: - Helpers

    private func launch() {
        app.launch()
        XCTAssertTrue(app.navigationBars["Spelers"].waitForExistence(timeout: 10))
    }

    private func field(_ id: String) -> XCUIElement { app.textFields[id] }

    private func row(_ number: String) -> XCUIElement {
        app.descendants(matching: .any)["spelers.player.\(number)"].firstMatch
    }

    private func message() -> String? {
        let text = app.staticTexts["spelers.message"]
        return text.waitForExistence(timeout: 5) ? text.label : nil
    }

    private func add(_ name: String, _ number: String) {
        replace(field("spelers.name"), with: name)
        replace(field("spelers.number"), with: number)
        app.buttons["Toevoegen"].tap()
    }

    /// Clears a text field and types the new text.
    private func replace(_ field: XCUIElement, with text: String) {
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.tap()
        if let current = field.value as? String, !current.isEmpty, current != field.placeholderValue {
            field.typeText(String(repeating: XCUIKeyboardKey.delete.rawValue, count: current.count))
        }
        if !text.isEmpty { field.typeText(text) }
    }

    private func storedRoster() throws -> [String: Any] {
        let data = try Data(contentsOf: rosterFile)
        return try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func plant(players: [(id: Int, name: String, number: String)]) throws {
        let object: [String: Any] = [
            "version": 1,
            "nextId": (players.map(\.id).max() ?? 0) + 1,
            "players": players.map { ["id": $0.id, "name": $0.name, "number": $0.number] },
        ]
        try JSONSerialization.data(withJSONObject: object).write(to: rosterFile)
    }
}
