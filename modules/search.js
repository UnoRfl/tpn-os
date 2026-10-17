/* ═══════════════════════════════════════════════════════════════
   Search everything — one box for pages, how-to help, and the things
   already loaded in the portal (orders, staff, inquiries, dishes).

   Open it from the search field at the top of the sidebar, the 🔍 on
   the phone header, Ctrl+K / ⌘K, or "/" when you are not typing.
   ↑ ↓ to move, Enter to open, Esc to close. The last few picks are kept
   on this device and shown when the box is empty.

   Only searches what this account can already see: pages come from the
   sidebar (which follows permissions), and the records are the ones
   the portal has loaded. Nothing new is fetched from the server.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const lang = () => { try { return (typeof TPN_LANG !== 'undefined' && TPN_LANG) || localStorage.getItem('tpn.lang') || 'en'; } catch (e) { return 'en'; } };
  const tx = (o) => (o == null ? '' : typeof o === 'string' ? o : (o[lang()] || o.en));
  const esc = (v) => String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const fold = (s) => String(s || '').toLowerCase().normalize('NFD').replace(/[̀-ͯ]/g, '');
  const RECENT_KEY = 'tpn.search.recent';
  const L = {
    field: { en: 'Search…', tl: 'Maghanap…' },
    placeholder: { en: 'Search pages, orders, staff, dishes, how-to…', tl: 'Maghanap ng pahina, order, staff, ulam, paano…' },
    pages: { en: 'Pages', tl: 'Mga pahina' }, help: { en: 'How do I…', tl: 'Paano…' },
    orders: { en: 'Orders', tl: 'Mga order' }, staff: { en: 'Staff', tl: 'Staff' },
    inquiries: { en: 'Inquiries', tl: 'Mga inquiry' }, dishes: { en: 'Dishes', tl: 'Mga ulam' },
    recent: { en: 'Recent', tl: 'Kamakailan' },
    none: { en: 'Nothing found. Try a name, an order number or a page.', tl: 'Walang nakita. Subukan ang pangalan, numero ng order o pahina.' },
    hint: { en: '↑↓ to move · Enter to open · Esc to close', tl: '↑↓ para lumipat · Enter para buksan · Esc para isara' },
    open: { en: 'Search', tl: 'Maghanap' }
  };
  // Other words people use for a page, so "sahod" finds Payroll and
  // "86" finds the kitchen queue.
  const SYN = {
    dashboard: 'home today summary ngayon', orders: 'live orders kanban order bill', kds: 'kitchen queue cook 86 sold out kusina luto',
    'void-requests': 'void cancel item', inquiries: 'catering events booking b2b', guests: 'customers suki regular',
    rewards: 'stamp card loyalty reward', 'staff-board': 'roles team move', tasks: 'todo task gawain', schedules: 'shift roster iskedyul',
    'attendance-admin': 'clock in out late attendance', 'clockin-review': 'photo uniform wifi network', payroll: 'salary pay sahod sweldo',
    'menu-manager': 'dishes price menu ulam presyo', modifiers: 'add-ons extras rice choices', discounts: 'promo senior pwd discount',
    inventory: 'stock ingredients delivery supplier sangkap', variance: 'loss waste shortage', 'table-qr': 'qr code tables mesa print',
    payments: 'cash gcash bank refund hitpay bayad', 'daily-close': 'z read count cash end of day close till', finance: 'expenses profit costs gastos kita',
    performance: 'analytics top dishes peak hours', history: 'past days audit archive', notifications: 'alerts bell',
    'messages-admin': 'message broadcast announce mensahe', website: 'faq testimonials packages contact hours site',
    accounts: 'users staff account add staff password', roles: 'permissions access', 'access-matrix': 'permissions grid', audit: 'log who did what',
    preferences: 'theme dark language tagalog text size settings', 'staff-home': 'home clock in', 'staff-schedule': 'my schedule shift',
    'staff-attendance': 'my attendance', 'staff-notifications': 'alerts', 'staff-messages': 'inbox', 'staff-settings': 'password account',
    floor: 'tables counter pos cashier dine-in close table', 'kitchen-station': 'kitchen screen wall',
    deliveries: 'delivery rider lalamove grab courier dispatch area fee zone'
  };

  const kind = () => document.getElementById('portal-staff')?.classList.contains('active') ? 'staff'
    : document.getElementById('portal-admin')?.classList.contains('active') ? 'admin' : null;
  const go = (id) => { if (kind() === 'staff') routeStaff(id); else route(id); };
  const canGo = (id) => {
    try { return (_tpnHubState[kind()] || []).some(h => h.items.some(i => i.id === id && !i.external)); } catch (e) { return false; }
  };

  /* ── Scoring: whole start > word start > anywhere > letters in order ── */
  // The name counts most; the extra words (synonyms, help steps) only
  // count when a word in them starts with what you typed.
  function score(q, label, hay) {
    if (!q) return 0;
    const l = fold(label), h = fold(hay);
    if (l.startsWith(q)) return 100;
    if (new RegExp('(^|[\\s\\-·(])' + q.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).test(l)) return 85;
    if (l.includes(q)) return 70;
    const words = q.split(/\s+/).filter(Boolean);
    if (words.every(w => new RegExp('(^|[\\s\\-·(])' + w.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')).test(h))) return words.length > 1 ? 55 : 50;
    // Letters in order on the name only ("pyrl" → Payroll).
    if (q.length >= 3 && q.length <= 8 && !q.includes(' ')) { let i = 0; for (const c of l) if (c === q[i]) i++; if (i === q.length) return 20; }
    return 0;
  }
  const rank = (list, q, n) => list.map(x => ({ x, s: score(q, x.label, x.hay) })).filter(r => r.s > 0)
    .sort((a, b) => b.s - a.s).slice(0, n);

  /* ── Sources ────────────────────────────────────────────────── */
  function pages() {
    const k = kind(); if (!k) return [];
    const hubs = (typeof _tpnHubState !== 'undefined' && _tpnHubState[k]) || [];
    return hubs.flatMap(h => h.items.map(it => {
      const row = typeof TPN_STRINGS !== 'undefined' && it.key && TPN_STRINGS[it.key];
      const label = it.label || (typeof T === 'function' ? T(it.key) : it.id);
      const group = typeof T === 'function' ? T(h.key) : '';
      return { type: 'page', icon: it.icon || '📄', label, sub: group !== label ? group : '',
        hay: [label, row && row.en, row && row.tl, group, SYN[it.id] || ''].join(' '),
        run: () => it.external ? window.open(it.external, '_blank', 'noopener') : go(it.id), id: 'page:' + it.id };
    }));
  }
  function helpTopics() {
    if (!window.TPN_GUIDE) return [];
    return TPN_GUIDE.topics().flatMap(g => g.items.map(it => ({
      type: 'help', icon: '💡', label: tx(it.title), sub: tx(g.group),
      hay: [it.title.en, it.title.tl, ...it.steps.flatMap(s => [s.en, s.tl])].join(' '),
      run: () => TPN_GUIDE.showMe(it), id: 'help:' + it.title.en })));
  }
  function orders() {
    const list = (typeof portalState !== 'undefined' && portalState.orders) || [];
    return list.map(o => ({ type: 'order', icon: '🧾', label: `${o.id} · ${o.customer || o.customerName || '—'}`,
      sub: [o.status, o.table ? 'Table ' + o.table : '', o.total != null ? '₱' + Number(o.total).toLocaleString('en-PH') : ''].filter(Boolean).join(' · '),
      hay: [o.id, o.customer, o.customerName, o.phone, o.items, o.table && 'table ' + o.table].join(' '),
      run: () => { if (canGo('orders')) go('orders'); if (window.openPaymentPanel && o.dbId) setTimeout(() => openPaymentPanel(o.dbId), 300); else flash(o.id); },
      id: 'order:' + o.id }));
  }
  function staff() {
    if (kind() !== 'admin') return [];
    const list = (typeof portalState !== 'undefined' && portalState.staff) || [];
    return list.map(s => ({ type: 'staff', icon: '👤', label: s.name, sub: [s.role, s.accountState].filter(Boolean).join(' · '),
      hay: [s.name, s.email, s.phone, s.role].join(' '),
      run: () => { const r = canGo('accounts') ? 'accounts' : canGo('staff-board') ? 'staff-board' : null; if (r) { go(r); flash(s.name); } },
      id: 'staff:' + s.id }));
  }
  function inquiries() {
    if (!canGo('inquiries')) return [];
    const list = (typeof portalState !== 'undefined' && portalState.inquiries) || [];
    return list.map(i => ({ type: 'inq', icon: '📩', label: `${i.name} · ${i.company && i.company !== '—' ? i.company : i.type}`,
      sub: [i.id, i.status, i.date].filter(Boolean).join(' · '),
      hay: [i.id, i.name, i.company, i.phone, i.email, i.notes, i.type].join(' '),
      run: () => { go('inquiries'); flash(i.id); }, id: 'inq:' + i.id }));
  }
  function dishes() {
    const cats = (typeof menuData !== 'undefined' && menuData) || [];
    const can = canGo('menu-manager');
    return cats.flatMap(c => (c.items || []).map(d => ({ type: 'dish', icon: d.emoji || '🍽️', label: d.name,
      sub: [lang() === 'tl' ? c.catNameTl : c.catName,
            d.price != null ? '₱' + d.price : d.pricePax ? Object.values(d.pricePax).map(v => '₱' + v).join(' / ') : ''].filter(Boolean).join(' · '),
      hay: [d.name, d.nameTl, d.desc, d.description, c.catName, c.catNameTl].join(' '),
      run: () => { if (can) { go('menu-manager'); flash(d.name); } else if (canGo('kds')) go('kds'); },
      id: 'dish:' + (d.id || d.name) })));
  }

  // After opening a page, find the row and make it blink once.
  function flash(text, tries = 0) {
    if (!text) return;
    setTimeout(() => {
      const main = document.getElementById(kind() === 'staff' ? 'staffMain' : 'portalMain'); if (!main) return;
      const hit = [...main.querySelectorAll('tr, .panel, .kanban-card, .order-card, .inq-card, .menu-row, li, div')]
        .filter(el => el.children.length < 40 && (el.textContent || '').includes(text))
        .sort((a, b) => a.textContent.length - b.textContent.length)[0];
      if (!hit) { if (tries < 6) flash(text, tries + 1); return; }
      const row = hit.closest('tr') || hit;
      row.scrollIntoView({ block: 'center', behavior: 'smooth' });
      row.classList.remove('tpn-flash'); void row.offsetWidth; row.classList.add('tpn-flash');
    }, tries ? 300 : 500);
  }

  /* ── Recent picks ───────────────────────────────────────────── */
  const recentIds = () => { try { return JSON.parse(localStorage.getItem(RECENT_KEY) || '[]'); } catch (e) { return []; } };
  const remember = (id) => { try { localStorage.setItem(RECENT_KEY, JSON.stringify([id, ...recentIds().filter(x => x !== id)].slice(0, 6))); } catch (e) {} };

  /* ── UI ─────────────────────────────────────────────────────── */
  const css = `
  .tpn-cmdk .cmdk-group{padding:10px 14px 4px;font-size:10.5px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:var(--brick,#8B1A0E);cursor:default}
  .tpn-cmdk li .cmdk-ic{width:24px;text-align:center;flex:0 0 auto;font-size:17px}
  .tpn-cmdk li .cmdk-txt{min-width:0;display:flex;flex-direction:column}
  .tpn-cmdk li .cmdk-lbl{white-space:nowrap;overflow:hidden;text-overflow:ellipsis;font-weight:600}
  .tpn-cmdk li .cmdk-sub{font-size:12px;color:var(--ink-faint,#9C7F65);white-space:nowrap;overflow:hidden;text-overflow:ellipsis}
  .tpn-cmdk li mark{background:color-mix(in srgb,var(--amber,#D4720A) 30%,transparent);color:inherit;border-radius:3px;padding:0 1px}
  .tpn-cmdk .cmdk-foot{padding:9px 16px;font-size:11.5px;color:var(--ink-faint,#9C7F65);border-top:1px solid var(--line-soft,rgba(139,26,14,.08))}
  .tpn-cmdk .cmdk-none{padding:24px 18px;text-align:center;color:var(--ink-muted,#6B4A35)}
  .tpn-cmdk-btn{cursor:pointer;font:500 13px 'DM Sans',system-ui,sans-serif;min-height:40px;box-sizing:border-box}
  .tpn-cmdk-btn:hover{border-color:var(--gold,#B8800F);color:var(--ink,#2B1810)}
  .portal-mobile-search{background:transparent;border:0;font-size:20px;width:40px;height:40px;cursor:pointer;color:inherit}
  @keyframes tpnFlash{0%,100%{box-shadow:none}30%{box-shadow:0 0 0 3px var(--amber,#D4720A)}}
  .tpn-flash{animation:tpnFlash 1.4s ease 2;border-radius:10px}
  @media (max-width:640px){.tpn-cmdk-overlay{padding:10px}.tpn-cmdk ul{max-height:70vh}}`;
  const st = document.createElement('style'); st.textContent = css; document.head.appendChild(st);

  let ov = null, sel = 0, rows = [];
  function open(prefill) {
    if (!kind()) return;
    if (ov) { ov.querySelector('input').focus(); return; }
    ov = document.createElement('div');
    ov.className = 'tpn-cmdk-overlay';
    ov.innerHTML = `<div class="tpn-cmdk" role="dialog" aria-modal="true" aria-label="${esc(tx(L.open))}">
      <input type="search" autocomplete="off" spellcheck="false" placeholder="${esc(tx(L.placeholder))}" aria-label="${esc(tx(L.placeholder))}" role="combobox" aria-expanded="true" aria-controls="cmdkList">
      <ul id="cmdkList" role="listbox"></ul>
      <div class="cmdk-foot">${esc(tx(L.hint))}</div></div>`;
    ov.setAttribute('translate', 'no');
    document.body.appendChild(ov);
    const input = ov.querySelector('input');
    ov.addEventListener('mousedown', (e) => { if (e.target === ov) close(); });
    input.addEventListener('input', () => { sel = 0; draw(input.value); });
    input.addEventListener('keydown', (e) => {
      if (e.key === 'ArrowDown') { e.preventDefault(); sel = Math.min(rows.length - 1, sel + 1); paintSel(); }
      else if (e.key === 'ArrowUp') { e.preventDefault(); sel = Math.max(0, sel - 1); paintSel(); }
      else if (e.key === 'Enter') { e.preventDefault(); pick(sel); }
      else if (e.key === 'Escape') { e.preventDefault(); close(); }
    });
    if (prefill) input.value = prefill;
    draw(input.value);
    setTimeout(() => input.focus(), 20);
  }
  function close() { if (ov) { ov.remove(); ov = null; } }

  function draw(raw) {
    const q = fold(raw).trim();
    const list = ov.querySelector('ul');
    let groups;
    if (!q) {
      const all = [...pages(), ...helpTopics(), ...orders(), ...staff(), ...inquiries(), ...dishes()];
      const recent = recentIds().map(id => all.find(x => x.id === id)).filter(Boolean);
      groups = recent.length ? [[L.recent, recent]] : [[L.pages, pages().slice(0, 8)]];
    } else {
      groups = [
        [L.pages, rank(pages(), q, 6)],
        [L.orders, rank(orders(), q, 5)],
        [L.staff, rank(staff(), q, 5)],
        [L.inquiries, rank(inquiries(), q, 4)],
        [L.dishes, rank(dishes(), q, 5)],
        [L.help, rank(helpTopics(), q, 4)]
      ];
      // A strong match anywhere hides the loose guesses everywhere.
      const best = Math.max(0, ...groups.flatMap(([, r]) => r.map(x => x.s)));
      const floor = best >= 70 ? 50 : 0;
      groups = groups.map(([g, r]) => [g, r.filter(x => x.s >= floor).map(x => x.x)]);
    }
    groups = groups.filter(([, items]) => items.length);
    rows = groups.flatMap(([, items]) => items);
    if (!rows.length) { list.innerHTML = `<li class="cmdk-none" role="presentation">${esc(tx(L.none))}</li>`; return; }
    const hl = (s) => { const t = esc(s); if (!q) return t; const i = fold(s).indexOf(q); return i < 0 ? t : esc(s.slice(0, i)) + '<mark>' + esc(s.slice(i, i + q.length)) + '</mark>' + esc(s.slice(i + q.length)); };
    let n = 0;
    list.innerHTML = groups.map(([g, items]) => `<li class="cmdk-group" role="presentation">${esc(tx(g))}</li>` + items.map(it => {
      const i = n++;
      return `<li role="option" id="cmdk-${i}" data-i="${i}" aria-selected="${i === sel}"><span class="cmdk-ic" aria-hidden="true">${esc(it.icon)}</span>
        <span class="cmdk-txt"><span class="cmdk-lbl">${hl(it.label)}</span>${it.sub ? `<span class="cmdk-sub">${esc(it.sub)}</span>` : ''}</span></li>`;
    }).join('')).join('');
    list.querySelectorAll('li[data-i]').forEach(li => {
      li.addEventListener('mousemove', () => { if (sel !== +li.dataset.i) { sel = +li.dataset.i; paintSel(); } });
      li.addEventListener('click', () => pick(+li.dataset.i));
    });
    paintSel();
  }
  function paintSel() {
    if (!ov) return;
    ov.querySelectorAll('li[data-i]').forEach(li => li.setAttribute('aria-selected', String(+li.dataset.i === sel)));
    const cur = ov.querySelector(`#cmdk-${sel}`);
    if (cur) { cur.scrollIntoView({ block: 'nearest' }); ov.querySelector('input').setAttribute('aria-activedescendant', cur.id); }
  }
  function pick(i) {
    const it = rows[i]; if (!it) return;
    remember(it.id); close();
    // Close the phone sidebar if it was open.
    if (typeof setPortalSidebar === 'function') setPortalSidebar(false);
    try { it.run(); } catch (e) { console.warn('search pick', e); }
  }

  /* ── Entry points ───────────────────────────────────────────── */
  function mountButtons() {
    // Top right of the page, on the same row as the hub tabs.
    document.querySelectorAll('.portal-topbar').forEach(top => {
      if (top.querySelector('.tpn-cmdk-btn')) return;
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'tpn-cmdk-btn';
      b.innerHTML = `<span aria-hidden="true" class="cmdk-ico"><svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/></svg></span><span class="cmdk-field-label"></span><kbd translate="no">${/Mac|iPhone|iPad/.test(navigator.platform) ? '⌘K' : 'Ctrl K'}</kbd>`;
      b.addEventListener('click', () => open());
      top.appendChild(b);
    });
    document.querySelectorAll('.portal-mobile-bar').forEach(bar => {
      if (bar.querySelector('.portal-mobile-search')) return;
      const spacer = bar.lastElementChild;
      const b = document.createElement('button');
      b.type = 'button'; b.className = 'portal-mobile-search'; b.innerHTML = '<svg viewBox="0 0 24 24" width="18" height="18" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" aria-hidden="true"><circle cx="11" cy="11" r="6.5"/><path d="m20 20-4.2-4.2"/></svg>';
      b.addEventListener('click', () => open());
      if (spacer && !spacer.children.length && spacer.tagName === 'DIV') spacer.replaceWith(b); else bar.appendChild(b);
    });
    paintLabels();
  }
  function paintLabels() {
    document.querySelectorAll('.tpn-cmdk-btn .cmdk-field-label').forEach(s => { s.textContent = tx(L.field); });
    document.querySelectorAll('.tpn-cmdk-btn, .portal-mobile-search').forEach(b => b.setAttribute('aria-label', tx(L.open)));
  }

  document.addEventListener('keydown', (e) => {
    if (!kind()) return;
    if ((e.ctrlKey || e.metaKey) && (e.key === 'k' || e.key === 'K')) { e.preventDefault(); ov ? close() : open(); return; }
    const typing = /input|textarea|select/i.test(document.activeElement?.tagName || '') || document.activeElement?.isContentEditable;
    // "/" is the Counter's own search key; leave it alone there.
    if (e.key === '/' && !typing && !ov && !document.getElementById('posSearch')) { e.preventDefault(); open(); }
  });
  const prevSetLang = window.setLang;
  if (typeof prevSetLang === 'function') window.setLang = function () { const out = prevSetLang.apply(this, arguments); paintLabels(); if (ov) { const v = ov.querySelector('input').value; close(); open(v); } return out; };
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', mountButtons); else mountButtons();

  window.TPN_SEARCH = { open, close };
})();
