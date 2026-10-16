/* ═══════════════════════════════════════════════════════════════
   Portal tab: Rewards (stamp cards, sql/34)
   Redeem: scan the customer's QR (camera) or type their 6-digit code.
   Settings: on/off, minimum order, stamps needed, the reward, expiry.
   Stamps themselves are never typed in here: paid orders add them.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const st = { settings: {}, lookup: null };
  let scanStream = null, scanTimer = null;

  const S = [
    { key: 'rewards.enabled', label: 'Stamp card is on', type: 'bool' },
    { key: 'rewards.min_order', label: 'Minimum paid order for a stamp (₱)', type: 'number' },
    { key: 'rewards.stamps_needed', label: 'Stamps needed for the reward', type: 'number' },
    { key: 'rewards.reward_text', label: 'The reward (what customers see)', type: 'text' },
    { key: 'rewards.card_days', label: 'Stamps expire after (days, 0 = never)', type: 'number' }
  ];

  async function render(main) {
    main.innerHTML = `<div class="portal-header"><div><h1>Rewards</h1>
        <div class="portal-header-sub">Stamp cards fill themselves: every paid order at or above the minimum adds one, refunds take it back. Here you give the reward.</div></div></div>
      <div class="pos-wrap" style="grid-template-columns:minmax(0,1fr) minmax(0,1fr)">
        <section class="panel" aria-labelledby="rdTitle">
          <h2 id="rdTitle" style="font-family:'Playfair Display',serif;font-size:20px;color:var(--ink)">Give a reward</h2>
          <p class="pref-row-hint">Ask the customer to open their card and tap “Show code to staff”.</p>
          ${can('rewards.redeem') ? `
          <div class="btn-row" style="display:flex;gap:8px;flex-wrap:wrap;margin:10px 0">
            <button class="btn-next" style="margin:0" onclick="rwScan()">📷 Scan their QR</button></div>
          <div id="rwScan" hidden><video id="rwVideo" playsinline muted style="width:100%;max-width:360px;border-radius:14px;background:#111"></video>
            <p class="pref-row-hint">Hold the customer's QR inside the frame.</p></div>
          <details style="margin-top:10px"><summary style="cursor:pointer;font-weight:600">No camera? Type it</summary>
            <label class="form-label" for="rwPhone">Customer's mobile</label><input class="form-input" id="rwPhone" type="tel" placeholder="0917 123 4567">
            <label class="form-label" for="rwCode">6-digit code on their screen</label><input class="form-input" id="rwCode" inputmode="numeric" maxlength="7" placeholder="123 456" autocomplete="off">
            <div class="modal-actions"><button class="btn-next" onclick="rwRedeemTyped()">Give reward</button></div></details>` : '<p class="tpn-muted">Your account cannot give rewards.</p>'}
          <div id="rwResult" aria-live="assertive"></div>
          <hr style="border:0;border-top:1px solid var(--line-soft);margin:16px 0">
          <label class="form-label" for="rwLook">Check a customer's stamps</label>
          <div style="display:flex;gap:8px;align-items:center"><input class="form-input" id="rwLook" type="tel" placeholder="Mobile number" style="flex:1;min-width:0"><button class="btn-ghost" style="flex:0 0 auto" onclick="rwLookup()">Look up</button></div>
          <div id="rwLookOut"></div>
        </section>
        <section class="panel" aria-labelledby="rsTitle"><h2 id="rsTitle" style="font-family:'Playfair Display',serif;font-size:20px;color:var(--ink)">Settings</h2>
          <div id="rwSet"><div class="tpn-muted">Loading…</div></div></section>
      </div>`;
    try {
      const { data, error } = await sb.from('site_settings').select('key,value').like('key', 'rewards.%');
      if (error) throw error;
      st.settings = Object.fromEntries(data.map(r => [r.key, r.value]));
    } catch (e) { document.getElementById('rwSet').innerHTML = loadErrorPanel('reward settings', e, "route('rewards',{refresh:true})"); return; }
    drawSettings();
  }

  function drawSettings() {
    const el = document.getElementById('rwSet'); const edit = can('rewards.manage');
    const v = (k) => { const x = st.settings[k]; return x == null ? '' : (typeof x === 'string' ? x : JSON.stringify(x)).replace(/^"|"$/g, ''); };
    el.innerHTML = S.map(s => s.type === 'bool'
      ? `<label style="display:flex;gap:10px;align-items:center;margin:8px 0"><input type="checkbox" id="rs-${E(s.key)}" ${['true', 'yes', '1'].includes(v(s.key)) ? 'checked' : ''} ${edit ? '' : 'disabled'} style="width:22px;height:22px"> ${E(s.label)}</label>`
      : `<label class="form-label" for="rs-${E(s.key)}">${E(s.label)}</label><input class="form-input" id="rs-${E(s.key)}" ${s.type === 'number' ? 'type="number" min="0" inputmode="numeric"' : ''} value="${E(v(s.key))}" ${edit ? '' : 'disabled'}>`).join('')
      + (edit ? `<div class="modal-actions"><button class="btn-next" onclick="rwSave()">Save settings</button></div>` : '')
      + `<p class="pref-row-hint" style="margin-top:10px">Customers' card page: <a href="tpn-rewards" target="_blank" rel="noopener">tpn-rewards ↗</a>. Counter customers claim it from the QR on their printed bill.</p>`;
  }
  window.rwSave = async function () {
    const rows = S.map(s => {
      const el = document.getElementById('rs-' + s.key);
      return { key: s.key, value: s.type === 'bool' ? el.checked : s.type === 'number' ? Math.max(0, +el.value || 0) : el.value.trim() };
    });
    if (rows.find(r => r.key === 'rewards.stamps_needed').value < 1) { toast('At least 1 stamp.'); return; }
    const { error } = await sb.from('site_settings').upsert(rows);
    if (error) { toast(error.message); return; }
    toast('Saved.');
  };

  function rwError(msg) {
    msg = String(msg || '');
    if (/code_expired_or_wrong/.test(msg)) return 'That code is wrong or expired. Ask them to show the new one.';
    if (/code_already_used/.test(msg)) return 'That code was already used.';
    if (/not_enough_stamps: (\d+) of (\d+)/.test(msg)) { const m = msg.match(/(\d+) of (\d+)/); return `Not enough stamps yet (${m[1]} of ${m[2]}).`; }
    if (/card_not_found/.test(msg)) return 'No card found.';
    if (/permission/.test(msg)) return 'Your account cannot give rewards.';
    return msg;
  }
  async function redeem(cardId, code) {
    const out = document.getElementById('rwResult');
    const { data, error } = await sb.rpc('redeem_stamp_reward', { p_card: cardId, p_code: String(code).replace(/\D/g, '') });
    out.innerHTML = error
      ? `<div class="pay-alert" role="alert">⚠️ ${E(rwError(error.message))}</div>`
      : `<div class="pay-alert" style="background:color-mix(in srgb,var(--success) 16%,transparent)">🎁 <strong>Give: ${E(data.reward)}</strong><div class="pref-row-hint">Stamps left on their card: ${E(data.stamps_left)}</div></div>`;
  }
  window.rwRedeemTyped = async function () {
    const phone = document.getElementById('rwPhone').value, code = document.getElementById('rwCode').value;
    const { data, error } = await sb.rpc('stamp_card_lookup', { p_phone: phone });
    if (error || !data) { document.getElementById('rwResult').innerHTML = `<div class="pay-alert">No card for that number.</div>`; return; }
    await redeem(data.card_id, code);
  };
  ['rwRedeemTyped'].forEach(n => window.guardAsync && guardAsync(n));

  window.rwScan = async function () {
    const box = document.getElementById('rwScan'), v = document.getElementById('rwVideo');
    if (!('BarcodeDetector' in window)) { toast('This browser cannot scan. Use “Type it” below.'); return; }
    try {
      scanStream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: 'environment' } });
    } catch (e) { toast('Camera blocked. Use “Type it” below.'); return; }
    box.hidden = false; v.srcObject = scanStream; await v.play();
    const det = new BarcodeDetector({ formats: ['qr_code'] });
    const stopScan = () => { clearInterval(scanTimer); if (scanStream) scanStream.getTracks().forEach(t => t.stop()); scanStream = null; box.hidden = true; };
    scanTimer = setInterval(async () => {
      if (!document.getElementById('rwVideo')) return stopScan();
      try {
        const codes = await det.detect(v);
        const m = codes.map(c => c.rawValue).map(r => /^TPNR:([0-9a-f-]{36}):(\d{6})$/i.exec(r)).find(Boolean);
        if (m) { stopScan(); await redeem(m[1], m[2]); }
      } catch (e) { /* keep scanning */ }
    }, 350);
    setTimeout(stopScan, 60000);
  };

  window.rwLookup = async function () {
    const out = document.getElementById('rwLookOut');
    const { data, error } = await sb.rpc('stamp_card_lookup', { p_phone: document.getElementById('rwLook').value });
    if (error) { out.innerHTML = `<p class="pay-alert">${E(rwError(error.message))}</p>`; return; }
    if (!data) { out.innerHTML = '<p class="tpn-muted">No card for that number yet. It starts with their first paid order.</p>'; return; }
    st.lookup = data;
    out.innerHTML = `<p style="margin:10px 0"><strong>${E(data.stamps)}</strong> of ${E(data.needed)} stamps · ${E(data.devices)} phone(s)
      ${can('rewards.manage') && data.devices ? ` · <button class="link-btn" onclick="rwRevoke('${JA(data.card_id)}')">sign out all phones</button>` : ''}</p>
      <ul class="pay-list">${(data.history || []).slice(0, 15).map(h => `<li class="pay-row" style="grid-template-columns:1fr auto"><div>${E({ stamp: '🍲 Stamp', reversal: '↩️ Removed', redeem: '🎁 Reward', adjust: 'Adjust' }[h.kind] || h.kind)} ${h.order_number ? '· ' + E(h.order_number) : ''}<div class="form-hint">${E(new Date(h.at).toLocaleString('en-PH'))}</div></div><div class="pay-row-amt">${h.delta > 0 ? '+' : ''}${E(h.delta)}</div></li>`).join('')}</ul>
      ${tpnExportButton('rwExport', 'Export history')}`;
  };
  window.rwRevoke = async (id) => {
    if (!await tpnConfirm('Sign the card out of every phone? The customer claims it again with a receipt. Use this if a phone was lost or shared.', { confirmText: 'Sign out phones' })) return;
    const { error } = await sb.rpc('revoke_stamp_devices', { p_card: id }); toast(error ? error.message : 'Done.'); rwLookup();
  };
  window.rwExport = (fmt) => tpnExport((st.lookup && st.lookup.history) || [], [
    { label: 'When', key: 'at', type: 'datetime' }, { label: 'Type', key: 'kind' }, { label: 'Change', key: 'delta', type: 'number' },
    { label: 'Order', key: 'order_number' }, { label: 'Note', key: 'note' }], { format: fmt, filename: 'tpn-stamp-card', sheet: 'Stamps' });

  TPN_MOD.register({ id: 'rewards', side: 'both', section: 'sec.money', icon: '🎁', label: 'Rewards', labelTl: 'Rewards',
    perm: 'rewards.redeem', render });
})();
