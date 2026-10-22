/* ═══════════════════════════════════════════════════════════════
   Counter POS — walk-in and phone orders at the counter.
   Rules live in sql/32 (submit_order prices everything; cash drawer
   shifts with X/Z reads) and sql/31 (payments).

   Built for speed and for gloves-on tapping: big tiles, search, one-tap
   repeat, a ticket that stays visible, and nothing lost if the tab
   reloads (the ticket is kept on this device until it is sent).
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const TICKET_KEY = 'tpn.pos.ticket';
  const HELD_KEY = 'tpn.pos.held';   // tickets parked with Hold, this device only
  const TOP_KEY = 'tpn.pos.top';     // "Most ordered" ranking, refreshed once a day
  // modules/offline.js, on the floor screen only (the portal has no outbox).
  const OFF = () => window.TPN_OFFLINE || null;
  const st = {
    cats: [], items: [], mods: { groups: [], byItem: {} }, tables: [], branch: null, zones: [], zone: '',
    cat: 'all', q: '', session: null, report: null,
    ticket: load(), held: loadKey(HELD_KEY, []), top: loadKey(TOP_KEY, null), type: 'pickup', table: '', name: '', phone: '', address: '', notes: ''
  };
  function load() { try { return JSON.parse(localStorage.getItem(TICKET_KEY) || '[]'); } catch (e) { return []; } }
  function save() { try { localStorage.setItem(TICKET_KEY, JSON.stringify(st.ticket)); } catch (e) {} }
  function loadKey(k, dflt) { try { return JSON.parse(localStorage.getItem(k) || 'null') || dflt; } catch (e) { return dflt; } }
  function saveKey(k, v) { try { localStorage.setItem(k, JSON.stringify(v)); } catch (e) {} }

  async function loadData() {
    st.branch = st.branch || await TPN.getBranchByCode('laspinas');
    const [c, i, m, t, s] = await Promise.all([
      sb.from('menu_categories').select('*').eq('is_active', true).order('display_order'),
      sb.from('menu_items').select('*').order('display_order'),
      TPN.loadModifiers().catch(() => ({ groups: [], byItem: {} })),       // works before sql/32 too
      TPN.getTablesForBranch(st.branch.id).catch(() => []),
      can('cash.drawer') ? TPN.myOpenCashSession().then(id => OFF() ? OFF().lastCashSession(id) : id)
        .catch(() => OFF() && OFF().isOffline() ? OFF().lastCashSession() : null) : Promise.resolve(null)
    ]);
    st.zones = await (TPN.deliveryZones ? TPN.deliveryZones().catch(() => []) : []);
    if (c.error) throw c.error; if (i.error) throw i.error;
    st.cats = c.data; st.items = i.data; st.mods = m; st.tables = t; st.session = s;
    window.tpnCashSessionId = s || null;
    // The floor screen opens the counter for a table: Dine-in, that table, the guest's name.
    if (st.pending) {
      const p = st.pending; st.pending = null;
      if (p.type) st.type = p.type;
      if (p.table != null) st.table = (st.tables.find(x => Number(x.table_number) === Number(p.table)) || {}).id || '';
      if (p.name && !st.name) st.name = p.name;
    }
  }
  window.posStartFor = function (opts) { st.pending = opts || null; };

  async function render(main) {
    main.innerHTML = `
      <div class="portal-header pos-header"><div><h1>Counter</h1>
        <div class="portal-header-sub">Ring up walk-in and phone orders. Prices come from the menu; the kitchen sees it the moment you send.</div></div>
        <div id="posDrawer" class="pos-drawer"></div></div>
      <div class="pos-wrap">
        <section class="pos-menu panel" aria-label="Menu">
          <label class="sr-only" for="posSearch">Search the menu</label>
          <input id="posSearch" class="form-input" type="search" placeholder="Search dishes… (press / to focus)" autocomplete="off" oninput="posSearch(this.value)">
          <div id="posTop"></div>
          <div id="posCats"></div>
          <div id="posGrid" class="pos-grid" role="list"></div>
        </section>
        <aside class="pos-ticket panel" aria-label="Current order" id="posTicket"></aside>
      </div>`;
    try { await loadData(); }
    catch (e) { main.querySelector('.pos-wrap').outerHTML = loadErrorPanel('the menu', e, "route('pos',{refresh:true})"); return; }
    drawDrawer(); drawCats(); drawGrid(); drawTicket();
    refreshTop();
  }

  /* ── Drawer bar ──────────────────────────────────────────── */
  function drawDrawer() {
    const el = document.getElementById('posDrawer'); if (!el) return;
    if (!can('cash.drawer')) { el.innerHTML = ''; return; }
    el.innerHTML = st.session
      ? `<span class="tpn-pill ok">Drawer open</span>
         <details class="tpn-menu"><summary class="btn-ghost tpn-menu-btn">Drawer ▾</summary>
           <div class="tpn-menu-list glass" role="menu">
             <button role="menuitem" onclick="posCashMove('cash_in')">＋ Cash in</button>
             <button role="menuitem" onclick="posCashMove('cash_out')">－ Cash out / petty cash</button>
             <button role="menuitem" onclick="posXRead()">X read (mid-shift report)</button>
             <button role="menuitem" onclick="posCloseShift()">Close shift (Z read)</button>
           </div></details>`
      : `<span class="tpn-pill warn">Drawer closed</span><button class="btn-next" style="margin:0" onclick="posOpenShift()">Open shift</button>`;
  }
  window.posOpenShift = async function () {
    const f = await tpnAsk('Opening cash (float) in the drawer', { chips: ['1000', '2000', '3000'], input: { type: 'number', min: 0, step: '0.01', inputmode: 'decimal', placeholder: '₱' }, confirmText: 'Open drawer' });
    if (f === null) return;
    try { st.session = await TPN.openCashSession(+f); window.tpnCashSessionId = st.session; toast('Drawer open with ' + peso(+f)); drawDrawer(); }
    catch (e) { toast(/already_open/.test(e.message) ? 'A drawer is already open on this register.' : e.message); }
  };
  window.posCashMove = async function (kind) {
    const amt = await tpnAsk(kind === 'cash_in' ? 'Cash put INTO the drawer' : 'Cash taken OUT of the drawer', { input: { type: 'number', min: 0.01, step: '0.01', inputmode: 'decimal' }, confirmText: 'Next' });
    if (amt === null) return;
    const why = await tpnAsk('What for?', { chips: kind === 'cash_in' ? ['Change top-up from safe', 'Owner deposit'] : ['Bought ice', 'Bought gas/LPG', 'Rider fare', 'Supplies', 'To safe'], input: { placeholder: 'Reason' } });
    if (why === null) return;
    try { await TPN.cashMove(st.session, kind, +amt, why); toast('Recorded.'); } catch (e) { toast(e.message); }
  };
  function reportHtml(r, title) {
    const row = (a, b, strong) => `<div style="display:flex;justify-content:space-between;padding:4px 0;border-bottom:1px solid var(--line-soft)">${strong ? `<strong>${a}</strong><strong>${b}</strong>` : `<span>${a}</span><span>${b}</span>`}</div>`;
    return `<div class="modal-title">${E(title)}</div><div class="modal-content" style="font-variant-numeric:tabular-nums">
      ${row('Opening float', peso(r.opening_float))}${row('Cash sales (' + r.sales_count + ')', peso(r.cash_sales))}${row('Tips (cash)', peso(r.tips))}
      ${row('Cash refunds', '− ' + peso(r.cash_refunds))}${row('Cash in', peso(r.cash_in))}${row('Cash out', '− ' + peso(r.cash_out))}
      ${row('Expected in drawer', peso(r.expected_cash), true)}
      ${r.counted != null ? row('Counted', peso(r.counted), true) + row('Variance', (r.variance < 0 ? '− ' : '') + peso(Math.abs(r.variance)), true) : ''}
      <div class="pref-row-hint" style="margin-top:10px">Other methods this shift: ${Object.entries(r.other_methods || {}).map(([k, v]) => E(k) + ' ' + peso(v)).join(' · ') || 'none'}</div></div>`;
  }
  window.posXRead = async function () {
    try { const r = await TPN.cashSessionReport(st.session); showModal(reportHtml(r, 'X read — ' + new Date().toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' })) + `<div class="modal-actions"><button class="btn-ghost" onclick="window.print()">🖨 Print</button><button class="btn-next" onclick="closeModal()">Done</button></div>`); }
    catch (e) { toast(e.message); }
  };
  const DENOMS = [1000, 500, 200, 100, 50, 20, 10, 5, 1, 0.25];
  window.posCloseShift = async function () {
    let r; try { r = await TPN.cashSessionReport(st.session); } catch (e) { toast(e.message); return; }
    showModal(`<div class="modal-title">Close shift — count the drawer</div>
      <div class="modal-content"><p class="pref-row-hint">Count each bill and coin. Expected in the drawer: <strong>${peso(r.expected_cash)}</strong>.</p>
      <div class="pos-denoms">${DENOMS.map(d => `<label>₱${d}<input class="form-input" type="number" min="0" step="1" inputmode="numeric" data-denom="${d}" value=""></label>`).join('')}</div>
      <div class="pay-change" id="zTotal" aria-live="polite"></div>
      <label class="form-label" for="zNotes">Notes</label><input class="form-input" id="zNotes" placeholder="Anything unusual this shift">
      </div><div class="modal-actions"><button class="btn-back" onclick="closeModal()">Cancel</button><button class="btn-next" onclick="posCloseShiftSave(${Number(r.expected_cash)})">Close shift</button></div>`);
    const upd = () => {
      const t = [...document.querySelectorAll('[data-denom]')].reduce((a, i) => a + (+i.dataset.denom) * (+i.value || 0), 0);
      const v = Math.round((t - Number(r.expected_cash)) * 100) / 100;
      document.getElementById('zTotal').innerHTML = `Counted <strong>${peso(t)}</strong> · ${v === 0 ? 'exact ✅' : v > 0 ? 'over by ' + peso(v) : '<span style="color:var(--danger)">short by ' + peso(-v) + '</span>'}`;
    };
    document.querySelector('.pos-denoms').addEventListener('input', upd); upd();
  };
  window.posCloseShiftSave = async function (expected) {
    const den = {}; let total = 0;
    document.querySelectorAll('[data-denom]').forEach(i => { const n = +i.value || 0; if (n) { den[i.dataset.denom] = n; total += (+i.dataset.denom) * n; } });
    total = Math.round(total * 100) / 100;
    if (Math.abs(total - expected) > 0.009 && !await tpnConfirm(`The count is ${peso(total)} but ${peso(expected)} was expected. Close anyway? The difference is recorded with your name.`, { title: 'Count does not match', confirmText: 'Close shift' })) return;
    try {
      const z = await TPN.closeCashSession(st.session, total, den, document.getElementById('zNotes').value);
      st.session = null; window.tpnCashSessionId = null; drawDrawer();
      showModal(reportHtml(z, 'Z read — shift closed') + `<div class="modal-actions"><button class="btn-ghost" onclick="window.print()">🖨 Print</button><button class="btn-next" onclick="closeModal()">Done</button></div>`);
    } catch (e) { toast(e.message); }
  };
  ['posCloseShiftSave'].forEach(n => window.guardAsync && guardAsync(n));

  /* ── Menu ────────────────────────────────────────────────── */
  function drawCats() {
    const tabs = [{ id: 'all', label: 'All' }].concat(st.cats.map(c => ({ id: c.id, label: (c.icon ? c.icon + ' ' : '') + c.name })));
    document.getElementById('posCats').innerHTML = tpnTabs('Menu categories', tabs, st.cat, 'posCat');
  }
  window.posCat = (c) => { st.cat = c; drawCats(); drawGrid(); };
  window.posSearch = (q) => { st.q = q.trim().toLowerCase(); drawGrid(); };
  const priceLabel = (it) => it.pax_options && Object.keys(it.pax_options).length
    ? Object.values(it.pax_options).map(v => peso(v)).join(' / ') : peso(it.price);
  const tile = (it) => `
      <button type="button" role="listitem" class="pos-tile ${it.is_available === false ? 'is-out' : ''}" ${it.is_available === false ? 'aria-disabled="true"' : ''}
        onclick="posPick('${JA(it.id)}')" aria-label="${E(it.name)}, ${E(priceLabel(it))}${it.is_available === false ? ', sold out' : ''}">
        ${window.TPN_PHOTO && TPN_PHOTO(it.name) ? `<img class="pos-tile-photo" src="${E(TPN_PHOTO(it.name))}" alt="" loading="lazy" decoding="async" width="72" height="72">` : `<span class="pos-tile-emoji" aria-hidden="true">${E(it.emoji || '🍽️')}</span>`}
        <span class="pos-tile-name">${E(it.name)}</span>
        <span class="pos-tile-price">${it.is_available === false ? 'Sold out' : E(priceLabel(it))}</span>
      </button>`;
  function drawGrid() {
    const g = document.getElementById('posGrid'); if (!g) return;
    const rows = st.items.filter(it => (st.cat === 'all' || it.category_id === st.cat)
      && (!st.q || (it.name + ' ' + (it.name_tagalog || '')).toLowerCase().includes(st.q)));
    g.innerHTML = rows.map(tile).join('') || '<p class="tpn-muted" style="padding:20px">No dishes match.</p>';
    drawTop();
  }

  /* ── Most ordered ────────────────────────────────────────── */
  // The 12 dishes sold most in the last 30 days, first on the All tab.
  // Ranked from completed orders of this branch (staff can read their own
  // branch's orders), kept on the device so it works offline, refreshed
  // once a day. Until there are enough sales the menu's ★ Bestsellers fill in.
  function topItems() {
    const by = new Map(st.items.map(it => [it.id, it]));
    const ids = ((st.top && st.top.ids) || []).concat(st.items.filter(it => it.is_featured).map(it => it.id));
    const out = [];
    for (const id of ids) {
      const it = by.get(id);
      if (it && it.is_available !== false && !out.includes(it)) out.push(it);
      if (out.length === 12) break;
    }
    return out;
  }
  function drawTop() {
    const el = document.getElementById('posTop'); if (!el) return;
    const rows = st.cat === 'all' && !st.q ? topItems() : [];
    el.innerHTML = rows.length ? `<h2 class="pos-top-h" id="posTopH">Most ordered</h2>
      <div class="pos-grid pos-top-grid" role="list" aria-labelledby="posTopH">${rows.map(tile).join('')}</div>` : '';
  }
  async function refreshTop() {
    const today = TPN.today ? TPN.today() : new Date().toISOString().slice(0, 10);
    if (st.top && st.top.day === today && st.top.branch === st.branch.id) return;
    if (OFF() && OFF().isOffline()) return;
    try {
      const since = new Date(Date.now() - 30 * 864e5).toISOString(), tally = {};
      for (let from = 0; from < 50000; from += 1000) {   // the API hands back 1,000 rows at a time
        const r = await sb.from('order_items').select('menu_item_id, quantity, orders!inner(branch_id, status, placed_at)')
          .eq('orders.branch_id', st.branch.id).eq('orders.status', 'completed').gte('orders.placed_at', since)
          .is('voided_at', null).not('menu_item_id', 'is', null).order('id').range(from, from + 999);
        if (r.error) throw r.error;
        r.data.forEach(x => { tally[x.menu_item_id] = (tally[x.menu_item_id] || 0) + (Number(x.quantity) || 0); });
        if (r.data.length < 1000) break;
      }
      const ids = Object.keys(tally).sort((a, b) => tally[b] - tally[a]).slice(0, 40);
      st.top = { day: today, branch: st.branch.id, ids }; saveKey(TOP_KEY, st.top);
      drawTop();
    } catch (e) { console.warn('[pos] most ordered', e); }   // the cached row (or the Bestsellers) stays
  }

  window.posPick = function (id) {
    const it = st.items.find(x => x.id === id); if (!it) return;
    if (it.is_available === false) { toast(it.name + ' is sold out.'); return; }
    const groups = st.mods.byItem[id] || [];
    const sizes = it.pax_options ? Object.keys(it.pax_options) : [];
    if (!groups.length && sizes.length <= 1) return addLine(it, sizes[0] || null, [], 1, '');
    showModal(`<div class="modal-title">${E(it.name)}</div><div class="modal-content" id="posOpt">
      ${sizes.length > 1 ? `<fieldset class="pos-fs"><legend class="form-label">Size</legend><div class="tpn-dlg-chips">
        ${sizes.map((s, i) => `<label class="tpn-chip"><input type="radio" name="pos-size" value="${E(s)}" ${i === 0 ? 'checked' : ''}> ${E(s)} pax · ${peso(it.pax_options[s])}</label>`).join('')}</div></fieldset>` : ''}
      ${groups.map(g => `<fieldset class="pos-fs" data-group="${E(g.id)}" data-min="${g.min_select}" data-max="${g.max_select}">
        <legend class="form-label">${E(g.name)} <span class="form-hint">${g.min_select ? 'choose ' + (g.min_select === g.max_select ? g.min_select : g.min_select + '–' + g.max_select) : 'optional' + (g.max_select > 1 ? ', up to ' + g.max_select : '')}</span></legend>
        <div class="tpn-dlg-chips">${g.options.filter(o => o.is_available).map(o => `<label class="tpn-chip"><input type="${g.max_select === 1 ? 'radio' : 'checkbox'}" name="pos-g-${E(g.id)}" value="${E(o.id)}"> ${E(o.name)}${Number(o.price_delta) ? ' +' + peso(o.price_delta) : ''}</label>`).join('')}</div></fieldset>`).join('')}
      <div class="form-row"><div><label class="form-label" for="pos-qty">Quantity</label><input class="form-input" id="pos-qty" type="number" min="1" max="50" value="1" inputmode="numeric"></div>
        <div><label class="form-label" for="pos-note">Note for the kitchen</label><input class="form-input" id="pos-note" placeholder="e.g. less spicy"></div></div>
      <div class="form-error" id="pos-err" role="alert"></div></div>
      <div class="modal-actions"><button class="btn-back" onclick="closeModal()">Cancel</button><button class="btn-next" onclick="posPickSave('${JA(id)}')">Add to order</button></div>`);
  };
  window.posPickSave = function (id) {
    const it = st.items.find(x => x.id === id), box = document.getElementById('posOpt'), err = document.getElementById('pos-err');
    const size = (box.querySelector('[name=pos-size]:checked') || {}).value || null;
    const picked = [];
    for (const fs of box.querySelectorAll('[data-group]')) {
      const sel = [...fs.querySelectorAll('input:checked')].map(i => i.value);
      if (sel.length < +fs.dataset.min || sel.length > +fs.dataset.max) { err.textContent = 'Please choose for “' + fs.querySelector('legend').firstChild.textContent.trim() + '”.'; return; }
      picked.push(...sel);
    }
    const qty = Math.max(1, Math.min(50, +document.getElementById('pos-qty').value || 1));
    addLine(it, size, picked, qty, document.getElementById('pos-note').value.trim());
    closeModal();
  };
  function linePrice(it, size, modIds) {
    const base = size && it.pax_options ? Number(it.pax_options[size]) : Number(it.price);
    const delta = modIds.reduce((a, id) => { const o = st.mods.groups.flatMap(g => g.options).find(x => x.id === id); return a + (o ? Number(o.price_delta) : 0); }, 0);
    return base + delta;   // display only; the server prices the order
  }
  function addLine(it, size, mods, qty, note) {
    const key = [it.id, size, mods.slice().sort().join(','), note].join('|');
    const ex = st.ticket.find(l => l.key === key);
    if (ex) ex.qty = Math.min(50, ex.qty + qty);
    else st.ticket.push({ key, id: it.id, name: it.name, size, mods, modNames: mods.map(id => (st.mods.groups.flatMap(g => g.options).find(o => o.id === id) || {}).name).filter(Boolean), qty, note, price: linePrice(it, size, mods) });
    save(); drawTicket();
    const live = document.getElementById('posLive'); if (live) live.textContent = 'Added ' + qty + ' ' + it.name;
  }

  /* ── Ticket ──────────────────────────────────────────────── */
  function deliveryFee() {
    const zone = st.type === 'delivery' ? st.zones.find(z => z.id === st.zone) : null;
    return zone ? Number(zone.fee) || 0 : 0;
  }
  function drawTicket() {
    const el = document.getElementById('posTicket'); if (!el) return;
    const fee = deliveryFee();
    const total = st.ticket.reduce((a, l) => a + l.price * l.qty, 0) + fee;
    // The customer screen follows the ticket as it is rung up.
    if (window.TPN_CDS) TPN_CDS.order({ lines: TPN_CDS.lines(st.ticket), fee, total, type: st.type });
    el.innerHTML = `
      ${st.held.length ? `<div class="pos-held" role="list" aria-label="Orders on hold">${st.held.map(h => `<span class="pos-held-chip" role="listitem">
        <button type="button" class="pos-held-open" onclick="posResume('${JA(h.id)}')"><span>Held</span>&nbsp;·&nbsp;<span translate="no">${E(heldName(h))}</span>&nbsp;·&nbsp;${heldCount(h)}&nbsp;<span>${heldCount(h) === 1 ? 'item' : 'items'}</span></button>
        <button type="button" class="pos-held-x" onclick="posDropHeld('${JA(h.id)}')" aria-label="Discard">×</button></span>`).join('')}</div>` : ''}
      <div class="pos-ticket-head"><h2>Order</h2>${st.ticket.length ? `<div class="pos-ticket-acts">${st.type !== 'dine_in' ? '<button type="button" class="btn-ghost pos-hold" onclick="posHold()">Hold</button>' : ''}<button class="link-btn" onclick="posClear()">Clear</button></div>` : ''}</div>
      <div class="sr-only" aria-live="polite" id="posLive"></div>
      ${st.ticket.length ? `<ul class="pos-lines">${st.ticket.map((l, i) => `
        <li><div class="pos-line-main"><strong>${E(l.name)}</strong>${l.size ? ` <span class="form-hint">${E(l.size)} pax</span>` : ''}
            ${l.modNames.length ? `<div class="form-hint">${E(l.modNames.join(', '))}</div>` : ''}${l.note ? `<div class="form-hint">📝 ${E(l.note)}</div>` : ''}</div>
          <div class="pos-qty" role="group" aria-label="Quantity of ${E(l.name)}">
            <button class="qty-btn" onclick="posQty(${i},-1)" aria-label="One less">−</button><span>${l.qty}</span><button class="qty-btn" onclick="posQty(${i},1)" aria-label="One more">+</button></div>
          <div class="pos-line-amt">${peso(l.price * l.qty)}</div></li>`).join('')}</ul>`
        : '<p class="tpn-muted" style="padding:16px 0">Tap dishes on the left to start an order.</p>'}
      <div class="pos-type" role="radiogroup" aria-label="Order type">
        ${[['pickup', '🛍 Take-out'], ['dine_in', '🍽 Dine-in'], ['delivery', '🛵 Delivery']].map(([v, l]) => `<button type="button" role="radio" aria-checked="${st.type === v}" class="${st.type === v ? 'on' : ''}" onclick="posType('${v}')">${l}</button>`).join('')}
      </div>
      ${st.type === 'dine_in' ? `<label class="form-label" for="posTable">Table</label><select id="posTable" class="form-input" onchange="posSet('table',this.value)"><option value="">— choose —</option>${st.tables.map(t => `<option value="${E(t.id)}" ${st.table === t.id ? 'selected' : ''}>Table ${E(t.table_number)}</option>`).join('')}</select>` : ''}
      <div class="form-row"><div><label class="form-label" for="posName">Customer</label><input id="posName" class="form-input" value="${E(st.name)}" oninput="posSet('name',this.value)" placeholder="Name (optional)"></div>
        <div><label class="form-label" for="posPhone">Phone</label><input id="posPhone" class="form-input" type="tel" value="${E(st.phone)}" oninput="posSet('phone',this.value)" placeholder="For stamps / pickup"></div></div>
      ${st.type === 'delivery' ? `<label class="form-label" for="posAddr">Delivery address *</label><textarea id="posAddr" class="form-input" rows="2" oninput="posSet('address',this.value)">${E(st.address)}</textarea>` : ''}
      ${st.type === 'delivery' && st.zones.length ? `<label class="form-label" for="posZone">Delivery area *</label><select id="posZone" class="form-input" onchange="posSet('zone',this.value);posRedraw()"><option value="">— choose —</option>${st.zones.map(z => `<option value="${E(z.id)}" ${st.zone === z.id ? 'selected' : ''}>${E(z.name)} · ₱${Number(z.fee).toFixed(0)}</option>`).join('')}</select>` : ''}
      ${fee ? `<div class="pos-total" style="font-size:14px"><span>Delivery fee</span><span>${peso(fee)}</span></div>` : ''}
      <div class="pos-total"><span>Total</span><strong>${peso(total)}</strong></div>
      <p class="form-hint" style="margin:0 0 8px">Final price is checked by the server when you send.</p>
      <button class="btn-next pos-send" ${st.ticket.length ? '' : 'disabled'} onclick="posSend()">${st.type === 'dine_in' ? 'Send to kitchen' : 'Send to kitchen & take payment'}</button>
      ${st.type === 'dine_in' ? '<p class="form-hint" style="margin:6px 0 0">Dine-in is paid when the table closes (Floor → Close table).</p>' : ''}`;
  }
  window.posQty = (i, d) => { const l = st.ticket[i]; l.qty += d; if (l.qty <= 0) st.ticket.splice(i, 1); save(); drawTicket(); };
  window.posClear = async () => { if (await tpnConfirm('Clear this order? Nothing has been sent yet.', { confirmText: 'Clear' })) { st.ticket = []; save(); drawTicket(); } };
  window.posType = (t) => { st.type = t; drawTicket(); };

  /* ── Hold ────────────────────────────────────────────────── */
  // A take-out or delivery ticket parked while the guest decides or goes to
  // get cash. Kept on this device only: nothing reaches the kitchen or the
  // database until it is opened again and sent.
  const HELD_FIELDS = ['type', 'table', 'name', 'phone', 'address', 'zone', 'notes'];
  const heldName = (h) => h.name || (h.type === 'delivery' ? 'Delivery' : h.type === 'dine_in' ? 'Dine-in' : 'Take-out');
  const heldCount = (h) => h.lines.reduce((a, l) => a + l.qty, 0);
  function park() {
    const h = { id: Date.now().toString(36) + Math.random().toString(36).slice(2, 6), at: Date.now(), lines: st.ticket };
    HELD_FIELDS.forEach(k => { h[k] = st[k]; });
    st.held.push(h); saveKey(HELD_KEY, st.held);
    st.ticket = []; st.key = null; st.type = 'pickup'; st.name = st.phone = st.address = st.table = st.zone = st.notes = '';
    save();
    return h;
  }
  window.posHold = function () {
    if (!st.ticket.length) return;
    const h = park(); drawTicket();
    toast('On hold: ' + heldName(h));
  };
  window.posResume = async function (id) {
    const h = st.held.find(x => x.id === id); if (!h) return;
    if (st.ticket.length && !await tpnConfirm('The order on screen goes on hold, so nothing is lost.', { title: 'Open this held order?', confirmText: 'Hold this one and open' })) return;
    if (st.ticket.length) park();
    st.held = st.held.filter(x => x.id !== id); saveKey(HELD_KEY, st.held);
    st.ticket = h.lines; st.key = null;
    HELD_FIELDS.forEach(k => { st[k] = h[k] || (k === 'type' ? 'pickup' : ''); });
    save(); drawTicket();
  };
  window.posDropHeld = async function (id) {
    const h = st.held.find(x => x.id === id); if (!h) return;
    if (!await tpnConfirm('It was never sent to the kitchen.', { title: 'Discard this held order?', confirmText: 'Discard', danger: true })) return;
    st.held = st.held.filter(x => x.id !== id); saveKey(HELD_KEY, st.held); drawTicket();
  };
  window.posSet = (k, v) => { st[k] = v; };
  window.posRedraw = () => drawTicket();
  window.posSend = async function () {
    if (!st.ticket.length) return;
    if (st.type === 'dine_in' && !st.table) { toast('Choose the table.'); return; }
    if (st.type === 'delivery' && !st.address.trim()) { toast('Enter the delivery address.'); return; }
    if (st.type === 'delivery' && st.zones.length && !st.zone) { toast('Choose the delivery area.'); return; }
    const order = {
      branchId: st.branch.id, orderType: st.type, tableId: st.type === 'dine_in' ? st.table : null,
      customerName: st.name || null, customerPhone: st.phone || null, deliveryAddress: st.type === 'delivery' ? st.address : null, deliveryZoneId: st.type === 'delivery' ? st.zone || null : null,
      source: 'pos', joinTableBill: true,
      items: st.ticket.map(l => ({ menu_item_id: l.id, name: l.name, quantity: l.qty, pax_size: l.size, notes: l.note || null, modifiers: l.mods }))
    };
    // One key per order (sql/41): a send whose answer was lost, then sent
    // again from the offline outbox, returns the first order.
    st.key = TPN.orderKey(st.key, JSON.stringify(order));
    const off = OFF(), queue = () => off.queueOrder({ clientKey: st.key.key, order, lines: st.ticket, type: st.type,
      estTotal: st.ticket.reduce((a, l) => a + l.price * l.qty, 0) + deliveryFee() });
    let o = null, q = null;
    try {
      if (off && off.isOffline()) q = await queue();
      else o = await (off ? off.timed(TPN.createOrder(Object.assign({ clientKey: st.key.key }, order)), 15000) : TPN.createOrder(Object.assign({ clientKey: st.key.key }, order)));
    } catch (e) {
      if (!off || !off.isNetError(e)) { toast(e.message); return; }
      off.markOffline();
      try { q = await queue(); } catch (e2) { toast('Could not save the order on this device: ' + e2.message); return; }
    }
    const printed = st.ticket.slice(), type = st.type, where = ticketWhere();
    // Keep the lines on the customer screen while the guest pays.
    if (window.TPN_CDS && type !== 'dine_in') TPN_CDS.remember(o ? o.id : q.id, { lines: TPN_CDS.lines(printed), fee: deliveryFee(), type });
    st.ticket = []; st.key = null; st.name = st.phone = st.address = st.table = st.zone = ''; save(); drawTicket();
    if (q) {
      // No server: the kitchen works from paper, so the ticket always prints.
      toast('No internet. Saved as ' + q.localNo + '; it syncs when the connection is back.');
      printKitchenTicket(q.localNo, printed, type, true, where);
      if (type !== 'dine_in') off.openPayment(q.id);
      return;
    }
    toast('Sent to the kitchen: ' + o.order_number);
    printKitchenTicket(o.order_number, printed, type, false, where);
    // Take-out and delivery pay now; a dine-in table pays when it closes.
    if (type !== 'dine_in' && window.openPaymentPanel) openPaymentPanel(o.id);
    else if (window.onPosSent) window.onPosSent(o, type);
  };
  ['posSend'].forEach(n => window.guardAsync && guardAsync(n));
  window.printKitchenAtCounter = printAtCounter;

  // Table number or the guest's name, so a paper ticket finds its owner.
  function ticketWhere() {
    if (st.type === 'dine_in') { const t = st.tables.find(x => x.id === st.table); return t ? 'Table ' + t.table_number : ''; }
    return st.name || '';
  }
  // Kitchen ticket for a printer by the pass (optional; the KDS already has
  // it). Offline it always prints: then the paper is all the kitchen has.
  // Where it prints is the printer menu's "Kitchen tickets" setting
  // (modules/kprint.js): the kitchen printer (the counter if that fails),
  // the counter printer, or none when the kitchen works from its screen.
  function printKitchenTicket(num, lines, type, always, where) {
    const t = { number: num, lines, type, where };
    if (window.TPN_KPRINT && TPN_KPRINT.route(t, always, () => printAtCounter(num, lines, type, where))) return;
    if (!always && !window.TPN_KPRINT && (!window.getPref || getPref('posPrintTicket') !== 'on')) return;
    printAtCounter(num, lines, type, where);
  }
  function printAtCounter(num, lines, type, where) {
    // iMin counter: straight to the built-in printer, no print window.
    if (window.TPN_PRINT && TPN_PRINT.kitchen(num, lines, type, where)) return;
    if (window.TPN_SLIP) {   // the same picture, through the print window
      TPN_SLIP.ready().then(() => TPN_SLIP.printWindow(TPN_SLIP.kitchen({ number: num, lines, type, where, at: Date.now() }), num))
        .catch(e => console.warn('ticket picture', e));
      return;
    }
    // A print window, or a hidden frame where pop-ups are blocked.
    let w = window.open('', '_blank', 'width=360,height=520'), frame = null;
    if (!w) {
      frame = document.createElement('iframe');
      frame.setAttribute('aria-hidden', 'true'); frame.style.cssText = 'position:fixed;width:0;height:0;border:0;right:0;bottom:0';
      document.body.appendChild(frame); w = frame.contentWindow;
      setTimeout(() => frame.remove(), 60000);
    }
    w.document.write(`<!doctype html><meta charset="utf-8"><title>${E(num)}</title><style>@page{size:80mm auto;margin:3mm}body{font:15px/1.3 ui-monospace,Consolas,monospace;width:74mm}h1{font-size:20px;margin:0}li{margin:4px 0}</style>
      <h1>${E(num)}</h1>${where ? `<h1>${E(where)}</h1>` : ''}<div>${E({ pickup: 'TAKE-OUT', dine_in: 'DINE-IN', delivery: 'DELIVERY' }[type] || type)} · ${E(new Date().toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' }))}</div><hr>
      <ul style="padding-left:16px">${lines.map(l => `<li><b>${l.qty}× ${E(l.name)}</b>${l.size ? ' (' + E(l.size) + ')' : ''}${(l.modNames || []).length ? '<br>&nbsp;&nbsp;' + E(l.modNames.join(', ')) : ''}${l.note ? '<br>&nbsp;&nbsp;** ' + E(l.note) : ''}</li>`).join('')}</ul>
      ${frame ? '' : '<script>window.onload=()=>{print();setTimeout(()=>close(),400)}<\/script>'}`);
    w.document.close();
    if (frame) { w.focus(); w.print(); }
  }

  // Keyboard: "/" jumps to search while the POS is open.
  document.addEventListener('keydown', (e) => {
    if (e.key === '/' && document.getElementById('posSearch') && !/input|textarea|select/i.test(document.activeElement.tagName)) { e.preventDefault(); document.getElementById('posSearch').focus(); }
  });

  /* ── 86 panel (kitchen queue) ────────────────────────────── */
  // Kitchen crew mark a dish sold out the moment they run out; the website,
  // QR menu and POS stop offering it straight away.
  window.open86Panel = async function () {
    let items;
    try { const r = await sb.from('menu_items').select('id,name,emoji,is_available').order('display_order'); if (r.error) throw r.error; items = r.data; }
    catch (e) { toast('Could not load the menu: ' + e.message); return; }
    const draw = () => `<div class="modal-title">Sold out today?</div>
      <div class="modal-content"><p class="pref-row-hint">Tap a dish to switch it. Customers stop seeing it immediately.</p>
      <ul class="pay-list">${items.map(i => `<li class="pay-row" style="grid-template-columns:1fr auto"><div>${E(i.emoji || '🍽️')} ${E(i.name)}</div>
        <button class="table-btn" aria-pressed="${!i.is_available}" onclick="toggle86('${JA(i.id)}')">${i.is_available ? 'Available' : '🚫 Sold out'}</button></li>`).join('')}</ul></div>
      <div class="modal-actions"><button class="btn-next" onclick="closeModal()">Done</button></div>`;
    showModal(draw());
    window.toggle86 = async (id) => {
      const it = items.find(x => x.id === id);
      try { await TPN.setItemAvailable(id, !it.is_available, it.is_available ? 'ran out' : 'back in stock'); it.is_available = !it.is_available; showModal(draw()); }
      catch (e) { toast(/permission/.test(e.message) ? 'Your account cannot change this.' : e.message); }
    };
  };

  // The Counter lives on the floor screen (tpn-dine-in-floor → Counter tab),
  // next to the tables it rings up for. No separate portal tab; the portal
  // keeps this file only for the 86 panel on the kitchen board.
  // Most ordered row, Hold chips and the Hold button (tiles reuse .pos-tile).
  if (!document.getElementById('pos-style')) {
    const css = document.createElement('style'); css.id = 'pos-style';
    css.textContent = `
      .pos-top-h { font-family: 'Fraunces', 'Playfair Display', serif; font-size: 18px; color: var(--ink); margin: 2px 0 8px; }
      .pos-top-grid { grid-template-columns: repeat(6, 168px); overflow-x: auto; overscroll-behavior-x: contain;
        scroll-snap-type: x proximity; padding: 2px 2px 6px; margin-bottom: 12px; }
      .pos-top-grid .pos-tile { scroll-snap-align: start; }
      .pos-menu { min-width: 0; }   /* the sideways row must not widen the panel on phones */
      @media (max-width: 700px) { .pos-top-grid { grid-template-columns: none; grid-auto-flow: column; grid-auto-columns: 148px; } }
      .pos-held { display: flex; flex-wrap: wrap; gap: 8px; margin: 0 0 12px; }
      .pos-held-chip { display: inline-flex; align-items: stretch; border: 1.5px solid var(--brick, #A3321A); border-radius: 12px; overflow: hidden; background: var(--f-bg, #FFFDF8); }
      .pos-held-chip button { all: unset; box-sizing: border-box; cursor: pointer; min-height: 44px; display: inline-flex; align-items: center; white-space: nowrap; font-size: 13.5px; font-weight: 600; color: var(--ink, #2E1A10); }
      .pos-held-open { padding: 0 12px; }
      .pos-held-x { padding: 0 14px; font-size: 20px; border-left: 1px solid var(--line-soft, #E8DCC8); color: var(--ink-muted, #6E5240) !important; }
      .pos-held-chip button:focus-visible { box-shadow: var(--focus-ring); }
      .pos-held-chip button:active { background: rgba(163, 50, 26, .08); }
      .pos-ticket-head { align-items: center; }
      .pos-ticket-acts { display: flex; align-items: center; gap: 14px; }
      .pos-hold { margin: 0 !important; min-height: 44px; padding: 0 22px; white-space: nowrap; }
      .pay-quick .tpn-chip { min-height: 44px; padding: 0 16px; font-size: 15px; white-space: nowrap; }`;
    document.head.appendChild(css);
  }

  TPN_MOD.register({ id: 'pos', side: 'both', hidden: true, perm: 'pos.use', icon: '🧾', label: 'Counter (POS)', labelTl: 'Counter (POS)', render });
})();
