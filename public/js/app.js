// Entry point: picks the screen from the URL hash (#spelers, #match, #start) and draws it into <main>.

import { createStore } from './store.js';
import { rosterScreen, setupScreen, normaliseRoster, playerLabel } from './setup.js';
import { ON_COURT } from './planner.js';

const store = createStore();
const view = document.getElementById('view');

function defaultView() {
  return normaliseRoster(store.load('roster')).players.length >= ON_COURT ? 'match' : 'spelers';
}

// Until the live screen (#7) exists, "Start" lands here: the setup is saved, nothing more happens yet.
function startedScreen(root) {
  const setup = store.load('matchSetup');
  const lines = [];
  if (setup?.opponent) lines.push(`Tegen ${setup.opponent}.`);
  if (Array.isArray(setup?.players)) {
    const five = setup.players.filter((p) => setup.startingFive?.includes(p.id)).map(playerLabel);
    lines.push(`Basisvijf: ${five.join(', ')}.`);
  }
  const h1 = document.createElement('h1');
  h1.textContent = 'Match opgeslagen';
  const note = document.createElement('p');
  note.className = 'note';
  note.textContent = 'Het wedstrijdscherm komt in een volgende versie.';
  const back = document.createElement('a');
  back.className = 'button';
  back.href = '#match';
  back.textContent = 'Terug naar de match';
  root.replaceChildren(h1, ...lines.map((text) => Object.assign(document.createElement('p'), { textContent: text })), note, back);
}

function show() {
  const name = location.hash.slice(1) || defaultView();
  for (const link of document.querySelectorAll('.tabs a')) {
    const current = link.dataset.view === name || (name === 'start' && link.dataset.view === 'match');
    if (current) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
  if (name === 'spelers') rosterScreen(view, { store });
  else if (name === 'start') startedScreen(view);
  else setupScreen(view, { store, onStart: () => { location.hash = '#start'; } });
  window.scrollTo(0, 0);
}

window.addEventListener('hashchange', show);
show();
