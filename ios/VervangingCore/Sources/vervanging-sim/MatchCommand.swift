import Foundation
import VervangingCore

// The match command, ported from parseActions and runMatch in scripts/sim.mjs: the same action syntax, checks,
// messages and JSON, byte for byte.

/// One action of `--actions`, as parseActions gives it. A player number is kept as JavaScript's `Number()` reads the
/// digits, so a number too large for a player prints in messages as sim.mjs prints it.
enum SimAction {
    case wissel(keep: Double?, bench: Double?, extra: Bool)
    case undo
    case uit(Double)
    case terug(Double)
}

/// The ASCII digits of `text` from `index`, as JavaScript's `\d` (without the u flag) matches them.
private func digits(_ text: Substring) -> Substring { text.prefix { $0 >= "0" && $0 <= "9" && $0.isASCII } }

/// Like `parseActions` in sim.mjs: comma-separated items, empty items skipped; each item must match one of the
/// patterns as a whole.
func parseActions(_ text: String) throws -> [SimAction] {
    var actions: [SimAction] = []
    // Split on the comma itself, as JavaScript's split does, even where a combining mark follows it.
    let items = text.unicodeScalars.split(separator: ",", omittingEmptySubsequences: true)
        .map { Substring(String(String.UnicodeScalarView($0))) }
    for item in items {
        if let action = try parseAction(item) {
            actions += action
            continue
        }
        throw UsageError("unknown action \"\(item)\": use wissel, undo (optionally with *<count>), "
            + "wissel:keep=P[:extra][:bench=Q], uit=P or terug=P")
    }
    return actions
}

/// The actions one item stands for, or nil when it matches no pattern.
private func parseAction(_ item: Substring) throws -> [SimAction]? {
    // /^(wissel|undo)(?:\*(\d+))?$/
    for word in ["wissel", "undo"] where item.hasPrefix(word) {
        let rest = item.dropFirst(word.count)
        var count = 1.0
        if !rest.isEmpty {
            guard rest.first == "*" else { break }
            let number = digits(rest.dropFirst())
            guard !number.isEmpty, number.count == rest.count - 1 else { break }
            count = javaScriptNumber(String(number))
            if count < 1 || count > 1000 { throw UsageError("action \"\(item)\": the count must be 1 to 1000") }
        }
        let action: SimAction = word == "wissel" ? .wissel(keep: nil, bench: nil, extra: false) : .undo
        return Array(repeating: action, count: Int(count))
    }
    // /^wissel:keep=(\d+)(:extra)?(?::bench=(\d+))?$/
    if item.hasPrefix("wissel:keep=") {
        var rest = item.dropFirst("wissel:keep=".count)
        let keep = digits(rest)
        guard !keep.isEmpty else { return nil }
        rest = rest.dropFirst(keep.count)
        var extra = false
        if rest.hasPrefix(":extra") {
            extra = true
            rest = rest.dropFirst(":extra".count)
        }
        var bench: Double?
        if rest.hasPrefix(":bench=") {
            let number = digits(rest.dropFirst(":bench=".count))
            guard !number.isEmpty else { return nil }
            bench = javaScriptNumber(String(number))
            rest = rest.dropFirst(":bench=".count + number.count)
        }
        guard rest.isEmpty else { return nil }
        return [.wissel(keep: javaScriptNumber(String(keep)), bench: bench, extra: extra)]
    }
    // /^(uit|terug)=(\d+)$/
    for word in ["uit", "terug"] where item.hasPrefix(word + "=") {
        let number = item.dropFirst(word.count + 1)
        guard !number.isEmpty, digits(number).count == number.count else { return nil }
        let player = javaScriptNumber(String(number))
        return [word == "uit" ? .uit(player) : .terug(player)]
    }
    return nil
}

/// A player number for the engine. Digits always read as a whole number of 0 or more; one beyond Int (more than
/// 9.2e18, so never a player) becomes `stand-in`, a number no player has, and the message names the number as
/// JavaScript prints it.
private func playerNumber(_ value: Double?, standIn: Int) -> Int? {
    guard let value else { return nil }
    return value < 9_223_372_036_854_775_808.0 ? Int(value) : standIn
}

/// Applies one action as applyAction in match.js does; a MatchError becomes the sim's invalid input.
private func apply(_ action: SimAction, to state: MatchState) throws -> MatchState {
    // Each player number given, with the stand-in it gets when it is too large for an Int.
    var given: [(standIn: Int, value: Double?)] = []
    func number(_ value: Double?, _ standIn: Int) -> Int? {
        given.append((standIn, value))
        return playerNumber(value, standIn: standIn)
    }
    do {
        switch action {
        case .undo:
            return state.undo()
        case let .wissel(keep, bench, extra):
            return try state.wissel(keep: number(keep, -1), bench: number(bench, -2), extra: extra)
        case let .uit(player):
            return try state.uit(number(player, -1)!)
        case let .terug(player):
            return try state.terug(number(player, -1)!)
        }
    } catch let error as MatchError {
        var message = error.message
        for (standIn, value) in given {
            if let value, playerNumber(value, standIn: standIn) == standIn {
                message = message.replacingOccurrences(of: "player \(standIn) ",
                                                       with: "player \(value.javaScriptString) ")
            }
        }
        throw UsageError(message)
    }
}

/// The match command's output: the JSON.stringify text of runMatch's result object, with its key order. The keys of
/// `minutes` and `extraSeconds` are player numbers, which a JavaScript object lists in ascending order.
func matchJSON(_ opts: [String: String]) throws -> String {
    // As runMatch: the actions are read before the plan is made, so an action error comes first.
    let actions = try parseActions(opts["actions"] ?? "")
    var state = MatchState.start(try planFrom(opts))
    for action in actions { state = try apply(action, to: state) }
    func list(_ values: [Int]) -> String { "[" + values.map(String.init).joined(separator: ",") + "]" }
    func object(_ values: [Int: Int]) -> String {
        "{" + values.keys.sorted().map { "\"\($0)\":\(values[$0]!)" }.joined(separator: ",") + "}"
    }
    let overview = state.minutesOverview.map {
        "{\"player\":\($0.player),\"seconds\":\($0.seconds),\"onCourt\":\($0.onCourt),\"out\":\($0.out)}"
    }
    return "{\"block\":\(state.block),\"blocks\":\(state.blocks),\"ended\":\(state.ended),"
        + "\"onCourt\":\(list(state.onCourt)),\"minutes\":\(object(state.minutesSoFar)),"
        + "\"extraSeconds\":\(object(state.extraSeconds)),\"overview\":[\(overview.joined(separator: ","))]}"
}
