import Foundation
import Observation
import VervangingCore

/// One player's line in the minutes at a glance and the minutes table: the minutes so far, whether they are on court
/// now, and whether they are uit.
struct MinutesRow: Equatable, Identifiable, Sendable {
    var player: Player
    var seconds: Int
    var onCourt: Bool
    var out: Bool = false
    var id: Int { player.id }
}

/// In the zone or Extra minuten, chosen for the coming wissel but not yet applied (`zone` in `public/js/live.js`): the
/// player due off who stays on, the player due on who stays on the bench, and whether the block is a reward that is not
/// given back.
struct Zone: Equatable, Sendable {
    var keep: Int
    var bench: Int
    var extra: Bool
}

/// The live screen's state (plan decisions #8, #9, #11, #12, #17, #18, #24, #25, #27; `liveScreen` in
/// `public/js/live.js`): the match being played, the line under the last action, Wissel and Ongedaan maken, In the
/// zone and Extra minuten at the coming wissel, and Uit and Terug.
///
/// The model never computes a rule itself: every step is the engine's (`MatchState.wissel`, `undo`, `uit`, `terug`),
/// and what the screen shows comes from the engine's `onCourt`, `nextChange`, `proposedBench`, `replaced`, `subTime`,
/// `quarter` and `playedOverview`. The match is
/// saved after every tap that changes it (ADR-002), and the team history follows it (#104): the end of the match records
/// its minutes, an undo of the end takes them out again (`syncHistory` in live.js), and opening the screen catches up a
/// history write that failed before (`repairHistory`). No timer of any kind (ADR-001): the only time read is the moment
/// of a Wissel tap, to ignore a second tap that follows it too soon (#49).
@MainActor
@Observable
final class LiveModel {
    /// A second Wissel (or Einde match) tap this soon after the first is ignored: the button stays in the same spot and
    /// would otherwise take it as a second wissel, skipping a block or ending the match from the last but one block
    /// (`DOUBLE_TAP_MS` in `public/js/live.js`, #49).
    static let doubleTapInterval: TimeInterval = 0.6
    static let refused = String(localized: "Dat kan nu niet.")

    let setup: StartedMatch
    let players: [Player]
    private(set) var state: MatchState
    /// The line under the last action: its confirmation, or why it failed. Empty after a launch.
    private(set) var message: String
    /// True when `message` confirms an action rather than reporting a failure.
    private(set) var confirmed = false
    /// Goes up by one after every action, refused or not, so the screen can bring the line under it into view even
    /// when the text is the same as before.
    private(set) var actions = 0
    /// In the zone or Extra minuten chosen for the coming wissel; nil when none is. Any action clears it, as on the web.
    private(set) var zone: Zone?

    @ObservationIgnored private let store: MatchStore
    @ObservationIgnored private let history: HistoryStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastWisselAt: Date?

    /// `history` defaults to the history file beside the match file, so the app and the tests need not name it.
    init(match: LiveMatch, store: MatchStore, history: HistoryStore? = nil, message: String = "",
         now: @escaping () -> Date = Date.init) {
        setup = match.setup
        players = match.setup.players.sorted(by: SpelersModel.byNumber)
        state = match.state
        self.store = store
        self.history = history ?? HistoryStore(directory: store.fileURL.deletingLastPathComponent())
        self.message = message
        self.now = now
        if !repairHistory() { self.message = SetupModel.saveFailed }
    }

    /// A new match from setup at block 1, saved at once; when the write fails the match still opens, with the message
    /// that saving failed.
    static func start(_ started: StartedMatch, store: MatchStore, history: HistoryStore? = nil,
                      now: @escaping () -> Date = Date.init) -> LiveModel {
        var setup = started
        // The start time is stored to the millisecond, as the web app's `savedAt`; keep the same value in memory.
        setup.savedAt = MatchStore.date(MatchStore.isoString(started.savedAt)) ?? started.savedAt
        let match = LiveMatch(setup: setup, state: MatchState.start(setup.plan,
                                                                     setupSavedAt: MatchStore.isoString(setup.savedAt)))
        let saved = store.save(match)
        return LiveModel(match: match, store: store, history: history, message: saved ? "" : SetupModel.saveFailed,
                         now: now)
    }

    // MARK: - What the screen shows

    var isRunning: Bool { !state.ended }
    /// The screen stays on while the match runs (decision #18), and may dim and lock again after it ends.
    var keepsScreenAwake: Bool { !state.ended }
    var canUndo: Bool { state.canUndo }
    var isLastBlock: Bool { state.subTime == .endMatch }

    /// "Blok 3 van 12".
    var blockTitle: String { String(localized: "Blok \(state.block) van \(state.blocks)") }
    /// "kwart 1".
    var quarterText: String { String(localized: "kwart \(state.quarter)") }

    /// When the current block ends on the official clock (`subTimeText`): "Wissel op 6:40", "Einde kwart", or in the
    /// last block "Laatste blok".
    var subTimeText: String {
        switch state.subTime {
        case .endMatch: String(localized: "Laatste blok")
        case .endQuarter: String(localized: "Einde kwart")
        case let .sub(clockSeconds): String(localized: "Wissel op \(formatSeconds(clockSeconds))")
        }
    }

    var wisselLabel: String { isLastBlock ? String(localized: "Einde match") : String(localized: "Wissel") }

    var onCourt: [Player] { sorted(state.onCourt) }

    /// Who goes off and who comes on at the next wissel; nil in the last block and after the end.
    var nextChange: (off: [Player], on: [Player])? {
        state.nextChange.map { (sorted($0.off), sorted($0.on)) }
    }

    /// "Minuten tot nu": the engine's `playedOverview` (`minutesPlayed` in live.js, #54), by jersey number. Only the
    /// blocks already played count, and after the end every block.
    var minutes: [MinutesRow] {
        let entries = Dictionary(state.playedOverview.map { ($0.player, $0) }, uniquingKeysWith: { a, _ in a })
        return players.compactMap { player in
            entries[player.id].map { MinutesRow(player: player, seconds: $0.seconds, onCourt: $0.onCourt, out: $0.out) }
        }
    }

    /// The players who went uit in the current block and who came on for each, as the engine records them: "#12 Anna
    /// kwam erin voor #4 Lotte (uit). Het blok telt voor #4 Lotte."
    var replacements: [(starter: Player, replacement: Player)] {
        state.replaced.compactMap { pair in
            guard let starter = player(pair.starter), let replacement = player(pair.replacement) else { return nil }
            return (starter, replacement)
        }
    }

    func isOut(_ player: Player) -> Bool { state.out.contains(player.id) }

    /// Uit works at any time during the match; Terug takes effect from the next block, so it is offered while a next
    /// block exists (`canTerug` in live.js).
    var canTerug: Bool { !state.ended && state.block < state.blocks }

    /// The players due off at the coming wissel who can stay on (In the zone), by jersey number.
    var zoneCandidates: [Player] { (nextChange?.off ?? []).filter { !isOut($0) } }

    /// The sentence under In the zone: "#4 Lotte blijft in the zone op het veld, #12 Anna blijft op de bank." or, with
    /// Extra minuten, "#4 Lotte speelt een extra blok (extra minuten, niet teruggegeven), #12 Anna blijft op de bank."
    var zoneNote: String? {
        guard let zone, let keep = player(zone.keep), let bench = player(zone.bench) else { return nil }
        return zone.extra
            ? String(localized: "\(Self.label(keep)) speelt een extra blok (extra minuten, niet teruggegeven), \(Self.label(bench)) blijft op de bank.")
            : String(localized: "\(Self.label(keep)) blijft in the zone op het veld, \(Self.label(bench)) blijft op de bank.")
    }

    // MARK: - Actions

    /// Wissel: on to the next block, or at the last block the end of the match. A second tap within
    /// `doubleTapInterval` of the last one that counted is ignored (#49).
    func tapWissel() {
        let at = now()
        if let last = lastWisselAt, at.timeIntervalSince(last) < Self.doubleTapInterval { return }
        lastWisselAt = at
        let zone = zone
        act({ try $0.wissel(keep: zone?.keep, bench: zone?.bench, extra: zone?.extra ?? false) }, confirm: wisselLine)
    }

    /// In the zone: `keep` (due off) stays on at the coming wissel, with the engine's proposed player staying on the
    /// bench; choosing nobody, or the player already chosen, cancels it (`toggleZone` in live.js). Switching between
    /// players or to Extra minuten keeps the bench player chosen.
    func chooseZone(_ keep: Player?) {
        guard let keep, keep.id != zone?.keep, zoneCandidates.contains(keep) else {
            zone = nil
            return
        }
        if var zone {
            zone.keep = keep.id
            self.zone = zone
        } else if let bench = state.proposedBench {
            zone = Zone(keep: keep.id, bench: bench, extra: false)
        }
    }

    /// Op de bank: the player due on who stays off instead of the proposed one.
    func chooseBench(_ bench: Player) {
        guard zone != nil, nextChange?.on.contains(bench) == true else { return }
        zone?.bench = bench.id
    }

    /// Extra minuten (niet teruggeven): the chosen player plays the block on top and gives nothing back (#25).
    func setExtra(_ extra: Bool) {
        zone?.extra = extra
    }

    /// Uit: the player plays no more this match; on court, a replacement comes on at once (decision #11).
    func uit(_ player: Player) {
        act({ try $0.uit(player.id) }) { before, after in
            let cameOn = self.sorted(after.onCourt.filter { !before.onCourt.contains($0) })
            guard let replacement = cameOn.first else { return String(localized: "\(Self.label(player)) uit.") }
            return String(localized: "\(Self.label(player)) uit, \(Self.label(replacement)) erin.")
        }
    }

    /// Terug: the player is available again from the next block.
    func terug(_ player: Player) {
        act({ try $0.terug(player.id) }) { _, _ in String(localized: "\(Self.label(player)) terug vanaf het volgende blok.") }
    }

    /// Ongedaan maken: back to before the last action, one step (decision #17).
    func undo() {
        guard state.canUndo else { return }
        act({ $0.undo() }, confirm: { _, _ in String(localized: "Ongedaan gemaakt.") })
    }

    /// Applies one engine step, saves the new state and writes its confirmation line; a refused step keeps the state
    /// and says why when the reason helps (`refusalText`), and a failed write says that saving failed. Any action
    /// clears In the zone.
    private func act(_ step: (MatchState) throws -> MatchState, confirm: (MatchState, MatchState) -> String) {
        let before = state
        confirmed = false
        zone = nil
        actions += 1
        do {
            state = try step(before)
        } catch {
            message = Self.refusalText(error)
            return
        }
        let saved = store.save(LiveMatch(setup: setup, state: state))
        if saved && syncHistory() {
            message = confirm(before, state)
            confirmed = !message.isEmpty
        } else {
            message = SetupModel.saveFailed
        }
    }

    /// "Wissel gedaan: blok 4. Erin: #11 Hanne, #12 Anna." The end of the match shows the end screen itself, so it
    /// writes no line; with nobody coming on (exactly five players), the Erin part is left out.
    private func wisselLine(_ before: MatchState, _ after: MatchState) -> String {
        if after.ended { return "" }
        let cameOn = sorted(after.onCourt.filter { !before.onCourt.contains($0) })
        if cameOn.isEmpty { return String(localized: "Wissel gedaan: blok \(after.block).") }
        let names = cameOn.map(Self.label).joined(separator: ", ")
        return String(localized: "Wissel gedaan: blok \(after.block). Erin: \(names).")
    }

    /// A refused action says why when the reason helps the coach (`refusalText` in live.js, #62): the engine's
    /// messages are matched whole, built from the same constant the engine uses; anything else keeps the plain line.
    static func refusalText(_ error: any Error) -> String {
        switch (error as? MatchError)?.message {
        case "at least \(Planner.onCourt) players must be available":
            String(localized: "Dat kan nu niet: er moeten minstens \(Planner.onCourt) spelers overblijven.")
        case "no block left: this is the last block":
            String(localized: "Dat kan nu niet: dit is het laatste blok.")
        default:
            refused
        }
    }

    // MARK: - Team history

    /// The setup's start time as stored, the id of this match in the history: the text the running state carries
    /// (`setupSavedAt`, the match key), never a date formatted again, which for a start time before the year 1 can
    /// differ from the key after a relaunch (#139). `isoString` is only the fallback for a state without the text.
    private var savedAt: String { state.setupSavedAt ?? MatchStore.isoString(setup.savedAt) }

    /// Keeps the history in line with the match after an action (`syncHistory` in live.js): an ended match is recorded
    /// (replacing an earlier entry, so ending, undoing and ending again never counts it twice), and a match that is no
    /// longer ended is taken out again. Any other action writes nothing. True when no write was needed or it worked.
    private func syncHistory() -> Bool {
        let stored = history.load()
        if state.ended { return history.save(stored.recording(state, savedAt: savedAt)) }
        guard stored.has(JSString(savedAt)) else { return true }
        return history.save(stored.forgetting(JSString(savedAt)))
    }

    /// When the screen opens (`repairHistory` in live.js): an ended match missing from the history is recorded, unless
    /// "Wis geschiedenis" ran after its Start; a match no longer ended but still in the history is taken out. True when
    /// nothing was needed or the write worked.
    private func repairHistory() -> Bool {
        let stored = history.load()
        let recorded = stored.has(JSString(savedAt))
        if state.ended && !recorded && stored.startedAfterClear(savedAt) {
            return history.save(stored.recording(state, savedAt: savedAt))
        }
        if !state.ended && recorded { return history.save(stored.forgetting(JSString(savedAt))) }
        return true
    }

    // MARK: - Helpers

    /// A player as the screen writes them: "#11 Hanne".
    static func label(_ player: Player) -> String { "#\(player.number) \(player.name)" }

    /// The players with these ids, by jersey number as the screen lists them.
    private func sorted(_ ids: [Int]) -> [Player] { players.filter { ids.contains($0.id) } }

    private func player(_ id: Int) -> Player? { players.first { $0.id == id } }
}
