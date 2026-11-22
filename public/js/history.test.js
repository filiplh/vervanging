import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { makePlan, planStats } from './planner.js';
import {
  emptyHistory, normaliseHistory, recordMatch, forgetMatch, hasMatch, clearHistory, totalSeconds, extraPriority,
  startedAfterClear,
} from './history.js';

const ids = (n) => Array.from({ length: n }, (_, i) => i + 1);
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
