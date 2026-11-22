// Entry point: picks the screen from the URL hash (#spelers, #match, #start) and draws it into <main>.

import { createStore } from './store.js';
import { rosterScreen, setupScreen, startedScreen, normaliseRoster } from './setup.js';
import { ON_COURT } from './planner.js';

const store = createStore();
const view = document.getElementById('view');

function defaultView() {
  return normaliseRoster(store.load('roster')).players.length >= ON_COURT ? 'match' : 'spelers';
}

function show() {
  const name = location.hash.slice(1) || defaultView();
  for (const link of document.querySelectorAll('.tabs a')) {
    const current = link.dataset.view === name || (name === 'start' && link.dataset.view === 'match');
    if (current) link.setAttribute('aria-current', 'page');
    else link.removeAttribute('aria-current');
  }
  if (name === 'spelers') rosterScreen(view, { store });
  else if (name === 'start') startedScreen(view, { store });
  else setupScreen(view, { store, onStart: () => { location.hash = '#start'; } });
  window.scrollTo(0, 0);
}

window.addEventListener('hashchange', show);
show();
