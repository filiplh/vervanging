import Foundation

// The match state, ported from public/js/match.js (ADR-003): which block is being played, the live plan and what undo
// puts back. A plain value with a version, saved as JSON after every tap and restored on launch (ADR-002, decision
// #18). It has the same fields, with the same names and meanings, as the web app's state (MATCH_VERSION 2), so the
// two read alike; MatchState.swift holds the shape and Match.swift the actions.

/// A MatchError's message is the same text as the JavaScript MatchError's, so the Swift sim prints the same line.
public struct MatchError: Error, Equatable, Sendable, CustomStringConvertible {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var description: String { message }
}

/// A player marked uit in the current block and the player who came on for them (decision on #9, 22 Nov 2026).
/// Stored as a two-number list `[starter, replacement]`, as in the web app.
public struct Replacement: Equatable, Hashable, Sendable, Codable {
    public var starter: Int
    public var replacement: Int

    public init(starter: Int, replacement: Int) {
        self.starter = starter
        self.replacement = replacement
    }

    public init(from decoder: any Decoder) throws {
        var list = try decoder.unkeyedContainer()
        starter = try list.decode(Int.self)
        replacement = try list.decode(Int.self)
        guard list.isAtEnd else {
            throw DecodingError.dataCorruptedError(in: list, debugDescription: "a replacement is two players")
        }
    }

    public func encode(to encoder: any Encoder) throws {
        var list = encoder.unkeyedContainer()
        try list.encode(starter)
        try list.encode(replacement)
    }
}

/// What undo puts back (decision #17): the live part of the state before the last action, whatever the action was.
public struct MatchSnapshot: Equatable, Sendable, Codable {
    public var block: Int
    public var ended: Bool
    public var grid: [[Int]]
    public var out: [Int]
    public var replaced: [Replacement]
    public var extra: [Int]

    public init(block: Int, ended: Bool, grid: [[Int]], out: [Int], replaced: [Replacement], extra: [Int]) {
        self.block = block
        self.ended = ended
        self.grid = grid
        self.out = out
        self.replaced = replaced
        self.extra = extra
    }

    enum CodingKeys: String, CodingKey { case block, ended, grid, out, replaced, extra }

    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        block = try c.decode(Int.self, forKey: .block)
        ended = try c.decode(Bool.self, forKey: .ended)
        grid = try c.decode([[Int]].self, forKey: .grid)
        out = try c.decode([Int].self, forKey: .out)
        replaced = try c.decode([Replacement].self, forKey: .replaced)
        // A web state saved before Extra minuten (#25) has no list; it reads as none, as in normaliseMatchState.
        extra = try c.decodeIfPresent([Int].self, forKey: .extra) ?? []
    }
}

/// A match in play. Every action returns a new state; the state before it is kept in `previous` for one undo.
public struct MatchState: Equatable, Sendable, Codable {
    /// The version of the stored shape, MATCH_VERSION in match.js. A state with another version is not restored.
    public static let currentVersion = 2

    public var version: Int
    /// Ties the state to the saved match setup, so a state from an older setup is never restored.
    public var setupSavedAt: String?
    public var schedule: String
    public var blocks: Int
    public var blockSeconds: Int
    public var blocksPerQuarter: Int
    public var players: [Int]
    /// The plan as set up; ties a saved state to its plan.
    public var base: [[Int]]
    /// The live plan: the credited line-up of every block. In the zone, uit and terug change it from the next block on.
    public var grid: [[Int]]
    /// The players marked uit, ascending.
    public var out: [Int]
    /// The replacements of the current block; the grid keeps the starter, whose block it is.
    public var replaced: [Replacement]
    /// One entry per block a player got through Extra minuten (decision #25).
    public var extra: [Int]
    /// The block being played, 1-based.
    public var block: Int
    public var ended: Bool
    public var previous: MatchSnapshot?

    public init(version: Int = MatchState.currentVersion, setupSavedAt: String?, schedule: String, blocks: Int,
                blockSeconds: Int, blocksPerQuarter: Int, players: [Int], base: [[Int]], grid: [[Int]], out: [Int],
                replaced: [Replacement], extra: [Int], block: Int, ended: Bool, previous: MatchSnapshot?) {
        self.version = version
        self.setupSavedAt = setupSavedAt
        self.schedule = schedule
        self.blocks = blocks
        self.blockSeconds = blockSeconds
        self.blocksPerQuarter = blocksPerQuarter
        self.players = players
        self.base = base
        self.grid = grid
        self.out = out
        self.replaced = replaced
        self.extra = extra
        self.block = block
        self.ended = ended
        self.previous = previous
    }

    enum CodingKeys: String, CodingKey {
        case version, setupSavedAt, schedule, blocks, blockSeconds, blocksPerQuarter, players, base, grid, out
        case replaced, extra, block, ended, previous
    }

    // Decoding reads any version, so `restored` can refuse an unknown one; `setupSavedAt` and `previous` must be
    // there, as null when empty, as the web app writes them.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decode(Int.self, forKey: .version)
        setupSavedAt = try c.decode(String?.self, forKey: .setupSavedAt)
        schedule = try c.decode(String.self, forKey: .schedule)
        blocks = try c.decode(Int.self, forKey: .blocks)
        blockSeconds = try c.decode(Int.self, forKey: .blockSeconds)
        blocksPerQuarter = try c.decode(Int.self, forKey: .blocksPerQuarter)
        players = try c.decode([Int].self, forKey: .players)
        base = try c.decode([[Int]].self, forKey: .base)
        grid = try c.decode([[Int]].self, forKey: .grid)
        out = try c.decode([Int].self, forKey: .out)
        replaced = try c.decode([Replacement].self, forKey: .replaced)
        extra = try c.decodeIfPresent([Int].self, forKey: .extra) ?? []
        block = try c.decode(Int.self, forKey: .block)
        ended = try c.decode(Bool.self, forKey: .ended)
        previous = try c.decode(MatchSnapshot?.self, forKey: .previous)
    }

    public func encode(to encoder: any Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(version, forKey: .version)
        try c.encode(setupSavedAt, forKey: .setupSavedAt)
        try c.encode(schedule, forKey: .schedule)
        try c.encode(blocks, forKey: .blocks)
        try c.encode(blockSeconds, forKey: .blockSeconds)
        try c.encode(blocksPerQuarter, forKey: .blocksPerQuarter)
        try c.encode(players, forKey: .players)
        try c.encode(base, forKey: .base)
        try c.encode(grid, forKey: .grid)
        try c.encode(out, forKey: .out)
        try c.encode(replaced, forKey: .replaced)
        try c.encode(extra, forKey: .extra)
        try c.encode(block, forKey: .block)
        try c.encode(ended, forKey: .ended)
        try c.encode(previous, forKey: .previous)
    }

    /// The live part of this state, as undo keeps it.
    var snapshot: MatchSnapshot {
        MatchSnapshot(block: block, ended: ended, grid: grid, out: out, replaced: replaced, extra: extra)
    }
}
