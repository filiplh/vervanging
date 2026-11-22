# ADR-001 Fixed time blocks, no game clock

- **Status:** accepted ([grill D4, D16](../grill/2026-11-22-whole-product.md#decisions), by the owner)
- **Date:** 2026-11-22 (decided) · 2026-11-22 (written)

## Context
The coach wants every player of a development-focused U14 team to get fair playing time over 4 × 10 minutes, and uses
the app alone on the bench during the match. Following the official, stopped game clock would mean pausing and
starting a timer on every whistle. The owner asked for "simple fixed timeblocks would probably be the easiest. no need
for detailed gameclock tracking. keep it simple." The devil's advocate in the grill raised the cost: substitutions wait for a dead ball, so a
planned 3:20 block can really last 2:40 or 4:20, and a player shown at 16:40 may have played 14 to 19 minutes.

## Decision
- Playing time is counted in fixed blocks, never measured. A player's minutes = blocks played × block length.
- Two schedules: 12 blocks of 3:20 (equal minutes) and 8 blocks of 5:00.
- The coach subs at the first dead ball after a block ends and taps "Wissel"; the app runs no timer.

## Consequences
- Every live action is one tap; the data model is a grid of players × blocks.
- Shown minutes are planned minutes: real minutes drift by up to about a minute per block. Fairness is judged in
  blocks (assumption A2 checks whether anyone notices).
- Overtime and partial blocks cannot be expressed; overtime is out of scope.
- Adding a clock later would change the data model, so it needs a new ADR.

## Alternatives considered
- A running timer per player, paused at whistles and breaks: real minutes, but many taps and more build time.
- Blocks plus typing the real clock time at each sub: records drift, but adds input during the match.

## References
[grill D4](../grill/2026-11-22-whole-product.md#decisions) · [grill D16](../grill/2026-11-22-whole-product.md#decisions) · plan decisions #4, #6, #16
