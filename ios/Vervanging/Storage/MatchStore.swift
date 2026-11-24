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
    ///
    /// The state belongs to the setup when its `setupSavedAt` is the setup's stored `savedAt` text, compared as text
    /// (#134). The text is never derived again from a `Date`: a `Date` cannot hold every millisecond of every year, and
    /// the system formatter writes all times before the year -4712 as one text it cannot read back.
    func load() -> LiveMatch? {
        guard let data = try? Data(contentsOf: fileURL),
              let file = try? JSONDecoder().decode(StoredMatch.self, from: data),
              file.version == Self.version,
              let setup = Self.startedMatch(file.setup),
              let savedAt = file.setup.savedAt
        else { return nil }
        let state = file.state.flatMap { MatchState.restored($0, plan: setup.plan, setupSavedAt: savedAt) }
            ?? MatchState.start(setup.plan, setupSavedAt: savedAt)
        return LiveMatch(setup: setup, state: state)
    }

    /// Writes the match. False when the file could not be written.
    ///
    /// The setup's `savedAt` is written as the text the state carries in `setupSavedAt`: the state was started from
    /// this setup with that text (`LiveModel.start`) or restored against it (`load`), so the text written at the start
    /// is the text written after every tap, and the match key never depends on a `Date` read back (#134). Only a state
    /// without that text writes the setup's own time.
    @discardableResult
    func save(_ match: LiveMatch) -> Bool {
        let setup = match.setup
        let file = StoredMatch(
            version: Self.version,
            setup: StoredMatchSetup(
                savedAt: match.state.setupSavedAt ?? Self.isoString(setup.savedAt), opponent: setup.opponent, schedule: setup.schedule,
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
    /// The match key itself is carried as text (`load`, `save`). The text should still read back as itself through
    /// `date`, because the live screen names the match in the team history by this text written from the setup's
    /// `Date`. The system formatter cuts the fraction off, and a time it has just parsed is often a hair below its
    /// millisecond, so before #134 about half of all times came back 1 ms early. So the time is taken to its nearest
    /// whole millisecond and the milliseconds are written by hand after the whole seconds, which the formatter writes
    /// exactly. A time written by the earlier formatter reads back as its own text here.
    /// From 2^53 milliseconds on (past the year 287,000) a `Double` no longer counts single milliseconds, so the
    /// time is written in whole seconds there, which also keeps the arithmetic finite for every `Date`. Outside the
    /// years the formatter can write (before -4712, after 506,713) it writes one fixed date; the milliseconds of the
    /// real time would make that text differ while naming no time, so they are written as `.000` there.
    static func isoString(_ date: Date) -> String {
        let milliseconds = (date.timeIntervalSince1970 * 1000).rounded()
        var seconds = date.timeIntervalSince1970.rounded(.down)
        var fraction = 0
        if abs(milliseconds) < 9_007_199_254_740_992 {
            seconds = (milliseconds / 1000).rounded(.down)
            fraction = Int(milliseconds - seconds * 1000)
        }
        let style = Date.ISO8601FormatStyle()
        let whole = style.format(Date(timeIntervalSince1970: seconds))
        if fraction != 0, (try? style.parse(whole))?.timeIntervalSince1970 != seconds { fraction = 0 }
        return "\(whole.dropLast()).\(String(format: "%03d", fraction))Z"
    }

    /// The time a stored text names, or nil when it is no time the formatter reads. When a `Date` close to the parsed
    /// one is written back as the same text by `isoString`, that `Date` is returned. That holds for every text through
    /// the year 9999. Far beyond it, a `Date` steps by more than a millisecond: each step up and down is tried in
    /// turn, a few dozen at most, and the nearest whole millisecond is returned when none fits.
    static func date(_ text: String) -> Date? {
        guard let parsed = try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(text) else { return nil }
        let nearest = Date(timeIntervalSince1970: (parsed.timeIntervalSince1970 * 1000).rounded() / 1000)
        if isoString(nearest) == text { return nearest }
        var down = parsed.timeIntervalSinceReferenceDate
        var up = down
        for _ in 0..<64 {
            for candidate in [Date(timeIntervalSinceReferenceDate: up), Date(timeIntervalSinceReferenceDate: down)]
            where isoString(candidate) == text {
                return candidate
            }
            up = up.nextUp
            down = down.nextDown
        }
        return nearest
    }

    /// Stands in for a stored start time that the formatter cannot read back, so the match is still kept (#134): the
    /// system formatter writes every time before the year -4712 as `-4712-01-01T12:00:00Z`, which it then refuses.
    /// The web app keeps any `savedAt` text too (`normaliseMatchSetup`). The match key stays the stored text.
    static let unreadableStartTime = Date(timeIntervalSince1970: -100_000_000_000_000)

    /// The stored setup as a started match, checked as `normaliseMatchSetup` in `public/js/setup.js`: a known schema,
    /// at least five valid players with different ids (none dropped), a basisvijf and a plan start of five different
    /// players of the match, and one such line-up per block of the schema. Nil when any of it fails.
    static func startedMatch(_ stored: StoredMatchSetup) -> StartedMatch? {
        guard let schedule = stored.schedule, let shape = Planner.schedules[schedule],
              let rawPlayers = stored.players, let startingFive = stored.startingFive, let plan = stored.plan,
              let grid = plan.grid, let start = plan.start,
              let savedAtText = stored.savedAt
        else { return nil }
        let savedAt = date(savedAtText) ?? unreadableStartTime
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
