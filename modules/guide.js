/* ═══════════════════════════════════════════════════════════════
   Guide — a first-day tour and a "How do I…?" help panel.

   • A "?" button sits on every portal page, the floor screen and the
     kitchen screen. It opens a searchable list of every task, grouped
     like the sidebar; "Show me" opens the right page and lights up the
     button you need.
   • The tour runs once per person per device on their first sign-in and
     can be replayed from the help panel at any time.
   • Everything is written in English and Tagalog here, so it follows the
     language switch on its own.
   Highlights find buttons by what they do (their onclick), not by their
   label, so they keep working in either language.
   ═══════════════════════════════════════════════════════════════ */
(function () {
  'use strict';
  const lang = () => { try { return (typeof TPN_LANG !== 'undefined' && TPN_LANG) || localStorage.getItem('tpn.lang') || 'en'; } catch (e) { return 'en'; } };
  const tx = (o) => (o == null ? '' : typeof o === 'string' ? o : (o[lang()] || o.en));
  const esc = (v) => String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
  const where = /dine-in-floor/.test(location.pathname) ? 'floor' : /kitchen-station/.test(location.pathname) ? 'kitchen' : 'portal';
  const UI = {
    help: { en: 'Help & guide', tl: 'Tulong at gabay' },
    search: { en: 'What do you want to do?', tl: 'Ano ang gusto mong gawin?' },
    tour: { en: '▶ Take the tour', tl: '▶ Simulan ang tour' },
    showMe: { en: 'Show me', tl: 'Ipakita' },
    next: { en: 'Next', tl: 'Susunod' }, back: { en: 'Back', tl: 'Bumalik' },
    skip: { en: 'Skip', tl: 'Laktawan' }, done: { en: 'Got it', tl: 'Sige' }, close: { en: 'Close', tl: 'Isara' },
    none: { en: 'Nothing matches. Try another word.', tl: 'Walang tugma. Subukan ang ibang salita.' },
    notHere: { en: 'Your account cannot open this page. Ask a manager.', tl: 'Hindi ito mabubuksan ng account mo. Magtanong sa manager.' },
    step: { en: 'Step', tl: 'Hakbang' }, of: { en: 'of', tl: 'sa' }
  };

  /* ── Help topics ──────────────────────────────────────────────
     Short and direct: one action per step.
     route: the portal page it lives on (hidden if your account cannot
     open it). show: what to light up there. open: a separate screen. */
  const t = (en, tl) => ({ en, tl });
  const PORTAL_TOPICS = [
    { group: t('Getting around', 'Paglibot'), items: [
      { title: t('Find a page', 'Maghanap ng pahina'), show: '#portalNav, #staffNav',
        steps: [t('Tap a group in the sidebar.', 'I-tap ang grupo sa sidebar.'),
                t('Pick a tab at the top.', 'Pumili ng tab sa itaas.'),
                t('Or press Ctrl+K and type.', 'O pindutin ang Ctrl+K at mag-type.')] },
      { title: t('Change language', 'Palitan ang wika'), show: '.portal-lang, .lang-btn',
        steps: [t('Tap English or Tagalog at the top of the sidebar.', 'I-tap ang English o Tagalog sa itaas ng sidebar.')] },
      { title: t('Export or import a list', 'Mag-export o mag-import ng listahan'), show: '.tpn-io',
        steps: [t('Tap Export for an Excel or CSV file.', 'I-tap ang Export para sa Excel o CSV.'),
                t('Tap Import to upload one.', 'I-tap ang Import para mag-upload.')] },
      { title: t('Change theme or text size', 'Palitan ang theme o laki ng letra'), route: 'preferences',
        steps: [t('Open Preferences.', 'Buksan ang Preferences.'),
                t('Pick a theme and text size.', 'Pumili ng theme at laki ng letra.')] },
      { title: t('Sign out', 'Mag-sign out'), show: '.portal-logout',
        steps: [t('Tap Out next to your name.', 'I-tap ang Out sa tabi ng pangalan mo.')] }
    ] },
    { group: t('Service', 'Serbisyo'), items: [
      { title: t('Move an order along', 'Isulong ang order'), route: 'orders', show: '[onclick^="advanceOrder"]',
        steps: [t('Open Live Orders.', 'Buksan ang Live Orders.'),
                t('Tap the button on the order card.', 'I-tap ang button sa card ng order.')] },
      { title: t('Take payment', 'Tumanggap ng bayad'), route: 'orders', show: '[onclick^="openPaymentPanel"]',
        steps: [t('Tap Take payment on the order.', 'I-tap ang Take payment sa order.'),
                t('Pick Cash, Bank or Online.', 'Piliin ang Cash, Bank o Online.'),
                t('Enter the amount.', 'Ilagay ang halaga.')] },
      { title: t('Give a discount', 'Magbigay ng discount'), route: 'orders', show: '[onclick^="openDiscountPicker"]',
        steps: [t('Tap Discount on the order.', 'I-tap ang Discount sa order.'),
                t('Pick one. Senior/PWD needs the ID number.', 'Pumili. Kailangan ng ID number ang Senior/PWD.')] },
      { title: t('Cook an order', 'Lutuin ang order'), route: 'kds',
        steps: [t('Open Kitchen Queue.', 'Buksan ang Kitchen Queue.'),
                t('Tap Start cooking, then Mark ready.', 'I-tap ang Start cooking, tapos Mark ready.')] },
      { title: t('Mark a dish sold out', 'Markahang ubos ang ulam'), route: 'kds', show: '[onclick^="open86Panel"]',
        steps: [t('Tap Sold out (86).', 'I-tap ang Sold out (86).'),
                t('Tap the dish. Tap again when it\'s back.', 'I-tap ang ulam. I-tap ulit kapag mayroon na.')] },
      { title: t('Void an item', 'Mag-void ng item'), route: 'void-requests',
        steps: [t('On the order, tap Request void and give a reason.', 'Sa order, i-tap ang Request void at magbigay ng dahilan.'),
                t('A manager approves it in Void Requests.', 'Aaprubahan ito ng manager sa Void Requests.')] },
      { title: t('Ring up an order', 'Mag-ring up ng order'), open: 'tpn-dine-in-floor',
        steps: [t('Open Floor & Counter.', 'Buksan ang Floor & Counter.'),
                t('Tap Counter, or + Order on a table.', 'I-tap ang Counter, o + Order sa mesa.'),
                t('Tap dishes, then Send to kitchen.', 'I-tap ang mga ulam, tapos Send to kitchen.')] },
      { title: t('Close a table', 'Isara ang mesa'), open: 'tpn-dine-in-floor',
        steps: [t('Tap Bill, then Close Table.', 'I-tap ang Bill, tapos Close Table.'),
                t('Enter the cash received.', 'Ilagay ang natanggap na cash.'),
                t('Card or bank? Tap Other way.', 'Card o bangko? I-tap ang Other way.')] },
      { title: t('Open or close the cash drawer', 'Buksan o isara ang cash drawer'), open: 'tpn-dine-in-floor',
        steps: [t('Counter tab → Open shift. Enter the starting cash.', 'Counter tab → Open shift. Ilagay ang panimulang cash.'),
                t('At closing: Drawer → Close shift. Count the cash.', 'Pagsara: Drawer → Close shift. Bilangin ang cash.')] }
    ] },
    { group: t('Guests & events', 'Bisita at events'), items: [
      { title: t('Answer an inquiry', 'Sagutin ang inquiry'), route: 'inquiries',
        steps: [t('Open Inquiries.', 'Buksan ang Inquiries.'),
                t('Tap Call or Email, then update the status.', 'I-tap ang Call o Email, tapos i-update ang status.')] },
      { title: t('Find a regular guest', 'Hanapin ang suki'), route: 'guests',
        steps: [t('Open Guests and search a name or phone.', 'Buksan ang Guests at hanapin ang pangalan o phone.'),
                t('Add a note if needed.', 'Magdagdag ng tala kung kailangan.')] },
      { title: t('Give a stamp-card reward', 'Ibigay ang reward sa stamp card'), route: 'rewards', show: '[onclick^="rwScan"]',
        steps: [t('Tap Scan their QR.', 'I-tap ang Scan their QR.'),
                t('Check it, then tap Give reward.', 'Tingnan, tapos i-tap ang Give reward.')] }
    ] },
    { group: t('Team', 'Team'), items: [
      { title: t('Clock in or out', 'Mag-clock in o out'), route: 'staff-home', staffOnly: true, show: '[onclick^="doClockIn"], [onclick^="doClockOut"]',
        steps: [t('Tap Clock In on Home.', 'I-tap ang Clock In sa Home.'),
                t('Take a full-body photo in uniform.', 'Kumuha ng buong-katawan na litrato na naka-uniform.'),
                t('Tap Clock Out when you leave.', 'I-tap ang Clock Out pag-alis.')] },
      { title: t('Make the schedule', 'Gawin ang schedule'), route: 'schedules', show: '[onclick^="copyPrevWeekSchedules"]',
        steps: [t('Open Schedules and tap a cell.', 'Buksan ang Schedules at i-tap ang cell.'),
                t('Or tap Copy from prev week.', 'O i-tap ang Copy from prev week.')] },
      { title: t('Give a task', 'Magbigay ng task'), route: 'tasks', show: '[onclick^="openTaskEditor"]',
        steps: [t('Open Task Board → New task.', 'Buksan ang Task Board → New task.'),
                t('Add a title and people.', 'Lagyan ng pamagat at mga tao.')] },
      { title: t('Check clock-in photos', 'Suriin ang litrato sa clock-in'), route: 'clockin-review',
        steps: [t('Open Clock-in review.', 'Buksan ang Clock-in review.'),
                t('Tick the uniform, then Approve or Reject.', 'I-check ang uniform, tapos Approve o Reject.')] },
      { title: t('Fix a clock-in', 'Itama ang clock-in'), route: 'attendance-admin',
        steps: [t('Open Attendance and pick the day.', 'Buksan ang Attendance at piliin ang araw.'),
                t('Tap Correct and fix the time.', 'I-tap ang Correct at itama ang oras.')] },
      { title: t('Run payroll', 'Magpatakbo ng payroll'), route: 'payroll', show: '[onclick^="openNewPayRun"]',
        steps: [t('Tap New pay run and pick the dates.', 'I-tap ang New pay run at piliin ang petsa.'),
                t('Check it, approve, then mark paid.', 'Tingnan, aprubahan, tapos markahang bayad.')] },
      { title: t('Change someone\'s role', 'Palitan ang role ng tao'), route: 'staff-board',
        steps: [t('Open Staff Board.', 'Buksan ang Staff Board.'),
                t('Drag the person to the new role.', 'I-drag ang tao sa bagong role.')] }
    ] },
    { group: t('Menu & stock', 'Menu at stock'), items: [
      { title: t('Add or edit a dish', 'Magdagdag o mag-edit ng ulam'), route: 'menu-manager', show: '[onclick^="showMenuItemModal"]',
        steps: [t('Open Menu Manager → Add Item (or Edit).', 'Buksan ang Menu Manager → Add Item (o Edit).'),
                t('Enter name and price. Save.', 'Ilagay ang pangalan at presyo. I-save.')] },
      { title: t('Add extras (e.g. extra rice)', 'Magdagdag ng extra (hal. dagdag na kanin)'), route: 'modifiers',
        steps: [t('Open Add-ons & choices → New group.', 'Buksan ang Add-ons & choices → New group.'),
                t('Add choices and prices, then link dishes.', 'Magdagdag ng pagpipilian at presyo, tapos i-link ang ulam.')] },
      { title: t('Make a discount or promo', 'Gumawa ng discount o promo'), route: 'discounts', show: '[onclick^="openDiscountTemplateEditor"]',
        steps: [t('Open Discounts → New template.', 'Buksan ang Discounts → New template.'),
                t('Set percent or peso. Save.', 'Ilagay ang porsyento o piso. I-save.')] },
      { title: t('Record a delivery', 'Magtala ng delivery'), route: 'inventory', show: '[onclick^="openStockMovement"]',
        steps: [t('Open Inventory → Receive a delivery.', 'Buksan ang Inventory → Receive a delivery.'),
                t('Use Adjust for spoilage or a recount.', 'Gamitin ang Adjust para sa sira o muling bilang.')] },
      { title: t('Add a table or print QR', 'Magdagdag ng mesa o mag-print ng QR'), route: 'table-qr', show: '[onclick^="promptAddTable"]',
        steps: [t('Open Table QR Codes.', 'Buksan ang Table QR Codes.'),
                t('Tap + Add Table or Print All.', 'I-tap ang + Add Table o Print All.')] }
    ] },
    { group: t('Money', 'Pera'), items: [
      { title: t('Close the day', 'Isara ang araw'), route: 'daily-close', show: '[onclick^="openCloseTill"], [onclick^="doCloseTill"]',
        steps: [t('Open Daily Close.', 'Buksan ang Daily Close.'),
                t('Settle unpaid orders first.', 'Ayusin muna ang hindi bayad na order.'),
                t('Count the cash, enter it, close.', 'Bilangin ang cash, ilagay, isara.')] },
      { title: t('Confirm a transfer or refund', 'Kumpirmahin ang transfer o mag-refund'), route: 'payments',
        steps: [t('Open Payments.', 'Buksan ang Payments.'),
                t('Confirm a transfer after checking the bank app.', 'Kumpirmahin ang transfer pagkatapos tingnan ang bank app.'),
                t('Refunds need a manager and a reason.', 'Kailangan ng manager at dahilan ang refund.')] },
      { title: t('See sales and costs', 'Tingnan ang benta at gastos'), route: 'finance', show: '[onclick^="openExpenseEditor"]',
        steps: [t('Open Finance.', 'Buksan ang Finance.'),
                t('Tap Add expense to record a cost.', 'I-tap ang Add expense para magtala ng gastos.')] }
    ] },
    { group: t('Inbox', 'Inbox'), items: [
      { title: t('Clear notifications', 'Linisin ang notification'), route: 'notifications', show: '[onclick^="markAllNotificationsRead"]',
        steps: [t('Tap one to open it.', 'I-tap para buksan.'),
                t('Or tap Mark all read.', 'O i-tap ang Mark all read.')] },
      { title: t('Message the team', 'Mag-message sa team'), route: 'messages-admin', show: '[onclick^="openComposeMessageModal"]',
        steps: [t('Open Messages → Compose.', 'Buksan ang Messages → Compose.'),
                t('Pick a person or everyone.', 'Pumili ng tao o lahat.')] }
    ] },
    { group: t('Website', 'Website'), items: [
      { title: t('Edit the website', 'I-edit ang website'), route: 'website',
        steps: [t('Open Website and pick a tab.', 'Buksan ang Website at pumili ng tab.'),
                t('Edit and Save. It goes live at once.', 'I-edit at i-save. Live agad.')] }
    ] },
    { group: t('Accounts & access', 'Account at access'), items: [
      { title: t('Add a staff account', 'Magdagdag ng staff account'), route: 'accounts', show: '[onclick^="showCreateStaffModal"]',
        steps: [t('Tap Add Staff Account.', 'I-tap ang Add Staff Account.'),
                t('Enter name, email, role and a password.', 'Ilagay ang pangalan, email, role at password.'),
                t('Give them the password in person.', 'Ibigay nang personal ang password.')] },
      { title: t('Set what a role can do', 'Itakda ang kaya ng role'), route: 'roles', show: '[onclick^="openRoleEditor"]',
        steps: [t('Open Roles & Access and tap a role.', 'Buksan ang Roles & Access at i-tap ang role.'),
                t('Tick or untick permissions.', 'I-check o i-uncheck ang pahintulot.')] },
      { title: t('See who did what', 'Tingnan kung sino ang gumawa'), route: 'audit',
        steps: [t('Open Audit Log.', 'Buksan ang Audit Log.')] }
    ] }
  ];

  const FLOOR_TOPICS = [
    { group: t('Floor & counter', 'Floor at counter'), items: [
      { title: t('Read the floor map', 'Basahin ang floor map'), show: '.floor-grid',
        steps: [t('Each card is a table. The colour shows its status.', 'Bawat card ay mesa. Ang kulay ang status nito.'),
                t('A red badge means a guest is calling.', 'Ang pulang badge ay may bisitang tumatawag.')] },
      { title: t('Add an order to a table', 'Magdagdag ng order sa mesa'), show: '[onclick^="floorAddOrder"]',
        steps: [t('Tap + Order on the table.', 'I-tap ang + Order sa mesa.'),
                t('Tap dishes, then Send to kitchen.', 'I-tap ang ulam, tapos Send to kitchen.')] },
      { title: t('Ring up take-out', 'Mag-ring up ng take-out'), show: '#tab-counter',
        steps: [t('Open Counter. Pick Take-out or Delivery.', 'Buksan ang Counter. Piliin ang Take-out o Delivery.'),
                t('Tap dishes, send, take the cash.', 'I-tap ang ulam, ipadala, tanggapin ang cash.')] },
      { title: t('Close a table', 'Isara ang mesa'), show: '[onclick^="closeTable"], [onclick^="markBillReady"]',
        steps: [t('Tap Bill, then Close Table.', 'I-tap ang Bill, tapos Close Table.'),
                t('Enter the cash received.', 'Ilagay ang natanggap na cash.')] },
      { title: t('Open or close the drawer', 'Buksan o isara ang drawer'), show: '#tab-counter',
        steps: [t('Counter → Open shift.', 'Counter → Open shift.'),
                t('At closing: Drawer → Close shift.', 'Pagsara: Drawer → Close shift.')] },
      { title: t('Turn on sound', 'Buksan ang tunog'),
        steps: [t('Tap the screen once.', 'I-tap minsan ang screen.')] }
    ] }
  ];
  const KITCHEN_TOPICS = [
    { group: t('Kitchen screen', 'Screen sa kusina'), items: [
      { title: t('Cook the tickets', 'Lutuin ang mga ticket'),
        steps: [t('Tap a ticket to start.', 'I-tap ang ticket para simulan.'),
                t('Tap Mark Ready when done.', 'I-tap ang Mark Ready kapag tapos.'),
                t('Red means late.', 'Pula ay huli na.')] },
      { title: t('Turn on sound', 'Buksan ang tunog'),
        steps: [t('Tap the screen once.', 'I-tap minsan ang screen.')] }
    ] }
  ];

  /* ── Tours ──────────────────────────────────────────────────── */
  const TOURS = {
    admin: [
      { title: t('Welcome 👋', 'Maligayang pagdating 👋'), body: t('A quick tour. Replay it from the ? button.', 'Mabilisang tour. Ulitin sa ? na button.') },
      { sel: '#portalNav', title: t('Sidebar', 'Sidebar'), body: t('Pages are grouped here. Tap a group.', 'Naka-grupo dito ang mga pahina. I-tap ang grupo.') },
      { sel: '#hubTabsAdmin:not([hidden])', title: t('Tabs', 'Mga tab'), body: t('Pages in a group are tabs.', 'Tab ang mga pahina sa grupo.') },
      { sel: '.tpn-cmdk-btn', title: t('Search', 'Maghanap'), body: t('Find any page, order, staff or dish. Shortcut: Ctrl+K.', 'Hanapin ang kahit anong pahina, order, staff o ulam. Shortcut: Ctrl+K.') },
      { sel: '.portal-lang, .lang-btn', title: t('Language', 'Wika'), body: t('Switch English or Tagalog.', 'Lumipat sa English o Tagalog.') },
      { sel: '.tpn-io', title: t('Excel / CSV', 'Excel / CSV'), body: t('Export or import lists here.', 'Mag-export o mag-import dito.') },
      { sel: '#tpnHelpBtn', title: t('Help', 'Tulong'), body: t('Tap ? for step-by-step help.', 'I-tap ang ? para sa sunud-sunod na tulong.') },
      { sel: '#portalUser', title: t('Sign out', 'Mag-sign out'), body: t('Tap Out when you\'re done.', 'I-tap ang Out kapag tapos ka na.') }
    ],
    staff: [
      { title: t('Welcome 👋', 'Maligayang pagdating 👋'), body: t('A quick tour. Replay it from the ? button.', 'Mabilisang tour. Ulitin sa ? na button.') },
      { sel: '[onclick^="doClockIn"], [onclick^="doClockOut"]', title: t('Clock in', 'Mag-clock in'), body: t('Clock in at the start of every shift.', 'Mag-clock in sa simula ng bawat shift.') },
      { sel: '#staffNav', title: t('Your pages', 'Ang mga pahina mo'), body: t('Work, shifts and inbox.', 'Trabaho, shift at inbox.') },
      { sel: '.tpn-cmdk-btn', title: t('Search', 'Maghanap'), body: t('Find anything fast.', 'Hanapin agad ang kahit ano.') },
      { sel: '#tpnHelpBtn', title: t('Help', 'Tulong'), body: t('Tap ? for help.', 'I-tap ang ? para sa tulong.') }
    ],
    floor: [
      { title: t('Floor screen 👋', 'Floor screen 👋'), body: t('Tables, counter and bills.', 'Mesa, counter at bill.') },
      { sel: '#tab-nav', title: t('Tabs', 'Mga tab'), body: t('Floor Map, Counter, Orders.', 'Floor Map, Counter, Orders.') },
      { sel: '.floor-grid .table-card', title: t('A table', 'Isang mesa'), body: t('+ Order to add. Bill → Close Table to pay.', '+ Order para magdagdag. Bill → Close Table para magbayad.') },
      { sel: '[data-lang-toggle]', title: t('Language', 'Wika'), body: t('Switch English or Tagalog.', 'Lumipat sa English o Tagalog.') },
      { sel: '#tpnHelpBtn', title: t('Help', 'Tulong'), body: t('Tap ? for help.', 'I-tap ang ? para sa tulong.') }
    ],
    kitchen: [
      { title: t('Kitchen screen 👋', 'Screen sa kusina 👋'), body: t('Tap a ticket to start. Tap Mark Ready when done.', 'I-tap ang ticket para simulan. I-tap ang Mark Ready kapag tapos.') },
      { sel: '[data-lang-toggle]', title: t('Language', 'Wika'), body: t('Switch English or Tagalog.', 'Lumipat sa English o Tagalog.') },
      { sel: '#tpnHelpBtn', title: t('Help', 'Tulong'), body: t('Tap ? for help.', 'I-tap ang ? para sa tulong.') }
    ]
  };

  /* ── Context ────────────────────────────────────────────────── */
  const portalKind = () => {
    if (where !== 'portal') return where;
    if (document.getElementById('portal-staff')?.classList.contains('active')) return 'staff';
    if (document.getElementById('portal-admin')?.classList.contains('active')) return 'admin';
    return null;
  };
  const allowedRoute = (r) => {
    const k = portalKind();
    if (k === 'admin') return (window._tpnAdminRoutes || []).includes(r);
    if (k === 'staff') { try { return (_tpnHubState.staff || []).some(h => h.items.some(i => i.id === r && !i.external)); } catch (e) { return false; } }
    return false;
  };
  const topicsHere = () => {
    if (where === 'floor') return FLOOR_TOPICS;
    if (where === 'kitchen') return KITCHEN_TOPICS;
    const k = portalKind();
    return PORTAL_TOPICS.map(g => ({ group: g.group, items: g.items.filter(it =>
      (!it.route || allowedRoute(it.route)) && !(it.staffOnly && k !== 'staff')) })).filter(g => g.items.length);
  };

  /* ── Styles (self-contained; works on every screen) ─────────── */
  const css = `
  #tpnHelpBtn{position:fixed;right:16px;bottom:16px;z-index:1200;width:48px;height:48px;border-radius:50%;border:0;cursor:pointer;
    background:#8B1A0E;color:#fff;font:700 22px/1 'DM Sans',system-ui,sans-serif;box-shadow:0 6px 18px rgba(43,24,16,.35);display:none}
  #tpnHelpBtn.on{display:block} #tpnHelpBtn:focus-visible{outline:3px solid #E8B340;outline-offset:2px}
  body.has-mobile-bar #tpnHelpBtn{bottom:84px}
  .tg-panel{position:fixed;top:0;right:0;bottom:0;width:min(420px,100vw);z-index:1300;background:#FBF4E4;color:#2B1810;box-shadow:-12px 0 40px rgba(0,0,0,.25);
    display:flex;flex-direction:column;transform:translateX(100%);transition:transform .22s ease;font:400 14px/1.5 'DM Sans',system-ui,sans-serif}
  .tg-panel.open{transform:none}
  .tg-head{padding:16px 18px 10px;border-bottom:1px solid rgba(139,26,14,.14)}
  .tg-head h2{margin:0 0 10px;font:700 20px 'Playfair Display',serif;display:flex;justify-content:space-between;align-items:center;gap:8px}
  .tg-x{border:0;background:transparent;font-size:22px;cursor:pointer;color:#6B4A35;min-width:40px;min-height:40px}
  .tg-search{width:100%;box-sizing:border-box;padding:11px 13px;border-radius:12px;border:1.5px solid rgba(139,26,14,.2);background:#fff;font:inherit;color:inherit}
  .tg-tour{margin-top:10px;width:100%;min-height:42px;border-radius:999px;border:0;background:#C43D1A;color:#fff;font:600 14px inherit;cursor:pointer}
  .tg-body{overflow-y:auto;padding:6px 14px 30px;flex:1}
  .tg-group{margin:16px 4px 6px;font-size:11px;font-weight:700;letter-spacing:.12em;text-transform:uppercase;color:#8B1A0E}
  .tg-item{border:1px solid rgba(139,26,14,.12);background:#fff;border-radius:12px;margin:6px 0}
  .tg-item summary{list-style:none;cursor:pointer;padding:12px 14px;font-weight:600;display:flex;justify-content:space-between;gap:10px;min-height:44px;box-sizing:border-box;align-items:center}
  .tg-item summary::-webkit-details-marker{display:none}
  .tg-item summary::after{content:'▾';color:#9C7F65;transition:transform .15s} .tg-item[open] summary::after{transform:rotate(180deg)}
  .tg-item ol{margin:0;padding:0 16px 4px 34px} .tg-item li{margin:4px 0}
  .tg-show{margin:8px 14px 14px;min-height:40px;padding:0 16px;border-radius:999px;border:1.5px solid #8B1A0E;background:transparent;color:#8B1A0E;font:600 13px inherit;cursor:pointer}
  .tg-empty{padding:30px 10px;text-align:center;color:#6B4A35}
  .tg-dim{position:fixed;inset:0;z-index:1350;pointer-events:auto}
  .tg-hole{position:fixed;z-index:1360;border-radius:12px;box-shadow:0 0 0 9999px rgba(20,10,6,.6),0 0 0 3px #E8B340;pointer-events:none;transition:all .2s ease}
  .tg-card{position:fixed;z-index:1370;width:min(340px,calc(100vw - 32px));background:#FBF4E4;color:#2B1810;border-radius:16px;padding:16px 18px;
    box-shadow:0 18px 50px rgba(0,0,0,.35);font:400 14px/1.5 'DM Sans',system-ui,sans-serif}
  .tg-card h3{margin:0 0 6px;font:700 17px 'Playfair Display',serif}
  .tg-card p{margin:0 0 12px} .tg-card ol{margin:0 0 12px;padding-left:20px}
  .tg-card .tg-row{display:flex;gap:8px;align-items:center;justify-content:space-between;flex-wrap:wrap}
  .tg-card .tg-count{font-size:12px;color:#6B4A35}
  .tg-card button{min-height:40px;padding:0 16px;border-radius:999px;font:600 13px inherit;cursor:pointer;border:1.5px solid rgba(139,26,14,.25);background:#fff;color:#2B1810}
  .tg-card button.pri{background:#C43D1A;border-color:#C43D1A;color:#fff}
  .tg-card .tg-skip{border:0;background:transparent;color:#6B4A35;text-decoration:underline;padding:0 4px}
  html[data-theme="dark"] .tg-panel, html[data-theme="night"] .tg-panel, html[data-theme="dark"] .tg-card, html[data-theme="night"] .tg-card{background:#2A1D18;color:#F3E6D2}
  html[data-theme="dark"] .tg-item, html[data-theme="night"] .tg-item, html[data-theme="dark"] .tg-search, html[data-theme="night"] .tg-search, html[data-theme="dark"] .tg-card button:not(.pri), html[data-theme="night"] .tg-card button:not(.pri){background:#1E1512;color:#F3E6D2}
  @media (prefers-reduced-motion: reduce){.tg-panel,.tg-hole{transition:none}}`;
  const style = document.createElement('style'); style.id = 'tpn-guide-css'; style.textContent = css;
  document.head.appendChild(style);

  /* ── Help button + panel ────────────────────────────────────── */
  let btn, panel;
  function ensureUi() {
    if (btn) return;
    btn = document.createElement('button');
    btn.id = 'tpnHelpBtn'; btn.type = 'button'; btn.textContent = '?';
    btn.setAttribute('translate', 'no');
    btn.addEventListener('click', openPanel);
    document.body.appendChild(btn);
    panel = document.createElement('aside');
    panel.className = 'tg-panel'; panel.setAttribute('role', 'dialog'); panel.setAttribute('aria-modal', 'false'); panel.setAttribute('translate', 'no');
    document.body.appendChild(panel);
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape') { if (tourState) endTour(); else closePanel(); } });
    paintButton();
  }
  function paintButton() { if (btn) { btn.title = tx(UI.help); btn.setAttribute('aria-label', tx(UI.help)); } }
  function setButton(on) { ensureUi(); btn.classList.toggle('on', !!on); }

  function openPanel() {
    ensureUi();
    panel.innerHTML = `<div class="tg-head"><h2><span>${esc(tx(UI.help))}</span><button class="tg-x" type="button" aria-label="${esc(tx(UI.close))}">×</button></h2>
      <input class="tg-search" type="search" placeholder="${esc(tx(UI.search))}" aria-label="${esc(tx(UI.search))}">
      <button class="tg-tour" type="button">${esc(tx(UI.tour))}</button></div><div class="tg-body"></div>`;
    panel.querySelector('.tg-x').onclick = closePanel;
    panel.querySelector('.tg-tour').onclick = () => { closePanel(); startTour(true); };
    const input = panel.querySelector('.tg-search');
    input.addEventListener('input', () => drawTopics(input.value));
    drawTopics('');
    panel.classList.add('open');
    setTimeout(() => input.focus(), 60);
  }
  function closePanel() { if (panel) panel.classList.remove('open'); }
  function drawTopics(q) {
    const body = panel.querySelector('.tg-body');
    const needle = q.trim().toLowerCase();
    const groups = topicsHere().map(g => ({ g, items: g.items.filter(it => !needle ||
      [it.title.en, it.title.tl, ...it.steps.flatMap(s => [s.en, s.tl])].join(' ').toLowerCase().includes(needle)) })).filter(x => x.items.length);
    if (!groups.length) { body.innerHTML = `<div class="tg-empty">${esc(tx(UI.none))}</div>`; return; }
    let n = 0;
    body.innerHTML = groups.map(({ g, items }) => `<div class="tg-group">${esc(tx(g.group))}</div>` + items.map(it => {
      const id = 'tg' + (n++); it._id = id;
      const can = it.route || it.open || it.show;
      return `<details class="tg-item" ${needle && n === 1 ? 'open' : ''}><summary>${esc(tx(it.title))}</summary>
        <ol>${it.steps.map(s => `<li>${esc(tx(s))}</li>`).join('')}</ol>
        ${can ? `<button class="tg-show" type="button" data-topic="${id}">${esc(tx(UI.showMe))} →</button>` : ''}</details>`;
    }).join('')).join('');
    body.querySelectorAll('.tg-show').forEach(b => b.onclick = () => {
      const it = groups.flatMap(x => x.items).find(i => i._id === b.dataset.topic); if (it) showMe(it);
    });
  }

  function showMe(it) {
    closePanel();
    if (it.open) { window.open(it.open, '_blank', 'noopener'); return; }
    const go = () => setTimeout(() => runTour([{ sel: it.show, title: it.title, steps: it.steps }], { single: true }), 650);
    if (it.route && where === 'portal') {
      if (!allowedRoute(it.route)) { runTour([{ title: it.title, body: UI.notHere }], { single: true }); return; }
      const k = portalKind();
      if (k === 'staff' && typeof routeStaff === 'function') routeStaff(it.route);
      else if (typeof route === 'function') route(it.route);
      go();
    } else go();
  }

  /* ── Spotlight tour ─────────────────────────────────────────── */
  let tourState = null;
  const visible = (el) => { if (!el) return false; const r = el.getBoundingClientRect(); return r.width > 0 && r.height > 0 && getComputedStyle(el).visibility !== 'hidden'; };
  const findTarget = (sel) => { if (!sel) return null; for (const el of document.querySelectorAll(sel)) if (visible(el)) return el; return null; };

  function runTour(steps, opts = {}) {
    endTour();
    // A step whose target is not on this screen is skipped, unless it has none.
    const list = steps.filter(s => !s.sel || findTarget(s.sel) || opts.single);
    if (!list.length) return;
    tourState = { list, i: 0, opts };
    const dim = document.createElement('div'); dim.className = 'tg-dim';
    const hole = document.createElement('div'); hole.className = 'tg-hole';
    const card = document.createElement('div'); card.className = 'tg-card'; card.setAttribute('role', 'dialog'); card.setAttribute('aria-live', 'polite'); card.setAttribute('translate', 'no');
    dim.addEventListener('click', () => { if (opts.single) endTour(); });
    document.body.append(dim, hole, card);
    Object.assign(tourState, { dim, hole, card });
    window.addEventListener('resize', place); window.addEventListener('scroll', place, true);
    drawStep();
  }
  function drawStep() {
    const s = tourState.list[tourState.i], last = tourState.i === tourState.list.length - 1, single = tourState.opts.single;
    const target = findTarget(s.sel);
    if (target) target.scrollIntoView({ block: 'center', inline: 'nearest' });
    tourState.target = target;
    tourState.card.innerHTML = `<h3>${esc(tx(s.title))}</h3>
      ${s.body ? `<p>${esc(tx(s.body))}</p>` : ''}
      ${s.steps ? `<ol>${s.steps.map(x => `<li>${esc(tx(x))}</li>`).join('')}</ol>` : ''}
      <div class="tg-row">
        ${single ? '<span></span>' : `<span class="tg-count">${esc(tx(UI.step))} ${tourState.i + 1} ${esc(tx(UI.of))} ${tourState.list.length}</span>`}
        <span style="display:flex;gap:8px;align-items:center">
          ${!single && !last ? `<button class="tg-skip" type="button" data-a="skip">${esc(tx(UI.skip))}</button>` : ''}
          ${!single && tourState.i > 0 ? `<button type="button" data-a="back">${esc(tx(UI.back))}</button>` : ''}
          <button class="pri" type="button" data-a="${last ? 'done' : 'next'}">${esc(tx(last ? UI.done : UI.next))}</button>
        </span></div>`;
    tourState.card.querySelectorAll('button').forEach(b => b.onclick = () => {
      const a = b.dataset.a;
      if (a === 'next') { tourState.i++; drawStep(); }
      else if (a === 'back') { tourState.i--; drawStep(); }
      else endTour();
    });
    setTimeout(place, 60);
    setTimeout(() => tourState && tourState.card.querySelector('.pri')?.focus({ preventScroll: true }), 80);
  }
  function place() {
    if (!tourState) return;
    const { hole, card, target } = tourState;
    const cw = card.offsetWidth, ch = card.offsetHeight, W = innerWidth, H = innerHeight, pad = 8;
    if (!target || !visible(target)) {
      Object.assign(hole.style, { left: W / 2 + 'px', top: H / 2 + 'px', width: '0px', height: '0px' });
      Object.assign(card.style, { left: Math.max(16, (W - cw) / 2) + 'px', top: Math.max(16, (H - ch) / 2) + 'px' });
      return;
    }
    const r = target.getBoundingClientRect();
    Object.assign(hole.style, { left: r.left - pad + 'px', top: r.top - pad + 'px', width: r.width + pad * 2 + 'px', height: r.height + pad * 2 + 'px' });
    // Below the target if it fits, else above, else beside; always on screen.
    let top = r.bottom + 14, left = Math.min(Math.max(16, r.left), W - cw - 16);
    if (top + ch > H - 16) top = r.top - ch - 14;
    if (top < 16) { top = Math.min(Math.max(16, r.top), H - ch - 16); left = r.right + 14 + cw < W ? r.right + 14 : Math.max(16, r.left - cw - 14); }
    Object.assign(card.style, { left: left + 'px', top: top + 'px' });
  }
  function endTour() {
    if (!tourState) return;
    const { dim, hole, card, opts } = tourState;
    [dim, hole, card].forEach(el => el.remove());
    window.removeEventListener('resize', place); window.removeEventListener('scroll', place, true);
    if (!opts.single) markSeen();
    tourState = null;
  }

  /* ── First-run tour ─────────────────────────────────────────── */
  const seenKey = () => 'tpn.guide.seen.' + (where === 'portal' ? (portalKind() + '.' + ((typeof currentUser !== 'undefined' && currentUser && currentUser.id) || 'x')) : where);
  function markSeen() { try { localStorage.setItem(seenKey(), '1'); } catch (e) {} }
  function seen() { try { return !!localStorage.getItem(seenKey()); } catch (e) { return true; } }
  function startTour(force) {
    const k = where === 'portal' ? portalKind() : where;
    if (!k || !TOURS[k]) return;
    if (!force && seen()) return;
    runTour(TOURS[k]);
  }

  /* ── Wiring ─────────────────────────────────────────────────── */
  function inPortal() { return !!portalKind(); }
  if (where === 'portal') {
    // Show "?" inside the portal only, and offer the tour after first sign-in.
    const wrap = (name, after) => { const orig = window[name]; if (typeof orig !== 'function') return;
      window[name] = function () { const out = orig.apply(this, arguments); try { after(); } catch (e) {} return out; }; };
    wrap('renderRouteInto', () => setButton(true));
    wrap('renderStaffRouteInto', () => setButton(true));
    wrap('enterPortal', () => setTimeout(() => { setButton(inPortal()); startTour(false); }, 1400));
    wrap('exitStaffPortal', () => { setButton(false); endTour(); closePanel(); });
  } else {
    // Wall screens: once the sign-in gate lets the page show.
    const ready = () => document.body.classList.contains('tpn-authed');
    const go = () => { setButton(true); setTimeout(() => startTour(false), 1500); };
    if (ready()) go();
    else { const mo = new MutationObserver(() => { if (ready()) { mo.disconnect(); go(); } }); mo.observe(document.body, { attributes: true, attributeFilter: ['class'] }); }
  }
  // Repaint labels when the language changes.
  const prevSetLang = window.setLang;
  if (typeof prevSetLang === 'function') window.setLang = function () { const out = prevSetLang.apply(this, arguments); paintButton(); if (panel && panel.classList.contains('open')) openPanel(); return out; };
  if (window.TPN_I18N) { const a = TPN_I18N.toggle; TPN_I18N.toggle = function () { a(); paintButton(); if (panel && panel.classList.contains('open')) openPanel(); }; }

  window.TPN_GUIDE = { open: openPanel, tour: () => startTour(true), topics: () => topicsHere(), showMe, text: tx };
})();
