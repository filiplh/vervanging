import Foundation
import Testing
import VervangingCore
@testable import Vervanging

/// The match setup's model (#101): the plan it shows is exactly the Swift planner's output for the same inputs, swaps
/// are the planner's swaps, and the last match's attendance and basisvijf come back on the next setup.
@MainActor
struct SetupModelTests {
    let directory: URL
    let store: SetupStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = SetupStore(directory: directory)
    }

    /// Twelve players with numbers that do not sort the same as their ids, so the order the planner gets is tested.
    static func roster(_ count: Int = 12) -> Roster {
        var roster = Roster.empty
        for i in 0..<count { roster = roster.adding(name: "Speler\(i + 1)", number: String((i * 7) % 50)) }
        return roster
    }

    /// The present ids in roster order by jersey number, as the web app's `replan` hands them to the planner.
    static func idsByNumber(_ roster: Roster, present: Set<Int>? = nil) -> [Int] {
        roster.players.sorted(by: SpelersModel.byNumber).map(\.id).filter { present?.contains($0) ?? true }
    }

    func model(_ roster: Roster, matches: [HistoryMatch] = [], seed: Int = 4242) -> SetupModel {
        SetupModel(roster: roster, store: store, matches: matches, newSeed: { seed })
    }

    func pickFive(_ model: SetupModel, _ ids: [Int]) {
        for id in ids { model.toggleStart(id) }
    }

    // MARK: - The plan is the planner's

    @Test func planEqualsThePlannersOutputWithTheSwitchOff() throws {
        let roster = Self.roster()
        let model = model(roster)
        #expect(model.plan == nil, "no basisvijf yet, so no plan")
        let five = Array(roster.players.map(\.id).suffix(5))
        pickFive(model, five)

        let expected = try Planner.makePlan(players: Self.idsByNumber(roster), start: five, schedule: "equal", seed: 4242)
        #expect(model.plan == expected)
        // Every player 5 blocks of 3:20 with 12 present (the plan's success criterion).
        for row in model.rows {
            #expect(row.plays.filter { $0 }.count == 5)
            #expect(row.seconds == 1000)
        }
        #expect(model.rows.count == 12)
        #expect(model.rows.allSatisfy { $0.plays.count == 12 })
    }

    @Test func planEqualsThePlannersOutputForTheFiveMinuteSchedule() throws {
        let roster = Self.roster(9)
        let model = model(roster, seed: 77)
        let five = Array(roster.players.map(\.id).prefix(5))
        pickFive(model, five)
        model.setSchedule("five")

        let expected = try Planner.makePlan(players: Self.idsByNumber(roster), start: five, schedule: "five", seed: 77)
        #expect(model.plan == expected)
        #expect(model.plan?.blocks == 8)
    }

    @Test func planEqualsThePlannersOutputWithTheHistorySwitchOn() throws {
        let roster = Self.roster()
        let ids = roster.players.map(\.id)
        // Two players far behind: catch-up moves blocks to them.
        var seconds = JSObject<Double>()
        for id in ids { seconds[String(id)] = id <= 2 ? 0 : 3000 }
        let matches = [HistoryMatch(id: "m1", seconds: seconds), HistoryMatch(id: "m2", seconds: seconds)]
        let model = model(roster, matches: matches, seed: 9)
        let five = Array(ids.suffix(5))
        pickFive(model, five)
        model.setUseHistory(true)

        let history = History(useHistory: true, matches: matches)
        let players = Self.idsByNumber(roster)
        let catchUp = history.catchUp(players, schedule: Planner.schedules["equal"]!, seed: 9)
        #expect(!catchUp.moves.isEmpty, "the history must give moves, or this test proves nothing")
        let expected = try Planner.makePlan(players: players, start: five, schedule: "equal", seed: 9,
                                            extraPriority: catchUp.priority, moves: catchUp.moves)
        #expect(model.plan == expected)
        let plain = try Planner.makePlan(players: players, start: five, schedule: "equal", seed: 9)
        #expect(model.plan != plain, "the switch changes the plan")

        model.setUseHistory(false)
        #expect(model.plan == plain)
    }

    @Test func absentPlayersAreLeftOutOfThePlan() throws {
        let roster = Self.roster()
        let model = model(roster)
        let ids = roster.players.map(\.id)
        model.togglePresent(ids[0])
        model.togglePresent(ids[1])
        let five = Array(ids.suffix(5))
        pickFive(model, five)
        let present = Set(ids.dropFirst(2))
        let expected = try Planner.makePlan(players: Self.idsByNumber(roster, present: present), start: five,
                                            schedule: "equal", seed: 4242)
        #expect(model.plan == expected)
    }

    @Test func anotherPlanUsesTheNewSeed() throws {
        let roster = Self.roster()
        var seeds = [5, 6]
        let model = SetupModel(roster: roster, store: store, newSeed: { seeds.removeFirst() })
        let five = Array(roster.players.map(\.id).suffix(5))
        pickFive(model, five)
        #expect(model.plan == (try Planner.makePlan(players: Self.idsByNumber(roster), start: five, seed: 5)))
        model.anotherPlan()
        #expect(model.seed == 6)
        #expect(model.plan == (try Planner.makePlan(players: Self.idsByNumber(roster), start: five, seed: 6)))
    }

    // MARK: - Swaps

    @Test func swapIsThePlannersSwapAndTheRowsFollow() throws {
        let roster = Self.roster(9)
        let model = model(roster, seed: 3)
        let ids = roster.players.map(\.id)
        pickFive(model, Array(ids.prefix(5)))
        model.setSchedule("five")
        let before = try #require(model.plan)
        let a = ids[6], b = ids[8]

        model.tapRow(a)
        #expect(model.selected == a)
        #expect(model.message == "#\(roster.players[6].number) Speler7 gekozen. Tik de speler aan om mee te ruilen.")
        model.tapRow(b)
        #expect(model.selected == nil)
        #expect(model.plan == (try Planner.swapPlayers(before, a, b)))
        #expect(model.message == "Speler7 en Speler9 geruild.")

        let rowsBefore = SetupModel.rows(before, players: model.players)
        let rowA = try #require(model.rows.first { $0.id == a })
        let oldB = try #require(rowsBefore.first { $0.id == b })
        #expect(rowA.plays == oldB.plays)
        #expect(rowA.seconds == oldB.seconds)
    }

    @Test func swapOfAStarterWithABenchPlayerIsRefused() throws {
        let roster = Self.roster(8)
        let model = model(roster)
        let ids = roster.players.map(\.id)
        pickFive(model, Array(ids.prefix(5)))
        let before = model.plan
        model.tapRow(ids[0])
        model.tapRow(ids[7])
        #expect(model.plan == before)
        let p0 = roster.players[0], p7 = roster.players[7]
        #expect(model.message == "Wissel #\(p0.number) \(p0.name) en #\(p7.number) \(p7.name) kan niet: de ene staat in de basisvijf en de andere niet.")
    }

    @Test func rowsShowTheGridAndPlanStats() throws {
        let roster = Self.roster(10)
        let model = model(roster)
        let ids = roster.players.map(\.id)
        pickFive(model, [ids[9], ids[3], ids[5], ids[1], ids[7]])
        let plan = try #require(model.plan)
        let stats = Planner.planStats(plan)
        for row in model.rows {
            #expect(row.plays == plan.grid.map { $0.contains(row.id) })
            #expect(row.seconds == stats.minutes[row.id])
        }
        // The basisvijf first, each part by number.
        let starters = model.rows.prefix(5).map(\.player)
        #expect(Set(starters.map(\.id)) == Set(plan.start))
        #expect(starters == starters.sorted(by: SpelersModel.byNumber))
        let others = model.rows.dropFirst(5).map(\.player)
        #expect(others == others.sorted(by: SpelersModel.byNumber))
    }

    // MARK: - Refusals

    @Test func noPlanAndNoStartWithTooFewPresentOrAnIncompleteBasisvijf() {
        let roster = Self.roster(6)
        let model = model(roster)
        let ids = roster.players.map(\.id)
        #expect(model.missing == "Kies precies 5 spelers voor de basisvijf om het plan te zien.")
        pickFive(model, Array(ids.prefix(4)))
        #expect(!model.canStart)
        #expect(model.startMatch() == nil)
        model.togglePresent(ids[4])
        model.togglePresent(ids[5])
        #expect(model.missing == "Vink minstens 5 aanwezige spelers aan.")
        #expect(!model.canToggleStart(ids[4]), "an absent player cannot be in the basisvijf")
    }

    // MARK: - The last setup

    @Test func startSavesAttendanceAndBasisvijfAndTheNextSetupPreTicksThem() throws {
        let roster = Self.roster(8)
        let ids = roster.players.map(\.id)
        let first = model(roster)
        first.togglePresent(ids[2])
        let five = [ids[7], ids[0], ids[4], ids[5], ids[6]]
        pickFive(first, five)
        first.opponent = "  Gent  "
        let match = try #require(first.startMatch())
        #expect(match.opponent == "Gent")
        #expect(match.startingFive == five.sorted())
        #expect(match.plan == first.plan)
        #expect(store.load() == LastSetup(useHistory: false, attendance: ids.filter { $0 != ids[2] },
                                          startingFive: five.sorted()))

        let next = model(roster)
        #expect(next.present == Set(ids.filter { $0 != ids[2] }))
        #expect(Set(next.start) == Set(five))
        #expect(next.plan != nil, "a remembered basisvijf shows its plan at once")
    }

    @Test func aRememberedStarterWhoIsNoLongerOnTheRosterDropsOut() {
        let roster = Self.roster(8)
        let ids = roster.players.map(\.id)
        store.save(LastSetup(useHistory: true, attendance: ids + [999], startingFive: [ids[0], ids[1], ids[2], ids[3], 999]))
        let model = model(roster)
        #expect(model.present == Set(ids))
        #expect(model.start == [ids[0], ids[1], ids[2], ids[3]])
        #expect(model.plan == nil)
        #expect(model.history.useHistory)
    }

    @Test func aDamagedBasisvijfGivesNobody() {
        #expect(SetupModel.initialStartingFive([1, 2, 3, 4, 5, 6], [1, 2, 3]) == [])
        #expect(SetupModel.initialStartingFive([1, 2, 3, 4, 5, 6], [1, 1, 2, 3, 4]) == [])
        #expect(SetupModel.initialStartingFive([1, 2, 3, 4, 6], [1, 2, 3, 4, 5]) == [1, 2, 3, 4])
        #expect(SetupModel.initialAttendance(Self.roster(3), nil) == [1, 2, 3])
        #expect(SetupModel.initialAttendance(Self.roster(3), [3, 1, 7]) == [1, 3])
    }

    @Test func theSwitchIsRemembered() {
        let roster = Self.roster(6)
        model(roster).setUseHistory(true)
        #expect(store.load().useHistory)
        #expect(model(roster).history.useHistory)
    }

    @Test func aFailedSaveSaysSo() throws {
        let blocked = directory.appendingPathComponent("geen-map")
        try Data("x".utf8).write(to: blocked)
        let model = SetupModel(roster: Self.roster(6), store: SetupStore(directory: blocked), newSeed: { 1 })
        model.setUseHistory(true)
        #expect(model.message == "Opslaan lukte niet: de telefoon weigert opslag.")
        pickFive(model, Array(model.roster.players.map(\.id).prefix(5)))
        #expect(model.startMatch() == nil)
        #expect(model.message == "Opslaan lukte niet: de telefoon weigert opslag.")
    }

    // MARK: - The setup file

    @Test func missingDamagedOrUnknownFilesReadAsNoLastSetup() throws {
        #expect(store.load() == .none)
        try Data("{ geen json".utf8).write(to: store.fileURL)
        #expect(store.load() == .none)
        try Data(#"{"version":2,"useHistory":true}"#.utf8).write(to: store.fileURL)
        #expect(store.load() == .none)
        try Data(#"{"version":1,"useHistory":"ja","attendance":[1,"twee",3.5,4],"startingFive":7}"#.utf8)
            .write(to: store.fileURL)
        #expect(store.load() == LastSetup(useHistory: false, attendance: [1, 4], startingFive: []))
    }

    @Test func theFileRoundTrips() throws {
        let setup = LastSetup(useHistory: true, attendance: [3, 1, 2], startingFive: [1, 2, 3, 4, 5])
        #expect(store.save(setup))
        #expect(store.load() == setup)
        let text = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(text == #"{"attendance":[3,1,2],"startingFive":[1,2,3,4,5],"useHistory":true,"version":1}"#)
    }

    @Test func minutesAreWrittenAsTheWebAppWritesThem() {
        #expect(formatSeconds(1000) == "16:40")
        #expect(formatSeconds(200) == "3:20")
        #expect(formatSeconds(0) == "0:00")
    }
}
