import Foundation
import Observation
import VervangingCore

/// A match the coach has just started from setup: what the live screen (#102) plays.
struct StartedMatch: Equatable, Sendable {
    var savedAt: Date
    var opponent: String
    var schedule: String
    var seed: Int
    var players: [Player]
    var startingFive: [Int]
    var plan: Plan
}

/// One row of the plan grid as the screen draws it: the player, whether they play each block, and their planned
/// minutes in seconds.
struct PlanRow: Equatable, Identifiable, Sendable {
    var player: Player
    var plays: [Bool]
    var seconds: Int
    var id: Int { player.id }
}

/// The match setup's state (plan decisions #7, #10, #19, #20; `setupScreen` in `public/js/setup.js`): who is present,
/// the basisvijf, the schema, the history switch, the opponent, and the plan with its swaps.
///
/// The model never computes a plan itself: every plan comes from `Planner.makePlan` (with the history's `catchUp` when
/// the switch is on) and every swap from `Planner.swapPlayers`, so the grid is exactly what the Swift rules give.
@MainActor
@Observable
final class SetupModel {
    static let onCourt = Planner.onCourt
    static let saveFailed = String(localized: "Opslaan lukte niet: de telefoon weigert opslag.")

    /// The roster this setup was opened with, and its players by jersey number (as the web app lists them).
    let roster: Roster
    let players: [Player]
    private(set) var present: Set<Int>
    private(set) var start: [Int]
    private(set) var schedule = "equal"
    var opponent = ""
    private(set) var seed: Int
    private(set) var history: History
    private(set) var plan: Plan?
    private(set) var selected: Int?
    var message = ""

    @ObservationIgnored private let store: SetupStore
    @ObservationIgnored private var lastSetup: LastSetup
    @ObservationIgnored private let newSeed: () -> Int

    /// `matches` is the team history (empty until #104 stores it); the switch comes from the setup file. `newSeed`
    /// gives the seed for the first plan and for every "Ander plan".
    init(roster: Roster, store: SetupStore, matches: [HistoryMatch] = [], newSeed: @escaping () -> Int = SetupModel.randomSeed) {
        self.roster = roster
        self.store = store
        self.newSeed = newSeed
        players = roster.players.sorted(by: SpelersModel.byNumber)
        let last = store.load()
        lastSetup = last
        let present = Self.initialAttendance(roster, last.attendance)
        self.present = Set(present)
        start = Self.initialStartingFive(present, last.startingFive)
        seed = newSeed()
        history = History(useHistory: last.useHistory, matches: matches)
        // A remembered basisvijf of five shows its plan at once, as on the web.
        replan()
    }

    // MARK: - Rules of the screen (ported from setup.js)

    /// Who is ticked present when setup opens: the last match's selection, or everyone when there is none yet
    /// (`initialAttendance`).
    static func initialAttendance(_ roster: Roster, _ last: [Int]?) -> [Int] {
        let ids = roster.players.map(\.id)
        guard let last else { return ids }
        return ids.filter { last.contains($0) }
    }

    /// Who is in the basisvijf when setup opens (#56): the last match's basisvijf, keeping only the players present now
    /// (`initialStartingFive`). A stored basisvijf that is not five different players is damaged and gives nobody, as
    /// the web app's `normaliseMatchSetup` refuses it.
    static func initialStartingFive(_ present: [Int], _ last: [Int]) -> [Int] {
        guard last.count == onCourt, Set(last).count == onCourt else { return [] }
        let present = Set(present)
        return last.filter { present.contains($0) }
    }

    /// The plan for these inputs, as the web app's `replan` asks for it: the present players in roster order by
    /// number, the basisvijf, the schema and the seed, plus the history's catch-up when the switch is on.
    nonisolated static func makePlan(players: [Int], start: [Int], schedule: String, seed: Int, history: History)
        throws(PlanError) -> Plan {
        var priority: [Int] = []
        var moves: [[Int]] = []
        if history.useHistory, let shape = Planner.schedules[schedule] {
            let catchUp = history.catchUp(players, schedule: shape, seed: seed)
            priority = catchUp.priority
            moves = catchUp.moves
        }
        return try Planner.makePlan(players: players, start: start, schedule: schedule, seed: seed,
                                    extraPriority: priority, moves: moves)
    }

    /// The grid rows of a plan: the basisvijf first, then the others, each part by number (`planGrid`); a row plays a
    /// block when the plan has the player on court in it, and its minutes are `planStats`'.
    nonisolated static func rows(_ plan: Plan, players: [Player]) -> [PlanRow] {
        let stats = Planner.planStats(plan)
        let byId = Dictionary(players.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let starters = plan.start.compactMap { byId[$0] }.sorted(by: SpelersModel.byNumber)
        let others = plan.players.filter { !plan.start.contains($0) }.compactMap { byId[$0] }
            .sorted(by: SpelersModel.byNumber)
        return (starters + others).map { p in
            PlanRow(player: p, plays: plan.grid.map { $0.contains(p.id) }, seconds: stats.minutes[p.id] ?? 0)
        }
    }

    /// The present players' ids, in the order the planner gets them.
    var presentIds: [Int] { players.filter { present.contains($0.id) }.map(\.id) }

    var rows: [PlanRow] { plan.map { Self.rows($0, players: players) } ?? [] }

    /// Why there is no plan yet, in the web app's words; nil when there is one or the planner refused.
    var missing: String? {
        if present.count < Self.onCourt { return String(localized: "Vink minstens \(Self.onCourt) aanwezige spelers aan.") }
        if plan == nil && start.count != Self.onCourt {
            return String(localized: "Kies precies \(Self.onCourt) spelers voor de basisvijf om het plan te zien.")
        }
        return nil
    }

    var canStart: Bool { plan != nil }

    func isPresent(_ id: Int) -> Bool { present.contains(id) }
    func isStarter(_ id: Int) -> Bool { start.contains(id) }
    /// The basisvijf button is off for an absent player, and for anyone else once five are picked.
    func canToggleStart(_ id: Int) -> Bool { present.contains(id) && (start.contains(id) || start.count < Self.onCourt) }

    // MARK: - Actions

    func togglePresent(_ id: Int) {
        if present.contains(id) {
            present.remove(id)
            start.removeAll { $0 == id }
        } else {
            present.insert(id)
        }
        message = ""
        replan()
    }

    func toggleStart(_ id: Int) {
        if start.contains(id) {
            start.removeAll { $0 == id }
        } else if start.count < Self.onCourt && present.contains(id) {
            start.append(id)
        }
        message = ""
        replan()
    }

    func setSchedule(_ name: String) {
        guard Planner.schedules[name] != nil, name != schedule else { return }
        schedule = name
        message = ""
        replan()
    }

    /// The history switch, remembered in the setup file (the web app remembers it with the history).
    func setUseHistory(_ on: Bool) {
        guard on != history.useHistory else { return }
        message = ""
        history.useHistory = on
        var next = lastSetup
        next.useHistory = on
        if store.save(next) { lastSetup = next } else { message = Self.saveFailed }
        replan()
    }

    /// "Ander plan": a new seed, so a new plan for the same choices.
    func anotherPlan() {
        seed = newSeed()
        message = ""
        replan()
    }

    /// A tap on a grid row: the first picks a player, the second swaps the two rows, a tap on the picked row lets go.
    func tapRow(_ id: Int) {
        guard let plan else { return }
        guard let first = selected else {
            selected = id
            swapMessage(String(localized: "\(label(id)) gekozen. Tik de speler aan om mee te ruilen."))
            return
        }
        selected = nil
        if first == id {
            swapMessage("")
            return
        }
        do {
            self.plan = try Planner.swapPlayers(plan, first, id)
            message = String(localized: "\(name(first)) en \(name(id)) geruild.")
        } catch {
            swapMessage(String(localized: "Wissel \(label(first)) en \(label(id)) kan niet: \(swapRefusal(plan, first, id))."))
        }
    }

    /// Saves who is present and the basisvijf for the next setup, and gives the match to start; nil while there is no
    /// plan, or when saving failed (the message then says so).
    func startMatch(now: Date = .now) -> StartedMatch? {
        guard let plan else { return nil }
        var next = lastSetup
        next.attendance = roster.players.map(\.id).filter { present.contains($0) }
        next.startingFive = plan.start
        guard store.save(next) else {
            message = Self.saveFailed
            return nil
        }
        lastSetup = next
        return StartedMatch(savedAt: now, opponent: opponent.trimmingCharacters(in: .whitespacesAndNewlines),
                            schedule: schedule, seed: seed, players: players.filter { present.contains($0.id) },
                            startingFive: plan.start, plan: plan)
    }

    // MARK: - Helpers

    private func replan() {
        selected = nil
        plan = nil
        guard start.count == Self.onCourt, present.count >= Self.onCourt else { return }
        do {
            plan = try Self.makePlan(players: presentIds, start: start, schedule: schedule, seed: seed, history: history)
        } catch {
            message = String(localized: "Er kon geen plan gemaakt worden. Probeer „Ander plan”.")
        }
    }

    private func player(_ id: Int) -> Player? { players.first { $0.id == id } }
    /// A player as the plan grid writes them: "#4 Lotte".
    private func label(_ id: Int) -> String { player(id).map { "#\($0.number) \($0.name)" } ?? "" }
    private func name(_ id: Int) -> String { player(id)?.name ?? "" }

    /// Why the planner refuses a swap, to follow "kan niet: " (#58).
    private func swapRefusal(_ plan: Plan, _ a: Int, _ b: Int) -> String {
        if plan.start.contains(a) != plan.start.contains(b) {
            return String(localized: "de ene staat in de basisvijf en de andere niet")
        }
        return String(localized: "die ruil past niet in het plan")
    }

    /// A failed save stays on screen over the swap prompts (#58).
    private func swapMessage(_ text: String) {
        if message != Self.saveFailed { message = text }
    }

    /// A seed as the web app's `newSeed`: a whole number from 1 to 2³² − 1. A debug build reads `VERVANGING_SEED`
    /// first, so the UI tests and screenshots get the same plan every run.
    nonisolated static func randomSeed() -> Int {
        #if DEBUG
        if let text = ProcessInfo.processInfo.environment["VERVANGING_SEED"], let seed = Int(text) { return seed }
        #endif
        return Int.random(in: 1...0xffff_ffff)
    }
}

/// Minutes as the web app writes them (`formatSeconds`): m:ss.
func formatSeconds(_ seconds: Int) -> String {
    let s = max(0, seconds)
    return "\(s / 60):" + String(format: "%02d", s % 60)
}
