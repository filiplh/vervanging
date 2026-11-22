# Spike: UI/UX review of every screen at iPhone size (#35)

**Question.** How well do the screens hold up for a coach with one hand, in a noisy hall, with seconds to act? What
should we fix before the phase 2 exit?

**What was done.** The app ran at `main` d3ebd32 with the project's serve command. It was opened in headless Google
Chrome over the DevTools protocol at 402 × 874 CSS px, DPR 3, with mobile emulation, touch events and an iPhone user
agent, in light and dark (`prefers-color-scheme` emulation), each run with a fresh profile. Every flow was driven
through the real buttons: 11 made-up players added through the form, a match set up, swaps, In the zone, Extra
minuten, Uit and Terug, Ongedaan maken, play to the last block, Einde match, then a second match with "Houd rekening
met vorige matchen" on, and the season totals. Tap targets were measured with `getBoundingClientRect`, and the colour
tokens in `public/styles.css` were run through the WCAG contrast formula. Screenshots are in
[`2026-ui-review/`](2026-ui-review/), saved at half the device resolution to keep them small.

**Short answer.** Two P1s, both on the live screen: the names of the players due off vanish as soon as the In the
zone and Extra minuten buttons are drawn next to them, and once the coach leaves a running match the app offers no
way back to it, while "Start" on the setup screen drops it without asking. Fix those two, plus the double tap on Wissel, before the phase 2 exit. The rest is polish.

## Screens walked

| Screen or flow | Light | Dark |
| --- | --- | --- |
| Spelers, empty, then an empty Toevoegen | [leeg](2026-ui-review/01-spelers-leeg-light.png), [fout](2026-ui-review/02-spelers-fout-light.png) | no change |
| Spelers with season totals (after 2 matches) | [seizoen](2026-ui-review/23-spelers-seizoen-light.png) | [seizoen](2026-ui-review/23-spelers-seizoen-dark.png) |
| Match setup: top, home-screen hint, attendance and basisvijf | [boven](2026-ui-review/04-match-boven-light.png), [full page](2026-ui-review/08-match-volledig-light.png) | [boven](2026-ui-review/04-match-boven-dark.png) |
| Plan grid, equal and 5-minute schedule | [plan](2026-ui-review/05-match-plan-light.png), [5 min](2026-ui-review/09-match-plan-5min-light.png) | see swap |
| Swaps: first tap, done, refused | [gekozen](2026-ui-review/06a-match-ruil-gekozen-light.png), [geruild](2026-ui-review/06-match-ruil-light.png), [fout](2026-ui-review/07-match-ruil-fout-light.png) | [gekozen](2026-ui-review/06a-match-ruil-gekozen-dark.png) |
| History switch and Wis geschiedenis | [uit](2026-ui-review/21-match-geschiedenis-light.png), [aan](2026-ui-review/22-match-geschiedenis-aan-light.png) | [uit](2026-ui-review/21-match-geschiedenis-dark.png) |
| Live: block 1, overview at the top, Wissel, Ongedaan maken | [blok 1](2026-ui-review/10-live-blok1-light.png), [full page](2026-ui-review/11-live-volledig-light.png), [after a wissel](2026-ui-review/14-live-na-extra-light.png) | [blok 1](2026-ui-review/10-live-blok1-dark.png) |
| Live: In the zone and Extra minuten | [zone](2026-ui-review/12-live-zone-light.png), [extra](2026-ui-review/13-live-extra-light.png) | [zone](2026-ui-review/12-live-zone-dark.png), [extra](2026-ui-review/13-live-extra-dark.png) |
| Live: Uit, the replacement note, Terug | [uit](2026-ui-review/16-live-uit-light.png), [table](2026-ui-review/17-live-tabel-uit-light.png) | [uit](2026-ui-review/16-live-uit-dark.png), [table](2026-ui-review/17-live-tabel-uit-dark.png) |
| Live: last block with Einde match | [laatste blok](2026-ui-review/18-live-laatste-blok-light.png) | [laatste blok](2026-ui-review/18-live-laatste-blok-dark.png) |
| End of match | [einde](2026-ui-review/19-einde-light.png) | [einde](2026-ui-review/19-einde-dark.png) |
| Leaving a running match through the Match tab | [match tab](2026-ui-review/24-match-tab-tijdens-match-light.png) | no change |

"No change" means dark mode changes only the palette there, with nothing new to judge. The home-screen hint is the
first paragraph of the setup screen ("Tip: zet Vervanging op je beginscherm …").

## Findings

Priorities: **P1** can cost the coach the match flow or the minutes record during a game. **P2** slows the coach down
or invites a mistaken tap that can be undone. **P3** is polish. Sizes: **S** is under half a day, **M** is about a day.

### P1-1 · Live: the names under "Eruit" are gone

- **Element:** `.names.off li .player` in "Bij de volgende wissel › Eruit", on every block that has someone due off.
- **Seen:** the name measured **0 px wide** (`#4 Lotte` and `#8 Lien` in the run). Each row shows only the two
  buttons "In the zone" and "Extra minuten" ([light](2026-ui-review/10-live-blok1-light.png),
  [dark](2026-ui-review/10-live-blok1-dark.png), [after a wissel](2026-ui-review/14-live-na-extra-light.png)). Once
  a zone choice is open, the "Erin" names shrink to `#12 S…` next to "Op de bank"
  ([zone](2026-ui-review/12-live-zone-light.png), [dark](2026-ui-review/12-live-zone-dark.png)).
- **Why it matters:** at the wissel the coach needs one thing: who comes off. That is exactly what is missing. In the
  zone has to be decided per player, so the coach cannot even tell which button belongs to whom. The cause is the
  layout: `.player` has `flex: 1; min-width: 0; overflow: hidden`, and the two chips (75 + 88 px, plus margins) take
  the whole width of a half-screen column (`.change` is `1fr 1fr`).
- **Fix (S):** let an "Eruit" row wrap, with the name on its own full-width line and the chips under it
  (`.names.off li { flex-wrap: wrap }`, `.names.off .player { flex-basis: 100% }`). Do the same for the "Erin" rows
  while "Op de bank" is shown. P2-4 below removes one of the two chips, which also helps.

### P1-2 · No way back to a running match inside the app, and Start drops it without asking

- **Element:** the tabs `.tabs a[data-view="match"]` and `[data-view="spelers"]` on the live screen, `defaultView()` in
  `public/js/app.js`, and the "Start" button on the Match screen.
- **Seen:** at block 3, one tap on the "Match" tab opens the setup screen
  ([screenshot](2026-ui-review/24-match-tab-tijdens-match-light.png)). It has no link to `#start`, although the match
  is still saved. Opening the app at `/` (as the home-screen icon does: `start_url` is `/`) also lands on the setup
  screen, not on the match. In the browser tab, Back (the existing hashchange handler) or typing `#start` by hand
  brings the match back at block 3; nothing inside the app does. On the setup screen,
  "Start" runs `store.remove('match')` with no question asked, so a coach who taps it to get back loses the match.
- **Why it matters:** decision #18 ("never lose a match") holds for a reload of `#start`, but not for the two ways a
  coach really leaves the screen: a stray tap on the tab bar, and the phone dropping the app while the coach checks
  the scoreboard or takes a call, so the app starts again from the icon. ⚠ The installed iOS app has no address bar
  and no back button; whether iOS reopens a home-screen app at `start_url` or at the last URL after it drops it from
  memory could not be checked here (see below).
- **Fix (M):** while a saved match exists and has not ended, `defaultView()` returns `start`, the "Match" tab links to
  `#start`, and the setup screen shows a "Terug naar de match" button at the top (⚠ copy to confirm). "Start" asks
  first when it would replace a running match ("De lopende match stoppen en een nieuwe beginnen?", ⚠ copy to confirm).

### P2-1 · Live: a double tap on Wissel plays two wissels

- **Element:** `button.wissel` ("Wissel", and "Einde match" on the last block).
- **Seen:** two scripted touches 120 ms apart on Wissel took the match from block 1 to **block 3**. The button is
  redrawn in the same spot at once and takes the second tap. In code, each click applies, saves and redraws with no
  guard (`act` in `public/js/live.js`). No screenshot can show the two-tap sequence; for the button and its spot, see
  [block 1](2026-ui-review/10-live-blok1-light.png) (context, before the taps).
- **Why it matters:** ⚠ the risk (not observed with coaches) is a coach in a hurry tapping twice, or again because
  nothing seemed to happen (see P2-2). If two taps arrive, one block is skipped: the wrong players come on, and the minutes go wrong until the coach notices and taps
  Ongedaan maken. Ongedaan maken undoes one step, so a double tap on the second-to-last wissel also ends the match.
  ⚠ Whether real iOS Safari passes a fast double tap to the page as two clicks, or treats it as a zoom gesture, was
  not checked on a device.
- **Fix (S):** ignore a second Wissel tap within about 600 ms of the first (a timestamp in `liveScreen`), and set
  `touch-action: manipulation` on buttons.

### P2-2 · Live: no explicit confirmation that a tap worked, and Ongedaan maken does not say what it undoes

- **Element:** `.message` on the live screen (filled only on an error), `button.undo` ("Ongedaan maken"), and buttons
  in general (no `:active` style).
- **Seen:** after Wissel, Uit or Terug the screen is redrawn: the block heading, the overview totals and the lists
  change ([before](2026-ui-review/10-live-blok1-light.png), [after](2026-ui-review/14-live-na-extra-light.png)), so
  the new state is visible. But no message says what was done (a successful action clears `.message`), and buttons
  show no pressed state.
- **Why it matters:** in a loud hall, with eyes going between the court and the phone, the coach has to compare the
  lists to tell whether the tap took. ⚠ That this invites the double tap of P2-1 is our reading; it was not tested
  with coaches. Ongedaan maken is a blind undo: the coach cannot see
  whether it will undo the wissel or the Uit they made just before.
- **Fix (S):** after each action, write one line in `.message`, for example "Wissel gedaan: blok 3, #11 Hanne en #13
  Elise erin." or "#4 Lotte uit, #12 Sara erin." (⚠ copy to confirm), and give buttons an `:active` style.

### P2-3 · Live, last block: "Einde match" in big type before the match has ended

- **Element:** `p.sub-time` (from `subTimeText`) and `button.wissel` on the last block.
- **Seen:** on block 12 of 12 the big line under the heading reads "Einde match", the same words as the heading of
  the end screen, and the big button reads "Einde match" too
  ([light](2026-ui-review/18-live-laatste-blok-light.png), [dark](2026-ui-review/18-live-laatste-blok-dark.png),
  [end screen](2026-ui-review/19-einde-light.png)).
- **Why it matters:** at a glance the screen says the match is over while the last block is still being played. The
  button that really ends it sits where Wissel always was, in the same colour. ⚠ The risk (not observed with
  coaches) is a coach who taps from habit ending the match one block early. Ongedaan maken on the end screen saves it, but only if the coach sees the mistake.
- **Fix (S):** on the last block, show "Laatste blok" in `.sub-time` (⚠ copy to confirm) and keep "Einde match" on
  the button only.

### P2-4 · Live: "In the zone" and "Extra minuten" sit side by side, same size, on every row

- **Element:** `button.chip` and `button.chip.extra` in "Eruit".
- **Seen:** each player due off gets both buttons, 44 px tall, 8 px apart; rows are 45 px apart, so the four chips
  form a tight 2 × 2 block ([screenshot](2026-ui-review/10-live-blok1-light.png)). Once tapped, the two differ only
  in their border colour (accent or green) on the same pale yellow fill. In light mode that fill is 1.11:1 against
  white ([zone](2026-ui-review/12-live-zone-light.png), [extra](2026-ui-review/13-live-extra-light.png)).
- **Why it matters:** Extra minuten is chosen "on purpose, rarely" (glossary) and does not give the block back. As it
  stands it is exactly as easy to hit as In the zone, and the two are hard to tell apart once chosen. The note under
  the lists does tell them apart, but only for a coach who reads it.
- **Fix (M):** show only "In the zone" on each row. Once a player is chosen, offer "Extra minuten (niet teruggeven)"
  as a single toggle inside `.zone-note` (⚠ copy to confirm). This also gives the names in P1-1 room.

### P3-1 · Live: who is on court shows only as a thin green border in the overview

- **Element:** `.overview li.on`.
- **Seen:** players on court get a 2 px green border and bold text. In light mode that green is 2.90:1 against the
  grey border of the other cells ([screenshot](2026-ui-review/10-live-blok1-light.png)).
- **Why it matters:** at 2.90:1 the border is below the 3:1 WCAG asks for non-text contrast. ⚠ In a bright hall, or
  with the phone at an angle, the cells may look alike (not tried on a device), and the coach would fall back on the
  "Op het veld" list below, which takes 5 more rows of the screen.
- **Fix (S):** give on-court cells a filled background (a tint of `--on`), not only a border.

### P3-2 · Live: "Minuten tot nu" counts the block being played as already played

- **Element:** `.overview` (`aria-label` "Minuten tot nu per speler") and the "Minuten tot nu" table.
- **Seen:** at the tip-off of block 1, the five starters already show 3:20; on the last block, everyone shows their
  final total ([block 1](2026-ui-review/10-live-blok1-light.png),
  [last block](2026-ui-review/18-live-laatste-blok-light.png)).
- **Why it matters:** "tot nu" (so far) says something else than the numbers. ⚠ Counting in whole blocks matches
  decisions #11 and #16, so the numbers may be right and only the label off. That is a product call.
- **Fix (S):** rename it "Minuten na dit blok" (⚠ copy to confirm), or count only finished blocks.

### P3-3 · Live: the minutes table's last column has no header, and the "uit" tag is struck through

- **Element:** `.minutes thead` (two cells, while body rows have three) and `.minutes tr.out th .tag`.
- **Seen:** the header line and the white table surface stop before the Uit/Terug column. On a player marked uit, the
  red "uit" tag gets the same line-through as the name
  ([light](2026-ui-review/17-live-tabel-uit-light.png), [dark](2026-ui-review/17-live-tabel-uit-dark.png)).
- **Why it matters:** this looks unfinished, and the struck-through tag is harder to read than it needs to be. Screen
  readers get a column with no header.
- **Fix (S):** add a third `<th>` (visually hidden "Actie"), and leave `.tag` out of the line-through.

### P3-4 · Match setup: long page, basisvijf picked again every match, Start at the very bottom

- **Element:** the Match screen, from `.install-hint` down to the "Start" button.
- **Seen:** with 11 players the page is about 2,000 CSS px tall: the hint, 11 attendance rows, Schema, Vorige
  matchen, Tegenstander, then an 11-row plan, then "Start"
  ([full page](2026-ui-review/08-match-volledig-light.png), [top](2026-ui-review/04-match-boven-light.png)). After
  "Nieuwe match", the five "Basis" buttons are all off again
  ([screenshot](2026-ui-review/21-match-geschiedenis-light.png)), while attendance is remembered.
- **Why it matters:** decision #19 promises setup in under a minute. Five taps to pick the basisvijf again, then a
  long scroll down to Start, eat into that, minutes before tip-off.
- **Fix (S):** pre-select the last match's basisvijf among the players present, like attendance (⚠ product question:
  the owner may want it picked fresh every time).

### P3-5 · Match setup: the install tip takes the top of the screen on every visit

- **Element:** `p.install-hint`.
- **Seen:** four lines of muted text above "Aanwezig en basisvijf", every time, in a browser tab
  ([light](2026-ui-review/04-match-boven-light.png), [dark](2026-ui-review/04-match-boven-dark.png)).
- **Why it matters:** once the coach has read it, it only pushes the work down.
- **Fix (S):** add a "Begrepen" button that hides it, remembered in `localStorage` (per-viewer convenience).

### P3-6 · Match setup: swap selection gives no prompt for the second tap

- **Element:** `.plan tr.selected` and the `.message` above the grid.
- **Seen:** after the first tap, the row turns pale yellow and nothing else changes
  ([light](2026-ui-review/06a-match-ruil-gekozen-light.png), [dark](2026-ui-review/06a-match-ruil-gekozen-dark.png)).
  The yellow is 1.11:1 against white in light mode. After a refused swap, the message repeats the instruction above
  it almost word for word ([screenshot](2026-ui-review/07-match-ruil-fout-light.png)).
- **Why it matters:** the coach cannot tell whether the first tap took, and after a refused swap the screen does not
  say which player is wrong.
- **Fix (S):** after the first tap, write "#4 Lotte gekozen. Tik de speler aan om mee te ruilen." in `.message`, and
  name both players in the refusal (⚠ copy to confirm).

### P3-7 · Match setup: "Wis geschiedenis" sits against the Tegenstander label

- **Element:** the `.form-actions` holding "Wis geschiedenis", followed by the Tegenstander `section`.
- **Seen:** there is no space between the destructive button and the next field's label
  ([screenshot](2026-ui-review/21-match-geschiedenis-light.png),
  [dark](2026-ui-review/21-match-geschiedenis-dark.png),
  [switch on](2026-ui-review/22-match-geschiedenis-aan-light.png)).
- **Why it matters:** a tap meant for the opponent field can land on Wis geschiedenis. The confirm dialog catches it,
  but the layout reads as if the button belonged to the field below.
- **Fix (S):** give the setup sections a top margin (or `margin-bottom` on that `.form-actions`).

### P3-8 · Spelers: the season total has no visible label

- **Element:** `.season-total` in `.roster li`.
- **Seen:** "36:40" sits between the name and "Wijzig", in the same muted style as the jersey numbers. Only a
  visually hidden "speeltijd " says what it is ([light](2026-ui-review/23-spelers-seizoen-light.png),
  [dark](2026-ui-review/23-spelers-seizoen-dark.png)). Long names are cut to "Anne-Marie-…" to make room.
- **Why it matters:** the note above ("Speeltijd dit seizoen, over 2 bewaarde matchen.") explains it once, but a
  number with no label in a list of numbers is easy to misread, for example as a jersey number or a time of day.
- **Fix (S):** put the total in the text colour with a small header row ("Speler · Speeltijd"), or suffix it with
  "min" (⚠ copy to confirm).

### P3-9 · Spelers: the first-name field allows autocorrect

- **Element:** `input[name="name"]` (`autocapitalize="words"`, no `autocorrect` or `spellcheck`).
- **Seen:** in code (`public/js/setup.js`, the Voornaam input). The field is the one in
  [Spelers, empty](2026-ui-review/01-spelers-leeg-light.png) (context: a screenshot cannot show autocorrect).
  ⚠ iOS may "correct" names such as Fien or Lien to dictionary words; not tried on a device.
- **Why it matters:** a corrected name has to be fixed by hand through Wijzig.
- **Fix (S):** add `autocorrect="off"` and `spellcheck="false"` to the first-name input.

### P3-10 · Small copy and markup points

- **Element and seen, per point:**
  - `button.chip` and `.zone-note` on the live screen ([zone](2026-ui-review/12-live-zone-light.png)): "In the zone"
    is English inside `lang="nl"`, so ⚠ VoiceOver may read it with Dutch sounds (not tested with VoiceOver). Mark it
    `lang="en"`.
  - `.message` on the Match screen, text 'Er kon geen plan gemaakt worden. Probeer "Ander plan".' (`setup.js`):
    straight quotes, where Dutch uses „Ander plan”. Code only: it shows only when no plan can be made, which the walk
    did not reach; the place is the message line above the plan in [plan](2026-ui-review/05-match-plan-light.png).
  - `.message` on the live screen, text "Dat kan nu niet." (`act` in `live.js`, on a refused action): no next step.
    Code only: the walk did not trigger a refused action; the place is the line above the buttons in
    [block 1](2026-ui-review/10-live-blok1-light.png).
  - `<meta name="theme-color">` in `public/index.html`: the light accent `#1f5f8b` in dark mode as well, so ⚠ the
    status bar may show a blue band over the dark page ([dark page](2026-ui-review/10-live-blok1-dark.png); headless
    Chrome draws no status bar, so not seen).
- **Why it matters:** each is small, but together they make the app read less finished, and a refusal with no next
  step leaves the coach guessing.
- **Fix (S):** one ticket for the four: `lang="en"` on the term, curly quotes, a next step in the refusal (⚠ copy to
  confirm), and a second `theme-color` meta with `media="(prefers-color-scheme: dark)"`.

## Where each check came from

**Walking the flows in the browser** (screenshots, measured boxes, scripted taps): P1-1 (name width measured 0 px),
P1-2 (tab tap, start at `/`, no in-app way back; browser Back or `#start` resumes), P2-1 (two taps 120 ms apart → block 3), P2-2, P2-3, P2-4
(chip boxes and gaps), P3-1, P3-2, P3-3, P3-4, P3-5, P3-6, P3-7, P3-8. Contrast numbers come from the WCAG formula
applied to the tokens in `styles.css`, with opacity 0.4 blended in for disabled buttons.

**Web Interface Guidelines** (the `web-design-guidelines` skill, which fetched the current rules from
vercel-labs/web-interface-guidelines `command.md`, applied to `public/index.html`, `public/styles.css` and
`public/js/*.js`):

- led to findings: `touch-action: manipulation` missing (P2-1); no pressed or hover state (P2-2); destructive action
  without confirmation (Start replacing a running match, P1-2); text containers and flex children with long content
  (P1-1); table header cells (P3-3); `spellcheck`/autocorrect on a name field (P3-9); curly quotes, `theme-color`
  matching the dark background, `lang`/`translate` for foreign terms, and error messages with a next step (P3-10).
- checked and fine: zoom not blocked in the viewport meta; `:focus-visible` outlines on buttons, links and inputs;
  every input has a wrapping `<label>`, and checkbox and radio labels are the whole hit target (the 22 px boxes sit in
  44 px labels); `<button>` for actions and `<a>` for navigation; `role="alert"`/`role="status"` on message lines;
  `tabular-nums` on number columns; `env(safe-area-inset-*)` on the tabs and the action bar; `color-scheme` and a
  dark palette; confirms on Verwijder and Wis geschiedenis, undo on the live actions; every tap target at least
  44 × 44 px (measured on all four screens).
- not applicable: images, animation and reduced motion, fonts, hydration, `Intl` dates and numbers (no dates shown),
  virtualised lists (at most 15 rows), Title Case (Dutch copy).

**Dark mode.** The dark palette changed no finding except the `theme-color` point in P3-10. Its disabled buttons are
dimmer (2.6:1 for the disabled Wis geschiedenis), which is acceptable for a disabled control. Dark screenshots are
kept only for the screens where the palette matters for a finding.

**Glossary.** On-screen terms match `docs/GLOSSARY.md`: basisvijf, blok, schema, wissel, uit and terug, in the zone,
extra minuten. No "Avoid" word shows on screen.

## What could not be checked in a browser

- **Wake Lock:** headless Chrome has no screen to keep on; whether iOS keeps the screen awake during a match is a
  device check.
- **Offline:** the service worker was not exercised offline.
- **The installed home-screen app:** standalone mode, the install hint's absence when installed, the status-bar
  colour, and ⚠ whether iOS reopens a dropped home-screen app at `start_url` or at the last URL (this decides how bad
  P1-2 is in practice).
- **Real iPhone Safari rendering:** fonts (Chrome used the macOS system font, as Safari would, but sizes may differ),
  ⚠ double-tap handling (P2-1), ⚠ autocorrect on names (P3-9), and ⚠ readability in a bright hall of the contrast points
  (P2-4, P3-1, P3-6).
- **15 players:** the run used 11. With 15 the overview takes three rows and the setup page grows by about 400 px.
  Not walked.
