# Grill: whole product, U14 playing-time tracker (2026-11-22)
Depth: deep · Read: owner's idea text (Dutch, in session), README.md, AGENTS.md, factory.yaml, empty board, web search on Basketbal Vlaanderen U14 playing-time rules (no result) · Status: done (2026-11-22)

## Map
1. Who uses it, where ✓ coach alone, on a phone, on the bench, during the game (premise 1)
2. Time tracking ✓ no game clock: time is counted in fixed blocks (D4)
   3. Block structure ✓ A: 12 blocks of 3:20; B: 8 blocks of 5:00 (D6)
   3b. Substitution flow ✓ live screen + one 'Wissel' button, no timer (D12)
4. Plan ✓ coach picks the starting five, then the app generates the grid (D20, D7); sub rule: prefer 2, max 3, sits ≤ 15:00 (D21, D22); positions ignored (D9)
5. Uneven blocks ✓ history switch decides who gets them (D10)
6. "In the zone" ✓ one tap keeps a player on, auto swap-back (D8)
7. Exceptions ✓ attendance at setup, 'uit'/'terug' re-spreads remaining blocks (D11) · overtime ✗ out of scope (D13)
8. Data ✓ one phone, no login, no sync (D5); team history (D10); roster name + number (D14)
9. Platform ✓ static HTML/CSS/JS on a Cloudflare Worker, nl only (D1, D2); offline + home screen (D15)
10. Budget ✓ about 4 hours of build, very small, no big setup (owner)
11. Robustness ✓ undo (D17), save every tap + keep awake (D18), one-screen setup (D19)
gap: league playing-time rules: none apply (premise 3, owner knows)

## Open (frontier)
| ID | Question | Risk | Who can answer |
| --- | --- | --- | --- |
None.

## Decisions
| ID | Decision | Why | By |
| --- | --- | --- | --- |
| D1 | Stack: plain HTML/CSS/JS, no build, no dependencies, served by a Cloudflare Worker; tests with `node --test` | 4-hour budget, no setup | user (install PR #2) |
| D2 | On-screen text Dutch (`nl`) only; code, issues and plan in English | users are a Flemish coach and staff | user (install PR #2) |
| D3 | Releases to production are manual; first release approved by the owner | the app must never change mid-match | user (install PR #2) |
| D4 | No game-clock tracking. Playing time is counted in fixed time blocks; a player's minutes = blocks played × block length. Subs happen at the first dead ball after a block ends | "simple fixed timeblocks would probably be the easiest… keep it simple" | user |
| D5 | Premises confirmed: one coach alone on a phone on the bench; no league playing-time rule applies; one device, data on the phone, no login or sync | premise round | user |
| D6 | Two schedules. Equal minutes: 12 blocks of 3:20 (subs at 6:40 and 3:20 in each quarter), every player 5 blocks = 16:40 with 12 players. 5-minute blocks: 8 blocks of 5:00 (sub at 5:00 and at quarter breaks); with 12 players 4 play 4 blocks (20 min), 8 play 3 (15 min) | 200 player-minutes / 12 is only exact with 60 places | user |
| D7 | Before the match the app generates the full plan as a grid (players × blocks), spread so nobody sits or plays long runs in a row; the coach can swap two players before tip-off | a plan to read at a glance | user |
| D8 | "In the zone": at a block change, one tap keeps a player who is due off on court. The player who missed this block gets the zone player's next planned block (the next one where the bench player is not already on). With no block left to swap, the difference stays and the overview shows it (+1/−1 block) | one tap, fairness kept | user |
| D9 | When a zone player stays on, the app proposes which incoming player stays off: the one with the most minutes so far (ties: roster order); the coach can tap another. Positions are ignored in v1 | fits budget; development team | user |
| D10 | Team history: after each match the app stores each player's minutes on the phone. A switch at match start ("houd rekening met vorige matchen") decides who gets blocks that cannot be split equally (B's extra blocks, spare blocks with fewer players): on → fewest total minutes so far, off → random. A "wis geschiedenis" button resets for a new season. History changes nothing else | small: one list, one sort | user |

## Assumptions to test
| ID | Assumption | How to test | Owner |
| --- | --- | --- | --- |
| A1 | One "Wissel" tap per block is faster than the coach's current gut-feel tracking (today: all in the head), so the app is used for a whole match | Use it in one real match or a training scrimmage; it passes if the coach never falls back to gut feel mid-match | owner (coach) |
| A3 | A plan that meets D21 exists for every attendance from 8 to 12 players in both schedules, with any starting five (checked only for 12 players) | Unit tests over 8–12 players and several starting fives, both schedules; if one fails, the planner relaxes the sit limit, never the sub cap, and says so | builder (planner ticket) |
| A2 | Block drift (±1 min per block) does not make the fairness visibly wrong to players or parents | Ask after 3 matches whether anyone noticed unequal minutes | owner (coach) |

## Parked
| ID | Question | Owner | Blocks |
| --- | --- | --- | --- |

## Proposed follow-ups
- (approved) Plan: factory-plan writes the plan from D1–D22, with one phase sized to the ~4-hour budget and an exit test of one real (or scrimmage) match without falling back to gut feel (A1).
- (approved) ADR candidates (hard to reverse, surprising, real trade-off): D4/D16 (fixed blocks, no game clock) and D5 (one device, data only on the phone).
- (approved) Glossary terms: blok (block), wissel (sub moment), in the zone, uit/terug, schema (gelijke minuten / blokken van 5 minuten).
- (approved) Commit this log with the plan PR (no separate PR).
