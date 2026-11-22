// Team history (docs/PLAN.md decision #10): each finished match's seconds per player, kept on the phone (ADR-002)
// under the store thing "history". With the setup switch on, the places that cannot be split equally go to the
// players with the fewest total seconds so far (ties: random from the plan's seed); with it off, random as before.
// History changes nothing else.
//
// Stored shape (version 1):
//   { useHistory: boolean, matches: [{ id: string, seconds: { "<player id>": number } }] }
// `id` is the match setup's savedAt (one per "Start"). A match is in the history exactly while its live state is
// ended: ending records it (replacing an entry with the same id, so it is never counted twice), and undoing the end
// removes it again. Player ids are the roster's stable ids.

import { seededRandom } from './planner.js';

export function emptyHistory() {
  return { useHistory: false, matches: [] };
}

// The history read from the store, cleaned so a damaged value never breaks a screen or the planner: entries without
// a string id or a seconds object are dropped, and so are seconds that are not finite numbers of 0 or more, or keyed
// by something other than a whole player id. A later entry with the same id wins.
export function normaliseHistory(raw) {
  const history = emptyHistory();
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return history;
  history.useHistory = raw.useHistory === true;
  const byId = new Map();
  for (const match of Array.isArray(raw.matches) ? raw.matches : []) {
    if (!match || typeof match.id !== 'string' || !match.id) continue;
    const { seconds } = match;
    if (!seconds || typeof seconds !== 'object' || Array.isArray(seconds)) continue;
    const clean = {};
    for (const [id, value] of Object.entries(seconds)) {
      if (!/^\d+$/.test(id) || typeof value !== 'number' || !Number.isFinite(value) || value < 0) continue;
      clean[id] = value;
    }
    byId.delete(match.id);
    byId.set(match.id, { id: match.id, seconds: clean });
  }
  history.matches = [...byId.values()];
  return history;
}

// The history with this match's seconds recorded under `id`, replacing an earlier entry for the same match.
export function recordMatch(history, id, seconds) {
  const clean = {};
  for (const [player, value] of Object.entries(seconds)) {
    if (/^\d+$/.test(player) && Number.isFinite(value) && value >= 0) clean[player] = value;
  }
  return { ...history, matches: [...history.matches.filter((m) => m.id !== id), { id, seconds: clean }] };
}

export function forgetMatch(history, id) {
  return { ...history, matches: history.matches.filter((m) => m.id !== id) };
}

export function hasMatch(history, id) {
  return history.matches.some((m) => m.id === id);
}

// "Wis geschiedenis": no matches left; the switch keeps its setting.
export function clearHistory(history) {
  return { ...history, matches: [] };
}

// Total seconds per player id over all matches in the history.
export function totalSeconds(history) {
  const totals = {};
  for (const match of history.matches) {
    for (const [id, value] of Object.entries(match.seconds)) totals[id] = (totals[id] ?? 0) + value;
  }
  return totals;
}

// The present players ordered for the uneven extra places (the planner's `extraPriority`): fewest total seconds first;
// a player not in the history counts as 0; players in the history who are not present are ignored. Ties are put in
// a random order from `seed`, so the same seed and history give the same plan.
export function extraPriority(history, players, seed = 1) {
  const totals = totalSeconds(history);
  const random = seededRandom(seed);
  const order = players.slice();
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  const total = (p) => totals[String(p)] ?? 0;
  return order.sort((a, b) => total(a) - total(b)); // Array.prototype.sort is stable: ties keep the shuffled order
}
