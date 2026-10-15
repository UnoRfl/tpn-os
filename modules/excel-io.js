/* ═══════════════════════════════════════════════════════════════
   Excel / CSV on every portal list.
   Adds an Export ▾ (Excel or CSV) — and Import where staff keep the list
   by hand — to each page's header, using the same TPN.* data functions the
   page itself uses, so permissions are exactly the page's permissions.

   Imports always preview first, never delete, and ask before updating
   rows that already exist (matched by name).
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const today = () => (TPN.today ? TPN.today() : new Date().toISOString().slice(0, 10));
  const daysAgo = (n) => { const d = new Date(today() + 'T00:00:00+08:00'); d.setDate(d.getDate() - n); return d.toISOString().slice(0, 10); };
  const human = (k) => k.replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
  const guessType = (k, v) => /amount|price|cost|total|rate|pay|spend|gross|net|allowance|deduction|cash|sales/i.test(k) && !isNaN(+v) ? 'money'
    : /_at$|date|_on$/i.test(k) ? (String(v || '').length > 10 ? 'datetime' : 'date')
    : typeof v === 'number' ? 'number' : 'text';
  function autoCols(rows, skip = []) {
    const keys = [...new Set(rows.flatMap(r => Object.keys(r)))].filter(k => !skip.includes(k) && !/(^|_)id$/.test(k) || k === 'order_number');
    return keys.map(k => ({ key: k, label: human(k), type: guessType(k, rows.find(r => r[k] != null)?.[k]),
      get: r => (r[k] && typeof r[k] === 'object' && !Array.isArray(r[k])) ? (r[k].name || r[k].full_name || JSON.stringify(r[k])) : Array.isArray(r[k]) ? r[k].join(', ') : r[k] }));
  }
  async function askRange(title, defDays = 30) {
    const v = await tpnAsk(title + ': from which date?', { input: { type: 'date', value: daysAgo(defDays) }, chips: [], confirmText: 'Next' });
    if (v === null) return null;
    const to = await tpnAsk('…up to which date?', { input: { type: 'date', value: today() }, confirmText: 'Export' });
    if (to === null) return null;
    return { from: v, to };
  }
  const manila = (d, end) => new Date(d + 'T00:00:00+08:00').getTime() + (end ? 864e5 : 0);
  const iso = (ms) => new Date(ms).toISOString();

  /* ── Exporters, by route ─────────────────────────────────── */
  const X = {
    inquiries: { label: 'Inquiries', run: (fmt) => tpnExport(portalState.inquiries || [], [
      { label: 'Reference', key: 'id' }, { label: 'Type', key: 'type' }, { label: 'Name', key: 'name' }, { label: 'Phone', key: 'phone' },
      { label: 'Email', key: 'email' }, { label: 'Company', key: 'company' }, { label: 'Event date', key: 'date', type: 'date' },
      { label: 'Pax', key: 'pax', type: 'number' }, { label: 'Status', key: 'status' }, { label: 'Message', key: 'notes', width: 60 }
    ], { format: fmt, filename: 'tpn-inquiries', sheet: 'Inquiries', title: 'Tyo Paeng Nyo — inquiries' }) },

    orders: { label: 'Orders', run: async (fmt) => {
      const r = await askRange('Orders'); if (!r) return;
      const { data, error } = await sb.from('orders').select('order_number, placed_at, order_type, source, status, payment_status, payment_method, customer_name, customer_phone, subtotal, discount_amount, service_charge, total, order_items(name_snapshot, quantity, pax_size, total_price, voided_at)')
        .gte('placed_at', iso(manila(r.from))).lt('placed_at', iso(manila(r.to, true))).order('placed_at');
      if (error) throw error;
      await tpnExport(data, [
        { label: 'Order', key: 'order_number' }, { label: 'Placed', key: 'placed_at', type: 'datetime' }, { label: 'Type', key: 'order_type' },
        { label: 'Source', key: 'source' }, { label: 'Status', key: 'status' }, { label: 'Payment', key: 'payment_status' }, { label: 'Method', key: 'payment_method' },
        { label: 'Customer', key: 'customer_name' }, { label: 'Phone', key: 'customer_phone' },
        { label: 'Items', get: o => (o.order_items || []).filter(i => !i.voided_at).map(i => i.quantity + '× ' + i.name_snapshot + (i.pax_size ? ' (' + i.pax_size + ')' : '')).join('; '), width: 60 },
        { label: 'Subtotal', key: 'subtotal', type: 'money' }, { label: 'Discounts', key: 'discount_amount', type: 'money' },
        { label: 'Service charge', key: 'service_charge', type: 'money' }, { label: 'Total', key: 'total', type: 'money' }
      ], { format: fmt, filename: `tpn-orders-${r.from}-to-${r.to}`, sheet: 'Orders', title: `Tyo Paeng Nyo — orders ${r.from} to ${r.to}` });
    } },

    'menu-manager': { label: 'Menu', run: async (fmt) => {
      const [c, i] = await Promise.all([sb.from('menu_categories').select('id,name'), sb.from('menu_items').select('*').order('display_order')]);
      if (c.error) throw c.error; if (i.error) throw i.error;
      const cat = Object.fromEntries(c.data.map(x => [x.id, x.name]));
      const sizes = [...new Set(i.data.flatMap(x => x.pax_options ? Object.keys(x.pax_options) : []))];
      await tpnExport(i.data, [
        { label: 'Name', key: 'name', width: 30 }, { label: 'Tagalog name', key: 'name_tagalog' }, { label: 'Category', get: x => cat[x.category_id] || '' },
        { label: 'Price', key: 'price', type: 'money' },
        ...sizes.map(s => ({ label: 'Price ' + s, type: 'money', get: x => x.pax_options ? x.pax_options[s] : null })),
        { label: 'Available', get: x => x.is_available === false ? 'no' : 'yes' }, { label: 'Add-on', get: x => x.is_addon ? 'yes' : 'no' },
        { label: 'Prep minutes', key: 'prep_minutes', type: 'number' }, { label: 'Description', key: 'description', width: 50 }
      ], { format: fmt, filename: 'tpn-menu', sheet: 'Menu', title: 'Tyo Paeng Nyo — menu' });
    },
      import: () => importMenu() },

    'staff-board': { label: 'Staff', run: async (fmt) => staffExport(fmt) },
    accounts: { label: 'Accounts', run: async (fmt) => staffExport(fmt) },

    schedules: { label: 'Schedule (this week)', run: async (fmt) => {
      const wk = await tpnAsk('Which week? (pick its Monday)', { input: { type: 'date', value: TPN.weekStartISO ? TPN.weekStartISO() : today() }, confirmText: 'Export' });
      if (wk === null) return;
      const rows = await TPN.listSchedulesForWeek(wk);
      const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
      const cell = (v) => v == null ? '' : typeof v === 'string' ? v : (v.off ? 'OFF' : [v.start, v.end].filter(Boolean).join('–') || JSON.stringify(v));
      await tpnExport(rows, [{ label: 'Staff', get: r => r.staff?.full_name }, { label: 'Role', get: r => r.staff?.role },
        ...days.map((d, i) => ({ label: d.toUpperCase(), get: r => cell((r.shifts || {})[d] ?? (Array.isArray(r.shifts) ? r.shifts[i] : null)) })),
        { label: 'Notes', key: 'notes' }], { format: fmt, filename: 'tpn-schedule-' + wk, sheet: 'Schedule', title: 'Tyo Paeng Nyo — schedule, week of ' + wk });
    } },

    'attendance-admin': { label: 'Attendance', run: async (fmt) => {
      const r = await askRange('Attendance', 15); if (!r) return;
      const { data, error } = await sb.from('attendance').select('*, staff:staff_id(full_name, role)')
        .gte('work_date', r.from).lte('work_date', r.to).order('clock_in_at');
      if (error) throw error;
      await tpnExport(data, [
        { label: 'Date', key: 'work_date', type: 'date' }, { label: 'Name', get: a => a.staff?.full_name }, { label: 'Role', get: a => a.staff?.role },
        { label: 'Clock in', key: 'clock_in_at', type: 'datetime' }, { label: 'Clock out', key: 'clock_out_at', type: 'datetime' },
        { label: 'Hours', type: 'number', get: a => a.clock_out_at ? Math.round((new Date(a.clock_out_at) - new Date(a.clock_in_at)) / 36e5 * 100) / 100 : null },
        { label: 'Verified', key: 'verify_status' }, { label: 'Corrected', get: a => a.corrected_at ? 'yes' : '' }, { label: 'Notes', key: 'notes' }
      ], { format: fmt, filename: `tpn-attendance-${r.from}-to-${r.to}`, sheet: 'Attendance', title: `Tyo Paeng Nyo — attendance ${r.from} to ${r.to}` });
    } },

    tasks: { label: 'Tasks', run: async (fmt) => { const rows = await TPN.getTasks(true); await tpnExport(rows, autoCols(rows), { format: fmt, filename: 'tpn-tasks', sheet: 'Tasks' }); } },

    inventory: { label: 'Inventory', run: async (fmt) => {
      const rows = await TPN.getInventory(); await tpnExport(rows, autoCols(rows), { format: fmt, filename: 'tpn-inventory', sheet: 'Inventory', title: 'Tyo Paeng Nyo — inventory ' + today() });
    }, extra: [
      { label: 'Suppliers', run: async (fmt) => { const s = await TPN.getSuppliers(); await tpnExport(s, autoCols(s, ['branch_id', 'created_by']), { format: fmt, filename: 'tpn-suppliers', sheet: 'Suppliers' }); } },
      { label: 'Stock movements', run: async (fmt) => { const m = await TPN.getStockMovements(null, 2000); await tpnExport(m, [
          { label: 'When', key: 'occurred_at', type: 'datetime' }, { label: 'Ingredient', get: x => x.ingredients?.name }, { label: 'Type', key: 'movement_type' },
          { label: 'Quantity', key: 'quantity', type: 'number' }, { label: 'Unit', get: x => x.ingredients?.unit }, { label: 'Unit cost', key: 'unit_cost', type: 'money' },
          { label: 'Total cost', key: 'total_cost', type: 'money' }, { label: 'Supplier', get: x => x.suppliers?.name }, { label: 'By', get: x => x.staff?.full_name },
          { label: 'Reference', key: 'reference' }, { label: 'Notes', key: 'notes' }], { format: fmt, filename: 'tpn-stock-movements', sheet: 'Movements' }); } }
    ], import: () => importInventory(), importExtra: [{ label: 'Import suppliers', run: () => importSuppliers() }] },

    finance: { label: 'Expenses', run: async (fmt) => {
      const r = await askRange('Expenses', 31); if (!r) return;
      const rows = await TPN.getExpenses(r.from, r.to);
      await tpnExport(rows, [{ label: 'Date', key: 'incurred_on', type: 'date' }, { label: 'Category', key: 'category' }, { label: 'What', key: 'label', width: 30 },
        { label: 'Amount', key: 'amount', type: 'money' }, { label: 'Supplier', get: x => x.suppliers?.name }, { label: 'Reference', key: 'reference' },
        { label: 'Recorded by', get: x => x.staff?.full_name }, { label: 'Notes', key: 'notes' }],
        { format: fmt, filename: `tpn-expenses-${r.from}-to-${r.to}`, sheet: 'Expenses', title: `Tyo Paeng Nyo — expenses ${r.from} to ${r.to}` });
    }, import: () => importExpenses() },

    payroll: { label: 'Payroll runs', run: async (fmt) => {
      const runs = await TPN.getPayrollRuns();
      const wb = []; for (const run of runs.slice(0, 12)) for (const it of await TPN.getPayrollItems(run.id)) wb.push(Object.assign({ period: run.period_start + ' – ' + run.period_end, run_status: run.status }, it));
      await tpnExport(wb, [{ label: 'Period', key: 'period' }, { label: 'Run status', key: 'run_status' }, { label: 'Name', key: 'staff_name' },
        { label: 'Pay type', key: 'pay_type' }, { label: 'Rate', key: 'rate', type: 'money' }, { label: 'Days', key: 'days_worked', type: 'number' },
        { label: 'Hours', key: 'hours_worked', type: 'number' }, { label: 'Gross', key: 'gross', type: 'money' }, { label: 'Allowance', key: 'allowance', type: 'money' },
        { label: 'Deductions', key: 'deductions', type: 'money' }, { label: 'Net pay', key: 'net', type: 'money' }, { label: 'Note', key: 'note' }],
        { format: fmt, filename: 'tpn-payroll', sheet: 'Payroll', title: 'Tyo Paeng Nyo — payroll (last 12 runs)' });
    }, import: () => can('payroll.edit') ? importRates() : toast('Only CEO-level accounts can change pay rates.'), importLabel: 'Import pay rates' },

    guests: { label: 'Guests', run: async (fmt) => { const g = await TPN.listGuests(null, false, 2000); await tpnExport(g, autoCols(g), { format: fmt, filename: 'tpn-guests', sheet: 'Guests' }); } },

    audit: { label: 'Audit log (one day)', run: async (fmt) => {
      const d = await tpnAsk('Which day?', { input: { type: 'date', value: today() }, confirmText: 'Export' }); if (d === null) return;
      const rows = await TPN.listAuditForDay(d, null, 5000);
      await tpnExport(rows, [{ label: 'When', key: 'created_at', type: 'datetime' }, { label: 'Who', get: r => r.actor_name || r.actor_id }, { label: 'Role', key: 'actor_role' },
        { label: 'Action', key: 'action' }, { label: 'What', key: 'entity_type' }, { label: 'Details', get: r => JSON.stringify(r.metadata || r.after_state || {}), width: 80 }],
        { format: fmt, filename: 'tpn-audit-' + d, sheet: 'Audit' });
    } }
  };
  X.history = X.orders;

  async function staffExport(fmt) {
    const s = await TPN.listStaff();
    await tpnExport(s, [{ label: 'Name', key: 'full_name' }, { label: 'Role', key: 'role' }, { label: 'Branch', get: x => x.branches?.name },
      { label: 'Status', key: 'employment_status' }, { label: 'Phone', key: 'phone' }, { label: 'Hired', key: 'hired_at', type: 'date' }],
      { format: fmt, filename: 'tpn-staff', sheet: 'Staff', title: 'Tyo Paeng Nyo — staff' });
  }

  /* ── Imports ─────────────────────────────────────────────── */
  async function confirmUpserts(kind, nNew, nUpd) {
    if (!nUpd) return true;
    return tpnConfirm(`${nNew} new ${kind} will be added and ${nUpd} existing ${kind} (same name) will be UPDATED. Continue?`, { title: 'Update existing rows?', confirmText: 'Add and update' });
  }
  function importMenu() {
    tpnImport({ title: 'Import menu items', templateName: 'tpn-menu-template', columns: [
      { key: 'name', label: 'Name', required: true }, { key: 'category', label: 'Category' }, { key: 'price', label: 'Price', type: 'money' },
      { key: 'p23', label: 'Price 2-3', type: 'money', aliases: ['price23'] }, { key: 'p46', label: 'Price 4-6', type: 'money', aliases: ['price46'] },
      { key: 'available', label: 'Available', type: 'bool' }, { key: 'description', label: 'Description' }, { key: 'prep', label: 'Prep minutes', type: 'number' }
    ], async onCommit(rows) {
      const [c, i] = await Promise.all([sb.from('menu_categories').select('id,name'), sb.from('menu_items').select('id,name')]);
      const catId = (n) => (c.data || []).find(x => x.name.toLowerCase() === String(n || '').toLowerCase())?.id || null;
      const ex = new Map((i.data || []).map(x => [x.name.toLowerCase(), x.id]));
      if (!await confirmUpserts('dishes', rows.filter(r => !ex.has(r.name.toLowerCase())).length, rows.filter(r => ex.has(r.name.toLowerCase())).length)) return { ok: 0 };
      const failed = []; let ok = 0;
      for (const r of rows) {
        const pax = (r.p23 != null || r.p46 != null) ? Object.fromEntries([['2-3', r.p23], ['4-6', r.p46]].filter(([, v]) => v != null)) : undefined;
        const row = { name: r.name, category_id: r.category ? catId(r.category) : undefined, price: r.price ?? (pax ? Object.values(pax)[0] : undefined),
          pax_options: pax, is_shareable: pax ? true : undefined, is_available: r.available == null ? undefined : r.available,
          description: r.description ?? undefined, prep_minutes: r.prep ?? undefined };
        Object.keys(row).forEach(k => row[k] === undefined && delete row[k]);
        const id = ex.get(r.name.toLowerCase());
        if (!id && row.price == null) { failed.push({ label: r.name, error: 'New dish needs a price' }); continue; }
        const q = id ? sb.from('menu_items').update(row).eq('id', id) : sb.from('menu_items').insert(row);
        const { error } = await q; if (error) failed.push({ label: r.name, error: error.message }); else ok++;
      }
      return { ok, failed };
    } });
  }
  function importInventory() {
    tpnImport({ title: 'Import ingredients and stock counts', templateName: 'tpn-inventory-template', columns: [
      { key: 'name', label: 'Ingredient', required: true, aliases: ['name'] }, { key: 'unit', label: 'Unit' }, { key: 'category', label: 'Category' },
      { key: 'reorder', label: 'Reorder level', type: 'number' }, { key: 'counted', label: 'Counted stock', type: 'number' }, { key: 'notes', label: 'Notes' }
    ], async onCommit(rows) {
      const inv = await TPN.getInventory();
      const byName = new Map(inv.map(x => [String(x.name).toLowerCase(), x]));
      if (!await confirmUpserts('ingredients', rows.filter(r => !byName.has(r.name.toLowerCase())).length, rows.filter(r => byName.has(r.name.toLowerCase())).length)) return { ok: 0 };
      const failed = []; let ok = 0;
      for (const r of rows) {
        try {
          let cur = byName.get(r.name.toLowerCase());
          const saved = await TPN.saveIngredient({ name: r.name, unit: r.unit || cur?.unit || 'kg', category: r.category ?? cur?.category, reorderLevel: r.reorder ?? cur?.reorder_level ?? 0, notes: r.notes ?? cur?.notes }, cur?.id || cur?.ingredient_id);
          // A count never overwrites the stock number: it records the
          // difference as a movement, so the history explains it.
          if (r.counted != null) {
            const have = Number(cur?.current_stock ?? 0), diff = Math.round((r.counted - have) * 1000) / 1000;
            if (diff) await TPN.recordStockMovement({ ingredientId: saved.id, type: diff > 0 ? 'adjust_up' : 'adjust_down', quantity: Math.abs(diff), notes: 'Stock count import ' + today() });
          }
          ok++;
        } catch (e) { failed.push({ label: r.name, error: e.message }); }
      }
      return { ok, failed };
    } });
  }
  function importSuppliers() {
    tpnImport({ title: 'Import suppliers', templateName: 'tpn-suppliers-template', columns: [
      { key: 'name', label: 'Supplier', required: true, aliases: ['name'] }, { key: 'contactPerson', label: 'Contact person' }, { key: 'phone', label: 'Phone' },
      { key: 'email', label: 'Email' }, { key: 'address', label: 'Address' }, { key: 'notes', label: 'Notes' }
    ], async onCommit(rows) {
      const ex = new Map((await TPN.getSuppliers()).map(s => [s.name.toLowerCase(), s.id]));
      if (!await confirmUpserts('suppliers', rows.filter(r => !ex.has(r.name.toLowerCase())).length, rows.filter(r => ex.has(r.name.toLowerCase())).length)) return { ok: 0 };
      const failed = []; let ok = 0;
      for (const r of rows) { try { await TPN.saveSupplier(r, ex.get(r.name.toLowerCase())); ok++; } catch (e) { failed.push({ label: r.name, error: e.message }); } }
      return { ok, failed };
    } });
  }
  function importExpenses() {
    const CATS = window.EXPENSE_CATS || ['rent', 'utilities', 'gas_fuel', 'supplies', 'transport', 'marketing', 'repairs', 'permits', 'equipment', 'other'];
    tpnImport({ title: 'Import expenses', templateName: 'tpn-expenses-template', columns: [
      { key: 'incurredOn', label: 'Date', type: 'date', required: true }, { key: 'label', label: 'What', required: true },
      { key: 'amount', label: 'Amount', type: 'money', required: true, check: v => v > 0 ? null : 'Amount must be more than 0' },
      { key: 'category', label: 'Category', check: v => !v || CATS.includes(v) ? null : 'Category must be one of: ' + CATS.join(', ') },
      { key: 'reference', label: 'Reference' }, { key: 'notes', label: 'Notes' }
    ], async onCommit(rows) {
      const failed = []; let ok = 0;
      for (const r of rows) { try { await TPN.saveExpense(r); ok++; } catch (e) { failed.push({ label: r.label, error: e.message }); } }
      return { ok, failed };
    } });
  }
  function importRates() {
    tpnImport({ title: 'Import pay rates', templateName: 'tpn-pay-rates-template', columns: [
      { key: 'name', label: 'Staff name', required: true }, { key: 'payType', label: 'Pay type', check: v => !v || ['monthly', 'daily', 'hourly'].includes(v) ? null : 'monthly, daily or hourly' },
      { key: 'rate', label: 'Rate', type: 'money', required: true }, { key: 'allowance', label: 'Allowance', type: 'money' },
      { key: 'effectiveFrom', label: 'Effective from', type: 'date' }, { key: 'notes', label: 'Notes' }
    ], async onCommit(rows) {
      const staff = await TPN.listStaff(); const failed = []; let ok = 0;
      if (!await tpnConfirm(`Set new pay rates for ${rows.length} people? Old rates are kept as history.`, { confirmText: 'Set rates' })) return { ok: 0 };
      for (const r of rows) {
        const s = staff.filter(x => x.full_name.toLowerCase() === r.name.toLowerCase());
        if (s.length !== 1) { failed.push({ label: r.name, error: s.length ? 'Two staff have this name — set it by hand' : 'No staff with this name' }); continue; }
        try { await TPN.setCompensation(Object.assign({ staffId: s[0].id }, r)); ok++; } catch (e) { failed.push({ label: r.name, error: e.message }); }
      }
      return { ok, failed };
    } });
  }

  /* ── Header toolbar ─────────────────────────────────────── */
  function toolbar(route) {
    const x = X[route]; if (!x) return null;
    const div = document.createElement('div');
    div.className = 'tpn-io';
    const items = [{ label: x.label, run: x.run }].concat(x.extra || []);
    const imports = (x.import ? [{ label: x.importLabel || 'Import from Excel / CSV', run: x.import }] : []).concat(x.importExtra || []);
    div.innerHTML = `<details class="tpn-menu"><summary class="btn-ghost tpn-menu-btn">⬇ Export</summary><div class="tpn-menu-list glass" role="menu">
        ${items.map((it, i) => `<button type="button" role="menuitem" data-x="${i}" data-f="xlsx">${E(it.label)} — Excel</button><button type="button" role="menuitem" data-x="${i}" data-f="csv">${E(it.label)} — CSV</button>`).join('')}
      </div></details>
      ${imports.length ? `<details class="tpn-menu"><summary class="btn-ghost tpn-menu-btn">⬆ Import</summary><div class="tpn-menu-list glass" role="menu">
        ${imports.map((it, i) => `<button type="button" role="menuitem" data-i="${i}">${E(it.label)}</button>`).join('')}</div></details>` : ''}`;
    div.addEventListener('click', async (e) => {
      const b = e.target.closest('button[role=menuitem]'); if (!b) return;
      b.closest('details').open = false;
      try {
        if (b.dataset.x != null) { toast('Preparing the file…'); await items[+b.dataset.x].run(b.dataset.f); }
        else await imports[+b.dataset.i].run();
      } catch (err) { toast('Could not export: ' + (err.message || err)); }
    });
    return div;
  }
  function inject(route, main) {
    if (!X[route] || !main) return;
    let tries = 0;
    const tryOnce = () => {
      const head = main.querySelector('.portal-header');
      if (head && !head.querySelector('.tpn-io')) { const tb = toolbar(route); if (tb) head.appendChild(tb); return; }
      if (++tries < 30) setTimeout(tryOnce, 100);
    };
    tryOnce();
  }
  ['renderRouteInto', 'renderStaffRouteInto'].forEach(fn => {
    const orig = window[fn]; if (typeof orig !== 'function') return;
    window[fn] = function (r, main) { const out = orig.apply(this, arguments); try { inject(r, main); } catch (e) {} return out; };
  });
  window.tpnExcelIO = { exporters: X };
})();
