// Live match screen (#start): one tap per wissel, in the zone, uit and terug, undo, minutes so far, and the
// end-of-match minutes, with the screen kept awake during the match. Decisions: docs/PLAN.md #4, #8, #9, #11, #12,
// #17, #18, #27 (every player's minutes at a glance at the top). The match state (match.js) is saved after every tap and restored after a reload; a missing or damaged
// saved setup shows a Dutch message instead of breaking the page.

import { el, normaliseMatchSetup, formatSeconds, byNumber } from './setup.js';
import { SCHEDULES } from './planner.js';
import {
  startMatch, wissel, undo, uit, terug, canUndo, onCourt, nextChange, subTime, quarterOf, minutesSoFar, extraSeconds,
  normaliseMatchState, proposedBench, replacements, minutesOverview, MatchError,
} from './match.js';
import { normaliseHistory, recordMatch, forgetMatch, hasMatch, startedAfterClear } from './history.js';

const SAVE_FAILED = 'Opslaan lukte niet: de browser weigert opslag.';

// The Dutch line for when the current block ends: "Wissel op 6:40", "Einde kwart" or, in the last block, "Laatste blok"
// ("Einde match" is the end screen's heading and the button's label, so the line does not say it while play goes on).
export function subTimeText(state) {
  const time = subTime(state);
  if (time.kind === 'endMatch') return 'Laatste blok';
  if (time.kind === 'endQuarter') return 'Einde kwart';
  return `Wissel op ${formatSeconds(time.clockSeconds)}`;
}

// The plan the engine plays, built only from the parts normaliseMatchSetup checked (the schedule, the players and
// the grid), so a damaged block length or player list in the saved plan cannot reach the screen.
export function planOf(setup) {
  const { blocks, blockSeconds, blocksPerQuarter } = SCHEDULES[setup.schedule];
  return {
    schedule: setup.schedule, blocks, blockSeconds, blocksPerQuarter,
    players: setup.players.map((p) => p.id),
    grid: setup.plan.grid,
  };
}

// The saved match for this setup, or a new one at block 1 when there is none or it does not fit.
export function restoreMatch(store, setup) {
  const plan = planOf(setup);
  return normaliseMatchState(store.load('match'), plan, setup.savedAt) ?? startMatch(plan, setup.savedAt);
}

// Keeps the team history (decision #10) in line with the match after an action: an ended match is recorded under
// its setup's savedAt (replacing an earlier entry, so ending, undoing and ending again never counts it twice), and a
// match that is no longer ended (undo of the end) is removed again. A reload changes nothing: only actions call this.
// True when the history needed no write or was written.
export function syncHistory(store, setup, state) {
  if (!setup.savedAt) return true; // a setup without savedAt cannot be told apart from another, so it is not recorded
  const history = normaliseHistory(store.load('history'));
  if (state.ended) return store.save('history', recordMatch(history, setup.savedAt, minutesSoFar(state), extraSeconds(state)));
  if (!hasMatch(history, setup.savedAt)) return true;
  return store.save('history', forgetMatch(history, setup.savedAt));
}

// Run when the live screen opens: catches up a history write that the browser refused earlier, while the match state
// itself was saved. An ended match missing from the history is recorded, unless "Wis geschiedenis" ran after its
// Start (an old end screen must not refill a cleared history); a match that is no longer ended but still in the
// history (a refused removal after an undo) is removed. True when nothing was needed or the write worked.
export function repairHistory(store, setup, state) {
  if (!setup.savedAt) return true;
  const history = normaliseHistory(store.load('history'));
  const recorded = hasMatch(history, setup.savedAt);
  if (state.ended && !recorded && startedAfterClear(history, setup.savedAt)) {
    return store.save('history', recordMatch(history, setup.savedAt, minutesSoFar(state), extraSeconds(state)));
  }
  if (!state.ended && recorded) return store.save('history', forgetMatch(history, setup.savedAt));
  return true;
}

// Keeps the screen on during a match (decision #18) with the Screen Wake Lock API. set(true) asks for the lock,
// set(false) lets it go. The browser drops the lock when the page is hidden, so it is asked for again when the page
// is visible again and still wanted. Where the API is missing or refuses (low battery, page not visible) nothing
// happens and nothing is shown: the match works the same without it.
export function createWakeLock(nav, doc) {
  let wanted = false;
  let sentinel = null;
  let pending = false;

  const letGo = (lock) => { Promise.resolve().then(() => lock.release()).catch(() => {}); };

  async function acquire() {
    if (!wanted || sentinel || pending || !nav?.wakeLock || doc?.visibilityState === 'hidden') return;
    pending = true;
    try {
      const lock = await nav.wakeLock.request('screen');
      if (wanted) {
        sentinel = lock;
        lock.addEventListener?.('release', () => { if (sentinel === lock) sentinel = null; });
      } else {
        letGo(lock); // the match ended while the browser was still answering
      }
    } catch {
      // refused or not supported: the match goes on with the normal screen timeout
    } finally {
      pending = false;
    }
  }

  doc?.addEventListener?.('visibilitychange', () => { if (doc.visibilityState === 'visible') acquire(); });

  return {
    set(on) {
      wanted = on;
      if (on) return acquire();
      if (sentinel) { letGo(sentinel); sentinel = null; }
      return Promise.resolve();
    },
    get held() { return sentinel !== null; },
  };
}

let screenLock = null;

// The page's one wake lock: on while the live screen shows a match in progress, off otherwise (app.js turns it off
// when another screen opens).
export function keepScreenAwake(on) {
  screenLock ??= createWakeLock(globalThis.navigator, globalThis.document);
  return screenLock.set(on);
}

// A second Wissel (or Einde match) tap this soon after the first is ignored: the button is redrawn in the same spot and
// would otherwise take it as a second wissel, skipping a block, or ending the match from block 11 (#49).
export const DOUBLE_TAP_MS = 600;

// iOS Safari applies :active (the pressed state of buttons, #50) only when a touchstart listener exists on the page; an
// empty passive one is enough. ⚠ Not checked on a real iPhone.
let touchListening = false;
function listenForTouch() {
  if (touchListening) return;
  touchListening = true;
  globalThis.document?.addEventListener?.('touchstart', () => {}, { passive: true });
}

export function liveScreen(root, { store, keepAwake = keepScreenAwake, now = Date.now }) {
  listenForTouch();
  const setup = normaliseMatchSetup(store.load('matchSetup'));
  if (!setup) {
    keepAwake(false);
    root.replaceChildren(
      el('h1', {}, 'Geen match gevonden'),
      el('p', { className: 'note' }, 'De opgeslagen match kon niet gelezen worden. Stel de match opnieuw in.'),
      el('a', { className: 'button primary', href: '#match' }, 'Naar de match'));
    return;
  }
  const byId = new Map(setup.players.map((p) => [p.id, p]));
  let state = restoreMatch(store, setup);
  let message = repairHistory(store, setup, state) ? '' : SAVE_FAILED;
  let confirmed = false; // true when `message` is a confirmation line, not an error
  let zone = null; // in the zone or extra minuten, chosen but not yet applied: { keep, bench, extra }
  let lastWisselAt = -Infinity; // when the last Wissel tap that counted came, on the `now` clock

  // Applies one engine action, saves the new state and redraws; an action the engine refuses shows its reason.
  // A successful action writes its confirmation line (#50), made by `confirm` from the state before and after; a
  // refused write or action keeps its error text instead. The line stays until the next action replaces it (a tap on
  // In the zone or Op de bank keeps it); a reload starts without it.
  function act(step, confirm) {
    const before = state;
    confirmed = false;
    try {
      state = step();
      const saved = store.save('match', state);
      if (!(syncHistory(store, setup, state) && saved)) message = SAVE_FAILED;
      else {
        message = confirm(before, state);
        confirmed = message !== '';
      }
    } catch (error) {
      if (!(error instanceof MatchError)) throw error;
      message = 'Dat kan nu niet.';
    }
    zone = null;
    render();
  }

  function tapWissel() {
    const at = now();
    if (at - lastWisselAt < DOUBLE_TAP_MS) return;
    lastWisselAt = at;
    act(() => wissel(state, zone ? { keep: zone.keep, bench: zone.bench, extra: zone.extra } : {}), wisselLine);
  }

  // The confirmation lines (#50), worded as the owner approved them. Players are written as on screen: "#11 Hanne".
  const label = (id) => `#${byId.get(id).number} ${byId.get(id).name}`;
  const cameOn = (before, after) => sortedPlayers(onCourt(after).filter((id) => !onCourt(before).includes(id)));
  // The Einde match tap shows the end screen itself, so it writes no line.
  const wisselLine = (before, after) => (after.ended ? ''
    : `Wissel gedaan: blok ${after.block}. Erin: ${cameOn(before, after).map(label).join(', ')}.`);
  const uitLine = (id) => (before, after) => {
    const replacement = cameOn(before, after)[0];
    return replacement === undefined ? `${label(id)} uit.` : `${label(id)} uit, ${label(replacement)} erin.`;
  };
  const terugLine = (id) => () => `${label(id)} terug vanaf het volgende blok.`;
  const undoLine = () => 'Ongedaan gemaakt.';

  // In the zone on a row chooses that player, or cancels the choice when the player was already chosen (also after
  // switching to Extra minuten). Extra minuten is only a toggle in the zone note, for the chosen player: it keeps the
  // bench player, so switching to it and back changes nothing else (#52, P2-4 in docs/spikes/2026-ui-review.md).
  function toggleZone(keep) {
    zone = zone && zone.keep === keep ? null : { keep, bench: proposedBench(state), extra: false };
    render();
  }

  function toggleExtra() {
    if (zone) zone = { ...zone, extra: !zone.extra };
    render();
  }

  function chooseBench(bench) {
    if (zone) zone = { ...zone, bench };
    render();
  }

  const name = (id) => {
    const p = byId.get(id);
    return el('span', { className: 'player' }, el('span', { className: 'number' }, `#${p.number}`), ' ', p.name);
  };
  const sortedPlayers = (ids) => ids.map((id) => byId.get(id)).sort(byNumber).map((p) => p.id);
  // A row with buttons (In the zone, Op de bank) puts the name on its own line and the buttons under
  // it, so the name is never squeezed to nothing in a half-width column (#46).
  const nameList = (ids, className, extra = () => null) => el('ul', { className: `names ${className}` },
    sortedPlayers(ids).map((id) => {
      const buttons = extra(id);
      return buttons
        ? el('li', { className: 'with-chips' }, name(id), el('span', { className: 'chips' }, buttons))
        : el('li', {}, name(id));
    }));
  const isOut = (id) => state.out.includes(id);

  function minutesTable(heading) {
    const minutes = minutesSoFar(state);
    const court = state.ended ? [] : onCourt(state);
    return el('table', { className: 'minutes' },
      el('caption', {}, heading),
      el('thead', {}, el('tr', {},
        el('th', { scope: 'col' }, 'Speler'),
        el('th', { scope: 'col', className: 'min' }, 'Minuten'))),
      el('tbody', {}, sortedPlayers(setup.players.map((p) => p.id)).map((id) =>
        el('tr', { className: court.includes(id) ? 'on' : isOut(id) ? 'out' : null },
          el('th', { scope: 'row' }, name(id),
            court.includes(id) && el('span', { className: 'visually-hidden' }, ' (op het veld)'),
            isOut(id) && el('span', { className: 'tag' }, ' uit')),
          el('td', { className: 'min' }, formatSeconds(minutes[id])),
          !state.ended && el('td', { className: 'act' }, isOut(id)
            ? canTerug() && el('button', { type: 'button', className: 'chip', onclick: () => act(() => terug(state, id), terugLine(id)) }, 'Terug')
            : el('button', { type: 'button', className: 'chip', onclick: () => act(() => uit(state, id), uitLine(id)) }, 'Uit'))))));
  }

  // Every player's minutes at a glance (decision #27): a dense grid of small cells in jersey order, number above
  // minutes, players on court marked, so all of them fit on a phone without scrolling. The full table stays below.
  function overview() {
    const entries = new Map(minutesOverview(state).map((e) => [e.player, e]));
    return el('ol', { className: 'overview', 'aria-label': 'Minuten tot nu per speler' },
      sortedPlayers(setup.players.map((p) => p.id)).map((id) => {
        const e = entries.get(id);
        return el('li', { className: e.onCourt ? 'on' : e.out ? 'out' : null },
          el('span', { className: 'number' }, `#${byId.get(id).number}`),
          el('span', { className: 'min' }, formatSeconds(e.seconds)),
          e.onCourt && el('span', { className: 'visually-hidden' }, ' (op het veld)'),
          e.out && el('span', { className: 'visually-hidden' }, ' (uit)'));
      }));
  }

  // Uit works at any time during the match (on court, a replacement comes on at once). Terug takes effect from the
  // next block, so it is offered while a next block exists.
  const canTerug = () => !state.ended && state.block < state.blocks;

  const undoButton = () => el('button', { type: 'button', className: 'undo', disabled: !canUndo(state), onclick: () => act(() => undo(state), undoLine) },
    'Ongedaan maken');
  const status = () => el('p', { className: 'message', role: confirmed ? 'status' : 'alert' }, message);

  function playing() {
    const change = nextChange(state);
    return [
      el('h1', {}, `Blok ${state.block} van ${state.blocks}`,
        ' ', el('span', { className: 'count' }, `kwart ${quarterOf(state)}`)),
      setup.opponent && el('p', { className: 'note' }, `Tegen ${setup.opponent}`),
      el('p', { className: 'sub-time' }, subTimeText(state)),
      overview(),
      el('section', { 'aria-labelledby': 'h-court' },
        el('h2', { id: 'h-court' }, 'Op het veld'),
        nameList(onCourt(state), 'court'),
        replacements(state).map(([starter, replacement]) => el('p', { className: 'note replaced' },
          name(replacement), ' kwam erin voor ', name(starter), ' (uit). Het blok telt voor ', name(starter), '.'))),
      change && el('section', { 'aria-labelledby': 'h-next', className: 'next' },
        el('h2', { id: 'h-next' }, 'Bij de volgende wissel'),
        el('div', { className: 'change' },
          el('div', {}, el('h3', {}, 'Eruit'), change.off.length
            ? nameList(change.off, 'off', (id) => !isOut(id) && el('button', {
              type: 'button', className: 'chip', 'aria-pressed': zone && zone.keep === id ? 'true' : 'false',
              onclick: () => toggleZone(id),
            }, 'In the zone'))
            : el('p', { className: 'note' }, 'Niemand')),
          el('div', {}, el('h3', {}, 'Erin'), change.on.length
            ? nameList(change.on, 'on', (id) => zone && el('button', {
              type: 'button', className: 'chip', 'aria-pressed': zone.bench === id ? 'true' : 'false',
              onclick: () => chooseBench(id),
            }, 'Op de bank'))
            : el('p', { className: 'note' }, 'Niemand'))),
        zone && el('div', { className: 'zone-note' },
          zone.extra
            ? el('p', {}, name(zone.keep), ' speelt een extra blok (extra minuten, niet teruggegeven), ', name(zone.bench), ' blijft op de bank.')
            : el('p', {}, name(zone.keep), ' blijft in the zone op het veld, ', name(zone.bench), ' blijft op de bank.'),
          el('button', {
            type: 'button', className: 'chip extra', 'aria-pressed': zone.extra ? 'true' : 'false', onclick: toggleExtra,
          }, 'Extra minuten (niet teruggeven)'))),
      status(),
      el('div', { className: 'live-actions' },
        el('button', {
          type: 'button', className: 'primary wissel', onclick: tapWissel,
        }, subTime(state).kind === 'endMatch' ? 'Einde match' : 'Wissel'),
        undoButton()),
      minutesTable('Minuten tot nu'),
    ];
  }

  function ended() {
    return [
      el('h1', {}, 'Einde match'),
      setup.opponent && el('p', { className: 'note' }, `Tegen ${setup.opponent}`),
      status(),
      minutesTable('Minuten per speler'),
      el('div', { className: 'form-actions' },
        undoButton(),
        el('a', { className: 'button primary', href: '#match' }, 'Nieuwe match')),
    ];
  }

  function render() {
    keepAwake(!state.ended);
    root.replaceChildren(...(state.ended ? ended() : playing()).filter(Boolean));
  }

  render();
}
