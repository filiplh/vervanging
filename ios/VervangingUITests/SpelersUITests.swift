import XCTest

/// The Spelers screen (#100): add, edit (in a sheet, #149) and remove players, the web app's refusals and the 15-player limit, and the
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
        expectShown(app.staticTexts["spelers.empty"])
        expectShown(app.staticTexts["0 van 15"])

        add("Lotte", "7")

        expectRow("7", containing: "Lotte")
        expectGone(app.staticTexts["spelers.empty"])
        expectShown(app.staticTexts["1 van 15"])
        expectValue(field("spelers.name"), "Voornaam", "the form is cleared after adding")

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
        expectRow("7", containing: "Lotte")
        expectShown(app.staticTexts["1 van 15"])
    }

    @MainActor
    func testPlayersAreListedByNumber() throws {
        launch()
        addPlayer("Fien", "12")
        addPlayer("Lotte", "7")
        addPlayer("Mila", "07")
        for number in ["7", "07", "12"] { expectShown(row(number)) }
        // The list settles in order; wait for that before reading the positions.
        _ = waitUntil {
            let positions = ["7", "07", "12"].map { self.row($0).frame.minY }
            return positions == positions.sorted()
        }
        let order = ["7", "07", "12"].map { row($0).frame.minY }
        XCTAssertEqual(order, order.sorted(), "rows sorted by number, 7 before 07 (as the web app)")
    }

    // MARK: - Edit, in a sheet over the list (#149)

    @MainActor
    func testEditChangesNameAndNumberAndIsSaved() throws {
        launch()
        addPlayer("Lotte", "7")
        tapInRow(app.buttons["spelers.edit.7"])

        expectShown(sheet)
        expectShown(saveButton)
        expectShown(cancelButton)
        expectValue(field("spelers.sheet.name"), "Lotte")
        expectValue(field("spelers.sheet.number"), "7")
        expectValue(field("spelers.name"), "Voornaam", "the add form is not used for editing")

        replace(field("spelers.sheet.name"), with: "Fien")
        replace(field("spelers.sheet.number"), with: "8")
        tap(saveButton)

        expectGone(sheet, "Bewaren closes the sheet")
        expectRow("8", containing: "Fien")
        expectGone(row("7"))
        expectShown(app.buttons["Toevoegen"])
        expectShown(app.staticTexts["1 van 15"])

        app.terminate()
        launch()
        expectRow("8", containing: "Fien")
    }

    @MainActor
    func testEditKeepsOwnNumberAndCancelOrSwipeDownLeavesPlayerAsIs() throws {
        launch()
        addPlayer("Lotte", "7")

        // Saving with the player's own number is fine (the number is not "taken" by herself).
        tapInRow(app.buttons["spelers.edit.7"])
        replace(field("spelers.sheet.name"), with: "Lotje")
        tap(saveButton)
        expectGone(sheet)
        expectRow("7", containing: "Lotje")
        expectGone(app.staticTexts["spelers.message"])

        // Annuleren drops the change.
        tapInRow(app.buttons["spelers.edit.7"])
        replace(field("spelers.sheet.name"), with: "Iemand")
        tap(cancelButton)
        expectGone(sheet, "Annuleren closes the sheet")
        expectRow("7", containing: "Lotje")

        // Swiping the sheet down drops the change too.
        tapInRow(app.buttons["spelers.edit.7"])
        replace(field("spelers.sheet.name"), with: "Iemand")
        hideSheetKeyboard()
        swipeSheetDown()
        expectGone(sheet, "swiping down closes the sheet")
        expectRow("7", containing: "Lotje")

        // The next Wijzig starts from the stored values, not from the dropped ones.
        tapInRow(app.buttons["spelers.edit.7"])
        expectValue(field("spelers.sheet.name"), "Lotje")
        tap(cancelButton)

        let players = try XCTUnwrap(try storedRoster()["players"] as? [[String: Any]])
        XCTAssertEqual(players.first?["name"] as? String, "Lotje", "nothing cancelled was saved")
    }

    @MainActor
    func testTakenNumberIsRefusedInsideTheSheet() throws {
        launch()
        addPlayer("Lotte", "7")
        addPlayer("Fien", "12")

        tapInRow(app.buttons["spelers.edit.12"])
        replace(field("spelers.sheet.number"), with: "7")
        tap(saveButton)
        expectMessage("Rugnummer 7 is al van Lotte.", in: "spelers.sheet.message")
        expectShown(sheet, "a refused value keeps the sheet open")
        expectValue(field("spelers.sheet.number"), "7", "a refused value stays in the sheet")
        XCTAssertFalse(app.staticTexts["spelers.message"].exists, "the message is in the sheet, not under the add form")

        // An empty name, with the same message as when adding.
        replace(field("spelers.sheet.name"), with: "")
        replace(field("spelers.sheet.number"), with: "13")
        tap(saveButton)
        expectMessage("Vul een voornaam in.", in: "spelers.sheet.message")

        tap(cancelButton)
        expectGone(sheet)
        expectRow("12", containing: "Fien")
        expectGone(row("13"))

        // The message is gone the next time the sheet opens.
        tapInRow(app.buttons["spelers.edit.12"])
        expectShown(saveButton)
        expectGone(app.staticTexts["spelers.sheet.message"])
        tap(cancelButton)
    }

    @MainActor
    func testEditingARowFarDownKeepsTheListWhereItWas() throws {
        // A full list of 15, taller than the screen: the last row is only reached by scrolling.
        try plant(players: (1...15).map { (id: $0, name: "Speler\($0)", number: String($0 + 10)) })
        launch()
        let last = row("25")
        expectShown(row("11"))
        // The list loads rows as they come into view, so the last one only exists after scrolling.
        let list = app.collectionViews.firstMatch
        for _ in 0..<8 where !inView(app.buttons["spelers.edit.25"]) { list.swipeUp() }
        XCTAssertTrue(inView(app.buttons["spelers.edit.25"]), "scrolled down to the last row")
        XCTAssertFalse(inView(app.staticTexts["spelers.full"]), "the top of the list is scrolled away")
        // Let the scroll settle: the row's place no longer changes between two reads.
        var settled = CGFloat.nan
        _ = waitUntil {
            let now = last.frame.minY
            defer { settled = now }
            return now == settled
        }
        let before = last.frame.minY

        // Refused, then cancelled: the list has not moved.
        tap(app.buttons["spelers.edit.25"])
        replace(field("spelers.sheet.number"), with: "11")
        tap(saveButton)
        expectMessage("Rugnummer 11 is al van Speler1.", in: "spelers.sheet.message")
        tap(cancelButton)
        expectGone(sheet)
        XCTAssertEqual(row("25").frame.minY, before, accuracy: 1, "the list is where it was after Annuleren")

        // Saved: the row keeps its place (still the highest number) and shows the new values.
        tap(app.buttons["spelers.edit.25"])
        replace(field("spelers.sheet.name"), with: "Lotte")
        replace(field("spelers.sheet.number"), with: "99")
        tap(saveButton)
        expectGone(sheet)
        expectRow("99", containing: "Lotte")
        XCTAssertEqual(row("99").frame.minY, before, accuracy: 1, "the list is where it was after Bewaren")
        XCTAssertTrue(app.buttons["spelers.edit.99"].isHittable, "the edited row is in view without scrolling")
        XCTAssertFalse(inView(app.staticTexts["spelers.full"]), "the list did not jump back to the top")
    }

    @MainActor
    func testKlaarHidesTheKeyboardInTheSheet() throws {
        launch()
        addPlayer("Lotte", "7")
        tapInRow(app.buttons["spelers.edit.7"])
        let done = app.buttons["spelers.sheet.keyboardDone"]

        tap(field("spelers.sheet.name"))
        expectShown(keyboard)
        tap(done)
        expectGone(keyboard, "Klaar hides the keyboard from the sheet's name field")

        tap(field("spelers.sheet.number"))
        expectShown(keyboard)
        tap(done)
        expectGone(keyboard, "Klaar hides the number pad in the sheet")
        expectShown(sheet, "Klaar leaves the sheet open")
    }

    // MARK: - Remove

    @MainActor
    func testRemoveAsksFirstAndIsSaved() throws {
        launch()
        addPlayer("Lotte", "7")
        addPlayer("Fien", "12")

        // "Annuleren" keeps her.
        tapInRow(app.buttons["spelers.remove.7"])
        let alert = app.alerts["#7 Lotte verwijderen?"]
        expectShown(alert)
        tap(alert.buttons["Annuleren"])
        expectGone(alert)
        expectShown(row("7"))
        expectShown(app.staticTexts["2 van 15"])

        // "Verwijder" removes her.
        tapInRow(app.buttons["spelers.remove.7"])
        expectShown(alert)
        tap(alert.buttons["Verwijder"])
        expectGone(row("7"))
        expectShown(row("12"))
        expectShown(app.staticTexts["1 van 15"])

        app.terminate()
        launch()
        expectShown(row("12"))
        expectGone(row("7"))
    }

    // MARK: - Hiding the keyboard (#145)

    @MainActor
    func testKlaarAboveTheKeyboardHidesItFromTheNameAndTheNumberField() throws {
        launch()
        let done = app.buttons["spelers.keyboardDone"]

        tap(field("spelers.name"))
        expectShown(keyboard)
        expectShown(done)
        expectGone(app.buttons["spelers.keyboardSubmit"], "adding from the keyboard is offered on the number field")
        tap(done)
        expectGone(keyboard, "Klaar hides the keyboard from the name field")

        tap(field("spelers.number"))
        expectShown(keyboard)
        expectShown(app.buttons["spelers.keyboardSubmit"])
        tap(done)
        expectGone(keyboard, "Klaar hides the number pad, which has no return key")
        expectShown(app.staticTexts["spelers.empty"], "nothing was added")
    }

    @MainActor
    func testScrollingTheListDownHidesTheKeyboard() throws {
        try plant(players: (1...8).map { (id: $0, name: "Speler\($0)", number: String($0 + 10)) })
        launch()
        tap(field("spelers.name"))
        expectShown(keyboard)

        // A drag down through the list towards the keyboard (interactive dismissal).
        let list = app.collectionViews.firstMatch
        let from = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.2))
        let to = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 1.0))
        from.press(forDuration: 0.05, thenDragTo: to)
        expectGone(keyboard, "dragging the list down hides the keyboard")
    }

    @MainActor
    func testAddingFromTheKeyboardKeepsQuickEntry() throws {
        launch()
        replace(field("spelers.name"), with: "Lotte")
        replace(field("spelers.number"), with: "7")
        tap(app.buttons["spelers.keyboardSubmit"])

        expectRow("7", containing: "Lotte")
        expectValue(field("spelers.name"), "Voornaam", "the form is cleared after adding")
        XCTAssertTrue(waitUntil { self.hasFocus(self.field("spelers.name")) }, "the name field is ready for the next player")
        expectShown(keyboard, "the keyboard stays up for the next player")

        // The form only adds (#149): the keyboard's button adds the next player too.
        replace(field("spelers.name"), with: "Fien")
        replace(field("spelers.number"), with: "8")
        let add = app.buttons["spelers.keyboardSubmit"]
        expectShown(add)
        XCTAssertEqual(add.label, "Toevoegen")
        tap(add)
        expectRow("8", containing: "Fien")
        expectRow("7", containing: "Lotte")
    }

    @MainActor
    func testToevoegenStillFocusesTheNameForTheNextPlayer() throws {
        launch()
        add("Lotte", "7")
        expectRow("7", containing: "Lotte")
        XCTAssertTrue(waitUntil { self.hasFocus(self.field("spelers.name")) }, "quick entry: the name field is focused again")
        expectShown(keyboard)
    }

    // MARK: - Refusals, as the web app refuses them

    @MainActor
    func testEmptyNameTakenNumberAndBadNumberAreRefusedWithTheWebAppsMessages() throws {
        launch()
        addPlayer("Lotte", "7")

        // An empty name (spaces only count as empty).
        add("   ", "8")
        expectMessage("Vul een voornaam in.")
        expectGone(row("8"))

        // A number already taken.
        replace(field("spelers.name"), with: "Fien")
        replace(field("spelers.number"), with: "7")
        tap(submitButton)
        expectMessage("Rugnummer 7 is al van Lotte.")
        expectValue(field("spelers.name"), "Fien", "a refused entry stays in the form")

        // No number.
        replace(field("spelers.number"), with: "")
        tap(submitButton)
        expectMessage("Vul een rugnummer van 0 tot 99 in.")

        expectShown(app.staticTexts["1 van 15"])
        let players = try XCTUnwrap(try storedRoster()["players"] as? [[String: Any]])
        XCTAssertEqual(players.count, 1, "nothing refused was saved")

        // A good entry clears the message.
        replace(field("spelers.number"), with: "8")
        tap(submitButton)
        expectShown(row("8"))
        expectGone(app.staticTexts["spelers.message"])
    }

    @MainActor
    func testNameIsKeptAsTyped() throws {
        // Autocorrect (and with it spellcheck) is off for the name, as in the web app (#61). With autocorrect on,
        // the space after "Teh" would let the keyboard replace it.
        launch()
        add("Teh Lien", "3")
        expectRow("3", containing: "Teh Lien")
        let players = try XCTUnwrap(try storedRoster()["players"] as? [[String: Any]])
        XCTAssertEqual(players.first?["name"] as? String, "Teh Lien")
    }

    // MARK: - The 15-player limit

    @MainActor
    func testFifteenthPlayerFillsTheRosterAndASixteenthCannotBeAdded() throws {
        try plant(players: (1...14).map { (id: $0, name: "Speler\($0)", number: String($0 + 10)) })
        launch()
        expectShown(app.staticTexts["14 van 15"])

        add("Lotte", "7")
        expectShown(row("7"))
        expectShown(app.staticTexts["15 van 15"])

        // Full: the form gives way to the web app's message, so a 16th cannot be entered.
        let full = app.staticTexts["spelers.full"]
        expectShown(full)
        XCTAssertEqual(
            full.label, "Maximaal 15 spelers. Verwijder eerst een speler om er een toe te voegen."
        )
        expectGone(field("spelers.name"))
        expectGone(app.buttons["Toevoegen"])

        // Still full after a restart.
        app.terminate()
        launch()
        expectShown(app.staticTexts["spelers.full"])
        expectGone(field("spelers.name"))

        // Editing a player is still possible on a full roster, and the form stays away behind the sheet.
        tapInRow(app.buttons["spelers.edit.7"])
        expectShown(saveButton)
        replace(field("spelers.sheet.name"), with: "Lotje")
        tap(saveButton)
        expectGone(sheet)
        expectRow("7", containing: "Lotje")
        expectShown(app.staticTexts["spelers.full"])
        expectGone(field("spelers.name"))

        // Removing one makes room again.
        tapInRow(app.buttons["spelers.remove.7"])
        tap(app.alerts["#7 Lotje verwijderen?"].buttons["Verwijder"])
        expectShown(field("spelers.name"))
        expectShown(app.staticTexts["14 van 15"])
    }

    // MARK: - A missing or unreadable file

    @MainActor
    func testMissingFileStartsAnEmptyRoster() throws {
        XCTAssertFalse(FileManager.default.fileExists(atPath: rosterFile.path))
        launch()
        expectShown(app.staticTexts["spelers.empty"])
        expectShown(app.staticTexts["0 van 15"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: rosterFile.path), "nothing is written before a change")
    }

    @MainActor
    func testUnreadableFileStartsAnEmptyRosterAndIsReplacedOnTheNextChange() throws {
        try Data("{ dit is geen JSON".utf8).write(to: rosterFile)
        launch()
        expectShown(app.staticTexts["spelers.empty"])
        expectShown(app.staticTexts["0 van 15"])

        add("Lotte", "7")
        expectShown(row("7"))
        XCTAssertEqual(try storedRoster()["version"] as? Int, 1)
    }

    @MainActor
    func testUnknownVersionAndDamagedPlayersAreNotShown() throws {
        // A file from a later version is not guessed at.
        try JSONSerialization.data(withJSONObject: [
            "version": 99, "nextId": 2, "players": [["id": 1, "name": "Lotte", "number": "7"]],
        ]).write(to: rosterFile)
        launch()
        expectShown(app.staticTexts["spelers.empty"])
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
        expectShown(row("7"))
        expectGone(row("8"))
        expectGone(row("123"))
        expectShown(app.staticTexts["1 van 15"])
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
        expectShown(row("12"), "an id at the limit is kept")
        expectGone(row("7"), "an id above the limit is damaged and dropped")
        expectGone(row("9"), "an id below the negative limit is damaged and dropped")

        add("Mila", "4")
        expectShown(row("4"))
        let stored = try storedRoster()
        let players = try XCTUnwrap(stored["players"] as? [[String: Any]])
        let mila = try XCTUnwrap(players.first { $0["name"] as? String == "Mila" })
        XCTAssertEqual(mila["id"] as? Int, 1, "no id above the limit is free, so the smallest free one is used")
        XCTAssertEqual(stored["nextId"] as? Int, 2)

        app.terminate()
        launch()
        expectShown(row("4"))
        expectShown(row("12"))
    }

    @MainActor
    func testExtremeNextIdOnAnEmptyRosterStillAdds() throws {
        // A next id far above the limit: read as damaged, the first player gets id 1.
        try JSONSerialization.data(withJSONObject: ["version": 1, "nextId": Int.max, "players": []])
            .write(to: rosterFile)
        launch()
        add("Lotte", "7")
        expectShown(row("7"))
        var stored = try storedRoster()
        XCTAssertEqual((stored["players"] as? [[String: Any]])?.first?["id"] as? Int, 1)
        XCTAssertEqual(stored["nextId"] as? Int, 2)
        app.terminate()

        // A next id exactly at the limit is used, and the one after it wraps to a free small id, never overflowing.
        try JSONSerialization.data(withJSONObject: ["version": 1, "nextId": maxId, "players": []])
            .write(to: rosterFile)
        launch()
        addPlayer("Lotte", "7")
        addPlayer("Fien", "12")
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
        expectShown(app.staticTexts["spelers.empty"], "an unreadable storage folder starts empty")

        add("Lotte", "7")
        expectMessage("Opslaan lukte niet: de telefoon weigert opslag.")
        expectShown(row("7"), "the change stays on screen, as on the web, with the message saying it was not stored")
        XCTAssertEqual(try Data(contentsOf: blocked), Data("geen map".utf8), "nothing was written over the file")

        // A relaunch shows that nothing was stored.
        app.terminate()
        launch()
        expectShown(app.staticTexts["spelers.empty"])
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

    /// Adds a player and waits until she is listed and the form is empty again, so the next step starts from the
    /// settled screen.
    private func addPlayer(_ name: String, _ number: String) {
        add(name, number)
        expectRow(number, containing: name)
        expectValue(field("spelers.name"), "Voornaam", "the form is cleared after adding")
    }

    private func add(_ name: String, _ number: String) {
        replace(field("spelers.name"), with: name)
        replace(field("spelers.number"), with: number)
        tap(submitButton)
    }

    /// The form's Toevoegen / Bewaren button. Tapped by its identifier: while the number field is focused, the
    /// keyboard toolbar carries a button with the same label (#145).
    private var submitButton: XCUIElement { app.buttons["spelers.submit"] }

    /// The edit sheet (#149), found by its title.
    private var sheet: XCUIElement { app.navigationBars["Speler wijzigen"] }
    private var saveButton: XCUIElement { app.buttons["spelers.sheet.save"] }
    private var cancelButton: XCUIElement { app.buttons["spelers.sheet.cancel"] }

    /// Whether the element is on screen and can be tapped; false when the list has unloaded it.
    private func inView(_ element: XCUIElement) -> Bool { element.exists && element.isHittable }

    /// Hides the keyboard in the sheet with its Klaar button, when the keyboard is up.
    private func hideSheetKeyboard(file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["spelers.sheet.keyboardDone"]
        if done.exists {
            done.tap()
            expectGone(keyboard, "Klaar hides the keyboard in the sheet", file: file, line: line)
        }
    }

    /// Drags the sheet down by its title bar, as a coach closes it with a swipe.
    private func swipeSheetDown() {
        XCTAssertTrue(sheet.waitForExistence(timeout: Self.timeout))
        let from = sheet.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
        let to = from.withOffset(CGVector(dx: 0, dy: app.frame.height))
        from.press(forDuration: 0.05, thenDragTo: to)
    }

    /// The software keyboard, shown while a field is being edited.
    private var keyboard: XCUIElement { app.keyboards.firstMatch }

    /// Whether the text field has the keyboard focus.
    private func hasFocus(_ element: XCUIElement) -> Bool {
        (element.value(forKey: "hasKeyboardFocus") as? Bool) ?? false
    }

    /// Taps a button in a player's row. After Toevoegen the keyboard stays up (quick entry), and on a shorter screen
    /// such as the iPhone 17 Pro the keyboard toolbar covers the first rows, so a tap would land on the toolbar. Hide
    /// the keyboard with Klaar first, as a coach would (#145).
    private func tapInRow(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        let done = app.buttons["spelers.keyboardDone"]
        if done.exists {
            done.tap()
            expectGone(keyboard, "Klaar hides the keyboard before a row is tapped", file: file, line: line)
        }
        tap(element, file: file, line: line)
    }

    /// Taps an element once it is there, instead of failing at once when the screen is still catching up.
    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: Self.timeout), "\(element) never appeared", file: file, line: line)
        element.tap()
    }

    // MARK: - Waiting (a busy simulator is slow, so nothing is read the moment after a launch or tap)

    /// How long an element may take to appear, change or go away.
    private static let timeout: TimeInterval = 5

    /// Polls `condition` (every 0.1 s) until it holds or `timeout` has passed; true when it held.
    private func waitUntil(_ timeout: TimeInterval = SpelersUITests.timeout, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() >= deadline { return false }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        }
        return true
    }

    private func expectShown(
        _ element: XCUIElement, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForExistence(timeout: Self.timeout), "\(message) (\(element) never appeared)",
            file: file, line: line
        )
    }

    private func expectGone(
        _ element: XCUIElement, _ message: String = "", file: StaticString = #filePath, line: UInt = #line
    ) {
        XCTAssertTrue(
            element.waitForNonExistence(timeout: Self.timeout), "\(message) (\(element) is still there)",
            file: file, line: line
        )
    }

    /// Waits for a text field to hold `expected` (an empty field reads as its placeholder), then asserts it.
    private func expectValue(
        _ element: XCUIElement, _ expected: String, _ message: String = "",
        file: StaticString = #filePath, line: UInt = #line
    ) {
        _ = waitUntil { element.exists && element.value as? String == expected }
        XCTAssertEqual(element.value as? String, expected, message, file: file, line: line)
    }

    /// Waits for the validation message (under the add form, or `id`) to read `expected`, then asserts it.
    private func expectMessage(
        _ expected: String, in id: String = "spelers.message", file: StaticString = #filePath, line: UInt = #line
    ) {
        let text = app.staticTexts[id]
        _ = waitUntil { text.exists && text.label == expected }
        XCTAssertTrue(text.exists, "no message shown", file: file, line: line)
        XCTAssertEqual(text.label, expected, file: file, line: line)
    }

    /// Waits for the player's row to exist and, when given, to carry `name` in its label.
    private func expectRow(
        _ number: String, containing name: String? = nil, file: StaticString = #filePath, line: UInt = #line
    ) {
        let element = row(number)
        expectShown(element, "row \(number)", file: file, line: line)
        guard let name else { return }
        _ = waitUntil { element.exists && element.label.contains(name) }
        XCTAssertTrue(element.label.contains(name), "got \(element.label)", file: file, line: line)
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
