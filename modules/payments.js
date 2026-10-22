/* ═══════════════════════════════════════════════════════════════
   Payments — the payment panel on every order, and a Payments tab.
   Server rules: sql/31-payments.sql. Online: supabase/functions/hitpay-*.

   What staff can do here, by permission:
     payments.take      cash (with change, only while a shift is open, sql/48);
                        GCash, Maya, QR Ph, card and bank taken by hand and
                        recorded with their reference (sql/37b; bank waits for
                        a second person, sql/48)
     payments.confirm   mark a pending bank transfer received
     payments.refund    refund (cash/bank here; HitPay through HitPay)
     orders.service_charge  add / remove service charge
   Nothing on this screen writes an order's payment status. It records
   money; the database decides whether the bill is paid.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const METHOD = { cash: '💵 Cash', gcash: '📱 GCash', maya: '📲 Maya', qrph: '🔳 QR Ph', card: '💳 Card', hitpay: '🔳 Online (HitPay)', bank: '🏦 Bank transfer', card_terminal: '💳 Card terminal', other: 'Other' };
  // Taken by hand: staff show the shop's QR or run the card terminal, check
  // it went through, and type the reference shown on the customer's screen.
  const MANUAL = {
    gcash: { ref: 'GCash reference no.', hint: 'Check the customer\'s GCash shows the payment to Tyo Paeng Nyo, then type the reference number.' },
    maya:  { ref: 'Maya reference no.',  hint: 'Check the customer\'s Maya shows the payment, then type the reference number.' },
    qrph:  { ref: 'QR Ph reference no.', hint: 'Check the payment went through on the customer\'s app, then type the reference number.' },
    card:  { ref: 'Approval code',       hint: 'Run the card on the terminal. Type the approval code from the terminal slip.' },
    bank:  { ref: 'Bank reference no.',  hint: 'Type the bank reference number. Someone else checks the bank app and confirms it before the bill counts as paid.' }
  };
  const BANK_WAITING = 'Saved — waiting for someone to confirm it in the bank app.';
  const PAID_LOCKED = 'This bill is paid; refund instead.';
  const onlineOn = () => { const v = window.tpnSite && tpnSite.state.settings['payments.online_enabled']; return v === true || v === 'true' || v === 'yes'; };
  const STATUS = { completed: ['ok', 'Received'], pending: ['warn', 'Waiting'], failed: ['bad', 'Failed'], cancelled: ['bad', 'Cancelled'], expired: ['bad', 'Expired'] };
  let cur = null;           // current order payments summary
  // Customer screen (modules/customer-display.js, floor screen only): what
  // the guest sees while they pay. cdsMethod is set once staff pick a way
  // to pay here, so just opening an old bill never shows "Salamat po".
  const CDS = () => window.TPN_CDS || null;
  let cdsMethod = null, cdsChange = 0;
  const cdsPay = (extra) => { if (CDS() && cur && cur.payment_status !== 'paid') CDS().pay(Object.assign({ orderId: cur.order_id, number: cur.order_number, due: Number(cur.amount_due), total: Number(cur.total), method: cdsMethod }, extra)); };
  // modules/offline.js (floor screen only): true while the server can't be reached.
  const offline = () => !!(window.TPN_OFFLINE && TPN_OFFLINE.isOffline());
  const OFFLINE_WHY = 'No internet. GCash, Maya, QR Ph, card and bank need the server to check and record the reference, so they are off until the connection is back. Cash still works: it is saved on this device and syncs by itself.';
  let liveChan = null;
  // The branch's open shift (sql/48): cash is refused without one. undefined
  // = not known yet (offline): then the shift last seen on this device counts.
  let shift;
  async function loadShift() {
    if (offline()) { shift = undefined; return; }
    try {
      shift = await TPN.myShift();
      if (window.TPN_OFFLINE) TPN_OFFLINE.lastCashSession(shift);
      if (shift && !window.tpnCashSessionId) window.tpnCashSessionId = shift;
    } catch (e) { shift = undefined; }
  }
  const knownShift = () => shift !== undefined ? shift : (window.tpnCashSessionId || (window.TPN_OFFLINE && TPN_OFFLINE.lastCashSession()) || null);
  // The Counter's Open shift (modules/pos.js), then back to this bill.
  window.payOpenShift = async function () {
    if (typeof window.posOpenShift !== 'function') { toast('Open a shift from the Counter first.'); return; }
    await posOpenShift();
    if (cur) await refresh(cur.order_id);
  };
  function shiftBlock() {
    return `<div class="pay-work glass pay-shift" role="note"><strong>No shift is open.</strong>
      <p class="pref-row-hint">Cash goes into a counted drawer. Open a shift first; GCash, Maya, QR Ph, card and bank still work.</p>
      ${can('cash.drawer') && !offline() ? '<button class="btn-next pay-shift-btn" onclick="payOpenShift()">Open shift</button>' : '<p class="pref-row-hint">Ask someone who can open the drawer to open a shift.</p>'}</div>`;
  }
  window.payShiftBlock = shiftBlock;

  // Quick cash buttons for every cash screen (this panel, Close Table, the
  // offline panel): Exact, then the next amounts a guest is likely to hand
  // over, rounded up to the notes they carry. ₱1,165 → 1,200 / 1,500 / 2,000;
  // ₱85 → 100 / 500 / 1,000; ₱980 → 1,000 / 1,500 / 2,000.
  window.tpnCashQuick = function (due) {
    due = Math.round(Number(due) * 100) / 100;
    if (!(due > 0)) return [];
    const up = [];
    (due < 100 ? [20, 50, 100, 500, 1000] : [50, 100, 500, 1000]).forEach(s => {
      const v = Math.ceil(due / s) * s;
      if (v > due && !up.includes(v)) up.push(v);
    });
    while (up.length < 3) up.push((Math.floor((up[up.length - 1] || due) / 500) + 1) * 500);
    const fmt = (v) => '₱' + v.toLocaleString('en', { minimumFractionDigits: v % 1 ? 2 : 0, maximumFractionDigits: 2 });
    return [{ v: due, label: 'Exact' }].concat(up.slice(0, 3).map(v => ({ v, label: fmt(v) })));
  };

  function qrSvg(text, size = 220) {
    if (typeof window.qrcode !== 'function') return '';
    const q = qrcode(0, 'M'); q.addData(text); q.make();
    return q.createSvgTag({ cellSize: Math.max(2, Math.floor(size / (q.getModuleCount() + 8))), margin: 4, scalable: true });
  }

  /* ── Payment panel ───────────────────────────────────────── */
  window.openPaymentPanel = async function (orderId) {
    showModal(`<div class="modal-title">Payment</div><div class="modal-content" id="payPanel"><div class="tpn-muted">Loading…</div></div>`);
    await refresh(orderId);
    // Live: when HitPay's webhook settles the bill, the panel updates by itself.
    try {
      if (liveChan) sb.removeChannel(liveChan);
      liveChan = sb.channel('pay-' + orderId)
        .on('postgres_changes', { event: '*', schema: 'public', table: 'payments', filter: 'order_id=eq.' + orderId }, () => refresh(orderId))
        .subscribe();
    } catch (e) { /* realtime is a nicety; the Refresh button still works */ }
  };

  async function refresh(orderId) {
    const box = document.getElementById('payPanel');
    if (!box) { if (liveChan) { try { sb.removeChannel(liveChan); } catch (e) {} liveChan = null; } return; }
    try { [cur] = await Promise.all([tpnRetry(() => TPN.orderPayments(orderId), { what: 'payments' }), loadShift()]); }
    catch (e) {
      if (window.TPN_OFFLINE && TPN_OFFLINE.isNetError(e)) TPN_OFFLINE.markOffline();
      // Still drawn from before the line dropped: keep it, cash can queue.
      if (cur && cur.order_id === orderId && offline()) { draw(box); return; }
      box.innerHTML = offline()
        ? `<div class="pay-work glass" role="alert"><strong>This bill can't be loaded without the internet.</strong><p class="pref-row-hint">Take the payment once the connection is back. Orders rung up at the counter while offline take cash in the 📴 Offline list at the top.</p><button class="btn-next" onclick="openPaymentPanel('${JA(orderId)}')">↻ Try again</button></div>`
        : loadErrorPanel('the payments', e, `openPaymentPanel('${JA(orderId)}')`);
      return;
    }
    draw(box);
  }

  function draw(box) {
    const p = cur, due = Number(p.amount_due);
    const paid = p.payment_status === 'paid';
    const st = paid ? '<span class="tpn-pill ok">Paid</span>' : p.payment_status === 'refunded' ? '<span class="tpn-pill bad">Refunded</span>' : '<span class="tpn-pill warn">Not fully paid</span>';
    box.innerHTML = `
      <div class="pay-head">
        <div><div class="pref-row-hint">Order</div><strong>${E(p.order_number)}</strong> ${st}</div>
        <div class="pay-due" aria-live="polite"><div class="pref-row-hint">${due > 0 ? 'Amount due' : 'Balance'}</div><div class="pay-due-num">${peso(due)}</div></div>
      </div>
      <dl class="pay-lines">
        <div><dt>Subtotal</dt><dd>${peso(p.subtotal)}</dd></div>
        ${Number(p.discount) ? `<div><dt>Discounts</dt><dd>− ${peso(p.discount)}</dd></div>` : ''}
        <div><dt>Service charge ${can('orders.service_charge') && !paid ? `<button class="link-btn" onclick="payServiceCharge()">change</button>` : ''}</dt><dd>${peso(p.service_charge || 0)}</dd></div>
        ${(() => { const fee = Number(p.total) - (Number(p.subtotal) - Number(p.discount || 0) + Number(p.service_charge || 0)); return fee > 0.004 ? `<div><dt>Delivery fee</dt><dd>${peso(fee)}</dd></div>` : ''; })()}
        <div class="pay-total"><dt>Total</dt><dd>${peso(p.total)}</dd></div>
      </dl>
      ${paid ? `<p class="pref-row-hint pay-locked" role="note">🔒 ${E(PAID_LOCKED)}</p>` : ''}
      <div id="payInvoice"></div>
      ${due > 0 && can('payments.take') ? `
      <div class="pay-actions" role="group" aria-label="Take payment">
        <button class="btn-next" onclick="payCash()">💵 Cash${knownShift() ? '' : ' 🔒'}</button>
        ${['gcash', 'maya', 'qrph', 'card', 'bank'].map(m => `<button class="btn-ghost" ${offline() ? 'disabled' : ''} onclick="payManual('${m}')">${METHOD[m]}</button>`).join('')}
        ${onlineOn() && !offline() ? '<button class="btn-ghost" onclick="payOnline()">🌐 Online link</button>' : ''}
      </div>${offline() ? `<p class="pref-row-hint" role="note">${E(OFFLINE_WHY)}</p>` : ''}` : ''}
      <div id="payWork"></div>
      <h3 class="pay-sub">Payments on this order</h3>
      ${p.payments.length ? `<ul class="pay-list">${p.payments.map(x => {
        const [cls, lab] = STATUS[x.status] || ['warn', x.status];
        const refundable = x.kind === 'payment' && x.status === 'completed' && Number(x.amount) > Number(x.refunded);
        return `<li class="pay-row">
          <div><strong>${x.kind === 'refund' ? '↩️ Refund' : E(METHOD[x.method] || x.method)}</strong>
            ${x.provider_method ? `<span class="pref-row-hint">(${E(x.provider_method)})</span>` : ''}
            <span class="tpn-pill ${cls}">${E(lab)}</span>
            <div class="pref-row-hint">${E(new Date(x.created_at).toLocaleString('en-PH', { hour: 'numeric', minute: '2-digit', month: 'short', day: 'numeric' }))}
              ${x.tendered ? ` · tendered ${peso(x.tendered)}, change ${peso(x.change_due)}` : ''}
              ${x.reference ? ` · ref ${E(x.reference)}` : ''}${x.note ? ` · ${E(x.note)}` : ''}
              ${Number(x.refunded) ? ` · refunded ${peso(x.refunded)}` : ''}</div></div>
          <div class="pay-row-amt">${x.kind === 'refund' ? '−' : ''}${peso(x.amount)}${Number(x.tip) ? `<div class="pref-row-hint">+ tip ${peso(x.tip)}</div>` : ''}</div>
          <div class="pay-row-act">
            ${x.method === 'bank' && x.status === 'pending' && can('payments.confirm') ? `<button class="table-btn" onclick="payConfirmBank('${JA(x.id)}')">Confirm</button>` : ''}
            ${refundable && can('payments.refund') ? `<button class="table-btn" onclick="payRefund('${JA(x.id)}')">Refund</button>` : ''}
          </div></li>`;
      }).join('')}</ul>` : '<p class="tpn-muted">No payments yet.</p>'}
      <div class="modal-actions">
        <button class="btn-ghost" onclick="printReceipt('${JA(p.order_id)}')">🖨 Print bill</button>
        <button class="btn-back" onclick="closeModal()">Close</button></div>`;
    // Paid: does this sale need a booklet invoice (modules/invoices.js)?
    if (window.TPN_INVOICES && !offline()) TPN_INVOICES.orderBox(p.order_id, document.getElementById('payInvoice'), p);
    if (CDS()) {
      if (paid && cdsMethod) { CDS().thanks({ number: p.order_number, change: cdsChange }); cdsMethod = null; cdsChange = 0; }
      else if (!paid) cdsPay();
    }
  }

  /* Cash: tendered keypad with quick amounts; change shown big. */
  window.payCash = function () {
    // No open shift: the big Open shift button instead of the keypad.
    if (!knownShift()) { document.getElementById('payWork').innerHTML = shiftBlock(); return; }
    cdsMethod = 'cash'; cdsPay();
    const due = Number(cur.amount_due);
    document.getElementById('payWork').innerHTML = `
      <div class="pay-work glass">
        <div class="form-row">
          <div><label class="form-label" for="pc-amt">This payment covers</label>
            <input class="form-input" id="pc-amt" type="number" step="0.01" min="0.01" max="${due}" value="${due.toFixed(2)}" inputmode="decimal"></div>
          <div><label class="form-label" for="pc-tip">Tip (optional)</label>
            <input class="form-input" id="pc-tip" type="number" step="0.01" min="0" value="0" inputmode="decimal"></div>
        </div>
        <label class="form-label" for="pc-ten">Cash received</label>
        <input class="form-input pay-big" id="pc-ten" type="number" step="0.01" min="0" inputmode="decimal" placeholder="0.00" autofocus>
        <div class="tpn-dlg-chips pay-quick" role="group" aria-label="Quick amounts">${tpnCashQuick(due).map(q => `<button type="button" class="tpn-chip" onclick="payCashQuick(${q.v})">${E(q.label)}</button>`).join('')}</div>
        <div class="pay-change" id="pc-change" aria-live="assertive"></div>
        <div class="modal-actions"><button class="btn-next" onclick="payCashSave()">Record cash</button></div>
      </div>`;
    const w = document.getElementById('payWork');
    w.addEventListener('input', payCashCalc);
    document.getElementById('pc-ten').focus();
  };
  window.payCashQuick = function (v) { const i = document.getElementById('pc-ten'); if (i) { i.value = v.toFixed(2); payCashCalc(); } };
  window.payCashCalc = function () {
    const amt = +document.getElementById('pc-amt').value || 0, tip = +document.getElementById('pc-tip').value || 0;
    const ten = +document.getElementById('pc-ten').value || 0, ch = ten - amt - tip;
    const el = document.getElementById('pc-change');
    cdsPay(ten && ch >= 0 ? { tendered: ten, change: ch } : {});
    el.innerHTML = ten ? (ch >= 0 ? `Change: <strong>${peso(ch)}</strong>` : `<span style="color:var(--danger)">Short by ${peso(-ch)}</span>`) : '';
  };
  window.payCashSave = async function () {
    const amt = +document.getElementById('pc-amt').value, tip = +document.getElementById('pc-tip').value || 0;
    const ten = +document.getElementById('pc-ten').value;
    try {
      const r = await TPN.recordCash(cur.order_id, ten, { amount: amt, tip, cashSession: window.tpnCashSessionId || null });
      toast(r.change_due > 0 ? `Recorded. Give change: ${peso(r.change_due)}` : 'Recorded.');
      cdsChange = Number(r.change_due) || 0;
      // iMin counter: pop the cash drawer (and print, if that is switched on).
      if (window.TPN_PRINT) { TPN_PRINT.openDrawer('cash payment'); TPN_PRINT.receipt(cur.order_id).catch(() => {}); }
      await refresh(cur.order_id);
    } catch (e) {
      if (!window.TPN_OFFLINE || !TPN_OFFLINE.isNetError(e)) {
        toast(e.message);
        if (/No shift is open/.test(e.message)) { shift = null; document.getElementById('payWork').innerHTML = shiftBlock(); }
        return;
      }
      // The answer never came. Queue it; the replay checks first whether
      // this one already landed (offline.js tags the payment note).
      TPN_OFFLINE.markOffline();
      await TPN_OFFLINE.queueCash({ orderId: cur.order_id, orderNumber: cur.order_number, tendered: ten, amount: amt, tip });
      if (window.TPN_PRINT) TPN_PRINT.openDrawer('cash payment (offline)');
      const ch = ten - amt - tip;
      toast((ch > 0 ? `Give change: ${peso(ch)}. ` : '') + 'No internet: the cash is saved on this device and syncs by itself.');
      if (CDS()) { CDS().thanks({ number: cur.order_number, change: ch > 0 ? ch : 0 }); cdsMethod = null; }
      closeModal();
    }
  };
  ['payCashSave'].forEach(n => window.guardAsync && guardAsync(n));

  /* Online: HitPay checkout as a QR for the guest's own phone. */
  window.payOnline = async function () {
    const w = document.getElementById('payWork');
    w.innerHTML = '<div class="pay-work glass tpn-muted">Creating a secure payment link…</div>';
    try {
      const r = await TPN.startOnlinePayment({ orderId: cur.order_id });
      w.innerHTML = `<div class="pay-work glass" style="text-align:center">
        <p><strong>Ask the guest to scan with their phone camera</strong><br><span class="pref-row-hint">They choose QR Ph, GCash, Maya or card on HitPay's page. This screen updates by itself when HitPay confirms.</span></p>
        <div class="pay-qr" role="img" aria-label="QR code for the payment link">${qrSvg(r.checkout_url)}</div>
        <div class="pay-due-num">${peso(r.amount)}</div>
        <p><a href="${E(r.checkout_url)}" target="_blank" rel="noopener">Open payment page ↗</a> · <button class="link-btn" onclick="navigator.clipboard && navigator.clipboard.writeText('${JA(r.checkout_url)}').then(()=>toast('Link copied — paste it in Messenger or SMS'))">Copy link to send</button></p>
      </div>`;
    } catch (e) {
      w.innerHTML = `<div class="pay-work glass" role="alert"><strong>Online payment isn't available right now.</strong><p class="pref-row-hint">${E(e.message)}</p><p class="pref-row-hint">Take cash, or try again in a moment.</p></div>`;
    }
  };
  ['payOnline'].forEach(n => window.guardAsync && guardAsync(n));

  // GCash / Maya / QR Ph / card: recorded as received straight away. Bank is
  // saved as waiting until someone else confirms it (sql/48).
  window.payManual = function (method) {
    cdsMethod = method; cdsPay();
    const due = Number(cur.amount_due), m = MANUAL[method];
    document.getElementById('payWork').innerHTML = `
      <div class="pay-work glass">
        <p class="pref-row-hint">${E(m.hint)}</p>
        <div class="form-row">
          <div><label class="form-label" for="pm-amt">Amount</label><input class="form-input" id="pm-amt" type="number" step="0.01" min="0.01" max="${due}" value="${due.toFixed(2)}" inputmode="decimal"></div>
          <div><label class="form-label" for="pm-ref">${E(m.ref)} *</label><input class="form-input pay-big" id="pm-ref" autocomplete="off" inputmode="${method === 'card' ? 'text' : 'numeric'}"></div>
        </div>
        <div class="form-row">
          <div><label class="form-label" for="pm-tip">Tip (optional)</label><input class="form-input" id="pm-tip" type="number" step="0.01" min="0" value="0" inputmode="decimal"></div>
          <div><label class="form-label" for="pm-note">Note (optional)</label><input class="form-input" id="pm-note"></div>
        </div>
        <div class="modal-actions"><button class="btn-next" onclick="payManualSave('${method}')">${method === 'bank' ? 'Save for confirming' : '✓ Received'}</button></div>
      </div>`;
    document.getElementById('pm-ref').focus();
  };
  window.payManualSave = async function (method) {
    const ref = document.getElementById('pm-ref').value.trim();
    if (ref.length < 3) { toast('Type the reference / approval code.'); document.getElementById('pm-ref').focus(); return; }
    try {
      const r = await TPN.recordManualPayment(cur.order_id, method, ref, { amount: +document.getElementById('pm-amt').value,
        tip: +document.getElementById('pm-tip').value || 0, note: document.getElementById('pm-note').value.trim() });
      // Bank waits for a second person (sql/48): no receipt until it counts.
      if (r && r.pending) toast(BANK_WAITING);
      else { toast('Recorded.'); if (window.TPN_PRINT) TPN_PRINT.receipt(cur.order_id).catch(() => {}); }
      await refresh(cur.order_id);
    } catch (e) {
      if (window.TPN_OFFLINE && TPN_OFFLINE.isNetError(e)) { TPN_OFFLINE.markOffline(); toast('No answer from the server, so it may or may not have been recorded. Check this bill’s payments once the connection is back before recording it again.'); await refresh(cur.order_id); return; }
      toast(e.message);
    }
  };
  ['payManualSave'].forEach(n => window.guardAsync && guardAsync(n));

  window.payBank = function () {
    cdsMethod = 'bank'; cdsPay();
    const due = Number(cur.amount_due);
    document.getElementById('payWork').innerHTML = `
      <div class="pay-work glass">
        <p class="pref-row-hint">Recorded as <strong>waiting</strong> until someone checks the bank app and confirms it arrived.</p>
        <div class="form-row">
          <div><label class="form-label" for="pb-amt">Amount</label><input class="form-input" id="pb-amt" type="number" step="0.01" min="0.01" max="${due}" value="${due.toFixed(2)}" inputmode="decimal"></div>
          <div><label class="form-label" for="pb-ref">Bank reference no. *</label><input class="form-input" id="pb-ref" autocomplete="off"></div>
        </div>
        <div class="form-row full"><div><label class="form-label" for="pb-note">Bank / sender (optional)</label><input class="form-input" id="pb-note" placeholder="e.g. BDO, from ACME Corp"></div></div>
        <div class="modal-actions"><button class="btn-next" onclick="payBankSave()">Record transfer</button></div>
      </div>`;
  };
  window.payBankSave = async function () {
    try {
      await TPN.recordBankTransfer(cur.order_id, +document.getElementById('pb-amt').value,
        document.getElementById('pb-ref').value.trim(), document.getElementById('pb-note').value.trim());
      toast(BANK_WAITING);
      await refresh(cur.order_id);
    } catch (e) { toast(e.message); }
  };
  ['payBankSave'].forEach(n => window.guardAsync && guardAsync(n));

  window.payConfirmBank = async function (paymentId) {
    const ok = await tpnConfirm('Did this transfer arrive in the bank account? Only confirm after you have seen it in the bank app.',
      { title: 'Confirm bank transfer', confirmText: 'Yes, it arrived', cancelText: 'Not yet' });
    if (!ok) return;
    try { await TPN.confirmBankTransfer(paymentId, true); toast('Confirmed.'); }
    catch (e) { toast(e.message); }
    if (document.getElementById('payPanel') && cur) await refresh(cur.order_id);
    if (document.getElementById('payTabBody')) await loadTab();
  };

  window.payRefund = async function (paymentId) {
    const x = cur.payments.find(p => p.id === paymentId);
    const left = Number(x.amount) - Number(x.refunded || 0);
    const amt = await tpnAsk(`Refund how much? Up to ${peso(left)}`, { input: { type: 'number', value: left.toFixed(2), min: 0.01, step: '0.01', inputmode: 'decimal' }, confirmText: 'Next' });
    if (amt === null) return;
    const reason = await tpnAsk('Reason for the refund', { chips: ['Wrong order', 'Food quality', 'Long wait', 'Double payment', 'Order cancelled'], input: { placeholder: 'Reason' }, confirmText: 'Refund ' + peso(+amt), danger: true });
    if (reason === null) return;
    try {
      await TPN.refundPayment(x, +amt, reason);
      toast(x.method === 'hitpay' ? 'Refund sent through HitPay.' : 'Refund recorded. Hand the cash back to the guest.');
    } catch (e) { toast(e.message); }
    await refresh(cur.order_id);
  };

  window.payServiceCharge = async function () {
    const v = await tpnAsk('Service charge (% of the bill after discounts)', { chips: ['0', '5', '10'], input: { type: 'number', min: 0, step: '0.5', value: '10', inputmode: 'decimal' }, confirmText: 'Set' });
    if (v === null) return;
    try { await TPN.setServiceCharge(cur.order_id, { percent: +v }); await refresh(cur.order_id); }
    catch (e) { toast(e.message); }
  };

  // Counter customers claim their stamp card by scanning this (sql/34):
  // the link carries the order's private tracking token as proof.
  function rewardsQr(o, p) {
    const set = (window.tpnSite && tpnSite.state.settings) || {};
    if (!['true', 'yes', true].includes(set['rewards.enabled']) || !o.customer_phone || !o.track_token || p.payment_status !== 'paid') return '';
    const url = new URL('tpn-rewards', location.href);
    url.searchParams.set('claim', o.order_number); url.searchParams.set('t', o.track_token);
    return `<div class="c" style="margin:6px 0"><div class="n">Scan for your stamp card</div>${qrSvg(url.toString(), 140)}</div>`;
  }

  /* ── Printable bill (58/80mm thermal or A4) ──────────────── */
  window.printReceipt = async function (orderId) {
    let o, p;
    try { o = await TPN.getOrder(orderId); p = await TPN.orderPayments(orderId); }
    catch (e) { toast('Could not load the bill: ' + e.message); return; }
    // The same picture the counter printer prints (modules/slips.js).
    if (window.TPN_SLIP) {
      try {
        await TPN_SLIP.ready();
        TPN_SLIP.printWindow(TPN_SLIP.receipt(await TPN_SLIP.fromOrders([{ o, pay: p }])), o.order_number);
        return;
      } catch (e) { console.warn('bill picture', e); }
    }
    const site = (window.tpnSite && tpnSite.state.settings) || {};
    const items = (o.order_items || []).filter(i => !i.voided_at);
    const w = window.open('', '_blank', 'width=420,height=640');
    if (!w) { toast('Allow pop-ups to print.'); return; }
    w.document.write(`<!doctype html><html><head><meta charset="utf-8"><title>${E(o.order_number)}</title>
      <style>@page{size:80mm auto;margin:4mm}body{font:12px/1.35 ui-monospace,Menlo,Consolas,monospace;width:72mm;margin:0 auto;color:#000}
      h1{font-size:15px;text-align:center;margin:0}.c{text-align:center}.r{text-align:right}table{width:100%;border-collapse:collapse}
      td{vertical-align:top;padding:1px 0}.tot td{font-weight:700;border-top:1px dashed #000;padding-top:3px}hr{border:0;border-top:1px dashed #000}
      .n{font-size:10px}</style></head><body>
      <h1>Tyo Paeng Nyo</h1><div class="c n">${E(site['contact.address'] || 'KM 19, 316 Real St., Talon Uno, Las Piñas')}<br>${E(site['contact.phone'] || '0999 888 7817')}</div><hr>
      <div>Order: <b>${E(o.order_number)}</b><br>${E(new Date(o.placed_at || o.created_at).toLocaleString('en-PH'))}
      ${o.restaurant_tables ? '<br>Table ' + E(o.restaurant_tables.table_number) : ''}${o.customer_name ? '<br>' + E(o.customer_name) : ''}</div><hr>
      <table>${items.map(i => `<tr><td>${E(i.quantity)}× ${E(i.name_snapshot)}${i.pax_size ? ' (' + E(i.pax_size) + ')' : ''}</td><td class="r">${E(Number(i.total_price).toFixed(2))}</td></tr>`).join('')}
      <tr class="tot"><td>Subtotal</td><td class="r">${E(Number(o.subtotal).toFixed(2))}</td></tr>
      ${Number(o.discount_amount) ? `<tr><td>Less discounts</td><td class="r">-${E(Number(o.discount_amount).toFixed(2))}</td></tr>` : ''}
      ${Number(o.service_charge) ? `<tr><td>Service charge</td><td class="r">${E(Number(o.service_charge).toFixed(2))}</td></tr>` : ''}
      ${Number(o.delivery_fee) ? `<tr><td>Delivery fee</td><td class="r">${E(Number(o.delivery_fee).toFixed(2))}</td></tr>` : ''}
      <tr class="tot"><td>TOTAL</td><td class="r">₱${E(Number(o.total).toFixed(2))}</td></tr>
      ${p.payments.filter(x => x.status === 'completed').map(x => `<tr><td>${x.kind === 'refund' ? 'Refund' : E((METHOD[x.method] || x.method).replace(/^\S+\s/, ''))}</td><td class="r">${x.kind === 'refund' ? '-' : ''}${E(Number(x.amount).toFixed(2))}</td></tr>${x.change_due ? `<tr><td>Change</td><td class="r">${E(Number(x.change_due).toFixed(2))}</td></tr>` : ''}`).join('')}
      <tr><td>Balance</td><td class="r">${E(Number(p.amount_due).toFixed(2))}</td></tr></table><hr>
      ${rewardsQr(o, p)}
      <div class="c n">This is not an official receipt.<br>Salamat po! Come again.</div>
      <script>window.onload=()=>{window.print();setTimeout(()=>window.close(),400)}<\/script></body></html>`);
    w.document.close();
  };

  /* ── Payments tab ───────────────────────────────────────── */
  const tabState = { day: null, list: [], filter: 'all' };
  async function renderPaymentsTab(main) {
    tabState.day = tabState.day || (TPN.today ? TPN.today() : new Date().toISOString().slice(0, 10));
    main.innerHTML = `
      <div class="portal-header"><div><h1>Payments</h1>
        <div class="portal-header-sub">Every peso in and out, by the time the money moved. Online payments appear when HitPay confirms them.</div></div>
        <div style="display:flex;gap:8px;align-items:center;flex-wrap:wrap;">
          <label class="sr-only" for="payDay">Day</label><input type="date" id="payDay" class="form-input" style="width:auto" value="${E(tabState.day)}" onchange="payTabDay(this.value)">
          ${tpnExportButton('payTabExport')}</div></div>
      <div id="payTabFilters"></div>
      <div id="payTabBody" class="panel"><div class="tpn-muted" style="text-align:center;padding:24px">Loading…</div></div>`;
    await loadTab();
  }
  async function loadTab() {
    const body = document.getElementById('payTabBody'); if (!body) return;
    const lo = new Date(tabState.day + 'T00:00:00+08:00'), hi = new Date(lo.getTime() + 864e5);
    try {
      const [day, pend] = await Promise.all([
        tpnRetry(() => TPN.listPayments({ from: lo.toISOString(), to: hi.toISOString() }), { what: 'payments' }),
        tpnRetry(() => TPN.listPayments({ status: 'pending', method: 'bank' }), { what: 'pending transfers' })
      ]);
      tabState.list = day; tabState.pending = pend;
    } catch (e) { body.outerHTML = loadErrorPanel('payments', e, "route('payments',{refresh:true})"); return; }
    drawTab();
  }
  function drawTab() {
    const f = tabState.filter, rows = tabState.list.filter(x => f === 'all' || x.method === f || (f === 'refund' && x.kind === 'refund'));
    const done = tabState.list.filter(x => x.status === 'completed');
    const sum = (m) => done.filter(x => x.method === m).reduce((a, x) => a + (x.kind === 'refund' ? -1 : 1) * Number(x.amount), 0);
    document.getElementById('payTabFilters').innerHTML = tpnTabs('Filter payments', [
      { id: 'all', label: 'All', badge: tabState.list.length }, { id: 'cash', label: 'Cash ' + peso(sum('cash')) },
      { id: 'hitpay', label: 'Online ' + peso(sum('hitpay')) }, { id: 'bank', label: 'Bank ' + peso(sum('bank')) },
      { id: 'refund', label: 'Refunds' }], f, 'payTabFilter');
    const pend = tabState.pending || [];
    document.getElementById('payTabBody').innerHTML = `
      ${pend.length ? `<div class="pay-alert" role="status"><strong>🏦 ${pend.length} bank transfer${pend.length > 1 ? 's' : ''} waiting for confirmation</strong>
        <ul class="pay-list">${pend.map(x => `<li class="pay-row"><div>${E(x.orders?.order_number || '')} · ref ${E(x.reference || '')}${x.note ? ' · ' + E(x.note) : ''}</div>
          <div class="pay-row-amt">${peso(x.amount)}</div><div class="pay-row-act">${can('payments.confirm') ? `<button class="table-btn" onclick="payConfirmBank('${JA(x.id)}')">Confirm</button>` : ''}</div></li>`).join('')}</ul></div>` : ''}
      ${rows.length ? `<div class="data-table-wrap"><table class="data-table"><thead><tr><th>Time</th><th>Order</th><th>Method</th><th>Status</th><th style="text-align:right">Amount</th></tr></thead><tbody>
        ${rows.map(x => `<tr><td>${E(new Date(x.created_at).toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' }))}</td>
          <td><button class="link-btn" onclick="openPaymentPanel('${JA(x.order_id)}')">${E(x.orders?.order_number || '—')}</button></td>
          <td>${x.kind === 'refund' ? '↩️ Refund · ' : ''}${E(METHOD[x.method] || x.method)}${x.provider_method ? ' (' + E(x.provider_method) + ')' : ''}</td>
          <td><span class="tpn-pill ${(STATUS[x.status] || ['warn'])[0]}">${E((STATUS[x.status] || [0, x.status])[1])}</span></td>
          <td style="text-align:right">${x.kind === 'refund' ? '−' : ''}${peso(x.amount)}</td></tr>`).join('')}
      </tbody></table></div>` : '<p class="tpn-muted" style="padding:20px;text-align:center">No payments on this day.</p>'}`;
  }
  window.payTabDay = (d) => { tabState.day = d; loadTab(); };
  window.payTabFilter = (f) => { tabState.filter = f; drawTab(); };
  window.payTabExport = (fmt) => tpnExport(tabState.list, [
    { label: 'Time', type: 'datetime', get: r => r.created_at }, { label: 'Order', get: r => r.orders?.order_number },
    { label: 'Customer', get: r => r.orders?.customer_name }, { label: 'Type', key: 'kind' }, { label: 'Method', key: 'method' },
    { label: 'Wallet / card', key: 'provider_method' }, { label: 'Status', key: 'status' },
    { label: 'Amount', key: 'amount', type: 'money' }, { label: 'Tip', key: 'tip', type: 'money' },
    { label: 'Tendered', key: 'tendered', type: 'money' }, { label: 'Change', key: 'change_due', type: 'money' },
    { label: 'Reference', key: 'reference' }, { label: 'Note', key: 'note' }, { label: 'Confirmed', type: 'datetime', get: r => r.confirmed_at }
  ], { format: fmt, filename: 'tpn-payments-' + tabState.day, sheet: 'Payments', title: 'Tyo Paeng Nyo — payments ' + tabState.day });

  TPN_MOD.register({
    id: 'payments', side: 'admin', section: 'sec.money', icon: '💳', label: 'Payments', labelTl: 'Mga Bayad',
    perm: 'finance.view', render: renderPaymentsTab,
    badge: () => (tabState.pending || []).length || null
  });
})();
