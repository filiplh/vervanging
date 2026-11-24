import Foundation
import Testing
import VervangingCore
@testable import Vervanging

/// The live actions in the model (#103): In the zone with the engine's proposed sitter, Extra minuten, Uit and Terug,
/// each the engine's own step, saved after the tap and undone by one Ongedaan maken, with the web app's lines and
/// refusal reasons.
@MainActor
struct LiveActionsModelTests {
    let store: MatchStore

    init() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("live-actions-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        store = MatchStore(directory: directory)
    }

    final class Clock {
        var now = Date(timeIntervalSince1970: 0)
    }

    func model(_ count: Int = 12, clock: Clock = Clock()) throws -> LiveModel {
        LiveModel.start(try LiveModelTests.started(count), store: store, now: { clock.now })
    }

    func wissel(_ model: LiveModel, _ clock: Clock, times count: Int = 1) {
        for _ in 0..<count {
            clock.now += 1
            model.tapWissel()
        }
    }

    func player(_ model: LiveModel, _ id: Int) throws -> Player { try #require(model.players.first { $0.id == id }) }

    /// The first player due off at the coming wissel.
    func dueOff(_ model: LiveModel) throws -> Player { try #require(model.nextChange?.off.first) }

    func seconds(_ model: LiveModel, _ id: Int) -> Int? { model.minutes.first { $0.player.id == id }?.seconds }

    // MARK: - In the zone

    @Test func inTheZoneProposesTheEnginesSitterAndKeepsThePlayerOn() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let change = try #require(model.nextChange)
        let keep = try #require(change.off.first)
        model.chooseZone(keep)
        let bench = try #require(model.state.proposedBench)
        #expect(model.zone == Zone(keep: keep.id, bench: bench, extra: false))
        #expect(model.zoneNote == "\(LiveModel.label(keep)) blijft in the zone op het veld, "
            + "\(LiveModel.label(try player(model, bench))) blijft op de bank.")

        let expected = try model.state.wissel(keep: keep.id, bench: bench)
        wissel(model, clock)
        #expect(model.state == expected, "the engine's wissel with keep and bench")
        #expect(model.state.onCourt.contains(keep.id))
        #expect(!model.state.onCourt.contains(bench))
        #expect(model.zone == nil, "applied and cleared")
        #expect(store.load()?.state == model.state, "saved after the tap")
    }

    @Test func inTheZoneGivesTheBlockBackSoEveryPlayerEndsAtTheirPlannedMinutes() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let keep = try #require(model.nextChange?.off.first)
        model.chooseZone(keep)
        wissel(model, clock)
        #expect(seconds(model, keep.id) == 200, "block 1 played")
        wissel(model, clock, times: 11)
        #expect(model.state.ended)
        #expect(model.minutes.allSatisfy { $0.seconds == 1000 }, "every player 16:40: the zone block is given back")
    }

    @Test func choosingAnotherSitterOrTheSamePlayerAgainOrNobody() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let change = try #require(model.nextChange)
        let keep = try #require(change.off.first)
        model.chooseZone(keep)
        let proposed = try #require(model.zone?.bench)
        let other = try #require(change.on.first { $0.id != proposed })
        model.chooseBench(other)
        #expect(model.zone?.bench == other.id)
        model.setExtra(true)
        model.setExtra(false)
        #expect(model.zone == Zone(keep: keep.id, bench: other.id, extra: false), "Extra minuten keeps the sitter")
        if let second = change.off.dropFirst().first {
            model.chooseZone(second)
            #expect(model.zone == Zone(keep: second.id, bench: other.id, extra: false), "another player, same sitter")
            model.chooseZone(second)
        } else {
            model.chooseZone(keep)
        }
        #expect(model.zone == nil, "the chosen player again cancels")
        model.chooseZone(keep)
        model.chooseZone(nil)
        #expect(model.zone == nil, "Niemand cancels")

        model.chooseZone(keep)
        model.chooseBench(other)
        let expected = try model.state.wissel(keep: keep.id, bench: other.id)
        wissel(model, clock)
        #expect(model.state == expected)
        #expect(!model.state.onCourt.contains(other.id))
        #expect(model.state.onCourt.contains(proposed))
    }

    @Test func onlyAPlayerDueOffCanStayOnAndOnlyAPlayerDueOnCanSit() throws {
        let model = try model()
        let change = try #require(model.nextChange)
        let staying = try #require(model.onCourt.first { !change.off.contains($0) })
        model.chooseZone(staying)
        #expect(model.zone == nil)
        let keep = try #require(change.off.first)
        model.chooseZone(keep)
        let notDue = try #require(model.players.first { !change.on.contains($0) && !model.onCourt.contains($0) })
        let before = model.zone
        model.chooseBench(notDue)
        #expect(model.zone == before)
    }

    // MARK: - Extra minuten

    @Test func extraMinutenKeepsTheBlockWithoutGivingItBack() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let keep = try #require(model.nextChange?.off.first)
        model.chooseZone(keep)
        model.setExtra(true)
        let bench = try #require(model.zone?.bench)
        #expect(model.zoneNote == "\(LiveModel.label(keep)) speelt een extra blok (extra minuten, niet teruggegeven), "
            + "\(LiveModel.label(try player(model, bench))) blijft op de bank.")
        let expected = try model.state.wissel(keep: keep.id, bench: bench, extra: true)
        wissel(model, clock)
        #expect(model.state == expected)
        #expect(model.state.extra == [keep.id])
        wissel(model, clock, times: 11)
        #expect(model.state.ended)
        #expect(seconds(model, keep.id) == 1200, "planned 16:40 plus the extra block: 20:00")
        let total: Int = model.minutes.map(\.seconds).reduce(0, +)
        #expect(total == 12_000, "every block still has five players: the blocks left went to the others")
    }

    // MARK: - Uit and terug

    @Test func uitOnCourtBringsAReplacementOnAtOncePreferringOneDueOn() throws {
        let model = try model()
        let player = try #require(model.onCourt.first)
        let dueOn = try #require(model.nextChange?.on)
        let expected = try model.state.uit(player.id)
        model.uit(player)
        #expect(model.state == expected, "the engine's uit")
        let replacement = try #require(model.replacements.first)
        #expect(replacement.starter == player)
        #expect(dueOn.contains(replacement.replacement), "a player due on at the next wissel comes on")
        #expect(model.onCourt.contains(replacement.replacement))
        #expect(!model.onCourt.contains(player))
        #expect(model.message == "\(LiveModel.label(player)) uit, \(LiveModel.label(replacement.replacement)) erin.")
        #expect(model.confirmed)
        #expect(model.minutes.first { $0.player == player }?.out == true)
        #expect(store.load()?.state == model.state)
    }

    @Test func uitOnTheBenchTakesThePlayerOutOfLaterBlocks() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let benched = try #require(model.players.first { !model.onCourt.contains($0) })
        model.uit(benched)
        #expect(model.message == "\(LiveModel.label(benched)) uit.")
        #expect(model.replacements.isEmpty)
        #expect(!model.state.grid.dropFirst().contains { $0.contains(benched.id) }, "in no later block")
        wissel(model, clock, times: 12)
        #expect(seconds(model, benched.id) == 0)
    }

    @Test func terugBringsThePlayerBackFromTheNextBlock() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let player = try #require(model.onCourt.first)
        model.uit(player)
        wissel(model, clock)
        #expect(model.canTerug)
        let expected = try model.state.terug(player.id)
        model.terug(player)
        #expect(model.state == expected, "the engine's terug")
        #expect(model.message == "\(LiveModel.label(player)) terug vanaf het volgende blok.")
        #expect(!model.isOut(player))
        #expect(!model.state.onCourt.contains(player.id), "not in the current block")
        #expect(model.state.grid[model.state.block...].contains { $0.contains(player.id) }, "planned again later")
        #expect(store.load()?.state == model.state)
    }

    @Test func terugIsNotOfferedInTheLastBlockAndSaysWhy() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        let player = try #require(model.onCourt.first)
        model.uit(player)
        wissel(model, clock, times: 11)
        #expect(model.isLastBlock)
        #expect(!model.canTerug)
        let state = model.state
        model.terug(player)
        #expect(model.state == state)
        #expect(model.message == "Dat kan nu niet: dit is het laatste blok.")
        #expect(!model.confirmed)
    }

    @Test func uitBelowFiveAvailablePlayersIsRefusedWithTheReason() throws {
        let model = try model(6)
        model.uit(try #require(model.onCourt.first))
        let state = model.state
        model.uit(try #require(model.onCourt.first))
        #expect(model.state == state)
        #expect(model.message == "Dat kan nu niet: er moeten minstens 5 spelers overblijven.")
        #expect(!model.confirmed)
    }

    @Test func otherRefusalsKeepThePlainLine() {
        #expect(LiveModel.refusalText(MatchError("the match has ended")) == "Dat kan nu niet.")
        #expect(LiveModel.refusalText(MatchError("at least 5 players must be available, really")) == "Dat kan nu niet.")
        #expect(LiveModel.refusalText(CocoaError(.fileWriteUnknown)) == "Dat kan nu niet.")
    }

    // MARK: - Undo and the zone after an action

    @Test func eachActionIsUndoneByOneTap() throws {
        let clock = Clock()
        let model = try model(clock: clock)
        wissel(model, clock)

        func undone(_ action: () throws -> Void) throws {
            let before = model.state
            try action()
            #expect(model.state != before)
            model.undo()
            #expect(model.state.block == before.block)
            #expect(model.state.grid == before.grid)
            #expect(model.state.out == before.out)
            #expect(model.state.replaced == before.replaced)
            #expect(model.state.extra == before.extra)
            #expect(model.message == "Ongedaan gemaakt.")
            #expect(store.load()?.state == model.state)
        }
        try undone {
            model.chooseZone(try dueOff(model))
            wissel(model, clock)
        }
        try undone {
            model.chooseZone(try dueOff(model))
            model.setExtra(true)
            wissel(model, clock)
        }
        try undone { model.uit(try #require(model.onCourt.first)) }
        let player = try #require(model.onCourt.first)
        model.uit(player)
        try undone { model.terug(player) }
        #expect(model.isOut(player), "undo of terug leaves the player uit")
    }

    @Test func anyActionClearsTheZoneAndCountsForTheScreen() throws {
        let model = try model()
        let count = model.actions
        model.chooseZone(try dueOff(model))
        #expect(model.actions == count, "choosing is not an action")
        model.uit(try #require(model.players.first { !model.onCourt.contains($0) }))
        #expect(model.zone == nil)
        #expect(model.actions == count + 1)
        model.undo()
        #expect(model.actions == count + 2)
        let six = try self.model(6)
        six.uit(try #require(six.onCourt.first))
        six.uit(try #require(six.onCourt.first))
        #expect(six.actions == 2, "a refused action counts too, so its reason is brought into view")
    }
}
