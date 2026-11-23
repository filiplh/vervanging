// Command-line runner over the rules package, the Swift twin of scripts/sim.mjs (grown by later tickets), so the
// Swift rules can be checked from outside without a simulator. It follows sim.mjs's conventions: one JSON object or
// plain lines on stdout; invalid input: exit status 2, one line on stderr, nothing on stdout.
//   swift run --package-path ios/VervangingCore vervanging-sim random [--seed <n>] [--count <n>]
//     Prints the first <count> values (default 1) of the planner's seeded generator for <seed> (default 1, as in
//     sim.mjs), one per line, in the form JavaScript prints them. Like seededRandom, a seed of 0 counts as 1.
//   swift run --package-path ios/VervangingCore vervanging-sim plan --players <n> --start <a,b,c,d,e>
//                                               --schedule <equal|five> [--seed <n>] [--swap <a,b>]
//                                               [--history <file> [--use-history]] [--json]
//     The same arguments, checks and JSON as `node scripts/sim.mjs plan`, byte for byte (plan decision #35).
//     --history reads a team history file in the shape the web app stores (History.swift; player ids are the player
//     numbers); --use-history gives the uneven extra places to the players with the fewest seconds in it and lets
//     players behind catch up by one block (decision #28); seconds earned through Extra minuten are not counted.
//   swift run --package-path ios/VervangingCore vervanging-sim history --history <file> [--json]
//     The season totals of a team history file (decision #26), as `node scripts/sim.mjs history` prints them: matches
//     (the number of saved matches) and totals (seconds per player id over all of them; a player in no match is left
//     out).
//   swift run --package-path ios/VervangingCore vervanging-sim check-examples <dir> [--only <plan|match|history>]
//     Runs every shared example in <dir> (shared/examples/, see its README) through this sim, from the current
//     directory, and compares stdout, stderr and the exit status exactly. Names each mismatch with the example's file
//     name and the first differing line, and names the examples it skips because this sim cannot run them yet. The
//     last line reads "<m>/<n> <kind> examples match" ("<m>/<n> examples match" without --only). Exit status 0 when
//     every example it ran matches, 1 when one does not or a file cannot be read (counted in the last line as an example
//     that does not match), 2 for invalid input.
import Foundation

let outcome = run(Array(CommandLine.arguments.dropFirst()))
FileHandle.standardOutput.write(Data(outcome.stdout.utf8))
FileHandle.standardError.write(Data(outcome.stderr.utf8))
exit(outcome.status)
