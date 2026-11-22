// Match engine: which block is being played, and the live actions on it. Pure functions, no DOM or storage: a state
// goes in, a new state comes out, and every state is plain JSON, so the live screen saves it after every tap and
// scripts/sim.mjs drives the same code. Decisions: docs/PLAN.md #4 (blocks, minutes = blocks × length), #12 (live
// screen), #17 (undo, one step), #18 (saved after every tap).

export const MATCH_VERSION = 1;

export class MatchError extends Error {}

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
    grid: grid.map((court) => court.slice()),
    block: 1,
    ended: false,
    previous: null,
  };
}

// "wissel": on to the next block; at the last block it ends the match. After the end it changes nothing.
export function wissel(state) {
  if (state.ended) return state;
  const previous = { block: state.block, ended: state.ended };
  if (state.block >= state.blocks) return { ...state, ended: true, previous };
  return { ...state, block: state.block + 1, previous };
}

// "undo": back to the state before the last action, one step only. With nothing to undo it changes nothing.
export function undo(state) {
  if (!state.previous) return state;
  return { ...state, block: state.previous.block, ended: state.previous.ended, previous: null };
}

export function canUndo(state) {
  return state.previous != null;
}

export function applyAction(state, action) {
  if (action === 'wissel') return wissel(state);
  if (action === 'undo') return undo(state);
  throw new MatchError(`unknown action "${action}": use wissel or undo`);
}

// The players on court in the current block, sorted.
export function onCourt(state) {
  return state.grid[state.block - 1].slice().sort((a, b) => a - b);
}

// Who goes off and who comes on at the next wissel; null at the last block or after the end.
export function nextChange(state) {
  if (state.ended || state.block >= state.blocks) return null;
  const now = state.grid[state.block - 1];
  const next = state.grid[state.block];
  const sort = (list) => list.slice().sort((a, b) => a - b);
  return { off: sort(now.filter((p) => !next.includes(p))), on: sort(next.filter((p) => !now.includes(p))) };
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

// A match state read from the store, checked against the plan it must belong to. Returns the state, or null when it
// is missing, damaged, from another version or from another match setup (then the screen starts a new match).
export function normaliseMatchState(raw, plan, setupSavedAt = null) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw) || raw.version !== MATCH_VERSION) return null;
  const fresh = startMatch(plan, setupSavedAt);
  if (raw.setupSavedAt !== fresh.setupSavedAt) return null;
  for (const key of ['schedule', 'blocks', 'blockSeconds', 'blocksPerQuarter']) {
    if (raw[key] !== fresh[key]) return null;
  }
  if (JSON.stringify(raw.players) !== JSON.stringify(fresh.players)) return null;
  if (JSON.stringify(raw.grid) !== JSON.stringify(fresh.grid)) return null;
  const point = (p) => p && typeof p === 'object' && Number.isInteger(p.block) && p.block >= 1 && p.block <= fresh.blocks
    && typeof p.ended === 'boolean' && (!p.ended || p.block === fresh.blocks);
  if (!point(raw)) return null;
  if (raw.previous != null && !point(raw.previous)) return null;
  const previous = raw.previous == null ? null : { block: raw.previous.block, ended: raw.previous.ended };
  return { ...fresh, block: raw.block, ended: raw.ended, previous };
}
