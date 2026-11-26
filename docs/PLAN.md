# vervanging: plan of attack

A phone app for the coach of a development-focused U14 basketball team (12 players, 4 × 10 minutes). Before a
match it plans who plays when in fixed time blocks, so everyone gets fair minutes; during the match the coach follows
the plan with one tap per substitution and can keep a player "in the zone" without breaking fairness. On-screen text
is Dutch. It runs as a web app today; phase 3 rebuilds it as a native iPhone app, which also pilots the Apple
account and an iOS release pipeline for the commercial app Zappo; phase 6 gives the native app its own look.
Status: phase 3 · Built from: [grill 2026-11-22 whole product](grill/2026-11-22-whole-product.md), [grill 2026-11-22 phase 2](grill/2026-11-22-phase-2.md), [grill 2026-11-23 phase 3](grill/2026-11-23-phase-3-native-ios.md) · Last changed: 2026-11-26

## Summary
| Topic | Decision |
| --- | --- |
| Time | No game clock: time is counted in fixed blocks; minutes = blocks played × block length (#4, #16) |
| Schedules | Equal minutes: 12 blocks of 3:20. 5-minute blocks: 8 blocks of 5:00 (#6) |
| Substitutions | Coach picks the starting five; then normally 2 changes per sub moment, at most 3 (a change may take off more when that is every player marked uit, #21), nobody sits more than 15:00 in a row (#20, #21, #22) |
| Live | One "Wissel" button per block; "in the zone" keeps a player on and hands a block back later; "uit"/"terug"; undo (#8, #11, #12, #17) |
| Data | One phone, no login, no sync; roster and per-match minutes stored on the phone (#5, #10, #14) |
| Phase 2 | Extra minuten to reward a player on purpose; minutes at a glance during a match and per season; gradual catch-up for missed matches that leaves rewards alone (#25–#28) |
| Robustness | Every tap saved; screen kept awake; works offline (#15, #18) |
| Stack | Static HTML/CSS/JS, no build, no dependencies, on a Cloudflare Worker; manual releases (#1, #3) |
| Phase 3 | A native iPhone app in `ios/` with the same features: SwiftUI and Liquid Glass, iOS 27, the rules ported to Swift and refereed by shared examples; data on the phone; the web app stays live (#29–#47) |
| Pilot | Phase 4 ships through TestFlight from CI, phase 5 through App Review to a free App Store release; both wait for the Apple organisation account (#44) |
| Look | Phase 6 gives the native app the Wisselbord look (a referee's substitution board: near-black board, big numbers, ▼ eruit / ▲ erin, amber for time) and recolours today's icon to match; it does not wait for the Apple account; the web app keeps its look (#49–#52) |

## Scope
### Who it is for
One coach, alone on the bench, using a phone during the match (#5). Today playing time is tracked "in the head, on gut
feeling".
### What they need to do
1. Enter the roster once: first name and jersey number, up to 15 players (#14).
2. Before a match, on one screen in under a minute: tick who is present, pick the starting five, pick the schedule,
   set the history switch, check the plan and swap players if needed, start (#19, #20, #7, #10).
3. During the match: see the current block, the sub time on the official clock, who is on court, who goes off and
   comes on next; tap "Wissel" at each sub (#12). Keep a player on when they are "in the zone" (#8, #9); mark a player
   "uit" or "terug" (#11); undo the last tap (#17).
4. After the match: the minutes per player are kept as team history (#10).
### Out of scope, on purpose
- A game clock or timer of any kind (#4, #12, #16)
- Overtime (#13)
- Positions and position balance (#9)
- Accounts, sync, sharing with staff or parents (#5)
- Printing or exporting (#23)
- Moving data from the web app to the native app (#33)
- Android, iPad, Apple Watch, widgets, Live Activities (#32)
### Success criteria
- With 12 players present and the history switch off (#28 may then give one block more to players behind), the
  generated equal-minutes plan gives every player exactly 5 blocks (16:40), with 2
  changes at every sub moment; checked by unit tests (#6, #21).
- Match setup takes under one minute on the coach's phone, timed by the coach before the first real match (#19).
- The coach uses the app for a whole real match or scrimmage without falling back to gut feel (A1).
- The Swift rules give exactly the same output as the JavaScript rules on every shared example; checked by both test
  suites (#35).

## Decisions
| # | Decision | Chosen | What it changes | Status | Source |
| --- | --- | --- | --- | --- | --- |
| 1 | Stack | Plain HTML/CSS/JS ES modules in `public/`, no build, no npm dependencies; Cloudflare Worker serves static assets; tests with `node --test` | App code in `public/`, tests as `*.test.js`; no installs | Decided | [grill D1](grill/2026-11-22-whole-product.md#decisions) (install PR #2) |
| 2 | Languages | On-screen text Dutch (`nl`) only; code, issues and plan in English | All UI strings in Dutch | Decided | [grill D2](grill/2026-11-22-whole-product.md#decisions) |
| 3 | Releases | Manual production releases; first release approved by the owner | The app never changes mid-match | Decided | [grill D3](grill/2026-11-22-whole-product.md#decisions) |
| 4 | How time is tracked | Fixed time blocks, no game clock; minutes = blocks × block length; sub at the first dead ball after a block ends | No timer code; the model is blocks, not seconds | Decided | [grill D4](grill/2026-11-22-whole-product.md#decisions) · ADR-001 |
| 5 | Premises | One coach alone on a phone; no league playing-time rule applies; one device, data on the phone, no login or sync | No backend; one-handed, fast UI | Decided | [grill D5](grill/2026-11-22-whole-product.md#decisions) · ADR-002 |
| 6 | Schedules | Equal minutes: 12 blocks of 3:20 (subs at 6:40 and 3:20 each quarter). 5-minute blocks: 8 blocks of 5:00 (sub at 5:00 and at quarter breaks) | The planner works for any block count | Decided | [grill D6](grill/2026-11-22-whole-product.md#decisions) |
| 7 | Plan before the match | Generated grid players × blocks, spread; coach swaps two players before tip-off | Setup shows an editable grid | Decided | [grill D7](grill/2026-11-22-whole-product.md#decisions) |
| 8 | In the zone | One tap at a block change keeps a player due off on court; the bench player who missed the block gets the zone player's next planned block where the bench player is not already on; with no such block left, the difference stays and the overview shows +1/−1 | Live replanning with swap-back | Decided | [grill D8](grill/2026-11-22-whole-product.md#decisions) |
| 9 | Who sits when a zone player stays; positions | App proposes the incoming player with most minutes so far (ties: roster order), coach can change; positions ignored | No position data | Decided | [grill D9](grill/2026-11-22-whole-product.md#decisions) |
| 10 | Team history | Per-match minutes stored; a setup switch "houd rekening met vorige matchen" gives uneven blocks to the fewest total minutes (else random); "wis geschiedenis" resets | One stored list, one sort | Decided; partly replaced by #28 (history now also drives catch-up, not only the uneven blocks) | [grill D10](grill/2026-11-22-whole-product.md#decisions) |
| 11 | Absent and dropped-out players | Attendance at setup. "Uit" for a player on court: a replacement comes on at once, preferably a player due on at the next wissel (fewest minutes first), so that wissel has one change less; with none (the last block), the bench player with the fewest minutes. The block counts for the player who started it; the replacement's minutes in it are not counted (no clock). The remaining blocks are re-spread (fewest minutes this match first, through one "replan remaining blocks" function) only when the player was planned in a later block. "Uit" for a player on the bench removes them from later blocks. "Uit" is possible in the last block. "Terug" brings a player back from the next block | Planner must replan from any block | Decided (one function: agent's call, reversible; the uit rules: owner's decision, 2026-11-22) | [grill D11](grill/2026-11-22-whole-product.md#decisions) · [uit decision on #9](https://github.com/filiplh/vervanging/issues/9#issuecomment-7084717144) · PR #19 |
| 12 | Live screen | Block number, sub time ("wissel op 6:40"), on court, off/on next; one big "Wissel" button; no timer | One main screen | Decided | [grill D12](grill/2026-11-22-whole-product.md#decisions) |
| 13 | Overtime | Not planned or counted | None | Decided | [grill D13](grill/2026-11-22-whole-product.md#decisions) |
| 14 | Roster | First name and jersey number, up to 15, stored on the phone | Roster screen | Decided | [grill D14](grill/2026-11-22-whole-product.md#decisions) |
| 15 | Offline | Works offline after the first visit (service worker); can be added to the home screen | Service worker + manifest | Decided | [grill D15](grill/2026-11-22-whole-product.md#decisions) |
| 16 | Blocks after devil's advocate | Fixed blocks stand; real minutes drift ±1 min per block and even out | Fairness is shown in blocks | Decided | [grill D16](grill/2026-11-22-whole-product.md#decisions) · ADR-001 |
| 17 | Undo | "Ongedaan maken" undoes the last live action, one step | Live actions are reversible | Decided | [grill D17](grill/2026-11-22-whole-product.md#decisions) |
| 18 | Never lose a match | State saved after every tap and restored after reload; screen kept awake (Wake Lock) where allowed | Persistence on every action | Decided | [grill D18](grill/2026-11-22-whole-product.md#decisions) · ADR-002 |
| 19 | Fast setup | One screen; last attendance pre-ticked; opponent optional; under a minute | Setup screen design | Decided | [grill D19](grill/2026-11-22-whole-product.md#decisions) |
| 20 | Starting five | Coach picks it; the app plans the rest from there | Planner takes a fixed first block | Decided | [grill D20](grill/2026-11-22-whole-product.md#decisions) |
| 21 | Sub rule | As few changes as possible per sub moment, normally 2, at most 3; 3 only to keep sits ≤ 15:00 or after a live change. Exception: a change may take off every player marked uit when that is more than 3 (uit is never refused for planning reasons) | Planner constraint; verified for 12 players; the live planner may exceed 3 only to take off players marked uit | Decided (exception approved by the owner, H4, 2026-11-22) | [grill D21](grill/2026-11-22-whole-product.md#decisions) · [H4 approval on #9](https://github.com/filiplh/vervanging/issues/9#issuecomment-7084678388) · PR #19 |
| 22 | Quarter breaks | The sub limit applies there too | One rule everywhere | Decided | [grill D22](grill/2026-11-22-whole-product.md#decisions) |
| 23 | Printing, export | Out of scope for now | None | Decided | [grill D23](grill/2026-11-22-whole-product.md#decisions) |
| 24 | In the zone stays give-back | The benched player gets the zone player's next planned block back, so totals stay equal (#8 unchanged) | None | Decided | [phase 2 D1](grill/2026-11-22-phase-2.md#decisions) |
| 25 | Extra minuten | A second option next to In the zone: the kept player does not give the block back; the blocks left are spread over the others, fewest minutes first; undoable; the sub rule (#21) holds | Live engine and screen | Decided | [phase 2 D2](grill/2026-11-22-phase-2.md#decisions) |
| 26 | Season totals | The Spelers screen shows each player's total minutes over all saved matches and the number of matches; Wis geschiedenis resets it | Roster screen reads the team history (#10) | Decided | [phase 2 D3](grill/2026-11-22-phase-2.md#decisions) |
| 27 | Minutes at a glance | A compact overview of every player's minutes so far at the top of the live screen; the full table stays below | Live screen | Decided | [phase 2 D4](grill/2026-11-22-phase-2.md#decisions) |
| 28 | Catching up missed matches | With the history switch on, players behind on season minutes get at most one block more per match than the equal share, from the players furthest ahead (at most one less each), until level; switch off: unchanged. Minutes from Extra minuten are left out of the totals it compares, so rewards stay. Replaces the first grill's "history changes nothing else" (#10) | Planner targets from history; the history keeps extra minuten apart | Decided | [phase 2 D7, D8](grill/2026-11-22-phase-2.md#decisions) |
| 29 | Where the native app lives | In `ios/` in this repo, beside `public/`; the web app stays live until the native app passes its exit test | A mixed web and iOS repo, like Zappo's planned shape | Decided | [phase 3 D1](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 30 | Why a native app | To pilot the Apple developer account and an iOS build and release pipeline Zappo can reuse, and for a native Liquid Glass feel; not for a coaching need the web app fails | Phase 3 is judged on the app and the pipeline, not new features | Decided | [phase 3 D2](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 31 | The match phone | An iPhone 17 Pro on iOS 27; the iPhone Duo is a second target, checked in the simulator | The real-match test runs on the 17 Pro | Decided | [phase 3 D3, D14](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 32 | Native scope | The same features as the phase 2 web app (roster, setup, planner, Wissel, in the zone, Extra minuten, uit/terug, undo, history, catch-up, both overviews); no new match features; Android, iPad, Apple Watch, widgets and Live Activities out of scope | Phase 3 is a port, not new product | Decided | [phase 3 D4, D21](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 33 | No data move | The native app starts with an empty history; the coach enters the roster again by hand; no import from the web app | No export or import code | Decided | [phase 3 D5](grill/2026-11-23-phase-3-native-ios.md#decisions) · ADR-002 |
| 34 | How the rules move | Ported to a pure Swift package with Swift tests; no JavaScriptCore, no web wrapper; stands after the devil's advocate | Two copies of the rules while the web app lives | Decided | [phase 3 D6, D24](grill/2026-11-23-phase-3-native-ios.md#decisions) · ADR-003 |
| 35 | Shared examples | A script exports the JS test cases as JSON examples in `shared/examples/`; both suites run them and compare exact output; the seeded generator is ported bit for bit | The two copies cannot drift | Decided (exact output and the path: agent's call, reversible) | [phase 3 D7, D23](grill/2026-11-23-phase-3-native-ios.md#decisions) · ADR-003 |
| 36 | Rules freeze | During phase 3 the rules in `public/js` change only for bug fixes, and each fix also lands in Swift with an updated example | Web rule work stops in phase 3 | Decided | [phase 3 D8](grill/2026-11-23-phase-3-native-ios.md#decisions) · ADR-003 |
| 37 | Native UI | SwiftUI only, with the system's Liquid Glass materials and controls; no custom glass look-alikes; UIKit only where SwiftUI cannot | Screens follow the OS look | Decided | [phase 3 D9](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 38 | Native storage | ADR-002 carries over: JSON files in the app's storage, saved after every tap, restored on launch; no SwiftData, no iCloud sync, no login | No backend, as before | Decided | [phase 3 D10](grill/2026-11-23-phase-3-native-ios.md#decisions) · ADR-002 |
| 39 | Native language | Dutch only, the web app's terms and copy, in an Xcode String Catalog | Copy is reused, not rewritten | Decided | [phase 3 D11](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 40 | Minimum iOS | iOS 27.0 | Both target phones run iOS 27; the iPhone Duo needs 27.1 or later | Decided (agent's call, reversible) | [phase 3 D12](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 41 | Screens | The iPhone 17 Pro and the iPhone Duo's outer screen share the phone layout; the Duo's inner screen gets a wide layout (plan grid without scrolling, minutes beside the court); every screen is checked on all three in the simulator | Every screen item covers two layouts | Decided | [phase 3 D13](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 42 | Before the Apple account | Build and test in the simulator; at parity the owner installs the app on their iPhone 17 Pro with their own free Apple ID (they sign in themselves; agents never touch the account), with a bundle ID ending in `.dev`; the real-match test may use that build | Phase 3 does not wait for Apple | Decided | [phase 3 D15](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 43 | Swift tests and CI | The Swift tests are a heavy factory check that runs only when `ios/` or the shared examples change, run locally by builders, the reviewer and `factory verify`; CI on GitHub-hosted macOS runners comes in phase 4; the self-hosted Mac mini (factory #51) stays parked for this repo | No macOS CI in phase 3 | Decided | [phase 3 D16](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 44 | Release path | Phase 4 ends with a TestFlight build from CI on the owner's phone; phase 5 takes the app through App Review to a free App Store release; both start once the organisation account works | Two more phases after the native app | Decided | [phase 3 D18, D20](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 45 | The web app after phase 3 | Stays live and frozen as a fallback; retiring it is decided after phase 4 | No web work after phase 3 except fixes | Decided | [phase 3 D19](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 46 | Name and icon | "Vervanging" under the icon; a new layered iOS 27 icon (light, dark, tinted, clear), 2–3 drafts, the owner picks | An icon item in phase 3 | Decided | [phase 3 D22](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 47 | How the factory runs phase 3 | Team mode with roles `ios` (`ios/**`) and `web` (`public/**`, `shared/**`, `scripts/**`, `wrangler.jsonc`); this Mac capped at 2 builders in the owner's machine settings | Parallel builders; role files | Decided (role paths: agent's call) | [phase 3 D25](grill/2026-11-23-phase-3-native-ios.md#decisions) |
| 48 | History at the switch to the store build | The free-ID build (`.dev` bundle ID) and the TestFlight or App Store build are separate apps on the phone; the history built on the free-ID build does not move to the store build, and the coach starts fresh again | No export or import code in phase 4 | Decided | owner on [plan PR #90](https://github.com/filiplh/vervanging/pull/90#issuecomment-7106544862), 2026-11-23 (raised by the lead after the grill) |
| 49 | The native app's look | Wisselbord, from the redesign spike's three directions: a near-black board with big compressed numbers, ▼ eruit in red and ▲ erin in green, amber only for time, blocks as an LED strip; glass stays in the bars (#37); built as phase 6, after phase 3's exit test, without waiting for the Apple account; the web app keeps its look (#45) | Every native screen and its UI tests change once | Decided | owner, 2026-11-26 · [redesign spike, owner's decisions](spikes/2026-redesign.md#the-owners-decisions-2026-11-26) |
| 50 | The icon in the new look | Today's icon (#46, #118) keeps its shapes and layers and takes the Wisselbord colours (dark background, not black; board colours on the glass layers); the spike's own icon idea is not used | A recolour, no new drawing | Decided (exact colours: agent's call, the owner sees them in the PR) | owner, 2026-11-26 · [redesign spike, owner's decisions](spikes/2026-redesign.md#the-owners-decisions-2026-11-26) |
| 51 | One live screen | The spike's "Wissel moment" focus state (minutes hidden, the board grown) is not built: the app does not know when the referee whistles (no game clock, ADR-001), so it would need its own tap or a guess, and it would hide the minutes when the coach may want them | The live screen keeps one layout | Agent's call, to confirm | lead, 2026-11-26, after the owner asked why the proofs had an extra screen · [redesign spike, owner's decisions](spikes/2026-redesign.md#the-owners-decisions-2026-11-26) |
| 52 | Copy in the new look | Today's sentences stay word for word (#39); new copy is limited to short column labels in the new tables ("Nr", "Naam", "Seizoen"); the proofs' other new phrases are dropped (list in the spike) | The owner writes no new copy for phase 6 | Agent's call, to confirm | lead, 2026-11-26, after the owner asked what the copy needs · [redesign spike, new words](spikes/2026-redesign.md#new-words-on-screen) |

## Architecture
- [ADR-001](adr/001-fixed-blocks-no-game-clock.md) Fixed time blocks, no game clock (accepted): playing time is
  counted in blocks of 3:20 or 5:00, never measured.
- [ADR-002](adr/002-one-phone-local-storage.md) One phone, data only on the device (accepted): roster, match state
  and history live on the phone (the browser's storage; JSON files in the native app), saved after every tap; no
  backend, login or sync.
- [ADR-003](adr/003-native-rules-ported-to-swift.md) The native app ports the rules to Swift, refereed by shared exact
  examples (accepted): two copies of the rules while the web app lives, kept identical by examples both suites run.

Index: [adr/README.md](adr/README.md).

## Glossary
[GLOSSARY.md](GLOSSARY.md): blok, schema, wissel, in the zone, extra minuten, uit / terug, basisvijf, shared examples, Wisselbord.

## Assumptions to test
| # | Assumption | How to test | Owner | Tested in | Source |
| --- | --- | --- | --- | --- | --- |
| A1 | One "Wissel" tap per block beats gut-feel tracking, so the app is used for a whole match | Use it in one real match or scrimmage; passes if the coach never falls back to gut feel mid-match | owner (coach) | Phase 1 exit: passed 2026-11-22 (#12) | [grill A1](grill/2026-11-22-whole-product.md#assumptions-to-test) |
| A4 | Extra minuten stays rare, so equal minutes remains the norm over a season | After three matches, the coach counts the matches in which Extra minuten was used: at most one of the three passes | owner (coach) | after phase 2 | [phase 2 A1](grill/2026-11-22-phase-2.md#assumptions-to-test) |
| A2 | Block drift (±1 min per block) does not make fairness visibly wrong to players or parents | Ask after 3 matches whether anyone noticed unequal minutes | owner (coach) | after phase 1 | [grill A2](grill/2026-11-22-whole-product.md#assumptions-to-test) |
| A5 | ⚠ A free Apple ID can install the app on the owner's iPhone through Xcode; the install expires after 7 days, at most 3 such apps per phone, Developer Mode must be on; the app needs no paid-only capability | The owner's first install on the 17 Pro; the expiry noted a week later | owner | Phase 3 (free-ID install) | [phase 3 A1](grill/2026-11-23-phase-3-native-ios.md#assumptions-to-test) |
| A6 | ⚠ The iPhone Duo's screens in the simulator match the real device closely enough that layouts checked there hold | Not testable without a Duo; revisit if the owner or Zappo's users get one | owner | not before a real Duo | [phase 3 A2](grill/2026-11-23-phase-3-native-ios.md#assumptions-to-test) |
| A7 | This Mac carries Xcode builds and simulator runs beside the owner's other work, with 2 builders and one heavy run at a time | The lead notes build and test times on the first two Swift items (Xcode project, first rules slice) and reports them; if the Mac struggles, the owner slows other projects or lowers the cap | owner, lead | Phase 3 (first items) | [phase 3 A3](grill/2026-11-23-phase-3-native-ios.md#assumptions-to-test) |
| A8 | ⚠ The near-black board (#49) stays readable in a bright sports hall and in sun, without more reflections than a white page | The phase 6 exit test at a real match; the coach notes any glance that failed | owner (coach) | Phase 6 exit | [redesign spike, judged](spikes/2026-redesign.md#judged) |
| A3 | A plan meeting #21 exists for 8–12 players in both schedules, with any starting five | Unit tests over 8–12 players and several starting fives, both schedules; on failure the planner relaxes the sit limit, never the sub cap, and says so | builder | Phase 0 (planner) | [grill A3](grill/2026-11-22-whole-product.md#assumptions-to-test) |

## Parked
| # | Question | Owner | Blocks | Source |
| --- | --- | --- | --- | --- |
| P1 | Apple organisation enrolment (stuck; the owner has emailed Apple support) | owner | Phases 4 and 5: TestFlight, App Store Connect, distribution signing | [phase 3 P1](grill/2026-11-23-phase-3-native-ios.md#parked) |
| P2 | Filing the factory's iOS request (store-app deploy contract, an `ios-app-store` recipe, Swift/Xcode stack and mixed repo, revisit factory #51) in vegvisir-factory | owner | Phase 4's CI and release items | [phase 3 P2](grill/2026-11-23-phase-3-native-ios.md#parked) |
| P3 | A rules goal that a player ideally plays no more than 2 blocks in a row and sits no more than 2 blocks in a row (the owner's investigation of 2026-11-25); the current rules stay until the coach has used the native app at a few live matches | owner (coach) | Nothing now; any change to the rules (#20–#22, #36) | owner, 2026-11-26 · [redesign spike, owner's decisions](spikes/2026-redesign.md#the-owners-decisions-2026-11-26) |

## Risks
| Risk | What it would look like | Mitigation |
| --- | --- | --- |
| Lost match state | Phone locks or page reloads mid-match and the plan is gone | Save after every tap and restore (#18); undo (#17) |
| Planner cannot meet the sub rule for some attendance | With 9 players the plan breaks the 2–3 cap or a sit gets very long | A3 tests in phase 0; the planner relaxes the sit limit, never the cap, and shows it |
| Browser clears stored data | In a Safari tab, iOS deletes all of a site's script-writable storage (roster, match, history, and the offline cache) after 7 days of Safari use without interaction with the site: days of use, not calendar days, so history can disappear between weekly matches ([WebKit, 2020](https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/)). A home-screen app has its own counter of days of use, which real use resets, and WebKit does not expect its data to be deleted; this is not an exemption, and later WebKit policy says persistent storage is granted on heuristics such as whether the site is a Home Screen Web App ([WebKit, 2023](https://webkit.org/blog/14403/updates-to-storage-policy/)). ⚠ Not tried on the owner's iPhone | Phase 1: home-screen install (#15), and the setup screen tells the coach to add it (agent's call; built in PR #22) |
| App changes mid-match | A release lands during a game | Manual releases only (#3) |
| Fairness drift | Players notice unequal real minutes | Accepted (#16); A2 checks it |
| Apple enrolment never resolves | Phases 4 and 5 stall and Zappo has no proven pipeline | Phase 3 does not depend on it (#42); P1 is the owner's |
| Free-ID install expires | The app will not open at the bench on match day, 7 days after the install | Reinstall before each match while on the free ID (#42); A5 checks the limits |
| A port bug | The native planner gives a plan the web app would not, and the coach loses trust | Exact shared examples (#35); the phase 3 exit test at a real match |
| Glass hard to read in the hall | Names or the Wissel button get lost behind Liquid Glass under bright lights | The phase 3 exit test runs at a real match with Reduce Transparency off |
| Mac overloaded | Xcode and simulator runs slow down or flake with parallel builders | 2 builders, one heavy run at a time (#47); A7 measures it |
| The new look breaks a working screen | A restyled live screen loses a control, a label or a tap the coach relied on | Phase 6 keeps today's screens, copy and accessibility identifiers; the UI tests run on every item; the exit test is a real match |
| History lost at the switch to the store build | The `.dev` build and the store build have different bundle IDs, so a history built on the free-ID build does not carry over | Accepted (#48): a fresh start again at the switch, as with #33 |

## Plan of attack
Phase 0 builds the smallest app a coach can use at a match: roster, setup, the planner for both schedules and the live
"Wissel" flow, saved on every tap and deployed. Phase 1 adds the live exceptions and the extras the grill asked for
(in the zone, uit/terug, history, offline, wake lock) and ends with the real-match test. The planner comes first
because every screen depends on it, and its tests settle A3. Phase 2 answers what the coach missed in the phase 1
match: a deliberate way to reward a player with extra minutes, and the minutes at a glance, during a match and over the
season. Phase 3 rebuilds the app natively on the iPhone, rules first, because every screen depends on them
and the shared examples prove them identical; it needs no Apple account. Phases 4 and 5 walk the release pipeline
(TestFlight, then the App Store) once the account works. Phase 6 restyles the native app in the Wisselbord look; it
starts after phase 3's exit test and does not wait for the account, so it may run before or beside phases 4 and 5.

### Phase 0: plan and play a match
Goal: the coach can enter the roster, set up a match and follow the plan with one tap per sub on their phone, at the
production URL.
- [ ] Planner: pure functions that build a plan for N players present, a chosen starting five and either schedule,
      meeting the sub rule, with unit tests over 8–12 players (#6, #7, #20, #21, #22, A3)
- [ ] Roster and match setup screen: name + number, attendance (last match pre-ticked), starting five, schedule,
      plan grid with swaps, start (#14, #19, #20, #7, #2)
- [ ] Live screen: block, sub time, on court, off/on next, "Wissel", undo, minutes per player; an end-of-match screen
      with each player's minutes; state saved after every tap and restored after reload (#12, #17, #18, #4)
- [ ] Deploy: Wrangler config serving `public/` as static assets for Worker `vervanging`; first production release
      approved by the owner (#1, #3)
- **Exit:** On the coach's phone at the production URL, the coach enters 12 players, then sets up an equal-minutes
  match in under one minute (roster entry not counted), taps "Wissel" at each of the 11 sub moments and ends the match
  after block 12, with one reload in the middle, and the end-of-match screen shows 16:40 for every player. Checked by
  the owner.

### Phase 1: real matches
Goal: the app handles what happens in a real game and keeps history, offline.
- [ ] In the zone and drop-outs: keep-on with swap-back and proposed sitter; "uit"/"terug" through the replan function;
      both undoable (#8, #9, #11, #17)
- [ ] Team history: store per-match minutes, the setup switch, "wis geschiedenis" (#10)
- [ ] Offline and awake: service worker, web app manifest for the home screen, Wake Lock during a match, home-screen
      hint (#15, #18)
- **Exit:** The coach uses the app for one real match or scrimmage of 4 × 10 minutes with the hall's wifi and mobile
  data off, uses "in the zone" at least once, and never falls back to gut feel (A1). Checked by the owner.

### Phase 2: the coach's overview
Goal: the coach can reward a player with extra minutes on purpose, and sees every player's minutes at a glance during
a match and over the season.
- [ ] Extra minuten: a second option next to In the zone; the kept player keeps the block, the rest is re-spread
      fewest minutes first, undoable, under the sub rule (#24, #25, #21)
- [ ] Minutes at a glance at the top of the live screen (#27)
- [ ] Season totals per player on the Spelers screen, from the team history (#26, #10)
- [ ] Gradual catch-up for players behind on season minutes when the history switch is on (#28, #10, #21)
- **Exit:** At a real match or scrimmage, the coach uses Extra minuten for one player at least once and reads every
  player's minutes at the top of the live screen without scrolling. After the match, the Spelers screen shows that
  player's season total one block higher than the players who played the same matches without extra minuten. When a
  player missed an earlier match, the next plan with the history switch on gives them one block more than the equal
  share, and the rewarded player no block less. Checked by the owner.

### Phase 3: the native app
Goal: the coach runs a whole real match in a native iPhone app that does everything the phase 2 web app does, with the
rules ported to Swift and proven identical by the shared examples, without waiting for the Apple account.
Phase 3 starts the native side; the organisation account (P1) blocks phases 4 and 5, not this phase.
- [ ] Apple developer account: the owner enrols the organisation (a person's task; P1) (#30, #44)
- [ ] Xcode project in `ios/`: a SwiftUI app and a pure Swift rules package, iOS 27.0, a `.dev` bundle ID, and the
      Swift tests as a heavy factory check for `ios/**` and `shared/**` (that `factory.yaml` line is the owner's
      approval, H4); the lead notes build and test times (#29, #37, #40, #42, #43, A7)
- [ ] Shared examples: a script exports the JS test cases as exact JSON examples in `shared/examples/`, and the JS
      suite runs them (#35)
- [ ] The rules in Swift, in slices (planner with the seeded generator, the live match engine, history and catch-up),
      each passing every shared example (#34, #35, #36, #6–#11, #17, #20–#22, #24, #25, #28)
- [ ] Saving and staying awake: JSON files written after every tap and restored on launch; the screen stays on during
      a match (#38, #18)
- [ ] Screens, in Dutch with the web app's copy: Spelers with season totals, match setup with the plan grid and swaps,
      the live screen (Wissel, in the zone, Extra minuten, uit/terug, undo, minutes at a glance) and the end screen,
      each in the phone layout and checked on the iPhone 17 Pro and the Duo's outer screen (#32, #37, #39, #41, #12,
      #19, #26, #27)
- [ ] The wide layout for the iPhone Duo's inner screen: the plan grid without scrolling, the minutes beside the court
      (#41, A6)
- [ ] App icon: 2–3 drafts of a layered iOS 27 icon; the owner picks one (#46)
- [ ] Install on the coach's iPhone 17 Pro with the owner's free Apple ID (a person's task) (#42, A5)
- **Exit:** At a real match or scrimmage of 4 × 10 minutes, on the owner's iPhone 17 Pro (the free-ID build), in
  airplane mode and with Reduce Transparency off, the coach runs the whole match in the native app without opening
  the web app. In the zone, Extra minuten and uit/terug are each used at least once. The app is force-quit once
  mid-match and reopens on the same block with the same players. The end screen shows each player's minutes as the
  blocks they played, and the Spelers screen shows the same minutes as each player's season total (the history
  starts empty, #33). Every screen has been seen in the simulator on the iPhone 17 Pro and on both iPhone Duo screens.
  Checked by the owner.

### Phase 4: the release pipeline (draft)
Goal: a build made by CI from the default branch reaches the coach's phone through TestFlight, on the factory's iOS
recipe. Starts when the organisation account works (P1) and the factory's iOS request is filed and built (P2).
- [ ] CI on GitHub-hosted macOS runners for the Swift tests (#43)
- [ ] Signing with the organisation account and an upload to TestFlight from CI (#44)
- [ ] Decide whether to retire the web app (#45)
- **Exit:** A build that CI made from the default branch is installed through TestFlight on the owner's iPhone 17 Pro,
  opens, and plans a match. Checked by the owner.

### Phase 5: the App Store (draft)
Goal: vervanging is a free app on the App Store, so the whole path Zappo needs (App Review, privacy label, store
listing) has been walked once.
- [ ] Store listing in Dutch, screenshots, the privacy label (no data collected, #38) and the privacy policy page
      App Store Connect asks for (⚠ to confirm when the account works) (#44)
- [ ] Submit for App Review and release (#44)
- **Exit:** The owner installs vervanging from the App Store on their iPhone 17 Pro and plans a match with it.
  Checked by the owner.

### Phase 6: the Wisselbord look (draft)
Goal: the native app looks like a referee's substitution board, so the coach reads who goes off, who comes on and when
in one glance pitch-side, with every screen's features, copy and rules unchanged. Starts after phase 3's exit test
(#109); does not wait for the Apple account (P1). The look, its colours and the work list are in the
[redesign spike](spikes/2026-redesign.md).
- [ ] Design tokens: colour sets with light, dark and increased-contrast values, and type helpers (SF Pro Compressed for
      numbers, Condensed for labels, through text styles), replacing literal colours (#49)
- [ ] The live screen: the time board with the LED strip, the substitution board (▼ Eruit / ▲ Erin) with In the zone and
      Extra minuten, and the minutes as a stat sheet with Uit / Terug; the time never reads as a running clock (ADR-001);
      one layout, no focus state (#49, #51)
- [ ] Setup and the plan: the table with a present check and a "B" key, and the dot-matrix plan with swaps (#49)
- [ ] Spelers: big numbers, season bars, and a visible way to edit and delete (#49)
- [ ] The wide layout for the iPhone Duo's inner screen in the new look (#41, #49, A6)
- [ ] The app icon recoloured to the new look, in light, dark, tinted and clear (#50)
- [ ] Accessibility pass: Accessibility sizes, VoiceOver labels for drawn elements, Reduce Motion and Reduce
      Transparency, and a test that every token pair meets 4.5:1 for text (#49)
- **Exit:** At a real match or scrimmage, on the owner's iPhone 17 Pro, the coach runs the whole match in the restyled
  app, using Wissel at every change and In the zone, Extra minuten and uit/terug at least once, and reads the next
  wissel from the board without opening another view (A8). Every screen has been seen in the simulator on the iPhone 17
  Pro and on both iPhone Duo screens, in light and dark, at Accessibility L and with Increase Contrast, Reduce
  Transparency and Reduce Motion on, and with VoiceOver through one whole wissel. The home screen shows the recoloured
  icon. Checked by the owner.
