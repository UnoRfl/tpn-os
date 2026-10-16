/* ═══════════════════════════════════════════════════════════════
   TPN website v3 — home page + menu cards + motion (customer site only).

   Uses what index.html already has: menuData / menuLoadState (filled by
   loadMenuFromDB), T() / TPN_STRINGS / TPN_LANG for English ⇄ Tagalog,
   E() / JA() for escaping, addToCart() and navigate(). Nothing here talks
   to the database.

   Motion budget: everything per frame is transform / opacity on composited
   layers, plus two mask positions per title on screen. Offscreen spinners
   and titles are skipped, and the hero is only touched when the page scrolls.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';

  /* ---------- strings (merged into TPN_STRINGS on load) ---------- */
  const STR = {
    'v3.cta.order':     { en: 'Start your order', tl: 'Simulan ang order' },
    'v3.cta.best':      { en: 'See bestsellers', tl: 'Tingnan ang paborito' },
    'v3.logoAlt':       { en: 'Tyo Paeng Nyo logo', tl: 'Logo ng Tyo Paeng Nyo' },
    'v3.best.eyebrow':  { en: 'Everyone’s favorites', tl: 'Paborito ng lahat' },
    'v3.best.title':    { en: 'Our <i>Bestsellers</i>', tl: 'Mga <i>Paborito</i>' },
    'v3.best.sr':       { en: 'Our bestsellers', tl: 'Mga paborito' },
    'v3.badge.best':    { en: 'Bestseller', tl: 'Paborito' },
    'v3.badge.chef':    { en: 'Chef’s pick', tl: 'Pili ng chef' },
    'v3.badge.new':     { en: 'New', tl: 'Bago' },
    'v3.place.eyebrow': { en: 'Visit us', tl: 'Bisitahin kami' },
    'v3.place.title':   { en: 'Our <i>place</i>', tl: 'Ang aming <i>kainan</i>' },
    'v3.cap.dining':    { en: 'Dining room', tl: 'Silid-kainan' },
    'v3.cap.food':      { en: 'Fresh from the kitchen', tl: 'Bagong luto' },
    'v3.cap.kitchen':   { en: 'The kitchen', tl: 'Ang kusina' },
    'v3.cap.front':     { en: 'Our storefront', tl: 'Ang aming tindahan' },
    'v3.ph.interior':   { en: 'Interior photo', tl: 'Larawan ng loob' },
    'v3.ph.food':       { en: 'Food photo', tl: 'Larawan ng pagkain' },
    'v3.ph.kitchen':    { en: 'Kitchen photo', tl: 'Larawan ng kusina' },
    'v3.ph.front':      { en: 'Storefront photo', tl: 'Larawan ng harapan' },
    'v3.menu.eyebrow':  { en: 'Order online', tl: 'Umorder online' },
    'v3.menu.titleA':   { en: 'Our', tl: 'Ang aming' },
    'v3.menu.titleB':   { en: 'menu', tl: 'menu' },
    'v3.menu.search':   { en: 'Search sinigang, lechon, sisig…', tl: 'Hanapin ang sinigang, lechon, sisig…' },
    'v3.count':         { en: '{n} dishes', tl: '{n} putahe' },
    'v3.pax':           { en: 'pax', tl: 'katao' },
    'v3.single':        { en: 'Single', tl: 'Isahan' },
    'v3.add':           { en: 'Add {name}, {size}', tl: 'Idagdag ang {name}, {size}' },
    'v3.loading':       { en: 'Loading the menu…', tl: 'Nilo-load ang menu…' },
    'v3.empty.title':   { en: 'Nothing on the menu matches “{q}”.', tl: 'Walang tugma sa “{q}” sa menu.' },
    'v3.empty.body':    { en: 'Maybe a typo? Try sinigang, sisig or pancit.', tl: 'Baka may typo? Subukan ang sinigang, sisig o pancit.' },
    'v3.empty.clear':   { en: 'Clear search', tl: 'Burahin ang hinahanap' },
    'v3.est':           { en: 'Established 2003 · Las Piñas', tl: 'Itinatag noong 2003 · Las Piñas' },
    'v3.f.accept':      { en: 'We accept', tl: 'Tumatanggap kami ng' },
    'v3.f.contact':     { en: 'Contact', tl: 'Makipag-ugnayan' },
    'v3.f.hours':       { en: 'Hours', tl: 'Oras' },
    'v3.f.more':        { en: 'More', tl: 'Iba pa' },
    'v3.f.bank':        { en: 'Bank transfer (events & catering)', tl: 'Bank transfer (events at catering)' },
    'v3.f.cash':        { en: 'Cash', tl: 'Cash' },
    'v3.f.cards':       { en: 'Cards', tl: 'Card' },
    'v3.f.parking':     { en: 'Free parking', tl: 'Libreng parking' },
  };
  const tr = (k, vars) => {
    const row = (typeof TPN_STRINGS === 'object' && TPN_STRINGS[k]) || STR[k];
    let s = row ? (row[lang()] || row.en) : k;
    if (vars) for (const v in vars) s = s.split('{' + v + '}').join(vars[v]);
    return s;
  };
  const esc = v => (typeof E === 'function') ? E(v) : String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const jsq = v => (typeof JA === 'function') ? JA(v) : esc(v);
  const lang = () => (typeof TPN_LANG === 'string' ? TPN_LANG : 'en');

  /* ---------- dish photos (top-down cutouts), matched by dish name ---------- */
  const PHOTOS = {
    'buttered shrimp': 'buttered-shrimp',
    'adobong pusit with gata': 'pusit-gata',
    'pares': 'pares',
    'beef caldereta': 'beef-chili',
    'kare-kareng lechon kawali': 'sitaw-pork',
  };
  const photo = it => { const k = PHOTOS[(it.name || '').trim().toLowerCase()]; return k ? `assets/site/dishes/${k}.webp` : ''; };
  // sharpest source photos first, so the big bento card never gets a small one
  const PHOTO_RANK = ['buttered shrimp', 'adobong pusit with gata', 'kare-kareng lechon kawali', 'beef caldereta', 'pares'];
  const rank = it => { const i = PHOTO_RANK.indexOf((it.name || '').trim().toLowerCase()); return i < 0 ? 99 : i; };

  /* ---------- line icons per category, emoji from the menu as fallback ---------- */
  const G = {
    pan: '<circle cx="10" cy="12" r="7"/><path d="M17 12h5"/><circle cx="10" cy="12" r="2.4"/>',
    bowl: '<path d="M3 11h18a9 9 0 0 1-18 0z"/><path d="M8 7.5c0-1.6 1.2-1.6 1.2-3.5M12 7.5c0-1.6 1.2-1.6 1.2-3.5M16 7.5c0-1.6 1.2-1.6 1.2-3.5"/>',
    drum: '<ellipse cx="14.5" cy="9.5" rx="6" ry="4.6" transform="rotate(-45 14.5 9.5)"/><path d="M10.4 13.6L6 18"/><circle cx="4.6" cy="18" r="1.6"/><circle cx="6" cy="19.4" r="1.6"/>',
    shrimp: '<path d="M18.5 6.5C12 4 5 8 5 13.5 5 17 7.4 19 10.2 19c2 0 3.3-1.2 3.3-3"/><path d="M8.2 9.6l2 2.2M11 7.6l1.4 2.6M14.6 6.6l.4 3"/><path d="M13.5 16l3.2 3h-4.4"/><circle cx="17.2" cy="7.6" r=".6" fill="currentColor"/>',
    leaf: '<path d="M5 19C5 10 10 5 20 4c0 10-5 15-14 15z"/><path d="M5 19l9-9"/>',
    noodle: '<path d="M3 12h18a9 9 0 0 1-18 0z"/><path d="M14.5 3l-4 9M19.5 4.5L13 12"/><path d="M7 12c0-1.8 1.6-1.8 1.6-3.6"/>',
    cup: '<path d="M5 8h12v6a5 5 0 0 1-5 5h-2a5 5 0 0 1-5-5z"/><path d="M17 10h1.5a2.5 2.5 0 0 1 0 5H17"/><path d="M9 2.8c0 1.6 1.1 1.6 1.1 3.2M13 2.8c0 1.6 1.1 1.6 1.1 3.2"/>',
    cam: '<path d="M4 8h3l2-3h6l2 3h3v11H4z"/><circle cx="12" cy="13" r="3.5"/>',
  };
  const svg = k => `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${G[k]}</svg>`;
  const plus = '<svg width="14" height="14" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M12 5v14M5 12h14"/></svg>';
  function glyphFor(catName) {
    const c = (catName || '').toLowerCase();
    if (/silog|breakfast/.test(c)) return 'pan';
    if (/chicken|wing|thigh/.test(c)) return 'drum';
    if (/sea|fish|shrimp/.test(c)) return 'shrimp';
    if (/veg|gulay/.test(c)) return 'leaf';
    if (/merienda|pica|pancit|noodle/.test(c)) return 'noodle';
    if (/drink|inumin|coffee|beverage/.test(c)) return 'cup';
    if (/pork|beef|baboy|baka/.test(c)) return 'bowl';
    return '';
  }

  /* ---------- one card, used by the bento and by the menu page ---------- */
  let cardSeq = 0;
  function card(it, catName, opts = {}) {
    const name = (lang() === 'tl' && it.nameTl) ? it.nameTl : it.name;
    const img = photo(it), g = glyphFor(catName), i = cardSeq++;
    const sizes = it.pricePax
      ? Object.entries(it.pricePax).map(([pax, price]) => [pax, `${pax} ${tr('v3.pax')}`, price])
      : [['single', tr('v3.single'), it.price]];
    const badges = [
      it.best ? tr('v3.badge.best') : '', it.chefpick ? tr('v3.badge.chef') : '', it.isNew ? tr('v3.badge.new') : ''
    ].filter(Boolean).map(b => `<span class="v3-tag">${esc(b)}</span>`).join('');
    const lead = opts.feature
      ? '<span></span>'
      : img ? `<span class="v3-thumb"><img data-spin="${i % 2 ? -10 : 10}" src="${img}" alt="${esc(name)}" loading="lazy" decoding="async"></span>`
            : `<span class="v3-glyph">${g ? svg(g) : esc(it.emoji || '')}</span>`;
    const stage = opts.feature
      ? `<div class="v3-stage">${img ? `<div class="spin"><img data-spin="7" src="${img}" alt="${esc(name)}" decoding="async"></div>` : `<div class="big-emoji">${esc(it.emoji || '')}</div>`}</div>`
      : '';
    return `<article class="v3-shell v3-card v3-reveal" style="--i:${i % 6}"><div class="v3-core">
      ${stage}
      <div class="top">${lead}<span class="v3-tags">${badges}</span></div>
      <h4>${esc(name)}</h4>${it.desc ? `<p class="d">${esc(it.desc)}</p>` : ''}
      <div class="v3-sizes">${sizes.map(([key, label, price]) => `
        <div class="v3-size">${esc(label)}<span class="p">₱${esc(price)}</span>
          <button class="v3-add" onclick="addToCart('${jsq(it.id)}','${jsq(key)}');tpnHome.pop(this)" aria-label="${esc(tr('v3.add', { name, size: label }))}">${plus}</button></div>`).join('')}
      </div></div></article>`;
  }

  /* ---------- menu page: replaces the old card markup, same data + filters ---------- */
  function renderMenuGrid(sec, data, activeCategory, q) {
    let html = '';
    data.forEach(cat => {
      if (activeCategory !== 'all' && activeCategory !== cat.cat) return;
      const items = cat.items.filter(it => !q || (it.name + ' ' + (it.nameTl || '') + ' ' + (it.desc || '')).toLowerCase().includes(q));
      if (!items.length) return;
      const title = (lang() === 'tl' && cat.catNameTl) ? cat.catNameTl : cat.catName;
      html += `<div class="v3-cat"><h3>${esc(title)}<small>${esc(tr('v3.count', { n: items.length }))}</small></h3>
        <div class="v3-grid">${items.map(it => card(it, cat.catName)).join('')}</div></div>`;
    });
    return html;
  }
  function emptySearch(qRaw) {
    return `<div class="empty-state">
      <div class="empty-state-icon">🔍</div>
      <div class="empty-state-title">${esc(tr('v3.empty.title', { q: qRaw }))}</div>
      <div class="empty-state-body">${esc(tr('v3.empty.body'))}</div>
      <button class="empty-state-cta" onclick="document.getElementById('menuSearch').value='';setCategory('all')">${esc(tr('v3.empty.clear'))} →</button>
    </div>`;
  }

  /* ---------- home: bestsellers bento from the live menu ---------- */
  function renderBestsellers() {
    const el = document.getElementById('v3Bento');
    if (!el) return;
    const state = typeof menuLoadState === 'string' ? menuLoadState : 'loading';
    const data = (typeof menuData !== 'undefined' && Array.isArray(menuData)) ? menuData : [];
    const all = data.flatMap(c => c.items.map(it => ({ it, cat: c.catName })));
    if (!all.length) {
      el.innerHTML = state === 'error'
        ? `<div class="v3-best-state" role="alert">${esc(T('menu.unavailable'))} <button class="empty-state-cta" onclick="retryMenuLoad()">${esc(T('menu.retry'))}</button></div>`
        : `<div class="v3-best-state" aria-busy="true">${esc(tr('v3.loading'))}</div>`;
      return;
    }
    // dishes with a photo first, then the rest of the bestsellers
    const best = all.filter(x => x.it.best);
    const pool = (best.length ? best : all).slice().sort((a, b) => rank(a.it) - rank(b.it));
    el.innerHTML = pool.slice(0, 5).map((x, i) => card(x.it, x.cat, { feature: i === 0 })).join('');
    afterRender(el);
  }

  /* ---------- photo panels ---------- */
  function renderPhotos() {
    document.querySelectorAll('.v3-photo').forEach(f => {
      const src = f.dataset.src;
      f.classList.toggle('empty', !src);
      if (src) f.style.setProperty('--img', `url('${src.replace(/'/g, '%27')}')`);
      let ph = f.querySelector('.ph');
      if (!ph) { ph = document.createElement('div'); ph.className = 'ph'; f.insertBefore(ph, f.querySelector('figcaption')); }
      ph.innerHTML = `${svg('cam')}<span>${esc(tr(f.dataset.ph))}</span>`;
    });
  }

  /* ---------- bleed titles ---------- */
  const bleeds = [];
  function buildBleeds() {
    document.querySelectorAll('.v3-bleed').forEach((el, idx) => {
      let b = bleeds.find(x => x.el === el);
      if (!b) { b = { el, seed: idx * 1.7, cx: null, cy: null, tx: null, ty: null, vis: false }; bleeds.push(b); onScreen.observe(el); }
      const src = el.dataset.i18nLines ? tr(el.dataset.i18nLines) : el.dataset.lines;
      // the HTML here is our own (<i> tags in the strings above), never data from the DB
      const lines = src.split('|').map(l => `<span class="t">${l}</span>`).join('');
      el.innerHTML = ['solid', 'engrave'].map(k => `<div class="layer ${k}" aria-hidden="true">${lines}</div>`).join('');
      b.eng = el.querySelector('.engrave');
    });
    alignBleeds();
  }
  function alignBleeds() {
    for (const b of bleeds) {
      const sec = b.el.closest('.v3-tex') || b.el.parentElement;
      const sr = sec.getBoundingClientRect(), r = b.el.getBoundingClientRect();
      if (!r.width) continue;                              // page not visible yet
      b.eng.style.setProperty('--ox', (sr.left - r.left) + 'px');
      b.eng.style.setProperty('--oy', (sr.top - r.top) + 'px');
      b.w = r.width; b.h = r.height;
      const lh = b.el.querySelector('.solid .t').getBoundingClientRect().height;
      b.el.style.setProperty('--r1', (lh * .6).toFixed(0) + 'px');
      b.el.style.setProperty('--r2', (lh * .42).toFixed(0) + 'px');
    }
  }
  addEventListener('pointermove', e => {
    for (const b of bleeds) {
      if (!b.vis) continue;
      const r = b.el.getBoundingClientRect(), pad = 220;
      const inside = e.clientX > r.left - pad && e.clientX < r.right + pad && e.clientY > r.top - pad && e.clientY < r.bottom + pad;
      b.tx = inside ? e.clientX - r.left : null; b.ty = inside ? e.clientY - r.top : null;
    }
  }, { passive: true });

  /* ---------- visibility, reveal, spinners ---------- */
  const reduce = matchMedia('(prefers-reduced-motion: reduce)').matches;
  const spinners = new Map();
  const onScreen = new IntersectionObserver(es => es.forEach(e => {
    const s = spinners.get(e.target) || bleeds.find(b => b.el === e.target);
    if (s) s.vis = e.isIntersecting;
  }), { rootMargin: '120px' });
  const revealer = new IntersectionObserver(es => es.forEach(e => {
    if (e.isIntersecting) { e.target.classList.add('in'); revealer.unobserve(e.target); }
  }), { rootMargin: '0px 0px -8% 0px' });
  function afterRender(root) {
    for (const el of spinners.keys()) if (!el.isConnected) { onScreen.unobserve(el); spinners.delete(el); }
    root.querySelectorAll('[data-spin]').forEach(el => {
      if (!spinners.has(el)) { spinners.set(el, { base: +el.dataset.spin, a: Math.random() * 360, vis: false }); onScreen.observe(el); }
    });
    root.querySelectorAll('.v3-reveal:not(.in)').forEach(el => revealer.observe(el));
  }

  /* ---------- motion loop ---------- */
  let hero, hPhoto, hBlur, hVig, hInner, lastY = -1, prevY = 0, boost = 0, kick = 0, last = performance.now();
  function heroScroll(y) {
    if (!hero || !hero.offsetHeight) return;
    const hp = Math.min(1, Math.max(0, y / hero.offsetHeight));
    const sc = `scale(${(1 - hp * .03).toFixed(4)})`;
    hPhoto.style.transform = sc; hBlur.style.transform = sc;
    hBlur.style.opacity = hp.toFixed(3);
    hVig.style.opacity = (.55 + hp * .45).toFixed(3);
    hInner.style.transform = `translate3d(0, ${(-hp * 90).toFixed(1)}px, 0)`;
    hInner.style.opacity = Math.max(0, 1 - hp * 1.4).toFixed(3);
  }
  function frame(now) {
    const dt = Math.min(.05, (now - last) / 1000); last = now;
    if (!document.hidden) {
      const y = scrollY, v = Math.abs(y - prevY) / Math.max(dt, .001); prevY = y;
      const target = Math.min(5, v / 450) + kick;
      boost += (target - boost) * Math.min(1, dt * (target > boost ? 6 : 1.4));
      kick *= Math.pow(.03, dt);
      const mult = (reduce ? .3 : 1) * (1 + boost), tt = now / 1000;

      if (y !== lastY && hero && hero.offsetParent !== null && y < hero.offsetHeight * 1.2) { heroScroll(y); lastY = y; }

      for (const [el, s] of spinners) {
        if (!s.vis) continue;
        s.a = (s.a + s.base * mult * dt) % 360;
        el.style.transform = `rotate(${s.a.toFixed(2)}deg)`;
      }
      for (const b of bleeds) {
        if (!b.vis || !b.w) continue;
        const wx = b.w * (.5 + .46 * Math.sin(tt * .32 + b.seed)), wy = b.h * (.5 + .38 * Math.sin(tt * .51 + b.seed * 2));
        const gx = b.tx ?? b.w * (.5 + .46 * Math.sin(tt * .23 + b.seed + 2.4)), gy = b.ty ?? b.h * (.5 + .4 * Math.cos(tt * .37 + b.seed));
        b.cx = b.cx == null ? gx : b.cx + (gx - b.cx) * Math.min(1, dt * 4);
        b.cy = b.cy == null ? gy : b.cy + (gy - b.cy) * Math.min(1, dt * 4);
        const st = b.eng.style;   // only the engraved layer restyles
        st.setProperty('--h1x', b.cx.toFixed(1) + 'px'); st.setProperty('--h1y', b.cy.toFixed(1) + 'px');
        st.setProperty('--h2x', wx.toFixed(1) + 'px'); st.setProperty('--h2y', wy.toFixed(1) + 'px');
      }
    }
    requestAnimationFrame(frame);
  }

  /* ---------- language: everything this file draws ---------- */
  function relang() {
    buildBleeds(); renderBestsellers(); renderPhotos();
    const logo = document.querySelector('.nav-badge'); if (logo) logo.alt = tr('v3.logoAlt');
  }

  window.tpnHome = {
    card, renderMenuGrid, emptySearch, renderBestsellers, relang, afterRender,
    pop(btn) { btn.classList.remove('pop'); void btn.offsetWidth; btn.classList.add('pop'); kick += 3; },
    // called by navigate(): titles measure 0×0 while their page is hidden
    shown() { requestAnimationFrame(() => { alignBleeds(); lastY = -1; }); },
    scrollToBest() { document.getElementById('v3Best')?.scrollIntoView({ behavior: 'smooth', block: 'start' }); },
  };

  document.addEventListener('DOMContentLoaded', () => {
    if (typeof TPN_STRINGS === 'object') Object.assign(TPN_STRINGS, STR);
    hero = document.querySelector('.v3-hero');
    if (hero) { hPhoto = hero.querySelector('.photo'); hBlur = hero.querySelector('.photo-blur'); hVig = hero.querySelector('.vig'); hInner = hero.querySelector('.inner'); }
    relang();
    afterRender(document);
    heroScroll(scrollY);
    addEventListener('resize', alignBleeds, { passive: true });
    if (document.fonts) document.fonts.ready.then(alignBleeds);
    requestAnimationFrame(frame);
  });
})();
