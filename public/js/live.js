// Live match screen (#start): one tap per wissel, in the zone, uit and terug, undo, minutes so far, and the
// end-of-match minutes. Decisions: docs/PLAN.md #4, #8, #9, #11, #12, #17, #18. The match state (match.js) is saved after every tap and restored after a
// reload; a missing or damaged saved setup shows a Dutch message instead of breaking the page.

import { el, normaliseMatchSetup, formatSeconds, byNumber } from './setup.js';
import { SCHEDULES } from './planner.js';
import {
  startMatch, wissel, undo, uit, terug, canUndo, onCourt, nextChange, subTime, quarterOf, minutesSoFar,
  normaliseMatchState, proposedBench, replacements, MatchError,
} from './match.js';

const SAVE_FAILED = 'Opslaan lukte niet: de browser weigert opslag.';

// The Dutch line for when the current block ends: "Wissel op 6:40", "Einde kwart" or "Einde match".
export function subTimeText(state) {
  const time = subTime(state);
  if (time.kind === 'endMatch') return 'Einde match';
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

export function liveScreen(root, { store }) {
  const setup = normaliseMatchSetup(store.load('matchSetup'));
  if (!setup) {
    root.replaceChildren(
      el('h1', {}, 'Geen match gevonden'),
      el('p', { className: 'note' }, 'De opgeslagen match kon niet gelezen worden. Stel de match opnieuw in.'),
      el('a', { className: 'button primary', href: '#match' }, 'Naar de match'));
    return;
  }
  const byId = new Map(setup.players.map((p) => [p.id, p]));
  let state = restoreMatch(store, setup);
  let message = '';
  let zone = null; // in the zone, chosen but not yet applied: { keep, bench }

  // Applies one engine action, saves the new state and redraws; an action the engine refuses shows its reason.
  function act(step) {
    try {
      state = step();
      message = store.save('match', state) ? '' : SAVE_FAILED;
    } catch (error) {
      if (!(error instanceof MatchError)) throw error;
      message = 'Dat kan nu niet.';
    }
    zone = null;
    render();
  }

  function toggleZone(keep) {
    zone = zone && zone.keep === keep ? null : { keep, bench: proposedBench(state) };
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
  const nameList = (ids, className, extra = () => null) => el('ul', { className: `names ${className}` },
    sortedPlayers(ids).map((id) => el('li', {}, name(id), extra(id))));
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
            ? canTerug() && el('button', { type: 'button', className: 'chip', onclick: () => act(() => terug(state, id)) }, 'Terug')
            : el('button', { type: 'button', className: 'chip', onclick: () => act(() => uit(state, id)) }, 'Uit'))))));
  }

  // Uit works at any time during the match (on court, a replacement comes on at once). Terug takes effect from the
  // next block, so it is offered while a next block exists.
  const canTerug = () => !state.ended && state.block < state.blocks;

  const undoButton = () => el('button', { type: 'button', className: 'undo', disabled: !canUndo(state), onclick: () => act(() => undo(state)) },
    'Ongedaan maken');
  const status = () => el('p', { className: 'message', role: 'alert' }, message);

  function playing() {
    const change = nextChange(state);
    return [
      el('h1', {}, `Blok ${state.block} van ${state.blocks}`,
        ' ', el('span', { className: 'count' }, `kwart ${quarterOf(state)}`)),
      setup.opponent && el('p', { className: 'note' }, `Tegen ${setup.opponent}`),
      el('p', { className: 'sub-time' }, subTimeText(state)),
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
        zone && el('p', { className: 'zone-note' },
          name(zone.keep), ' blijft in the zone op het veld, ', name(zone.bench), ' blijft op de bank.')),
      status(),
      el('div', { className: 'live-actions' },
        el('button', {
          type: 'button', className: 'primary wissel',
          onclick: () => act(() => wissel(state, zone ? { keep: zone.keep, bench: zone.bench } : {})),
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
    root.replaceChildren(...(state.ended ? ended() : playing()).filter(Boolean));
  }

  render();
}
