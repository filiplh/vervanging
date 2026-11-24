import Foundation
import Testing
import VervangingCore
@testable import Vervanging

/// The match file keeps a running match through a force-quit for every start time (#134): the setup's `savedAt` and
/// the state's `setupSavedAt` tie the two together as text, written once and carried from then on. Before #134 the
/// key was written again from a `Date` at every save and load, and a format-parse-format trip of the start time came
/// out 1 ms early for about half of all times, so the match was thrown away on relaunch. The text should still read
/// back as itself where the formatter can, because the team history names the match by it.
@MainActor
struct MatchStoreTests {
    let directory: URL
    let store: MatchStore

    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("match-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MatchStore(directory: directory)
    }

    /// A small fixed generator (SplitMix64), so a failure names a time that can be run again.
    struct SplitMix64: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// 5,000 start times between 2001 and 2100, most of them between whole milliseconds as `Date()` gives them.
    static func randomTimes() -> [Date] {
        var generator = SplitMix64(state: 134)
        return (0..<5000).map { _ in
            Date(timeIntervalSince1970: Double.random(in: 1_000_000_000...4_102_444_800, using: &generator))
        }
    }

    /// The whole `Date` domain in seconds since 1970, cut where the text behaves differently: beyond what the
    /// formatter writes (before -4712, after 506,713, where it writes one fixed date), the years -4712 to 0 (which it
    /// writes but cannot read back), the years 1 to 9999, up to 2^42 seconds and past it (where a `Date` steps by more
    /// than a millisecond), and past 2^53 milliseconds.
    static let domain: [ClosedRange<Double>] = [
        -Double.greatestFiniteMagnitude / 2 ... -1e15, -1e15 ... -220_000_000_000, -220_000_000_000 ... -62_167_392_000,
        -62_167_392_000 ... 0, 0 ... 253_402_300_800, 253_402_300_800 ... 4_398_046_511_104,
        4_398_046_511_104 ... 1e13, 1e13 ... 1e16, 1e16 ... Double.greatestFiniteMagnitude / 2,
    ]

    /// `count` start times from each part of the domain, after its edges.
    static func domainTimes(_ count: Int) -> [Date] {
        var generator = SplitMix64(state: 0x136134)
        let edges: [Date] = [
            .distantPast, .distantFuture, Date(timeIntervalSince1970: 0), Date(timeIntervalSince1970: -0.0005),
            Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude),
            Date(timeIntervalSinceReferenceDate: .greatestFiniteMagnitude),
            Date(timeIntervalSince1970: 253_402_300_799.999), Date(timeIntervalSince1970: 253_402_300_800),
            Date(timeIntervalSince1970: 4_398_046_511_104), Date(timeIntervalSince1970: 4_411_677_459_741.068),
            Date(timeIntervalSince1970: -62_167_392_000.5), Date(timeIntervalSince1970: -220_000_000_000.25),
        ]
        return edges + domain.flatMap { range in
            (0..<count).map { _ in Date(timeIntervalSince1970: Double.random(in: range, using: &generator)) }
        }
    }

    /// Starts a match at `time`, taps Wissel, relaunches, taps again and relaunches again. Nil when both relaunches
    /// found the match as it was left, else what went wrong.
    func forceQuitTwice(at time: Date) throws -> String? {
        let model = LiveModel.start(try Self.started(at: time), store: store)
        model.tapWissel()
        guard let first = store.load() else { return "\(time.timeIntervalSince1970): no match" }
        let restored = LiveModel(match: first, store: store)
        restored.tapWissel()
        let second = store.load()
        guard first.state == model.state, second?.state == restored.state, second?.state.block == 3 else {
            return "\(time.timeIntervalSince1970) \(MatchStore.isoString(time)): back at block \(second?.state.block ?? 0)"
        }
        return nil
    }

    /// Ten players, the basisvijf 1 to 5, gelijke minuten, started at `savedAt`.
    static func started(at savedAt: Date) throws -> StartedMatch {
        let players = (1...10).map { Player(id: $0, name: "Speler\($0)", number: String($0)) }
        let plan = try Planner.makePlan(players: players.map(\.id), start: [1, 2, 3, 4, 5], schedule: "equal", seed: 7)
        return StartedMatch(savedAt: savedAt, opponent: "", schedule: "equal", seed: 7, players: players,
                            startingFive: [1, 2, 3, 4, 5], plan: plan)
    }

    // MARK: - The start time's text

    @Test func everyStartTimeReadsBackAsTheSameText() {
        var lost: [String] = []
        for time in Self.randomTimes() {
            let text = MatchStore.isoString(time)
            guard let back = MatchStore.date(text) else {
                lost.append("\(text) does not read back")
                continue
            }
            if MatchStore.isoString(back) != text { lost.append("\(text) -> \(MatchStore.isoString(back))") }
        }
        #expect(lost.isEmpty, "\(lost.count) of 5000 lost, first: \(lost.prefix(3))")
    }

    @Test func theTextIsTheWebAppsToISOStringShape() throws {
        #expect(MatchStore.isoString(Date(timeIntervalSince1970: 1_795_000_000.002)) == "2026-11-18T11:06:40.002Z")
        #expect(MatchStore.isoString(Date(timeIntervalSince1970: 1_795_000_000)) == "2026-11-18T11:06:40.000Z")
        #expect(MatchStore.isoString(Date(timeIntervalSince1970: 1_795_000_000.9996)) == "2026-11-18T11:06:41.000Z",
                "a whole millisecond, carried into the second")
        #expect(MatchStore.isoString(Date(timeIntervalSince1970: 0.5)) == "1970-01-01T00:00:00.500Z")
        #expect(MatchStore.date("2026-11-18T11:06:40.002Z").map(MatchStore.isoString) == "2026-11-18T11:06:40.002Z")
        #expect(MatchStore.date("not a time") == nil)
    }

    /// Across the whole domain the text never traps, and every text the formatter reads back is written back as
    /// itself. Only the years before 1 give texts it refuses: one fixed text before -4712, which the stand-in for an
    /// unreadable start time writes too, and a text per time from -4712 to 0.
    @Test func overTheWholeDateDomainEveryReadableTextReadsBackAsItself() {
        let clamped = MatchStore.isoString(MatchStore.unreadableStartTime)
        #expect(clamped == "-4712-01-01T12:00:00.000Z")
        var lost: [String] = []
        for time in Self.domainTimes(5000) {
            let text = MatchStore.isoString(time)
            if let back = MatchStore.date(text) {
                if MatchStore.isoString(back) != text { lost.append("\(time.timeIntervalSince1970): \(text)") }
            } else if !text.hasPrefix("-") {
                lost.append("\(time.timeIntervalSince1970): \(text) does not read back")
            }
        }
        #expect(lost.isEmpty, "\(lost.count) lost, first: \(lost.prefix(3))")
        #expect(MatchStore.isoString(.distantPast) == "0001-01-01T00:00:00.000Z")
        #expect(MatchStore.isoString(Date(timeIntervalSinceReferenceDate: -.greatestFiniteMagnitude)) == clamped)
        #expect(MatchStore.isoString(Date(timeIntervalSince1970: -1e12 - 0.25)) == clamped, "no milliseconds there")
    }

    // MARK: - Save and restore

    @Test func aRunningMatchComesBackAfterAForceQuitForEveryStartTime() throws {
        var dropped: [String] = []
        for time in Self.randomTimes() {
            if let problem = try forceQuitTwice(at: time) { dropped.append(problem) }
        }
        #expect(dropped.isEmpty, "\(dropped.count) of 5000 dropped, first: \(dropped.prefix(3))")
    }

    /// The review of #136 found this time: its key was written as "…21.071Z" at the start and read back as "…21.073Z".
    @Test func aRunningMatchInTheYear141770ComesBack() throws {
        let time = Date(timeIntervalSince1970: 4_411_677_459_741.068)
        #expect(try forceQuitTwice(at: time) == nil)
        let match = try #require(store.load())
        let setup = try #require(try storedObject()["setup"] as? [String: Any])
        #expect(setup["savedAt"] as? String == match.state.setupSavedAt, "the key is written as the state carries it")
    }

    /// Every part of the domain, years far beyond 9999 and before 1 too: the match is kept through two relaunches,
    /// and where the formatter reads the key back, the setup's time is written as the key again (the team history's
    /// id).
    @Test func overTheWholeDateDomainARunningMatchComesBack() throws {
        var dropped: [String] = []
        var renamed: [String] = []
        for time in Self.domainTimes(150) {
            if let problem = try forceQuitTwice(at: time) {
                dropped.append(problem)
                continue
            }
            let match = try #require(store.load())
            let key = try #require(match.state.setupSavedAt)
            let readable = MatchStore.date(key) != nil || key == MatchStore.isoString(MatchStore.unreadableStartTime)
            if readable && MatchStore.isoString(match.setup.savedAt) != key { renamed.append(key) }
        }
        #expect(dropped.isEmpty, "\(dropped.count) dropped, first: \(dropped.prefix(3))")
        #expect(renamed.isEmpty, "\(renamed.count) written under another key, first: \(renamed.prefix(3))")
    }

    @Test func aStateFromAnotherSetupIsStillRefused() throws {
        let model = LiveModel.start(try Self.started(at: Date(timeIntervalSince1970: 1_795_000_000.002)), store: store)
        model.tapWissel()
        #expect(try #require(store.load()).state.block == 2)
        var object = try storedObject()
        var setup = try #require(object["setup"] as? [String: Any])
        setup["savedAt"] = "2026-11-18T11:06:40.003Z"
        object["setup"] = setup
        try JSONSerialization.data(withJSONObject: object).write(to: store.fileURL)
        let foreign = try #require(store.load())
        #expect(foreign.state.block == 1, "a state tied to another start time starts again at block 1")
        #expect(foreign.state.setupSavedAt == "2026-11-18T11:06:40.003Z")
    }

    /// A start time the formatter cannot read back still keeps its match, under its own text.
    @Test func aStartTimeBeforeTheYearOneKeepsItsMatch() throws {
        for time in [Date(timeIntervalSince1970: -150_089_466_210.625), Date(timeIntervalSince1970: -1e14)] {
            #expect(try forceQuitTwice(at: time) == nil)
            let match = try #require(store.load())
            #expect(match.state.setupSavedAt == MatchStore.isoString(time))
        }
    }

    func storedObject() throws -> [String: Any] {
        try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: store.fileURL)) as? [String: Any])
    }

    /// A match.json exactly as the build before #134 wrote it, at a start time whose text that build could not read
    /// back exactly: that build threw this match away on relaunch and started again at block 1.
    @Test func aMatchFileWrittenBeforeTheFixStillRestores() throws {
        try Data(Self.oldMatchFile.utf8).write(to: store.fileURL)
        let match = try #require(store.load())
        #expect(match.state.block == 2)
        #expect(match.state.setupSavedAt == "2026-11-18T11:06:40.004Z")
        #expect(MatchStore.isoString(match.setup.savedAt) == "2026-11-18T11:06:40.004Z")
        // Saved again by this build, it is the same file.
        #expect(store.save(match))
        let again = try String(contentsOf: store.fileURL, encoding: .utf8)
        #expect(again == Self.oldMatchFile)
    }

    static let oldMatchFile = #"""
{"setup":{"opponent":"","plan":{"grid":[[1,2,3,4,5],[1,4,5,7,9],[4,7,8,9,10],[2,6,8,9,10],[1,2,3,6,10],[1,3,5,6,7],[3,4,5,7,8],[4,5,8,9,10],[1,2,4,9,10],[1,2,6,7,9],[2,3,6,7,8],[3,5,6,8,10]],"sitLimitRelaxed":false,"start":[1,2,3,4,5]},"players":[{"id":1,"name":"Speler1","number":"1"},{"id":2,"name":"Speler2","number":"2"},{"id":3,"name":"Speler3","number":"3"},{"id":4,"name":"Speler4","number":"4"},{"id":5,"name":"Speler5","number":"5"},{"id":6,"name":"Speler6","number":"6"},{"id":7,"name":"Speler7","number":"7"},{"id":8,"name":"Speler8","number":"8"},{"id":9,"name":"Speler9","number":"9"},{"id":10,"name":"Speler10","number":"10"}],"savedAt":"2026-11-18T11:06:40.004Z","schedule":"equal","seed":7,"startingFive":[1,2,3,4,5]},"state":{"base":[[1,2,3,4,5],[1,4,5,7,9],[4,7,8,9,10],[2,6,8,9,10],[1,2,3,6,10],[1,3,5,6,7],[3,4,5,7,8],[4,5,8,9,10],[1,2,4,9,10],[1,2,6,7,9],[2,3,6,7,8],[3,5,6,8,10]],"block":2,"blockSeconds":200,"blocks":12,"blocksPerQuarter":3,"ended":false,"extra":[],"grid":[[1,2,3,4,5],[1,4,5,7,9],[4,7,8,9,10],[2,6,8,9,10],[1,2,3,6,10],[1,3,5,6,7],[3,4,5,7,8],[4,5,8,9,10],[1,2,4,9,10],[1,2,6,7,9],[2,3,6,7,8],[3,5,6,8,10]],"out":[],"players":[1,2,3,4,5,6,7,8,9,10],"previous":{"block":1,"ended":false,"extra":[],"grid":[[1,2,3,4,5],[1,4,5,7,9],[4,7,8,9,10],[2,6,8,9,10],[1,2,3,6,10],[1,3,5,6,7],[3,4,5,7,8],[4,5,8,9,10],[1,2,4,9,10],[1,2,6,7,9],[2,3,6,7,8],[3,5,6,8,10]],"out":[],"replaced":[]},"replaced":[],"schedule":"equal","setupSavedAt":"2026-11-18T11:06:40.004Z","version":2},"version":1}
"""#
}
