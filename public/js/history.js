// Team history (docs/PLAN.md decision #10): each finished match's seconds per player, kept on the phone (ADR-002)
// under the store thing "history". With the setup switch on, the places that cannot be split equally go to the
// players with the fewest total seconds so far (ties: random from the plan's seed); with it off, random as before.
// With the switch on, players behind on season minutes also catch up gradually (decision #28): at most one block
// more per match than the equal share, from the present players furthest ahead (at most one block less each). Minutes
// earned through Extra minuten are kept apart per match and left out of these comparisons, so a reward stays
// (decision #28, phase 2 log D8). The season totals on the Spelers screen still count all minutes.
//
// Stored shape (version 1):
//   { useHistory: boolean, clearedAt: string | null,
//     matches: [{ id: string, seconds: { "<player id>": number }, extra?: { "<player id>": number } }] }
// `extra` holds the seconds a player got through Extra minuten in that match (part of `seconds`); matches saved
// before it existed have none.
// `id` is the match setup's savedAt (one per "Start"). A match is in the history exactly while its live state is
// ended: ending records it (replacing an entry with the same id, so it is never counted twice), and undoing the end
// removes it again. `clearedAt` is when "Wis geschiedenis" last emptied it: an ended match whose setup is not newer
// is not recorded again when its end screen is reopened (live.js, repairHistory). Player ids are the roster's stable
// ids.

import { seededRandom } from './planner.js';

export function emptyHistory() {
  return { useHistory: false, clearedAt: null, matches: [] };
}

// The history read from the store, cleaned so a damaged value never breaks a screen or the planner: entries without
// a string id or a seconds object are dropped, and so are seconds that are not finite numbers of 0 or more, or keyed
// by something other than a whole player id. A later entry with the same id wins.
export function normaliseHistory(raw) {
  const history = emptyHistory();
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return history;
  history.useHistory = raw.useHistory === true;
  history.clearedAt = typeof raw.clearedAt === 'string' && !Number.isNaN(Date.parse(raw.clearedAt)) ? raw.clearedAt : null;
  const byId = new Map();
  for (const match of Array.isArray(raw.matches) ? raw.matches : []) {
    if (!match || typeof match.id !== 'string' || !match.id) continue;
    const { seconds } = match;
    if (!seconds || typeof seconds !== 'object' || Array.isArray(seconds)) continue;
    const clean = cleanSeconds(seconds);
    const extra = cleanExtra(match.extra, clean);
    byId.delete(match.id);
    byId.set(match.id, Object.keys(extra).length ? { id: match.id, seconds: clean, extra } : { id: match.id, seconds: clean });
  }
  history.matches = [...byId.values()];
  return history;
}

function cleanSeconds(seconds) {
  const clean = {};
  if (!seconds || typeof seconds !== 'object' || Array.isArray(seconds)) return clean;
  for (const [id, value] of Object.entries(seconds)) {
    if (!/^\d+$/.test(id) || typeof value !== 'number' || !Number.isFinite(value) || value < 0) continue;
    clean[id] = value;
  }
  return clean;
}

// Extra seconds are kept only for players with seconds in that match, at most their seconds, and above 0.
function cleanExtra(extra, seconds) {
  const clean = {};
  for (const [id, value] of Object.entries(cleanSeconds(extra))) {
    if (value > 0 && id in seconds) clean[id] = Math.min(value, seconds[id]);
  }
  return clean;
}

// The history with this match's seconds recorded under `id`, replacing an earlier entry for the same match. `extra`
// (optional) holds the seconds each player got through Extra minuten.
export function recordMatch(history, id, seconds, extra = {}) {
  const clean = cleanSeconds(seconds);
  const extraClean = cleanExtra(extra, clean);
  const entry = Object.keys(extraClean).length ? { id, seconds: clean, extra: extraClean } : { id, seconds: clean };
  return { ...history, matches: [...history.matches.filter((m) => m.id !== id), entry] };
}

export function forgetMatch(history, id) {
  return { ...history, matches: history.matches.filter((m) => m.id !== id) };
}

export function hasMatch(history, id) {
  return history.matches.some((m) => m.id === id);
}

// "Wis geschiedenis": no matches left, and `now` (an ISO time) remembered as the moment of clearing; the switch keeps
// its setting.
export function clearHistory(history, now) {
  return { ...history, clearedAt: now, matches: [] };
}

// True when a match started at `savedAt` (its setup's ISO time) began after the last "Wis geschiedenis", so its
// minutes may (still) be recorded when its end screen is reopened.
export function startedAfterClear(history, savedAt) {
  if (history.clearedAt == null) return true;
  const started = Date.parse(savedAt);
  return !Number.isNaN(started) && started > Date.parse(history.clearedAt);
}

// Total seconds per player id over all matches in the history.
export function totalSeconds(history) {
  const totals = {};
  for (const match of history.matches) {
    for (const [id, value] of Object.entries(match.seconds)) totals[id] = (totals[id] ?? 0) + value;
  }
  return totals;
}

// The season totals (decision #26), as the Spelers screen and the runner show them: the number of saved matches and
// the total seconds per player id over all of them. A player in no saved match is not in `totals` (counts as 0).
export function seasonSummary(history) {
  return { matches: history.matches.length, totals: totalSeconds(history) };
}

// Total seconds per player id over all matches, without the seconds earned through Extra minuten: what catch-up and
// the uneven places compare (decision #28, rewards stay).
export function catchUpSeconds(history) {
  const totals = totalSeconds(history);
  for (const match of history.matches) {
    for (const [id, value] of Object.entries(match.extra ?? {})) totals[id] -= value;
  }
  return totals;
}

// The present players ordered for the uneven extra places (the planner's `extraPriority`): fewest seconds first
// (Extra minuten not counted); a player not in the history counts as 0; players in the history who are not present
// are ignored. Ties are put in a random order from `seed`, so the same seed and history give the same plan.
export function extraPriority(history, players, seed = 1) {
  const totals = catchUpSeconds(history);
  const random = seededRandom(seed);
  const order = players.slice();
  for (let i = order.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [order[i], order[j]] = [order[j], order[i]];
  }
  const total = (p) => totals[String(p)] ?? 0;
  return order.sort((a, b) => total(a) - total(b)); // Array.prototype.sort is stable: ties keep the shuffled order
}

// Gradual catch-up (decision #28): the targets the planner needs for a match with the history switch on. `priority`
// orders the uneven places (as extraPriority); `adjust` moves one block from a present player far ahead to a present
// player far behind, pairing the furthest behind with the furthest ahead, while they are at least one block apart.
// Each player gets at most one block more than the equal share (a player who already has an uneven place gets none)
// and at most one block less. Seconds earned through Extra minuten are not counted, so a reward is not taken back.
export function catchUp(history, players, { blocks, blockSeconds, onCourt = 5 }, seed = 1) {
  const priority = extraPriority(history, players, seed);
  const totals = catchUpSeconds(history);
  const total = (p) => totals[String(p)] ?? 0;
  const places = onCourt * blocks;
  const base = Math.floor(places / players.length);
  const uneven = new Set(priority.slice(0, places - base * players.length));
  const share = (p) => base + (uneven.has(p) ? 1 : 0);
  const adjust = {};
  let i = 0;
  let j = priority.length - 1;
  while (i < j) {
    const behind = priority[i];
    const ahead = priority[j];
    if (total(ahead) - total(behind) < blockSeconds) break;
    if (share(behind) + 1 > base + 1) { i += 1; continue; }
    if (share(ahead) - 1 < base - 1) { j -= 1; continue; }
    adjust[behind] = 1;
    adjust[ahead] = -1;
    i += 1;
    j -= 1;
  }
  return { priority, adjust };
}
