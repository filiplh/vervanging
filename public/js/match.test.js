import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makePlan, planStats } from './planner.js';
import {
  startMatch, wissel, undo, canUndo, applyAction, onCourt, nextChange, subTime, quarterOf, minutesSoFar,
  normaliseMatchState, MatchError, MATCH_VERSION,
} from './match.js';

const players = (n) => Array.from({ length: n }, (_, i) => i + 1);
const planFor = (schedule, n = 12, seed = 1) => makePlan({ players: players(n), start: [1, 2, 3, 4, 5], schedule, seed });
const times = (state, n, fn = wissel) => { for (let i = 0; i < n; i++) state = fn(state); return state; };
const roundTrip = (state) => JSON.parse(JSON.stringify(state));

test('a new match is at block 1 with the basisvijf on court and nothing to undo', () => {
  const state = startMatch(planFor('equal'), 'saved-1');
  assert.equal(state.version, MATCH_VERSION);
  assert.equal(state.block, 1);
  assert.equal(state.ended, false);
  assert.equal(canUndo(state), false);
  assert.equal(state.setupSavedAt, 'saved-1');
  assert.deepEqual(onCourt(state), [1, 2, 3, 4, 5]);
  assert.deepEqual(minutesSoFar(state), { 1: 200, 2: 200, 3: 200, 4: 200, 5: 200, 6: 0, 7: 0, 8: 0, 9: 0, 10: 0, 11: 0, 12: 0 });
});

for (const [schedule, blocks, blockSeconds, clocks] of [
  ['equal', 12, 200, ['6:40', '3:20', 'endQuarter']],
  ['five', 8, 300, ['5:00', 'endQuarter']],
]) {
  test(`wissel through a whole match (${schedule})`, () => {
    const plan = planFor(schedule, 9);
    let state = startMatch(plan);
    const seen = [];
    for (let b = 1; b <= blocks; b++) {
      assert.equal(state.block, b);
      assert.equal(state.ended, false);
      assert.deepEqual(onCourt(state), plan.grid[b - 1]);
      assert.equal(quarterOf(state), Math.ceil(b / plan.blocksPerQuarter));
      const time = subTime(state);
      seen.push(time.kind === 'sub' ? `${Math.floor(time.clockSeconds / 60)}:${String(time.clockSeconds % 60).padStart(2, '0')}` : time.kind);
      // Minutes so far: the blocks started, the current one included.
      const sofar = planStats({ ...plan, grid: plan.grid.slice(0, b) }).minutes;
      assert.deepEqual(minutesSoFar(state), Object.fromEntries(Object.entries(sofar).map(([k, v]) => [k, v])));
      const change = nextChange(state);
      if (b < blocks) {
        assert.deepEqual(change.off, plan.grid[b - 1].filter((p) => !plan.grid[b].includes(p)));
        assert.deepEqual(change.on, plan.grid[b].filter((p) => !plan.grid[b - 1].includes(p)));
      } else {
        assert.equal(change, null);
      }
      state = wissel(state);
      assert.equal(canUndo(state), true);
    }
    assert.equal(state.ended, true);
    assert.equal(state.block, blocks);
    // Each quarter repeats the pattern; the very last block says einde match.
    const quarters = blocks / plan.blocksPerQuarter;
    const expected = Array.from({ length: quarters }, () => clocks).flat();
    expected[expected.length - 1] = 'endMatch';
    assert.deepEqual(seen, expected);
    assert.deepEqual(minutesSoFar(state), planStats(plan).minutes);
    assert.equal(Object.values(minutesSoFar(state)).reduce((a, b) => a + b, 0), 5 * blocks * blockSeconds);
    // A wissel after the end changes nothing.
    assert.equal(wissel(state), state);
  });
}

test('undo after a wissel goes back one block, one step only', () => {
  const start = startMatch(planFor('equal'));
  const two = times(start, 2);
  const back = undo(two);
  assert.equal(back.block, 2);
  assert.equal(back.ended, false);
  assert.equal(canUndo(back), false);
  assert.equal(undo(back), back, 'a second undo changes nothing');
  assert.deepEqual(minutesSoFar(back), minutesSoFar(times(start, 1)));
  assert.equal(wissel(back).block, 3, 'play goes on after an undo');
});

test('undo after the match ended reopens the last block', () => {
  const done = times(startMatch(planFor('five')), 8);
  assert.equal(done.ended, true);
  const back = undo(done);
  assert.equal(back.ended, false);
  assert.equal(back.block, 8);
  assert.equal(subTime(back).kind, 'endMatch');
  assert.equal(wissel(back).ended, true);
});

test('undo with nothing to undo changes nothing', () => {
  const state = startMatch(planFor('equal'));
  assert.equal(undo(state), state);
  assert.equal(undo(state).block, 1);
  assert.deepEqual(onCourt(undo(state)), [1, 2, 3, 4, 5]);
});

test('applyAction runs wissel and undo, and refuses anything else', () => {
  const state = startMatch(planFor('equal'));
  assert.equal(applyAction(state, 'wissel').block, 2);
  assert.equal(applyAction(applyAction(state, 'wissel'), 'undo').block, 1);
  assert.throws(() => applyAction(state, 'skip'), MatchError);
});

test('the state is plain JSON and comes back exactly, at any block', () => {
  const plan = planFor('equal');
  let state = startMatch(plan, 'saved-1');
  for (let i = 0; i <= 12; i++) {
    const copy = roundTrip(state);
    assert.deepEqual(copy, state);
    const restored = normaliseMatchState(copy, plan, 'saved-1');
    assert.deepEqual(restored, state);
    assert.deepEqual(minutesSoFar(restored), minutesSoFar(state));
    state = wissel(state);
  }
  // After an undo, the restored state cannot undo again either.
  const undone = undo(times(startMatch(plan, 'saved-1'), 4));
  assert.deepEqual(normaliseMatchState(roundTrip(undone), plan, 'saved-1'), undone);
});

test('normaliseMatchState refuses damaged states and states of another setup', () => {
  const plan = planFor('equal');
  const good = roundTrip(times(startMatch(plan, 'saved-1'), 3));
  const damaged = [
    null, 7, 'x', [], {},
    { ...good, version: 2 },
    { ...good, setupSavedAt: 'saved-2' },
    { ...good, schedule: 'five' },
    { ...good, blockSeconds: 300 },
    { ...good, grid: good.grid.slice(1) },
    { ...good, grid: [[1, 2, 3, 4, 6], ...good.grid.slice(1)] },
    { ...good, players: [1, 2, 3] },
    { ...good, block: 0 },
    { ...good, block: 13 },
    { ...good, block: 2.5 },
    { ...good, block: '3' },
    { ...good, ended: 'no' },
    { ...good, ended: true }, // ended before the last block
    { ...good, previous: { block: 99, ended: false } },
    { ...good, previous: 'x' },
  ];
  for (const raw of damaged) assert.equal(normaliseMatchState(raw, plan, 'saved-1'), null, JSON.stringify(raw)?.slice(0, 80));
  assert.equal(normaliseMatchState(good, planFor('equal', 12, 2), 'saved-1'), null, 'another plan');
  assert.deepEqual(normaliseMatchState({ ...good, previous: undefined }, plan, 'saved-1').previous, null);
});
