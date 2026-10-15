/* ═══════════════════════════════════════════════════════════════
   Verified clock-in (sql/33)
   Staff: live camera, full-body photo with a framing guide, then clock
          in. The server records the time, the network and whether it is
          the restaurant's. No camera → still clocks in, flagged for a
          manager to check. Never a dead end.
   Managers: "Clock-in review" — photo, network, uniform checklist,
          approve / flag, trust a new restaurant IP, old photos cleaned up.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const can = (k) => !!(window.TPN && TPN.can && TPN.can(k));
  const PRIVACY_KEY = 'tpn.clockin.privacyAck.v1';
  let stream = null, facing = 'user', shot = null;

  const t = (en, tl) => { try { return (localStorage.getItem('tpn.lang') === 'tl' && tl) ? tl : en; } catch (e) { return en; } };

  function stop() { if (stream) { stream.getTracks().forEach(tr => tr.stop()); stream = null; } }

  window.openClockinCamera = async function () {
    let ack = false; try { ack = localStorage.getItem(PRIVACY_KEY) === '1'; } catch (e) {}
    if (!ack) {
      const ok = await tpnConfirm(t(
        'To clock in, we take one full-body photo to check you are at work in complete uniform.\n\n• Only managers can see it.\n• It is deleted automatically after 60 days.\n• It is used only for attendance and uniform checks.\n\n(Data Privacy Act of 2012)',
        'Para mag-clock in, kukuha kami ng isang full-body na litrato para matiyak na nasa trabaho ka at kumpleto ang uniporme.\n\n• Mga manager lang ang makakakita.\n• Awtomatikong buburahin pagkalipas ng 60 araw.\n• Para lang sa attendance at uniform check.\n\n(Data Privacy Act of 2012)'),
        { title: t('Before your first clock-in photo', 'Bago ang unang clock-in photo'), confirmText: t('I understand', 'Naiintindihan ko'), cancelText: t('Not now', 'Hindi muna') });
      if (!ok) return;
      try { localStorage.setItem(PRIVACY_KEY, '1'); } catch (e) {}
    }
    showModal(`<div class="modal-title">🕐 ${E(t('Clock in', 'Mag-clock in'))}</div>
      <div class="modal-content ci-wrap">
        <div id="ciNet" class="ci-net" aria-live="polite"><span class="tpn-pill warn">${E(t('Checking network…', 'Sinusuri ang network…'))}</span></div>
        <p class="ci-help">${E(t('Stand back so your whole body fits inside the outline — head to shoes.', 'Lumayo nang kaunti para buong katawan ay pasok sa guhit — ulo hanggang sapatos.'))}</p>
        <div class="ci-stage" id="ciStage">
          <video id="ciVideo" playsinline autoplay muted aria-label="${E(t('Camera preview', 'Camera'))}"></video>
          <svg class="ci-guide" viewBox="0 0 100 160" aria-hidden="true"><ellipse cx="50" cy="18" rx="10" ry="12"/><path d="M30 40 Q50 30 70 40 L76 92 L66 94 L64 150 L54 150 L50 100 L46 150 L36 150 L34 94 L24 92 Z"/></svg>
          <canvas id="ciCanvas" hidden></canvas>
          <img id="ciPreview" alt="${E(t('Your photo', 'Ang litrato mo'))}" hidden>
        </div>
        <div class="ci-err" id="ciErr" role="alert"></div>
      </div>
      <div class="modal-actions ci-actions" id="ciActions">
        <button class="btn-ghost" onclick="ciNoCamera()">${E(t('Camera not working', 'Ayaw gumana ng camera'))}</button>
        <button class="btn-ghost" onclick="ciFlip()" aria-label="${E(t('Switch camera', 'Palitan ang camera'))}">🔄</button>
        <button class="btn-next" id="ciShoot" onclick="ciShoot()">📸 ${E(t('Take photo', 'Kunan'))}</button>
      </div>`);
    // Closing the dialog any way must release the camera.
    const ov = document.getElementById('modalOverlay');
    const obs = new MutationObserver(() => { if (!ov.classList.contains('open')) { stop(); obs.disconnect(); } });
    obs.observe(ov, { attributes: true, attributeFilter: ['class'] });
    TPN.myNetworkStatus().then(n => {
      const el = document.getElementById('ciNet'); if (!el) return;
      el.innerHTML = !n ? `<span class="tpn-pill warn">${E(t('Network check unavailable', 'Hindi ma-check ang network'))}</span>`
        : n.trusted ? `<span class="tpn-pill ok">✓ ${E(t('Restaurant network', 'Network ng restawran'))}</span>`
        : `<span class="tpn-pill warn">${E(t('Not on the restaurant Wi-Fi — your manager will confirm this clock-in', 'Wala sa Wi-Fi ng restawran — kukumpirmahin ng manager'))}</span>`;
    });
    await startCam();
  };

  async function startCam() {
    stop();
    const err = document.getElementById('ciErr');
    if (!navigator.mediaDevices || !navigator.mediaDevices.getUserMedia) { err.textContent = t('This phone or browser has no camera access. Use “Camera not working”.', 'Walang camera access ang phone/browser. Pindutin ang “Ayaw gumana ng camera”.'); return; }
    try {
      stream = await navigator.mediaDevices.getUserMedia({ video: { facingMode: facing, width: { ideal: 1280 }, height: { ideal: 1280 } }, audio: false });
      const v = document.getElementById('ciVideo'); if (!v) { stop(); return; }
      v.srcObject = stream; v.hidden = false;
      v.classList.toggle('mirror', facing === 'user');
      err.textContent = '';
    } catch (e) {
      err.textContent = /NotAllowed|Permission/i.test(e.name + e.message)
        ? t('Camera permission was blocked. Allow the camera in your browser settings, or use “Camera not working”.', 'Naka-block ang camera. Payagan ito sa browser settings, o pindutin ang “Ayaw gumana ng camera”.')
        : t('Could not start the camera: ', 'Hindi mabuksan ang camera: ') + (e.message || e.name);
    }
  }
  window.ciFlip = () => { facing = facing === 'user' ? 'environment' : 'user'; startCam(); };

  // Downscale to ≤960px and step JPEG quality down until ≤ ~200 KB.
  async function compress(canvas) {
    for (const q of [0.82, 0.72, 0.62, 0.5, 0.4]) {
      const b = await new Promise(r => canvas.toBlob(r, 'image/jpeg', q));
      if (b && b.size <= 210 * 1024) return b;
      if (q === 0.4) return b;
    }
  }
  window.ciShoot = async function () {
    const v = document.getElementById('ciVideo'), c = document.getElementById('ciCanvas');
    if (!stream || !v.videoWidth) { document.getElementById('ciErr').textContent = t('The camera is not ready yet.', 'Hindi pa handa ang camera.'); return; }
    const scale = Math.min(1, 960 / Math.max(v.videoWidth, v.videoHeight));
    c.width = Math.round(v.videoWidth * scale); c.height = Math.round(v.videoHeight * scale);
    const g = c.getContext('2d');
    if (facing === 'user') { g.translate(c.width, 0); g.scale(-1, 1); }
    g.drawImage(v, 0, 0, c.width, c.height);
    g.setTransform(1, 0, 0, 1, 0, 0);
    // Burn in the device time; the server keeps its own time anyway.
    const stamp = new Date().toLocaleString('en-PH', { dateStyle: 'medium', timeStyle: 'short' }) + ' · ' + ((window.tpnWho && tpnWho()) || {}).name;
    g.fillStyle = 'rgba(0,0,0,.55)'; g.fillRect(0, c.height - 30, c.width, 30);
    g.fillStyle = '#fff'; g.font = '16px system-ui, sans-serif'; g.fillText(stamp, 10, c.height - 10);
    shot = await compress(c);
    stop();
    const img = document.getElementById('ciPreview');
    img.src = URL.createObjectURL(shot); img.hidden = false; v.hidden = true;
    document.getElementById('ciActions').innerHTML = `
      <button class="btn-ghost" onclick="ciRetake()">${E(t('Retake', 'Ulitin'))}</button>
      <button class="btn-next" onclick="ciSubmit(true)">✓ ${E(t('Use photo & clock in', 'Gamitin at mag-clock in'))}</button>`;
  };
  window.ciRetake = () => { document.getElementById('ciPreview').hidden = true; window.openClockinCamera(); };
  window.ciNoCamera = async () => {
    const ok = await tpnConfirm(t('Clock in without a photo? Your manager will check this clock-in.', 'Mag-clock in nang walang litrato? Susuriin ito ng manager.'), { confirmText: t('Clock in', 'Mag-clock in') });
    if (ok) { stop(); ciSubmit(false); }
  };

  window.ciSubmit = async function (withPhoto) {
    const err = document.getElementById('ciErr');
    let r;
    try { r = await TPN.clockIn(null, { expectPhoto: withPhoto && !!shot }); }
    catch (e) { if (err) err.textContent = e.message; else toast(e.message); return; }
    if (withPhoto && shot && r && r.upload_path) {
      let done = null, last;
      for (let i = 0; i < 3 && !done; i++) {
        try { done = await TPN.attachClockinPhoto(r.attendance_id, r.upload_path, shot); }
        catch (e) { last = e; await new Promise(res => setTimeout(res, 1500 * (i + 1))); }
      }
      closeModal();
      if (done) toast(done.status === 'verified' ? t('✓ Clocked in — verified', '✓ Naka-clock in — verified') : t('✓ Clocked in — your manager will confirm it', '✓ Naka-clock in — kukumpirmahin ng manager'));
      else toast(t('✓ Clocked in. The photo did not upload, so your manager will check this one.', '✓ Naka-clock in. Hindi na-upload ang litrato kaya susuriin ng manager.'));
    } else {
      closeModal();
      toast(t('✓ Clocked in — your manager will confirm it', '✓ Naka-clock in — kukumpirmahin ng manager'));
    }
    shot = null;
    if (typeof routeStaff === 'function' && document.getElementById('portal-staff')?.classList.contains('active')) routeStaff('staff-home');
  };
  ['ciSubmit'].forEach(n => window.guardAsync && guardAsync(n));

  /* ── Manager review ──────────────────────────────────────── */
  const rv = { rows: [], all: false, checklist: [], nets: [], pending: 0 };
  const REASON = { untrusted_network: 'Not on restaurant Wi-Fi', network_unknown: 'Network unknown', no_photo: 'No photo', photo_pending: 'Photo did not upload' };

  async function render(main) {
    main.innerHTML = `<div class="portal-header"><div><h1>Clock-in review</h1>
        <div class="portal-header-sub">Clock-ins that need a look: off the restaurant Wi-Fi, no photo, or uniform to check. Verified ones only need a glance.</div></div>
        <div style="display:flex;gap:8px;flex-wrap:wrap">
          <button class="btn-ghost" onclick="ciTrustHere()">📶 Trust this network</button>
          <label style="display:flex;gap:6px;align-items:center;font-size:13px"><input type="checkbox" ${rv.all ? 'checked' : ''} onchange="ciShowAll(this.checked)"> Show reviewed</label>
          ${tpnExportButton('ciExport')}</div></div>
      <div id="ciNets"></div><div id="ciBody"><div class="panel tpn-muted" style="text-align:center;padding:24px">Loading…</div></div>`;
    try {
      const [q, set, nets] = await Promise.all([
        sb.rpc('clockin_review_queue', { p_include_done: rv.all, p_days: 14 }),
        sb.from('site_settings').select('value').eq('key', 'hr.uniform_checklist').maybeSingle(),
        sb.from('trusted_networks').select('*').order('created_at')
      ]);
      if (q.error) throw q.error;
      rv.rows = q.data || []; rv.checklist = (set.data && set.data.value) || ['Uniform shirt', 'Apron', 'Cap or hairnet', 'Closed shoes'];
      rv.nets = nets.data || [];
      rv.pending = rv.rows.filter(r => r.verify_status === 'needs_approval').length;
    } catch (e) { document.getElementById('ciBody').innerHTML = loadErrorPanel('clock-ins', e, "route('clockin-review',{refresh:true})"); return; }
    drawNets(); await draw();
    purgeOld();     // retention: quietly delete photos past the window
  }
  function drawNets() {
    const el = document.getElementById('ciNets'); if (!el) return;
    el.innerHTML = `<details class="panel" style="margin-bottom:12px"><summary style="cursor:pointer;font-weight:700">📶 Trusted networks (${rv.nets.filter(n => n.is_active).length})</summary>
      ${rv.nets.length ? `<ul class="pay-list">${rv.nets.map(n => `<li class="pay-row"><div>${E(n.label)} <span class="form-hint">${E(String(n.network))}</span>
        <div class="form-hint">last used ${n.last_seen_at ? E(new Date(n.last_seen_at).toLocaleString('en-PH')) : 'never'}</div></div><div></div>
        <div class="pay-row-act"><button class="table-btn" onclick="ciNetToggle('${JA(n.id)}',${!n.is_active})">${n.is_active ? 'Stop trusting' : 'Trust again'}</button></div></li>`).join('')}</ul>`
        : '<p class="tpn-muted">None yet. Tap “Trust this network” while you are at the restaurant, on its Wi-Fi.</p>'}</details>`;
  }
  async function signed(path) {
    try { const { data } = await sb.storage.from('attendance-photos').createSignedUrl(path, 300); return data && data.signedUrl; } catch (e) { return null; }
  }
  async function draw() {
    const body = document.getElementById('ciBody'); if (!body) return;
    if (!rv.rows.length) { body.innerHTML = `<div class="panel tpn-empty" style="text-align:center;padding:32px;color:var(--ink-muted)">✅ Nothing waiting. Everyone who clocked in recently is verified.</div>`; return; }
    const urls = await Promise.all(rv.rows.map(r => r.photo_path && !r.photo_purged ? signed(r.photo_path) : null));
    body.innerHTML = `<div class="ci-grid">${rv.rows.map((r, i) => `
      <article class="panel ci-card" aria-label="${E(r.staff_name)} clock-in">
        <div class="ci-photo">${urls[i] ? `<a href="${E(urls[i])}" target="_blank" rel="noopener"><img src="${E(urls[i])}" alt="Clock-in photo of ${E(r.staff_name)}" loading="lazy"></a>` : `<div class="ci-nophoto">${r.photo_purged ? 'Photo deleted (retention)' : 'No photo'}</div>`}</div>
        <div class="ci-meta"><strong>${E(r.staff_name)}</strong> <span class="form-hint">${E(r.role)}</span>
          <div class="form-hint">${E(new Date(r.clock_in_at).toLocaleString('en-PH', { weekday: 'short', hour: 'numeric', minute: '2-digit', month: 'short', day: 'numeric' }))}</div>
          <div style="margin:6px 0;display:flex;gap:4px;flex-wrap:wrap">
            ${r.network_trusted ? '<span class="tpn-pill ok">Restaurant Wi-Fi</span>' : `<span class="tpn-pill warn">IP ${E(r.ip || '?')}</span>`}
            ${(r.verify_reasons || []).filter(x => x !== 'untrusted_network').map(x => `<span class="tpn-pill bad">${E(REASON[x] || x)}</span>`).join('')}
            ${r.verify_status !== 'needs_approval' ? `<span class="tpn-pill ${r.verify_status === 'flagged' ? 'bad' : 'ok'}">${E(r.verify_status)}${r.reviewed_by_name ? ' by ' + E(r.reviewed_by_name) : ''}</span>` : ''}
          </div>
          ${r.verify_status === 'needs_approval' ? `
          <fieldset class="ci-check"><legend class="form-label">Uniform</legend>
            ${rv.checklist.map(c => `<label><input type="checkbox" data-ci="${E(r.id)}" value="${E(c)}"> ${E(c)}</label>`).join('')}</fieldset>
          <div class="ci-btns">
            <button class="btn-next" style="margin:0" onclick="ciDecide('${JA(r.id)}',true,false)">Approve</button>
            ${!r.network_trusted && r.ip ? `<button class="btn-ghost" onclick="ciDecide('${JA(r.id)}',true,true)" title="Approve and trust this IP from now on">Approve + trust IP</button>` : ''}
            <button class="btn-ghost" onclick="ciDecide('${JA(r.id)}',false,false)">Flag</button>
          </div>` : (r.review_note ? `<div class="form-hint">“${E(r.review_note)}”</div>` : '')}
        </div></article>`).join('')}</div>`;
  }
  window.ciDecide = async function (id, approve, trust) {
    const checks = {}; document.querySelectorAll(`[data-ci="${CSS.escape(id)}"]`).forEach(c => checks[c.value] = c.checked);
    let note = null;
    if (!approve) {
      note = await tpnAsk('What is wrong? The staff member will see this.', { chips: ['Incomplete uniform', 'Not at the restaurant', 'Photo is not of you', 'Photo unclear'], input: { placeholder: 'Reason' }, confirmText: 'Flag', danger: true });
      if (note === null) return;
    } else if (Object.keys(checks).length && Object.values(checks).some(v => !v)) {
      if (!await tpnConfirm('Some uniform items are not ticked. Approve anyway?', { confirmText: 'Approve' })) return;
    }
    const { error } = await sb.rpc('review_clockin', { p_attendance_id: id, p_approve: approve, p_uniform: checks, p_note: note, p_trust_network: !!trust });
    if (error) { toast(/own_clockin/.test(error.message) ? 'Another manager must review your own clock-in.' : error.message); return; }
    toast(approve ? 'Approved.' : 'Flagged. They have been notified.');
    route('clockin-review', { refresh: true });
  };
  window.ciTrustHere = async function () {
    if (!await tpnConfirm('Only do this while you are AT the restaurant, connected to its Wi-Fi. Clock-ins from this network will then count as on-site.', { title: 'Trust this network?', confirmText: 'Trust it' })) return;
    const { data, error } = await sb.rpc('trust_current_network', { p_label: 'Restaurant Wi-Fi' });
    if (error) { toast(error.message); return; }
    toast('Trusted: ' + data.network + (data.family === 6 ? ' (IPv6 — also add the IPv4 if staff phones use it)' : ''));
    route('clockin-review', { refresh: true });
  };
  window.ciNetToggle = async (id, on) => { const { error } = await sb.from('trusted_networks').update({ is_active: on }).eq('id', id); if (error) toast(error.message); route('clockin-review', { refresh: true }); };
  window.ciShowAll = (v) => { rv.all = v; route('clockin-review', { refresh: true }); };
  window.ciExport = (fmt) => tpnExport(rv.rows, [
    { label: 'Name', key: 'staff_name' }, { label: 'Role', key: 'role' }, { label: 'Clock in', key: 'clock_in_at', type: 'datetime' },
    { label: 'Clock out', key: 'clock_out_at', type: 'datetime' }, { label: 'On restaurant Wi-Fi', get: r => r.network_trusted ? 'yes' : 'no' },
    { label: 'IP', key: 'ip' }, { label: 'Status', key: 'verify_status' }, { label: 'Reasons', get: r => (r.verify_reasons || []).join(', ') },
    { label: 'Reviewed by', key: 'reviewed_by_name' }, { label: 'Note', key: 'review_note' }
  ], { format: fmt, filename: 'tpn-clockins', sheet: 'Clock-ins', title: 'Tyo Paeng Nyo — clock-in review' });

  async function purgeOld() {
    try {
      const { data } = await sb.rpc('clockin_photos_expired', { p_limit: 200 });
      if (!data || !data.length) return;
      const { error } = await sb.storage.from('attendance-photos').remove(data.map(d => d.photo_path));
      if (!error) await sb.rpc('mark_clockin_photos_purged', { p_ids: data.map(d => d.attendance_id) });
    } catch (e) { /* retry next time a manager opens the queue */ }
  }

  TPN_MOD.register({ id: 'clockin-review', side: 'admin', section: 'sec.team', after: 'attendance-admin', perm: 'attendance.verify',
    icon: '📸', label: 'Clock-in review', labelTl: 'Suriin ang clock-in', render, badge: () => rv.pending || null });
})();
