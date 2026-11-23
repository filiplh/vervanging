import Foundation

/// One player on the roster: a stable id, a first name and a jersey number of one or two digits, kept as text the way
/// the web app keeps it ("7", "07" and "70" are different numbers).
struct Player: Codable, Equatable, Identifiable, Sendable {
    var id: Int
    var name: String
    var number: String
}

/// The coach's roster, the same shape as the web app's (`public/js/setup.js`): players plus the next free id.
struct Roster: Equatable, Sendable {
    static let maxPlayers = 15
    /// The largest id kept: JavaScript's largest safe integer, the web app's own limit. A stored id or next id above it
    /// (or below its negative) is damaged, and keeping ids this small means `+ 1` can never overflow.
    static let maxId = 9_007_199_254_740_991

    var nextId = 1
    var players: [Player] = []

    static let empty = Roster()

    /// An id for a new player: the stored next id when it is free and in range, else one above the highest id in use,
    /// else the smallest free positive id (there is always one, with at most 15 players).
    func newPlayerId() -> Int {
        let used = Set(players.map(\.id))
        if (1...Self.maxId).contains(nextId), !used.contains(nextId) { return nextId }
        if let top = used.max(), top >= 0, top < Self.maxId { return top + 1 }
        return (1...).first { !used.contains($0) }!
    }

    /// The roster with a new player added under `newPlayerId()`, and the next id moved past it (kept in range).
    func adding(name: String, number: String) -> Roster {
        let id = newPlayerId()
        var next = self
        next.players.append(Player(id: id, name: name, number: number))
        next.nextId = id < Self.maxId ? id + 1 : 1
        return next
    }
}

/// Reads and writes the roster as one small JSON file in the app's own storage (ADR-002, plan decision #38).
///
/// The file carries a version field, so a later shape can be told apart and migrated. It is written atomically (a
/// temporary file, then a rename), so a crash mid-write never leaves half a file. A missing, unreadable or damaged file,
/// or one with an unknown version, gives an empty roster instead of a crash.
struct RosterStore: Sendable {
    /// The version of the stored shape written by this build.
    static let version = 1
    static let fileName = "roster.json"

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The store in the app's Application Support folder. A debug build reads `VERVANGING_STORAGE_DIR` first, so the
    /// UI tests can give every test its own empty folder and look at the file the app wrote.
    static func standard() -> RosterStore {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["VERVANGING_STORAGE_DIR"], !override.isEmpty {
            return RosterStore(directory: URL(fileURLWithPath: override, isDirectory: true))
        }
        #endif
        let support = (try? FileManager.default.url(
            for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true
        )) ?? FileManager.default.temporaryDirectory
        return RosterStore(directory: support)
    }

    /// The stored roster, cleaned the way the web app's `normaliseRoster` cleans it; empty when there is none or it
    /// cannot be read.
    func load() -> Roster {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredRoster.self, from: data),
              file.version == Self.version
        else { return .empty }
        return Self.normalise(nextId: file.nextId, players: file.players)
    }

    /// Writes the roster. False when the file could not be written.
    @discardableResult
    func save(_ roster: Roster) -> Bool {
        let file = StoredRoster(version: Self.version, nextId: roster.nextId, players: roster.players)
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            try encoder.encode(file).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Drops players with a duplicate id, an empty name or a number that is not one or two digits, keeps at most 15,
    /// and makes sure the next id is above every id in use (as `normaliseRoster` in `public/js/setup.js`).
    static func normalise(nextId: Int?, players raw: [StoredPlayer]) -> Roster {
        var seen = Set<Int>()
        var players: [Player] = []
        for p in raw {
            guard let id = p.id, let name = p.name, let number = p.number,
                  (-Roster.maxId...Roster.maxId).contains(id),
                  !seen.contains(id),
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  Self.isJerseyNumber(number)
            else { continue }
            seen.insert(id)
            players.append(Player(id: id, name: name, number: number))
        }
        // Every id kept is within ±Roster.maxId, so `maxId + 1` cannot overflow; it can only reach maxId + 1, which
        // newPlayerId() treats as out of range.
        let maxId = max(players.map(\.id).max() ?? 0, 0)
        let next = if let nextId, nextId > maxId, nextId <= Roster.maxId { nextId } else { maxId + 1 }
        return Roster(nextId: next, players: Array(players.prefix(Roster.maxPlayers)))
    }

    /// One or two ASCII digits, as the web app's `/^\d{1,2}$/`.
    static func isJerseyNumber(_ text: String) -> Bool {
        (1...2).contains(text.count) && text.allSatisfy { ("0"..."9").contains($0) }
    }
}

/// The JSON shape on disk: `{ "version": 1, "nextId": 3, "players": [{ "id": 1, "name": "Lotte", "number": "7" }] }`.
/// Player fields are optional when read, so one damaged player is dropped instead of the whole roster.
struct StoredRoster: Codable {
    var version: Int
    var nextId: Int?
    var players: [StoredPlayer]

    init(version: Int, nextId: Int, players: [Player]) {
        self.version = version
        self.nextId = nextId
        self.players = players.map { StoredPlayer(id: $0.id, name: $0.name, number: $0.number) }
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        nextId = try? c.decodeIfPresent(Int.self, forKey: .nextId)
        players = (try? c.decodeIfPresent([StoredPlayer].self, forKey: .players)) ?? []
    }
}

struct StoredPlayer: Codable {
    var id: Int?
    var name: String?
    var number: String?

    init(id: Int?, name: String?, number: String?) {
        self.id = id
        self.name = name
        self.number = number
    }

    init(from decoder: any Decoder) throws {
        // A player that is not an object at all is read as empty and dropped, not a reason to lose the roster.
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { return }
        id = try? c.decodeIfPresent(Int.self, forKey: .id)
        name = try? c.decodeIfPresent(String.self, forKey: .name)
        number = try? c.decodeIfPresent(String.self, forKey: .number)
    }
}
