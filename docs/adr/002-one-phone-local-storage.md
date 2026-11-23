# ADR-002 One phone, data only on the device

- **Status:** accepted ([grill D5, D18](../grill/2026-11-22-whole-product.md#decisions), by the owner)
- **Date:** 2026-11-22 (decided) · 2026-11-22 (written)

## Context
One coach operates the app on one phone; nobody else needs the data, and the build budget is about four hours. Any
login or sync would add a backend. A match must survive the phone locking or the page reloading, and sports halls
often have poor reception.

## Decision
- Roster, the running match and the team history live in the browser's storage on the coach's phone.
- The match state is written after every tap and restored exactly on reload or restart.
- No backend, no login, no sync, no sharing. The Worker only serves static files.

## Consequences
- No server code, no accounts, no personal data leaves the phone.
- Data is lost if the phone is lost or the browser clears site data; iOS Safari may clear it after about 7 days without
  a visit unless the app is on the home screen (⚠ unconfirmed: from memory of WebKit's storage policy, check before
  phase 1), so phase 1 adds the home-screen install and a hint.
- A second device (an assistant) or a season export would need a new ADR.

## Native app (phase 3)
The decision carries over to the native iPhone app unchanged
([phase 3 D10](../grill/2026-11-23-phase-3-native-ios.md#decisions), 2026-11-23): roster, the running match and the
team history are small JSON files in the app's own storage, written after every tap and restored on launch. No
SwiftData, no iCloud sync, no login. A normal iPhone backup includes the files. Nothing moves from the web app: the
native app starts with an empty history and the roster is entered again by hand
([phase 3 D5](../grill/2026-11-23-phase-3-native-ios.md#decisions)).

## Alternatives considered
- Sync through a small backend (Workers KV or D1): shared data, but accounts, secrets and far more than four hours.

## References
[grill D5](../grill/2026-11-22-whole-product.md#decisions) · [grill D18](../grill/2026-11-22-whole-product.md#decisions) · plan decisions #5, #10, #14, #18 · [phase 3 D5, D10](../grill/2026-11-23-phase-3-native-ios.md#decisions) · plan decisions #33, #38
