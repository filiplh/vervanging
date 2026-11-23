# Shared examples

The match rules exist twice while the web app lives: in `public/js` and in the Swift package in `ios/` (ADR-003).
These examples referee the two (plan decision #35). Each file is one run of the command-line runner
`scripts/sim.mjs` with its exact output. The JS test suite checks that the JS rules still give that output, and the
Swift suite runs the same arguments through its own runner and must give the same output, byte for byte.

**Never edit these files by hand.** They are written by `scripts/export-examples.mjs` from the list of argument sets in
that script. To add or change an example, change the list and regenerate.

## Regenerate and check

From the repo root:

```sh
node scripts/export-examples.mjs           # writes every example, removes files that are no longer in the list
node scripts/export-examples.mjs --check   # compares the files with what the JS rules give now
```

`--check` exits 0 with the last line `<n> examples match`, or exits 1 and names each example that is out of date,
missing or not in the list. `node --test` runs it (`scripts/export-examples.test.js`), so verify fails when an example
goes stale. Re-running the export on an unchanged tree changes no file. During phase 3 the JS rules change only for
bug fixes (plan decision #36); such a fix regenerates the examples in the same PR.

## One file

`<name>.json`, one JSON object, written with two-space indentation and a final newline:

| Field | Type | Meaning |
| --- | --- | --- |
| `name` | string | The file name without `.json`. Names of invalid-input examples start with `invalid-`. |
| `kind` | string | `plan`, `match` or `history`: the sim command, the first argument. |
| `actions` | string[] | The match actions `--actions` uses, sorted, each once: `wissel`, `undo`, `keep` (in the zone, `wissel:keep=P`), `extra` (Extra minuten), `bench` (`:bench=Q`), `uit`, `terug`. Empty when there is no `--actions`. An invalid example can list the unknown word it tests. |
| `args` | string[] | The arguments after `scripts/sim.mjs`, exactly as passed. |
| `exitStatus` | number | 0 for a result, 2 for invalid input. |
| `stdout` | string | The exact stdout: one JSON object and a newline, or empty for invalid input. |
| `stderr` | string | The exact stderr: empty, or one line starting with `sim: ` for invalid input. |

File paths in `args` (the team history fixtures in `scripts/fixtures/`) are relative to the repo root, so a runner
runs every example from the repo root. The meaning of each argument and of the output is in the comment at the top of
`scripts/sim.mjs`.

A runner can pick a subset by `kind` (for example only `match`), or leave out examples whose `actions` contain an
action it does not support yet (for example `uit` and `terug`).
