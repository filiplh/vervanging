import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { makePlan, planStats } from './planner.js';
import {
  emptyHistory, normaliseHistory, recordMatch, forgetMatch, hasMatch, clearHistory, totalSeconds, extraPriority,
  startedAfterClear, seasonSummary, catchUp, catchUpSeconds,
} from './history.js';
import { SCHEDULES, maxSubsFrom, seededRandom } from './planner.js';

const ids = (n) => Array.from({ length: n }, (_, i) => i + 1);
// catchUp's [behind, ahead] moves as a block change per player id.
const deltas = (moves) => {
  const d = {};
  for (const [to, from] of moves) { d[to] = (d[to] ?? 0) + 1; d[from] = (d[from] ?? 0) - 1; }
  return d;
};
const sample = JSON.parse(readFileSync(new URL('../../scripts/fixtures/history-sample.json', import.meta.url), 'utf8'));

test('normaliseHistory: damaged values give an empty history, bad entries and seconds are dropped', () => {
  for (const raw of [null, undefined, 42, 'x', [], {}, { matches: 'x' }, { matches: {} }]) {
    assert.deepEqual(normaliseHistory(raw), emptyHistory());
  }
  assert.equal(normaliseHistory({ useHistory: 'true', matches: [] }).useHistory, false, 'only true switches it on');
  const cleaned = normaliseHistory({
    useHistory: true,
    matches: [
      null, 'x', { id: 3, seconds: {} }, { id: '', seconds: {} }, { id: 'a', seconds: [] }, { id: 'b' },
      { id: 'c', seconds: { 1: 600, 2: -1, 3: 'x', 4: null, x: 5, 5: Infinity, '1.5': 3, 6: 0 } },
      { id: 'd', seconds: { 1: 1 } }, { id: 'd', seconds: { 1: 2 } },
    ],
  });
  assert.deepEqual(cleaned, { useHistory: true, clearedAt: null, matches: [{ id: 'c', seconds: { 1: 600, 6: 0 } }, { id: 'd', seconds: { 1: 2 } }] });
});

test('the sample fixture has the stored shape: players 1 to 4 at 0 seconds, 5 to 12 at 3000', () => {
  const history = normaliseHistory(sample);
  assert.deepEqual(history, sample, 'nothing is dropped from the fixture');
  const totals = totalSeconds(history);
  for (const p of ids(12)) assert.equal(totals[p], p <= 4 ? 0 : 3000, `player ${p}`);
});

test('recordMatch adds once per id, forgetMatch removes, clearHistory keeps the switch', () => {
  let history = emptyHistory();
  history = recordMatch(history, 'm1', { 1: 600, 2: 400 });
  history = recordMatch(history, 'm1', { 1: 700, 2: 300 }); // ended again after an undo, or recorded twice
  assert.deepEqual(history.matches, [{ id: 'm1', seconds: { 1: 700, 2: 300 } }]);
  history = recordMatch(history, 'm2', { 1: 100, 3: 900 });
  assert.equal(hasMatch(history, 'm2'), true);
  assert.deepEqual(totalSeconds(history), { 1: 800, 2: 300, 3: 900 });
  history = forgetMatch(history, 'm1');
  assert.deepEqual(totalSeconds(history), { 1: 100, 3: 900 });
  assert.equal(hasMatch(history, 'm1'), false);
  assert.deepEqual(clearHistory({ ...history, useHistory: true }, '2026-11-22T10:00:00.000Z'),
    { useHistory: true, clearedAt: '2026-11-22T10:00:00.000Z', matches: [] });
});

test('clearedAt: kept when it is a time, dropped otherwise; startedAfterClear compares with the setup time', () => {
  assert.equal(normaliseHistory({ clearedAt: '2026-11-22T10:00:00.000Z' }).clearedAt, '2026-11-22T10:00:00.000Z');
  for (const clearedAt of [42, 'gisteren', '', null, {}]) assert.equal(normaliseHistory({ clearedAt }).clearedAt, null);
  const cleared = clearHistory(emptyHistory(), '2026-11-22T10:00:00.000Z');
  assert.equal(startedAfterClear(emptyHistory(), '2026-01-01T00:00:00.000Z'), true, 'never cleared');
  assert.equal(startedAfterClear(cleared, '2026-11-22T09:59:59.999Z'), false);
  assert.equal(startedAfterClear(cleared, '2026-11-22T10:00:00.000Z'), false);
  assert.equal(startedAfterClear(cleared, '2026-11-22T10:00:00.001Z'), true);
  assert.equal(startedAfterClear(cleared, 'kapot'), false);
});

test('extraPriority: fewest total seconds first; absent players ignored; unknown players count as 0', () => {
  const history = recordMatch(emptyHistory(), 'm1', { 1: 900, 2: 300, 3: 600, 99: 0 });
  // 99 is in the history but not present; 4 is present but not in the history.
  assert.deepEqual(extraPriority(history, [1, 2, 3, 4], 7), [4, 2, 3, 1]);
});

test('extraPriority: ties are ordered at random from the seed, the same seed gives the same order', () => {
  const players = ids(12);
  const empty = emptyHistory();
  const orders = new Set();
  for (let seed = 1; seed <= 20; seed++) {
    const order = extraPriority(empty, players, seed);
    assert.deepEqual(order.slice().sort((a, b) => a - b), players, 'every present player, once');
    assert.deepEqual(extraPriority(empty, players, seed), order, 'deterministic');
    orders.add(order.join(','));
  }
  assert.ok(orders.size > 1, 'different seeds give different tie orders');
  const order = extraPriority(sample, players, 3);
  assert.deepEqual(order.slice(0, 4).sort((a, b) => a - b), [1, 2, 3, 4]);
});

test('makePlan with the switch on: the extra blocks go to the players who played least', () => {
  for (let seed = 1; seed <= 10; seed++) {
    const plan = makePlan({ players: ids(12), start: [1, 5, 6, 7, 8], schedule: 'five', seed, extraPriority: extraPriority(sample, ids(12), seed) });
    const { minutes } = planStats(plan);
    for (const p of ids(12)) assert.equal(minutes[p], p <= 4 ? 1200 : 900, `seed ${seed}, player ${p}`);
  }
});

test('makePlan with the switch off, or an empty history: the plan the seed gives without history', () => {
  for (let seed = 1; seed <= 5; seed++) {
    const base = makePlan({ players: ids(10), start: [1, 2, 3, 4, 5], schedule: 'equal', seed });
    const off = makePlan({ players: ids(10), start: [1, 2, 3, 4, 5], schedule: 'equal', seed, extraPriority: [] });
    assert.deepEqual(off, base);
    // With an empty history the switch still works: every player ties at 0, so the extras are random from the seed.
    const empty = makePlan({ players: ids(10), start: [1, 2, 3, 4, 5], schedule: 'equal', seed, extraPriority: extraPriority(emptyHistory(), ids(10), seed) });
    const seconds = Object.values(planStats(empty).minutes);
    assert.equal(seconds.reduce((a, b) => a + b, 0), 5 * 12 * 200);
    assert.ok(Math.max(...seconds) - Math.min(...seconds) <= 200);
  }
});

test('players in the history who are not present take no extra place', () => {
  // Players 11 and 12 never played but are absent today; among the present ones, 1 to 4 played least.
  const history = recordMatch(emptyHistory(), 'm1', { 1: 100, 2: 100, 3: 100, 4: 100, 5: 3000, 6: 3000, 7: 3000, 8: 3000, 9: 3000, 10: 3000, 11: 0, 12: 0 });
  const nine = ids(9); // five: 40 places for 9 players, 4 each and 4 extras
  assert.equal(extraPriority(history, nine, 1).includes(11), false);
  const plan = makePlan({ players: nine, start: [1, 5, 6, 7, 8], schedule: 'five', seed: 2, extraPriority: extraPriority(history, nine, 2) });
  const { minutes } = planStats(plan);
  for (const p of nine) assert.equal(minutes[p], p <= 4 ? 1500 : 1200, `player ${p}`);
});

// ---------- season totals (decision #26) ----------

test('seasonSummary: totals over several matches, players missing from some matches count only where they played', () => {
  let history = emptyHistory();
  history = recordMatch(history, 'm1', { 1: 600, 2: 1200, 3: 0 });
  history = recordMatch(history, 'm2', { 1: 900, 4: 300 }); // 2 and 3 absent
  history = recordMatch(history, 'm3', { 2: 2400.5, 4: 3600 });
  assert.deepEqual(seasonSummary(history), { matches: 3, totals: { 1: 1500, 2: 3600.5, 3: 0, 4: 3900 } });
  assert.deepEqual(seasonSummary(normaliseHistory(sample)).matches, 2);
});

test('seasonSummary: an empty, a cleared and a damaged history give no matches and no totals', () => {
  assert.deepEqual(seasonSummary(emptyHistory()), { matches: 0, totals: {} });
  const cleared = clearHistory(normaliseHistory(sample), '2026-11-22T10:00:00.000Z');
  assert.deepEqual(seasonSummary(cleared), { matches: 0, totals: {} });
  for (const raw of [null, 'x', [], { matches: 'x' }, { matches: [null, { id: 3 }, { id: 'a', seconds: [] }] }]) {
    assert.deepEqual(seasonSummary(normaliseHistory(raw)), { matches: 0, totals: {} });
  }
  // Damaged seconds inside a good entry are dropped, the rest still counts.
  const partly = normaliseHistory({ matches: [{ id: 'a', seconds: { 1: 600, 2: -5, 3: 'x' } }, { id: 'b', seconds: { 1: 60 } }] });
  assert.deepEqual(seasonSummary(partly), { matches: 2, totals: { 1: 660 } });
});

const SIM = fileURLToPath(new URL('../../scripts/sim.mjs', import.meta.url));
const FIXTURE = (name) => fileURLToPath(new URL(`../../scripts/fixtures/${name}`, import.meta.url));
const sim = (...args) => spawnSync(process.execPath, [SIM, ...args], { encoding: 'utf8' });

test('runner history: the sample and the empty fixture give matches and totals', () => {
  const full = sim('history', '--history', FIXTURE('history-sample.json'), '--json');
  assert.equal(full.status, 0, full.stderr);
  const out = JSON.parse(full.stdout);
  assert.equal(out.matches, 2);
  for (const p of ids(12)) assert.equal(out.totals[p], p <= 4 ? 0 : 3000, `player ${p}`);
  const empty = sim('history', '--history', FIXTURE('history-empty.json'), '--json');
  assert.equal(empty.status, 0, empty.stderr);
  assert.deepEqual(JSON.parse(empty.stdout), { matches: 0, totals: {} });
  assert.deepEqual(normaliseHistory(JSON.parse(readFileSync(FIXTURE('history-empty.json'), 'utf8'))),
    JSON.parse(readFileSync(FIXTURE('history-empty.json'), 'utf8')), 'the empty fixture has the stored shape');
});

test('runner history: a missing or unreadable file exits 2 with one line about the history on stderr', () => {
  for (const args of [['--history', FIXTURE('does-not-exist.json')], ['--history', SIM], []]) {
    const run = sim('history', ...args, '--json');
    assert.equal(run.status, 2, `args ${args.join(' ')}`);
    assert.equal(run.stdout, '');
    assert.equal(run.stderr.trim().split('\n').length, 1);
    assert.match(run.stderr, /history/);
  }
});

// ---------- catch-up (#34, decision #28) ----------

const withMatches = (matches) => normaliseHistory({ useHistory: true, clearedAt: null, matches });
const full = (n, secs, extra) => ({ id: `m${Math.random()}`, seconds: Object.fromEntries(ids(n).map((p) => [String(p), secs(p)])), ...(extra ? { extra } : {}) });

test('recordMatch keeps extra seconds apart; old entries without them load; damaged extra is dropped', () => {
  const h = recordMatch(emptyHistory(), 'a', { 1: 1200, 2: 800 }, { 1: 200, 2: 0, 9: 200 });
  assert.deepEqual(h.matches[0].extra, { 1: 200 }, 'only players with seconds, above 0');
  assert.equal(normaliseHistory({ matches: [{ id: 'x', seconds: { 1: 600 } }] }).matches[0].extra, undefined);
  const damaged = normaliseHistory({ matches: [{ id: 'x', seconds: { 1: 600 }, extra: { 1: 'lots', 2: 200, 1.5: 3 } }] });
  assert.equal(damaged.matches[0].extra, undefined);
  const capped = normaliseHistory({ matches: [{ id: 'x', seconds: { 1: 600 }, extra: { 1: 900 } }] });
  assert.deepEqual(capped.matches[0].extra, { 1: 600 }, 'extra is never more than the seconds');
});

test('catchUpSeconds leaves Extra minuten out; seasonSummary still counts them', () => {
  const h = withMatches([{ id: 'a', seconds: { 1: 1200, 2: 1000 }, extra: { 1: 200 } }]);
  assert.deepEqual(catchUpSeconds(h), { 1: 1000, 2: 1000 });
  assert.deepEqual(seasonSummary(h).totals, { 1: 1200, 2: 1000 });
});

test('catchUp: a player one block or more behind gets +1, the furthest ahead -1; within a block nothing moves', () => {
  const behind = withMatches([full(12, (p) => (p === 12 ? 2000 : 3000))]);
  const { moves } = catchUp(behind, ids(12), SCHEDULES.equal, 1);
  assert.equal(moves.length, 1);
  assert.equal(moves[0][0], 12);
  assert.notEqual(moves[0][1], 12);
  const close = withMatches([full(12, (p) => (p === 12 ? 2900 : 3000))]);
  assert.deepEqual(catchUp(close, ids(12), SCHEDULES.equal, 1).moves, [], 'less than one block apart');
  assert.deepEqual(catchUp(withMatches([]), ids(12), SCHEDULES.equal, 1).moves, [], 'empty history');
});

test('catchUp: several players behind each get one block at most, never more than one per match', () => {
  const h = withMatches([full(12, (p) => (p <= 3 ? 0 : 5000))]);
  const { moves } = catchUp(h, ids(12), SCHEDULES.equal, 1);
  const adjust = deltas(moves);
  assert.deepEqual([1, 2, 3].map((p) => adjust[p]), [1, 1, 1]);
  assert.ok(Object.values(adjust).every((d) => d === 1 || d === -1), 'nobody is in two moves');
  assert.equal(moves.length, 3);
});

test('catchUp: a lead that is all Extra minuten is not taken back (rewards stay)', () => {
  const h = withMatches([full(12, (p) => (p === 5 ? 1200 : 1000), { 5: 200 }), full(12, () => 1000)]);
  assert.deepEqual(catchUp(h, ids(12), SCHEDULES.equal, 1).moves, []);
});

test('catchUp: a player who already has an uneven place gets no extra block on top', () => {
  // 11 players, equal schedule: 60 places, base 5, five players get 6. The fewest-seconds players get the uneven places.
  const h = withMatches([full(11, (p) => (p <= 6 ? 0 : 5000))]);
  const { priority, moves } = catchUp(h, ids(11), SCHEDULES.equal, 1);
  const adjust = deltas(moves);
  const uneven = new Set(priority.slice(0, 5));
  for (const p of uneven) assert.notEqual(adjust[p], 1, `player ${p} has an uneven place already`);
});

// The sub rule (#21) and the one-block limit for one catch-up plan.
function assertCatchUpPlan(h, n, start, schedule, seed, label) {
  const { priority, moves } = catchUp(h, ids(n), SCHEDULES[schedule], seed);
  const plan = makePlan({ players: ids(n), start, schedule, seed, extraPriority: priority, moves });
  const plain = makePlan({ players: ids(n), start, schedule, seed, extraPriority: priority });
  assert.ok(maxSubsFrom(plan.grid) <= 3, `${label}: at most 3 subs`);
  const stats = planStats(plan);
  assert.ok(!plan.sitLimitRelaxed && stats.longestBenchSeconds <= 900, `${label}: nobody sits more than 15:00`);
  const plainStats = planStats(plain);
  const stintLimit = Math.max(600, 3 * plan.blockSeconds); // the planner's stint limit (searchGrid)
  if (plainStats.longestStintSeconds <= stintLimit) {
    assert.ok(stats.longestStintSeconds <= stintLimit, `${label}: no longer stint than the plain plan's limit`);
  }
  if (maxSubsFrom(plain.grid) <= 2) assert.ok(maxSubsFrom(plan.grid) <= 2, `${label}: still at most 2 subs`);
  const before = plainStats.minutes;
  for (const p of ids(n)) {
    assert.ok(Math.abs(stats.minutes[p] - before[p]) <= plan.blockSeconds, `${label}: player ${p} moves at most one block`);
  }
  return { plan, plain, moves };
}

test('catch-up plans keep the sub rule for 8 to 12 players, both schedules, random histories and starting fives', () => {
  const random = seededRandom(42);
  for (const schedule of ['equal', 'five']) {
    for (let n = 8; n <= 12; n++) {
      for (let k = 0; k < 10; k++) {
        const h = withMatches([full(n, () => Math.floor(random() * 6) * SCHEDULES[schedule].blockSeconds)]);
        // half the runs start with the five players furthest ahead (the ones who give blocks), half with a random five
        const order = ids(n).sort((a, b) => (k % 2 ? random() - 0.5 : (h.matches[0].seconds[b] - h.matches[0].seconds[a])));
        assertCatchUpPlan(h, n, order.slice(0, 5), schedule, k + 1, `${schedule} ${n} history ${k}`);
      }
    }
  }
});

test('catch-up keeps the stint limit the plain plan keeps (re-review of #40: 8 players, five schedule)', () => {
  const h = normaliseHistory({ matches: [{ id: 'past', seconds: { 1: 3000, 2: 3000, 3: 3000, 4: 3000, 5: 3000 } }] });
  const { plan, plain } = assertCatchUpPlan(h, 8, [1, 2, 3, 4, 5], 'five', 1, '8 players');
  assert.ok(planStats(plain).longestStintSeconds <= 900, 'the plain plan keeps the stint limit');
  assert.ok(planStats(plan).longestStintSeconds <= 900, 'so the catch-up plan does too');
});

test('catch-up takes only the moves that still fit the sit limit (review of #40: all four givers in the starting five)', () => {
  const h = normaliseHistory({ matches: [{ id: 'past', seconds: { 1: 3000, 2: 3000, 3: 3000, 4: 3000 } }] });
  for (let seed = 1; seed <= 5; seed++) {
    const { moves, plan, plain } = assertCatchUpPlan(h, 12, [1, 2, 3, 4, 5], 'five', seed, `seed ${seed}`);
    assert.equal(moves.length, 4, 'catchUp asks for four moves');
    assert.notDeepEqual(plan.grid, plain.grid, `seed ${seed}: at least one move still fits`);
  }
});
