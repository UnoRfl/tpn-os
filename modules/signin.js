/* ═══════════════════════════════════════════════════════════════
   Station sign-in — Floor & Counter and the Kitchen station.

   Each person signs in on the station itself with their own account, so
   every order, payment, void, drawer shift and kitchen bump is theirs, and
   the full portal never loads just to sign in. Load this right after the
   empty <div id="tpn-auth-gate"></div>; it draws the gate (styles in
   tpn-signin.css). The page's own gate code calls:

     TPN_SIGNIN.show(msgEl)          nobody signed in: show the form
     TPN_SIGNIN.switchUser(opts)     sign out for the next person
                                     ({ drawer: true } warns about an open
                                     cash-drawer shift first)

   Nothing about who signed in before is kept or suggested: each person
   types their own login every time, because signing in IS their time-in.
   Signing in clocks them in (attendance, the same record Clock-in and
   payroll use; no photo, so it lands in Clock-in review like any photo-less
   clock-in), and Switch user clocks them out before signing out. The shared
   screen-only accounts (kitchen / floor display) are not people and never
   clock in.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const STATION = /kitchen/.test(location.pathname) ? 'kitchen' : 'counter';
  const DISPLAY = ['kitchen_display', 'dine_in_display'];
  const FLASH = 'tpn.station.flash';
  const hhmm = () => new Date().toLocaleTimeString('en-PH', { hour: 'numeric', minute: '2-digit' });
  // After the reload that follows signing in, say whether the clock-in landed.
  function flash() {
    let m = null; try { m = sessionStorage.getItem(FLASH); sessionStorage.removeItem(FLASH); } catch (e) {}
    if (!m) return;
    const say = () => (window.showToast || window.toast || console.log)(m);
    const wait = () => document.body.classList.contains('tpn-authed') ? say() : setTimeout(wait, 400);
    setTimeout(wait, 400);
  }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', flash); else flash();
  // Earlier builds kept a "recent people" list on the device; it goes.
  try { localStorage.removeItem('tpn.station.recent'); localStorage.removeItem('tpn.counter.recent'); } catch (e) {}
  const gate = document.getElementById('tpn-auth-gate');

  if (gate) gate.innerHTML = `
    <div class="cs-brand" aria-hidden="true">
      <img src="assets/site/logo.webp" alt="">
      <div class="cs-logo">Tyo Paeng <span>Nyo</span></div>
      <h1 class="cs-headline">Welcome back, <em>kabayan</em>.</h1>
    </div>
    <div class="cs-side">
      <button class="cs-portal" type="button" onclick="window.location.href='portal'">← Portal</button>
      <div class="cs-wrap">
        <div class="g-spin"></div>
        <div class="g-sub" id="tpn-auth-msg" role="status">Checking your login…</div>
        <form class="g-form" id="tpn-signin" hidden>
          <h2 class="cs-title">Welcome.</h2>
          <label for="cs-email">Email</label>
          <input id="cs-email" type="email" autocomplete="off" autocapitalize="off" spellcheck="false" inputmode="email" placeholder="you@tyopaengnyo.com" required>
          <label for="cs-pass">Password</label>
          <input id="cs-pass" type="password" autocomplete="current-password" placeholder="Your password" required>
          <button class="g-btn" type="submit" id="cs-go">Sign In</button>
          <p class="g-err" id="cs-err" role="alert"></p>
        </form>
        <button class="g-btn" id="tpn-auth-btn" style="display:none;" onclick="window.location.href='portal'">Open the portal</button>
      </div>
    </div>`;

  // A message (inactive account, no access…) replaces the spinner.
  const msgEl = document.getElementById('tpn-auth-msg');
  if (msgEl) new MutationObserver(() => {
    if (msgEl.textContent && msgEl.textContent !== 'Checking your login…') gate.querySelector('.g-spin').style.display = 'none';
  }).observe(msgEl, { childList: true, characterData: true, subtree: true });

  function show(msg) {
    gate.querySelector('.g-spin').style.display = 'none';
    (msg || msgEl).textContent = '';   // the heading says enough; only a real state gets a line
    const form = document.getElementById('tpn-signin'), err = document.getElementById('cs-err');
    form.hidden = false;
    if (navigator.onLine === false) err.textContent = 'No internet. Signing in needs a connection.';
    document.getElementById('cs-email').value = '';
    document.getElementById('cs-email').focus();
  }

  async function signIn(ev) {
    ev.preventDefault();
    const email = document.getElementById('cs-email').value.trim(), pass = document.getElementById('cs-pass').value;
    const go = document.getElementById('cs-go'), err = document.getElementById('cs-err');
    err.textContent = ''; go.disabled = true; go.textContent = 'Signing in…';
    try {
      const me = await TPN.login(email, pass);
      // Signing in is the time-in.
      let note = null;
      if (me && !DISPLAY.includes(me.role)) {
        try { await TPN.clockIn('Signed in at the ' + STATION); note = 'Clocked in at ' + hhmm() + '.'; }
        catch (e) {
          note = /open shift/i.test(e.message || '') ? 'You were already clocked in.'
               : 'Signed in, but the clock-in didn’t save (' + (e.message || 'error') + '). Tell your manager.';
        }
      }
      try { if (note) sessionStorage.setItem(FLASH, note); } catch (e) {}
      location.reload();
    } catch (e) {
      err.textContent = /invalid/i.test(e.message || '') ? 'That email and password don’t match.' : (e.message || 'Could not sign in.');
      go.disabled = false; go.textContent = 'Sign In';
    }
  }
  const form = document.getElementById('tpn-signin');
  if (form) form.addEventListener('submit', signIn);

  async function switchUser(opts) {
    // A drawer shift belongs to the person who opened it: close it first so their cash is counted.
    let open = null;
    if (opts && opts.drawer && TPN.myOpenCashSession) { try { open = await TPN.myOpenCashSession(); } catch (e) {} }
    const q = open ? 'Your drawer shift is still open. Close it first (Counter → Close shift) so your cash is counted. Clock out and switch anyway?'
                   : 'Clock out and sign out, so the next person can sign in?';
    const ok = window.tpnConfirm ? await tpnConfirm(q, { confirmText: 'Clock out & switch' }) : confirm(q);
    if (!ok) return;
    // Switching is the time-out (screen-only accounts have no shift to close).
    const me = TPN.currentUser && TPN.currentUser();
    if (me && !DISPLAY.includes(me.role)) {
      try { await TPN.clockOut(); }
      catch (e) {
        const go = window.tpnConfirm ? await tpnConfirm('The clock-out didn’t save (' + (e.message || 'no connection') + '). Sign out anyway? Your manager can fix the time.', { confirmText: 'Sign out' }) : confirm('Clock-out failed. Sign out anyway?');
        if (!go) return;
      }
    }
    try { await TPN.logout(); } catch (e) {}
    try { localStorage.removeItem('tpn.offline.me'); } catch (e) {}
    location.reload();
  }

  // "First name · Role" for the top bar.
  function whoLabel(profile) {
    const role = String(profile.role || 'staff').replace(/_/g, ' ').replace(/\b\w/g, c => c.toUpperCase());
    const first = String(profile.full_name || '').trim().split(/\s+/)[0];
    return first ? first + ' · ' + role : role;
  }

  window.TPN_SIGNIN = { show, switchUser, whoLabel };
})();
