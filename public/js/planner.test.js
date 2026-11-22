import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  makePlan, swapPlayers, planStats, blockTargets, seededRandom, PlanError, SCHEDULES, evenTargets, replanRemaining,
  blockCounts, maxSubsFrom, repairRemaining,
} from './planner.js';

const range = (n) => Array.from({ length: n }, (_, i) => i + 1);
const STARTS = [[1, 2, 3, 4, 5], [3, 5, 7, 8, 2], [4, 5, 6, 7, 8]];

// Plan assumption A3: a plan that meets decision #21 exists for 8 to 12 players, both schedules, any starting five.
for (const schedule of Object.keys(SCHEDULES)) {
  for (let n = 8; n <= 12; n++) {
    for (const start of STARTS) {
      test(`${schedule} schedule, ${n} players, start ${start.join(',')}`, () => {
        const plan = makePlan({ players: range(n), start, schedule, seed: 7 });
        const stats = planStats(plan);
        const { blocks, blockSeconds } = SCHEDULES[schedule];

        assert.equal(plan.grid.length, blocks);
        assert.deepEqual(plan.grid[0], start.slice().sort((a, b) => a - b));
        for (const court of plan.grid) assert.equal(new Set(court).size, 5);

        const minutes = Object.values(stats.minutes);
        assert.equal(minutes.reduce((a, b) => a + b, 0), 5 * blocks * blockSeconds);
        assert.ok(Math.max(...minutes) - Math.min(...minutes) <= blockSeconds, 'shares differ by at most one block');

        assert.ok(Math.max(...stats.subsPerChange) <= 3, 'never more than 3 subs per change');
        assert.equal(plan.sitLimitRelaxed, false, 'no case from 8 to 12 players needs the sit limit relaxed');
        assert.ok(stats.longestBenchSeconds <= 900, 'nobody sits more than 15:00 in a row');
        if (schedule === 'equal' && n === 12) {
          assert.ok(stats.subsPerChange.every((k) => k === 2), 'equal minutes with 12 players: 2 subs at every change');
          assert.ok(minutes.every((m) => m === 1000), 'equal minutes with 12 players: 16:40 each');
        }
      });
    }
  }
}

test('the 5-minute schedule with 12 players gives four players an extra block', () => {
  const stats = planStats(makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'five', seed: 3 }));
  const minutes = Object.values(stats.minutes);
  assert.equal(minutes.filter((m) => m === 1200).length, 4);
  assert.equal(minutes.filter((m) => m === 900).length, 8);
});

test('the same seed gives the same plan', () => {
  const a = makePlan({ players: range(11), start: [1, 2, 3, 4, 5], schedule: 'five', seed: 5 });
  const b = makePlan({ players: range(11), start: [1, 2, 3, 4, 5], schedule: 'five', seed: 5 });
  assert.deepEqual(a.grid, b.grid);
});

test('extra blocks go to the players named in extraPriority first', () => {
  const targets = blockTargets(range(12), 40, seededRandom(1), [9, 10, 11, 12]);
  assert.deepEqual([9, 10, 11, 12].map((p) => targets[p]), [4, 4, 4, 4]);
  assert.equal(Object.values(targets).filter((t) => t === 4).length, 4);
});

test('swapping two bench players exchanges their rows and keeps the totals', () => {
  const plan = makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 1 });
  const swapped = swapPlayers(plan, 6, 7);
  plan.grid.forEach((court, i) => {
    const expected = court.map((p) => (p === 6 ? 7 : p === 7 ? 6 : p)).sort((a, b) => a - b);
    assert.deepEqual(swapped.grid[i], expected);
  });
  assert.deepEqual(planStats(swapped).subsPerChange, planStats(plan).subsPerChange);
});

test('a swap between a starter and a bench player is refused', () => {
  const plan = makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 1 });
  assert.throws(() => swapPlayers(plan, 1, 6), PlanError);
  assert.throws(() => swapPlayers(plan, 6, 6), PlanError);
  assert.throws(() => swapPlayers(plan, 6, 13), PlanError);
});

test('invalid input is refused with a PlanError', () => {
  assert.throws(() => makePlan({ players: range(12), start: [1, 2, 3, 4], schedule: 'equal' }), /starting five/);
  assert.throws(() => makePlan({ players: range(12), start: [1, 1, 2, 3, 4], schedule: 'equal' }), /starting five/);
  assert.throws(() => makePlan({ players: range(12), start: [1, 2, 3, 4, 13], schedule: 'equal' }), /not present/);
  assert.throws(() => makePlan({ players: range(4), start: [1, 2, 3, 4, 5], schedule: 'equal' }), /at least 5/);
  assert.throws(() => makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'six' }), /unknown schedule/);
});

test('exactly five players: everyone plays every block', () => {
  const stats = planStats(makePlan({ players: range(5), start: [1, 2, 3, 4, 5], schedule: 'equal' }));
  assert.ok(Object.values(stats.minutes).every((m) => m === 2400));
  assert.ok(stats.subsPerChange.every((k) => k === 0));
});

// Above the plan's 8-12 range, the 5-minute schedule cannot keep sits at 15:00 under the cap of 3: the planner
// relaxes the sit limit (never the cap) and says so.
test('13 players in the 5-minute schedule: the sit limit is relaxed, the sub cap is not', () => {
  const plan = makePlan({ players: range(13), start: [1, 2, 3, 4, 5], schedule: 'five', seed: 1 });
  assert.equal(plan.sitLimitRelaxed, true);
  assert.ok(Math.max(...planStats(plan).subsPerChange) <= 3);
});

test('evenTargets gives the places left to the fewest blocks first, nothing to players who are out', () => {
  const plan = makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 1 });
  const available = range(12).filter((p) => p !== 1);
  const targets = evenTargets({ grid: plan.grid, players: plan.players, available, fromBlock: 4 });
  const played = blockCounts(plan.grid.slice(0, 4), plan.players);
  assert.equal(targets[1], played[1], 'an out player gets no more blocks');
  const others = available.map((p) => targets[p]);
  assert.ok(Math.max(...others) - Math.min(...others) <= 1);
  assert.equal(Object.values(targets).reduce((a, b) => a + b, 0), 60);
});

test('replanRemaining keeps the fixed blocks, meets the targets and the cap of 3', () => {
  const plan = makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 2 });
  const available = range(12).filter((p) => p !== 3);
  const targets = evenTargets({ grid: plan.grid, players: plan.players, available, fromBlock: 5 });
  const grid = replanRemaining({ grid: plan.grid, players: plan.players, available, fromBlock: 5, targets, blockSeconds: 200 });
  assert.deepEqual(grid.slice(0, 5), plan.grid.slice(0, 5));
  assert.deepEqual(blockCounts(grid, plan.players), targets);
  assert.ok(grid.slice(5).every((court) => !court.includes(3)));
  assert.ok(maxSubsFrom(grid, 4) <= 3);
  assert.throws(() => replanRemaining({ grid: plan.grid, players: plan.players, available: [1, 2, 3, 4], fromBlock: 5, targets, blockSeconds: 200 }), PlanError);
});

test('repairRemaining holds the cap and drops players who are not available, whatever the plan', () => {
  const plan = makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 4 });
  const available = range(12).filter((p) => p !== 2 && p !== 7);
  const grid = repairRemaining({ grid: plan.grid, players: plan.players, available, fromBlock: 3 });
  assert.deepEqual(grid.slice(0, 3), plan.grid.slice(0, 3));
  assert.ok(grid.slice(3).every((court) => court.length === 5 && !court.includes(2) && !court.includes(7)));
  assert.ok(maxSubsFrom(grid, 2) <= 3);
  assert.throws(() => repairRemaining({ grid: plan.grid, players: plan.players, available: [1, 2, 3, 4], fromBlock: 3 }), PlanError);
});

test('makePlan moves: each [to, from] pair moves one block; a bad list is refused with PlanError', () => {
  const plan = makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 1, moves: [[12, 6]] });
  const minutes = planStats(plan).minutes;
  assert.equal(minutes[12], 1200);
  assert.equal(minutes[6], 800);
  const bad = [null, 3, 'x', {}, { 12: 1, 6: -1 }, [[12]], [[12, 6, 7]], [12, 6], [[12, 12]], [[12, 6], [12, 7]], [[12, 6], [11, 6]],
    [['12', 6]], [[1.5, 6]], [[13, 6]], [[12, 0]]];
  for (const moves of bad) {
    assert.throws(() => makePlan({ players: range(12), start: [1, 2, 3, 4, 5], schedule: 'equal', moves }), PlanError, JSON.stringify(moves));
  }
});
