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
    skip: { en: 'Skip tour', tl: 'Laktawan' }, done: { en: 'Got it', tl: 'Sige' }, close: { en: 'Close', tl: 'Isara' },
    none: { en: 'Nothing matches. Try another word.', tl: 'Walang tugma. Subukan ang ibang salita.' },
    notHere: { en: 'Your account cannot open this page. Ask a manager.', tl: 'Hindi ito mabubuksan ng account mo. Magtanong sa manager.' },
    step: { en: 'Step', tl: 'Hakbang' }, of: { en: 'of', tl: 'sa' }
  };

  /* ── Help topics ──────────────────────────────────────────────
     route: the portal page it lives on (hidden if your account cannot
     open it). show: what to light up there. open: a separate screen. */
  const t = (en, tl) => ({ en, tl });
  const PORTAL_TOPICS = [
    { group: t('Getting around', 'Paglibot'), items: [
      { title: t('Find a page', 'Maghanap ng pahina'), show: '#portalNav, #staffNav',
        steps: [t('The sidebar on the left has a few groups (Service, Team, Money…).', 'Ang sidebar sa kaliwa ay may ilang grupo (Service, Team, Money…).'),
                t('Tap a group. Its pages appear as tabs across the top.', 'I-tap ang grupo. Lalabas ang mga pahina nito bilang tab sa itaas.'),
                t('On a phone, tap ☰ to open the sidebar; the tabs become a dropdown.', 'Sa phone, i-tap ang ☰ para buksan ang sidebar; nagiging dropdown ang mga tab.')] },
      { title: t('Switch to English or Tagalog', 'Lumipat sa English o Tagalog'), show: '.portal-lang, .lang-btn',
        steps: [t('Use the English / Tagalog switch at the top of the sidebar.', 'Gamitin ang English / Tagalog sa itaas ng sidebar.'),
                t('The whole portal changes straight away and remembers your choice on this device.', 'Agad magbabago ang buong portal at tatandaan ito ng device na ito.')] },
      { title: t('Download or upload a list (Excel/CSV)', 'Mag-download o mag-upload ng listahan (Excel/CSV)'), show: '.tpn-io',
        steps: [t('Lists like Orders, Staff, Menu and Inventory have Export and Import buttons at the top right.', 'May Export at Import sa kanang itaas ang mga listahan gaya ng Orders, Staff, Menu at Inventory.'),
                t('Export gives you an Excel or CSV file. Import reads one back in; "Download blank template" shows the columns it needs.', 'Ang Export ay nagbibigay ng Excel o CSV. Ang Import ay nagbabasa nito pabalik; ipinapakita ng "Download blank template" ang kailangang column.')] },
      { title: t('Change the look, text size or landing page', 'Baguhin ang itsura, laki ng letra o unang pahina'), route: 'preferences',
        steps: [t('Open Preferences (You → Preferences).', 'Buksan ang Preferences (You → Preferences).'),
                t('Pick a theme (Daylight, Dark, Night), spacing and text size.', 'Pumili ng theme (Daylight, Dark, Night), espasyo at laki ng letra.'),
                t('"Open on sign-in" chooses the page you land on.', 'Ang "Open on sign-in" ang pipili ng unang pahina mo.')] },
      { title: t('Sign out', 'Mag-sign out'), show: '.portal-logout',
        steps: [t('Tap "Out" next to your name at the bottom of the sidebar.', 'I-tap ang "Out" sa tabi ng pangalan mo sa ibaba ng sidebar.'),
                t('On a shared device, always sign out at the end of your shift.', 'Sa device na pinaghahatian, laging mag-sign out pagkatapos ng shift.')] }
    ] },
    { group: t('Service', 'Serbisyo'), items: [
      { title: t('Move an order along (received → preparing → ready → done)', 'Isulong ang order (received → preparing → ready → done)'), route: 'orders', show: '[onclick^="advanceOrder"]',
        steps: [t('Open Service → Live Orders. Each column is a stage.', 'Buksan ang Service → Live Orders. Bawat column ay isang yugto.'),
                t('Tap the button at the bottom of a card to move it to the next stage.', 'I-tap ang button sa ibaba ng card para ilipat sa susunod na yugto.'),
                t('New orders appear on their own and chime.', 'Kusang lumalabas at tumutunog ang mga bagong order.')] },
      { title: t('Take payment for a take-out or delivery order', 'Tumanggap ng bayad sa take-out o delivery'), route: 'orders', show: '[onclick^="openPaymentPanel"]',
        steps: [t('On the order card, tap "Take payment".', 'Sa card ng order, i-tap ang "Take payment".'),
                t('Choose Cash (enter what you were handed; change is worked out), Bank transfer, or Online.', 'Piliin ang Cash (ilagay ang iniabot; kukuwentahin ang sukli), Bank transfer, o Online.'),
                t('The order shows Paid once the money covers the bill.', 'Magiging Paid ang order kapag sakop na ng bayad ang bill.')] },
      { title: t('Give a senior / PWD or promo discount', 'Magbigay ng senior / PWD o promo na discount'), route: 'orders', show: '[onclick^="openDiscountPicker"]',
        steps: [t('Open the order and tap Discount.', 'Buksan ang order at i-tap ang Discount.'),
                t('Pick the discount. Senior/PWD asks for the ID number and the guest\'s share of the bill.', 'Piliin ang discount. Hihingin ng Senior/PWD ang ID number at bahagi ng bisita sa bill.'),
                t('Supervisors and up can apply discounts; removing one needs a manager.', 'Supervisor pataas ang makakapaglagay ng discount; manager ang kailangan para magtanggal.')] },
      { title: t('Cook from the kitchen queue', 'Magluto mula sa pila sa kusina'), route: 'kds',
        steps: [t('Open Service → Kitchen Queue (or the Kitchen Screen on the wall).', 'Buksan ang Service → Kitchen Queue (o ang Kitchen Screen sa dingding).'),
                t('Tap Start cooking, then Mark ready when it is plated.', 'I-tap ang Start cooking, tapos Mark ready kapag nakaplato na.'),
                t('Late tickets glow amber, then red.', 'Nagiging dilaw tapos pula ang mga ticket na nahuhuli.')] },
      { title: t('Mark a dish sold out (86)', 'Markahang ubos ang ulam (86)'), route: 'kds', show: '[onclick^="open86Panel"]',
        steps: [t('In the Kitchen Queue tap "Sold out (86)".', 'Sa Kitchen Queue i-tap ang "Sold out (86)".'),
                t('Tap the dish. Customers stop seeing it on the website, QR menu and counter at once.', 'I-tap ang ulam. Agad itong mawawala sa website, QR menu at counter.'),
                t('Tap it again when it is back.', 'I-tap ulit kapag mayroon na.')] },
      { title: t('Void an item or a whole order', 'Mag-void ng item o buong order'), route: 'void-requests',
        steps: [t('Crew and supervisors ask: open the order and use "Request void" with a reason.', 'Ang crew at supervisor ay humihiling: buksan ang order at gamitin ang "Request void" na may dahilan.'),
                t('Managers approve or deny it in Service → Void Requests.', 'Inaaprubahan o tinatanggihan ito ng manager sa Service → Void Requests.'),
                t('Every void keeps the name and reason.', 'Bawat void ay may naitalang pangalan at dahilan.')] },
      { title: t('Ring up an order at the counter', 'Mag-ring up ng order sa counter'), open: 'tpn-dine-in-floor',
        steps: [t('Open Service → Floor & Counter (it opens in its own tab).', 'Buksan ang Service → Floor & Counter (bubukas sa sariling tab).'),
                t('Use the Counter tab for take-out and delivery, or "+ Order" on a table for dine-in.', 'Gamitin ang Counter tab para sa take-out at delivery, o "+ Order" sa mesa para sa dine-in.'),
                t('Tap dishes, then "Send to kitchen". Take-out pays right away; a table pays at Close table.', 'I-tap ang mga ulam, tapos "Send to kitchen". Ang take-out ay magbabayad agad; ang mesa ay sa Close table.')] },
      { title: t('Close a table and take the money', 'Isara ang mesa at tumanggap ng bayad'), open: 'tpn-dine-in-floor',
        steps: [t('On the Floor Map, tap Bill, then Close Table on the table card.', 'Sa Floor Map, i-tap ang Bill, tapos Close Table sa card ng mesa.'),
                t('Type the cash received (or tap a quick amount). The change shows below.', 'I-type ang natanggap na cash (o i-tap ang mabilis na halaga). Lalabas ang sukli sa ibaba.'),
                t('Card or bank? Use "Other way…". The table only closes once it is paid.', 'Card o bangko? Gamitin ang "Other way…". Magsasara lang ang mesa kapag bayad na.')] },
      { title: t('Open or close the cash drawer (shift)', 'Buksan o isara ang cash drawer (shift)'), open: 'tpn-dine-in-floor',
        steps: [t('On the floor screen, open the Counter tab and tap "Open shift" with the starting cash.', 'Sa floor screen, buksan ang Counter tab at i-tap ang "Open shift" kasama ang panimulang cash.'),
                t('Use Drawer ▾ for cash in/out (e.g. bought ice) and an X read mid-shift.', 'Gamitin ang Drawer ▾ para sa cash in/out (hal. bumili ng yelo) at X read sa gitna ng shift.'),
                t('At the end, "Close shift": count each bill and coin. Any difference is recorded.', 'Sa dulo, "Close shift": bilangin ang bawat papel at barya. Naitatala ang anumang diperensya.')] }
    ] },
    { group: t('Guests & events', 'Bisita at events'), items: [
      { title: t('Answer a catering or event inquiry', 'Sagutin ang inquiry sa catering o event'), route: 'inquiries',
        steps: [t('Open Guests & events → Inquiries. New ones are marked.', 'Buksan ang Guests & events → Inquiries. May marka ang mga bago.'),
                t('Tap Call or Email, then update the status so the team knows it is handled.', 'I-tap ang Call o Email, tapos i-update ang status para alam ng team na naasikaso na.')] },
      { title: t('Look up a regular guest', 'Hanapin ang suki'), route: 'guests',
        steps: [t('Open Guests. Search by name or phone.', 'Buksan ang Guests. Maghanap ayon sa pangalan o phone.'),
                t('Add a note (allergies, favourite table) — staff see it on their next order.', 'Magdagdag ng tala (allergy, paboritong mesa) — makikita ito ng staff sa susunod nilang order.')] },
      { title: t('Give a stamp-card reward', 'Magbigay ng reward sa stamp card'), route: 'rewards', show: '[onclick^="rwScan"]',
        steps: [t('Ask the customer to open their card and tap "Show code to staff".', 'Pabuksan sa customer ang card at ipa-tap ang "Show code to staff".'),
                t('Tap "Scan their QR" (or type the code), check the reward, then Give reward.', 'I-tap ang "Scan their QR" (o i-type ang code), tingnan ang reward, tapos Give reward.'),
                t('Stamps are added by themselves for every paid order over the minimum.', 'Kusang nadadagdag ang stamp sa bawat bayad na order na lagpas sa minimum.')] }
    ] },
    { group: t('Team', 'Team'), items: [
      { title: t('Clock in or out (with photo)', 'Mag-clock in o out (may litrato)'), route: 'staff-home', staffOnly: true, show: '[onclick^="doClockIn"], [onclick^="doClockOut"]',
        steps: [t('On your Home page tap Clock In.', 'Sa Home mo, i-tap ang Clock In.'),
                t('Take a full-body photo in uniform when asked. On the restaurant Wi-Fi it is verified straight away.', 'Kumuha ng buong-katawan na litrato na naka-uniform. Sa Wi-Fi ng restaurant, agad itong verified.'),
                t('Tap Clock Out at the end of your shift.', 'I-tap ang Clock Out pagkatapos ng shift.')] },
      { title: t('Write the weekly schedule', 'Gawin ang lingguhang schedule'), route: 'schedules', show: '[onclick^="copyPrevWeekSchedules"]',
        steps: [t('Open Team → Schedules. Tap any cell to set a shift; it saves at once.', 'Buksan ang Team → Schedules. I-tap ang kahit anong cell para maglagay ng shift; agad itong nase-save.'),
                t('"Copy from prev week" fills the week from last week\'s shifts.', 'Pupunuin ng "Copy from prev week" ang linggo mula sa mga shift noong nakaraang linggo.')] },
      { title: t('Give someone a task', 'Magbigay ng task'), route: 'tasks', show: '[onclick^="openTaskEditor"]',
        steps: [t('Open Team → Task Board and tap New task.', 'Buksan ang Team → Task Board at i-tap ang New task.'),
                t('Add a title, due date and the people. Each person marks their own part done.', 'Lagyan ng pamagat, due date at mga tao. Kanya-kanyang mamarkahan ang bahagi nila.')] },
      { title: t('Check clock-in photos', 'Suriin ang mga litrato sa clock-in'), route: 'clockin-review',
        steps: [t('Open Team → Clock-in review. Ones off the restaurant Wi-Fi or without a photo are listed first.', 'Buksan ang Team → Clock-in review. Nauuna ang mga wala sa Wi-Fi ng restaurant o walang litrato.'),
                t('Tick the uniform items you can see, then Approve or Reject.', 'I-check ang mga parte ng uniform na nakikita, tapos Approve o Reject.'),
                t('At the restaurant, "Trust this network" once so clock-ins there verify on their own.', 'Sa restaurant, i-tap minsan ang "Trust this network" para kusang ma-verify ang clock-in doon.')] },
      { title: t('Fix a wrong clock-in', 'Itama ang maling clock-in'), route: 'attendance-admin',
        steps: [t('Open Team → Attendance and pick the day.', 'Buksan ang Team → Attendance at piliin ang araw.'),
                t('Tap Correct on the entry, fix the time and give a reason.', 'I-tap ang Correct sa entry, itama ang oras at magbigay ng dahilan.')] },
      { title: t('Run payroll', 'Magpatakbo ng payroll'), route: 'payroll', show: '[onclick^="openNewPayRun"]',
        steps: [t('Open Team → Payroll and tap "New pay run". Pick the dates.', 'Buksan ang Team → Payroll at i-tap ang "New pay run". Piliin ang mga petsa.'),
                t('Check each person\'s lines (allowances, deductions), approve, then mark it paid.', 'Tingnan ang bawat linya (allowance, bawas), aprubahan, tapos markahang bayad.')] },
      { title: t('Move someone to another role', 'Ilipat ang tao sa ibang role'), route: 'staff-board',
        steps: [t('Open Team → Staff Board.', 'Buksan ang Team → Staff Board.'),
                t('Drag the person\'s chip to the new role and confirm. They are told about it.', 'I-drag ang chip ng tao sa bagong role at kumpirmahin. Maaabisuhan sila.')] }
    ] },
    { group: t('Menu & stock', 'Menu at stock'), items: [
      { title: t('Add or change a dish', 'Magdagdag o magbago ng ulam'), route: 'menu-manager', show: '[onclick^="showMenuItemModal"]',
        steps: [t('Open Menu & stock → Menu Manager and tap "Add Item" (or Edit on a dish).', 'Buksan ang Menu & stock → Menu Manager at i-tap ang "Add Item" (o Edit sa ulam).'),
                t('Set the name, price (or prices per size), category and photo emoji. Save.', 'Ilagay ang pangalan, presyo (o presyo bawat laki), kategorya at emoji. I-save.')] },
      { title: t('Add extras like "Extra rice +₱25"', 'Magdagdag ng extra gaya ng "Extra rice +₱25"'), route: 'modifiers',
        steps: [t('Open Menu & stock → Add-ons & choices and make a group (e.g. "Extras").', 'Buksan ang Menu & stock → Add-ons & choices at gumawa ng grupo (hal. "Extras").'),
                t('Add choices with their price, then link the group to its dishes.', 'Magdagdag ng pagpipilian at presyo, tapos i-link ang grupo sa mga ulam.')] },
      { title: t('Set up a discount or promo', 'Gumawa ng discount o promo'), route: 'discounts', show: '[onclick^="openDiscountTemplateEditor"]',
        steps: [t('Open Menu & stock → Discounts & Promos and tap New template.', 'Buksan ang Menu & stock → Discounts & Promos at i-tap ang New template.'),
                t('Choose percent or fixed peso, any cap or minimum, and whether it needs an ID.', 'Piliin ang porsyento o tiyak na piso, limit o minimum, at kung kailangan ng ID.')] },
      { title: t('Record a delivery or stock count', 'Magtala ng delivery o bilang ng stock'), route: 'inventory', show: '[onclick^="openStockMovement"]',
        steps: [t('Open Menu & stock → Inventory.', 'Buksan ang Menu & stock → Inventory.'),
                t('Use "Receive a delivery" when stock arrives, and "Adjust" for spoilage or a recount.', 'Gamitin ang "Receive a delivery" pagdating ng stock, at "Adjust" para sa sira o muling bilang.'),
                t('Low items get a warning badge.', 'May babala ang mga paubos na.')] },
      { title: t('Add a table or print its QR code', 'Magdagdag ng mesa o i-print ang QR nito'), route: 'table-qr', show: '[onclick^="promptAddTable"]',
        steps: [t('Open Menu & stock → Table QR Codes.', 'Buksan ang Menu & stock → Table QR Codes.'),
                t('"+ Add Table" adds one; "Print All" prints every code to stick on the tables.', 'Ang "+ Add Table" ay nagdadagdag; ang "Print All" ay nagpi-print ng lahat ng code para idikit sa mesa.')] }
    ] },
    { group: t('Money', 'Pera'), items: [
      { title: t('Close the day (count the cash)', 'Isara ang araw (bilangin ang cash)'), route: 'daily-close', show: '[onclick^="openCloseTill"], [onclick^="doCloseTill"]',
        steps: [t('Open Money → Daily Close at the end of the day.', 'Buksan ang Money → Daily Close sa dulo ng araw.'),
                t('It lists unpaid orders and unconfirmed bank transfers first — settle those.', 'Nauuna ang mga hindi bayad na order at hindi kumpirmadong bank transfer — ayusin muna iyon.'),
                t('Count the cash, enter it and close. Any difference is kept on record.', 'Bilangin ang cash, ilagay at isara. Naitatala ang anumang diperensya.')] },
      { title: t('Confirm a bank transfer or refund a payment', 'Kumpirmahin ang bank transfer o mag-refund'), route: 'payments',
        steps: [t('Open Money → Payments.', 'Buksan ang Money → Payments.'),
                t('A transfer stays "pending" until someone else checks the bank app and confirms it.', 'Naka-"pending" ang transfer hanggang may ibang tumingin sa bank app at kumpirmahin.'),
                t('Refund (manager): pick the payment, the amount and a reason.', 'Refund (manager): piliin ang bayad, halaga at dahilan.')] },
      { title: t('See sales and costs', 'Tingnan ang benta at gastos'), route: 'finance', show: '[onclick^="openExpenseEditor"]',
        steps: [t('Money → Finance shows sales, costs and profit by day, week or month.', 'Ipinapakita ng Money → Finance ang benta, gastos at kita ayon sa araw, linggo o buwan.'),
                t('Record rent, gas and other costs with "Add expense".', 'Itala ang upa, gas at iba pang gastos gamit ang "Add expense".'),
                t('Performance shows top dishes and busy hours.', 'Ipinapakita ng Performance ang pinakamabentang ulam at oras na pinakamarami.')] }
    ] },
    { group: t('Inbox', 'Inbox'), items: [
      { title: t('Clear notifications', 'Linisin ang mga notification'), route: 'notifications', show: '[onclick^="markAllNotificationsRead"]',
        steps: [t('Open Inbox → Notifications. Tap one to read it and jump to it.', 'Buksan ang Inbox → Notifications. I-tap para basahin at puntahan.'),
                t('"Mark all read" clears the count for you only; × hides one for you.', 'Ang "Mark all read" ay para sa iyo lang; ang × ay nagtatago para sa iyo.')] },
      { title: t('Send a message to the team', 'Magpadala ng mensahe sa team'), route: 'messages-admin', show: '[onclick^="openComposeMessageModal"]',
        steps: [t('Open Inbox → Messages and tap Compose.', 'Buksan ang Inbox → Messages at i-tap ang Compose.'),
                t('Pick one person, or "everyone" to broadcast to the branch.', 'Pumili ng isang tao, o "everyone" para sa buong branch.')] }
    ] },
    { group: t('Website', 'Website'), items: [
      { title: t('Change the phone, hours, FAQs or event packages', 'Baguhin ang phone, oras, FAQ o event package'), route: 'website',
        steps: [t('Open Website. Pick a tab: Contact & hours, FAQs, Testimonials, Event packages.', 'Buksan ang Website. Pumili ng tab: Contact & hours, FAQs, Testimonials, Event packages.'),
                t('Edit and Save — the public site shows it straight away.', 'I-edit at i-save — agad itong lalabas sa site.'),
                t('Only publish testimonials the customer agreed to.', 'I-publish lang ang testimonial na pinayagan ng customer.')] }
    ] },
    { group: t('Accounts & access', 'Account at access'), items: [
      { title: t('Add a staff account', 'Magdagdag ng staff account'), route: 'accounts', show: '[onclick^="showCreateStaffModal"]',
        steps: [t('Open Accounts and tap "Add Staff Account".', 'Buksan ang Accounts at i-tap ang "Add Staff Account".'),
                t('Enter their name, email and role, and a temporary password.', 'Ilagay ang pangalan, email at role nila, at pansamantalang password.'),
                t('Give them the password in person; they change it after signing in.', 'Ibigay nang personal ang password; papalitan nila ito pagka-sign in.')] },
      { title: t('Decide what a role can do', 'Piliin ang kayang gawin ng isang role'), route: 'roles', show: '[onclick^="openRoleEditor"]',
        steps: [t('Open Accounts → Roles & Access. Tap a role to see its permissions.', 'Buksan ang Accounts → Roles & Access. I-tap ang role para makita ang mga pahintulot.'),
                t('Tick or untick. 🔒 means the role is too junior for that permission.', 'I-check o i-uncheck. Ang 🔒 ay ibig sabihing masyadong mababa ang role para doon.'),
                t('The Access Matrix shows every role side by side.', 'Ipinapakita ng Access Matrix ang lahat ng role nang magkakatabi.')] },
      { title: t('See who did what', 'Tingnan kung sino ang gumawa ng ano'), route: 'audit',
        steps: [t('Open Accounts → Audit Log. Every change is listed with the person and time.', 'Buksan ang Accounts → Audit Log. Nakalista ang bawat pagbabago kasama ang tao at oras.')] }
    ] }
  ];

  const FLOOR_TOPICS = [
    { group: t('Floor & counter', 'Floor at counter'), items: [
      { title: t('Read the floor map', 'Basahin ang floor map'), show: '.floor-grid',
        steps: [t('Each card is a table. Colours: empty, occupied, cooking, food ready, bill asked.', 'Bawat card ay isang mesa. Kulay: bakante, may tao, niluluto, handa na, humingi ng bill.'),
                t('A red badge on top means a guest pressed "Call staff" or "Bill" on their phone.', 'Ang pulang badge sa itaas ay ibig sabihing pinindot ng bisita ang "Call staff" o "Bill" sa phone nila.')] },
      { title: t('Add an order to a table', 'Magdagdag ng order sa mesa'), show: '[onclick^="floorAddOrder"]',
        steps: [t('Tap "+ Order" on the table. The Counter opens set to that table.', 'I-tap ang "+ Order" sa mesa. Bubukas ang Counter na naka-set sa mesang iyon.'),
                t('Tap dishes, then "Send to kitchen". It pays when the table closes.', 'I-tap ang mga ulam, tapos "Send to kitchen". Magbabayad ito pagsara ng mesa.')] },
      { title: t('Ring up take-out or delivery', 'Mag-ring up ng take-out o delivery'), show: '#tab-counter',
        steps: [t('Open the Counter tab, choose Take-out or Delivery.', 'Buksan ang Counter tab, piliin ang Take-out o Delivery.'),
                t('Tap dishes, "Send to kitchen & take payment", then take the cash.', 'I-tap ang mga ulam, "Send to kitchen & take payment", tapos tanggapin ang cash.')] },
      { title: t('Close a table and take the money', 'Isara ang mesa at tumanggap ng bayad'), show: '[onclick^="closeTable"], [onclick^="markBillReady"]',
        steps: [t('Tap Bill, then Close Table.', 'I-tap ang Bill, tapos Close Table.'),
                t('Enter the cash received; the change shows. Card or bank? "Other way…".', 'Ilagay ang natanggap na cash; lalabas ang sukli. Card o bangko? "Other way…".')] },
      { title: t('Open or close the cash drawer', 'Buksan o isara ang cash drawer'), show: '#tab-counter',
        steps: [t('Counter tab → "Open shift" with the starting cash.', 'Counter tab → "Open shift" kasama ang panimulang cash.'),
                t('Drawer ▾ → Close shift at the end, and count each bill and coin.', 'Drawer ▾ → Close shift sa dulo, at bilangin ang bawat papel at barya.')] },
      { title: t('Turn the sound on', 'Buksan ang tunog'),
        steps: [t('Tap the screen once after it turns on — browsers keep sound off until you do.', 'I-tap minsan ang screen pagbukas nito — naka-off ang tunog hanggang gawin mo ito.')] }
    ] }
  ];
  const KITCHEN_TOPICS = [
    { group: t('Kitchen screen', 'Screen sa kusina'), items: [
      { title: t('Work the tickets', 'Asikasuhin ang mga ticket'),
        steps: [t('New tickets appear on the left and chime.', 'Lumalabas sa kaliwa at tumutunog ang mga bagong ticket.'),
                t('Tap a ticket to start cooking, then "Mark Ready" when it is plated.', 'I-tap ang ticket para simulang lutuin, tapos "Mark Ready" kapag nakaplato na.'),
                t('Amber means getting late, red means late.', 'Ang dilaw ay ibig sabihing nahuhuli na, ang pula ay huli na.')] },
      { title: t('Turn the sound on', 'Buksan ang tunog'),
        steps: [t('Tap the screen once after it turns on.', 'I-tap minsan ang screen pagbukas nito.')] }
    ] }
  ];

  /* ── Tours ──────────────────────────────────────────────────── */
  const TOURS = {
    admin: [
      { title: t('Welcome to the TPN portal 👋', 'Maligayang pagdating sa TPN portal 👋'), body: t('A one-minute tour of where things are. You can replay it any time from the ? button.', 'Isang minutong tour kung nasaan ang mga bagay. Pwede mo itong ulitin kahit kailan sa ? na button.') },
      { sel: '#portalNav', title: t('The sidebar', 'Ang sidebar'), body: t('Pages are grouped: Service, Team, Menu & stock, Money and more. Tap a group to open it.', 'Naka-grupo ang mga pahina: Service, Team, Menu & stock, Money at iba pa. I-tap ang grupo para buksan.') },
      { sel: '#hubTabsAdmin:not([hidden])', title: t('Tabs inside a group', 'Mga tab sa loob ng grupo'), body: t('A group\'s pages are tabs across the top. Each group remembers the tab you used last.', 'Ang mga pahina ng grupo ay tab sa itaas. Tinatandaan ng bawat grupo ang huling tab na ginamit mo.') },
      { sel: '.portal-lang, .lang-btn', title: t('English or Tagalog', 'English o Tagalog'), body: t('Switch the whole portal\'s language here.', 'Dito palitan ang wika ng buong portal.') },
      { sel: '.tpn-io', title: t('Excel / CSV', 'Excel / CSV'), body: t('Lists have Export and Import here, for files you can open in Excel.', 'May Export at Import ang mga listahan dito, para sa mga file na nabubuksan sa Excel.') },
      { sel: '#tpnHelpBtn', title: t('Stuck? Tap ?', 'Naipit? I-tap ang ?'), body: t('Search "how do I…" for any task. "Show me" takes you to the right button.', 'Hanapin ang "paano…" para sa kahit anong gawain. Dadalhin ka ng "Ipakita" sa tamang button.') },
      { sel: '#portalUser', title: t('Your account', 'Ang account mo'), body: t('Your name and role. Tap "Out" to sign out at the end of your shift.', 'Pangalan at role mo. I-tap ang "Out" para mag-sign out pagkatapos ng shift.') }
    ],
    staff: [
      { title: t('Welcome to your workspace 👋', 'Maligayang pagdating sa workspace mo 👋'), body: t('A quick look around. Replay it any time from the ? button.', 'Mabilisang silip. Ulitin kahit kailan sa ? na button.') },
      { sel: '[onclick^="doClockIn"], [onclick^="doClockOut"]', title: t('Clock in here', 'Dito mag-clock in'), body: t('Start every shift with Clock In and a uniform photo. Clock Out when you leave.', 'Simulan ang bawat shift sa Clock In at litrato na naka-uniform. Mag-Clock Out pag-alis.') },
      { sel: '#staffNav', title: t('Your pages', 'Ang mga pahina mo'), body: t('My work (orders, tasks), My shifts (schedule, attendance) and Inbox.', 'My work (order, task), My shifts (schedule, attendance) at Inbox.') },
      { sel: '#tpnHelpBtn', title: t('Need help?', 'Kailangan ng tulong?'), body: t('Tap ? to search how to do anything.', 'I-tap ang ? para hanapin kung paano gawin ang kahit ano.') }
    ],
    floor: [
      { title: t('The floor screen 👋', 'Ang floor screen 👋'), body: t('Tables, the counter and the bills, in one place.', 'Mesa, counter at bill, nasa iisang lugar.') },
      { sel: '#tab-nav', title: t('Tabs', 'Mga tab'), body: t('Floor Map for tables, Counter to ring up orders, Dine-In Orders for what is cooking.', 'Floor Map para sa mesa, Counter para mag-ring up, Dine-In Orders para sa niluluto.') },
      { sel: '.floor-grid .table-card', title: t('A table', 'Isang mesa'), body: t('"+ Order" adds an order. Bill, then Close Table, takes the money.', 'Ang "+ Order" ay nagdadagdag ng order. Bill, tapos Close Table, para tumanggap ng bayad.') },
      { sel: '[data-lang-toggle]', title: t('Language', 'Wika'), body: t('Switch this screen between English and Tagalog.', 'Palitan ang wika ng screen na ito.') },
      { sel: '#tpnHelpBtn', title: t('Help', 'Tulong'), body: t('Tap ? any time for step-by-step help.', 'I-tap ang ? kahit kailan para sa sunud-sunod na tulong.') }
    ],
    kitchen: [
      { title: t('The kitchen screen 👋', 'Ang screen sa kusina 👋'), body: t('Tap a ticket to start it, then Mark Ready. Late tickets turn amber, then red.', 'I-tap ang ticket para simulan, tapos Mark Ready. Nagiging dilaw tapos pula ang nahuhuli.') },
      { sel: '[data-lang-toggle]', title: t('Language', 'Wika'), body: t('Switch this screen between English and Tagalog.', 'Palitan ang wika ng screen na ito.') },
      { sel: '#tpnHelpBtn', title: t('Help', 'Tulong'), body: t('Tap ? any time for help.', 'I-tap ang ? kahit kailan para sa tulong.') }
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

  window.TPN_GUIDE = { open: openPanel, tour: () => startTour(true), topics: () => topicsHere() };
})();
