import { test } from 'node:test';
import assert from 'node:assert/strict';
import { makePlan, planStats, maxSubsFrom, blockCounts } from './planner.js';
import {
  startMatch, wissel, undo, canUndo, applyAction, onCourt, nextChange, subTime, quarterOf, minutesSoFar,
  normaliseMatchState, MatchError, MATCH_VERSION, uit, terug, proposedBench, capHolds,
} from './match.js';
import { seededRandom } from './planner.js';

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
    { ...good, version: 3 },
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
    { ...good, previous: { block: 10, ended: false } }, // forward history: undo would jump ahead
    { ...good, previous: { block: 1, ended: false } }, // skipped history: block 4 back to block 1
    { ...good, previous: { block: 4, ended: false } }, // the current block itself
    { ...good, previous: { block: 3, ended: true } }, // an ended point before the last block
    { ...good, block: 1, previous: { block: 1, ended: false } }, // history at block 1, where no wissel happened
  ];
  for (const raw of damaged) assert.equal(normaliseMatchState(raw, plan, 'saved-1'), null, JSON.stringify(raw)?.slice(0, 80));
  assert.equal(normaliseMatchState(good, planFor('equal', 12, 2), 'saved-1'), null, 'another plan');
  assert.deepEqual(normaliseMatchState({ ...good, previous: undefined }, plan, 'saved-1').previous, null);
  // An ended match: its history must be the active last block, never an ended point or another block.
  const done = roundTrip(times(startMatch(plan, 'saved-1'), 12));
  assert.deepEqual(normaliseMatchState(done, plan, 'saved-1'), done);
  for (const previous of [{ block: 12, ended: true }, { block: 11, ended: false }, { block: 5, ended: false }]) {
    assert.equal(normaliseMatchState({ ...done, previous }, plan, 'saved-1'), null, JSON.stringify(previous));
  }
  // The reviewer's reproduction: block 3 (two wissels) with previous block 10 must not restore, so undo never jumps.
  const two = roundTrip(times(startMatch(plan, 'saved-1'), 2));
  assert.deepEqual(normaliseMatchState(two, plan, 'saved-1'), two);
  assert.equal(normaliseMatchState({ ...two, previous: { block: 10, ended: false } }, plan, 'saved-1'), null);
});

// ---------- in the zone, uit and terug (#9) ----------

const totalsAtEnd = (state) => Object.values(minutesSoFar(times(state, state.blocks, wissel)));
const dueOff = (state) => nextChange(state).off;

test('in the zone: the kept player stays on, the proposed bench player stays off, and the block comes back', () => {
  for (const seed of [1, 2, 3, 4, 5]) {
    const plan = planFor('equal', 12, seed);
    const atTwo = wissel(startMatch(plan)); // block 2
    for (const keep of dueOff(atTwo)) {
      const bench = proposedBench(atTwo);
      const next = wissel(atTwo, { keep });
      assert.ok(onCourt(next).includes(keep), 'the zone player is on court in the next block');
      assert.ok(!onCourt(next).includes(bench), 'the proposed incoming player stays on the bench');
      assert.ok(maxSubsFrom(next.grid) <= 3, 'never more than 3 subs per change');
      const end = times(next, 12);
      assert.deepEqual(new Set(Object.values(minutesSoFar(end))), new Set([1000]), `seed ${seed}, keep ${keep}: equal at the end`);
      assert.deepEqual(next.grid.slice(0, 2), atTwo.grid.slice(0, 2), 'blocks already played do not change');
    }
  }
});

test('in the zone: the proposal is the incoming player with the most minutes, ties to the lowest number', () => {
  const state = times(startMatch(planFor('equal')), 3); // block 4
  const minutes = minutesSoFar(state);
  const on = nextChange(state).on;
  const best = Math.max(...on.map((p) => minutes[p]));
  assert.equal(proposedBench(state), Math.min(...on.filter((p) => minutes[p] === best)));
});

test('in the zone with a chosen bench player', () => {
  const state = wissel(startMatch(planFor('equal')));
  const { off, on } = nextChange(state);
  const bench = on.find((p) => p !== proposedBench(state));
  const next = wissel(state, { keep: off[0], bench });
  assert.ok(onCourt(next).includes(off[0]));
  assert.ok(!onCourt(next).includes(bench));
  assert.deepEqual(new Set(totalsAtEnd(next)), new Set([1000]));
});

test('in the zone at the last change: no block left, so the difference stays', () => {
  const state = times(startMatch(planFor('equal')), 10); // block 11
  const keep = dueOff(state)[0];
  const bench = proposedBench(state);
  const end = wissel(wissel(state, { keep }));
  const minutes = minutesSoFar(end);
  assert.equal(minutes[keep], 1200);
  assert.equal(minutes[bench], 800);
  assert.equal(Object.values(minutes).filter((m) => m === 1000).length, 10);
});

test('in the zone is refused for a player not due off, a bench player not due on, and at the last block', () => {
  const state = wissel(startMatch(planFor('equal')));
  const stays = onCourt(state).find((p) => !dueOff(state).includes(p));
  if (stays !== undefined) assert.throws(() => wissel(state, { keep: stays }), MatchError);
  assert.throws(() => wissel(state, { keep: dueOff(state)[0], bench: onCourt(state)[0] }), MatchError);
  assert.throws(() => wissel(times(startMatch(planFor('equal')), 11), { keep: 1 }), MatchError);
});

for (const at of [2, 9]) {
  test(`uit at block ${at}: the player plays no more, the others end at most one block apart`, () => {
    const start = times(startMatch(planFor('equal')), at - 1);
    const player = onCourt(start)[0];
    const out = uit(start, player);
    assert.equal(out.block, at, 'uit does not move to the next block');
    assert.deepEqual(out.grid.slice(0, at), start.grid.slice(0, at), 'played blocks and the current block stay');
    assert.ok(out.grid.slice(at).every((court) => !court.includes(player)));
    assert.ok(maxSubsFrom(out.grid, at - 1) <= 3);
    const end = times(out, 12);
    const minutes = minutesSoFar(end);
    const others = Object.entries(minutes).filter(([p]) => Number(p) !== player).map(([, m]) => m);
    assert.ok(Math.max(...others) - Math.min(...others) <= 200, others.join(' '));
    assert.equal(minutes[player], blockCounts(start.grid.slice(0, at), start.players)[player] * 200);
  });
}

test('terug: the player is back from the next block on and catches up', () => {
  const start = times(startMatch(planFor('equal')), 2); // block 3
  const player = onCourt(start)[0];
  const out = times(uit(start, player), 3); // block 6
  const back = terug(out, player);
  assert.deepEqual(back.out, []);
  assert.ok(back.grid.slice(6).some((court) => court.includes(player)), 'plays again in a later block');
  assert.ok(maxSubsFrom(back.grid, 5) <= 3);
  const minutes = minutesSoFar(times(back, 12));
  assert.ok(Math.max(...Object.values(minutes)) - Math.min(...Object.values(minutes)) <= 400, Object.values(minutes).join(' '));
});

test('uit and terug are refused where they cannot apply', () => {
  const state = startMatch(planFor('equal', 6));
  assert.throws(() => uit(uit(state, 1), 2), MatchError, 'fewer than 5 available');
  assert.throws(() => uit(uit(startMatch(planFor('equal')), 1), 1), MatchError, 'already out');
  assert.throws(() => terug(startMatch(planFor('equal')), 1), MatchError, 'not out');
  assert.throws(() => uit(times(startMatch(planFor('equal')), 11), 1), MatchError, 'last block');
  assert.throws(() => uit(startMatch(planFor('equal')), 13), MatchError, 'not in the match');
});

test('undo puts back exactly one step after in the zone, uit and terug', () => {
  const base = wissel(startMatch(planFor('equal')));
  const zone = wissel(base, { keep: dueOff(base)[0] });
  assert.deepEqual({ ...undo(zone), previous: null }, { ...base, previous: null });
  const out = uit(base, onCourt(base)[0]);
  assert.deepEqual({ ...undo(out), previous: null }, { ...base, previous: null });
  const back = terug(out, onCourt(base)[0]);
  const undone = undo(back);
  assert.deepEqual(undone.out, out.out);
  assert.deepEqual(undone.grid, out.grid);
  assert.equal(canUndo(undone), false, 'one step only');
});

test('the runner actions: wissel with keep and bench, uit and terug', () => {
  const state = wissel(startMatch(planFor('equal')));
  const keep = dueOff(state)[0];
  assert.deepEqual(applyAction(state, { type: 'wissel', keep }), wissel(state, { keep }));
  assert.deepEqual(applyAction(state, { type: 'uit', player: 1 }), uit(state, 1));
  assert.throws(() => applyAction(state, { type: 'swap' }), MatchError);
});

test('saved states after in the zone and uit round-trip and restore; a version 1 save still loads', () => {
  const plan = planFor('equal');
  const zone = wissel(wissel(startMatch(plan, 's')), { keep: dueOff(wissel(startMatch(plan, 's')))[0] });
  assert.deepEqual(normaliseMatchState(roundTrip(zone), plan, 's'), zone);
  const out = uit(zone, onCourt(zone)[0]);
  assert.deepEqual(normaliseMatchState(roundTrip(out), plan, 's'), out);
  // Damaged: someone who is out plays later; the first block changed; history whose played blocks differ.
  const bad = roundTrip(out);
  bad.grid[11] = [...bad.out, ...bad.grid[11].filter((p) => !bad.out.includes(p))].slice(0, 5);
  assert.equal(normaliseMatchState(bad, plan, 's'), null);
  const history = roundTrip(out);
  history.previous.grid[0] = [1, 2, 3, 4, 6];
  assert.equal(normaliseMatchState(history, plan, 's'), null);
  // Version 1 (before #9): no live grid of its own, no one out, history without a grid.
  const v1 = { version: 1, setupSavedAt: 's', schedule: plan.schedule, blocks: plan.blocks, blockSeconds: plan.blockSeconds,
    blocksPerQuarter: plan.blocksPerQuarter, players: plan.players, grid: plan.grid, block: 4, ended: false,
    previous: { block: 3, ended: false } };
  const restored = normaliseMatchState(roundTrip(v1), plan, 's');
  assert.equal(restored.version, MATCH_VERSION);
  assert.equal(restored.block, 4);
  assert.deepEqual(restored.out, []);
  assert.equal(undo(restored).block, 3);
});

test('uit is never refused for planning reasons: one or two players out at any block, any count from 8 to 12', () => {
  for (const schedule of ['equal', 'five']) {
    for (let n = 8; n <= 12; n++) {
      for (const seed of [1, 2, 3, 10]) {
        const plan = planFor(schedule, n, seed);
        for (let at = 1; at < plan.blocks; at++) {
          let state = times(startMatch(plan), at - 1);
          state = uit(state, 1);
          state = uit(state, 6);
          assert.ok(maxSubsFrom(state.grid, at - 1) <= 3, `${schedule} ${n} seed ${seed} block ${at}`);
          assert.ok(state.grid.slice(at).every((court) => !court.includes(1) && !court.includes(6)));
        }
      }
    }
  }
});

test('in the zone at the second-to-last change keeps the cap of 3 (repair when no replan fits)', () => {
  for (const schedule of ['equal', 'five']) {
    for (let n = 8; n <= 12; n++) {
      for (let seed = 1; seed <= 30; seed++) {
        const plan = planFor(schedule, n, seed);
        const state = times(startMatch(plan), plan.blocks - 3); // the change into the second-to-last block
        for (const keep of nextChange(state).off) {
          const next = wissel(state, { keep });
          assert.ok(maxSubsFrom(next.grid, state.block - 1) <= 3, `${schedule} ${n} seed ${seed} keep ${keep}`);
        }
      }
    }
  }
});

// ---------- review of PR #19: mixed actions ----------

test('F1: a player marked uit cannot be kept on in the zone', () => {
  const plan = planFor('equal');
  const out = uit(startMatch(plan), 1);
  assert.ok(nextChange(out).off.includes(1), 'the out player is due off');
  assert.throws(() => wissel(out, { keep: 1 }), MatchError);
});

test('F2: four players uit at once: the next change takes all four off, the only case above 3 subs', () => {
  const plan = planFor('equal');
  let state = startMatch(plan);
  for (const p of [1, 2, 3, 4]) state = uit(state, p);
  const subs = state.grid[1].filter((p) => !state.grid[0].includes(p)).length;
  assert.equal(subs, 4, 'four forced departures need four subs');
  assert.ok(state.grid.slice(1).every((court) => [1, 2, 3, 4].every((p) => !court.includes(p))));
  assert.ok(capHolds(state.grid, 0, state.out), 'allowed: every sub above 3 is a forced departure');
  assert.ok(maxSubsFrom(state.grid, 1) <= 3, 'all later changes keep 3');
});

test('F3: damaged version 2 plans and undo snapshots are refused', () => {
  const plan = planFor('equal');
  const fiveSubs = roundTrip(startMatch(plan, 's'));
  fiveSubs.grid[1] = [6, 7, 8, 9, 10];
  assert.equal(normaliseMatchState(fiveSubs, plan, 's'), null, 'a five-sub change with nobody out');
  const badHistory = roundTrip(wissel(startMatch(plan, 's')));
  badHistory.previous.out = [1];
  assert.equal(normaliseMatchState(badHistory, plan, 's'), null, 'undo would bring back an out player still planned');
});

test('random mixed sequences: the sub rule, nobody out playing, one-step undo and save/restore always hold', () => {
  let cases = 0;
  for (const schedule of ['equal', 'five']) {
    for (let n = 8; n <= 12; n++) {
      for (let seed = 1; seed <= 6; seed++) {
        const plan = planFor(schedule, n, seed);
        const random = seededRandom(seed * 97 + n);
        let state = startMatch(plan, 's');
        while (!state.ended) {
          const before = state;
          const x = random();
          try {
            const change = nextChange(state);
            const keepable = change ? change.off.filter((p) => !state.out.includes(p)) : [];
            if (x < 0.2 && keepable.length) state = wissel(state, { keep: keepable[0] });
            else if (x < 0.35) {
              const pool = state.players.filter((p) => !state.out.includes(p));
              state = uit(state, pool[Math.floor(random() * pool.length)]);
            } else if (x < 0.45 && state.out.length) state = terug(state, state.out[0]);
            else if (x < 0.5) state = undo(state);
            else state = wissel(state);
          } catch (error) {
            if (!(error instanceof MatchError)) throw error;
            assert.match(error.message, /last block|at least 5|no change left/, error.message);
            state = wissel(state);
          }
          cases += 1;
          assert.ok(capHolds(state.grid, state.block - 1, state.out), `${schedule} ${n} seed ${seed} block ${state.block}`);
          assert.ok(state.grid.slice(state.block).every((court) => court.every((p) => !state.out.includes(p))));
          assert.deepEqual(state.grid.slice(0, Math.min(before.block, state.block) - 1), before.grid.slice(0, Math.min(before.block, state.block) - 1), 'played blocks never change');
          assert.deepEqual(normaliseMatchState(roundTrip(state), plan, 's'), state, 'every state saves and restores');
          if (state.previous) assert.equal(canUndo(undo(state)), false);
        }
      }
    }
  }
  assert.ok(cases > 500);
});
