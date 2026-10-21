/* ═══════════════════════════════════════════════════════════════
   Offline counter — keeps the Counter taking orders when the
   restaurant's internet drops. Loaded by tpn-dine-in-floor.html only.

   Three parts:
     1. tpn-counter-sw.js (registered here) keeps the page, its files
        and the last menu, so the screen opens with no internet.
     2. An outbox in IndexedDB ("tpn-counter"). An order the server can't
        be reached for is saved with its idempotency key (sql/41) and a
        local number (OFF-007), and cash taken for it rides along. When
        the connection is back they are replayed oldest first. A replayed
        order with a key the server has seen returns the first order, so
        a send that did land before the line dropped is never doubled.
        Cash is replayed only after its order exists, and is tagged
        "offline OFF-007 …" in the payment note so a replay can see it
        already went through.
     3. The sign-in this device last had (staff profile + permissions)
        is remembered, so a reload while offline still opens the screen.
        That only decides what the screen shows; the database checks the
        real session when the outbox syncs, and nothing is sent without
        one.

   Needs the server, so not offline: GCash/Maya/QR Ph/card/bank (the
   reference is checked and recorded there), opening or closing a shift,
   Close table, voids, the 86 list.

   TPN_OFFLINE.isOffline()       last known state (navigator + probe)
   TPN_OFFLINE.check()           probe now if the last answer is stale
   TPN_OFFLINE.isNetError(e)     a failure that may not have reached the server
   TPN_OFFLINE.queueOrder(..)    save an order (returns the outbox entry)
   TPN_OFFLINE.queueCash(..)     save cash for an order that already exists
   TPN_OFFLINE.openPayment(id)   offline payment panel for a queued order
   TPN_OFFLINE.sync()            replay now (also runs by itself)
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const DB_NAME = 'tpn-counter', ME_KEY = 'tpn.offline.me', CASH_KEY = 'tpn.offline.cashSession';
  const URL_ = (window.TPN_CONFIG && TPN_CONFIG.SUPABASE_URL) || '';
  const KEY_ = (window.TPN_CONFIG && TPN_CONFIG.SUPABASE_ANON_KEY) || '';
  const P = (v) => (window.peso ? peso(v) : '₱' + Number(v || 0).toFixed(2));
  const esc = (v) => (window.E ? E(v) : String(v == null ? '' : v));
  const T = { online: navigator.onLine, checkedAt: 0, entries: [], syncing: false, authProblem: false, lastError: '' };

  /* ── Service worker ────────────────────────────────────────── */
  if ('serviceWorker' in navigator && /^https?:$/.test(location.protocol)) {
    navigator.serviceWorker.register('tpn-counter-sw.js', { scope: './tpn-dine-in-floor' })
      .catch(e => console.warn('[offline] service worker not registered:', e && e.message));
  }

  /* ── IndexedDB ─────────────────────────────────────────────── */
  let dbp = null;
  function db() {
    return dbp || (dbp = new Promise((res, rej) => {
      const r = indexedDB.open(DB_NAME, 1);
      r.onupgradeneeded = () => {
        const d = r.result;
        if (!d.objectStoreNames.contains('outbox')) d.createObjectStore('outbox', { keyPath: 'id' });
        if (!d.objectStoreNames.contains('kv')) d.createObjectStore('kv');
      };
      r.onsuccess = () => res(r.result);
      r.onerror = () => { dbp = null; rej(r.error); };
    }));
  }
  function req(store, mode, fn) {
    return db().then(d => new Promise((res, rej) => {
      const t = d.transaction(store, mode), q = fn(t.objectStore(store));
      t.oncomplete = () => res(q ? q.result : undefined);
      t.onerror = t.onabort = () => rej(t.error);
    }));
  }
  const putEntry = (e) => req('outbox', 'readwrite', s => s.put(e));
  const delEntry = (id) => req('outbox', 'readwrite', s => s.delete(id));
  async function load() {
    const all = (await req('outbox', 'readonly', s => s.getAll())) || [];
    // Synced rows stay a day so staff can match OFF-007 to its real number.
    const old = all.filter(e => e.state === 'synced' && Date.now() - (e.syncedAt || 0) > 864e5);
    for (const e of old) await delEntry(e.id);
    T.entries = all.filter(e => !old.includes(e)).sort((a, b) => a.seq - b.seq);
    paint();
    return T.entries;
  }
  // One counter per device; the number only has to be unique on this
  // device's paper tickets until the real order number exists.
  function nextSeq() {
    return db().then(d => new Promise((res, rej) => {
      const t = d.transaction('kv', 'readwrite'), s = t.objectStore('kv'), g = s.get('seq');
      let n;
      g.onsuccess = () => { n = (g.result || 0) + 1; s.put(n, 'seq'); };
      t.oncomplete = () => res(n);
      t.onerror = () => rej(t.error);
    }));
  }
  function uuid() {
    try { return crypto.randomUUID(); } catch (e) {
      return Array.from(crypto.getRandomValues(new Uint8Array(16)), x => x.toString(16).padStart(2, '0')).join('').replace(/^(.{8})(.{4})(.{4})(.{4})/, '$1-$2-$3-$4-');
    }
  }

  /* ── Connection ────────────────────────────────────────────── */
  // navigator.onLine only knows about the Wi-Fi. A router with no internet
  // behind it says "online", so ask Supabase itself.
  function timed(promise, ms) {
    let t;
    return Promise.race([promise, new Promise((_, rej) => { t = setTimeout(() => rej(new Error('timeout: no answer from the server')), ms); })])
      .finally(() => clearTimeout(t));
  }
  async function probe() {
    let ok = false;
    if (navigator.onLine !== false) {
      try { const r = await timed(fetch(URL_ + '/auth/v1/health', { headers: { apikey: KEY_ }, cache: 'no-store' }), 4000); ok = r.ok; }
      catch (e) { ok = false; }
    }
    setOnline(ok);
    return ok;
  }
  T.check = (force) => (force || Date.now() - T.checkedAt > 10000) ? probe() : Promise.resolve(T.online);
  T.isOffline = () => !T.online;
  T.markOffline = () => setOnline(false);
  T.timed = timed;
  function setOnline(ok) {
    const was = T.online;
    T.online = ok; T.checkedAt = Date.now();
    document.body && document.body.classList.toggle('tpn-offline', !ok);
    paint();
    if (ok && !was) T.sync();
  }
  // Could this failure mean the request never got an answer? Then it may
  // or may not have landed, and only an idempotent replay is safe.
  T.isNetError = function (e) {
    const m = String((e && (e.message || e.code)) || e || '');
    return /No connection|Failed to fetch|NetworkError|Load failed|network|timeout|took too long|ERR_|fetch failed|AbortError|50[234]|too_many_requests|Too many tries/i.test(m);
  };
  window.addEventListener('online', () => probe());
  window.addEventListener('offline', () => setOnline(false));
  setInterval(() => {
    const busy = T.entries.some(e => e.state === 'waiting');
    if (!T.online || busy) probe().then(ok => { if (ok && busy) T.sync(); });
  }, 15000);

  /* ── Remembered sign-in ────────────────────────────────────── */
  function storedUid() {
    try {
      const k = Object.keys(localStorage).find(x => /^sb-.+-auth-token$/.test(x) && x !== 'sb-tpn-anon');
      const s = k && JSON.parse(localStorage.getItem(k));
      return (s && s.user && s.user.id) || (s && s.currentSession && s.currentSession.user && s.currentSession.user.id) || null;
    } catch (e) { return null; }
  }
  function me() {
    try { const m = JSON.parse(localStorage.getItem(ME_KEY) || 'null'); return m && m.uid && m.uid === storedUid() ? m : null; }
    catch (e) { return null; }
  }
  function saveMe(patch) {
    try { localStorage.setItem(ME_KEY, JSON.stringify(Object.assign(me() || {}, patch))); } catch (e) {}
  }
  // The auth gate asks this when getSession() came back empty: an expired
  // token can't be refreshed with no internet, but the device is still
  // signed in, and the refresh happens once the connection is back.
  T.canRunOffline = async function () { return !!(storedUid() && me() && !(await T.check(true))); };

  if (window.TPN) {
    const loadProfile = TPN.loadProfile, loadPermissions = TPN.loadPermissions;
    TPN.loadProfile = async function () {
      let u = null;
      if (T.online || await T.check()) { try { u = await timed(loadProfile.apply(this, arguments), 8000); } catch (e) { u = null; } }
      if (u) { saveMe({ uid: u.id, user: u, at: Date.now() }); return u; }
      const m = me();
      if (m && !(await T.check(true))) { this._user = m.user; T.fromCache = true; return m.user; }
      return u;
    };
    TPN.loadPermissions = async function () {
      const r = await loadPermissions.apply(this, arguments);
      if (this._user && this._perms && !this._permsFailed) saveMe({ uid: this._user.id, perms: [...this._perms] });
      else if (this._permsFailed) {
        const m = me();
        if (m && m.perms) { this._perms = new Set(m.perms); this._permsFailed = false; }
      }
      return this._perms || r;
    };
  }
  // The Counter's open shift, for cash taken while the server is away.
  T.lastCashSession = function (id) {
    try {
      if (arguments.length) { id ? localStorage.setItem(CASH_KEY, id) : localStorage.removeItem(CASH_KEY); return id; }
      return localStorage.getItem(CASH_KEY) || null;
    } catch (e) { return null; }
  };

  /* ── Outbox ────────────────────────────────────────────────── */
  T.queueOrder = async function ({ clientKey, order, lines, type, estTotal }) {
    const seq = await nextSeq();
    const who = (window.TPN && TPN.currentUser && TPN.currentUser()) || {};
    const e = {
      id: clientKey || uuid(), kind: 'order', seq, localNo: 'OFF-' + String(seq).padStart(3, '0'),
      createdAt: Date.now(), by: who.full_name || who.name || '', order, type,
      lines: (lines || []).map(l => ({ name: l.name, qty: l.qty, size: l.size || null, modNames: l.modNames || [], note: l.note || '', price: l.price })),
      estTotal: Math.round((estTotal || 0) * 100) / 100, cash: null,
      state: 'waiting', stage: 'order', error: '', attempts: 0
    };
    await putEntry(e); await load();
    return e;
  };
  T.queueCash = async function ({ orderId, orderNumber, tendered, amount, tip }) {
    const seq = await nextSeq();
    const e = {
      id: uuid(), kind: 'cash', seq, localNo: 'OFF-' + String(seq).padStart(3, '0'), createdAt: Date.now(),
      orderId, orderNumber, estTotal: amount, cash: { tendered, amount, tip: tip || 0, cashSession: window.tpnCashSessionId || T.lastCashSession() },
      state: 'waiting', stage: 'payment', error: '', attempts: 0
    };
    await putEntry(e); await load();
    return e;
  };
  const tagOf = (e) => 'offline ' + e.localNo + ' ' + e.id.slice(0, 8);

  T.sync = async function () {
    // Asked again mid-run (Try again, the connection coming back): run once
    // more afterwards rather than drop it.
    if (T.syncing) { T.again = true; return; }
    T.syncing = true; paint();
    let sent = 0;
    try {
      await load();
      if (!T.entries.some(e => e.state === 'waiting')) return;
      if (!(await T.check(true))) return;
      // Never replay without the staff session: submit_order is also the
      // customers' door, and an order sent signed-out would go in as a guest's.
      const { data } = await sb.auth.getSession();
      T.authProblem = !(data && data.session);
      if (T.authProblem) return;
      for (const e of T.entries.filter(x => x.state === 'waiting')) {
        e.attempts++;
        try {
          if (e.stage === 'order') {
            const o = await timed(TPN.createOrder(Object.assign({}, e.order, { clientKey: e.id })), 20000);
            e.orderId = o.id; e.orderNumber = o.order_number; e.serverTotal = o.total;
            e.stage = e.cash ? 'payment' : 'done';
            await putEntry(e);
          }
          if (e.stage === 'payment') { await payCash(e); e.stage = 'done'; }
          e.state = 'synced'; e.syncedAt = Date.now(); e.error = '';
          sent++;
        } catch (err) {
          if (T.isNetError(err)) { e.attempts--; await putEntry(e); setOnline(false); break; }
          e.state = 'failed'; e.error = err.message || String(err);
        }
        await putEntry(e);
      }
    } catch (err) {
      T.lastError = err.message || String(err);
      console.warn('[offline] sync', err);
    } finally {
      T.syncing = false;
      await load().catch(() => {});
      if (T.again) { T.again = false; setTimeout(T.sync, 0); }
      if (sent) {
        const fails = T.entries.filter(e => e.state === 'failed').length;
        window.toast && toast(`Synced ${sent} offline order${sent > 1 ? 's' : ''}` + (fails ? ` · ${fails} need attention` : '') + '.');
        if (typeof window.reloadFloor === 'function') window.reloadFloor();
      }
    }
  };
  async function payCash(e) {
    // Already recorded on an earlier try whose answer was lost?
    const tag = tagOf(e);
    const p = await timed(TPN.orderPayments(e.orderId), 15000);
    if ((p.payments || []).some(x => x.method === 'cash' && (x.note || '').includes(tag))) return;
    try {
      // A new order pays whatever the server says it costs (amount null);
      // the cash taken has to cover it, or the server refuses and staff
      // collect the difference.
      await timed(TPN.recordCash(e.orderId, e.cash.tendered, {
        amount: e.kind === 'cash' ? e.cash.amount : null, tip: e.cash.tip || 0,
        cashSession: e.cash.cashSession || null, note: tag }), 15000);
    } catch (err) {
      if (/already fully paid|nothing_due/.test(err.message)) { e.note = 'Already paid when it synced; the cash was not recorded twice.'; return; }
      if (/Not enough cash/.test(err.message)) {
        const need = Number(p.amount_due) || 0;
        throw new Error(`The server's total is ${P(need)} but ${P(e.cash.tendered)} cash was taken. Collect ${P(need - e.cash.tendered)} more and record it under Payment.`);
      }
      throw err;
    }
  }

  /* ── Chip in the top bar ───────────────────────────────────── */
  function paint() {
    const bar = document.querySelector('.topbar-right');
    if (!bar) return;
    let chip = document.getElementById('offlineChip');
    if (!chip) {
      chip = document.createElement('button');
      chip.id = 'offlineChip'; chip.type = 'button'; chip.className = 'topbar-btn secondary offline-chip';
      chip.setAttribute('aria-live', 'polite');
      chip.addEventListener('click', () => T.openPanel());
      bar.insertBefore(chip, bar.firstChild);
    }
    const waiting = T.entries.filter(e => e.state === 'waiting').length;
    const failed = T.entries.filter(e => e.state === 'failed').length;
    const s = (n) => n === 1 ? '' : 's';
    let text = '', state = '';
    if (!T.online) { state = 'off'; text = waiting ? `📴 Offline: ${waiting} order${s(waiting)} waiting to sync` : '📴 Offline: orders are kept on this device'; }
    else if (T.authProblem && waiting) { state = 'bad'; text = `🔑 Sign in again to sync ${waiting} order${s(waiting)}`; }
    else if (waiting) { state = 'sync'; text = `⟳ Syncing ${waiting} order${s(waiting)}…`; }
    if (failed) { state = 'bad'; text = (text ? text + ' · ' : '⚠ ') + `${failed} failed to sync`; }
    chip.hidden = !text;
    chip.textContent = text;
    chip.dataset.state = state;
    if (document.getElementById('offlinePanel')) drawPanel();
  }

  /* ── Outbox panel ──────────────────────────────────────────── */
  const TYPE = { pickup: 'Take-out', dine_in: 'Dine-in', delivery: 'Delivery' };
  const STATE = { waiting: ['warn', 'Waiting'], synced: ['ok', 'Synced'], failed: ['bad', 'Failed'] };
  T.openPanel = function () {
    if (typeof showModal !== 'function') return;
    showModal('<div class="modal-title">Offline orders</div><div class="modal-content" id="offlinePanel"></div>'
      + '<div class="modal-actions"><button class="btn-ghost" onclick="TPN_OFFLINE.sync()">↻ Sync now</button><button class="btn-next" onclick="closeModal()">Close</button></div>');
    drawPanel();
  };
  function drawPanel() {
    const box = document.getElementById('offlinePanel'); if (!box) return;
    const when = (t) => new Date(t).toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' });
    box.innerHTML = `
      <p class="pref-row-hint">${T.online ? 'Connected.' : 'No internet. New counter orders are saved here, their kitchen tickets print on this counter, and they go to the server by themselves when the connection is back.'}
        ${T.authProblem ? ' <strong>This device has to sign in again before it can sync.</strong>' : ''}</p>
      ${T.entries.length ? `<ul class="pay-list">${T.entries.slice().reverse().map(e => {
        const [cls, lab] = STATE[e.state] || ['warn', e.state];
        return `<li class="pay-row">
          <div><strong>${esc(e.localNo)}</strong> ${e.kind === 'cash' ? 'Cash for ' + esc(e.orderNumber || 'an order') : esc(TYPE[e.type] || e.type || '')}
            <span class="tpn-pill ${cls}">${esc(lab)}${e.state === 'synced' && e.orderNumber ? ' as ' + esc(e.orderNumber) : ''}</span>
            <div class="pref-row-hint">${esc(when(e.createdAt))}${e.by ? ' · ' + esc(e.by) : ''}
              ${e.lines ? ' · ' + esc(e.lines.map(l => l.qty + '× ' + l.name).join(', ')) : ''}
              ${e.cash ? ' · cash ' + esc(P(e.cash.tendered)) : e.kind === 'order' && e.type !== 'dine_in' ? ' · not paid yet' : ''}</div>
            ${e.error ? `<div class="form-error" role="alert">${e.stage === 'payment' ? 'The order went through' + (e.orderNumber ? ' as ' + esc(e.orderNumber) : '') + ', the cash did not: ' : ''}${esc(e.error)}</div>` : ''}
            ${e.note ? `<div class="pref-row-hint">${esc(e.note)}</div>` : ''}</div>
          <div class="pay-row-amt">${esc(P(e.serverTotal != null ? e.serverTotal : e.estTotal))}</div>
          <div class="pay-row-act">
            ${e.state === 'failed' ? `<button class="table-btn" onclick="TPN_OFFLINE.retry('${esc(e.id)}')">Try again</button>` : ''}
            ${e.state === 'failed' && e.orderId && window.openPaymentPanel ? `<button class="table-btn" onclick="openPaymentPanel('${esc(e.orderId)}')">Payment</button>` : ''}
            ${e.state === 'failed' ? `<button class="table-btn" onclick="TPN_OFFLINE.drop('${esc(e.id)}')">Remove</button>` : ''}
            ${e.state === 'waiting' && e.kind === 'order' && !e.cash && e.type !== 'dine_in' ? `<button class="table-btn" onclick="TPN_OFFLINE.openPayment('${esc(e.id)}')">Take cash</button>` : ''}
          </div></li>`;
      }).join('')}</ul>` : '<p class="tpn-muted">Nothing waiting.</p>'}`;
  }
  T.retry = async function (id) {
    const e = T.entries.find(x => x.id === id); if (!e) return;
    e.state = 'waiting'; e.error = ''; await putEntry(e); await load(); T.sync();
  };
  T.drop = async function (id) {
    const e = T.entries.find(x => x.id === id); if (!e) return;
    const ok = await tpnConfirm(`Remove ${e.localNo} from this list? Only do this after it has been sorted out by hand${e.orderNumber ? '' : ' — it never reached the server'}.`, { title: 'Remove from the outbox', confirmText: 'Remove', danger: true });
    if (!ok) return;
    await delEntry(id); await load(); T.openPanel();
  };

  /* ── Offline payment for a queued order ────────────────────── */
  T.openPayment = function (id) {
    const e = T.entries.find(x => x.id === id); if (!e) return;
    const due = e.estTotal;
    const quick = [...new Set([due, Math.ceil(due / 100) * 100, Math.ceil(due / 500) * 500, Math.ceil(due / 1000) * 1000])].filter(v => v >= due).slice(0, 4);
    showModal(`<div class="modal-title">Payment · ${esc(e.localNo)} <span class="tpn-pill warn">offline</span></div>
      <div class="modal-content">
        <div class="pay-head"><div><div class="pref-row-hint">Estimated total</div><span class="pref-row-hint">From the menu prices on this device. The server checks it when the order syncs.</span></div>
          <div class="pay-due"><div class="pay-due-num">${P(due)}</div></div></div>
        <div class="pay-work glass">
          <label class="form-label" for="oc-ten">Cash received</label>
          <input class="form-input pay-big" id="oc-ten" type="number" step="0.01" min="0" inputmode="decimal" placeholder="0.00">
          <div class="tpn-dlg-chips">${quick.map(v => `<button type="button" class="tpn-chip" onclick="document.getElementById('oc-ten').value='${v.toFixed(2)}';TPN_OFFLINE.calc(${due})">${P(v)}</button>`).join('')}</div>
          <div class="pay-change" id="oc-change" aria-live="assertive"></div>
          <div class="modal-actions"><button class="btn-next" onclick="TPN_OFFLINE.saveCash('${esc(e.id)}')">💵 Record cash (syncs later)</button></div>
        </div>
        <div class="pay-actions offline-off" role="group" aria-label="Needs the internet">
          ${['📱 GCash', '📲 Maya', '🔳 QR Ph', '💳 Card', '🏦 Bank transfer'].map(m => `<button class="btn-ghost" disabled>${m}</button>`).join('')}
        </div>
        <p class="pref-row-hint">GCash, Maya, QR Ph, card and bank need the internet: the reference has to be checked and recorded on the server. Take cash now, or tap <strong>Pay later</strong> and take the payment from the order once it has synced.</p>
      </div>
      <div class="modal-actions"><button class="btn-back" onclick="closeModal()">Pay later</button></div>`);
    const ten = document.getElementById('oc-ten');
    ten.addEventListener('input', () => T.calc(due)); ten.focus();
    // The customer screen works with no internet too: it's on this device.
    if (window.TPN_CDS) TPN_CDS.pay({ orderId: e.id, number: e.localNo, due, total: due, method: 'cash' });
  };
  T.calc = function (due) {
    const ten = +document.getElementById('oc-ten').value || 0, ch = ten - due, el = document.getElementById('oc-change');
    if (window.TPN_CDS) TPN_CDS.pay(Object.assign({ due, total: due, method: 'cash' }, ten && ch >= 0 ? { tendered: ten, change: ch } : {}));
    if (el) el.innerHTML = ten ? (ch >= 0 ? `Change: <strong>${P(ch)}</strong>` : `<span style="color:var(--danger)">Short by ${P(-ch)}</span>`) : '';
  };
  T.saveCash = async function (id) {
    const e = T.entries.find(x => x.id === id); if (!e) return;
    const ten = Math.round((+document.getElementById('oc-ten').value || 0) * 100) / 100;
    if (ten < e.estTotal) { window.toast && toast('Not enough cash for the bill (need ' + P(e.estTotal) + ').'); return; }
    e.cash = { tendered: ten, tip: 0, cashSession: window.tpnCashSessionId || T.lastCashSession() };
    if (e.state === 'synced') { e.state = 'waiting'; e.stage = 'payment'; }
    await putEntry(e); await load();
    if (window.TPN_PRINT) TPN_PRINT.openDrawer('cash payment (offline ' + e.localNo + ')');
    closeModal();
    window.toast && toast((ten > e.estTotal ? 'Give change: ' + P(ten - e.estTotal) + '. ' : '') + 'Cash noted; it syncs with the order.');
    if (window.TPN_CDS) TPN_CDS.thanks({ number: e.localNo, change: Math.max(0, ten - e.estTotal) });
    if (T.online) T.sync();
  };

  window.TPN_OFFLINE = T;
  // Opened with orders still waiting and the internet already back: send them now.
  const start = () => { paint(); load().then(() => probe()).then(ok => ok && T.sync()).catch(e => console.warn('[offline] outbox', e)); };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start); else start();
})();
