/* ═══════════════════════════════════════════════════════════════
   Kitchen printer — a network thermal printer (ESC/POS, port 9100)
   on the restaurant's own network.

   A web page can't open a raw printer socket, so the TPN Counter app
   (1.4+) passes the bytes on: POST http://127.0.0.1:8091/print?host=…
   The slip is the same picture modules/slips.js draws, sent as an
   ESC/POS raster image, so it looks like the counter's.

   Settings live on this device (localStorage tpn.kprint.*): the
   printer's address, port and paper width.

   TPN_KPRINT.bridge          true once the app answered /ping with print
   TPN_KPRINT.print(canvas)   send one slip; resolves or throws a message
   TPN_KPRINT.testKitchen() / testReceipt()  sample slips, marked TEST
   TPN_KPRINT.section()       the settings block for the printer menu
   TPN_KPRINT.mode()          'off' | 'kitchen' | 'counter' — where kitchen tickets print
   TPN_KPRINT.route(t, always, atCounter)   a counter order's ticket
   TPN_KPRINT.watch()         the floor screen: print QR/website orders too
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const RELAY = 'http://127.0.0.1:8091';
  const GET = (k, d) => { try { const v = localStorage.getItem('tpn.kprint.' + k); return v === null ? d : v; } catch (e) { return d; } };
  const SET = (k, v) => { try { localStorage.setItem('tpn.kprint.' + k, v); } catch (e) {} };
  const say = (m) => (window.toast ? toast(m) : console.log(m));
  const K = { bridge: false };
  K.host = () => GET('host', '');
  K.port = () => Number(GET('port', '9100')) || 9100;
  K.width = () => (GET('paper', '80') === '58' ? 384 : 576);
  // Kitchen tickets: 'off' (the kitchen works from its screen), 'kitchen'
  // (the kitchen printer; the counter printer if it fails) or 'counter'.
  // Before this setting, the old posPrintTicket pref meant 'counter'.
  K.mode = () => {
    const m = GET('mode', '');
    if (m) return m;
    try { return (JSON.parse(localStorage.getItem('tpn.prefs') || '{}') || {}).posPrintTicket === 'on' ? 'counter' : 'off'; } catch (e) { return 'off'; }
  };
  // Same rule as the app: a private IPv4 address on this network.
  K.isLan = (h) => {
    const m = /^(\d{1,3})\.(\d{1,3})\.(\d{1,3})\.(\d{1,3})$/.exec(h || '');
    if (!m) return false;
    const n = m.slice(1).map(Number);
    if (n.some(v => v > 255)) return false;
    return n[0] === 10 || (n[0] === 172 && n[1] >= 16 && n[1] <= 31) || (n[0] === 192 && n[1] === 168);
  };

  async function ping() {
    try {
      const r = await Promise.race([fetch(RELAY + '/ping', { cache: 'no-store' }), new Promise((_, no) => setTimeout(() => no(new Error('t')), 1500))]);
      const j = await r.json(); K.bridge = !!(j && j.print);
    } catch (e) { K.bridge = false; }
    return K.bridge;
  }

  /* ── ESC/POS: init, the picture in bands of raster rows, feed, cut ── */
  function escpos(src) {
    const w = K.width();
    let c = src;
    if (src.width !== w) {   // 58mm paper: scale the 80mm picture down
      c = document.createElement('canvas'); c.width = w; c.height = Math.round(src.height * w / src.width);
      const x = c.getContext('2d'); x.fillStyle = '#fff'; x.fillRect(0, 0, w, c.height); x.drawImage(src, 0, 0, w, c.height);
    }
    const px = c.getContext('2d').getImageData(0, 0, c.width, c.height).data;
    const bw = c.width / 8, out = [0x1B, 0x40];
    for (let y0 = 0; y0 < c.height; y0 += 128) {
      const h = Math.min(128, c.height - y0);
      out.push(0x1D, 0x76, 0x30, 0x00, bw & 255, bw >> 8, h & 255, h >> 8);
      for (let y = y0; y < y0 + h; y++) for (let b = 0; b < bw; b++) {
        let v = 0;
        for (let k = 0; k < 8; k++) {
          const i = (y * c.width + b * 8 + k) * 4;
          if (px[i] * 0.299 + px[i + 1] * 0.587 + px[i + 2] * 0.114 < 128) v |= 0x80 >> k;
        }
        out.push(v);
      }
    }
    out.push(0x1B, 0x64, 0x04, 0x1D, 0x56, 0x42, 0x00);   // feed 4 lines, partial cut
    return new Uint8Array(out);
  }

  K.print = async function (canvas) {
    const host = K.host();
    if (!K.isLan(host)) throw new Error('Set the kitchen printer address first.');
    if (!K.bridge && !(await ping())) throw new Error('Update the TPN Counter app to print to the kitchen printer.');
    const url = `${RELAY}/print?host=${encodeURIComponent(host)}&port=${K.port()}`;
    let r;
    try { r = await fetch(url, { method: 'POST', headers: { 'content-type': 'application/octet-stream' }, body: escpos(canvas) }); }
    catch (e) { throw new Error('The TPN Counter app did not answer.'); }
    if (!r.ok) {
      let m = ''; try { m = (await r.json()).error || ''; } catch (e) {}
      throw new Error('Kitchen printer: ' + (m || 'could not print') + '.');
    }
  };

  // Manager tools (printer.manage, sql/45), like the rest of the printer menu.
  const boss = () => !!(window.TPN && TPN.can && TPN.can('printer.manage'));
  async function test(kind) {
    if (!window.TPN_SLIP || !boss()) return;
    await TPN_SLIP.ready();
    const c = kind === 'kitchen' ? TPN_SLIP.kitchen(TPN_SLIP.sample.kitchen()) : TPN_SLIP.receipt(TPN_SLIP.sample.receipt());
    try { await K.print(c); say('Sent to the kitchen printer.'); } catch (e) { say(e.message); }
  }
  K.testKitchen = () => test('kitchen');
  K.testReceipt = () => test('receipt');

  K.save = function () {
    if (!boss()) return false;
    const h = (document.getElementById('kpHost') || {}).value || '';
    const p = (document.getElementById('kpPort') || {}).value || '9100';
    const w = (document.getElementById('kpPaper') || {}).value || '80';
    if (h && !K.isLan(h.trim())) { say('Use the printer\'s address on this network, like 192.168.1.50.'); return false; }
    const n = Number(p); if (!(n >= 9100 && n <= 9109)) { say('The port is usually 9100.'); return false; }
    const m = (document.getElementById('kpMode') || {}).value || K.mode();
    if (m === 'kitchen' && !K.isLan(h.trim())) { say('Set the kitchen printer address first.'); return false; }
    SET('host', h.trim()); SET('port', String(n)); SET('paper', w === '58' ? '58' : '80');
    SET('mode', ['off', 'kitchen', 'counter'].includes(m) ? m : 'off');
    if (m === 'kitchen') seed();
    say('Kitchen printer saved.');
    return true;
  };
  K.saveAnd = function (kind) { if (K.save()) test(kind); };

  K.section = function () {
    const E = (v) => String(v).replace(/[&<>"]/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
    return `<h3 style="margin:16px 0 8px;font-size:15px">Kitchen printer</h3>
      ${K.bridge ? '' : '<p style="margin:0 0 8px">Update the TPN Counter app to print to the kitchen printer.</p>'}
      <label style="display:block;margin-bottom:8px">Kitchen tickets<select id="kpMode" style="width:100%">
        <option value="off"${K.mode() === 'off' ? ' selected' : ''}>Kitchen screen only</option>
        <option value="kitchen"${K.mode() === 'kitchen' ? ' selected' : ''}>Kitchen printer (counter printer if it fails)</option>
        <option value="counter"${K.mode() === 'counter' ? ' selected' : ''}>Counter printer</option>
      </select></label>
      <div style="display:grid;grid-template-columns:1fr 90px 90px;gap:8px;margin-bottom:8px">
        <label>Address<input id="kpHost" inputmode="decimal" placeholder="192.168.1.50" value="${E(K.host())}" style="width:100%"></label>
        <label>Port<input id="kpPort" inputmode="numeric" value="${E(K.port())}" style="width:100%"></label>
        <label>Paper<select id="kpPaper" style="width:100%"><option value="80"${K.width() === 576 ? ' selected' : ''}>80mm</option><option value="58"${K.width() === 384 ? ' selected' : ''}>58mm</option></select></label>
      </div>
      <div style="display:flex;flex-wrap:wrap;gap:8px">
        <button class="modal-btn secondary" onclick="TPN_KPRINT.save()">Save</button>
        <button class="modal-btn secondary" onclick="TPN_KPRINT.saveAnd('kitchen')">Test kitchen ticket</button>
        <button class="modal-btn secondary" onclick="TPN_KPRINT.saveAnd('receipt')">Test receipt</button>
      </div>`;
  };

  /* ── Real tickets ─────────────────────────────────────────── */
  async function toKitchen(t, atCounter) {
    try {
      if (!window.TPN_SLIP) throw new Error('no slips');
      await TPN_SLIP.ready();
      await K.print(TPN_SLIP.kitchen(Object.assign({ at: Date.now() }, t)));
    } catch (e) {
      console.warn('kitchen printer', e);
      say('Kitchen printer didn\'t print ' + t.number + '. Printed at the counter.');
      if (atCounter) atCounter();
    }
  }
  // A counter order. True when this took care of it (or nothing should
  // print); false sends it to the counter printer as before.
  K.route = function (t, always, atCounter) {
    const m = K.mode();
    if (m === 'kitchen' && K.isLan(K.host())) { toKitchen(t, atCounter); return true; }
    if (m === 'counter') return false;
    return !always;   // screen only; offline the counter prints, as before
  };

  /* ── Orders from the QR menu and the website ─────────────────
     Counter orders print when they're sent (above). Guests' orders only
     ever reached the kitchen screen, so in kitchen-printer mode the floor
     screen prints them: straight away from its realtime feed, and a
     minute-by-minute check for any event that was missed. Each order
     prints once per device (tpn.kprint.done). Only one device should be
     set to the kitchen printer, or guests' orders print twice. */
  const DONE = 'tpn.kprint.done';
  const done = () => { try { return JSON.parse(localStorage.getItem(DONE) || '[]'); } catch (e) { return []; } };
  const mark = (id) => { const d = done(); if (!d.includes(id)) { d.push(id); try { localStorage.setItem(DONE, JSON.stringify(d.slice(-300))); } catch (e) {} } };
  const FRESH = 15 * 60 * 1000;
  const wanted = (o) => o && o.source !== 'pos' && ['pending', 'confirmed'].includes(o.status) &&
    Date.now() - new Date(o.placed_at || o.created_at).getTime() < FRESH && !done().includes(o.id);
  function fromOrder(o) {
    return {
      number: o.order_number, type: o.order_type, at: o.placed_at || o.created_at,
      where: o.restaurant_tables ? 'Table ' + o.restaurant_tables.table_number : (o.customer_name || ''),
      lines: (o.order_items || []).filter(i => !i.voided_at).map(i => ({
        qty: i.quantity, name: i.name_snapshot, size: i.pax_size || '', note: i.notes || '',
        modNames: (Array.isArray(i.modifiers) ? i.modifiers : []).map(m => (m && m.name) || '').filter(Boolean),
      })),
      note: o.notes || '',
    };
  }
  async function printOrder(o) {
    if (!wanted(o)) return;
    mark(o.id);
    const t = fromOrder(o);
    await toKitchen(t, () => window.printKitchenAtCounter && printKitchenAtCounter(t.number, t.lines, t.type, t.where));
  }
  // Everything already open counts as printed, so turning this on (or a
  // first run) doesn't print the backlog.
  async function seed() {
    try {
      const open = await TPN.listActiveOrders(null) || [];
      try { localStorage.setItem(DONE, localStorage.getItem(DONE) || '[]'); } catch (e) {}
      open.forEach(o => mark(o.id));
    } catch (e) {}
  }
  const on = () => K.mode() === 'kitchen' && K.isLan(K.host()) && window.TPN && TPN._user;
  K.onOrder = async function (id) {
    if (!on() || !localStorage.getItem(DONE)) return;
    try { await printOrder(await TPN.getOrder(id)); } catch (e) { console.warn('kitchen printer order', e); }
  };
  let watching = false;
  K.watch = function () {
    if (watching) return; watching = true;
    setInterval(async () => {
      if (!on() || document.hidden) return;
      if (!localStorage.getItem(DONE)) return seed();
      try { for (const o of (await TPN.listActiveOrders(null) || [])) await printOrder(o); } catch (e) {}
    }, 60000);
  };

  K.ping = ping;
  window.TPN_KPRINT = K;
  if (/Android/i.test(navigator.userAgent)) ping();
  if (/tpn-dine-in-floor/.test(location.pathname)) K.watch();
})();
