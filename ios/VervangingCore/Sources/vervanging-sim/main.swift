// Command-line runner over the rules package, the Swift twin of scripts/sim.mjs (grown by later tickets), so the
// Swift rules can be checked from outside without a simulator. It follows sim.mjs's conventions: one JSON object or
// plain lines on stdout; invalid input: exit status 2, one line on stderr, nothing on stdout.
//   swift run --package-path ios/VervangingCore vervanging-sim random [--seed <n>] [--count <n>]
//     Prints the first <count> values (default 1) of the planner's seeded generator for <seed> (default 1, as in
//     sim.mjs), one per line, in the form JavaScript prints them. Like seededRandom, a seed of 0 counts as 1.
//   swift run --package-path ios/VervangingCore vervanging-sim plan --players <n> --start <a,b,c,d,e>
//                                               --schedule <equal|five> [--seed <n>] [--swap <a,b>] [--json]
//     The same arguments, checks and JSON as `node scripts/sim.mjs plan`, byte for byte (plan decision #35). The
//     --history and --use-history options come with the history rules (#97); until then --history is refused.
//   swift run --package-path ios/VervangingCore vervanging-sim check-examples <dir> [--only <plan|match|history>]
//     Runs every shared example in <dir> (shared/examples/, see its README) through this sim, from the current
//     directory, and compares stdout, stderr and the exit status exactly. Names each mismatch with the example's file
//     name and the first differing line, and names the examples it skips because this sim cannot run them yet. The
//     last line reads "<m>/<n> <kind> examples match" ("<m>/<n> examples match" without --only). Exit status 0 when
//     every example it ran matches, 1 when one does not or a file cannot be read, 2 for invalid input.
import Foundation

let outcome = run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
FileHandle.standardError.write(Data(outcome.stderr.utf8))
exit(outcome.status)
