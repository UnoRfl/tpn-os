/* ═══════════════════════════════════════════════════════════════
   Portal tab: Website
   Everything the public site shows that is not the menu: contact
   details and hours, FAQs, real customer testimonials, event packages.
   Needs the 'site.edit' permission (manager and up by default).
   Tables and rules: sql/30-site-content.sql.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const st = { tab: 'contact', settings: {}, faqs: [], testimonials: [], packages: [] };

  const SETTINGS = [
    { key: 'contact.phone',     label: 'Phone number',          hint: 'Shown on every page and used for tap-to-call.' },
    { key: 'contact.email',     label: 'Email (optional)',      hint: 'Leave blank to hide it everywhere.' },
    { key: 'contact.address',   label: 'Address' },
    { key: 'contact.landmark',  label: 'Landmark',              hint: 'Helps first-time visitors find you.' },
    { key: 'contact.map_url',   label: 'Google Maps link',      hint: 'Must start with https://' },
    { key: 'contact.parking',   label: 'Parking' },
    { key: 'hours.text',        label: 'Opening hours' },
    { key: 'contact.facebook',  label: 'Facebook page link' },
    { key: 'contact.instagram', label: 'Instagram link' },
    { key: 'payments.online_enabled', label: 'Online payments (HitPay): type yes to turn on', hint: 'Only after the HitPay keys are set up and a sandbox test payment worked. Leave blank for cash only.' },
    { key: 'legal.company',     label: 'Registered business name' },
    { key: 'legal.sec_no',      label: 'SEC registration no. (optional)', hint: 'The "SEC" badge only appears once this is filled in.' },
    { key: 'legal.tin',         label: 'TIN (optional)',        hint: 'The "VAT" badge only appears once this is filled in.' }
  ];

  async function load() {
    const [s, f, t, p] = await Promise.all([
      sb.from('site_settings').select('key,value,updated_at'),
      sb.from('faqs').select('*').order('sort').order('created_at'),
      sb.from('testimonials').select('*').order('sort').order('created_at', { ascending: false }),
      sb.from('event_packages').select('*').order('sort')
    ]);
    for (const r of [s, f, t, p]) if (r.error) throw r.error;
    st.settings = Object.fromEntries(s.data.map(r => [r.key, r.value]));
    st.faqs = f.data; st.testimonials = t.data; st.packages = p.data;
  }

  async function render(main) {
    main.innerHTML = `
      <div class="portal-header">
        <div><h1>Website</h1>
          <div class="portal-header-sub">What customers see on the public site. Changes go live as soon as you save — no update needed.</div></div>
        <a class="btn-ghost" href="./#faq" target="_blank" rel="noopener" style="text-decoration:none;padding:10px 18px;">View site ↗</a>
      </div>
      <div id="webTabs"></div>
      <div id="webBody" class="panel"><div class="tpn-muted" style="text-align:center;padding:24px;">Loading…</div></div>`;
    try { await load(); }
    catch (e) { main.querySelector('#webBody').outerHTML = loadErrorPanel('the website content', e, "route('website',{refresh:true})"); return; }
    draw();
  }

  function draw() {
    const tabs = [
      { id: 'contact', label: 'Contact & hours' },
      { id: 'faqs', label: 'FAQs', badge: st.faqs.length },
      { id: 'testimonials', label: 'Testimonials', badge: st.testimonials.length },
      { id: 'packages', label: 'Event packages', badge: st.packages.length }
    ];
    document.getElementById('webTabs').innerHTML = tpnTabs('Website sections', tabs, st.tab, 'webSetTab');
    const body = document.getElementById('webBody');
    ({ contact: drawContact, faqs: drawFaqs, testimonials: drawTestimonials, packages: drawPackages })[st.tab](body);
  }
  window.webSetTab = (t) => { st.tab = t; draw(); };

  /* ── Contact & hours ─────────────────────────────────────── */
  function drawContact(body) {
    const val = (k) => { const v = st.settings[k]; return v == null ? '' : String(v); };
    body.innerHTML = `
      <form id="webContact" class="web-form" onsubmit="event.preventDefault();webSaveContact()">
        ${SETTINGS.map(s => `
          <div class="form-row full"><div>
            <label class="form-label" for="ws-${E(s.key)}">${E(s.label)}</label>
            <input class="form-input" id="ws-${E(s.key)}" name="${E(s.key)}" value="${E(val(s.key))}" maxlength="300">
            ${s.hint ? `<div class="pref-row-hint">${E(s.hint)}</div>` : ''}
          </div></div>`).join('')}
        <div class="modal-actions"><button class="btn-next" type="submit">Save contact details</button></div>
      </form>`;
    tpnDraft.bind('web-contact', document.getElementById('webContact'));
  }
  window.webSaveContact = async function () {
    const rows = SETTINGS.map(s => {
      const raw = document.getElementById('ws-' + s.key).value.trim();
      return { key: s.key, value: raw === '' ? null : raw };
    });
    const bad = rows.find(r => /url|facebook|instagram/.test(r.key) && r.value && !/^https:\/\//.test(r.value));
    if (bad) { toast('Links must start with https://'); return; }
    const { error } = await sb.from('site_settings').upsert(rows.map(r => ({ key: r.key, value: r.value })));
    if (error) { toast('Could not save: ' + error.message); return; }
    tpnDraft.clear('web-contact');
    rows.forEach(r => st.settings[r.key] = r.value);
    toast('Saved. The public site now shows these details.');
  };

  /* ── Shared list UI ──────────────────────────────────────── */
  function listHtml(rows, cols, kind) {
    if (!rows.length) return `<div class="tpn-empty" style="padding:32px;text-align:center;color:var(--ink-muted);">Nothing here yet.</div>`;
    return `<div class="data-table-wrap"><table class="data-table"><thead><tr>
        ${cols.map(c => `<th>${E(c.label)}</th>`).join('')}<th style="text-align:right">Actions</th></tr></thead><tbody>
      ${rows.map(r => `<tr>
        ${cols.map(c => `<td>${c.html ? c.html(r) : E(c.get ? c.get(r) : r[c.key] ?? '')}</td>`).join('')}
        <td style="text-align:right;white-space:nowrap;">
          <button class="table-btn" onclick="webEdit('${JA(kind)}','${JA(r.id)}')">Edit</button>
          <button class="table-btn" onclick="webDelete('${JA(kind)}','${JA(r.id)}')">Delete</button>
        </td></tr>`).join('')}
      </tbody></table></div>`;
  }
  const pub = (r) => r.is_published ? '<span class="tpn-pill ok">Published</span>' : '<span class="tpn-pill warn">Draft</span>';
  function toolbar(kind, addLabel) {
    return `<div style="display:flex;gap:8px;flex-wrap:wrap;justify-content:flex-end;margin-bottom:14px;">
      ${tpnExportButton('webExport_' + kind)}
      <button class="btn-ghost" onclick="webImport('${JA(kind)}')">⬆ Import</button>
      <button class="btn-next" style="margin-left:0" onclick="webEdit('${JA(kind)}',null)">${E(addLabel)}</button></div>`;
  }

  function drawFaqs(body) {
    body.innerHTML = toolbar('faqs', '+ New question') +
      `<p class="pref-row-hint" style="margin-bottom:10px;">Drafts are not shown on the site. Questions marked “[Fill in]” need your real answer before publishing.</p>` +
      listHtml(st.faqs, [
        { label: 'Category', key: 'category' },
        { label: 'Question', key: 'question' },
        { label: 'Status', html: pub },
        { label: 'Order', key: 'sort' }
      ], 'faqs');
  }
  function drawTestimonials(body) {
    body.innerHTML = toolbar('testimonials', '+ Add a real quote') +
      `<p class="pref-row-hint" style="margin-bottom:10px;">Only quotes customers actually gave you, with their permission. The site cannot publish one without a consent date. Use first name and initial.</p>` +
      listHtml(st.testimonials, [
        { label: 'Quote', get: r => (r.quote || '').slice(0, 80) + ((r.quote || '').length > 80 ? '…' : '') },
        { label: 'By', key: 'author_display' },
        { label: 'Consent', get: r => r.consent_on || '— none —' },
        { label: 'Status', html: pub }
      ], 'testimonials');
  }
  function drawPackages(body) {
    body.innerHTML = toolbar('packages', '+ New package') +
      `<p class="pref-row-hint" style="margin-bottom:10px;">Shown on the Events page as “from ₱…”. A package needs a price before it can be published.</p>` +
      listHtml(st.packages, [
        { label: 'Package', key: 'name' },
        { label: 'From', get: r => r.from_price == null ? '—' : peso(r.from_price) + ' ' + ({ per_pax: '/ pax', per_event: '/ event', per_tray: '/ tray' })[r.price_unit] },
        { label: 'Min pax', get: r => r.min_pax || '—' },
        { label: 'Status', html: pub }
      ], 'packages');
  }

  /* ── Edit forms ──────────────────────────────────────────── */
  const FORMS = {
    faqs: { table: 'faqs', title: 'question', fields: [
      { k: 'category', label: 'Category', type: 'text', def: 'General' },
      { k: 'question', label: 'Question (English)', type: 'text', req: true },
      { k: 'answer', label: 'Answer (English)', type: 'textarea', req: true },
      { k: 'question_tl', label: 'Question (Tagalog, optional)', type: 'text' },
      { k: 'answer_tl', label: 'Answer (Tagalog, optional)', type: 'textarea' },
      { k: 'sort', label: 'Order (lower shows first)', type: 'number', def: 100 },
      { k: 'is_published', label: 'Published on the site', type: 'check' }
    ]},
    testimonials: { table: 'testimonials', title: 'author_display', fields: [
      { k: 'quote', label: 'Their words, exactly as given', type: 'textarea', req: true },
      { k: 'author_display', label: 'Name to show (e.g. "Ana R.")', type: 'text', req: true },
      { k: 'context', label: 'Context (e.g. "Regular since 2019")', type: 'text' },
      { k: 'source', label: 'Where they said it', type: 'select', opts: ['in_person', 'facebook', 'messenger', 'google', 'instagram', 'email', 'other'], def: 'in_person' },
      { k: 'rating', label: 'Star rating they gave (optional)', type: 'number' },
      { k: 'consent_on', label: 'Date they agreed to be quoted', type: 'date' },
      { k: 'consent_note', label: 'How they agreed (staff only)', type: 'text' },
      { k: 'sort', label: 'Order', type: 'number', def: 100 },
      { k: 'is_published', label: 'Published on the site', type: 'check' }
    ]},
    packages: { table: 'event_packages', title: 'name', fields: [
      { k: 'name', label: 'Package name', type: 'text', req: true },
      { k: 'name_tl', label: 'Name in Tagalog (optional)', type: 'text' },
      { k: 'description', label: 'Short description', type: 'textarea' },
      { k: 'from_price', label: 'Starting price (₱)', type: 'number' },
      { k: 'price_unit', label: 'Price is…', type: 'select', opts: ['per_pax', 'per_event', 'per_tray'], def: 'per_pax' },
      { k: 'min_pax', label: 'Minimum guests (optional)', type: 'number' },
      { k: 'inclusions', label: 'Inclusions (one per line)', type: 'lines' },
      { k: 'badge', label: 'Badge (e.g. "Popular")', type: 'text' },
      { k: 'sort', label: 'Order', type: 'number', def: 100 },
      { k: 'is_published', label: 'Published on the site', type: 'check' }
    ]}
  };
  const rowsOf = (kind) => kind === 'faqs' ? st.faqs : kind === 'testimonials' ? st.testimonials : st.packages;

  window.webEdit = function (kind, id) {
    const F = FORMS[kind]; const r = id ? rowsOf(kind).find(x => x.id === id) : {};
    const field = (f) => {
      const v = r[f.k] ?? f.def ?? '';
      const idA = 'wf-' + f.k;
      if (f.type === 'textarea') return `<textarea class="form-input" id="${idA}" rows="3">${E(v)}</textarea>`;
      if (f.type === 'lines') return `<textarea class="form-input" id="${idA}" rows="4">${E((v || []).join('\n'))}</textarea>`;
      if (f.type === 'select') return `<select class="form-input" id="${idA}">${f.opts.map(o => `<option ${o === v ? 'selected' : ''}>${E(o)}</option>`).join('')}</select>`;
      if (f.type === 'check') return `<label style="display:flex;gap:10px;align-items:center;"><input type="checkbox" id="${idA}" ${v ? 'checked' : ''} style="width:20px;height:20px;"> ${E(f.label)}</label>`;
      return `<input class="form-input" id="${idA}" type="${f.type === 'number' ? 'number' : f.type === 'date' ? 'date' : 'text'}" ${f.type === 'number' ? 'step="any" inputmode="decimal"' : ''} value="${E(v)}">`;
    };
    showModal(`<div class="modal-title">${id ? 'Edit' : 'New'} ${E(kind === 'faqs' ? 'question' : kind === 'testimonials' ? 'testimonial' : 'package')}</div>
      <div class="modal-content">
        ${F.fields.map(f => `<div class="form-row full"><div>${f.type === 'check' ? '' : `<label class="form-label" for="wf-${E(f.k)}">${E(f.label)}${f.req ? ' *' : ''}</label>`}${field(f)}</div></div>`).join('')}
        <div class="form-error" id="wf-err" role="alert"></div>
      </div>
      <div class="modal-actions"><button class="btn-back" onclick="closeModal()">Cancel</button>
        <button class="btn-next" onclick="webSave('${JA(kind)}',${id ? `'${JA(id)}'` : 'null'})">Save</button></div>`);
  };
  window.webSave = async function (kind, id) {
    const F = FORMS[kind]; const out = {}; const err = document.getElementById('wf-err');
    for (const f of F.fields) {
      const el = document.getElementById('wf-' + f.k);
      let v = f.type === 'check' ? el.checked : el.value.trim();
      if (f.type === 'number') v = v === '' ? null : Number(v);
      if (f.type === 'lines') v = v.split('\n').map(x => x.trim()).filter(Boolean);
      if ((f.type === 'text' || f.type === 'textarea' || f.type === 'date') && v === '') v = null;
      if (f.req && (v == null || v === '')) { err.textContent = f.label + ' is required.'; return; }
      out[f.k] = v;
    }
    if (kind === 'testimonials' && out.is_published && !out.consent_on) { err.textContent = 'Add the date the customer agreed to be quoted before publishing.'; return; }
    if (kind === 'packages' && out.is_published && out.from_price == null) { err.textContent = 'Add a starting price before publishing.'; return; }
    if (kind === 'testimonials' && out.rating != null && (out.rating < 1 || out.rating > 5)) { err.textContent = 'Rating is 1 to 5.'; return; }
    const q = id ? sb.from(F.table).update(out).eq('id', id) : sb.from(F.table).insert(out);
    const { error } = await q;
    if (error) { err.textContent = 'Could not save: ' + error.message; return; }
    closeModal(); toast('Saved.');
    await load(); draw();
  };
  window.webDelete = async function (kind, id) {
    const F = FORMS[kind]; const r = rowsOf(kind).find(x => x.id === id);
    if (!await tpnConfirm(`Delete “${r ? r[F.title] : ''}”? It disappears from the site straight away. The audit log keeps a copy.`, { title: 'Delete?', confirmText: 'Delete', danger: true })) return;
    const { error } = await sb.from(F.table).delete().eq('id', id);
    if (error) { toast('Could not delete: ' + error.message); return; }
    await load(); draw();
  };

  /* ── Excel / CSV ─────────────────────────────────────────── */
  const IO = {
    faqs: [
      { key: 'category', label: 'Category' }, { key: 'question', label: 'Question', required: true },
      { key: 'answer', label: 'Answer', required: true }, { key: 'question_tl', label: 'Question (Tagalog)' },
      { key: 'answer_tl', label: 'Answer (Tagalog)' }, { key: 'sort', label: 'Order', type: 'number' },
      { key: 'is_published', label: 'Published', type: 'bool' }
    ],
    testimonials: [
      { key: 'quote', label: 'Quote', required: true }, { key: 'author_display', label: 'Name shown', required: true },
      { key: 'context', label: 'Context' }, { key: 'source', label: 'Source', check: v => ['in_person', 'facebook', 'messenger', 'google', 'instagram', 'email', 'other'].includes(v) ? null : 'Source must be in_person, facebook, messenger, google, instagram, email or other' },
      { key: 'rating', label: 'Rating', type: 'number' }, { key: 'consent_on', label: 'Consent date', type: 'date' },
      { key: 'consent_note', label: 'Consent note' }, { key: 'is_published', label: 'Published', type: 'bool',
        check: (v, row) => v && !row.consent_on ? 'Cannot publish without a consent date' : null }
    ],
    packages: [
      { key: 'name', label: 'Package', required: true }, { key: 'description', label: 'Description' },
      { key: 'from_price', label: 'From price', type: 'money' },
      { key: 'price_unit', label: 'Price unit', check: v => ['per_pax', 'per_event', 'per_tray'].includes(v) ? null : 'Price unit must be per_pax, per_event or per_tray' },
      { key: 'min_pax', label: 'Min pax', type: 'number' },
      { key: 'inclusions', label: 'Inclusions (separate with ;)', parse: v => v.split(';').map(x => x.trim()).filter(Boolean) },
      { key: 'badge', label: 'Badge' }, { key: 'sort', label: 'Order', type: 'number' },
      { key: 'is_published', label: 'Published', type: 'bool', check: (v, row) => v && row.from_price == null ? 'Cannot publish without a price' : null }
    ]
  };
  for (const kind of Object.keys(IO)) {
    window['webExport_' + kind] = (fmt) => tpnExport(
      rowsOf(kind).map(r => kind === 'packages' ? Object.assign({}, r, { inclusions: (r.inclusions || []).join('; ') }) : r),
      IO[kind].map(c => ({ key: c.key, label: c.label, type: c.type === 'bool' ? 'text' : c.type, get: c.type === 'bool' ? (r => r[c.key] ? 'yes' : 'no') : undefined })),
      { format: fmt, filename: 'tpn-' + kind, sheet: kind, title: 'Tyo Paeng Nyo — ' + kind });
  }
  window.webImport = function (kind) {
    tpnImport({
      title: 'Import ' + kind, columns: IO[kind], templateName: 'tpn-' + kind + '-template',
      async onCommit(rows) {
        // Adds new rows; it never overwrites or deletes existing ones.
        const { error } = await sb.from(FORMS[kind].table).insert(rows.map(r => {
          const o = {}; for (const [k, v] of Object.entries(r)) if (v !== null && v !== '') o[k] = v; return o;
        }));
        if (error) throw new Error(error.message);
        await load(); draw();
        return { ok: rows.length };
      }
    });
  };

  TPN_MOD.register({
    id: 'website', side: 'admin', section: 'sec.stock', after: 'table-qr',
    perm: 'site.edit', icon: '🌐', label: 'Website', labelTl: 'Website', render
  });
})();
