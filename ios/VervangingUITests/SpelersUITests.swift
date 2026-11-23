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

    // MARK: - Damaged or extreme ids (review of #117)

    /// The web app's own id limit (JavaScript's largest safe integer), the largest id the store keeps.
    private let maxId = 9_007_199_254_740_991

    @MainActor
    func testOutOfRangeStoredIdsAreDroppedWithoutACrashAndAddingStillWorks() throws {
        try JSONSerialization.data(withJSONObject: [
            "version": 1, "nextId": Int.max, "players": [
                ["id": Int.max, "name": "Lotte", "number": "7"],
                ["id": Int.min, "name": "Noor", "number": "9"],
                ["id": maxId, "name": "Fien", "number": "12"],
            ],
        ]).write(to: rosterFile)
        launch()
        XCTAssertTrue(row("12").waitForExistence(timeout: 5), "an id at the limit is kept")
        XCTAssertFalse(row("7").exists, "an id above the limit is damaged and dropped")
        XCTAssertFalse(row("9").exists, "an id below the negative limit is damaged and dropped")

        add("Mila", "4")
        XCTAssertTrue(row("4").waitForExistence(timeout: 5))
        let stored = try storedRoster()
        let players = try XCTUnwrap(stored["players"] as? [[String: Any]])
        let mila = try XCTUnwrap(players.first { $0["name"] as? String == "Mila" })
        XCTAssertEqual(mila["id"] as? Int, 1, "no id above the limit is free, so the smallest free one is used")
        XCTAssertEqual(stored["nextId"] as? Int, 2)

        app.terminate()
        launch()
        XCTAssertTrue(row("4").waitForExistence(timeout: 5))
        XCTAssertTrue(row("12").exists)
    }

    @MainActor
    func testExtremeNextIdOnAnEmptyRosterStillAdds() throws {
        // A next id far above the limit: read as damaged, the first player gets id 1.
        try JSONSerialization.data(withJSONObject: ["version": 1, "nextId": Int.max, "players": []])
            .write(to: rosterFile)
        launch()
        add("Lotte", "7")
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        var stored = try storedRoster()
        XCTAssertEqual((stored["players"] as? [[String: Any]])?.first?["id"] as? Int, 1)
        XCTAssertEqual(stored["nextId"] as? Int, 2)
        app.terminate()

        // A next id exactly at the limit is used, and the one after it wraps to a free small id, never overflowing.
        try JSONSerialization.data(withJSONObject: ["version": 1, "nextId": maxId, "players": []])
            .write(to: rosterFile)
        launch()
        add("Lotte", "7")
        XCTAssertTrue(row("7").waitForExistence(timeout: 5))
        add("Fien", "12")
        XCTAssertTrue(row("12").waitForExistence(timeout: 5))
        stored = try storedRoster()
        let ids = (stored["players"] as? [[String: Any]])?.compactMap { $0["id"] as? Int }
        XCTAssertEqual(ids, [maxId, 1])
        XCTAssertEqual(stored["nextId"] as? Int, 2)
    }

    // MARK: - A failed save (review of #117)

    @MainActor
    func testFailedSaveShowsTheStorageMessage() throws {
        // The storage folder's path is a regular file, so the folder cannot be made and every write fails.
        let blocked = storageDir.appendingPathComponent("geen-map")
        try Data("geen map".utf8).write(to: blocked)
        app.launchEnvironment["VERVANGING_STORAGE_DIR"] = blocked.path
        launch()
        XCTAssertTrue(app.staticTexts["spelers.empty"].exists, "an unreadable storage folder starts empty")

        add("Lotte", "7")
        XCTAssertEqual(message(), "Opslaan lukte niet: de telefoon weigert opslag.")
        XCTAssertTrue(row("7").exists, "the change stays on screen, as on the web, with the message saying it was not stored")
        XCTAssertEqual(try Data(contentsOf: blocked), Data("geen map".utf8), "nothing was written over the file")

        // A relaunch shows that nothing was stored.
        app.terminate()
        launch()
        XCTAssertTrue(app.staticTexts["spelers.empty"].exists)
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
