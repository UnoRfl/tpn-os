# TPN OS — the complete guide

Everything about TPN OS, Tyo Paeng Nyo's restaurant system: every screen and what is on it, the design system and every asset, the code and how the pieces talk, the hardware links, the database with its money rules, roles and security, the daily workflows, how changes go live, and the full history. Written from the code on Oct 22, 2026 (HANDOFF Rev 37). The machines themselves (the iMin, the kitchen printer, building the apps at home and the simulator) have their own guide: [HARDWARE.md](HARDWARE.md).

**How to read it.** Each part starts with the plain-English picture, then the exact files, functions and settings, so the owner and a developer can both use it. "Not found in code" means the guide looked and found no answer; it doesn't guess.

## Contents

- **Part 1 — Screens, design system and assets:** every page and portal tab, colours, fonts, components, the owner's design rules, every image and library, the printed slips, English and Tagalog.
- **Part 2 — Front-end code, devices and printing:** how the pages are built, every module, live updates, the two Android apps, the hardware links, every browser-storage key, client security.
- **Part 3 — Database, money rules, roles and security:** every migration and table, every server function the apps call, the role ladder and permission keys, the hard money rules, the tests, known findings.
- **Part 4 — Operations, workflows and history:** each daily workflow step by step, deployment, app releases, backups, the go-live checklist, the working conventions ("frameworks followed"), every revision, where everything lives.

## Changed after this guide was researched

- **Orders have one door (sql/47, live Oct 22).** Part 3 (3.9) found that any signed-in staff account could insert an order row directly, with any total and already "paid". That is now closed: `orders_auth_create` is dropped and `INSERT` on `orders` is revoked from guests and staff, so every order goes through `submit_order`. Where Part 3 mentions `orders_auth_create` refusing the screen accounts, that policy no longer exists. Next free migration: 48.
- **Fonts on the portal.** Part 1 noted that the portal serves the v3 faces under its old names ("DM Sans" = Plus Jakarta Sans, "Playfair Display" = Fraunces), so `tpn-forms.css` fell back to system fonts there. `tpn-forms.css` now lists those names as fallbacks (`?v=20261022b`).
- **Still open from Part 3 (3.9):** personal overrides and custom roles can go below a permission's minimum tier; `payroll.run` can change a run's status directly; a manual "bank" payment is marked received without the second-person check; a paid bill's total can still move (direct discount or service-charge edits by supervisor+, `remove_discount`, `void_order_item`); some functions don't check the branch argument is yours; some reports cut days at UTC midnight instead of Manila; production has three policies that aren't in `sql/`.

---

## Part 1 — Screens, design system and assets

This part of the TPN OS guide covers everything you can see: every page, every tab in the staff portal, the colours, fonts, shapes and motion, every image and font file, the printed slips, and the English/Tagalog switch.

Everything here was read from the code in the `tpn-os` repository (branch `main`, up to commit `c4d5b4b`, "Rev 37", 22 Oct 2026 19:35). File paths are relative to the repository root. Line numbers are given where they help you find something; they will drift as the code changes. Where something could not be confirmed from the code, it says so.

**Where the site lives:** `https://unorfl.github.io/tpn-os/` (GitHub Pages). The same address is the default the Android apps open (`android/app/build.gradle` line 10). A `vercel.json` with `cleanUrls: true` is also in the repo, but `README.md` (line 88–97) says Vercel is not needed and GitHub Pages is the host.

**Short addresses (no `.html`):** GitHub Pages answers both `/portal` and `/portal.html`. Every page also has a small script that, if the address ends in `.html`, rewrites it in the address bar without reloading (for example `index.html` lines 52–60, `portal.html` lines 30–37, `tpn-table-menu.html` lines 47–52, `tpn-rewards.html` line 9). Links inside the system use the short form (`portal`, `tpn-dine-in-floor`, `tpn-rewards`). One exception: the website footer's **Staff Login** button goes to `portal.html` with the extension (`index.html` line 2187), which the portal then shortens.

---

### 1. The screens

#### 1.1 All pages at a glance

| Page file | Address | Who uses it | Sign-in |
|---|---|---|---|
| `index.html` | `/tpn-os/` (sections by `#menu`, `#events` …) | The public: customers ordering pickup/delivery, event and catering enquiries | None |
| `portal.html` | `/tpn-os/portal` (tab by `?view=<route id>`) | All staff. Dining and kitchen crew get "My Workspace"; supervisor and up get the management view | Email + password |
| `tpn-dine-in-floor.html` | `/tpn-os/tpn-dine-in-floor` | The floor and counter screen (the iMin D4 counter, via the TPN Counter app), managers, dining staff with `floor.view`, the shared `dine_in_display` screen account | Station sign-in (`modules/signin.js`) |
| `tpn-dine-in-floor-customer.html` | `/tpn-os/tpn-dine-in-floor-customer` | The customer-facing screen on the back of the iMin counter | None (no buttons) |
| `tpn-kitchen-station.html` | `/tpn-os/tpn-kitchen-station` | The kitchen wall screen (TPN Kitchen app), kitchen staff, the shared `kitchen_display` account | Station sign-in |
| `tpn-table-menu.html` | `/tpn-os/tpn-table-menu?table=3&branch=Las%20Piñas&branchId=laspinas` | Dine-in guests, by scanning the QR on their table | None |
| `tpn-rewards.html` | `/tpn-os/tpn-rewards` (claim link adds `?claim=<order no.>&t=<token>`) | Customers checking their stamp card | Phone number + order proof |

Other `.html` files in the repo, neither part of the restaurant's screens:
- `tools/imin-sim/dashboard.html` — the **iMin simulator** dashboard, a developer tool added in Rev 37. `node tools/imin-sim/imin-sim.js --local` serves it at `http://127.0.0.1:7070/` (`tools/imin-sim/README.md`). It pretends to be the counter's iMin D4 so the real pages can be tested on a PC: drop-downs for the counter printer (Ready / Out of paper / Cover open / Print service not installed), the kitchen printer (Ready / Unplugged), the app link (TPN Counter 1.4+ / No app) and a print delay; buttons **Open counter**, **Open rear screen**, **Open kitchen**, **Clear**; and panels showing both printers' paper rolls, the rear screen and the drawer/event log. It uses the v3 colours and Fraunces + Plus Jakarta Sans from Google Fonts, and gets the QR library from the simulator at `/qrcode.js` (which serves `vendor/qrcode-generator-1.4.4.js`). Full instructions are in `HARDWARE.md` section 7.
- `tests/db/node_modules/@electric-sql/pglite/dist/pglite.html`, which belongs to a third-party test library (PGlite) used by the database tests.

**Station apps send people back to their station.** If a page is opened inside the TPN Counter or TPN Kitchen Android app (its browser identifies itself with `TPNCounter/…` or `TPNKitchen/…`), `tpn-kit.js` lines 21–32 do two things: they add the class `tpn-lite` to the page (a cheaper drawing mode, see 2.6), and if the page is the public site, the QR table menu or the rewards page, they send the app to `tpn-dine-in-floor` (Counter) or `tpn-kitchen-station` (Kitchen).

---

#### 1.2 `index.html` — the public website

**Who:** customers. **What it is:** one page that swaps between sections without reloading (`navigate(page)`, `index.html` line 1164). Each section is a `<div class="page" id="page-…">`. A link with `#faq`, `#events`, `#menu` and so on opens that section directly (`index.html` lines 2333–2337).

**Loads (in order):**
- Fonts: one Google Fonts request for Playfair Display, Lora, DM Sans, Fraunces and Plus Jakarta Sans (line 17; see 4.4).
- Styles: `tpn-app.css` → `tpn-glass.css` → `tpn-site-v3.css` in the head (lines 18–20); `tpn-forms.css` last, just before `</body>` (line 2348).
- Scripts (all in the head, preloaded): `vendor/supabase-js-2.117.2.js` (with a hash-checked CDN fallback, lines 29–34) → `config.js` → `tpn-supabase.js` → `tpn-kit.js` → `tpn-site.js` → `tpn-i18n.js` → `modules/photos.js` → `tpn-home.js`, then the large inline script in the page.
- `assets/site/hero.webp` is preloaded with high priority (line 28).

**Always on screen:**
- **Boot overlay** (`#tpn-boot`, lines 75–79): dark brown screen with "Tyo Paeng Nyo", "Authentic Filipino Since 2003" and a spinner while the page starts.
- **Top bar** (`#mainNav`, lines 85–113): wordmark "Tyo Paeng *Nyo*" (goes home), links **Home**, **Menu**, a drop-down **Events & Catering** (Events, Concessions), a drop-down **Visit** (Our Restaurant, About, FAQ), the **Tray** button (cloche icon + count), the **EN / TL** language switch, a ☰ button on phones, and the round logo badge pinned at the right.
- **Phone menu** (`#mobileMenu`, lines 115–128): the same links stacked, plus Tray and English/Tagalog.
- **Tray drawer** (`#cartDrawer`, lines 545–558): "Your Order", the items, Subtotal, Total, **Proceed to Checkout →**.
- **Floating tray button** (`#cartFab`) on phones; hidden at 901px and wider (`tpn-site-v3.css` line 378) and on checkout.
- **Connection banner** (`#connectionBanner`): "📶 Looks like your connection has a problem…" with **I-reload →**.
- **Toast** (`#toast`) and the shared **modal** (`#modalOverlay`).

**Sections ("pages"):**

| Section | What is on it | Main buttons |
|---|---|---|
| Home (`#page-home`) | Full-screen hero: the food-spread photo fixed behind the page, a slowly turning mandala, the engraved title "Tyo Paeng Nyo". Bestsellers "bento" grid (filled live from dishes marked featured, dishes with a photo first). A hidden testimonials block (shown when testimonials exist). "Our *place*": two photo panels and a map. A closing "Salamat *po!*" band. | **Start your order** (→ Menu), **See bestsellers** (scrolls) |
| Menu (`#page-menu`) | Page header with the eyebrow "Order online" and engraved "Menu" title; search box ("Search sinigang, lechon, sisig…"); category chips; the dish cards. | **+** on each size of each dish adds it to the tray |
| Our Restaurant (`#page-restaurant`) | Photo + four facts (Address, Hours, Phone, Parking — all editable from the portal's Website tab); "We've *moved*" with three numbered steps and a map. | Map opens Google Maps |
| Concessions (`#page-concessions`) | Eyebrow "For businesses"; four cards with emoji icons (Office Catering 🏢, On-Site Concessions 🏬, Schools & Institutions 🎓, Large Corporate Events 🎉); the form "Tell us what you *need*" (name, role, company, industry, email, phone, preferred contact, headcount, service type, timing, notes). | **Send Inquiry**, **Cancel** |
| Events (`#page-events`) | Eyebrow "Events & catering"; four cards (Celebrations 🎂, Weddings & Debuts 💍, Corporate Events 🏢, Customize ✨); "Starting *Rates*" packages (hidden until packages exist); "🍽️ Try before you book" box; the form "Let's Make It *Special*" (name, phone, email, event type, pax, date, venue, notes). | **Request a food tasting**, **Send Inquiry**, **Cancel** |
| About (`#page-about`) | Engraved title and three paragraphs of the restaurant's story. | — |
| FAQ (`#page-faq`) | Search box and the question list (loaded from the database). | — |
| Checkout (`#page-checkout`) | Step circles 1–4 and the step card (see below). | — |

**Checkout steps** (`renderCheckoutStepView`, line 1562):
1. "How to receive your order?" — Takeout / Pickup 🥡 or Delivery 🛵, a note telling dine-in guests to scan their table QR, then "When?" (date and time). **Continue →**
2. "Your Information" — Full Name, Phone, Delivery Address (delivery only), Special Requests. **← Back**, **Continue →**
3. "Payment" — Pay online now (only when the owner has switched online payments on), Cash, GCash / Maya / QR Ph, Card. **Review Order →**
4. "Review & Confirm" — **Place Order ✓**
5. Confirmation — "Order *Placed!*" with a small animated printer that feeds out the receipt (`.rcpt-*` styles, `tpn-site-v3.css` lines 398–435), the order reference and order tracking.

**Footer** (lines 506–541): wordmark, "Established 2003 · Las Piñas", the tagline "Kapag iyong natikman, hindi mo titigilan.", Facebook/Instagram links, "We accept" (Cash, QR Ph, GCash, Maya, Cards, Bank transfer for events & catering), Contact, Hours, a **Stamp card** link (only when rewards are switched on), the copyright line and **Staff Login** (→ portal).

**Where the text comes from:** contact details, hours, FAQs, testimonials and event packages are read from the database by `tpn-site.js` into elements marked `data-site="…"`. If the database cannot be reached, the last saved copy on the device is used, and failing that, the text written in `index.html` (`tpn-site.js` header).

---

#### 1.3 `portal.html` — the staff portal

**Who:** every staff member. **Loads:**
- Scripts in the head: supabase-js (local, CDN fallback) → `config.js` → `tpn-supabase.js` → `tpn-kit.js` → `tpn-site.js` → `tpn-i18n.js` (lines 12–22).
- Styles in the head: `tpn-app.css` → `tpn-glass.css` → `tpn-portal.css` (lines 53–55). There is no Google Fonts stylesheet link; `tpn-portal.css` loads the font files itself (see 2.3).
- At the end of the page (lines 8843–8860): `modules/website.js`, `vendor/qrcode-generator-1.4.4.js`, `modules/payments.js`, `modules/invoices.js`, `modules/photos.js`, `modules/pos.js`, `vendor/imin-printer-1.4.0.min.js`, `modules/slips.js`, `modules/kprint.js`, `modules/imin.js`, `modules/modifiers.js`, `modules/clockin.js`, `modules/stamps.js`, `modules/excel-io.js`, `modules/delivery.js`, `modules/guide.js`, `modules/search.js`, then `tpn-forms.css` last.
- `vendor/exceljs-4.4.0.min.js` is not loaded up front. It is fetched the first time someone exports to Excel (`_loadExcelJS`, line 4714), with the pinned jsDelivr copy as a fallback.

##### Sign-in screens

- **Login** (`#portal-login`, lines 76–122). Left: brick panel with "Tyo Paeng *Nyo*", "Staff Portal", "Welcome back, *kabayan*.", a short blurb and "SECURE STAFF ACCESS". Right: **← Back to Site**, "Staff Sign In", "Welcome.", "Sign in with your TPN staff account.", English/Tagalog buttons, Email, Password (👁 to show), "Remember this device", "Forgot password?" (only shows a toast: contact your administrator), **Sign In**.
- What happens on **Sign In** (`attemptLogin`, line 930): a 15-second deadline; accounts that are pending, flagged, suspended or disabled get a plain message and are signed out; an unreachable server is reported as such, not as a wrong password.
- **Screen accounts** (`kitchen_display`, `dine_in_display`) never see the portal: they are sent straight to the kitchen screen or the floor (`redirectDisplayAccount`, lines 1032–1043).
- **Two-factor screen** (`#portal-2fa`, lines 124–157): "One more *step*." and a 6-digit code box. **Not reachable:** nothing in the code opens this screen, and its **Verify** button just enters the portal (`verifyTwoFA`, line 998, comment "Skip for MVP"). It is leftover markup.
- **Idle sign-out:** management sessions sign out after 30 minutes without activity, with a warning 2 minutes before (`IDLE_LIMIT_MS`, line 1099). Screen accounts are exempt.

##### Layout

Two layouts share one set of styles:
- **Management view** (`#portal-admin`) for supervisor, manager, admin, director and CEO.
- **My Workspace** (`#portal-staff`) for the `dining` and `kitchen` roles.

Each has: a left sidebar (wordmark, "Staff Portal" or "My Workspace", the English/Tagalog switch, a "clear badges" button when any red count is showing, the hub list, and the person's initials, name, role and an **Out** button); a phone bar with ☰; a tab strip at the top of the content; the content area.

**Hubs.** The sidebar no longer lists 30+ pages. Related pages share one row (a "hub"); inside a hub the pages are tabs across the top, which become a drop-down on a phone (`TPN_HUBS`, line 1423; `tpnTabs`, `tpn-kit.js` line 498). A hub with one page shows that page's name; a hub with none is hidden; each hub reopens the tab you used last. Hub icons are drawn line icons (1.8 stroke), not emoji (`TPN_HUB_SVG`, line 1461). Floor & Counter and Kitchen Screen open in a new browser tab, marked ↗.

**Who sees what.** Each page has a permission key. The sidebar only shows pages your access role allows (`TPN.can`), and the database refuses the underlying reads and writes anyway (comment at line 1557). The "lowest role by default" below is each permission's `min_tier` as seeded in `sql/19-access-control.sql` and later migrations (named in brackets). Roles rank, lowest first: `kitchen_display`, `dine_in_display`, `dining`, `kitchen`, `supervisor`, `manager`, `admin`, `director`, `ceo` (`sql/01-schema.sql` line 8 + `sql/15a-display-roles.sql` lines 32–33). An owner can change any grant in **Roles & Access** / **Access Matrix**, so treat this column as the starting point, not a guarantee.

##### Management view: every route

Routes come from two places: the built-in list in `renderAdminSidebar` (lines 1549–1631) drawn by `renderRouteInto` (line 1718), and tabs that modules add through `TPN_MOD.register` (`tpn-kit.js` lines 52–104). An unknown route id falls back to the Dashboard.

| Route id | Label (Tagalog) | Hub | Permission (lowest role by default) | What it does |
|---|---|---|---|---|
| `dashboard` | Dashboard | Today | `dashboard.view` (dining) | "Good day, *name*." with tiles and two panels, "Needs Attention" and "Recent Orders". Tiles depend on rank: Revenue Today, Orders Today, Active Staff, Open Inquiries — or Active Orders, In the Kitchen, Active Staff, Inquiries (lines 1791–1881). **Refresh**, **View All →** |
| `orders` | Live Orders (Mga Order) | Service | `orders.view` (dining) | The active order queue. Each order has a "next step" button, **💸 Discount**, **🚫 Void items** or **🚫 Request void** |
| `kds` | Kitchen Queue (Pila sa Kusina) | Service | `kds.view` (kitchen_display) | Received and preparing tickets, oldest first. **Start Cooking →**, **Mark Ready ✓**; **🚫 Sold out (86)** for people with `menu.86` or `menu.edit` |
| `deliveries` *(module `delivery.js`)* | Deliveries (Mga delivery) | Service | `delivery.dispatch` (dining) | Tabs Active / Done today / Areas & fees. **Assign**, **🛵 On the way**, **✓ Delivered**, **Couldn't deliver**, **Take payment**, **＋ Add area** |
| `void-requests` | Void Requests, or My Void Requests for people who cannot approve | Service | `voids.request` (kitchen_display); approving needs `voids.approve` (manager) | Every void goes through here. **✓ Approve void**, **✗ Deny**, **Withdraw request** |
| `floor` | Floor & Counter ↗ | Service | `floor.view` (kitchen_display) | Opens `tpn-dine-in-floor` in a new tab |
| `kitchen-station` | Kitchen Screen ↗ | Service | `kitchen_station.view` (kitchen_display) | Opens `tpn-kitchen-station` in a new tab |
| `inquiries` | Inquiries (Mga Tanong) — page title "Inbox" | Guests & events | `inquiries.view` (supervisor) | Business and event enquiries from the website. **Mark In Progress**, **Close** |
| `guests` | Guests (Mga Bisita) | Guests & events | `orders.view` (dining) | Past customers, what they usually order, and anyone worth a second look |
| `rewards` *(module `stamps.js`)* | Rewards | Guests & events | `rewards.redeem` (supervisor) | Redeem a stamp card: **📷 Scan their QR** or type the 6-digit code, **Give reward**. Settings (on/off, minimum order, stamps needed, reward, expiry) need `rewards.manage` (manager) |
| `staff-board` | Staff Board | Team | `staff.view` (dining) | Team assignments; people who may drag staff between branches and roles can do so |
| `tasks` | Task Board | Team | `tasks.view` (dining) | Assign work to one or several people; each marks their own progress |
| `schedules` | Schedules | Team | `schedules.view` (dining) | Weekly grid, edit by clicking a cell. **← Prev**, **This Week**, **Next →**, **Copy from prev week**, notes |
| `attendance-admin` | Attendance | Team | `attendance.view` (dining) | Clock-in/out records for the branch. **Correct** |
| `clockin-review` *(module `clockin.js`)* | Clock-in review | Team | `attendance.verify` (manager) | Clock-ins off the restaurant Wi-Fi, with no photo, or with uniform to check. **Approve**, **Approve + trust IP**, **Flag**, **📶 Trust this network** |
| `payroll` | Payroll | Team | `payroll.view` (admin) | Work out a pay period, review each person, record it as paid. **New run**, **Pay rates** |
| `menu-manager` | Menu Manager | Menu & stock | `menu.view` (dining) | The dish list from the database. **+ Add Item** |
| `modifiers` *(module `modifiers.js`)* | Add-ons & choices (Add-ons) | Menu & stock | `menu.edit` (manager) | Groups like egg style, extras, spice level, and their choices. **+ New group**, **+ Choice**, **⬆ Import** |
| `discounts` | Discounts & Promos | Menu & stock | `discounts.view` (supervisor) | Reusable discount presets used from Live Orders and the floor. **+ New template** (needs edit rights) |
| `inventory` | Inventory | Menu & stock | `inventory.view` (kitchen) | Ingredients in, out and left. **Receive**, **New item** |
| `variance` | Stock Variance | Menu & stock | `inventory.view` (kitchen) | Delivered, used, wasted, found short and closing stock, with the peso loss |
| `table-qr` | Table QR Codes | Menu & stock | `tables.manage` (manager) | One QR per table. Each QR points to `…/tpn-table-menu?table=N&branch=<name>&branchId=<code>` (lines 3115, 3146). **+ Add Table**, **🖨️ Print All**, **Open Menu →** |
| `website` *(module `website.js`)* | Website | Website | `site.edit` (manager) | Tabs Contact & hours, FAQs, Testimonials, Event packages. Changes go live on save. Also holds the "Online payments (HitPay): type yes to turn on" switch (`payments.online_enabled`) |
| `payments` *(module `payments.js`)* | Payments (Mga Bayad) | Sales & finance | `finance.view` (manager) | Every peso in and out. Filters All / Cash / Online / Bank / Refunds; bank transfers waiting for confirmation |
| `daily-close` | Daily Close | Sales & finance | `finance.view` (manager) | Reconcile the day before locking up |
| `finance` | Financials | Sales & finance | `finance.view` (manager) | Revenue, cost of sales, labour and net result. **Day / Week / Month**, **Add expense**, **Costing**, **Pay rates** |
| `performance` | Performance | Sales & finance | `performance.view` (manager) | Monthly revenue, top dishes, peak hours, 30-day bars. **↻ Reload**, **⬇ Export Excel** |
| `history` | History (Kasaysayan) | Sales & finance | `history.view` (manager) | Branch audit trail; rows older than 31 days are archived by a monthly job. **↳ Archive now**, **Reload** |
| `notifications` | Notifications | Inbox | `notifications.view` (dining) | One feed for the branch. **✓ Mark all read**, **↻ Refresh** |
| `messages-admin` | Messages | Inbox | `messages.view` (dining) | Inbox and Sent; compose to one person or broadcast (broadcast needs `messages.broadcast`, manager). **✉️ Compose**, **📥 Inbox**, **📤 Sent** |
| `accounts` | Accounts | Accounts | `accounts.view` (manager) | Staff accounts; new accounts wait for approval. **+ Add Staff Account** |
| `roles` | Roles & Access | Accounts | `roles.view` (manager) | Build a role and choose what it can reach (editing needs `roles.edit`, admin) |
| `access-matrix` | Access Matrix | Accounts | `roles.view` (manager) | Every role across the top, every permission down the side; tap a cell to change it |
| `audit` | Audit Log | Accounts | `audit.view` (admin) | Every account and system action, newest first |
| `preferences` | Preferences | You | none | This device only: theme, density, motion, sound, badge clearing, landing tab, language, change password, sign out of all devices |
| `pos` *(module `pos.js`)* | Counter (POS) | not in the sidebar (`hidden: true`) | `pos.use` (dining) | The counter till. It is drawn inside the floor screen's **Counter** tab, not in the portal sidebar |

Any module tab not placed in a hub lands in a **More** hub (`hub.more`). None currently does.

##### "My Workspace": every route (dining and kitchen roles)

Built by `renderStaffSidebar` (line 7989) and drawn by `renderStaffRouteInto` (line 8064). These rows are chosen by role, not by permission, except the module tabs and Floor.

| Route id | Label | Hub | Who | What it does |
|---|---|---|---|---|
| `staff-home` | Home | Today | everyone | "Good day, *name*!", This Week / This Month / Streak, **🕐 Clock In** / **🕐 Clock Out**, **Full Week →**, **Inbox →** |
| `kds` | Kitchen Queue | My work | `kitchen` role only | as above |
| `orders` | Live Orders | My work | `dining` role only | as above |
| `deliveries` | Deliveries | My work | `delivery.dispatch` | as above |
| `tasks` | Task Board | My work | everyone | their tasks |
| `staff-void-requests` | My Void Requests | My work | everyone | voids they asked for |
| `floor` | Floor & Counter ↗ | My work | `floor.view` | opens the floor screen |
| `staff-schedule` | My Schedule | My shifts | everyone | their week |
| `staff-attendance` | My Attendance | My shifts | everyone | their last 30 days |
| `staff-notifications` | Notifications | Inbox | everyone | |
| `staff-messages` | Messages | Inbox | everyone | from their manager; compose if allowed |
| `rewards` | Rewards | Guests | `rewards.redeem` (supervisor by default, so not dining/kitchen unless granted) | as above |
| `preferences` | Preferences | You | everyone | |
| `staff-settings` | Settings | You | everyone | **Change Password** |

Known quirk: after a reload, only the routes in the `validStaff` list (line 1051) are reopened; `deliveries` and `rewards` are not on it, so a reload on those tabs lands on Home.

##### Tools on every portal page
- **Search everything** (`modules/search.js`): the search field at the top of the sidebar, 🔍 on phones, **Ctrl+K / ⌘K**, or **/**. Finds pages, how-to help and records already loaded (orders, staff, inquiries, dishes).
- **Help & guide** (`modules/guide.js`): a **?** button on every portal page, the floor and the kitchen. A searchable "How do I…?" list with **Show me**, and a first-day tour that runs once per person per device.
- **Export / Import** (`modules/excel-io.js`): adds **⬇ Export ▾** (Excel or CSV) to list pages, and **⬆ Import** where staff keep a list by hand. Imports preview first and never delete.
- **Language switch** in the sidebar (see section 6).
- **Session guard** (`tpn-kit.js` lines 526+): signing out in one tab signs out every tab; if a session ends on its own, a "Your session ended" dialog offers **Sign in again**.

---

#### 1.4 `tpn-dine-in-floor.html` — Floor & Counter

**Who:** the counter (iMin D4 running the TPN Counter app), managers, dining staff whose role has `floor.view`, and the shared `dine_in_display` screen account (`tpnAuthGate`, lines 531–640). Each person signs in on the station with their own account; signing in clocks them in (`modules/signin.js` header).

**Loads:** supabase-js → `config.js` → `tpn-supabase.js` → `tpn-kit.js` → `modules/offline.js` → `tpn-i18n.js` (head); styles `tpn-glass.css` → `tpn-signin.css` → `tpn-ui.css`, a Google Fonts link (Playfair Display, DM Sans, Lora, Fraunces, Plus Jakarta Sans), then the page's own large `<style>` block (lines 61–376); `modules/signin.js` (line 377); at the end `vendor/qrcode-generator-1.4.4.js`, `modules/customer-display.js`, `payments.js`, `invoices.js`, `photos.js`, `pos.js`, `vendor/imin-printer-1.4.0.min.js`, `slips.js`, `kprint.js`, `imin.js`, `guide.js`, and `tpn-forms.css` last. It links the web app manifest `counter.webmanifest` (line 25) and registers the offline service worker `tpn-counter-sw.js` through `modules/offline.js`.

**Sign-in gate:** until someone is signed in, everything except `#tpn-auth-gate` is hidden. The gate (`tpn-signin.css`, drawn by `modules/signin.js`) is the portal's sign-in in the v3 colours: brick panel with the logo, paper card with the form.

**Top bar** (dark, lines 381–396): **← Portal** (hidden for the screen account), "Tyo Paeng Nyo / Dine-In Floor · Las Piñas", a live-connection pill (Connecting… / live / down), the role badge, **Switch user**, **🌐 Tagalog**, **↺ Refresh**, **+ Table** (managers). Modules add more buttons to this bar: the printer status chip (`imin.js`, e.g. "🖨 Printer ready"), **Customer screen** (`customer-display.js`), and an offline chip (`offline.js`).

**Tabs** (lines 400–406, `showTab` line 951):

| Tab | Shown to | What it does |
|---|---|---|
| 🪑 **Floor Map** (badge: occupied tables) | everyone | Four stat tiles: Tables Occupied, Active Orders, Bill Requested, and Session Revenue (or "Covers Tonight" on the screen account, because guests can see it). The table grid: each card shows the table number, status (Empty, Occupied, Active Orders, Food Ready, 💳 Bill Requested), guest, minutes open, total, and buttons **View**, **Open QR**, **+ Order**, **Bill**, **Close Table**, **Clear**. **+ Add Table** |
| 🧾 **Counter** | people with `pos.use`, never the screen account (`canCounter`, line 2124) | The `pos` module: menu tiles with dish photos, search, the ticket, **Open shift**, **X read**, **Close shift (Z read)**, **＋ Cash in**, **－ Cash out / petty cash**, **🖨 Print** |
| 📋 **Dine-In Orders** (badge) | everyone | Filter chips All, 🟡 Received, 🔴 Preparing, 🟢 Ready, ✅ Done; order cards that move to the next step |
| 🍽️ **Menu Status** | managers (hidden for the screen account) | "Menu Availability": switch dishes on and off |
| ⚙️ **Settings** | managers (hidden for the screen account) | Branch & Table Settings, Branch Info, Table QR Codes, General (Live updates, QR Menu URL, Sound) |

**Close Table** opens the payment panel (`modules/payments.js`) with method buttons and quick cash amounts; the bill can be printed for the table (all rounds) before paying.

**Table requests** (`renderRequests`, line 799): when a guest taps **Call staff** or **Ask for the bill** on the QR menu, a card appears at the bottom right — "🤚 Table N needs assistance" (**On it ✓**) or "💳 Table N wants the bill" with how they will pay (**Got it ✓**). Cards stay until someone takes them, pulse after 2 minutes, and re-chime every 30 seconds.

**Sound gate:** browsers block sound until the screen is tapped, so a full-screen "🔔 Tap to start" appears when needed.

**Live banner:** a red bar under the top bar when the live connection drops, with a retry.

**Voids:** nobody voids from this screen. A small ✕ next to an item sends a request to the portal's Void Requests (lines 496–530).

---

#### 1.5 `tpn-dine-in-floor-customer.html` — the customer screen

**Who:** guests at the counter, on the second screen on the back of the iMin D4. It has no buttons and no sign-in, and never shows a customer's name, phone or address (comment, lines 9–11; `modules/customer-display.js` header).

**Loads:** a Google Fonts link (Fraunces, Plus Jakarta Sans 400–800), its own `<style>`, `vendor/gsap-3.12.5.min.js`, `modules/customer-display.js`. It does not load the shared stylesheets. The mouse pointer is hidden and text cannot be selected.

**How it gets data:** the counter publishes one "state" and this page draws it. The state travels every way that might work: a BroadcastChannel `tpn-cds`, the last state in `localStorage` key `tpn.cds`, the browser Presentation API, the Android app's bridge, or the app's local link `http://127.0.0.1:8091/state` (`customer-display.js` lines 1–25). A state older than 2 hours is ignored.

**Views:**
- **Welcome** (`#idle`): a looping brand reel on cocoa — paisley tiles with a saffron wave, a mandala of dots that bursts into streaks, TYO / PAENG / NYO in different faces, "Mabuhay! · Kain na!" tickers, the logo spinning in, and the tagline "kapag iyong natikman, hindi mo titigilan" word by word.
- **Order** (`#order`): "Your order", the order type, up to 7 lines (older ones fold into "plus N more"), and the total on a cocoa panel with rolling odometer digits. The payment part shows "Amount to pay", the method, and for cash the amount received and change; GCash, Maya, QR Ph, card and bank show what the guest should do.
- **Thanks** (`#thanks`): "Salamat po!", change and order number, and a small printer feeding out a receipt marked "Not an official receipt". It returns to Welcome after 15 seconds (`tpn-dine-in-floor-customer.html` line 684).
- Between views, three canvas "liquid" blobs (saffron, brick, cocoa) pour over the screen.

On older or low-memory devices (Chrome below 100 or 4 GB or less) the page switches to a "lite" mode: 30 frames a second, no blend or blur (lines 274–279). With the OS "reduce motion" setting, GSAP is not used and changes are instant.

---

#### 1.6 `tpn-kitchen-station.html` — the kitchen screen

**Who:** the kitchen (TPN Kitchen app on a wall screen), the `kitchen` role, anyone with `kitchen_station.view`, and the shared `kitchen_display` account (lines 345–400). The page is dark (`<html data-theme="dark">`).

**Loads:** supabase-js → `config.js` → `tpn-supabase.js` → `tpn-kit.js` → `tpn-i18n.js`; styles `tpn-glass.css` → `tpn-signin.css`, Google Fonts (Playfair Display, DM Sans, Fraunces, Plus Jakarta Sans), two inline `<style>` blocks (lines 53 and 245); `modules/signin.js`; `modules/guide.js`; `tpn-forms.css` last. It does not load `tpn-app.css`.

**Screen:**
- Top bar: "Kitchen Station", "Las Piñas · *clock*", role badge, **🌐 Tagalog**, **↺ Refresh**, **Switch user**, **← Portal** (hidden for the screen account).
- Stats bar: Received, Cooking, Ready counts and the connection state.
- Three lanes: **🔔 Received**, **👨‍🍳 Preparing**, **✓ Ready for Pickup**. Each ticket shows the order, its age and its items. **Start Cooking →** moves a ticket to Preparing; **Mark Ready ✓** moves it to Ready.
- A small ✕ on each item asks a manager for a void.
- Live banner with **Retry now** when the connection drops; sound gate "🔔 Tap to start"; a chime on new orders.

---

#### 1.7 `tpn-table-menu.html` — the QR table menu

**Who:** dine-in guests who scan the table QR. The page opens in **Tagalog** unless the guest chose English before (`TPN_LANG` default `'tl'`, line 295).

**Address:** `tpn-table-menu?table=<n>&branch=<name>&branchId=<code>`. If the link has no table number, the page shows only "Scan the code on your table" and stops (lines 279–288), so an order can never land on the wrong table.

**Loads:** supabase-js → `config.js` → `tpn-supabase.js` → `tpn-kit.js` (head); Google Fonts (same request as the website); `tpn-app.css` (note: version `?v=20261017o`, older than the website's `?v=20261021c`) → `tpn-glass.css` → `tpn-site-v3.css`, then its own `<style>`; at the end `modules/photos.js`, `tpn-home.js`, `tpn-forms.css`. It does **not** load `tpn-i18n.js`; all its text is in its own dictionary (lines 298–408).

**Views** (`go(v)`, line 717; the address gets `#review`, `#sent`, `#bill`):

| View | What is on it | Buttons |
|---|---|---|
| Menu (`#page-menu`) | Top bar with wordmark, a dark "Table N" chip, EN/TL, Tray, logo. Header: eyebrow "Table N · Dine-in", engraved "Menu" title, the line "Order right from your table. We bring it to you, and you pay at the end." A "Welcome back" card for returning guests with their usual. Search, category chips, dish cards (same cards as the website). A bottom dock with **Call staff** and **Bill ₱…** | **+** adds; dishes with choices open a bottom sheet (sizes, add-ons, quantity, **Add to tray · ₱…**) |
| Tray drawer | "This round", items, round total, "Your bill after this" | **Review order →** |
| Review (`#page-review`) | "Review your *order*", "We bring it to Table N. Nothing to pay yet…", your name and number of guests (first round only), the items, "Anything the kitchen should know?" | **← Edit**, **Send to kitchen →** |
| Sent (`#page-sent`) | "Sent to the *kitchen*", an on-screen kitchen ticket, live status Received → Cooking → Ready → Served, the bill so far | **Order more**, **Ready to pay? See your bill** |
| Bill (`#page-bill`) | "Your *bill*", one row per round, Total, the whole table's total if other phones ordered too, "How will you pay?" (Pay on my phone — only if online payments are on; Cash; GCash · Maya · bank app; Card — only if card is on), "Nothing is charged from this page…" | **← Back**, **Ask for the bill →** |
| Bill sent | "Staff will be *right with you*", a "Table N · paying … · ₱…" chip, "What happens next" with three numbered steps for the chosen method | **Back to the menu** |

---

#### 1.8 `tpn-rewards.html` — the stamp card

**Who:** customers. Linked from the website footer ("Stamp card", only when rewards are on) and from the QR printed on paid receipts.

**Loads:** supabase-js (local only), `config.js`, `tpn-supabase.js`, `tpn-kit.js`, `vendor/qrcode-generator-1.4.4.js`; Google Fonts (Playfair Display, DM Sans only); its own `<style>` (older palette, see 2.1.8); `tpn-glass.css` after it; `tpn-forms.css` last. No language switch: the page is English only.

**Views** (one script, lines 61–186):
- **Claim:** "Your *stamp card*", explanation, "Your mobile number", **Show my card**. With no past order on this phone it says to order with your number first and shows **Order now**.
- **Card:** "Your *stamp card*" (or "Reward *ready!*"), "Card for the number ending in …", 10 circles (filled ones show 🍲, empty ones their number), the reward, a **History** list, **Show code to staff** (only when full) or "Collect N more", **Remove card from this phone**. Works offline with the last saved copy.
- **Code:** "Show this to *staff*", a QR and a 6-digit code that change every 30 seconds, a shrinking bar, **Back to card**.

---

#### 1.9 Load order, side by side

Stylesheets in the order each page applies them (later wins when two rules are equally specific):

| Page | Stylesheets, in order |
|---|---|
| `index.html` | `tpn-app.css` → `tpn-glass.css` → `tpn-site-v3.css` → `tpn-forms.css` |
| `portal.html` | `tpn-app.css` → `tpn-glass.css` → `tpn-portal.css` → (inline styles from modules) → `tpn-forms.css` |
| `tpn-dine-in-floor.html` | `tpn-glass.css` → `tpn-signin.css` → `tpn-ui.css` → page `<style>` → `tpn-forms.css` |
| `tpn-kitchen-station.html` | `tpn-glass.css` → `tpn-signin.css` → page `<style>` ×2 → `tpn-forms.css` |
| `tpn-table-menu.html` | `tpn-app.css` → `tpn-glass.css` → `tpn-site-v3.css` → page `<style>` → `tpn-forms.css` |
| `tpn-rewards.html` | page `<style>` → `tpn-glass.css` → `tpn-forms.css` |
| `tpn-dine-in-floor-customer.html` | page `<style>` only |

Script order is always the same backbone where it applies: **supabase-js → `config.js` → `tpn-supabase.js` → `tpn-kit.js`** (stated in `tpn-kit.js` lines 3–5), then page scripts, then feature modules. Every local file carries a `?v=` date tag (for example `tpn-kit.js?v=20261022b`) so browsers fetch a new copy when it changes.

---

### 2. The design system

The current look is called **v3** in the code: warm paper, brick red as the one accent, saffron for big titles, cocoa for dark panels, **Fraunces** for display text and **Plus Jakarta Sans** for everything else (`tpn-site-v3.css` lines 1–18). It started on the public website and was then carried to the portal, the stations and the slips. Older layers (the "Daylight" parchment palette, Playfair Display / DM Sans, and the "Liquid Glass" layer) are still in the code underneath and still show through in places. This section lists all of them.

#### 2.1 Colours

##### 2.1.1 v3 palette (`tpn-site-v3.css` lines 20–35) — the website and QR menu

| Token | Value | Used for |
|---|---|---|
| `--v3-paper` | `#FBF6EC` | page background |
| `--v3-paper-2` | `#F4EAD8` | second paper tone, language switch well |
| `--v3-card` | `#FFFDF8` | cards |
| `--v3-ink` | `#2E1A10` | main text |
| `--v3-ink-2` | `#6E5240` | secondary text |
| `--v3-ink-3` | `#A68B74` | faint text |
| `--v3-accent` | `#A3321A` | brick: buttons, links, wordmark |
| `--v3-accent-2` | `#8A2914` | brick hover |
| `--v3-saffron` | `#E4A23C` | big engraved titles, dots, underline |
| `--v3-cocoa` | `#3A1D10` | dark panels, title outline |
| `--v3-hair` | `rgba(46,26,16,.09)` | hairlines |
| `--v3-sand` | `#E3CEAB` | the tray drawer |
| `--v3-shadow` | `0 24px 48px -24px rgba(58,29,16,.18), 0 2px 6px -2px rgba(58,29,16,.06)` | card shadow |
| `--v3-ease` | `cubic-bezier(.22,1,.36,1)` | standard easing |
| `--v3-pop` | `cubic-bezier(.34,1.4,.64,1)` | springy easing |
| `--v3-display` | `"Fraunces", Georgia, serif` | display face |
| `--v3-ui` | `"Plus Jakarta Sans", system-ui, sans-serif` | UI face |
| `--v3-gutter` | `clamp(16px, 4vw, 56px)` | page side padding |

It also points the shared tokens at the paper: `--bg: var(--v3-paper)`, `--bg-2: var(--v3-paper-2)`, `--surface: var(--v3-card)`.

The same v3 values appear, under other names, in: `tpn-signin.css` (`--c-paper #F7F0E2`, `--c-card #FFFDF8`, `--c-sand #F4EAD8`, `--c-ink #2E1A10`, `--c-ink-2 #6E5240`, `--c-brick #A3321A`, `--c-brick-deep #8A2914`, `--c-saffron #E4A23C`, `--c-cream #FFF8E8`), the customer screen (`--paper #FBF6EC`, `--paper-2 #F4EAD8`, `--card #FFFDF8`, `--ink #2E1A10`, `--ink-2 #6E5240`, `--ink-3 #8C6F58`, `--brick #A3321A`, `--saffron #E4A23C`, `--cocoa #3A1D10`, `--cocoa-2 #4A2818`, `--on-cocoa #FBF1DF`, `--on-cocoa-2 #D9C3A6`) and `tpn-forms.css` (below).

##### 2.1.2 Shared app palette, "Daylight" (`tpn-app.css` lines 37–71)

The original palette, still the base for the portal and the website's older components.

| Group | Tokens |
|---|---|
| Brand accents | `--brick #8B1A0E`, `--brick-deep #5C1008`, `--ember #C43D1A`, `--amber #D4720A`, `--gold #B8800F`, `--gold-light #D4960F`, `--gold-hi #E8B340` |
| Surfaces | `--bg #F2E4C7`, `--bg-2 #EDDCB8`, `--surface #F7EDD3`, `--surface-2 #E8D4A8`, `--surface-3 #DEC592` |
| Text | `--ink #2B1810`, `--ink-soft #4A2F1D`, `--ink-muted #6B4A35`, `--ink-faint #9C7F65` |
| Lines and shadows | `--line rgba(139,26,14,.16)`, `--line-soft rgba(139,26,14,.08)`, `--shadow-sm 0 1px 2px rgba(74,47,29,.10)`, `--shadow 0 4px 16px rgba(74,47,29,.12)`, `--shadow-lg 0 12px 40px rgba(74,47,29,.16)`, `--shadow-warm 0 8px 32px rgba(196,61,26,.14)` |
| Status | `--success #5C8A3A`, `--warn #C8881A`, `--danger #B22A1A`, `--info #2C6B8A` |

`tpn-ui.css` repeats exactly these values, scoped to `.tpn-ui`, so the Counter and payment panel look the same on the floor screen as in the portal (lines 12–22).

##### 2.1.3 Portal light theme moved onto paper (`tpn-portal.css` lines 51–66)

Loaded only by the portal, after `tpn-app.css`, so in the portal's light theme these win:

`--bg #F7F0E2`, `--bg-2 #F1E6D2`, `--surface #FFFDF8`, `--surface-2 #F4EAD8`, `--surface-3 #EADCC2`, `--line rgba(46,26,16,.12)`, `--line-soft rgba(46,26,16,.07)`, `--shadow-sm 0 1px 2px rgba(58,29,16,.08)`, `--shadow 0 10px 24px -14px rgba(58,29,16,.22), 0 2px 6px -2px rgba(58,29,16,.06)`, `--shadow-lg 0 24px 48px -24px rgba(58,29,16,.24), 0 2px 6px -2px rgba(58,29,16,.06)`, glass tints `255,253,248` and `247,240,226`. The brick/ember accents are not changed here, so portal buttons use `--ember #C43D1A`. Text selection is saffron at 35% and the focus outline is 3px ember at 55%.

##### 2.1.4 Themes: Daylight, Dark, Night, Match OS (`tpn-app.css` lines 1936–2060)

A theme is a swap of the same tokens, chosen by `<html data-theme="…">`.

| Token | Daylight (`light`) | Dark (`dark`) | Night (`night`) |
|---|---|---|---|
| `--bg` | `#F2E4C7` (`#F7F0E2` in portal) | `#1A1210` | `#140E0C` |
| `--bg-2` | `#EDDCB8` | `#221715` | `#1A1210` |
| `--surface` | `#F7EDD3` | `#251A17` | `#1D1512` |
| `--surface-2` | `#E8D4A8` | `#2F211D` | `#241A16` |
| `--surface-3` | `#DEC592` | `#3A2924` | `#2C201B` |
| `--ink` | `#2B1810` | `#F5E7D0` | `#DCCBB4` |
| `--ink-soft` | `#4A2F1D` | `#DFCBAE` | `#C3B096` |
| `--ink-muted` | `#6B4A35` | `#B49A7E` | `#9A8468` |
| `--ink-faint` | `#9C7F65` | `#8A7159` | `#74604B` |
| `--brick` | `#8B1A0E` | `#E8734F` | `#C86A4C` |
| `--ember` | `#C43D1A` | `#C6532F` | `#A8492C` |
| `--gold` | `#B8800F` | `#D9A94A` | `#B8913F` |
| `--line` | `rgba(139,26,14,.16)` | `rgba(232,196,138,.16)` | same as Dark |

Dark and Night also darken the shadows. **Match OS** (`system`) uses the Dark values when the device is in dark mode and Daylight otherwise, and follows the device live (`portal.html` lines 7266–7272).

Where the theme is chosen: **Preferences → Theme** in the portal. The swatches are Daylight `#F2E4C7 / #F7EDD3 / #8B1A0E`, Dark `#1A1210 / #2F211D / #E8734F`, Night `#140E0C / #241A16 / #C86A4C`, Match OS `#F2E4C7 / #1A1210 / #B49A7E` (`THEME_CHOICES`, line 7280). Default is Daylight (`TPN_PREF_DEFAULTS`, line 7221). Preferences are stored on the device in `localStorage` key `tpn.prefs` and written onto `<html>` as `data-theme`, `data-density`, `data-motion`, `data-glass`, `data-text` (`applyPrefs`, line 7256).

Other pages: the kitchen screen is fixed to `data-theme="dark"`; the rewards page is fixed to `data-theme="light"` but has its own dark colours for phones in dark mode (lines 25–26, which the fixed attribute actually blocks, since they apply only when the attribute is not `light`); the website, floor and QR menu set no theme and use the light values.

##### 2.1.5 Glass tokens (`tpn-glass.css` lines 16–59)

| Token | Daylight | Dark / Match OS dark | Night |
|---|---|---|---|
| `--glass-tint` (rgb) | `247,237,211` | `37,26,23` | `29,21,18` |
| `--glass-tint-2` | `242,228,199` | `26,18,16` | `20,14,12` |
| `--glass-alpha` / `-hi` / `-card` | `.78` / `.90` / `.86` | `.72` / `.86` / `.86` | `.80` / `.90` / `.90` |
| `--glass-sheen` | `rgba(255,255,255,.30)` | `rgba(255,236,210,.05)` | `rgba(255,236,210,.03)` |
| `--glass-edge` | `rgba(255,255,255,.55)` | `rgba(255,236,210,.10)` | `rgba(255,236,210,.06)` |
| `--glass-edge-lo` | `rgba(139,26,14,.10)` | `rgba(0,0,0,.35)` | `rgba(0,0,0,.4)` |
| `--mesh-a / b / c` (background wash) | saffron `.22`, ember `.12`, green `.10` | `.16 / .10 / .10` | `.10 / .06 / .06` |
| `--focus-ring` | `0 0 0 3px rgba(212,114,10,.55)` | `rgba(240,160,110,.6)` | `rgba(200,140,100,.6)` |

Fixed values: `--glass-blur 18px`, `--glass-sat 1.45`, `--glass-radius 18px`, `--glass-radius-sm 12px`, and the shadow `--glass-shadow`. Also `--ease-out cubic-bezier(.22,1,.36,1)` and `--ease-spring cubic-bezier(.34,1.4,.64,1)` (line 436).

##### 2.1.6 Text boxes, toasts and dialogs (`tpn-forms.css` lines 12–50)

| Token | Light | Dark / Night / Match OS dark |
|---|---|---|
| `--f-font` | `"Plus Jakarta Sans", system-ui, -apple-system, "Segoe UI", sans-serif` | same |
| `--f-bg` / `--f-bg-hover` | `#FFFDF8` / `#FFFFFF` | `rgba(255,236,210,.06)` / `.09` |
| `--f-border` / `--f-border-hover` | `rgba(46,26,16,.18)` / `.32` | `rgba(255,236,210,.18)` / `.30` |
| `--f-text` | `#2E1A10` | `#F5E7D0` |
| `--f-muted` | `#6E5240` | `rgba(245,231,208,.72)` |
| `--f-placeholder` | `#7A6150` | `rgba(245,231,208,.58)` |
| `--f-focus` | `#A3321A` | `#E8A15C` |
| `--f-ring` | `0 0 0 3px rgba(228,162,60,.42)` | `0 0 0 3px rgba(232,161,92,.38)` |
| `--f-error` | `#A3321A` | same |
| `--f-disabled` | `rgba(46,26,16,.05)` | `rgba(255,236,210,.03)` |
| `--t-bg` / `--t-text` / `--t-edge` (toast) | `#3A1D10` / `#FBF6EC` / `rgba(255,236,210,.10)` | `#F4EAD8` / `#2E1A10` / `rgba(46,26,16,.12)` |

Dialog card: `#FBF6EC` light, `#251A17` dark (lines 140–153).

##### 2.1.7 Floor and kitchen page colours (inline `:root`)

Both `tpn-dine-in-floor.html` (lines 62–75) and `tpn-kitchen-station.html` (lines 54–67) define their own older set: `--brick #8B1A0E`, `--brick-dark #6a1208`, `--brick-light #c4392a`, `--gold #c8922a`, `--gold-light #e8b84b`, `--cream #fdf6ec`, `--cream-dark #f5ead8`, `--charcoal #1a0a00`, `--text #2d1a0a`, `--text-muted #7a5c3a`, `--surface #fff8f0`, `--border #e8d5b8`, `--green #2d7a4f`, `--green-light #e8f5e0`, `--amber #c8922a`, `--amber-light #fff8e8`, `--red #8B1A0E`, `--red-light #fff0ee`, `--blue #1a4a7a`, `--blue-light #e8f0fa` (floor), `--gray #9e9e9e`, `--gray-light #f5f5f5`, `--shadow 0 2px 16px rgba(26,10,0,.10)`, `--radius 14px`. The floor's background is cream with a soft colour wash from `tpn-glass.css` (lines 439–445); the kitchen's is charcoal `#1a0a00` with a `#0f0700` top bar.

##### 2.1.8 Rewards page colours (inline, `tpn-rewards.html` lines 22–26)

The older Daylight set: `--brick #8B1A0E`, `--ember #C43D1A`, `--amber #D4720A`, `--gold #B8800F`, `--bg #F2E4C7`, `--bg-2 #EDDCB8`, `--surface #F7EDD3`, `--surface-2 #E8D4A8`, `--ink #2B1810`, `--ink-soft #4A2F1D`, `--ink-muted #6B4A35`, `--ink-faint #9C7F65`, lines, `--success #5C8A3A`, `--warn #C8881A`, `--danger #B22A1A`, shadows.

##### 2.1.9 Floor alerts and other fixed colours

- Table call request: brick `#A3321A` on cream `#FBF6EC`; bill request: saffron `#E4A23C` with ink `#2E1A10` text (`tpn-forms.css` lines 164–166). The floor page's own older colours for these (blue `var(--blue)` and purple `#6b3fa0`, lines 312–313) are overridden.
- Browser bar colour (`theme-color`): `#8B1A0E` on the website, portal and rewards; `#1a0a00` on the floor and kitchen; `#FBF6EC` on the QR menu.
- Counter app manifest: background `#1a0a00`, theme `#8B1A0E`.
- App icon SVG `icons/tpn-icon.svg`: `#8B1A0E` rounded square, `#E8B340` ring at 55%, "TPN" in `#FFF8E8`.

#### 2.2 Other preferences on `<html>`

| Attribute | Values | Set by | Effect |
|---|---|---|---|
| `data-density` | `comfortable` (default), `compact` | Preferences → Density | Compact tightens sidebar rows, page padding, finance tiles, task cards, matrix cells (`tpn-app.css` lines 2062–2069) |
| `data-motion` | `on` (default), `off` | Preferences → Motion | `off` cuts every animation and transition to ~0 (`tpn-app.css` line 2074) |
| `data-glass` | `on` (default), `off` | no control found in Preferences | `off` makes glass surfaces solid (`tpn-glass.css` lines 171–175) |
| `data-text` | `normal` (default), `large`, `xlarge` | no control found in Preferences | 112.5% / 125% text (`tpn-glass.css` lines 156–159) |

The comments in `tpn-glass.css` mention "Preferences → Glass: Off" and "Preferences → Text size", but `renderPreferences` (lines 7287–7417) has no such controls. `tpn-glass.css` also has rules for `data-motion="reduced"` (lines 183, 515), a value the Preferences never sets; the `off` rule in `tpn-app.css` covers it instead.

#### 2.3 Typography

**The two faces now in use:**
- **Fraunces** — display serif for headings, wordmarks, big numbers, table numbers, the slips. Set with `font-variation-settings: "SOFT" 100` (soft corners) and, for the big titles, `"opsz" 144` and `"WONK" 0`.
- **Plus Jakarta Sans** — everything else: body text, buttons, labels, text boxes (16px in boxes so phones don't zoom in).

**Older faces still referenced:** Playfair Display (old display), DM Sans (old body), Lora (old italic). In the code: Playfair Display appears 56 times in `tpn-app.css`, 11 in `portal.html`, 7 in `index.html`, 5 in modules; Lora 12 times in `tpn-app.css`; DM Sans 3 times in `tpn-app.css` (body font, line 80) and 4 in modules.

**How each page gets its fonts:**

| Page | Font source | Families requested |
|---|---|---|
| `index.html`, `tpn-table-menu.html` | Google Fonts CSS link | Playfair Display (700, 900, italic 700), Lora (400, 600, italic 400), DM Sans (300–700), Fraunces (italic and roman, opsz 9–144, weight 500–900, SOFT 0–100, WONK 0–1), Plus Jakarta Sans (400–700) |
| `portal.html` | `tpn-portal.css` `@font-face` rules pointing straight at Google's font files | Fraunces (`fonts.gstatic.com/s/fraunces/v38/…`) **registered under the names "Playfair Display" and "Lora"**; Plus Jakarta Sans (`…/plusjakartasans/v12/…`) **registered under the name "DM Sans"** (lines 21–43). This turns the portal's ~80 old font declarations into the new faces without editing each one |
| `tpn-dine-in-floor.html` | Google Fonts link | Playfair Display, DM Sans, Lora, Fraunces, Plus Jakarta Sans (400–700) |
| `tpn-kitchen-station.html` | Google Fonts link | Playfair Display (700, 900), DM Sans, Fraunces, Plus Jakarta Sans |
| `tpn-dine-in-floor-customer.html` | Google Fonts link | Fraunces, Plus Jakarta Sans (400–800) |
| `tpn-rewards.html` | Google Fonts link | Playfair Display, DM Sans only |
| Printed slips | `modules/slips.js` adds its own link when it first draws | Fraunces (opsz 9–144, weight 700), Plus Jakarta Sans (400, 600, 800) |
| Offline counter | `tpn-counter-sw.js` caches the Google Fonts CSS and font files | whatever the floor page requests |

Exact Google Fonts URL on the website (`index.html` line 17):
`https://fonts.googleapis.com/css2?family=Playfair+Display:ital,wght@0,700;0,900;1,700&family=Lora:ital,wght@0,400;0,600;1,400&family=DM+Sans:wght@300;400;500;700&family=Fraunces:ital,opsz,wght,SOFT,WONK@0,9..144,500..900,0..100,0..1;1,9..144,500..900,0..100,0..1&family=Plus+Jakarta+Sans:wght@400;500;600;700&display=swap`

**A font gap in the portal (from reading the code, not tested in a browser):** `tpn-forms.css` and `tpn-signin.css` ask for the families by their real names, "Plus Jakarta Sans" and "Fraunces". The portal never registers those names (it registers the same files only as "DM Sans", "Playfair Display" and "Lora"), so in the portal those text boxes, labels, toasts and dialog titles fall back to the system font and Georgia, until `modules/slips.js` adds its own Google Fonts link the first time a slip is drawn.

**Type scale in use (from the CSS):**

| Element | Size / weight |
|---|---|
| Website engraved titles (`.v3-bleed .t`) | Fraunces 900, `clamp(46px, 8.6vw, 148px)` on the hero; `clamp(48px, 6vw, 100px)` on page headers; letter-spacing .03em; saffron with a cocoa outline |
| Website dish name (`.v3-card h4`) | Fraunces 700, 21px; the big bento card `clamp(30px, 3vw, 42px)` |
| Website body | Plus Jakarta Sans, dish descriptions 14px |
| Website buttons (`.v3-btn`) | 600 15px |
| Portal page title | inherits the theme heading (`h1` with SOFT 100, -0.01em) |
| Portal labels (`.tile-label`, `.form-label`, table headers) | 13px, 600, no tracking (`tpn-portal.css` line 74) |
| Text boxes | 16px, 500 (`tpn-forms.css`) |
| Form labels | 13.5px, 600, `--f-muted` |
| Toasts | 14px, 600 |
| Dialog title (`.tpn-dlg-title`) | Fraunces 700, 20px |
| Floor table number / section titles | Fraunces 700, 20px; stat values Fraunces 700, 26px |
| Customer screen | sized in one unit `--u: min(1vw, 1.6vh)`; "Salamat po!" `--u × 10.5` |

Numbers line up in tables everywhere (`font-variant-numeric: tabular-nums` in `tpn-portal.css` line 47, `tpn-forms.css` for number boxes, the customer screen body).

#### 2.4 Spacing, corners and shadows

- **Page gutters:** website `--v3-gutter` = 16px on phones up to 56px; content width 1320px (`.v3-wrap`). Portal main padding is tighter in compact density (20px 26px 44px).
- **Corners (most common values found):** `tpn-site-v3.css` 22px (inner card, photo panels), 28px (card shell, restaurant photo), 18px (nav bar), 14px (buttons), 12px (tray button, language switch), 9px (button arrows); `tpn-portal.css` 12px buttons and chips, 9px tab buttons, 7px small tags and badges, 18px panels/tiles/modals/dialogs, 10px text boxes; `tpn-forms.css` 12px text boxes and chips, 14px toasts; `tpn-glass.css` 18px panels, 12px tiles, 22px modals and dialogs; `tpn-signin.css` 8px; floor and kitchen 8–14px. The rule written in `tpn-portal.css` (lines 13–14) is "rounded rectangles like the site (12–14px); switches and avatars stay round".
- **Round (999px) shapes still present:** see section 3.
- **Shadows:** v3 uses long, soft, warm-brown shadows (`--v3-shadow`); the portal light theme the same family (`tpn-portal.css` lines 58–60); dialogs `0 30px 60px -24px rgba(58,29,16,.45)`; toasts `0 18px 36px -14px rgba(58,29,16,.55)`. On the counter app (`tpn-lite`) panels and cards drop to `0 1px 3px rgba(0,0,0,.12)`.
- **Tap targets:** 44px minimum on touch screens (`tpn-glass.css` lines 152–155); text boxes 46px tall, 48px on phones; buttons in the dialogs 40px+.

#### 2.5 Components

| Component | Where defined | What it looks like / does |
|---|---|---|
| Website buttons `.v3-btn.primary / .ghost` | `tpn-site-v3.css` 116–125 | Brick, 14px corners, a square arrow tile on the right that nudges on hover; ghost is a dark see-through button for the hero |
| App buttons `.btn-primary`, `.btn-next`, `.btn-ghost`, `.btn-secondary`, `.btn-back`, `.btn-outline`, `.btn-danger`, `.table-btn` | `tpn-glass.css` 116–137; portal overrides in `tpn-portal.css` 80–86 | Glass layer makes them 999px pills with a glossy gradient; in the portal they become 12px rounded rectangles with a flat ember fill. Press = scale .97. Labels never wrap (`tpn-glass.css` line 410) |
| Chips `.tpn-chip` | `tpn-glass.css` 195–196; `tpn-forms.css` 154–158 | Quick-choice buttons (e.g. reasons in dialogs): 12px corners, 1.5px border, brick border on hover |
| Category chips (`#page-menu .chip`) | `tpn-site-v3.css` 368 | 999px pills, 600 13px |
| Tabs `tpnTabs()` | `tpn-kit.js` 498; `tpn-glass.css` 264–273 | A row of tabs in a glass strip; on phones (≤640px) they fold into a drop-down |
| Tiles `.tile`, `.fin-tile`, `.stat-tile` | `tpn-app.css`, `tpn-glass.css` | Dashboard and floor numbers; decorative emoji in portal tiles are hidden (`tpn-portal.css` line 101) |
| Panels `.panel` | `tpn-glass.css` 84–106 | Frosted card (tint 86%, no blur), 18px corners, a sheen across the top |
| Modals `.modal` (portal), `.modal-box` / `.ui-modal` (floor) | `tpn-app.css`, `tpn-ui.css`, `tpn-glass.css` 465–471 | Ease up and fade in (translateY 14px, scale .98) |
| Dialogs `tpnConfirm`, `tpnAsk`, `tpnAlert` | `tpn-kit.js` 107–177; styles `tpn-glass.css` 186–194 and `tpn-forms.css` 140–153 | Replace the browser's confirm/prompt. Title, message, optional quick-reason chips and input, an error line, Cancel + OK (OK turns red for dangerous actions). Esc cancels, Enter confirms, focus stays inside. Solid paper card, no blur, max 440px wide (760px for `.tpn-dlg-wide`) |
| Toasts `.toast` / `#toast` | `tpn-forms.css` 119–138; `tpn-portal.css` 103–109 | Cocoa bar with cream text (cream bar in dark themes), wraps, up to 560px, sits above the help button |
| Tables `.data-table` | `tpn-app.css`; `tpn-glass.css` 415–427 | On phones (≤640px) each row becomes a card and each value gets its column name in front (`labelDataTables`, `portal.html` line 1527) |
| Export menu `tpnExportButton()` | `tpn-kit.js` 511 | "⬇ Export" drop-down with Excel (.xlsx) and CSV (.csv) |
| Command palette `.tpn-cmdk` | `tpn-glass.css` 275–285; `modules/search.js` | Search box over a dimmed page, 560px wide, 20px corners |
| Floor request banners `.req-item` | floor page lines 309–321; colours `tpn-forms.css` 164–166 | Stacked cards bottom-right; brick = "needs assistance", saffron = "wants the bill"; pulse after 2 minutes |
| Live pill / live banner | floor 323–339; kitchen | Green dot = live, yellow pulsing = connecting, red = down; red banner with Retry |
| Sound gate | floor 341–344 | Dark full-screen overlay with one big "🔔 Tap to start" button |
| Sign-in gate `#tpn-auth-gate` | `tpn-signin.css` | Two columns: brick gradient panel with logo and mandala, paper form side; one column under 900px |
| Engraved titles `.v3-bleed` | `tpn-site-v3.css` 81–113; `tpn-home.js` | Saffron letters with a 16-step cocoa outline; a second copy filled with the paisley engraving shows through two soft moving spotlights |
| Dish card `.v3-shell > .v3-core` | `tpn-site-v3.css` 155–186; `tpn-home.js` `card()` | Card in a card: sand shell (28px) around a paper core (22px). Dish photo cut-out slowly spinning, or a line icon for the category, tags (Bestseller, Chef's pick, New) as a saffron dot + brick text, name, description, one row per size with **+** |
| Photo panels `.v3-photo` | `tpn-site-v3.css` 198–206 | 22px corners, photo slightly zoomed; empty panels show paisley |
| Map `.v3-map` | `tpn-home.js` 225–266 | OpenStreetMap tiles drawn as images, a brick pin, an address card with × and "Open in Maps", © OpenStreetMap credit |
| Receipt printer `.rcpt-*` | `tpn-site-v3.css` 398–435 | Website order confirmation: a cocoa printer with a blinking saffron light feeds out the receipt in four jerks |
| Boot overlay `#tpn-boot` | `tpn-app.css` 6–36 | Dark brown gradient, "Tyo Paeng Nyo" in Playfair 42px `#E8C97C`, spinner |
| Skip link | `tpn-glass.css` 150–151 | "Skip to content", appears on keyboard focus |

#### 2.6 Motion

**The rule:** animate only `transform` and `opacity`, because those are cheap for the graphics chip. Written in `tpn-glass.css` lines 486–489, `tpn-site-v3.css` (hero "opacity/transform only — no live blur filter", receipt "Transform only") and `tpn-home.js` lines 8–11 ("everything per frame is transform / opacity on composited layers, plus two mask positions per title on screen").

**What moves:**
- Portal pages and floor tabs rise in (`tpnRise`: fade + 10px up, .42s) with the first cards following 40–170ms apart (`tpn-glass.css` 490–503, triggered by `tpnEnter`, `tpn-kit.js` 492).
- Tabs, chips and the language switch glide between states (.25s); dialogs and the command palette rise in; toasts spring.
- Website: the hero photo shrinks 3% and blurs into its pre-blurred copy (`hero-blur.webp`) as you scroll, the text lifts and fades (`heroScroll`, `tpn-home.js`); mandalas and dish photos spin slowly, faster while you scroll; the paisley layers sway; the engraving spotlights wander and follow the pointer; cards fade up as they come into view (`.v3-reveal`). On phones and touch screens the hero does not move (it jittered as browser bars slid).
- Customer screen: GSAP 3.12.5 animations and the canvas "liquid" transitions.
- QR menu: steps slide in one by one.

**Exceptions to the rule (in the code today):** the engraved titles move their mask position through CSS custom properties every frame (acknowledged in `tpn-home.js`); transitions in `tpn-glass.css` also animate `background-color`, `box-shadow` and `color` on buttons, tabs and the sidebar; the customer screen draws to a canvas.

**Turning motion down:**
- The operating system's "reduce motion" setting: everything is cut to ~0 (`tpn-app.css` 2080, `tpn-glass.css` 180 and 516, `tpn-site-v3.css` 435 and 469); the website keeps the spinners at 30% speed and stops the paisley sway (`tpn-home.js` 385, 394); the customer screen skips GSAP.
- Portal **Preferences → Motion: Off** (`data-motion="off"`).
- **`html.tpn-lite`** — added by `tpn-kit.js` line 22 inside the TPN Counter / TPN Kitchen apps (the iMin's graphics chip runs both the counter and the customer screen). No backdrop blur at all, transitions .08s, animations played once in .01s, lighter shadows (`tpn-glass.css` lines 518–529). Phones and laptops keep the full look.

#### 2.7 Every CSS file and its job

| File | Size | Loaded by | Responsible for |
|---|---|---|---|
| `tpn-app.css` | 2,219 lines | website, portal, QR menu | The original shared styles: boot overlay, website sections, tray, checkout, the whole portal (sidebar, tiles, panels, tables, kitchen queue, access matrix, task board, inventory and finance, mobile layouts), the Daylight/Dark/Night/Match OS themes, density and motion preferences, Preferences tab |
| `tpn-glass.css` | 529 lines | every page except the customer screen | The "Liquid Glass" layer: glass tokens per theme, background colour wash, frosted cards, blur on floating bars/menus/dialogs, pill buttons, focus ring, tap targets, text size, solid mode, kit components (dialogs, chips, import, menus, tabs, command palette), public-site extras (event packages, FAQ, nav drop-downs), payment panel, POS, clock-in, phone tables, glass for the floor/QR menu/kitchen, motion, `tpn-lite` |
| `tpn-site-v3.css` | 469 lines | website, QR menu | The v3 look of the public site: tokens, nav, engraved titles, buttons, hero, bestsellers bento, photo panels, inner page headers, restaurant facts, steps, menu page, receipt printer, footer, responsive rules |
| `tpn-portal.css` | 119 lines | portal only, after glass | Brings the v3 look into the portal: font aliasing, paper light theme, sentence-case labels, 12–14px corners, flat brick buttons, drawn icons (emoji hidden), toasts, narrow-screen fixes |
| `tpn-forms.css` | 175 lines | every page except the customer screen, always last | One look for text boxes, selects, labels, toasts, dialogs, chips and the floor alerts, in all themes, with no blur |
| `tpn-ui.css` | 60 lines | floor | The portal's controls (buttons, fields, tables, modals) scoped to `.tpn-ui`, so the Counter and payment panel look right on the floor screen |
| `tpn-signin.css` | 49 lines | floor, kitchen | The station sign-in gate |
| Inline `<style>` | — | floor, kitchen, QR menu, rewards, customer screen; modules `guide.js`, `search.js`, `pos.js` etc. inject their own | Page-specific layout |

#### 2.8 Accessibility pieces

Skip link on the website and portal; visible 3px focus ring (`tpn-glass.css` 148, `tpn-portal.css` 67); 44px tap targets on touch; screen-reader-only headings behind every engraved title (`.v3-sr` `h1`/`h2` with the real text, the visual title marked `aria-hidden`); `role="dialog"` / `alertdialog` with focus trapping in dialogs; `aria-live` on toasts, request queues and the customer screen; "reduce transparency" makes glass solid (`tpn-glass.css` 163–170).

---

### 3. The owner's design rules, and where the code still breaks them

**The rules** (from the owner's instructions and repeated in `HANDOFF.md`, e.g. lines 91, 184, 262, 376): no eyebrow or kicker labels above headings; no subheading lines that restate the heading; no tiny uppercase tracked labels; no 01/02/03 numbering; no pill badges; no gradient washes, glass panels or purple palettes; also flagged in `HANDOFF.md`: one italic/accented word in a heading, emoji used as icons, and icon-topped card grids.

**What has already been done:**
- `tpn-portal.css` lines 69–77 force sentence case and normal letter-spacing inside the portal (`.portal-app *`, the login screen, dialogs, modals, the command palette) and set labels to 13px with no tracking.
- `tpn-forms.css` lines 105–117 do the same on every page for `label`, `legend`, `.form-label`, `.review-label` and any class ending in `-label` (which also covers the floor and kitchen `.stat-label`).
- `tpn-portal.css` hides decorative emoji in tiles and empty states and uses drawn hub icons.
- Website home: the eyebrows over "Our Bestsellers" and "Our place" were removed (`HANDOFF.md` line 376); their strings (`v3.best.eyebrow`, `v3.place.eyebrow`, `v3.locate.eyebrow` in `tpn-home.js`) are still in the dictionary but nothing uses them.
- Floor alerts were moved from blue/purple to brick/saffron (`tpn-forms.css` 164–166).

**Where the rules are still broken (found by searching the code):**

| Rule | Where it is broken |
|---|---|
| **Eyebrow labels** | `.v3-eyebrow` (11px, 600, .2em tracking, uppercase, a pill with a saffron dot; `tpn-site-v3.css` lines 41–43) is used on the website Menu ("Order online", `index.html` 209), Concessions ("For businesses", 272), Events ("Events & catering", 393) and the QR menu ("Table N · Dine-in", `tpn-table-menu.html` 211). Portal login: "Staff Sign In" (`.login-form-eyebrow`, `portal.html` 94) and the "Staff Portal" / "Two-Factor Authentication" taglines above the headline |
| **Subheading lines under headings** | `portal-header-sub` under nearly every portal page title: 33 in `portal.html` and one each in `clockin.js`, `delivery.js`, `modifiers.js`, `payments.js`, `pos.js`, `stamps.js`, `website.js`. Nothing hides them. Also the login "Sign in with your TPN staff account.", the website checkout's `checkout-sub` lines, the QR menu's lede "Order right from your table…", `reviewSub`, `billSub`, and the rewards page `.lead` |
| **Tiny uppercase tracked labels** (still showing, because the overrides above do not reach them) | Website restaurant facts "Address / Hours / Phone / Parking" (`.v3-facts dt`, 11px, .18em, `tpn-site-v3.css` 303); event package badge `.pkg-badge` (`tpn-glass.css` 223); phone table labels `td[data-label]::before` (`tpn-glass.css` 422 — the portal's override does not apply to `::before`); QR menu option-sheet headings `.tm-sheet .lbl` (`tpn-table-menu.html` 108); floor `.order-status-pill`, `.settings-card-title` and inline labels "Orders (n active)", "Items", "Total Session Revenue", "Per Table" (`tpn-dine-in-floor.html` 219, 246, 1827, 1888, 1950, 2034, 2038); help panel group names `.tg-group` (`modules/guide.js` 290); command-palette group names (letter-spacing .12em stays; uppercase is overridden in the portal, `modules/search.js` 152); website order tracking "Track your order" and "Reference Number" (inline, `index.html` 1753, 2048, 2086); boot overlay "Authentic Filipino Since 2003" (.28em, uppercase, `tpn-app.css` 22–25); portal login "SECURE STAFF ACCESS" and "SMS VERIFICATION • …" (typed in capitals, `portal.html` 89, 133). `tpn-app.css` still has 46 uppercase rules and 64 em-tracking rules, most of them neutralised in the portal only. The unused sidebar section names in `portal.html` 337–343 are written in capitals ("OPERATIONS", "PEOPLE" …) but are no longer drawn |
| **Numbered steps** | Website checkout step circles 1–2–3–4 (`index.html` 495–500); "We've moved" steps 1–3 (`.v3-steps .n`, `index.html` 253–256); QR menu "What happens next" steps 1–3 (`.tm-steps .n`, `tpn-table-menu.html` 170–174). Not 01/02/03, but numbered. (The stamp card's numbered circles and the tour's "Step x of y" are functional counts.) |
| **Pill badges and pill shapes** | `.v3-eyebrow`; the QR menu "Table N" chip with a dot (`tpn-table-menu.html` 56–57) and the waiting chip `.tm-wait` (165); `.pkg-badge`; void status pills and the "returning guest" pill in the portal (inline 999px, `portal.html` 3871, 7635); floor `.order-status-pill`, `.topbar-badge`, `.live-pill`; `.v3-photo figcaption`. Round 999px buttons from `tpn-glass.css` (13 uses) remain everywhere except the portal (which overrides them to 12px): website checkout buttons, floor and QR menu buttons, menu search box and category chips (`tpn-site-v3.css` 344, 366, 368), floor payment chips (`tpn-dine-in-floor.html` 162–164) |
| **Gradient washes** | Three-colour radial wash behind every portal page (`.portal-page`, `tpn-glass.css` 69–75) and behind the floor (`tpn-glass.css` 439–445); the `body::after` wash (hidden on the website by `tpn-site-v3.css` 37); a radial wash over the hero photo (`.v3-hero .wash`, `tpn-site-v3.css` 136); the brick gradient on the station sign-in panel (`tpn-signin.css`); the boot overlay gradient; the sheen gradient across every panel, tile and dialog (`tpn-glass.css` 109–114); glossy gradient pill buttons outside the portal (`tpn-glass.css` 121–124). `linear-gradient` / `radial-gradient` appear 47 times in `tpn-app.css` and 13 in `tpn-glass.css` |
| **Glass panels** | The whole `tpn-glass.css` "Liquid Glass" layer is still loaded on six pages: real blur on the website nav (`blur(10px)`, `tpn-site-v3.css` 48), phone menu, drop-downs, modals, tray drawer, export menus and command palette (`blur(18px)`), and the QR menu category bar (`blur(14px)`); frosted see-through cards everywhere. Elements with the class `glass` in markup: website drop-downs, FAQ search, "Try before you book", the rewards cards, the tab strips. Dialogs and toasts were made solid by `tpn-forms.css` |
| **Purple** | Only in the floor page's old bill-request colour `#6b3fa0` (`tpn-dine-in-floor.html` 313), which `tpn-forms.css` overrides. Not displayed |
| **One accented word in a heading** | `<em>`/`<i>` words in headings: "Our *Bestsellers*", "Our *place*", "Salamat *po!*", "We've *moved*", "Tell us what you *need*", "Mga *Suki* Speak", "Starting *Rates*", "Let's Make It *Special*", "Order *Placed!*" (website); "Welcome back, *kabayan*.", "One more *step*." (portal); "Review your *order*", "Sent to the *kitchen*", "Your *bill*", "Staff will be *right with you*" (QR menu); "Your *stamp card*", "Reward *ready!*", "Show this to *staff*" (rewards); the station sign-in headline (`modules/signin.js`) |
| **Emoji as icons / icon-topped card grids** | Website concessions cards 🏢🏬🎓🎉 and event cards 🎂💍🏢✨ (icon on top of each card), checkout 🥡 🛵 and payment method icons, "🍽️ Try before you book", upsell icons 🥤🍚➕; floor tabs 🪑🧾📋🍽️⚙️ and request cards; kitchen lanes 🔔👨‍🍳✓; QR menu payment icons 💵📱💳🔳; many portal buttons (✉️ 📥 📤 📷 🖨️ 💸 🚫). Portal tile and empty-state emoji are hidden by `tpn-portal.css` |

`HANDOFF.md` line 91 lists the owner's open items in the same spirit: the QR menu's "TABLE 7 · DINE-IN" eyebrow and lines under headings, "WHAT HAPPENS NEXT" with 1-2-3 steps, one italic word in headings, the Counter's subtitle and "Drawer open" pill, and the on-screen QR ticket still in the old typewriter look.

---

### 4. Assets

#### 4.1 Images in `assets/site/`

| File | Pixels | Size | What it is | Where it is used |
|---|---|---|---|---|
| `logo.webp` | 200×184 | 18 KB | The round badge: Tyo Paeng's photo giving a thumbs-up inside a red ring with "Kapag iyong natikman, hindi mo titigilan" and a "Tyo Paeng Nyo" ribbon | Website and QR menu nav badge; customer screen (corner brand, reel, receipt); station sign-in panel (`signin.js`); printed receipt footer (dithered, see 5); precached by the counter service worker |
| `icon.png` | 200×200 | 78 KB | The same badge as a square PNG | Favicon and Apple touch icon on every page; `og:image` share picture of the website (`https://unorfl.github.io/tpn-os/assets/site/icon.png`); service worker precache. Byte-for-byte the same file as the Android launcher icon |
| `hero.webp` | 2560×1707 | 1.3 MB | The food-spread photo | Website hero background (`tpn-site-v3.css` 133), preloaded; precached by the counter service worker |
| `hero-blur.webp` | 1280×853 | 22 KB | A pre-blurred copy of the hero | Faded in over the hero on scroll (`tpn-site-v3.css` 135), so no live blur is needed |
| `mandala-a.webp` | 820×820 | 460 KB | Saffron line mandala (pointed petals) on transparent | Spinning decorations on the website (about 20 places in `index.html`) and QR menu; masks and backgrounds on the customer screen; station sign-in panel (`tpn-signin.css` 16); precached |
| `mandala-b.webp` | 820×820 | 457 KB | Gold mandala with dotted petals | Hero background mandala and many decorations on the website and QR menu; customer screen |
| `mandala-b-blur.webp` | 410×410 | 38 KB | Blurred copy of mandala B | Fades in over the hero mandala on scroll (`index.html` 139) |
| `paisley-light.webp` | 1650×1466 | 274 KB | Pale cream paisley pattern | Background behind the engraved titles (`.v3-pat`), empty photo panels, the tray drawer decoration, the receipt printer head (`tpn-site-v3.css` 85, 188, 206, 385, 406); customer screen backgrounds |
| `paisley-engrave.webp` | 1650×1466 | 668 KB | The "engraving" version of the paisley | Shows through the letters of the engraved titles (`tpn-site-v3.css` 107); customer screen reel |
| `spread.webp` | 1536×1024 | 540 KB | — | **Not referenced anywhere in the code** (only the words "food-spread hero" in comments, which use `hero.webp`) |
| `photos/dining-evening.webp` | 960×1280 | 291 KB | Dining room photo | Home "Our place" panel and the Our Restaurant photo (`index.html` 183, 237) |
| `photos/dining-garden.webp` | 960×1280 | 360 KB | Dining / garden photo | Home "Our place" second panel (`index.html` 184) |

#### 4.2 Dish photos (`assets/site/dishes/`) and the dishes they belong to

One list, `modules/photos.js`, decides which dish gets which photo. It matches the dish **name** from the database, ignoring capitals and spaces at either end. A dish not on the list keeps its emoji (counter) or a line icon for its category (website). Each photo URL carries `?v=20261017f`; that tag must be changed when a photo is replaced under the same name. Used by the website and QR menu cards (`tpn-home.js` 104), the counter tiles (`modules/pos.js` 153) and the floor (`tpn-dine-in-floor.html` 1309).

| Dish name in the menu | Photo file | Pixels | Size |
|---|---|---|---|
| Buttered Shrimp | `buttered-shrimp.webp` | 600×600 | 94 KB |
| Adobong Pusit with Gata | `pusit-gata.webp` | 513×513 | 56 KB |
| Pares | `pares.webp` | 309×309 | 28 KB |
| Beef Caldereta | `caldereta.webp` | 521×521 | 60 KB |
| Kare-Kareng Lechon Kawali | `kare-kare-lechon.webp` | 511×511 | 47 KB |
| Ginataang Sitaw at Kalabasa | `ginataang-sitaw-kalabasa.webp` | 678×678 | 94 KB |
| Pork Sisig | `sisig.webp` | 600×600 | 67 KB |
| Teriyaki Wings | `teriyaki-wings.webp` | 489×489 | 58 KB |
| Laing | `laing.webp` | 720×720 | 117 KB |
| Cornedbeef Silog | `cornedbeef-silog.webp` | 436×436 | 56 KB |
| Sisig Silog | `sisig-silog.webp` | 441×441 | 48 KB |
| Liemposilog | `liempo-silog.webp` | 428×428 | 50 KB |
| Tapsilog | `tapsilog.webp` | 428×428 | 51 KB |
| Tocilog | `tocilog.webp` | 596×596 | 125 KB |
| Bacon Silog | `bacon-silog.webp` | 588×588 | 120 KB |
| Chicksilog | `chicksilog.webp` | 1076×1076 | 318 KB |
| Calamares | `calamares.webp` | 600×600 | 76 KB |
| Beef Bistek | `bistek.webp` | 436×436 | 51 KB |
| Pancit Bihon | `pancit-bihon.webp` | 350×350 | 37 KB |
| Ginataang Hipon | `ginataang-hipon.webp` | 428×428 | 35 KB |

`tpn-home.js` (lines 106–108) also ranks these photos "sharpest first", so the large bestseller card always gets a good one: Buttered Shrimp, Adobong Pusit with Gata, Kare-Kareng Lechon Kawali, Beef Caldereta, Pork Sisig, Laing, Ginataang Sitaw at Kalabasa, Calamares, Teriyaki Wings, Ginataang Hipon, Beef Bistek, Pancit Bihon, Chicksilog, Tocilog, Bacon Silog, Tapsilog, Sisig Silog, Liemposilog, Cornedbeef Silog, Pares.

Category line icons used when there is no photo (`tpn-home.js` 112–135): pan (silog/breakfast), drumstick (chicken), shrimp (seafood/fish), leaf (vegetables), noodle bowl (merienda/pancit/noodles), cup (drinks/coffee), bowl (pork/beef); otherwise the dish's emoji from the database.

#### 4.3 Icons, manifest and app files

| File | What it is |
|---|---|
| `icons/tpn-icon.svg` | 512×512 vector app icon: brick rounded square, saffron ring, "TPN" in Georgia/Playfair. Used by `counter.webmanifest` and precached by the service worker |
| `counter.webmanifest` | Install file for the counter: name "TPN Counter & Floor", short name "TPN Counter", start `./tpn-dine-in-floor`, full screen, landscape, background `#1a0a00`, theme `#8B1A0E`, the SVG icon. Linked only by the floor page |
| `tpn-counter-sw.js` | Offline service worker for the floor and customer screen (scope `./tpn-dine-in-floor`). Precaches the page, every script and style it names, Google Fonts, `counter.webmanifest`, `icons/tpn-icon.svg`, `assets/site/icon.png`, `logo.webp`, `hero.webp`, `mandala-a.webp`; keeps the last menu, modifier, table, branch and delivery-zone data. Version `tpn-counter-20261021b` |
| `android/app/src/main/res/mipmap-xxhdpi/ic_launcher.png` | Android launcher icon, 200×200, identical to `assets/site/icon.png` |
| Favicons | Every page: `assets/site/icon.png` (`rel="icon"`); website and portal also `rel="apple-touch-icon"` |

Line icons drawn in code (not files): the portal hub icons (`portal.html` 1461–1474), the tray/cloche icon (website, QR menu), category glyphs, the map pin, the select arrow (a data-URI SVG in brick, `tpn-forms.css` line 75).

#### 4.4 Fonts and where they load from

All fonts come from **Google Fonts** (`fonts.googleapis.com` for the CSS, `fonts.gstatic.com` for the files); none are stored in the repository. The pages' security rules allow only those two font hosts (`font-src 'self' https://fonts.gstatic.com data:`). See the table in 2.3 for which page requests which families. The portal's direct file URLs are in `tpn-portal.css` lines 22–43 (Fraunces `v38`, Plus Jakarta Sans `v12`). The offline counter caches the font CSS and files on install. Offline elsewhere, Georgia and the system sans-serif stand in.

#### 4.5 Third-party code in `vendor/`

| File | Version | Size | Licence (as stated in the file) | Used by | For |
|---|---|---|---|---|---|
| `supabase-js-2.117.2.js` | 2.117.2 | 218 KB | No licence header in the file. Not recorded in the repo | every page except the customer screen | Database, sign-in, live updates. A jsDelivr copy of the same version with a SHA-384 hash check is the fallback (not on the rewards page) |
| `gsap-3.12.5.min.js` | 3.12.5 | 72 KB | "Copyright 2024, GreenSock… Subject to the terms at https://gsap.com/standard-license" (`HANDOFF.md`: free standard licence, fine commercially) | customer screen | Animation |
| `qrcode-generator-1.4.4.js` | 1.4.4 | 57 KB | MIT, © 2009 Kazuhiko Arase | portal, floor, rewards; `slips.js` | Table QR codes, receipt stamp-card QR, rewards code |
| `imin-printer-1.4.0.min.js` | 1.4.0 | 29 KB | MIT, © 2022 archiesong | portal, floor | Talking to the iMin printer service at `127.0.0.1:8081` |
| `exceljs-4.4.0.min.js` | 4.4.0 (header dated 19-10-2023) | 948 KB | Not stated in the header | portal, loaded on first Excel export | Excel files |

Other outside services the pages call for display: OpenStreetMap map tiles (`tile.openstreetmap.org`, website only). The CSP of the website, portal, floor and kitchen also allows `api.qrserver.com`, but no code calls it (QR codes are drawn locally).

#### 4.6 Orphans and leftovers

- `assets/site/spread.webp` — not used.
- `.tpn-net` offline banner styles (`tpn-glass.css` 286–288) — no code creates that element.
- Portal two-factor screen — not reachable (see 1.3).
- Eyebrow strings `v3.best.eyebrow`, `v3.place.eyebrow`, `v3.locate.eyebrow` in `tpn-home.js` — not used.
- Old section labels `sec.*` in `portal.html` 337–343 — not drawn.
- An orphaned CSS fragment in `tpn-signin.css` line 36 (`font: 600 14px inherit; … cursor: pointer; }` with no selector of its own); browsers ignore it.

---

### 5. Printed slips (`modules/slips.js`)

**What:** the kitchen ticket and the customer receipt (or table bill), each drawn as **one black-and-white picture** in the v3 look and sent to the printer as an image.

**Size:** 80mm thermal paper is **576 dots** wide, so each slip is a 576-pixel-wide picture that prints dot for dot (`W = 576`, line 21), with 20px side padding. The picture is drawn on a 4000px-tall sheet and cropped to what was used. For 58mm paper the kitchen printer module scales it down to **384 dots** (`modules/kprint.js` line 30, 58–62).

**Fonts:** Fraunces for the table/guest name, quantities, the wordmark and totals; Plus Jakarta Sans for everything else. `TPN_SLIP.ready()` adds a Google Fonts link for `Fraunces:opsz,wght@9..144,700` and `Plus Jakarta Sans:wght@400;600;800`, loads the four faces it uses and the logo, and waits at most 4 seconds; offline, Georgia and the system sans-serif are used (lines 29–53).

**The dithered logo:** `logo.webp` is drawn into a 132×132 square on white, turned to grey, then to pure black and white dots using **Floyd–Steinberg dithering** (each pixel's rounding error is passed on to its neighbours 7/16, 3/16, 5/16, 1/16), so the badge prints as a dot pattern on thermal paper (lines 55–86). If the logo cannot load, the footer simply centres its text.

**Kitchen ticket layout** (`kitchen(t)`, lines 160–195), no prices:
1. A black rounded panel (24px corners) with the table — or guest name, or the order number — in Fraunces 700 at up to 62px (shrinks to 70% for long names, then wraps), and on the right "Dine-in / Take-out / Delivery" and the time (Plus Jakarta Sans 600, 25px).
2. The order number "#…" under it when there is a table or name.
3. One block per dish, separated by a 2px rule: the quantity in a left margin column (Fraunces 700, 46px), the dish name (Plus Jakarta Sans 800, 31px, wraps), then size and "+ add-ons" (400, 25px), and the dish note in an outlined rounded box (600, 25px, 3px line).
4. The guest's note for the whole order in an outlined box at the end.

**Receipt / bill layout** (`receipt(r)`, lines 197–269). Rules between blocks are 2px lines with 24px space above and below (`s.rule`, line 107; widened in Rev 37, "roomier slips"):
1. "Tyo Paeng Nyo" centred (Fraunces 700, 50px), address and phone (22px) — from the Website settings, falling back to "KM 19, 316 Real St., Talon Uno, Las Piñas" and "0999 888 7817".
2. Rule. For a bill: "Bill" and the table. "Order …" (or "Orders …" when a table had several rounds), date · time, "Deliver to: …" for deliveries.
3. Rule. Items: quantity, name and size, price right-aligned (25px).
4. Rule. Subtotal; Less discounts; Service charge; Delivery fee (each only when not zero).
5. A black panel: "Total" (receipt) or "Amount due" (bill), with the amount in Fraunces 700, 46px on the right.
6. Payments with their reference, Change, Balance (only when something is still owed), or "Paying by …" on a bill.
7. The stamp-card QR (at least 4 dots per square so phones can read it) with "Scan to collect your stamp" — only on a paid receipt, when rewards are on, and the order has a phone number (`fromOrders`, lines 333–360).
8. Rule. "Salamat po!" (Fraunces 700, 38px) and "This is not an official receipt." (21px) on the left, the dithered badge bottom-right.

**Printing paths:**
- **iMin counter printer** (`modules/imin.js`): the picture is sent with `printSingleBitmap`, then feed and cut. Jobs run one at a time. If the picture fails or takes over 15 seconds, a plain-text slip prints instead (sizes 20–40, about 32 characters a line at size 24, "--------------------------------" rules, "TOTAL" in bold 28, "Salamat po! Come again."). Test buttons **Test kitchen ticket**, **Test receipt** and **Test bill** (Rev 37) in the printer menu are a manager tool (`printer.manage`) and print the sample slips.
- **Kitchen network printer** (`modules/kprint.js`): the same picture converted to ESC/POS raster (bands of 128 rows, dots darker than 50% grey printed), then feed 4 lines and partial cut, sent through the TPN Counter app to port 9100.
- **Any other device:** a print window with `@page { size: 80mm auto; margin: 0 }` and the picture at 72mm wide (`printWindow`, lines 370–385).
- `TPN_SLIP.preview('kitchen' | 'receipt' | 'bill')` shows the sample slips in a window on any device.

**Test slips** (`sample`, lines 272–306): since Rev 37 they contain filler only, so a test can never be mistaken for a real order: order "TEST-0000", "Test table", "Sample dish one", "Sample dish two" (Big size, with "Sample note for the kitchen"), a deliberately long dish name to check wrapping (quantity 12), "Sample drink", and an order note. There are three: kitchen ticket, receipt (with a cash payment, change and the stamp QR) and a two-round table bill paid by GCash.

---

### 6. Languages: English and Tagalog

#### 6.1 Where the switch is

| Screen | Switch |
|---|---|
| Website | **EN / TL** in the top bar; **English / Tagalog** in the phone menu |
| Portal | **English / Tagalog** on the login screen, at the top of the sidebar on every page (`langSwitchHtml`, `portal.html` 1403), and in Preferences → Language |
| Floor, kitchen | **🌐 Tagalog** / **🌐 English** button in the top bar (`data-lang-toggle`; it shows the language you would switch to) |
| QR table menu | **EN / TL** in the top bar; opens in Tagalog by default |
| Rewards page, customer screen | No switch. English, with fixed Filipino phrases ("Salamat po!", "Mabuhay! · Kain na!") |

The choice is saved on the device in `localStorage` key **`tpn.lang`** (`en` or `tl`) and shared by every page on that device. The page's `lang` attribute changes with it.

#### 6.2 How text gets translated

There are five mechanisms, used side by side:

1. **Keyed strings.** `TPN_STRINGS` dictionaries of `{ en, tl }` pairs: about 310 keys in `portal.html` (from line 282) and a separate copy of about 309 in `index.html` (from line 663). Markup uses `data-i18n="key"` (text), `data-i18n-ph` (placeholder), `data-i18n-title` (tooltip), `data-i18n-html` and `data-i18n-lines` (for titles with `<i>`); code uses `T('key')`, which falls back to English, then to the key itself so a missing entry is obvious. `tpn-home.js` adds about 74 more (`STR`, line 17) for the v3 website; the QR menu has its own 109 (`tpn-table-menu.html` 298–408).
2. **Phrase layer, `tpn-i18n.js`** (loaded by the website, portal, floor and kitchen). Most portal screens write English straight into the page. This file holds **1,503 English → Tagalog phrases** (as of Rev 37) (`PHRASES`, line 23) and watches the page (a MutationObserver); whenever a known English phrase appears in text, a placeholder, a tooltip or an `aria-label`, it swaps in the Tagalog, and puts the English back when you switch back. Rules (header, lines 1–19): exact phrases only, never guessed; leading icons (✓ 🧾 +) and trailing arrows, ↗, "(3)" counts or "*" are kept; messages like "Could not save: <error>" match on their known start; joined labels split on " — ", " · " and ". " are translated piece by piece; anything marked `translate="no"` is left alone. The page title is translated too.
3. **Database text.** Dishes and ingredients have `name_tagalog`; roles and permissions have `label_tl`. These come from the row, not from a dictionary.
4. **Module labels.** Portal tabs added by modules carry `labelTl` (`TPN_MOD.label`, `tpn-kit.js` 71–74). The help guide writes every line as `{ en, tl }` (`modules/guide.js`).
5. **Page-specific dictionaries** on the QR menu (see 1).

**Translation style** (`portal.html` lines 274–281): the Tagalog a Las Piñas crew actually speaks, not textbook Filipino; loan words that are more natural stay ("order", "delivery", "stock", "schedule"); money and counts stay in numerals.

**To add a phrase:** put it in `PHRASES` in `tpn-i18n.js`, English → Tagalog (header line 19); for keyed text, add a key to the page's `TPN_STRINGS`.

**Not translated:** the rewards page, the customer screen, the printed slips (English with "Salamat po!"), and any English phrase that is not in a dictionary (it stays English by design).

---

### 7. Gaps and open points from this section

- **Default permission grants** are listed as each permission's seeded minimum role. The live grants can differ if someone changed Roles & Access; that can only be checked in the database.
- **Licences** for `supabase-js` and `exceljs` are not stated in the vendored files and are not recorded anywhere in the repo.
- **The portal font gap** (2.3) and the **rewards dark-mode** colours being blocked by `data-theme="light"` (2.1.4) are conclusions from reading the code; they were not checked in a browser.
- **`data-glass` and `data-text`** have styles but no control in Preferences; `data-motion="reduced"` is styled but never set.
- **What the photos look like:** only `logo.webp`, `icon.png`, the two mandalas and `paisley-light.webp` were viewed for this guide; the hero, dining and dish photos are described from their file names and the code comments.
- **Exact text of every portal dialog and form** is not listed here; the route table names each screen's purpose and main buttons only.
- **The repository changed while this section was written** (Rev 37, commit `c4d5b4b`: roomier slips, a Test bill button, the iMin simulator, one new phrase). Those changes are included; anything committed after `c4d5b4b` is not.

---

## Part 2 — Front-end code, devices and printing

This part explains the code that runs in the browser and on the restaurant's devices: the web pages, the shared JavaScript files, every file in `modules/`, the live (realtime) updates, the two Android apps, the iMin counter and its printer, the kitchen network printer, everything the system stores on a device, and the client-side security rules.

Everything here was read from the repository `tpn-os` (branch `main`, latest commit `4501448 HANDOFF Rev 36`). File paths are relative to the repository root. Where the code does not answer a question, this guide says "not found in code".

A short reading guide for the owner:

- **Sections 1–2** are about the files that make the screens work.
- **Section 3** is about how screens update by themselves.
- **Sections 4–5** are about the iMin counter, the Android apps and the printers.
- **Section 6** lists every piece of information kept on a device.
- **Section 7** is about what the browser is and is not trusted to do.
- **Section 9** lists things that look wrong or out of date in the code or the docs.

---

### 1. Architecture

#### 1.1 No framework, no build step

TPN OS is plain HTML, CSS and JavaScript. There is no React, no Vue, no bundler, no `npm build`. The files in the repository are exactly the files the browser downloads. The site is served as static files (GitHub Pages today; `vercel.json` is ready for Vercel). The database, sign-in and file storage are Supabase.

What this means in practice:

- Changing a page means editing the `.html` or `.js` file and publishing it. Nothing is compiled.
- Every page loads its scripts with ordinary `<script src="…">` tags, in a fixed order.
- Browsers cache scripts aggressively, so every script tag carries a version query, for example `tpn-kit.js?v=20261022b`. When a file changes, its `?v=` must be bumped in every page that loads it, or devices keep the old copy. (The counter's offline cache treats any `?v=` file as never changing; see 2.3.)
- Shared code is attached to `window` as globals (`window.TPN`, `window.TPN_PRINT`, and so on). Modules find each other through these globals and always check that the other module exists first (`if (window.TPN_PRINT) …`), so a page that does not load a module still works.
- Many page functions are called from inline `onclick="…"` attributes in HTML strings. That is why every page has `'unsafe-inline'` in its script policy (section 7.1) and why the `JA()` escaping helper exists (section 7.2).

#### 1.2 The pages and what each one loads

| Page (file) | What it is | Scripts loaded, in order |
|---|---|---|
| `index.html` | Public website | `vendor/supabase-js-2.117.2.js` (CDN fallback), `config.js`, `tpn-supabase.js`, `tpn-kit.js`, `tpn-site.js`, `tpn-i18n.js`, `modules/photos.js`, `tpn-home.js` |
| `portal.html` | Staff portal (admin and staff sides) | supabase-js (CDN fallback), `config.js`, `tpn-supabase.js`, `tpn-kit.js`, `tpn-site.js`, `tpn-i18n.js`; at the end: `modules/website.js`, `vendor/qrcode-generator-1.4.4.js`, `modules/payments.js`, `modules/invoices.js`, `modules/photos.js`, `modules/pos.js`, `vendor/imin-printer-1.4.0.min.js`, `modules/slips.js`, `modules/kprint.js`, `modules/imin.js`, `modules/modifiers.js`, `modules/clockin.js`, `modules/stamps.js`, `modules/excel-io.js`, `modules/delivery.js`, `modules/guide.js`, `modules/search.js` |
| `tpn-dine-in-floor.html` | Floor & Counter (tables, Counter POS, payments) | supabase-js (CDN fallback), `config.js`, `tpn-supabase.js`, `tpn-kit.js`, `modules/offline.js`, `tpn-i18n.js`; after the sign-in gate: `modules/signin.js`; at the end: `vendor/qrcode-generator-1.4.4.js`, `modules/customer-display.js`, `modules/payments.js`, `modules/invoices.js`, `modules/photos.js`, `modules/pos.js`, `vendor/imin-printer-1.4.0.min.js`, `modules/slips.js`, `modules/kprint.js`, `modules/imin.js`, `modules/guide.js` |
| `tpn-dine-in-floor-customer.html` | The customer screen on the back of the iMin | `vendor/gsap-3.12.5.min.js`, `modules/customer-display.js` (no Supabase at all) |
| `tpn-kitchen-station.html` | Kitchen screen | supabase-js (CDN fallback), `config.js`, `tpn-supabase.js`, `tpn-kit.js`, `tpn-i18n.js`; after the gate: `modules/signin.js`; at the end: `modules/guide.js` |
| `tpn-table-menu.html` | QR table menu (guests' phones) | supabase-js (CDN fallback), `config.js`, `tpn-supabase.js`, `tpn-kit.js`; at the end: `modules/photos.js`, `tpn-home.js` |
| `tpn-rewards.html` | Customer stamp card | `vendor/supabase-js-2.117.2.js` (no CDN fallback on this page), `config.js`, `tpn-supabase.js`, `tpn-kit.js`, `vendor/qrcode-generator-1.4.4.js` |

Stylesheets: `tpn-app.css`, `tpn-glass.css`, `tpn-site-v3.css` (website, table menu), `tpn-portal.css` (portal), `tpn-ui.css` and `tpn-signin.css` (floor), `tpn-signin.css` (kitchen), `tpn-forms.css` (all staff and public pages, loaded last), plus Google Fonts.

#### 1.3 Load order and the Supabase library

The order matters because each file uses the one before it (comment at the top of `tpn-kit.js`):

```
supabase-js → config.js → tpn-supabase.js → tpn-kit.js → page script → modules/*.js
```

**Supabase library.** Every page first loads the local copy `vendor/supabase-js-2.117.2.js`. On `index.html`, `portal.html`, `tpn-dine-in-floor.html`, `tpn-kitchen-station.html` and `tpn-table-menu.html` an inline script then checks `window.supabase`; if the local copy failed, it writes a script tag for the same pinned version from `cdn.jsdelivr.net` with a Subresource Integrity hash (`sha384-Rj26LVGvoeRVR6+mwQmFfcR3QOBEwT+ZmuCWpuiqeTzJpCs0ER4ITAWGb4Hiy3Ok`), so the browser refuses a tampered CDN file. `tpn-rewards.html` has no such fallback.

**Anti-framing.** Every page except the customer screen (`tpn-dine-in-floor-customer.html`) starts with a script that breaks out of, or blanks itself inside, someone else's frame, because GitHub Pages cannot send an `X-Frame-Options` header (clickjacking protection).

**Clean URLs.** `tpn-dine-in-floor.html` and `tpn-rewards.html` rewrite `….html` to the address without `.html` using `history.replaceState`.

#### 1.4 `config.js`

Sets one global, `window.TPN_CONFIG`, with two values:

- `SUPABASE_URL` — the project address (`https://xjlqfpnzobfqxetgkkai.supabase.co`).
- `SUPABASE_ANON_KEY` — the public "anon" key. The file's own comment says this key is safe to be public because Row Level Security in the database protects the data, and that the `service_role` key must never be put here.

This is the only file holding the project keys. `tpn-supabase.js`, `offline.js` and the payments helper read them from `window.TPN_CONFIG`.

#### 1.5 `tpn-supabase.js` — the data layer

This file creates the Supabase client and the `TPN` object that almost every screen uses to read and write data. It ends with `window.TPN = TPN; window.sb = sb;`.

**The client (`sb`).** Created with `window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, …)`.

- On the QR table menu (any path matching `tpn-table-menu`) the client is created with `persistSession: false`, `autoRefreshToken: false`, `detectSessionInUrl: false` and `storageKey: 'sb-tpn-anon'`. The comment explains why: if a staff member had ever signed in on that browser, their login would otherwise be restored and the guest's order would go through the staff security path and fail with "permission denied". So the QR menu always acts as an anonymous guest.
- Everywhere else: `persistSession: true`, `autoRefreshToken: true`, `detectSessionInUrl: false` (the staff login is kept on the device and refreshed).

**Session restore.** At the bottom of the file, `sb.auth.onAuthStateChange` loads the staff profile and then the permissions on `SIGNED_IN` or `INITIAL_SESSION`, and clears all cached user data on `SIGNED_OUT`.

##### Every `TPN.*` function, grouped

Functions that call a database function ("RPC") name it in brackets. "No caller found" means no page or module in the repository calls it (searched: all `.html` files, `modules/*.js`, `tpn-home.js`, `tpn-site.js`).

**Sign-in and roles**

| Function | What it does |
|---|---|
| `login(email, password)` | Signs in with email and password, then loads the staff profile. |
| `logout()` | Signs out. Wrapped later in the file so it also clears the cached branches and menu. |
| `loadProfile()` | Reads the signed-in user's row from `staff` (with its branch) into `TPN._user`. Replaced on the floor screen by `offline.js` (section 2.3). |
| `currentUser()` | Returns the cached staff profile. |
| `ROLE_HIERARCHY` | The role ladder, lowest first: `kitchen_display, dine_in_display, dining, kitchen, supervisor, manager, admin, director, ceo`. Comment: must match the database enum order. |
| `DISPLAY_ROLES` | The two shared wall-screen roles: `kitchen_display`, `dine_in_display`. |
| `hasRole(minRole)` | True if the user's role is at or above `minRole` in the ladder. |
| `isDisplayAccount(role)` | True for the two wall-screen roles. |
| `displayHome(role)` | Which page a wall-screen account belongs on (`tpn-kitchen-station` or `tpn-dine-in-floor`). |

**Permissions (what the screen offers)**

| Function | What it does |
|---|---|
| `loadPermissions()` | Loads the user's permission keys [`my_permissions`]. If that fails, sets `_permsFailed` so `can()` falls back to role tiers. Replaced on the floor screen by `offline.js`. |
| `FALLBACK_CREW_KEYS`, `FALLBACK_ADMIN_KEYS`, `_fallbackCan(key)` | The old tier rules used only when permissions could not be loaded: admin keys need `admin`, crew keys need `dining`, `payroll.edit` needs `ceo`, anything else needs `manager`. |
| `can(key)` | True if the user has the permission. `ceo` always true. Comment: "Hiding a button is courtesy; the database is the security boundary." |
| `canAny(...keys)` | True if any of the keys is allowed. |
| `getAccessRoles()` | Reads `access_roles`. |
| `getAccessMatrix()` | [`access_matrix`] the role × permission grid. |
| `getPermissionCatalogue()` | Reads `permissions`. |
| `createAccessRole(row)`, `updateAccessRole(id, patch)`, `deleteAccessRole(id)` | Edit custom roles (the database refuses deleting the nine built-ins). |
| `setRolePermission(roleId, key, allowed)` | Upserts one cell of the matrix. |
| `assignAccessRole(staffId, roleId)` | Sets `staff.access_role_id`. |
| `getStaffOverrides(staffId)`, `setStaffOverride(...)`, `clearStaffOverride(...)` | Per-person permission exceptions. |
| `getStaffDirectory()` | [`staff_directory`] minimal staff list for people who can assign tasks. |

**Branches, menu, tables**

| Function | What it does |
|---|---|
| `getBranches()` | Active branches, cached in `TPN._branches`. |
| `getBranchByCode(code)` | One branch by its code (e.g. `laspinas`). |
| `invalidateBranchCache()` | Clears the branch cache. |
| `loadMenu(branchCode)` | Active categories and available items; filters by `branch_availability` when a branch code is given. |
| `itemsInCategory(categoryId)` | Items of one category from the cached menu. No caller found. |
| `loadGroupedMenu(branchCode)` | Menu grouped by category in the shape the website and QR menu draw. |
| `getFeaturedItems()` | Up to 8 featured items, shuffled, for the website slideshow. |
| `loadModifiers()` | Add-on groups, their choices, and which dishes they apply to. |
| `setItemAvailable(itemId, available, reason)` | [`set_item_available`] the "86 / sold out" switch. |
| `getAddonSuggestions(excludeIds, limit)` | [`addon_suggestions`] "goes well with" suggestions. |
| `getTablesForBranch(branchId)` | Active tables of a branch. |
| `getTableByNumber(branchCode, n)` | One table. |
| `ackCallStaff(tableId)` | [`ack_call_staff`] clears a table's "call staff" signal. |
| `ackBillRequest(tableId)` | [`ack_bill_request`] clears a table's "bill please" signal. |

**Orders**

| Function | What it does |
|---|---|
| `deviceId()` | A random id this browser makes for itself once and keeps in `localStorage` `tpn.device`; used to group one table's bill by phone. Comment: "Not a fingerprint". |
| `createOrder(opts)` | Places an order through [`submit_order`] (never a direct insert). Sends items, table, customer, notes, delivery address/zone, scheduled time, `p_device_id`, `p_join_table_bill`, `p_source`, `p_client_key`. If the database is older and has no `p_client_key` (error `PGRST202`), retries without it. Saves the returned tracking token. |
| `orderKey(prev, sig)` | The idempotency key for one checkout attempt: same order again gives the same key; a changed order gives a new key. |
| `_trackKey`, `_saveTrackToken`, `_trackToken` | Keep the last 30 order tracking tokens in `localStorage` `tpn.trackTokens`. The token proves this device placed the order. |
| `prettyOrderError(msg)` | Turns database error codes (`no_items`, `item_sold_out`, `delivery_min_order`, `too_many_requests`, …) into plain sentences for guests. |
| `getOrder(id)` | One order with its items and table (staff). |
| `getOrderByNumber(orderNumber)` | [`track_order`] one order by its number; with the device's token it returns full detail, without it progress only. |
| `subscribeToOrder(idOrNumber, cb, opts)` | Watches one order for a guest by **polling** `track_order` every 8 seconds (guests cannot use realtime; see section 3). Returns a stop function. |
| `subscribeToOrderRealtime(orderId, cb)` | Staff realtime watch of one order. No caller found. |
| `getTableBill(tableId)` | [`table_bill`] a table's open bill grouped by phone. No caller found. |
| `splitTableBill(orderId, deviceId)` | [`split_order_by_device`] moves one phone's lines to their own bill (staff only). |
| `listActiveOrders(branchId)` | Orders in `pending`, `confirmed`, `preparing`, `ready`. |
| `listTodayOrders(branchId)` | Orders since local midnight. No caller found. |
| `listOrdersSince({sinceMinutes, branchId})` | Live orders plus anything placed in the last N minutes (default 60), max 200. |
| `listOrdersToday({branchId})` | Every non-cancelled order since Manila midnight, max 1000 (dashboard revenue). |
| `updateOrderStatus(orderId, status)` | Direct status update with the matching timestamp. Used only as a fallback. |
| `advanceOrderStatus(orderId, status, source)` | [`advance_order_status`] the normal way to move an order, recording which screen did it (`kitchen_screen`, `floor_panel`, …). Falls back to `updateOrderStatus` only if the RPC does not exist. |
| `prettyStatusError(msg)` | Plain messages for status errors (`closing_requires_manager`, …). |

**Voids**

| Function | What it does |
|---|---|
| `voidOrderItem(itemId, reason)` | [`void_order_item`] manager void. |
| `unvoidOrderItem(itemId)` | [`unvoid_order_item`]. |
| `requestVoid({orderId, itemId, reason})` | [`request_void`] staff below manager ask for a void (`itemId` null = whole order). |
| `voidRequestErrorText(e)` | Plain messages for void errors. |
| `listVoidRequests({status, limit, mineOnly})` | Reads the `v_void_requests` view. |
| `pendingVoidRequestCount()` | [`pending_void_request_count`]. |
| `approveVoidRequest(id, note)`, `denyVoidRequest(id, note)`, `cancelVoidRequest(id)` | [`approve_void_request`], [`deny_void_request`], [`cancel_void_request`]. |
| `subscribeVoidRequests(cb)` | Realtime on `void_requests` (section 3). |

**Discounts**

| Function | What it does |
|---|---|
| `listDiscountTemplates(activeOnly)`, `createDiscountTemplate`, `updateDiscountTemplate`, `deleteDiscountTemplate` | Manage discount templates; each change is written to the audit log. |
| `listAppliedDiscounts(orderId, opts)` | Discounts on one order. |
| `applyDiscount(orderId, templateId, idRef, coveredAmount)` | [`apply_discount`] the server computes the amount. |
| `removeDiscount(appliedId, reason)` | [`remove_discount`]. |

**Payments, cash drawer, daily close**

| Function | What it does |
|---|---|
| `_fnUrl(name)`, `_callFn(name, body)` | Call a Supabase Edge Function (20-second timeout) with the user's token, or the anon key for guests. |
| `startOnlinePayment({orderNumber, orderId, returnPath, returnQuery})` | Calls the `hitpay-create` edge function. Staff pass the order id; a guest must have the tracking token saved on this device, or it refuses. |
| `orderPayments(orderId)` | [`order_payments`] an order's totals, amount due and every payment row. |
| `recordCash(orderId, tendered, {amount, tip, cashSession, note})` | [`record_cash_payment`]. |
| `recordManualPayment(orderId, method, reference, {...})` | [`record_manual_payment`] GCash, Maya, QR Ph, card, bank taken by hand. |
| `settleTableCash(orderIds, tendered, {...})` | [`settle_table_cash`] one cash payment for a whole table. |
| `settleTableManual(orderIds, method, reference, {...})` | [`settle_table_manual`]. |
| `ordersAmountDue(orderIds)` | [`orders_amount_due`]. |
| `recordBankTransfer(orderId, amount, reference, note)` | [`record_bank_transfer`] a transfer waiting for confirmation. |
| `confirmBankTransfer(paymentId, received, note)` | [`confirm_bank_transfer`]. |
| `refundPayment(payment, amount, reason)` | HitPay payments go through the `hitpay-refund` edge function; others through [`refund_payment`]. |
| `setServiceCharge(orderId, {percent, amount})` | [`set_service_charge`]. |
| `listPayments({from, to, status, method})` | Reads `payments` (max 500). |
| `prettyPaymentError(msg)` | Plain messages (`not_enough_cash`, `needs_second_person`, `payment_state_is_derived`, …). |
| `myOpenCashSession(register)`, `openCashSession(float, register)`, `cashMove(session, kind, amount, reason)`, `cashSessionReport(session)`, `closeCashSession(session, counted, denominations, notes)` | The cash-drawer shift: [`my_open_cash_session`], [`open_cash_session`], [`cash_move`], [`cash_session_report`], [`close_cash_session`]. Register name defaults to `Counter`. |
| `getDailyCloseReport(date)`, `recordDailyClose(date, counted, notes)`, `listDailyCloses(limit)` | [`daily_close_report`], [`record_daily_close`], [`list_daily_closes`]. |

**Delivery**

| Function | What it does |
|---|---|
| `deliveryZones(includeOff)`, `saveDeliveryZone(zone)`, `deleteDeliveryZone(id)` | Delivery areas and fees. |
| `deliveryBoard({sinceHours})` | Open and recent delivery orders with their dispatch row (default 18 hours, max 100). |
| `deliveryAssign(orderId, {...})` | [`delivery_assign`] rider or courier. |
| `deliveryUpdate(orderId, status, reason)` | [`delivery_update`]. |
| `setDeliveryFee(orderId, {...})` | [`set_delivery_fee`]. |
| `trackDelivery(orderNumber, token)` | [`track_delivery`] guest view. |
| `prettyDeliveryError(msg)` | Plain messages. |

**Staff, schedules, attendance**

| Function | What it does |
|---|---|
| `listStaff()`, `updateStaffRole`, `updateStaffEmploymentStatus`, `updateStaffBranch`, `updateStaffAssignment` | Staff records; each change is audit-logged. |
| `weekStartISO(d)` | Monday of a week as `YYYY-MM-DD`. |
| `getSchedule`, `listSchedulesForWeek`, `upsertSchedule`, `deleteSchedule` | Weekly schedules. |
| `clockIn(notes, {expectPhoto})` | [`clock_in_verified`] (server sets time and IP). Falls back to a direct insert only if the RPC does not exist. |
| `attachClockinPhoto(attendanceId, path, blob)` | Uploads to storage bucket `attendance-photos`, then [`attach_clockin_photo`]. |
| `myNetworkStatus()` | [`my_network_status`] is this device on a trusted restaurant network. |
| `clockOut()` | [`clock_out_verified`], with a direct-update fallback. |
| `getOpenShift()`, `getMyAttendance(days, staffId)`, `getAttendanceSummary(ids, days)`, `listAttendanceForDate(date)`, `correctAttendance(id, patch)` | Attendance reads and corrections. |

**Messages, notifications, inquiries, audit, reports**

| Function | What it does |
|---|---|
| `listMyMessages`, `listSentMessages`, `sendMessage`, `markMessageRead`, `markAllMessagesRead` [`mark_read`], `unreadMessageCount` | Staff messages. |
| `listNotifications` [`my_notifications`], `unreadCounts` [`my_unread_counts`], `unreadNotifCount`, `markNotifRead`, `markAllNotifsRead` [`mark_read`], `deleteNotification` [`dismiss_notification`] | Notifications (read state is per person). |
| `pushNotification({...})` | Inserts a notification directly. No caller found. |
| `createInquiry({...})` | Website inquiry form; the id is made in the browser because visitors may not read inquiries back. |
| `listInquiries(status)` | Staff list. |
| `logAudit(action, entityType, entityId, metadata)` | Writes an `audit_log` row with the user's id, role and browser user agent. |
| `getAuditDailyCounts` [`audit_daily_counts`], `listAuditForDay`, `getSalesPerformanceMonth` [`sales_performance_month`], `archiveAuditLog` [`audit_log_archive_old`] | History and performance screens. (`listAuditForDay` builds one query it never uses, then runs a second; harmless.) |

**Tasks, inventory, finance, payroll, guests**

| Function | What it does |
|---|---|
| `getTasks` [`task_board`], `createTask`, `updateTask`, `deleteTask`, `setTaskAssignees`, `setMyTaskState` [`set_my_task_state`], `getTaskActivity` | Task board. |
| `getInventory` [`inventory_board`], `getSuppliers`, `saveSupplier`, `saveIngredient`, `deleteIngredient` (soft: sets `is_active=false`), `recordStockMovement`, `getStockMovements`, `getInventoryVariance` [`inventory_variance`] | Inventory. Stock is never typed directly; it is the sum of movements. |
| `getFinanceSummary` [`finance_summary`], `getExpenseBreakdown` [`expense_breakdown`], `getFinanceSettings`, `saveFinanceSettings`, `getExpenses`, `saveExpense`, `deleteExpense`, `getCompensation`, `setCompensation` | Finance and pay rates (a rate change closes the old row and opens a new one). |
| `getPayrollRuns`, `getPayrollItems`, `buildPayrollRun` [`build_payroll_run`], `rebuildPayrollRun` [`rebuild_payroll_run`], `setPayrollStatus` [`set_payroll_status`], `updatePayrollItem`, `deletePayrollRun`, `prettyPayrollError` | Payroll. Note: `updatePayrollItem` computes `net = max(0, gross − deductions)` in the browser and writes it. |
| `getGuestProfile` [`guest_profile`], `getMyGuestProfile` [`my_guest_profile`], `listGuests` [`guest_list`], `flagGuest` [`flag_guest_device`], `unflagGuest` [`unflag_guest_device`], `setGuestNote` [`set_guest_note`] | Guest profiles. |

**Live updates, sound, time and helpers**

| Function | What it does |
|---|---|
| `subscribeOrders(branchId, cb)` | Realtime on `orders`, built on `liveChannel` (section 3). |
| `subscribeInquiries`, `subscribeAttendance`, `subscribeToTasks` | Plain realtime channels. No caller found. |
| `subscribeMessages(cb)` | Realtime inserts on `messages`. |
| `subscribeNotifications(cb)` | Realtime on `notifications`; rebuilds itself on wake. |
| `liveChannel(name, configure)` | A realtime channel that reports its health and rebuilds itself after errors (2 s, 4 s, 8 s … max 30 s). |
| `liveStatus()`, `onLiveStatus(fn)`, `_recomputeLive()` | The combined health of all live channels: `connecting`, `live` or `down`, plus the time of the last event and reconnect count. |
| `registerResub(fn)`, `_runResub()` | Functions to re-run when the tab becomes visible again or the network comes back. |
| `broadcast(kind, payload)`, `onBroadcast(handler)` | Same-browser messages between tabs (`BroadcastChannel 'tpn-os-sync'`, or `localStorage 'tpn.bcast'` as fallback). No caller found. |
| `agoText(ts)` | "12s ago", "3 min ago" for the status pill. |
| `audioCtx()`, `unlockAudio()`, `audioReady()`, `chime(notes, volume)` | Sound. Browsers stay silent until the screen has been tapped once; `unlockAudio()` must run inside a tap. |
| `TZ`, `today(d)`, `dayStartISO(ymd)` | The restaurant's day is Manila's calendar day (`Asia/Manila`), not UTC. |
| `esc(v)` | HTML-escapes `& < > " '`. |
| `escAttr(v)` | `esc` plus the backtick. |

**Added to `TPN` by other files**

- `tpn-kit.js`: `TPN.retry`, `TPN.withTimeout`.
- `modules/invoices.js`: `TPN.recordOrderInvoice` [`record_order_invoice`], `TPN.invoiceDaySummary` [`invoice_day_summary`], `TPN.recordDayInvoice` [`record_day_invoice`].
- `modules/offline.js` (floor screen only): replaces `TPN.loadProfile` and `TPN.loadPermissions` with versions that remember the last sign-in (section 2.3).

#### 1.6 `tpn-kit.js` — shared tools

**App detection and redirects (top of the file, runs immediately)**

- If the browser's user agent contains `TPNCounter/` or `TPNKitchen/` (the two Android apps add this, section 4), it adds the class `tpn-lite` to the page, which turns off glass effects and long animations on the POS-grade graphics chip.
- Inside either app, the public website, the QR table menu and the rewards page are not allowed: if the page name is `''`, `index`, `tpn-table-menu` or `tpn-rewards`, it replaces the page with `tpn-kitchen-station` (Kitchen app) or `tpn-dine-in-floor` (Counter app). The portal is allowed.

**`peso(v)`** — the one money formatter: `Intl.NumberFormat('en-PH', { style: 'currency', currency: 'PHP', minimumFractionDigits: 2 })`; a non-number shows as ₱0.00.

**`TPN_MOD` — the module router.** Lets a file in `modules/` add a page (tab) to the portal without editing `portal.html`.

- `TPN_MOD.register(def)` needs an `id` and a `render(main, side)` function. Defaults: `side: 'admin'`, `section: 'sec.workspace'`, `icon: '•'`. Other fields used: `label`, `labelTl`, `perm` (permission key), `hidden`, `when()`, `after` (place after another tab), `badge()` (number on the tab), `external`. If the portal is already showing, the sidebar is redrawn.
- `TPN_MOD.navFor(side)` returns the tabs for `'admin'` or `'staff'` (a `side: 'both'` tab appears on both), skipping hidden ones and those the user lacks `perm` for. `portal.html` merges these into its own sidebar sections and reads `after` and `badge` itself.
- `TPN_MOD.label(def)` picks the Tagalog label when the language is Tagalog.
- `TPN_MOD.render(id, main, side)` draws a module page; if it fails after the user has already moved to another page, the error is not painted over the new page.
- `window.tpnWho()` returns the portal's `currentUser` (it is declared with `let` in `portal.html`, so it is not on `window`).

**Dialogs** (own overlay, so a confirm raised from inside an open modal does not replace it; focus is trapped; Escape cancels; Enter confirms; clicking the dark background cancels):

- `tpnConfirm(message, opts)` → resolves `true` or `false`.
- `tpnAsk(title, opts)` → resolves the typed text, or `null` if cancelled. `opts.input` sets the field type, `opts.chips` adds quick-choice buttons, `allowEmpty` permits a blank answer, `danger` makes the button red.
- `tpnAlert(message, opts)` → a single OK.

**Resilience**

- `tpnWithTimeout(promise, ms, what)` — rejects with "The … took too long. Check the connection and try again."
- `tpnRetry(fn, {tries=3, base=600, timeout=12000, what})` — retries with growing waits. It does not retry refusals (permission, RLS, validation, JWT). The comment is explicit: **only for reads**, never for writes, because a write that timed out may have landed and a retry could double an order or payment.
- `tpnDraft` — autosaves a form into `localStorage` `tpn.draft.<name>` and restores it for 3 days; password, hidden and file fields and anything marked `data-no-draft` are never stored. Used by the website's event and tasting forms (`tpn.draft.event-form`, `tpn.draft.tasting-form`).

**Spreadsheets**

- `tpnLoadExcel()` — loads ExcelJS from `vendor/exceljs-4.4.0.min.js`, or the pinned CDN copy if that fails.
- `tpnExport(rows, columns, opts)` — Excel (default) or CSV download. Money columns stay numbers with a ₱ format, header row frozen, auto-filter on. CSV gets a byte-order mark so Excel reads ñ and ₱. Any cell starting with `= + - @` (or tab/CR) gets a leading `'` so Excel cannot run it as a formula (formula-injection protection).
- `tpnImport({title, columns, onCommit, maxRows=2000, templateName})` — pick file, preview with every bad row marked, import only the good rows. Nothing is written until Import is pressed. Offers a blank template.
- `tpnExportButton(fnName, label)` — the "⬇ Export ▾ Excel / CSV" menu.

**Other UI helpers**: `tpnTabs(name, tabs, current, onChangeFn)` (pill bar on wide screens, a dropdown on phones), `tpnEnter(el)` (one-time rise-in animation).

**Session guard** (`window.tpnSession`)

- Signing out in one tab signs out every tab on that browser (`BroadcastChannel 'tpn-session'`).
- If the login can no longer refresh (expired, revoked, password changed), a "Your session ended" dialog offers sign-in instead of every list turning into permission errors. This listener is skipped on the QR table menu.
- When the network returns, the session is re-checked. Offline, it returns "unknown" and does not sign anyone out.

#### 1.7 `tpn-i18n.js` — English ⇄ Tagalog

A large dictionary (`PHRASES`, English → Tagalog) of exact phrases. A `MutationObserver` watches the page and swaps known English text, placeholders, tooltips and `aria-label`s when the language is Tagalog, and puts the English back when switched back. Rules from the file header:

- Exact phrases only; names, dishes and numbers from the database are never guessed. Unknown phrases stay English.
- Leading icons and trailing arrows, badges like "(3)" and "*" are kept around the translated phrase.
- Anything marked `translate="no"` is never changed.

Exposes `window.TPN_I18N = { apply(l), toggle(), t(s), has(s), size }`. The language is stored in `localStorage` `tpn.lang`. Screens without the portal's language switch (floor, kitchen) use a button with `data-lang-toggle` that shows the language you would switch to.

#### 1.8 `tpn-site.js` — website content

Loads contact details, hours, FAQs, testimonials [`public_testimonials`] and event packages from the database so the portal's Website tab can change them without a deploy. Order of fallbacks: live database → last good copy on the device (`localStorage` `tpn.site.v1`) → the text already written in the HTML. Exposes `window.tpnSite = { state, load(), refresh }`. It does **not** auto-load on the QR menu, kitchen station or floor screen. Consequence: on the floor screen `window.tpnSite` is undefined, which matters for payments (section 2.2).

#### 1.9 `tpn-home.js` — website home and menu cards

Customer site only (loaded by `index.html` and `tpn-table-menu.html`). Header comment: "Nothing here talks to the database." It uses what the page already has (`menuData`, `T()`, `E()`/`JA()`, `addToCart()`, `navigate()`). Exposes `window.tpnHome = { card, renderMenuGrid, emptySearch, renderBestsellers, relang, afterRender, pop, shown, scrollToBest }`. It adds its own strings to `TPN_STRINGS`, draws bestsellers, place photos, and a small map from OpenStreetMap tiles (`tile.openstreetmap.org`) centred on the point in the `contact.map_url` setting.

#### 1.10 Helpers each page defines for itself

| Helper | Where | What |
|---|---|---|
| `E(v)` | `portal.html`, `index.html`, `tpn-dine-in-floor.html`, `tpn-kitchen-station.html`, `tpn-table-menu.html`, `tpn-rewards.html`, `tpn-dine-in-floor-customer.html` | HTML-escape (uses `TPN.esc` where loaded). |
| `JA(v)` | portal, index, floor, kitchen, table menu | For a value inside a JS string inside an inline `onclick`: first replaces `\ ' " < > newline` etc. with `\uXXXX`, then HTML-escapes. Comment: the browser HTML-decodes the attribute before running it, so `E()` alone would let a `'` through. |
| `N(v, d)` | floor | Number to fixed decimals, 0 for non-numbers. |
| `guardAsync(name)` | portal (full version), floor (simple version) | Wraps a `window` function so a second tap while the first is still running is ignored; the portal version also disables and marks the pressed button busy. |
| `toast`, `showModal`, `getPref`, `loadErrorPanel`, `route` | floor (adapters) | The modules were written for the portal; the floor page provides these so the same modules work there. `getPref` reads `localStorage` `tpn.prefs`. |

---

### 2. Every file in `modules/`

Summary of who loads what:

| Module | Global(s) | Portal | Floor | Kitchen | Other |
|---|---|---|---|---|---|
| `pos.js` | `posStartFor`, `posSend`, `printKitchenAtCounter`, `open86Panel`, many `pos*` | ✓ (86 panel only; route hidden) | ✓ (Counter tab) | | |
| `payments.js` | `openPaymentPanel`, `printReceipt`, `pay*` | ✓ | ✓ | | |
| `offline.js` | `TPN_OFFLINE` | | ✓ | | |
| `invoices.js` | `TPN_INVOICES`, `inv*` | ✓ | ✓ | | |
| `stamps.js` | `rw*` | ✓ | | | |
| `customer-display.js` | `TPN_CDS`, `tpnCdsReceive` | | ✓ | | customer screen |
| `signin.js` | `TPN_SIGNIN` | | ✓ | ✓ | |
| `imin.js` | `TPN_PRINT` | ✓ | ✓ | | |
| `slips.js` | `TPN_SLIP` | ✓ | ✓ | | |
| `kprint.js` | `TPN_KPRINT` | ✓ | ✓ | | |
| `photos.js` | `TPN_PHOTO` | ✓ | ✓ | | website, table menu |
| `guide.js` | `TPN_GUIDE` | ✓ | ✓ | ✓ | |
| `search.js` | `TPN_SEARCH` | ✓ | | | |
| `clockin.js` | `openClockinCamera`, `ci*` | ✓ | | | |
| `delivery.js` | `dlv*`, `_tpnWaitingDeliveries` | ✓ | | | |
| `modifiers.js` | `mod*` | ✓ | | | |
| `website.js` | `web*` | ✓ | | | |
| `excel-io.js` | `tpnExcelIO` | ✓ | | | |

Tabs registered with `TPN_MOD`:

| id | Module | Side | Section | Permission | Badge |
|---|---|---|---|---|---|
| `pos` | pos.js | both, **hidden** | — | `pos.use` | — |
| `payments` | payments.js | admin | `sec.money` | `finance.view` | pending bank transfers |
| `rewards` | stamps.js | both | `sec.money` | `rewards.redeem` | — |
| `clockin-review` | clockin.js | admin | `sec.team`, after `attendance-admin` | `attendance.verify` | clock-ins needing approval |
| `deliveries` | delivery.js | both | (default) | `delivery.dispatch` | deliveries waiting for a rider |
| `modifiers` | modifiers.js | admin | `sec.stock`, after `menu-manager` | `menu.edit` | — |
| `website` | website.js | admin | `sec.stock`, after `table-qr` | `site.edit` | — |

#### 2.1 `pos.js` — Counter POS

**Purpose.** Ring up walk-in and phone orders: take-out (`pickup`), dine-in and delivery. Built for "gloves-on tapping": big tiles, search, a ticket that stays visible, nothing lost on reload.

**Where it runs.** On the floor screen's Counter tab (`tpn-dine-in-floor.html` calls `TPN_MOD.render('pos', …)`). The portal loads the file but the `pos` route is registered `hidden: true`; the portal uses it only for the 86 panel on the kitchen board (comment at the bottom of the file).

**Data it loads.** Branch `laspinas`, active categories, all menu items, modifiers, tables, the user's open cash-drawer shift (only if the user has `cash.drawer`), and delivery zones. The open shift id is put in `window.tpnCashSessionId`. If `offline.js` is present, the shift id is remembered on the device (`tpn.offline.cashSession`) so cash taken offline can still be tied to it.

**Key flows**

- **Drawer bar** (needs `cash.drawer`): Open shift (float with quick chips 1000/2000/3000), Cash in / Cash out with reason chips, X read (mid-shift report, printable), Close shift (Z read) with a denomination count (₱1000 down to ₱0.25), live "exact / over / short" and a confirm if the count does not match ("The difference is recorded with your name").
- **Menu grid**: category tabs, search (press `/` to focus), tiles with a dish photo (from `TPN_PHOTO`) or emoji, "Sold out" tiles disabled.
- **Picking a dish**: if it has sizes (`pax_options`) or add-on groups, a dialog asks for size, required/optional choices (min/max enforced), quantity (1–50) and a kitchen note. Same dish + size + add-ons + note adds to the existing line.
- **Prices on the ticket are display only.** `linePrice()` comment: "display only; the server prices the order". The ticket says "Final price is checked by the server when you send." The order sent to the server contains dish ids, quantities, sizes, notes and add-on ids — no prices.
- **Order type**: Take-out, Dine-in (choose table), Delivery (address and, if zones exist, area; the zone's fee is shown).
- **Send** (`posSend`): makes an idempotency key with `TPN.orderKey` (same order → same key), then:
  - Online: `TPN.createOrder` with `source: 'pos'` and a 15-second timeout (when `offline.js` is present).
  - Offline, or a network error: the order goes to the offline outbox (`TPN_OFFLINE.queueOrder`) with a local number like `OFF-007`. Any other error is shown and nothing is queued.
  - Then the ticket is cleared, a kitchen ticket is printed (see below), and take-out/delivery open the payment panel (online: `openPaymentPanel`; offline: `TPN_OFFLINE.openPayment`). Dine-in is paid when the table closes (Floor → Close table); after a dine-in send the floor page switches back to the floor.
- **Kitchen ticket routing** (`printKitchenTicket`):
  1. If `TPN_KPRINT` is loaded, its "Kitchen tickets" setting decides (section 2.12): kitchen printer, counter printer, or screen only. Offline, a ticket always prints at the counter because the kitchen screen cannot see the order.
  2. Without `TPN_KPRINT`, a ticket prints only offline or if the old preference `posPrintTicket` is `on` (in `tpn.prefs`; no screen that sets it was found in code).
  3. "At the counter" means: the iMin printer (`TPN_PRINT.kitchen`), else the slip picture through the browser print window (`TPN_SLIP.printWindow`), else a plain 80 mm HTML ticket in a pop-up or a hidden frame if pop-ups are blocked.
- **86 panel** (`open86Panel`): lists every dish with Available / Sold out; tapping calls `TPN.setItemAvailable`. Customers stop seeing it immediately.
- **Customer screen**: every ticket change is sent to `TPN_CDS.order(...)`; after sending a take-out/delivery order the lines are remembered (`TPN_CDS.remember`) so the pay screen still lists them.

**Globals**: `posStartFor(opts)` (the floor's "+ Order" on a table opens the counter as dine-in for that table and guest), `posOpenShift`, `posCashMove`, `posXRead`, `posCloseShift`, `posCloseShiftSave`, `posCat`, `posSearch`, `posPick`, `posPickSave`, `posQty`, `posClear`, `posType`, `posSet`, `posRedraw`, `posSend`, `printKitchenAtCounter`, `open86Panel`, `toggle86`.

**localStorage**: `tpn.pos.ticket` (the unsent ticket lines).

#### 2.2 `payments.js` — payment panel and Payments tab

**Purpose.** The payment panel on every order and the portal's Payments tab. Header comment: "Nothing on this screen writes an order's payment status. It records money; the database decides whether the bill is paid."

**Permissions used**: `payments.take` (cash and hand-taken methods), `payments.confirm` (bank transfer received), `payments.refund`, `orders.service_charge`, `finance.view` (the tab).

**Payment panel** (`openPaymentPanel(orderId)`):

- Loads `TPN.orderPayments` (with `tpnRetry`) and shows subtotal, discounts, service charge, a delivery fee line (worked out as total − (subtotal − discount + service charge)), total, amount due and every payment with status (Received, Waiting, Failed, Cancelled, Expired).
- Opens a realtime channel `pay-<orderId>` on `payments` for this order, so the panel refreshes itself when HitPay's webhook settles it.
- **Cash** (`payCash`): "This payment covers", tip, cash received with quick amounts (exact, next ₱100, ₱500, ₱1000), change shown big. Save calls `TPN.recordCash` with the open drawer shift; then pops the iMin drawer (`TPN_PRINT.openDrawer('cash payment')`) and asks for a receipt (`TPN_PRINT.receipt`, which only prints if auto-print is on). On a network error (and only on the floor screen, where `TPN_OFFLINE` exists) the cash is queued in the outbox, the drawer opens, and the guest is told change.
- **GCash / Maya / QR Ph / Card / Bank** (`payManual`): staff check the customer's app or the card terminal, then type the reference or approval code (at least 3 characters). Saved with `TPN.recordManualPayment` as received. These buttons are disabled offline ("the reference has to be checked and recorded on the server"). A network error here is **not** queued; staff are told to check the bill before recording again.
- **Online link** (`payOnline`): only when the site setting `payments.online_enabled` is true/yes and the device is online. Shows a QR of the HitPay checkout link plus "Open payment page" and "Copy link". Because `tpnSite` is not loaded on the floor screen, this button can only appear in the portal (`onlineOn()` reads `window.tpnSite`).
- **Refund** (`payRefund`), **Confirm bank transfer** (`payConfirmBank`), **Service charge** (`payServiceCharge`, chips 0/5/10 %).
- **Booklet invoice**: once paid, `TPN_INVOICES.orderBox` is drawn inside the panel (online only).
- **Customer screen**: after staff choose a method, the guest screen shows the amount, method, cash and change; once paid it shows "Salamat po" with the change.

**Printing a bill** (`printReceipt(orderId)`): the slip picture through the print window (`TPN_SLIP`); fallback a plain 80 mm HTML bill with an optional stamp-card QR. `imin.js` replaces this function so that on the iMin it prints directly.

**Payments tab** (portal): a day picker (Manila day), pending bank transfers at the top with Confirm buttons, filters (All, Cash, Online, Bank, Refunds) with totals, a table, and Excel/CSV export.

**Defined but no caller found**: `payBank()` / `payBankSave()` (records a bank transfer as *waiting* via `TPN.recordBankTransfer`). The Bank button on the panel calls `payManual('bank')` instead, which records the transfer as received.

**Storage**: none of its own.

#### 2.3 `offline.js` — the offline counter

Loaded by `tpn-dine-in-floor.html` only. It keeps the Counter taking orders when the internet drops. Exposes `window.TPN_OFFLINE`.

**Part 1 — service worker.** Registers `tpn-counter-sw.js` with scope `./tpn-dine-in-floor` (so it also covers `tpn-dine-in-floor-customer`, which starts with the same path). Nothing else on the site is affected. What the service worker does:

| What | How |
|---|---|
| The floor page and the customer page | Network first with a 4-second limit, else the last saved copy (each page saved under its own key). |
| Same-site files with `?v=` or under `/vendor/` | Cache first (a versioned file never changes). |
| Other same-site files | Network first, 4 seconds. |
| Google Fonts CSS and font files | Cache first. |
| Supabase reads of `menu_categories`, `menu_items`, `modifier_groups`, `modifiers`, `menu_item_modifier_groups`, `restaurant_tables`, `branches`, `delivery_zones` | Network first with 5 seconds, else the last answer. Comment: nothing with a customer's name, phone or money is cached. |
| Anything that is not a GET (orders, RPCs, sign-in) | Not touched. |

At install it saves the floor page, the customer page, every script/stylesheet those pages list, `counter.webmanifest`, `icons/tpn-icon.svg`, `assets/site/icon.png`, `logo.webp`, `hero.webp`, `mandala-a.webp` and the font files. Cache names are `tpn-counter-20261021b-shell` and `tpn-counter-20261021b-data`; older `tpn-counter-*` caches are deleted on activate. `vercel.json` serves the service worker with `Cache-Control: no-cache` (only on Vercel). The manifest `counter.webmanifest` describes an installable full-screen landscape app "TPN Counter" starting at `./tpn-dine-in-floor`.

**Part 2 — the outbox (IndexedDB).**

- Database `tpn-counter`, version 1, two stores: `outbox` (key `id`) and `kv` (holds `seq`, the device's running number).
- **Detecting "offline".** `navigator.onLine` only knows about Wi-Fi, so it also asks Supabase directly: `GET <SUPABASE_URL>/auth/v1/health` with a 4-second limit. The answer is reused for 10 seconds. It re-checks every 15 seconds while offline or while anything is waiting. The body gets the class `tpn-offline` while offline.
- **`isNetError(e)`** decides whether a failure might not have reached the server (failed to fetch, timeout, 502/503/504, too many requests, etc.). Only those are queued.
- **`queueOrder({clientKey, order, lines, type, estTotal})`** saves: `id` = the order's idempotency key, `kind: 'order'`, `seq`, `localNo` like `OFF-007`, time, who rang it up, the full order request, the lines (name, qty, size, add-on names, note, display price), the device's estimated total, `state: 'waiting'`, `stage: 'order'`.
- **`queueCash({orderId, orderNumber, tendered, amount, tip})`** saves cash for an order that already exists on the server (used when the cash save's answer was lost).
- **Sync** (`TPN_OFFLINE.sync()`, runs by itself when the connection returns and on page open):
  1. It never sends without a staff session. Comment: "submit_order is also the customers' door, and an order sent signed-out would go in as a guest's." If the session is missing, the chip says "Sign in again to sync".
  2. Oldest first. The order is sent with `TPN.createOrder` using the **same idempotency key** (20-second limit). If the first try had actually reached the server, the server returns the first order instead of making a second.
  3. Then cash: it first reads the order's payments and looks for a cash payment whose note contains the tag `offline OFF-007 <first 8 characters of the id>`. If found, it skips (already recorded). Otherwise `TPN.recordCash` with that tag as the note. For a new order the amount is "whatever the server says it costs". If the server's total is higher than the cash taken, the entry fails with a message to collect the difference. If the bill is already paid, it notes that and does not record twice.
  4. A network error stops the run and keeps the entry waiting; any other error marks it `failed`.
  5. Synced entries are kept for one day so staff can match `OFF-007` to the real order number.
- **Chip and panel.** A chip in the top bar: "📴 Offline: orders are kept on this device", "⟳ Syncing N orders…", "🔑 Sign in again to sync …", "⚠ N failed to sync". Tapping opens "Offline orders": each entry with its state, Try again, Payment, Remove (asks first; "Only do this after it has been sorted out by hand"), Take cash.
- **Offline payment** (`openPayment(id)`): cash only, against the device's estimated total, with change; GCash/Maya/QR Ph/card/bank buttons shown disabled with the reason. Cash must be at least the estimated total. The drawer pops and the customer screen thanks the guest (the customer screen is on the same device, so it works offline).

**Part 3 — remembered sign-in.**

- `TPN.loadProfile` is replaced: online it loads normally (8-second limit) and saves `{uid, user, at}` in `localStorage` `tpn.offline.me`; offline it uses that saved profile if it belongs to the Supabase login still stored on the device (`sb-…-auth-token`, never `sb-tpn-anon`).
- `TPN.loadPermissions` is replaced: it saves the permission list into the same `tpn.offline.me` entry, and uses it if permissions cannot be loaded.
- `canRunOffline()` is asked by the floor's sign-in gate when `getSession()` came back empty: true only if a login is stored, a remembered profile matches it, and the server really is unreachable. Comment: this "only decides what the screen shows; the database checks the real session when the outbox syncs".
- `lastCashSession(id)` keeps the open drawer shift in `localStorage` `tpn.offline.cashSession`.

**Works offline**: cash orders (take-out, delivery, dine-in), kitchen tickets on the counter printer, the customer screen, cash with change. **Needs the server** (header comment): GCash/Maya/QR Ph/card/bank, opening or closing a shift, Close table, voids, the 86 list.

**Storage**: `localStorage` `tpn.offline.me`, `tpn.offline.cashSession`; IndexedDB `tpn-counter`; Cache Storage `tpn-counter-<VERSION>-shell` and `-data`.

#### 2.4 `invoices.js` — BIR booklet invoices

**Purpose.** TPN OS has no BIR Permit to Use, so official invoices are hand-written from the BIR-registered booklet. This module tells staff when one is needed and records its number.

- Reads `site_settings` key `bir.vat_registered` (yes/true/y/oo = VAT-registered) and caches it; a failed read is not cached.
- `THRESHOLD = 500` (comment: mirrors `private.bir_threshold()` in the database).
- **`orderBox(orderId, el, payments)`** — in the payment panel, once paid: if the order already has an `invoice_no`, shows it (with "change" for `payments.take`). Otherwise says either "Write a booklet invoice for this sale" (VAT-registered, or total over ₱500) or "Booklet invoice only if the customer asks" (₱500 or less, goes on the end-of-day invoice), with a field to save the number [`record_order_invoice`].
- **`dayBox(date, el)`** — on the portal's Daily close: paid sales still missing their own invoice (links open their payment panel), the total of small sales, day invoices already written, and a form to record the end-of-day invoice [`invoice_day_summary`, `record_day_invoice`]. If the check fails it says so instead of looking empty.
- The rule itself lives in the database; the screen shows what `invoice_day_summary` decides.

**Globals**: `TPN_INVOICES = { orderBox, dayBox }`, `invSave`, `invEdit`, `invDaySave`; adds three `TPN.*` functions (1.5). **Storage**: none.

#### 2.5 `stamps.js` — Rewards (stamp cards)

**Purpose.** The portal's Rewards tab. Stamps are never typed in: paid orders add them and refunds remove them (database, sql/34). This screen gives the reward and edits the settings.

- **Give a reward** (needs `rewards.redeem`): "📷 Scan their QR" uses the camera and the browser's `BarcodeDetector`, looking for a code shaped `TPNR:<card uuid>:<6 digits>` (stops after 60 seconds). Or "No camera? Type it": mobile number → [`stamp_card_lookup`] → [`redeem_stamp_reward`] with the 6-digit code. Shows "Give: <reward>" and stamps left.
- **Check a customer's stamps**: by mobile number; shows stamps, needed, number of phones, history, export, and (with `rewards.manage`) "sign out all phones" [`revoke_stamp_devices`].
- **Settings** (edit needs `rewards.manage`): `rewards.enabled`, `rewards.min_order`, `rewards.stamps_needed` (at least 1), `rewards.reward_text`, `rewards.card_days` — saved with an upsert into `site_settings`.
- Customers claim a card from the QR on a paid counter receipt: link `tpn-rewards?claim=<order number>&t=<tracking token>` (built in `payments.js`, `imin.js`, `slips.js` only when rewards are on, the order has a phone and a token, and it is paid).

**Globals**: `rwSave`, `rwRedeemTyped`, `rwScan`, `rwLookup`, `rwRevoke`, `rwExport`. **Storage**: none (the customer's card page `tpn-rewards.html` keeps `tpn.card.v1` and `tpn.card.cache.v1`; section 6).

#### 2.6 `customer-display.js` — the rear customer screen

**Purpose.** The counter publishes what the guest should see; `tpn-dine-in-floor-customer.html` draws it. Everything stays on the device, so it works with no internet.

**The state object** (always `v: 1` and a timestamp `ts`):

```
{ mode: 'idle' | 'order' | 'pay' | 'thanks',
  lines: [{ name, size, mods, qty, amount }], fee, total, type,
  number, orderId, due, method, tendered, change }
```

Header rule: never a customer's name, phone or address — the screen faces the queue. Kitchen notes are also left out (`lines()` drops them).

**Counter side (`TPN_CDS`)**

- `idle()`, `order(o)` (switches to idle if there are no lines), `pay(p)` (keeps the last order's lines and number while cash is typed), `remember(orderId, o)`, `thanks(t)`, `lines(ticket)`.
- Each state is sent every way that might reach the other page, skipping exact repeats:
  1. `localStorage` `tpn.cds` (the last state, for a page that opens late).
  2. `BroadcastChannel 'tpn-cds'` (two tabs or windows of the same browser).
  3. The Presentation API connection (Chrome on a device with a second screen).
  4. `window.TPNCounter.toCustomer(msg)` if such a native bridge exists (not provided by the current app; see section 4.6).
  5. `POST http://127.0.0.1:8091/state` (the TPN Counter app's loopback server), only on Android (or when `tpn.cds.force` is `on`), and only after `GET /ping` answered `ok`. It re-checks `/ping` every 20 seconds while not connected and re-sends the last state when it connects.
- **Chrome route** (`present()`): needs a tap; opens `tpn-dine-in-floor-customer` on the second screen with `PresentationRequest`; the presentation id is kept in `tpn.cds.pid` so a reload of the counter reconnects.
- **Top-bar chip** "Customer screen" / "Customer screen: on" appears on Android (or when forced) if one of the routes is possible. If the app runs the screen, tapping it says so.

**Customer side**: `listen(onState)` reads `BroadcastChannel`, `storage` events, Presentation connections, the last `tpn.cds`, and defines `window.tpnCdsReceive(raw)` which the Android app calls. The customer page (`tpn-dine-in-floor-customer.html`) ignores any state older than 2 hours (counter switched off mid-order), shows at most 7 lines (older ones fold into "plus N more"), returns from "thanks" to idle after 15 seconds, and plays a GSAP colour-blob transition and an idle reel. It runs in a "lite" mode (30 fps, no blur) on Chromium below 100, on devices with 4 GB or less, or when `localStorage` `tpn.cds.lite` is `on` (`off` forces it off).

**Storage**: `tpn.cds`, `tpn.cds.force`, `tpn.cds.pid`, `tpn.cds.lite`.

#### 2.7 `signin.js` — station sign-in = clock-in

Loaded by the floor screen and the kitchen station right after the empty `<div id="tpn-auth-gate">`. It draws the sign-in form (styles in `tpn-signin.css`). Exposes `TPN_SIGNIN = { show, switchUser, whoLabel }`.

- **Each person signs in with their own account every time.** Nothing about previous users is kept or suggested; it even deletes old "recent people" lists (`tpn.station.recent`, `tpn.counter.recent`). The email field is cleared each time.
- **Signing in is the time-in.** After `TPN.login`, it calls `TPN.clockIn('Signed in at the counter')` or `'… at the kitchen'` (station from the page path), except for the two wall-screen accounts. No photo, so it lands in Clock-in review. If they were already clocked in, it says so; if clock-in fails, it says "Signed in, but the clock-in didn't save … Tell your manager." The message survives the page reload through `sessionStorage` `tpn.station.flash`.
- **Switch user is the time-out.** `switchUser({drawer: true})` (floor) first checks for the user's open drawer shift and warns "Close it first (Counter → Close shift) so your cash is counted". Then `TPN.clockOut()` (if it fails, asks whether to sign out anyway), `TPN.logout()`, removes `tpn.offline.me`, reloads.
- Offline, the form says "No internet. Signing in needs a connection."
- `whoLabel(profile)` → "Maria · Dining" for the top bar.

The page's own gate (`tpnAuthGate` in each page) decides who may enter: the floor needs `floor.view` or manager+, or the `dine_in_display` account (reduced "display mode"); the kitchen needs `kitchen_station.view` or kitchen+, or the `kitchen_display` account. Each display account is redirected away from the other's screen. The kitchen gate retries with backoff (5 s doubling to 60 s) when the server cannot be reached, because wall tablets often start before the router.

#### 2.8 `imin.js` — the iMin counter printer and cash drawer (`TPN_PRINT`)

**How it reaches the printer.** On the iMin, iMin's **iMinprinterplugin** app (from the iMin App Store) runs a small service on the device at `127.0.0.1:8081`. iMin's MIT-licensed SDK `vendor/imin-printer-1.4.0.min.js` talks to it: commands over a WebSocket `ws://127.0.0.1:8081/websocket`, and picture uploads by HTTP `POST http://127.0.0.1:8081/upload` (checked in the vendor file). The page's security policy allows exactly these (section 7.1).

**When it tries.** Only if the user agent contains `Android`, or `localStorage` `tpn.imin.force` is `on`. On laptops and phones nothing changes: printing uses the browser print window and the drawer is opened by hand.

**Connecting** (`connect()`): creates `new IminPrinter('127.0.0.1')`. The SDK's endless 4-second reconnect is switched off until the printer has answered once (no wasted work on a staff phone). Then it asks the printer status on the saved connection type (`USB` by default; the D4's printer is USB, other iMin models SPI), then the other, each with a 2.5-second limit. Status codes: `0` ready, `3` cover open, `7` or `8` paper problem, anything else error; a failed connect is "no plugin". The working type is saved in `tpn.imin.type`.

**Functions**

| Function | What it does |
|---|---|
| `TPN_PRINT.ready` | True once the printer answered "ready". |
| `receipt(orderId, {force})` | Prints an order's receipt. Without `force`, only if auto-print is on. |
| `slip(ids, {bill, method})` | One slip for one order or a whole table (each round is its own order). `bill: true` = what is still owed, before paying. |
| `bill(ids, method)` | A table's bill (used when a guest asks for the bill from the QR menu, and by "bill ready" on the floor). |
| `tableReceipt(ids)` | A table's receipt after paying (only if auto-print is on). |
| `kitchen(number, lines, type, where)` | A kitchen ticket. |
| `openDrawer(reason)` | Pops the cash drawer and writes an audit row `cash.drawer_open` with the reason. |
| `noSale()` | "Open drawer" from the menu: managers only (`printer.manage`). |
| `testKitchen()`, `testReceipt()` | Sample slips marked TEST (`printer.manage`). |
| `reconnect()`, `toggleAuto()` | Reconnect (everyone); auto-print on/off (`printer.manage`, saved in `tpn.imin.auto`, default on). |

**Picture printing with text fallback.** Every slip is first drawn as a picture by `TPN_SLIP` (2.9), turned into a PNG and sent with `printSingleBitmap` (15-second limit), then the paper is fed (100) and partially cut. If the picture fails, the plain-text slip is printed instead (80 mm, about 32 characters per line at size 24, two-column rows) and the error is remembered; managers see "Last slip printed as plain text (time): reason" in the printer menu. The text receipt includes a stamp-card QR when the rules allow.

**Job queue.** All jobs go through one promise chain, so a receipt and a ticket never interleave on paper. Errors in a job are logged and the queue continues.

**A dropped printer link never breaks a sale.** After connecting, every function first checks that the WebSocket is open (`readyState === 1`); if not, it returns `false` without throwing, so the caller falls back (a kitchen ticket goes to the print window).

**Hooks.** It replaces `window.printReceipt` so "Print bill" prints directly on the iMin (toast "Printed.") and only falls back to the old print window if that fails.

**Status chip and menu.** A chip in the floor top bar: "🖨 Printer ready", "No printer service", "Printer offline", "Check paper", "Cover open". Tapping opens "Printers": the counter printer part (status, Reconnect for everyone; test prints, Open drawer, Auto-print toggle for `printer.manage` only) and, for managers, the kitchen printer settings from `kprint.js`.

**Who can do what** (`printer.manage`, from sql/45 per the comment): managers and up get test prints, no-sale drawer, auto-print and kitchen printer settings. Cash payments open the drawer for everyone through `openDrawer`.

**Storage**: `tpn.imin.type`, `tpn.imin.auto`, `tpn.imin.force`.

#### 2.9 `slips.js` — slip pictures (`TPN_SLIP`)

**Purpose.** Draws the kitchen ticket and the customer receipt as one black-and-white picture each, in the v3 look (Fraunces and Plus Jakarta Sans, rounded black panels). 80 mm thermal paper is 576 dots wide, so the canvas is 576 px wide and prints dot for dot.

| Function | What it does |
|---|---|
| `ready()` | Loads the two Google Fonts and the logo (max 4 seconds). Offline, Georgia and the system sans stand in. |
| `kitchen(t)` → canvas | `{ number, where, type, at, lines, note }`. Big black panel with the table or guest name, type and time; each dish with its quantity in a left column, size and add-ons below, kitchen notes in an outlined box; the whole-order note at the bottom. |
| `receipt(r)` → canvas | Brand, address, phone, order number(s), date and time, delivery address, items, subtotal, discounts, service charge, delivery fee, a black "Total" (receipt) or "Amount due" (bill) panel, payments with change, balance, "Paying by …" on a bill, an optional stamp-card QR (at least 4 dots per module so a phone can read it), then "Salamat po!" and "This is not an official receipt." with the logo. |
| `fromOrders(list, {bill, method})` | Builds receipt data for one order or a whole table from `[{o: order, pay: orderPayments}]`: sums subtotal, discounts, service, delivery, total and balance across orders; leaves out voided items; lists only completed payments; adds the stamp QR only on a paid receipt with phone and token and rewards on. |
| `loadOrders(ids)` | Fetches each order and its payments. |
| `site()` | Reads `rewards.enabled`, `contact.address`, `contact.phone` from `tpnSite` or directly from `site_settings` (cached 5 minutes). |
| `printWindow(canvas, title)` | Any device without the iMin: the picture in an 80 mm print window (or a hidden frame if pop-ups are blocked). |
| `preview(kind)` | Opens a sample in a window. |
| `sample.kitchen()`, `sample.receipt()` | Test data (Table 5, Tapsilog, Sinigang…, number `TEST`). |

The logo (`assets/site/logo.webp`) is turned into black dots with Floyd–Steinberg dithering. **Storage**: none.

#### 2.10 `kprint.js` — kitchen network printer (`TPN_KPRINT`)

**What it is for.** A network thermal printer in the kitchen that speaks ESC/POS on TCP port 9100. A web page cannot open a raw printer socket, so the TPN Counter app (version 1.4 or later) relays the bytes: the page sends `POST http://127.0.0.1:8091/print?host=<printer IP>&port=<port>` and the app writes them to the printer (section 4.4).

**ESC/POS raster.** `escpos(canvas)`: takes the same `TPN_SLIP` picture; for 58 mm paper scales it to 384 dots wide (80 mm = 576); converts each pixel to black or white (luminance below 128 = black); sends `ESC @` (initialise), then the picture in bands of up to 128 rows with `GS v 0`, then `ESC d 4` (feed 4 lines) and `GS V B 0` (partial cut).

**Settings (per device, `localStorage`)**: `tpn.kprint.host` (printer IP), `tpn.kprint.port` (9100–9109, default 9100), `tpn.kprint.paper` (`80` or `58`), `tpn.kprint.mode`.

- The address must be a private IPv4 address on the restaurant's network: `10.x.x.x`, `172.16–31.x.x` or `192.168.x.x` (`isLan`, same rule as the app).
- Only managers (`printer.manage`) can save the settings or run tests.

**"Kitchen tickets" setting (`mode`)**

| Value | Shown as | Counter orders | Guests' QR/website orders |
|---|---|---|---|
| `off` | Kitchen screen only | Not printed (online). Offline: printed at the counter. | Not printed. |
| `kitchen` | Kitchen printer (counter printer if it fails) | Kitchen printer; on failure a toast "Kitchen printer didn't print … Printed at the counter." and it prints at the counter. | Printed by the floor screen (watcher below). |
| `counter` | Counter printer | Counter printer. | Not printed. |

If `mode` was never set, it reads the old preference `posPrintTicket` in `tpn.prefs`: `on` means `counter`, otherwise `off`.

**`route(t, always, atCounter)`** is what `pos.js` calls: returns true when it handled the ticket (or nothing should print), false to print at the counter.

**Guest-order watcher.** Counter orders print when sent. Orders from the QR menu and website only reached the kitchen screen, so in `kitchen` mode the **floor screen** prints them:

- Immediately, from the floor's realtime feed: on each new order the floor page calls `TPN_KPRINT.onOrder(order.id)`.
- And every 60 seconds (only on `tpn-dine-in-floor`, only while the page is visible) it checks `TPN.listActiveOrders` for anything missed.
- An order is printed if: its `source` is not `pos`, status is `pending` or `confirmed`, it was placed less than 15 minutes ago, and its id is not in the device's printed list `tpn.kprint.done` (last 300 ids).
- When kitchen mode is first switched on (or the list is missing), every currently open order is marked as already printed (`seed()`), so the backlog does not print.
- **One-device rule** (comment): "Only one device should be set to the kitchen printer, or guests' orders print twice." The printed list is per device.

**Bridge check**: `ping()` asks `GET http://127.0.0.1:8091/ping` (1.5-second limit) and sets `bridge = true` if the answer has `print: true`. Runs on Android at load and when a manager opens the printer menu. Without it, the menu says "Update the TPN Counter app to print to the kitchen printer."

**Error messages** a manager can see: "Set the kitchen printer address first.", "Update the TPN Counter app …", "The TPN Counter app did not answer.", "Kitchen printer: <app's error>." (app errors: "not a printer on this network", "bad port", "incomplete", "printer did not answer", "could not reach the printer").

#### 2.11 `photos.js` — dish photos (`TPN_PHOTO`)

One list, by dish name (lower-case, trimmed), shared by the website, QR menu and Counter. `TPN_PHOTO(name)` returns `assets/site/dishes/<file>.webp?v=20261017f` or `''`. Twenty dishes are listed: buttered shrimp, adobong pusit with gata, pares, beef caldereta, kare-kareng lechon kawali, ginataang sitaw at kalabasa, pork sisig, teriyaki wings, laing, cornedbeef silog, sisig silog, liemposilog, tapsilog, tocilog, bacon silog, chicksilog, calamares, beef bistek, pancit bihon, ginataang hipon. A dish not on the list keeps its emoji (Counter) or line icon (website). `PHOTO_V` must be bumped when a photo is replaced under the same name.

#### 2.12 `guide.js` — help panel and first-day tour (`TPN_GUIDE`)

- A "?" button on every portal page, the floor screen and the kitchen screen. It opens "Help & guide": a searchable list of tasks grouped like the sidebar, in English and Tagalog; "Show me" opens the right page and lights up the button (found by its `onclick`, not its label, so it works in both languages). Topics for pages the account cannot open are hidden.
- A tour runs once per person per device after the first sign-in (`localStorage` `tpn.guide.seen.<admin|staff>.<user id>` in the portal, `tpn.guide.seen.floor` / `tpn.guide.seen.kitchen` on the stations) and can be replayed.
- Exposes `TPN_GUIDE = { open, tour, topics, showMe, text }`. Wraps the portal's `renderRouteInto`, `renderStaffRouteInto`, `enterPortal`, `exitStaffPortal`, `setLang` and `TPN_I18N.toggle`.

#### 2.13 `search.js` — search everything (`TPN_SEARCH`)

Portal only. One box for pages, help topics, and records the portal has already loaded (orders, staff, inquiries, dishes). It never fetches anything new, so it only finds what the account can already see. Open with the search field, the 🔍 on phones, Ctrl+K / ⌘K, or `/` (except on the Counter, where `/` is the menu search). Scoring: name starts with > word starts with > contains > all words in synonyms > letters in order. Synonyms help ("sahod" finds Payroll, "86" finds the kitchen queue). The last 6 picks are kept in `localStorage` `tpn.search.recent`. Exposes `TPN_SEARCH = { open, close }`.

#### 2.14 `clockin.js` — verified clock-in and Clock-in review

**Staff side** (`openClockinCamera()`):

- First time on a device: a privacy notice (one full-body photo, only managers see it, deleted after 60 days, Data Privacy Act 2012). Acknowledgement kept in `localStorage` `tpn.clockin.privacyAck.v1`.
- Shows whether the device is on the restaurant network [`my_network_status`].
- Live camera with a body outline; switch front/back; takes the photo, mirrors the selfie camera, burns in the device time and name, scales to at most 960 px and steps JPEG quality down until about 200 KB.
- `TPN.clockIn` (server records time, network) → upload to `attendance-photos` at the path the server returned → [`attach_clockin_photo`], up to 3 tries. "Camera not working" clocks in without a photo, flagged for review.

**Manager side** — tab "Clock-in review" (`attendance.verify`): queue of the last 14 days [`clockin_review_queue`], each with photo (signed URL valid 5 minutes), network, reasons (not on restaurant Wi-Fi, network unknown, no photo, photo did not upload), a uniform checklist (site setting `hr.uniform_checklist`, default "Uniform shirt, Apron, Cap or hairnet, Closed shoes"), Approve / Approve + trust IP / Flag [`review_clockin`]. "Trust this network" [`trust_current_network`] and a list of trusted networks (`trusted_networks`). A manager cannot review their own clock-in (`own_clockin` error). Export.

**Photo retention runs from the browser**: each time a manager opens the queue, `purgeOld()` asks [`clockin_photos_expired`] (up to 200), deletes those files from storage, then [`mark_clockin_photos_purged`]. If nobody opens the queue, nothing is deleted by this code.

#### 2.15 `delivery.js` — Deliveries board

Tab "Deliveries" (`delivery.dispatch`; areas need `delivery.manage`). Active and "Done today" tabs; cards sorted failed → waiting → assigned → on the way → delivered. Each card: customer, tap-to-call, address with a Google Maps link, area, fee, items, kitchen status, paid or "Collect ₱…". Actions: Assign rider (our rider from the staff list, or Lalamove/Grab/other with name, phone, `https://` tracking link and courier cost), On the way, Delivered (asks to take payment first if unpaid), Couldn't deliver (reason), Change fee (reason), Take payment. "Areas & fees": add/edit/delete zones and a starter set (Las Piñas ₱50; Parañaque/Bacoor ₱100, min ₱500; Muntinlupa/Imus ₱150, min ₱800). Live: realtime channel `deliveries-board` on `deliveries` and on `orders` where `order_type=delivery`, plus a 45-second refresh while visible. The server adds the fee to the bill; nobody types it on the order.

#### 2.16 `modifiers.js` — Add-ons & choices

Tab (`menu.edit`): groups ("Extras", "Egg style") with minimum and maximum picks, choices with a price change (`price_delta`), sold-out flag, and which dishes each group applies to (`menu_item_modifier_groups`). Excel/CSV export and import (groups matched by name; new choices added, existing names updated). Comment: "Prices are added by the server, so the website, QR menu and counter always agree."

#### 2.17 `website.js` — Website tab

Tab (`site.edit`): contact and settings keys (`contact.phone`, `contact.email`, `contact.address`, `contact.landmark`, `contact.map_url`, `contact.parking`, `hours.text`, `contact.facebook`, `contact.instagram`, `payments.online_enabled`, `legal.company`, `legal.sec_no`, `legal.tin`, `bir.vat_registered`), FAQs, testimonials and event packages (tables `site_settings`, `faqs`, `testimonials`, `event_packages`), with import.

#### 2.18 `excel-io.js` — Export/Import on portal lists

Adds an "⬇ Export" menu (and "⬆ Import" where staff keep a list by hand) to portal page headers, using the same `TPN.*` reads the page uses, so permissions are the page's. Exporters by page: `inquiries`, `orders` (and `history`, same exporter), `menu-manager`, `staff-board`, `accounts`, `schedules`, `attendance-admin`, `tasks`, `inventory` (plus Suppliers, Stock movements), `finance` (expenses), `payroll`, `guests`, `audit` (one day). Imports: menu, inventory, suppliers, expenses, pay rates (pay rates need `payroll.edit`; matched by staff name; two staff with one name are refused). Imports always preview, never delete, and ask before updating. Exposes `tpnExcelIO = { exporters }`.

#### 2.19 How the modules talk to each other

All through globals, each checked before use:

```
pos.js ──order──▶ TPN.createOrder ──fails offline──▶ TPN_OFFLINE.queueOrder
   │ ticket ──▶ TPN_KPRINT.route ──kitchen──▶ app /print ──▶ kitchen printer
   │                    └──counter/fallback──▶ printKitchenAtCounter
   │                                            ├─▶ TPN_PRINT.kitchen (iMin)
   │                                            ├─▶ TPN_SLIP.printWindow
   │                                            └─▶ plain HTML print
   │ lines ──▶ TPN_CDS.order / remember
   └─ take-out/delivery ──▶ openPaymentPanel (payments.js)
payments.js ──▶ TPN_CDS.pay / thanks; TPN_PRINT.openDrawer / receipt;
                TPN_INVOICES.orderBox; TPN_OFFLINE.queueCash on network errors
imin.js ──▶ TPN_SLIP pictures; TPN_KPRINT.section() in its menu; replaces printReceipt
kprint.js ──▶ TPN_SLIP pictures; printKitchenAtCounter on failure
floor page ──▶ TPN_KPRINT.onOrder on each new order; TPN_PRINT.bill on a QR bill request;
               TPN_PRINT.tableReceipt / openDrawer on Close table; posStartFor on "+ Order"
```

---

### 3. Realtime (live updates)

#### 3.1 The building blocks (`tpn-supabase.js`)

- **`TPN.liveChannel(name, configure)`** creates a Supabase realtime channel and watches its status. On `CHANNEL_ERROR`, `TIMED_OUT` or `CLOSED` it rebuilds the channel after 2 s, 4 s, 8 s … up to 30 s. It also rebuilds when the tab becomes visible again or the browser comes back online (`registerResub`). Each event calls `touch()`, which records the time of the last event.
- **`TPN.onLiveStatus(fn)`** reports one combined state for all live channels on the page: `down` if the browser is offline or any channel errored; `live` if all are subscribed; otherwise `connecting`. It stays `down` until every channel is back. It reports `previous`, so a page can reload what it missed when it goes from not-live to live. This replaced an old "Live" pill that only looked at Wi-Fi (comment).
- **`TPN.subscribeOrders(branchId, cb)`** listens to all events (`*`) on `orders` (optionally filtered by branch) through `liveChannel`.
- **Guests cannot use realtime.** Realtime delivers changes through the same database rules as a read, and guests (`anon`) cannot read `orders`. So guest screens poll `track_order` every 8 seconds instead (`TPN.subscribeToOrder`).

#### 3.2 What each screen listens to

| Screen | Realtime | Safety nets and timers |
|---|---|---|
| **Floor & Counter** (`tpn-dine-in-floor.html`) | `TPN.subscribeOrders(null)` (all branches): on INSERT fetches the full order, adds it to its table, chimes, toasts, and calls `TPN_KPRINT.onOrder`; on UPDATE updates status and total. `TPN.liveChannel('restaurant_tables:all')`: UPDATE on `restaurant_tables` for "call staff" and "bill please" (on a new bill request, prints the table's bill on the iMin, once per signal, tracked in `sessionStorage` `tpn.billPrinted`). `TPN.subscribeVoidRequests`: tells the user when their own void request is approved or denied. Payment panel: channel `pay-<orderId>`. | `onLiveStatus`: reloads the whole floor when it comes back live. Every 60 s while visible: full reload from the database. Every 15 s: refresh the live pill. Every 30 s while a table request is waiting: redraw and chime again. `kprint.js`: 60-second check for missed guest orders. `offline.js`: 15-second connection check while offline or waiting. `customer-display.js`: 20-second `/ping` while the back screen is not connected. |
| **Kitchen station** (`tpn-kitchen-station.html`) | `TPN.subscribeOrders(null)`: INSERT adds the order (chime, toast), UPDATE moves it between lanes (or fetches it if unknown and live), DELETE removes it. `TPN.subscribeVoidRequests`: own requests' verdicts. | `onLiveStatus`: catch-up reload when it comes back live. Every 60 s while visible: catch-up reload. Every 15 s: redraw (ages) and refresh the connection pill. Every 1 s: the clock. Boot retry 5 s → 60 s if the server cannot be reached. |
| **Portal** (`portal.html`) | `TPN.subscribeOrders(null)` (INSERT/UPDATE/DELETE into `portalState.orders`; a finished order leaves the board after 5 minutes; re-fetches if the payload looks cut). Plain channel `portal_tables` on `restaurant_tables` (toasts for call staff and bill requests). `subscribeVoidRequests` (manager badge and toasts). `subscribeMessages`. `subscribeNotifications`. Payments panel `pay-<orderId>`. Deliveries `deliveries-board`. | `registerResub`: reloads orders and re-subscribes on wake/online. Every 30 s on the Orders page and every 15 s on the kitchen board (KDS) page: redraw. Menu load retry every 15 s after a failure. Deliveries: 45-second refresh. |
| **QR table menu** (`tpn-table-menu.html`) | None (guests cannot). | Each placed order polled every 8 s via `track_order` until served/completed/cancelled; resumes for stored orders on reload. Menu retry every 20 s after a failure. |
| **Website** (`index.html`) | None. | Order lookup is on demand (`getOrderByNumber`, `trackDelivery`). Menu retry every 15 s after a failure. Featured slideshow every 4.5 s. |
| **Customer screen** | None (gets state from the counter on the same device). | Thanks → idle after 15 s. |
| **Rewards page** | None. | The redeem code refreshes when it expires (`valid_for`). |

Realtime helpers with no caller found: `subscribeInquiries`, `subscribeAttendance`, `subscribeToTasks`, `subscribeToOrderRealtime`.

---

### 4. The Android apps (`android/`)

#### 4.1 One codebase, two apps

`android/app/build.gradle` defines one flavor dimension `station` with two product flavors:

| | TPN Counter | TPN Kitchen |
|---|---|---|
| Flavor | `counter` | `kitchen` |
| `applicationId` | `ph.tyopaengnyo.counter` | `ph.tyopaengnyo.kitchen` |
| App name | TPN Counter | TPN Kitchen |
| `BuildConfig.START_PATH` | `tpn-dine-in-floor` | `tpn-kitchen-station` |
| `BuildConfig.CUSTOMER_SCREEN` | `true` | `false` |
| `BuildConfig.UA_TAG` | `TPNCounter` | `TPNKitchen` |

Shared settings: `namespace ph.tyopaengnyo.counter`, `compileSdk 36`, `minSdk 26` (Android 8.0), `targetSdk 34`, Java 17, ARM only (`arm64-v8a`, `armeabi-v7a`) to keep the bundled engine small, compressed native libraries (`useLegacyPackaging true`), `minifyEnabled false`. `BuildConfig.SITE_URL` comes from the environment variable `TPN_SITE_URL`, default `https://unorfl.github.io/tpn-os/` (a trailing `/` is added if missing).

**Versions.** `versionCode` = `TPN_VERSION_CODE` (the GitHub Actions run number; default 1). `versionName` = `1.4.<run number>`. Android Gradle Plugin `8.9.1` (`android/build.gradle`); CI uses Gradle `8.11.1` and Temurin Java 17. The single dependency is GeckoView `org.mozilla.geckoview:geckoview:153.0.20260810162159`, from Mozilla's Maven repository (`android/settings.gradle`). Comment: pinned; 154+ needs compileSdk 37, beyond AGP 8.9.

**Build.** `.github/workflows/build-apk.yml` ("Build TPN apps") runs on pushes that change `android/**` or the workflow, or by hand with a `site_url` input. It runs `gradle -p android assembleCounterRelease assembleKitchenRelease` and uploads both APKs as the artifact `tpn-apps-<run number>`.

#### 4.2 Signing key policy

- The key is never in the repository. `.gitignore` excludes `*.p12`. `android/app/build.gradle` reads the key only from environment variables: `TPN_KEYSTORE` (file path, PKCS12, alias `tpncounter`) and `TPN_KEYSTORE_PASSWORD` (used for both store and key).
- In CI, the key comes from repository secrets `TPN_KEYSTORE_B64` (base64 of the `.p12`) and `TPN_KEYSTORE_PASSWORD`. The workflow decodes it into the runner's temporary folder, builds, and deletes it in an `if: always()` step. The workflow has `permissions: contents: read`.
- Without a key, the release build is debug-signed. The workflow comment warns that each new debug build then needs the old app uninstalled first, which wipes its storage (including any offline outbox).
- Where the key is kept (from `HANDOFF.md`, not code): made Oct 21 on the Mac at `~/Downloads/tpn-os-study/keys/` (`tpn-counter.p12`, alias `tpncounter`, password in `keystore-password.txt`); "Keep an offline copy of the key". Both flavors are signed with the same key.

#### 4.3 `MainActivity` — the app window

- **Engine: GeckoView** (Firefox's engine, bundled in the APK). Class comment: the D4-504 ships Android System WebView 83 and TPN OS needs 87+, so the front screen no longer depends on the device's WebView. One `GeckoRuntime` per app process. Remote debugging (`about:debugging`) is on only while USB debugging is on.
- **Starts on its station**: `SITE + START_PATH` (`tpn-dine-in-floor` or `tpn-kitchen-station`). The station's own sign-in asks each person for their account. The portal opens in the same window from "← Portal".
- **User agent**: the default GeckoView user agent plus `" TPNCounter/1.4.N"` or `" TPNKitchen/1.4.N"`. The site uses this for lite mode and to keep the app off the public pages (1.6).
- **Screen**: keeps the screen on (`FLAG_KEEP_SCREEN_ON`), immersive full-screen (hides status and navigation bars, re-applied on focus). Back steps back inside the site; it never closes the app.
- **"Display over other apps"**: asked once on start if not granted. Counter: needed for the back screen. Kitchen: needed so it can reopen by itself after a power cut (Android 10+). "Not now" continues without it.
- **Navigation rules** (`onLoadRequest`):
  - Only the site itself loads inside the app: `https`, same host as `SITE_URL`, path starting with the site path (`isSite`).
  - A site link that asks for a new window (the portal opens Floor & Counter and the kitchen "in a new tab") loads in the same window.
  - `about:` pages are allowed.
  - Anything else (Google Maps, `tel:`, HitPay pages, other sites) is handed to Android (`ACTION_VIEW`, usually the browser) and blocked inside the app.
- **Load errors** (`onLoadError`): if a site page other than the station fails to load (no internet), the app goes to the station page instead. Comment: the counter works offline thanks to its service worker. The kitchen station has no service worker in code (the worker's scope is the floor page only), so the Kitchen app has no offline copy to fall back to.
- **Permissions**:
  - Camera (`onMediaPermissionRequest`): granted only for video, only for the site, never the microphone (for the clock-in photo). Android's camera permission is requested when the page asks.
  - Content permissions: only autoplay (audible/inaudible) and persistent storage, only for the site. Everything else denied.
  - JavaScript `alert`, `confirm`, `prompt` are shown as Android dialogs.
- **Crash recovery**: if the page's process crashes or is killed (low memory), a new session opens. Comment: the ticket and the offline outbox are in the site's storage, so nothing is lost.
- `launchMode singleTask`; handles rotation and keyboard changes itself (no restart).

#### 4.4 `CustomerScreenService` — back screen and loopback server (Counter app only)

Started by `MainActivity` (and `BootReceiver`) only when `BuildConfig.CUSTOMER_SCREEN` is true. It is a foreground service (type `specialUse`, subtype "Customer-facing display on the POS second screen") with a minimal-importance notification "Customer screen is on". `START_STICKY` (Android restarts it).

**Back screen.** Looks for a "presentation" display (the iMin's rear screen). If there is one, and "Display over other apps" is allowed, it shows `CustomerPresentation` on it as an overlay window (`TYPE_APPLICATION_OVERLAY`), so it stays up whatever is on the front screen. It reacts to displays being added or removed. The last state received is replayed to a newly shown screen.

**Loopback server: `127.0.0.1:8091`** (bound to the loopback address only, so nothing outside the device can reach it; backlog 8; one thread per connection; 5-second read timeout; request headers up to 8 KB).

The "allowed origin" is the scheme and host of `SITE_URL` (for example `https://unorfl.github.io`). A request is "ours" only if its `Origin` header matches exactly.

| Request | Rule | Answer |
|---|---|---|
| `OPTIONS` (CORS preflight) | Any | 204; CORS headers only if ours. |
| `GET /ping` | Any origin, or none | 200 `{"ok":true,"print":true,"screen":<true if the back screen is showing>}`. |
| `POST /state` | Ours; body 1 byte – 64 KB; must start with `{` | 204; the JSON is passed to the back screen. |
| `POST /print?host=…&port=…` | Ours; body 1 byte – 2 MB; `host` must be a private IPv4 (`10/8`, `172.16/12`, `192.168/16`, each part 0–255 without leading zeros); `port` 9100–9109 (default 9100) | Opens a TCP connection to the printer (4-second connect, 8-second write timeout), writes the bytes, closes. 200 `{"ok":true}` or 502 `{"ok":false,"error":"…"}` with one of: `bad port`, `not a printer on this network`, `incomplete`, `printer did not answer`, `could not reach the printer`. |
| Anything else | | 404 if ours, 403 otherwise. |

When the origin is ours, the reply carries `Access-Control-Allow-Origin: <origin>`, `Allow-Methods: GET, POST, OPTIONS`, `Allow-Headers: content-type`, `Access-Control-Allow-Private-Network: true` and `Vary: Origin`. Every reply has `Cache-Control: no-store` and `Connection: close`.

The Kitchen app does not start this service, so it has no `/print` relay and no back screen.

#### 4.5 `CustomerPresentation`

An Android `Presentation` (a window on the second display) holding a **system `WebView`** (not GeckoView) that loads `SITE + "tpn-dine-in-floor-customer"`. WebView settings (`MainActivity.configure`): JavaScript, DOM storage and database on; media may autoplay; mixed-content compatibility mode; cookies accepted. It has no buttons. Each new state is pushed with `evaluateJavascript("window.tpnCdsReceive && tpnCdsReceive(<quoted JSON>)")`, and again after the page finishes loading. The WebView is destroyed when the presentation stops.

#### 4.6 How the counter page actually reaches the back screen in the app

The front page runs in GeckoView and the back page in the system WebView: two different engines, so they do not share `localStorage` or `BroadcastChannel`, and no `window.TPNCounter` bridge is registered (no `addJavascriptInterface` or GeckoView equivalent in the Java code; `CustomerScreenService.deliver()` has no caller). So in the app the path is: `customer-display.js` → `POST http://127.0.0.1:8091/state` → `CustomerScreenService.push` → `CustomerPresentation` → `tpnCdsReceive`. The `/ping` check every 20 seconds is what turns the "Customer screen: on" chip on.

#### 4.7 `BootReceiver`

On `BOOT_COMPLETED`: Counter app starts `CustomerScreenService` (so the back screen comes up even if the app window cannot), then both apps try to open `MainActivity`. Android 10+ only allows this once "Display over other apps" is granted.

#### 4.8 Manifest, permissions, network rules

`AndroidManifest.xml` permissions: `INTERNET`, `ACCESS_NETWORK_STATE`, `CAMERA` (camera hardware not required), `RECEIVE_BOOT_COMPLETED`, `SYSTEM_ALERT_WINDOW` (display over other apps), `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_SPECIAL_USE`.

Application: `allowBackup="false"` (app data is not included in Android backups), theme `Counter` (full-screen, no action bar, white background).

`res/xml/network_security_config.xml`: plain `http`/`ws` is refused everywhere except `127.0.0.1` and `localhost` (the iMin print plugin on 8081 and the app's own 8091). This applies to the system WebView (the back screen) and the Java code; GeckoView applies its own rules.

---

### 5. Hardware

#### 5.1 The iMin D4-504 counter

What the code and docs say about the device (device facts from `HANDOFF.md`, checked Oct 21): iMin **D4-504** (model I20D01), Android 11, a 10.1-inch rear customer screen, no Google Play Store (iMin App Store only), Android System WebView 83 (cannot be updated from the device), Chrome 104.

| Part | How TPN OS uses it | Code |
|---|---|---|
| Built-in 80 mm thermal printer | Through the **iMinprinterplugin** service at `127.0.0.1:8081` (WebSocket for commands, HTTP `/upload` for pictures) via iMin's JS SDK. Receipts, table bills, kitchen tickets (when "Kitchen tickets" is `counter`, or as the fallback), test slips. Connection type USB first (D4), then SPI. | `modules/imin.js`, `vendor/imin-printer-1.4.0.min.js` |
| Cash drawer | `openCashBox()` through the same plugin. Opens on every cash payment, cash table settle and offline cash; "Open drawer" (no sale) for managers. Every opening is written to the audit log as `cash.drawer_open` with a reason. | `imin.js` `openDrawer` |
| Rear customer screen | In the app: `CustomerScreenService` + `CustomerPresentation` (system WebView). In Chrome: the Presentation API ("Customer screen" chip). | `customer-display.js`, Android service |
| Front screen | The floor screen in the TPN Counter app (GeckoView). | `MainActivity` |

Setup steps (from `GO-LIVE.md` sections 8 and 10, not code): install iMinprinterplugin from the iMin App Store and open it once; install the TPN Counter APK; allow "Display over other apps"; the printer chip should read "🖨 Printer ready".

#### 5.2 The kitchen network printer

Any ESC/POS network thermal printer reachable on the restaurant's network on port 9100 (9100–9109 allowed), 80 mm or 58 mm paper. The page never talks to it directly: it goes through the Counter app's `POST /print` relay (section 4.4), so **only the TPN Counter app (1.4+) can print to the kitchen printer**; a laptop or phone browser cannot. Settings are per device and manager-only (`kprint.js`). The model of the printer is not in the code. `HANDOFF.md` Rev 34 notes the owner's kitchen printer test worked.

#### 5.3 What happens with no internet

| Thing | Offline behaviour |
|---|---|
| Floor & Counter page | Opens from the service worker cache (must have been opened online at least once). The last menu, tables, modifiers and zones come from the cache. |
| Sign-in | A new sign-in needs the internet. The last signed-in person on that device can keep working (remembered profile and permissions). |
| Counter orders | Saved in the device outbox with `OFF-###` numbers and replayed with their idempotency key when the connection returns. |
| Kitchen tickets for those orders | Always printed at the counter (the kitchen screen cannot see them). If "Kitchen tickets" is `kitchen`, it still tries the kitchen printer first (local network, not internet), falling back to the counter. |
| Cash | Works; saved in the outbox and synced after the order; drawer pops. |
| GCash, Maya, QR Ph, card, bank, HitPay | Disabled. |
| Open/close drawer shift, Close table, voids, 86 list | Need the server. |
| iMin printer and drawer | Work (they are on the device). Slips use fallback fonts if Google Fonts are not cached. |
| Customer screen | Works (same device). |
| Kitchen station | Shows "Disconnected — reconnecting" and keeps retrying; no offline copy. Orders queued at the counter appear only after they sync. |
| QR menu, website | Need the internet. |

---

### 6. Every browser-storage key

#### 6.1 `localStorage` (kept until cleared)

| Key | Written by | Holds |
|---|---|---|
| `sb-xjlqfpnzobfqxetgkkai-auth-token` (Supabase's default name `sb-<project ref>-auth-token`) | supabase-js | The staff login session (tokens, user). Not on the QR menu. Read by `offline.js` to know who the device's login belongs to. |
| `sb-tpn-anon` | QR menu client | Configured as the QR menu's storage key, but with `persistSession: false` the session is not saved. `offline.js` explicitly ignores this name. |
| `tpn.device` | `TPN.deviceId()` | A random id for this browser (groups a table's bill by phone). |
| `tpn.trackTokens` | `TPN._saveTrackToken` | Up to 30 recent `{order number: {t: token, at: time}}` proving this device placed those orders. |
| `tpn.bcast` | `TPN.broadcast` (fallback only) | Last cross-tab message, only when `BroadcastChannel` is unavailable. |
| `tpn.lang` | i18n, website, portal, QR menu | `en` or `tl`. QR menu defaults to `tl`; other pages to `en`. |
| `tpn.draft.event-form`, `tpn.draft.tasting-form` | `tpnDraft` on the website | Unsent form fields with a timestamp (restored for 3 days). |
| `tpn.site.v1` | `tpn-site.js` | Last good copy of website settings, FAQs, testimonials, packages. |
| `tpn_cart_v1` | `index.html` (code also present in `portal.html`) | Website cart `{items, _ts}`. |
| `tpn_last_order_v1` | `index.html` checkout | The last placed order's checkout data, for 2 hours. |
| `tpn_session_<branch>_t<table>` | QR menu | Orders placed from this phone at this table (for progress and the bill). |
| `tpn.card.v1`, `tpn.card.cache.v1` | `tpn-rewards.html` | The customer's stamp card link on this phone and a cached copy of the card. |
| `tpn.prefs` | Portal Preferences | `theme`, `density`, `motion`, `sound`, `autoClearBadges`, `landing` (and possibly the old `posPrintTicket`). Read by the floor's `getPref` and `kprint.js`. |
| `tpn.badgeAck` | Portal | Which tab badges have been acknowledged. |
| `tpn.hub.<kind>.<hub key>` | Portal | Last page opened inside each hub. |
| `tpn.lastRoute.admin`, `tpn.lastRoute.staff` | Portal | Last page, to reopen after reload; cleared on sign-out. |
| `tpn.search.recent` | `search.js` | Last 6 search picks (ids). |
| `tpn.guide.seen.<admin|staff>.<user id>`, `tpn.guide.seen.floor`, `tpn.guide.seen.kitchen` | `guide.js` | Tour already shown. |
| `tpn.clockin.privacyAck.v1` | `clockin.js` | `1` once the clock-in photo notice was accepted on this device. |
| `tpn.floor.sound` | Floor page | `on`/`off` for chimes. |
| `tpn.pos.ticket` | `pos.js` | The Counter's unsent ticket lines. |
| `tpn.offline.me` | `offline.js` | `{uid, user (staff profile), perms, at}` — the last sign-in, for offline use. Removed by Switch user. |
| `tpn.offline.cashSession` | `offline.js` | The open drawer shift id. |
| `tpn.cds` | `customer-display.js` | Last customer-screen state (JSON). |
| `tpn.cds.pid` | `customer-display.js` | Chrome presentation id, to reconnect. |
| `tpn.cds.force` | Set by hand | `on` makes non-Android browsers behave as the iMin for the customer screen (testing). |
| `tpn.cds.lite` | Set by hand | `on`/`off` forces the customer screen's lite mode. |
| `tpn.imin.type` | `imin.js` | `USB` or `SPI`. |
| `tpn.imin.auto` | `imin.js` | Auto-print receipts `on`/`off` (default `on`). |
| `tpn.imin.force` | Set by hand | `on` tries the iMin printer on non-Android devices (testing). |
| `tpn.kprint.host`, `tpn.kprint.port`, `tpn.kprint.paper`, `tpn.kprint.mode` | `kprint.js` | Kitchen printer address, port, paper width, "Kitchen tickets" mode. |
| `tpn.kprint.done` | `kprint.js` | Ids of guest orders already printed on this device (last 300). |
| `tpn.station.recent`, `tpn.counter.recent` | (old builds) | Deleted on load by `signin.js`. |

#### 6.2 `sessionStorage` (this tab only, gone when the tab closes)

| Key | Written by | Holds |
|---|---|---|
| `tpn.station.flash` | `signin.js` | The "Clocked in at …" message shown after the reload. |
| `tpn.billPrinted` | Floor page | Bill-request signals already printed (last 100), so a repeated signal does not print twice. |
| `tpn_checkout_v1` | `index.html` | Checkout step and answers. |
| `tpn_table_cart_<branch>_t<table>` | QR menu | The guest's cart. |
| `tpn_bill_<branch>_t<table>` | QR menu | That the bill was requested (valid 3 hours). |
| `tpn_order_key_<branch>_t<table>` | QR menu | The idempotency key `{key, sig}` for the order being placed; removed once sent. |

#### 6.3 IndexedDB and Cache Storage

| Name | Holds |
|---|---|
| IndexedDB `tpn-counter` → store `outbox` | Offline orders and cash (section 2.3). |
| IndexedDB `tpn-counter` → store `kv`, key `seq` | The device's running `OFF-###` number. |
| Cache `tpn-counter-20261021b-shell` | Floor and customer pages, scripts, styles, images, fonts. |
| Cache `tpn-counter-20261021b-data` | Last answers for the menu, modifier, table, branch and zone reads. |

#### 6.4 Same-browser channels (not storage, but carry data between tabs)

`BroadcastChannel` `tpn-session` (sign-out everywhere), `tpn-os-sync` (`TPN.broadcast`, unused), `tpn-cds` (customer screen).

---

### 7. Security on the client

#### 7.1 Content Security Policy per page

Each page sets its policy with a `<meta http-equiv="Content-Security-Policy">` tag. All staff and public pages share `default-src 'self'`, `object-src 'none'`, `base-uri 'self'`, `style-src 'self' 'unsafe-inline' https://fonts.googleapis.com`, `font-src 'self' https://fonts.gstatic.com data:`, and `script-src 'self' 'unsafe-inline'` plus the pinned supabase-js CDN file. The differences:

| Page | Extra in `script-src` | `img-src` | `connect-src` | Other |
|---|---|---|---|---|
| `index.html` | — | `'self' data: blob:` Supabase, `api.qrserver.com`, `tile.openstreetmap.org` | `'self'`, Supabase `https` and `wss` | `media-src 'self' data: blob:`, `worker-src 'self' blob:`, `form-action 'self'` |
| `portal.html` | ExcelJS CDN file | `'self' data: blob:` Supabase, `api.qrserver.com` | Supabase https/wss, `ws://127.0.0.1:8081`, `http://127.0.0.1:8081`, `http://127.0.0.1:8091` | media, worker, `form-action 'self'` |
| `tpn-dine-in-floor.html` | — | same as portal | same as portal (iMin plugin and the app's loopback) | media, worker, `form-action 'self'` |
| `tpn-kitchen-station.html` | — | same as portal | Supabase https/wss only | media, worker, `form-action 'self'` |
| `tpn-table-menu.html` | — | `'self' data: blob:` Supabase | Supabase https/wss | media, worker, `form-action 'self'` |
| `tpn-rewards.html` | — | `'self' data: blob:` | Supabase https/wss | `form-action 'self'` |
| `tpn-dine-in-floor-customer.html` | (no CDN; `'self' 'unsafe-inline'` only) | `'self' data:` | `'self'` only | `form-action 'none'` |

Notes:

- `'unsafe-inline'` is needed because the pages use inline scripts and inline `onclick` handlers. The protection against injected script therefore rests on escaping (7.2).
- Only the portal and floor may talk to `127.0.0.1` (the printer plugin and the app). The customer screen page cannot make any outside connection.
- Other headers: every page except the customer screen sets `<meta name="referrer" content="strict-origin-when-cross-origin">`. `vercel.json` adds `X-Content-Type-Options: nosniff`, `Referrer-Policy` and `X-Frame-Options: SAMEORIGIN` when served by Vercel; GitHub Pages cannot, hence the frame-busting script (1.3).
- Supabase-js from the CDN must match its SRI hash (1.3).

#### 7.2 Escaping helpers

| Helper | Use |
|---|---|
| `TPN.esc(v)` / `E(v)` | Every database or user value placed into HTML. Escapes `& < > " '`. `null`/`undefined` become empty. |
| `JA(v)` | A value placed inside a quoted JS string inside an inline handler, e.g. `onclick="openPaymentPanel('${JA(id)}')"`. JS-escapes then HTML-escapes. |
| `TPN.escAttr(v)` | `esc` plus the backtick. |
| `esc` (local copies) | `tpn-kit.js`, `tpn-site.js`, `search.js`, `guide.js`, `offline.js`, `kprint.js` keep their own equivalent. |
| `cellSafe` (in `tpnExport`) | Prefixes `'` on spreadsheet cells starting with `= + - @` (formula injection). |
| `printWindow` titles, iMin menu error | Strip `<` and `&`. |

#### 7.3 What the client must never decide

These rules come from comments and from how the calls are written:

- **Prices.** The browser never sends a price that counts. The Counter sends dish ids, quantities, sizes, add-on ids and notes; `submit_order` prices everything (`pos.js`: "display only; the server prices the order"). `createOrder` passes a `unit_price` field from the website/QR cart, but the comment in `pos.js` and the error codes (`negative_price`, `unknown_size`, `item_has_no_price`) show the server checks prices. Delivery fees are added by the server from the zone (`delivery.js`: "The server adds the fee to the bill; nobody types it"). Add-on prices are added by the server (`modifiers.js`). Discount amounts are computed by `apply_discount`. The offline estimate is only an estimate; the server's total wins when it syncs.
- **Payment status.** Nothing in the client sets an order's `payment_status`; it is derived from `payments` rows written only by server functions (`tpn-supabase.js` and `payments.js` comments; error `payment_state_is_derived` → "Record a payment instead of changing the status"). Online payments are completed only by HitPay's signed webhook (comment).
- **Permissions.** `TPN.can()` only decides which buttons and tabs to show; Row Level Security and the database functions refuse anything not allowed. If permissions cannot be loaded, the fallback can be too generous on purpose, because the database still refuses.
- **Time and place of clock-in.** The server records the time and IP (`clock_in_verified`); the time burned into the photo is only the device's.
- **Who placed a guest order.** Guests prove ownership with the tracking token saved at checkout; `device_id` is not a secret and is never used as proof (comment on `splitTableBill`).
- **BIR invoice rule.** Decided by `invoice_day_summary` in the database; the ₱500 in `invoices.js` is a copy for display.
- **Writes are never retried automatically** (`tpnRetry` is for reads). The only automatic replay is the offline outbox, which is safe because of the idempotency key and the cash tag.

#### 7.4 Device-side protections

- The QR menu runs as a pure guest (no staff session can leak into it).
- The offline outbox never syncs without a staff session.
- The Android app loads only the site; everything else goes to the system browser. Camera only for the site; microphone never.
- The loopback server listens on `127.0.0.1` only and accepts `/state` and `/print` only from the site's exact origin; `/print` only to private-network printers on ports 9100–9109.
- Cleartext network traffic is limited to `127.0.0.1`/`localhost` (Android network config).
- `allowBackup=false`.
- The customer screen never receives names, phones, addresses or kitchen notes.
- Clock-in photos are shown through 5-minute signed links.

---

### 8. Third-party files and versions

| File | Version | Used by |
|---|---|---|
| `vendor/supabase-js-2.117.2.js` | 2.117.2 (CDN fallback pinned, SRI) | all Supabase pages |
| `vendor/exceljs-4.4.0.min.js` | 4.4.0 (CDN fallback in `tpnLoadExcel`) | portal exports/imports |
| `vendor/qrcode-generator-1.4.4.js` | 1.4.4 | payments QR, receipt QR, rewards page |
| `vendor/imin-printer-1.4.0.min.js` | 1.4.0, MIT | iMin printing |
| `vendor/gsap-3.12.5.min.js` | 3.12.5 | customer screen animation |
| GeckoView | 153.0.20260810162159 | Android apps |
| Service worker cache | `tpn-counter-20261021b` | floor offline |
| Dish photo version | `20261017f` | `photos.js` |

Script `?v=` versions at the time of writing: `config.js`, `tpn-supabase.js`, `tpn-site.js` `20261017o`; `tpn-kit.js` `20261022b`; `tpn-i18n.js` `20261022c`; `tpn-home.js` `20261022a`; `pos.js` `20261022b`; `payments.js`, `invoices.js`, `photos.js` `20261022a`; `slips.js`, `imin.js` `20261022d`; `kprint.js` `20261022c`; `offline.js`, `customer-display.js` `20261021b`; `signin.js` `20261021c`; `website.js` `20261021a`; `modifiers.js`, `clockin.js`, `stamps.js`, `excel-io.js`, `delivery.js`, `guide.js`, `search.js` `20261017o`.

---

### 9. Things that look wrong, unused or out of date

These are observations from reading the code, not tested behaviour.

1. **`window.TPNCounter` bridge does not exist in the current app.** `customer-display.js` and the `CustomerScreenService` class comment still describe it, and `CustomerScreenService.deliver()` is never called. The app works through the loopback `/state` route instead (4.6).
2. **Stale comments about shared storage.** `CustomerPresentation.java` says the back page "reads the last state from localStorage (shared with the counter's WebView)", and `GO-LIVE.md` says "Both WebViews share the site's storage". Since the front moved to GeckoView, the front and back use different engines and do not share storage.
3. **`GO-LIVE.md` section 8 is behind the code.** It tells staff to tap "Test print" and "Open drawer"; in code those buttons are "Test kitchen ticket" / "Test receipt" / "Open drawer" and appear only for `printer.manage` (managers). It also still describes the Chrome-only setup, and refers to the workflow as "Build TPN Counter APK" (the workflow is named "Build TPN apps" and builds both).
4. **Kitchen app offline fallback.** `MainActivity.onLoadError` sends failed loads to the station page, on the basis that the counter works offline. For the Kitchen app the station is `tpn-kitchen-station`, which has no service worker, so there is nothing to fall back to offline.
5. **`payBank()` / `payBankSave()` have no caller** (`payments.js`). The pending-bank-transfer list and Confirm button remain for rows created by `record_bank_transfer`, which no button now calls.
6. **The old `posPrintTicket` preference** is still read by `pos.js` and `kprint.js`, but no screen that sets it was found.
7. **Online payment link cannot appear on the floor screen**, because `payments.js` reads `window.tpnSite`, which the floor page does not load. Whether this is intended is not stated in code.
8. **Unused data-layer functions** (no caller in pages or modules): `itemsInCategory`, `subscribeToOrderRealtime`, `getTableBill`, `listTodayOrders`, `subscribeInquiries`, `subscribeAttendance`, `subscribeToTasks`, `broadcast`, `onBroadcast`, `pushNotification`. `listAuditForDay` builds a query it never runs.
9. **`tpn-rewards.html` has no CDN fallback** for supabase-js, unlike the other pages.
10. **Clock-in photo deletion depends on a manager opening Clock-in review** (`purgeOld()` runs in the browser). No scheduled deletion was found in the front-end code (the database side is covered elsewhere).
11. **`updatePayrollItem` computes `net` in the browser.** Whether the database recomputes or checks it is not visible in front-end code.
12. **`GO-LIVE.md` APK size** says about 165 MB; `HANDOFF.md` says the first build was 86 KB (before GeckoView). Not a code issue; sizes are not in code.

---

## Part 3 — Database, money rules, roles and security

This section describes the TPN OS database: every migration file, every table, every function the apps call, the roles and permissions, the hard rules that protect money, and how it is tested. It is written from the files in the repo (`sql/01` to `sql/46`, `tests/db/`, and the notes in `HANDOFF.md`). Where something exists only on the live database and not in the repo, or could not be found in code, that is said plainly.

Source of truth: `/Users/jannellecaro/Downloads/tpn-os-study/tpn-os` (main branch). All paths below are relative to that folder.

---

### 3.1 How the database protects itself (read this first)

The restaurant runs on **Supabase**, which is a hosted **Postgres** database with a web API in front of it. Every screen (website, QR table menu, counter, floor, kitchen, portal) talks to the same database.

There are three kinds of caller:

| Caller | Who it is | What it can reach |
|---|---|---|
| `anon` | Anyone on the internet: a guest on the website or the QR menu. No login. | Only a short list of functions (order, track, call staff, bill, rewards card) and a few public tables (menu, site settings, FAQs, event packages, delivery zones, modifiers). It cannot read or write orders, payments or staff at all since `sql/29`. |
| `authenticated` | A signed-in staff account (people and the two wall-screen accounts). | What the row rules (RLS) and the functions allow for that person's role and permissions. |
| `service_role` | The server-side Edge Functions in `supabase/functions/` (HitPay checkout, HitPay webhook, HitPay refund, create-staff). | Everything. Only four HitPay functions are reserved to it. |

Four mechanisms do the protecting:

1. **Row Level Security (RLS)**: a rule on each table that decides which rows a caller may see or change. Every table in `public` has RLS turned on.
2. **Grants**: whether a caller may use a table or function at all. Many tables have had insert/update/delete taken away from browsers entirely, so the only way to change them is through a function.
3. **SECURITY DEFINER functions**: server functions that run with full rights but check who is calling first (role, permission, branch). Money is moved only through these.
4. **Triggers**: code that runs automatically when a row changes. Triggers recompute totals, refuse forbidden edits, write the audit log and send notifications.

Two schemas matter:

- `public`: tables and functions the API exposes.
- `private`: helper functions and secret tables the API never exposes (`private.can`, `private.settle_order`, `private.rate_hits`, `private.loyalty_secret`, and so on). Nothing in `private` can be called from a browser.

#### The four "who am I" helpers

All of the access rules lean on these. Final versions in `sql/29-security-hotfix.sql` (first versions in `sql/01-schema.sql` and `sql/19-access-control.sql`).

| Helper | Returns | Notes |
|---|---|---|
| `private.my_role()` | The caller's `staff.role` | Returns nothing if the account is not `employment_status = 'active'` (since `sql/29`). A disabled or pending account is treated as no account everywhere. |
| `private.my_branch()` | The caller's `staff.branch_id` | Same active-only rule. |
| `private.has_role(min)` | true if the caller's role sits at or above `min` in the role ladder | Compares positions in the `staff_role` enum (`sql/01`). |
| `private.can(key)` | true if the caller holds permission `key` | The permission resolver (section 3.3.4). |

---

### 3.2 Every migration file, in order

Run order is file-name order (`tests/db/run.mjs` sorts the names, so `15-` runs before `15a-` and `15b-`, and `29-` before `29a-`). Files marked **run alone** add enum values and must be pasted into the Supabase SQL editor by themselves, because Postgres refuses to use a new enum value in the same transaction that added it.

"Superseded" means a later file replaced that object with `create or replace` or `drop`; the later version is the one that runs today.

| File | What it adds or changes | Superseded parts |
|---|---|---|
| `01-schema.sql` | The foundation. Enums `staff_role` (dining → ceo), `order_type_enum`, `order_status`, `payment_method`, `payment_status`, `station_enum`, `inquiry_type`, `inquiry_status`. Tables `branches`, `staff`, `menu_categories`, `menu_items`, `restaurant_tables`, `orders`, `order_items`, `inquiries`, `audit_log`; sequence `order_number_seq`. Helpers `my_role`, `my_branch`, `has_role`. Order-number trigger, `updated_at` touch triggers, `handle_new_user` (a new login gets a `staff` row at `dining`). First RLS policies. Realtime on orders, order_items, inquiries. | Most order/order-item policies replaced by 03, 05, 15b, 18, 29, 32. `audit_read` replaced by 07. `my_role`/`my_branch` replaced by 29. |
| `02-seed.sql` | Seed data: 3 branches (`laspinas`, `bacoor`, `tgt`), 10 menu categories, sample dishes, 8 tables. | Menu replaced by 39/40/42. |
| `03-security-fixes.sql` | Pins `search_path` on functions; stops `handle_new_user` being callable through the API; audit rows must be written as yourself; staff can create orders only in their own branch; inquiries need a name and a message. | `orders_auth_create` and `order_items_auth_insert` replaced by 15b; order_items insert removed by 32. |
| `04-signals.sql` | Table "Call staff" and "Bill please": columns `call_staff_at`, `bill_requested_at`, `bill_payment_method`, `bill_total` on `restaurant_tables`; functions `signal_call_staff`, `signal_bill_request` (anyone) and `ack_call_staff`, `ack_bill_request` (staff). Realtime on tables. | Signals replaced by 11 then 29; acks replaced by 17. |
| `05-anon-orders.sql` | Lets the public website create pickup and delivery orders (not only dine-in). | Replaced by 18; the policy was dropped entirely by 29. |
| `06-menu-fields.sql` | `menu_items.emoji`, `is_featured`, `featured_tag` plus backfill. | Never reached production (found Oct 2026); re-added by 29. |
| `07-single-branch.sql` | Audit log readable by manager and up (was director). | Current. |
| `08-schedules.sql` | `schedules` table (one row per person per week, days as JSON) with RLS. | Current. |
| `09-order-fields-and-attendance.sql` | Reconstructed from production: order columns (`customer_email`, `delivery_address`, `scheduled_for`, `cancel_reason`, `discount_amount`, `service_charge` …); `attendance` table (one open shift per person); `messages` table. | Attendance self-insert/update policies dropped by 33; `messages_insert` dropped by 29; `messages_read` and `messages_update_read` replaced by 15b, the latter dropped by 36. |
| `10-notifications.sql` | `notification_priority` enum, `notifications` table, `notify_push` helper, triggers that raise notifications for new orders, ready/cancelled orders, new inquiries, new messages, attendance corrections, pending staff, table signals; `notifications_prune`. | `notif_read` replaced by 15b; `notif_update` replaced by 36. |
| `11-security-hardening.sql` | **Totals are computed by the server**: `private.recompute_order_totals` plus triggers on `order_items` and on discount/service-charge changes. Anonymous readers lose personal columns. 90-second cooldown on table signals. `void_order_item` and `unvoid_order_item` (manager+). `audit_log_archive`, `audit_daily_summary`, `audit_log_archive_old`, view `v_audit_log_all`, `audit_daily_counts`. | Recompute replaced by 17 then 38; signals by 29; unvoid by 17; archive function by 17; `audit_daily_counts` by 13. `void_order_item` is still the 11 version. |
| `12-advisor-cleanup.sql` | Supabase advisor fixes: audit view runs as the caller, trigger functions not callable through the API, acks closed to anon, maintenance functions closed. | Its comment says `audit_log_archive_old` checks manager inside; it did not until 17. |
| `13-fix-audit-daily-counts.sql` | Fixes an "ambiguous column" bug in `audit_daily_counts`. | Current. |
| `14-restaurant-performance.sql` | `sales_performance_month` (manager+): one call for the monthly Performance report. Analytics indexes. | Current. |
| `15-discounts.sql` | First write-up of discounts: `discount_kind`, `discount_templates`, `applied_discounts`, `apply_discount`, `remove_discount`. **Seeds three statutory templates**: Senior Citizen (RA 9994, 20%), PWD (RA 10754, 20%), Solo Parent (RA 11861, 10%). | Fully replaced by 16 (except the seed rows, which 16 does not repeat). `apply_discount` replaced again by 31. |
| `15a-display-roles.sql` | **Run alone.** Adds `kitchen_display` and `dine_in_display` to `staff_role`, below `dining`. | Current. |
| `15b-void-requests.sql` | Void requests: `void_request_status`, `void_request_scope`, `void_requests` table, `request_void`, `approve_void_request`, `deny_void_request`, `cancel_void_request`, `pending_void_request_count`, view `v_void_requests`. Guard rails: screens cannot create orders or lines; **no direct UPDATE/DELETE on `order_items` for anyone**; `trg_guard_order_update` (column guard on orders); audit rows cannot claim a false role; screens do not read branch broadcasts; no negative lines; pending requests close when an order closes. | `trg_guard_order_update` replaced by 17 then 31; `cancel_void_request` replaced by 17. |
| `16-discounts.sql` | The discount system as it really ran in production, versioned, with two additions: audit rows on apply/remove, and a branch check. Applied discounts readable only within your branch. | `apply_discount` replaced by 31. `remove_discount` is still the 16 version. |
| `17-hardening.sql` | Drops the broken first-generation discount functions. **Locks `orders.total` and `orders.subtotal`** to the recompute path (transaction flag `tpn.recompute`). Adds the missing manager check and a 7-day minimum to `audit_log_archive_old`. Removes TRUNCATE from browsers on every table. Revokes trigger functions from the API by shape. Floor screen may clear signals; acks are branch-scoped. Audits `cancel_void_request`. No un-void on a closed order. `orders_cleanup_empty` delete policy. `trg_audit_order_money`. | Guard replaced by 31; recompute by 38; `orders_cleanup_empty` replaced by 29. |
| `18-anon-order-fix.sql` | Restores anonymous pickup/delivery ordering and pins every money/lifecycle column on an anonymous insert to its default. | Policies dropped by 29 (customers order only through `submit_order`). |
| `19-access-control.sql` | The permission layer: `permissions` catalogue (49 keys), `access_roles` (9 system roles + custom roles), `access_role_permissions` grid, `staff_permission_overrides`, `staff.access_role_id`, floor trigger, system-role protection trigger, `private.can`, `my_permissions`, `access_matrix`, audit triggers on all three tables. | `private.can` replaced by 29 (active-only). |
| `20-tasks.sql` | Task board: `tasks`, `task_assignees`, `task_activity`, roll-up of task status from assignees, `set_my_task_state`. | `trg_task_assignee_stamp` re-created by 23. |
| `21-inventory-and-finance.sql` | Inventory: `suppliers`, `ingredients`, `stock_movements` (stock level derived by trigger). Money: `staff_compensation`, `operating_expenses`, `finance_settings`; `finance_summary`, `expense_breakdown`. | Current. |
| `22-board-read-helpers.sql` | `staff_directory`, `task_board`, `inventory_board`, `private.task_assignee_json`: name/role only, never email, phone or pay. | Current. |
| `23-function-grant-hardening.sql` | Closes the new functions from 19–22 to anonymous callers (revoke from PUBLIC as well as anon) and closes trigger functions. | Current. |
| `24-customer-ordering-and-table-sessions.sql` | **`submit_order`** (the ordering door) and `track_order`; shared table bills (several phones join one open bill); `order_items.guest_name`, `device_id`; `split_order_by_device`, `table_bill`. | `submit_order` replaced by 27, 29, 29c, 32, 38, 41; `track_order` by 29. |
| `25-payroll.sql` | Permission `payroll.run`; `payroll_status` enum; `payroll_runs`, `payroll_items`; `build_payroll_run`, `rebuild_payroll_run`, `set_payroll_status`; paid runs frozen by trigger. | Current. |
| `26-order-status-audit.sql` | Every status change writes an audit row (trigger); `advance_order_status` adds which screen did it. | Current. |
| `27-guest-memory.sql` | Returning-guest memory: `customer_devices`, `customer_device_items`, `private.remember_device`, `guest_profile`, `my_guest_profile`, `flag_guest_device`, `unflag_guest_device`, `set_guest_note`, `guest_list`. `submit_order` now records the visit. | `my_guest_profile` and `submit_order` replaced by 29. |
| `28-addons-close-variance.sql` | Add-ons (`is_addon`, `addon_group`, `prep_minutes` on menu items, `addon_suggestions`, `order_prep_target`); low-stock notification trigger; `daily_closes` with `daily_close_report`, `record_daily_close`, `list_daily_closes`; `inventory_variance`; `order_bill_breakdown`. | `daily_close_report` and `record_daily_close` replaced by 31. |
| `29-security-hotfix.sql` | Oct 2026 audit. **Server-side pricing** in `submit_order`; anon loses every direct grant on orders and order_items; **non-active accounts are no account**; `messages_insert` dropped; `track_order` needs the private `track_token` for details; device ids validated; rate limiting (`private.client_ip`, `private.rate_hits`, `private.rate_limit`); inquiries: anon may fill contact columns only, capped and rate-limited. Re-adds the 06 columns. | `submit_order` replaced by 29c, 32, 38, 41. |
| `29a-enum-values.sql` | **Run alone.** `payment_method` + `hitpay`, `bank`; `inquiry_type` + `tasting`. | Current. |
| `29b-platform-helpers.sql` | `private.audit_row()` (one generic audit trigger) and `private.add_permission()` (adds a key and grants it to system roles at or above its floor; never to the screen accounts). | Current. |
| `29c-order-size-fix.sql` | `submit_order` accepts "2-3" and "2-3 pax"; no size means the menu price. | Replaced by 32, 38, 41 (the size rule carries forward). |
| `30-site-content.sql` | Permission `site.edit`; `site_settings`, `faqs`, `testimonials` (cannot publish without a consent date), `event_packages`; `public_testimonials()`; all audited. | Current. |
| `31-payments.sql` | **Payments ledger.** Permissions `payments.take`, `payments.confirm`, `payments.refund`, `orders.service_charge`. `payments` table; `private.settle_order` (payment status derived from payments); `trg_guard_order_update` final version; cash, bank transfer, HitPay, refunds, service charge; Senior/PWD VAT exemption (`vat_exempt`, `covered_amount`); `apply_discount` final version (refuses paid bills); daily close counts **received** cash. Realtime on payments. | `settle_order` replaced by 37b. |
| `32-pos-cash-modifiers.sql` | Permissions `pos.use`, `cash.drawer`, `menu.86`. Modifiers (`modifier_groups`, `modifiers`, `menu_item_modifier_groups`, `order_items.modifiers`). `orders.source`. `submit_order` v3 (modifiers, staff path, branch check). **Staff lose direct INSERT on `order_items`** (one ordering door). `set_item_available` (86). Cash shifts: `cash_sessions`, `cash_movements`, X read `cash_session_report`, `open_cash_session`, `cash_move`, Z read `close_cash_session`, `my_open_cash_session`; cash payments attach to the open drawer. Realtime on menu items. | `submit_order` replaced by 38, 41. |
| `33-clockin-verification.sql` | Permission `attendance.verify`; `trusted_networks`; verification columns on `attendance`; staff lose direct writes on attendance; `clock_in_verified`, `attach_clockin_photo`, `clock_out_verified`, `clockin_review_queue`, `review_clockin`, `trust_current_network`, `my_network_status`, `clockin_photos_expired`, `mark_clockin_photos_purged`; private storage bucket `attendance-photos`. | Current. |
| `34-stamp-cards.sql` | Permissions `rewards.redeem`, `rewards.manage`; reward settings; `private.loyalty_secret`; `loyalty_cards`, `loyalty_devices`, `loyalty_ledger`, `private.loyalty_used_codes`; stamp trigger on orders; `claim_stamp_card`, `my_stamp_card`, `stamp_card_code`, `redeem_stamp_reward`, `stamp_card_lookup`, `revoke_stamp_devices`; reward settings guard. | Current. |
| `35-table-settle.sql` | `orders_amount_due`, `settle_table_cash` (one cash tender pays every open order at a table). | Current. |
| `36-read-receipts.sql` | `read_receipts` (per-person read/dismissed for shared rows); messages and notifications become updatable on `read_at` only; `my_notifications`, `my_unread_counts`, `mark_read`, `dismiss_notification`. | `my_notifications` and `my_unread_counts` replaced by 46. |
| `37a-payment-enum.sql` | **Run alone.** `payment_method` + `qrph`. | Current. |
| `37b-manual-payments.sql` | Payment methods `gcash`, `maya`, `qrph`, `card` on the ledger; `settle_order` final version; `record_manual_payment`, `settle_table_manual` (paid immediately, reference required). | Current. |
| `38-delivery.sql` | Permissions `delivery.dispatch`, `delivery.manage`; `delivery_zones`; `orders.delivery_zone_id`, `delivery_fee` (guarded); recompute now adds the fee (final version); `deliveries`; `submit_order` with a zone; `set_delivery_fee`, `delivery_assign`, `delivery_update`, `track_delivery`. | `submit_order` replaced by 41. |
| `39-menu-oct-2026.sql` | Data: the real October 2026 menu from the printed boards. Dishes not on the boards are deleted if never ordered, otherwise hidden. | — |
| `40-menu-descriptions.sql` | Data: short English descriptions for dishes that had none (fills empty only). HANDOFF says it was not yet run on production at the time it was written. | — |
| `41-order-idempotency.sql` | `orders.client_key` (unique), `order_items.client_key`; `private.submit_order_reply`; **final `submit_order`**: a retry with the same key returns the original order. | Current. |
| `42-silog-menu.sql` | Data: "Chicken Silog" → "Chicksilog"; Tocilog back on the menu at ₱115. | — |
| `43-bir-invoices.sql` | Booklet invoice numbers: `orders.invoice_no/at/by` (guarded), `bir_day_invoices`, `record_order_invoice`, `record_day_invoice`, `invoice_day_summary`; setting `bir.vat_registered`. | Current. |
| `44-staff-rank-guard.sql` | `private.guard_staff_rank` on `staff` and `private.guard_override_rank` on `staff_permission_overrides`: nobody changes their own role/access/status, nobody touches someone at or above their tier, nobody grants a tier above their own. CEO exempt. | Current. |
| `45-printer-permission.sql` | Permission `printer.manage` (Administration, manager). | Current. |
| `46-my-notifications-only.sql` | `my_notifications` and `my_unread_counts` list only my own plus shared notifications. | Current. |

`tests/db/prod-drift-after-17.sql` is not a migration. The test runner applies it right after `17` to recreate things production has that no migration creates: the legacy `discount_presets` table and the legacy order columns `discount`, `discount_label`, `discount_preset_id`, `discount_reference`, `discount_applied_by`, `discount_applied_at`.

Next free migration number, per `HANDOFF.md`: **47**.

---

### 3.3 Roles and permissions

There are two layers. The **role ladder** (the `staff_role` enum) is the floor the database enforces on everything that moves money. The **permission keys** sit on top and decide what each person may reach. A permission can take access away; it is meant never to give access the tier forbids (but see 3.9.2 for two ways around that).

#### 3.3.1 The role ladder (`staff_role` enum), lowest to highest

| # | Role | Added in | What it is |
|---|---|---|---|
| 1 | `kitchen_display` | `sql/15a` | Shared login for the kitchen wall screen. Not a person. |
| 2 | `dine_in_display` | `sql/15a` | Shared login for the dining-floor screen. Not a person. |
| 3 | `dining` | `sql/01` | Front of house. Default for every new login (`handle_new_user`). |
| 4 | `kitchen` | `sql/01` | Back of house. |
| 5 | `supervisor` | `sql/01` | Runs a shift. |
| 6 | `manager` | `sql/01` | Runs the branch. |
| 7 | `admin` | `sql/01` | System administrator. |
| 8 | `director` | `sql/01` | Oversight. |
| 9 | `ceo` | `sql/01` | Full access, always. |

`private.has_role('x')` is true when the caller is at or above `x` on this ladder. Because the two screens sit at the bottom, they fail every `has_role` check.

Screens are further limited by name (not by position) in several places: `orders_auth_create` (`sql/15b`) refuses them, `trg_guard_order_update` lets them change only `status` and its timestamps and never to `completed`/`cancelled`, and `notif_read`/`messages_read` hide branch-wide rows from them. `private.add_permission` (`sql/29b`) never grants them a new key.

The create-staff Edge Function (`supabase/functions/create-staff/index.ts`) keeps its own copy of this order and refuses: callers below manager, roles above the caller's own, and screen accounts unless the caller is admin or higher.

#### 3.3.2 System access roles (`access_roles`, seeded in `sql/19`)

Nine rows with `is_system = true`, one per enum value. Their `key`, `base_tier` and existence cannot be changed, and they cannot be deactivated (`trg_protect_system_roles`); label, colour, icon and their permission grid stay editable.

| key | Label | Tagalog label | Base tier | Colour | Description (seed) |
|---|---|---|---|---|---|
| `kitchen_display` | Kitchen Screen | Kitchen Screen | kitchen_display | #6B7280 | Shared login for the wall-mounted kitchen display. Not a person. |
| `dine_in_display` | Floor Screen | Floor Screen | dine_in_display | #6B7280 | Shared login for the wall-mounted floor display. Not a person. |
| `dining` | Dining Crew | Dining Crew | dining | #2D7A4F | Front of house. Takes and serves orders. |
| `kitchen` | Kitchen Crew | Kusinero | kitchen | #B45309 | Back of house. Cooks and books in deliveries. |
| `supervisor` | Supervisor | Superbisor | supervisor | #0E7490 | Runs a shift. Can discount and raise tasks. |
| `manager` | Manager | Manedyer | manager | #8B1A0E | Runs the branch. Approves voids, edits the menu, sees the money. |
| `admin` | Admin | Admin | admin | #5B21B6 | System administrator. Creates accounts and sets access. |
| `director` | Director | Direktor | director | #1E3A8A | Oversight across the business. |
| `ceo` | CEO | CEO | ceo | #111827 | Full access, always. Cannot be locked out by design. |

Custom roles (`is_system = false`) can be created, edited and deleted by anyone holding `roles.edit`. Each has a `base_tier`; `trg_role_perm_floor` refuses to tick a permission whose `min_tier` is above that base tier.

#### 3.3.3 The permission catalogue

64 keys in total: 49 seeded by `sql/19`, then `payroll.run` (`sql/25`) and 14 added with `private.add_permission` (`sql/30`, `31`, `32`, `33`, `34`, `38`, `45`).

**Default grid.** For each system role a key starts ON when the role's tier is at or above the key's minimum tier, with these exceptions:
- The two screen accounts start with only `kds.view`, `kds.advance`, `floor.view`, `kitchen_station.view`, `voids.request` (`sql/19` section 12). `orders.view` is in the keep-list in `sql/19`, but it was seeded OFF for screens because its floor (`dining`) is above theirs, and the update there only turns keys off. So by the repo, screens do **not** hold `orders.view` by default. (Not checked against live.)
- Manager starts with `performance.view`, `history.view` and `roles.view` OFF (`sql/19` section 16), to match what managers saw before.
- The CEO always holds every key, whatever the grid says (`private.can`).

"DB check" says where the database itself tests the key. "UI only" means no SQL in the repo checks that key; the portal uses it to hide or show things, and the database relies on the role ladder or on RLS instead.

| Key | Category | Label | Min tier | Default holders (system roles) | DB check |
|---|---|---|---|---|---|
| `dashboard.view` | Workspace | See the dashboard | dining | dining and up | UI only |
| `orders.view` | Workspace | See live orders | dining | dining and up | `table_bill` (24), `guest_profile`, `guest_list`, `customer_devices` read (27), `order_bill_breakdown`, `daily_close_report` (28/31, or finance.view), `order_payments` and `payments` read (31), `orders_amount_due` (35), `deliveries` read (38) |
| `orders.manage` | Workspace | Move orders along | dining | dining and up | `split_order_by_device` (24), `advance_order_status` (26, or kds.advance), guest flag/note functions (27), staff path of `submit_order` (32/38/41, or pos.use) |
| `pos.use` | Workspace | Use the counter POS | dining | dining and up | staff path of `submit_order` (32, 38, 41) |
| `orders.cancel` | Workspace | Cancel an order | manager | manager and up | `advance_order_status` to completed/cancelled (26). Cancelling is also hard-gated at manager by `trg_guard_order_update`. |
| `kds.view` | Workspace | See the kitchen queue | kitchen_display | screens, dining and up | UI only |
| `kds.advance` | Workspace | Move kitchen tickets | kitchen_display | screens, dining and up | `advance_order_status` (26) |
| `menu.86` | Workspace | Mark dishes sold out | kitchen | kitchen and up | `set_item_available` (32, or menu.edit) |
| `floor.view` | Workspace | Open the dine-in floor | kitchen_display | screens, dining and up | UI only |
| `kitchen_station.view` | Workspace | Open the kitchen screen | kitchen_display | screens, dining and up | UI only |
| `voids.request` | Workspace | Ask for a void | kitchen_display | screens, dining and up | UI only. `request_void` accepts any active staff account. |
| `voids.approve` | Workspace | Approve a void | manager | manager and up | UI only. `approve_void_request` checks the manager tier. |
| `inquiries.view` | Workspace | See enquiries | supervisor | supervisor and up | UI only. RLS: supervisor+ read (`sql/01`). |
| `inquiries.manage` | Workspace | Handle enquiries | supervisor | supervisor and up | UI only. RLS: **manager+** update (`sql/01`), so a supervisor holding this key is still refused by the database. |
| `delivery.dispatch` | Orders | Dispatch deliveries | dining | dining and up | `delivery_assign`, `delivery_update` (or assigned rider), `deliveries` read (38) |
| `delivery.manage` | Orders | Manage delivery zones | manager | manager and up | `delivery_zones` write and read of inactive zones (38) |
| `staff.view` | Team | See the team | dining | dining and up | `staff_directory` (22, or tasks.assign) |
| `staff.assign` | Team | Move people between roles | admin | admin and up | UI only. RLS on `staff`: admin+ update. |
| `schedules.view` | Team | See schedules | dining | dining and up | UI only. RLS `sql/08`. |
| `schedules.edit` | Team | Write schedules | manager | manager and up | UI only. RLS `sql/08` (manager+). |
| `attendance.view` | Team | See attendance | dining | dining and up | UI only. RLS `sql/09`. |
| `attendance.edit` | Team | Correct attendance | manager | manager and up | UI only. RLS `sql/33` (manager+). |
| `messages.view` | Team | Read messages | dining | dining and up | UI only |
| `messages.broadcast` | Team | Send to everyone | manager | manager and up | UI only. The insert policy lives only on production (see 3.12). |
| `notifications.view` | Team | See notifications | dining | dining and up | UI only |
| `tasks.view` | Team | See the task board | dining | dining and up | `tasks`/`task_assignees`/`task_activity` read (20), `task_board` (22) |
| `tasks.create` | Team | Create tasks | supervisor | supervisor and up | `tasks` insert (20) |
| `tasks.assign` | Team | Assign tasks | supervisor | supervisor and up | `tasks` update, `task_assignees` write (20), `staff_directory` (22) |
| `tasks.close_any` | Team | Close anyone's task | manager | manager and up | `tasks` update/delete (20) |
| `attendance.verify` | People | Review clock-in photos | manager | manager and up | all clock-in review functions, `trusted_networks`, photo bucket read/delete (33) |
| `menu.view` | Menu & Pricing | See the menu manager | dining | dining and up | UI only |
| `menu.edit` | Menu & Pricing | Edit the menu | manager | manager and up | modifier tables write (32), `set_item_available` (32). `menu_items`/`menu_categories` RLS use the manager tier instead (`sql/01`). |
| `discounts.view` | Menu & Pricing | See discounts | supervisor | supervisor and up | UI only. Templates are readable by every signed-in account (`sql/16`). |
| `discounts.manage` | Menu & Pricing | Build discounts | manager | manager and up | UI only. RLS uses the manager tier (`sql/16`). |
| `discounts.apply` | Menu & Pricing | Apply a discount | supervisor | supervisor and up | UI only. `apply_discount` checks the supervisor tier. |
| `tables.manage` | Menu & Pricing | Manage tables and QRs | manager | manager and up | UI only. RLS on `restaurant_tables`: **admin+** write (`sql/01`), so a manager is refused by the database. |
| `finance.view` | Money | See the money view | manager | manager and up | `finance_summary`, `expense_breakdown`, expenses/finance-settings read (21); daily close (28/31); `payments` read (31); cash drawer reports/RLS (32, or cash.drawer); BIR read (43, or payments.take) |
| `finance.edit` | Money | Set costing rules | admin | admin and up | `finance_settings` write, expense delete (21) |
| `expenses.record` | Money | Record an expense | manager | manager and up | `operating_expenses` insert/update (21) |
| `payroll.view` | Money | See pay rates | admin | admin and up | `staff_compensation` read (21), `payroll_runs`/`payroll_items` read (25) |
| `payroll.run` | Money | Run payroll | admin | admin and up | build/rebuild/status, `payroll_runs` update/delete, `payroll_items` update (25) |
| `payroll.edit` | Money | Set pay rates | ceo | ceo | `staff_compensation` write (21) |
| `payments.take` | Money | Take payments | dining | dining and up | cash, bank, manual, table settle, `order_payments`, `orders_amount_due` (31/35/37b), BIR functions (43); hitpay-create checks it via `my_permissions` |
| `payments.confirm` | Money | Confirm bank transfers | supervisor | supervisor and up | `confirm_bank_transfer` (31) |
| `payments.refund` | Money | Refund payments | manager | manager and up | `refund_check`, `refund_payment` (31) |
| `orders.service_charge` | Money | Set service charge | supervisor | supervisor and up | `set_service_charge` (31) |
| `cash.drawer` | Money | Open and close the cash drawer | dining | dining and up | drawer functions and RLS (32) |
| `rewards.redeem` | Money | Redeem stamp-card rewards | supervisor | supervisor and up | `redeem_stamp_reward`, `stamp_card_lookup`, loyalty table read (34) |
| `rewards.manage` | Money | Manage the stamp card | manager | manager and up | `revoke_stamp_devices`, `stamp_card_lookup`, reward settings write (34) |
| `inventory.view` | Inventory | See stock | kitchen | kitchen and up | read of suppliers/ingredients/movements (21), `inventory_board` (22), `inventory_variance` (28) |
| `inventory.receive` | Inventory | Receive a delivery | kitchen | kitchen and up | insert `delivery_in` / `usage` movements (21) |
| `inventory.adjust` | Inventory | Adjust or write off stock | manager | manager and up | insert `wastage` / `adjust_up` / `adjust_down` / `return_out` (21) |
| `inventory.manage` | Inventory | Manage ingredients | manager | manager and up | suppliers and ingredients write, movement delete (21) |
| `accounts.view` | Administration | See accounts | manager | manager and up | UI only |
| `accounts.create` | Administration | Create accounts | manager | manager and up | UI only. The create-staff Edge Function checks the manager tier itself. |
| `accounts.deactivate` | Administration | Deactivate accounts | admin | admin and up | UI only. `staff` update RLS is admin+; `sql/44` rank guard applies. |
| `roles.view` | Administration | See roles and access | manager | admin and up (manager starts OFF) | `access_roles`/grid/override read, `access_matrix` (19) |
| `roles.edit` | Administration | Change roles and access | admin | admin and up | all writes to roles, grid and overrides (19) |
| `audit.view` | Administration | Read the audit log | admin | admin and up | UI only. `audit_log` RLS lets **manager+** read (`sql/07`). |
| `performance.view` | Administration | See performance | manager | admin and up (manager starts OFF) | UI only. `sales_performance_month` checks the manager tier. |
| `history.view` | Administration | See history | manager | admin and up (manager starts OFF) | UI only |
| `settings.manage` | Administration | Change settings | admin | admin and up | used as the "every branch" key in tasks (20/22), payroll read (25), daily-close read (28), `advance_order_status` (26) |
| `site.edit` | Administration | Edit the website | manager | manager and up | `site_settings`, `faqs`, `testimonials`, `event_packages` write and draft read (30) |
| `printer.manage` | Administration | Printer tools | manager | manager and up | UI only. `sql/45` states nothing on the server uses it; it controls the counter's printer menu (test prints, no-sale drawer, auto-print, kitchen printer address). |

#### 3.3.4 How `private.can(key)` decides (final version `sql/29`)

1. Look up the caller's `staff` row, **active accounts only**. No row → **no**.
2. Role is `ceo` → **yes**, always (lockout protection: no setting can lock the CEO out of the roles editor).
3. A personal override in `staff_permission_overrides` for this key → that answer wins.
4. The person has a custom role (`staff.access_role_id`) → the custom role's grid answers; a missing row means no. If that custom role is inactive, every key answers **no** (it does not fall back to the system role).
5. Otherwise → the grid of the system role whose key equals the person's enum tier.

`public.my_permissions()` returns every key the caller holds (one call at login). `public.access_matrix()` returns the whole role × permission grid for the Access Matrix screen, with `grantable = false` where the key's floor is above the role's base tier; it returns nothing unless the caller holds `roles.view`.

#### 3.3.5 Guards on roles and people

| Guard | File | Rule |
|---|---|---|
| `trg_role_perm_floor` (before insert/update on `access_role_permissions`) | `sql/19` | Refuses `allowed = true` when the key's `min_tier` is above the role's `base_tier` (`permission_above_role_tier`). Revoking is always allowed. |
| `trg_protect_system_roles` (before update/delete on `access_roles`) | `sql/19` | System roles: cannot be deleted, re-keyed, re-tiered, un-flagged or deactivated. |
| `trg_audit_roles`, `trg_audit_arp`, `trg_audit_spo` | `sql/19` | Every insert/update/delete on roles, the grid and overrides writes `access.insert/update/delete` to `audit_log`. |
| `private.guard_staff_rank` (before insert/update/delete on `staff`) | `sql/44` | For a signed-in caller below CEO: you cannot change your own `role`, `access_role_id` or `employment_status` (`staff_self_change`); cannot change those on, or delete, anyone at or above your tier (`staff_outranks_you`); cannot give a tier above your own (`role_above_yours`); cannot delete yourself. Name and other fields stay editable. Calls with no signed-in user (SQL editor, service role, sign-up) are not affected. |
| `private.guard_override_rank` (before insert/update/delete on `staff_permission_overrides`) | `sql/44` | Below CEO: no overrides on yourself (`override_self`), none on anyone at or above your tier. |
| `staff` RLS | `sql/01` | Read: yourself; manager+ your branch; admin+ everyone. Insert and update: admin+. Delete: director+. |

---

### 3.4 Every table, by area

For each table: what it is for, the important columns, who can read and write it, and its triggers. "Written only by functions" means browsers have no insert/update/delete grant, so the only way in is a SECURITY DEFINER function.

#### 3.4.1 Orders and order lines

**`orders`** (`sql/01`, extended by 09, 24, 29, 32, 38, 41, 43)
- Purpose: one bill. A dine-in table can have several (each QR round can join or open one).
- Key columns: `order_number` (`TPN-{BRANCH}-{YYYYMMDD}-{nnnn}`, from the global `order_number_seq`; nothing in the repo resets the sequence daily), `branch_id`, `table_id`, `order_type` (dine_in, pickup, delivery), `status` (pending, confirmed, preparing, ready, served, completed, cancelled), `customer_name`, `customer_phone`, `customer_email`, `delivery_address`, `scheduled_for`, `subtotal`, `discount_amount`, `service_charge`, `delivery_fee`, `total`, `payment_method`, `payment_status` (pending, paid, refunded, failed), `payment_reference`, `notes`, lifecycle timestamps (`placed_at`, `confirmed_at`, `ready_at`, `served_at`, `completed_at`, `cancelled_at`), `cancel_reason`, `track_token` (private, for the customer's tracking link, `sql/29`), `source` (web, qr, pos, phone; `sql/32`), `delivery_zone_id`, `client_key` (unique, idempotency, `sql/41`), `invoice_no`, `invoice_at`, `invoice_by` (`sql/43`). Legacy columns on production only: `discount`, `discount_label`, `discount_preset_id`, `discount_reference`, `discount_applied_by`, `discount_applied_at` (unused).
- Read: staff in the order's branch, admin+ everywhere (`orders_staff_read`). Anon: none since `sql/29`; guests use `track_order`.
- Insert: in practice only through `submit_order` (and `split_order_by_device`). A policy and grant for staff direct insert still exist (`orders_auth_create`, `sql/15b`; screens refused); see 3.9.1.
- Update: staff in the branch (`orders_staff_update`, `sql/01`), limited column-by-column by the guard triggers below.
- Delete: dining+ in the branch, and only an order with no lines (`orders_cleanup_empty`, `sql/29`).
- Triggers:
  - `trg_orders_number` (before insert): order number. `sql/01`/`03`.
  - `trg_orders_touch` (before update): `updated_at`.
  - `trg_guard_order_update` (before update, final `sql/31`): totals only via recompute; cancel needs manager; discount/service charge changes need supervisor unless a settlement function is running; `payment_status`, `payment_reference` (and `payment_method` once paid) only via settlement; screens may change only `status`, `confirmed_at`, `ready_at`, `served_at`, `updated_at`, and never to completed/cancelled.
  - `trg_guard_delivery_fee` (before update, `sql/38`): `delivery_fee` and `delivery_zone_id` only via `set_delivery_fee`.
  - `trg_guard_invoice_no` (before update, `sql/43`): invoice columns only via `record_order_invoice`.
  - `trg_orders_adjustments_recompute` (after update of discount_amount, service_charge, `sql/11`): recompute total.
  - `trg_audit_order_money` (after update, `sql/17`): audit row `order.complete`, `order.cancel` or `order.money_change` when status becomes completed/cancelled or total, discount, service charge or payment fields change.
  - `trg_orders_audit_status` (after update of status, `sql/26`): audit row `order.status` for every other status change, with the screen name when set.
  - `trg_close_void_requests_on_terminal` (after update of status, `sql/15b`): pending void requests on an order that closes are cancelled with a note.
  - `trg_order_stamp` (after update of payment_status, status, `sql/34`): stamp-card stamp or reversal.
  - `trg_orders_notify_new` (after insert) and `trg_orders_notify_status` (after update of status) (`sql/10`): notifications.
- Realtime: yes.

**`order_items`** (`sql/01`, extended by 11, 24, 32, 41)
- Purpose: one line on a bill.
- Key columns: `menu_item_id`, `name_snapshot`, `price_snapshot`, `unit_price`, `quantity`, `total_price`, `pax_size`, `modifiers` (JSON snapshot of chosen modifiers and their prices), `notes`, `station`, `status`, `voided_at`, `voided_by`, `void_reason`, `guest_name`, `device_id` (random browser id, validated `^[A-Za-z0-9_-]{8,64}$`), `client_key`.
- Read: signed-in staff who can see the parent order (`order_items_read`, restricted to `authenticated` in `sql/29`).
- Insert: nobody directly. Anon lost it in `sql/29`, staff in `sql/32`. Lines are written only by `submit_order`.
- Update, delete, truncate: nobody directly (`sql/15b`). Voiding goes through `void_order_item` or `approve_void_request`; moving lines through `split_order_by_device`.
- Triggers: `trg_order_items_nonneg` (before insert, `sql/15b`): refuses negative price or quantity ≤ 0. `trg_order_items_recompute_ins/upd/del` (after, `sql/11`): recompute the order's totals.
- Realtime: yes.

**`void_requests`** (`sql/15b`)
- Purpose: a request to void one line (`scope = 'item'`) or a whole order (`scope = 'order'`), and its decision.
- Key columns: `branch_id`, `order_id`, `order_item_id`, `scope`, `status` (pending, approved, denied, cancelled), snapshots (`item_name`, `item_qty`, `item_amount`, `order_number`), `reason`, `requested_by`, `requested_by_role`, `reviewed_by`, `reviewed_at`, `review_note`.
- Unique: one pending request per item; one pending whole-order request per order.
- Read: the requester; manager+ in the branch; admin+ everywhere. View `v_void_requests` adds names (runs as the caller).
- Written only by functions (`request_void`, `approve_void_request`, `deny_void_request`, `cancel_void_request`, and the terminal-order trigger).
- Realtime: yes.

#### 3.4.2 Payments and refunds

**`payments`** (`sql/31`, method list widened in `sql/37b`, drawer link in `sql/32`)
- Purpose: the money ledger. Every peso in (`kind = 'payment'`) or out (`kind = 'refund'`) is a row.
- Key columns: `order_id`, `branch_id`, `kind`, `method` (cash, gcash, maya, qrph, card, bank, hitpay, card_terminal, other), `status` (pending, completed, failed, cancelled, expired), `amount` (> 0), `tip`, `tendered`, `change_due`, `provider_request_id` (unique, HitPay), `provider_payment_id`, `provider_method`, `checkout_url`, `reference` (bank ref / GCash ref / approval code, ≤ 120), `note`, `refund_of` (required exactly when `kind = 'refund'`), `cash_session_id`, `raw` (HitPay payload), `created_by`, `confirmed_by`, `confirmed_at`.
- Read: holders of `orders.view` or `finance.view`, in their branch (admin+ everywhere).
- Written only by functions: `record_cash_payment`, `record_bank_transfer`, `confirm_bank_transfer`, `record_manual_payment`, `settle_table_cash`, `settle_table_manual`, `refund_payment`, and the service-role HitPay functions.
- Triggers: `trg_audit_payments` (after insert/update, generic `audit_row`); `trg_payment_cash_session` (before insert, `sql/32`): a cash payment with no drawer is attached to the branch's newest open drawer.
- Realtime: yes.

How the order's payment state is derived: see `private.settle_order` in 3.5.3.

#### 3.4.3 Discounts

**`discount_templates`** (`sql/15`/`16`, VAT option widened in `sql/31`)
- Purpose: reusable discounts (promos, staff meal, statutory discounts).
- Key columns: `code` (unique), `name`, `kind` (percent, fixed), `value`, `legal_law` (non-null = statutory, cannot be deleted), `requires_id`, `min_subtotal`, `max_discount` (peso cap), `stackable`, `is_active`, `vat_treatment` (gross, net_of_vat, vat_exempt), `created_by`.
- Seed (`sql/15`): `senior-citizen` (RA 9994, 20%, needs ID, not stackable), `pwd` (RA 10754, 20%, needs ID, not stackable), `solo-parent` (RA 11861, 10%, gross, needs ID, stackable). `sql/31` switches the two RA 9994 / RA 10754 templates to `vat_exempt`.
- Read: every signed-in account. Insert/update: manager+. Delete: manager+, statutory templates never.
- Trigger: `trg_discount_templates_touch` (`updated_at`).

**`applied_discounts`** (`sql/16`, columns added in `sql/31`)
- Purpose: one row per discount actually put on an order. Removal is a soft delete, so the trail survives.
- Key columns: `order_id`, `template_id`, `name_snapshot`, `kind_snapshot`, `value_snapshot`, `amount_applied`, `id_ref` (Senior/PWD ID number), `legal_law`, `applied_by`, `applied_at`, `removed_at`, `removed_by`, `remove_reason`, `covered_amount` (the qualifying guest's share), `vat_exempt_amount`.
- Read: admin+, or anyone whose branch is the order's branch. Written only by `apply_discount` and `remove_discount`.
- Triggers: `trg_applied_discounts_recompute_ins/upd/del` → `private.recompute_order_discount` sums live rows into `orders.discount_amount`, which recomputes the total.

**`discount_presets`**: legacy first-generation table, production only (created for tests by `tests/db/prod-drift-after-17.sql`). Nothing reads or writes it (`sql/17` notes).

#### 3.4.4 Cash shifts and the drawer (X and Z read)

**`cash_sessions`** (`sql/32`)
- Purpose: one drawer shift.
- Key columns: `branch_id`, `register_label` (default "Counter"), `opened_by`, `opened_at`, `opening_float`, `status` (open, closed), `closed_by`, `closed_at`, `expected_cash`, `counted_cash`, `variance`, `denominations` (JSON count), `notes`.
- Unique: one open drawer per branch per register label.
- Read: holders of `cash.drawer` or `finance.view` in the branch (admin+ everywhere). Written only by functions. Audited (`audit_row` on insert/update).

**`cash_movements`** (`sql/32`)
- Purpose: cash in / cash out during a shift (petty cash, change top-ups), each with a reason of 3–200 characters.
- Read: as for the session. Written only by `cash_move`. Audited.

X read and Z read: `cash_session_report` is the X read (any time); `close_cash_session` is the Z read. Expected cash = opening float + cash sales + cash tips − cash refunds + cash in − cash out (`sql/32`).

**`daily_closes`** (`sql/28`, fed by `sql/31`)
- Purpose: one end-of-day till close per branch per date; figures are snapshotted.
- Key columns: `close_date`, `expected_cash` (since `sql/31`: cash actually received, from payments), `counted_cash`, `variance`, `gross_sales`, `discounts`, `net_sales`, `order_count`, `void_count`, `voided_value`, `notes`, `closed_by`.
- Read: `finance.view` in the branch (or `settings.manage`). Written only by `record_daily_close` (re-closing the same date overwrites it).

#### 3.4.5 Menu, modifiers and 86

**`menu_categories`** (`sql/01`): name, Tagalog name, order, icon, active. Read: anyone, active only. Write: manager+ (`sql/01`).

**`menu_items`** (`sql/01`, extended by 06/29, 28)
- Key columns: `category_id`, `name`, `name_tagalog`, `description`, `price`, `pax_options` (JSON of size → price, e.g. `{"2-3": x, "4-6": y}`), `is_available` (the 86 switch), `is_shareable`, `station`, `display_order`, `branch_availability`, `emoji`, `is_featured`, `featured_tag`, `image_url`, `is_addon`, `addon_group`, `prep_minutes`.
- Read: anyone, but **only available items** (`menu_items_read`, `is_available = true`); manager+ also see hidden ones through the write policy. A dish switched off disappears from the public menu.
- Write: manager+. 86 by kitchen crew goes through `set_item_available`.
- Trigger: `trg_menu_items_touch`. Realtime: yes (`sql/32`).

**`modifier_groups`**, **`modifiers`**, **`menu_item_modifier_groups`** (`sql/32`)
- Purpose: choices on a dish ("Egg: sunny side up / scrambled", "Extras: extra rice +₱25"). Groups have `min_select`/`max_select`; modifiers have `price_delta` (−10,000 to 10,000) and `is_available`; the link table attaches groups to dishes.
- Read: anyone. Write: `menu.edit`. Audited (`audit_row`).

#### 3.4.6 Tables, signals and table sessions

**`restaurant_tables`** (`sql/01`, signals `sql/04`)
- Key columns: `branch_id`, `table_number` (unique per branch), `capacity`, `is_active`, `call_staff_at`, `bill_requested_at`, `bill_payment_method`, `bill_total`.
- Read: anyone, active tables only. Write: admin+ (`tables_write`). Signals are set only through `signal_call_staff` / `signal_bill_request` and cleared through `ack_call_staff` / `ack_bill_request`.
- Trigger: `trg_tables_notify_signal` (a new call or bill request notifies the branch).
- Realtime: yes.

**Table sessions.** There is no separate session table. A "table session" is the open dine-in order on a table: `submit_order` joins a new round to the oldest open, unpaid dine-in order on that table when `p_join_table_bill` is true (`sql/24`, locked with `for update` since `sql/29`). Each line records `guest_name` and `device_id`, so the bill can be shown per phone (`table_bill`, `order_bill_breakdown`) and split (`split_order_by_device`). See 3.8.1 for the "two first orders" race.

#### 3.4.7 Deliveries

**`delivery_zones`** (`sql/38`)
- Key columns: `branch_id`, `name`, `areas`, `fee` (0–5,000), `min_order`, `eta_minutes`, `is_active`, `sort`.
- Read: anyone (active zones; `delivery.manage` holders also see inactive). Write: `delivery.manage` in the branch. Audited.
- Once a branch has at least one active zone, `submit_order` requires a delivery zone, applies its fee and minimum order.

**`deliveries`** (`sql/38`)
- Purpose: dispatch record, one per delivery order.
- Key columns: `order_id` (primary key), `status` (waiting, assigned, on_the_way, delivered, failed), `courier` (own, lalamove, grab, other), `rider_staff_id`, `rider_name`, `rider_phone`, `tracking_url` (must start `https://`), `courier_cost`, `note`, `fail_reason`, `assigned_at`, `picked_up_at`, `delivered_at`, `updated_by`.
- Read: `orders.view` or `delivery.dispatch` holders, or the assigned rider, in the branch. Written only by functions. Audited.
- `delivery_update` moves the order too: on the way → order `served`; delivered → order `completed`.

#### 3.4.8 Staff, roles and permissions

**`branches`** (`sql/01`): `code`, `name`, `address`, `is_active`. Read: anyone (active). Write: admin+.

**`staff`** (`sql/01`, `access_role_id` from `sql/19`)
- Key columns: `id` (= the login's id), `full_name`, `phone`, `role` (`staff_role`), `branch_id`, `employment_status` (active, pending, disabled, terminated as used in code and tests; free text in the schema), `hired_at`, `access_role_id`.
- RLS and guards: see 3.3.5.
- Triggers: `trg_staff_touch`; `trg_staff_notify_pending` (a pending account notifies the branch, `sql/10`); `trg_guard_staff_rank` (`sql/44`); `on_auth_user_created` on `auth.users` creates the row (`sql/01`).

**`permissions`**, **`access_roles`**, **`access_role_permissions`**, **`staff_permission_overrides`** (`sql/19`)
- `permissions`: the catalogue (key, category, label, Tagalog label, description, `min_tier`, order). Read: any signed-in account. No write path from the app.
- `access_roles`: system and custom roles. Read: `roles.view`. Write: `roles.edit`. Guards in 3.3.5. Audited.
- `access_role_permissions`: role × key → allowed. Read: `roles.view`. Write: `roles.edit`. Floor trigger. Audited.
- `staff_permission_overrides`: per-person allow/deny with reason and who granted. Read: yourself, or `roles.view`. Write: `roles.edit`, plus `sql/44` rank guard. Audited.
- None of these four is readable by anon.

#### 3.4.9 Attendance and clock-in verification

**`attendance`** (`sql/09`, verification columns `sql/33`)
- Key columns: `staff_id`, `clock_in_at`, `clock_out_at`, `work_date` (generated, Manila date), `notes`, correction fields (`corrected_by`, `corrected_at`, `correction_note`), `clock_in_ip`, `clock_out_ip`, `network_trusted`, `verify_status` (verified, needs_approval, approved, flagged), `verify_reasons` (untrusted_network, network_unknown, no_photo, photo_pending), `photo_path`, `photo_purged_at`, `uniform_check` (JSON), `reviewed_by`, `reviewed_at`, `review_note`.
- Unique: one open shift per person.
- Read: yourself; manager+ for your branch; admin+ everyone (`attendance_self_read`, `sql/09`).
- Insert: nobody directly since `sql/33`; clock-in is `clock_in_verified`. Update: manager+ for staff in their branch, admin+ anywhere (`attendance_manager_update`, `sql/33`); staff cannot edit their own row, so no back-dating. Delete: admin+.
- Trigger: `trg_attendance_notify_correction` (`sql/10`): a correction notifies the person.
- Realtime: yes.

**`trusted_networks`** (`sql/33`)
- Purpose: the restaurant's internet connections. IPv4 stored as the exact address (/32), IPv6 as its /64.
- Key columns: `branch_id`, `label`, `network`, `is_active`, `added_by`, `last_seen_at`.
- Read/update/delete: `attendance.verify` in the branch (admin+ everywhere). New rows only through `trust_current_network` or `review_clockin`. Audited.

**Storage bucket `attendance-photos`** (`sql/33`): private, 1 MB limit, JPEG only. Upload: only by the person, only to the path issued for their own open clock-in, within 10 minutes, once. Read and delete: `attendance.verify`. Retention: `site_settings.hr.photo_retention_days` (default 60); the portal lists expired photos with `clockin_photos_expired`, deletes the files through the Storage API, then calls `mark_clockin_photos_purged`.

#### 3.4.10 Schedules

**`schedules`** (`sql/08`)
- Key columns: `staff_id`, `week_start` (the Monday), `shifts` (JSON per day, e.g. `{"mon":"9:45a-6p","tue":"OFF"}`), `notes`, `updated_by`. Unique per person per week.
- Read: yourself; manager+ for staff in their branch (admin+ any). Insert/update/delete: manager+ for staff in their branch (admin+ any).
- Trigger: `trg_schedules_touch`. Not audited (no audit trigger found).

#### 3.4.11 Tasks

**`tasks`**, **`task_assignees`**, **`task_activity`** (`sql/20`)
- `tasks`: `branch_id`, `title` (not blank), `description`, `category`, `status` (todo, in_progress, blocked, done, cancelled), `priority` (low, normal, high, urgent), `due_at`, `checklist` (JSON), `created_by`, `started_at`, `completed_at`, `completed_by`.
- `task_assignees`: one row per person on a task, with their own `state` (assigned, working, done), `note`, `assigned_by`, `state_changed_at`.
- `task_activity`: append-only trail (`actor_id`, `action`, `detail`).
- Status roll-up (`private.roll_up_task`): everyone done → task `done`; anyone working → `in_progress`; otherwise `todo`. A `cancelled` task, a `blocked` task, and a task with no assignees keep their hand-set status.
- RLS: read with `tasks.view` in your branch (or `settings.manage` everywhere), and always any task you are on. Create: `tasks.create`. Update: `tasks.assign` or `tasks.close_any`. Delete: `tasks.close_any`. Assignees write: `tasks.assign`. Activity insert: as yourself. An assignee changes their own progress through `set_my_task_state`.
- Triggers: `trg_tasks_touch`; `trg_task_assignee_stamp` (before update); `trg_task_assignee_rollup` (after insert/update/delete).

#### 3.4.12 Messages, notifications and read receipts

**`messages`** (`sql/09`)
- Key columns: `from_staff_id`, `to_staff_id` (null = broadcast to the branch), `branch_id`, `subject`, `body` (1–5,000 chars), `read_at`.
- Read: messages to you or from you; branch broadcasts for your branch (not for screen accounts); admin+ everything (`messages_read`, `sql/15b`).
- Insert: the permissive policy was dropped in `sql/29`. The comment there says a policy `messages_send` (manager+) "remains"; **that policy is not in any repo file** (production only).
- Update: only the `read_at` column is granted (`sql/36`). The comment in `sql/36` says a policy `messages_mark_read` (to_staff_id = you) "stays"; **not in any repo file**.
- Delete: the sender or admin+.
- Trigger: `trg_messages_notify_new` (notifies the recipient or the branch). Realtime: yes.

**`notifications`** (`sql/10`)
- Key columns: `user_id` (null = branch-wide), `branch_id`, `kind`, `title`, `body`, `link`, `entity_type`, `entity_id`, `priority` (low, normal, high, urgent), `read_at`.
- Read (`notif_read`, `sql/15b`): your own; branch-wide rows for your branch (not for screens); **admin+ can read every notification**, including other people's personal ones.
- Insert: yourself, or manager+ for your branch. Triggers insert through `notify_push`, which bypasses RLS.
- Update: `read_at` column only (`sql/36`), on your own rows (admin+ any).
- Delete: your own, or admin+.
- Kinds raised by the database: `order_new`, `order_ready`, `order_cancelled`, `inquiry_new`, `message_new`, `attendance_correction`, `staff_pending`, `table_signal` (`sql/10`); `void_request`, `void_request_approved`, `void_request_denied` (`sql/15b`), `void_request_cancelled` (`sql/17`); `low_stock` (`sql/28`); `attendance` for a flagged clock-in (`sql/33`).
- Pruning: `notifications_prune()` deletes read rows older than 60 days and unread rows older than 180. It is not callable from the app; no schedule for it was found in the repo.
- Realtime: yes.

**`read_receipts`** (`sql/36`)
- Purpose: per-person read and dismissed marks for shared rows (branch notifications and broadcast messages), so one person reading a branch notice no longer marks it read for everybody.
- Key columns: `kind` (notification, message), `item_id`, `user_id`, `read_at`, `dismissed_at`.
- RLS: your own rows only.

The bell (`sql/46`): `my_notifications` and `my_unread_counts` list only your own personal rows plus shared branch rows. Before `sql/46`, an admin's bell also listed other people's personal notifications (readable by policy), which `mark_read` cannot mark, so they came back after every refresh. The table policy itself was not changed: admin screens can still read all notifications directly.

#### 3.4.13 Inquiries

**`inquiries`** (`sql/01`, guard `sql/29`)
- Key columns: `inquiry_type` (events, catering, concession, general, tasting), `status` (pending, in_progress, resolved, closed), contact fields, `organization`, `message`, `event_date`, `expected_pax`, `assigned_to`, `branch_id`, `resolved_at`, `resolution_notes`.
- Insert: anyone, name and message required. Anon may fill only `id, inquiry_type, branch_id, contact_name, contact_phone, contact_email, organization, message, event_date, expected_pax`.
- Read: supervisor+. Update: manager+.
- Triggers: `trg_inquiry_guard` (before insert, `sql/29`): for anon, 5 per 30 minutes per connection, status forced to pending, assignment and resolution cleared; for everyone, text trimmed and capped (name 80, phone 20, email 120, organisation 120, message 3,000), pax 1–5,000. `trg_inquiries_notify_new` notifies managers. `trg_inquiries_touch`.
- Realtime: yes.

#### 3.4.14 Inventory and stock variance

**`suppliers`** (`sql/21`): name, contact, phone, email, address, notes, active; `branch_id` may be null (shared). Read: `inventory.view` (own branch or shared). Write: `inventory.manage`.

**`ingredients`** (`sql/21`)
- Key columns: `name` (unique per branch), `name_tagalog`, `category`, `unit`, `current_stock` (derived, never typed), `reorder_level`, `last_unit_cost`, `avg_unit_cost`, `default_supplier_id`, `is_active`.
- Read: `inventory.view` in the branch. Write: `inventory.manage` in the branch.
- Triggers: `trg_ingredients_touch`; `trg_ingredients_low_stock` (`sql/28`): a `low_stock` notification when stock crosses down through the reorder level (crossing only, not every later movement).

**`stock_movements`** (`sql/21`)
- Purpose: the stock ledger. `quantity` is always positive; `movement_type` decides the sign (`private.stock_direction`): `delivery_in` and `adjust_up` add; `usage`, `wastage`, `adjust_down`, `return_out` remove.
- Key columns: `ingredient_id`, `branch_id`, `movement_type`, `quantity`, `unit_cost`, `total_cost`, `supplier_id`, `reference` (DR/invoice number), `occurred_at`, `recorded_by`, `notes`.
- Read: `inventory.view` in the branch. Insert: `delivery_in`/`usage` need `inventory.receive`; the other four need `inventory.adjust`. Delete: `inventory.manage`. No update grant.
- Triggers: `trg_stock_cost` (before insert/update: fills unit cost or line total from the other); `trg_stock_level` (after insert/delete: moves `ingredients.current_stock`, and on deliveries updates last and average cost).

Variance (`inventory_variance`, `sql/28`) is movement-based, not recipe-based: there is no recipe table. `found_short` (stock a count found missing) is the leakage figure.

#### 3.4.15 Payroll and finance

**`staff_compensation`** (`sql/21`): pay history. `pay_type` (monthly, daily, hourly), `rate`, `allowance`, `effective_from`, `effective_to`, `notes`. Read: your own rows, or `payroll.view`. Write: `payroll.edit` (CEO tier).

**`operating_expenses`** (`sql/21`): `category` (rent, utilities, gas_fuel, supplies, transport, marketing, repairs, permits, equipment, other), `label`, `amount`, `incurred_on`, `supplier_id`, `reference`, `notes`, `recorded_by`. Read: `finance.view` in the branch. Insert/update: `expenses.record`. Delete: `finance.edit`.

**`finance_settings`** (`sql/21`): one row per branch: `cogs_method` (actual, percent_of_sales; default percent_of_sales), `cogs_percent` (default 35), `include_wastage_in_cogs`. Read: `finance.view`. Write: `finance.edit`.

**`payroll_runs`** (`sql/25`): `branch_id`, `period_start`, `period_end`, `status` (draft, approved, paid, reversed), `payment_method`, `notes`, who created/approved/paid and when. Read: `payroll.view` in the branch (or `settings.manage`). Update: `payroll.run`. Delete: `payroll.run`, drafts only. Insert only via `build_payroll_run`. No audit trigger on the table itself (the functions write audit rows).

**`payroll_items`** (`sql/25`): frozen lines: `staff_name`, `pay_type`, `rate`, `allowance`, `days_worked`, `hours_worked`, `gross`, `deductions`, `net`, `note`. Read: your own line, or `payroll.view`. Update: `payroll.run`. Trigger `trg_payroll_items_lock`: no insert, update or delete once the run is paid or reversed (a paid run therefore cannot be deleted even by cascade).

#### 3.4.16 BIR invoices

**`orders.invoice_no` / `invoice_at` / `invoice_by`** (`sql/43`): the booklet invoice number written for that order. Only `record_order_invoice` writes them.

**`bir_day_invoices`** (`sql/43`): `branch_id`, `business_date`, `invoice_no` (unique per branch and date), `amount`, `recorded_by`. Read: `payments.take` or `finance.view`. Written only by `record_day_invoice`.

Rules (`invoice_day_summary`): if `site_settings.bir.vat_registered` is yes/true/y/oo, every paid sale needs its own invoice. Otherwise only sales over ₱500 (`private.bir_threshold`, RR 7-2024 as amended by RR 11-2024, per the file header) need their own; the rest go on one end-of-day invoice. A blank setting is treated as not VAT-registered and flagged on screen.

#### 3.4.17 Stamp cards (loyalty)

**`loyalty_cards`** (`sql/34`): `phone_hash` (salted SHA-256 of the normalised +63 number, unique), `phone_last4`. The phone number itself is never stored.

**`loyalty_devices`**: devices that may show a card: `card_id`, `secret_hash` (hashed device secret), `last_seen_at`, `revoked_at`.

**`loyalty_ledger`**: `card_id`, `order_id`, `kind` (stamp, reversal, redeem, adjust), `delta`, `note`, `created_by`, `expires_at`. Unique per order and kind (one stamp per order). Audited on insert.

**`private.loyalty_secret`** (one row, generated once) and **`private.loyalty_used_codes`** (each 30-second code works once): not reachable from the API.

- Read of the three public tables: `rewards.redeem` or `rewards.manage`. No browser writes at all.
- The only way a stamp appears: `trg_order_stamp` when an order becomes `paid` (which only real payments can cause), rewards are enabled, the total is at least `rewards.min_order` and the order has a phone. A refund (`refunded`) or a cancellation writes a reversal.
- Settings (`site_settings`): `rewards.enabled` (seeded false; HANDOFF says off on production as of Oct 22), `rewards.min_order` (300), `rewards.stamps_needed` (10), `rewards.reward_text`, `rewards.card_days` (365, stamp expiry).

#### 3.4.18 Audit log and archive

**`audit_log`** (`sql/01`)
- Key columns: `actor_id`, `actor_role`, `action`, `entity_type`, `entity_id`, `before_state`, `after_state`, `metadata`, `ip_address`, `user_agent`, `created_at`.
- Read: manager+ (`sql/07`). Insert: as yourself, and `actor_role` must be your true role or empty (`sql/15b`). No update or delete policy; truncate revoked (`sql/15b`, `sql/17`).
- Written by: every money function, the order triggers, `audit_row` on many tables, the access triggers, and advisory client-side `logAudit` calls (HANDOFF: the 18 client-written actions are advisory only).

**`audit_log_archive`** (`sql/11`): same shape plus `archived_at`. Read: manager+.

**`audit_daily_summary`** (`sql/11`): rows of day × branch × action × role → count. Read: manager+ for your branch (admin+ all) (`sql/15b`).

**`v_audit_log_all`**: hot + archive in one view, runs with the caller's rights (`sql/12`).

Archiving: `audit_log_archive_old(days)` (manager+, minimum 7 days) rolls up counts, copies rows to the archive and deletes them from the hot table. The portal calls it (two call sites); the file comments suggest a daily cron, but no schedule was found in the repo.

#### 3.4.19 Website settings and content

**`site_settings`** (`sql/30`): key (lowercase, dots, underscores) → JSON value. **Public: never store secrets here.** Keys seeded in the repo: `contact.phone`, `contact.email`, `contact.address`, `contact.landmark`, `contact.map_url`, `contact.facebook`, `contact.instagram`, `contact.parking`, `hours.text`, `legal.sec_no`, `legal.tin`, `legal.company` (`sql/30`); `hr.uniform_checklist`, `hr.photo_retention_days` (`sql/33`); `rewards.*` (`sql/34`); `bir.vat_registered` (`sql/43`).
- Read: anyone. Write: `site.edit`; keys starting `rewards.` additionally need `rewards.manage` (trigger `trg_rewards_settings_guard` and policy `site_settings_rewards_write`, `sql/34`).
- Triggers: `trg_site_settings_stamp` (who/when), audit.

**`faqs`**, **`testimonials`**, **`event_packages`** (`sql/30`)
- FAQs and event packages: anyone reads published rows; `site.edit` reads drafts and writes. Seeded FAQs whose answers only the restaurant knows are unpublished with "[Fill in …]".
- Testimonials: not readable by anon at all; the public gets `public_testimonials()` (no consent fields). A testimonial cannot be published without `consent_on`.
- Event packages cannot be published without a `from_price`.
- All audited and touch-stamped.

#### 3.4.20 Rate limiting

**`private.rate_hits`** (`sql/29`): `bucket`, `ip`, `at`. `private.rate_limit(bucket, max, window)` counts hits from the caller's IP (Cloudflare's `cf-connecting-ip`, else the right-most `x-forwarded-for`) and raises `too_many_requests` (code P0429) over the limit. No IP (SQL editor, triggers, tests) means no limit. About 2% of calls also delete hits older than a day.

| Bucket | Limit | Used by |
|---|---|---|
| `submit_order` | 20 per 10 min | `submit_order` for anonymous callers (staff are not limited) |
| `track_order` | 120 per 10 min | `track_order` |
| `track_delivery` | 60 per 10 min | `track_delivery` |
| `signal` | 30 per 10 min | `signal_call_staff`, `signal_bill_request` (plus the 90-second per-table cooldown) |
| `inquiry` | 5 per 30 min | anonymous inquiries |
| `loyalty_claim` | 10 per 30 min | `claim_stamp_card` |
| `loyalty_view` | 120 per 10 min | `my_stamp_card` |
| `loyalty_code` | 240 per 10 min | `stamp_card_code` |

#### 3.4.21 Guest memory

**`customer_devices`** (`sql/27`): one row per guest browser (`device_id`, a random value the browser stores for itself). `order_count`, `lifetime_spend`, `last_order_at`, `last_name`, `last_phone`, `known_names` (every name used), staff judgement (`no_show_count`, `is_flagged`, `flag_reason`, `flagged_by`, `flagged_at`, `staff_note`). Read: `orders.view`. Update: `orders.manage`. Anon: none.

**`customer_device_items`** (`sql/27`): per device and dish name: `times_ordered`, `total_qty`, `last_ordered_at`. Read: `orders.view`.

Filled by `private.remember_device`, called from `submit_order` for guests only (not for staff orders since `sql/32`). Spend is counted per batch, so a shared table bill does not credit one phone with everyone's food. Clearing the browser makes a new guest.

#### 3.4.22 Backups

No backup tables exist in the database. Backups are taken outside it: `ops/backup/` (`backup.ps1`, `install.ps1`, `set-password.ps1`) runs a nightly encrypted `pg_dump` on the headless PC at 03:00, keeps 30 dumps, and was restore-tested on Oct 20, 2026 (`HANDOFF.md`, "Backups"). Not included in the dumps: uploaded photo files, Edge Function code (in the repo) and vault secrets.

#### 3.4.23 Realtime

Tables published to Supabase Realtime: `orders`, `order_items`, `inquiries` (`sql/01`); `restaurant_tables` (`sql/04`); `attendance`, `messages` (`sql/09`); `notifications` (`sql/10`); `void_requests` (`sql/15b`); `payments` (`sql/31`); `menu_items` (`sql/32`). Realtime respects the same RLS.

---

### 3.5 Every function the apps call

Function names the apps call were taken from every `rpc('…')` in the app code (91 names). "Who may call" is the grant plus the check inside the function. All functions below are SECURITY DEFINER with `search_path = ''` unless noted. "Branch-checked" means a caller below admin can act only on their own branch's rows.

#### 3.5.1 Ordering

**`submit_order`** (final `sql/41`). Grant: anon and authenticated. The one door for orders: website, QR menu and counter.

Parameters: branch, order type, items (JSON array of `{menu_item_id, quantity, pax_size, modifiers[], notes}`), table, customer name, phone, notes, payment method (what the guest picked; it is not a payment), delivery address, scheduled time, device id, join-table-bill flag, source, delivery zone, client key.

Checks, in order:
1. Caller type. Anonymous: rate limit `submit_order` 20/10 min. Staff: must hold `pos.use` or `orders.manage`, are not rate-limited, and must order for their own branch (admin+ any).
2. Source: web, qr, pos or phone; a guest cannot claim pos or phone.
3. At least 1 and at most 40 lines; type dine_in/pickup/delivery; delivery needs an address; branch must exist and be active.
4. **Idempotency.** If `p_client_key` is sent it must match `^[A-Za-z0-9-]{16,64}$`. If an order in this branch already has that key, or lines in this branch carry it, the function returns that original order and writes nothing, before any other validation (so a dish that sold out in between does not turn a retry into an error).
5. Table must belong to the branch and be active. Scheduled time between 5 minutes ago and 60 days ahead.
6. **Server-side pricing, every line, before anything is written.** The dish must exist (`unknown_item`) and be available (`item_sold_out`); quantity 1–50; size "2-3" or "2-3 pax" must be a key of `pax_options` and gives that price, no size gives `menu_items.price`; modifiers must be linked to that dish, active and available, at most 20, and each group's min/max must be met; modifier price deltas are added; a negative line price is floored at 0. The browser's `unit_price` and `name` are ignored: the name comes from the menu.
7. Delivery: if the branch has active zones, a zone of that branch is required, its minimum order applies, and its fee goes on the order.
8. **Table bill join.** Dine-in with a table and join flag: lock (`for update`) the oldest open, unpaid dine-in order on that table and append to it. If a line with the same client key is already on it (two copies of one round racing), return that.
9. Otherwise insert a new order. A unique-key clash on `client_key` returns the order that won (or `client_key_in_use` if it belongs to another branch). Delivery orders get a `deliveries` row.
10. Insert the lines (totals recompute by trigger), remember the guest's device (guests only), and return `{id, order_number, track_token, joined_existing, device_flagged, total, subtotal, delivery_fee}`.

Text caps: name 60, phone digits/+ 16, notes 500 (2,000 when appended), address 300, line notes 200. A later guest's note is appended, not overwritten.

**`track_order(order_number, token)`** (`sql/29`). Anon and authenticated; 120/10 min. Without the right `track_token`: progress only (status, type, payment status, times, table number, item names and quantities, voided flags). With it: also totals, customer name, notes, prices and guest names.

**`track_delivery(order_number, token)`** (`sql/38`). Anon; 60/10 min; needs the token. Status, courier, rider's first name, tracking link, zone, ETA, fee, times.

**`addon_suggestions(exclude, limit)`** (`sql/28`). Anon and staff. Available add-on dishes, up to 12.

**`my_guest_profile(device)`** (`sql/29`). Anon. "Welcome back": first name, visit count, top 3 dishes. No phone, flags or spend.

**`signal_call_staff(table)`**, **`signal_bill_request(table, method, total)`** (`sql/29`). Anon. 30/10 min per connection plus a 90-second cooldown per table (returns false inside the cooldown). Bill total must be 0–1,000,000; the method text is stripped to letters, spaces, `_`, `-` and capped at 20.

**`ack_call_staff(table)`**, **`ack_bill_request(table)`** (`sql/17`). Staff at dining+ or the floor screen; branch-checked. Clear the signal.

**`advance_order_status(order, status, source)`** (`sql/26`). `orders.manage` or `kds.advance`; branch-checked (or `settings.manage`). Refuses unknown status, closed orders, and moving to completed/cancelled without `orders.cancel`. Stamps confirmed/ready/served times and records the screen (`portal_kds`, `portal_orders`, `kitchen_screen`, `floor_panel`) in the audit row.

**`table_bill(table)`** (`sql/24`), **`order_bill_breakdown(order)`** (`sql/28`). `orders.view`. The open bill grouped by phone.

**`split_order_by_device(order, device)`** (`sql/24`). `orders.manage`. Moves one phone's open lines to a new order. Refuses closed or paid orders, a phone with no lines, and a split that would empty the original. Audited `order.split`. Not branch-checked in code.

**`set_item_available(item, available, reason)`** (`sql/32`). `menu.86` or `menu.edit`. The 86 switch; audited `menu.86` / `menu.restock`.

#### 3.5.2 Voids

| Function | Who may call | What it does and checks | File |
|---|---|---|---|
| `void_order_item(item, reason)` | manager+ (supervisor excluded on purpose) | Reason ≥ 3 chars; not already voided; branch-checked; order not completed/cancelled. Sets `voided_at/by/reason`; totals recompute; audit `order_item.void`. | `sql/11` |
| `unvoid_order_item(item)` | manager+ | Branch-checked; refuses closed orders (since 17). Audit `order_item.unvoid`. | `sql/17` |
| `request_void(order, item or null, reason)` | any **active** staff account, screens included | Reason ≥ 3; own branch (admin any); order not closed; no duplicate pending request; item belongs to the order and is not voided. Notifies every active manager+ of the branch; audit `void_request.create`. | `sql/15b` |
| `approve_void_request(request, note)` | manager+ | Request pending; branch-checked; order not closed. Item scope: calls `void_order_item`. Order scope: voids every remaining line, marks other pending requests on that order approved, then cancels the order. Notifies the requester; audit `void_request.approve`. | `sql/15b` |
| `deny_void_request(request, note)` | manager+ | Pending; branch-checked. Notifies requester; audit `void_request.deny`. | `sql/15b` |
| `cancel_void_request(request)` | the requester, or manager+ in the branch | Pending only. Audit `void_request.cancel`; notifies the requester if a manager withdrew it. | `sql/17` |
| `pending_void_request_count()` | signed in | Count of pending requests visible to a manager (0 for others). | `sql/15b` |

#### 3.5.3 Payments, refunds and settlement

**`private.settle_order(order)`** (final `sql/37b`, not callable from the app). The only writer of `orders.payment_status` and `payment_method`. It adds up **completed** payment rows and completed refund rows:
- money came in and all of it went back out → `refunded`
- total > 0 and payments − refunds ≥ total → `paid`
- total = 0 and something was paid and nothing refunded → `paid`
- anything else → `pending`

The method that brought in the most money names the order. It sets a transaction-local flag `tpn.settle` so the order guard lets the write through.

**`private.amount_due(order)`**: total − (completed payments − completed refunds), never below 0.

| Function | Who may call | What it does and checks | File |
|---|---|---|---|
| `order_payments(order)` | `orders.view` or `payments.take`; branch-checked | Totals, amount due and every payment with how much of it was refunded. | `sql/31` |
| `record_cash_payment(order, tendered, amount?, tip?, drawer?, note?)` | `payments.take`; branch-checked | Order not cancelled; something due; amount (default: all due) > 0 and ≤ due; tip 0–100,000; tendered ≥ amount + tip. Writes a completed cash row with change, attached to the open drawer; settles. | `sql/31` |
| `record_bank_transfer(order, amount, reference, note?)` | `payments.take`; branch-checked | Amount > 0 and ≤ due; reference ≥ 4 chars. Writes a **pending** bank row (not paid yet). | `sql/31` |
| `confirm_bank_transfer(payment, received, note?)` | `payments.confirm`; branch-checked | Bank row still pending. **Second person:** whoever recorded it cannot confirm it unless manager+. Received → completed; not received → failed. Settles. | `sql/31` |
| `record_manual_payment(order, method, reference, amount?, tip?, note?)` | `payments.take`; branch-checked | Method gcash, maya/paymaya, qrph/"qr ph", card or bank; reference ≥ 3 chars; amount ≤ due; tip 0–100,000. Written as **completed at once** (the staff member vouches for it). Settles. | `sql/37b` |
| `orders_amount_due(order_ids[])` | `payments.take` or `orders.view`; each order branch-checked | What each order still owes (up to 50 orders). | `sql/35` |
| `settle_table_cash(order_ids[], tendered, tip?, drawer?, note?)` | `payments.take`; each order branch-checked | Locks every order in a fixed order (no deadlocks), totals what is due, refuses short cash, then writes **one completed cash row per order for exactly what it owed**; tip and change ride on the first row. All or nothing. | `sql/35` |
| `settle_table_manual(order_ids[], method, reference, tip?, note?)` | `payments.take`; branch-checked | Same as above for gcash/maya/qrph/card/bank, reference required. | `sql/37b` |
| `refund_check(payment, amount)` | `payments.refund`; branch-checked | Payment must be a completed payment row. **Cap:** amount ≤ payment amount − refunds already completed or pending against it. Returns what is refundable. | `sql/31` |
| `refund_payment(payment, amount, reason)` | `payments.refund` (through `refund_check`) | Reason ≥ 3 chars; refuses HitPay payments (they go through the HitPay refund flow). Writes a completed refund row; settles (a partial refund reopens the balance). | `sql/31` |
| `set_service_charge(order, percent?, amount?)` | `orders.service_charge`; branch-checked | Refuses paid orders. Percent 0–20 of (subtotal − discount), or a fixed amount 0–subtotal; 0 removes it. Audited `order.service_charge`. | `sql/31` |
| `hitpay_begin(order_number+token or order_id, actor)` | **service_role only** (hitpay-create Edge Function) | Guest proves ownership with the track token; staff path is checked by the Edge Function (`payments.take` via `my_permissions`). Amount is always the amount due, computed here. Reuses a matching open checkout under 50 minutes old, otherwise cancels older open ones and creates a pending HitPay row. | `sql/31` |
| `hitpay_attach(payment, request_id, url)` | service_role | Stores HitPay's request id and checkout link on the pending row. | `sql/31` |
| `hitpay_complete(request_id, status, amount, currency, …)` | service_role (hitpay-webhook, after signature check) | Idempotent: an already-completed row returns `already_completed`. Non-success → failed. **Amount and currency must equal what was asked (PHP)**, otherwise it is noted, audited `payment.hitpay_mismatch` and not accepted. Success → completed; settles. | `sql/31` |
| `hitpay_refund_recorded(payment, amount, reason, actor, ref, payload)` | service_role (hitpay-refund, after `refund_check` with the user's own login) | Writes the completed refund row; settles. | `sql/31` |

#### 3.5.4 Discounts and delivery fees

| Function | Who may call | What it does and checks | File |
|---|---|---|---|
| `apply_discount(order, template, id_ref?, covered_amount?)` | supervisor+ (tier check) | Template exists and is active; ID number ≥ 3 chars when required; order exists, not completed/cancelled, **not paid** (`order_already_paid`); branch-checked; subtotal ≥ template minimum; non-stackable refuses a second discount. Computed on the remaining subtotal (so stacked discounts cannot go past zero), on the covered share if given. `vat_exempt`: remove 12% VAT, then the percentage of the VAT-exclusive amount (both count as the discount; the cap does not apply). `net_of_vat`: percentage of share ÷ 1.12. `gross`: percentage of share. Fixed: the peso value. Cap at `max_discount` (not for vat_exempt), never above the remaining subtotal. Audit `discount.apply`. | `sql/31` |
| `remove_discount(applied, reason?)` | manager+ | Not already removed; order not completed/cancelled; branch-checked. Soft delete; audit `discount.remove`. Does not check whether the order is paid. | `sql/16` |
| `set_delivery_fee(order, zone?, fee?, reason?)` | supervisor+ (tier check); branch-checked | Delivery orders only; refuses paid orders; fee 0–5,000; a typed fee needs a reason. Audit `order.delivery_fee`. | `sql/38` |
| `delivery_assign(order, courier, rider…, url?, cost?, note?)` | `delivery.dispatch`; branch-checked | Courier own/lalamove/grab/other; tracking link must be https; refuses closed orders. | `sql/38` |
| `delivery_update(order, status, reason?)` | `delivery.dispatch` or the assigned rider; branch-checked | waiting/on_the_way/delivered/failed; failed needs a reason; must be assigned first. Moves the order to served/completed. | `sql/38` |

#### 3.5.5 Cash drawer

| Function | Who may call | What it does and checks | File |
|---|---|---|---|
| `open_cash_session(float, register?)` | `cash.drawer` | Needs a branch; float 0–100,000; refuses a second open drawer on the same register. | `sql/32` |
| `cash_move(drawer, cash_in/cash_out, amount, reason)` | `cash.drawer`; branch-checked | Drawer open; amount 0–100,000; reason ≥ 3 chars. | `sql/32` |
| `cash_session_report(drawer)` (X read) | `cash.drawer` or `finance.view`; branch-checked | Float, cash sales, tips, cash refunds, in, out, expected cash, other methods during the shift, movements. | `sql/32` |
| `close_cash_session(drawer, counted, denominations?, notes?)` (Z read) | `cash.drawer`; branch-checked | Drawer open; count ≥ 0. Stores expected, counted and variance permanently; closes. | `sql/32` |
| `my_open_cash_session(register?)` | `cash.drawer` | The id of my branch's open drawer. | `sql/32` |
| `daily_close_report(date?, branch?)` | `finance.view` or `orders.view` | The day in Manila time: gross, discounts, service charge, net, unpaid, collected by method, **received cash**, pending bank, declared methods, cancelled, voided, VAT-exempt sales, top items, already closed. | `sql/31` |
| `record_daily_close(date, counted, notes?, branch?)` | `finance.view` | Expected = received cash. Upserts the day; audit `till.close`. | `sql/31` |
| `list_daily_closes(limit?, branch?)` | `finance.view` | Past closes (up to 365). | `sql/28` |

`daily_close_report`, `record_daily_close`, `list_daily_closes`, `finance_summary`, `expense_breakdown`, `inventory_board`, `inventory_variance`, `invoice_day_summary`, `task_board`, `build_payroll_run` and `record_day_invoice` accept a branch argument and, except `record_day_invoice`, do not check that it is the caller's own branch. With one live branch this has no effect today.

#### 3.5.6 Staff, access, tasks

| Function | Who may call | Notes | File |
|---|---|---|---|
| `my_permissions()` | signed in | Keys I hold. | `sql/19` |
| `access_matrix()` | `roles.view` | Role × key grid with `grantable`. | `sql/19` |
| `staff_directory()` | `staff.view` or `tasks.assign` | Name, role, initials, status for my branch (all with `settings.manage`). Never email, phone or pay. | `sql/22` |
| `task_board(include_done?, branch?)` | signed in | Full board with `tasks.view`; otherwise only tasks I am on. | `sql/22` |
| `set_my_task_state(task, state, note?)` | an assignee of that task | Updates my own state; writes `task_activity`. | `sql/20` |

#### 3.5.7 Attendance

| Function | Who may call | What it does and checks | File |
|---|---|---|---|
| `clock_in_verified(expect_photo?, note?)` | active staff | Refuses a second open shift. Server records time and IP; checks the IP against the branch's trusted networks. Always starts `needs_approval` with reasons; returns the exact photo upload path. Audit `attendance.clock_in`. | `sql/33` |
| `attach_clockin_photo(attendance)` | the person | Within 10 minutes; the file must exist at the issued path. Trusted network + photo + no other reasons → `verified`; else `needs_approval`. | `sql/33` |
| `clock_out_verified()` | the person | Closes the open shift with time and IP. Audit `attendance.clock_out`. | `sql/33` |
| `clockin_review_queue(include_done?, days?)` | `attendance.verify` | Branch (admin all); 1–90 days. | `sql/33` |
| `review_clockin(attendance, approve, uniform?, note?, trust_network?)` | `attendance.verify`; branch-checked | You cannot review your own clock-in unless director+. Flagging needs a note and notifies the person. Optionally trusts the IP. | `sql/33` |
| `trust_current_network(label?)` | `attendance.verify` | Trusts the caller's current IP for their branch. | `sql/33` |
| `my_network_status()` | signed in | Am I on a trusted network; does my branch have any. | `sql/33` |
| `clockin_photos_expired(limit?)`, `mark_clockin_photos_purged(ids[])` | `attendance.verify` | Retention clean-up (minimum 7 days). | `sql/33` |

#### 3.5.8 Payroll, finance and inventory

| Function | Who may call | Notes | File |
|---|---|---|---|
| `build_payroll_run(start, end, branch?)` | `payroll.run` | Snapshots each person's rate (left join, so a missing rate is a ₱0 line with a note) and attendance; includes anyone who clocked in during the period even if since disabled. Monthly = (rate + allowance) ÷ 30.4375 × days in period; daily = (rate + allowance) × days worked; hourly = rate × hours + allowance. Refuses an empty run. Audit `payroll.build`. | `sql/25` |
| `rebuild_payroll_run(run)` | `payroll.run` | Drafts only; recalculates in place keeping the run id. | `sql/25` |
| `set_payroll_status(run, status, method?)` | `payroll.run` | draft → approved → paid → reversed, nothing else. Audit `payroll.<status>`. | `sql/25` |
| `finance_summary(from, to, granularity, branch?)` | `finance.view` | Per day/week/month: gross, discounts, net, orders, cost of goods (measured or estimated, labelled), labour, other expenses, net income. | `sql/21` |
| `expense_breakdown(from, to, branch?)` | `finance.view` | Expenses by category. | `sql/21` |
| `inventory_board(branch?)` | `inventory.view` | Stock, reorder flag, value, supplier, last delivery. | `sql/22` |
| `inventory_variance(from, to, branch?)` | `inventory.view` | Delivered, used, wasted, found short/over, returned, loss values. | `sql/28` |
| `sales_performance_month(month, branch?)` | manager+ (tier) | Monthly report JSON (overview, previous month, daily, top items, categories, order types, hours, payment methods, void reasons). | `sql/14` |
| `audit_daily_counts(month, branch?)` | manager+ (tier) | Daily counts from summary + hot log. | `sql/13` |
| `audit_log_archive_old(days)` | manager+ (tier) | Minimum 7 days. | `sql/17` |

#### 3.5.9 Guests, rewards, invoices, notifications, website

| Function | Who may call | Notes | File |
|---|---|---|---|
| `guest_profile(device, phone?)` | `orders.view` | Full staff view incl. phone, flags, no-shows, usuals; falls back to phone lookup. | `sql/27` |
| `guest_list(search?, flagged_only?, limit?)` | `orders.view` | Up to 500. | `sql/27` |
| `flag_guest_device`, `unflag_guest_device` | `orders.manage` | Audited `guest.flag` / `guest.unflag`. | `sql/27` |
| `set_guest_note` | `orders.manage` | Not audited. | `sql/27` |
| `claim_stamp_card(phone, order_number, token)` | anon; 10/30 min | Needs the private token of an order whose phone matches. Returns a device secret (only the hash is stored). | `sql/34` |
| `my_stamp_card(card, secret)` | anon; 120/10 min | Balance, rules, last 20 entries. | `sql/34` |
| `stamp_card_code(card, secret)` | anon; 240/10 min | 6-digit code that changes every 30 seconds. | `sql/34` |
| `redeem_stamp_reward(card, code, note?)` | `rewards.redeem` | Accepts the current or previous code, once each; needs enough unexpired stamps; writes a `redeem` entry. | `sql/34` |
| `stamp_card_lookup(phone)` | `rewards.redeem` or `rewards.manage` | Balance and history by phone. | `sql/34` |
| `revoke_stamp_devices(card)` | `rewards.manage` | Logs every device out of the card. | `sql/34` |
| `record_order_invoice(order, invoice_no)` | `payments.take`; own branch unless admin/director/ceo | Up to 40 chars; blank clears. Audit `invoice.record`. | `sql/43` |
| `record_day_invoice(date, invoice_no, amount, branch?)` | `payments.take` or `finance.view`; own branch unless admin+ | Amount > 0. Audit `invoice.day`. | `sql/43` |
| `invoice_day_summary(date?, branch?)` | `payments.take` or `finance.view` | Which paid sales still need an invoice; small-sales total; day invoices. | `sql/43` |
| `my_notifications(limit?, unread_only?)` | signed in (runs as caller) | Own + shared, minus dismissed. | `sql/46` |
| `my_unread_counts()` | signed in (runs as caller) | Unread notifications and messages. | `sql/46` |
| `mark_read(kind, ids?)` | signed in (runs as caller) | Own rows get `read_at`; shared rows get a receipt. Null ids = all. | `sql/36` |
| `dismiss_notification(id)` | signed in (runs as caller) | Own row: deleted. Shared row: hidden for me only. | `sql/36` |
| `public_testimonials()` | anyone | Published, consented quotes only (max 12). | `sql/30` |

Defined but not called by any app file found: `order_prep_target` (`sql/28`), `notifications_prune` (`sql/10`, closed to the app).

---

### 3.6 The hard money and security rules

| # | Rule | How it is enforced | File |
|---|---|---|---|
| 1 | **One ordering door.** Every order and every line is created by `submit_order`. | Anon has no insert/select on orders or lines (`sql/29`); staff have no insert on `order_items` (`sql/32`); no update/delete on lines for anyone (`sql/15b`). | `sql/29`, `32`, `15b`, `41` |
| 2 | **Server-side pricing.** The browser's price and name are ignored. | `submit_order` reads `menu_items.price` / `pax_options` and modifier `price_delta`; refuses unknown, sold-out, bad size, bad modifier, quantity outside 1–50. | `sql/29`, `29c`, `32`, `41` |
| 3 | **A retry never places a second order.** | `client_key` unique index and early return in `submit_order`. | `sql/41` |
| 4 | **Nobody edits totals.** `subtotal` and `total` are always sum of live lines − discount + service charge + delivery fee, never below 0. | `private.recompute_order_totals` is the only writer (flag `tpn.recompute`); `trg_guard_order_update` raises `totals_are_derived` otherwise, for every caller including the SQL API. | `sql/11`, `17`, `31`, `38` |
| 5 | **No negative lines.** | `trg_order_items_nonneg` on insert. | `sql/15b` |
| 6 | **Payment state is derived only from payments.** Not even a manager can type "paid". | `trg_guard_order_update` raises `payment_state_is_derived` unless `private.settle_order` is running (flag `tpn.settle`). | `sql/31`, `37b` |
| 7 | **Every peso in or out is a ledger row**, written only by functions. | No insert/update/delete grant on `payments`; audit trigger on every insert/update. | `sql/31` |
| 8 | **A bank transfer is not money until a second person confirms it.** | `record_bank_transfer` writes pending; `confirm_bank_transfer` needs `payments.confirm` and refuses the recorder unless manager+. (Note: `record_manual_payment` with method `bank` skips this; see 3.9.4.) | `sql/31` |
| 9 | **HitPay is paid only when HitPay says so, for the right amount.** | Only the webhook (service role, signature checked in the Edge Function) completes it; amount and PHP must match; retries are harmless. The customer's return to the site changes nothing. | `sql/31` |
| 10 | **Refunds are capped and need a reason.** | `refund_check`: refund ≤ that payment − its completed and pending refunds; manager tier by default (`payments.refund`); reason ≥ 3 chars. | `sql/31` |
| 11 | **No discount, service charge or delivery-fee change on a paid bill.** | `apply_discount`, `set_service_charge`, `set_delivery_fee` raise `order_already_paid`. (Direct column updates by supervisors and `remove_discount` are not covered; see 3.9.5.) | `sql/31`, `38` |
| 12 | **Discounts are supervisor+ and audited.** | `apply_discount` tier check; `trg_guard_order_update` refuses discount/service-charge changes below supervisor; audit rows inside the functions. | `sql/15b`, `16`, `31` |
| 13 | **Statutory discounts are VAT-correct and cannot be deleted.** | `vat_exempt` computation; delete policy excludes templates with `legal_law`. | `sql/31`, `16` |
| 14 | **Voids are manager+; everyone else can only ask.** | `void_order_item` / `approve_void_request` manager tier; `request_void` for staff and screens; no direct line updates. | `sql/11`, `15b` |
| 15 | **Only managers cancel an order.** | `trg_guard_order_update` (`cancel_requires_manager`); `advance_order_status` needs `orders.cancel`. | `sql/15b`, `26` |
| 16 | **Closed orders cannot be voided, un-voided or discounted.** | Status checks in `void_order_item`, `unvoid_order_item`, `apply_discount`, `remove_discount`, `approve_void_request`. | `sql/11`, `17`, `16`, `31` |
| 17 | **Screens can only move tickets along.** | `trg_guard_order_update` jsonb comparison; cannot complete/cancel; cannot create orders; no permissions beyond the five screen keys. | `sql/15b`, `17`, `19` |
| 18 | **Delivery fee and BIR invoice numbers change only through their functions.** | `trg_guard_delivery_fee`, `trg_guard_invoice_no`. | `sql/38`, `43` |
| 19 | **Cash belongs to a drawer; the drawer is counted.** | `trg_payment_cash_session`; Z read stores variance permanently; one open drawer per register. | `sql/32` |
| 20 | **A paid payroll run is frozen.** | `trg_payroll_items_lock`; drafts only can be deleted. | `sql/25` |
| 21 | **Stamps come only from real payments.** | `trg_order_stamp` on `paid`; reversal on refund/cancel; no browser writes; rotating one-time redeem codes. | `sql/34` |
| 22 | **A disabled or pending account is no account.** | `my_role`, `my_branch`, `can` return nothing for non-active staff. | `sql/29` |
| 23 | **Nobody climbs the ladder on their own.** | `guard_staff_rank`, `guard_override_rank`. | `sql/44` |
| 24 | **Audit rows cannot be forged or erased from the app.** | Insert as yourself with your true role; no update/delete policy; truncate revoked; archive needs manager+ and ≥ 7 days. | `sql/03`, `15b`, `17` |
| 25 | **Customers' personal data stays private.** | No anon read on orders; `track_order` shows details only with the private token; device ids validated; phone stored only hashed for loyalty. | `sql/29`, `34` |
| 26 | **Anonymous endpoints are rate-limited.** | `private.rate_limit` buckets (3.4.20). | `sql/29`, `34`, `38` |
| 27 | **Clock-in time and place are set by the server.** | No direct insert/update by staff; IP and time recorded in the function. | `sql/33` |
| 28 | **No TRUNCATE from browsers.** | Revoked on every public table and for future tables. | `sql/17` |

---

### 3.7 The test suite

#### 3.7.1 How it works

- Location: `tests/db/`. Dependency: `@electric-sql/pglite` 0.3.7 (Postgres compiled to run inside Node, in memory). No real database is touched.
- Run: `cd tests/db && npm install` (once), then `node run.mjs` for everything or `node run.mjs t_31_payments.sql` for one file. `VERBOSE=1` prints each migration and every passing check.
- What `run.mjs` does:
  1. Loads `supabase-stub.sql`: creates the `anon`, `authenticated` and `service_role` roles, `auth.users`, `auth.uid()` (read from the setting `request.jwt.claim.sub`), `storage.buckets` and `storage.objects`, the `supabase_realtime` publication, Supabase's default grants, and the shared `public.t_results` table.
  2. Replays every `sql/*.sql` in name order. After `17-…` it also applies `prod-drift-after-17.sql`. The first failing migration stops the run.
  3. Splits each `t_*.sql` into blocks at blank lines and runs them in order. A block whose last line starts `select name, ok` prints PASS/FAIL per row, then `t_results` is emptied. Any error is a failure.
  4. Exit code 0 only if every migration applied and every check passed.
- Tests pretend to be a user by setting `request.jwt.claim.sub` to a staff id and `set local role authenticated` (or `anon`), and pretend to be a client IP by setting `request.headers` with `cf-connecting-ip`.
- Counts reported over time: 82 (rev 6), 123 (`GO-LIVE.md`), 141, 153, and on Oct 22 "159 + 4 new passed locally" (`HANDOFF.md` rev 36).

#### 3.7.2 What each file covers

| File | Covers |
|---|---|
| `t_29_security.sql` | Server price used, not the browser's ₱0; name from the menu; tracking token returned; size price; unknown item, quantity 500 and sold-out refused; script-like device id dropped; anon cannot select orders or insert lines; `track_order` without token hides the name, with token shows it; a disabled manager has no permissions, sees only their own staff row and no orders, while an active manager sees orders; anon cannot set an inquiry's status; rate limit trips within 25 orders; "4-6 pax" accepted, no size = menu price, made-up size refused. |
| `t_31_payments.sql` | A manager cannot type "paid"; part cash with change; still pending with the right balance; short cash refused; bank transfer stays pending; cashier cannot confirm; supervisor confirms and the order is paid; method named by the largest payment; supervisor cannot refund; refund above the payment refused; partial refund reopens the balance; anon cannot call `hitpay_begin`; wrong token refused; HitPay amount = amount due; wrong amount not accepted; webhook settles; webhook retry harmless; Senior share at a table of 4 (₱280 share → ₱30 VAT + ₱50 = ₱80 off, total ₱1,040); cashier cannot set service charge; 10% service charge = ₱50, total ₱550. |
| `t_32_pos.sql` | Modifier priced by the server (150 + 25, × 2 = 350); required modifier group enforced; unlinked modifier refused; staff cannot insert lines directly; one open drawer per register; counter order source = pos; cash attaches to the open drawer; X read expected cash (1000 + 150 − 50 + 300); Z read variance −10; drawer closed; kitchen can 86 and a guest then cannot order it; dining cashier cannot 86. |
| `t_33_clockin.sql` | Manager trusts the shop network; trusted + photo = verified; server records the IP; crew cannot back-date (0 rows updated); crew cannot read photos; no double clock-in; clock-out recorded; cannot upload to another person's path; untrusted + no photo = needs approval with both reasons; flagging needs a note; queue shows it; approve + trust the new IP; disabled account cannot clock in; crew cannot see the review queue. |
| `t_34_stamps.sql` | Only paid orders over the minimum stamp; one card per phone (two spellings of one number); no double stamp per order; anon cannot read the ledger or add stamps; claim without token refused; claim with another phone refused; card shows 2 stamps; wrong device secret refused; crew cannot redeem; wrong code refused; redeem spends stamps; a code works once; refund reverses the stamp. |
| `t_35_table_settle.sql` | Table due lists both orders (₱750); short cash refused and nothing written; ₱1,000 with ₱50 tip gives ₱200 change and pays both; one payment row per order with exact amounts; a settled table cannot be paid twice; a login with no staff row cannot settle; anon cannot read amounts due. |
| `t_36_read_receipts.sql` | Crew can mark a branch notice read; receipts written; other crew still unread; crew cannot edit a manager's broadcast; dismiss hides it only for me. |
| `t_37_manual_delivery.sql` | GCash needs a reference; GCash payment settles the order; unknown method refused; card settles via the table path; delivery needs a zone; delivery minimum enforced; fee on the bill (₱400 + ₱50); fee cannot be edited directly; supervisor waives the fee; rider marks on the way and the customer sees it with the rider's first name; delivered completes the order; wrong token shows nothing; courier link must be https. |
| `t_41_idempotency.sql` | Retry returns the same order (id, number, token) with the same reply shape and inserts nothing; retry after sell-out still returns the order; no key = separate orders; malformed key refused; keyed order still priced by the server; a QR round joins the table bill and its retry adds nothing (total 490, fee 0); a key from one branch cannot fetch another branch's order; grants (anon can call the new signature, old signature dropped, reply helper private, exactly one `submit_order`). |
| `t_42_silog_menu.sql` | Chicksilog on the menu; no Chicken Silog left; Tocilog on the menu once at ₱115. |
| `t_43_bir_invoices.sql` | Non-VAT: only the ₱600 sale is missing; small sales add up (₱200, 2); blank VAT setting flagged; direct update of `invoice_no` refused; cashier records "0451" (trimmed) and it is audited; recorded sale no longer missing; screen account cannot record; day invoice listed; VAT-registered: every sale without its own number is missing; blank clears the number; anon cannot record, read the summary or read day invoices. |
| `t_44_staff_rank.sql` | Admin cannot make themselves CEO, demote the CEO, disable the director, or give a role above their own; admin can still promote crew to supervisor and edit their own name; admin cannot grant themselves a permission or set overrides on the director; admin can set overrides on crew; director cannot delete the CEO; the CEO can change anyone; the service role / SQL editor is not blocked. |
| `t_45_printer_perm.sql` | `printer.manage` default: dining, kitchen and both screens not allowed; manager and admin allowed. |
| `t_46_my_notifications.sql` | Admin's bell shows own + shared; skips the CEO's personal one; "mark all read" leaves nothing unread; the CEO's notification is still unread for the CEO. |

No test file exists for: void requests, discounts other than the Senior share, tasks, inventory, payroll, guest memory, site content, access control beyond `sql/44`/`45`, or the audit archive. (Not found in `tests/db`.)

#### 3.7.3 The "live, rolled back" method (Oct 22, 2026)

Recorded in `HANDOFF.md`, rev 36 ("How it was tested", Oct 22, 18:51–19:15 Manila):

- Each `tests/db/t_*.sql` file was sent to the **production** database as **one single call**. The call ended by **raising an error that carried its results**. Because the whole call was one transaction and it ended in an error, Postgres undid everything the test had written. The results were read from the error message.
- The wrapper script is named as `scratchpad/tools/wrap.py`. **It is not in the repo** (not found in code).
- Result: 140 checks passed, 0 failed. 12 checks could not run this way: values set with `set_config(…, true)` leak between blocks when a whole file is one transaction, and one live cash drawer was already open (which collides with "one open drawer per register").
- **Side effect that a rollback cannot undo:** `order_number_seq` still advanced, because Postgres sequences are never rolled back. That day's order numbers jumped from 0054 to 0117. Invoice numbers were untouched.
- Alongside it, a hands-on live flow used orders named `TEST — Claude`; they were deleted at 19:18 with their items, void requests, payments, refund, notifications and read receipts. The 56 audit-log rows from the test were kept on purpose as the record that it happened.

---

### 3.8 Known findings

#### 3.8.1 Two simultaneous first orders at one table open two bills
Source: `HANDOFF.md` rev 36, "Found, not fixed". `submit_order` (`sql/41`, and since `sql/29`) joins a table's bill with `select … for update` on the **existing** open order. When there is no open order yet, there is nothing to lock, so two guests submitting at the same instant each insert a new order. HANDOFF calls it harmless today because the floor, the bill print and Close Table add up every open order on the table. Suggested fix in HANDOFF: take `pg_advisory_xact_lock` on the table id inside `submit_order` before looking for the open bill. Not fixed in the repo.

#### 3.8.2 Admins can read every notification by policy
Source: `sql/46` header and `HANDOFF.md` rev 36. `notif_read` (`sql/15b`) lets admin and up read all notifications, including other people's personal ones (a void request sent to the CEO, for example). Since `sql/46`, the bell (`my_notifications`, `my_unread_counts`) shows only your own plus shared rows, which fixed "read notifications come back after a refresh". The policy itself is unchanged, so an admin screen or a direct query can still read everyone's notifications.

---

### 3.9 Further observations from reading the code

These were found while writing this guide by reading the SQL. They are **not** listed in HANDOFF and were **not tested** on a database. Each says what the code does; whether it matters is for the owner to decide.

#### 3.9.1 Staff can still insert an order header directly
`orders_auth_create` (`sql/15b`) and Supabase's default insert grant on `orders` are still in place for signed-in staff (screens excluded). Nothing checks money or payment columns on **insert** (`trg_guard_order_update` runs on update only). A staff account using the API directly could insert an order row with any `total` and `payment_status = 'paid'` and no lines or payments. The app never does this (it uses `submit_order`). `orders_cleanup_empty` would let dining+ delete such an empty row again.

#### 3.9.2 Permission floors can be bypassed through overrides and custom roles
- `staff_permission_overrides` has no floor check: `trg_role_perm_floor` guards only `access_role_permissions`. `t_44_staff_rank.sql` itself grants `menu.86` (floor `kitchen`) to a `dining` account successfully. So someone with `roles.edit` (admin by default) can give a crew member, for example, `payments.refund` or `payroll.view`, and every function that checks `can()` will accept it.
- A custom role's `base_tier` is checked against the keys ticked on it, but not against the creator's tier or the tier of the person it is given to. `sql/44` checks `staff.role`, not the custom role's base tier.
- Functions gated by the tier (`has_role`) are unaffected: voids, discounts, cancelling, service-charge/discount column changes.

#### 3.9.3 Payroll status can be changed outside the state machine
`pr_write` (`sql/25`) lets any `payroll.run` holder update `payroll_runs` directly, including `status`. That bypasses `set_payroll_status` (and its audit row): for example, a paid run could be set back to `draft`, which would then unlock its lines. There is no audit trigger on `payroll_runs`.

#### 3.9.4 `record_manual_payment` with method "bank" skips the second-person confirmation
`private.manual_method` (`sql/37b`) maps `bank` to a manual method, and `record_manual_payment` writes it as completed immediately. `record_bank_transfer` + `confirm_bank_transfer` (`sql/31`) require a second person. Both paths exist.

#### 3.9.5 Changes that can still move a paid bill's total
- A supervisor or higher can set `orders.discount_amount` or `service_charge` with a plain UPDATE. The guard allows supervisor+, the total recomputes, and `trg_audit_order_money` logs `order.money_change`, but the paid-bill, template, ID and cap checks of `apply_discount` / `set_service_charge` are skipped.
- `remove_discount` (`sql/16`) refuses closed orders but not paid ones.
- `void_order_item` refuses closed orders but not paid ones.
In each case `settle_order` is not re-run, so `payment_status` stays as it was until the next payment row.

#### 3.9.6 Permission keys that the database does not enforce, or enforces differently
- `voids.request` and `voids.approve`, `discounts.apply`, `performance.view`, `audit.view`, `inquiries.*`, `tables.manage` and others are UI only (table in 3.3.3).
- `audit.view` floors at admin, but `audit_log` RLS lets manager+ read it.
- `tables.manage` floors at manager, but `restaurant_tables` RLS needs admin+.
- `inquiries.manage` floors at supervisor, but `inquiries` update RLS needs manager+.

#### 3.9.7 Date boundaries
`daily_close_report` and `invoice_day_summary` cut days at Manila midnight. `finance_summary`, `inventory_variance` and `build_payroll_run` compare against plain dates, which Postgres reads in the database's own time zone; if that is UTC (the Supabase default), those days start at 8:00 AM Manila. The order number's date part uses `now()` in the database's time zone too.

#### 3.9.8 Other small points
- `split_order_by_device` (`sql/24`) checks `orders.manage` but not the branch.
- `set_guest_note` writes no audit row (flag/unflag do).
- `notifications_prune` and `audit_log_archive_old` have no schedule in the repo.

---

### 3.10 Where the repo and production differ

Documented in the files themselves:

| Item | Where it exists | Source |
|---|---|---|
| `messages_send` insert policy (manager+) | Production only; no repo file creates it. A database rebuilt from `sql/` has **no** insert policy on `messages`, so sending a message would be refused. | `sql/29` comment |
| `messages_mark_read` update policy | Production only. A rebuild has no update policy on `messages`, so marking a direct message read would update nothing. | `sql/36` comment |
| `attendance_self_write` policy | Production only (dropped by `sql/33` if present). | `sql/33` comment |
| `discount_presets` table and orders columns `discount`, `discount_label`, `discount_preset_id`, `discount_reference`, `discount_applied_by`, `discount_applied_at` | Production only; recreated for tests by `tests/db/prod-drift-after-17.sql`. Unused. | `sql/17` note |
| `sql/06` columns | Were missing on production until `sql/29` re-added them. | `sql/29` header |
| `sql/05` policy | Was not in effect on production (fixed by `sql/18`). | `sql/18` header |
| `sql/40` descriptions | Not yet run on production when written. | `HANDOFF.md` |
| Live migration names | Applied to production under names like `45_printer_permission` and `46_my_notifications_only`. | `HANDOFF.md` |

Supabase dashboard setting that SQL cannot change: "Prevent use of leaked passwords" (Authentication → Providers → Email) must be switched on by hand (`sql/12`). Whether it is on: not found in code.

The Supabase advisor is expected to keep two warnings that are correct: `signal_call_staff` and `signal_bill_request` must stay callable by anyone, because they are the guest's "Call staff" and "Bill" buttons (`sql/12`, `17`, `23`).

---

## Part 4 — Operations, workflows and history

This section explains how the restaurant actually runs on TPN OS from opening to closing, how a change reaches the live system, how the two Android apps are released, how the data is backed up, the rules the two Claude accounts follow, and the full revision history.

**Where the facts come from.** Everything here was read from the `main` branch of `UnoRfl/tpn-os` as cloned at `~/Downloads/tpn-os-study/tpn-os` on Oct 22, 2026 (last commit `4501448`, "HANDOFF Rev 36: test data cleanup record"), from `~/Downloads/tpn-os-study/TPN-OS-PLAYBOOK.md`, from the GitHub releases list of the repo, and from the live Supabase project's migration history and edge function list (read-only). File names are given so a developer can check each claim. Where something could not be found, the text says "not found".

**How to read it.** Each workflow starts with plain steps for the owner and staff. A "Behind the scenes" note follows for developers: the file, the function and the database rule that does the work.

---

### 4.1 Who can do what in the daily workflows

Two layers decide access (README.md "Two layers"; HANDOFF "What migrations 18–22 added"):

- **Staff tier (the lock).** Every account has one of nine tiers, lowest first: `kitchen_display`, `dine_in_display`, `dining`, `kitchen`, `supervisor`, `manager`, `admin`, `director`, `ceo`. The database enforces this. The two `*_display` tiers are shared screen logins, not people.
- **Permissions (what the screens offer).** Named permissions such as `payments.take` each have a minimum tier. The portal's Access Matrix can take a permission away from a role, but it can never give a role more than its tier allows.

The permissions that matter for daily work, with the minimum tier set in the SQL:

| Permission | What it allows | Lowest tier | Defined in |
|---|---|---|---|
| `pos.use` | Ring up orders on the Counter | dining | `sql/32-pos-cash-modifiers.sql` |
| `cash.drawer` | Open/close a cash shift, cash in/out, X read | dining | `sql/32` |
| `payments.take` | Take cash, record GCash/Maya/QR Ph/card/bank, write booklet invoice numbers | dining | `sql/31-payments.sql`, `sql/43` |
| `payments.confirm` | Confirm a bank transfer arrived | supervisor | `sql/31` |
| `payments.refund` | Refund all or part of a payment | manager | `sql/31` |
| `orders.service_charge` | Add or remove a service charge | supervisor | `sql/31` |
| Apply a discount | Senior/PWD/Solo Parent/promos | supervisor (role check) | `sql/31` `apply_discount` |
| Remove a discount | Take a discount off | manager (role check) | `sql/16-discounts.sql` `remove_discount` |
| Approve/deny a void | Void a line | manager (role check) | `sql/15b-void-requests.sql` |
| `menu.86` | Mark a dish sold out / back on | kitchen | `sql/32` |
| `delivery.dispatch` | Assign riders, move deliveries along | dining | `sql/38-delivery.sql` |
| `rewards.redeem` | Give a stamp-card reward | supervisor | `sql/34-stamp-cards.sql` |
| `rewards.manage` | Change stamp-card settings | manager | `sql/34` |
| `attendance.verify` | Clock-in review, trust the restaurant network | manager | `sql/33-clockin-verification.sql` |
| `printer.manage` | Test prints, no-sale drawer, auto-print, kitchen printer settings | manager | `sql/45-printer-permission.sql` |
| `finance.view` | Daily close, finance | manager (per README) | `sql/19` / `sql/28` / `sql/31` |

---

### 4.2 Daily restaurant workflows

#### 4.2.1 Starting a shift: signing in at a station (sign-in = clock-in)

**For staff**
1. Open **TPN Counter** (the iMin at the counter) or **TPN Kitchen** (the kitchen device). Both open on their own sign-in screen.
2. Type **your own email and password**. Nothing is remembered or suggested: no name buttons, no prefilled email, no autocomplete. The owner decided this on Oct 21 because signing in is how each person starts their time.
3. After signing in, a note says "Clocked in at h:mm". If you were already clocked in, it says "You were already clocked in".
4. The top bar shows who is on, for example "Maria · Dining".
5. At shift change, tap **Switch user**. It warns you if your cash drawer shift is still open (close it first, see 4.2.2), clocks you out, signs you out and returns to the sign-in screen.
6. Closing the app without Switch user leaves your attendance shift open. A manager corrects it in Attendance.

**For managers:** station clock-ins have no photo, so each one appears in **Clock-in review** marked "needs approval" (reasons `no_photo`, plus `untrusted_network` / `network_unknown` until the restaurant network is trusted). Approve them there.

**Behind the scenes**
- `modules/signin.js` (`TPN_SIGNIN.show / switchUser / whoLabel`), styles in `tpn-signin.css`. Used by `tpn-dine-in-floor.html` and `tpn-kitchen-station.html` (Rev 30, Rev 31).
- After `TPN.login`, it calls `TPN.clockIn('Signed in at the counter' | '… kitchen')`, which is `clock_in_verified(p_expect_photo false)` from `sql/33`. Switch user calls `TPN.clockOut()`; if that fails it asks before signing out anyway. The flash message is kept in sessionStorage `tpn.station.flash`.
- The old remembered-people lists `tpn.station.recent` and `tpn.counter.recent` are deleted on load (`modules/signin.js` line 39).
- The screen-only accounts `kitchen_display` and `dine_in_display` never clock in. The shared floor-screen account has no Switch user button; the kitchen display account does (so the kitchen device can always hand over).
- The floor screen admits anyone whose role has `floor.view`; the kitchen admits kitchen tier and up, or anyone with `kitchen_station.view` (Rev 28, Rev 31).
- Making a trusted-network station clock-in auto-verified would be a policy change; the HANDOFF leaves it for the owner (Rev 31).

#### 4.2.2 Opening the cash drawer shift

**For staff (Counter tab on the floor screen)**
1. Top right of the Counter shows **Drawer closed** and an **Open shift** button.
2. Tap **Open shift**, type the opening float (quick chips ₱1,000 / ₱2,000 / ₱3,000), tap **Open drawer**.
3. The bar now reads **Drawer open** with a **Drawer ▾** menu: **＋ Cash in**, **－ Cash out / petty cash**, **X read (mid-shift report)**, **Close shift (Z read)**.
4. Cash in and cash out ask for the amount and a reason (chips such as "Change top-up from safe", "Bought ice", "Rider fare", "To safe").
5. Only one drawer can be open per register; trying again says "A drawer is already open on this register."

**Behind the scenes:** `modules/pos.js` (`posOpenShift`, `posCashMove`) → `TPN.openCashSession`, `TPN.cashMove` → `open_cash_session`, `cash_move` in `sql/32` (permission `cash.drawer`). Opening/closing a shift needs the internet (Rev 21).

#### 4.2.3 Counter take-out and delivery order, and taking payment

**For staff**
1. Floor screen → **Counter** tab. Tap dish tiles (photos where the website has one, emoji otherwise). Search with the box or press `/`.
2. Dishes with sizes or add-ons open a small sheet: pick size, add-ons, quantity, a note for the kitchen. Sold-out dishes show "Sold out" and cannot be added.
3. On the ticket, pick **🛍 Take-out**, **🍽 Dine-in** or **🛵 Delivery**. Optional customer name and phone (phone is needed for stamps). Delivery needs an address and, if delivery areas are set up, an area; the area's fee is added.
4. The ticket total says "Final price is checked by the server when you send."
5. Tap **Send to kitchen & take payment**. The kitchen ticket prints (where it prints is the "Kitchen tickets" setting, 4.2.11), and the payment panel opens.
6. In the payment panel:
   - **💵 Cash:** type the amount tendered (quick amounts offered); the change shows big; save. The drawer pops on the iMin. A receipt prints if Auto-print is on.
   - **GCash / Maya / QR Ph / Card / Bank:** show the shop QR or run the card terminal, check the payment on the restaurant phone (never from the guest's screenshot), type the **reference or approval code** (at least 3 characters), optional tip and note, tap **✓ Received**. Bank transfers are recorded as **waiting** until a supervisor confirms them.
7. The ticket stays on the device until it is sent, so a page reload does not lose it. Double taps on Send create only one order.

**Behind the scenes**
- `modules/pos.js` (`posSend`) builds the order with `source: 'pos'` and always sends an idempotency key `TPN.orderKey` (sql/41). Ticket kept in localStorage `tpn.pos.ticket`. Prices on screen are display-only; `submit_order()` prices every line on the server (hard rule, Rev 6).
- If the server does not answer within 15s, or the device is offline, the order goes to the offline outbox (4.2.12).
- `modules/payments.js` draws the panel. It never writes "paid". It records money (`record_cash_payment`, `record_manual_payment` in `sql/37b`, `record_bank_transfer` in `sql/31`), and the database works out the payment status with `private.settle_order()`.
- After a paid bill, the panel also shows the booklet-invoice box (4.2.14).
- The customer screen on the back of the iMin follows the ticket and the payment (`modules/customer-display.js`, Rev 24).
- HitPay "Online link" exists in code but stays hidden while `site_settings 'payments.online_enabled'` is off. GO-LIVE status: not used for now.

#### 4.2.4 Dine-in through the floor: open table, add rounds, bill, close table

**For staff**
1. **Open a table / first round.** On the floor screen, tap a table → **+ Order**. The Counter opens set to Dine-in, that table and the guest's name. Ring up the dishes and tap **Send to kitchen**. Dine-in is not paid now; the note says "Dine-in is paid when the table closes (Floor → Close table)." The screen returns to the floor.
   - Guests can also open the table themselves by ordering on the QR menu (4.2.5).
2. **Add rounds.** Tap **+ Order** again. Each round is its own order on the table bill; the floor adds them all together.
3. **Bill.** Tap **Bill** on the table. The table's bill prints on the counter printer: every live round on one slip, "Bill", the order numbers, items, **Amount due**, and "Paying by …" if the guest chose a method on the QR menu. The table shows "Bill requested".
4. **Discounts** (optional): in Close Table, supervisors see a discount button (4.2.9).
5. **Close table.** Tap **Close table**. The screen fetches live totals from the database (so voids and discounts since loading are included) and asks the database what is still owed.
   - **Cash:** type the cash received (chips for the exact amount and rounded-up notes), optional tip; it shows the change or "Short by ₱X". Tap **✓ Paid · Close table**. The drawer pops.
   - **GCash / Maya / QR Ph / Card / Bank:** type the reference or approval code, then **✓ Paid · Close table**. If the guest already chose a method on the QR menu, that method is pre-selected (Rev 36).
   - **Pay one round…:** for a part payment or one round at a time, opens the normal payment panel for a chosen round.
   - Already paid (for example online): "✅ Already paid. Nothing to collect." → **✓ Close table**.
6. One receipt prints for the whole table (all rounds, all payments) if Auto-print is on.
7. **Clear** on a table that still has open orders sends you to Close Table instead. On an empty table it asks first, then clears its call and bill flags on every screen.

**Behind the scenes**
- `tpn-dine-in-floor.html`: `floorAddOrder` → `posStartFor`; `printTableBill` / `markBillReady` → `TPN_PRINT.bill(ids, method)`; `closeTable` → `TPN.getOrder`, `TPN.listAppliedDiscounts`, `TPN.ordersAmountDue`; `confirmCloseTable` → `TPN.settleTableCash` (`settle_table_cash`, `sql/35-table-settle.sql`) or `TPN.settleTableManual` (`settle_table_manual`, `sql/37b`), then `TPN.advanceOrderStatus(id, 'completed', 'floor_panel')` for each live order, then `clearTableSignals` (`ack_bill_request`, `ack_call_staff`).
- A guard (`_closingTable`) blocks a double close. If some orders fail to complete, the table stays on screen with "Closed X/Y order(s)".
- Before Rev 7, closing a table recorded no money; before the Aug 14 hardening it wrote nothing to the database at all (WHATS-NEW.md item 4).
- Split by phone: `table_bill(table_id)` and `split_order_by_device` exist and are tested; the HANDOFF ("Split bills on the floor panel", "Shared table bills") says the split RPCs are staff-gated. The floor has `confirmSplit`/`doSplit` functions (lines ~1915–1937).
- Known, not fixed (Rev 36): two guests ordering at the same table in the same instant can open two bills. Harmless today because the floor, bill print and Close Table add every open order. Proposed fix: `pg_advisory_xact_lock` on the table id in `submit_order`.

#### 4.2.5 Guest QR ordering at the table

**For guests**
1. Scan the QR on the table. It opens `tpn-table-menu?table=N` (the table's number is in the link). A link with no table number shows "Scan the code on your table" instead of guessing Table 1 (Rev 36).
2. Language follows the website's saved choice (`tpn.lang`), Tagalog by default at the table.
3. Tap **+** on a dish to put it on the **tray** (dishes with add-on groups open an options sheet). Adjust quantities in the tray.
4. **Review:** first round asks the guest's name (required) and number of guests; one notes field per round.
5. **Send.** A kitchen ticket "prints" on screen (an animation, not a real printer), then a live status line follows: Received → Cooking → Ready → Served. A toast says when it is ready.
6. Later rounds join the same table bill ("joined" toast with the new table total).
7. The dock at the bottom left has **Call staff** and the bill so far.
8. **Call staff:** sends a signal to the floor. Repeated presses inside 90 seconds only say "already called".
9. **Ask for the bill:** pick Cash or GCash·Maya·bank QR (Card appears only when `payments.card_enabled` is set). The screen says staff will be right with you and shows three steps for that method (for QR: scan, pay the exact total, show the success screen). The bill prints at the counter. The dock shows "Staff coming" until the guest orders again.
10. The phone's Back button moves between screens.

**For floor staff**
- New guest orders arrive on the floor screen live. Calls and bill requests appear in a queue at the bottom right with a chime that repeats every 30s until someone taps **On it**. "On it" clears a call on every screen; a bill request stays as "Bill requested" on the table until it is closed.
- Floor alerts are brick for calls and saffron for bills (Rev 36).

**Behind the scenes**
- `tpn-table-menu.html`: `submitOrder` → `TPN.createOrder` → `submit_order()` with a per-round key kept in sessionStorage `tpn_order_key_<branch>_t<table>` (sql/41). Cart in `tpn_table_cart_…`, session in `tpn_session_…`.
- Status: `TPN.subscribeToOrder` polls `track_order` (every 8s per HANDOFF) because guests have no read access on `orders`; realtime would never fire for them (HANDOFF "CUSTOMER ORDERING: NEVER READ BACK THROUGH THE TABLES").
- `callStaff` → `signal_call_staff`; `notifyBillRequest` → `signal_bill_request(p_table_id, p_payment_method, p_total)`. These two are anon-callable on purpose and must stay that way (HANDOFF "Known quirks").
- The table lookup retries when the guest taps Send, Bill or Call staff, and on `online` (Rev 23).
- On the floor: `noteSignals`, `addRequest`, `takeRequest` (`ack_call_staff`), and a QR bill request prints once per request (sessionStorage `tpn.billPrinted`, keyed by table row + `bill_requested_at`).
- Known, not fixed (Rev 36): the guest's phone keeps saying "Staff will be right with you" after the table is paid.

#### 4.2.6 The kitchen screen

**For cooks**
1. TPN Kitchen opens `tpn-kitchen-station`. Sign in as yourself (4.2.1). If sound is blocked, a "Tap to start" overlay appears; tap once.
2. Three lanes: **NEW**, **COOKING**, **READY**. Oldest first. New orders chime.
3. On a NEW ticket tap **Start Cooking →**. On a COOKING ticket tap **Mark Ready ✓**. A READY ticket shows "Waiting for dining pickup"; the kitchen does not mark orders served or done.
4. Ages are colour-coded: waiting 5 min (warn) / 15 min (urgent); cooking 20 / 35 min; ready 10 / 20 min.
5. The kitchen cannot void. The **✕** on a line asks a manager to void it (reason chips: Wrong item, Customer changed mind, Kitchen error, Duplicate, Too long a wait; at least 3 characters). The line then shows ⏳ until a manager decides.
6. Tickets show the table (or order type), the customer, items with sizes and notes, and the special request. No prices.

**Behind the scenes**
- `tpn-kitchen-station.html`: `advance()` → `TPN.advanceOrderStatus(id, status, 'kitchen_screen')` → `advance_order_status` (`sql/26-order-status-audit.sql`), so the audit log records that the tap came from the kitchen screen. `requestVoid` → `request_void` (`sql/15b`). `ageInfo` holds the age thresholds.
- Connection status is real: red banner and "Orders couldn't load" when it does not know; catch-up fetch on reconnect and every 60s (Rev 5). The login check has a 10s timeout and retries with backoff 5s → 60s (Rev 23).
- `menu_items.prep_minutes` per dish exists (sql/28, "Prep targets"); the station's `ageInfo` uses the fixed thresholds above. Whether the station reads `prep_minutes`: not found in `tpn-kitchen-station.html`.
- Kitchen tickets can also print on paper (4.2.11).

#### 4.2.7 Voids and manager approval

**Flow**
1. Anyone on a station (floor, kitchen, including display screens) taps ✕ on a line and gives a reason. This creates a **void request**; every manager on duty is notified.
2. A manager opens **Service → Void requests** in the portal (filters: pending, approved, denied, all) and taps **Approve** or **Deny** (themed dialogs with reason chips since Rev 36; before that the native browser dialog was blocked inside the apps and "Approve void did nothing").
3. On approval the line is voided, the total is recomputed, the kitchen screen updates live, and the requester is notified.
4. A manager can also void directly from the order, and un-void a line (not on a closed order).
5. Staff see their own requests under **My void requests**.

**Behind the scenes**
- Voiding has exactly two doors: `void_order_item()` (manager+, direct) and `approve_void_request()` (manager+, through a request). Both are SECURITY DEFINER and write `audit_log`. Do not add a third (HANDOFF "Known quirks"; playbook hard rules).
- `request_void` refuses: no staff profile, inactive account, reason under 3 characters, wrong branch (unless admin+), closed order, a request already pending, an already voided line (`sql/15b`).
- `cancel_void_request` is audited and notifies the requester (WHATS-NEW item 7). `unvoid_order_item` refuses closed orders (item 8).
- Portal: `renderVoidRequests`, `approveVoidReq` in `portal.html` (~line 3885–3981).
- Voids need the internet (Rev 21).

#### 4.2.8 Refunds

1. Open the order's payment panel. Each completed payment that still has money left shows a **Refund** button (needs `payments.refund`, manager+).
2. Type how much (up to what remains), then a reason (chips: Wrong order, Food quality, Long wait, Double payment, Order cancelled).
3. "Refund recorded. Hand the cash back to the guest." The order's status is recalculated; for example a ₱50 refund on a paid order reopens it with ₱50 due (Rev 36 live test).

**Behind the scenes:** `payRefund` in `modules/payments.js` → `TPN.refundPayment` → `refund_payment` (`sql/31`): reason of at least 3 characters required; `refund_check` enforces `payments.refund` and that the payment is a completed payment; inserts a `kind = 'refund'` row and runs `private.settle_order`. HitPay payments must be refunded through HitPay (`use_hitpay_refund`). Cash refunds reduce the drawer's expected cash in the X/Z read.

#### 4.2.9 Discounts (Senior Citizen, PWD, Solo Parent, promos)

**For supervisors and up (floor → Close table → discount button)**
1. The picker lists active discount templates and the discounts already on the bill.
2. Tap a template. Templates that need an ID ask for the **ID number** (at least 3 characters).
3. For **Senior Citizen or PWD**, it asks for **their share of the bill**: at a shared table, enter what their dishes come to (or the bill ÷ number of guests); leave blank if they ate alone.
4. The discount applies to every open round of the table. Managers can **Remove** an applied discount with a reason.
5. A discount on an already paid order is refused (Rev 36 live test).

**The three legal templates** (seeded in `sql/15-discounts.sql`, versioned in `sql/16-discounts.sql`, corrected in `sql/31`):

| Template | Law | Amount | VAT handling (current) | Notes |
|---|---|---|---|---|
| Senior Citizen | RA 9994 | 20% | `vat_exempt`: VAT removed from the covered share, then 20% off the VAT-exclusive price | Requires ID. Cannot be deleted (legal row). |
| PWD | RA 10754 | 20% | `vat_exempt`, same as senior | Requires ID. Not stackable. |
| Solo Parent | RA 11861 | 10% | `gross` (not VAT-exempt) | Requires ID. Stackable. |

Worked example from `sql/31-payments.sql`: for a ₱1,120 share, the old calculation gave ₱200 off; the correct deduction is ₱120 VAT + ₱200 = ₱320. `applied_discounts` records `covered_amount` and `vat_exempt_amount` for BIR reporting.

**Behind the scenes:** `openFloorDiscountPicker`, `applyFloorDiscount`, `removeFloorAppliedDiscount` in `tpn-dine-in-floor.html` → `apply_discount(order, template, id_ref, covered_amount)` (supervisor+, own branch unless admin+, refuses closed or paid orders, minimum subtotal, non-stackable combinations) and `remove_discount` (manager+). Both write their own audit row inside the function. Templates are managed in the portal's **Discounts** tab (`renderDiscounts`). Open question in GO-LIVE: confirm the "staff enter the guest's share" practice with the accountant.

#### 4.2.10 Service charge

On the payment panel, "Service charge … change" (needs `orders.service_charge`, supervisor+) sets a percentage of the bill after discounts (chips 0, 5, 10). `payServiceCharge` → `set_service_charge` (`sql/31`).

#### 4.2.11 86-ing a dish (sold out)

There are two places:
1. **Portal → Kitchen queue → 🚫 Sold out (86)** (needs `menu.86`, kitchen tier and up, or `menu.edit`): tap a dish to switch between Available and Sold out. Customers stop seeing it immediately. Logged as `menu.86` / `menu.restock` in the audit log. Code: `open86Panel` in `modules/pos.js` → `TPN.setItemAvailable` → `set_item_available` (`sql/32`).
2. **Floor screen → Menu tab** toggles: `toggleMenuItem` in `tpn-dine-in-floor.html` writes `menu_items.is_available` directly and logs `menu.toggle_availability` from the browser. Per `sql/01-schema.sql` policy `menu_items_write`, a direct write needs manager or above.

Effects: the website, QR menu and Counter stop offering the dish. Known (Rev 36): a dish switched off disappears from the public menu instead of showing "sold out", because the public read policy only returns available dishes (`menu_items_read`, `sql/01`). 86 needs the internet.

#### 4.2.12 Printing

| Slip | When it prints | Where | Code |
|---|---|---|---|
| Kitchen ticket (counter orders) | On Send | Per the "Kitchen tickets" setting: `kitchen` (kitchen network printer, falls back to the counter printer, then the browser print window, with a toast), `counter` (counter printer), `off` (kitchen screen only; offline the counter still prints) | `modules/pos.js` `printKitchenTicket` → `TPN_KPRINT.route` |
| Kitchen ticket (QR and website orders) | Only in `kitchen` mode, printed by the floor screen | Kitchen printer | `TPN_KPRINT.onOrder`, realtime INSERT + 60s check; once per device (`tpn.kprint.done`) |
| Table bill | Floor **Bill** button, or a guest's QR bill request | Counter printer | `printTableBill` → `TPN_PRINT.bill` |
| Receipt (one order) | After payment, if **Auto-print receipts** is On; or **🖨 Print bill** on the payment panel | Counter printer, else browser print window | `TPN_PRINT.receipt`, `printReceipt` |
| Table receipt | After Close table, if Auto-print is On | Counter printer | `TPN_PRINT.tableReceipt` |
| X read / Z read | **🖨 Print** button on the report | Browser print | `modules/pos.js` |
| Test kitchen ticket / Test receipt | Printer menu (managers) | Counter printer or kitchen printer | `TPN_PRINT.testKitchen/testReceipt`, `TPN_KPRINT.tests` |

**The printer menu** (🖨 chip on the floor top bar, titled "Printers"):
- Everyone sees the status (🖨 Printer ready / No printer service / Printer offline / Check paper / Cover open) and **Reconnect**.
- Managers (`printer.manage`, sql/45) also see **Test kitchen ticket**, **Test receipt**, **Open drawer** (no sale, audited), **Auto-print receipts: On/Off**, and the **Kitchen printer** part: address, port (9100), paper (80/58mm), Save, tests, and the "Kitchen tickets" mode. Settings are per device in localStorage (`tpn.imin.*`, `tpn.kprint.host/port/paper/mode`).
- Cash payments open the drawer for everyone (`TPN_PRINT.openDrawer`); every drawer open is in the audit log (GO-LIVE §8).
- **Only one device should be in kitchen-printer mode**, or guests' orders print twice (Rev 34).

**How the printing works**
- **Counter printer:** the iMin D4's built-in 80mm printer via iMin's **iMinprinterplugin** app (iMin App Store), reached at `ws://127.0.0.1:8081` with `vendor/imin-printer-1.4.0.min.js` (`modules/imin.js`). Slips print as one black-and-white picture (`modules/slips.js`, 576px wide, Fraunces + Plus Jakarta Sans); if the picture fails or takes over 15s, a plain text slip prints and managers see "Last slip printed as plain text …". Jobs run one at a time in a queue.
- **Kitchen printer:** a network ESC/POS thermal printer on the restaurant network, port 9100–9109, private IPv4 only. A web page can't open a printer socket, so **TPN Counter 1.4+** relays the bytes through `POST http://127.0.0.1:8091/print` (`modules/kprint.js`, `CustomerScreenService.java`).
- **Receipt content:** wordmark, address, phone; order, table or guest, date; items; subtotal, discounts, service charge, delivery fee; Total; payments and change; Balance if still due; stamp-card QR (only when Rewards is on, the order has a phone and is paid); "Salamat po!" and "This is not an official receipt."
- A dropped printer link never breaks a sale: every `TPN_PRINT` call checks the socket and never throws (Rev 23).
- Status: both test slips were printed on the iMin D4 and approved by the owner (Rev 32). The kitchen-printer routing was **not yet run on the iMin with the real kitchen printer** as of Rev 34.

#### 4.2.13 Offline counter

**What staff see:** a chip on the floor top bar: "📴 Offline: N orders waiting to sync", "⟳ Syncing…", or "⚠ N failed to sync". Tapping it lists each entry: Waiting, Synced as TPN-…, or Failed with the reason (sold out, price changed…), with **Try again / Payment / Remove**. Synced rows stay 24h so OFF numbers can be matched to real ones.

**What works offline**
- The Counter opens and takes orders. Each offline order gets a local number like **OFF-007**; its kitchen ticket always prints at once (paper is all the kitchen has).
- Take-out and delivery: **cash only**. Cash is checked against the total estimated from the cached menu, and the drawer pops. GCash, Maya, QR Ph, card and bank are disabled with the reason. "Pay later" leaves the order unpaid.
- A reload offline still opens for whoever last signed in on that device. Signing in fresh needs a connection.

**What still needs the internet:** opening/closing a shift, Close table, voids, 86, X/Z reads, receipts that read the order back. QR and website orders still reach the database over guests' mobile data, but the counter and kitchen only see them after reconnecting.

**When the connection returns:** replay runs oldest first (on `online`, every 15s while anything waits, and on page open). A send that already landed is not doubled (same key returns the first order). Replayed cash is tagged `offline OFF-… <key>` so it is never recorded twice; `nothing_due` blocks a second full payment; if the server's price is higher than the cash taken, the entry fails with "collect ₱X more".

**Rules for the device:** after each deploy, open the floor screen online **twice** so the menu is cached. Don't uninstall the app while orders are waiting (uninstalling wipes them). If the sign-in has expired when the line returns, the chip says "Sign in again to sync"; orders wait until someone signs in on that device.

**Behind the scenes:** `tpn-counter-sw.js` (current `VERSION = 'tpn-counter-20261021b'`; bump it to drop old caches) and `modules/offline.js` (IndexedDB `tpn-counter`, remembered profile `localStorage tpn.offline.me`, probe `/auth/v1/health`). Floor screen only. Known open items (Rev 23): an outbox "Take cash" during a running sync can be lost and there is no cross-tab lock; payment and Close-table sends have no timeout; the service worker serves `?v=` files from cache forever; a 15s-timeout order can print an OFF ticket for an order that also lands online.

#### 4.2.14 X read, Z read and the daily close

There are three separate end-of-shift tools:

| Tool | Where | What it does |
|---|---|---|
| **X read** | Counter → Drawer ▾ → X read | Mid-shift report, changes nothing: opening float, cash sales (count), cash tips, cash refunds, cash in, cash out, **expected in drawer**, and "other methods this shift". Printable. |
| **Z read (Close shift)** | Counter → Drawer ▾ → Close shift | Count each denomination (₱1000 … ₱0.25). It shows counted vs expected live ("exact ✅", "over by", "short by"). If it doesn't match it asks "Close anyway? The difference is recorded with your name." Saves counted cash, denominations and notes, then shows the Z read. |
| **Daily close** | Portal → Sales & finance → Daily close (needs `finance.view`) | For a chosen date: net sales, order count, average ticket, discounts, gross, voids and cancelled orders, **cash received**, by method, by type, top items, unpaid orders and bank transfers waiting. Then **Count the drawer**: type counted cash, see the variance as you type, record it. Re-counting overwrites and re-audits. Last 14 closes listed. Includes the **BIR invoices (booklet)** panel (4.2.15). |

**Behind the scenes:** `posXRead`, `posCloseShift`, `posCloseShiftSave` in `modules/pos.js` → `cash_session_report`, `close_cash_session` (`sql/32`). Daily close: `renderDailyClose`, `openCloseTill`, `doCloseTill` in `portal.html` → `daily_close_report`, `record_daily_close`, `list_daily_closes` (`sql/28`, rewritten in `sql/31` to count **received** cash from the payments ledger). `daily_closes` snapshots the figures so a void the next morning can't rewrite last night.

Note: the HANDOFF section "⚠️ DAILY CLOSE READS *DECLARED* PAYMENTS, NOT RECEIPTS" is out of date; Rev 6 and `sql/31` changed the close to received cash. The on-screen label is "Cash received".

**End of day, in order:** close every table → each cashier closes their drawer shift (Z read) and uses Switch user → manager does the Daily close count → writes the end-of-day BIR booklet invoice if needed. Rev 36 noted a drawer left open during the test; "otherwise a Z read was missed".

#### 4.2.15 BIR booklet invoices

TPN OS replaces StoreHub to save its fee, but has no BIR Permit to Use, so the **official invoice is handwritten from the BIR-registered booklet**. The system tells staff when one is needed and keeps the number (Rev 22, `sql/43-bir-invoices.sql`, `modules/invoices.js`).

1. Once a bill is paid, the payment panel shows either **"Write a booklet invoice for this sale"** with a box for its number, or "only if the customer asks".
2. The rule lives in the database: if `site_settings 'bir.vat_registered'` is `yes`, every sale needs an invoice. Otherwise a sale needs one when it is **over ₱500** (`private.bir_threshold()`, RR 7-2024 as amended by RR 11-2024), and the small sales go on **one end-of-day invoice**. If the setting is blank, the system assumes non-VAT and says so on screen. The setting is in Portal → Website ("VAT-registered? type yes or no").
3. The daily close's **BIR invoices (booklet)** panel lists paid sales still missing an invoice and the small-sales total, with a form for the end-of-day invoice.
4. A wrong number is cleared by saving a blank number; both cases are audited (`invoice.record`, `invoice.day`).

Rules: `orders.invoice_no/at/by` are written only by `record_order_invoice` (trigger `trg_guard_invoice_no` refuses any other update). `bir_day_invoices` is written only by `record_day_invoice`. `invoice_day_summary(date, branch)` decides what is missing. None are callable without signing in. GO-LIVE points to the BIR steps (stamp old "Official Receipt" booklets "Invoice", cancel a StoreHub PTU if there is one); those steps are described in Rev 22 only in that one sentence; a fuller BIR procedure was not found in GO-LIVE.md.

#### 4.2.16 Stamp cards (rewards)

**Status: OFF on production** (GO-LIVE §6; Rev 35 "off on production as of Oct 22"). The reward (₱300 minimum, 10 stamps, free dish up to ₱300) is a placeholder until the owner approves an offer.

How it works when switched on (`sql/34-stamp-cards.sql`, `modules/stamps.js`, `tpn-rewards.html`):
1. Stamps are added **only** by the trigger `trg_order_stamp` when an order becomes paid and meets the minimum. One per order; refunds and cancellations reverse it. Nobody types stamps.
2. The printed receipt carries a QR (only when the order has the guest's phone and is paid). The guest scans it → `tpn-rewards?claim=<order>&t=<token>` → `claim_stamp_card` with the same phone. The card is the phone number, stored as a salted hash plus last 4 digits.
3. To redeem, the guest shows a QR or 6-digit code that changes every 30 seconds; staff (`rewards.redeem`, supervisor+) scan it or type it in Portal → Rewards (`redeem_stamp_reward`). Each code works once.
4. Settings (Portal → Rewards, `rewards.manage`): on/off, minimum order, stamps needed, reward text, expiry days. Turning it on makes the website footer link appear by itself; re-publish the stamp-card FAQ in the Website tab.

#### 4.2.17 Clock-in and clock-out (other than stations), and Clock-in review

- **Phone or portal clock-in** (`modules/clockin.js`, `sql/33`): live camera, full-body uniform photo with a framing guide, then clock in. The server records the time, the IP and whether it is a trusted restaurant network. No camera → still clocks in, flagged for review. Never a dead end.
- **Clock-in review** (managers, `attendance.verify`): photo, network, uniform checklist (`hr.uniform_checklist` in Website settings), approve or flag, **Trust this network** (do it once on the restaurant Wi-Fi). IPv4 matched exactly, IPv6 on the /64.
- Photos live in a private bucket (`attendance-photos`), readable only by managers, deleted after 60 days by `purgeOld()` when a manager opens the queue (Data Privacy Act retention).
- Staff cannot write `attendance` directly (closed back-dating); manager corrections are in Attendance.
- GO-LIVE §3 status: **waiting** for someone at the restaurant to trust the Wi-Fi and test the phone camera. The camera was only tested in a browser without one.

#### 4.2.18 Schedules, tasks, messages and notifications

| Feature | Where | How it works | Source |
|---|---|---|---|
| Schedules | Portal → Team → Schedules (admin editor); staff → Shifts | Week view, click any cell to edit (saves immediately), ← Prev / This Week / Next →, **Copy from prev week** | `portal.html` `renderSchedulesAdmin`, `copyPrevWeekSchedules`, `renderStaffSchedule`; `sql/08` |
| Tasks | Portal → Team → Tasks | Many assignees per task, each with their own state; the task's status is derived (nobody started → todo, anyone working → in progress, all done → done) | `renderTasks`, `saveTask`; `sql/20`, `sql/22` |
| Messages | Portal → Inbox → Messages (manager+ compose); staff → Inbox | Inbox and Sent, **✉️ Compose** to a person or broadcast to the branch; realtime toasts and badges | `renderMessagesAdmin`, `openComposeMessageModal`; `sql/09`, `sql/36` |
| Notifications (bell) | Portal → Inbox | One read receipt per person (`read_receipts`); `my_notifications`, `my_unread_counts`, `mark_read`, `dismiss_notification`. Since sql/46 the bell lists only my own and shared notifications, so read ones stay read | `sql/36`, `sql/46` |
| Badges | Sidebar | Real unread (messages, notifications) clears in the database; derived counts (new enquiries, pending voids, low stock…) clear per browser in `localStorage tpn.badgeAck` and reappear if the count falls then rises | HANDOFF "Badges you can clear" |

**Known open issue:** schedule week keys are saved as **Sundays**, not Mondays, because `isoDay()` uses `toISOString()` (UTC) on a Manila Monday (`portal.html` line ~8211). HANDOFF Rev 5 explains the fix (shift stored rows by one day and switch the helper to `TPN.today(monday)`, together). Still not fixed in the current code.

#### 4.2.19 Deliveries (short)

Portal → Service → Deliveries (`modules/delivery.js`, `sql/38-delivery.sql`). Every delivery order lands as **Waiting**. Assign our rider (staff) or book Lalamove / Grab / other by hand and paste the tracking link → **On the way** (order = served) → **Delivered** (order = completed), or **Failed** with a reason. Delivered asks for payment first if the order isn't paid. **Areas & fees**: fee, minimum and usual time per area; the server adds the fee; changing it later needs `set_delivery_fee` (supervisor+, with a reason). No areas = no fee and no area question. GO-LIVE: set areas before announcing delivery.

---

### 4.3 Deployment and environments

#### The pieces

| Piece | What | Where | Notes |
|---|---|---|---|
| Code | GitHub repo `UnoRfl/tpn-os` | https://github.com/UnoRfl/tpn-os | **Public** repo, default branch `main`. Collaborators: UnoRfl (owner), JaPat24. |
| Website hosting | GitHub Pages | https://unorfl.github.io/tpn-os/ | Built from `main`, root folder, "legacy" Pages build (no workflow). Live about a minute after a push. |
| Database, logins, realtime, functions | Supabase | project ref `xjlqfpnzobfqxetgkkai` | One project, one branch. **No staging project** (WHATS-NEW lists a staging project as an account action not yet done). Free plan: no Supabase backups (hence 4.5), leaked-password protection unavailable. |
| Edge functions | Supabase | `create-staff` deployed (ACTIVE, version 4) | `hitpay-create`, `hitpay-refund`, `hitpay-webhook` are in the repo but **not deployed** (Rev 23; confirmed by the live function list). |
| Station apps | GitHub Releases | `releases/latest/download/tpn-counter.apk` and `tpn-kitchen.apk` | See 4.4. |
| Planned host | Vercel | not set up yet | GO-LIVE §9. |

`config.js` holds the Supabase URL and the public anon key. It is committed on purpose; regenerate it only if the project itself changes (HANDOFF "Known quirks").

#### How a change goes live
1. Pull the latest `main` (the other account pushes between sessions).
2. Work on a branch (`feature/…`, `fix/…`, `perf/…`, `docs/…`).
3. If the database changes: write `sql/NN-name.sql`, test it locally (`cd tests/db && npm install && node run.mjs`), then apply it to production. Recent ones were applied as named migrations (`43_bir_invoices`, `44_staff_rank_guard`, `45_printer_permission`, `46_my_notifications_only`), which show up in the project's migration history. Take a backup by hand first for risky ones (4.5).
4. Bump the `?v=` version on every changed JS/CSS file in **every page that loads it** (next section).
5. Update `HANDOFF.md` (new "Rev N"), `GO-LIVE.md` (the migration row and any setup step).
6. Merge into `main` with a "Merge …" commit and push. GitHub Pages serves it in about a minute.
7. Devices: wall screens re-sync on reload; the counter must open the floor screen online twice to refresh its offline copy.

#### Asset version bumping (`?v=`)
- Every page loads its scripts and styles with a hand-written version, e.g. `tpn-kit.js?v=20261022b`. GitHub Pages re-checks the HTML but caches versioned files hard, and the counter's service worker serves `?v=` files from cache forever. **If you change a file and don't bump its version, devices keep running the old file against the new page.**
- This broke sign-in once (Aug 22): the cached `tpn-supabase.js` lacked `TPN.loadPermissions`, and nobody could log in. Two defences remain: `preloadPermissions()` never throws, and `TPN.can()` falls back to tier gating (HANDOFF "BUMP THE ASSET VERSION ON EVERY RELEASE").
- Format seen: `YYYYMMDD` + a letter (`20261022a`, `b`, …); the website's v3 files used `20261017vNN`. Dish photo URLs have their own `PHOTO_V`.
- If you add a head script to a page, add its `<link rel="preload">` with the same `?v=` (Rev 11).
- If you bump supabase-js or exceljs, change the CSP `<meta>` on all pages too (Rev 23: `script-src` names exact files).
- Seven HTML pages carry versions: `index.html`, `portal.html`, `tpn-dine-in-floor.html`, `tpn-dine-in-floor-customer.html`, `tpn-kitchen-station.html`, `tpn-table-menu.html`, `tpn-rewards.html`. Current shared versions on Oct 22: `tpn-kit.js?v=20261022b` (7 pages), `config.js` and `tpn-supabase.js` `?v=20261017o`.

#### Rolling back
- **Pages:** revert the merge commit on `main` and push (GO-LIVE §7). The database changes have been kept backwards-compatible with older pages.
- **One feature off without a deploy:** blank "Online payments" in Website settings (HitPay off); untick Rewards (stamps stop).
- **A wall screen stuck:** reload it; screens re-sync on reconnect.
- **Database:** restore from the nightly backup (4.5). Never replay `sql/01` on production; it reintroduces the anonymous-ordering bug (re-run `sql/18` afterwards if it happens).
- **Apps:** install the previous release's APK over the top is not described anywhere; Android normally refuses a lower `versionCode` without uninstalling. A documented app rollback was not found.

#### Vercel preparation (GO-LIVE §9, Rev 22)
Prepared, not done. GitHub keeps the code, Supabase the data, Vercel would serve the pages.
1. vercel.com → sign in with the GitHub account that owns the repo → Add New → Project → import `tpn-os`.
2. Framework preset **Other**, no build command, output = repo root. `vercel.json` already sets clean URLs (`/tpn-table-menu` serves `tpn-table-menu.html`), headers (`X-Content-Type-Options: nosniff`, `Referrer-Policy: strict-origin-when-cross-origin`, `X-Frame-Options: SAMEORIGIN`) and `no-cache` on `tpn-counter-sw.js`. `.vercelignore` keeps `sql/`, `supabase/`, `tests/`, `ops/`, `*.md`, `android/`, `.github/` off the site.
3. Check the menu, the portal sign-in, `/tpn-table-menu?table=1`, `/tpn-kitchen-station`.
4. Optional: add the restaurant's own domain.
5. Then print the table QR codes from the portal on the new address, rebuild the apps with the new `site_url` and install over the top, and update `og:image` in `index.html` (and `SITE_URL` for the unused HitPay functions).
6. Keep GitHub Pages on for a week, then turn it off.
**Do this before printing table QR codes or installing the counter app**, because both remember the address. Supabase needs no change (password logins, no redirect URLs).

---

### 4.4 Android apps release process

#### What gets built
One Android project in `android/` (plain Java, no libraries apart from GeckoView) builds two apps as product flavors (`android/app/build.gradle`, `flavorDimensions 'station'`):

| Flavor | App name | Package | Opens | Back screen | User-agent tag |
|---|---|---|---|---|---|
| `counter` | TPN Counter | `ph.tyopaengnyo.counter` | `tpn-dine-in-floor` | yes (`CustomerScreenService`) | `TPNCounter` |
| `kitchen` | TPN Kitchen | `ph.tyopaengnyo.kitchen` | `tpn-kitchen-station` | no | `TPNKitchen` |

- Engine: bundled **GeckoView 153** (`org.mozilla.geckoview:geckoview:153.0.20260810162159`) because the iMin D4-504's built-in WebView is 83 and can't be updated. 154+ needs compileSdk 37, beyond AGP 8.9; move up together with the toolchain.
- Toolchain: AGP 8.9.1, Gradle 8.11.1, compileSdk 36, targetSdk 34, minSdk 26, Java 17. ARM only (`arm64-v8a`, `armeabi-v7a`), native libs compressed: about **165 MB** per APK.
- `versionCode` = the GitHub Actions run number; `versionName` = `1.4.<run>`.
- `BuildConfig`: `SITE_URL` (default `https://unorfl.github.io/tpn-os/`), `START_PATH`, `CUSTOMER_SCREEN`, `UA_TAG`.
- Java files: `MainActivity.java`, `CustomerScreenService.java` (back screen + loopback link on `127.0.0.1:8091`: `/ping`, `/state`, `/print`), `CustomerPresentation.java`, `BootReceiver.java` (reopen after power-on; needs "Display over other apps"). `network_security_config.xml` allows plain HTTP only to 127.0.0.1/localhost.
- Inside the apps, `tpn-kit.js` adds `html.tpn-lite` (no blur, short animations), and redirects the public website, QR menu and rewards page back to the station (Rev 29, Rev 35).

#### The workflow (`.github/workflows/build-apk.yml`, "Build TPN apps")
- **Triggers:** a push that changes `android/**` or the workflow file, or **Run workflow** by hand (input `site_url`, default `https://unorfl.github.io/tpn-os/`).
- **Steps:** checkout → Java 17 (Temurin) → Gradle 8.11.1 → decode the signing key from the secret into the runner's temp folder → `gradle -p android assembleCounterRelease assembleKitchenRelease` → delete the key file → upload artifact `tpn-apps-<run>` with both APKs.
- Without the key secret the build is **debug-signed**, and every new build would need the old app uninstalled first (which wipes its storage).
- Changing this workflow file needs a GitHub token with the `workflow` scope: UnoRfl's. On the Mac: `gh auth switch -u UnoRfl`, push, then switch back to JaPat24 (Rev 24).
- Actions warns that `setup-java@v4` is deprecated; move to `@v5` when convenient (Rev 24).

#### Signing secrets
- Repo secrets (set by the owner Oct 21): `TPN_KEYSTORE_B64` (the key file as base64) and `TPN_KEYSTORE_PASSWORD`.
- The key: `~/Downloads/tpn-os-study/keys/tpn-counter.p12`, alias `tpncounter`, with its password file and a base64 copy, plus a README. **Never commit it** (`*.p12` is in `.gitignore`). Both apps are signed with the same key.
- If the key is lost, the apps can't be updated in place; they would have to be uninstalled (losing sign-in and any unsynced offline orders). **Keep a second copy offline** (USB / password manager), like the backup key. Whether that offline copy exists: not found.

#### Releasing
1. Run the workflow (or push an `android/` change). Wait for green.
2. Download the artifact `tpn-apps-<run>` and unzip it.
3. Create a GitHub release named **`apps-X.Y.Z`** with **both** files attached as exactly `tpn-counter.apk` and `tpn-kitchen.apk`, so both "latest" links keep working (Rev 31). Write in the notes what changed, "Install over X", and "Built by run N".
4. Copy the APKs to `~/Downloads/tpn-os-study/apk/` (the 1.4 build is in `apk/1.4/`).

GO-LIVE §10 B still shows the older single-app naming (`gh release create counter-1.0.N tpn-counter.apk` and workflow name "Build TPN Counter APK"); that text is out of date since 1.3.0.

#### Download links (always the newest release)
- https://github.com/UnoRfl/tpn-os/releases/latest/download/tpn-counter.apk
- https://github.com/UnoRfl/tpn-os/releases/latest/download/tpn-kitchen.apk

#### Installing and updating on a device
1. On the device, open the link in Chrome (use Wi-Fi; about 165 MB). Allow "Install unknown apps" for Chrome.
2. Open the app → **Open setting** → allow **Display over other apps** (needed for the back screen and for reopening after a power cut) → back.
3. Counter only: allow the camera when a clock-in asks.
4. **Updates install over the old build** and keep the sign-in and offline queue, as long as the build was signed with the same key. Don't uninstall while the offline chip shows orders waiting.
5. Exception: going from 1.0.x to 1.1.0 required uninstalling first (engine change).
6. The counter also needs **iMinprinterplugin** from the iMin App Store for the printer and drawer.
7. After a Vercel move, run the workflow with the new site URL and install over the top.

#### Release history (from GitHub Releases)

| Tag | Date (UTC) | Published by | Contents |
|---|---|---|---|
| `counter-1.0.1` | Oct 21 | JaPat24 | First build: floor screen full screen, customer screen on the rear display. Run 39577220672, release-signed. |
| `counter-1.0.2` | Oct 21 | JaPat24 | Warns when the WebView is older than 87; back screen fills the display; logo top-left. |
| `counter-1.0.3` | Oct 21 | JaPat24 | On old WebViews the app keeps only the back screen and opens the counter in Chrome, linked over 127.0.0.1:8091. |
| `counter-1.1.0` | Oct 21 | JaPat24 | Everything in one app on bundled GeckoView 153; about 165 MB; **uninstall the previous version first**. |
| `counter-1.1.1` | Oct 21 | JaPat24 | Reopens signed in where it left off; lighter drawing on the iMin. |
| `counter-1.2.0` | Oct 21 | JaPat24 | Opens on the counter's own sign-in; Switch user. |
| `apps-1.3.0` | Oct 21 | JaPat24 | Two apps (Counter + Kitchen); sign-in = clock-in. Run 39603913305. |
| `apps-1.4.0` (Latest) | Oct 22 | JaPat24 | Kitchen network printer relay (`/print`), test prints. Run 39736601966. |

---

### 4.5 Backups, the go-live checklist and status files

#### Nightly encrypted backups (HANDOFF "Backups", Oct 20; scripts in `ops/backup/`)
- **Why:** the free Supabase plan keeps no backups.
- **What:** on the always-on **headless PC**, the scheduled task **`TPN OS Backup (nightly)`** runs `C:\TPNBackup\backup.ps1` at **03:00** as SYSTEM (or when the PC comes back if it was off). It runs `pg_dump --format=custom` of the whole database (public, private, auth logins, storage metadata) over the Supabase session pooler and pipes it straight into **`age`** encryption, so no unencrypted copy touches the disk. Files: `C:\TPNBackup\dumps\tpn-os-YYYYMMDD-HHMM.dump.age`, newest **30** kept.
- **Check it:** `C:\TPNBackup\backup.log` gets one `OK` or `FAIL` line per run. `FAIL … password authentication failed` means the database password was reset: re-enter it with `ssh -t headless powershell -NoProfile -File C:\TPNBackup\set-password.ps1` (hidden prompt; stored in `secrets\pgpass.conf`, readable by admins and SYSTEM only).
- **Backup by hand** before a risky migration: `schtasks /Run /TN "TPN OS Backup (nightly)"` on the headless PC.
- **Not included:** uploaded photo files in Storage (only their metadata), edge function code (it's in the repo), `vault` secrets.
- **The key:** the headless PC holds only the age public key. The private key `tpn-backup-identity.txt` is in `C:\Users\pc\TPN-Backup-Key` on Uno's main PC. **Keep a second copy offline**; without it every dump is unreadable. Whether that copy exists: not found.
- **Rebuild the backup box:** copy `ops/backup/*` to `C:\TPNBackup`, put PostgreSQL 17 `pgsql\bin` in `C:\TPNBackup\bin\pgsql\bin` and `age.exe` in `C:\TPNBackup\bin\age`, run `install.ps1` elevated, then `set-password.ps1`.
- **Restore** (HANDOFF "Restore"): copy the newest dump off the PC (`scp`), decrypt with `age -d -i tpn-backup-identity.txt`, **practise first** on a throwaway local Postgres 17, then restore `public` and `private` into the same project over the pooler with `pg_restore --clean --if-exists --no-owner`, or into a new project (logins first, then the app schemas, then point `config.js` at the new project, bump `?v=` and redeploy the edge function; this new-project path has not been rehearsed). Delete the decrypted file afterwards: it holds customer names and phone numbers.
- **Restore-tested Oct 20:** the first dump (1.1 MB) restored into a throwaway Postgres 17.6; row counts matched production (orders 7, menu_items 62, order_items 17, staff 4, auth.users 4, 56 public tables).

#### GO-LIVE.md, section by section (last changed Oct 22, commit `a05697d`)

| Section | What it says | Status |
|---|---|---|
| Status table (dated 2026-10-16, rows updated since) | One-line state per step | See rows below |
| **0 Before you start** | Leaked password protection ON; backup; run the tests | Leaked-password protection **skipped** (needs paid plan). Backups ✅ nightly. The test count in the text (`123 passed`) is stale; Rev 36 reports 159 + 4 new. |
| **1 Database** | Run each file alone, in order: 29a (⚠ alone), 29b, 30, 31, 32, 33, 34, 35, 36, 37a (⚠ alone), 37b, 38, 39, 40, 41, 42, 43, 44, 45, 46. Then Advisors → Security: only the customer functions (`submit_order`, `track_order`, `claim_stamp_card`, `my_stamp_card`, `stamp_card_code`, `my_guest_profile`, `addon_suggestions`, `signal_*`) should warn | ✅ Live. Production's migration history lists 29–38 and 40–46; **39 is not in the recorded history** (whether it ran another way: not found). |
| **2 Website + portal** | Merge the v2 overhaul, check with `?nc=1`, fill Website tab (phone, address, hours, FAQs marked `[Fill in]`, testimonials only with consent, package prices) | ✅ Merged and live. FAQs with `[Fill in]` stay unpublished. |
| **3 Clock-in** | On the restaurant Wi-Fi: Trust this network; test a camera clock-in; test from mobile data; optional uniform checklist | ⏸ Waiting for someone at the restaurant. |
| **4 HitPay** | API key and salt as edge secrets, deploy the three functions, webhook URL, sandbox test, then turn on | ⏸ Not used: every payment is taken by hand. Update the "How do I pay?" FAQ. |
| Delivery (status row) | Set areas and fees first | ✅ Live. |
| **5 Counter POS and cash drawer** | Add-ons if any; open shift with float, close with Z read; daily close expects cash received | ✅ Usable. No add-ons set up. |
| **6 Stamp cards** | Set the offer in Rewards, tick on; footer link appears | ⏸ Off on purpose. |
| **7 If something goes wrong** | Revert the merge; switch features off in settings; reload stuck screens | Reference. |
| Open questions | "Established 2003 / 20+ years" vs Facebook's 2019; real email and SEC/TIN; delivery radius, minimum pax, booking lead time; senior/PWD share practice with the accountant | On hold. |
| **8 iMin D4 at the counter** | Install iMinprinterplugin; Chrome → floor screen → install as app; printer chip test print and drawer; auto-print; optional keep-screen-on; adb help over USB | Partly superseded by the app (§10). |
| **9 Moving to Vercel** | See 4.3 | Not done. |
| **10 Customer screen on the back of the iMin** | A: Chrome Presentation (try first). Since 1.1 everything runs in TPN Counter: fresh install steps, sign-in = clock-in, Switch user, ← Portal, back-screen check, printer test, daily use. B: the older app route (single-app naming) | App route in use; part B text is out of date. |
| **11 The kitchen screen: TPN Kitchen app** | Download `tpn-kitchen.apk`, allow display over other apps, each cook signs in, check the chime | Ready; kitchen hardware not yet confirmed in the docs. |

#### WHATS-NEW.md status
**Stale.** It still describes the **Aug 14, 2026 "hardening release"** (commit `9212439`, migrations 16–17): the order-total hole, the broken archive function, the floor's dead advance button, Close Table writing nothing, the QR orders saved without dish links, TRUNCATE grants, discount audit rows, the 30-minute idle timeout, and its own setup steps. It has not been changed since Aug 14, although the playbook says to update it on each release. Its "deliberately not in this release" list (offline queueing, modifiers, split bills, cash drawer, inventory, labour cost, backups, staging) has since been mostly built, except a staging project and error monitoring (Sentry), which were not found.

#### Other docs and their age

| File | Last changed | State |
|---|---|---|
| `HANDOFF.md` | Oct 22 (Rev 36) | Current; the main rulebook. Its "Current state" file layout (top of file) and "Migration order" (ends at 17) are older parts. |
| `GO-LIVE.md` | Oct 22 | Current except §0 test count and §10 B naming. |
| `README.md` | Aug 22 | Out of date: says `index.html` holds the portal (split out in Rev 7), migration list stops at 23, production checklist still mentions StoreHub receipts and nightly backups as to-dos. |
| `TESTING.md` | Aug 10 | Out of date: phase 3–6 checklist from the zip-delivery era. |
| `CEO-FEEDBACK-TRIAGE.md` | Aug 22 | Historical: review of the CEOs' 18 suggestions (3 built, 7 quick wins, 2 need a decision, 1 "don't build": screenshot testimonials). |

---

### 4.6 Collaboration conventions ("frameworks followed")

#### Who works on it
- **Two Claude accounts** work on the same repo between sessions: the owner's other Claude (pushing as **UnoRfl**) and this Mac's Claude (pushing as **JaPat24**; commits made on this Mac carry the author name "Ritchelle"). Commit counts on `main`: UnoRfl 84, Ritchelle 61, JaPat24 21.
- On this Mac, `gh` has both accounts: **JaPat24** (default, everyday pushes) and **UnoRfl** (owner, has the `workflow` scope). Switch with `gh auth switch -u UnoRfl` only for workflow files or secrets, then switch back.
- The owner's memory notes (`MEMORY.md`): follow the other Claude's playbook in `~/Downloads/tpn-os-study`.

#### Working rules
1. **Pull before editing.** Always fetch `main` first; the other account pushes between sessions. Never assume your copy matches live (HANDOFF "Always ask for current files before editing").
2. **Feature branches.** Big work goes on `feature/*` (also `fix/*`, `perf/*`, `docs/*`) and is merged into `main` with a "Merge …" commit. Pushing to `main` deploys.
3. **On release:** bump `?v=` on every page that loads a changed file, add a "Rev N" section at the top of HANDOFF.md (newest first) and update its "Last updated" line, add the migration to GO-LIVE.md, update WHATS-NEW.md (not done since Aug 14).
4. **HANDOFF Rev N format:** heading "Rev N — what changed in plain words (date)", the owner's request, bullets of what changed with file and function names, how it was tested and what was not tested, asset versions, and the next free migration number.

#### Adding a feature end to end (the order of work)
1. **SQL migration** `sql/NN-name.sql`: safe to re-run, starts with the `═══` banner. Enum additions go in their own `NNa` file and run alone (the SQL Editor runs a paste as one transaction). Functions are `security definer set search_path = ''`, schema-qualified, with the permission check first (`private.can('x.y')` → `permission_denied`). Raise snake_case error tokens the screens translate. `revoke all … from public, anon` then `grant execute … to authenticated` (anon only for deliberate customer functions; `revoke from anon` alone does not close a function, see HANDOFF sql/23). Add permissions with `private.add_permission(...)`. RLS on every table.
2. **Test** `tests/db/t_NN_name.sql`, run `cd tests/db && npm install && node run.mjs` (PGlite replays every migration). A block counts only if its last line is `select name, ok, detail from public.t_results;`. Production checks are done inside rolled-back transactions.
3. **TPN wrapper** in `tpn-supabase.js`: `TPN.x` calling `sb.rpc('fn', {p_arg})` with `if (error) throw error` (some modules keep their helpers inside the module, e.g. invoices).
4. **Module** `modules/name.js`: an IIFE ending in `TPN_MOD.register({id, perm, label, labelTl, render, side, section})`; add the id to `TPN_HUBS` and the script tag in `portal.html`. Escape with `E()` for HTML and `JA()` inside inline onclick strings. Use `tpnConfirm`/`tpnAsk`, never `confirm()`/`prompt()`. Add new money-moving actions to `guardAsync`.
5. **EN/TL i18n:** English in code, Tagalog in `PHRASES` in `tpn-i18n.js` (or `TPN_STRINGS` keys). Never hard-code Tagalog in templates; brand lines ("Salamat po!", the slogan) are the exception. `translate="no"` opts a string out.

#### Commit style
- Subject: plain English, optional area prefix ("Website v3: …", "sql/41: …", "Counter: …", "HANDOFF Rev 33: …").
- Body: `- ` bullets wrapped at 72 columns, saying why, naming the sql files and tests, ending with "All new text is EN/TL."
- Trailer: `Co-Authored-By: Claude …` (current commits use `Claude Opus 5.5 <noreply@anthropic.com>`).

#### Migration numbering
- Sequential two-digit numbers with letter suffixes for enum-only or split files (`15a`, `15b`, `29a`, `29b`, `29c`, `37a`, `37b`). Note `sql/15-discounts.sql` also exists; `16` supersedes it.
- **Next free number: 47** (HANDOFF Rev 36; confirmed: highest file is `46-my-notifications-only.sql`).
- Production migration names for 18–28 differ from the file names (e.g. `restore_anon_pickup_delivery_ordering`); from 29 on they match the file (`29_security_hotfix` … `46_my_notifications_only`). 01–15 predate the recorded history.

#### Money and security hard rules (never break)
- **One order door:** `submit_order()` prices everything on the server. Guests have no read access on `orders`; tracking is `track_order` plus a token.
- **Payment status is derived** from `payments` by `private.settle_order()`. Nobody types "paid". Payments are recorded by hand with a reference.
- **Totals** (`orders.total/subtotal`) are written only by `recompute_order_totals` (the `tpn.recompute` flag).
- **Money audit rows** are written inside the SECURITY DEFINER function, never by the browser.
- **Voiding has two doors:** `void_order_item` and `approve_void_request`.
- **Stamps** come only from `trg_order_stamp`. **Invoice numbers** only from `record_order_invoice`.
- **Role order is the permission model:** `kitchen_display, dine_in_display, dining, kitchen, supervisor, manager, admin, director, ceo`, mirrored in `sql/01`+`15a`, `TPN.ROLE_HIERARCHY`, `DISPLAY_ROLES/ROLE_LABELS`, `create-staff/index.ts`. Drift is a security bug.
- **Nobody climbs the ladder** (sql/44): below CEO nobody changes their own role, status or overrides, or edits someone at or above their tier.
- **Login path:** nothing it awaits may be a hard dependency.
- **PostgREST joins** with two foreign keys to one table: `staff:staff_id(...)`.
- **Internal links** are extensionless. **Menu categories** always come from the database.
- **Public sign-up stays off** (any new login becomes a `dining` staff row).
- **Never commit the signing key** (`*.p12` is ignored) or any secret; the repo is public and GitHub Pages serves its files.
- **Never remember emails or people at stations** (Rev 31).
- Keep the two customer signals (`signal_call_staff`, `signal_bill_request`) callable without login.
- Never downscale or recompress the owner's photos (Rev 14; owner memory "Keep photo resolution").

#### The owner's design rules (as recorded)
- Follow the theme and reuse existing v3 screens; no clutter subheadings or lines under headings (Rev 30; owner memory "TPN UI: theme + no subheadings").
- Less text; no captions on photo panels; no duplicate controls; button labels never wrap; never claim credentials that aren't on file (playbook "Copy").
- Public v3 palette: paper `#FBF6EC`/`#F4EAD8`/`#FFFDF8`, ink `#2E1A10`/`#6E5240`/`#A68B74`, one accent brick `#A3321A`, saffron and cocoa for big titles only; Fraunces + Plus Jakarta Sans; warm brown shadows; glass blur only on floating chrome (playbook "Design system").
- Rev 10 (home) removed eyebrows and pill buttons from the home page; Rev 36 lists what still breaks the rules: the QR menu's "TABLE 7 · DINE-IN" eyebrow and lines under headings, "WHAT HAPPENS NEXT" with 1-2-3 steps, one italic word in headings, the Counter's subtitle and "Drawer open" pill, the old typewriter QR ticket.
- **Conflict to settle:** this Mac's global rules ban eyebrow labels, subtitles, numbering, pills, one accented word in a headline and similar; v3 used some of them. The playbook says to ask the owner which rule wins on TPN work.

#### Testing conventions
- Local: `tests/db` (PGlite), 14 test files `t_29` … `t_46`, plus `supabase-stub.sql` and `prod-drift-after-17.sql` (columns production has that no migration creates).
- Production: probes inside `begin; … rollback;`; pen-test recipe in the playbook (Rev 23). Test orders are named `TEST — Claude` and cleaned up afterwards (Rev 36 cleanup record).
- Preview servers: the desktop app reads `~/Downloads/.claude/launch.json`, not the repo; serve a scratchpad copy (playbook Rev 23 notes).

---

### 4.7 Revision history

#### Before the "Rev" sections (from `git log`)
- **Aug 8–9, 2026:** initial commit and "Initial TPN OS with Supabase"; MVP with real Supabase sign-in; admin-only account creation through the `create-staff` edge function; Supabase credentials added; KDS, live order sync, real sales data, single branch; session persistence; persistent schedules and pending-account workflow.
- **Aug 10:** phase 2 (delivery address, notes, scheduled time, order tracking, table QR, realtime table progress); phases 3–6 (floor sign-in gate, staff board fix, attendance and messages, password change, dynamic table QR); fake floor data purged; extensionless URLs; branded boot overlay.
- **Aug 11–13:** nav fixes; security hardening, notifications tab, cross-device sync; cache-busting; performance analytics; Excel exports; discounts and promos; kitchen station page (sql/15).
- **Rev 1–3:** not found in HANDOFF.md.
- **Aug 14 (hardening release, WHATS-NEW.md):** order totals locked to the recompute path, discounts versioned and audited (sql/16), order lifecycle audited, TRUNCATE revoked (sql/17).
- **Rev 4 (Aug 22)** (only named in HANDOFF's "Last updated" line): access control and custom roles, tasks, inventory and finance, real i18n, anonymous pickup/delivery ordering fixed (sql/18–23); customer ordering through `submit_order`/`track_order`, shared table bills, payroll (sql/24–25); status-change audit, guest memory (26–27); split bills, daily close, stock variance, working add-ons, prep targets, low-stock alerts (28). Also the login lockout from a stale cached script (the origin of the `?v=` rule) and the CEOs' 18-suggestion review.

#### Rev 5 to Rev 36 (oldest first)

**Rev 5 — UI/UX reliability pass (Oct 2).** No SQL. Realtime channels rebuild themselves (`TPN.liveChannel`), Manila calendar day helpers, "Tap to start" for sound on wall screens, one error panel for ~22 lists, double-tap guards on ~27 actions, accessible dialogs. Floor: live status, safety re-fetch, call/bill queue with "On it", Close Table settles properly. Kitchen: real connection status. Left open: schedule week keys saved as Sundays.

**Rev 6 — v2 overhaul and security hotfix (Oct 15–16).** sql/29 (server-side prices, anon order access closed, staff screens escaped) and 29c live; then 29a–34 on the v2 branch. New rules: one ordering door, derived payment status, daily close on received cash, senior/PWD VAT-exempt + 20% on the covered share, clock-in by server functions with photos, stamps only from the trigger, new tabs as modules, `E()`/`JA()` escaping, PGlite tests (82 checks). Found migration 06 never applied on production.

**Rev 7 — faster pages, hubs, Counter on the floor (Oct 17).** `portal.html` split from `index.html`; blur only on floating chrome; portal sidebar grouped into ~10 hubs; the Counter becomes a tab on the floor screen; Close table takes cash for every open order at once (sql/35). Fixed the Add-ons module that no page loaded and the broken change-password call.

**Rev 8 — read receipts, Tagalog everywhere, layout, guide (Oct 17).** Per-person read receipts and a closed hole on broadcast message edits (sql/36); table QR page in one retried query with locally drawn QR codes; ~1,300 English→Tagalog phrases in `tpn-i18n.js`; Accounts & access layout; portal search (Ctrl/⌘+K); the "How do I…?" guide with Show me and a first-sign-in tour.

**Rev 9 — manual payments, delivery, iMin counter, glass and motion (Oct 17).** All payments taken by hand with a reference (sql/37a/37b); delivery areas, fees and dispatch (sql/38); iMin printer and cash drawer through iMinprinterplugin (`modules/imin.js`); installable counter (`counter.webmanifest`); glass look and gentle motion on floor, QR menu and kitchen.

**Rev 10 — home page cleanup, tray, printed receipt (Oct 17, branch `feature/home-no-pills`).** Home loses eyebrow labels and pill shapes; phone hero stops jittering; the tray gets a cloche icon and opaque drawer; checkout step 5 prints an animated receipt. (Two sections in HANDOFF are numbered Rev 10; this is the first by date.)

**Rev 11 — phone hero and load speed (Oct 17).** Touch devices use `100svh` so the hero stops growing mid-scroll; phones got a smaller hero image (later reversed in Rev 14); head scripts preloaded so they download in parallel; faster card reveals.

**Rev 12 — new dish photos (Oct 17).** Nine dishes with cut-out photos; spin balanced on the largest inscribed circle.

**Rev 13 — touch hero pinned, more dish photos (Oct 17).** Hero height pinned in px for in-app browsers; 18 dishes with photos; photo URLs carry `?v=PHOTO_V`; real photos of the place added.

**Rev 14 — smooth scroll-up, full-resolution photos (Oct 17).** Map no longer redraws on every toolbar resize; `will-change` only near the screen; the owner's photos used at full resolution (no recompression, a standing rule); Our place shows both room photos.

**Rev 15 — new sisig photo, Our place layout, dish descriptions (Oct 17).** Clean sisig cut-out; portrait plus square-over-map layout; `sql/40` adds short descriptions for 42 dishes (Tagalog in `PHRASES`).

**Rev 16 — checkout that survives customers (Oct 17).** Checkout keeps its step and answers across refresh, Back/Forward and other tabs; the receipt survives a refresh for 2 hours; scheduled orders can't be in the past. Gap left: a retry after a lost reply could create a second order.

**Rev 17 — the portal wears the website's look (Oct 17).** `tpn-portal.css`: font aliases to Fraunces/Plus Jakarta Sans, paper light theme, sentence-case labels, 12px rounded shapes, drawn SVG hub icons, full-length toasts.

**Rev 18 — a retry can't place a second order (Oct 17).** `sql/41`: `submit_order` takes an idempotency key; the website and QR menu send one. Gap left: the counter didn't send a key (closed in Rev 21). sql/40 and 41 applied to production.

**Rev 19 — portal Parking and Landmark reach the website (Oct 17).** Parking, landmark and email come from the portal's Website settings; Our place photos swapped; page title "Tyo Paeng Nyo · Las Piñas"; the badge logo as the site icon and share image.

**Rev 20 — silog photos, new laing and ginataang photos (Oct 17).** Tocilog, Bacon Silog, Chicksilog photos; `sql/42` renames Chicken Silog to Chicksilog and restores Tocilog (₱115), which had gone missing on production.

**Rev 10 (second) — QR table menu matches the website (Oct 20).** `tpn-table-menu.html` rebuilt on the website's design and components; tray → Review → Send → live status; Call staff and bill dock; pay at the table by picking Cash or QR and asking for the bill; card hidden until enabled; the fake QR service removed.

**Rev 21 — offline counter (Oct 20).** Service worker and IndexedDB outbox; OFF-numbered orders with paper tickets; cash-only offline payments replayed safely; the counter now always sends an idempotency key. Same day: nightly encrypted backups set up and restore-tested (HANDOFF "Backups").

**Rev 22 — BIR booklet invoices, ready for Vercel (Oct 21).** `sql/43` and `modules/invoices.js` (when a handwritten invoice is needed, the ₱500 line, end-of-day invoice); `vercel.json` and `.vercelignore`; hard-coded `/tpn-os/` links removed. Tests 141/141.

**Rev 23 — security pass (Oct 21).** Pen test found an admin could make themselves CEO; `sql/44` adds rank guards on staff and permission overrides. CSP pinned to exact CDN files. Fallbacks: printer calls never throw, BIR panel shows a retry, QR menu re-looks up its table, kitchen login retries. Tests 153/153. Listed open items for the offline outbox and timeouts.

**Rev 24 — customer screen and TPN Counter app (Oct 21).** The back-screen page `tpn-dine-in-floor-customer.html` with Welcome / Order / Pay / Thanks states and GSAP motion, linked over four transports (`modules/customer-display.js`); the Android wrapper in `android/`, built by GitHub Actions; signing key made and secrets set; first build green (86 KB WebView app).

**Rev 25 — the iMin's old WebView, back-screen layout (Oct 21).** The real device is an iMin D4-504, Android 11, no Play Store, WebView 83; the site needs Chrome 85+/87+. The app warns about old WebViews; the back screen rewritten for old engines; logo top-left, no subheadings.

**Rev 26 — the counter runs in Chrome, the app drives the back screen (Oct 21).** `CustomerScreenService` keeps the back screen up as an overlay and runs the loopback link on `127.0.0.1:8091`; on old WebViews the counter opens in Chrome (version 104) and talks to the app over that link.

**Rev 27 — welcome loop; in-app engine on hold (Oct 21).** The TPN → TyoPaengNyo → Mabuhay! → Kain na! welcome loop; the owner wants the counter inside the app, so a GeckoView build is prepared (stashed, not committed) pending an iMin system-update check.

**Rev 28 — one app with its own engine; brand reel (Oct 21).** TPN Counter 1.1 bundles GeckoView 153 (~165 MB); opens on the portal, floor and kitchen open inside it, offline launch to the counter; floor admits `floor.view`; the back screen plays a ~24s brand motion reel at 60 fps.

**Rev 29 — reopens where it left off; light drawing on the iMin (Oct 21).** The app remembers the last page; counter mode (`html.tpn-lite`) strips blur and long animations inside the app; the back reel gets a lite mode for weak devices.

**Rev 30 — every person signs in at the counter (Oct 21).** The floor screen gets its own v3 sign-in; the top bar shows "First name · Role"; Switch user warns about an open drawer; app 1.2.0 opens on the counter.

**Rev 31 — TPN Kitchen app; one shared station sign-in (Oct 21).** Counter and Kitchen flavors from one project; `modules/signin.js` shared by both stations; nothing remembered at sign-in; signing in clocks you in, Switch user clocks you out; publish both APKs in one `apps-X.Y.Z` release.

**Rev 32 — printed slips in the v3 look; test buttons (Oct 22).** `modules/slips.js` draws the kitchen ticket and receipt as one black-and-white picture; the iMin prints it with a text fallback and a one-at-a-time queue; Test kitchen ticket / Test receipt. Printed on the iMin and approved by the owner.

**Rev 33 — kitchen network printer, test prints from the counter; apps 1.4 (Oct 22).** The app relays ESC/POS bytes to a kitchen printer (`/print`, private IPs, ports 9100–9109); `modules/kprint.js`; printer tools limited to managers (`sql/45`, `printer.manage`); release `apps-1.4.0`.

**Rev 34 — kitchen tickets: kitchen printer, counter printer or screen only (Oct 22).** The "Kitchen tickets" setting per device; counter orders route through it; guests' QR and website orders print in the kitchen from the floor screen in kitchen mode, once each; only one device should be in that mode.

**Rev 35 — table bills print; one receipt per table; apps stay on staff pages; dish photos at the counter (Oct 22).** The floor's Bill button and a guest's QR bill request now print the table bill; Close table prints one combined receipt; the stamp QR made reliably scannable; inside the apps the public pages redirect to the station; dish photos moved to `modules/photos.js` and shown at the counter.

**Rev 36 — full live test; the bell keeps read things read; one look for every text box and alert (Oct 22).** A full live test of every button with `TEST — Claude` orders (money matched across X read, daily close and dashboard), then cleaned up. Fixed: the bell showed other people's notifications that couldn't be marked read (`sql/46`); all 13 native `confirm()`/`prompt()` replaced (Approve void had done nothing inside the apps); `tpn-forms.css` gives every text box, label, toast and dialog the theme; floor and kitchen fonts and phone top bars; peso amounts with commas; QR links without a table ask for the code. Left for the owner: the two-bills race, the guest phone's message after paying, sold-out dishes vanishing, and the design-rule leftovers. Next free migration: 47.

---

### 4.8 Where everything lives, and the accounts

#### On the owner's Mac: `~/Downloads/tpn-os-study/`

| Path | What it is | Rules |
|---|---|---|
| `tpn-os/` | The git clone of `UnoRfl/tpn-os` (`main`). Also has local-only branches never pushed: `feature/counter-chrome-relay`, `feature/counter-signin`, `feature/idle-morph`, `feature/idle-tpn-story`, `fix/badge-clear-button`, `fix/counter-old-webview`, `fix/counter-signin-theme`, `perf/counter-lite` | Pull before editing. |
| `keys/` | App signing key `tpn-counter.p12` (alias `tpncounter`), `keystore-password.txt`, `tpn-counter.p12.b64.txt` (for the GitHub secret), `README.txt` | **Never commit, never paste anywhere.** Keep an offline second copy. |
| `apk/` | Downloaded builds: `tpn-counter.apk` and `tpn-kitchen.apk` (Oct 21, 1.3), and `apk/1.4/` with the 1.4 pair | Each about 165 MB. |
| `TPN-OS-PLAYBOOK.md` | This Mac's summary of how the other Claude builds TPN OS | Synced Oct 21; says "rev 9" in its header but its later notes cover Rev 21–24. |
| `tools/platform-tools/` | Android `adb` and friends, for checking the iMin over USB (GO-LIVE §8) | |
| `tpn-os-site/`, `site-screenshots/`, `site-screenshots.zip` | An older site copy and screenshots (Oct 17) | Not covered by the docs. |

Also: the desktop app's preview servers read `~/Downloads/.claude/launch.json` (playbook).

#### Elsewhere
- **Headless PC** (Windows, always on): `C:\TPNBackup` with the backup task, dumps, log and `secrets\` (4.5). Reached as `ssh headless`.
- **Uno's main PC:** the backup private key in `C:\Users\pc\TPN-Backup-Key`.
- **The iMin D4-504** at the counter: TPN Counter app, iMinprinterplugin; StoreHub and an old Chrome shortcut "tpn-meal-tracker" were also installed (Rev 25).

#### Accounts

| Account | Role |
|---|---|
| GitHub **UnoRfl** | Owner of `tpn-os`; has the `workflow` scope; set the signing secrets; earlier commits (Aug–Oct 21). |
| GitHub **JaPat24** | Collaborator; the default `gh` account on this Mac; publishes the app releases. |
| Supabase project `xjlqfpnzobfqxetgkkai` | Database, auth, realtime, storage, `create-staff` function. Owner of the Supabase account: not stated in the docs. The HANDOFF's old "Deferred" notes mention an "uncle" transfer to a paid project, not done. |
| Staff logins | Created only through Portal → Accounts (`create-staff`); public sign-up is off. The first CEO was promoted by SQL (README). |

---

### 4.9 Gaps and things not found

- **Rev 1–3** are not in HANDOFF.md; Rev 4 appears only in the "Last updated" line.
- **`sql/39-menu-oct-2026.sql`** is not in production's recorded migration history; how it was applied is not recorded.
- **Offline copies** of the app signing key and the backup private key: the docs say to make them; no record that they exist.
- **App rollback** (installing an older APK) is not documented.
- **Staging environment** and **error monitoring**: none.
- **BIR procedure details** beyond Rev 22's one sentence: not found.
- **Kitchen device model** for TPN Kitchen: not stated.
- Whether the kitchen station uses `menu_items.prep_minutes` for ticket ages: not found in `tpn-kitchen-station.html`.
- HANDOFF's "Daily close reads declared payments" section, README, TESTING and WHATS-NEW are out of date (4.5).
- At the time of writing, the Mac clone had **uncommitted changes** to `modules/imin.js`, `modules/slips.js` and `tpn-i18n.js` (a new "Test bill" print, `TPN_PRINT.testBill`). They are not on `main` and are not described above.
