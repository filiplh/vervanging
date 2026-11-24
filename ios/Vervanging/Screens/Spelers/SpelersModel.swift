import Foundation
import Observation
import VervangingCore

/// The Spelers screen's state: the roster, the player being edited and the message under the form, plus the season
/// totals from the team history (decision #26) and "Wis geschiedenis" (decision #10, #104). Every change is written to
/// the store at once (plan decision #38). The totals are the engine's `seasonSummary`; the screen only formats them.
///
/// The roster checks are ported from `public/js/setup.js` (`checkPlayer`, `byNumber`) with the same Dutch messages.
/// They live with the screen, not in VervangingCore, because they are entry checks for this screen rather than match
/// rules shared through `shared/examples/`.
@MainActor
@Observable
final class SpelersModel {
    static let maxName = 20
    static let maxNumber = 2

    private(set) var roster: Roster
    private(set) var editingId: Int?
    var message = ""
    /// The team history the totals come from, read again each time the screen opens.
    private(set) var history: History
    /// The line under Wis geschiedenis: "Geschiedenis gewist." or that saving failed. Empty until it is used.
    private(set) var historyMessage = ""
    private(set) var historyFailed = false

    @ObservationIgnored private let store: RosterStore
    @ObservationIgnored private let historyStore: HistoryStore

    /// `history` defaults to the history file beside the roster.
    init(store: RosterStore, history: HistoryStore? = nil) {
        self.store = store
        historyStore = history ?? HistoryStore(directory: store.fileURL.deletingLastPathComponent())
        roster = store.load()
        self.history = historyStore.load()
    }

    /// The season totals (`seasonSummary`): the number of saved matches and each player's total seconds.
    var season: SeasonSummary { history.seasonSummary() }

    /// A player's season total in seconds; 0 for a player in no saved match.
    func seasonSeconds(_ player: Player) -> Int { Int((season.totals[String(player.id)] ?? 0).rounded()) }

    /// Reads the history again, after a match ended or the history was cleared elsewhere.
    func reloadHistory() {
        history = historyStore.load()
    }

    /// "Wis geschiedenis" (`clearHistory`), after the screen has asked: no saved matches left, every total back to 0.
    func clearHistory(now: Date = .now) {
        let next = history.cleared(at: MatchStore.isoString(now))
        if historyStore.save(next) {
            history = next
            historyMessage = String(localized: "Geschiedenis gewist.")
            historyFailed = false
        } else {
            historyMessage = SetupModel.saveFailed
            historyFailed = true
        }
    }

    /// The line above the roster that says what the totals behind each name are (`seasonNote` in setup.js).
    static func seasonNote(_ matches: Int) -> String {
        switch matches {
        case 0: String(localized: "Speeltijd dit seizoen: nog geen matchen bewaard.")
        case 1: String(localized: "Speeltijd dit seizoen, over 1 bewaarde match.")
        default: String(localized: "Speeltijd dit seizoen, over \(matches) bewaarde matchen.")
        }
    }

    /// A season total as the web app writes it (`formatDuration`): m:ss, or h:mm:ss from an hour on.
    nonisolated static func formatDuration(_ seconds: Int) -> String {
        let s = max(0, seconds)
        if s < 3600 { return formatSeconds(s) }
        return "\(s / 3600):" + String(format: "%02d:%02d", s / 60 % 60, s % 60)
    }

    var isFull: Bool { editingId == nil && roster.players.count >= Roster.maxPlayers }
    var editing: Player? { roster.players.first { $0.id == editingId } }
    var sortedPlayers: [Player] { roster.players.sorted(by: Self.byNumber) }

    /// A Dutch message saying why the entry cannot be saved, or nil when it can (`checkPlayer` in setup.js).
    static func check(_ roster: Roster, name: String, number: String, editingId: Int?) -> String? {
        if editingId == nil && roster.players.count >= Roster.maxPlayers {
            return String(localized: "Maximaal \(Roster.maxPlayers) spelers.")
        }
        if name.isEmpty { return String(localized: "Vul een voornaam in.") }
        if name.count > maxName { return String(localized: "Een voornaam heeft hoogstens \(maxName) tekens.") }
        if !RosterStore.isJerseyNumber(number) { return String(localized: "Vul een rugnummer van 0 tot 99 in.") }
        if let taken = roster.players.first(where: { $0.number == number && $0.id != editingId }) {
            return String(localized: "Rugnummer \(number) is al van \(taken.name).")
        }
        return nil
    }

    /// Adds the entry, or saves it over the player being edited. True when it was accepted.
    @discardableResult
    func submit(name rawName: String, number rawNumber: String) -> Bool {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        let number = rawNumber.trimmingCharacters(in: .whitespacesAndNewlines)
        if let error = Self.check(roster, name: name, number: number, editingId: editingId) {
            message = error
            return false
        }
        message = ""
        var next = roster
        if let id = editingId, let index = next.players.firstIndex(where: { $0.id == id }) {
            next.players[index] = Player(id: id, name: name, number: number)
        } else {
            next = next.adding(name: name, number: number)
        }
        editingId = nil
        persist(next)
        return true
    }

    func startEditing(_ player: Player) {
        editingId = player.id
        message = ""
    }

    func cancelEditing() {
        editingId = nil
        message = ""
    }

    func remove(_ player: Player) {
        if editingId == player.id { editingId = nil }
        message = ""
        var next = roster
        next.players.removeAll { $0.id == player.id }
        persist(next)
    }

    private func persist(_ next: Roster) {
        roster = next
        if !store.save(roster) {
            // ⚠ New copy: the web app says "de browser weigert opslag"; on the phone it is the phone that refuses.
            message = String(localized: "Opslaan lukte niet: de telefoon weigert opslag.")
        }
    }

    /// By jersey number, then "7" before "07", then by name (`byNumber` in setup.js).
    nonisolated static func byNumber(_ a: Player, _ b: Player) -> Bool {
        let na = Int(a.number) ?? 0, nb = Int(b.number) ?? 0
        if na != nb { return na < nb }
        if a.number.count != b.number.count { return a.number.count < b.number.count }
        return a.name.compare(b.name, locale: Locale(identifier: "nl")) == .orderedAscending
    }
}
