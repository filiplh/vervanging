# ADR-003 The native app ports the rules to Swift, refereed by shared exact examples

- **Status:** accepted ([phase 3 D6, D7, D24](../grill/2026-11-23-phase-3-native-ios.md#decisions), by the owner;
  D23 is an agent's call, reversible)
- **Date:** 2026-11-23 (decided) · 2026-11-23 (written)

## Context
Phase 3 rebuilds vervanging as a native iPhone app (SwiftUI, Liquid Glass, iOS 27) in `ios/`, beside the web app in
`public/`, which stays live ([phase 3 D1, D19](../grill/2026-11-23-phase-3-native-ios.md#decisions)). The match
rules (the planner, the live match engine, the team history and catch-up) are about 1,000 lines of pure JavaScript in
`public/js/planner.js`, `match.js`, `history.js` and the pure parts of `live.js`, with about 100 tests. They took
phases 0 to 2 and many review rounds to get right. vervanging is also the pilot for Zappo, the commercial app that
will follow the same native pattern ([phase 3 D2](../grill/2026-11-23-phase-3-native-ios.md#decisions)).

## Decision
- The rules are ported to a pure Swift package in `ios/`, with its own Swift tests. The app does not run the
  JavaScript (no JavaScriptCore) and does not wrap the web app (no WKWebView).
- A script exports the JavaScript test cases as **shared examples**: JSON files with inputs and expected outputs in
  `shared/examples/` (path: agent's call). The JavaScript suite and the Swift suite both run every example, so the
  two copies of the rules cannot drift while both apps are live.
- The examples compare **exact** output. The planner's seeded generator (mulberry32 in `seededRandom`) is ported bit
  for bit with 32-bit wrapping arithmetic, so the same seed gives the same plan in both apps.
- During phase 3 the rules in `public/js` change only for bug fixes; each fix also lands in Swift, in the same PR or
  the next, with an updated example ([phase 3 D8](../grill/2026-11-23-phase-3-native-ios.md#decisions)).

## Consequences
- Two copies of the rules while the web app lives: every rule fix is done twice and needs a shared example. The
  duplication ends if the web app is retired after phase 4.
- A port bug could put an unfair plan in front of the coach; the exact examples and the phase 3 exit test at a real
  match guard against it.
- The Swift rules package imports only Foundation, so its tests run without a simulator.
- Zappo gets a native pattern to copy: a pure Swift rules package plus SwiftUI screens.

## Alternatives considered
- **Run the JavaScript in JavaScriptCore:** one copy of the rules, already tested; but a bridge layer, harder
  debugging, `live.js` pulls in UI helpers, and an odd pattern to hand to Zappo.
- **Wrap the web app in a WKWebView:** fastest; but no native Liquid Glass, App Review often rejects thin web wrappers
  (guideline 4.2), and it proves nothing about a Swift pipeline.

## References
[phase 3 D6](../grill/2026-11-23-phase-3-native-ios.md#decisions) · [phase 3 D7](../grill/2026-11-23-phase-3-native-ios.md#decisions) ·
[phase 3 D8](../grill/2026-11-23-phase-3-native-ios.md#decisions) · [phase 3 D23](../grill/2026-11-23-phase-3-native-ios.md#decisions) ·
[phase 3 D24](../grill/2026-11-23-phase-3-native-ios.md#decisions) (devil's advocate) · plan decisions #34, #35, #36
