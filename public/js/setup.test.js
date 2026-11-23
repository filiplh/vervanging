import { test, beforeEach } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { join, relative, basename } from 'node:path';
import vm from 'node:vm';
import { createHash } from 'node:crypto';
import { createStore } from './store.js';
import { makePlan, planStats, SCHEDULES } from './planner.js';
import { liveScreen } from './live.js';
import {
  MAX_PLAYERS, normaliseRoster, checkPlayer, addPlayer, editPlayer, removePlayer, normaliseAttendance,
  initialAttendance, normaliseMatchSetup, formatSeconds, playerLabel, rosterScreen, setupScreen, isInstalled,
  formatDuration, seasonNote, hasRunningMatch, initialStartingFive,
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

// A valid saved match setup for rosterOf(n)'s players `ids`, with `five` as its basisvijf.
function savedSetup(n, ids, five) {
  const players = rosterOf(n).players.filter((p) => ids.includes(p.id));
  const plan = makePlan({ players: ids, start: five, schedule: 'equal', seed: 7 });
  return { savedAt: '2026-11-23T10:00:00.000Z', opponent: '', schedule: 'equal', seed: 7, players, startingFive: five, plan };
}

test('initialStartingFive: the last basisvijf among the players present; nobody on a first match or damaged data', () => {
  const last = savedSetup(8, [1, 2, 3, 4, 5, 6, 7, 8], [2, 4, 6, 7, 8]);
  assert.deepEqual(initialStartingFive([1, 2, 3, 4, 5, 6, 7, 8], last), [2, 4, 6, 7, 8]);
  assert.deepEqual(initialStartingFive([1, 2, 3, 5, 6, 8], last), [2, 6, 8], 'absent ones are left out');
  assert.deepEqual(initialStartingFive([1, 3, 5], last), []);
  assert.deepEqual(initialStartingFive([1, 2, 3], null), [], 'first match ever');
  assert.deepEqual(initialStartingFive([1, 2, 3], { startingFive: [1, 2, 3] }), [], 'a damaged setup gives nobody');
  assert.deepEqual(initialStartingFive([1, 2, 3], 'x'), []);
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

test('roster screen: the Voornaam input turns off autocorrect and spellcheck, when adding and in Wijzig (#61)', () => {
  const { store } = memoryStore();
  store.save('roster', rosterOf(2));
  const view = new FakeElement('main');
  rosterScreen(view, { store });
  const nameInput = () => find(view, 'input', (e) => e.attrs.name === 'name')[0];
  for (const mode of ['add', 'edit']) {
    if (mode === 'edit') button(view, 'Wijzig', 0).fire('click');
    const { attrs } = nameInput();
    assert.equal(attrs.autocorrect, 'off', mode);
    assert.equal(attrs.spellcheck, 'false', mode);
    assert.equal(attrs.autocapitalize, 'words', mode);
    assert.equal(attrs.autocomplete, 'off', mode);
  }
  assert.ok(button(view, 'Bewaren'), 'the Wijzig form was checked');
});

test('roster screen: a refused write shows a Dutch message', () => {
  const store = createStore({ getItem: () => null, setItem() { throw new Error('full'); }, removeItem() {} });
  const view = new FakeElement('main');
  rosterScreen(view, { store });
  fillForm(view, 'Lien', '7');
  assert.match(pageText(view), /Opslaan lukte niet/);
});

// ---------- season totals on the roster screen (decision #26) ----------

test('formatDuration: m:ss under an hour, h:mm:ss from an hour; seasonNote counts the saved matches', () => {
  assert.equal(formatDuration(0), '0:00');
  assert.equal(formatDuration(3000), '50:00');
  assert.equal(formatDuration(3599.4), '59:59');
  assert.equal(formatDuration(3600), '1:00:00');
  assert.equal(formatDuration(3 * 3600 + 5 * 60 + 7), '3:05:07');
  assert.equal(formatDuration(-1), '0:00');
  assert.equal(formatDuration(NaN), '0:00');
  assert.match(seasonNote(0), /nog geen matchen bewaard/);
  assert.match(seasonNote(1), /over 1 bewaarde match\./);
  assert.match(seasonNote(2), /over 2 bewaarde matchen\./);
});

function openRoster(history) {
  const env = memoryStore();
  env.store.save('roster', rosterOf(6));
  if (history !== undefined) env.store.save('history', history);
  env.view = new FakeElement('main');
  rosterScreen(env.view, { store: env.store });
  return env;
}
const totalsShown = (view) => find(view, 'li').map((li) => find(li, 'span', (e) => e.className.includes('season-total'))[0].children.at(-1).text);

test('roster screen: each player shows the season total and the note the match count; no minutes shows 0:00 min', () => {
  const history = {
    useHistory: false,
    clearedAt: null,
    matches: [
      { id: '2026-11-01T10:00:00.000Z', seconds: { 1: 1500, 2: 1200, 3: 2000 } },
      { id: '2026-11-08T10:00:00.000Z', seconds: { 1: 2100.4, 2: 300, 4: 45 } }, // 3 absent, 4 only here
    ],
  };
  const { view } = openRoster(history);
  assert.deepEqual(totalsShown(view), ['1:00:00 min', '25:00 min', '33:20 min', '0:45 min', '0:00 min', '0:00 min']);
  assert.match(pageText(view), /over 2 bewaarde matchen/);
});

test('roster screen: the season total carries a visible "min" unit, in the text colour, read once as "speeltijd … min" (#60)', () => {
  const { view } = openRoster({ useHistory: false, clearedAt: null, matches: [{ id: 'm1', seconds: { 1: 2200 } }] });
  const [total] = find(view, 'span', (e) => e.className.includes('season-total'));
  assert.equal(total.className, 'season-total', 'not muted like the jersey numbers');
  const [hidden, shown] = total.children;
  assert.equal(hidden.className, 'visually-hidden');
  assert.equal(shown.text, '36:40 min', 'the unit is visible text, not hidden');
  assert.equal(total.text, 'speeltijd 36:40 min');
  assert.doesNotMatch(total.text, /minuten/, 'no unit said twice');
});

test('roster screen: no history, a damaged one or a cleared one shows 0:00 min for everyone', () => {
  const cleared = { useHistory: true, clearedAt: '2026-11-22T10:00:00.000Z', matches: [] };
  for (const history of [undefined, 42, 'x', { matches: [null, { id: 3 }] }, cleared]) {
    const { view } = openRoster(history);
    assert.deepEqual(totalsShown(view), Array(6).fill('0:00 min'), `history ${JSON.stringify(history)}`);
    assert.match(pageText(view), /nog geen matchen bewaard/);
  }
  const empty = new FakeElement('main');
  rosterScreen(empty, { store: memoryStore().store });
  assert.doesNotMatch(pageText(empty), /Speeltijd/, 'no note without players');
});

test('roster screen: Wis geschiedenis on the Match screen resets the totals', () => {
  const env = openSetup({ players: 6, history: { useHistory: false, clearedAt: null, matches: [{ id: 'm1', seconds: { 1: 600 } }] } });
  const before = new FakeElement('main');
  rosterScreen(before, { store: env.store });
  assert.equal(totalsShown(before)[0], '10:00 min');
  button(env.view, 'Wis geschiedenis').fire('click');
  const after = new FakeElement('main');
  rosterScreen(after, { store: env.store });
  assert.deepEqual(totalsShown(after), Array(6).fill('0:00 min'));
});

// ---------- setup screen ----------

const checkboxes = (view) => find(view, 'input', (e) => e.attrs.type === 'checkbox' && e.attrs.name !== 'useHistory');
const historySwitch = (view) => find(view, 'input', (e) => e.attrs.name === 'useHistory')[0];
const radios = (view) => find(view, 'input', (e) => e.attrs.type === 'radio');
const rows = (view) => find(view, 'tbody')[0]?.children ?? [];
const rowCells = (row) => row.children.slice(1, -1).map((c) => c.className).join(',');

function openSetup({ players = 10, attendance, history, installed } = {}) {
  const env = memoryStore();
  env.store.save('roster', rosterOf(players));
  if (attendance) env.store.save('attendance', attendance);
  if (history !== undefined) env.store.save('history', history);
  env.view = new FakeElement('main');
  env.started = [];
  const options = { store: env.store, onStart: (s) => env.started.push(s) };
  if (installed !== undefined) options.installed = installed;
  setupScreen(env.view, options);
  return env;
}

const basisButtons = (view) => find(view, 'button', (e) => e.text === 'Basis');
const basisOn = (view) => basisButtons(view).map((b) => b.attrs['aria-pressed'] === 'true');

// Picks up to n more basisvijf players. A setup after an earlier Start may already have the last basisvijf
// pre-selected (#56); then there is nothing left to pick and it stops.
function pickFive(view, n = 5) {
  for (let i = 0; i < n; i++) {
    const next = basisButtons(view).find((e) => !e.disabled && e.attrs['aria-pressed'] === 'false');
    if (!next) return;
    next.fire('click');
  }
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
  assert.match(planStatus(view), /kan niet: /);
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

// The swap prompts name the players (#58, P3-6 in docs/spikes/2026-ui-review.md).
const planStatus = (view) => find(view, 'p', (e) => e.className === 'message' && e.attrs.role === 'status')[0].text;

test('setup screen: the first tap of a swap names the chosen player; tapping them again clears it', () => {
  const { view } = openSetup();
  pickFive(view);
  const rowButton = (i) => rows(view)[i].children[0].children[0];
  const name = rowButton(5).text; // as the grid writes it, "#6 Speler6"
  assert.match(name, /^#\d+ Speler\d+$/);

  rowButton(5).fire('click');
  assert.equal(planStatus(view), `${name} gekozen. Tik de speler aan om mee te ruilen.`);
  rowButton(5).fire('click');
  assert.equal(planStatus(view), '', 'cancelling the choice clears the line');

  rowButton(5).fire('click');
  rowButton(6).fire('click');
  assert.match(planStatus(view), /geruild\.$/, 'a done swap replaces the prompt');
});

test('setup screen: a refused swap names both players and the reason', () => {
  const { view } = openSetup();
  pickFive(view);
  const rowButton = (i) => rows(view)[i].children[0].children[0];
  const starter = rowButton(0).text;
  const bench = rowButton(7).text;

  rowButton(0).fire('click');
  rowButton(7).fire('click');
  assert.equal(planStatus(view), `Wissel ${starter} en ${bench} kan niet: de ene staat in de basisvijf en de andere niet.`);

  rowButton(7).fire('click'); // the other way round names them in tap order
  rowButton(0).fire('click');
  assert.equal(planStatus(view), `Wissel ${bench} en ${starter} kan niet: de ene staat in de basisvijf en de andere niet.`);
  assert.ok(!rows(view).some((r) => r.className?.includes('selected')), 'nobody stays chosen after a refusal');
});

test('setup screen: a failed save stays on screen over the swap prompts', () => {
  const env = openSetup();
  const data = new Map(env.data);
  const store = createStore({ getItem: (k) => data.get(k) ?? null, setItem() { throw new Error('full'); }, removeItem() {} });
  const view = new FakeElement('main');
  setupScreen(view, { store, onStart() {} });
  pickFive(view);
  button(view, 'Start').fire('click');
  const failed = planStatus(view);
  assert.match(failed, /^Opslaan lukte niet/);
  const rowButton = (i) => rows(view)[i].children[0].children[0];

  rowButton(5).fire('click');
  assert.equal(planStatus(view), failed, 'first tap');
  rowButton(5).fire('click');
  assert.equal(planStatus(view), failed, 'cancel');
  rowButton(0).fire('click');
  rowButton(7).fire('click');
  assert.equal(planStatus(view), failed, 'refusal');
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

// The last basisvijf pre-selected after "Nieuwe match" (#56, P3-4 in docs/spikes/2026-ui-review.md).
function startedWith({ players = 11, absent = [], five = [1, 2, 3, 4, 5] } = {}) {
  const env = openSetup({ players });
  for (const id of absent) checkboxes(env.view)[id - 1].fire('change');
  for (const id of five) basisButtons(env.view)[id - 1].fire('click');
  button(env.view, 'Start').fire('click');
  assert.equal(env.started.length, 1);
  return env;
}

test('setup screen: a first match ever has no basisvijf pre-selected', () => {
  const { view } = openSetup();
  assert.deepEqual(basisOn(view), Array(10).fill(false));
  assert.match(pageText(view), /Basisvijf: 0 van 5/);
  assert.equal(button(view, 'Start'), undefined);
});

test('setup screen: after Start, the next setup pre-selects the last basisvijf and shows its plan', () => {
  const env = startedWith({ absent: [11], five: [2, 4, 6, 8, 10] });
  const view = setupView(env);
  assert.deepEqual(basisOn(view), [false, true, false, true, false, true, false, true, false, true, false]);
  assert.match(pageText(view), /Aanwezig: 10 · Basisvijf: 5 van 5/);
  assert.equal(rows(view).length, 10, 'the plan is shown at once');
  assert.deepEqual(rows(view).slice(0, 5).map((r) => find(r, 'span', (e) => e.className === 'number')[0].text),
    ['#2', '#4', '#6', '#8', '#10'], 'the remembered five start');
  assert.ok(button(view, 'Start'));
});

test('setup screen: the coach can still change a pre-selected basisvijf', () => {
  const env = startedWith();
  const view = setupView(env);
  basisButtons(view)[0].fire('click');
  assert.match(pageText(view), /Basisvijf: 4 van 5/);
  assert.equal(find(view, 'table').length, 0, 'no plan and no Start with four');
  assert.equal(button(view, 'Start'), undefined);
  basisButtons(view)[6].fire('click');
  assert.deepEqual(basisOn(view), [false, true, true, true, true, false, true, false, false, false, false]);
  button(view, 'Start').fire('click');
  assert.deepEqual(env.raw('matchSetup').startingFive.slice().sort((a, b) => a - b), [2, 3, 4, 5, 7]);
});

test('setup screen: absent or deleted players of the last basisvijf are left out; the coach picks the rest', () => {
  const env = startedWith();
  // Player 2 was deleted from the squad; player 4 is not ticked present any more.
  env.store.save('roster', removePlayer(rosterOf(11), 2));
  env.store.save('attendance', [1, 3, 5, 6, 7, 8, 9, 10, 11]);
  const view = setupView(env);
  assert.deepEqual(basisOn(view), [true, true, false, true, false, false, false, false, false, false],
    'ids 1, 3 and 5 of the ten players left');
  assert.match(pageText(view), /Basisvijf: 3 van 5/);
  assert.match(pageText(view), /Kies precies 5/);
  assert.equal(button(view, 'Start'), undefined, 'no Start until the coach picks five');
  pickFive(view, 2);
  assert.ok(button(view, 'Start'));

  // Unticking a pre-selected starter takes them out of the basisvijf, as with one picked by hand.
  checkboxes(view)[0].fire('change');
  assert.match(pageText(view), /Basisvijf: 4 van 5/);
});

test('setup screen: a damaged saved setup pre-selects nobody', () => {
  const env = startedWith();
  env.store.save('matchSetup', { ...env.raw('matchSetup'), plan: null });
  assert.deepEqual(basisOn(setupView(env)), Array(11).fill(false));
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

// ------// ---------- Start with a running match (#47, P1-2 in docs/spikes/2026-ui-review.md) ----------

const REPLACE_QUESTION = 'De lopende match stoppen en een nieuwe beginnen?';

// The live screen (#start) as app.js opens it after Start, which first removes the old match state.
function openLive(env) {
  const view = new FakeElement('main');
  liveScreen(view, { store: env.store, keepAwake() {}, now: ((t) => () => (t += 1000))(0) }); // taps 1 s apart (#49)
  return view;
}
const liveTitle = (view) => find(view, 'h1')[0].text;
const tapWissel = (view) => find(view, 'button', (e) => e.className.split(' ').includes('wissel'))[0].fire('click');

// A first Start on the setup screen, then the live screen with no tap yet: only the setup is saved, no match state.
function startedUntouched() {
  const env = openSetup({ players: 11 });
  pickFive(env.view);
  button(env.view, 'Start').fire('click');
  env.store.remove('match');
  const live = openLive(env);
  assert.equal(env.store.load('match'), null, 'opening the live screen saves no match state');
  return { env, live };
}

// Plays the started match to its end on the live screen, as the coach does with Wissel.
function playToEnd(env, live) {
  for (let taps = 0; liveTitle(live) !== 'Einde match'; taps++) {
    assert.ok(taps < 20, 'the match ends');
    tapWissel(live);
  }
  assert.equal(env.store.load('match').ended, true);
}

// A second setup screen on the same store, where the coach picks the other schedule and taps Start.
function startAgain(env, answer) {
  const asked = [];
  globalThis.window = { confirm: (q) => { asked.push(q); return answer; } };
  const view = new FakeElement('main');
  const started = [];
  setupScreen(view, { store: env.store, onStart: (s) => started.push(s) });
  radios(view)[1].fire('change');
  pickFive(view);
  button(view, 'Start').fire('click');
  return { view, asked, started };
}

test('hasRunningMatch: only when the live screen would resume a match that has not ended', () => {
  const first = openSetup();
  assert.equal(hasRunningMatch(first.store), false, 'no setup saved yet');
  const { env, live } = startedUntouched();
  assert.equal(hasRunningMatch(env.store), true, 'started, no tap yet');
  tapWissel(live);
  assert.equal(hasRunningMatch(env.store), true, 'saved match in play');
  playToEnd(env, live);
  assert.equal(hasRunningMatch(env.store), false, 'ended match');
  env.store.save('matchSetup', { damaged: true });
  assert.equal(hasRunningMatch(env.store), false, 'a damaged setup resumes nothing');
});

test('setup screen: Start after a started match with no tap yet asks; no keeps it and the live screen resumes it', () => {
  const { env } = startedUntouched();
  const before = new Map(env.data);
  const savedAt = env.raw('matchSetup').savedAt;

  const { view, asked, started } = startAgain(env, false);
  assert.deepEqual(asked, [REPLACE_QUESTION]);
  assert.equal(started.length, 0, 'no: the new match is not started');
  assert.deepEqual(new Map(env.data), before, 'no: no stored key changed');
  assert.ok(button(view, 'Start'), 'still on the setup screen');
  const live = openLive(env);
  assert.notEqual(liveTitle(live), 'Geen match gevonden');
  assert.equal(env.raw('matchSetup').savedAt, savedAt, 'the live screen resumes the first match');
  assert.equal(env.raw('matchSetup').schedule, 'equal');
});

test('setup screen: Start with a saved match in play asks first; no keeps it and stays on setup', () => {
  const { env, live } = startedUntouched();
  tapWissel(live);
  assert.equal(env.raw('match').block, 2);
  const before = new Map(env.data);

  const { view, asked, started } = startAgain(env, false);
  assert.deepEqual(asked, [REPLACE_QUESTION]);
  assert.equal(started.length, 0, 'no: the new match is not started');
  assert.deepEqual(new Map(env.data), before, 'no: no stored key changed');
  assert.ok(button(view, 'Start'), 'still on the setup screen');
});

test('setup screen: Start with a running match and yes saves the new setup and starts it', () => {
  for (const tap of [false, true]) {
    const { env, live } = startedUntouched();
    if (tap) tapWissel(live);
    const { asked, started } = startAgain(env, true);
    assert.deepEqual(asked, [REPLACE_QUESTION]);
    assert.equal(started.length, 1);
    assert.equal(env.raw('matchSetup').schedule, 'five', 'the new setup replaced the old one');
  }
});

test('setup screen: a first-ever Start, or one after a finished match and Nieuwe match, starts at once without asking', () => {
  const first = startAgain(openSetup(), false);
  assert.deepEqual(first.asked, [], 'first-ever Start');
  assert.equal(first.started.length, 1);

  const { env, live } = startedUntouched();
  playToEnd(env, live);
  const nieuwe = find(live, 'a', (e) => e.text === 'Nieuwe match')[0];
  assert.equal(nieuwe.attrs.href, '#match', 'Nieuwe match opens the setup screen and removes nothing');
  const { asked, started } = startAgain(env, false);
  assert.deepEqual(asked, [], 'an ended match is not asked about');
  assert.equal(started.length, 1);
  assert.equal(env.raw('matchSetup').schedule, 'five');
});

// "Terug naar de match" at the top of the setup screen while a match runs (#48, P1-2 in docs/spikes/2026-ui-review.md).
const backLinks = (view) => find(view, 'a', (e) => e.text === 'Terug naar de match');
function setupView(env) {
  const view = new FakeElement('main');
  setupScreen(view, { store: env.store, onStart() {} });
  return view;
}

test('setup screen: "Terug naar de match" is the first thing under the title while a match runs, and leads to #start', () => {
  const { env, live } = startedUntouched();
  for (const tapped of [false, true]) {
    if (tapped) tapWissel(live);
    const view = setupView(env);
    const links = backLinks(view);
    assert.equal(links.length, 1, tapped ? 'saved match in play' : 'started, no tap yet');
    assert.equal(links[0].attrs.href, '#start');
    assert.ok(links[0].className.split(' ').includes('primary'), 'styled as a primary button');
    assert.deepEqual(view.children.slice(0, 2).map((c) => c.tag), ['h1', 'a']);
    assert.equal(view.children[1], links[0], 'right under the title, above everything else');
  }
  assert.match(liveTitle(openLive(env)), /^Blok 2 van /, 'the live screen it leads to resumes the saved block');
});

test('setup screen: no "Terug naar de match" with no match, an ended one or a damaged setup', () => {
  assert.equal(backLinks(openSetup().view).length, 0, 'no match yet');
  assert.equal(backLinks(openSetup({ players: 4 }).view).length, 0, 'fewer than 5 players, no match');
  const { env, live } = startedUntouched();
  playToEnd(env, live);
  assert.equal(backLinks(setupView(env)).length, 0, 'ended match');
  env.store.save('matchSetup', { damaged: true });
  assert.equal(backLinks(setupView(env)).length, 0, 'damaged setup');
});

test('setup screen: with fewer than 5 players left, a running match still shows the way back', () => {
  const { env } = startedUntouched();
  env.store.save('roster', rosterOf(4));
  const view = setupView(env);
  assert.match(pageText(view), /minstens 5 spelers/);
  assert.equal(backLinks(view)[0]?.attrs.href, '#start');
});

// ---------- team history on the setup screen (decision #10) ----------

const minutesById = (view) => Object.fromEntries(rows(view).map((r) => {
  const number = Number(find(r, 'span', (e) => e.className === 'number')[0].text.slice(1));
  const [m, sec] = r.children.at(-1).text.split(':').map(Number);
  return [number, m * 60 + sec];
}));

// 12 players, ids = numbers; players 1 to 4 never played, the others played 3000 seconds.
const sampleHistory = (useHistory) => ({
  useHistory,
  matches: [{ id: 'm1', seconds: Object.fromEntries(Array.from({ length: 12 }, (_, i) => [i + 1, i < 4 ? 0 : 3000])) }],
});

test('setup screen: with the switch on, the extra blocks go to the players with the fewest minutes so far', () => {
  for (let run = 0; run < 5; run++) { // a new random seed each time the screen opens
    const { view } = openSetup({ players: 12, history: sampleHistory(true) });
    assert.equal(historySwitch(view).checked, true, 'the saved switch is shown');
    radios(view)[1].fire('change'); // five: 40 places for 12 players, 4 extras
    pickFive(view);
    const minutes = minutesById(view);
    for (let p = 1; p <= 12; p++) assert.equal(minutes[p], p <= 4 ? 1200 : 900, `player ${p}`);
  }
});

test('setup screen: the switch toggles, is saved, and replans', () => {
  const { view, raw, store } = openSetup({ players: 12, history: sampleHistory(false) });
  assert.match(pageText(view), /Houd rekening met vorige matchen/);
  assert.equal(historySwitch(view).checked, false, 'off by default in this history');
  radios(view)[1].fire('change');
  pickFive(view);
  historySwitch(view).fire('change');
  assert.equal(raw('history').useHistory, true);
  assert.equal(historySwitch(view).checked, true);
  const minutes = minutesById(view);
  for (let p = 1; p <= 4; p++) assert.equal(minutes[p], 1200);
  const next = new FakeElement('main');
  setupScreen(next, { store, onStart() {} });
  assert.equal(historySwitch(next).checked, true, 'remembered for the next match');
  historySwitch(view).fire('change');
  assert.equal(raw('history').useHistory, false);
  assert.equal(raw('history').matches.length, 1, 'the switch changes nothing else');
});

test('setup screen: no history at all still plans, with the switch on or off', () => {
  const { view, raw } = openSetup({ players: 12 });
  assert.equal(historySwitch(view).checked, false);
  assert.match(pageText(view), /Nog geen matchen bewaard/);
  assert.equal(button(view, 'Wis geschiedenis').disabled, true);
  pickFive(view);
  historySwitch(view).fire('change');
  assert.equal(raw('history').useHistory, true);
  assert.equal(rows(view).length, 12);
});

test('setup screen: Wis geschiedenis asks first, and empties the history only when confirmed', () => {
  const { view, raw } = openSetup({ players: 12, history: sampleHistory(true) });
  assert.match(pageText(view), /1 match bewaard/);
  const asked = [];
  globalThis.window = { confirm: (q) => { asked.push(q); return false; } };
  button(view, 'Wis geschiedenis').fire('click');
  assert.equal(asked.length, 1);
  assert.match(asked[0], /geschiedenis/);
  assert.equal(raw('history').matches.length, 1, 'cancelled: nothing wiped');
  globalThis.window = { confirm: () => true };
  button(view, 'Wis geschiedenis').fire('click');
  const wiped = raw('history');
  assert.deepEqual({ ...wiped, clearedAt: null }, { useHistory: true, clearedAt: null, matches: [] });
  assert.ok(!Number.isNaN(Date.parse(wiped.clearedAt)), 'the moment of clearing is remembered');
  assert.match(pageText(view), /Geschiedenis gewist/);
  assert.match(pageText(view), /Nog geen matchen bewaard/);
});

test('setup screen: a damaged stored history is treated as empty', () => {
  for (const history of [42, 'x', [], { matches: 'x' }, { useHistory: 'yes', matches: [null, { id: 3 }] }]) {
    const { view } = openSetup({ players: 12, history });
    assert.equal(historySwitch(view).checked, false);
    pickFive(view);
    assert.equal(rows(view).length, 12);
  }
});

// ---------- home-screen hint (#11) ----------

test('isInstalled: true on the iOS home screen or in standalone display mode, false in a browser tab', () => {
  const media = (matches) => (query) => ({ matches: query === '(display-mode: standalone)' && matches });
  assert.equal(isInstalled({ navigator: { standalone: true } }), true, 'iOS home screen');
  assert.equal(isInstalled({ navigator: { standalone: false }, matchMedia: media(false) }), false, 'iOS Safari tab');
  assert.equal(isInstalled({ navigator: {}, matchMedia: media(true) }), true, 'installed elsewhere');
  assert.equal(isInstalled({ navigator: {}, matchMedia: media(false) }), false, 'browser tab elsewhere');
  assert.equal(isInstalled({}), false, 'neither API');
  assert.equal(isInstalled({ matchMedia: () => { throw new Error('no'); } }), false, 'a failing matchMedia');
});

const hints = (view) => find(view, 'p', (e) => e.className.split(' ').includes('install-hint'));

test('setup screen: the home-screen hint shows in a browser tab and says why, and not when installed', () => {
  for (const players of [12, 3]) {
    const tab = openSetup({ players, installed: false }).view;
    assert.equal(hints(tab).length, 1, `${players} players: one hint in a tab`);
    assert.match(hints(tab)[0].text, /beginscherm/);
    assert.match(hints(tab)[0].text, /zonder internet/);
    assert.match(hints(tab)[0].text, /bewaard/);
    assert.equal(hints(openSetup({ players, installed: true }).view).length, 0, `${players} players: no hint installed`);
  }
});

// Opens the setup screen in a browser tab on `store`, as a fresh page load would (#57).
function openTab(store) {
  const view = new FakeElement('main');
  setupScreen(view, { store, onStart: () => {}, installed: false });
  return view;
}

test('setup screen: Begrepen hides the home-screen hint, and it stays hidden after a reload (#57)', () => {
  for (const players of [12, 3]) {
    const env = memoryStore();
    env.store.save('roster', rosterOf(players));
    const view = openTab(env.store);
    assert.equal(hints(view).length, 1, `${players} players: the hint shows before Begrepen`);
    button(hints(view)[0], 'Begrepen').fire('click');
    assert.equal(hints(view).length, 0, `${players} players: Begrepen hides it at once`);
    assert.equal(env.raw('installTip'), true, 'the choice is saved on this device');
    assert.equal(hints(openTab(env.store)).length, 0, `${players} players: still hidden after a reload`);
  }
  // Installed, there is no hint and so no Begrepen, whatever was saved.
  const env = memoryStore();
  env.store.save('roster', rosterOf(12));
  const installed = new FakeElement('main');
  setupScreen(installed, { store: env.store, onStart: () => {}, installed: true });
  assert.equal(hints(installed).length, 0);
  assert.equal(env.data.has('vervanging.installTip.v1'), false);
});

test('setup screen: when storage fails or is missing, Begrepen keeps the hint shown and says why (#57)', () => {
  const memory = memoryStore();
  memory.store.save('roster', rosterOf(12));
  const rosterRaw = memory.data.get('vervanging.roster.v1');
  const failing = (getItem) => createStore({
    getItem,
    setItem: () => { throw new Error('QuotaExceededError'); },
    removeItem: () => {},
  });
  const cases = {
    'a refused write': failing((k) => (k === 'vervanging.roster.v1' ? rosterRaw : null)),
    'reads and writes that throw': failing((k) => {
      if (k === 'vervanging.roster.v1') return rosterRaw;
      throw new Error('SecurityError');
    }),
    'no storage at all': createStore(null),
  };
  for (const [name, store] of Object.entries(cases)) {
    const view = openTab(store);
    assert.equal(hints(view).length, 1, `${name}: the hint shows`);
    button(hints(view)[0], 'Begrepen').fire('click');
    assert.equal(hints(view).length, 1, `${name}: the hint stays after Begrepen`);
    assert.match(hints(view)[0].text, /Opslaan lukte niet/, `${name}: it says the choice was not saved`);
    assert.equal(hints(openTab(store)).length, 1, `${name}: and it shows again on the next load`);
  }
});

// ---------- offline: service worker, manifest, icons (#11) ----------
// These read the files in public/ (a separate pwa.test.js would fit better, but this issue owns only this test file
// and live.test.js).

const PUBLIC = fileURLToPath(new URL('..', import.meta.url));
const readPublic = (path) => readFileSync(join(PUBLIC, path));

// Every file the host serves from public/: what .assetsignore leaves (its patterns are simple globs on the file name).
function servedFiles() {
  const ignore = readPublic('.assetsignore').toString().split('\n').map((l) => l.trim()).filter((l) => l && !l.startsWith('#'))
    .map((glob) => new RegExp(`^${glob.replace(/[.+^${}()|[\]\\]/g, '\\$&').replace(/\*/g, '.*')}$`));
  const walk = (dir) => readdirSync(dir, { withFileTypes: true }).flatMap((d) =>
    (d.isDirectory() ? walk(join(dir, d.name)) : [relative(PUBLIC, join(dir, d.name)).split('\\').join('/')]));
  return walk(PUBLIC).filter((f) => f !== '.assetsignore' && !ignore.some((re) => re.test(basename(f))));
}

// Runs sw.js in a sandbox with fake caches and fetch; returns its handlers and what it did. Two workers given the same
// `stores` share one Cache Storage, as an old and a new version do in the browser; `server` gives each file's body.
function loadServiceWorker({
  source = readPublic('sw.js').toString(),
  stores = new Map([['vervanging-old', new Map()], ['other-app', new Map()]]),
  server = (url) => `body of ${url}`,
} = {}) {
  const listeners = {};
  const calls = { skipWaiting: 0, claim: 0, added: [], deleted: [], opened: [], fetched: [] };
  const origin = 'https://vervanging.test';
  const cacheFor = (name) => {
    if (!stores.has(name)) stores.set(name, new Map());
    const entries = stores.get(name);
    return {
      addAll: async (requests) => {
        for (const r of requests) { calls.added.push({ url: r.url, cache: r.cache }); entries.set(r.url, server(r.url)); }
      },
      match: async (key, { ignoreSearch = false } = {}) => {
        let url = typeof key === 'string' ? key : key.url;
        if (ignoreSearch) url = url.split('?')[0];
        return entries.get(url);
      },
    };
  };
  const sandbox = {
    URL,
    Request: class { constructor(url, init = {}) { this.url = url; this.cache = init.cache; } },
    caches: {
      open: async (name) => { calls.opened.push(name); return cacheFor(name); },
      keys: async () => [...stores.keys()],
      delete: async (name) => { calls.deleted.push(name); return stores.delete(name); },
    },
    fetch: async (request) => { calls.fetched.push(request.url); return `network ${request.url}`; },
    self: {
      location: new URL('/sw.js', origin),
      addEventListener: (type, fn) => { listeners[type] = fn; },
      skipWaiting: () => { calls.skipWaiting++; },
      clients: { claim: () => { calls.claim++; } },
    },
  };
  const context = vm.createContext(sandbox);
  vm.runInContext(source, context, { filename: 'sw.js' });
  const value = (name) => vm.runInContext(name, context);
  async function run(type, extra = {}) {
    const waits = [];
    let response;
    listeners[type]({ ...extra, waitUntil: (p) => waits.push(p), respondWith: (p) => { response = p; } });
    await Promise.all(waits);
    return response === undefined ? undefined : await response;
  }
  const request = (path, init = {}) => ({ url: new URL(path, origin).href, method: 'GET', mode: 'cors', ...init });
  return { listeners, calls, stores, origin, value, run, request };
}

test('service worker: caches exactly the files the page needs, and never a test file', () => {
  const { value } = loadServiceWorker();
  const assets = value('ASSETS');
  const expected = servedFiles().filter((f) => f !== 'sw.js').map((f) => (f === 'index.html' ? './' : f));
  assert.deepEqual([...assets].sort(), expected.sort(), 'ASSETS lists every served file (index.html as ./), nothing else');
  assert.equal(new Set(assets).size, assets.length, 'no file twice');
  assert.ok(!assets.some((a) => a.endsWith('.test.js')), 'no test file');
  assert.ok(!assets.includes('sw.js'), 'the worker does not cache itself');
});

test('service worker: every file the page links or imports is in its list', () => {
  const assets = new Set(loadServiceWorker().value('ASSETS'));
  const html = readPublic('index.html').toString();
  const refs = [...html.matchAll(/(?:href|src)="([^"#]+)"/g)].map((m) => m[1].replace(/^\//, ''));
  const manifest = JSON.parse(readPublic('manifest.webmanifest'));
  refs.push(...manifest.icons.map((i) => i.src.replace(/^\//, '')));
  for (const file of servedFiles().filter((f) => f.endsWith('.js') && f.startsWith('js/'))) {
    for (const m of readPublic(file).toString().matchAll(/^import [^;]*? from '\.\/([^']+)'/gm)) refs.push(`js/${m[1]}`);
  }
  assert.ok(refs.includes('js/app.js') && refs.includes('js/planner.js') && refs.includes('styles.css'), 'the scan finds links and imports');
  for (const ref of refs) assert.ok(assets.has(ref), `${ref} is cached`);
});

// The cache version sw.js must carry: sha256 over every cached file (its path, byte length and bytes, in ASSETS order)
// and over sw.js itself without its VERSION line, first 16 hex characters. Any change to a cached file or to the worker
// gives a new cache name, so a new version never writes into the cache the open app is using.
const VERSION_LINE = /^const VERSION = '[^']*';\n/m;
function cacheDigest(assets, read, swSource) {
  const hash = createHash('sha256');
  const add = (name, bytes) => { hash.update(`${name}\n${bytes.length}\n`); hash.update(bytes); };
  for (const path of assets) add(path, read(path === './' ? 'index.html' : path));
  add('sw.js', Buffer.from(swSource.replace(VERSION_LINE, '')));
  return hash.digest('hex').slice(0, 16);
}

test('service worker: VERSION is the digest of the cached files and the worker, so a release always gets a new cache', () => {
  const source = readPublic('sw.js').toString();
  assert.equal(source.match(new RegExp(VERSION_LINE.source, 'gm'))?.length, 1, "sw.js has one line: const VERSION = '...';");
  const assets = [...loadServiceWorker().value('ASSETS')];
  const expected = cacheDigest(assets, readPublic, source);
  assert.equal(loadServiceWorker().value('VERSION'), expected,
    `public/sw.js must name the digest of the files it caches. Set its VERSION line to:\nconst VERSION = '${expected}';`);
});

test('service worker digest: changes with any cached byte, the list or the worker, not with the VERSION line alone', () => {
  const files = { 'index.html': Buffer.from('<p>page</p>'), 'js/a.js': Buffer.from('a'), 'js/b.js': Buffer.from('b') };
  const read = (path) => files[path];
  const sw = "const VERSION = 'x';\nconst ASSETS = [];\n";
  const base = cacheDigest(['./', 'js/a.js', 'js/b.js'], read, sw);
  assert.match(base, /^[0-9a-f]{16}$/);
  assert.equal(cacheDigest(['./', 'js/a.js', 'js/b.js'], read, sw.replace("'x'", "'y'")), base, 'VERSION line excluded');
  assert.notEqual(cacheDigest(['./', 'js/a.js', 'js/b.js'], read, `${sw}// changed\n`), base, 'worker changed');
  assert.notEqual(cacheDigest(['./', 'js/a.js'], read, sw), base, 'a file left out');
  assert.notEqual(cacheDigest(['./', 'js/b.js', 'js/a.js'], read, sw), base, 'order');
  files['js/b.js'] = Buffer.from('B');
  assert.notEqual(cacheDigest(['./', 'js/a.js', 'js/b.js'], read, sw), base, 'one byte of a file');
  files['js/a.js'] = Buffer.from('ab');
  files['js/b.js'] = Buffer.from('');
  assert.notEqual(cacheDigest(['./', 'js/a.js', 'js/b.js'], read, sw), base, 'bytes moved between files');
});

test('service worker: an old and a new version keep separate caches; the open app keeps its files until the next start', async () => {
  const stores = new Map();
  const oldSource = readPublic('sw.js').toString();
  const newSource = oldSource.replace(VERSION_LINE, "const VERSION = 'next-release';\n");
  const old = loadServiceWorker({ source: oldSource, stores, server: (url) => `old ${url}` });
  await old.run('install');
  await old.run('activate');
  const live = old.request('/js/live.js');
  assert.equal(await old.run('fetch', { request: live }), `old ${live.url}`);

  const next = loadServiceWorker({ source: newSource, stores, server: (url) => `new ${url}` });
  await next.run('install'); // installed in the background, waiting: the old worker still controls the app
  assert.equal(await old.run('fetch', { request: live }), `old ${live.url}`, 'mid-match: still the old file');
  assert.equal(await old.run('fetch', { request: old.request('/', { mode: 'navigate' }) }), `old ${old.origin}/`);
  assert.deepEqual([...stores.keys()].sort(), [old.value('CACHE'), next.value('CACHE')].sort(), 'two caches side by side');
  assert.equal(next.calls.skipWaiting + next.calls.claim, 0, 'the new version does not take over by itself');

  await next.run('activate'); // the next app start, once no page uses the old version
  assert.deepEqual([...stores.keys()], [next.value('CACHE')], 'the old cache is removed');
  assert.equal(await next.run('fetch', { request: live }), `new ${live.url}`);
});

test('service worker: install stores the files fresh in a versioned cache and does not take over the open app', async () => {
  const { run, calls, value, origin } = loadServiceWorker();
  await run('install');
  const cache = value('CACHE');
  assert.match(cache, /^vervanging-.+/);
  assert.equal(cache, `vervanging-${value('VERSION')}`);
  assert.deepEqual(calls.opened, [cache]);
  assert.deepEqual(calls.added.map((a) => a.url).sort(), [...value('ASSETS')].map((a) => new URL(a, `${origin}/sw.js`).href).sort());
  assert.ok(calls.added.every((a) => a.cache === 'reload'), 'bypasses the HTTP cache');
  assert.equal(calls.skipWaiting, 0, 'a new version waits for the next app start');
  assert.ok(!/skipWaiting|clients\.claim|\.reload\(|navigate\(/.test(readPublic('sw.js').toString().replace(/\/\/.*$/gm, '')),
    'no skipWaiting, no claim, no page reload anywhere in the worker');
});

test('service worker: activating removes only the old caches of this app', async () => {
  const { run, calls, stores, value } = loadServiceWorker();
  await run('install');
  await run('activate');
  assert.deepEqual(calls.deleted, ['vervanging-old']);
  assert.ok(stores.has(value('CACHE')) && stores.has('other-app'));
  assert.equal(calls.claim, 0);
});

test('service worker: answers from the cache first, the page for / with any query, the network only for the rest', async () => {
  const { run, calls, request, origin } = loadServiceWorker();
  await run('install');
  const page = `body of ${origin}/`;
  assert.equal(await run('fetch', { request: request('/', { mode: 'navigate' }) }), page);
  assert.equal(await run('fetch', { request: request('/?utm=x', { mode: 'navigate' }) }), page);
  assert.equal(await run('fetch', { request: request('/index.html', { mode: 'navigate' }) }), page);
  assert.equal(await run('fetch', { request: request('/js/live.js') }), `body of ${origin}/js/live.js`);
  assert.equal(await run('fetch', { request: request('/icons/apple-touch-icon.png') }), `body of ${origin}/icons/apple-touch-icon.png`);
  assert.deepEqual(calls.fetched, [], 'offline-ready: nothing went to the network');
  assert.equal(await run('fetch', { request: request('/nope.txt') }), `network ${origin}/nope.txt`);
  assert.equal(await run('fetch', { request: request('/js/live.js', { method: 'POST' }) }), undefined, 'not a GET: left alone');
  assert.equal(await run('fetch', { request: { url: 'https://elsewhere.test/x.js', method: 'GET', mode: 'cors' } }), undefined,
    'another origin: left alone');
});

test('manifest and page: installable as "Vervanging" in Dutch, standalone from /, with an apple-touch-icon', () => {
  const manifest = JSON.parse(readPublic('manifest.webmanifest'));
  assert.equal(manifest.name, 'Vervanging');
  assert.equal(manifest.lang, 'nl');
  assert.equal(manifest.display, 'standalone');
  assert.equal(manifest.start_url, '/');
  const html = readPublic('index.html').toString();
  assert.match(html, /<link rel="manifest" href="\/manifest\.webmanifest">/);
  // Two theme colours (#62): the light accent for a light page, the dark page background for a dark one, so the
  // status bar does not show a blue band over the dark page. The manifest keeps the light one (it has no dark variant).
  const themes = [...html.matchAll(/<meta name="theme-color" content="(#[0-9a-f]{6})" media="\(prefers-color-scheme: (light|dark)\)">/g)]
    .map((m) => [m[2], m[1]]);
  assert.equal((html.match(/name="theme-color"/g) || []).length, 2, 'exactly two theme-color metas');
  const css = readPublic('styles.css').toString();
  const darkBg = css.match(/@media \(prefers-color-scheme: dark\)\s*\{\s*:root\s*\{[^}]*--bg:\s*(#[0-9a-f]{6})/)[1];
  assert.deepEqual(Object.fromEntries(themes), { light: manifest.theme_color, dark: darkBg });
  const touch = html.match(/<link rel="apple-touch-icon" href="\/([^"]+)">/);
  assert.ok(touch, 'apple-touch-icon link');
  const pngSize = (path) => {
    const png = readPublic(path);
    assert.deepEqual([...png.subarray(0, 8)], [137, 80, 78, 71, 13, 10, 26, 10], `${path} is a PNG`);
    return `${png.readUInt32BE(16)}x${png.readUInt32BE(20)}`;
  };
  assert.equal(pngSize(touch[1]), '180x180');
  assert.ok(manifest.icons.some((i) => i.sizes === '192x192') && manifest.icons.some((i) => i.sizes === '512x512'));
  for (const icon of manifest.icons) assert.equal(pngSize(icon.src.replace(/^\//, '')), icon.sizes, icon.src);
});

test('setup screen: with the switch on, a player who missed a match gets one block more in the plan (#28)', () => {
  const missed = {
    useHistory: true,
    matches: [
      { id: 'm1', seconds: Object.fromEntries(Array.from({ length: 12 }, (_, i) => [i + 1, 1000])) },
      { id: 'm2', seconds: Object.fromEntries(Array.from({ length: 11 }, (_, i) => [i + 1, 1000])) },
    ],
  };
  const { view } = openSetup({ players: 12, history: missed });
  pickFive(view);
  const minutes = minutesById(view);
  assert.equal(minutes[12], 1200, 'player 12 missed a match: one block more');
  assert.equal(Object.values(minutes).filter((m) => m === 800).length, 1, 'one player furthest ahead gives a block');
  historySwitch(view).fire('change'); // the switch replans with the same five
  assert.ok(Object.values(minutesById(view)).every((m) => m === 1000), 'switch off: equal minutes');
});

// ---------- Dutch quotes in the copy (#62, P3-10 in docs/spikes/2026-ui-review.md) ----------
// The no-plan message shows only when the planner throws, which a real setup does not reach (the planner always finds
// a plan for 5 to 15 players), so the copy is checked in the source.
test('copy: the no-plan message quotes the button with Dutch quotes, and no screen string uses straight double quotes', () => {
  const source = (file) => readFileSync(join(PUBLIC, 'js', file)).toString();
  assert.ok(source('setup.js').includes("'Er kon geen plan gemaakt worden. Probeer „Ander plan”.'"));
  for (const file of ['setup.js', 'live.js', 'app.js']) {
    // Single-quoted string literals (the screens' copy) outside comments, holding a straight double quote; a CSS
    // attribute selector such as input[name="name"] is code, not copy.
    const code = source(file).split('\n').filter((line) => !line.trim().startsWith('//')).join('\n');
    const straight = [...code.matchAll(/'((?:[^'\\\n]|\\.)*)'/g)].map((m) => m[1])
      .map((t) => t.replace(/\[[\w-]+="[^"]*"\]/g, '')).filter((t) => t.includes('"'));
    assert.deepEqual(straight, [], `${file}: no straight double quotes in a string`);
  }
});
