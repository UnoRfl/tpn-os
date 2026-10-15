/* ═══════════════════════════════════════════════════════════════
   TPN OS — Kit
   Shared pieces every newer portal feature builds on. Load order:
     supabase-js → config.js → tpn-supabase.js → tpn-kit.js → page
   Feature modules (modules/*.js) load after the page script.

   What lives here and why:
   - TPN_MOD     a small registry so a feature can add a portal tab from
                 its own file instead of growing index.html further.
   - tpnAsk /    accessible replacements for window.confirm/prompt
     tpnConfirm  (focus trap, Escape, preset reason chips, works on iOS
                 standalone where native prompts are suppressed).
   - tpnExport / one Excel/CSV path for every list, with a downloadable
     tpnImport   template and a preview step that shows bad rows before
                 anything is written.
   - peso()      the one money formatter.
   - TPN.retry / timeouts and backoff for reads, so a slow network
     withTimeout reads as "retrying" rather than a frozen screen.
   - tpnDraft    autosaves long forms so a dropped session loses nothing.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  const esc = (v) => (window.TPN && TPN.esc) ? TPN.esc(v)
    : String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));

  /* ── Money ─────────────────────────────────────────────────── */
  const _pesoFmt = new Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP', minimumFractionDigits: 2 });
  window.peso = function (v) {
    const n = Number(v);
    return _pesoFmt.format(Number.isFinite(n) ? n : 0);
  };

  /* ── Module registry ───────────────────────────────────────── */
  // A module declares where it appears and how it draws. The sidebar and
  // router in index.html read this; permission checks stay the same
  // TPN.can() courtesy layer, with RLS doing the real refusing.
  const TPN_MOD = {
    routes: {},          // id → def
    order: [],
    register(def) {
      if (!def || !def.id || typeof def.render !== 'function') throw new Error('TPN_MOD.register needs id + render');
      this.routes[def.id] = Object.assign({ side: 'admin', section: 'sec.workspace', icon: '•' }, def);
      if (!this.order.includes(def.id)) this.order.push(def.id);
      // Re-draw the sidebar if the portal is already up (module loaded late).
      try {
        if (who()) {
          if (typeof renderAdminSidebar === 'function' && document.getElementById('portalNav')?.childElementCount) renderAdminSidebar();
          if (typeof renderStaffSidebar === 'function' && document.getElementById('staffNav')?.childElementCount) renderStaffSidebar();
        }
      } catch (e) { /* sidebar not mounted yet */ }
    },
    // Nav rows for one side, already filtered by permission.
    navFor(side) {
      return this.order.map(id => this.routes[id])
        .filter(d => d.side === side || d.side === 'both')
        .filter(d => !d.hidden)
        .filter(d => !d.perm || (window.TPN && TPN.can && TPN.can(d.perm)))
        .filter(d => !d.when || safe(() => d.when(), false));
    },
    label(d) {
      const lang = (pstate() && pstate().lang) || (safe(() => localStorage.getItem('tpn.lang'), null)) || 'en';
      return (lang === 'tl' && d.labelTl) ? d.labelTl : d.label;
    },
    render(id, main, side) {
      const d = this.routes[id];
      if (!d) return false;
      try {
        const out = d.render(main, side);
        if (out && typeof out.catch === 'function') out.catch(err => {
          console.error('[module ' + id + ']', err);
          main.innerHTML = (typeof loadErrorPanel === 'function') ? loadErrorPanel(d.label, err, `route('${id}',{refresh:true})`) : esc(err.message);
        });
      } catch (err) {
        console.error('[module ' + id + ']', err);
        main.innerHTML = (typeof loadErrorPanel === 'function') ? loadErrorPanel(d.label, err, `route('${id}',{refresh:true})`) : esc(err.message);
      }
      return true;
    }
  };
  function safe(fn, fallback) { try { return fn(); } catch (e) { return fallback; } }
  // index.html declares these with let/const, which do not land on window.
  // Read them through the shared global scope instead.
  const who = () => safe(() => (typeof currentUser !== 'undefined' ? currentUser : null), null);
  const pstate = () => safe(() => (typeof portalState !== 'undefined' ? portalState : null), null);
  window.TPN_MOD = TPN_MOD;
  window.tpnWho = who;

  /* ── Dialogs ───────────────────────────────────────────────── */
  // Own overlay, not the portal #modal: a confirm raised from inside an
  // open modal must not replace that modal's contents.
  let _dlgSeq = 0;
  function dialog({ title, message = '', input = null, chips = null, confirmText = 'OK', cancelText = 'Cancel', danger = false, allowEmpty = false }) {
    return new Promise(resolve => {
      const id = 'tpn-dlg-' + (++_dlgSeq);
      const back = document.activeElement;
      const wrap = document.createElement('div');
      wrap.className = 'tpn-dlg-overlay';
      wrap.id = id;
      const chipHtml = chips && chips.length
        ? `<div class="tpn-dlg-chips" role="group" aria-label="Quick choices">${chips.map((c, i) =>
            `<button type="button" class="tpn-chip" data-chip="${i}">${esc(c)}</button>`).join('')}</div>` : '';
      const inputHtml = input ? (input.type === 'textarea'
        ? `<textarea class="form-input tpn-dlg-input" rows="3" placeholder="${esc(input.placeholder || '')}" aria-label="${esc(input.label || title)}">${esc(input.value || '')}</textarea>`
        : `<input class="form-input tpn-dlg-input" type="${esc(input.type || 'text')}" ${input.inputmode ? `inputmode="${esc(input.inputmode)}"` : ''} placeholder="${esc(input.placeholder || '')}" value="${esc(input.value || '')}" aria-label="${esc(input.label || title)}" ${input.min != null ? `min="${esc(input.min)}"` : ''} ${input.step != null ? `step="${esc(input.step)}"` : ''}>`) : '';
      wrap.innerHTML = `<div class="tpn-dlg glass" role="${danger ? 'alertdialog' : 'dialog'}" aria-modal="true" aria-labelledby="${id}-t" aria-describedby="${id}-m">
          <div class="tpn-dlg-title" id="${id}-t">${esc(title)}</div>
          ${message ? `<div class="tpn-dlg-msg" id="${id}-m">${esc(message)}</div>` : `<div id="${id}-m" hidden></div>`}
          ${chipHtml}${inputHtml}
          <div class="tpn-dlg-err" role="alert" aria-live="assertive"></div>
          <div class="tpn-dlg-actions">
            <button type="button" class="btn-ghost tpn-dlg-cancel">${esc(cancelText)}</button>
            <button type="button" class="${danger ? 'btn-danger' : 'btn-primary'} tpn-dlg-ok">${esc(confirmText)}</button>
          </div>
        </div>`;
      document.body.appendChild(wrap);
      const box = wrap.querySelector('.tpn-dlg');
      const field = wrap.querySelector('.tpn-dlg-input');
      const err = wrap.querySelector('.tpn-dlg-err');
      const done = (val) => {
        document.removeEventListener('keydown', onKey, true);
        wrap.remove();
        if (back && document.contains(back) && back.focus) back.focus({ preventScroll: true });
        resolve(val);
      };
      const ok = () => {
        if (!input) return done(true);
        const v = field.value.trim();
        if (!v && !allowEmpty) { err.textContent = 'Please fill this in.'; field.focus(); return; }
        done(v);
      };
      const onKey = (e) => {
        if (!document.body.contains(wrap)) return;
        if (e.key === 'Escape') { e.preventDefault(); e.stopPropagation(); done(input ? null : false); }
        else if (e.key === 'Enter' && (!field || field.tagName !== 'TEXTAREA' || e.ctrlKey || e.metaKey)) {
          if (document.activeElement && document.activeElement.classList.contains('tpn-dlg-cancel')) return;
          e.preventDefault(); ok();
        } else if (e.key === 'Tab') {
          const f = [...box.querySelectorAll('button, input, textarea')];
          const i = f.indexOf(document.activeElement);
          if (e.shiftKey && i <= 0) { e.preventDefault(); f[f.length - 1].focus(); }
          else if (!e.shiftKey && i === f.length - 1) { e.preventDefault(); f[0].focus(); }
        }
      };
      document.addEventListener('keydown', onKey, true);
      wrap.addEventListener('click', (e) => { if (e.target === wrap) done(input ? null : false); });
      wrap.querySelector('.tpn-dlg-cancel').onclick = () => done(input ? null : false);
      wrap.querySelector('.tpn-dlg-ok').onclick = ok;
      wrap.querySelectorAll('[data-chip]').forEach(b => b.onclick = () => {
        const c = chips[+b.dataset.chip];
        if (field) { field.value = c; field.focus(); } else done(c);
      });
      setTimeout(() => (field || wrap.querySelector('.tpn-dlg-ok')).focus({ preventScroll: true }), 20);
    });
  }
  window.tpnConfirm = (message, opts = {}) => dialog(Object.assign({ title: opts.title || 'Are you sure?', message }, opts));
  window.tpnAsk = (title, opts = {}) => dialog(Object.assign({ title, input: Object.assign({ type: 'text' }, opts.input || {}) }, opts));
  window.tpnAlert = (message, opts = {}) => dialog(Object.assign({ title: opts.title || 'Heads up', message, cancelText: '' }, opts))
    .then(v => v);

  /* ── Resilience ────────────────────────────────────────────── */
  function withTimeout(promise, ms, what = 'request') {
    let t;
    return Promise.race([
      promise,
      new Promise((_, rej) => { t = setTimeout(() => rej(new Error(`The ${what} took too long. Check the connection and try again.`)), ms); })
    ]).finally(() => clearTimeout(t));
  }
  // Retries reads only. Never wrap a write in this: a write that timed out
  // may still have landed, and retrying it doubles an order or a payment.
  async function retry(fn, { tries = 3, base = 600, timeout = 12000, what } = {}) {
    let last;
    for (let i = 0; i < tries; i++) {
      try { return await withTimeout(Promise.resolve().then(fn), timeout, what); }
      catch (e) {
        last = e;
        // A refusal (RLS, validation) will not get better by asking again.
        const msg = String(e && (e.message || e.code || e));
        if (/permission|denied|violates|not allowed|invalid|42501|PGRST301|JWT/i.test(msg)) throw e;
        if (i < tries - 1) await new Promise(r => setTimeout(r, base * Math.pow(2, i) + Math.random() * 200));
      }
    }
    throw last;
  }
  window.tpnWithTimeout = withTimeout;
  window.tpnRetry = retry;
  if (window.TPN) { TPN.retry = retry; TPN.withTimeout = withTimeout; }

  // Form drafts survive a dropped session or a closed tab. Keyed per form;
  // cleared by the caller after a successful save.
  window.tpnDraft = {
    key: (name) => 'tpn.draft.' + name,
    save(name, data) { try { localStorage.setItem(this.key(name), JSON.stringify({ at: Date.now(), data })); } catch (e) {} },
    load(name, maxAgeMs = 3 * 864e5) {
      try {
        const v = JSON.parse(localStorage.getItem(this.key(name)) || 'null');
        if (!v || Date.now() - v.at > maxAgeMs) return null;
        return v.data;
      } catch (e) { return null; }
    },
    clear(name) { try { localStorage.removeItem(this.key(name)); } catch (e) {} },
    // Wire every [name] field inside a container to autosave.
    bind(name, container) {
      if (!container) return;
      const saved = this.load(name);
      // Fields are keyed by name, or by id when they have none. Passwords
      // and card-like fields are never stored.
      const fields = () => [...container.querySelectorAll('input[name], textarea[name], select[name], input[id], textarea[id], select[id]')]
        .filter(el => !/password|hidden|file/.test(el.type) && !el.hasAttribute('data-no-draft'));
      const key = (el) => el.name || el.id;
      if (saved) fields().forEach(el => {
        if (saved[key(el)] == null) return;
        if (el.type === 'checkbox') el.checked = !!saved[key(el)]; else if (!el.value) el.value = saved[key(el)];
      });
      const snap = () => {
        const d = {};
        fields().forEach(el => { d[key(el)] = el.type === 'checkbox' ? el.checked : el.value; });
        this.save(name, d);
      };
      container.addEventListener('input', snap);
      container.addEventListener('change', snap);
    }
  };

  /* ── Files: export ─────────────────────────────────────────── */
  function loadScriptOnce(src, globalName) {
    if (globalName && window[globalName]) return Promise.resolve(window[globalName]);
    return new Promise((resolve, reject) => {
      const s = document.createElement('script');
      s.src = src; s.async = true;
      s.onload = () => resolve(globalName ? window[globalName] : true);
      s.onerror = () => reject(new Error('Could not load ' + src));
      document.head.appendChild(s);
    });
  }
  // Local copy first (survives a CDN outage), CDN as the fallback.
  function loadExcel() {
    if (window.ExcelJS) return Promise.resolve(window.ExcelJS);
    return loadScriptOnce('vendor/exceljs-4.4.0.min.js', 'ExcelJS')
      .catch(() => loadScriptOnce('https://cdn.jsdelivr.net/npm/exceljs@4.4.0/dist/exceljs.min.js', 'ExcelJS'));
  }
  window.tpnLoadExcel = loadExcel;

  function stamp() {
    const d = new Date();
    const p = (n) => String(n).padStart(2, '0');
    return `${d.getFullYear()}-${p(d.getMonth() + 1)}-${p(d.getDate())}`;
  }
  function download(blob, filename) {
    const a = document.createElement('a');
    a.href = URL.createObjectURL(blob);
    a.download = filename;
    document.body.appendChild(a); a.click(); a.remove();
    setTimeout(() => URL.revokeObjectURL(a.href), 4000);
  }
  // Spreadsheet formula injection: a cell starting with = + - @ is run as
  // a formula by Excel. Customer-typed names and notes end up in these
  // exports, so neutralise them.
  function cellSafe(v) {
    if (typeof v !== 'string') return v;
    return /^[=+\-@\t\r]/.test(v) ? "'" + v : v;
  }
  function csvCell(v) {
    if (v == null) return '';
    v = cellSafe(v instanceof Date ? v.toISOString() : v);
    const s = String(v);
    return /[",\n\r]/.test(s) ? '"' + s.replace(/"/g, '""') + '"' : s;
  }

  /**
   * tpnExport(rows, columns, opts)
   *   columns: [{ key, label, type?: 'money'|'number'|'date'|'datetime'|'text', width?, get?(row) }]
   *   opts:    { filename, sheet, format: 'xlsx'|'csv', title }
   * Excel by default: it is what the office opens, peso columns stay
   * numbers (so SUM works) and the header row is frozen.
   */
  window.tpnExport = async function (rows, columns, opts = {}) {
    const format = opts.format || 'xlsx';
    const base = (opts.filename || 'tpn-export').replace(/[^\w\-]+/g, '-') + '-' + stamp();
    const val = (r, c) => c.get ? c.get(r) : r[c.key];
    if (format === 'csv') {
      const lines = [columns.map(c => csvCell(c.label)).join(',')]
        .concat(rows.map(r => columns.map(c => csvCell(val(r, c))).join(',')));
      // BOM so Excel on Windows reads ñ and ₱ correctly.
      download(new Blob(['﻿' + lines.join('\r\n')], { type: 'text/csv;charset=utf-8' }), base + '.csv');
      return;
    }
    const ExcelJS = await loadExcel();
    const wb = new ExcelJS.Workbook();
    wb.creator = 'TPN OS';
    const ws = wb.addWorksheet((opts.sheet || 'Data').slice(0, 31));
    let startRow = 1;
    if (opts.title) {
      ws.addRow([opts.title]).font = { bold: true, size: 14 };
      ws.addRow([`Exported ${new Date().toLocaleString('en-PH')}`]).font = { italic: true, color: { argb: 'FF6B4A35' } };
      ws.addRow([]);
      startRow = 4;
    }
    const head = ws.addRow(columns.map(c => c.label));
    head.font = { bold: true, color: { argb: 'FFFFFFFF' } };
    head.eachCell(cell => { cell.fill = { type: 'pattern', pattern: 'solid', fgColor: { argb: 'FF8B1A0E' } }; });
    rows.forEach(r => {
      ws.addRow(columns.map(c => {
        const v = val(r, c);
        if (v == null || v === '') return null;
        if (c.type === 'money' || c.type === 'number') { const n = Number(v); return Number.isFinite(n) ? n : cellSafe(String(v)); }
        if (c.type === 'date' || c.type === 'datetime') { const d = new Date(v); return isNaN(d) ? cellSafe(String(v)) : d; }
        return cellSafe(typeof v === 'object' ? JSON.stringify(v) : String(v));
      }));
    });
    columns.forEach((c, i) => {
      const col = ws.getColumn(i + 1);
      col.width = c.width || Math.min(48, Math.max(10, (c.label || '').length + 4));
      if (c.type === 'money') col.numFmt = '"₱"#,##0.00';
      if (c.type === 'date') col.numFmt = 'yyyy-mm-dd';
      if (c.type === 'datetime') col.numFmt = 'yyyy-mm-dd hh:mm';
    });
    ws.views = [{ state: 'frozen', ySplit: startRow }];
    if (rows.length) ws.autoFilter = { from: { row: startRow, column: 1 }, to: { row: startRow, column: columns.length } };
    const buf = await wb.xlsx.writeBuffer();
    download(new Blob([buf], { type: 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet' }), base + '.xlsx');
  };

  /* ── Files: import ─────────────────────────────────────────── */
  function parseCsv(text) {
    text = text.replace(/^﻿/, '');
    const rows = []; let row = []; let cell = ''; let q = false;
    for (let i = 0; i < text.length; i++) {
      const ch = text[i];
      if (q) {
        if (ch === '"') { if (text[i + 1] === '"') { cell += '"'; i++; } else q = false; }
        else cell += ch;
      } else if (ch === '"') q = true;
      else if (ch === ',') { row.push(cell); cell = ''; }
      else if (ch === '\n' || ch === '\r') {
        if (ch === '\r' && text[i + 1] === '\n') i++;
        row.push(cell); rows.push(row); row = []; cell = '';
      } else cell += ch;
    }
    if (cell !== '' || row.length) { row.push(cell); rows.push(row); }
    return rows.filter(r => r.some(c => String(c).trim() !== ''));
  }
  async function readSheet(file) {
    if (/\.csv$/i.test(file.name) || file.type === 'text/csv') return parseCsv(await file.text());
    const ExcelJS = await loadExcel();
    const wb = new ExcelJS.Workbook();
    await wb.xlsx.load(await file.arrayBuffer());
    const ws = wb.worksheets[0];
    const out = [];
    ws.eachRow({ includeEmpty: false }, (r) => {
      const vals = [];
      for (let i = 1; i <= ws.columnCount; i++) {
        let v = r.getCell(i).value;
        if (v && typeof v === 'object') v = v.result ?? v.text ?? (v instanceof Date ? v.toISOString().slice(0, 10) : (v.richText ? v.richText.map(t => t.text).join('') : String(v)));
        vals.push(v == null ? '' : String(v));
      }
      out.push(vals);
    });
    return out;
  }
  const norm = (s) => String(s || '').toLowerCase().replace(/[^a-z0-9]/g, '');

  /**
   * tpnImport({ title, columns, onCommit, maxRows })
   *   columns: [{ key, label, required?, type?: 'text'|'number'|'money'|'date'|'bool', aliases?: [], parse?(v), check?(v,row) → error string }]
   *   onCommit(rows) → Promise<{ ok: n, failed: [{row, error}] }>
   * Shows: pick file → preview with every problem marked → commit only the
   * good rows. Nothing is written until the person presses Import.
   */
  window.tpnImport = function ({ title = 'Import', columns, onCommit, maxRows = 2000, templateName }) {
    const id = 'tpn-imp-' + (++_dlgSeq);
    const wrap = document.createElement('div');
    wrap.className = 'tpn-dlg-overlay';
    wrap.innerHTML = `<div class="tpn-dlg tpn-dlg-wide glass" role="dialog" aria-modal="true" aria-labelledby="${id}-t">
      <div class="tpn-dlg-title" id="${id}-t">${esc(title)}</div>
      <div class="tpn-dlg-msg">Use an Excel (.xlsx) or CSV file. The first row must be the column names:
        <strong>${columns.map(c => esc(c.label) + (c.required ? '*' : '')).join(', ')}</strong>.</div>
      <div class="tpn-imp-pick">
        <label class="btn-primary tpn-file-btn">Choose file<input type="file" accept=".xlsx,.csv,text/csv,application/vnd.openxmlformats-officedocument.spreadsheetml.sheet" hidden></label>
        <button type="button" class="btn-ghost tpn-imp-tpl">Download blank template</button>
      </div>
      <div class="tpn-imp-preview" aria-live="polite"></div>
      <div class="tpn-dlg-actions">
        <button type="button" class="btn-ghost tpn-dlg-cancel">Close</button>
        <button type="button" class="btn-primary tpn-dlg-ok" disabled>Import</button>
      </div></div>`;
    document.body.appendChild(wrap);
    const close = () => wrap.remove();
    wrap.querySelector('.tpn-dlg-cancel').onclick = close;
    wrap.addEventListener('keydown', e => { if (e.key === 'Escape') close(); });
    wrap.querySelector('.tpn-imp-tpl').onclick = () =>
      window.tpnExport([], columns.map(c => ({ key: c.key, label: c.label })), { filename: templateName || (title + '-template'), sheet: 'Template' });
    const prev = wrap.querySelector('.tpn-imp-preview');
    const okBtn = wrap.querySelector('.tpn-dlg-ok');
    let good = [];

    wrap.querySelector('input[type=file]').onchange = async (ev) => {
      const file = ev.target.files[0];
      if (!file) return;
      prev.innerHTML = '<div class="tpn-muted">Reading…</div>';
      okBtn.disabled = true;
      try {
        const grid = await readSheet(file);
        if (!grid.length) throw new Error('The file is empty.');
        const header = grid[0].map(norm);
        const idx = columns.map(c => {
          const names = [c.key, c.label, ...(c.aliases || [])].map(norm);
          return header.findIndex(h => names.includes(h));
        });
        const missing = columns.filter((c, i) => c.required && idx[i] < 0).map(c => c.label);
        if (missing.length) throw new Error('Missing column(s): ' + missing.join(', '));
        const body = grid.slice(1, maxRows + 1);
        const results = body.map((cells, n) => {
          const row = {}; const errs = [];
          columns.forEach((c, i) => {
            let v = idx[i] >= 0 ? String(cells[idx[i]] ?? '').trim() : '';
            if (!v) { if (c.required) errs.push(c.label + ' is required'); row[c.key] = null; return; }
            try {
              if (c.parse) v = c.parse(v);
              else if (c.type === 'number' || c.type === 'money') {
                const x = Number(String(v).replace(/[₱,\s]/g, ''));
                if (!Number.isFinite(x)) throw new Error(c.label + ' must be a number');
                v = x;
              } else if (c.type === 'bool') v = /^(y|yes|true|1|oo)$/i.test(v);
              else if (c.type === 'date') {
                const d = new Date(v);
                if (isNaN(d)) throw new Error(c.label + ' must be a date (YYYY-MM-DD)');
                v = d.toISOString().slice(0, 10);
              }
              const bad = c.check && c.check(v, row);
              if (bad) throw new Error(bad);
            } catch (e) { errs.push(e.message); }
            row[c.key] = v;
          });
          return { n: n + 2, row, errs };
        });
        good = results.filter(r => !r.errs.length).map(r => r.row);
        const bad = results.filter(r => r.errs.length);
        prev.innerHTML = `<div class="tpn-imp-sum"><span class="tpn-pill ok">${good.length} ready</span>
            ${bad.length ? `<span class="tpn-pill bad">${bad.length} with problems (skipped)</span>` : ''}
            ${grid.length - 1 > maxRows ? `<span class="tpn-pill warn">Only the first ${maxRows} rows are read</span>` : ''}</div>
          ${bad.length ? `<div class="tpn-imp-errs"><table><thead><tr><th>Row</th><th>Problem</th></tr></thead><tbody>
            ${bad.slice(0, 50).map(b => `<tr><td>${b.n}</td><td>${esc(b.errs.join('; '))}</td></tr>`).join('')}</tbody></table></div>` : ''}
          <div class="tpn-imp-table"><table><thead><tr>${columns.map(c => `<th>${esc(c.label)}</th>`).join('')}</tr></thead><tbody>
            ${good.slice(0, 8).map(r => `<tr>${columns.map(c => `<td>${esc(r[c.key] ?? '')}</td>`).join('')}</tr>`).join('')}
          </tbody></table>${good.length > 8 ? `<div class="tpn-muted">…and ${good.length - 8} more</div>` : ''}</div>`;
        okBtn.disabled = !good.length;
      } catch (e) {
        prev.innerHTML = `<div class="tpn-imp-errs" role="alert">${esc(e.message)}</div>`;
      }
    };
    okBtn.onclick = async () => {
      okBtn.disabled = true; okBtn.textContent = 'Importing…';
      try {
        const res = await onCommit(good) || {};
        const failed = res.failed || [];
        prev.innerHTML = `<div class="tpn-imp-sum"><span class="tpn-pill ok">${res.ok ?? good.length - failed.length} imported</span>
          ${failed.length ? `<span class="tpn-pill bad">${failed.length} refused by the server</span>` : ''}</div>
          ${failed.length ? `<div class="tpn-imp-errs"><table><tbody>${failed.slice(0, 50).map(f => `<tr><td>${esc(f.label || '')}</td><td>${esc(f.error)}</td></tr>`).join('')}</tbody></table></div>` : ''}`;
        okBtn.textContent = 'Done';
      } catch (e) {
        prev.insertAdjacentHTML('afterbegin', `<div class="tpn-imp-errs" role="alert">${esc(e.message)}</div>`);
        okBtn.disabled = false; okBtn.textContent = 'Import';
      }
    };
  };

  /* ── Export menu button ────────────────────────────────────── */
  // One button, two formats. Pages call tpnExportButton('fnName') where
  // window[fnName](format) does the export.
  window.tpnExportButton = function (fnName, label = 'Export') {
    return `<details class="tpn-menu"><summary class="btn-ghost tpn-menu-btn">⬇ ${esc(label)}</summary>
      <div class="tpn-menu-list glass" role="menu">
        <button type="button" role="menuitem" onclick="this.closest('details').open=false;${esc(fnName)}('xlsx')">Excel (.xlsx)</button>
        <button type="button" role="menuitem" onclick="this.closest('details').open=false;${esc(fnName)}('csv')">CSV (.csv)</button>
      </div></details>`;
  };
  // Close open menus on outside click / Escape.
  document.addEventListener('click', (e) => {
    document.querySelectorAll('details.tpn-menu[open]').forEach(d => { if (!d.contains(e.target)) d.open = false; });
  });
  document.addEventListener('keydown', (e) => {
    if (e.key === 'Escape') document.querySelectorAll('details.tpn-menu[open]').forEach(d => { d.open = false; d.querySelector('summary')?.focus(); });
  });

  /* ── Session guard ─────────────────────────────────────────── */
  // A staff session must never end silently mid-shift. Three things:
  //  1. Sign-out in one tab signs out every tab (BroadcastChannel), so a
  //     shared terminal is not left logged in elsewhere.
  //  2. If the token can no longer refresh (expired, revoked, password
  //     changed elsewhere), the page says so and offers sign-in in place,
  //     instead of every list turning into a permission error.
  //  3. When the network comes back, the session is re-checked first.
  const bc = ('BroadcastChannel' in window) ? new BroadcastChannel('tpn-session') : null;
  window.tpnSession = {
    _userInitiated: false,
    markUserSignOut() { this._userInitiated = true; try { bc && bc.postMessage({ t: 'signout' }); } catch (e) {} },
    async check() {
      if (!window.sb || !sb.auth) return true;
      try {
        const { data, error } = await withTimeout(sb.auth.getSession(), 8000, 'session check');
        if (error) throw error;
        return !!(data && data.session);
      } catch (e) { return null; } // unknown (offline) — do not kick anyone out
    }
  };
  if (bc) bc.onmessage = (ev) => {
    if (ev.data && ev.data.t === 'signout' && who() && typeof exitStaffPortal === 'function') {
      exitStaffPortal().catch(() => {});
    }
  };
  if (window.sb && sb.auth && !/tpn-table-menu/i.test(location.pathname)) {
    sb.auth.onAuthStateChange((event) => {
      if (event === 'SIGNED_OUT' && !tpnSession._userInitiated && who()) {
        showSessionLost();
      }
      if (event === 'SIGNED_IN' || event === 'TOKEN_REFRESHED') {
        tpnSession._userInitiated = false;
        document.getElementById('tpn-session-lost')?.remove();
      }
    });
    window.addEventListener('online', async () => {
      if (!who()) return;
      const ok = await tpnSession.check();
      if (ok === false) showSessionLost();
    });
  }
  function showSessionLost() {
    if (document.getElementById('tpn-session-lost')) return;
    const d = document.createElement('div');
    d.id = 'tpn-session-lost';
    d.className = 'tpn-dlg-overlay';
    d.innerHTML = `<div class="tpn-dlg glass" role="alertdialog" aria-modal="true" aria-labelledby="tsl-t">
      <div class="tpn-dlg-title" id="tsl-t">Your session ended</div>
      <div class="tpn-dlg-msg">You were signed out (expired, or signed out on another device). Anything you were typing is saved on this device. Sign in again to continue where you left off.</div>
      <div class="tpn-dlg-actions"><button type="button" class="btn-primary">Sign in again</button></div></div>`;
    document.body.appendChild(d);
    d.querySelector('button').onclick = () => {
      d.remove();
      try { if (typeof exitStaffPortal === 'function') exitStaffPortal(); } catch (e) {}
      try { if (typeof openStaffLogin === 'function') openStaffLogin(); } catch (e) {}
    };
    d.querySelector('button').focus();
  }
})();
