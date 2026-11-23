// Command-line runner over the rules package, the Swift twin of scripts/sim.mjs (grown by later tickets), so the
// Swift rules can be checked from outside without a simulator. It follows sim.mjs's conventions: one JSON object or
// plain lines on stdout; invalid input: exit status 2, one line on stderr, nothing on stdout.
//   swift run --package-path ios/VervangingCore vervanging-sim random [--seed <n>] [--count <n>]
//     Prints the first <count> values (default 1) of the planner's seeded generator for <seed> (default 1, as in
//     sim.mjs), one per line, in the form JavaScript prints them. Like seededRandom, a seed of 0 counts as 1.
import Foundation
import VervangingCore

struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

let usage = "usage: vervanging-sim random [--seed <n>] [--count <n>]"

func parse(_ argv: [String]) throws -> (command: String, opts: [String: String]) {
    guard let command = argv.first else { throw UsageError(usage) }
    var opts: [String: String] = [:]
    var rest = argv.dropFirst()
    while let arg = rest.popFirst() {
        guard arg.hasPrefix("--") else { throw UsageError("unexpected argument \"\(arg)\"") }
        let key = String(arg.dropFirst(2))
        guard let value = rest.popFirst(), !value.hasPrefix("--") else { throw UsageError("--\(key) needs a value") }
        opts[key] = value
    }
    return (command, opts)
}

func random(_ opts: [String: String]) throws -> [String] {
    for key in opts.keys where key != "seed" && key != "count" { throw UsageError("unknown option --\(key)") }
    var seed = 1
    if let text = opts["seed"] {
        guard let value = Int(text) else { throw UsageError("--seed must be a whole number") }
        seed = value
    }
    var count = 1
    if let text = opts["count"] {
        guard let value = Int(text), value >= 1 else { throw UsageError("--count must be a whole number of 1 or more") }
        count = value
    }
    var generator = SeededRandom(seed: seed)
    return (0..<count).map { _ in generator.next().javaScriptString }
}

do {
    let (command, opts) = try parse(Array(CommandLine.arguments.dropFirst()))
    switch command {
    case "random":
        let lines = try random(opts)
        print(lines.joined(separator: "\n"))
    default:
        throw UsageError("unknown command \"\(command)\": \(usage)")
    }
} catch let error as UsageError {
    FileHandle.standardError.write(Data((error.message + "\n").utf8))
    exit(2)
}
