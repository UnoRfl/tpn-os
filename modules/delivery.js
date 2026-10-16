/* ═══════════════════════════════════════════════════════════════
   Deliveries — dispatch board and delivery areas (sql/38).

   Every delivery order lands here as "Waiting". Staff hand it to one of
   our riders or book a courier by hand (Lalamove / Grab / other) and
   paste the tracking link; then On the way → Delivered. Payment is taken
   by hand like everywhere else: Delivered asks for it first if the order
   is not paid yet.
   Areas & fees: each area's delivery fee, minimum order and usual time.
   The server adds the fee to the bill; nobody types it.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const st = { tab: 'active', list: [], zones: [], chan: null, timer: null };
  const COURIER = { own: '🛵 Our rider', lalamove: '🚚 Lalamove', grab: '🟢 Grab', other: '📦 Courier' };
  const DSTATUS = {
    waiting: ['warn', 'Waiting for a rider'], assigned: ['', 'Rider assigned'], on_the_way: ['ok', 'On the way'],
    delivered: ['ok', 'Delivered'], failed: ['bad', 'Failed']
  };
  const KITCHEN = { pending: 'New', confirmed: 'Confirmed', preparing: 'Cooking', ready: 'Ready to go', served: 'Out', completed: 'Done', cancelled: 'Cancelled' };
  const ago = (d) => { const m = Math.max(0, Math.round((Date.now() - new Date(d)) / 60000)); return m < 60 ? m + ' min ago' : Math.floor(m / 60) + 'h ' + (m % 60) + 'm ago'; };
  const mapUrl = (addr) => 'https://www.google.com/maps/search/?api=1&query=' + encodeURIComponent(addr + ', Las Piñas');
  const telUrl = (p) => 'tel:' + String(p || '').replace(/[^0-9+]/g, '').replace(/^0/, '+63');

  async function render(main) {
    main.innerHTML = `
      <div class="portal-header"><div><h1>Deliveries</h1>
        <div class="portal-header-sub">Give each delivery to a rider or a courier, then mark it on the way and delivered.</div></div>
        <div><button class="btn-ghost" onclick="dlvRefresh()">↻ Refresh</button></div></div>
      <div id="dlvTabs"></div>
      <div id="dlvBody"><div class="panel tpn-muted" style="padding:28px;text-align:center">Loading…</div></div>`;
    drawTabs();
    await load();
    live();
  }
  function drawTabs() {
    const el = document.getElementById('dlvTabs'); if (!el) return;
    const open = st.list.filter(o => !['completed', 'cancelled'].includes(o.status)).length;
    const tabs = [{ id: 'active', label: 'Active', badge: open || null }, { id: 'done', label: 'Done today' }];
    if (can('delivery.manage')) tabs.push({ id: 'zones', label: 'Areas & fees' });
    el.innerHTML = tpnTabs('Deliveries', tabs, st.tab, 'dlvTab');
  }
  window.dlvTab = (t) => { st.tab = t; drawTabs(); draw(); };
  window.dlvRefresh = () => load();

  async function load() {
    try {
      const [list, zones] = await Promise.all([
        tpnRetry(() => TPN.deliveryBoard(), { what: 'deliveries' }),
        TPN.deliveryZones(can('delivery.manage')).catch(() => [])
      ]);
      st.list = list; st.zones = zones;
      window._tpnWaitingDeliveries = list.filter(o => (o.delivery?.status || 'waiting') === 'waiting' && !['completed', 'cancelled'].includes(o.status)).length;
      drawTabs(); draw();
    } catch (e) {
      const b = document.getElementById('dlvBody');
      if (b) b.innerHTML = loadErrorPanel('deliveries', e, 'dlvRefresh()');
    }
  }
  // Realtime on dispatch rows and orders, plus a slow safety refresh.
  function live() {
    try {
      if (st.chan) sb.removeChannel(st.chan);
      st.chan = sb.channel('deliveries-board')
        .on('postgres_changes', { event: '*', schema: 'public', table: 'deliveries' }, () => load())
        .on('postgres_changes', { event: '*', schema: 'public', table: 'orders', filter: 'order_type=eq.delivery' }, () => load())
        .subscribe();
    } catch (e) { /* the refresh button and timer still work */ }
    clearInterval(st.timer);
    st.timer = setInterval(() => { if (!document.hidden && document.getElementById('dlvBody')) load(); else if (!document.getElementById('dlvBody')) { clearInterval(st.timer); if (st.chan) { try { sb.removeChannel(st.chan); } catch (e) {} st.chan = null; } } }, 45000);
  }

  function draw() {
    const b = document.getElementById('dlvBody'); if (!b) return;
    if (st.tab === 'zones') { b.innerHTML = zonesHtml(); return; }
    const done = st.tab === 'done';
    const rows = st.list.filter(o => done ? ['completed', 'cancelled'].includes(o.status) : !['completed', 'cancelled'].includes(o.status));
    const order = { failed: 0, waiting: 1, assigned: 2, on_the_way: 3, delivered: 4 };
    rows.sort((a, b) => (order[a.delivery?.status || 'waiting'] - order[b.delivery?.status || 'waiting']) || new Date(a.placed_at) - new Date(b.placed_at));
    if (!st.zones.length && can('delivery.manage') && !done) {
      b.innerHTML = `<div class="panel dlv-hint">💡 No delivery areas yet, so the website does not ask for one and charges no fee. <button class="link-btn" onclick="dlvTab('zones')">Set up areas & fees →</button></div>`;
    } else b.innerHTML = '';
    if (!rows.length) { b.innerHTML += `<div class="panel tpn-muted" style="padding:36px;text-align:center">${done ? 'No deliveries finished today yet.' : '🛵 No deliveries right now.'}</div>`; return; }
    b.innerHTML += `<div class="dlv-grid">${rows.map(card).join('')}</div>`;
  }

  function card(o) {
    const d = o.delivery || { status: 'waiting' };
    const [cls, lab] = DSTATUS[d.status] || DSTATUS.waiting;
    const paid = o.payment_status === 'paid';
    const items = (o.order_items || []).filter(i => !i.voided_at).map(i => `${i.quantity}× ${i.name_snapshot}${i.pax_size ? ' (' + i.pax_size + ')' : ''}`).join(', ');
    const closed = ['completed', 'cancelled'].includes(o.status);
    const pm = { cash: 'cash', gcash: 'GCash/Maya', paymaya: 'Maya', card: 'card', qrph: 'QR Ph' }[o.payment_method] || o.payment_method || 'cash';
    return `<article class="dlv-card panel" data-status="${E(d.status)}">
      <header class="dlv-head">
        <div><strong>${E(o.order_number)}</strong> <span class="tpn-pill ${cls}">${E(lab)}</span></div>
        <span class="pref-row-hint">${E(ago(o.placed_at))}${o.scheduled_for ? ' · for ' + E(new Date(o.scheduled_for).toLocaleString('en-PH', { hour: 'numeric', minute: '2-digit', month: 'short', day: 'numeric' })) : ''}</span>
      </header>
      <div class="dlv-who"><strong>${E(o.customer_name || 'Guest')}</strong>
        ${o.customer_phone ? `<a class="table-btn" href="${E(telUrl(o.customer_phone))}">📞 ${E(o.customer_phone)}</a>` : ''}</div>
      <div class="dlv-addr">📍 ${E(o.delivery_address || '—')} ${o.delivery_address ? `<a href="${E(mapUrl(o.delivery_address))}" target="_blank" rel="noopener">Map ↗</a>` : ''}
        ${o.delivery_zones ? `<div class="pref-row-hint">${E(o.delivery_zones.name)} · fee ${peso(o.delivery_fee)}${o.delivery_zones.eta_minutes ? ' · ~' + E(o.delivery_zones.eta_minutes) + ' min' : ''}</div>` : ''}</div>
      <div class="dlv-items pref-row-hint">${E(items)}</div>
      ${o.notes ? `<div class="dlv-note">📝 ${E(o.notes)}</div>` : ''}
      <div class="dlv-money">
        <span>Kitchen: <strong>${E(KITCHEN[o.status] || o.status)}</strong></span>
        <span>${paid ? '<span class="tpn-pill ok">Paid</span>' : `<span class="tpn-pill warn">Collect ${peso(o.total)} · ${E(pm)}</span>`}</span>
      </div>
      ${d.courier ? `<div class="dlv-courier">${E(COURIER[d.courier] || d.courier)}${d.rider_name ? ' · ' + E(d.rider_name) : ''}
        ${d.rider_phone ? ` · <a href="${E(telUrl(d.rider_phone))}">${E(d.rider_phone)}</a>` : ''}
        ${d.tracking_url ? ` · <a href="${E(d.tracking_url)}" target="_blank" rel="noopener">Tracking ↗</a>` : ''}
        ${d.courier_cost != null ? ` · cost ${peso(d.courier_cost)}` : ''}</div>` : ''}
      ${d.status === 'failed' && d.fail_reason ? `<div class="dlv-note" style="color:var(--danger)">⚠️ ${E(d.fail_reason)}</div>` : ''}
      ${closed ? '' : `<div class="dlv-actions">
        ${['waiting', 'failed', 'assigned'].includes(d.status) && can('delivery.dispatch') ? `<button class="${d.status === 'assigned' ? 'btn-ghost' : 'btn-next'}" onclick="dlvAssign('${JA(o.id)}')">${d.status === 'assigned' ? 'Change rider' : 'Assign rider'}</button>` : ''}
        ${d.status === 'assigned' ? `<button class="btn-next" onclick="dlvStatus('${JA(o.id)}','on_the_way')">🛵 On the way</button>` : ''}
        ${d.status === 'on_the_way' ? `<button class="btn-next" onclick="dlvDelivered('${JA(o.id)}')">✓ Delivered</button>` : ''}
        ${!paid && can('payments.take') ? `<button class="btn-ghost" onclick="openPaymentPanel('${JA(o.id)}')">Take payment</button>` : ''}
        ${['assigned', 'on_the_way'].includes(d.status) ? `<button class="link-btn" onclick="dlvFailed('${JA(o.id)}')">Couldn't deliver</button>` : ''}
        ${!paid && can('orders.service_charge') ? `<button class="link-btn" onclick="dlvFee('${JA(o.id)}')">Change fee</button>` : ''}
      </div>`}
    </article>`;
  }

  /* ── Assign ─────────────────────────────────────────────────── */
  window.dlvAssign = function (orderId) {
    const o = st.list.find(x => x.id === orderId), d = (o && o.delivery) || {};
    const riders = ((typeof portalState !== 'undefined' && portalState.staff) || []).filter(s => s.accountState === 'active' && !/display/.test(s.role || ''));
    showModal(`<div class="modal-title">Who is delivering ${E(o.order_number)}?</div>
      <div class="modal-content" id="dlvForm">
        <div class="tpn-dlg-chips" role="radiogroup" aria-label="Courier">
          ${Object.entries(COURIER).map(([k, v]) => `<label class="tpn-chip"><input type="radio" name="dlv-c" value="${k}" ${((d.courier || 'own') === k) ? 'checked' : ''} onchange="dlvCourierPick()"> ${E(v)}</label>`).join('')}
        </div>
        <div id="dlvOwn">
          <label class="form-label" for="dlv-rider">Rider</label>
          <select class="form-input" id="dlv-rider"><option value="">— choose —</option>
            ${riders.map(s => `<option value="${E(s.id)}" ${d.rider_staff_id === s.id ? 'selected' : ''}>${E(s.name)}</option>`).join('')}</select>
        </div>
        <div id="dlvExt" hidden>
          <div class="form-row">
            <div><label class="form-label" for="dlv-name">Rider name</label><input class="form-input" id="dlv-name" value="${E(d.courier !== 'own' ? d.rider_name || '' : '')}"></div>
            <div><label class="form-label" for="dlv-phone">Rider phone</label><input class="form-input" id="dlv-phone" type="tel" value="${E(d.rider_phone || '')}"></div>
          </div>
          <div class="form-row">
            <div><label class="form-label" for="dlv-url">Tracking link</label><input class="form-input" id="dlv-url" type="url" placeholder="https://…" value="${E(d.tracking_url || '')}"></div>
            <div><label class="form-label" for="dlv-cost">What the courier charged (₱)</label><input class="form-input" id="dlv-cost" type="number" min="0" step="1" inputmode="numeric" value="${d.courier_cost != null ? E(d.courier_cost) : ''}"></div>
          </div>
        </div>
        <label class="form-label" for="dlv-note">Note (optional)</label><input class="form-input" id="dlv-note" value="${E(d.note || '')}" placeholder="e.g. gate code, landmark">
        <div class="form-error" id="dlv-err" role="alert"></div>
      </div>
      <div class="modal-actions"><button class="btn-back" onclick="closeModal()">Cancel</button><button class="btn-next" onclick="dlvAssignSave('${JA(orderId)}')">Assign</button></div>`);
    dlvCourierPick();
  };
  window.dlvCourierPick = function () {
    const c = (document.querySelector('[name=dlv-c]:checked') || {}).value || 'own';
    document.getElementById('dlvOwn').hidden = c !== 'own';
    document.getElementById('dlvExt').hidden = c === 'own';
  };
  window.dlvAssignSave = async function (orderId) {
    const c = (document.querySelector('[name=dlv-c]:checked') || {}).value || 'own';
    const err = document.getElementById('dlv-err'); err.textContent = '';
    const val = (id) => (document.getElementById(id)?.value || '').trim();
    if (c === 'own' && !val('dlv-rider')) { err.textContent = 'Choose the rider.'; return; }
    const url = val('dlv-url');
    if (url && !/^https:\/\//.test(url)) { err.textContent = 'The tracking link must start with https://'; return; }
    try {
      await TPN.deliveryAssign(orderId, { courier: c, riderStaffId: c === 'own' ? val('dlv-rider') : null,
        riderName: c === 'own' ? null : val('dlv-name') || null, riderPhone: c === 'own' ? null : val('dlv-phone') || null,
        trackingUrl: c === 'own' ? null : url || null, courierCost: c === 'own' || !val('dlv-cost') ? null : +val('dlv-cost'),
        note: val('dlv-note') || null });
      closeModal(); toast('Assigned.'); load();
    } catch (e) { err.textContent = e.message; }
  };
  ['dlvAssignSave'].forEach(n => window.guardAsync && guardAsync(n));

  window.dlvStatus = async function (orderId, status, reason) {
    try { await TPN.deliveryUpdate(orderId, status, reason); toast(status === 'on_the_way' ? 'On the way 🛵' : 'Updated.'); load(); }
    catch (e) { toast(e.message); }
  };
  window.dlvDelivered = async function (orderId) {
    const o = st.list.find(x => x.id === orderId);
    if (o && o.payment_status !== 'paid') {
      const go = await tpnConfirm(`${o.order_number} is not paid yet (${peso(o.total)}). Take the payment first?`,
        { title: 'Collect payment', confirmText: 'Take payment', cancelText: 'Already sorted' });
      if (go) { openPaymentPanel(orderId); return; }
    }
    window.dlvStatus(orderId, 'delivered');
  };
  window.dlvFailed = async function (orderId) {
    const why = await tpnAsk('Why could it not be delivered?', { chips: ['Customer not answering', 'Wrong address', 'Customer cancelled', 'Rider problem'], input: { placeholder: 'Reason' }, confirmText: 'Mark failed', danger: true });
    if (why === null) return;
    window.dlvStatus(orderId, 'failed', why);
  };
  window.dlvFee = async function (orderId) {
    const o = st.list.find(x => x.id === orderId);
    const v = await tpnAsk(`Delivery fee for ${o.order_number}`, { chips: ['0', ...st.zones.map(z => String(Number(z.fee)))].filter((x, i, a) => a.indexOf(x) === i), input: { type: 'number', min: 0, step: '1', value: String(Number(o.delivery_fee) || 0), inputmode: 'numeric' }, confirmText: 'Next' });
    if (v === null) return;
    const why = await tpnAsk('Reason for the change', { chips: ['Regular customer', 'Promo', 'Wrong area picked', 'Nearby'], input: { placeholder: 'Reason' }, confirmText: 'Set fee ' + peso(+v) });
    if (why === null) return;
    try { await TPN.setDeliveryFee(orderId, { fee: +v, reason: why }); toast('Fee updated.'); load(); } catch (e) { toast(e.message); }
  };

  /* ── Areas & fees ───────────────────────────────────────────── */
  function zonesHtml() {
    return `<div class="panel">
      <p class="pref-row-hint" style="margin-top:0">Customers pick their area at checkout. The fee is added to their bill; orders below the minimum are not accepted for that area.</p>
      ${st.zones.length ? `<div class="data-table-wrap"><table class="data-table"><thead><tr><th>Area</th><th>Covers</th><th>Fee</th><th>Minimum</th><th>Time</th><th>Shown</th><th></th></tr></thead><tbody>
        ${st.zones.map(z => `<tr><td><strong>${E(z.name)}</strong>${z.name_tl ? `<div class="pref-row-hint">${E(z.name_tl)}</div>` : ''}</td>
          <td class="pref-row-hint">${E(z.areas || '—')}</td><td>${peso(z.fee)}</td><td>${Number(z.min_order) ? peso(z.min_order) : '—'}</td>
          <td>${z.eta_minutes ? '~' + E(z.eta_minutes) + ' min' : '—'}</td><td>${z.is_active ? '✓' : 'Off'}</td>
          <td class="table-actions"><button class="table-btn" onclick="dlvZoneEdit('${JA(z.id)}')">Edit</button></td></tr>`).join('')}
      </tbody></table></div>` : '<p class="tpn-muted">No areas yet. Start with your own city, then the next ones out.</p>'}
      <div class="modal-actions" style="justify-content:flex-start;margin-top:12px"><button class="btn-next" onclick="dlvZoneEdit(null)">＋ Add area</button>
        ${st.zones.length ? '' : '<button class="btn-ghost" onclick="dlvZoneStarter()">Add a starter set</button>'}</div>
    </div>`;
  }
  window.dlvZoneEdit = function (id) {
    const z = st.zones.find(x => x.id === id) || { fee: 50, min_order: 0, eta_minutes: 30, is_active: true, sort: 100 };
    showModal(`<div class="modal-title">${id ? 'Edit area' : 'New delivery area'}</div><div class="modal-content">
      <div class="form-row"><div><label class="form-label" for="z-name">Area name *</label><input class="form-input" id="z-name" value="${E(z.name || '')}" placeholder="e.g. Las Piñas"></div>
        <div><label class="form-label" for="z-tl">Name in Tagalog (optional)</label><input class="form-input" id="z-tl" value="${E(z.name_tl || '')}"></div></div>
      <label class="form-label" for="z-areas">Barangays / places it covers</label><input class="form-input" id="z-areas" value="${E(z.areas || '')}" placeholder="e.g. Talon Uno to Talon Singko, Pamplona, Almanza">
      <div class="form-row"><div><label class="form-label" for="z-fee">Delivery fee (₱) *</label><input class="form-input" id="z-fee" type="number" min="0" step="1" inputmode="numeric" value="${E(z.fee)}"></div>
        <div><label class="form-label" for="z-min">Minimum order (₱)</label><input class="form-input" id="z-min" type="number" min="0" step="1" inputmode="numeric" value="${E(z.min_order || 0)}"></div></div>
      <div class="form-row"><div><label class="form-label" for="z-eta">Usual travel time (minutes)</label><input class="form-input" id="z-eta" type="number" min="5" max="600" step="5" inputmode="numeric" value="${E(z.eta_minutes || '')}"></div>
        <div><label class="form-label" for="z-sort">Order in the list</label><input class="form-input" id="z-sort" type="number" step="1" inputmode="numeric" value="${E(z.sort || 100)}"></div></div>
      <label class="tpn-chip" style="margin-top:8px"><input type="checkbox" id="z-on" ${z.is_active ? 'checked' : ''}> Show this area to customers</label>
      <div class="form-error" id="z-err" role="alert"></div></div>
      <div class="modal-actions">${id ? `<button class="btn-ghost" style="margin-right:auto;color:var(--danger)" onclick="dlvZoneDelete('${JA(id)}')">Delete</button>` : ''}
        <button class="btn-back" onclick="closeModal()">Cancel</button><button class="btn-next" onclick="dlvZoneSave(${id ? `'${JA(id)}'` : 'null'})">Save</button></div>`);
  };
  window.dlvZoneSave = async function (id) {
    const v = (i) => document.getElementById(i).value.trim();
    if (v('z-name').length < 2) { document.getElementById('z-err').textContent = 'Give the area a name.'; return; }
    try {
      const branch = await TPN.getBranchByCode('laspinas');
      await TPN.saveDeliveryZone({ id, branch_id: branch && branch.id, name: v('z-name'), name_tl: v('z-tl'), areas: v('z-areas'),
        fee: v('z-fee'), min_order: v('z-min'), eta_minutes: v('z-eta'), sort: v('z-sort'), is_active: document.getElementById('z-on').checked });
      closeModal(); toast('Saved.'); load();
    } catch (e) { document.getElementById('z-err').textContent = e.message; }
  };
  ['dlvZoneSave'].forEach(n => window.guardAsync && guardAsync(n));
  window.dlvZoneDelete = async function (id) {
    if (!await tpnConfirm('Delete this area? Past orders keep their fee.', { confirmText: 'Delete', danger: true })) return;
    try { await TPN.deleteDeliveryZone(id); closeModal(); toast('Deleted.'); load(); } catch (e) { toast(e.message); }
  };
  // A sensible first draft the manager can edit: Las Piñas and its neighbours.
  window.dlvZoneStarter = async function () {
    if (!await tpnConfirm('Add Las Piñas (₱50), Parañaque / Bacoor (₱100) and Muntinlupa / Imus (₱150) as a starting point? You can change any of them.', { confirmText: 'Add them' })) return;
    try {
      const branch = await TPN.getBranchByCode('laspinas');
      const rows = [['Las Piñas', 'Las Piñas', 'All barangays in Las Piñas', 50, 0, 30, 10],
                    ['Parañaque / Bacoor', 'Parañaque / Bacoor', 'BF Homes, Moonwalk, Sucat; Molino, Niog, Talaba', 100, 500, 45, 20],
                    ['Muntinlupa / Imus', 'Muntinlupa / Imus', 'Alabang, Ayala Alabang, Tunasan; Anabu, Bucandala', 150, 800, 60, 30]];
      for (const [name, name_tl, areas, fee, min_order, eta_minutes, sort] of rows)
        await TPN.saveDeliveryZone({ branch_id: branch && branch.id, name, name_tl, areas, fee, min_order, eta_minutes, sort, is_active: true });
      toast('Added. Check the fees and areas.'); load();
    } catch (e) { toast(e.message); }
  };

  const css = `
  .dlv-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(320px,1fr));gap:14px}
  .dlv-card{display:flex;flex-direction:column;gap:8px;padding:16px 18px}
  .dlv-card[data-status="waiting"]{border-left:4px solid var(--amber,#D4720A)}
  .dlv-card[data-status="failed"]{border-left:4px solid var(--danger,#B22A1A)}
  .dlv-card[data-status="on_the_way"]{border-left:4px solid var(--success,#5C8A3A)}
  .dlv-head{display:flex;justify-content:space-between;gap:10px;align-items:flex-start;flex-wrap:wrap}
  .dlv-who{display:flex;gap:10px;align-items:center;flex-wrap:wrap}
  .dlv-who .table-btn{text-decoration:none}
  .dlv-addr a,.dlv-courier a{color:var(--brick)}
  .dlv-note{font-size:13px;background:var(--surface-2);border-radius:8px;padding:6px 10px}
  .dlv-money{display:flex;justify-content:space-between;align-items:center;gap:8px;flex-wrap:wrap;font-size:13px}
  .dlv-courier{font-size:13px}
  .dlv-actions{display:flex;flex-wrap:wrap;gap:8px;align-items:center;margin-top:4px}
  .dlv-actions .btn-next{padding:10px 18px}
  .dlv-hint{padding:12px 16px;margin-bottom:12px;font-size:13px}`;
  const style = document.createElement('style'); style.textContent = css; document.head.appendChild(style);

  TPN_MOD.register({ id: 'deliveries', side: 'both', perm: 'delivery.dispatch', icon: '🛵', label: 'Deliveries', labelTl: 'Mga delivery', render,
    badge: () => window._tpnWaitingDeliveries || null });
})();
