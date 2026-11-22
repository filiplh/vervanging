// Planner: who plays which block. Pure functions, no DOM or storage, shared by the screens and scripts/sim.mjs.
// Decisions: docs/PLAN.md #6 (schedules), #7 (grid, swaps), #20 (starting five), #21 and #22 (sub rule), ADR-001.

export const SCHEDULES = Object.freeze({
  equal: Object.freeze({ blocks: 12, blockSeconds: 200, blocksPerQuarter: 3 }),
  five: Object.freeze({ blocks: 8, blockSeconds: 300, blocksPerQuarter: 2 }),
});

export const ON_COURT = 5;
export const MAX_SUBS = 3;
export const MAX_SIT_SECONDS = 900;
export const MAX_STINT_SECONDS = 600;
const NODE_BUDGET = 50000;
const TWO_SUB_BUDGET = 3000;
const CANDIDATES_PER_K = 24;

export class PlanError extends Error {}

// Small seeded generator (mulberry32), so the same seed gives the same plan.
export function seededRandom(seed) {
  let a = (Number(seed) >>> 0) || 1;
  return () => {
    a = (a + 0x6d2b79f5) >>> 0;
    let t = a;
    t = Math.imul(t ^ (t >>> 15), t | 1);
    t ^= t + Math.imul(t ^ (t >>> 7), t | 61);
    return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
  };
}

function shuffled(list, random) {
  const out = list.slice();
  for (let i = out.length - 1; i > 0; i--) {
    const j = Math.floor(random() * (i + 1));
    [out[i], out[j]] = [out[j], out[i]];
  }
  return out;
}

function scheduleOf(name) {
  const schedule = SCHEDULES[name];
  if (!schedule) throw new PlanError(`unknown schedule "${name}": use equal or five`);
  return schedule;
}

function checkPlayers(players, start) {
  if (!Array.isArray(players) || players.length < ON_COURT) {
    throw new PlanError(`at least ${ON_COURT} players must be present`);
  }
  if (new Set(players).size !== players.length) throw new PlanError('players must be distinct');
  if (!Array.isArray(start) || start.length !== ON_COURT || new Set(start).size !== ON_COURT) {
    throw new PlanError(`the starting five must have ${ON_COURT} different players`);
  }
  for (const p of start) {
    if (!players.includes(p)) throw new PlanError(`starting five player ${p} is not present`);
  }
}

// Blocks per player: as equal as possible. The places that cannot be split equally go first to the players in
// `extraPriority` (in its order; history uses it, decision #10), then to players in seeded random order.
export function blockTargets(players, totalPlaces, random, extraPriority = []) {
  const base = Math.floor(totalPlaces / players.length);
  const extras = totalPlaces - base * players.length;
  const order = [
    ...extraPriority.filter((p) => players.includes(p)),
    ...shuffled(players.filter((p) => !extraPriority.includes(p)), random),
  ];
  const lucky = new Set(order.slice(0, extras));
  return Object.fromEntries(players.map((p) => [p, base + (lucky.has(p) ? 1 : 0)]));
}

function combinations(list, k) {
  if (k === 0) return [[]];
  if (list.length < k) return [];
  const [head, ...rest] = list;
  return [...combinations(rest, k - 1).map((c) => [head, ...c]), ...combinations(rest, k)];
}

// Fills blocks prefix.length .. blocks-1 so every player reaches its target, with at most MAX_SUBS changes per sub
// moment (trying 2 first, then 1, then 3, then 0), no sit longer than maxSit blocks and no stint longer than maxStint
// blocks. `available` limits who may play the remaining blocks. Returns the full grid or null.
export function fillGrid({ prefix, players, available = players, targets, blocks, maxSit, maxStint, maxSubs = MAX_SUBS, budget = NODE_BUDGET, random }) {
  const played = Object.fromEntries(players.map((p) => [p, 0]));
  const sit = Object.fromEntries(players.map((p) => [p, 0]));
  const stint = Object.fromEntries(players.map((p) => [p, 0]));
  for (const court of prefix) {
    for (const p of players) {
      if (court.includes(p)) {
        played[p] += 1; stint[p] += 1; sit[p] = 0;
      } else {
        sit[p] += 1; stint[p] = 0;
      }
    }
  }
  const avail = new Set(available);
  const noise = Object.fromEntries(players.map((p) => [p, random() * 1e-3]));
  const grid = prefix.map((c) => c.slice());
  let nodes = 0;

  const feasible = (left) => {
    // left = blocks still to fill after the one just placed
    for (const p of players) {
      const need = targets[p] - played[p];
      if (need < 0 || need > left) return false;
      if (need > 0 && !avail.has(p)) return false;
      if (sit[p] > maxSit && avail.has(p) && targets[p] > 0) return false;
      if (stint[p] > maxStint) return false;
      // a player who is done sits out the rest of the match: that tail counts as a sit too
      if (need === 0 && avail.has(p) && sit[p] + left > maxSit) return false;
    }
    return true;
  };

  const step = () => {
    if (grid.length === blocks) return true;
    if (++nodes > budget) return false;
    const left = blocks - grid.length; // including the block being chosen
    const current = grid[grid.length - 1];
    const urgency = (p) => (targets[p] - played[p]) / left + sit[p] * 0.05 - stint[p] * 0.05 + noise[p];
    const need = (p) => targets[p] - played[p];
    // Forced moves: who must leave, who must stay, who must come on for the limits and targets to hold.
    const mustOut = current.filter((p) => !avail.has(p) || need(p) === 0 || stint[p] >= maxStint);
    const mustStay = current.filter((p) => !mustOut.includes(p) && need(p) === left);
    const freeOut = current
      .filter((p) => !mustOut.includes(p) && !mustStay.includes(p))
      .sort((a, b) => urgency(a) - urgency(b));
    const bench = players.filter((p) => !current.includes(p) && avail.has(p) && need(p) > 0);
    const mustIn = bench.filter((p) => need(p) === left || sit[p] >= maxSit);
    const freeIn = bench.filter((p) => !mustIn.includes(p)).sort((a, b) => urgency(b) - urgency(a));
    if (mustOut.length > maxSubs || mustIn.length > maxSubs) return false;
    const candidates = [];
    for (const k of [2, 1, 3, 0]) {
      if (k > maxSubs || k < mustOut.length || k < mustIn.length) continue;
      const perK = [];
      for (const outsExtra of combinations(freeOut, k - mustOut.length)) {
        const outs = mustOut.concat(outsExtra);
        for (const insExtra of combinations(freeIn, k - mustIn.length)) {
          const ins = mustIn.concat(insExtra);
          const next = current.filter((p) => !outs.includes(p)).concat(ins);
          const score = ins.reduce((s, p) => s + urgency(p), 0) - outs.reduce((s, p) => s + urgency(p), 0);
          perK.push({ next, score });
        }
      }
      perK.sort((a, b) => b.score - a.score);
      candidates.push(...perK.slice(0, CANDIDATES_PER_K));
    }
    for (const { next } of candidates) {
      const saved = players.map((p) => [played[p], sit[p], stint[p]]);
      for (const p of players) {
        if (next.includes(p)) {
          played[p] += 1; stint[p] += 1; sit[p] = 0;
        } else {
          sit[p] += 1; stint[p] = 0;
        }
      }
      grid.push(next.slice().sort((a, b) => a - b));
      if (feasible(left - 1) && step()) return true;
      grid.pop();
      players.forEach((p, i) => { [played[p], sit[p], stint[p]] = saved[i]; });
      if (nodes > budget) return false;
    }
    return false;
  };

  return step() ? grid : null;
}

// Tries a cap of 2 subs with the strict limits, then a cap of 3, then drops the stint limit, then the sit limit
// (never the cap of 3; plan assumption A3).
export function searchGrid({ prefix, players, available, targets, blocks, blockSeconds, random }) {
  const sitBlocks = Math.floor(MAX_SIT_SECONDS / blockSeconds);
  const stintBlocks = Math.max(1, Math.floor(MAX_STINT_SECONDS / blockSeconds));
  const stint = Math.max(stintBlocks, 3);
  // A cap of 2 first: 3 subs only where 2 cannot keep the limits (decision #21).
  const levels = [
    { maxSubs: 2, maxSit: sitBlocks, maxStint: stint, budget: TWO_SUB_BUDGET, sitLimitRelaxed: false },
    { maxSubs: 3, maxSit: sitBlocks, maxStint: stint, budget: NODE_BUDGET, sitLimitRelaxed: false },
    { maxSubs: 3, maxSit: sitBlocks, maxStint: blocks, budget: NODE_BUDGET, sitLimitRelaxed: false },
    { maxSubs: 3, maxSit: blocks, maxStint: blocks, budget: NODE_BUDGET, sitLimitRelaxed: true },
  ];
  for (const level of levels) {
    const grid = fillGrid({ prefix, players, available, targets, blocks, ...level, random });
    if (grid) return { grid, sitLimitRelaxed: level.sitLimitRelaxed };
  }
  throw new PlanError('no plan found within the substitution limit of 3');
}

export function makePlan({ players, start, schedule = 'equal', seed = 1, extraPriority = [] }) {
  const { blocks, blockSeconds, blocksPerQuarter } = scheduleOf(schedule);
  checkPlayers(players, start);
  const random = seededRandom(seed);
  const targets = blockTargets(players, ON_COURT * blocks, random, extraPriority);
  const first = start.slice().sort((a, b) => a - b);
  const { grid, sitLimitRelaxed } = searchGrid({ prefix: [first], players, targets, blocks, blockSeconds, random });
  return { schedule, blocks, blockSeconds, blocksPerQuarter, players: players.slice(), start: first, grid, sitLimitRelaxed };
}

// Exchanges two players' rows. Both must be in the starting five, or both not, so the starting five stays as picked.
export function swapPlayers(plan, a, b) {
  for (const p of [a, b]) {
    if (!plan.players.includes(p)) throw new PlanError(`player ${p} is not in the plan`);
  }
  if (a === b) throw new PlanError('pick two different players to swap');
  if (plan.start.includes(a) !== plan.start.includes(b)) {
    throw new PlanError('swap two starters or two bench players, so the starting five stays as picked');
  }
  const swap = (p) => (p === a ? b : p === b ? a : p);
  const grid = plan.grid.map((court) => court.map(swap).sort((x, y) => x - y));
  return { ...plan, grid };
}

export function planStats(plan) {
  const { grid, players, blockSeconds } = plan;
  const minutes = {};
  let longestSit = 0;
  let longestStint = 0;
  for (const p of players) {
    let count = 0; let sit = 0; let stint = 0;
    for (const court of grid) {
      if (court.includes(p)) {
        count += 1; stint += 1; sit = 0;
      } else {
        sit += 1; stint = 0;
      }
      longestSit = Math.max(longestSit, sit);
      longestStint = Math.max(longestStint, stint);
    }
    minutes[p] = count * blockSeconds;
  }
  const subsPerChange = grid.slice(1).map((court, i) => court.filter((p) => !grid[i].includes(p)).length);
  return {
    minutes,
    subsPerChange,
    longestBenchSeconds: longestSit * blockSeconds,
    longestStintSeconds: longestStint * blockSeconds,
  };
}

// Live changes (decisions #8 and #11): replan the blocks after `fromBlock` (1-based count of blocks already fixed)
// so every available player reaches `targets`, under the same sub rule. Earlier blocks are never changed. Players who
// are not available get no more blocks. Returns the full grid; throws PlanError when no plan fits.
export function replanRemaining({ grid, players, available = players, fromBlock, targets, blockSeconds, seed = 1 }) {
  if (!Number.isInteger(fromBlock) || fromBlock < 1 || fromBlock > grid.length) {
    throw new PlanError('fromBlock must be between 1 and the number of blocks');
  }
  if (fromBlock === grid.length) return grid.map((court) => court.slice());
  if (available.length < ON_COURT) throw new PlanError(`at least ${ON_COURT} players must be available`);
  const prefix = grid.slice(0, fromBlock).map((court) => court.slice());
  const { grid: filled } = searchGrid({
    prefix, players, available, targets, blocks: grid.length, blockSeconds, random: seededRandom(seed),
  });
  return filled;
}

// Blocks per player for the rest of the match when who may play changes (uit, terug): the places left after
// `fromBlock` go one by one to the available player with the fewest blocks so far (ties: lowest number), so the match
// totals end as equal as the remaining blocks allow (decision #11).
export function evenTargets({ grid, players, available, fromBlock }) {
  const left = grid.length - fromBlock;
  const counts = Object.fromEntries(players.map((p) => [p, 0]));
  for (const court of grid.slice(0, fromBlock)) for (const p of court) counts[p] += 1;
  const extra = Object.fromEntries(players.map((p) => [p, 0]));
  const pool = players.filter((p) => available.includes(p)).sort((a, b) => a - b);
  for (let place = 0; place < ON_COURT * left; place++) {
    let best = null;
    for (const p of pool) {
      if (extra[p] >= left) continue;
      if (best === null || counts[p] + extra[p] < counts[best] + extra[best]) best = p;
    }
    if (best === null) throw new PlanError(`at least ${ON_COURT} players must be available`);
    extra[best] += 1;
  }
  return Object.fromEntries(players.map((p) => [p, counts[p] + extra[p]]));
}

export function blockCounts(grid, players) {
  const counts = Object.fromEntries(players.map((p) => [p, 0]));
  for (const court of grid) for (const p of court) counts[p] += 1;
  return counts;
}

export function maxSubsFrom(grid, fromChange = 0) {
  let max = 0;
  for (let i = Math.max(1, fromChange + 1); i < grid.length; i++) {
    max = Math.max(max, grid[i].filter((p) => !grid[i - 1].includes(p)).length);
  }
  return max;
}

// Last resort when no plan meets the targets under the sub rule (late in a match, after several live changes): keep
// the planned line-ups as far as possible, but put in an available player for anyone who is not available (fewest
// blocks first) and hold every change to at most MAX_SUBS subs by keeping available players on instead (fewest blocks
// so far come on first). The one exception: players who are not available must leave, so a change may need as many
// subs as the unavailable players it takes off, when that is more than MAX_SUBS (four players uit at once). Totals may
// then differ by more than a block; the minutes on screen show it. Never fails while ON_COURT players are available.
export function repairRemaining({ grid, players, available = players, fromBlock }) {
  if (available.length < ON_COURT) throw new PlanError(`at least ${ON_COURT} players must be available`);
  const out = grid.map((court) => court.slice());
  const counts = blockCounts(out.slice(0, fromBlock), players);
  const fewest = (a, b) => counts[a] - counts[b] || a - b;
  for (let k = fromBlock; k < out.length; k++) {
    const prev = out[k - 1];
    const row = out[k].filter((p) => available.includes(p));
    for (const p of [...prev.filter((q) => available.includes(q)), ...available.slice().sort(fewest)]) {
      if (row.length >= ON_COURT) break;
      if (!row.includes(p)) row.push(p);
    }
    let incoming = row.filter((p) => !prev.includes(p)).sort(fewest);
    const stayers = prev.filter((p) => available.includes(p) && !row.includes(p)).sort(fewest);
    while (incoming.length > MAX_SUBS && stayers.length > 0) {
      const drop = incoming.pop(); // the incoming player with the most blocks waits
      row.splice(row.indexOf(drop), 1, stayers.shift());
      incoming = row.filter((p) => !prev.includes(p)).sort(fewest);
    }
    out[k] = row.sort((a, b) => a - b);
    for (const p of out[k]) counts[p] += 1;
  }
  return out;
}
