# Grill: phase 3, the native iOS app (2026-11-23)
Depth: deep · Read: AGENTS.md, factory.yaml, docs/PLAN.md, docs/adr/ (ADR-001, ADR-002), the phase 1–2 grill logs, public/js (logic modules and store keys), the lead's memory notes on phase 3, the board (only #1 open; #36 and the phase 2 milestone closed), filiplh/vegvisir-factory#51 (parked, agent:human), the installed Xcode (27.2) and its simulators (iPhone 17 Pro and iPhone Duo device types exist) · Status: done (2026-11-23)

## Map
1. Why native, and for whom ✓ the pilot (Apple account, an iOS pipeline for Zappo) plus the Liquid Glass feel; the web app meets the coaching need (D2)
   2. Scope ✓ parity with the phase 2 web app, no new match features (D4)
   15. The match phone ✓ an iPhone on iOS 27 (D3)
3. Where it lives ✓ `ios/` beside `public/` in this repo; web app stays live until the native exit test (owner, side chat, memory note)
4. How the match logic moves ✓ ported to a pure Swift package with Swift tests (D6)
   5. How both stay in step ✓ shared JSON examples exported from the JS tests, run by both suites (D7); rules frozen except bug fixes, which land in both (D8)
   16. UI toolkit ✓ SwiftUI with the system's Liquid Glass (D9)
   17. Language ✓ Dutch only, same copy, String Catalog (D11)
6. Moving data from the web app ✓ none: start fresh, roster re-entered by hand (D5)
7. Storage on the device ✓ JSON files in the app's storage, saved after every tap, no sync (D10)
8. Devices and screens ✓ iPhone 17 Pro and Duo outer share the phone layout; Duo inner gets a wide layout; all three in the simulator (D13); minimum iOS 27.0 (D12); match phone is the 17 Pro (D14)
9. Tests and CI for Swift ✓ a local factory check for ios/ and the shared examples now; GitHub-hosted macOS CI when the factory supports it; Mac mini parked for this repo (D16)
10. Running it before enrolment ✓ simulator, then the owner's free Apple ID on the 17 Pro once parity is reached, `.dev` bundle ID (D15; limits are A1)
11. Exit test ✓ split: phase 3 ends with a real match on the native app (D17); phase 4, the release pipeline, ends with a TestFlight build from CI (D18)
12. What happens to the web app after the exit test ✓ stays live and frozen as a fallback; retiring it is decided after phase 4 (D19)
   18. Store goal ✓ phase 4 to TestFlight, phase 5 through App Review to a free App Store release (D20)
   19. Name and icon ✓ "Vervanging"; a new layered icon, drafts of 2–3 options in a phase 3 ticket, owner picks (D22)
20. How the factory runs phase 3 ✓ team mode, roles ios and web, this Mac capped at 2 builders (D25)
13. Factory iOS request ⏸ drafted, not filed until the owner says so (owner)
14. Android, iPad, Apple Watch, widgets, Live Activities ✗ out of scope (D21)
gap: the Phase 0 and Phase 1 milestones are still open with no issues in them → follow-up: close them
gap: the last factory-deploy-app-production run (2026-11-23 10:11 UTC) failed; the live site was deployed by hand → follow-up: the next normal release should go through the workflow

## Open (frontier)
None.

## Decisions
| ID | Decision | Why | By |
| --- | --- | --- | --- |
| D1 | The native app lives in `ios/` in this repo, beside `public/`; the web app stays live until the native app passes its exit test | A mixed web plus iOS repo mirrors Zappo's planned shape and keeps the rules, plan and data move in one place | carried over from the owner (side chat, 2026-11-23) |
| D2 | Phase 3 exists for the pilot (setting up the Apple developer account and an iOS build and release pipeline that Zappo can reuse) and for a native Liquid Glass feel, not for a coaching need the web app fails | Phase 2 exit passed ("all looks good"), no open bugs | user (premise agreed) |
| D3 | The coach's match phone is an iPhone running iOS 27 (an iPhone 17 Pro or an iPhone Duo) | Owner's device | user (premise agreed) |
| D4 | Scope is parity with the phase 2 web app: roster, setup, planner, live Wissel, in the zone, Extra minuten, uit/terug, undo, history, catch-up and both overviews; no new match features in phase 3 | Keeps the phase about the pilot; the rules are settled | user (premise agreed) |
| D5 | No data moves from the web app: the native app starts with an empty history and the coach re-enters the roster by hand | The owner disagreed that the current history is worth keeping | user (premise disagreed), agent's call (roster re-entered by hand, no import) |
| D6 | The match rules (planner, match, history, the pure parts of live) are ported to a pure Swift package with its own Swift tests; no JavaScriptCore, no web wrapper | Idiomatic native code and the pattern Zappo will copy; about 1,000 lines of pure JS is small enough to port; a WKWebView wrapper would give no native Liquid Glass and risks App Review guideline 4.2 | user |
| D7 | A script exports the JS test cases as shared JSON examples (inputs and expected outputs) in the repo; the JS suite and the Swift suite both run them, so the two apps cannot drift while both are live | Two copies of the rules need a referee | user (accepted with D6) |
| D8 | During phase 3 the rules in `public/js` change only for bug fixes; each fix also lands in the Swift package, in the same PR or the next, with an updated shared example | Parity (D4) and D7 only hold if the reference stands still | user |
| D9 | Screens are SwiftUI only, using the system's Liquid Glass materials and controls; no custom glass look-alikes; UIKit only where SwiftUI cannot | The native feel is a reason for phase 3 (D2), and system materials age with the OS | user |
| D10 | ADR-002 carries over: roster, running match and history are saved as small JSON files in the app's own storage after every tap and restored on launch; no SwiftData, no iCloud sync, no login; normal device backups include them | Same premise as the web app (one coach, one phone); plain Codable files are the simplest thing that survives a relaunch | user |
| D11 | On-screen text is Dutch only, with the web app's terms and copy, kept in an Xcode String Catalog | Language rule in AGENTS.md; parity (D4) | user |
| D12 | The app's minimum is iOS 27.0 | Both target phones run iOS 27 (D3); the iPhone Duo simulator profile needs runtime 27.1 or later | agent's call, reversible |
| D13 | Layouts: the iPhone 17 Pro and the iPhone Duo's outer screen share the phone layout; the Duo's inner screen gets a wide layout (plan grid without scrolling, live screen with the minutes beside the court); every screen is checked on all three in the simulator | The owner named all three screens; the plan grid is players × 12 blocks and suffers most on a narrow screen | user |
| D14 | The coach's match phone is the iPhone 17 Pro; the real-match test runs on it, and the Duo is checked in the simulator | Owner's answer | user |
| D15 | Before enrolment: build and test in the simulator; once the app reaches parity, the owner installs it on their iPhone 17 Pro with their own free Apple ID (they sign in to Xcode themselves, a human gate; agents never touch the account), with a bundle ID ending in `.dev` so the final ID stays free for the organisation account; the real-match test may use that build | The match test should not wait on Apple's enrolment problem (P1) | user |
| D16 | Until the factory supports macOS CI, the Swift tests are a factory check (`checks`) that runs only when `ios/` or the shared examples change; builders, the reviewer and `factory verify` run it on this Mac. CI on GitHub-hosted macOS runners comes with the factory request. The self-hosted Mac mini (factory #51) stays parked for this repo | ⚠ GitHub-hosted macOS runners are free for public repos; a self-hosted runner on a public repo can run code from fork PRs on the owner's machine, which GitHub advises against | user |
| D17 | Phase 3 exit test: at a real match or scrimmage, on the owner's iPhone 17 Pro (the free-ID build, D15), in airplane mode, the coach runs the whole match in the native app; In the zone, Extra minuten and uit/terug are each used at least once; the app is force-quit once mid-match and restores the match; the end screen and the season totals are right. All three screens (D13) are checked in the simulator. Checked by the owner | Proves the native app at a real match without waiting on Apple (P1) | user |
| D18 | A phase 4, "the release pipeline", follows phase 3: CI on GitHub-hosted macOS runners, signing with the organisation account, and a TestFlight build from CI installed on the owner's phone as its exit. It starts when enrolment works (P1) and the factory's iOS recipe exists (P2) | The pilot (D2) needs the pipeline, but it is blocked on Apple; splitting keeps phase 3 moving | user |
| D19 | After the phase 3 exit test the web app stays live and frozen as a fallback; whether to retire it is decided after phase 4 | Costs nothing on Workers; a fallback while the native app is new | user |
| D20 | The pilot goes all the way: phase 4 ends at TestFlight, and a phase 5 takes the app through App Review to a free App Store release | Proves the whole path Zappo needs (App Review, privacy label, store listing), not just signing and upload | user |
| D21 | Out of scope for phase 3: Android, iPad, Apple Watch, widgets, Live Activities | iPhone only (D3) | user |
| D22 | The name under the icon is "Vervanging"; the icon is new, a layered iOS 27 icon (light, dark, tinted, clear); a phase 3 ticket drafts 2–3 options and the owner picks one | The owner declined the web app's icon and asked to see drafts | user |
| D23 | The shared examples compare exact output: the planner's seeded generator (mulberry32 in `seededRandom`) is ported bit for bit, so the same seed gives the same plan in both apps | Exact parity is provable and catches subtle port bugs; the generator uses only 32-bit integer operations, which Swift reproduces with wrapping arithmetic | agent's call, reversible |
| D24 | D6 (port to Swift) stands after the devil's advocate case (two copies of the rules while the web app lives, every fix done twice, risk of a port bug at a real match) | Shared exact examples referee the copies; the rules are frozen (D8); the duplication ends if the web app is retired after phase 4; Zappo needs a native pattern | user |
| D25 | Phase 3 runs in team mode: `mode: team` in factory.yaml with two roles, `ios` (owns `ios/**`) and `web` (owns `public/**` and the shared examples), proposed in the plan PR (H4); this Mac is capped at 2 builders in the owner's `~/.factory/machine.yaml` (the owner edits it; agents only propose the line), raised if the first Swift tickets show the Mac copes (A3) | Parallel screen tickets shorten the build; the cap answers the owner's only pre-mortem worry | user |

## Assumptions to test
| ID | Assumption | How to test | Owner |
| --- | --- | --- | --- |
| A1 | ⚠ A free Apple ID can install the app on the owner's iPhone through Xcode; the install expires after 7 days, at most 3 such apps per phone, Developer Mode must be on; the app needs no paid-only capability | The owner's first install on the 17 Pro (the N-ticket for the free install); expiry noted on the week after | owner |
| A3 | This Mac can carry Xcode builds and simulator runs alongside the owner's other work; solo mode runs one issue at a time and the Swift check runs under the machine's heavy lock, so one Xcode build at a time | Note build and test times on the first Swift tickets (Xcode project, logic port); if the Mac struggles, the owner slows other projects down | owner, lead |
| A2 | ⚠ The iPhone Duo's screens in the simulator match the real device closely enough that layouts checked there hold on a real Duo | Not testable without a Duo; revisit if the owner or Zappo's users get one | owner |

## Parked
| ID | Question | Owner | Blocks |
| --- | --- | --- | --- |
| P1 | Apple organisation enrolment (stuck; the owner emailed Apple support) | owner | TestFlight, App Store Connect, distribution signing, the store recipe's release step |
| P2 | Filing the factory iOS request in vegvisir-factory | owner | nothing before the CI and release tickets |

## Pre-mortem
Reasons the native pilot could fail by May 2027, collected 2026-11-23. The owner's only worry: whether this Mac can carry the workload (A3). The lead's, kept as risks for the plan:
1. Apple enrolment never resolves, so phases 4–5 stall and Zappo has no proven pipeline (P1).
2. The free-ID install expires after 7 days and the app will not open at the bench on match day (A1): reinstall before each match.
3. A port bug puts an unfair plan in front of the coach (D7, D23 and the exit test guard it).
4. Liquid Glass is hard to read under bright hall lights (the exit test at a real match checks it; Reduce Transparency as a fallback).
5. Xcode and simulator runs slow down or flake on this Mac (A3).

## Proposed follow-ups
- (approved) Plan (H4): phase 3 "the native app" built from D1–D25 with the D17 exit test; phase 4 "the release pipeline" (D18) and phase 5 "the App Store" (D20) as outlines that wait on P1 and P2; decisions-table rows; the pre-mortem reasons as risks; A1–A3.
- (approved) ADR candidate: ADR-003 "Native app ports the rules to Swift, refereed by shared exact examples" (D6, D7, D23, D24): hard to reverse, surprising without context, a real trade-off against JavaScriptCore.
- (approved) ADR-002: add a note that it applies to the native app as well (D10), with JSON files in the app's storage instead of the browser's.
- (approved) Rules (H4): AGENTS.md › Stack and Where things live gain the Swift side (SwiftUI, Xcode 27.2, iOS 27.0 minimum, `ios/`, the shared examples).
- (approved) factory.yaml (H4): `mode: team`, roles `ios` and `web` with role files, and a heavy `checks` entry for the Swift tests that runs when `ios/**` or the shared examples change (D16, D25).
- (approved) Owner, by hand: `builders: 2` under `limits` in `~/.factory/machine.yaml` (D25).
- (approved) Glossary: the shared examples (code name to be set in the plan).
- (approved) Tickets after the plan merges: N1 Apple organisation account (agent:human), N2 Xcode project and the Swift check, N3 the logic port with the shared-examples export (in slices), then saving, the screens, the Duo wide layout, icon drafts (D22), the owner's free-ID install (agent:human, D15), and the exit test (D17).
- (approved) Factory request: redraft the four-part iOS request (store-app deploy contract, `ios-app-store` recipe, Swift/Xcode stack and mixed repo, revisit #51, now with D16's reason against a self-hosted runner on a public repo); not filed until the owner says so, then sent to the factory lead thread.
- (approved) Close the empty Phase 0 and Phase 1 milestones.
