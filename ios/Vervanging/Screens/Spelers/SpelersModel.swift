import Foundation
import Observation

/// The Spelers screen's state: the roster, the player being edited and the message under the form. Every change is
/// written to the store at once (plan decision #38).
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

    @ObservationIgnored private let store: RosterStore

    init(store: RosterStore) {
        self.store = store
        roster = store.load()
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
            next.players.append(Player(id: next.nextId, name: name, number: number))
            next.nextId += 1
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
