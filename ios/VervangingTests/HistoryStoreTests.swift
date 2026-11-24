import Foundation
import Testing
import VervangingCore
@testable import Vervanging

/// The team history on the phone (#104): the file is versioned and written only when a match ends (or the end is
/// undone, or it is cleared), a missing or unreadable file starts an empty history, the live screen records and repairs
/// it as the web app's `syncHistory` and `repairHistory` do, the Spelers screen shows the engine's season totals and
/// clears them, and the next setup with the switch on plans with that history.
@MainActor
struct HistoryStoreTests {
    let directory: URL
    let matchStore: MatchStore
    let historyStore: HistoryStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        matchStore = MatchStore(directory: directory)
        historyStore = HistoryStore(directory: directory)
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
    }

    /// Starts a match in the test folder and plays it to the end: every Wissel well after the last.
    func playedMatch(_ started: StartedMatch) -> LiveModel {
        let clock = Clock()
        let model = LiveModel.start(started, store: matchStore, now: { clock.now })
        while model.isRunning {
            clock.now += 1
            model.tapWissel()
        }
        return model
    }

    func modificationDate() throws -> Date? {
        try FileManager.default.attributesOfItem(atPath: historyStore.fileURL.path)[.modificationDate] as? Date
    }

    // MARK: - The file

    @Test func noFileGivesTheEmptyHistory() {
        #expect(!FileManager.default.fileExists(atPath: historyStore.fileURL.path))
        #expect(historyStore.load() == History())
    }

    @Test func anUnreadableDamagedOrUnknownFileGivesTheEmptyHistory() throws {
        for text in ["not json", "[]", "{\"matches\":[]}", "{\"version\":2,\"matches\":[{\"id\":\"a\",\"seconds\":{\"1\":60}}]}",
                     "{\"version\":\"1\",\"matches\":[{\"id\":\"a\",\"seconds\":{\"1\":60}}]}"] {
            try Data(text.utf8).write(to: historyStore.fileURL)
            #expect(historyStore.load() == History(), "\(text)")
        }
        // Bytes that are not text at all.
        try Data([0xff, 0xfe, 0x00, 0x7b]).write(to: historyStore.fileURL)
        #expect(historyStore.load() == History())
        // A folder where the file should be.
        try FileManager.default.removeItem(at: historyStore.fileURL)
        try FileManager.default.createDirectory(at: historyStore.fileURL, withIntermediateDirectories: true)
        #expect(historyStore.load() == History())
    }

    @Test func theFileIsVersionedInTheEnginesShapeAndRoundTrips() throws {
        let history = History(clearedAt: "2026-11-01T10:00:00.000Z", matches: [
            HistoryMatch(id: "2026-11-23T10:15:00.123Z", seconds: ["1": 1000, "2": 600], extra: ["2": 200]),
        ])
        #expect(historyStore.save(history))
        let text = try String(contentsOf: historyStore.fileURL, encoding: .utf8)
        #expect(text == "{\"version\":1,\"useHistory\":false,\"clearedAt\":\"2026-11-01T10:00:00.000Z\",\"matches\":"
            + "[{\"id\":\"2026-11-23T10:15:00.123Z\",\"seconds\":{\"1\":1000,\"2\":600},\"extra\":{\"2\":200}}]}")
        #expect(historyStore.load() == history)
    }

    @Test func aDamagedEntryIsDroppedAndTheRestKept() throws {
        try Data(("{\"version\":1,\"matches\":[{\"id\":\"\",\"seconds\":{\"1\":60}},"
            + "{\"id\":\"b\",\"seconds\":{\"1\":120,\"x\":5}}]}").utf8).write(to: historyStore.fileURL)
        #expect(historyStore.load().matches == [HistoryMatch(id: "b", seconds: ["1": 120])])
    }

    @Test func aFailedWriteSaysFalse() throws {
        try FileManager.default.createDirectory(at: historyStore.fileURL, withIntermediateDirectories: true)
        #expect(!historyStore.save(History()))
    }

    // MARK: - The live screen keeps it

    @Test func theFileIsWrittenOnlyWhenTheMatchEnds() throws {
        let clock = Clock()
        let model = LiveModel.start(try LiveModelTests.started(), store: matchStore, now: { clock.now })
        while !model.isLastBlock {
            clock.now += 1
            model.tapWissel()
            #expect(!FileManager.default.fileExists(atPath: historyStore.fileURL.path), "no write before the end")
        }
        clock.now += 1
        model.tapWissel()
        #expect(model.state.ended)
        let history = historyStore.load()
        #expect(history.matches.count == 1)
        #expect(history.matches[0].id == JSString(MatchStore.isoString(model.setup.savedAt)))
    }

    @Test func theEndRecordsTheEnginesMinutesWhichTheEndScreenShows() throws {
        let model = playedMatch(try LiveModelTests.started())
        let match = try #require(historyStore.load().matches.first)
        #expect(match.extra == nil)
        for (id, seconds) in model.state.minutesSoFar { #expect(match.seconds[String(id)] == Double(seconds)) }
        for row in model.minutes { #expect(match.seconds[String(row.player.id)] == Double(row.seconds)) }
        #expect(model.minutes.allSatisfy { $0.seconds == 1000 }, "12 players, 12 blocks of 3:20: 16:40 each")
    }

    @Test func extraMinutenAreKeptApart() throws {
        let clock = Clock()
        let model = LiveModel.start(try LiveModelTests.started(), store: matchStore, now: { clock.now })
        let keep = try #require(model.zoneCandidates.first)
        model.chooseZone(keep)
        model.setExtra(true)
        while model.isRunning {
            clock.now += 1
            model.tapWissel()
        }
        let match = try #require(historyStore.load().matches.first)
        #expect(match.extra == [String(keep.id): Double(model.setup.plan.blockSeconds)])
    }

    @Test func undoOfTheEndTakesTheMatchOutAndEndingAgainCountsItOnce() throws {
        let clock = Clock()
        let model = LiveModel.start(try LiveModelTests.started(), store: matchStore, now: { clock.now })
        while model.isRunning {
            clock.now += 1
            model.tapWissel()
        }
        #expect(historyStore.load().matches.count == 1)
        model.undo()
        #expect(model.isRunning)
        #expect(historyStore.load().matches.isEmpty)
        clock.now += 1
        model.tapWissel()
        #expect(model.state.ended)
        #expect(historyStore.load().matches.count == 1)
    }

    @Test func aRelaunchOfTheEndScreenWritesNothing() throws {
        let model = playedMatch(try LiveModelTests.started())
        let before = try modificationDate()
        let stored = try #require(matchStore.load())
        let again = LiveModel(match: stored, store: matchStore)
        #expect(!again.isRunning)
        #expect(again.message.isEmpty)
        #expect(try modificationDate() == before)
        #expect(historyStore.load().matches.count == 1)
        _ = model
    }

    @Test func openingAnEndedMatchMissingFromTheHistoryRecordsIt() throws {
        let model = playedMatch(try LiveModelTests.started())
        try FileManager.default.removeItem(at: historyStore.fileURL)
        _ = LiveModel(match: LiveMatch(setup: model.setup, state: model.state), store: matchStore)
        #expect(historyStore.load().matches.count == 1)
    }

    @Test func openingAnEndedMatchStartedBeforeWisGeschiedenisDoesNotRefillIt() throws {
        let model = playedMatch(try LiveModelTests.started())
        let cleared = historyStore.load().cleared(at: MatchStore.isoString(model.setup.savedAt.addingTimeInterval(60)))
        #expect(historyStore.save(cleared))
        _ = LiveModel(match: LiveMatch(setup: model.setup, state: model.state), store: matchStore)
        #expect(historyStore.load().matches.isEmpty)
    }

    @Test func openingARunningMatchStillInTheHistoryTakesItOut() throws {
        let model = playedMatch(try LiveModelTests.started())
        _ = LiveModel(match: LiveMatch(setup: model.setup, state: model.state.undo()), store: matchStore)
        #expect(historyStore.load().matches.isEmpty)
    }

    @Test func aFailedHistoryWriteAtTheEndSaysSo() throws {
        try FileManager.default.createDirectory(at: historyStore.fileURL, withIntermediateDirectories: true)
        let model = playedMatch(try LiveModelTests.started())
        #expect(!model.isRunning)
        #expect(model.message == SetupModel.saveFailed)
    }

    // MARK: - Spelers: season totals and Wis geschiedenis

    func roster(_ count: Int = 12) -> RosterStore {
        let store = RosterStore(directory: directory)
        var roster = Roster.empty
        for n in 1...count { roster = roster.adding(name: "Speler\(n)", number: String(n)) }
        store.save(roster)
        return store
    }

    @Test func theSeasonTotalsAreTheEnginesAndShowOneMatch() throws {
        let store = roster()
        let spelers = SpelersModel(store: store)
        #expect(spelers.season.matches == 0)
        #expect(SpelersModel.seasonNote(spelers.season.matches) == "Speeltijd dit seizoen: nog geen matchen bewaard.")
        #expect(spelers.roster.players.allSatisfy { spelers.seasonSeconds($0) == 0 })

        let model = playedMatch(try LiveModelTests.started())
        spelers.reloadHistory()
        #expect(spelers.season == historyStore.load().seasonSummary())
        #expect(SpelersModel.seasonNote(spelers.season.matches) == "Speeltijd dit seizoen, over 1 bewaarde match.")
        for row in model.minutes {
            let player = try #require(spelers.roster.players.first { $0.id == row.player.id })
            #expect(spelers.seasonSeconds(player) == row.seconds)
        }
        #expect(SpelersModel.seasonNote(3) == "Speeltijd dit seizoen, over 3 bewaarde matchen.")
    }

    @Test func wisGeschiedenisResetsTheTotalsAndRemembersWhen() throws {
        let store = roster()
        _ = playedMatch(try LiveModelTests.started())
        let spelers = SpelersModel(store: store)
        #expect(spelers.season.matches == 1)
        let now = Date(timeIntervalSince1970: 1_796_000_000)
        spelers.clearHistory(now: now)
        #expect(spelers.season.matches == 0)
        #expect(spelers.roster.players.allSatisfy { spelers.seasonSeconds($0) == 0 })
        #expect(spelers.historyMessage == "Geschiedenis gewist.")
        #expect(!spelers.historyFailed)
        let stored = historyStore.load()
        #expect(stored.matches.isEmpty)
        #expect(stored.clearedAt == MatchStore.isoString(now))
    }

    @Test func aFailedClearSaysSoAndKeepsTheTotals() throws {
        let store = roster()
        _ = playedMatch(try LiveModelTests.started())
        let spelers = SpelersModel(store: store)
        try FileManager.default.removeItem(at: historyStore.fileURL)
        try FileManager.default.createDirectory(at: historyStore.fileURL, withIntermediateDirectories: true)
        spelers.clearHistory()
        #expect(spelers.season.matches == 1)
        #expect(spelers.historyMessage == SetupModel.saveFailed)
        #expect(spelers.historyFailed)
    }

    @Test func aSeasonTotalIsMinutesAndSecondsOrHoursFromAnHourOn() {
        #expect(SpelersModel.formatDuration(0) == "0:00")
        #expect(SpelersModel.formatDuration(1000) == "16:40")
        #expect(SpelersModel.formatDuration(3599) == "59:59")
        #expect(SpelersModel.formatDuration(3600) == "1:00:00")
        #expect(SpelersModel.formatDuration(5000) == "1:23:20")
    }

    // MARK: - The next setup

    @Test func theNextSetupWithTheSwitchOnPlansWithTheStoredHistory() throws {
        // A first match with 11 players: 60 places over 11 leaves five uneven places, so the totals differ.
        let first = try LiveModelTests.started(11)
        _ = playedMatch(first)
        let stored = historyStore.load()
        #expect(stored.matches.count == 1)

        let rosterStore = roster(11)
        let setupStore = SetupStore(directory: directory)
        setupStore.save(LastSetup(useHistory: true, attendance: nil, startingFive: [1, 2, 3, 4, 5]))
        let setup = SetupModel(roster: rosterStore.load(), store: setupStore, matches: stored.matches, newSeed: { 7 })
        #expect(setup.history.useHistory)
        #expect(setup.history.matches == stored.matches)
        let expected = try SetupModel.makePlan(players: setup.presentIds, start: [1, 2, 3, 4, 5], schedule: "equal",
                                               seed: 7, history: History(useHistory: true, matches: stored.matches))
        #expect(setup.plan == expected)
        // The players who got an uneven place in the first match get no more planned minutes than the others now.
        let totals = stored.totalSeconds()
        let most = totals.entries.map(\.value).max()!
        let planned = Planner.planStats(try #require(setup.plan)).minutes
        let ahead = setup.presentIds.filter { totals[String($0)] == most }
        let behind = setup.presentIds.filter { totals[String($0)] != most }
        #expect(!ahead.isEmpty && !behind.isEmpty)
        #expect(ahead.map { planned[$0] ?? 0 }.max()! <= behind.map { planned[$0] ?? 0 }.min()!)
    }
}
