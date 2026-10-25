/* ═══════════════════════════════════════════════════════════════
   Counter service worker — lets the floor screen (and the Counter on
   it) open with no internet. Registered by tpn-dine-in-floor.html with
   scope "./tpn-dine-in-floor", so no other page is touched: the website,
   portal, kitchen and QR menu behave exactly as before.

   What it keeps:
     the page             network first (4s), else the last copy
     its scripts/styles   precached from the page's own <script>/<link>
                          tags at install; a ?v= URL never changes, so
                          it is served from the cache, anything else is
                          network first
     fonts                Google Fonts CSS + woff2, cache first
     the last menu        Supabase GETs on the menu, modifier, table,
                          branch and delivery-zone tables: network first
                          (5s), else the last answer

   Orders are NOT handled here. A service worker cannot know whether a
   failed POST reached the database; modules/offline.js keeps them in an
   outbox with their idempotency key and replays them (sql/41).
   ═══════════════════════════════════════════════════════════════ */
'use strict';
const VERSION = 'tpn-counter-20261025a';
const SHELL = VERSION + '-shell';
const DATA = VERSION + '-data';
const PAGE = 'tpn-dine-in-floor.html';
// The customer screen on the back of the counter (same scope prefix, so it opens offline too).
const CUSTOMER = 'tpn-dine-in-floor-customer.html';
const SUPA = 'https://xjlqfpnzobfqxetgkkai.supabase.co';
// Read-only tables the Counter and floor need to draw. Nothing with a
// customer's name, phone or money in it is cached.
const DATA_TABLES = /^\/rest\/v1\/(menu_categories|menu_items|modifier_groups|modifiers|menu_item_modifier_groups|restaurant_tables|branches|delivery_zones)(\?|$)/;
// Files the page loads after start-up, which the tag scan below can't see.
const EXTRA = ['counter.webmanifest', 'icons/tpn-icon.svg', 'assets/site/icon.png'];

self.addEventListener('install', (e) => {
  e.waitUntil((async () => {
    const c = await caches.open(SHELL);
    const page = await fetch(PAGE, { cache: 'no-cache' });
    if (!page.ok) throw new Error('page ' + page.status);
    let html = await page.clone().text();
    await c.put(PAGE, page);
    // The customer screen is a nicety: a failure here must not stop the counter installing.
    try {
      const cp = await fetch(CUSTOMER, { cache: 'no-cache' });
      if (cp.ok) { html += await cp.clone().text(); await c.put(CUSTOMER, cp); }
    } catch (err) {}
    const urls = new Set(EXTRA.concat(['assets/site/logo.webp', 'assets/site/hero.webp', 'assets/site/mandala-a.webp']));
    for (const m of html.matchAll(/<(?:script|link)\b[^>]*?\s(?:src|href)="([^"]+)"/g)) {
      const u = new URL(m[1], self.registration.scope);
      if (u.origin === location.origin || u.origin === 'https://fonts.googleapis.com') urls.add(u.href);
    }
    // One failure (a font server hiccup) must not abort the whole install.
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
    for (const k of await caches.keys()) if (k.startsWith('tpn-counter-') && !k.startsWith(VERSION)) await caches.delete(k);
    await self.clients.claim();
  })());
});

// Network, but give up after `ms` so a router with no internet behind it
// doesn't leave the counter staring at a spinner.
function timed(req, ms) {
  return new Promise((resolve, reject) => {
    const t = setTimeout(() => reject(new Error('timeout')), ms);
    fetch(req).then(r => { clearTimeout(t); resolve(r); }, err => { clearTimeout(t); reject(err); });
  });
}
async function networkFirst(req, cacheName, ms, key) {
  const c = await caches.open(cacheName);
  if (self.navigator && self.navigator.onLine === false) {
    const hit = await c.match(key || req, { ignoreVary: true });
    if (hit) return hit;
  }
  try {
    let r = await timed(req, ms);
    // A redirected response can't answer a navigation; keep only its body.
    if (r.redirected) r = new Response(await r.blob(), { status: r.status, headers: r.headers });
    if (r.ok) c.put(key || req, r.clone());
    return r;
  } catch (err) {
    const hit = await c.match(key || req, { ignoreVary: true }) || (key ? null : await c.match(req, { ignoreSearch: true, ignoreVary: true }));
    if (hit) return hit;
    throw err;
  }
}
async function cacheFirst(req, cacheName) {
  const c = await caches.open(cacheName);
  const hit = await c.match(req, { ignoreVary: true });
  if (hit) return hit;
  const r = await fetch(req);
  if (r.ok || r.type === 'opaque') c.put(req, r.clone());
  return r;
}

self.addEventListener('fetch', (e) => {
  const req = e.request;
  if (req.method !== 'GET') return;          // orders, RPCs, auth: straight through
  const u = new URL(req.url);

  if (req.mode === 'navigate') {
    // Both /tpn-dine-in-floor and /tpn-dine-in-floor.html, any query; the
    // customer screen keeps its own copy so neither overwrites the other.
    e.respondWith(networkFirst(req, SHELL, 4000, /-customer(\.html)?$/.test(u.pathname) ? CUSTOMER : PAGE));
    return;
  }
  if (u.origin === location.origin) {
    if (u.pathname.endsWith('/tpn-counter-sw.js')) return;
    e.respondWith(u.searchParams.has('v') || u.pathname.includes('/vendor/')
      ? cacheFirst(req, SHELL) : networkFirst(req, SHELL, 4000));
    return;
  }
  if (u.origin === 'https://fonts.googleapis.com' || u.origin === 'https://fonts.gstatic.com') {
    e.respondWith(cacheFirst(req, SHELL));
    return;
  }
  if (u.origin === SUPA && DATA_TABLES.test(u.pathname + u.search.slice(0, 1))) {
    // Keyed by URL alone: the same query always means the same rows.
    e.respondWith(networkFirst(req, DATA, 5000, u.href));
  }
});
