import Foundation
import VervangingCore

/// A match on the live screen: the setup it was started with and where play is now.
struct LiveMatch: Equatable, Sendable {
    var setup: StartedMatch
    var state: MatchState

    /// The plan the engine plays, built from the started setup (`planOf` in `public/js/live.js`).
    var plan: Plan { setup.plan }
}

/// Reads and writes the match being played as `match.json` beside the roster (ADR-002, plan decisions #18 and #38):
/// the setup it was started with (players with their names and numbers, the plan) and the match state the engine
/// keeps (`MatchState`, which carries its own version). The web app keeps the same two parts as `matchSetup` and
/// `match`; here they are one file, so a write never leaves a state beside the wrong setup.
///
/// The file carries a version field and is written atomically (a temporary file, then a rename) after every tap. On
/// load, the setup is checked as the web app's `normaliseMatchSetup` checks it, and the state is restored through the
/// engine's `MatchState.restored`: a missing or damaged setup gives no match, and a missing, damaged or foreign state
/// gives the same match back at block 1, as the web app's `restoreMatch` does.
struct MatchStore: Sendable {
    static let version = 1
    static let fileName = "match.json"

    let fileURL: URL

    init(directory: URL) {
        fileURL = directory.appendingPathComponent(Self.fileName, isDirectory: false)
    }

    /// The store in the same folder as the roster (`RosterStore.standard()`, which honours `VERVANGING_STORAGE_DIR` in
    /// debug builds for the UI tests).
    static func standard() -> MatchStore {
        MatchStore(directory: RosterStore.standard().fileURL.deletingLastPathComponent())
    }

    /// The stored match, or nil when there is none or its setup cannot be read.
    func load() -> LiveMatch? {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredMatch.self, from: data),
              file.version == Self.version,
              let setup = Self.startedMatch(file.setup)
        else { return nil }
        let savedAt = Self.isoString(setup.savedAt)
        let state = file.state.flatMap { MatchState.restored($0, plan: setup.plan, setupSavedAt: savedAt) }
            ?? MatchState.start(setup.plan, setupSavedAt: savedAt)
        return LiveMatch(setup: setup, state: state)
    }

    /// Writes the match. False when the file could not be written.
    @discardableResult
    func save(_ match: LiveMatch) -> Bool {
        let setup = match.setup
        let file = StoredMatch(
            version: Self.version,
            setup: StoredMatchSetup(
                savedAt: Self.isoString(setup.savedAt), opponent: setup.opponent, schedule: setup.schedule,
                seed: setup.seed,
                players: setup.players.map { StoredPlayer(id: $0.id, name: $0.name, number: $0.number) },
                startingFive: setup.startingFive,
                plan: StoredPlan(start: setup.plan.start, grid: setup.plan.grid,
                                 sitLimitRelaxed: setup.plan.sitLimitRelaxed)),
            state: match.state)
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

    /// A start time as the web app writes `savedAt` (`new Date().toISOString()`): `2026-11-23T10:15:00.123Z`. The
    /// match state keeps it as `setupSavedAt`, which ties a state to its setup.
    ///
    /// The text must read back as the same text (#134): `load` compares the state's `setupSavedAt` with the setup's
    /// time written again, and every save writes the time it read. The system formatter cuts the fraction off, and a
    /// time it has just parsed is often a hair below its millisecond, so about half of all times came back 1 ms early
    /// and the running match was thrown away. So the time is taken to its nearest whole millisecond and the
    /// milliseconds are written by hand after the whole seconds, which the formatter writes exactly. A time written by
    /// the earlier formatter reads back as its own text here, so match files from before #134 keep their match.
    static func isoString(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        let seconds = (milliseconds / 1000).rounded(.down)
        let fraction = Int(milliseconds - seconds * 1000)
        let whole = Date.ISO8601FormatStyle().format(Date(timeIntervalSince1970: seconds))
        return "\(whole.dropLast()).\(String(format: "%03d", fraction))Z"
    }

    /// The time a stored text names, at its nearest whole millisecond (see `isoString`), or nil when it is no time.
    static func date(_ text: String) -> Date? {
        guard let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) else { return nil }
        return Date(timeIntervalSince1970: (parsed.timeIntervalSince1970 * 1000).rounded() / 1000)
    }

    /// The stored setup as a started match, checked as `normaliseMatchSetup` in `public/js/setup.js`: a known schema,
    /// at least five valid players with different ids (none dropped), a basisvijf and a plan start of five different
    /// players of the match, and one such line-up per block of the schema. Nil when any of it fails.
    static func startedMatch(_ stored: StoredMatchSetup) -> StartedMatch? {
        guard let schedule = stored.schedule, let shape = Planner.schedules[schedule],
              let rawPlayers = stored.players, let startingFive = stored.startingFive, let plan = stored.plan,
              let grid = plan.grid, let start = plan.start,
              let savedAtText = stored.savedAt, let savedAt = date(savedAtText)
        else { return nil }
        let roster = RosterStore.normalise(nextId: nil, players: rawPlayers)
        guard roster.players.count == rawPlayers.count, roster.players.count >= Planner.onCourt else { return nil }
        let ids = Set(roster.players.map(\.id))
        func isFive(_ court: [Int]) -> Bool {
            court.count == Planner.onCourt && Set(court).count == Planner.onCourt && court.allSatisfy(ids.contains)
        }
        guard isFive(startingFive), isFive(start), grid.count == shape.blocks, grid.allSatisfy(isFive) else { return nil }
        let players = roster.players
        return StartedMatch(
            savedAt: savedAt, opponent: stored.opponent ?? "", schedule: schedule, seed: stored.seed ?? 0,
            players: players, startingFive: startingFive,
            plan: Plan(schedule: schedule, blocks: shape.blocks, blockSeconds: shape.blockSeconds,
                       blocksPerQuarter: shape.blocksPerQuarter, players: players.map(\.id), start: start, grid: grid,
                       sitLimitRelaxed: plan.sitLimitRelaxed ?? false))
    }
}

/// The JSON shape on disk:
/// `{ "version": 1, "setup": { "savedAt": "…", "opponent": "", "schedule": "equal", "seed": 7, "players": […],
/// "startingFive": […], "plan": { "start": […], "grid": [[…]], "sitLimitRelaxed": false } }, "state": { … } }`.
/// The setup's fields and the state are read leniently, so the checks in `MatchStore` decide what is kept.
struct StoredMatch: Codable {
    var version: Int
    var setup: StoredMatchSetup
    var state: MatchState?

    init(version: Int, setup: StoredMatchSetup, state: MatchState?) {
        self.version = version
        self.setup = setup
        self.state = state
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        setup = try c.decode(StoredMatchSetup.self, forKey: .setup)
        state = try? c.decodeIfPresent(MatchState.self, forKey: .state)
    }
}

struct StoredMatchSetup: Codable {
    var savedAt: String?
    var opponent: String?
    var schedule: String?
    var seed: Int?
    var players: [StoredPlayer]?
    var startingFive: [Int]?
    var plan: StoredPlan?

    init(savedAt: String, opponent: String, schedule: String, seed: Int, players: [StoredPlayer], startingFive: [Int],
         plan: StoredPlan) {
        self.savedAt = savedAt
        self.opponent = opponent
        self.schedule = schedule
        self.seed = seed
        self.players = players
        self.startingFive = startingFive
        self.plan = plan
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        savedAt = try? c.decodeIfPresent(String.self, forKey: .savedAt)
        opponent = try? c.decodeIfPresent(String.self, forKey: .opponent)
        schedule = try? c.decodeIfPresent(String.self, forKey: .schedule)
        seed = try? c.decodeIfPresent(Int.self, forKey: .seed)
        players = try? c.decodeIfPresent([StoredPlayer].self, forKey: .players)
        startingFive = try? c.decodeIfPresent([Int].self, forKey: .startingFive)
        plan = try? c.decodeIfPresent(StoredPlan.self, forKey: .plan)
    }
}

struct StoredPlan: Codable {
    var start: [Int]?
    var grid: [[Int]]?
    var sitLimitRelaxed: Bool?

    init(start: [Int], grid: [[Int]], sitLimitRelaxed: Bool) {
        self.start = start
        self.grid = grid
        self.sitLimitRelaxed = sitLimitRelaxed
    }

    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        start = try? c.decodeIfPresent([Int].self, forKey: .start)
        grid = try? c.decodeIfPresent([[Int]].self, forKey: .grid)
        sitLimitRelaxed = try? c.decodeIfPresent(Bool.self, forKey: .sitLimitRelaxed)
    }
}
