/* ═══════════════════════════════════════════════════════════════
   Portal tab: Add-ons & choices (modifiers)
   Groups ("Egg style", "Extras", "Spice level") hold choices with a
   price change; a group is linked to the dishes it applies to. Rules and
   pricing live in sql/32 — this screen only edits the lists.
   Needs menu.edit.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const st = { groups: [], items: [], links: [] };

  async function load() {
    const [g, m, i, l] = await Promise.all([
      sb.from('modifier_groups').select('*').order('sort'),
      sb.from('modifiers').select('*').order('sort'),
      sb.from('menu_items').select('id,name,emoji').order('display_order'),
      sb.from('menu_item_modifier_groups').select('*')
    ]);
    for (const r of [g, m, i, l]) if (r.error) throw r.error;
    st.groups = g.data.map(x => Object.assign(x, { options: m.data.filter(o => o.group_id === x.id) }));
    st.items = i.data; st.links = l.data;
  }

  async function render(main) {
    main.innerHTML = `<div class="portal-header"><div><h1>Add-ons &amp; choices</h1>
        <div class="portal-header-sub">Things a guest picks with a dish: egg style, extra rice, spice level. Prices are added by the server, so the website, QR menu and counter always agree.</div></div>
        <div style="display:flex;gap:8px;flex-wrap:wrap">${tpnExportButton('modExport')}<button class="btn-ghost" onclick="modImport()">⬆ Import</button><button class="btn-next" style="margin:0" onclick="modEditGroup(null)">+ New group</button></div></div>
      <div id="modBody"><div class="panel tpn-muted" style="text-align:center;padding:24px">Loading…</div></div>`;
    try { await load(); } catch (e) { document.getElementById('modBody').innerHTML = loadErrorPanel('add-ons', e, "route('modifiers',{refresh:true})"); return; }
    draw();
  }
  function draw() {
    const body = document.getElementById('modBody'); if (!body) return;
    if (!st.groups.length) { body.innerHTML = `<div class="panel tpn-empty" style="text-align:center;padding:32px;color:var(--ink-muted)">No groups yet. Start with something like “Extras” (optional, up to 3) or “Egg style” (choose 1).</div>`; return; }
    body.innerHTML = st.groups.map(g => {
      const dishes = st.links.filter(l => l.group_id === g.id).map(l => st.items.find(i => i.id === l.menu_item_id)).filter(Boolean);
      return `<section class="panel" style="margin-bottom:14px" aria-label="${E(g.name)}">
        <div style="display:flex;justify-content:space-between;gap:10px;flex-wrap:wrap;align-items:baseline">
          <div><h2 style="font-family:'Playfair Display',serif;font-size:19px;color:var(--ink)">${E(g.name)} ${g.is_active ? '' : '<span class="tpn-pill warn">Off</span>'}</h2>
          <div class="pref-row-hint">${g.min_select ? 'Required: choose ' + (g.min_select === g.max_select ? g.min_select : g.min_select + '–' + g.max_select) : 'Optional' + (g.max_select > 1 ? ', up to ' + g.max_select : ', pick one')}</div></div>
          <div style="display:flex;gap:6px;flex-wrap:wrap"><button class="table-btn" onclick="modEditGroup('${JA(g.id)}')">Edit group</button>
            <button class="table-btn" onclick="modLink('${JA(g.id)}')">Dishes (${dishes.length})</button>
            <button class="table-btn" onclick="modEditOption('${JA(g.id)}',null)">+ Choice</button></div></div>
        <ul class="pay-list" style="margin-top:8px">${g.options.map(o => `<li class="pay-row" style="grid-template-columns:1fr auto auto">
          <div>${E(o.name)} ${o.is_available ? '' : '<span class="tpn-pill bad">Sold out</span>'}</div>
          <div class="pay-row-amt">${Number(o.price_delta) ? (o.price_delta > 0 ? '+' : '−') + peso(Math.abs(o.price_delta)) : 'free'}</div>
          <div class="pay-row-act"><button class="table-btn" onclick="modEditOption('${JA(g.id)}','${JA(o.id)}')">Edit</button></div></li>`).join('') || '<li class="tpn-muted">No choices yet.</li>'}</ul>
        ${dishes.length ? `<div class="pref-row-hint" style="margin-top:8px">On: ${dishes.map(d => E((d.emoji || '') + ' ' + d.name)).join(', ')}</div>` : '<div class="pref-row-hint" style="margin-top:8px">Not on any dish yet — use “Dishes”.</div>'}
      </section>`;
    }).join('');
  }

  async function saveRow(table, id, row) {
    const q = id ? sb.from(table).update(row).eq('id', id) : sb.from(table).insert(row);
    const { error } = await q; if (error) throw error;
  }
  window.modEditGroup = function (id) {
    const g = id ? st.groups.find(x => x.id === id) : { name: '', min_select: 0, max_select: 1, sort: 100, is_active: true };
    showModal(`<div class="modal-title">${id ? 'Edit' : 'New'} group</div><div class="modal-content">
      <label class="form-label" for="mg-name">Name *</label><input class="form-input" id="mg-name" value="${E(g.name)}" placeholder="e.g. Extras">
      <div class="form-row"><div><label class="form-label" for="mg-min">Guest must pick at least</label><input class="form-input" id="mg-min" type="number" min="0" value="${E(g.min_select)}"></div>
        <div><label class="form-label" for="mg-max">and at most</label><input class="form-input" id="mg-max" type="number" min="1" value="${E(g.max_select)}"></div></div>
      <label style="display:flex;gap:8px;align-items:center;margin-top:8px"><input type="checkbox" id="mg-on" ${g.is_active ? 'checked' : ''}> Turned on</label>
      <div class="form-error" id="mg-err" role="alert"></div></div>
      <div class="modal-actions">${id ? `<button class="btn-ghost" onclick="modDelete('modifier_groups','${JA(id)}')">Delete</button>` : ''}<button class="btn-back" onclick="closeModal()">Cancel</button>
      <button class="btn-next" onclick="modSaveGroup(${id ? `'${JA(id)}'` : 'null'})">Save</button></div>`);
  };
  window.modSaveGroup = async function (id) {
    const name = document.getElementById('mg-name').value.trim(), mn = +document.getElementById('mg-min').value, mx = +document.getElementById('mg-max').value;
    const err = document.getElementById('mg-err');
    if (!name) { err.textContent = 'Give it a name.'; return; }
    if (!(mx >= 1) || mn < 0 || mn > mx) { err.textContent = 'At least must be 0 or more and not more than “at most”.'; return; }
    try { await saveRow('modifier_groups', id, { name, min_select: mn, max_select: mx, is_active: document.getElementById('mg-on').checked }); closeModal(); await load(); draw(); }
    catch (e) { err.textContent = e.message; }
  };
  window.modEditOption = function (groupId, id) {
    const g = st.groups.find(x => x.id === groupId);
    const o = id ? g.options.find(x => x.id === id) : { name: '', price_delta: 0, is_available: true };
    showModal(`<div class="modal-title">${id ? 'Edit' : 'New'} choice in “${E(g.name)}”</div><div class="modal-content">
      <div class="form-row"><div><label class="form-label" for="mo-name">Name *</label><input class="form-input" id="mo-name" value="${E(o.name)}" placeholder="e.g. Extra rice"></div>
        <div><label class="form-label" for="mo-price">Adds (₱)</label><input class="form-input" id="mo-price" type="number" step="0.01" value="${E(o.price_delta)}" inputmode="decimal"></div></div>
      <label style="display:flex;gap:8px;align-items:center"><input type="checkbox" id="mo-on" ${o.is_available ? 'checked' : ''}> Available</label>
      <div class="form-error" id="mo-err" role="alert"></div></div>
      <div class="modal-actions">${id ? `<button class="btn-ghost" onclick="modDelete('modifiers','${JA(id)}')">Delete</button>` : ''}<button class="btn-back" onclick="closeModal()">Cancel</button>
      <button class="btn-next" onclick="modSaveOption('${JA(groupId)}',${id ? `'${JA(id)}'` : 'null'})">Save</button></div>`);
  };
  window.modSaveOption = async function (groupId, id) {
    const name = document.getElementById('mo-name').value.trim(), price = +document.getElementById('mo-price').value || 0;
    if (!name) { document.getElementById('mo-err').textContent = 'Give it a name.'; return; }
    try { await saveRow('modifiers', id, { group_id: groupId, name, price_delta: price, is_available: document.getElementById('mo-on').checked }); closeModal(); await load(); draw(); }
    catch (e) { document.getElementById('mo-err').textContent = e.message; }
  };
  window.modLink = function (groupId) {
    const on = new Set(st.links.filter(l => l.group_id === groupId).map(l => l.menu_item_id));
    showModal(`<div class="modal-title">Which dishes offer this?</div><div class="modal-content">
      <input class="form-input" type="search" placeholder="Filter dishes" oninput="[...document.querySelectorAll('[data-dish]')].forEach(l=>l.hidden=!l.dataset.dish.includes(this.value.toLowerCase()))" style="margin-bottom:8px">
      <div style="max-height:50vh;overflow:auto">${st.items.map(i => `<label data-dish="${E(i.name.toLowerCase())}" style="display:flex;gap:10px;align-items:center;padding:8px 2px;border-bottom:1px solid var(--line-soft)">
        <input type="checkbox" value="${E(i.id)}" ${on.has(i.id) ? 'checked' : ''} style="width:20px;height:20px"> ${E((i.emoji || '') + ' ' + i.name)}</label>`).join('')}</div></div>
      <div class="modal-actions"><button class="btn-back" onclick="closeModal()">Cancel</button><button class="btn-next" onclick="modSaveLinks('${JA(groupId)}')">Save</button></div>`);
  };
  window.modSaveLinks = async function (groupId) {
    const want = new Set([...document.querySelectorAll('#modal input[type=checkbox]:checked')].map(c => c.value));
    const have = new Set(st.links.filter(l => l.group_id === groupId).map(l => l.menu_item_id));
    const add = [...want].filter(x => !have.has(x)).map(x => ({ group_id: groupId, menu_item_id: x }));
    const del = [...have].filter(x => !want.has(x));
    try {
      if (add.length) { const r = await sb.from('menu_item_modifier_groups').insert(add); if (r.error) throw r.error; }
      if (del.length) { const r = await sb.from('menu_item_modifier_groups').delete().eq('group_id', groupId).in('menu_item_id', del); if (r.error) throw r.error; }
      closeModal(); await load(); draw();
    } catch (e) { toast(e.message); }
  };
  window.modDelete = async function (table, id) {
    if (!await tpnConfirm('Delete this? Past orders keep their record of it.', { danger: true, confirmText: 'Delete' })) return;
    const { error } = await sb.from(table).delete().eq('id', id);
    if (error) { toast(error.message); return; }
    closeModal(); await load(); draw();
  };
  ['modSaveGroup', 'modSaveOption', 'modSaveLinks'].forEach(n => window.guardAsync && guardAsync(n));

  const COLS = [
    { key: 'group', label: 'Group', required: true }, { key: 'min', label: 'Min', type: 'number' }, { key: 'max', label: 'Max', type: 'number' },
    { key: 'choice', label: 'Choice', required: true }, { key: 'price', label: 'Adds (PHP)', type: 'money' }
  ];
  window.modExport = (fmt) => tpnExport(st.groups.flatMap(g => g.options.map(o => ({ group: g.name, min: g.min_select, max: g.max_select, choice: o.name, price: o.price_delta }))),
    COLS, { format: fmt, filename: 'tpn-add-ons', sheet: 'Add-ons', title: 'Tyo Paeng Nyo — add-ons & choices' });
  window.modImport = () => tpnImport({
    title: 'Import add-ons', columns: COLS, templateName: 'tpn-add-ons-template',
    async onCommit(rows) {
      // Groups are matched by name; new choices are added, existing names updated.
      let n = 0;
      for (const r of rows) {
        let g = st.groups.find(x => x.name.toLowerCase() === r.group.toLowerCase());
        if (!g) {
          const { data, error } = await sb.from('modifier_groups').insert({ name: r.group, min_select: r.min ?? 0, max_select: Math.max(1, r.max ?? 1) }).select().single();
          if (error) throw error; g = Object.assign(data, { options: [] }); st.groups.push(g);
        }
        const ex = g.options.find(o => o.name.toLowerCase() === r.choice.toLowerCase());
        const { error } = ex ? await sb.from('modifiers').update({ price_delta: r.price ?? 0 }).eq('id', ex.id)
                             : await sb.from('modifiers').insert({ group_id: g.id, name: r.choice, price_delta: r.price ?? 0 });
        if (error) throw error; n++;
      }
      await load(); draw(); return { ok: n };
    }
  });

  TPN_MOD.register({ id: 'modifiers', side: 'admin', section: 'sec.stock', after: 'menu-manager', perm: 'menu.edit', icon: '➕', label: 'Add-ons & choices', labelTl: 'Add-ons', render });
})();
