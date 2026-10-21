/* ═══════════════════════════════════════════════════════════════
   Customer display — the screen on the back of the iMin D4.

   The counter (floor screen) publishes what the guest should see; the
   customer page (tpn-dine-in-floor-customer.html) draws it. Everything
   stays on the device, so it keeps working with no internet.

   One state object, sent every way that might reach the other page:
     BroadcastChannel 'tpn-cds'   two windows/tabs, or two WebViews in
                                  the TPN Counter app (same origin)
     localStorage 'tpn.cds'       the last state, so a page that opens
                                  late (or reloads) shows the right thing
     Presentation API             Chrome putting the page on the second
                                  screen ("Customer screen" on the top bar)
     window.TPNCounter            the Android app's bridge, if present
     http://127.0.0.1:8091/state  the app's loopback link, when the counter
                                  runs in Chrome (the iMin's own WebView is
                                  too old for it; the app then drives only
                                  the back screen)

   State: { mode: 'idle' | 'order' | 'pay' | 'thanks', lines, fee, total,
            type, number, due, method, tendered, change, ts }
   Never a customer's name, phone or address: this faces the queue.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const KEY = 'tpn.cds';
  const bc = ('BroadcastChannel' in window) ? new BroadcastChannel('tpn-cds') : null;
  const native = () => window.TPNCounter && typeof window.TPNCounter.toCustomer === 'function' ? window.TPNCounter : null;
  const PAGE = 'tpn-dine-in-floor-customer';
  // The app's link; tried only on Android (the iMin) or when forced for testing.
  const RELAY = 'http://127.0.0.1:8091';
  const ANDROID = /Android/i.test(navigator.userAgent) || (() => { try { return localStorage.getItem(KEY + '.force') === 'on'; } catch (e) { return false; } })();
  let relayOk = false;
  let last = null, conn = null, req = null;
  let payBase = null;
  const mem = {};   // order id → its lines, so the pay screen still lists what was ordered

  function send(state) {
    const msg = JSON.stringify(Object.assign({ v: 1, ts: Date.now() }, state));
    if (msg === last) return;
    last = msg;
    try { localStorage.setItem(KEY, msg); } catch (e) {}
    try { bc && bc.postMessage(msg); } catch (e) {}
    try { conn && conn.state === 'connected' && conn.send(msg); } catch (e) {}
    try { const n = native(); n && n.toCustomer(msg); } catch (e) {}
    if (ANDROID && !native() && relayOk) relay(msg);
  }
  function relay(msg) {
    fetch(RELAY + '/state', { method: 'POST', body: msg, mode: 'cors', keepalive: true, headers: { 'content-type': 'text/plain' } })
      .then(r => { if (!r.ok) throw 0; }).catch(() => { relayOk = false; paint(); });
  }
  // Is the app's back screen there? Asked on open, and every 20s while it isn't.
  function probeRelay() {
    if (!ANDROID || native()) return;
    fetch(RELAY + '/ping', { mode: 'cors', cache: 'no-store' }).then(r => r.json()).then(j => {
      const was = relayOk; relayOk = !!j.ok;
      if (relayOk && !was && last) relay(last);   // catch the screen up
      paint();
    }).catch(() => { relayOk = false; paint(); });
  }

  /* ── Counter side ─────────────────────────────────────────── */
  const C = {
    idle() { send({ mode: 'idle' }); },
    order(o) { send(Object.assign({ mode: o.lines && o.lines.length ? 'order' : 'idle' }, o)); },
    // Later updates (cash typed in) may leave out the order: keep the last one's lines and number.
    pay(p) {
      if (p.orderId) payBase = Object.assign({}, mem[p.orderId] || {}, { orderId: p.orderId, number: p.number });
      send(Object.assign({ mode: 'pay' }, payBase || {}, p));
    },
    remember(orderId, o) { if (orderId) mem[orderId] = o; },
    thanks(t) { send(Object.assign({ mode: 'thanks' }, t)); },
    // The ticket as the guest should read it (no notes: they're for the kitchen).
    lines(ticket) {
      return (ticket || []).map(l => ({ name: l.name, size: l.size || '', mods: l.modNames || [], qty: l.qty, amount: l.price * l.qty }));
    },
    /* Chrome route: put the customer page on the second screen. Needs a tap
       (browsers only start a presentation from a user gesture). */
    canPresent: () => !native() && 'PresentationRequest' in window,
    async present() {
      if (native()) return 'app';
      if (!C.canPresent()) throw new Error('This browser can’t open a second screen.');
      req = req || new PresentationRequest([PAGE]);
      try { navigator.presentation.defaultRequest = req; } catch (e) {}
      const c = await req.start();
      attach(c);
      try { localStorage.setItem(KEY + '.pid', c.id); } catch (e) {}
      return 'presentation';
    },
    stop() { try { conn && conn.terminate(); } catch (e) {} conn = null; paint(); },
    connected: () => !!native() || relayOk || !!(conn && conn.state === 'connected')
  };
  function attach(c) {
    conn = c;
    const resend = () => { if (last) try { conn.send(last); } catch (e) {} paint(); };
    c.onconnect = resend; c.onclose = paint; c.onterminate = () => { conn = null; paint(); };
    if (c.state === 'connected') resend();
  }
  // After a reload of the counter, pick the running presentation back up.
  async function reconnect() {
    let id = null; try { id = localStorage.getItem(KEY + '.pid'); } catch (e) {}
    if (!id || !C.canPresent()) return;
    try { req = new PresentationRequest([PAGE]); attach(await req.reconnect(id)); } catch (e) {}
  }
  function paint() { document.dispatchEvent(new CustomEvent('tpn:cds', { detail: { connected: C.connected() } })); }

  /* ── Customer side ────────────────────────────────────────── */
  function listen(onState) {
    const take = (raw) => { try { const s = typeof raw === 'string' ? JSON.parse(raw) : raw; if (s && s.v === 1) onState(s); } catch (e) {} };
    if (bc) bc.onmessage = (e) => take(e.data);
    window.addEventListener('storage', (e) => { if (e.key === KEY && e.newValue) take(e.newValue); });
    window.tpnCdsReceive = take;   // the Android app calls this
    if (navigator.presentation && navigator.presentation.receiver) {
      navigator.presentation.receiver.connectionList.then(list => {
        const add = (c) => { c.onmessage = (e) => take(e.data); };
        list.connections.forEach(add);
        list.onconnectionavailable = (e) => add(e.connection);
      }).catch(() => {});
    }
    try { const s = localStorage.getItem(KEY); if (s) take(s); } catch (e) {}
  }

  /* ── Top-bar chip on the counter (Android = the iMin, or the app) ── */
  function chip() {
    const want = native() || /Android/i.test(navigator.userAgent) || (() => { try { return localStorage.getItem(KEY + '.force') === 'on'; } catch (e) { return false; } })();
    const bar = document.querySelector('.topbar-right');
    if (!want || !bar || !(native() || relayOk || C.canPresent())) return;
    let b = document.getElementById('cdsChip');
    if (!b) {
      b = document.createElement('button');
      b.id = 'cdsChip'; b.type = 'button'; b.className = 'topbar-btn secondary';
      b.addEventListener('click', async () => {
        if (native() || relayOk) { window.toast && toast('The customer screen is run by the TPN Counter app.'); return; }
        if (C.connected()) { if (await (window.tpnConfirm ? tpnConfirm('Turn the customer screen off?', { confirmText: 'Turn off' }) : confirm('Turn the customer screen off?'))) C.stop(); return; }
        try { await C.present(); }
        catch (e) {
          // NotFoundError: no second screen offered; AbortError: the picker was closed.
          if (e && e.name === 'AbortError') return;
          window.toast && toast('Chrome couldn’t open the customer screen on this device (' + (e && (e.name || e.message)) + '). Use the TPN Counter app instead.');
        }
      });
      bar.insertBefore(b, bar.firstChild);
    }
    b.textContent = C.connected() ? 'Customer screen: on' : 'Customer screen';
  }
  document.addEventListener('tpn:cds', chip);

  window.TPN_CDS = Object.assign(C, { listen });
  if (!/customer/.test(location.pathname)) {
    reconnect();
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', chip); else chip();
    probeRelay();
    setInterval(() => { if (!relayOk) probeRelay(); }, 20000);
  }
})();
