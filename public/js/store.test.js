import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createStore, keyOf, THINGS } from './store.js';

// In-memory stand-in for localStorage.
function memoryStorage() {
  const data = new Map();
  return {
    data,
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => { data.set(k, String(v)); },
    removeItem: (k) => { data.delete(k); },
  };
}

test('one versioned key per thing', () => {
  assert.equal(keyOf('roster'), 'vervanging.roster.v1');
  assert.equal(keyOf('attendance'), 'vervanging.attendance.v1');
  assert.equal(keyOf('matchSetup'), 'vervanging.matchSetup.v1');
  assert.equal(keyOf('history'), 'vervanging.history.v1');
  assert.equal(keyOf('installTip'), 'vervanging.installTip.v1');
  assert.equal(keyOf('roster', 2), 'vervanging.roster.v2');
  assert.throws(() => keyOf('nope'), /unknown store thing/);
  assert.deepEqual(Object.keys(THINGS).sort(), ['attendance', 'history', 'installTip', 'match', 'matchSetup', 'roster']);
});

test('save then load round-trips through JSON under the versioned key', () => {
  const storage = memoryStorage();
  const store = createStore(storage);
  const roster = { nextId: 2, players: [{ id: 1, name: 'Lien', number: '7' }] };
  assert.equal(store.save('roster', roster), true);
  assert.equal(storage.data.get('vervanging.roster.v1'), JSON.stringify(roster));
  assert.deepEqual(createStore(storage).load('roster'), roster);
});

test('load gives the fallback for a missing value', () => {
  const store = createStore(memoryStorage());
  assert.equal(store.load('roster'), null);
  assert.equal(store.load('attendance', 'fallback'), 'fallback');
});

test('load gives the fallback for corrupted JSON', () => {
  const storage = memoryStorage();
  for (const thing of Object.keys(THINGS)) storage.setItem(keyOf(thing), '{not json');
  const store = createStore(storage);
  for (const thing of Object.keys(THINGS)) assert.equal(store.load(thing, 'fb'), 'fb');
});

test('blocked or failing storage never throws', () => {
  const broken = {
    getItem() { throw new Error('SecurityError'); },
    setItem() { throw new Error('QuotaExceededError'); },
    removeItem() { throw new Error('SecurityError'); },
  };
  const store = createStore(broken);
  assert.equal(store.load('roster', 'fb'), 'fb');
  assert.equal(store.save('roster', { players: [] }), false);
  assert.doesNotThrow(() => store.remove('roster'));
});

test('no storage at all (null) never throws', () => {
  const store = createStore(null);
  assert.equal(store.load('roster', 'fb'), 'fb');
  assert.equal(store.save('roster', {}), false);
  assert.doesNotThrow(() => store.remove('roster'));
});

test('remove deletes the value', () => {
  const storage = memoryStorage();
  const store = createStore(storage);
  store.save('attendance', [1, 2]);
  store.remove('attendance');
  assert.equal(store.load('attendance'), null);
  assert.equal(storage.data.size, 0);
});
