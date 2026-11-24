import Foundation
import Testing
import VervangingCore
@testable import Vervanging

/// The match file keeps a running match through a force-quit for every start time (#134): the setup's `savedAt` and
/// the state's `setupSavedAt` tie the two together, so the text written for a start time must read back as the same
/// time and be written again as the same text. Before #134 a format-parse-format trip of the start time came out 1 ms
/// early for about half of all times, and the match was thrown away on relaunch.
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

    // MARK: - Save and restore

    @Test func aRunningMatchComesBackAfterAForceQuitForEveryStartTime() throws {
        var dropped: [String] = []
        for time in Self.randomTimes() {
            let model = LiveModel.start(try Self.started(at: time), store: store)
            model.tapWissel()
            guard let first = store.load() else {
                dropped.append("\(MatchStore.isoString(time)): no match")
                continue
            }
            // A second relaunch, after a tap on the restored match, must find it again too.
            let restored = LiveModel(match: first, store: store)
            restored.tapWissel()
            let second = store.load()
            if first.state != model.state || second?.state != restored.state || second?.state.block != 3 {
                dropped.append(MatchStore.isoString(time))
            }
        }
        #expect(dropped.isEmpty, "\(dropped.count) of 5000 dropped, first: \(dropped.prefix(3))")
    }

    @Test func aStateFromAnotherSetupIsStillRefused() throws {
        let model = LiveModel.start(try Self.started(at: Date(timeIntervalSince1970: 1_795_000_000.002)), store: store)
        model.tapWissel()
        var match = try #require(store.load())
        #expect(match.state.block == 2)
        match.setup.savedAt = Date(timeIntervalSince1970: 1_795_000_000.003)
        #expect(store.save(match))
        let foreign = try #require(store.load())
        #expect(foreign.state.block == 1, "a state tied to another start time starts again at block 1")
        #expect(foreign.state.setupSavedAt == "2026-11-18T11:06:40.003Z")
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
