import Foundation
import Testing
import VervangingCore
@testable import Vervanging

/// The live screen's model and the match file (#102): every step is the engine's, the match is saved after every tap
/// and comes back the same after a relaunch, a second Wissel tap too soon counts once, undo takes back exactly the last
/// action, and the screen is kept awake only while the match runs.
@MainActor
struct LiveModelTests {
    let directory: URL
    let store: MatchStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MatchStore(directory: directory)
    }

    /// Twelve players numbered 1 to 12 (ids 1 to 12), the basisvijf 1 to 5, gelijke minuten.
    static func started(_ count: Int = 12, schedule: String = "equal", opponent: String = "",
                        at savedAt: Date = Date(timeIntervalSince1970: 1_795_000_000.123_456)) throws -> StartedMatch {
        let players = (1...count).map { Player(id: $0, name: "Speler\($0)", number: String($0)) }
        let plan = try Planner.makePlan(players: players.map(\.id), start: [1, 2, 3, 4, 5], schedule: schedule, seed: 7)
        return StartedMatch(savedAt: savedAt, opponent: opponent,
                            schedule: schedule, seed: 7, players: players, startingFive: [1, 2, 3, 4, 5], plan: plan)
    }

    /// A clock the test moves by hand; each read is the current value.
    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
        func advance(_ seconds: TimeInterval) { now += seconds }
    }

    func model(_ started: StartedMatch, clock: Clock = Clock()) -> LiveModel {
        LiveModel.start(started, store: store, now: { clock.now })
    }

    /// Taps Wissel `count` times, each well after the last.
    func wissel(_ model: LiveModel, _ clock: Clock, times count: Int) {
        for _ in 0..<count {
            clock.advance(1)
            model.tapWissel()
        }
    }

    // MARK: - Wissel and the minutes

    @Test func elevenWisselsAndEindeMatchGiveEveryPlayerSixteenFortyWithTwelvePlayers() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        #expect(model.blockTitle == "Blok 1 van 12")
        #expect(model.minutes.allSatisfy { $0.seconds == 0 }, "only finished blocks count (#54)")
        #expect(model.keepsScreenAwake)

        wissel(model, clock, times: 11)
        #expect(model.state.block == 12)
        #expect(model.isLastBlock)
        #expect(model.wisselLabel == "Einde match")
        #expect(model.subTimeText == "Laatste blok")
        #expect(model.nextChange == nil)

        wissel(model, clock, times: 1)
        #expect(model.state.ended)
        #expect(!model.isRunning)
        #expect(!model.keepsScreenAwake, "the screen may dim again after the end")
        #expect(model.minutes.count == 12)
        #expect(model.minutes.allSatisfy { $0.seconds == 1000 }, "every player 16:40")
        #expect(model.minutes.allSatisfy { !$0.onCourt })
    }

    @Test func theMinutesAreTheEnginesPlayedOverview() throws {
        let clock = Clock()
        let model = model(try Self.started(10), clock: clock)
        wissel(model, clock, times: 4)
        let expected = Dictionary(uniqueKeysWithValues: model.state.playedOverview.map { ($0.player, $0) })
        for row in model.minutes {
            #expect(row.seconds == expected[row.player.id]?.seconds)
            #expect(row.onCourt == expected[row.player.id]?.onCourt)
        }
        #expect(model.minutes.map(\.player.number) == (1...10).map(String.init), "by jersey number")
    }

    @Test func theScreenShowsTheEnginesBlockSubTimeCourtAndNextChange() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        #expect(model.subTimeText == "Wissel op 6:40")
        #expect(model.quarterText == "kwart 1")
        #expect(model.onCourt.map(\.id) == model.state.onCourt)
        let change = try #require(model.nextChange)
        let engine = try #require(model.state.nextChange)
        #expect(change.off.map(\.id) == engine.off)
        #expect(change.on.map(\.id) == engine.on)

        wissel(model, clock, times: 1)
        #expect(model.subTimeText == "Wissel op 3:20")
        wissel(model, clock, times: 1)
        #expect(model.subTimeText == "Einde kwart")
        wissel(model, clock, times: 1)
        #expect(model.blockTitle == "Blok 4 van 12")
        #expect(model.quarterText == "kwart 2")
    }

    @Test func aWisselSaysWhoCameOn() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        let on = try #require(model.nextChange).on
        wissel(model, clock, times: 1)
        let names = on.map(LiveModel.label).joined(separator: ", ")
        #expect(model.message == "Wissel gedaan: blok 2. Erin: \(names).")
        #expect(model.confirmed)
    }

    @Test func withFivePlayersAWisselNamesNobody() throws {
        let clock = Clock()
        let model = model(try Self.started(5), clock: clock)
        wissel(model, clock, times: 1)
        #expect(model.message == "Wissel gedaan: blok 2.")
    }

    // MARK: - Double tap and undo

    @Test func aSecondWisselTapWithinSixHundredMillisecondsCountsOnce() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        model.tapWissel()
        clock.advance(0.3)
        model.tapWissel()
        #expect(model.state.block == 2, "the second tap is ignored (#49)")
        clock.advance(0.29)
        model.tapWissel()
        #expect(model.state.block == 2, "still within 600 ms of the tap that counted")
        clock.advance(0.31)
        model.tapWissel()
        #expect(model.state.block == 3)
    }

    @Test func aDoubleTapOnTheLastButOneBlockDoesNotEndTheMatch() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        wissel(model, clock, times: 10)
        #expect(model.state.block == 11)
        clock.advance(1)
        model.tapWissel()
        clock.advance(0.1)
        model.tapWissel()
        #expect(model.state.block == 12)
        #expect(!model.state.ended)
    }

    @Test func undoTakesBackExactlyTheLastAction() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        #expect(!model.canUndo)
        wissel(model, clock, times: 2)
        let afterFirst = try MatchState.start(Self.started().plan,
                                              setupSavedAt: MatchStore.isoString(model.setup.savedAt)).wissel()
        model.undo()
        #expect(model.state.block == 2)
        #expect(model.state.grid == afterFirst.grid)
        #expect(model.message == "Ongedaan gemaakt.")
        #expect(!model.canUndo, "one step only (decision #17)")
        model.undo()
        #expect(model.state.block == 2)
    }

    @Test func undoOfTheEndKeepsTheScreenAwakeAgain() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        wissel(model, clock, times: 12)
        #expect(!model.keepsScreenAwake)
        model.undo()
        #expect(model.state.block == 12)
        #expect(model.isRunning)
        #expect(model.keepsScreenAwake)
    }

    // MARK: - Saved after every tap, restored on launch

    @Test func theMatchIsSavedAtStartAndAfterEveryTap() throws {
        let clock = Clock()
        let model = model(try Self.started(opponent: "Ajax"), clock: clock)
        #expect(store.load()?.state == model.state)
        for _ in 0..<3 {
            clock.advance(1)
            model.tapWissel()
            #expect(store.load()?.state == model.state)
        }
        model.undo()
        #expect(store.load()?.state == model.state)
    }

    @Test func aRelaunchRestoresTheSameBlockPlayersAndMinutes() throws {
        let clock = Clock()
        let model = model(try Self.started(opponent: "Ajax"), clock: clock)
        wissel(model, clock, times: 5)

        let loaded = try #require(store.load())
        let again = LiveModel(match: loaded, store: store)
        #expect(again.setup == model.setup)
        #expect(again.state == model.state)
        #expect(again.blockTitle == "Blok 6 van 12")
        #expect(again.onCourt == model.onCourt)
        #expect(again.minutes == model.minutes)
        #expect(again.canUndo, "undo survives a relaunch, as on the web")
        #expect(again.message.isEmpty)
    }

    @Test func theFileIsVersionedAndKeepsTheEnginesState() throws {
        let model = model(try Self.started())
        let data = try Data(contentsOf: store.fileURL)
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["version"] as? Int == 1)
        let state = try #require(object["state"] as? [String: Any])
        #expect(state["version"] as? Int == MatchState.currentVersion)
        #expect(state["setupSavedAt"] as? String == MatchStore.isoString(model.setup.savedAt))
        let setup = try #require(object["setup"] as? [String: Any])
        #expect(setup["savedAt"] as? String == "2026-11-18T11:06:40.123Z")
    }

    @Test func noFileOrADamagedOrUnknownFileGivesNoMatch() throws {
        #expect(store.load() == nil)
        try Data("{not json".utf8).write(to: store.fileURL)
        #expect(store.load() == nil)

        _ = model(try Self.started())
        var object = try storedObject()
        object["version"] = 2
        try write(object)
        #expect(store.load() == nil, "an unknown version is not read")
    }

    @Test func aDamagedSetupGivesNoMatch() throws {
        _ = model(try Self.started())
        var object = try storedObject()
        var setup = try #require(object["setup"] as? [String: Any])
        var plan = try #require(setup["plan"] as? [String: Any])
        var grid = try #require(plan["grid"] as? [[Int]])
        grid[3] = [1, 1, 2, 3, 4]
        plan["grid"] = grid
        setup["plan"] = plan
        object["setup"] = setup
        try write(object)
        #expect(store.load() == nil)
    }

    @Test func aDamagedOrForeignStateStartsTheSameMatchAgainAtBlockOne() throws {
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        wissel(model, clock, times: 3)

        var object = try storedObject()
        var state = try #require(object["state"] as? [String: Any])
        state["setupSavedAt"] = "2020-01-01T00:00:00.000Z"
        object["state"] = state
        try write(object)
        let foreign = try #require(store.load())
        #expect(foreign.state.block == 1, "a state from another setup is not restored")
        #expect(foreign.setup == model.setup)

        object["state"] = ["version": 2]
        try write(object)
        #expect(try #require(store.load()).state.block == 1)

        object.removeValue(forKey: "state")
        try write(object)
        #expect(try #require(store.load()).state == MatchState.start(model.setup.plan,
                                                                      setupSavedAt: MatchStore.isoString(model.setup.savedAt)))
    }

    /// #139: a start time in the year -100 has a key the formatter cannot read back, so after a relaunch the setup's
    /// date is a stand-in whose text is another one. The team history's id must stay the key the match is stored
    /// under, or the undo of the end after a relaunch would not find the entry it recorded.
    @Test func theHistoryIdIsTheMatchKeyAfterARelaunchAtAStartTimeInTheYearMinus100() throws {
        let time = Date(timeIntervalSince1970: -65_300_000_000.5)
        let key = MatchStore.isoString(time)
        #expect(key.hasPrefix("-"), "the year -100 is written with a sign: \(key)")
        #expect(MatchStore.date(key) == nil, "this start time does not read back, which is the case of #139")

        let clock = Clock()
        let model = model(try Self.started(at: time), clock: clock)
        wissel(model, clock, times: 12)
        #expect(model.state.ended)
        let history = HistoryStore(directory: directory)
        #expect(history.load().matches.map(\.id) == [JSString(key)], "recorded under the key")

        let loaded = try #require(store.load())
        #expect(loaded.state.setupSavedAt == key)
        #expect(MatchStore.isoString(loaded.setup.savedAt) != key, "the reloaded date alone no longer names the key")
        let again = LiveModel(match: loaded, store: store, now: { clock.now })
        #expect(again.message.isEmpty, "opening the end screen again writes nothing")
        #expect(history.load().matches.map(\.id) == [JSString(key)], "still once, under the key")

        again.undo()
        #expect(again.isRunning)
        #expect(history.load().matches.isEmpty, "the undo finds the entry by the key")
        clock.advance(1)
        again.tapWissel()
        #expect(history.load().matches.map(\.id) == [JSString(key)], "ending again counts it once")
    }

    @Test func aFailedWriteSaysSoAndKeepsPlaying() throws {
        // A folder where the file should be: the write cannot replace it.
        try FileManager.default.createDirectory(at: store.fileURL, withIntermediateDirectories: true)
        let clock = Clock()
        let model = model(try Self.started(), clock: clock)
        #expect(model.message == SetupModel.saveFailed)
        wissel(model, clock, times: 1)
        #expect(model.state.block == 2)
        #expect(model.message == SetupModel.saveFailed)
        #expect(!model.confirmed)
    }

    // MARK: - Helpers

    func storedObject() throws -> [String: Any] {
        let data = try Data(contentsOf: store.fileURL)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func write(_ object: [String: Any]) throws {
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
    }
}
