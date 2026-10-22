/* ═══════════════════════════════════════════════════════════════
   Printed slips — the kitchen ticket and the customer receipt, drawn
   as one black-and-white picture each in the v3 look (Fraunces +
   Plus Jakarta Sans, rounded ink panels where the screens use brick).

   80mm thermal paper is 576 dots wide, so the picture is 576px wide and
   prints dot for dot. modules/imin.js sends it to the iMin printer and
   falls back to its plain text slips if the picture can't be printed.

   TPN_SLIP.kitchen(t)   → canvas   { number, where, type, at, lines }
   TPN_SLIP.receipt(r)   → canvas   see sample.receipt below
   TPN_SLIP.ready()      → promise, resolves once the fonts are in
   TPN_SLIP.sample       test data for the printer's test buttons
   TPN_SLIP.preview(k)   opens the picture in a window (any device)
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const W = 576, PAD = 20, INK = '#000', PAPER = '#fff';
  const SERIF = '"Fraunces", Georgia, serif';
  const SANS = '"Plus Jakarta Sans", system-ui, sans-serif';
  const TYPE = { dine_in: 'Dine-in', pickup: 'Take-out', delivery: 'Delivery' };
  const money = (v) => Number(v || 0).toLocaleString('en-PH', { minimumFractionDigits: 2, maximumFractionDigits: 2 });
  const clock = (d) => new Date(d).toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' });
  const day = (d) => new Date(d).toLocaleDateString('en-PH', { month: 'short', day: 'numeric', year: 'numeric' });

  /* ── Fonts: the portal serves its faces under other names, so ask
     Google Fonts for the two we draw with. Offline, Georgia and the
     system sans stand in. ─────────────────────────────────────── */
  let fonts = null;
  function ready() {
    if (fonts) return fonts;
    let l = document.querySelector('link[data-tpn-slip-fonts]');
    const sheetIn = new Promise(r => {
      if (l) return r();
      l = document.createElement('link');
      l.rel = 'stylesheet'; l.dataset.tpnSlipFonts = '1';
      l.href = 'https://fonts.googleapis.com/css2?family=Fraunces:opsz,wght@9..144,700&family=Plus+Jakarta+Sans:wght@400;600;800&display=swap';
      l.onload = l.onerror = () => r();
      document.head.appendChild(l);
    });
    // The faces only exist once the stylesheet is in; then fetch each one.
    const want = ['700 60px "Fraunces"', '400 24px "Plus Jakarta Sans"', '600 24px "Plus Jakarta Sans"', '800 24px "Plus Jakarta Sans"'];
    fonts = Promise.race([
      sheetIn.then(() => Promise.all(want.map(f => document.fonts.load(f, 'Tyo Paeng Nyo ₱1,216.00 ñ–·').catch(() => null)))),
      new Promise(r => setTimeout(r, 4000)),
    ]);
    return fonts;
  }

  /* ── A tall sheet we draw down, then crop to what was used ── */
  function sheet() {
    const c = document.createElement('canvas');
    c.width = W; c.height = 4000;
    const x = c.getContext('2d');
    x.fillStyle = PAPER; x.fillRect(0, 0, W, c.height);
    x.fillStyle = INK; x.strokeStyle = INK; x.textBaseline = 'alphabetic';
    const s = { c, x, y: PAD };
    s.font = (w, px, fam) => { x.font = `${w} ${px}px ${fam || SANS}`; };
    s.wrap = (text, maxW) => {
      const out = []; let cur = '';
      String(text).split(/\s+/).filter(Boolean).forEach(word => {
        const t = cur ? cur + ' ' + word : word;
        if (x.measureText(t).width <= maxW || !cur) cur = t; else { out.push(cur); cur = word; }
      });
      if (cur) out.push(cur);
      return out.length ? out : [''];
    };
    // Shrink a one-line heading until it fits.
    s.fit = (text, w, px, fam, maxW, min) => { let n = px; do { s.font(w, n, fam); } while (x.measureText(text).width > maxW && (n -= 2) > min); return n; };
    s.rule = (h = 2, gap = 16) => { s.y += gap; x.fillRect(PAD, s.y, W - PAD * 2, h); s.y += h + gap; };
    s.round = (rx, ry, w, h, r, fill) => {
      x.beginPath(); x.moveTo(rx + r, ry); x.arcTo(rx + w, ry, rx + w, ry + h, r); x.arcTo(rx + w, ry + h, rx, ry + h, r);
      x.arcTo(rx, ry + h, rx, ry, r); x.arcTo(rx, ry, rx + w, ry, r); x.closePath();
      fill ? x.fill() : x.stroke();
    };
    // Left text and right text on one baseline; the left side wraps.
    s.row = (left, right, { w = 400, px = 25, rw, gap = 8 } = {}) => {
      s.font(rw || w, px); const rW = right ? x.measureText(right).width : 0;
      s.font(w, px); const ls = s.wrap(left, W - PAD * 2 - rW - 16);
      ls.forEach((l, i) => {
        s.y += px * 1.3; s.font(w, px); x.textAlign = 'left'; x.fillText(l, PAD, s.y);
        if (i === 0 && right) { s.font(rw || w, px); x.textAlign = 'right'; x.fillText(right, W - PAD, s.y); }
      });
      x.textAlign = 'left'; s.y += gap;
    };
    s.center = (text, w, px, fam, gap = 6) => {
      s.font(w, px, fam); x.textAlign = 'center';
      s.wrap(text, W - PAD * 2).forEach(l => { s.y += px * 1.25; x.fillText(l, W / 2, s.y); });
      x.textAlign = 'left'; s.y += gap;
    };
    s.done = () => {
      const out = document.createElement('canvas');
      out.width = W; out.height = Math.ceil(s.y + PAD * 2);
      const o = out.getContext('2d'); o.fillStyle = PAPER; o.fillRect(0, 0, W, out.height); o.drawImage(c, 0, 0);
      return out;
    };
    return s;
  }

  // An ink panel: the heading on the left, small lines stacked on the right.
  function panel(s, left, rightLines, { px = 62, fam = SERIF, small = 25 } = {}) {
    const x = s.x, inner = 24;
    s.font(600, small); const rW = Math.max(0, ...rightLines.map(t => x.measureText(t).width));
    const room = W - PAD * 2 - inner * 2 - rW - (rW ? 20 : 0);
    // Shrink a long name a little, then wrap it rather than go tiny.
    const n = s.fit(left, 700, px, fam, room, Math.round(px * 0.7));
    s.font(700, n, fam); const ls = s.wrap(left, room), lh = n * 1.12;
    const h = Math.max(ls.length * lh, rightLines.length * small * 1.35) + inner * 1.4;
    x.fillStyle = INK; s.round(PAD, s.y, W - PAD * 2, h, 24, true);
    x.fillStyle = PAPER; x.textBaseline = 'middle';
    const top0 = s.y + h / 2 - (ls.length - 1) * lh / 2;
    ls.forEach((l, i) => x.fillText(l, PAD + inner, top0 + i * lh + n * 0.04));
    s.font(600, small); x.textAlign = 'right';
    const top = s.y + h / 2 - (rightLines.length - 1) * small * 0.675;
    rightLines.forEach((t, i) => x.fillText(t, W - PAD - inner, top + i * small * 1.35));
    x.textAlign = 'left'; x.textBaseline = 'alphabetic'; x.fillStyle = INK;
    s.y += h;
  }

  /* ── Kitchen ticket ─────────────────────────────────────────
     Big table (or guest), then each dish with its quantity in the
     margin. Notes sit in an outlined box so they can't be missed. */
  function kitchen(t) {
    const s = sheet(), x = s.x;
    const where = t.where || t.number;
    panel(s, where, [TYPE[t.type] || t.type || '', clock(t.at || Date.now())]);
    if (t.where) { s.y += 6; s.row('#' + String(t.number).replace(/^#/, ''), '', { w: 600, px: 25, gap: 4 }); }
    s.y += 10;
    // Quantities share one column, as wide as the widest of them.
    s.font(700, 46, SERIF);
    const nx = PAD + Math.max(66, ...(t.lines || []).map(l => x.measureText(String(l.qty)).width + 20)), nw = W - PAD - nx;
    (t.lines || []).forEach(l => {
      x.fillRect(PAD, s.y, W - PAD * 2, 2); s.y += 2;
      s.font(700, 46, SERIF); x.fillText(String(l.qty), PAD, s.y + 52);
      s.font(800, 31);
      s.wrap(l.name, nw).forEach((ln, i) => { s.y += i ? 38 : 48; x.fillText(ln, nx, s.y); });
      const subs = [];
      if (l.size) subs.push(l.size);
      if (l.modNames && l.modNames.length) subs.push('+ ' + l.modNames.join(', '));
      s.font(400, 25);
      subs.forEach(sub => s.wrap(sub, nw).forEach(ln => { s.y += 33; x.fillText(ln, nx, s.y); }));
      if (l.note) {
        s.font(600, 25); const ls = s.wrap(l.note, nw - 28), h = ls.length * 33 + 18;
        s.y += 12; x.lineWidth = 3; s.round(nx, s.y, nw, h, 16, false);
        ls.forEach((ln, i) => x.fillText(ln, nx + 14, s.y + 34 + i * 33));
        s.y += h;
      }
      s.y += 18;
    });
    return s.done();
  }

  /* ── Customer receipt ───────────────────────────────────────── */
  function receipt(r) {
    const s = sheet(), x = s.x;
    s.y += 6;
    s.center(r.brand || 'Tyo Paeng Nyo', 700, 50, SERIF, 4);
    if (r.address) s.center(r.address, 400, 22, SANS, 0);
    if (r.phone) s.center(r.phone, 400, 22);
    s.rule();
    s.row('Order ' + r.number, r.where || '', { w: 600, px: 25, gap: 0 });
    s.row([day(r.at), clock(r.at)].join(' · '), '', { px: 23, gap: 0 });
    if (r.deliverTo) s.row('Deliver to: ' + r.deliverTo, '', { px: 23, gap: 0 });
    s.rule();
    (r.items || []).forEach(i => {
      const price = money(i.total);
      s.font(400, 25); const pW = x.measureText(price).width, nx = PAD + 40;
      s.wrap(i.name + (i.size ? ' ' + i.size : ''), W - PAD - nx - pW - 16).forEach((ln, k) => {
        s.y += 33;
        if (!k) { x.fillText(String(i.qty), PAD, s.y); x.textAlign = 'right'; x.fillText(price, W - PAD, s.y); x.textAlign = 'left'; }
        x.fillText(ln, nx, s.y);
      });
      s.y += 4;
    });
    s.rule();
    s.row('Subtotal', money(r.subtotal), { gap: 0 });
    if (Number(r.discount)) s.row(r.discountLabel || 'Less discounts', '−' + money(r.discount), { gap: 0 });
    if (Number(r.service)) s.row('Service charge', money(r.service), { gap: 0 });
    if (Number(r.delivery)) s.row('Delivery fee', money(r.delivery), { gap: 0 });
    s.y += 18;
    panel(s, 'Total', [], { px: 27, fam: SANS });
    // The amount sits on the right of the same panel, in the display face.
    s.font(700, 46, SERIF); x.fillStyle = PAPER; x.textAlign = 'right'; x.textBaseline = 'middle';
    const ph = 27 * 1.15 + 24 * 1.4; x.fillText('₱' + money(r.total), W - PAD - 24, s.y - ph / 2 + 2);
    x.textAlign = 'left'; x.textBaseline = 'alphabetic'; x.fillStyle = INK;
    s.y += 8;
    (r.payments || []).forEach(p => {
      s.row(p.label, (p.refund ? '−' : '') + money(p.amount), { gap: 0 });
      if (Number(p.change)) s.row('Change', money(p.change), { w: 800, gap: 0 });
    });
    if (Number(r.balance) > 0) s.row('Balance', money(r.balance), { w: 800, gap: 0 });
    if (r.qr && typeof window.qrcode === 'function') {
      s.rule();
      const q = qrcode(0, 'M'); q.addData(r.qr); q.make();
      const n = q.getModuleCount(), cell = Math.max(3, Math.floor(150 / n)), size = n * cell;
      for (let i = 0; i < n; i++) for (let j = 0; j < n; j++) if (q.isDark(i, j)) x.fillRect(PAD + j * cell, s.y + i * cell, cell, cell);
      s.font(600, 25); s.wrap('Scan to collect your stamp', W - PAD * 3 - size)
        .forEach((ln, i, all) => x.fillText(ln, PAD + size + 22, s.y + size / 2 + 9 + (i - (all.length - 1) / 2) * 33));
      s.y += size;
    }
    s.rule();
    s.center('Salamat po!', 700, 38, SERIF, 2);
    s.center('This is not an official receipt.', 400, 21);
    return s.done();
  }

  /* ── Test data for the printer's test buttons ─────────────── */
  const sample = {
    kitchen: () => ({
      number: 'TEST', where: 'Table 5', type: 'dine_in', at: Date.now(),
      lines: [
        { qty: 2, name: 'Tapsilog', modNames: ['Extra egg'] },
        { qty: 1, name: 'Sinigang na Baboy', size: '3–4 pax', modNames: [], note: 'Less sour, no siling haba' },
        { qty: 1, name: 'Pancit Canton', size: 'Bilao S', modNames: [] },
        { qty: 3, name: 'Iced Tea', modNames: [] },
      ],
    }),
    receipt: () => ({
      number: 'TEST', where: 'Table 5', at: Date.now(),
      address: 'KM 19, 316 Real St., Talon Uno, Las Piñas', phone: '0999 888 7817',
      items: [
        { qty: 2, name: 'Tapsilog', total: 370 },
        { qty: 1, name: 'Sinigang na Baboy', size: '3–4 pax', total: 420 },
        { qty: 1, name: 'Pancit Canton', size: 'Bilao S', total: 350 },
        { qty: 3, name: 'Iced Tea', total: 150 },
      ],
      subtotal: 1290, discount: 74, total: 1216,
      payments: [{ label: 'Cash', amount: 1500, change: 284 }], balance: 0,
      qr: new URL('tpn-rewards', location.href).toString(),
    }),
  };

  async function preview(kind) {
    await ready();
    const c = kind === 'kitchen' ? kitchen(sample.kitchen()) : receipt(sample.receipt());
    const w = window.open('', '_blank', 'width=420,height=760');
    if (!w) return c;
    w.document.write(`<!doctype html><meta charset="utf-8"><title>${kind}</title><body style="margin:0;background:#ddd;display:flex;justify-content:center;padding:20px"><img src="${c.toDataURL('image/png')}" style="width:300px;background:#fff">`);
    w.document.close();
    return c;
  }

  window.TPN_SLIP = { kitchen, receipt, ready, sample, preview };
})();
