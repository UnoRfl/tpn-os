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
   types their own login every time, because signing in is how they start
   their time on the station.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
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
      await TPN.login(email, pass);
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
    const q = open ? 'Your drawer shift is still open. Close it first (Counter → Close shift) so your cash is counted. Switch anyway?'
                   : 'Sign out so the next person can sign in?';
    const ok = window.tpnConfirm ? await tpnConfirm(q, { confirmText: 'Switch user' }) : confirm(q);
    if (!ok) return;
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
