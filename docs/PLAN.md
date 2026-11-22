# vervanging: plan of attack

A phone web app for the coach of a development-focused U14 basketball team (12 players, 4 × 10 minutes). Before a
match it plans who plays when in fixed time blocks, so everyone gets fair minutes; during the match the coach follows
the plan with one tap per substitution and can keep a player "in the zone" without breaking fairness. On-screen text
is Dutch.
Status: phase 2 · Built from: [grill 2026-11-22 whole product](grill/2026-11-22-whole-product.md), [grill 2026-11-22 phase 2](grill/2026-11-22-phase-2.md) · Last changed: 2026-11-22

## Summary
| Topic | Decision |
| --- | --- |
| Time | No game clock: time is counted in fixed blocks; minutes = blocks played × block length (#4, #16) |
| Schedules | Equal minutes: 12 blocks of 3:20. 5-minute blocks: 8 blocks of 5:00 (#6) |
| Substitutions | Coach picks the starting five; then normally 2 changes per sub moment, at most 3 (a change may take off more when that is every player marked uit, #21), nobody sits more than 15:00 in a row (#20, #21, #22) |
| Live | One "Wissel" button per block; "in the zone" keeps a player on and hands a block back later; "uit"/"terug"; undo (#8, #11, #12, #17) |
| Data | One phone, no login, no sync; roster and per-match minutes stored on the phone (#5, #10, #14) |
| Robustness | Every tap saved; screen kept awake; works offline (#15, #18) |
| Stack | Static HTML/CSS/JS, no build, no dependencies, on a Cloudflare Worker; manual releases (#1, #3) |

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
### Success criteria
- With 12 players present, the generated equal-minutes plan gives every player exactly 5 blocks (16:40), with 2
  changes at every sub moment; checked by unit tests (#6, #21).
- Match setup takes under one minute on the coach's phone, timed by the coach before the first real match (#19).
- The coach uses the app for a whole real match or scrimmage without falling back to gut feel (A1).

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
| 10 | Team history | Per-match minutes stored; a setup switch "houd rekening met vorige matchen" gives uneven blocks to the fewest total minutes (else random); "wis geschiedenis" resets | One stored list, one sort | Decided; "changes nothing else" replaced by #28 | [grill D10](grill/2026-11-22-whole-product.md#decisions) |
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
| 28 | Catching up missed matches | With the history switch on, players behind on season minutes get at most one block more per match than the equal share, from the players furthest ahead (at most one less each), until level; switch off: unchanged. Replaces "history changes nothing else" in #10 | Planner targets from history | Decided | [phase 2 D7](grill/2026-11-22-phase-2.md#decisions) |

## Architecture
- [ADR-001](adr/001-fixed-blocks-no-game-clock.md) Fixed time blocks, no game clock (accepted): playing time is
  counted in blocks of 3:20 or 5:00, never measured.
- [ADR-002](adr/002-one-phone-local-storage.md) One phone, data only on the device (accepted): roster, match state
  and history live in the browser's storage, saved after every tap; no backend, login or sync.

Index: [adr/README.md](adr/README.md).

## Glossary
[GLOSSARY.md](GLOSSARY.md): blok, schema, wissel, in the zone, extra minuten, uit / terug, basisvijf.

## Assumptions to test
| # | Assumption | How to test | Owner | Tested in | Source |
| --- | --- | --- | --- | --- | --- |
| A1 | One "Wissel" tap per block beats gut-feel tracking, so the app is used for a whole match | Use it in one real match or scrimmage; passes if the coach never falls back to gut feel mid-match | owner (coach) | Phase 1 exit: passed 2026-11-22 (#12) | [grill A1](grill/2026-11-22-whole-product.md#assumptions-to-test) |
| A4 | Extra minuten stays rare, so equal minutes remains the norm over a season | After three matches, season totals differ by at most a few blocks between players who attended the same matches | owner (coach) | after phase 2 | [phase 2 A1](grill/2026-11-22-phase-2.md#assumptions-to-test) |
| A2 | Block drift (±1 min per block) does not make fairness visibly wrong to players or parents | Ask after 3 matches whether anyone noticed unequal minutes | owner (coach) | after phase 1 | [grill A2](grill/2026-11-22-whole-product.md#assumptions-to-test) |
| A3 | A plan meeting #21 exists for 8–12 players in both schedules, with any starting five | Unit tests over 8–12 players and several starting fives, both schedules; on failure the planner relaxes the sit limit, never the sub cap, and says so | builder | Phase 0 (planner) | [grill A3](grill/2026-11-22-whole-product.md#assumptions-to-test) |

## Parked
None.

## Risks
| Risk | What it would look like | Mitigation |
| --- | --- | --- |
| Lost match state | Phone locks or page reloads mid-match and the plan is gone | Save after every tap and restore (#18); undo (#17) |
| Planner cannot meet the sub rule for some attendance | With 9 players the plan breaks the 2–3 cap or a sit gets very long | A3 tests in phase 0; the planner relaxes the sit limit, never the cap, and shows it |
| Browser clears stored data | In a Safari tab, iOS deletes all of a site's script-writable storage (roster, match, history, and the offline cache) after 7 days of Safari use without interaction with the site: days of use, not calendar days, so history can disappear between weekly matches ([WebKit, 2020](https://webkit.org/blog/10218/full-third-party-cookie-blocking-and-more/)). A home-screen app has its own counter of days of use, which real use resets, and WebKit does not expect its data to be deleted; this is not an exemption, and later WebKit policy says persistent storage is granted on heuristics such as whether the site is a Home Screen Web App ([WebKit, 2023](https://webkit.org/blog/14403/updates-to-storage-policy/)). ⚠ Not tried on the owner's iPhone | Phase 1: home-screen install (#15), and the setup screen tells the coach to add it (agent's call; built in PR #22) |
| App changes mid-match | A release lands during a game | Manual releases only (#3) |
| Fairness drift | Players notice unequal real minutes | Accepted (#16); A2 checks it |

## Plan of attack
Phase 0 builds the smallest app a coach can use at a match: roster, setup, the planner for both schedules and the live
"Wissel" flow, saved on every tap and deployed. Phase 1 adds the live exceptions and the extras the grill asked for
(in the zone, uit/terug, history, offline, wake lock) and ends with the real-match test. The planner comes first
because every screen depends on it, and its tests settle A3. Phase 2 answers what the coach missed in the phase 1
match: a deliberate way to reward a player with extra minutes, and the minutes at a glance, during a match and over the
season.

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
- **Exit:** At a real match or scrimmage, the coach uses Extra minuten for one player at least once, reads the minutes
  at the top of the live screen without scrolling, and after the match sees that player's higher total on the Spelers
  screen. With the history switch on, a player who missed an earlier match gets one block more than the equal share in
  the plan. Checked by the owner.
