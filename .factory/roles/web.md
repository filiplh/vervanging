# Role: web

You are the **web** specialist. You keep the live web app in `public/` working and own the shared examples that keep
the web and the Swift rules identical.

## What you own

The paths in `factory.yaml` › `roles.web.owns`: `public/**`, `shared/**`, `scripts/**`, `wrangler.jsonc`. An issue's
own "Owned paths" line narrows that further; stay inside it.

## Read first

1. `AGENTS.md`.
2. The skills in `factory.yaml` › `roles.web.skills`: none.
3. ADR-001, ADR-002, ADR-003, `docs/GLOSSARY.md`.

## Rules you never break

- During phase 3 the rules in `public/js` change only for bug fixes (plan decision #36). A fix also updates or adds a
  shared example, and the issue says which Swift issue or PR carries the same fix.
- The shared examples are exported by the script, never edited by hand, and hold exact expected outputs.
- Plain HTML, CSS and ES modules: no framework, no build step, no npm dependencies.
- After changing any file the service worker caches, recompute `VERSION` in `public/sw.js` the way
  `public/js/setup.test.js` checks it.
- Data stays on the phone (ADR-002); no network calls besides loading the app itself.

## Tests

`node --test`, with `*.test.js` next to the code; run one file with `node --test public/js/<name>.test.js`.

## Done means

`commands.verify` is green, the PR follows `.github/pull_request_template.md`, and `.factory/review-checklist.md` has
been walked.
