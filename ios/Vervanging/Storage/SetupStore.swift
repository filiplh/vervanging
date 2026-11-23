import Foundation

/// What the match setup remembers between matches (#101, #56): the history switch, and who was present and who was in
/// the basisvijf at the last started match. The web app keeps these in three places (`attendance`, `matchSetup` and the
/// switch inside `history`); the native app keeps them in one small file, because it starts with no web data
/// (decision #33) and the team history file comes later (#104).
struct LastSetup: Equatable, Sendable {
    /// The history switch, "Houd rekening met vorige matchen" (decision #10).
    var useHistory = false
    /// The player ids present at the last started match; nil before the first match, so everyone is ticked.
    var attendance: [Int]?
    /// The last started match's basisvijf.
    var startingFive: [Int] = []

    static let none = LastSetup()
}

/// Reads and writes `setup.json` beside the roster, the same way `RosterStore` does: versioned, written atomically, and
/// a missing, unreadable or damaged file, or one with an unknown version, reads as no last setup instead of a crash.
struct SetupStore: Sendable {
    static let version = 1
    static let fileName = "setup.json"

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The store in the same folder as the roster (`RosterStore.standard()`, which honours `VERVANGING_STORAGE_DIR` in
    /// debug builds for the UI tests).
    static func standard() -> SetupStore {
        SetupStore(directory: RosterStore.standard().fileURL.deletingLastPathComponent())
    }

    func load() -> LastSetup {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredSetup.self, from: data),
              file.version == Self.version
        else { return .none }
        return LastSetup(useHistory: file.useHistory ?? false, attendance: file.attendance?.ids,
                         startingFive: file.startingFive?.ids ?? [])
    }

    /// Writes the setup. False when the file could not be written.
    @discardableResult
    func save(_ setup: LastSetup) -> Bool {
        let file = StoredSetup(version: Self.version, useHistory: setup.useHistory,
                               attendance: setup.attendance.map(LossyIds.init), startingFive: LossyIds(setup.startingFive))
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
}

/// The JSON shape on disk: `{ "version": 1, "useHistory": false, "attendance": [1, 2], "startingFive": [1, 2, 3, 4, 5] }`.
/// `attendance` is left out until the first match is started. Every field but the version is read leniently.
struct StoredSetup: Codable {
    var version: Int
    var useHistory: Bool?
    var attendance: LossyIds?
    var startingFive: LossyIds?

    init(version: Int, useHistory: Bool, attendance: LossyIds?, startingFive: LossyIds) {
        self.version = version
        self.useHistory = useHistory
        self.attendance = attendance
        self.startingFive = startingFive
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        useHistory = try? c.decodeIfPresent(Bool.self, forKey: .useHistory)
        attendance = try? c.decodeIfPresent(LossyIds.self, forKey: .attendance)
        startingFive = try? c.decodeIfPresent(LossyIds.self, forKey: .startingFive)
    }
}

/// A list of player ids that keeps only whole numbers and drops anything else, as the web app's `normaliseAttendance`
/// keeps only integers.
struct LossyIds: Codable {
    var ids: [Int]

    init(_ ids: [Int]) { self.ids = ids }

    init(from decoder: any Decoder) throws {
        var c = try decoder.unkeyedContainer()
        var ids: [Int] = []
        while !c.isAtEnd {
            if let id = try? c.decode(Int.self) { ids.append(id) } else { _ = try? c.decode(Skip.self) }
        }
        self.ids = ids
    }

    func encode(to encoder: any Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(ids)
    }

    /// Reads and drops one value of any kind.
    private struct Skip: Decodable {
        init(from decoder: any Decoder) throws {}
    }
}
