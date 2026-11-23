import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createStore } from './store.js';
import { makePlan } from './planner.js';
import { startMatch, wissel, minutesSoFar } from './match.js';
import { liveScreen, subTimeText, planOf, restoreMatch, syncHistory, createWakeLock } from './live.js';

// ---------- test doubles: in-memory localStorage and a minimal DOM (no dependency) ----------

function memoryStore() {
  const data = new Map();
  const store = createStore({
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => { data.set(k, String(v)); },
    removeItem: (k) => { data.delete(k); },
  });
  return { store, data };
}

class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.attrs = {};
    this.listeners = {};
    this.className = '';
    this.disabled = false;
  }

  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }

  setAttribute(key, value) { this.attrs[key] = value; }

  append(...nodes) { for (const n of nodes) this.children.push(typeof n === 'string' ? { text: n } : n); }

  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }

  get text() { return this.children.map((c) => (c instanceof FakeElement ? c.text : c.text)).join(''); }

  all() { return [this, ...this.children.filter((c) => c instanceof FakeElement).flatMap((c) => c.all())]; }

  fire(type) { for (const fn of this.listeners[type] || []) fn({ preventDefault() {}, currentTarget: this, target: this }); }
}

beforeEach(() => {
  globalThis.document = { createElement: (tag) => new FakeElement(tag) };
});

const find = (root, tag, pred = () => true) => root.all().filter((e) => e.tag === tag && pred(e));
const button = (root, label) => find(root, 'button', (e) => e.text === label)[0];
const wisselButton = (root) => find(root, 'button', (e) => e.className.split(' ').includes('wissel'))[0];
const listOf = (root, className) => find(root, 'ul', (e) => e.className.split(' ').includes(className))[0];
const numbers = (ul) => (ul ? find(ul, 'li').map((li) => Number(find(li, 'span', (s) => s.className === 'number')[0].text.slice(1))) : []);
const minuteRows = (root) => find(root, 'table', (e) => e.className === 'minutes')
  .flatMap((t) => find(t, 'tbody')[0].children)
  .map((tr) => ({ number: Number(find(tr, 'span', (s) => s.className === 'number')[0].text.slice(1)), minutes: tr.children[1].text }));

// Players with id = number, so the screen's numbers can be compared with the plan's ids.
function setupOf({ n = 8, schedule = 'equal', savedAt = '2026-11-22T10:00:00.000Z' } = {}) {
  const players = Array.from({ length: n }, (_, i) => ({ id: i + 1, name: `Speler${i + 1}`, number: String(i + 1) }));
  const ids = players.map((p) => p.id);
  const plan = makePlan({ players: ids, start: [1, 2, 3, 4, 5], schedule, seed: 3 });
  return { savedAt, opponent: 'BC Test', schedule, seed: 3, players, startingFive: [1, 2, 3, 4, 5], plan };
}

function open(setup = setupOf(), env = memoryStore()) {
  env.store.save('matchSetup', setup);
  const view = new FakeElement('main');
  liveScreen(view, { store: env.store });
  return { ...env, view, setup, reload() { const v = new FakeElement('main'); liveScreen(v, { store: env.store }); return v; } };
}

const h1 = (view) => find(view, 'h1')[0].text;
const subLine = (view) => find(view, 'p', (e) => e.className === 'sub-time')[0]?.text;

test('subTimeText: wissel op m:ss inside a quarter, einde kwart, einde match', () => {
  let state = startMatch(planOf(setupOf()));
  const lines = [];
  for (let b = 0; b < 12; b++) { lines.push(subTimeText(state)); state = wissel(state); }
  assert.deepEqual(lines, [
    'Wissel op 6:40', 'Wissel op 3:20', 'Einde kwart', 'Wissel op 6:40', 'Wissel op 3:20', 'Einde kwart',
    'Wissel op 6:40', 'Wissel op 3:20', 'Einde kwart', 'Wissel op 6:40', 'Wissel op 3:20', 'Einde match',
  ]);
  state = startMatch(planOf(setupOf({ schedule: 'five' })));
  const five = [];
  for (let b = 0; b < 8; b++) { five.push(subTimeText(state)); state = wissel(state); }
  assert.deepEqual(five, ['Wissel op 5:00', 'Einde kwart', 'Wissel op 5:00', 'Einde kwart', 'Wissel op 5:00', 'Einde kwart', 'Wissel op 5:00', 'Einde match']);
});

test('live screen: block, sub time, on court, off and on next, Wissel, Ongedaan maken and minutes', () => {
  const { view, setup } = open();
  const { grid } = setup.plan;
  assert.match(h1(view), /^Blok 1 van 12/);
  assert.equal(subLine(view), 'Wissel op 6:40');
  assert.deepEqual(numbers(listOf(view, 'court')), grid[0]);
  assert.deepEqual(numbers(listOf(view, 'off')), grid[0].filter((p) => !grid[1].includes(p)));
  assert.deepEqual(numbers(listOf(view, 'on')), grid[1].filter((p) => !grid[0].includes(p)));
  assert.ok(wisselButton(view));
  assert.equal(button(view, 'Ongedaan maken').disabled, true, 'nothing to undo yet');
  const rows = minuteRows(view);
  assert.equal(rows.length, 8);
  for (const r of rows) assert.equal(r.minutes, grid[0].includes(r.number) ? '3:20' : '0:00');
});

test('live screen: one tap per wissel moves one block, saves, and undo goes back', () => {
  const { view, data, setup } = open();
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 2 van 12/);
  assert.equal(subLine(view), 'Wissel op 3:20');
  assert.deepEqual(numbers(listOf(view, 'court')), setup.plan.grid[1]);
  assert.equal(JSON.parse(data.get('vervanging.match.v1')).block, 2, 'saved after the tap');
  wisselButton(view).fire('click');
  assert.equal(subLine(view), 'Einde kwart');
  button(view, 'Ongedaan maken').fire('click');
  assert.match(h1(view), /^Blok 2 van 12/);
  assert.equal(button(view, 'Ongedaan maken').disabled, true, 'one step only');
  assert.equal(JSON.parse(data.get('vervanging.match.v1')).block, 2, 'the undo is saved too');
});

test('live screen: a reload at any block comes back on the same block with the same minutes', () => {
  const env = open();
  let view = env.view;
  for (let b = 1; b <= 12; b++) {
    const before = { title: h1(view), minutes: minuteRows(view), court: numbers(listOf(view, 'court')), undo: button(view, 'Ongedaan maken').disabled };
    view = env.reload();
    assert.deepEqual({ title: h1(view), minutes: minuteRows(view), court: numbers(listOf(view, 'court')), undo: button(view, 'Ongedaan maken').disabled }, before, `block ${b}`);
    wisselButton(view).fire('click');
  }
  assert.equal(h1(env.reload()), 'Einde match', 'the ended match is restored as ended');
});

test('end-of-match screen lists every present player with minutes as m:ss, and undo reopens the last block', () => {
  const env = open(setupOf({ n: 9, schedule: 'five' }));
  for (let i = 0; i < 8; i++) wisselButton(env.view).fire('click');
  const { view } = env;
  assert.equal(h1(view), 'Einde match');
  const rows = minuteRows(view);
  assert.deepEqual(rows.map((r) => r.number), [1, 2, 3, 4, 5, 6, 7, 8, 9]);
  assert.ok(rows.every((r) => /^\d+:\d\d$/.test(r.minutes)), rows.map((r) => r.minutes).join(' '));
  const total = rows.reduce((s, r) => { const [m, sec] = r.minutes.split(':').map(Number); return s + m * 60 + sec; }, 0);
  assert.equal(total, 5 * 8 * 300, 'all 40 minutes × 5 places are given out');
  assert.equal(find(view, 'a', (a) => a.attrs.href === '#match').length, 1, 'a way to a new match');
  button(view, 'Ongedaan maken').fire('click');
  assert.match(h1(view), /^Blok 8 van 8/);
  assert.equal(subLine(view), 'Einde match');
});

test('live screen: a refused write shows a Dutch message and the tap still counts on screen', () => {
  const env = open();
  const data = new Map(env.data);
  const store = createStore({ getItem: (k) => data.get(k) ?? null, setItem() { throw new Error('full'); }, removeItem() {} });
  const view = new FakeElement('main');
  liveScreen(view, { store });
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 2/);
  assert.ok(find(view, 'p', (p) => /Opslaan lukte niet/.test(p.text)).length);
});

test('live screen: a saved state of another setup or a damaged one starts at block 1', () => {
  const setup = setupOf();
  const old = wissel(wissel(startMatch(planOf(setup), 'an older setup')));
  for (const raw of [old, { block: 5 }, '{not json']) {
    const env = memoryStore();
    if (raw === '{not json') env.data.set('vervanging.match.v1', raw);
    else env.store.save('match', raw);
    const { view } = open(setup, env);
    assert.match(h1(view), /^Blok 1 van 12/);
  }
  const env = memoryStore();
  assert.equal(restoreMatch(env.store, { ...setup, plan: { ...setup.plan, blockSeconds: 'x' } }).blockSeconds, 200,
    'the block length comes from the schema, never from the saved plan');
});

test('live screen: a damaged saved setup shows a Dutch fallback instead of crashing', () => {
  for (const damaged of [{ players: [null], startingFive: [1] }, { players: [], startingFive: 'x' }, '{not json', null]) {
    const { store, data } = memoryStore();
    if (damaged === '{not json') data.set('vervanging.matchSetup.v1', damaged);
    else if (damaged !== null) store.save('matchSetup', damaged);
    const view = new FakeElement('main');
    assert.doesNotThrow(() => liveScreen(view, { store }));
    assert.match(h1(view), /Geen match gevonden/);
    assert.equal(find(view, 'a')[0].attrs.href, '#match');
  }
});

// ---------- in the zone, uit and terug, Einde match (#9) ----------

const chips = (root, label) => find(root, 'button', (e) => e.className.split(' ').includes('chip') && e.text === label);

test('live screen: In the zone on a player due off proposes a bench player, which the coach can change', () => {
  const { view, setup } = open();
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  const on = grid[1].filter((p) => !grid[0].includes(p));
  assert.equal(chips(view, 'In the zone').length, off.length, 'one In the zone button per player due off');
  assert.equal(chips(view, 'Op de bank').length, 0, 'no bench choice before In the zone');
  chips(view, 'In the zone')[0].fire('click');
  assert.equal(chips(view, 'In the zone')[0].attrs['aria-pressed'], 'true');
  const bench = chips(view, 'Op de bank');
  assert.equal(bench.length, on.length);
  assert.equal(bench.filter((b) => b.attrs['aria-pressed'] === 'true').length, 1, 'one proposed bench player');
  const other = bench.findIndex((b) => b.attrs['aria-pressed'] !== 'true');
  if (other >= 0) {
    bench[other].fire('click');
    assert.equal(chips(view, 'Op de bank')[other].attrs['aria-pressed'], 'true', 'the coach changed the bench player');
  }
  const kept = off[0];
  wisselButton(view).fire('click');
  assert.ok(numbers(listOf(view, 'court')).includes(kept), 'the zone player stays on court');
  button(view, 'Ongedaan maken').fire('click');
  assert.match(h1(view), /^Blok 1 van 12/);
});

test('live screen: Uit and Terug per player in the minutes table, both undoable', () => {
  const { view, data } = open();
  const uitButtons = chips(view, 'Uit');
  assert.equal(uitButtons.length, 8);
  uitButtons[0].fire('click');
  assert.equal(chips(view, 'Terug').length, 1);
  const saved = JSON.parse(data.get('vervanging.match.v1'));
  assert.deepEqual(saved.out, [1]);
  assert.match(h1(view), /^Blok 1 van 12/, 'uit does not move to the next block');
  chips(view, 'Terug')[0].fire('click');
  assert.deepEqual(JSON.parse(data.get('vervanging.match.v1')).out, []);
  button(view, 'Ongedaan maken').fire('click');
  assert.equal(chips(view, 'Terug').length, 1, 'undo of terug puts the player back out');
});

test('live screen: the button reads Einde match at the last block', () => {
  const { view } = open();
  for (let b = 1; b < 12; b++) {
    assert.equal(wisselButton(view).text, 'Wissel', `block ${b}`);
    wisselButton(view).fire('click');
  }
  assert.equal(wisselButton(view).text, 'Einde match');
  assert.equal(chips(view, 'Uit').length, 8, 'uit is possible in the last block too');
  wisselButton(view).fire('click');
  assert.equal(h1(view), 'Einde match');
});

test('live screen: no In the zone button for a player who is out', () => {
  const { view, setup } = open();
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  const before = chips(view, 'In the zone').length;
  // Mark the first player of the starting five out: they become due off at the next change.
  const row = find(view, 'tr', (tr) => find(tr, 'span', (sp) => sp.className === 'number' && sp.text === '#1').length > 0)[0];
  find(row, 'button', (b) => b.text === 'Uit')[0].fire('click');
  assert.ok(!numbers(listOf(view, 'court')).includes(1), 'the out player left the court at once');
  assert.ok(!numbers(listOf(view, 'off')).includes(1), 'so has no In the zone button');
  assert.equal(chips(view, 'In the zone').length, numbers(listOf(view, 'off')).length);
  assert.ok(find(view, 'p', (p) => p.className === 'note replaced').length === 1, 'a line says who came in for whom');
  assert.ok(before >= off.length - 1);
});

// ---------- team history (decision #10) ----------

const storedHistory = (data) => JSON.parse(data.get('vervanging.history.v1') ?? 'null');
const endMatch = (view, blocks) => { for (let i = 0; i < blocks; i++) wisselButton(view).fire('click'); };

test('history: ending the match records each player\'s seconds once, under the setup\'s savedAt', () => {
  const env = open(setupOf({ n: 9, schedule: 'five' }));
  endMatch(env.view, 7);
  assert.equal(storedHistory(env.data), null, 'nothing is recorded before the end');
  wisselButton(env.view).fire('click');
  assert.equal(h1(env.view), 'Einde match');
  const history = storedHistory(env.data);
  assert.equal(history.matches.length, 1);
  assert.equal(history.matches[0].id, env.setup.savedAt);
  const state = JSON.parse(env.data.get('vervanging.match.v1'));
  assert.deepEqual(history.matches[0].seconds, JSON.parse(JSON.stringify(minutesSoFar(state))));
  assert.equal(Object.values(history.matches[0].seconds).reduce((a, b) => a + b, 0), 5 * 8 * 300);
  // Reloading the end screen does not add it again.
  env.reload();
  env.reload();
  assert.equal(storedHistory(env.data).matches.length, 1);
});

test('history: undoing the end removes the match; ending again records it once, with the new minutes', () => {
  const env = open(setupOf({ n: 9, schedule: 'five' }));
  endMatch(env.view, 8);
  button(env.view, 'Ongedaan maken').fire('click');
  assert.match(h1(env.view), /^Blok 8 van 8/);
  assert.deepEqual(storedHistory(env.data).matches, [], 'an undone end leaves no entry');
  const view = env.reload(); // undo after a reload works the same
  wisselButton(view).fire('click');
  assert.equal(storedHistory(env.data).matches.length, 1);
  button(view, 'Ongedaan maken').fire('click');
  wisselButton(view).fire('click');
  assert.equal(storedHistory(env.data).matches.length, 1, 'never a duplicate');
});

test('history: earlier matches stay, the switch is kept, and a damaged stored history is replaced cleanly', () => {
  const env = open(setupOf({ n: 9, schedule: 'five' }));
  env.store.save('history', { useHistory: true, matches: [{ id: 'earlier', seconds: { 1: 1200 } }, null, 'x'] });
  endMatch(env.view, 8);
  const history = storedHistory(env.data);
  assert.equal(history.useHistory, true);
  assert.deepEqual(history.matches.map((m) => m.id), ['earlier', env.setup.savedAt]);
  env.data.set('vervanging.history.v1', '{broken');
  button(env.view, 'Ongedaan maken').fire('click');
  wisselButton(env.view).fire('click');
  assert.deepEqual(storedHistory(env.data).matches.map((m) => m.id), [env.setup.savedAt]);
});

test('history: syncHistory without a savedAt records nothing', () => {
  const { store, data } = memoryStore();
  let state = startMatch(planOf(setupOf({ schedule: 'five' })));
  for (let i = 0; i < 8; i++) state = wissel(state);
  assert.equal(syncHistory(store, { savedAt: null }, state), true);
  assert.equal(data.has('vervanging.history.v1'), false);
});

// A store over `data` that refuses writes to the history while `refuse.history` is true (a full browser storage).
function flakyStore(data, refuse) {
  return createStore({
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => {
      if (refuse.history && k === 'vervanging.history.v1') throw new Error('QuotaExceededError');
      data.set(k, String(v));
    },
    removeItem: (k) => { data.delete(k); },
  });
}

const saveFailedShown = (view) => find(view, 'p', (p) => /Opslaan lukte niet/.test(p.text)).length > 0;

test('history: a refused history write at the end is caught up on reload, once', () => {
  const setup = setupOf({ n: 9, schedule: 'five' });
  const data = new Map();
  const refuse = { history: true };
  const env = open(setup, { store: flakyStore(data, refuse), data });
  endMatch(env.view, 8);
  assert.equal(h1(env.view), 'Einde match');
  assert.ok(saveFailedShown(env.view), 'the refused write is shown');
  assert.equal(storedHistory(data), null, 'the match state was saved, the history was not');

  let view = env.reload(); // still refused: the message stays
  assert.equal(h1(view), 'Einde match');
  assert.ok(saveFailedShown(view));
  assert.equal(storedHistory(data), null);

  refuse.history = false;
  view = env.reload();
  assert.equal(saveFailedShown(view), false);
  const history = storedHistory(data);
  assert.deepEqual(history.matches.map((m) => m.id), [setup.savedAt]);
  const state = JSON.parse(data.get('vervanging.match.v1'));
  assert.deepEqual(history.matches[0].seconds, JSON.parse(JSON.stringify(minutesSoFar(state))));
  env.reload();
  env.reload();
  assert.equal(storedHistory(data).matches.length, 1, 'later reloads add nothing');
});

test('history: a refused removal after an undo of the end is caught up on reload', () => {
  const data = new Map();
  const refuse = { history: false };
  const env = open(setupOf({ n: 9, schedule: 'five' }), { store: flakyStore(data, refuse), data });
  endMatch(env.view, 8);
  refuse.history = true;
  button(env.view, 'Ongedaan maken').fire('click');
  assert.equal(storedHistory(data).matches.length, 1, 'the removal was refused');
  refuse.history = false;
  const view = env.reload();
  assert.match(h1(view), /^Blok 8 van 8/);
  assert.deepEqual(storedHistory(data).matches, []);
});

test('history: after Wis geschiedenis, reopening an old end screen does not refill it', () => {
  const setup = setupOf({ n: 9, schedule: 'five', savedAt: '2026-11-22T10:00:00.000Z' });
  const env = open(setup);
  endMatch(env.view, 8);
  assert.equal(storedHistory(env.data).matches.length, 1);
  // "Wis geschiedenis" on the setup screen, after this match's Start.
  env.store.save('history', { useHistory: true, clearedAt: '2026-11-22T12:00:00.000Z', matches: [] });
  env.reload();
  env.reload();
  assert.deepEqual(storedHistory(env.data).matches, [], 'not refilled');
  // Undo and end again is a new end: the match is recorded again on purpose.
  const view = env.reload();
  button(view, 'Ongedaan maken').fire('click');
  wisselButton(view).fire('click');
  assert.deepEqual(storedHistory(env.data).matches.map((m) => m.id), [setup.savedAt]);
});

test('history: a match started after the last clear is caught up on reload', () => {
  const setup = setupOf({ n: 9, schedule: 'five', savedAt: '2026-11-22T13:00:00.000Z' });
  const data = new Map();
  const refuse = { history: false };
  const store = flakyStore(data, refuse);
  store.save('history', { useHistory: false, clearedAt: '2026-11-22T12:00:00.000Z', matches: [] });
  refuse.history = true;
  const env = open(setup, { store, data });
  endMatch(env.view, 8);
  refuse.history = false;
  env.reload();
  const history = storedHistory(data);
  assert.equal(history.clearedAt, '2026-11-22T12:00:00.000Z');
  assert.deepEqual(history.matches.map((m) => m.id), [setup.savedAt]);
});

// ---------- screen kept awake (#11) ----------

// A fake Screen Wake Lock API: request() hands out sentinels that can be released by the page or by the browser.
function fakeWakeLock({ refuse = false } = {}) {
  const sentinels = [];
  let resolveNext = null;
  const api = {
    held: () => sentinels.filter((x) => !x.released),
    sentinels,
    deferred: false,
    finish() { resolveNext(); },
    request(type) {
      assert.equal(type, 'screen');
      if (refuse) return Promise.reject(new Error('NotAllowedError'));
      const sentinel = {
        released: false, listeners: [],
        addEventListener(t, fn) { if (t === 'release') this.listeners.push(fn); },
        async release() { if (!this.released) { this.released = true; this.listeners.forEach((fn) => fn()); } },
      };
      sentinels.push(sentinel);
      if (!api.deferred) return Promise.resolve(sentinel);
      return new Promise((resolve) => { resolveNext = () => resolve(sentinel); });
    },
  };
  return api;
}

function fakeDocument() {
  const listeners = {};
  return {
    visibilityState: 'visible',
    addEventListener(type, fn) { (listeners[type] ||= []).push(fn); },
    become(state) { this.visibilityState = state; (listeners.visibilitychange || []).forEach((fn) => fn()); },
  };
}

const settle = () => new Promise((resolve) => setTimeout(resolve, 0));

test('wake lock: asked for when on, released when off', async () => {
  const api = fakeWakeLock();
  const lock = createWakeLock({ wakeLock: api }, fakeDocument());
  await lock.set(true);
  assert.equal(api.held().length, 1);
  assert.equal(lock.held, true);
  await lock.set(true);
  assert.equal(api.sentinels.length, 1, 'asking again while held does nothing');
  await lock.set(false);
  await settle();
  assert.equal(api.held().length, 0);
  assert.equal(lock.held, false);
});

test('wake lock: asked for again when the page is visible again, only while wanted', async () => {
  const api = fakeWakeLock();
  const doc = fakeDocument();
  const lock = createWakeLock({ wakeLock: api }, doc);
  await lock.set(true);
  doc.visibilityState = 'hidden';
  await api.sentinels[0].release(); // the browser drops the lock when the page is hidden
  doc.become('hidden');
  await settle();
  assert.equal(api.sentinels.length, 1, 'not asked for while hidden');
  doc.become('visible');
  await settle();
  assert.equal(api.held().length, 1, 'asked for again');
  assert.equal(lock.held, true);
  await lock.set(false);
  doc.become('hidden');
  doc.become('visible');
  await settle();
  assert.equal(api.held().length, 0, 'not after the match');
});

test('wake lock: a lock that arrives after the match ended is released at once', async () => {
  const api = fakeWakeLock();
  api.deferred = true;
  const lock = createWakeLock({ wakeLock: api }, fakeDocument());
  const asked = lock.set(true);
  await lock.set(false);
  api.finish();
  await asked;
  await settle();
  assert.equal(api.held().length, 0);
  assert.equal(lock.held, false);
});

test('wake lock: no error and nothing shown where the API is missing or refuses', async () => {
  for (const nav of [undefined, {}, { wakeLock: fakeWakeLock({ refuse: true }) }]) {
    const lock = createWakeLock(nav, undefined);
    await lock.set(true);
    assert.equal(lock.held, false);
    await lock.set(false);
  }
  const env = memoryStore();
  env.store.save('matchSetup', setupOf());
  const view = new FakeElement('main');
  liveScreen(view, { store: env.store }); // the real lock, in Node without navigator.wakeLock
  assert.equal(find(view, 'p', (e) => e.className === 'message')[0].text, '', 'no message');
});

test('live screen: keeps the screen awake while the match runs, not after the end, and again after undo', () => {
  const awake = [];
  const env = memoryStore();
  env.store.save('matchSetup', setupOf());
  const view = new FakeElement('main');
  liveScreen(view, { store: env.store, keepAwake: (on) => awake.push(on) });
  assert.equal(awake.at(-1), true, 'on when the match screen opens');
  for (let b = 1; b <= 12; b++) wisselButton(view).fire('click');
  assert.equal(h1(view), 'Einde match');
  assert.equal(awake.at(-1), false, 'off at the end of the match');
  button(view, 'Ongedaan maken').fire('click');
  assert.equal(awake.at(-1), true, 'on again when the end is undone');

  const reloaded = [];
  liveScreen(new FakeElement('main'), { store: env.store, keepAwake: (on) => reloaded.push(on) });
  assert.deepEqual(reloaded, [true], 'a reload mid-match asks again');

  const missing = [];
  liveScreen(new FakeElement('main'), { store: memoryStore().store, keepAwake: (on) => missing.push(on) });
  assert.deepEqual(missing, [false], 'no match: not kept awake');
});

test('live screen: Extra minuten next to In the zone; the note says the block is not given back', () => {
  const { view, setup, data } = open();
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  assert.equal(chips(view, 'Extra minuten').length, off.length);
  chips(view, 'Extra minuten')[0].fire('click');
  assert.equal(chips(view, 'Extra minuten')[0].attrs['aria-pressed'], 'true');
  assert.match(find(view, 'p', (p) => p.className === 'zone-note')[0].text, /extra minuten, niet teruggegeven/);
  wisselButton(view).fire('click');
  const saved = JSON.parse(data.get('vervanging.match.v1'));
  assert.deepEqual(saved.extra, [off[0]]);
  button(view, 'Ongedaan maken').fire('click');
  assert.deepEqual(JSON.parse(data.get('vervanging.match.v1')).extra, []);
});

// ---------- names next to the zone buttons (#46) ----------

// Each row of a list: its class, the player's name as shown, and the labels of its buttons in order.
const rows = (ul) => find(ul, 'li').map((li) => ({
  className: li.className,
  first: li.children[0],
  chips: find(li, 'span', (s) => s.className === 'chips')[0],
  buttons: find(li, 'button').map((b) => b.text),
}));

test('live screen: every Eruit row shows the player\'s name on its own line above In the zone and Extra minuten', () => {
  for (const n of [11, 15]) {
    const { view, setup } = open(setupOf({ n }));
    const byId = new Map(setup.players.map((p) => [p.id, p]));
    const off = rows(listOf(view, 'off'));
    assert.ok(off.length > 0, `someone is due off with ${n} players`);
    for (const row of off) {
      assert.equal(row.className, 'with-chips', 'the row wraps: name on its own line, buttons under it');
      assert.equal(row.first.className, 'player', 'the name comes first in the row');
      const number = Number(find(row.first, 'span', (s) => s.className === 'number')[0].text.slice(1));
      assert.equal(row.first.text, `#${number} ${byId.get(number).name}`, 'the full name is in the row');
      assert.ok(row.chips, 'the buttons sit in their own group');
      assert.deepEqual(find(row.chips, 'button').map((b) => b.text), ['In the zone', 'Extra minuten']);
    }
    for (const row of rows(listOf(view, 'on'))) assert.equal(row.className, '', 'no wrap on Erin before a zone choice');
    chips(view, 'In the zone')[0].fire('click');
    for (const row of rows(listOf(view, 'on'))) {
      assert.equal(row.className, 'with-chips', 'Erin rows wrap while Op de bank is shown');
      assert.equal(row.first.className, 'player');
      assert.match(row.first.text, /^#\d+ Speler\d+$/);
      assert.deepEqual(row.buttons, ['Op de bank']);
    }
  }
});

// The layout itself was measured in a browser at 402 x 874 (#46); these guard the rules that measurement rests on.
test('styles: a name row with buttons wraps, its name is never cut, and the buttons stay compact on one line', () => {
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  const rule = (selector) => css.match(new RegExp(`(?:^|\\n)${selector.replace(/[.*()]/g, '\\$&')}\\s*\\{([^}]*)\\}`))?.[1] ?? '';
  assert.match(rule('.names li.with-chips'), /flex-wrap:\s*wrap/, 'buttons that do not fit go under the name');
  const player = rule('.names li.with-chips .player');
  assert.match(player, /white-space:\s*normal/, 'a long name wraps instead of being cut');
  assert.doesNotMatch(player, /flex-basis:\s*100%/, 'the name does not force the buttons onto a line of their own');
  assert.match(player, /flex:\s*1 1 auto/, 'the name is laid out at its full width before the buttons');
  const chip = rule('.names li .chips button.chip');
  assert.match(chip, /padding:\s*0 6px/, 'narrow buttons, so In the zone and Extra minuten fit side by side');
  assert.match(chip, /font-size:\s*0\.8rem/);
  assert.match(chip, /margin-left:\s*0/);
  assert.doesNotMatch(chip, /min-height/, 'the buttons keep the 44 px tap height of button.chip');
  assert.match(rule('.change'), /grid-template-columns:\s*minmax\(0, 1\.05fr\) minmax\(0, 1fr\)/, 'Eruit is a little wider');
});

// ---------- minutes at a glance (#32) ----------

const overviewCells = (view) => {
  const ol = find(view, 'ol', (e) => e.className === 'overview')[0];
  return ol ? find(ol, 'li').map((li) => ({
    number: find(li, 'span', (s) => s.className === 'number')[0].text,
    minutes: find(li, 'span', (s) => s.className === 'min')[0].text,
    on: li.className === 'on',
    out: li.className === 'out',
    text: li.text,
  })) : null;
};

test('minutes at a glance: at the top, every player in jersey order with minutes, on-court players marked', () => {
  // twelve players whose ids are not in jersey order, so the screen has to sort by number
  const numbers12 = [12, 3, 7, 1, 10, 5, 9, 2, 11, 4, 8, 6];
  const players = numbers12.map((n, i) => ({ id: i + 1, name: `Speler${n}`, number: String(n) }));
  const ids = players.map((p) => p.id);
  const plan = makePlan({ players: ids, start: [1, 2, 3, 4, 5], schedule: 'equal', seed: 3 });
  const setup = { savedAt: '2026-11-22T10:00:00.000Z', opponent: 'BC Test', schedule: 'equal', seed: 3, players, startingFive: [1, 2, 3, 4, 5], plan };
  const { view } = open(setup);

  const top = view.children.filter((c) => c instanceof FakeElement);
  const at = (pred) => top.findIndex(pred);
  const overviewAt = at((c) => c.tag === 'ol' && c.className === 'overview');
  assert.ok(overviewAt > 0, 'the overview is on the screen');
  assert.ok(overviewAt < at((c) => c.tag === 'section'), 'above Op het veld');
  assert.ok(overviewAt < at((c) => c.tag === 'table'), 'above the full table, which stays');
  assert.equal(at((c) => c.className === 'sub-time') + 1, overviewAt, 'right under the sub time');

  const check = () => {
    const cells = overviewCells(view);
    assert.deepEqual(cells.map((c) => c.number), Array.from({ length: 12 }, (_, i) => `#${i + 1}`), 'jersey order');
    const rows = minuteRows(view);
    assert.deepEqual(cells.map((c) => c.minutes), rows.map((r) => r.minutes), 'the same minutes as the full table');
    const court = numbers(listOf(view, 'court')).map((n) => `#${n}`);
    assert.deepEqual(cells.filter((c) => c.on).map((c) => c.number).sort(), court.sort(), 'on court marked');
    for (const c of cells.filter((x) => x.on)) assert.match(c.text, /\(op het veld\)/, 'said for screen readers too');
  };
  check();
  wisselButton(view).fire('click');
  wisselButton(view).fire('click');
  check();
  assert.ok(overviewCells(view).some((c) => c.minutes !== '0:00' && c.minutes !== '3:20'), 'minutes grow');
});

test('minutes at a glance: a player who went uit is marked out, and the end screen shows only the full table', () => {
  const { view } = open();
  const row = find(view, 'tr', (tr) => find(tr, 'span', (sp) => sp.className === 'number' && sp.text === '#1').length > 0)[0];
  find(row, 'button', (b) => b.text === 'Uit')[0].fire('click');
  const one = overviewCells(view).find((c) => c.number === '#1');
  assert.deepEqual({ on: one.on, out: one.out, minutes: one.minutes }, { on: false, out: true, minutes: '3:20' });
  assert.match(one.text, /\(uit\)/);
  for (let b = 0; b < 12; b++) wisselButton(view).fire('click');
  assert.equal(h1(view), 'Einde match');
  assert.equal(overviewCells(view), null, 'no overview after the end: the table is at the top there');
  assert.equal(minuteRows(view).length, 8);
});

test('history: a match with Extra minuten records the extra seconds apart', () => {
  const env = open();
  const { view, data, setup } = env;
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  chips(view, 'Extra minuten')[0].fire('click');
  wisselButton(view).fire('click');
  endMatch(view, 11);
  const stored = storedHistory(data);
  const match = stored.matches.find((m) => m.id === setup.savedAt);
  assert.deepEqual(match.extra, { [off[0]]: 200 });
  assert.equal(match.seconds[off[0]] >= 200, true);
});
