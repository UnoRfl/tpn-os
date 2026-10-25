/* ═══════════════════════════════════════════════════════════════
   Kitchen service worker — lets the kitchen station open with no
   internet (a power cut, the router restarting). Registered by
   tpn-kitchen-station.html with scope "./tpn-kitchen-station", so no other
   page is touched.

   What it keeps:
     the page             network first (4s), else the last copy
     its scripts/styles   a ?v= URL never changes, so cache first;
                          anything else network first
     fonts                cache first

   Orders are NOT cached here. The page keeps its own copy of the tickets
   it last showed (localStorage tpn.kitchen.snap) and a queue of the taps
   made offline (tpn.kitchen.queue), and sends those when it reconnects.
   ═══════════════════════════════════════════════════════════════ */
'use strict';
const VERSION = 'tpn-kitchen-20261025a';
const PAGE = 'tpn-kitchen-station.html';

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(VERSION);
    const page = await fetch(PAGE, { cache: 'no-cache' });
    if (!page.ok) throw new Error('page ' + page.status);
    const html = await page.clone().text();
    await c.put(PAGE, page);
    const urls = new Set(['assets/site/icon.png']);
    for (const m of html.matchAll(/<(?:script|link)\b[^>]*?\s(?:src|href)="([^"]+)"/g)) {
      const u = new URL(m[1], self.registration.scope);
      if (u.origin === location.origin || u.origin === 'https://fonts.googleapis.com') urls.add(u.href);
    }
    await Promise.all([...urls].map(async (u) => {
      try {
        const r = await fetch(u, { cache: 'no-cache' });
        if (!r.ok) return;
        if (u.startsWith('https://fonts.googleapis.com')) {
          const css = await r.clone().text();
          await Promise.all([...css.matchAll(/url\((https:\/\/fonts\.gstatic\.com\/[^)]+)\)/g)].map(f =>
            fetch(f[1]).then(x => x.ok && c.put(f[1], x)).catch(() => {})));
        }
        await c.put(u, r);
      } catch (err) { /* cached on first use instead */ }
    }));
    self.skipWaiting();
  })());
});

self.addEventListener('activate', (e) => {
  e.waitUntil((async () => {
    for (const k of await caches.keys()) if (k.startsWith('tpn-kitchen-') && k !== VERSION) await caches.delete(k);
    await self.clients.claim();
  })());
});

function timed(req, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout')), ms);
    fetch(req).then(r => { clearTimeout(t); resolve(r); }, err => { clearTimeout(t); reject(err); });
  });
}
async function networkFirst(req, key) {
  const c = await caches.open(VERSION);
  try {
    let r = await timed(req, 4000);
    if (r.redirected) r = new Response(await r.blob(), { status: r.status, headers: r.headers });
    if (r.ok) c.put(key || req, r.clone());
    return r;
  } catch (err) {
    const hit = await c.match(key || req, { ignoreVary: true }) || await c.match(req, { ignoreSearch: true, ignoreVary: true });
    if (hit) return hit;
    throw err;
  }
}
async function cacheFirst(req) {
  const c = await caches.open(VERSION);
  const hit = await c.match(req, { ignoreVary: true });
  if (hit) return hit;
  const r = await fetch(req);
  if (r.ok || r.type === 'opaque') c.put(req, r.clone());
  return r;
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;
  const u = new URL(req.url);
  if (req.mode === 'navigate') { e.respondWith(networkFirst(req, PAGE)); return; }
  if (u.origin === location.origin) {
    if (u.pathname.endsWith('/tpn-kitchen-sw.js')) return;
    e.respondWith(u.searchParams.has('v') || u.pathname.includes('/vendor/') ? cacheFirst(req) : networkFirst(req));
    return;
  }
  if (u.origin === 'https://fonts.googleapis.com' || u.origin === 'https://fonts.gstatic.com') e.respondWith(cacheFirst(req));
});
