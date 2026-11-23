import Foundation
import Testing
@testable import VervangingCore

// Ported from public/js/history.test.js (plan decisions #10 the history switch, #26 season totals, #28 catch-up). The
// exact expected values below are what public/js/history.js gives for the same input, printed by Node; the shared
// examples check the rest through `vervanging-sim check-examples`.

private func ids(_ n: Int) -> [Int] { Array(1...n) }

private let repoRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

private func fixtureText(_ name: String) throws -> String {
    try String(contentsOf: repoRoot.appendingPathComponent("scripts/fixtures/\(name)"), encoding: .utf8)
}

private func fixture(_ name: String) throws -> History { try History(json: try fixtureText(name)) }

/// catchUp's [behind, ahead] moves as a block change per player id.
private func deltas(_ moves: [[Int]]) -> [Int: Int] {
    var d: [Int: Int] = [:]
    for move in moves {
        d[move[0], default: 0] += 1
        d[move[1], default: 0] -= 1
    }
    return d
}

/// Seconds for players 1...n, as the JS tests' `full(n, secs)`.
private func full(_ n: Int, _ secs: (Int) -> Double) -> JSObject<Double> {
    var seconds = JSObject<Double>()
    for p in ids(n) { seconds[String(p)] = secs(p) }
    return seconds
}

private func history(_ matches: [HistoryMatch]) -> History { History(useHistory: true, matches: matches) }

private func plan(_ n: Int, start: [Int], schedule: String, seed: Int, catchUp: CatchUp = CatchUp()) throws -> Plan {
    try Planner.makePlan(players: ids(n), start: start, schedule: schedule, seed: seed,
                         extraPriority: catchUp.priority, moves: catchUp.moves)
}

private func minutes(_ plan: Plan) -> [Int: Int] { Planner.planStats(plan).minutes }

@Suite struct HistoryTests {
    @Test func normaliseHistoryDropsDamagedValuesBadEntriesAndBadSeconds() throws {
        for raw in ["null", "42", "\"x\"", "[]", "{}", "{\"matches\":\"x\"}", "{\"matches\":{}}"] {
            #expect(try History(json: raw) == History(), "\(raw)")
        }
        #expect(try History(json: "{\"useHistory\":\"true\",\"matches\":[]}").useHistory == false,
                "only true switches it on")
        let cleaned = try History(json: """
            {"useHistory":true,"matches":[null,"x",{"id":3,"seconds":{}},{"id":"","seconds":{}},{"id":"a","seconds":[]},
            {"id":"b"},{"id":"c","seconds":{"1":600,"2":-1,"3":"x","4":null,"x":5,"5":1e400,"1.5":3,"6":0}},
            {"id":"d","seconds":{"1":1}},{"id":"d","seconds":{"1":2}}]}
            """)
        #expect(cleaned == History(useHistory: true, clearedAt: nil, matches: [
            HistoryMatch(id: "c", seconds: ["1": 600, "6": 0]), HistoryMatch(id: "d", seconds: ["1": 2]),
        ]))
    }

    @Test func theSampleFixtureHasTheStoredShape() throws {
        let text = try fixtureText("history-sample.json")
        let history = try History(json: text)
        #expect(try JSONValue.parse(history.json, keep: 10) == JSONValue.parse(text, keep: 10),
                "nothing is dropped from the fixture")
        let totals = history.totalSeconds()
        for p in ids(12) { #expect(totals[String(p)] == (p <= 4 ? 0 : 3000), "player \(p)") }
    }

    @Test func recordAddsOncePerIDForgetRemovesClearKeepsTheSwitch() {
        var h = History()
        h = h.recording("m1", seconds: ["1": 600, "2": 400])
        h = h.recording("m1", seconds: ["1": 700, "2": 300]) // ended again after an undo, or recorded twice
        #expect(h.matches == [HistoryMatch(id: "m1", seconds: ["1": 700, "2": 300])])
        h = h.recording("m2", seconds: ["1": 100, "3": 900])
        #expect(h.has("m2"))
        #expect(h.totalSeconds() == ["1": 800, "2": 300, "3": 900])
        h = h.forgetting("m1")
        #expect(h.totalSeconds() == ["1": 100, "3": 900])
        #expect(!h.has("m1"))
        var on = h
        on.useHistory = true
        #expect(on.cleared(at: "2026-11-22T10:00:00.000Z")
            == History(useHistory: true, clearedAt: "2026-11-22T10:00:00.000Z", matches: []))
    }

    @Test func clearedAtIsKeptWhenItIsATimeAndStartedAfterClearComparesWithTheSetupTime() throws {
        #expect(try History(json: "{\"clearedAt\":\"2026-11-22T10:00:00.000Z\"}").clearedAt
            == "2026-11-22T10:00:00.000Z")
        for clearedAt in ["42", "\"gisteren\"", "\"\"", "null", "{}"] {
            #expect(try History(json: "{\"clearedAt\":\(clearedAt)}").clearedAt == nil, "\(clearedAt)")
        }
        let cleared = History().cleared(at: "2026-11-22T10:00:00.000Z")
        #expect(History().startedAfterClear("2026-01-01T00:00:00.000Z"), "never cleared")
        #expect(!cleared.startedAfterClear("2026-11-22T09:59:59.999Z"))
        #expect(!cleared.startedAfterClear("2026-11-22T10:00:00.000Z"))
        #expect(cleared.startedAfterClear("2026-11-22T10:00:00.001Z"))
        #expect(!cleared.startedAfterClear("kapot"))
    }

    @Test func extraPriorityPutsFewestSecondsFirstIgnoresAbsentPlayersAndCountsUnknownOnesAs0() {
        let h = History().recording("m1", seconds: ["1": 900, "2": 300, "3": 600, "99": 0])
        // 99 is in the history but not present; 4 is present but not in the history.
        #expect(h.extraPriority([1, 2, 3, 4], seed: 7) == [4, 2, 3, 1])
    }

    @Test func extraPriorityOrdersTiesAtRandomFromTheSeed() throws {
        let players = ids(12)
        var orders = Set<[Int]>()
        for seed in 1...20 {
            let order = History().extraPriority(players, seed: seed)
            #expect(order.sorted() == players, "every present player, once")
            #expect(History().extraPriority(players, seed: seed) == order, "deterministic")
            orders.insert(order)
        }
        #expect(orders.count > 1, "different seeds give different tie orders")
        // The exact tie orders public/js/history.js gives.
        #expect(History().extraPriority(players, seed: 1) == [5, 11, 3, 7, 10, 4, 2, 12, 9, 6, 1, 8])
        #expect(History().extraPriority(players, seed: 2) == [6, 7, 1, 11, 2, 10, 12, 8, 5, 3, 4, 9])
        let order = try fixture("history-sample.json").extraPriority(players, seed: 3)
        #expect(order.prefix(4).sorted() == [1, 2, 3, 4])
    }

    @Test func withTheSwitchOnTheExtraBlocksGoToThePlayersWhoPlayedLeast() throws {
        let sample = try fixture("history-sample.json")
        for seed in 1...10 {
            let p = try plan(12, start: [1, 5, 6, 7, 8], schedule: "five", seed: seed,
                             catchUp: CatchUp(priority: sample.extraPriority(ids(12), seed: seed)))
            for player in ids(12) {
                #expect(minutes(p)[player] == (player <= 4 ? 1200 : 900), "seed \(seed), player \(player)")
            }
        }
    }

    @Test func withTheSwitchOffOrAnEmptyHistoryThePlanIsTheOneTheSeedGives() throws {
        for seed in 1...5 {
            let base = try plan(10, start: [1, 2, 3, 4, 5], schedule: "equal", seed: seed)
            let off = try plan(10, start: [1, 2, 3, 4, 5], schedule: "equal", seed: seed, catchUp: CatchUp(priority: []))
            #expect(off == base)
            // With an empty history the switch still works: every player ties at 0, so the extras are random.
            let empty = try plan(10, start: [1, 2, 3, 4, 5], schedule: "equal", seed: seed,
                                 catchUp: CatchUp(priority: History().extraPriority(ids(10), seed: seed)))
            let seconds = Array(minutes(empty).values)
            #expect(seconds.reduce(0, +) == 5 * 12 * 200)
            #expect(seconds.max()! - seconds.min()! <= 200)
        }
    }

    @Test func playersInTheHistoryWhoAreNotPresentTakeNoExtraPlace() throws {
        // Players 11 and 12 never played but are absent today; among the present ones, 1 to 4 played least.
        let h = History().recording("m1", seconds: full(12) { $0 <= 4 ? 100 : ($0 <= 10 ? 3000 : 0) })
        let nine = ids(9) // five: 40 places for 9 players, 4 each and 4 extras
        #expect(!h.extraPriority(nine, seed: 1).contains(11))
        let p = try plan(9, start: [1, 5, 6, 7, 8], schedule: "five", seed: 2,
                         catchUp: CatchUp(priority: h.extraPriority(nine, seed: 2)))
        for player in nine { #expect(minutes(p)[player] == (player <= 4 ? 1500 : 1200), "player \(player)") }
    }

    // ---------- season totals (decision #26) ----------

    @Test func seasonSummaryCountsPlayersOnlyInTheMatchesTheyPlayed() throws {
        var h = History()
        h = h.recording("m1", seconds: ["1": 600, "2": 1200, "3": 0])
        h = h.recording("m2", seconds: ["1": 900, "4": 300]) // 2 and 3 absent
        h = h.recording("m3", seconds: ["2": 2400.5, "4": 3600])
        #expect(h.seasonSummary() == SeasonSummary(matches: 3, totals: ["1": 1500, "2": 3600.5, "3": 0, "4": 3900]))
        #expect(h.seasonSummary().json == "{\"matches\":3,\"totals\":{\"1\":1500,\"2\":3600.5,\"3\":0,\"4\":3900}}")
        #expect(try fixture("history-sample.json").seasonSummary().matches == 2)
    }

    @Test func seasonSummaryOfAnEmptyAClearedAndADamagedHistoryIsEmpty() throws {
        let none = SeasonSummary(matches: 0, totals: [:])
        #expect(History().seasonSummary() == none)
        #expect(try fixture("history-sample.json").cleared(at: "2026-11-22T10:00:00.000Z").seasonSummary() == none)
        for raw in ["null", "\"x\"", "[]", "{\"matches\":\"x\"}", "{\"matches\":[null,{\"id\":3},{\"id\":\"a\",\"seconds\":[]}]}"] {
            #expect(try History(json: raw).seasonSummary() == none, "\(raw)")
        }
        // Damaged seconds inside a good entry are dropped, the rest still counts.
        let partly = try History(json: """
            {"matches":[{"id":"a","seconds":{"1":600,"2":-5,"3":"x"}},{"id":"b","seconds":{"1":60}}]}
            """)
        #expect(partly.seasonSummary() == SeasonSummary(matches: 2, totals: ["1": 660]))
    }

    @Test func seasonTotalsListKeysInJavaScriptOrder() throws {
        // Array-index keys first in ascending order, then the other keys in the order they were first added; the
        // JSON is what JSON.stringify(seasonSummary(...)) printed in Node.
        let h = try History(json: """
            {"matches":[{"id":"a","seconds":{"9":1,"02":1,"x":1,"01":1,"4294967295":2,"4294967294":3}},
            {"id":"b","seconds":{"01":2,"003":1,"0":4}}]}
            """)
        #expect(h.seasonSummary().json
            == "{\"matches\":2,\"totals\":{\"0\":4,\"9\":1,\"4294967294\":3,\"02\":1,\"01\":3,\"4294967295\":2,\"003\":1}}")
        // A total beyond the largest Double is Infinity, which JSON.stringify writes as null.
        let huge = try History(json: "{\"matches\":[{\"id\":\"a\",\"seconds\":{\"1\":1e308}},{\"id\":\"b\",\"seconds\":{\"1\":1e308}}]}")
        #expect(huge.seasonSummary().json == "{\"matches\":2,\"totals\":{\"1\":null}}")
    }

    @Test func matchIDsAreComparedByTheirCodeUnitsAsInJavaScript() throws {
        // "é" and "e" + U+0301 are equal Swift Strings but two different JavaScript strings, so two matches.
        let h = try History(json: """
            {"matches":[{"id":"\\u00e9","seconds":{"1":1}},{"id":"e\\u0301","seconds":{"1":2}}]}
            """)
        #expect(h.matches.count == 2)
        #expect(h.recording("\u{212A}", seconds: ["1": 1]).recording("K", seconds: ["1": 1]).matches.count == 4)
        #expect(!h.has("e"))
    }

    // Review of #121 (P2): escaped lone surrogates became U+FFFD, so "\ud800" and "\ud801" were one id and the later
    // match replaced the earlier one, which changed the totals and the catch-up plan.
    @Test func escapedLoneSurrogatesInIDsStayDistinctAsInJavaScript() throws {
        let h = try History(json: #"{"matches":[{"id":"\ud800","seconds":{"1":200}},{"id":"\ud801","seconds":{"2":300}}]}"#)
        #expect(h.matches.map(\.id) == [JSString(utf16: [0xD800]), JSString(utf16: [0xD801])])
        #expect(h.seasonSummary().json == #"{"matches":2,"totals":{"1":200,"2":300}}"#)
        #expect(h.has(JSString(utf16: [0xD800])) && !h.has("\u{FFFD}"))
        #expect(h.recording(JSString(utf16: [0xD801]), seconds: ["3": 5]).matches.count == 2, "the same id replaces")
        #expect(h.recording("\u{FFFD}", seconds: ["3": 5]).matches.count == 3, "U+FFFD is another id")
    }

    @Test func aLiteralAndAnEscapedFFFDAreOneIDApartFromALoneSurrogate() throws {
        // What JSON.stringify(normaliseHistory(JSON.parse(text))) printed in Node: "�" and the literal U+FFFD are
        // the same id (the later wins), "\ud800" is another; lone surrogates are written back escaped, pairs as they
        // are.
        let text = #"""
            {"clearedAt":null,"matches":[{"id":"\ud800","seconds":{"1":1}},{"id":"�","seconds":{"1":2}},
            {"id":"\udc00\ud800x😀","seconds":{"1":4}},{"id":"�","seconds":{"1":3}}]}
            """#
        let h = try History(json: text)
        #expect(h.json == #"""
            {"useHistory":false,"clearedAt":null,"matches":[{"id":"\ud800","seconds":{"1":1}},\#
            {"id":"\udc00\ud800x😀","seconds":{"1":4}},{"id":"�","seconds":{"1":3}}]}
            """#)
        #expect(try History(json: h.json) == h)
        #expect(h.matches.map(\.id) == [JSString(utf16: [0xD800]), JSString(utf16: [0xDC00, 0xD800, 0x78, 0xD83D, 0xDE00]),
                                        JSString(utf16: [0xFFFD])])
    }

    @Test func theStoredJSONIsWhatJSONStringifyWrites() throws {
        let h = try History(json: """
            {"useHistory":true,"clearedAt":"2026-11-22T10:00:00.000Z",
            "matches":[{"id":"q\\"\\\\\\n\\u0001é","seconds":{"2":1.5,"1":600},"extra":{"1":100}}]}
            """)
        #expect(h.json == """
            {"useHistory":true,"clearedAt":"2026-11-22T10:00:00.000Z","matches":[{"id":"q\\"\\\\\\n\\u0001é",\
            "seconds":{"1":600,"2":1.5},"extra":{"1":100}}]}
            """)
        #expect(try History(json: h.json) == h)
    }

    // ---------- catch-up (#34, decision #28) ----------

    @Test func recordKeepsExtraSecondsApartOldEntriesLoadAndDamagedExtraIsDropped() throws {
        let h = History().recording("a", seconds: ["1": 1200, "2": 800], extra: ["1": 200, "2": 0, "9": 200])
        #expect(h.matches[0].extra == ["1": 200], "only players with seconds, above 0")
        #expect(try History(json: "{\"matches\":[{\"id\":\"x\",\"seconds\":{\"1\":600}}]}").matches[0].extra == nil)
        let damaged = try History(json: """
            {"matches":[{"id":"x","seconds":{"1":600},"extra":{"1":"lots","2":200,"1.5":3}}]}
            """)
        #expect(damaged.matches[0].extra == nil)
        let capped = try History(json: "{\"matches\":[{\"id\":\"x\",\"seconds\":{\"1\":600},\"extra\":{\"1\":900}}]}")
        #expect(capped.matches[0].extra == ["1": 600], "extra is never more than the seconds")
    }

    @Test func catchUpSecondsLeavesExtraMinutenOutSeasonSummaryStillCountsThem() {
        let h = history([HistoryMatch(id: "a", seconds: ["1": 1200, "2": 1000], extra: ["1": 200])])
        #expect(h.catchUpSeconds() == ["1": 1000, "2": 1000])
        #expect(h.seasonSummary().totals == ["1": 1200, "2": 1000])
    }

    @Test func aPlayerABlockBehindGetsOneMoreAndTheFurthestAheadOneLess() {
        let equal = Planner.schedules["equal"]!
        let behind = history([HistoryMatch(id: "m", seconds: full(12) { $0 == 12 ? 2000 : 3000 })])
        let moves = behind.catchUp(ids(12), schedule: equal, seed: 1).moves
        #expect(moves.count == 1)
        #expect(moves.first?[0] == 12)
        #expect(moves.first?[1] != 12)
        let close = history([HistoryMatch(id: "m", seconds: full(12) { $0 == 12 ? 2900 : 3000 })])
        #expect(close.catchUp(ids(12), schedule: equal, seed: 1).moves == [], "less than one block apart")
        #expect(history([]).catchUp(ids(12), schedule: equal, seed: 1).moves == [], "empty history")
    }

    @Test func severalPlayersBehindEachGetOneBlockAtMost() {
        let h = history([HistoryMatch(id: "m", seconds: full(12) { $0 <= 3 ? 0 : 5000 })])
        let moves = h.catchUp(ids(12), schedule: Planner.schedules["equal"]!, seed: 1).moves
        let adjust = deltas(moves)
        #expect([1, 2, 3].map { adjust[$0] } == [1, 1, 1])
        #expect(adjust.values.allSatisfy { $0 == 1 || $0 == -1 }, "nobody is in two moves")
        #expect(moves.count == 3)
    }

    @Test func aLeadThatIsAllExtraMinutenIsNotTakenBack() {
        let h = history([
            HistoryMatch(id: "a", seconds: full(12) { $0 == 5 ? 1200 : 1000 }, extra: ["5": 200]),
            HistoryMatch(id: "b", seconds: full(12) { _ in 1000 }),
        ])
        #expect(h.catchUp(ids(12), schedule: Planner.schedules["equal"]!, seed: 1).moves == [])
    }

    @Test func aPlayerWhoAlreadyHasAnUnevenPlaceGetsNoExtraBlockOnTop() {
        // 11 players, equal schedule: 60 places, base 5, five players get 6; the fewest-seconds players get those.
        let h = history([HistoryMatch(id: "m", seconds: full(11) { $0 <= 6 ? 0 : 5000 })])
        let result = h.catchUp(ids(11), schedule: Planner.schedules["equal"]!, seed: 1)
        let adjust = deltas(result.moves)
        for p in result.priority.prefix(5) { #expect(adjust[p] != 1, "player \(p) has an uneven place already") }
    }

    @Test func catchUpGivesExactlyWhatTheJavaScriptGivesForTheFixtures() throws {
        let equal = Planner.schedules["equal"]!, five = Planner.schedules["five"]!
        let cases: [(String, Int, ScheduleShape, Int, CatchUp)] = [
            ("catchup", 12, equal, 5, CatchUp(priority: [12, 11, 2, 8, 4, 10, 7, 5, 1, 6, 3, 9], moves: [[12, 9]])),
            ("catchup", 12, five, 3, CatchUp(priority: [12, 6, 10, 8, 2, 3, 4, 7, 11, 5, 1, 9], moves: [])),
            ("reward", 12, equal, 5, CatchUp(priority: [11, 2, 8, 4, 10, 7, 5, 1, 6, 3, 12, 9], moves: [])),
            ("sample", 12, equal, 5, CatchUp(priority: [2, 4, 1, 3, 11, 8, 10, 7, 5, 6, 12, 9],
                                             moves: [[2, 9], [4, 12], [1, 6], [3, 5]])),
            ("sit-relaxed", 16, equal, 5, CatchUp(priority: [6, 1, 14, 10, 5, 2, 9, 4, 3, 12, 11, 13, 7, 16, 15, 8],
                                                  moves: [[7, 8], [16, 15]])),
            ("sit-relaxed", 16, five, 3, CatchUp(priority: [14, 9, 4, 2, 5, 6, 10, 1, 3, 12, 11, 13, 7, 16, 8, 15],
                                                 moves: [[3, 15], [12, 8], [11, 16], [13, 7]])),
        ]
        for (name, n, schedule, seed, expected) in cases {
            #expect(try fixture("history-\(name).json").catchUp(ids(n), schedule: schedule, seed: seed) == expected,
                    "\(name), seed \(seed)")
        }
        #expect(History().catchUp([], schedule: equal) == CatchUp(), "no players: nothing to order or move")
    }

    /// The sub rule (#21) and the one-block limit for one catch-up plan.
    @discardableResult
    private func checkCatchUpPlan(_ h: History, _ n: Int, start: [Int], schedule: String, seed: Int,
                                  _ label: String) throws -> (plan: Plan, plain: Plan, moves: [[Int]]) {
        let result = h.catchUp(ids(n), schedule: Planner.schedules[schedule]!, seed: seed)
        let p = try plan(n, start: start, schedule: schedule, seed: seed, catchUp: result)
        let plain = try plan(n, start: start, schedule: schedule, seed: seed,
                             catchUp: CatchUp(priority: result.priority))
        #expect(Planner.maxSubsFrom(p.grid) <= 3, "\(label): at most 3 subs")
        let stats = Planner.planStats(p)
        #expect(!p.sitLimitRelaxed && stats.longestBenchSeconds <= 900, "\(label): nobody sits more than 15:00")
        let plainStats = Planner.planStats(plain)
        let stintLimit = max(600, 3 * p.blockSeconds) // the planner's stint limit (searchGrid)
        if plainStats.longestStintSeconds <= stintLimit {
            #expect(stats.longestStintSeconds <= stintLimit, "\(label): no longer stint than the plain plan's limit")
        }
        if Planner.maxSubsFrom(plain.grid) <= 2 {
            #expect(Planner.maxSubsFrom(p.grid) <= 2, "\(label): still at most 2 subs")
        }
        for player in ids(n) {
            #expect(abs(stats.minutes[player]! - plainStats.minutes[player]!) <= p.blockSeconds,
                    "\(label): player \(player) moves at most one block")
        }
        return (p, plain, result.moves)
    }

    @Test(arguments: ["equal", "five"])
    func catchUpPlansKeepTheSubRuleForRandomHistoriesAndStartingFives(schedule: String) throws {
        var random = SeededRandom(seed: 42)
        let blockSeconds = Double(Planner.schedules[schedule]!.blockSeconds)
        for n in 8...12 {
            for k in 0..<10 {
                let seconds = full(n) { _ in (random.next() * 6).rounded(.down) * blockSeconds }
                let h = history([HistoryMatch(id: "m", seconds: seconds)])
                // Half the runs start with the five players furthest ahead (the ones who give blocks), half with a
                // random five.
                let start = k % 2 == 1
                    ? Planner.shuffled(ids(n), &random)
                    : ids(n).sorted { seconds[String($0)]! > seconds[String($1)]! || (seconds[String($0)]! == seconds[String($1)]! && $0 < $1) }
                try checkCatchUpPlan(h, n, start: Array(start.prefix(5)), schedule: schedule, seed: k + 1,
                                     "\(schedule) \(n) history \(k)")
            }
        }
    }

    @Test func catchUpKeepsTheStintLimitThePlainPlanKeeps() throws {
        // Re-review of #40: 8 players, five schedule.
        let h = history([HistoryMatch(id: "past", seconds: ["1": 3000, "2": 3000, "3": 3000, "4": 3000, "5": 3000])])
        let (p, plain, _) = try checkCatchUpPlan(h, 8, start: [1, 2, 3, 4, 5], schedule: "five", seed: 1, "8 players")
        #expect(Planner.planStats(plain).longestStintSeconds <= 900, "the plain plan keeps the stint limit")
        #expect(Planner.planStats(p).longestStintSeconds <= 900, "so the catch-up plan does too")
    }

    @Test func catchUpTakesOnlyTheMovesThatStillFitTheSitLimit() throws {
        // Review of #40: all four givers in the starting five.
        let h = history([HistoryMatch(id: "past", seconds: ["1": 3000, "2": 3000, "3": 3000, "4": 3000])])
        for seed in 1...5 {
            let (p, plain, moves) = try checkCatchUpPlan(h, 12, start: [1, 2, 3, 4, 5], schedule: "five", seed: seed,
                                                         "seed \(seed)")
            #expect(moves.count == 4, "catchUp asks for four moves")
            #expect(p.grid != plain.grid, "seed \(seed): at least one move still fits")
        }
    }
}

// ---------- what the history needs of JSON.parse and Date.parse ----------

@Suite struct HistoryJSONTests {
    @Test(arguments: ["", " ", "\u{FEFF}{}", "\u{A0}{}", "{", "{\"a\":1,}", "[1,]", "01", "-", "1.", ".5", "1e",
                      "\"\\x\"", "\"\t\"", "{\"a\" 1}", "tru", "nulls", "\"\\u12\"", "NaN", "Infinity", "'x'", "[1] 2"])
    func textThatJSONParseRefusesIsNotJSON(text: String) {
        #expect(throws: NotJSON.self) { try History(json: text) }
    }

    @Test func numbersAndStringsReadAsJSONParseReadsThem() throws {
        let value = try JSONValue.parse("""
             \t\r\n[-0, 1.5e2, 1E-7, 12345678901234567890, 1e400, "\\u0041\\/\\b\\f\\n\\r\\t\\"\\\\", "\\ud83d\\ude00", true, false, null]
            """, keep: 1)
        guard case .array(let items) = value else { Issue.record("not an array"); return }
        #expect(items.count == 10)
        #expect(items[0] == .number(0) && items[1] == .number(150) && items[2] == .number(1e-7))
        #expect(items[3] == .number(12_345_678_901_234_567_168)) // the nearest Double
        #expect(items[4] == .number(.infinity))
        #expect(items[5] == .string("A/\u{08}\u{0C}\n\r\t\"\\"))
        #expect(items[6] == .string("😀"))
        #expect(items[7] == .bool(true) && items[8] == .bool(false) && items[9] == .null)
    }

    @Test func aDuplicateKeyKeepsItsFirstPlaceAndTakesTheLastValue() throws {
        let value = try JSONValue.parse("{\"b\":1,\"a\":2,\"b\":3}", keep: 1)
        guard case .object(let object) = value else { Issue.record("not an object"); return }
        #expect(object.keys == ["b", "a"])
        #expect(object["b"] == .number(3))
    }

    @Test func anyNestingDepthIsReadButOnlyTheKeptDepthIsKept() throws {
        let depth = 200_000
        let deep = String(repeating: "[", count: depth) + String(repeating: "]", count: depth)
        #expect(try JSONValue.parse("[\(deep)]", keep: 1) == .array([.deeper(isArray: true)]))
        #expect(throws: NotJSON.self) { try JSONValue.parse("[\(deep)", keep: 1) }
        let h = try History(json: "{\"x\":\(deep),\"matches\":[{\"id\":\"a\",\"seconds\":{\"5\":1,\"6\":\(deep)}}]}")
        #expect(h.matches == [HistoryMatch(id: "a", seconds: ["5": 1])])
    }

    // Date.parse in Node 22 gave these values (nil where it gave NaN).
    @Test(arguments: [
        ("2026-11-22T10:00:00.000Z", 1795341600000), ("2026", 1767225600000), ("2026-11", 1793491200000),
        ("2026-11-22", 1795305600000), ("2026-11-22T10:00Z", 1795341600000),
        ("2026-11-22T10:00:00.1Z", 1795341600100), ("2026-11-22T10:00:00.12345Z", 1795341600123),
        ("2026-11-22T10:00:00.000+01:00", 1795338000000), ("2026-11-22T10:00:00.000-05:30", 1795361400000),
        ("2026-02-30", 1772409600000), ("2026-02-31T00:00Z", 1772496000000), ("2026-02-32", nil),
        ("2026-13-01", nil), ("2026-00-01", nil), ("2026-11-00", nil), ("2026-11-22T24:00Z", 1795392000000),
        ("2026-11-22T24:00:01Z", nil), ("2026-11-22T23:60Z", nil), ("2026-11-22T10:00:60Z", nil),
        ("+002026-11-22T10:00Z", 1795341600000), ("-000000-01-01T00:00Z", nil),
        ("+275760-09-13T00:00:00.000Z", 8640000000000000), ("+275760-09-13T00:00:00.001Z", nil),
        ("-271821-04-20T00:00Z", -8640000000000000), ("-271821-04-19T23:59:59.999Z", nil), ("2026-11-22T10Z", nil),
        ("2026-11-22T10:00+01", nil), ("2026-11-22T10:00:00.Z", nil), ("2026-11-22T10:00+24:00", nil),
        ("2026-11-22T10:00+23:59", 1795255260000), ("20261122", nil), ("1970-01-01T00:00:00.000Z", 0),
        ("1969-12-31T23:59:59.999Z", -1), ("-000001-12-31T00:00Z", -62167305600000),
        ("0000-03-01T00:00Z", -62162035200000), ("2000-02-29T00:00Z", 951782400000),
        ("1900-02-29T00:00Z", -2203891200000), ("2026T10:00Z", 1767261600000), ("2026-11T10:00Z", 1793527200000),
        ("gisteren", nil), ("", nil), ("kapot", nil), ("2026-11-22T10:00:00.000Z ", nil),
    ] as [(String, Double?)])
    func isoTimesReadAsDateParseReadsThem(text: String, expected: Double?) {
        #expect(javaScriptISOTime(text) == expected)
    }
}
