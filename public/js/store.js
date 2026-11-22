// Store: a small wrapper over localStorage. Data stays on the phone (ADR-002).
// One key per thing, each with its own version in the key ("vervanging.roster.v1"), so a later shape gets a new key
// and a migration can still read the old one.

const PREFIX = 'vervanging';

export const THINGS = {
  roster: 1, // { nextId, players: [{ id, name, number }] }
  attendance: 1, // [id, ...] of the players present at the last started match
  matchSetup: 1, // the match setup saved by "Start", read by the live screen
  match: 1, // the live match state (match.js), saved after every tap
  history: 1, // { useHistory, matches: [{ id, seconds }] }: finished matches' seconds per player (history.js)
};

export function keyOf(thing, version = THINGS[thing]) {
  if (!version) throw new Error(`unknown store thing "${thing}"`);
  return `${PREFIX}.${thing}.v${version}`;
}

function defaultStorage() {
  try {
    return globalThis.localStorage ?? null;
  } catch {
    return null; // storage blocked by the browser
  }
}

export function createStore(storage = defaultStorage()) {
  return {
    // The stored value, or `fallback` when there is none, it cannot be read or it is not valid JSON.
    load(thing, fallback = null) {
      try {
        const raw = storage?.getItem(keyOf(thing));
        return raw == null ? fallback : JSON.parse(raw);
      } catch {
        return fallback;
      }
    },
    // True when the value was written; false when the browser refused (full or blocked storage).
    save(thing, value) {
      try {
        storage.setItem(keyOf(thing), JSON.stringify(value));
        return true;
      } catch {
        return false;
      }
    },
    remove(thing) {
      try {
        storage?.removeItem(keyOf(thing));
      } catch {
        // nothing to do: the value is gone or was never readable
      }
    },
  };
}
