/* ═══════════════════════════════════════════════════════════════
   BIR invoices from the booklet (sql/43-bir-invoices.sql).

   TPN OS has no BIR Permit to Use, so the official invoice is written
   by hand from the BIR-registered booklet. This module tells staff
   when one is needed and keeps the number on record:
     orderBox  inside the payment panel, once a bill is paid
     dayBox    on the daily close: sales still missing an invoice and
               the end-of-day invoice for the small sales
   The rule (VAT-registered or not, the ₱500 line) lives in the
   database; the screen only shows what invoice_day_summary decides.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const THRESHOLD = 500;   // mirrors private.bir_threshold()
  let vatCache = null;     // { vat: bool, set: bool }

  async function vatStatus() {
    if (vatCache) return vatCache;
    const { data, error } = await sb.from('site_settings').select('value').eq('key', 'bir.vat_registered').maybeSingle();
    if (error) throw error;   // a failed read is not "not VAT-registered": don't cache it
    const v = String((data && data.value) ?? '').trim().toLowerCase();
    vatCache = { vat: ['yes', 'true', 'y', 'oo'].includes(v), set: v !== '' && v !== 'null' };
    return vatCache;
  }

  TPN.recordOrderInvoice = async function (orderId, invoiceNo) {
    const { data, error } = await sb.rpc('record_order_invoice', { p_order_id: orderId, p_invoice_no: invoiceNo });
    if (error) throw error;
    return data;
  };
  TPN.invoiceDaySummary = async function (date) {
    const { data, error } = await sb.rpc('invoice_day_summary', { p_date: date || null });
    if (error) throw error;
    return data;
  };
  TPN.recordDayInvoice = async function (date, invoiceNo, amount) {
    const { data, error } = await sb.rpc('record_day_invoice', { p_date: date, p_invoice_no: invoiceNo, p_amount: amount });
    if (error) throw error;
    return data;
  };

  /* ── One order (payment panel) ──────────────────────────── */
  async function orderBox(orderId, el, p) {
    if (!el || !p || p.payment_status !== 'paid') return;
    let o, vs;
    try {
      [{ data: o }, vs] = await Promise.all([
        sb.from('orders').select('invoice_no').eq('id', orderId).maybeSingle(),
        vatStatus()]);
    } catch (e) { return; }   // offline or no access: the panel works without it
    if (!o || !document.body.contains(el)) return;
    const total = Number(p.total);
    const needed = vs.vat || total > THRESHOLD;
    const edit = can('payments.take');
    const why = vs.vat ? 'VAT-registered: every sale gets one.' : `Over ₱${THRESHOLD}: this sale gets its own invoice.`;
    el.innerHTML = o.invoice_no
      ? `<div class="pay-work glass inv-box">🧾 BIR invoice no. <strong>${E(o.invoice_no)}</strong>
           ${edit ? `<button class="link-btn" onclick="invEdit('${JA(orderId)}')">change</button>` : ''}</div>`
      : `<div class="pay-work glass inv-box" ${needed ? 'role="alert"' : ''}>
           <strong>🧾 ${needed ? 'Write a booklet invoice for this sale' : 'Booklet invoice only if the customer asks'}</strong>
           <p class="pref-row-hint">${E(needed ? why : `Under ₱${THRESHOLD}: it goes on the end-of-day invoice (Daily close).`)}${vs.set ? '' : ' VAT status isn\'t set yet: Website → "VAT-registered?".'}</p>
           ${edit ? `<div class="form-row"><div><label class="form-label" for="inv-no">Invoice no. from the booklet</label>
             <input class="form-input" id="inv-no" autocomplete="off" inputmode="numeric" maxlength="40"></div>
             <div style="align-self:end"><button class="btn-next" onclick="invSave('${JA(orderId)}')">Save</button></div></div>` : ''}
         </div>`;
  }
  window.invSave = async function (orderId) {
    const v = (document.getElementById('inv-no') || {}).value || '';
    if (!v.trim()) { toast('Type the number printed on the booklet invoice.'); return; }
    try {
      await TPN.recordOrderInvoice(orderId, v);
      toast('Invoice number saved.');
      if (window.openPaymentPanel) openPaymentPanel(orderId);
    } catch (e) { toast(e.message); }
  };
  window.invEdit = async function (orderId) {
    const v = prompt('Correct booklet invoice no. (leave blank to remove it):');
    if (v === null) return;
    try { await TPN.recordOrderInvoice(orderId, v); toast('Saved.'); if (window.openPaymentPanel) openPaymentPanel(orderId); }
    catch (e) { toast(e.message); }
  };

  /* ── The day (daily close) ──────────────────────────────── */
  async function dayBox(date, el) {
    if (!el) return;
    let s;
    try { s = await TPN.invoiceDaySummary(date); }
    catch (e) {
      // Say so: an empty space here reads as "nothing missing".
      el.innerHTML = `<div class="panel" style="margin-top:18px;padding:14px 16px;" role="alert">
        <div class="pref-group-title">🧾 BIR invoices (booklet)</div>
        <p class="pref-row-hint">Couldn't check which sales still need a booklet invoice${navigator.onLine ? '' : ' (no internet)'}.</p>
        <button class="btn-ghost" onclick="TPN_INVOICES.dayBox(${date ? `'${JA(date)}'` : 'null'}, document.getElementById('${JA(el.id)}'))">Try again</button></div>`;
      return;
    }
    const recorded = (s.day_invoices || []).reduce((a, d) => a + Number(d.amount), 0);
    const left = Math.max(0, Number(s.small_total) - recorded);
    const miss = s.missing || [];
    el.innerHTML = `<div class="panel" style="margin-top:18px;padding:14px 16px;">
      <div class="pref-group-title">🧾 BIR invoices (booklet)</div>
      ${s.vat_status_set ? '' : `<p class="pref-row-hint" role="alert">VAT status isn't set. Website → "VAT-registered?" (yes / no). Until then this assumes not VAT-registered.</p>`}
      <p class="pref-row-hint">${s.vat_registered ? 'VAT-registered: every sale needs its own invoice.' : `Not VAT-registered: sales over ₱${N(s.threshold, 0)} get their own invoice; the rest go on one end-of-day invoice.`}
        ${Number(s.invoiced)} sale(s) already have a number.</p>
      ${miss.length ? `<div style="margin:8px 0"><strong>${miss.length} paid sale(s) still need their own invoice:</strong>
        <ul style="margin:6px 0 0 18px">${miss.slice(0, 20).map(m => `<li><button class="link-btn" onclick="openPaymentPanel('${JA(m.id)}')">${E(m.order_number)}</button> · ₱${N(m.total, 2)}</li>`).join('')}</ul>
        ${miss.length > 20 ? `<div class="pref-row-hint">…and ${miss.length - 20} more.</div>` : ''}</div>`
        : '<p class="pref-row-hint">✓ Every sale that needs its own invoice has one.</p>'}
      ${s.vat_registered ? '' : `<div style="margin-top:10px">
        <div>Small sales without an invoice: <strong>₱${N(s.small_total, 2)}</strong> (${Number(s.small_count)} sale(s))${recorded ? ` · day invoice(s) written: ₱${N(recorded, 2)}` : ''}</div>
        ${(s.day_invoices || []).map(d => `<div class="pref-row-hint">Day invoice no. ${E(d.invoice_no)} · ₱${N(d.amount, 2)}</div>`).join('')}
        ${left > 0.004 && (can('payments.take') || can('finance.view')) ? `<div class="form-row" style="margin-top:8px">
          <div><label class="form-label" for="dinv-no">End-of-day invoice no.</label><input class="form-input" id="dinv-no" autocomplete="off" maxlength="40"></div>
          <div><label class="form-label" for="dinv-amt">Amount</label><input class="form-input" id="dinv-amt" type="number" step="0.01" min="0.01" value="${left.toFixed(2)}"></div>
          <div style="align-self:end"><button class="btn-next" onclick="invDaySave('${JA(s.date)}')">Save</button></div></div>
          <p class="pref-row-hint">Write one booklet invoice for ₱${N(left, 2)} ("sales for ${E(s.date)}"), then type its number here.</p>` : ''}
      </div>`}
    </div>`;
  }
  window.invDaySave = async function (date) {
    const no = (document.getElementById('dinv-no') || {}).value || '';
    const amt = Number((document.getElementById('dinv-amt') || {}).value || 0);
    if (!no.trim()) { toast('Type the booklet invoice number.'); return; }
    try { await TPN.recordDayInvoice(date, no, amt); toast('Day invoice saved.'); dayBox(date, document.getElementById('birInvoiceBox')); }
    catch (e) { toast(e.message); }
  };

  const N = (v, d) => Number(v || 0).toLocaleString('en-PH', { minimumFractionDigits: d, maximumFractionDigits: d });
  window.TPN_INVOICES = { orderBox, dayBox };
})();
