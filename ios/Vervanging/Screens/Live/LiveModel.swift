import Foundation
import Observation
import VervangingCore

/// One player's line in the minutes at a glance and the minutes table: the minutes so far, and whether they are on
/// court now.
struct MinutesRow: Equatable, Identifiable, Sendable {
    var player: Player
    var seconds: Int
    var onCourt: Bool
    var id: Int { player.id }
}

/// The live screen's state (plan decisions #12, #17, #18, #27; `liveScreen` in `public/js/live.js`): the match being
/// played, the line under the last action, and Wissel and Ongedaan maken.
///
/// The model never computes a rule itself: every step is the engine's (`MatchState.wissel`, `undo`), and what the
/// screen shows comes from the engine's `onCourt`, `nextChange`, `subTime`, `quarter` and `minutesSoFar`. The match is
/// saved after every tap that changes it (ADR-002). No timer of any kind (ADR-001): the only time read is the moment
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

    @ObservationIgnored private let store: MatchStore
    @ObservationIgnored private let now: () -> Date
    @ObservationIgnored private var lastWisselAt: Date?

    init(match: LiveMatch, store: MatchStore, message: String = "", now: @escaping () -> Date = Date.init) {
        setup = match.setup
        players = match.setup.players.sorted(by: SpelersModel.byNumber)
        state = match.state
        self.store = store
        self.message = message
        self.now = now
    }

    /// A new match from setup at block 1, saved at once; when the write fails the match still opens, with the message
    /// that saving failed.
    static func start(_ started: StartedMatch, store: MatchStore, now: @escaping () -> Date = Date.init) -> LiveModel {
        var setup = started
        // The start time is stored to the millisecond, as the web app's `savedAt`; keep the same value in memory.
        setup.savedAt = MatchStore.date(MatchStore.isoString(started.savedAt)) ?? started.savedAt
        let match = LiveMatch(setup: setup, state: MatchState.start(setup.plan,
                                                                     setupSavedAt: MatchStore.isoString(setup.savedAt)))
        let saved = store.save(match)
        return LiveModel(match: match, store: store, message: saved ? "" : SetupModel.saveFailed, now: now)
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

    /// "Minuten tot nu" (`minutesPlayed` in live.js, #54): only the blocks already played count, so at tip-off everyone
    /// has 0:00 and the block being played counts once its Wissel (or Einde match) is tapped. After the end every block
    /// is played. The seconds are the engine's `minutesSoFar` up to the last finished block.
    var minutes: [MinutesRow] {
        var played = state
        if !played.ended { played.block -= 1 }
        let seconds = played.minutesSoFar
        let court = state.ended ? [] : state.onCourt
        return players.map { MinutesRow(player: $0, seconds: seconds[$0.id] ?? 0, onCourt: court.contains($0.id)) }
    }

    // MARK: - Actions

    /// Wissel: on to the next block, or at the last block the end of the match. A second tap within
    /// `doubleTapInterval` of the last one that counted is ignored (#49).
    func tapWissel() {
        let at = now()
        if let last = lastWisselAt, at.timeIntervalSince(last) < Self.doubleTapInterval { return }
        lastWisselAt = at
        act({ try $0.wissel() }, confirm: wisselLine)
    }

    /// Ongedaan maken: back to before the last action, one step (decision #17).
    func undo() {
        guard state.canUndo else { return }
        act({ $0.undo() }, confirm: { _, _ in String(localized: "Ongedaan gemaakt.") })
    }

    /// Applies one engine step, saves the new state and writes its confirmation line; a refused step keeps the state
    /// and says so, and a failed write says that saving failed.
    private func act(_ step: (MatchState) throws -> MatchState, confirm: (MatchState, MatchState) -> String) {
        let before = state
        confirmed = false
        do {
            state = try step(before)
        } catch {
            message = Self.refused
            return
        }
        if store.save(LiveMatch(setup: setup, state: state)) {
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

    // MARK: - Helpers

    /// A player as the screen writes them: "#11 Hanne".
    static func label(_ player: Player) -> String { "#\(player.number) \(player.name)" }

    /// The players with these ids, by jersey number as the screen lists them.
    private func sorted(_ ids: [Int]) -> [Player] { players.filter { ids.contains($0.id) } }
}
