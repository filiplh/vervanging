import Foundation
import VervangingCore

/// Invalid input: exit status 2, the message on stderr after "sim: " for the sim.mjs commands.
struct UsageError: Error {
    let message: String
    init(_ message: String) { self.message = message }
}

/// What one run of the sim prints, and its exit status. `main.swift` writes it out; check-examples compares it with
/// an example, so both see exactly the same text.
struct Outcome: Equatable {
    var stdout = ""
    var stderr = ""
    var status: Int32 = 0
}

let usage = "usage: vervanging-sim random|plan|match|history|check-examples (see the comment at the top of main.swift)"

/// Like `parse` in scripts/sim.mjs: the command, then `--key value` pairs; `--json` and `--use-history` take no value.
/// A later value for the same key wins, as in the JS object.
func parse(_ argv: [String]) throws -> (command: String, opts: [String: String]) {
    guard let command = argv.first else { throw UsageError(usage) }
    var opts: [String: String] = [:]
    var rest = argv.dropFirst()
    while let arg = rest.popFirst() {
        guard arg.hasPrefix("--") else { throw UsageError("unexpected argument \"\(arg)\"") }
        let key = String(arg.dropFirst(2))
        if key == "json" || key == "use-history" {
            opts[key] = "true"
            continue
        }
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

/// One run of the sim with these arguments (without the program name).
func run(_ argv: [String]) -> Outcome {
    switch argv.first {
    case "check-examples":
        // check-examples takes a directory as its first argument, which the sim.mjs parser does not allow.
        return checkExamples(Array(argv.dropFirst()))
    case "plan", "match", "history":
        // As in sim.mjs, every UsageError and PlanError, from the parser too, is printed after "sim: ".
        do {
            let opts = try parse(argv).opts
            let json = switch argv.first {
            case "plan": try planJSON(opts)
            case "match": try matchJSON(opts)
            default: try historyJSON(opts)
            }
            return Outcome(stdout: json + "\n")
        } catch let error as UsageError {
            return Outcome(stderr: "sim: \(error.message)\n", status: 2)
        } catch let error as PlanError {
            return Outcome(stderr: "sim: \(error.message)\n", status: 2)
        } catch let error as MatchError {
            // sim.mjs turns every MatchError into invalid input; the match command does so already, this is a guard.
            return Outcome(stderr: "sim: \(error.message)\n", status: 2)
        } catch {
            return Outcome(stderr: "sim: \(error)\n", status: 2)
        }
    default:
        do {
            let (command, opts) = try parse(argv)
            guard command == "random" else { throw UsageError("unknown command \"\(command)\": \(usage)") }
            return Outcome(stdout: try random(opts).joined(separator: "\n") + "\n")
        } catch let error as UsageError {
            return Outcome(stderr: error.message + "\n", status: 2)
        } catch {
            return Outcome(stderr: "\(error)\n", status: 2)
        }
    }
}
