/* ═══════════════════════════════════════════════════════════════
   iMin counter — built-in receipt printer and cash drawer.

   On the iMin D4 at the counter, iMin's "iMinprinterplugin" app (from the
   iMin App Store) runs a small service on the device at 127.0.0.1:8081.
   vendor/imin-printer-1.4.0.min.js (iMin's MIT-licensed JS SDK) talks to
   it, so this web page can print receipts and kitchen tickets and pop the
   cash drawer without any print dialog.

   Anywhere else (a laptop, a phone, the plugin not installed) nothing
   changes: printing falls back to the normal browser print window and the
   drawer is opened by hand.

   TPN_PRINT.ready        true once the printer answered
   TPN_PRINT.receipt(id)  print an order's receipt (auto after payment if on)
   TPN_PRINT.bill(ids, method)   a table's bill before paying, all rounds
   TPN_PRINT.tableReceipt(ids)   a table's receipt after paying (auto)
   TPN_PRINT.kitchen(..)  print a kitchen ticket
   TPN_PRINT.openDrawer() pop the cash drawer (logged in the audit trail)
   TPN_PRINT.testKitchen() / testReceipt()  sample slips, marked TEST

   Both slips print as one picture in the v3 look (modules/slips.js),
   one job at a time; if a picture fails, the plain text slip prints.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const PREF = (k, d) => { try { const v = localStorage.getItem('tpn.imin.' + k); return v === null ? d : v; } catch (e) { return d; } };
  const SETP = (k, v) => { try { localStorage.setItem('tpn.imin.' + k, v); } catch (e) {} };
  const peso = (v) => '₱' + Number(v || 0).toFixed(2);
  // Test prints, no-sale drawer, auto-print and the kitchen printer are
  // manager tools (printer.manage, sql/45); staff see status + Reconnect.
  const boss = () => !!(window.TPN && TPN.can && TPN.can('printer.manage'));
  const T = { ready: false, type: PREF('type', 'USB'), status: 'off', autoReceipt: PREF('auto', 'on') === 'on' };
  let p = null;

  // Only try where it can work: an Android device (the iMin), or when
  // someone switched it on by hand.
  const want = /Android/i.test(navigator.userAgent) || PREF('force', 'off') === 'on';

  async function statusOf(type) {
    try {
      p.initPrinter(type);
      const s = await Promise.race([p.getPrinterStatus(type), new Promise(r => setTimeout(() => r({ value: -1 }), 2500))]);
      return Number(s && s.value);
    } catch (e) { return -1; }
  }
  async function connect() {
    if (!want || typeof window.IminPrinter !== 'function') return paint();
    try {
      p = new IminPrinter('127.0.0.1');
      // The SDK retries every 4 s forever; on a staff phone with no printer
      // that is wasted work. No retries until the printer has answered once.
      p.reconnect = function () {};
      const ok = await p.connect();
      if (!ok) { T.status = 'no-plugin'; try { p.close(); } catch (e) {} return paint(); }
      delete p.reconnect;   // a real iMin: let the SDK recover if the service restarts
      // The D4's printer is on USB; other iMin models use SPI. Try the saved
      // one first, then the other.
      for (const type of [T.type, T.type === 'USB' ? 'SPI' : 'USB']) {
        const v = await statusOf(type);
        if (v === 0) { T.type = type; SETP('type', type); T.ready = true; T.status = 'ready'; return paint(); }
        if (v === 3) { T.status = 'cover-open'; }
        if (v === 7 || v === 8) { T.status = 'paper'; }
      }
      if (T.status === 'off' || T.status === 'no-plugin') T.status = 'error';
    } catch (e) { T.status = 'no-plugin'; }
    paint();
  }

  /* ── Layout helpers: 80mm paper, about 32 characters a line at size 24 ── */
  const W = 576;
  function line(text, { align = 0, size = 24, bold = false } = {}) {
    p.setAlignment(align); p.setTextSize(size); p.setTextStyle(bold ? 1 : 0);
    p.printText(String(text) + '\n', 0);
  }
  function cols(left, right, { bold = false, size = 24 } = {}) {
    p.setTextStyle(bold ? 1 : 0);
    p.printColumnsText([String(left), String(right)], [3, 1], [0, 2], [size, size], W);
  }
  const rule = () => line('--------------------------------', { align: 1 });

  /* ── One job at a time, so a receipt and a ticket never interleave ── */
  let queue = Promise.resolve();
  const job = (fn) => (queue = queue.then(fn).catch(e => console.warn('iMin print', e)));
  const feedCut = () => { p.printAndFeedPaper(100); p.partialCut(); };
  // The v3 picture (modules/slips.js); the plain text slip if it fails.
  async function picture(draw, text) {
    if (window.TPN_SLIP) {
      try {
        await TPN_SLIP.ready();
        const url = draw().toDataURL('image/png');
        await Promise.race([p.printSingleBitmap(url), new Promise((_, no) => setTimeout(() => no(new Error('timeout')), 15000))]);
        return feedCut();
      } catch (e) { console.warn('iMin picture, printing text', e); T.lastError = (e && e.message) || String(e); T.lastErrorAt = Date.now(); }
    }
    text(); feedCut();
  }

  const PAY = { cash: 'Cash', gcash: 'GCash', maya: 'Maya', qrph: 'QR Ph', card: 'Card', bank: 'Bank' };
  T.receipt = async function (orderId, { force = false } = {}) {
    if (!T.ready || (!force && !T.autoReceipt)) return false;
    return T.slip([orderId]);
  };
  // One slip for one order or a whole table (each round is its own order).
  // bill: what's still owed, before paying; otherwise the receipt.
  T.slip = async function (ids, { bill = false, method = '' } = {}) {
    if (!T.ready || !ids.length) return false;
    const list = await TPN_SLIP.loadOrders(ids);
    const r = await TPN_SLIP.fromOrders(list, { bill, method });
    await job(() => picture(() => TPN_SLIP.receipt(r), () => list.forEach(x => {
      textReceipt(x.o, x.pay, {}, (x.o.order_items || []).filter(i => !i.voided_at));
    })));
    return true;
  };
  T.bill = (ids, method) => T.slip(ids, { bill: true, method });
  T.tableReceipt = (ids) => (T.autoReceipt ? T.slip(ids) : Promise.resolve(false));

  function textReceipt(o, pay, site, items) {
    line('Tyo Paeng Nyo', { align: 1, size: 34, bold: true });
    line(site['contact.address'] || 'KM 19, 316 Real St., Talon Uno, Las Piñas', { align: 1, size: 20 });
    line(site['contact.phone'] || '0999 888 7817', { align: 1, size: 20 });
    rule();
    line('Order ' + o.order_number, { bold: true });
    line(new Date(o.placed_at || o.created_at).toLocaleString('en-PH'), { size: 20 });
    if (o.restaurant_tables) line('Table ' + o.restaurant_tables.table_number);
    if (o.customer_name) line(o.customer_name);
    if (o.order_type === 'delivery' && o.delivery_address) line('Deliver to: ' + o.delivery_address, { size: 20 });
    rule();
    items.forEach(i => cols(`${i.quantity}x ${i.name_snapshot}${i.pax_size ? ' (' + i.pax_size + ')' : ''}`, Number(i.total_price).toFixed(2)));
    rule();
    cols('Subtotal', Number(o.subtotal).toFixed(2));
    if (Number(o.discount_amount)) cols('Less discounts', '-' + Number(o.discount_amount).toFixed(2));
    if (Number(o.service_charge)) cols('Service charge', Number(o.service_charge).toFixed(2));
    if (Number(o.delivery_fee)) cols('Delivery fee', Number(o.delivery_fee).toFixed(2));
    cols('TOTAL', peso(o.total), { bold: true, size: 28 });
    (pay.payments || []).filter(x => x.status === 'completed').forEach(x => {
      cols(x.kind === 'refund' ? 'Refund' : (PAY[x.method] || x.method) + (x.reference ? ' ' + x.reference : ''),
           (x.kind === 'refund' ? '-' : '') + Number(x.amount).toFixed(2));
      if (Number(x.change_due)) cols('Change', Number(x.change_due).toFixed(2));
    });
    cols('Balance', Number(pay.amount_due).toFixed(2));
    rule();
    // Stamp card claim link for paid counter orders (same rule as the paper bill).
    if (['true', 'yes', true].includes(site['rewards.enabled']) && o.customer_phone && o.track_token && pay.payment_status === 'paid') {
      const url = new URL('tpn-rewards', location.href); url.searchParams.set('claim', o.order_number); url.searchParams.set('t', o.track_token);
      line('Scan for your stamp card', { align: 1, size: 20 });
      p.setQrCodeSize(6); p.printQrCode(url.toString(), 1);
    }
    line('This is not an official receipt.', { align: 1, size: 20 });
    line('Salamat po! Come again.', { align: 1, size: 22, bold: true });
  }

  T.kitchen = function (number, lines, type, where) {
    if (!T.ready) return false;
    const at = Date.now();
    job(() => picture(() => TPN_SLIP.kitchen({ number, lines, type, where, at }), () => textKitchen(number, lines, type, where)));
    return true;
  };
  function textKitchen(number, lines, type, where) {
    line(number, { size: 40, bold: true });
    if (where) line(where, { size: 34, bold: true });
    line(({ pickup: 'TAKE-OUT', dine_in: 'DINE-IN', delivery: 'DELIVERY' }[type] || type) + ' · ' +
         new Date().toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' }), { size: 24 });
    rule();
    lines.forEach(l => {
      line(`${l.qty}x ${l.name}${l.size ? ' (' + l.size + ')' : ''}`, { size: 30, bold: true });
      if (l.modNames && l.modNames.length) line('   ' + l.modNames.join(', '), { size: 24 });
      if (l.note) line('   ** ' + l.note, { size: 24 });
    });
  }

  T.openDrawer = function (reason) {
    if (!T.ready) return false;
    p.openCashBox();
    try { TPN.logAudit && TPN.logAudit('cash.drawer_open', 'register', null, { reason: reason || 'manual' }); } catch (e) {}
    return true;
  };

  // Test buttons: the same slips with made-up dishes, marked TEST.
  T.testKitchen = function () {
    if (!T.ready || !window.TPN_SLIP || !boss()) return false;
    const t = TPN_SLIP.sample.kitchen();
    job(() => picture(() => TPN_SLIP.kitchen(t), () => textKitchen(t.number, t.lines, t.type, t.where)));
    return true;
  };
  T.testReceipt = function () {
    if (!T.ready || !window.TPN_SLIP || !boss()) return false;
    job(() => picture(() => TPN_SLIP.receipt(TPN_SLIP.sample.receipt()), () => {
      line('Tyo Paeng Nyo', { align: 1, size: 34, bold: true });
      line('Printer test · ' + new Date().toLocaleString('en-PH'), { align: 1, size: 22 });
    }));
    return true;
  };

  /* ── A dropped printer link never breaks a sale ──────────────
     T.ready is set once, at connect. If the plugin's socket closes later,
     the SDK drops sends silently or throws. These run right after money
     is recorded, so: check the socket is open, never throw, and return
     false so a kitchen ticket falls back to the browser print window. */
  const live = () => T.ready && !!p && !!p.ws && p.ws.readyState === 1;
  ['kitchen', 'openDrawer', 'testKitchen', 'testReceipt'].forEach(k => {
    const f = T[k];
    T[k] = function () {
      if (!live()) return false;
      try { return f.apply(this, arguments); } catch (e) { console.warn('iMin ' + k, e); return false; }
    };
  });
  ['receipt', 'slip'].forEach(k => {
    const f = T[k];
    T[k] = async function () {
      if (!live()) return false;
      try { return await f.apply(this, arguments); } catch (e) { console.warn('iMin ' + k, e); return false; }
    };
  });

  /* ── Hook the existing print paths ─────────────────────────── */
  const origReceipt = window.printReceipt;
  if (typeof origReceipt === 'function') {
    window.printReceipt = async function (orderId) {
      if (T.ready && await T.receipt(orderId, { force: true })) { toast && toast('Printed.'); return; }
      return origReceipt.apply(this, arguments);
    };
  }

  /* ── Status chip (floor screen top bar) ────────────────────── */
  const LABEL = { ready: '🖨 Printer ready', 'no-plugin': '🖨 No printer service', error: '🖨 Printer offline', paper: '🖨 Check paper', 'cover-open': '🖨 Cover open', off: '' };
  function paint() {
    const bar = document.querySelector('.topbar-right, .topbar .actions, #topbar-actions') || document.querySelector('[data-lang-toggle]')?.parentElement;
    if (!bar || !want) return;
    let chip = document.getElementById('iminChip');
    if (!chip) {
      chip = document.createElement('button');
      chip.id = 'iminChip'; chip.type = 'button'; chip.className = 'topbar-btn secondary';
      chip.addEventListener('click', menu);
      bar.insertBefore(chip, bar.firstChild);
    }
    chip.textContent = LABEL[T.status] || '🖨 Printer';
    chip.dataset.state = T.status;
  }
  async function menu() {
    if (window.TPN_KPRINT && boss()) await TPN_KPRINT.ping();
    const mgr = boss();
    const kp = mgr && window.TPN_KPRINT;
    const html = `${kp ? '<h3 style="margin:0 0 8px;font-size:15px">Counter printer</h3>' : ''}<p style="margin:0 0 10px">${T.ready ? 'Receipts print on the built-in printer.' :
      'Install <strong>iMinprinterplugin</strong> from the iMin App Store on this device, then tap Reconnect.'}</p>
      <div style="display:flex;flex-wrap:wrap;gap:8px">
        ${T.ready && mgr ? '<button class="modal-btn secondary" onclick="TPN_PRINT.testKitchen()">Test kitchen ticket</button><button class="modal-btn secondary" onclick="TPN_PRINT.testReceipt()">Test receipt</button>' : ''}
        ${T.ready && mgr ? '<button class="modal-btn secondary" onclick="TPN_PRINT.noSale()">Open drawer</button>' : ''}
        <button class="modal-btn secondary" onclick="TPN_PRINT.reconnect()">Reconnect</button>
        ${T.ready && mgr ? `<button class="modal-btn secondary" onclick="TPN_PRINT.toggleAuto()">Auto-print receipts: ${T.autoReceipt ? 'On' : 'Off'}</button>` : ''}
      </div>${mgr && T.lastError ? `<p style="margin:10px 0 0;color:var(--danger)">Last slip printed as plain text (${new Date(T.lastErrorAt).toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' })}): ${String(T.lastError).replace(/[<&]/g, '')}</p>` : ''}${kp ? TPN_KPRINT.section() : ''}`;
    if (typeof openModal === 'function') openModal('Printers', html, [{ label: 'Close', cls: 'primary', fn: 'closeModal()' }]);
    else if (typeof showModal === 'function') showModal(`<div class="modal-title">Printers</div><div class="modal-content">${html}</div><div class="modal-actions"><button class="btn-next" onclick="closeModal()">Close</button></div>`);
  }
  // The menu's Open drawer (no sale): managers only. Cash payments still
  // open the drawer for everyone through T.openDrawer.
  T.noSale = () => boss() && T.openDrawer('no sale');
  T.reconnect = () => { T.ready = false; T.status = 'off'; try { p && p.close(); } catch (e) {} connect(); };
  T.toggleAuto = () => { if (!boss()) return; T.autoReceipt = !T.autoReceipt; SETP('auto', T.autoReceipt ? 'on' : 'off'); menu(); };

  window.TPN_PRINT = T;
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', connect); else connect();
})();
