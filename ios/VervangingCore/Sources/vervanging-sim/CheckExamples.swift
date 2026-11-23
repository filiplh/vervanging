import Foundation

// check-examples: runs the shared examples (shared/examples/, plan decision #35) through this sim and compares what
// it prints with what scripts/sim.mjs printed, exactly.

/// The example kinds the Swift sim runs so far; later tickets add match (#98, #99) and history (#97).
let supportedKinds: Set<String> = ["plan"]
let knownKinds = ["plan", "match", "history"]

/// Options of a supported kind that the Swift sim does not have yet, with the reason given when an example is skipped.
let unsupportedOptions: [(kind: String, option: String, reason: String)] = [
    ("plan", "--history", "--history and --use-history come with the history rules (#97)"),
]

struct Example {
    let file: String
    let kind: String
    let args: [String]
    let exitStatus: Int32
    let stdout: String
    let stderr: String
}

func readExample(_ url: URL) throws -> Example {
    let data = try Data(contentsOf: url)
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
          let kind = object["kind"] as? String,
          let args = object["args"] as? [String],
          let exitStatus = object["exitStatus"] as? Int,
          let stdout = object["stdout"] as? String,
          let stderr = object["stderr"] as? String
    else {
        throw UsageError("not an example: it needs kind, args, exitStatus, stdout and stderr")
    }
    return Example(file: url.lastPathComponent, kind: kind, args: args, exitStatus: Int32(exitStatus), stdout: stdout,
                   stderr: stderr)
}

/// The first line where `actual` differs from `expected`, as report lines; nil when they are the same.
func firstDifference(_ stream: String, expected: String, actual: String) -> [String]? {
    if expected == actual { return nil }
    let want = expected.split(separator: "\n", omittingEmptySubsequences: false)
    let got = actual.split(separator: "\n", omittingEmptySubsequences: false)
    var line = 0
    while line < want.count && line < got.count && want[line] == got[line] { line += 1 }
    let w = line < want.count ? String(want[line]) : nil
    let g = line < got.count ? String(got[line]) : nil
    var column = 1
    if let w, let g {
        for (a, b) in zip(w, g) {
            if a != b { break }
            column += 1
        }
    }
    return [
        "  \(stream) line \(line + 1) differs" + (w != nil && g != nil ? " at column \(column)" : ""),
        "    expected: " + (w ?? "(no line)"),
        "    actual:   " + (g ?? "(no line)"),
    ]
}

func checkExamples(_ argv: [String]) -> Outcome {
    let checkUsage = "usage: vervanging-sim check-examples <dir> [--only <plan|match|history>]"
    var rest = argv[...]
    guard let dir = rest.popFirst(), !dir.hasPrefix("--") else { return Outcome(stderr: checkUsage + "\n", status: 2) }
    var only: String?
    while let arg = rest.popFirst() {
        guard arg == "--only", let value = rest.popFirst() else { return Outcome(stderr: checkUsage + "\n", status: 2) }
        guard knownKinds.contains(value) else {
            return Outcome(stderr: "--only takes plan, match or history, not \"\(value)\"\n", status: 2)
        }
        guard supportedKinds.contains(value) else {
            return Outcome(stderr: "the Swift sim does not run \(value) examples yet\n", status: 2)
        }
        only = value
    }
    let files: [String]
    do {
        files = try FileManager.default.contentsOfDirectory(atPath: dir).filter { $0.hasSuffix(".json") }.sorted()
    } catch {
        return Outcome(stderr: "cannot read the examples folder \"\(dir)\"\n", status: 2)
    }

    var lines: [String] = []
    var skipped: [String: [String]] = [:] // reason -> files
    var ran = 0
    var matched = 0
    var unreadable = 0
    for file in files {
        let example: Example
        do {
            example = try readExample(URL(fileURLWithPath: dir).appendingPathComponent(file))
        } catch let error as UsageError {
            lines.append("cannot read \(file): \(error.message)")
            unreadable += 1
            continue
        } catch {
            lines.append("cannot read \(file): not valid JSON")
            unreadable += 1
            continue
        }
        if let only, example.kind != only { continue }
        if !supportedKinds.contains(example.kind) {
            skipped["the Swift sim has no \(example.kind) command yet", default: []].append(file)
            continue
        }
        if let gap = unsupportedOptions.first(where: { $0.kind == example.kind && example.args.contains($0.option) }) {
            skipped[gap.reason, default: []].append(file)
            continue
        }
        ran += 1
        let outcome = run(example.args)
        var report: [String] = []
        if outcome.status != example.exitStatus {
            report.append("  exit status \(outcome.status), expected \(example.exitStatus)")
        }
        report += firstDifference("stdout", expected: example.stdout, actual: outcome.stdout) ?? []
        report += firstDifference("stderr", expected: example.stderr, actual: outcome.stderr) ?? []
        if report.isEmpty {
            matched += 1
        } else {
            lines.append("mismatch \(file):")
            lines += report
        }
    }
    for reason in skipped.keys.sorted() {
        let names = skipped[reason]!
        lines.append("skipped \(names.count) example\(names.count == 1 ? "" : "s") (\(reason)): "
            + names.joined(separator: ", "))
    }
    if ran == 0 { lines.append("no example ran: \"\(dir)\" holds no example this sim can run") }
    lines.append("\(matched)/\(ran) \(only.map { "\($0) " } ?? "")examples match")
    // A run that checks nothing (a wrong or empty folder) is not a pass.
    let ok = ran > 0 && matched == ran && unreadable == 0
    return Outcome(stdout: lines.joined(separator: "\n") + "\n", status: ok ? 0 : 1)
}
