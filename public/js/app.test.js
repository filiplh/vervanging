// The routing of app.js without a DOM: importing app.js outside the browser only defines defaultView.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from './store.js';
import { addPlayer, normaliseRoster } from './setup.js';
import { makePlan } from './planner.js';
import { restoreMatch } from './live.js';
import { wissel } from './match.js';
import { defaultView } from './app.js';

function memoryStore() {
  const data = new Map();
  return createStore({
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => { data.set(k, String(v)); },
    removeItem: (k) => { data.delete(k); },
  });
}

function rosterOf(n) {
  let roster = normaliseRoster(null);
  for (let i = 1; i <= n; i++) roster = addPlayer(roster, { name: `Speler${i}`, number: String(i) });
  return roster;
}

// What "Start" on the setup screen saves, for 8 present players.
function saveSetup(store) {
  const roster = rosterOf(8);
  const ids = roster.players.map((p) => p.id);
  const start = ids.slice(0, 5);
  const plan = makePlan({ players: ids, start, schedule: 'equal', seed: 7 });
  store.save('matchSetup', {
    savedAt: '2026-11-23T10:00:00.000Z', opponent: '', schedule: 'equal', seed: 7,
    players: roster.players, startingFive: start, plan,
  });
  return store.load('matchSetup');
}

test('defaultView: with no match, setup from 5 players and Spelers below, as before', () => {
  const store = memoryStore();
  assert.equal(defaultView(store), 'spelers', 'nothing saved');
  store.save('roster', rosterOf(4));
  assert.equal(defaultView(store), 'spelers', '4 players');
  store.save('roster', rosterOf(5));
  assert.equal(defaultView(store), 'match', '5 players');
  store.save('matchSetup', { damaged: true });
  assert.equal(defaultView(store), 'match', 'a damaged setup resumes nothing');
});

test('defaultView: a running match opens the live screen, started or in play', () => {
  const store = memoryStore();
  store.save('roster', rosterOf(8));
  saveSetup(store);
  assert.equal(defaultView(store), 'start', 'started, no tap yet');
  store.save('match', wissel(restoreMatch(store, store.load('matchSetup'))));
  assert.equal(defaultView(store), 'start', 'saved match in play');
  store.save('roster', rosterOf(3));
  assert.equal(defaultView(store), 'start', 'even when players were removed from the roster since');
});

test('defaultView: an ended match changes nothing', () => {
  const store = memoryStore();
  store.save('roster', rosterOf(8));
  const setup = saveSetup(store);
  let state = restoreMatch(store, setup);
  for (let taps = 0; !state.ended; taps++) {
    assert.ok(taps < 20, 'the match ends');
    state = wissel(state);
  }
  store.save('match', state);
  assert.equal(restoreMatch(store, setup).ended, true, 'the saved match counts as ended');
  assert.equal(defaultView(store), 'match');
  store.save('roster', rosterOf(4));
  assert.equal(defaultView(store), 'spelers');
});
