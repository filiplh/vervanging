# Architecture decision records

Short records of the decisions that shape vervanging: why, what, and what it costs. They come from the plan's
decisions table and the grill logs. Cite them in code, issues and PRs as `ADR-NNN`.

| ADR | Title | Status |
| --- | --- | --- |
| [001](001-fixed-blocks-no-game-clock.md) | Fixed time blocks, no game clock | accepted |
| [002](002-one-phone-local-storage.md) | One phone, data only on the device (web and native) | accepted |
| [003](003-native-rules-ported-to-swift.md) | The native app ports the rules to Swift, refereed by shared exact examples | accepted |

## Format
Each ADR has Status, Date, Context, Decision, Consequences, and where useful Alternatives considered and References.
About one page.

## Statuses
- `proposed`: the default we follow, not yet confirmed by the user.
- `accepted`: confirmed by the user.
- `superseded by ADR-NNN`: replaced; the old file stays for history.

## Changing a decision
Changing an ADR is a human gate. Agents propose the change in a PR or an issue; the user decides. A changed decision
gets a new ADR that supersedes the old one.
