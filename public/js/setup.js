// Roster and match setup screens (docs/PLAN.md decisions #7, #14, #19, #20).
// Roster entries carry a stable numeric id; the planner works with those ids, the screen shows names and numbers.

import { makePlan, swapPlayers, planStats, PlanError, ON_COURT, SCHEDULES } from './planner.js';
import { normaliseHistory, clearHistory, catchUp, seasonSummary } from './history.js';

export const MAX_PLAYERS = 15;
const MAX_NAME = 20;

// ---------- pure helpers (no DOM) ----------

// A roster read from the store, cleaned so a damaged value never breaks the screen.
export function normaliseRoster(raw) {
  const players = [];
  const seen = new Set();
  for (const p of Array.isArray(raw?.players) ? raw.players : []) {
    if (!Number.isInteger(p?.id) || seen.has(p.id)) continue;
    if (typeof p.name !== 'string' || !p.name.trim() || typeof p.number !== 'string' || !/^\d{1,2}$/.test(p.number)) continue;
    seen.add(p.id);
    players.push({ id: p.id, name: p.name, number: p.number });
  }
  const maxId = players.reduce((m, p) => Math.max(m, p.id), 0);
  const nextId = Number.isInteger(raw?.nextId) && raw.nextId > maxId ? raw.nextId : maxId + 1;
  return { nextId, players: players.slice(0, MAX_PLAYERS) };
}

export function byNumber(a, b) {
  return Number(a.number) - Number(b.number) || a.number.length - b.number.length || a.name.localeCompare(b.name, 'nl');
}

// A Dutch error message for the entry, or null when it can be saved. `editingId` is the player being edited.
export function checkPlayer(roster, { name, number }, editingId = null) {
  if (editingId == null && roster.players.length >= MAX_PLAYERS) return `Maximaal ${MAX_PLAYERS} spelers.`;
  if (!name) return 'Vul een voornaam in.';
  if (name.length > MAX_NAME) return `Een voornaam heeft hoogstens ${MAX_NAME} tekens.`;
  if (!/^\d{1,2}$/.test(number)) return 'Vul een rugnummer van 0 tot 99 in.';
  const taken = roster.players.find((p) => p.number === number && p.id !== editingId);
  if (taken) return `Rugnummer ${number} is al van ${taken.name}.`;
  return null;
}

export function addPlayer(roster, { name, number }) {
  return { nextId: roster.nextId + 1, players: [...roster.players, { id: roster.nextId, name, number }] };
}

export function editPlayer(roster, id, { name, number }) {
  return { ...roster, players: roster.players.map((p) => (p.id === id ? { id, name, number } : p)) };
}

export function removePlayer(roster, id) {
  return { ...roster, players: roster.players.filter((p) => p.id !== id) };
}

// The last attendance read from the store: a list of player ids, or null when there is none or it is damaged.
export function normaliseAttendance(raw) {
  return Array.isArray(raw) ? raw.filter((id) => Number.isInteger(id)) : null;
}

// Who is ticked present when setup opens: the last match's selection, or everyone when there is none yet.
export function initialAttendance(roster, raw) {
  const ids = roster.players.map((p) => p.id);
  const last = normaliseAttendance(raw);
  if (!last) return ids;
  return ids.filter((id) => last.includes(id));
}

// A match setup read from the store, or null when it is missing or its shape is damaged, so no screen
// (the live screen, live.js) ever renders from broken data.
export function normaliseMatchSetup(raw) {
  if (!raw || typeof raw !== 'object' || Array.isArray(raw)) return null;
  const { players: rawPlayers, startingFive, plan, schedule, opponent = '', seed, savedAt } = raw;
  if (!Array.isArray(rawPlayers) || !Array.isArray(startingFive) || !Object.hasOwn(SCHEDULES, String(schedule))) return null;
  if (typeof opponent !== 'string') return null;
  const roster = normaliseRoster({ players: rawPlayers });
  if (roster.players.length !== rawPlayers.length || roster.players.length < ON_COURT) return null;
  const ids = new Set(roster.players.map((p) => p.id));
  const isFive = (court) => Array.isArray(court) && court.length === ON_COURT && new Set(court).size === ON_COURT
    && court.every((id) => ids.has(id));
  if (!isFive(startingFive)) return null;
  const { blocks } = SCHEDULES[schedule];
  if (!plan || typeof plan !== 'object' || !Array.isArray(plan.grid) || plan.grid.length !== blocks
    || !plan.grid.every(isFive) || !Array.isArray(plan.start) || !isFive(plan.start)) return null;
  return {
    savedAt: typeof savedAt === 'string' ? savedAt : null,
    opponent,
    schedule,
    seed: Number.isInteger(seed) ? seed : null,
    players: roster.players,
    startingFive: startingFive.slice(),
    plan,
  };
}

export function formatSeconds(seconds) {
  const s = Math.max(0, Math.round(seconds));
  return `${Math.floor(s / 60)}:${String(s % 60).padStart(2, '0')}`;
}

// A season total: m:ss, or h:mm:ss from an hour on.
export function formatDuration(seconds) {
  const s = Math.max(0, Math.round(Number.isFinite(seconds) ? seconds : 0));
  if (s < 3600) return formatSeconds(s);
  const m = Math.floor(s / 60) % 60;
  return `${Math.floor(s / 3600)}:${String(m).padStart(2, '0')}:${String(s % 60).padStart(2, '0')}`;
}

// The line above the roster that says what the totals behind each name are (decision #26).
export function seasonNote(matches) {
  if (matches === 0) return 'Speeltijd dit seizoen: nog geen matchen bewaard.';
  return `Speeltijd dit seizoen, over ${matches} bewaarde ${matches === 1 ? 'match' : 'matchen'}.`;
}

export function playerLabel(p) {
  return `#${p.number} ${p.name}`;
}

function newSeed() {
  return Math.floor(Math.random() * 0xffffffff) + 1;
}

// ---------- DOM helpers ----------

export function el(tag, props = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(props)) {
    if (value == null || value === false) continue;
    if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (key === 'className') node.className = value;
    else if (key in node && typeof value !== 'string') node[key] = value;
    else node.setAttribute(key, value === true ? '' : value);
  }
  node.append(...children.flat().filter((c) => c != null && c !== false));
  return node;
}

// ---------- roster screen ----------

export function rosterScreen(root, { store }) {
  let roster = normaliseRoster(store.load('roster'));
  // Season totals from the team history (decision #26); "Wis geschiedenis" on the Match screen resets them.
  const season = seasonSummary(normaliseHistory(store.load('history')));
  let editingId = null;
  let message = '';

  function persist(next) {
    roster = next;
    if (!store.save('roster', roster)) message = 'Opslaan lukte niet: de browser weigert opslag.';
  }

  function submit(event) {
    event.preventDefault();
    const form = event.currentTarget;
    const entry = { name: form.elements.name.value.trim(), number: form.elements.number.value.trim() };
    const error = checkPlayer(roster, entry, editingId);
    if (error) {
      message = error;
      render(form.elements.name.value, form.elements.number.value);
      return;
    }
    message = '';
    persist(editingId == null ? addPlayer(roster, entry) : editPlayer(roster, editingId, entry));
    editingId = null;
    render();
  }

  function remove(p) {
    if (!window.confirm(`${playerLabel(p)} verwijderen?`)) return;
    if (editingId === p.id) editingId = null;
    message = '';
    persist(removePlayer(roster, p.id));
    render();
  }

  function render(nameDraft, numberDraft) {
    const editing = roster.players.find((p) => p.id === editingId) ?? null;
    const full = !editing && roster.players.length >= MAX_PLAYERS;
    const form = full
      ? el('p', { className: 'note' }, `Maximaal ${MAX_PLAYERS} spelers. Verwijder eerst een speler om er een toe te voegen.`)
      : el('form', { className: 'player-form', onsubmit: submit, novalidate: true },
        el('label', { className: 'field field-name' }, 'Voornaam',
          el('input', { name: 'name', type: 'text', autocomplete: 'off', autocapitalize: 'words', maxlength: String(MAX_NAME),
            value: nameDraft ?? editing?.name ?? '' })),
        el('label', { className: 'field field-number' }, 'Rugnummer',
          el('input', { name: 'number', type: 'text', inputmode: 'numeric', pattern: '[0-9]*', maxlength: '2', autocomplete: 'off',
            value: numberDraft ?? editing?.number ?? '' })),
        el('div', { className: 'form-actions' },
          el('button', { type: 'submit', className: 'primary' }, editing ? 'Bewaren' : 'Toevoegen'),
          editing && el('button', { type: 'button', onclick: () => { editingId = null; message = ''; render(); } }, 'Annuleren')));

    const list = roster.players.length === 0
      ? el('p', { className: 'note' }, 'Nog geen spelers. Voeg je spelers toe met voornaam en rugnummer.')
      : el('ul', { className: 'roster' }, roster.players.slice().sort(byNumber).map((p) =>
        el('li', { className: p.id === editingId ? 'editing' : null },
          el('span', { className: 'player' }, el('span', { className: 'number' }, `#${p.number}`), ' ', p.name),
          el('span', { className: 'number season-total' },
            el('span', { className: 'visually-hidden' }, 'speeltijd '), formatDuration(season.totals[String(p.id)] ?? 0)),
          el('button', { type: 'button', onclick: () => { editingId = p.id; message = ''; render(); } }, 'Wijzig'),
          el('button', { type: 'button', className: 'danger', onclick: () => remove(p) }, 'Verwijder'))));

    root.replaceChildren(
      el('h1', {}, 'Spelers ', el('span', { className: 'count' }, `${roster.players.length} van ${MAX_PLAYERS}`)),
      form,
      el('p', { className: 'message', role: 'alert' }, message),
      ...(roster.players.length > 0 ? [el('p', { className: 'note season-note' }, seasonNote(season.matches))] : []),
      list,
    );
    if (editing || nameDraft != null) root.querySelector('input[name="name"]')?.focus();
  }

  render();
}

// ---------- match setup screen ----------

// ---------- home-screen hint ----------

// True when the app runs from the home screen (installed): iOS sets navigator.standalone, other browsers match the
// display-mode media query of the manifest's "standalone".
export function isInstalled(env = globalThis) {
  if (env.navigator?.standalone === true) return true;
  try {
    return env.matchMedia?.('(display-mode: standalone)')?.matches === true;
  } catch {
    return false;
  }
}

// Shown on the match setup screen in a browser tab: on the home screen the app opens without internet and the browser
// keeps its saved data (⚠ iOS Safari may clear the data of a site that is not on the home screen; see docs/PLAN.md ›
// Risks).
export function installHint() {
  return el('p', { className: 'note install-hint' },
    'Tip: zet Vervanging op je beginscherm (in Safari: Deel › Zet op beginscherm). ',
    'Dan werkt de app ook zonder internet en blijven je spelers en geschiedenis bewaard.');
}

export function setupScreen(root, { store, onStart, installed = isInstalled() }) {
  const roster = normaliseRoster(store.load('roster'));
  const players = roster.players.slice().sort(byNumber);
  const byId = new Map(players.map((p) => [p.id, p]));
  const present = new Set(initialAttendance(roster, store.load('attendance')));
  let start = [];
  let schedule = 'equal';
  let opponent = '';
  let seed = newSeed();
  let history = normaliseHistory(store.load('history'));
  let plan = null;
  let selected = null;
  let message = '';

  function replan() {
    selected = null;
    plan = null;
    if (start.length !== ON_COURT || present.size < ON_COURT) return;
    try {
      const ids = players.filter((p) => present.has(p.id)).map((p) => p.id);
      const { priority, moves } = history.useHistory
        ? catchUp(history, ids, SCHEDULES[schedule], seed) : { priority: [], moves: [] };
      plan = makePlan({ players: ids, start, schedule, seed, extraPriority: priority, moves });
    } catch (error) {
      if (!(error instanceof PlanError)) throw error;
      message = 'Er kon geen plan gemaakt worden. Probeer "Ander plan".';
    }
  }

  function togglePresent(id) {
    if (present.has(id)) {
      present.delete(id);
      start = start.filter((s) => s !== id);
    } else {
      present.add(id);
    }
    message = '';
    replan();
    render();
  }

  function toggleStart(id) {
    if (start.includes(id)) start = start.filter((s) => s !== id);
    else if (start.length < ON_COURT && present.has(id)) start = [...start, id];
    message = '';
    replan();
    render();
  }

  function tapRow(id) {
    if (selected == null) {
      selected = id;
      message = '';
    } else if (selected === id) {
      selected = null;
    } else {
      try {
        plan = swapPlayers(plan, selected, id);
        message = `${byId.get(selected).name} en ${byId.get(id).name} geruild.`;
      } catch (error) {
        if (!(error instanceof PlanError)) throw error;
        message = 'Ruil twee spelers van de basisvijf, of twee spelers die niet in de basisvijf staan.';
      }
      selected = null;
    }
    render();
  }

  // The switch and "Wis geschiedenis" (decision #10). The switch is remembered with the history. True when saved.
  function saveHistory(next) {
    history = next;
    const ok = store.save('history', history);
    if (!ok) message = 'Opslaan lukte niet: de browser weigert opslag.';
    return ok;
  }

  function toggleHistory() {
    message = '';
    saveHistory({ ...history, useHistory: !history.useHistory });
    replan();
    render();
  }

  function wipeHistory() {
    if (!window.confirm('De geschiedenis van alle vorige matchen wissen?')) return;
    message = '';
    if (saveHistory(clearHistory(history, new Date().toISOString()))) message = 'Geschiedenis gewist.';
    replan();
    render();
  }

  function startMatch() {
    const setup = {
      savedAt: new Date().toISOString(),
      opponent: opponent.trim(),
      schedule,
      seed,
      players: players.filter((p) => present.has(p.id)),
      startingFive: plan.start.slice(),
      plan,
    };
    const ok = store.save('matchSetup', setup) && store.save('attendance', [...present]);
    if (!ok) {
      message = 'Opslaan lukte niet: de browser weigert opslag.';
      render();
      return;
    }
    onStart(setup);
  }

  function attendanceSection() {
    return el('section', { 'aria-labelledby': 'h-attendance' },
      el('h2', { id: 'h-attendance' }, 'Aanwezig en basisvijf'),
      el('p', { className: 'note' },
        `Aanwezig: ${present.size} · Basisvijf: ${start.length} van ${ON_COURT}`),
      el('ul', { className: 'attendance' }, players.map((p) => {
        const isPresent = present.has(p.id);
        const inStart = start.includes(p.id);
        return el('li', {},
          el('label', { className: 'check' },
            el('input', { type: 'checkbox', checked: isPresent, onchange: () => togglePresent(p.id) }),
            el('span', { className: 'player' }, el('span', { className: 'number' }, `#${p.number}`), ' ', p.name)),
          el('button', {
            type: 'button',
            className: inStart ? 'toggle on' : 'toggle',
            'aria-pressed': inStart ? 'true' : 'false',
            disabled: !isPresent || (!inStart && start.length >= ON_COURT),
            onclick: () => toggleStart(p.id),
          }, 'Basis'));
      })));
  }

  function scheduleSection() {
    const option = (value, text) => el('label', { className: 'choice' },
      el('input', { type: 'radio', name: 'schedule', value, checked: schedule === value,
        onchange: () => { schedule = value; message = ''; replan(); render(); } }),
      el('span', {}, text));
    return el('section', { 'aria-labelledby': 'h-schedule' },
      el('h2', { id: 'h-schedule' }, 'Schema'),
      el('div', { className: 'choices' },
        option('equal', 'Gelijke minuten'),
        option('five', 'Blokken van 5 minuten')));
  }

  function historySection() {
    const count = history.matches.length;
    return el('section', { 'aria-labelledby': 'h-history' },
      el('h2', { id: 'h-history' }, 'Vorige matchen'),
      el('label', { className: 'check' },
        el('input', { type: 'checkbox', name: 'useHistory', checked: history.useHistory, onchange: toggleHistory }),
        el('span', {}, 'Houd rekening met vorige matchen')),
      el('p', { className: 'note' }, count === 0
        ? 'Nog geen matchen bewaard.'
        : `${count} ${count === 1 ? 'match' : 'matchen'} bewaard. Aan: de extra blokken gaan naar wie in vorige matchen het minst speelde.`),
      el('div', { className: 'form-actions' },
        el('button', { type: 'button', className: 'danger', disabled: count === 0, onclick: wipeHistory }, 'Wis geschiedenis')));
  }

  function opponentSection() {
    return el('section', {},
      el('label', { className: 'field' }, 'Tegenstander (niet verplicht)',
        el('input', { type: 'text', autocomplete: 'off', maxlength: '40', value: opponent,
          oninput: (event) => { opponent = event.target.value; } })));
  }

  function planGrid() {
    const stats = planStats(plan);
    const rows = [...plan.start, ...plan.players.filter((id) => !plan.start.includes(id))]
      .map((id) => byId.get(id));
    const sorted = [...rows.slice(0, ON_COURT).sort(byNumber), ...rows.slice(ON_COURT).sort(byNumber)];
    const quarterStart = (b) => b > 0 && b % plan.blocksPerQuarter === 0;
    return el('table', { className: 'plan' },
      el('caption', { className: 'visually-hidden' }, 'Plan: spelers per blok, met de geplande minuten'),
      el('thead', {}, el('tr', {},
        el('th', { scope: 'col', className: 'name' }, 'Speler'),
        Array.from({ length: plan.blocks }, (_, b) =>
          el('th', { scope: 'col', className: quarterStart(b) ? 'block q' : 'block' }, String(b + 1))),
        el('th', { scope: 'col', className: 'min' }, 'Min'))),
      el('tbody', {}, sorted.map((p, i) => el('tr', {
        className: [i === ON_COURT - 1 ? 'last-start' : '', p.id === selected ? 'selected' : ''].join(' ').trim() || null,
      },
      el('th', { scope: 'row', className: 'name' },
        el('button', { type: 'button', 'aria-pressed': p.id === selected ? 'true' : 'false', onclick: () => tapRow(p.id) },
          el('span', { className: 'number' }, `#${p.number}`), ' ', p.name)),
      plan.grid.map((court, b) => {
        const on = court.includes(p.id);
        return el('td', { className: ['block', on ? 'on' : '', quarterStart(b) ? 'q' : ''].join(' ').trim() },
          el('span', { className: 'visually-hidden' }, on ? 'speelt' : 'bank'));
      }),
      el('td', { className: 'min' }, formatSeconds(stats.minutes[p.id]))))));
  }

  function planSection() {
    const status = el('p', { className: 'message', role: 'status' }, message);
    if (present.size < ON_COURT) {
      return el('section', { 'aria-labelledby': 'h-plan' }, el('h2', { id: 'h-plan' }, 'Plan'),
        el('p', { className: 'note' }, `Vink minstens ${ON_COURT} aanwezige spelers aan.`), status);
    }
    if (!plan) {
      return el('section', { 'aria-labelledby': 'h-plan' }, el('h2', { id: 'h-plan' }, 'Plan'),
        el('p', { className: 'note' }, `Kies precies ${ON_COURT} spelers voor de basisvijf om het plan te zien.`), status);
    }
    return el('section', { 'aria-labelledby': 'h-plan' },
      el('h2', { id: 'h-plan' }, 'Plan'),
      el('p', { className: 'note' },
        'Tik twee spelers aan om hun rijen te ruilen: twee van de basisvijf, of twee die er niet in staan.'),
      status,
      planGrid(),
      el('div', { className: 'form-actions' },
        el('button', { type: 'button', onclick: () => { seed = newSeed(); message = ''; replan(); render(); } }, 'Ander plan'),
        el('button', { type: 'button', className: 'primary', onclick: startMatch }, 'Start')));
  }

  function render() {
    if (players.length < ON_COURT) {
      root.replaceChildren(...[
        el('h1', {}, 'Match'),
        el('p', { className: 'note' }, `Voeg eerst minstens ${ON_COURT} spelers toe bij Spelers.`),
        el('a', { className: 'button primary', href: '#spelers' }, 'Naar Spelers'),
        !installed && installHint()].filter(Boolean));
      return;
    }
    root.replaceChildren(...[
      el('h1', {}, 'Match'),
      !installed && installHint(),
      attendanceSection(),
      scheduleSection(),
      historySection(),
      opponentSection(),
      planSection(),
    ].filter(Boolean));
  }

  render();
}
