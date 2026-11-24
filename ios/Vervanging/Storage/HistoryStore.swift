import Foundation
import VervangingCore

/// Reads and writes the team history (plan decisions #10, #26, #28, #33) as `history.json` beside the roster (ADR-002,
/// decision #38): every finished match's seconds per player, with the Extra minuten seconds kept apart, in the engine's
/// `History` shape (`public/js/history.js`), plus a version field.
///
/// The history starts empty (decision #33): nothing is imported from the web app. A missing, unreadable or damaged
/// file, or one with an unknown version, reads as the empty history instead of a crash, and the engine's
/// `History(json:)` drops damaged entries one by one. The file is written atomically (a temporary file, then a rename),
/// and only when a match ends, when the end is undone, and by "Wis geschiedenis", never on every tap.
///
/// The history switch lives in `setup.json` (`SetupStore`, #101), where the setup screen reads it; the `useHistory`
/// field of this file is kept only because it is part of the engine's shape, and the app does not read it.
struct HistoryStore: Sendable {
    static let version = 1
    static let fileName = "history.json"

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The store in the same folder as the roster (`RosterStore.standard()`, which honours `VERVANGING_STORAGE_DIR` in
    /// debug builds for the UI tests).
    static func standard() -> HistoryStore {
        HistoryStore(directory: RosterStore.standard().fileURL.deletingLastPathComponent())
    }

    /// The stored history; empty when there is none, it cannot be read, or its version is not this build's.
    func load() -> History {
        guard let data = try? Data(contentsOf: fileURL),
              let header = try? JSONDecoder().decode(Header.self, from: data),
              header.version == Self.version,
              let text = String(data: data, encoding: .utf8),
              let history = try? History(json: text)
        else { return History() }
        return history
    }

    /// Writes the history. False when the file could not be written.
    @discardableResult
    func save(_ history: History) -> Bool {
        // The engine's JSON is an object that starts with "{"; the version goes in front of its first key:
        // `{"version":1,"useHistory":false,"clearedAt":null,"matches":[…]}`.
        let text = "{\"version\":\(Self.version)," + history.json.dropFirst()
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try Data(text.utf8).write(to: fileURL, options: [.atomic])
            return true
        } catch {
            return false
        }
    }

    /// Only the version is read here; the rest is the engine's to read.
    private struct Header: Decodable {
        var version: Int
    }
}

extension History {
    /// The history with this ended match recorded under its setup's start time (`recordMatch` with `minutesSoFar` and
    /// `extraSeconds`, as `syncHistory` in `public/js/live.js` records it). Every number comes from the engine.
    func recording(_ state: MatchState, savedAt: String) -> History {
        recording(JSString(savedAt), seconds: Self.object(state.minutesSoFar), extra: Self.object(state.extraSeconds))
    }

    /// Seconds per player id as the engine's history takes them, keyed by the id written as a whole number.
    private static func object(_ seconds: [Int: Int]) -> JSObject<Double> {
        var object = JSObject<Double>()
        for (id, value) in seconds.sorted(by: { $0.key < $1.key }) { object[String(id)] = Double(value) }
        return object
    }
}
