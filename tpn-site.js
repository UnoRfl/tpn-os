/* ═══════════════════════════════════════════════════════════════
   TPN OS — Public website content
   Contact details, FAQs, testimonials and event packages come from the
   database (sql/30) so the restaurant can change them in the portal's
   Website tab without a deploy.

   Fallbacks, in order: live database → last good copy saved on this
   device → the text already written in index.html. A paused or slow
   server therefore never blanks the page; it shows the last known
   details instead.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const CACHE_KEY = 'tpn.site.v1';
  const esc = (v) => (window.TPN && TPN.esc) ? TPN.esc(v)
    : String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const lang = () => { try { return localStorage.getItem('tpn.lang') || 'en'; } catch (e) { return 'en'; } };
  const pick = (en, tl) => (lang() === 'tl' && tl) ? tl : en;

  const state = { settings: {}, faqs: [], testimonials: [], packages: [], loadedFrom: 'markup' };

  function readCache() {
    try { return JSON.parse(localStorage.getItem(CACHE_KEY) || 'null'); } catch (e) { return null; }
  }
  function writeCache() {
    try {
      localStorage.setItem(CACHE_KEY, JSON.stringify({
        at: Date.now(), settings: state.settings, faqs: state.faqs,
        testimonials: state.testimonials, packages: state.packages
      }));
    } catch (e) { /* storage full or private mode: the markup still works */ }
  }

  async function fetchAll() {
    if (!window.sb) throw new Error('offline');
    const wrap = (p) => (window.tpnRetry ? tpnRetry(() => p(), { tries: 2, timeout: 8000, what: 'website content' }) : p());
    const [s, f, t, p] = await Promise.allSettled([
      wrap(() => sb.from('site_settings').select('key,value').then(r => { if (r.error) throw r.error; return r.data; })),
      wrap(() => sb.from('faqs').select('id,category,question,question_tl,answer,answer_tl,sort').eq('is_published', true).order('sort').then(r => { if (r.error) throw r.error; return r.data; })),
      wrap(() => sb.rpc('public_testimonials').then(r => { if (r.error) throw r.error; return r.data; })),
      wrap(() => sb.from('event_packages').select('id,name,name_tl,description,from_price,price_unit,min_pax,inclusions,badge,sort').eq('is_published', true).order('sort').then(r => { if (r.error) throw r.error; return r.data; }))
    ]);
    let any = false;
    if (s.status === 'fulfilled') { state.settings = Object.fromEntries((s.value || []).map(r => [r.key, r.value])); any = true; }
    if (f.status === 'fulfilled') { state.faqs = f.value || []; any = true; }
    if (t.status === 'fulfilled') { state.testimonials = t.value || []; any = true; }
    if (p.status === 'fulfilled') { state.packages = p.value || []; any = true; }
    if (!any) throw new Error('no website content reachable');
    state.loadedFrom = 'live';
  }

  /* ── Apply ───────────────────────────────────────────────── */
  const S = (k) => state.settings[k];
  function applySettings() {
    // <x data-site="contact.phone"> gets text; data-site-href="tel|map|url"
    // turns it into the right link. Missing values hide [data-site-optional].
    document.querySelectorAll('[data-site]').forEach(el => {
      const v = S(el.dataset.site);
      if (v == null || v === '') {
        if (el.hasAttribute('data-site-optional')) el.closest('[data-site-wrap]')?.setAttribute('hidden', '');
        return;
      }
      el.closest('[data-site-wrap]')?.removeAttribute('hidden');
      if (el.dataset.siteHref === 'tel') { el.textContent = v; el.href = 'tel:' + String(v).replace(/[^0-9+]/g, '').replace(/^0/, '+63'); }
      else if (el.dataset.siteHref === 'url') { if (/^https:\/\//.test(v)) el.href = v; }
      else el.textContent = v;
    });
    // <x data-site-if="rewards.enabled" hidden> shows only while that switch is on.
    document.querySelectorAll('[data-site-if]').forEach(el => {
      const v = S(el.dataset.siteIf);
      el.hidden = !(v === true || v === 'true' || v === 'yes');
    });
    // Trust badges are claims; show a registration only once its number is on file.
    const trust = document.getElementById('concTrust');
    if (trust) {
      const items = [
        { num: '20+', label: 'Years in Business' },
        { num: 'BIR', label: 'Official Receipts' },
        S('legal.sec_no') ? { num: 'SEC', label: 'Reg. No. ' + S('legal.sec_no') } : null,
        S('legal.tin') ? { num: 'VAT', label: 'TIN ' + S('legal.tin') } : null,
        { num: '🅿️', label: 'Free Parking' }
      ].filter(Boolean);
      trust.innerHTML = items.map(i => `<div class="conc-trust-item"><div class="conc-trust-num">${esc(i.num)}</div><div class="conc-trust-label">${esc(i.label)}</div></div>`).join('');
    }
    const legal = document.getElementById('footerLegal');
    if (legal) {
      const parts = ['© ' + new Date().getFullYear() + ' ' + (S('legal.company') || 'Tyo Paeng Nyo')];
      if (S('legal.sec_no')) parts.push('SEC Reg. No. ' + S('legal.sec_no'));
      if (S('legal.tin')) parts.push('TIN ' + S('legal.tin'));
      legal.textContent = parts.join(' • ');
    }
  }

  function applyTestimonials() {
    const sec = document.getElementById('testimonialsSection');
    const grid = document.getElementById('testGrid');
    if (!sec || !grid) return;
    const rows = state.testimonials || [];
    // No real quotes yet → no section. Never placeholder reviews.
    if (!rows.length) { sec.hidden = true; return; }
    const srcLabel = { facebook: 'via Facebook', messenger: 'via Messenger', google: 'via Google', instagram: 'via Instagram', email: 'via email' };
    grid.innerHTML = rows.map(r => `
      <figure class="test-card">
        ${r.rating ? `<div class="test-stars" aria-label="${esc(r.rating)} out of 5 stars">${'★'.repeat(r.rating)}${'☆'.repeat(5 - r.rating)}</div>` : ''}
        <blockquote class="test-quote">“${esc(r.quote)}”</blockquote>
        <figcaption class="test-author">
          <div class="test-avatar" aria-hidden="true">${esc((r.author_display || '?').split(/\s+/).map(s => s[0]).join('').slice(0, 2).toUpperCase())}</div>
          <div><div class="test-name">${esc(r.author_display)}</div>
          <div class="test-meta">${esc([r.context, srcLabel[r.source]].filter(Boolean).join(' · '))}</div></div>
        </figcaption>
      </figure>`).join('');
    sec.hidden = false;
  }

  function applyPackages() {
    const sec = document.getElementById('eventPackages');
    const grid = document.getElementById('eventPackagesGrid');
    if (!sec || !grid) return;
    const rows = state.packages || [];
    if (!rows.length) { sec.hidden = true; return; }
    const unit = { per_pax: '/ pax', per_event: '/ event', per_tray: '/ tray' };
    grid.innerHTML = rows.map(p => `
      <article class="pkg-card glass">
        ${p.badge ? `<span class="pkg-badge">${esc(p.badge)}</span>` : ''}
        <h3 class="pkg-name">${esc(pick(p.name, p.name_tl))}</h3>
        <div class="pkg-price"><span class="pkg-from">from</span> ${esc(window.peso ? peso(p.from_price) : '₱' + p.from_price)} <span class="pkg-unit">${esc(unit[p.price_unit] || '')}</span></div>
        ${p.min_pax ? `<div class="pkg-min">Minimum ${esc(p.min_pax)} pax</div>` : ''}
        ${p.description ? `<p class="pkg-desc">${esc(p.description)}</p>` : ''}
        ${(p.inclusions || []).length ? `<ul class="pkg-inc">${p.inclusions.map(i => `<li>${esc(i)}</li>`).join('')}</ul>` : ''}
        <button type="button" class="btn-outline pkg-cta" data-pkg="${esc(p.name)}">Ask about this package</button>
      </article>`).join('');
    grid.querySelectorAll('[data-pkg]').forEach(b => b.addEventListener('click', () => window.pickEvent && pickEvent(b.dataset.pkg)));
    sec.hidden = false;
  }

  function applyFaqs() {
    const box = document.getElementById('faqList');
    if (!box) return;
    const rows = state.faqs || [];
    if (!rows.length) {
      box.innerHTML = `<p class="faq-empty">Questions? Call us at <a href="tel:+639998887817">${esc(S('contact.phone') || '0999 888 7817')}</a> or message us on Facebook.</p>`;
      return;
    }
    const cats = [...new Set(rows.map(r => r.category || 'General'))];
    box.innerHTML = cats.map(c => `
      <section class="faq-cat" aria-label="${esc(c)}">
        <h2 class="faq-cat-title">${esc(c)}</h2>
        ${rows.filter(r => (r.category || 'General') === c).map(r => `
          <details class="faq-item glass" data-faq-text="${esc((r.question + ' ' + r.answer + ' ' + (r.question_tl || '') + ' ' + (r.answer_tl || '')).toLowerCase())}">
            <summary>${esc(pick(r.question, r.question_tl))}</summary>
            <div class="faq-answer">${esc(pick(r.answer, r.answer_tl)).replace(/\n/g, '<br>')}</div>
          </details>`).join('')}
      </section>`).join('');
  }

  // FAQ search: hides questions that do not match, opens those that do.
  window.filterFaqs = function (q) {
    q = String(q || '').trim().toLowerCase();
    let shown = 0;
    document.querySelectorAll('#faqList .faq-item').forEach(d => {
      const hit = !q || d.dataset.faqText.includes(q);
      d.hidden = !hit; if (hit) shown++;
      if (q && hit) d.open = true;
    });
    document.querySelectorAll('#faqList .faq-cat').forEach(s => { s.hidden = !s.querySelector('.faq-item:not([hidden])'); });
    const none = document.getElementById('faqNone');
    if (none) none.hidden = shown > 0;
  };

  function applyAll() {
    try { applySettings(); } catch (e) { console.warn('site settings', e); }
    try { applyTestimonials(); } catch (e) { console.warn('testimonials', e); }
    try { applyPackages(); } catch (e) { console.warn('packages', e); }
    try { applyFaqs(); } catch (e) { console.warn('faqs', e); }
  }

  window.tpnSite = {
    state,
    async load() {
      const cached = readCache();
      if (cached) { Object.assign(state, cached, { loadedFrom: 'cache' }); applyAll(); }
      try { await fetchAll(); writeCache(); applyAll(); }
      catch (e) { if (!cached) applyAll(); console.info('website content: using', state.loadedFrom, '-', e.message || e); }
    },
    refresh: applyAll
  };

  if (!/tpn-(table-menu|kitchen-station|dine-in-floor)/i.test(location.pathname)) {
    if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', () => tpnSite.load());
    else tpnSite.load();
  }
})();
