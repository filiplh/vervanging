import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { createStore } from './store.js';
import { makePlan, planStats } from './planner.js';
import {
  MAX_PLAYERS, normaliseRoster, checkPlayer, addPlayer, editPlayer, removePlayer, normaliseAttendance,
  initialAttendance, normaliseMatchSetup, formatSeconds, playerLabel, rosterScreen, setupScreen,
} from './setup.js';

// ---------- test doubles: in-memory localStorage and a minimal DOM (no dependency) ----------

function memoryStore() {
  const data = new Map();
  const store = createStore({
    getItem: (k) => (data.has(k) ? data.get(k) : null),
    setItem: (k, v) => { data.set(k, String(v)); },
    removeItem: (k) => { data.delete(k); },
  });
  return { store, data, raw: (thing) => JSON.parse(data.get(`vervanging.${thing}.v1`)) };
}

class FakeElement {
  constructor(tag) {
    this.tag = tag;
    this.children = [];
    this.attrs = {};
    this.listeners = {};
    this.className = '';
    this.checked = false;
    this.disabled = false;
    this.value = '';
    this.elements = {};
  }

  addEventListener(type, fn) { (this.listeners[type] ||= []).push(fn); }

  setAttribute(key, value) {
    this.attrs[key] = value;
    if (key === 'value') this.value = value;
  }

  append(...nodes) { for (const n of nodes) this.children.push(typeof n === 'string' ? { text: n } : n); }

  replaceChildren(...nodes) { this.children = []; this.append(...nodes); }

  querySelector() { return null; }

  focus() {}

  get text() { return this.children.map((c) => c.text).join(''); }

  all() { return [this, ...this.children.filter((c) => c instanceof FakeElement).flatMap((c) => c.all())]; }

  fire(type) {
    for (const fn of this.listeners[type] || []) fn({ preventDefault() {}, currentTarget: this, target: this });
  }
}

beforeEach(() => {
  globalThis.document = { createElement: (tag) => new FakeElement(tag) };
  globalThis.window = { confirm: () => true };
});

const find = (root, tag, pred = () => true) => root.all().filter((e) => e.tag === tag && pred(e));
const button = (root, label, n = 0) => find(root, 'button', (e) => e.text.includes(label))[n];
const pageText = (root) => root.all().map((e) => e.children.filter((c) => !(c instanceof FakeElement)).map((c) => c.text).join('')).join('|');

function fillForm(root, name, number) {
  const [form] = find(root, 'form');
  const [nameInput, numberInput] = find(form, 'input');
  form.elements = { name: nameInput, number: numberInput };
  nameInput.value = name;
  numberInput.value = number;
  form.fire('submit');
}

function rosterOf(n) {
  let roster = normaliseRoster(null);
  for (let i = 1; i <= n; i++) roster = addPlayer(roster, { name: `Speler${i}`, number: String(i) });
  return roster;
}

// ---------- pure helpers ----------

test('roster: add, edit, remove, ids never reused', () => {
  let roster = rosterOf(3);
  assert.deepEqual(roster.players.map((p) => p.id), [1, 2, 3]);
  roster = editPlayer(roster, 2, { name: 'Lien', number: '00' });
  assert.deepEqual(roster.players[1], { id: 2, name: 'Lien', number: '00' });
  roster = removePlayer(roster, 3);
  assert.deepEqual(roster.players.map((p) => p.id), [1, 2]);
  assert.equal(addPlayer(roster, { name: 'Nieuw', number: '9' }).players.at(-1).id, 4);
});

test('roster: checkPlayer enforces the cap, name, number and unique numbers', () => {
  const full = rosterOf(MAX_PLAYERS);
  assert.equal(MAX_PLAYERS, 15);
  assert.match(checkPlayer(full, { name: 'X', number: '50' }), /Maximaal 15 spelers/);
  assert.equal(checkPlayer(full, { name: 'X', number: '50' }, 1), null, 'editing is allowed at the cap');
  const roster = rosterOf(3);
  assert.match(checkPlayer(roster, { name: '', number: '5' }), /voornaam/);
  assert.match(checkPlayer(roster, { name: 'X'.repeat(21), number: '5' }), /hoogstens 20/);
  for (const number of ['', '100', '-1', '1a', '4.5']) assert.match(checkPlayer(roster, { name: 'X', number }), /0 tot 99/);
  assert.match(checkPlayer(roster, { name: 'X', number: '2' }), /Rugnummer 2 is al van Speler2/);
  assert.equal(checkPlayer(roster, { name: 'Speler2', number: '2' }, 2), null, 'own number while editing');
  assert.equal(checkPlayer(roster, { name: 'X', number: '00' }), null);
});

test('roster: normaliseRoster survives damaged stored values', () => {
  for (const raw of [null, 42, 'x', [], {}, { players: 'x' }]) {
    assert.deepEqual(normaliseRoster(raw), { nextId: 1, players: [] });
  }
  const cleaned = normaliseRoster({
    nextId: 1,
    players: [null, { id: 3, name: 'Lien', number: '7' }, { id: 3, name: 'Dubbel', number: '8' },
      { id: 'x', name: 'A', number: '1' }, { id: 5, name: '', number: '1' }, { id: 6, name: 'B', number: 7 },
      { id: 7, name: 'C', number: '123' }],
  });
  assert.deepEqual(cleaned, { nextId: 4, players: [{ id: 3, name: 'Lien', number: '7' }] });
  assert.equal(normaliseRoster({ players: Array.from({ length: 20 }, (_, i) => ({ id: i + 1, name: 'P', number: String(i) })) }).players.length, 15);
});

test('attendance: last selection pre-ticked, everyone when none, damaged values ignored', () => {
  const roster = rosterOf(6);
  assert.deepEqual(initialAttendance(roster, [2, 4, 99]), [2, 4]);
  assert.deepEqual(initialAttendance(roster, null), [1, 2, 3, 4, 5, 6]);
  assert.deepEqual(initialAttendance(roster, { 0: 1 }), [1, 2, 3, 4, 5, 6]);
  assert.deepEqual(initialAttendance(roster, [null, '2', 3]), [3]);
  assert.deepEqual(normaliseAttendance([1, null, 'x', 2.5, 4]), [1, 4]);
  assert.equal(normaliseAttendance('1,2'), null);
});

test('formatSeconds and playerLabel', () => {
  assert.equal(formatSeconds(1000), '16:40');
  assert.equal(formatSeconds(200), '3:20');
  assert.equal(formatSeconds(0), '0:00');
  assert.equal(formatSeconds(-5), '0:00');
  assert.equal(playerLabel({ name: 'Lien', number: '7' }), '#7 Lien');
});

function validSetup() {
  const players = rosterOf(8).players;
  const ids = players.map((p) => p.id);
  const plan = makePlan({ players: ids, start: ids.slice(0, 5), schedule: 'equal', seed: 3 });
  return { savedAt: '2026-11-22T10:00:00.000Z', opponent: 'BC Test', schedule: 'equal', seed: 3, players, startingFive: ids.slice(0, 5), plan };
}

test('match setup: a valid setup passes normaliseMatchSetup', () => {
  const setup = validSetup();
  const out = normaliseMatchSetup(JSON.parse(JSON.stringify(setup)));
  assert.deepEqual(out.players, setup.players);
  assert.deepEqual(out.startingFive, setup.startingFive);
  assert.equal(out.opponent, 'BC Test');
  assert.equal(normaliseMatchSetup({ ...setup, opponent: undefined }).opponent, '');
});

test('match setup: damaged shapes give null', () => {
  const setup = validSetup();
  const damaged = [
    null, 7, 'x', [], {},
    { ...setup, players: [null] },
    { ...setup, players: [null, ...setup.players] },
    { ...setup, players: 'x' },
    { ...setup, startingFive: 'x' },
    { ...setup, startingFive: { includes: 1 } },
    { ...setup, startingFive: [1, 2, 3, 4] },
    { ...setup, startingFive: [1, 2, 3, 4, 99] },
    { ...setup, startingFive: [1, 1, 2, 3, 4] },
    { ...setup, schedule: 'toString' },
    { ...setup, schedule: 'other' },
    { ...setup, opponent: 5 },
    { ...setup, plan: null },
    { ...setup, plan: { ...setup.plan, grid: setup.plan.grid.slice(1) } },
    { ...setup, plan: { ...setup.plan, grid: [...setup.plan.grid.slice(1), [1, 2, 3, 4, 99]] } },
    { ...setup, plan: { ...setup.plan, start: 'x' } },
    { ...setup, schedule: 'five' },
  ];
  for (const raw of damaged) assert.equal(normaliseMatchSetup(raw), null, JSON.stringify(raw)?.slice(0, 80));
});

// ---------- roster screen ----------

test('roster screen: add up to 15, the 16th is impossible, everything persists', () => {
  const { store, raw } = memoryStore();
  const view = new FakeElement('main');
  rosterScreen(view, { store });
  assert.match(pageText(view), /Nog geen spelers/);
  for (let i = 1; i <= MAX_PLAYERS; i++) fillForm(view, `Speler${i}`, String(i));
  assert.equal(raw('roster').players.length, 15);
  assert.equal(find(view, 'form').length, 0, 'no form at the cap');
  assert.match(pageText(view), /Maximaal 15 spelers/);

  // A reload (a new screen on the same storage) shows the same roster.
  const again = new FakeElement('main');
  rosterScreen(again, { store });
  assert.match(pageText(again), /15 van 15/);
  assert.equal(find(again, 'li').length, 15);
});

test('roster screen: invalid entries show a message and are not saved', () => {
  const { store, data } = memoryStore();
  const view = new FakeElement('main');
  rosterScreen(view, { store });
  fillForm(view, '', '7');
  assert.match(pageText(view), /Vul een voornaam in/);
  assert.equal(data.size, 0);
  fillForm(view, 'Lien', '7');
  fillForm(view, 'Mona', '7');
  assert.match(pageText(view), /Rugnummer 7 is al van Lien/);
});

test('roster screen: edit and remove persist', () => {
  const { store, raw } = memoryStore();
  store.save('roster', rosterOf(3));
  const view = new FakeElement('main');
  rosterScreen(view, { store });
  button(view, 'Wijzig', 1).fire('click');
  assert.ok(button(view, 'Bewaren'));
  fillForm(view, 'Lien', '22');
  assert.deepEqual(raw('roster').players[1], { id: 2, name: 'Lien', number: '22' });
  button(view, 'Verwijder', 0).fire('click');
  assert.deepEqual(raw('roster').players.map((p) => p.id), [2, 3]);

  globalThis.window.confirm = () => false;
  button(view, 'Verwijder', 0).fire('click');
  assert.equal(raw('roster').players.length, 2, 'cancelled remove keeps the player');
});

test('roster screen: a refused write shows a Dutch message', () => {
  const store = createStore({ getItem: () => null, setItem() { throw new Error('full'); }, removeItem() {} });
  const view = new FakeElement('main');
  rosterScreen(view, { store });
  fillForm(view, 'Lien', '7');
  assert.match(pageText(view), /Opslaan lukte niet/);
});

// ---------- setup screen ----------

const checkboxes = (view) => find(view, 'input', (e) => e.attrs.type === 'checkbox');
const radios = (view) => find(view, 'input', (e) => e.attrs.type === 'radio');
const rows = (view) => find(view, 'tbody')[0]?.children ?? [];
const rowCells = (row) => row.children.slice(1, -1).map((c) => c.className).join(',');

function openSetup({ players = 10, attendance } = {}) {
  const env = memoryStore();
  env.store.save('roster', rosterOf(players));
  if (attendance) env.store.save('attendance', attendance);
  env.view = new FakeElement('main');
  env.started = [];
  setupScreen(env.view, { store: env.store, onStart: (s) => env.started.push(s) });
  return env;
}

function pickFive(view, n = 5) {
  for (let i = 0; i < n; i++) find(view, 'button', (e) => e.text === 'Basis' && !e.disabled && e.attrs['aria-pressed'] === 'false')[0].fire('click');
}

test('setup screen: asks for more players when the roster has fewer than 5', () => {
  const { view } = openSetup({ players: 4 });
  assert.match(pageText(view), /minstens 5 spelers/);
  assert.equal(find(view, 'table').length, 0);
});

test('setup screen: attendance pre-ticked from the last match', () => {
  const { view } = openSetup({ players: 12, attendance: [1, 2, 3, 4, 5, 6, 7, 8] });
  assert.deepEqual(checkboxes(view).map((b) => b.checked), [...Array(8).fill(true), ...Array(4).fill(false)]);
  assert.match(pageText(view), /Aanwezig: 8/);
});

test('setup screen: no plan until exactly 5 present basisvijf players', () => {
  const { view } = openSetup();
  assert.equal(find(view, 'table').length, 0);
  pickFive(view, 4);
  assert.match(pageText(view), /Kies precies 5/);
  assert.equal(find(view, 'table').length, 0);
  pickFive(view, 1);
  assert.equal(find(view, 'table').length, 1);
  assert.ok(find(view, 'button', (e) => e.text === 'Basis' && e.attrs['aria-pressed'] === 'false').every((b) => b.disabled),
    'a 6th pick is disabled');
  // Unticking a starter's attendance removes them from the basisvijf and hides the plan.
  checkboxes(view)[0].fire('change');
  assert.equal(find(view, 'table').length, 0);
  assert.match(pageText(view), /Basisvijf: 4 van 5/);
});

test('setup screen: fewer than 5 present asks for more', () => {
  const { view } = openSetup({ players: 6, attendance: [1, 2, 3, 4] });
  assert.match(pageText(view), /minstens 5 aanwezige/);
});

test('setup screen: grid shows each present player with minutes as m:ss, for both schemas', () => {
  const { view } = openSetup({ players: 12, attendance: [1, 2, 3, 4, 5, 6, 7, 8, 9] });
  pickFive(view);
  assert.equal(rows(view).length, 9);
  assert.equal(rows(view)[0].children.length, 1 + 12 + 1);
  const minutes = rows(view).map((r) => r.children.at(-1).text);
  assert.ok(minutes.every((m) => /^\d+:\d\d$/.test(m)), minutes.join(' '));
  const seconds = minutes.map((m) => Number(m.split(':')[0]) * 60 + Number(m.split(':')[1]));
  assert.equal(seconds.reduce((a, b) => a + b, 0), 5 * 40 * 60, 'five players on court for 40 minutes');
  assert.ok(Math.max(...seconds) - Math.min(...seconds) <= 200, 'shares differ by at most one block');
  assert.equal(radios(view)[0].checked, true);

  radios(view)[1].fire('change');
  assert.equal(radios(view)[1].checked, true);
  assert.equal(rows(view)[0].children.length, 1 + 8 + 1);
  assert.ok(rows(view).every((r) => /^\d+:\d\d$/.test(r.children.at(-1).text)));
});

test('setup screen: swaps follow the planner rule and update the grid', () => {
  const { view } = openSetup();
  pickFive(view);
  const rowButton = (i) => rows(view)[i].children[0].children[0];
  const before = rows(view).map(rowCells);

  rowButton(0).fire('click');
  rowButton(7).fire('click');
  assert.match(pageText(view), /Ruil twee spelers van de basisvijf/);
  assert.deepEqual(rows(view).map(rowCells), before, 'refused swap changes nothing');

  rowButton(5).fire('click');
  rowButton(6).fire('click');
  assert.match(pageText(view), /geruild/);
  const after = rows(view).map(rowCells);
  assert.equal(after[5], before[6]);
  assert.equal(after[6], before[5]);

  rowButton(1).fire('click');
  rowButton(3).fire('click');
  assert.match(pageText(view), /geruild/, 'two starters can swap too');
});

test('setup screen: Start saves the setup and the attendance', () => {
  const { view, store, raw, started } = openSetup({ players: 11 });
  checkboxes(view)[10].fire('change');
  pickFive(view);
  radios(view)[1].fire('change');
  const opponent = find(view, 'input', (e) => e.attrs.maxlength === '40')[0];
  opponent.value = '  BC Test ';
  opponent.fire('input');
  const rowButton = (i) => rows(view)[i].children[0].children[0];
  rowButton(5).fire('click');
  rowButton(6).fire('click');
  const shownGrid = rows(view).map(rowCells);

  button(view, 'Start').fire('click');
  assert.equal(started.length, 1);
  const saved = raw('matchSetup');
  assert.equal(saved.opponent, 'BC Test');
  assert.equal(saved.schedule, 'five');
  assert.equal(saved.players.length, 10);
  assert.deepEqual(saved.startingFive.slice().sort((a, b) => a - b), [1, 2, 3, 4, 5]);
  assert.equal(saved.plan.grid.length, 8);
  assert.deepEqual(raw('attendance').sort((a, b) => a - b), [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]);
  assert.ok(normaliseMatchSetup(saved), 'the saved setup is valid');
  // The saved plan is the one after the swap, as shown.
  const minutes = planStats(saved.plan).minutes;
  assert.equal(Object.keys(minutes).length, 10);
  assert.equal(shownGrid.length, 10);

  // The next setup pre-ticks this attendance.
  const next = new FakeElement('main');
  setupScreen(next, { store, onStart() {} });
  assert.deepEqual(checkboxes(next).map((b) => b.checked), [...Array(10).fill(true), false]);
});

test('setup screen: Start with refused storage shows a message and does not leave', () => {
  const env = openSetup();
  pickFive(env.view);
  const data = new Map(env.data);
  const store = createStore({ getItem: (k) => data.get(k) ?? null, setItem() { throw new Error('full'); }, removeItem() {} });
  const view = new FakeElement('main');
  const started = [];
  setupScreen(view, { store, onStart: (s) => started.push(s) });
  pickFive(view);
  button(view, 'Start').fire('click');
  assert.equal(started.length, 0);
  assert.match(pageText(view), /Opslaan lukte niet/);
});
