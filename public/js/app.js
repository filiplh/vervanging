// Entry point: picks the screen from the URL hash (#spelers, #match, #start) and draws it into <main>, and registers
// the service worker that keeps the app working offline (sw.js). Importing it without a DOM (the tests) only gives
// defaultView.

import { createStore } from './store.js';
import { rosterScreen, setupScreen, normaliseRoster, hasRunningMatch } from './setup.js';
import { liveScreen, keepScreenAwake } from './live.js';
import { ON_COURT } from './planner.js';

// The screen for the app opened with no hash, as the home-screen icon opens it (start_url is /): the running match
// when there is one, so the coach gets back to it (P1-2 in docs/spikes/2026-ui-review.md); otherwise setup, or Spelers
// while the roster has fewer than 5 players.
export function defaultView(store) {
  if (hasRunningMatch(store)) return 'start';
  return normaliseRoster(store.load('roster')).players.length >= ON_COURT ? 'match' : 'spelers';
}

function startApp() {
  const store = createStore();
  const view = document.getElementById('view');

  function show() {
    const name = location.hash.slice(1) || defaultView(store);
    for (const link of document.querySelectorAll('.tabs a')) {
      const current = link.dataset.view === name || (name === 'start' && link.dataset.view === 'match');
      if (current) link.setAttribute('aria-current', 'page');
      else link.removeAttribute('aria-current');
    }
    if (name !== 'start') keepScreenAwake(false);
    if (name === 'spelers') rosterScreen(view, { store });
    else if (name === 'start') liveScreen(view, { store });
    else {
      // A new "Start" begins a new match: the previous match state is dropped (the live screen also refuses a state
      // that belongs to another setup). The setup screen asks first when that match has not ended.
      setupScreen(view, { store, onStart: () => { store.remove('match'); location.hash = '#start'; } });
    }
    window.scrollTo(0, 0);
  }

  window.addEventListener('hashchange', show);
  show();

  // A new version of the service worker installs in the background and only takes over at the next app start; the
  // page is never reloaded for it (decision #3). Without service worker support the app works online as before.
  if ('serviceWorker' in navigator) navigator.serviceWorker.register('/sw.js').catch(() => {});
}

if (typeof document !== 'undefined') startApp();
