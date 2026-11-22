// Match engine: which block is being played, and the live actions on it. Pure functions, no DOM or storage: a state
// goes in, a new state comes out, and every state is plain JSON, so the live screen saves it after every tap and
// scripts/sim.mjs drives the same code. Decisions: docs/PLAN.md #4 (blocks, minutes = blocks × length), #8 and #9
// (in the zone), #11 (uit and terug), #12 (live screen), #17 (undo, one step), #18 (saved after every tap).
//
// The state carries the plan as set up (`base`) and its own live plan (`grid`), which in the zone, uit and terug change from the next block on, and
// the players who are out. `previous` is the whole state before the last action (block, ended, grid, out), so undo
// puts back exactly one step, whatever the action was.

import {
  replanRemaining, repairRemaining, evenTargets, blockCounts, maxSubsFrom, MAX_SUBS, ON_COURT, PlanError,
} from './planner.js';

export const MATCH_VERSION = 2;

export class MatchError extends Error {}

const sorted = (list) => list.slice().sort((a, b) => a - b);
const copyGrid = (grid) => grid.map((court) => court.slice());
const snapshot = (state) => ({ block: state.block, ended: state.ended, grid: copyGrid(state.grid), out: state.out.slice() });

// A new match from a plan (planner.js › makePlan, after swaps): block 1 is being played, nothing to undo.
// `setupSavedAt` ties the state to the saved match setup, so a state from an older setup is never restored.
export function startMatch(plan, setupSavedAt = null) {
  const { schedule, blocks, blockSeconds, blocksPerQuarter, players, grid } = plan;
  return {
    version: MATCH_VERSION,
    setupSavedAt,
    schedule,
    blocks,
    blockSeconds,
    blocksPerQuarter,
    players: players.slice(),
    base: copyGrid(grid), // the plan as set up; ties a saved state to its plan
    grid: copyGrid(grid),
    out: [],
    block: 1,
    ended: false,
    previous: null,
  };
}

const available = (state) => state.players.filter((p) => !state.out.includes(p));

// The incoming player the app proposes to keep on the bench when `keep` stays on: the one with the most minutes so
// far, ties to the lowest number (decision #9).
export function proposedBench(state) {
  const change = nextChange(state);
  if (!change || change.on.length === 0) return null;
  const minutes = minutesSoFar(state);
  return change.on.slice().sort((a, b) => minutes[b] - minutes[a] || a - b)[0];
}

// In the zone at the coming change: `keep` (due off) stays on for the next block, `bench` (due on; the proposal by
// default) stays off. The benched player gets back the zone player's next planned block where the benched player is
// not on yet. When that would break the sub cap, the blocks after the next one are replanned to the original totals;
// with no later block, the difference stays.
function keepOn(state, keep, bench) {
  const change = nextChange(state);
  if (!change) throw new MatchError('no change left: this is the last block');
  if (!change.off.includes(keep)) throw new MatchError(`player ${keep} is not due off at this change`);
  const q = bench ?? proposedBench(state);
  if (!change.on.includes(q)) throw new MatchError(`player ${q} is not due on at this change`);
  const next = state.block; // 0-based index of the next block
  const totals = blockCounts(state.grid, state.players);
  const kept = copyGrid(state.grid);
  kept[next] = sorted(kept[next].filter((p) => p !== q).concat(keep));
  const fixed = next + 1; // blocks 1..next+1 are now fixed
  if (fixed >= state.blocks) return kept; // the last change: the difference stays

  for (let k = fixed; k < state.blocks; k++) {
    if (!kept[k].includes(keep) || kept[k].includes(q)) continue;
    const swapped = copyGrid(kept);
    swapped[k] = sorted(swapped[k].filter((p) => p !== keep).concat(q));
    if (maxSubsFrom(swapped, next) <= MAX_SUBS) return swapped;
  }
  const replan = (targets) => {
    try {
      return replanRemaining({
        grid: kept, players: state.players, available: available(state), fromBlock: fixed, targets,
        blockSeconds: state.blockSeconds, seed: state.block,
      });
    } catch (error) {
      if (error instanceof PlanError) return null;
      throw error;
    }
  };
  // Original totals (zone player one block back, benched player one block more); else keep the difference; else the
  // last-resort repair, which holds the sub cap whatever the totals.
  return replan(totals) ?? replan(blockCounts(kept, state.players))
    ?? repairRemaining({ grid: kept, players: state.players, available: available(state), fromBlock: fixed });
}

// "wissel": on to the next block; at the last block it ends the match. After the end it changes nothing.
// `keep` (and optionally `bench`) apply in the zone at this change.
export function wissel(state, { keep = null, bench = null } = {}) {
  if (state.ended) return state;
  const previous = snapshot(state);
  if (state.block >= state.blocks) {
    if (keep != null) throw new MatchError('no change left: this is the last block');
    return { ...state, ended: true, previous };
  }
  const grid = keep == null ? state.grid : keepOn(state, keep, bench);
  return { ...state, grid, block: state.block + 1, previous };
}

// Re-spreads the blocks after the current one over the players who are not out (uit and terug, decision #11).
function respread(state, out) {
  const avail = state.players.filter((p) => !out.includes(p));
  if (avail.length < ON_COURT) throw new MatchError(`at least ${ON_COURT} players must be available`);
  const targets = evenTargets({ grid: state.grid, players: state.players, available: avail, fromBlock: state.block });
  try {
    return replanRemaining({
      grid: state.grid, players: state.players, available: avail, fromBlock: state.block, targets,
      blockSeconds: state.blockSeconds, seed: state.block,
    });
  } catch (error) {
    if (!(error instanceof PlanError)) throw error;
    // No plan meets the targets under the sub rule: never refuse a player who is out, repair instead.
    return repairRemaining({ grid: state.grid, players: state.players, available: avail, fromBlock: state.block });
  }
}

// "uit": from the next block on, `player` plays no more this match.
export function uit(state, player) {
  if (state.ended) throw new MatchError('the match has ended');
  if (!state.players.includes(player)) throw new MatchError(`player ${player} is not in this match`);
  if (state.out.includes(player)) throw new MatchError(`player ${player} is already out`);
  if (state.block >= state.blocks) throw new MatchError('no block left: this is the last block');
  const out = sorted(state.out.concat(player));
  return { ...state, grid: respread(state, out), out, previous: snapshot(state) };
}

// "terug": `player` is available again from the next block on.
export function terug(state, player) {
  if (state.ended) throw new MatchError('the match has ended');
  if (!state.out.includes(player)) throw new MatchError(`player ${player} is not out`);
  if (state.block >= state.blocks) throw new MatchError('no block left: this is the last block');
  const out = state.out.filter((p) => p !== player);
  return { ...state, grid: respread(state, out), out, previous: snapshot(state) };
}

// "undo": back to the state before the last action, one step only. With nothing to undo it changes nothing.
export function undo(state) {
  if (!state.previous) return state;
  const { block, ended, grid, out } = state.previous;
  return { ...state, block, ended, grid: copyGrid(grid), out: out.slice(), previous: null };
}

export function canUndo(state) {
  return state.previous != null;
}

// Actions as the runner writes them: { type: 'wissel', keep?, bench? }, { type: 'undo' }, { type: 'uit', player },
// { type: 'terug', player }; the strings 'wissel' and 'undo' also work.
export function applyAction(state, action) {
  const a = typeof action === 'string' ? { type: action } : action;
  if (a.type === 'wissel') return wissel(state, { keep: a.keep ?? null, bench: a.bench ?? null });
  if (a.type === 'undo') return undo(state);
  if (a.type === 'uit') return uit(state, a.player);
  if (a.type === 'terug') return terug(state, a.player);
  throw new MatchError(`unknown action "${a.type}": use wissel, undo, uit or terug`);
}

// The players on court in the current block, sorted.
export function onCourt(state) {
  return sorted(state.grid[state.block - 1]);
}

// Who goes off and who comes on at the next wissel; null at the last block or after the end.
export function nextChange(state) {
  if (state.ended || state.block >= state.blocks) return null;
  const now = state.grid[state.block - 1];
  const next = state.grid[state.block];
  return { off: sorted(now.filter((p) => !next.includes(p))), on: sorted(next.filter((p) => !now.includes(p))) };
}

// When the current block ends on the official clock, which counts down from 10:00 each quarter:
// { kind: 'sub', clockSeconds } for a wissel inside the quarter (6:40 and 3:20 in the equal schedule, 5:00 in the
// 5-minute one), { kind: 'endQuarter' } at the last block of a quarter, { kind: 'endMatch' } at the last block.
export function subTime(state) {
  if (state.block >= state.blocks) return { kind: 'endMatch' };
  const inQuarter = (state.block - 1) % state.blocksPerQuarter; // 0-based place of the block in its quarter
  if (inQuarter === state.blocksPerQuarter - 1) return { kind: 'endQuarter' };
  const quarterSeconds = state.blocksPerQuarter * state.blockSeconds;
  return { kind: 'sub', clockSeconds: quarterSeconds - (inQuarter + 1) * state.blockSeconds };
}

export function quarterOf(state) {
  return Math.floor((state.block - 1) / state.blocksPerQuarter) + 1;
}

// Seconds per player so far: blocks started (the current one included) × block length.
export function minutesSoFar(state) {
  const minutes = Object.fromEntries(state.players.map((p) => [p, 0]));
  for (const court of state.grid.slice(0, state.block)) {
    for (const p of court) minutes[p] += state.blockSeconds;
  }
  return minutes;
}

function validGrid(grid, fresh) {
  return Array.isArray(grid) && grid.length === fresh.blocks && grid.every((court) => Array.isArray(court)
    && court.length === ON_COURT && new Set(court).size === ON_COURT && court.every((p) => fresh.players.includes(p)));
}

function validOut(out, fresh) {
  return Array.isArray(out) && new Set(out).size === out.length && out.every((p) => fresh.players.includes(p))
    && fresh.players.length - out.length >= ON_COURT;
}

const samePrefix = (a, b, blocks) => JSON.stringify(a.slice(0, blocks)) === JSON.stringify(b.slice(0, blocks));

// Version 1 states (before in the zone, uit and terug) followed the plan's grid and had no one out.
function fromVersion1(raw, fresh) {
  const previous = raw.previous && typeof raw.previous === 'object'
    ? { block: raw.previous.block, ended: raw.previous.ended, grid: copyGrid(fresh.grid), out: [] }
    : raw.previous;
  return { ...raw, version: MATCH_VERSION, base: copyGrid(fresh.grid), grid: raw.grid, out: [], previous };
}

// A match state read from the store, checked against the plan it must belong to. Returns the state, or null when it
// is missing, damaged, from an unknown version or from another match setup (then the screen starts a new match).
export function normaliseMatchState(stored, plan, setupSavedAt = null) {
  if (!stored || typeof stored !== 'object' || Array.isArray(stored)) return null;
  const fresh = startMatch(plan, setupSavedAt);
  let raw = stored;
  if (raw.version === 1) {
    if (JSON.stringify(raw.grid) !== JSON.stringify(fresh.grid)) return null;
    raw = fromVersion1(raw, fresh);
  }
  if (raw.version !== MATCH_VERSION || raw.setupSavedAt !== fresh.setupSavedAt) return null;
  for (const key of ['schedule', 'blocks', 'blockSeconds', 'blocksPerQuarter']) {
    if (raw[key] !== fresh[key]) return null;
  }
  if (JSON.stringify(raw.players) !== JSON.stringify(fresh.players)) return null;
  if (JSON.stringify(raw.base) !== JSON.stringify(fresh.base)) return null;
  const point = (p) => p && typeof p === 'object' && Number.isInteger(p.block) && p.block >= 1 && p.block <= fresh.blocks
    && typeof p.ended === 'boolean' && (!p.ended || p.block === fresh.blocks)
    && validGrid(p.grid, fresh) && validOut(p.out, fresh);
  if (!point(raw)) return null;
  // The first block is the coach's starting five and never changes.
  if (JSON.stringify(sorted(raw.grid[0])) !== JSON.stringify(sorted(fresh.grid[0]))) return null;
  // Nobody who is out plays in a block after the current one.
  if (raw.grid.slice(raw.block).some((court) => court.some((p) => raw.out.includes(p)))) return null;
  if (raw.previous != null) {
    // The only history an action leaves: a wissel from the active block just before this one (or, after the end,
    // from the active last block), or an uit or terug on this same active block. Blocks that were already played
    // are the same in both. Anything else would make undo jump, so it is refused.
    const prev = raw.previous;
    if (!point(prev) || prev.ended !== false) return null;
    const allowed = raw.ended ? [fresh.blocks] : [raw.block - 1, raw.block];
    if (!allowed.includes(prev.block)) return null;
    if (!samePrefix(prev.grid, raw.grid, prev.block)) return null;
  }
  const previous = raw.previous == null ? null : snapshot(raw.previous);
  return { ...fresh, grid: copyGrid(raw.grid), out: raw.out.slice(), block: raw.block, ended: raw.ended, previous };
}
