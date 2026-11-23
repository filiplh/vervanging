// Service worker: keeps the app working without a network after the first visit (decision #15) and never changes the
// app mid-match (decision #3).
//
// - On install, every file the page needs (ASSETS, an explicit list; setup.test.js checks it against public/) is
//   stored in one cache named after VERSION.
// - Requests are answered from that cache first, so an open app always runs one consistent version.
// - A new version (a changed sw.js) installs in the background and waits: there is no skipWaiting() and no
//   clients.claim(), and no page is ever reloaded. It takes over at the next app start, once no page uses the old
//   version, and then removes the old caches.
//
// VERSION is a digest of every file in ASSETS and of this file (without the VERSION line). setup.test.js computes it
// and fails, printing the new line to paste, when a cached file or this worker changed and VERSION did not. So every
// release gets its own cache: phones see the new worker, and it never writes into the cache the open app is using.

const VERSION = 'da2c71f68d1d74a7';
const CACHE = `vervanging-${VERSION}`;

// Paths relative to this file (served at /sw.js). './' is the page itself (index.html); it is cached under '/' only,
// because the host may redirect /index.html to /.
const ASSETS = [
  './',
  'styles.css',
  'manifest.webmanifest',
  'icons/apple-touch-icon.png',
  'icons/icon-192.png',
  'icons/icon-512.png',
  'js/app.js',
  'js/history.js',
  'js/live.js',
  'js/match.js',
  'js/planner.js',
  'js/setup.js',
  'js/store.js',
];

self.addEventListener('install', (event) => {
  // cache: 'reload' skips the browser's HTTP cache, so the new version stores the files as they are on the server.
  event.waitUntil(caches.open(CACHE).then((cache) =>
    cache.addAll(ASSETS.map((path) => new Request(new URL(path, self.location).href, { cache: 'reload' })))));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(caches.keys().then((keys) => Promise.all(
    keys.filter((key) => key.startsWith('vervanging-') && key !== CACHE).map((key) => caches.delete(key)))));
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  // The app has one page (screens are chosen by the URL hash): opening it as / or /index.html, with or without a
  // query, gets the cached page.
  const page = url.pathname === '/' || url.pathname === '/index.html';
  const key = page ? new URL('./', self.location).href : request;
  event.respondWith(caches.open(CACHE)
    .then((cache) => cache.match(key, { ignoreSearch: page }))
    .then((cached) => cached || fetch(request)));
});
