import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import { createStore } from './store.js';
import { formatSeconds } from './setup.js';
import { makePlan } from './planner.js';
import { startMatch, wissel, uit, onCourt, minutesSoFar } from './match.js';
import { liveScreen, subTimeText, planOf, restoreMatch, syncHistory, createWakeLock, DOUBLE_TAP_MS } from './live.js';

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

// A fake clock that moves a second on every read, so each tap in a test is a separate tap, never a double tap (#49).
function spacedClock() {
  let t = 0;
  return () => (t += 1000);
}

function open(setup = setupOf(), env = memoryStore()) {
  env.store.save('matchSetup', setup);
  const view = new FakeElement('main');
  liveScreen(view, { store: env.store, now: spacedClock() });
  return { ...env, view, setup, reload() { const v = new FakeElement('main'); liveScreen(v, { store: env.store, now: spacedClock() }); return v; } };
}

const h1 = (view) => find(view, 'h1')[0].text;
const subLine = (view) => find(view, 'p', (e) => e.className === 'sub-time')[0]?.text;

test('subTimeText: wissel op m:ss inside a quarter, einde kwart, laatste blok', () => {
  let state = startMatch(planOf(setupOf()));
  const lines = [];
  for (let b = 0; b < 12; b++) { lines.push(subTimeText(state)); state = wissel(state); }
  assert.deepEqual(lines, [
    'Wissel op 6:40', 'Wissel op 3:20', 'Einde kwart', 'Wissel op 6:40', 'Wissel op 3:20', 'Einde kwart',
    'Wissel op 6:40', 'Wissel op 3:20', 'Einde kwart', 'Wissel op 6:40', 'Wissel op 3:20', 'Laatste blok',
  ]);
  state = startMatch(planOf(setupOf({ schedule: 'five' })));
  const five = [];
  for (let b = 0; b < 8; b++) { five.push(subTimeText(state)); state = wissel(state); }
  assert.deepEqual(five, ['Wissel op 5:00', 'Einde kwart', 'Wissel op 5:00', 'Einde kwart', 'Wissel op 5:00', 'Einde kwart', 'Wissel op 5:00', 'Laatste blok']);
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
  for (const r of rows) assert.equal(r.minutes, '0:00', 'nothing played yet at tip-off (#54)');
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
  assert.equal(subLine(view), 'Laatste blok');
});

test('live screen: a refused write shows a Dutch message and the tap still counts on screen', () => {
  const env = open();
  const data = new Map(env.data);
  const store = createStore({ getItem: (k) => data.get(k) ?? null, setItem() { throw new Error('full'); }, removeItem() {} });
  const view = new FakeElement('main');
  liveScreen(view, { store, now: spacedClock() });
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
  assert.equal(subLine(view), 'Laatste blok', 'the line under the heading names the last block, not the end screen');
  assert.match(h1(view), /^Blok 12 van 12/);
  assert.equal(chips(view, 'Uit').length, 8, 'uit is possible in the last block too');
  wisselButton(view).fire('click');
  assert.equal(h1(view), 'Einde match');
});

// ---------- a double tap on Wissel (#49, P2-1 in docs/spikes/2026-ui-review.md) ----------

// A clock the test sets by hand: `clock.at` is what the screen reads as now, in milliseconds.
function handClock() {
  const clock = { at: 0, now: () => clock.at };
  return clock;
}

function openWithClock(clock) {
  const env = memoryStore();
  env.store.save('matchSetup', setupOf());
  const view = new FakeElement('main');
  liveScreen(view, { store: env.store, now: clock.now });
  return { ...env, view };
}

test('live screen: a second Wissel tap within 600 ms does nothing; a tap after that plays the next wissel', () => {
  assert.equal(DOUBLE_TAP_MS, 600);
  const clock = handClock();
  const { view, data } = openWithClock(clock);
  clock.at = 10_000;
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 2 van 12/);
  clock.at += 120; // the two scripted touches of P2-1, 120 ms apart
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 2 van 12/, 'the second tap is ignored, no block is skipped');
  clock.at = 10_000 + DOUBLE_TAP_MS - 1;
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 2 van 12/, 'still ignored just under 600 ms after the first tap');
  assert.equal(JSON.parse(data.get('vervanging.match.v1')).block, 2, 'the ignored taps saved nothing');
  clock.at = 10_000 + DOUBLE_TAP_MS;
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 3 van 12/, '600 ms after the first tap, a tap counts again');
  assert.equal(JSON.parse(data.get('vervanging.match.v1')).block, 3);
});

test('live screen: a double tap at block 11 does not end the match; Einde match ends it on a later tap', () => {
  const clock = handClock();
  const { view, data } = openWithClock(clock);
  for (let b = 1; b < 11; b++) { clock.at += 1000; wisselButton(view).fire('click'); }
  assert.match(h1(view), /^Blok 11 van 12/);
  clock.at += 1000;
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 12 van 12/);
  assert.equal(wisselButton(view).text, 'Einde match', 'the redrawn button in the same spot reads Einde match');
  clock.at += 200;
  wisselButton(view).fire('click');
  assert.match(h1(view), /^Blok 12 van 12/, 'the second tap of the double tap does not end the match');
  assert.equal(JSON.parse(data.get('vervanging.match.v1')).ended, false);
  clock.at += DOUBLE_TAP_MS;
  wisselButton(view).fire('click');
  assert.equal(h1(view), 'Einde match', 'a later tap on Einde match ends it as before');
  assert.equal(JSON.parse(data.get('vervanging.match.v1')).ended, true);
});

test('styles: buttons have touch-action: manipulation, so a quick second tap is not taken as a zoom', () => {
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  const rule = css.match(/(?:^|\n)button, \.button\s*\{([^}]*)\}/)?.[1] ?? '';
  assert.match(rule, /touch-action:\s*manipulation/);
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
  liveScreen(view, { store: env.store, keepAwake: (on) => awake.push(on), now: spacedClock() });
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

// ---------- Extra minuten behind In the zone (#52, P2-4 in docs/spikes/2026-ui-review.md) ----------

const EXTRA = 'Extra minuten (niet teruggeven)';
const zoneNote = (view) => find(view, 'div', (d) => d.className === 'zone-note')[0];
const zoneText = (view) => find(zoneNote(view), 'p')[0].text;
const pressed = (b) => b.attrs['aria-pressed'] === 'true';

test('live screen: Extra minuten shows only for the chosen player, as one toggle in the zone note', () => {
  const { view, setup } = open();
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  assert.equal(chips(view, 'In the zone').length, off.length);
  assert.equal(find(view, 'button', (b) => /Extra minuten/.test(b.text)).length, 0, 'no Extra minuten before a choice');
  assert.equal(zoneNote(view), undefined);
  chips(view, 'In the zone')[1].fire('click');
  const extra = find(view, 'button', (b) => /Extra minuten/.test(b.text));
  assert.equal(extra.length, 1, 'one Extra minuten toggle, for the chosen player only');
  assert.equal(extra[0].text, EXTRA);
  assert.ok(find(zoneNote(view), 'button').includes(extra[0]), 'the toggle sits in the zone note');
  assert.equal(pressed(extra[0]), false, 'In the zone is the choice until the coach turns Extra minuten on');
  assert.match(zoneText(view), /blijft in the zone op het veld/);
  for (const ul of [listOf(view, 'off'), listOf(view, 'on')]) {
    assert.equal(find(ul, 'button', (b) => /Extra minuten/.test(b.text)).length, 0, 'never on a row');
  }
});

test('live screen: In the zone, then Extra minuten and back, keeps the player and the bench player', () => {
  const { view, setup, data } = open();
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  chips(view, 'In the zone')[0].fire('click');
  const bench = chips(view, 'Op de bank');
  const other = bench.findIndex((b) => !pressed(b));
  if (other >= 0) bench[other].fire('click');
  const benchChoice = () => chips(view, 'Op de bank').findIndex(pressed);
  const chosenBench = benchChoice();

  chips(view, EXTRA)[0].fire('click');
  assert.equal(pressed(chips(view, EXTRA)[0]), true, 'switched to Extra minuten');
  assert.equal(pressed(chips(view, 'In the zone')[0]), true, 'the same player stays chosen');
  assert.equal(benchChoice(), chosenBench, 'the bench choice is kept');
  assert.match(zoneText(view), /extra minuten, niet teruggegeven/);

  chips(view, EXTRA)[0].fire('click');
  assert.equal(pressed(chips(view, EXTRA)[0]), false, 'and back to In the zone');
  assert.equal(benchChoice(), chosenBench);
  assert.match(zoneText(view), /blijft in the zone op het veld/);
  wisselButton(view).fire('click');
  assert.deepEqual(JSON.parse(data.get('vervanging.match.v1')).extra, [], 'back to In the zone plays no extra minuten');
  assert.ok(numbers(listOf(view, 'court')).includes(off[0]), 'the zone player stays on court');
});

test('live screen: Extra minuten plays an Extra minuten wissel as before, and undo takes it back', () => {
  const { view, setup, data } = open();
  const { grid } = setup.plan;
  const off = grid[0].filter((p) => !grid[1].includes(p));
  chips(view, 'In the zone')[0].fire('click');
  chips(view, EXTRA)[0].fire('click');
  wisselButton(view).fire('click');
  const saved = JSON.parse(data.get('vervanging.match.v1'));
  assert.deepEqual(saved.extra, [off[0]]);
  assert.ok(numbers(listOf(view, 'court')).includes(off[0]));
  assert.equal(zoneNote(view), undefined, 'the choice is used up by the wissel');
  button(view, 'Ongedaan maken').fire('click');
  assert.deepEqual(JSON.parse(data.get('vervanging.match.v1')).extra, []);
  assert.match(h1(view), /^Blok 1 van 12/);
});

test('live screen: tapping In the zone again cancels the choice, also after switching to Extra minuten', () => {
  const { view, data } = open();
  chips(view, 'In the zone')[0].fire('click');
  chips(view, 'In the zone')[0].fire('click');
  assert.equal(zoneNote(view), undefined, 'cancelled: no note, no toggle');
  assert.equal(chips(view, 'Op de bank').length, 0);
  assert.equal(chips(view, 'In the zone').filter(pressed).length, 0);

  chips(view, 'In the zone')[0].fire('click');
  chips(view, EXTRA)[0].fire('click');
  chips(view, 'In the zone')[0].fire('click');
  assert.equal(zoneNote(view), undefined, 'cancelled from Extra minuten too');
  assert.equal(chips(view, EXTRA).length, 0);
  wisselButton(view).fire('click');
  const saved = JSON.parse(data.get('vervanging.match.v1'));
  assert.deepEqual(saved.extra, [], 'the wissel after a cancel plays the plan');

  // Choosing another player starts that player on In the zone, not on Extra minuten.
  chips(view, 'In the zone')[0].fire('click');
  chips(view, EXTRA)[0].fire('click');
  if (chips(view, 'In the zone').length > 1) {
    chips(view, 'In the zone')[1].fire('click');
    assert.equal(pressed(chips(view, 'In the zone')[1]), true);
    assert.equal(pressed(chips(view, 'In the zone')[0]), false);
    assert.equal(pressed(chips(view, EXTRA)[0]), false, 'a new choice starts as In the zone');
  }
});

// ---------- names next to the zone buttons (#46) ----------

// Each row of a list: its class, the player's name as shown, and the labels of its buttons in order.
const rows = (ul) => find(ul, 'li').map((li) => ({
  className: li.className,
  first: li.children[0],
  chips: find(li, 'span', (s) => s.className === 'chips')[0],
  buttons: find(li, 'button').map((b) => b.text),
}));

test('live screen: every Eruit row shows the player\'s name with its one button beside it, In the zone', () => {
  for (const n of [11, 15]) {
    const { view, setup } = open(setupOf({ n }));
    const byId = new Map(setup.players.map((p) => [p.id, p]));
    const off = rows(listOf(view, 'off'));
    assert.ok(off.length > 0, `someone is due off with ${n} players`);
    for (const row of off) {
      assert.equal(row.className, 'with-chips', 'a row with a button: the name and the button beside it');
      assert.equal(row.first.className, 'player', 'the name comes first in the row');
      const number = Number(find(row.first, 'span', (s) => s.className === 'number')[0].text.slice(1));
      assert.equal(row.first.text, `#${number} ${byId.get(number).name}`, 'the full name is in the row');
      assert.ok(row.chips, 'the buttons sit in their own group');
      assert.deepEqual(find(row.chips, 'button').map((b) => b.text), ['In the zone'], 'only In the zone on a row (#52)');
    }
    for (const row of rows(listOf(view, 'on'))) assert.equal(row.className, '', 'no button layout on Erin before a zone choice');
    chips(view, 'In the zone')[0].fire('click');
    for (const row of rows(listOf(view, 'on'))) {
      assert.equal(row.className, 'with-chips', 'Erin rows get the button layout while Op de bank is shown');
      assert.equal(row.first.className, 'player');
      assert.match(row.first.text, /^#\d+ Speler\d+$/);
      assert.deepEqual(row.buttons, ['Op de bank']);
    }
  }
});

// The layout itself was measured in a browser at 402 x 874 (#46); these guard the rules that measurement rests on.
// #52 fix round: with one button per row, the button stays beside the name and a long name wraps in its own space, so
// "Marie-Louise" or "Anne-Sophie" no longer push the button onto a line of its own (which put the third row under the
// Wissel bar).
test('styles: a name row keeps its one button beside the name, and the name wraps beside it, never cut', () => {
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  const rule = (selector) => css.match(new RegExp(`(?:^|\\n)${selector.replace(/[.*()]/g, '\\$&')}\\s*\\{([^}]*)\\}`))?.[1] ?? '';
  assert.match(rule('.names li.with-chips'), /flex-wrap:\s*nowrap/, 'the button never moves under the name');
  const player = rule('.names li.with-chips .player');
  assert.match(player, /white-space:\s*normal/, 'a long name wraps instead of being cut');
  // #74: break-word, not anywhere, so "Mohammed" never splits into "Mohamm/ed" while it fits on a line of its own; only
  // a word wider than the whole column is split, so it still never overflows onto the button.
  assert.match(player, /overflow-wrap:\s*break-word/, 'a name breaks between words, and splits only a word too wide to fit');
  assert.doesNotMatch(player, /anywhere/, 'never in the middle of a word that fits');
  assert.match(player, /flex:\s*1 1 0/, 'the name takes the width the button leaves');
  assert.match(player, /min-width:\s*0/, 'so it can wrap inside that width');
  assert.doesNotMatch(player, /overflow:\s*hidden|text-overflow/, 'the name is never cut');
  assert.match(rule('.names li .chips'), /flex:\s*0 0 auto/, 'the button keeps its full width');
  const chip = rule('.names li .chips button.chip');
  assert.match(chip, /padding:\s*0 6px/, 'narrow buttons, so a button fits beside a short name');
  assert.match(chip, /font-size:\s*0\.8rem/);
  assert.match(chip, /margin-left:\s*0/);
  assert.doesNotMatch(chip, /min-height/, 'the buttons keep the 44 px tap height of button.chip');
  // #74: the label wraps in two lines ("In the / zone"), so the button is about 50 px wide and a long single name
  // ("Bernadette", "Maximiliaan") fits beside it on one line at 360 px, keeping every row 44 px high.
  assert.match(chip, /max-width:\s*4\.6em/, 'a narrow button: its label takes two lines');
  assert.match(chip, /white-space:\s*normal/, 'the label may wrap');
  assert.match(chip, /line-height:\s*1\.1/, 'two lines of label fit in 44 px');
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
  assert.deepEqual({ on: one.on, out: one.out, minutes: one.minutes }, { on: false, out: true, minutes: '0:00' });
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
  chips(view, 'In the zone')[0].fire('click');
  chips(view, 'Extra minuten (niet teruggeven)')[0].fire('click');
  wisselButton(view).fire('click');
  endMatch(view, 11);
  const stored = storedHistory(data);
  const match = stored.matches.find((m) => m.id === setup.savedAt);
  assert.deepEqual(match.extra, { [off[0]]: 200 });
  assert.equal(match.seconds[off[0]] >= 200, true);
});

// ---------- a confirmation line after each action (#50, P2-2 in docs/spikes/2026-ui-review.md) ----------

const messageOf = (view) => find(view, 'p', (e) => e.className === 'message')[0];
const messageText = (view) => messageOf(view).text;
const rowButton = (view, number, label) => {
  const row = find(view, 'tr', (tr) => find(tr, 'span', (sp) => sp.className === 'number' && sp.text === `#${number}`).length > 0)[0];
  return find(row, 'button', (b) => b.text === label)[0];
};
// Players in setupOf have id = number and name `Speler<id>`, so "#3 Speler3" is how the screen writes player 3.
const playerLabel = (id) => `#${id} Speler${id}`;
const cameOnIds = (before, after) => onCourt(after).filter((id) => !onCourt(before).includes(id)).sort((a, b) => a - b);

test('confirmation: Wissel writes the new block and who came on, in jersey order', () => {
  const { view, setup } = open();
  const s0 = startMatch(planOf(setup), setup.savedAt);
  const s1 = wissel(s0);
  const s2 = wissel(s1);
  assert.equal(messageText(view), '', 'no line before the first action');
  wisselButton(view).fire('click'); // open() uses a clock that moves a second per read, so the next tap counts too
  assert.equal(messageText(view), `Wissel gedaan: blok 2. Erin: ${cameOnIds(s0, s1).map(playerLabel).join(', ')}.`);
  assert.equal(messageOf(view).attrs.role, 'status', 'a confirmation is a polite status, not an alert');
  wisselButton(view).fire('click');
  assert.equal(messageText(view), `Wissel gedaan: blok 3. Erin: ${cameOnIds(s1, s2).map(playerLabel).join(', ')}.`);
});

test('confirmation: a Wissel that brings nobody on (exactly five players) leaves out the Erin part', () => {
  const { view } = open(setupOf({ n: 5 }));
  wisselButton(view).fire('click');
  assert.equal(messageText(view), 'Wissel gedaan: blok 2.');
  wisselButton(view).fire('click');
  assert.equal(messageText(view), 'Wissel gedaan: blok 3.');
});

test('confirmation: Uit on court names the replacement; Uit of a bench player leaves out the erin part', () => {
  const { view, setup } = open();
  const s0 = startMatch(planOf(setup), setup.savedAt);
  const [replacement] = cameOnIds(s0, uit(s0, 1));
  rowButton(view, 1, 'Uit').fire('click');
  assert.equal(messageText(view), `#1 Speler1 uit, ${playerLabel(replacement)} erin.`);
  const bench = setup.players.map((p) => p.id).find((id) => !onCourt(s0).includes(id) && id !== replacement);
  rowButton(view, bench, 'Uit').fire('click');
  assert.equal(messageText(view), `${playerLabel(bench)} uit.`);
});

test('confirmation: Terug says the player is back from the next block, and undo says Ongedaan gemaakt', () => {
  const { view } = open();
  rowButton(view, 8, 'Uit').fire('click');
  rowButton(view, 8, 'Terug').fire('click');
  assert.equal(messageText(view), '#8 Speler8 terug vanaf het volgende blok.');
  button(view, 'Ongedaan maken').fire('click');
  assert.equal(messageText(view), 'Ongedaan gemaakt.');
});

test('confirmation: the line stays while choosing In the zone, and a reload starts without it', () => {
  const env = open();
  wisselButton(env.view).fire('click');
  const line = messageText(env.view);
  assert.match(line, /^Wissel gedaan: blok 2\./);
  chips(env.view, 'In the zone')[0].fire('click');
  assert.equal(messageText(env.view), line, 'In the zone is not an action, so the line stays');
  assert.equal(messageText(env.reload()), '');
});

test('confirmation: Einde match writes no line, the end screen says it', () => {
  const { view } = open();
  for (let i = 1; i < 12; i++) wisselButton(view).fire('click');
  assert.equal(wisselButton(view).text, 'Einde match');
  wisselButton(view).fire('click');
  assert.equal(h1(view), 'Einde match');
  assert.equal(messageText(view), '');
  button(view, 'Ongedaan maken').fire('click');
  assert.equal(messageText(view), 'Ongedaan gemaakt.');
});

test('confirmation: errors keep their own text, never a confirmation', () => {
  // An action the engine refuses: with 8 players, a fourth Uit would leave fewer than five.
  const { view } = open();
  for (const id of [6, 7, 8]) rowButton(view, id, 'Uit').fire('click');
  assert.equal(messageText(view), '#8 Speler8 uit.');
  rowButton(view, 5, 'Uit').fire('click');
  assert.equal(messageText(view), 'Dat kan nu niet.');
  assert.equal(messageOf(view).attrs.role, 'alert');

  // A refused write: the save-failed message, not the confirmation line.
  const env = open();
  const data = new Map(env.data);
  const store = createStore({ getItem: (k) => data.get(k) ?? null, setItem() { throw new Error('full'); }, removeItem() {} });
  const refused = new FakeElement('main');
  liveScreen(refused, { store, now: spacedClock() });
  for (const tap of [() => wisselButton(refused), () => rowButton(refused, 1, 'Uit'), () => button(refused, 'Ongedaan maken')]) {
    tap().fire('click');
    assert.equal(messageText(refused), 'Opslaan lukte niet: de browser weigert opslag.');
  }
});

test('buttons have a pressed (:active) style', () => {
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  assert.match(css, /button:active:not\(:disabled\)/);
  assert.match(css, /button\.primary:active:not\(:disabled\)/);
});

// #74: with a three-player change the zone note starts under the sticky Wissel bar, so its Extra minuten toggle was out
// of sight. The browser measured it (PR); here a fake layout checks the rule: after In the zone, and after the toggle
// is pressed (its sentence grows by a line), the page scrolls just far enough to put the toggle 8 px above the bar.
function withLayout({ toggleTop }, fn) {
  let scrolled = 0;
  const scrolls = [];
  const make = globalThis.document.createElement;
  globalThis.document = {
    createElement(tag) {
      const node = make(tag);
      node.getBoundingClientRect = () => {
        const classes = node.className.split(' ');
        if (classes.includes('live-actions')) return { top: 725, bottom: 874 };
        if (classes.includes('extra')) {
          const top = toggleTop + (node.attrs['aria-pressed'] === 'true' ? 22 : 0) - scrolled;
          return { top, bottom: top + 44 };
        }
        return { top: 0, bottom: 0 };
      };
      return node;
    },
  };
  globalThis.scrollBy = (x, y) => { scrolls.push([x, y]); scrolled += y; };
  try {
    fn(scrolls);
  } finally {
    delete globalThis.scrollBy;
  }
}

test('live screen: choosing In the zone scrolls the Extra minuten toggle above the Wissel bar, and pressing it keeps it there', () => {
  withLayout({ toggleTop: 785 }, (scrolls) => {
    const { view } = open(setupOf({ n: 15 }));
    assert.deepEqual(scrolls, [], 'opening the screen does not scroll');
    chips(view, 'In the zone')[0].fire('click');
    assert.deepEqual(scrolls, [[0, 785 + 44 + 8 - 725]], 'scrolled just far enough: toggle bottom 8 px above the bar');
    chips(view, 'Extra minuten (niet teruggeven)')[0].fire('click');
    assert.deepEqual(scrolls.at(-1), [0, 22], 'pressed: the longer sentence pushes it down 22 px, the page follows');
    assert.equal(scrolls.length, 2);
    chips(view, 'Extra minuten (niet teruggeven)')[0].fire('click');
    assert.equal(scrolls.length, 2, 'back to In the zone: the toggle moves up and stays in view, no scroll');
    chips(view, 'In the zone')[0].fire('click');
    assert.equal(scrolls.length, 2, 'cancelling the choice does not scroll');
  });
});

test('live screen: a toggle already above the Wissel bar does not move the page', () => {
  withLayout({ toggleTop: 600 }, (scrolls) => {
    const { view } = open(setupOf({ n: 15 }));
    chips(view, 'In the zone')[0].fire('click');
    chips(view, 'Extra minuten (niet teruggeven)')[0].fire('click');
    assert.deepEqual(scrolls, []);
  });
});

// ---------- the minutes table's header (#55, P3-3 in docs/spikes/2026-ui-review.md) ----------

const minutesTables = (view) => find(view, 'table', (e) => e.className === 'minutes');
const headerCells = (table) => find(find(table, 'thead')[0], 'th');
const cellsOf = (tr) => tr.children.filter((c) => c instanceof FakeElement);

test('minutes table: a header cell for every column, the Uit/Terug one visually hidden', () => {
  const env = open(setupOf({ schedule: 'five' }));
  chips(env.view, 'Uit')[0].fire('click');
  const [live] = minutesTables(env.view);
  const head = headerCells(live);
  for (const tr of find(live, 'tbody')[0].children) assert.equal(cellsOf(tr).length, head.length, 'as many header cells as row cells');
  assert.deepEqual(head.map((th) => th.text), ['Speler', 'Minuten', 'Actie']);
  assert.ok(head.every((th) => th.attrs.scope === 'col'));
  const [hidden] = find(head[2], 'span');
  assert.equal(hidden.className, 'visually-hidden', 'screen readers announce it; the layout stays the same');

  for (let i = 0; i < 8; i++) wisselButton(env.view).fire('click');
  assert.equal(h1(env.view), 'Einde match');
  const [end] = minutesTables(env.view);
  const endHead = headerCells(end);
  assert.deepEqual(endHead.map((th) => th.text), ['Speler', 'Minuten'], 'no action column at the end, so no header for it');
  for (const tr of find(end, 'tbody')[0].children) assert.equal(cellsOf(tr).length, endHead.length);
});

test('styles: the uit tag is not struck through with the name', () => {
  const css = readFileSync(new URL('../styles.css', import.meta.url), 'utf8');
  const struck = [...css.replace(/\/\*[\s\S]*?\*\//g, '').matchAll(/([^{}]+)\{([^}]*)\}/g)]
    .filter(([, , body]) => /text-decoration:\s*line-through/.test(body))
    .flatMap(([, sel]) => sel.split(',').map((s) => s.trim()))
    .filter((s) => s.startsWith('.minutes'));
  assert.ok(struck.includes('.minutes tr.out th .player'), 'the name is struck through');
  assert.ok(!struck.some((s) => /tr\.out th$/.test(s) || /\.tag\b/.test(s)), `not the whole cell or the tag: ${struck.join(' | ')}`);
});

// ---------- "Minuten tot nu" counts finished blocks only (#54, P3-2 in docs/spikes/2026-ui-review.md) ----------

// The seconds from the plan's grid for the first `played` blocks, by player.
const playedFrom = (grid, played, ids) => Object.fromEntries(ids.map((id) => [id,
  grid.slice(0, played).filter((row) => row.includes(id)).length * 200]));
const shown = (cellsOrRows) => Object.fromEntries(cellsOrRows.map((c) => [Number(String(c.number).replace('#', '')), c.minutes]));
const asText = (seconds) => Object.fromEntries(Object.entries(seconds).map(([id, s]) => [Number(id), formatSeconds(s)]));

test('minutes so far: the overview and the table count only finished blocks, at every block', () => {
  const env = open(); // open() uses a clock that moves a second per read, so every Wissel tap counts
  const { grid } = env.setup.plan;
  const ids = env.setup.players.map((p) => p.id);
  for (let block = 1; block <= 12; block++) {
    assert.match(h1(env.view), new RegExp(`^Blok ${block} van 12`));
    const want = asText(playedFrom(grid, block - 1, ids));
    assert.deepEqual(shown(minuteRows(env.view)), want, `table, block ${block}`);
    assert.deepEqual(shown(overviewCells(env.view)), want, `overview, block ${block}`);
    assert.equal(find(env.view, 'caption')[0].text, 'Minuten tot nu');
    wisselButton(env.view).fire('click');
  }
  assert.equal(h1(env.view), 'Einde match');
  assert.deepEqual(shown(minuteRows(env.view)), asText(playedFrom(grid, 12, ids)), 'the end screen: every block, full totals');
  assert.equal(find(env.view, 'caption')[0].text, 'Minuten per speler');
});

test('minutes so far: the end screen and the history keep the full totals', () => {
  const env = open(setupOf({ n: 9, schedule: 'five' }));
  endMatch(env.view, 8);
  const state = JSON.parse(env.data.get('vervanging.match.v1'));
  const full = minutesSoFar(state);
  assert.deepEqual(shown(minuteRows(env.view)), asText(full));
  assert.deepEqual(storedHistory(env.data).matches[0].seconds, JSON.parse(JSON.stringify(full)));
  button(env.view, 'Ongedaan maken').fire('click');
  assert.match(h1(env.view), /^Blok 8 van 8/);
  const lastPlaying = JSON.parse(env.data.get('vervanging.match.v1'));
  assert.deepEqual(shown(minuteRows(env.view)), asText(minutesSoFar({ ...lastPlaying, block: 7 })),
    'back in the last block, it is not counted until the match ends');
});

test('minutes so far: a starter taken uit keeps the block once it is played; the replacement does not get it', () => {
  const { view, setup } = open();
  const { grid } = setup.plan;
  const starter = grid[0][0];
  rowButton(view, starter, 'Uit').fire('click');
  const replacement = numbers(listOf(view, 'court')).find((p) => !grid[0].includes(p));
  assert.equal(shown(minuteRows(view))[starter], '0:00', 'block 1 is not finished yet');
  wisselButton(view).fire('click');
  assert.equal(shown(minuteRows(view))[starter], '3:20', 'the block counts for the starter (as the screen says)');
  assert.equal(shown(overviewCells(view))[starter], '3:20');
  assert.equal(shown(minuteRows(view))[replacement], '0:00', 'the replacement is not credited for block 1');
});

test('minutes so far: an Extra minuten block counts once it is played', () => {
  const { view, setup } = open();
  const { grid } = setup.plan;
  const keep = grid[0].filter((p) => !grid[1].includes(p))[0];
  chips(view, 'In the zone')[0].fire('click');
  chips(view, 'Extra minuten (niet teruggeven)')[0].fire('click');
  wisselButton(view).fire('click');
  assert.deepEqual(numbers(listOf(view, 'court')).includes(keep), true, 'kept on for block 2');
  assert.equal(shown(minuteRows(view))[keep], '3:20', 'only block 1 is finished');
  wisselButton(view).fire('click');
  assert.equal(shown(minuteRows(view))[keep], '6:40', 'the extra block counts after it is played');
  assert.equal(shown(overviewCells(view))[keep], '6:40');
});
