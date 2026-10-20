# TPN OS — Session Handoff

**Last updated:** Oct 20, 2026 (rev 21 — offline counter, see "Rev 21"). Earlier: Oct 17, 2026 (rev 8 — read receipts, Tagalog everywhere, layout, guide; see "Rev 8"). Rev 7 — portal split out of the website, hubs, Counter on the floor screen; see "Rev 7"). Rev 6 (Oct 16 — v2 overhaul, see "Rev 6" and GO-LIVE.md). Previously rev 5 — UI/UX reliability pass, no migrations; see "Rev 5" below). Rev 4 (Aug 22): split bills, daily close, variance, working add-ons, low-stock alerts; migrations 18–28
**Deployed:** https://unorfl.github.io/tpn-os/
**Repo:** https://github.com/UnoRfl/tpn-os
**Supabase project ref:** `xjlqfpnzobfqxetgkkai` (single project, single branch)

---

## Current state

**MVP is functionally complete.** The site handles the full restaurant-management workflow end-to-end using real Supabase data. Zero hardcoded/fake demo data remains. All 4 files pass Node syntax checks.

### File layout
```
tpn-os/
├── index.html                 public website only (~130 KB)
├── portal.html                staff portal (~460 KB); index.html?view=… redirects here
├── tpn-app.css                styles shared by index.html + portal.html (cached once)
├── tpn-glass.css              glass layer; real blur only on floating chrome (see Rev 7)
├── tpn-ui.css                 portal controls for non-portal pages (the floor screen hosts the Counter)
├── tpn-supabase.js            ~625 lines — TPN.* helper layer over supabase-js
├── config.js                  Supabase URL + anon key (never commit real secrets from other envs)
├── tpn-table-menu.html        ~870 lines — customer-facing QR-scanned menu
├── tpn-dine-in-floor.html     ~1200 lines — manager-facing floor overview
├── sql/                       migrations 01–09 (run in order in Supabase SQL Editor)
├── supabase/functions/
│   └── create-staff/          edge function for auth.admin.createUser
├── HANDOFF.md
└── README.md
```

### Working systems

| System | State |
|---|---|
| Public marketing site + navigation | ✅ live |
| Menu display (categories, featured, pax pricing) — reads DB | ✅ live |
| Customer checkout (dine-in/pickup/delivery) with delivery_address, notes, scheduled_for | ✅ live |
| Anonymous order tracking by `order_number` | ✅ live |
| Table QR codes — absolute URLs, dynamic count from DB, "+ Add Table" button | ✅ live |
| Table dine-in menu — realtime progress via `subscribeToOrder` | ✅ live |
| Call-staff / bill-request signals | ✅ live |
| Live Orders kanban (portal) | ✅ live |
| Kitchen Display System with chime + age counters | ✅ live |
| **Dine-In Floor Panel** — accessible from portal sidebar, real Supabase data only, single branch | ✅ live |
| Auth gate on floor panel (manager+) | ✅ live |
| Inquiries with `tel:`/`mailto:` and DB persistence | ✅ live |
| Menu Manager CRUD | ✅ live |
| Staff Board with correct DB enum roles + Leadership row | ✅ live |
| Persistent Schedules (staff view + admin editor + copy-week) | ✅ live |
| **Attendance** — clock in/out, real stats, admin correction modal | ✅ live |
| **Messages** — inbox + broadcasts + realtime toasts + badges | ✅ live |
| Accounts / staff creation via edge function | ✅ live |
| Audit log (admin+ only) | ✅ live |
| Change Password modal → `sb.auth.updateUser` | ✅ live |
| **Display device accounts** (`kitchen_display`, `dine_in_display`) — screen-only logins, portal-blocked | ✅ live |
| **Void requests** — request → manager approve/deny, realtime both ways, full audit trail | ✅ live |
| Dashboard tiles + revenue drilldown + prep-time analytics | ✅ live |
| Session restore with **branded boot overlay** (no flicker) | ✅ live |
| **Extensionless URLs** (`/tpn-table-menu`, `/tpn-dine-in-floor`) | ✅ live |

---

## Rev 21 — offline counter (Oct 20, 2026, branch `feature/offline-counter`)

If the restaurant's internet drops, the Counter keeps taking orders for as long as the device has power. Only the floor screen changes; the website, portal, kitchen screen and QR menu behave as before.
- **Opens with no internet:** `tpn-counter-sw.js`, registered by `modules/offline.js` with scope `./tpn-dine-in-floor`. At install it precaches every `<script>`/`<link>` the floor page names, plus Google Fonts. Versioned (`?v=`) and `vendor/` files are cache-first; the page and anything else is network-first (4s). The last menu, modifiers, tables, branches and delivery zones are network-first Supabase GETs (5s) with the last answer as fallback. Nothing with customer data or money is cached. **The device has to open the floor screen online once after this deploys, and once more after that, so the menu is in the cache.** Bump `VERSION` in the worker to drop old caches.
- **Sign-in offline:** `offline.js` remembers this device's staff profile and permissions (`localStorage tpn.offline.me`, only while the stored Supabase session has the same user id). The auth gate gives `getSession()` 6s; an expired token can't refresh offline, so the gate opens on that remembered profile. The token refreshes when the connection returns. This only decides what the screen shows; the database checks the real session when the outbox syncs.
- **Outbox (IndexedDB `tpn-counter`):** the Counter now always sends an idempotency key (`TPN.orderKey`, sql/41), which closes the "counter POS doesn't send a key" gap from Rev 18. When offline, or when a send fails with no answer (or takes over 15s), the order is saved with that key and a local number (`OFF-007`). Its kitchen ticket prints straight away, with the table or guest name, whatever the "print kitchen ticket" setting says. Replay runs oldest first when a probe of `/auth/v1/health` succeeds: on the `online` event, every 15s while anything is waiting, and on page open. It never sends without a staff session (`submit_order` is also the guests' door). A key the server has seen returns the first order, so a send that landed before the line dropped is not doubled.
- **Cash offline:** take-out and delivery open an offline payment panel. Cash is checked against the total estimated from the cached menu, and the drawer pops. GCash, Maya, QR Ph, card and bank are disabled with the reason; "Pay later" leaves the order unpaid. On replay the cash goes in with `p_amount null` (the server's total), tagged `offline OFF-007 <key>` in the note. Before sending, the replay checks the order's payments for that tag, so a payment whose answer was lost is not recorded twice. A second full payment is also refused by `nothing_due`. If the server's price is higher than the cash taken, that entry fails with "collect ₱X more". The regular payment panel (`payments.js`) disables the reference methods offline, and cash on an existing order queues if the server doesn't answer.
- **Chip and panel:** "📴 Offline: N orders waiting to sync", "⟳ Syncing…", or "⚠ N failed to sync" on the top bar. Tapping it lists each entry: Waiting, Synced as TPN-…, or Failed with the server's reason (sold out, price changed…), with Try again / Payment / Remove. Synced rows stay 24h so OFF numbers can be matched to real ones.
- **Print fallback:** where pop-ups are blocked, kitchen tickets print from a hidden frame instead of not at all.
- **Still needs the internet:** opening/closing a shift, Close table (`settle_table_cash`), voids, 86, X/Z reads, receipts that read the order back. QR and website orders still reach Supabase over the guests' mobile data, but this counter only sees them after it reconnects (the kitchen screen is blind too).
- **How long can it run blind?** As long as the counter has power, and the browser storage is not cleared. A day of orders is a few hundred KB. The limit is the Supabase refresh token: it has to still be valid when the connection returns (no session time-box is set today). If not, the chip says "Sign in again to sync"; the orders stay in the outbox until someone signs in on that device.
- **Tested:** in a local harness (not in the repo) with a fetch shim that cut Supabase and stopped the web server. The page loaded, took a take-out with cash and a dine-in, and printed through the hidden frame. After reconnecting, a deliberately lost `submit_order` answer and a lost cash answer each replayed to exactly one order and one payment. A price change and a sold-out refusal showed as failures, and Try again during a running sync was not lost. Against production, in a rolled-back transaction as a director: the same key twice returned TPN-…-0045 both times (one row), and a second cash record was refused with `nothing_due`. Nothing persisted. Not tested on the D4 itself (iMin printing offline goes through the same local `ws://127.0.0.1:8081` call as online).
- Asset versions: `modules/pos.js`, `payments.js`, `imin.js` `?v=20261020a` on the floor screen and the portal; `modules/offline.js?v=20261020a` (floor only).

## Rev 10 — home page cleanup, tray, printed receipt (Oct 17, 2026, branch `feature/home-no-pills`)

- **Home without labels or pills:** the eyebrows over "Our Bestsellers" and "Our place" are gone (the engraved title names the section). Buttons, nav bar, tray and language toggle use 9–18px corners instead of 999px. Dish marks are sentence case with a saffron dot; "Bestseller" is hidden inside the bestsellers bento. The footer headings are sentence case and the payment list is a plain stack.
- **Phone hero:** at ≤900px the hero photo, wash, vignette and mandala are `position: absolute` and `heroScroll()` leaves them alone (`heroStill` in `tpn-home.js`). The fixed, scaling photo jittered as mobile browser bars slid in and out. Desktop is unchanged.
- **Tray:** the nav button is a cloche icon + "Tray", with the count after a hairline only when there is something in it (`.cart-btn.has`). The FAB uses the same icon. The drawer is `--v3-sand` with the site paisley in a deeper brown (`.cart-decor`), and it is opaque, so it has no blur. Empty state: one line and the menu button; no emoji.
- **Printed receipt:** step 5 of checkout prints a receipt out of a small printer (`.rcpt-*` in `tpn-site-v3.css`). Lines come from the tray; subtotal, delivery fee and total come from `submit_order`'s return (`checkoutData.receipt`, set in `confirmOrder`). Feed time scales with the line count (`--print`). The rest of the screen fades in afterwards, and the page scrolls the printer into view first. Off under reduced motion.
- Asset versions: shared `?v=20261017j` (tpn-i18n.js gained 4 phrases), v3 files `?v=20261017v16`.

## Rev 20 — silog photos, new laing and ginataang photos (Oct 17, 2026, branch `feature/silog-photos`)

- **New dish photos:** Tocilog, Bacon Silog and Chicksilog are new (`tocilog`, `bacon-silog`, `chicksilog` in `PHOTOS`). Laing and Ginataang Sitaw at Kalabasa have new photos under the same file names. `PHOTO_V` is `20261017f`. The three silogs rank just above Tapsilog in `PHOTO_RANK`.
- **How they were made:** the owner's photos were on pure white, two dishes per sheet. A flood fill from the border clears near-white and the pale drop shadow (min channel ≥ 165, spread ≤ 22), and the largest shapes are kept. A 2px edge is un-mixed from white so there is no halo. Each file is centred on its largest inscribed circle for the spin, at the source's full resolution (≈590–720px; Chicksilog 1076px), WebP q92 with lossless alpha.
- **`sql/42-silog-menu.sql`** (data only) renames Chicken Silog to Chicksilog and puts Tocilog back (₱115, sql/39's order and description). It had gone missing on production. `sql/39` now says Chicksilog too, so re-running it can't undo the rename. Applied to production Oct 17. Test: `t_42_silog_menu.sql`; 126 passed.
- Asset versions: v3 `?v=20261017v30` (tpn-home.js).

## Rev 19 — portal Parking and Landmark reach the website (Oct 17, 2026, branch `feature/site-parking-landmark`, stacked on Rev 18)

No migration. The portal's Website → Contact & hours tab already saved `contact.parking` and `contact.landmark` (sql/30), but the site printed its own fixed text.
- **Parking:** the Our place facts row and the footer line read `contact.parking` through `data-site`. Blank hides the whole row. The old `v3.fact.parkingVal` / `v3.f.parking` keys are gone from `tpn-home.js`; the Tagalog comes from `PHRASES`.
- **Landmark:** a small line under the address in Our place (`.v3-landmark`), and the map card's second line. Blank hides both.
- **Email:** `data-site-href="mailto"` in `tpn-site.js`, so a filled-in email in the footer is a working link (only when it looks like an address).
- **Map card redraw:** `tpn-site.js` fires `tpn:site-content` after applying; `tpn-home.js` redraws the map so a changed address or landmark shows without waiting for a resize.
- **Our place photos swapped:** the evening room is now the tall photo on the left and the garden wall is the square on the right.
- **Page title** is "Tyo Paeng Nyo · Las Piñas" (title and og:title).
- **Logo as the site icon:** `assets/site/icon.png` (the official badge, `logo.webp` padded to a 200×200 square at full size; no larger original exists). It is the tab icon on every page, the home-screen icon (the old `/apple-touch-icon.png` pointed outside the Pages site and 404'd), and the share image (`og:image`, which pointed at a domain we don't serve). Give it a bigger logo file to get a sharper share preview.
- Asset versions: shared `?v=20261017o`, v3 files `?v=20261017v29`.

## Rev 18 — a retry can't place a second order (Oct 17, 2026, branch `feature/order-idempotency`)

Closes the gap Rev 16 left open: the connection drops after the server saved the order but before the reply, and the customer taps Place Order again.
- **`sql/41-order-idempotency.sql`:** `submit_order` takes an optional `p_client_key` (old signature dropped and recreated, same revoke/grant). The key goes on `orders.client_key` (unique index `orders_client_key_uniq`) for an order the call opened, and on `order_items.client_key` for every line it added, so a QR round appended to a table bill is covered too. A repeat key in the same branch inserts nothing and returns the original order through `private.submit_order_reply`, in the same jsonb shape. The key check runs after the rate limit and branch checks and before item validation, so a dish that sold out in between can't turn a retry into an error. Two copies racing are caught by the row lock (appends) or the unique index (new orders). Keys must be 16–64 of `A-Za-z0-9-` (`bad_client_key`); a key already used at another branch is `client_key_in_use`.
- **Website:** `confirmOrder` builds the key with `TPN.orderKey(prev, sig)` and saves it in `tpn_checkout_v1` (`checkoutData.orderKey`) before sending, so a refresh then a retry reuses it. `sig` is the order type, payment, name, phone, address, zone, time, notes and lines: change any of them and it is a different order with a new key. The key is dropped once the order is placed.
- **QR menu:** same, kept in sessionStorage `tpn_order_key_<branch>_t<table>` and removed once the round is sent.
- **Before sql/41 runs:** `TPN.createOrder` retries without the key when PostgREST can't find the new signature (`PGRST202`), so the site never stops taking orders.
- **Not covered:** the counter POS doesn't send a key (staff see the order appear on the floor screen).
- Tests: `tests/db/t_41_idempotency.sql` (14 checks), 123 passed.
- **Live:** sql/40 and sql/41 were applied to production on Oct 17 (the live function bodies match the file). A rolled-back live check showed that a retry returns the same order and that the old keyless call still works.
- Asset versions: shared `20261017n` on every page.

## Rev 17 — the portal wears the website's look (Oct 17, 2026)

`tpn-portal.css` is new and loaded only by `portal.html`, after `tpn-glass.css`. The floor, kitchen and QR screens don't load it.
- **Fonts by alias:** `@font-face` maps "Playfair Display" and "Lora" to Fraunces, and "DM Sans" to Plus Jakarta Sans (gstatic woff2, allowed by the CSP). The ~80 hard-coded font names keep their roles without editing each rule. `portal.html` no longer requests the old families. If you add the old Google Fonts link back, the aliases conflict.
- **Light theme:** paper tones (`--bg #F7F0E2`, surfaces `#FFFDF8` / `#F4EAD8`) and warm, offset shadows. Dark and night are unchanged because their selectors outrank `:root`. Checked in dark.
- **Labels and shapes:** sentence case and no tracking across the portal. Buttons, chips, tabs and the branch chip are 12px rounded rectangles; badges are 7px. The primary button is flat ember (no gloss). Switches and avatars stay round.
- **Icons:** hub icons are drawn SVGs (`TPN_HUB_SVG` in `portal.html`; an unknown hub falls back to its own icon). The search buttons use an SVG magnifier (`modules/search.js`). A large lone emoji used as decoration (tiles, empty states, kanban lanes) gets `.tpn-deco-emoji` and is hidden by a small observer in `portal.html`; emoji inside text and buttons stay.
- **Toasts** wrap to the full message (they were cut off on phones) and sit above the help button.
- Checked with a fake signed-in session in a local preview (no data): Dashboard, Live Orders, Menu Manager and Accounts at 1280px and 375px, dark theme, sidebar active state, and a long toast. Pages that need real data (payroll, finance with numbers) were only seen in their empty or error state.
- Asset versions: shared `20261017m` (search.js), `tpn-portal.css?v=20261017p1`.

## Rev 16 — checkout that survives customers (Oct 17, 2026)

All of this lives in `index.html`, at the top of the checkout section (`renderCheckoutStep` is now a wrapper around `renderCheckoutStepView`).
- **Refresh** keeps the step and the answers. They are stored in sessionStorage `tpn_checkout_v1` (this tab only), and typed fields are saved as they are typed. Restoring never skips past a step whose answers are missing.
- **Refresh on the receipt** shows the same receipt again without re-printing it. The last order is kept in localStorage `tpn_last_order_v1` for 2 hours. Starting a new order clears it.
- **Browser Back/Forward** moves between checkout steps (each step is a history entry `{ck: n}`). The on-page Back uses the same history, and once ordered, the receipt stays put.
- **Another tab** emptying the tray (or placing the order) empties it here too, through the `storage` event. An empty tray at checkout shows "Your cart is empty!" with a menu button and can't be submitted.
- **Scheduled orders** can't be in the past or under 15 minutes away (`min` on the date input, plus a check). Name, phone, address and notes have max lengths.
- **Double or triple taps** on Place Order still send one order (the existing busy guard, re-tested).
- **Not covered:** if the connection drops after the server saved the order but before the reply arrives, a retry can create a second order. `submit_order` has no idempotency key; adding one is the real fix.
- Asset versions: shared `20261017l`, v3 `20261017v28`.

## Rev 15 — new sisig photo, Our place layout, dish descriptions (Oct 17, 2026)

- **Pork Sisig** has a new cutout, shown as the whole oval sizzling plate centred on a sand disc (`#F4EAD8`) that fills the round frame, like an eye in an eyeball. It is not cropped. `PHOTO_V` is `20261017e`. The automatic (Vision) cutout had dropped most of the wooden board. For a photo on pure white, a flood fill from the border is exact: near-white pixels connected to the edge become transparent, edge pixels are un-mixed from white so there is no halo, only the largest shape is kept, and the result is centred on its bounding box.
- **Our place:** the garden room is a tall portrait on the left. On the right, the evening room is a square (`aspect-ratio: 1`) over a wide map (`aspect-ratio: 2.4`, `width: 100%`; 1.8 at 900px and below). The columns are `minmax(0,1.085fr) minmax(0,1fr)`, so the portrait stays near 3:4 and both sides end level; measured at 1440, 1280, 1024, 887 and 768px. Keep `width: 100%` on the map: its 220px minimum height otherwise widens it to keep the ratio. Phones stack portrait (3:4), square and a 230px map.
- **`sql/40-menu-descriptions.sql` (not yet run on production):** short English descriptions for the 42 dishes that had none, matched by name. It only fills empty descriptions, so Menu Manager edits survive. The Tagalog for each is in `PHRASES` in `tpn-i18n.js`, because `menu_items` has no Tagalog description column. The wording is generic; correct any dish in Menu Manager. Not run through tests/db, since it is data only and the PGlite package was not installed on this machine.
- Asset versions: shared `20261017k` (tpn-i18n.js), v3 `20261017v27`.

## Rev 14 — smooth scroll-up, full-resolution photos (Oct 17, 2026)

- **Scrolling up no longer "unloads" anything on phones.** A phone toolbar sliding back fires `resize`, and `drawMap()` rebuilt the whole map (every tile reloaded). It now redraws only when its size, place, address or language changes (`data-drawn`). Spinners and paisley layers get `will-change` only while within 300px of the screen (`onScreen` in `tpn-home.js`), so phones aren't evicting and repainting 59 GPU layers. Don't put `will-change` back in the CSS for those.
- **Full resolution only.** The owner found the recompressed photos blurry. Place photos are the original files (`assets/site/photos/dining-garden.webp`, `dining-evening.webp`), and phones use `hero.webp` again. `hero-sm.jpg` and the food-strip JPEGs are deleted. Don't downscale or recompress photos the owner sends.
- **Our place** has both room photos (`dining-garden`, `dining-evening`) at their own 3:4 shape, with no crop and no hover zoom beyond 3%, and a narrower map beside them (`1fr 1fr .8fr`). On tablets the map goes below at 300px; on phones everything stacks and the map is 340px. The food strip is gone.
- v3 asset version `20261017v22`.

## Rev 13 — touch hero pinned, more dish photos (Oct 17, 2026)

- **Touch hero height is pinned in px.** `lockHero()` in `tpn-home.js` sets `--hero-h` to `innerHeight` at load and re-reads it only when the width changes (rotation). In-app browsers such as Messenger and Instagram resize the page itself when their toolbar hides, so svh/vh still moved and the photo rescaled on the first scroll. The hero mandala width no longer uses vh on touch devices.
- **18 dishes have photos.** New: Cornedbeef Silog, Sisig Silog, Liemposilog, Tapsilog, Calamares, Beef Bistek ("Bistek" on the photo sheet), Pancit Bihon, Ginataang Hipon. Buttered Shrimp has a new photo.
- **Long dishes** (Pork Sisig on its board, Pancit Bihon in its tray) are cropped to a circle the size of the largest circle inside the dish, so they fill the round frame like the bowls do.
- **Dish photo URLs carry `?v=PHOTO_V`** (`tpn-home.js`). Bump it whenever a photo is replaced under the same file name.
- **Cutout tool notes:** a dish photographed edge to edge needs a white margin before Vision will treat it as a subject. Subjects are merged per quadrant, so a dip bowl stays with its plate.
- **Photos of the place** in `assets/site/photos/` (JPEG, letterbox bars trimmed). "Our place" shows only the place: `dining-garden` (tall) and `dining-evening`, then the map; the grid now has three children. The food shots (`shrimp-table`, `sisig-table`, `laing-table`) are a heading-less strip (`.v3-strip`) between Bestsellers and Our place. The Restaurant page photo is `dining-evening` (it was `spread.webp`, which is now unused).
- v3 asset version `20261017v19`.

## Rev 12 — new dish photos (Oct 17, 2026)

- Nine dishes have photos now (`PHOTOS` in `tpn-home.js`, keyed by lower-case menu name). New: Beef Caldereta, Kare-Kareng Lechon Kawali, Ginataang Sitaw at Kalabasa, Pork Sisig, Adobong Pusit with Gata, Teriyaki Wings, Laing, Buttered Shrimp. Kept: Pares. `beef-chili.webp` and `sitaw-pork.webp` are replaced and removed.
- **How they were made:** macOS Vision subject masks (cutouts from the owner's photo sheets), then WebP from the browser at q.82, max 600px, 45–65 KB each.
- **Spin balance:** each file is centred on the middle of the largest circle that fits inside the dish, not on its bounding box. That way the laing/ginataang basket knot and the sisig board handle don't make it wobble. The canvas is as big as the farthest opaque pixel, so nothing clips while it turns. Use the same rule for new photos.
- v3 asset version `20261017v18`.

## Rev 11 — phone hero and load speed (Oct 17, 2026)

- **The phone "zoom" was `100dvh`.** dvh grows as the mobile browser bar slides away, so the hero grew mid-scroll and its cover photo rescaled. Touch devices (`(max-width: 900px), (hover: none) and (pointer: coarse)`, the same query in CSS and in `heroStill`) now use `100svh`, which stays still. Desktop keeps dvh and the recede effect.
- **Phones get `assets/site/hero-sm.jpg`** (1200px, 280 KB) instead of the 1.3 MB `hero.webp`. Each is preloaded only for its own media query.
- **The head no longer waterfalls.** The stylesheets come before the scripts, and every head script has a `<link rel="preload">`, so they all download at once and still run in order. Live, on a phone, the six scripts used to take about 2.2s back to back before any CSS started. If you add a head script, add its preload with the same `?v=`, or it falls back into the queue.
- Below-the-fold mandalas on home are `loading="lazy"`. Cards reveal in .55s with a 40ms stagger (was .9s/60ms).
- v3 asset version `20261017v17`.

## Rev 10 — QR table menu matches the website (Oct 20, 2026)

- **`tpn-table-menu.html` rebuilt on the website's design.** It loads the same `tpn-app.css` / `tpn-glass.css` / `tpn-site-v3.css` and draws dishes with `tpnHome.card()` from `tpn-home.js`, so cards, photos, spinning cutouts, the engraved title, chips, tray drawer and receipt printer are the website's own. Change those files and both pages follow. Bump their `?v=` here too.
- **Flow:** + on a card adds in one tap (dishes with add-on groups open an options sheet) → tray → Review (name + guests on the first round, one notes field) → Send → the kitchen ticket prints, then a live status line (Received → Cooking → Ready → Served via `track_order`). The dock (bottom left) has Call staff and the bill so far. Bill → pick Cash / GCash·Maya·bank QR / Card → `signal_bill_request` → the bill prints. Each screen is a history entry, so the phone's Back button works.
- **Unchanged:** `submit_order` with the sql/41 idempotency key, table-bill joining, `signal_call_staff`, guest profile, HitPay still behind `payments.online_enabled`. Session keys are the same, so open tables survive the deploy. Per-dish notes became one note per round. The unused fake-QR screen (api.qrserver.com) is gone and dropped from the CSP.
- Language follows the website's saved choice (`tpn.lang`), defaulting to Tagalog at the table.
- **Paying at the table (no payment app, no BIR needed):** the guest picks Cash or GCash·Maya·bank QR and taps "Ask for the bill". The screen says staff will be right with them, with three steps for that method (QR: scan, pay the exact total, show the success screen; staff confirm it on the restaurant phone, never from a screenshot), then the bill prints. The dock shows "Staff coming" until they order again. Card is hidden until `payments.card_enabled` is set in site settings (it needs a terminal, which needs a merchant account).

## Rev 9 — manual payments, delivery, iMin counter, glass + motion (Oct 17, 2026)

- **Payments are all taken by hand (sql/37a, 37b).** No payment app talks to the system. Staff show the shop's QR (GCash/Maya/QR Ph) or run the card terminal, check it went through, then record it with the reference / approval code: `record_manual_payment`, or `settle_table_manual` for a whole table at Close table. Counts as paid at once and keeps who/when/reference. HitPay code stays but is hidden while `payments.online_enabled` is off. Customers pick what they will pay with (Cash / GCash-Maya-QR Ph / Card at pickup) so staff bring the QR or terminal; the QR menu bill request shows it on the floor.
- **Delivery (sql/38).** `delivery_zones` (area, fee, minimum, time); the fee is on the bill via `recompute_order_totals` and only changes through `set_delivery_fee` (supervisor+, with a reason). `submit_order` gained `p_delivery_zone_id` (old 13-arg version dropped). `deliveries` holds dispatch: our rider (staff) or Lalamove / Grab / other with tracking link and courier cost; waiting → assigned → on_the_way (order = served) → delivered (order = completed), or failed with a reason. `track_delivery(number, token)` for the customer. Portal: Service → Deliveries (board + Areas & fees, with a starter set). No zones = no fee and no area question.
- **iMin D4 counter (`modules/imin.js`, `vendor/imin-printer-1.4.0.min.js`, MIT).** With iMin's **iMinprinterplugin** installed on the device, the page prints receipts and kitchen tickets on the built-in 80mm printer and pops the cash drawer (`ws://127.0.0.1:8081`, allowed in the floor/portal CSP). Cash payments open the drawer; receipts print after payment when "Auto-print receipts" is on (printer chip on the floor top bar). Elsewhere it falls back to the browser print window. `counter.webmanifest` makes the floor screen installable full-screen.
- **Glass + motion.** The floor, QR menu and kitchen screens get the frosted glass look; pages and tabs rise in once (`tpnEnter`), cards cascade, dialogs ease up. Opacity/transform only; off under reduce-motion.

## Rev 8 — read receipts, Tagalog everywhere, layout pass, beginner guide (Oct 17, 2026)

- **Notifications/messages that came back after reading (sql/36):** branch-wide rows had one shared `read_at` and only managers could update them, so crew "reads" failed silently and a manager's read hid it for everyone. Now `read_receipts` holds one row per person; the client calls `my_notifications`, `my_unread_counts`, `mark_read(kind, ids|null)`, `dismiss_notification`. Also closed a hole: any branch member could UPDATE a broadcast message's text — staff now have `UPDATE (read_at)` only, on rows addressed to them.
- **"Couldn't load tables":** the Table QR page made a branch lookup then a query per branch with no retry, and failed whole on one hiccup. Now one joined query through `tpnRetry`, and the QR codes are drawn locally (vendor/qrcode-generator) instead of fetched from api.qrserver.com.
- **Tagalog:** `tpn-i18n.js` translates text written straight into the pages (≈1,300 phrases, English → Tagalog) on the website, portal, floor and kitchen screens, including dialogs and toasts; it restores the English exactly. Keyed labels (`data-i18n`, `T()`) still work as before. To add a phrase, add it to `PHRASES` in `tpn-i18n.js`. Use `translate="no"` on anything that must never change. Floor/kitchen have a 🌐 button and follow the device's choice.
- **Layout:** Accounts & access fits (compact matrix with vertical role names; switches to one-role view by available width; role list aligned; two-column permission editor). Data tables become labelled cards on phones. Header buttons share one wrapping row; button labels never wrap; hub tabs wrap instead of hiding; the sticky tab bar is solid.
- **Search (`modules/search.js`):** sidebar search field, 🔍 on the phone header, Ctrl/⌘+K or "/". Finds pages (with synonyms, e.g. "sahod" → Payroll), loaded orders, staff, inquiries, dishes and guide topics; only what the account can already see, nothing fetched. Last picks are remembered on the device.
- **No Tagalog hard-coded in templates:** write English in the code and put the Tagalog in `tpn-i18n.js` — text written in Tagalog cannot switch back to English. Brand lines (slogan, "Salamat po" on receipts) are the exception.
- **Guide (`modules/guide.js`):** "?" button on every portal page and on the floor/kitchen screens → searchable "How do I…?" with Show me (opens the page and spotlights the button, matched by onclick so it works in both languages). A tour runs once per person per device on first sign-in. Topics/tours are bilingual inside the file.

## Rev 7 — faster pages, hubs, Counter on the floor (Oct 17, 2026)

- **Split:** `index.html` is the website, `portal.html` the staff portal, `tpn-app.css` their shared styles. Customers no longer download ~400 KB of portal script. The Staff Login button, `?view=` bookmarks and the wall screens' "Go to Staff Login" all lead to `portal.html`. A portal change goes in `portal.html`; a shared style change in `tpn-app.css`.
- **Speed:** `backdrop-filter` only on the top bar, menus, dialogs and drawers (a handful on screen at once). Cards, tiles, buttons and table headers use a frosted tint with no blur — every blurred box is re-sampled on each scroll frame. Overlays blur only while open. The paper grain no longer blends. Kitchen-ticket pulses animate opacity, not box-shadow. The home carousel and the portal's timed re-renders pause when off screen or in a hidden tab.
- **Hubs:** the portal sidebar is ~10 hubs (Service, Team, Money …) instead of 34 rows. A hub's pages are tabs across the top (one dropdown on phones); each hub reopens the tab used last. The map is `TPN_HUBS` in `portal.html`; a new module tab whose id is not in it lands in "More".
- **Counter = floor screen:** the POS is a tab on `tpn-dine-in-floor` ("+ Order" on a table opens it for that table). Dine-in orders are paid at **Close table**, which now takes cash for every open order at the table in one transaction (`settle_table_cash`, sql/35) before completing them; card or bank go through "Other way…" (the per-order payment panel). Before this, closing a table recorded no money at all. Take-out and delivery still pay at once.
- **Fixed on the way:** the Add-ons & choices module was never loaded by any page; Preferences → Change password called a function that did not exist.

## Rev 6 — v2 overhaul + security hotfix (Oct 15–16, 2026)

**Live on main:** sql/29 (security hotfix) and sql/29c (size fix). Everything else
is on `feature/tpn-v2-overhaul`; see GO-LIVE.md for the order to ship it.

Rules that are new and must not be broken:

- **One ordering door.** Every order — website, QR menu, counter POS — goes
  through `submit_order()`, which prices lines from `menu_items` (+ modifiers)
  on the server. anon has no direct access to `orders`/`order_items`; staff
  have no direct INSERT on `order_items`. Do not add another path.
- **Payment status is derived** from `public.payments` by
  `private.settle_order()` (flag `tpn.settle`, like `tpn.recompute`). Nobody,
  not even a manager, types "paid". HitPay payments are completed **only** by
  the `hitpay-webhook` edge function after the HMAC check.
- **Daily close counts received cash** (payments ledger), not declared cash.
  The "declared" warning is gone with it, as the old note required.
- **Senior / PWD** templates are `vat_treatment = 'vat_exempt'`: VAT removed +
  20% on the covered share (`p_covered_amount`). `applied_discounts`
  records `covered_amount` and `vat_exempt_amount` for BIR reporting.
- **Clock-in/out are server functions** (`clock_in_verified`,
  `clock_out_verified`); staff cannot write `attendance` directly (this closed
  back-dating an open shift). Photos: private bucket, 60-day retention,
  deleted through the Storage API by `purgeOld()` when a manager opens the queue.
- **Stamps come only from the `trg_order_stamp` trigger** on paid orders.
- **New portal tabs are modules** (`modules/*.js`, registered with
  `TPN_MOD.register` from `tpn-kit.js`), not new cases in `index.html`.
- **Escaping:** `E()` for HTML, `JA()` for values inside inline
  `onclick="f('…')"` strings (HTML-decoding runs first, so `E()` alone is
  not enough there).
- **Asset version** is now `?v=20261016b` on all pages. Bump it on every
  release that touches shared JS.
- **Tests:** `cd tests/db && npm install && node run.mjs` replays every
  migration into PGlite and runs `t_*.sql` (82 checks). Add a test with any
  new RPC or policy. `prod-drift-after-17.sql` holds columns production has
  that no migration creates.
- Production drift found: migration 06 had never been applied (the public
  menu query failed live). 29 adds those columns. Compare the live schema
  with the migrations before trusting either.

## Rev 5 — UI/UX reliability pass (Oct 2, 2026)

No SQL changes. Asset version bumped to `20261002` on **all four pages**
(the floor and kitchen pages now depend on new `TPN.*` functions, so a stale
cached `tpn-supabase.js` there would break them; see the asset-version
section below).

**Shared, in `tpn-supabase.js`:**
- `TPN.liveChannel(name, configure)`: every realtime channel the screens
  use goes through this. It tracks the real channel status, rebuilds a dead
  channel with backoff (2s up to 30s), and rebuilds on tab wake.
  `TPN.onLiveStatus(fn)` reports `connecting | live | down` plus `previous`;
  a page re-fetches when it goes `down → live`. `subscribeOrders()` uses it.
- `TPN.today(d)` / `TPN.dayStartISO()`: the **Manila** calendar day. Use
  these, never `toISOString().slice(0,10)`, which is the UTC day and still
  yesterday before 8 AM here.
- `TPN.listOrdersToday()`: the dashboard's "Revenue/Orders Today" and the
  sales drilldown. They used to sum `portalState.orders`, which only holds
  active orders + the last hour.
- `TPN.unlockAudio() / audioReady() / chime()`: browsers block sound until
  the page has had a tap, so both wall screens show a **"Tap to start"**
  overlay on boot, and again if a chime would play silently.

**Portal (`index.html`):**
- Realtime and timers call `rerenderLive()`, which redraws only the live
  pages (orders, kds, dashboard, staff-home), keeps the scroll, never touches
  history, and waits while someone is typing. `route(r, { refresh: true })`
  is the in-place redraw. The portal pages scroll themselves
  (`.portal-page`), not the window; see `portalScroller()`.
- The landing/restore allow-list is built from the sidebar
  (`window._tpnAdminRoutes`), and `?view=` is honoured on load, so reloads
  and shared links land on the right tab.
- `loadErrorPanel(what, err, retryJs)`: one error panel (offline vs. refused,
  plus Try again) used by ~22 lists. A failed load must never render as an
  empty list.
- `guardAsync(name)` wraps ~27 save/approve/apply actions against double
  taps (same arguments ignored while in flight; the pressed button is
  disabled). **Add new money-moving actions to that list.**
- Escaped: KDS special requests, audit log fields, drilldown item names.
- Modal: Escape closes, focus moves in and returns, Tab is trapped,
  `role="dialog"`. Mobile drawer has a backdrop and closes on an outside tap.
- The reduce-motion CSS was invalid (an `@media` inside a selector list) and
  did nothing; it is now two rules.
- Public menu: loading / error / empty are separate states; it no longer
  says "baka may typo?" when the database is down. The menu also failed to
  redraw on load (it checked for `#menuGrid`, which does not exist).

**Floor panel:** live status pill + banner; 60s safety re-fetch;
`reloadFloor()` resets table state first (re-loading on top used to
double table totals); call/bill requests are a persistent queue
(bottom-right) that re-chimes every 30s until "On it" (`ack_call_staff`).
Signals are compared with what the screen last saw, **not `payload.old`**:
`restaurant_tables` has no REPLICA IDENTITY FULL, so `payload.old` carries
only the id. "Clear" on a table with open orders goes to Close Table; on an
empty table it asks, then clears the flags server-side. The table modal's
"✓ Close Table" was still the old local-only clear and now settles properly.
A call-staff press no longer marks the table as billed. The sound toggle in
Settings works (`localStorage tpn.floor.sound`).

**Kitchen station:** real connection status; red banner and "Orders couldn't
load" instead of "Walang bagong order" when it does not know; catch-up fetch
on reconnect and every 60s, with a chime for orders found that way.

**Table QR menu:** each attempt has a 5s deadline (a paused server hangs
rather than failing). After about 16s the guest sees what to do ("wave to our
staff"), and it keeps retrying in the background.

### ⚠️ Open: schedule week keys are Sundays
`TPN.weekStartISO()` and `isoDay()` turn "Monday 00:00 local" into a date
with `toISOString()`, which in UTC+8 is **Sunday**. So `schedules.week_start`
rows are almost certainly Sundays. This was left alone on purpose: fixing
the code alone would hide every saved schedule. Fix both together:
```sql
update public.schedules set week_start = week_start + 1
 where extract(dow from week_start) = 0;
```
then switch both helpers to `TPN.today(monday)`. Check the row count first.

### Still not done from the audit
Native `confirm()`/`prompt()` (about 20; void reasons especially want preset
chips), sortable/filterable long lists, one peso formatter everywhere, mixed
English/Tagalog, Staff Board drag-and-drop on touch, tier-vs-permission
checks inside some pages, placeholder contact details and SEC number on the
public site, food photos.

---

## Deferred — blocked on external dependencies

These are **not code problems.** They cannot be shipped until external steps happen:

### 1. GCash / PayMaya payment webhooks
- Currently: QR payment screen displays a fake plain-text QR
- Needed:
  1. Uncle finishes paid Supabase project transfer
  2. GCash Business API application approved (~2-4 week process from application submission)
  3. Static merchant QR image from GCash Business dashboard
  4. Webhook edge function: receives GCash payment confirmation → updates `orders.payment_status` → notifies floor panel
- ETA to unblock: uncle-dependent

### 2. SMS 2FA
- Currently: cleanly bypassed on login (no fake demo hints anymore)
- Needed:
  1. Sign up with paid SMS provider (recommended: Semaphore.co, ~₱0.50/SMS in PH)
  2. Store provider API key as Supabase edge function secret
  3. New edge function `send-2fa-code` — generates 6-digit, stores hashed in DB with 5-min TTL, sends via SMS
  4. Wire the existing 2FA screen input to verify against DB
- ETA: 4-6 hours of dev work once provider chosen

### 3. BIR-compliant receipts
- **Explicitly out of scope** by architecture decision — StoreHub handles official receipts
- Do not add unless the strategy changes

---

## Potential enhancements (not gaps — nice-to-haves)

These are ordered by user value. Only start these if the site is stable in production for 2+ weeks.

### High value

1. **Web Push notifications for staff messages** — currently in-app toast only. Add VAPID keys + service worker (same approach used on Orbit). Staff get notified even when tab is closed. ~2 hours.

2. **Attendance geo-fence** — prevent buddy-punching. Require browser geolocation within 100m of the restaurant to clock in. Requires `branches.latitude` + `branches.longitude` columns. ~1 hour.

3. **Schedule → Attendance late/on-time badges** — compare `attendance.clock_in_at` against the day's scheduled shift start time from `schedules`. Show ⏰ Late/✅ On Time chips on attendance rows. ~1 hour.

### Medium value

4. **Sales report CSV export** — button on Dashboard revenue drilldown → downloads a CSV of orders for a date range. ~30 min.

5. **Order edit before "preparing"** — customer or staff can add items to an existing order while it's still in `pending`/`confirmed` state. ~2 hours.

6. **Staff profile photo upload** — Supabase Storage bucket + upload widget in Settings. Chips throughout the portal show photos instead of initials. ~2 hours.

7. **Menu item photo upload** — same, for menu_items. Improves customer-facing menu. ~1 hour.

### Low value (defer indefinitely)

8. Multi-branch support (Bacoor, TGT Concession) — DB already supports it; just need UI branch switcher throughout. Only build when second branch actually opens.
9. Full chat/reply threading on messages — current inbox is 1-way (manager → staff). Only build if staff-to-manager backchannel becomes a felt need.
10. Analytics dashboard — top items, hour heatmap, category revenue splits. Current dashboard covers the essentials.

---

## What migrations 18–22 added (Aug 22, 2026)

### The ordering bug — fixed
Placing a **pickup or delivery** order from the public site failed with
"new row violates row-level security policy", which reads to a user as a
permissions error. Production was running the ORIGINAL `orders_anon_create`
from `sql/01-schema.sql`, which permits anonymous inserts only when
`order_type = 'dine_in'`. `sql/05-anon-orders.sql` was written to widen that
and its effect was not present in the live database — either `01` was replayed
after `05`, or `05` never ran. Verified by inserting as role `anon` before the
fix: dine-in succeeded, pickup and delivery both returned 42501.

`sql/18` restores the widening **and** pins what an anonymous caller may
assert. The old policy would also have accepted `status = 'done'`,
`payment_status = 'paid'` or a self-applied discount; nothing in the app does
that, but the policy allowed it. It cannot now.

**If you ever replay `sql/01` against production, you will reintroduce this
bug.** Re-run `sql/18` afterwards.

### Access control (`sql/19`)
Read the "Two layers" table in README.md first. The short version: the enum is
the lock, the permission grid is the UI. Four things worth knowing:

- `private.can()` returns true for `ceo` before touching a table. Deliberate
  lockout protection — do not "optimise" it away.
- A permission cannot be attached to a role whose `base_tier` sits below the
  permission's `min_tier`. The Access Matrix renders those cells hatched and
  unclickable rather than as empty checkboxes, because the trigger would
  refuse the write and a silently-failing checkbox is worse than a visibly
  unavailable one.
- The nine system roles cannot be deleted, rekeyed, re-tiered or deactivated.
  Their permission grid IS editable — that is the intended way to tune access.
- One shared audit trigger function across `access_roles`,
  `access_role_permissions` and `staff_permission_overrides` **does not work**.
  plpgsql resolves OLD/NEW field references against a concrete row type, so a
  function containing both `old.id` and `old.role_id` dies with
  `record "old" has no field "role_id"` the moment it fires on the wrong
  table. Three separate functions, one per table. Found the hard way.

### Tasks (`sql/20`)
Many assignees per task, each carrying their own state. The task's own status
is **derived** by `private.roll_up_task()` — nobody started → `todo`, anyone
working → `in_progress`, everyone done → `done`. A task with no assignees keeps
its hand-set status so an unassigned backlog item still works.

- `tasks_read` and `ta_read` must **never** reference each other's table.
  Doing so produced `42P17 infinite recursion detected in policy for relation
  "tasks"` on the very first insert. `private.am_i_on_task()` and
  `private.task_branch()` are SECURITY DEFINER precisely to break that cycle.
- Two triggers, two functions: `state_changed_at` must be stamped BEFORE the
  row lands, the roll-up must run AFTER it. Sharing one function across both
  timings made the roll-up run twice and read a row that had not been written.

### Inventory + finance (`sql/21`)
`ingredients.current_stock` is derived from `stock_movements` by trigger, the
same way `orders.total` is derived from `order_items`. **Never write it
directly** — record an `adjust_up` / `adjust_down` movement so the history
explains the number.

- `quantity` is always a positive magnitude; `private.stock_direction()` is the
  only place the sign convention lives.
- There is no single signed `adjustment` type on purpose. `quantity` is
  CHECK-constrained positive, so one adjustment type could only ever ADD stock,
  making a downward stock-count correction impossible to record.
- `finance_summary()` returns `cogs_basis` alongside the number. Cost of goods
  is either MEASURED from stock usage or ESTIMATED as a percent of sales, and
  the UI states which. Do not remove that — an estimate presented as a
  measurement is how a P&L loses its credibility.
- Monthly pay is prorated at `/30.4375` per day in the bucket; daily and hourly
  pay read real `attendance` rows.

### Board read helpers (`sql/22`)
`staff` RLS is deliberately tight: below manager you can read exactly one staff
row, your own. That is right for the staff table and wrong for a shared task
board, and it broke two things in testing — a kitchen crew member could not see
who else was on their task, and a supervisor with `tasks.assign` got an empty
assignment picker. The fix is NOT to loosen staff RLS. `staff_directory()`,
`task_board()` and `inventory_board()` expose the minimum a board needs
(name, role, progress) through SECURITY DEFINER functions with their own
explicit permission checks. None of them return email, phone or pay.

### Function grants — the trap that caught this release (`sql/23`)
`revoke all on function ... from anon` **does not close a function to
anonymous callers.** There are two grants, not one:

1. Postgres grants EXECUTE on every new function to `PUBLIC` by default.
2. Supabase runs `ALTER DEFAULT PRIVILEGES` granting EXECUTE on new functions
   in `public` to `anon` and `authenticated` **directly**.

Revoking "from anon" removes (2) and leaves (1), so the function stays
reachable at `/rest/v1/rpc/<name>` without a session. All eight new RPCs in
migrations 19–22 shipped that way until the Supabase advisor flagged them.
Nothing leaked — each checks `private.can()` first and an anonymous caller has
no staff row — but the door was open. **Always `revoke ... from public, anon`.**

Trigger functions were also world-executable. Revoking EXECUTE from every role
does not break them: a trigger runs as the table owner. Verified after
applying — stock still moves, task status still rolls up, access changes still
audit.

The two remaining anon-executable advisor warnings (`signal_call_staff`,
`signal_bill_request`) are correct and must stay — they are the customer
"Call staff" and "Bill" buttons on the QR menu.

### Language (`index.html`)
`setLang()` used to set `portalState.lang`, which nothing read, and then toast
"Tagalog naka-set na". It now drives a real dictionary (`TPN_STRINGS`), a
`T()` lookup, a `data-i18n` DOM pass and a re-render of the current route.
There is now a switch on the public site too — it previously had none at all.

**Coverage is honest, not total.** Fully translated: both navs, the login
screen, all five new tabs, and every DB field that carries a `*_tagalog` /
`label_tl` column. Not yet translated: the pre-existing public marketing copy
(hero, About, Concessions, Events, the two inquiry forms) and the older portal
tabs, which are still hardcoded English/Taglish. Those are a mechanical pass —
wrap the string, add the key — but there are several hundred of them.
`T('some.missing.key')` returns the key itself rather than blank, so a gap is
visible in testing instead of rendering as an empty label.

---

## ⚠️ DAILY CLOSE READS *DECLARED* PAYMENTS, NOT RECEIPTS

`orders.payment_method` is what the **customer selected at checkout**, not a
confirmed receipt. Payment confirmation is not built — another developer owns
it. So:

- The close screen labels the breakdown **"declared"** and says so on screen.
- `expected_cash` counts **declared cash only**, because cash is the one
  figure a drawer count can actually verify.
- **When real payment confirmation lands**, `expected_cash` must switch to
  confirmed receipts, and the warning text in `renderDailyClose` and in
  `daily_close_report`'s header comment should be removed together. Do not
  remove one without the other.

`daily_closes` snapshots the figures at close time, so a void the next morning
cannot silently rewrite what was reconciled last night. Re-counting overwrites
and re-audits.

---

## Stock variance is NOT a yield report (sql/28)

`inventory_variance()` reports movements: delivered, used, wasted,
`found_short` (a stock count discovered less), `found_over`, returned.

**It cannot tell you what a dish *should* have consumed** — that needs recipes,
and there is no recipe table. `found_short` is the leakage signal worth
chasing. The UI states this limitation on screen and there is a test asserting
that sentence is present; if you ever add recipes, that is when this becomes a
real yield report and the caveat can go.

---

## The upsell that never fired (sql/28)

`upsellRules` in index.html matched on short codes (`'tap'`, `'ur'`) while
`menu_items.id` is a uuid, so `cartIds.includes('tap')` was **always false**.
It never appeared once in production. The tell was
`const sugItem = findItem(rule.suggest)` — assigned and never used.

Replaced with `menu_items.is_addon` + `addon_suggestions()`, so the kitchen
changes the offer in Menu Manager without a deploy. **Nothing is marked as an
add-on yet** — tick `is_addon` on rice, drinks and sauces and it starts
working.

Placement is deliberate: inside the cart drawer, **not** a modal over the
checkout button. An interstitial at the moment of payment is the most disliked
pattern in food ordering and it costs completed orders. Ignoring an inline
card costs one scroll.

---

## Prep targets (sql/28)

`menu_items.prep_minutes` per dish; a ticket ages against its **slowest**
item. Null falls back to the old generic thresholds, so an unconfigured menu
behaves exactly as before and gets sharper as the numbers are filled in.

---

## Low-stock alerts fire on the CROSSING only

`trg_low_stock_notify` fires when stock goes *from above* the reorder level
*to at or below* it. Without that check, every later movement on an
already-low item re-alerts and the feed becomes noise nobody reads. If you
ever want a daily nag instead, that is a scheduled job, not this trigger.

`private.fmt_qty()` exists because `to_char(8.000,'FM999999.99')` returns
`"8."` — FM strips padding but keeps the decimal point, so alerts read
"8. kg left (reorder at 10.)".

---

## Split bills on the floor panel

Wired in this round. Note the floor panel's `tableStates` is keyed by
**branch + table NUMBER** and carries order ids, not a table uuid — which is
why there are two RPCs for the same breakdown:

- `table_bill(table_id)` — for anything holding a table uuid
- `order_bill_breakdown(order_id)` — what the floor panel actually uses

Splitting stays staff-gated. `device_id` travels in the request payload and
is not a secret, so a guest who could split by passing an id could move
someone else's food onto a separate bill.

---

## Status changes are attributable (sql/26)

Two layers, and the order matters:

- **`trg_audit_order_status`** is a trigger, so *any* status change lands in
  `audit_log` with the actor — including a plain `update orders set status=...`
  from old client code. Verified. This is the layer that matters.
- **`advance_order_status(id, status, source)`** is what the screens call. It
  adds *which surface* acted: `portal_kds`, `portal_orders`, `kitchen_screen`,
  `floor_panel`. Free text on purpose — a new surface should not need a
  migration to start attributing itself.

The trigger deliberately skips `completed`/`cancelled` because
`trg_audit_order_money` already logs those with the money detail. Two rows per
event makes the log harder to read, not safer.

`TPN.advanceOrderStatus()` falls back to a plain UPDATE **only** when the RPC
itself is missing (an older database). A permission error is re-thrown, not
swallowed — a kitchen must not stop for an audit nicety, but it also must not
silently ignore a refusal.

All three surfaces already subscribed to `orders` realtime before this, so
they were in sync; what was missing was the record of who did it.

---

## Guest memory (sql/27)

`customer_devices` + `customer_device_items`, filled automatically by
`submit_order()` — not by a separate call the client could forget.

**Three privacy tiers, verified by probe:**

| Caller | Sees |
|---|---|
| `anon` | nothing from the tables; `my_guest_profile()` only — first name, visit count, top 3 usuals |
| staff (`orders.view`) | `guest_profile()` / `guest_list()` — phone, spend, flags, no-shows, every name used |
| staff (`orders.manage`) | can flag, unflag, and write a note |

**Two limits to repeat wherever this is surfaced** (the Guests tab says both
on screen, deliberately):

- Clearing the browser makes them a new guest. That is the correct trade for
  something built on a value the guest controls.
- One phone can be several people. That is why `known_names` accumulates
  instead of overwriting.

A flag is a note about behaviour (an uncollected pickup), **not** a credit
score. It tells staff to ask for payment up front; it never changes a price,
and every flag is audited with the actor's name.

Guest spend is scored on **the batch that phone submitted**, not the running
table total — otherwise one phone on a shared bill gets credited with
everyone's food.

---

## Themes and Preferences

Preferences live in `localStorage` (`tpn.prefs`), not the database: a shared
counter terminal and a manager's laptop want different settings for the same
person, and a preference is not worth a round trip on every load.
`applyPrefs()` runs before first paint, so there is no white flash on the way
into dark.

Themes are a **token swap**, not a restyle — every surface already draws from
the same CSS variables. `light` / `dark` / `night` / `system` are set on
`<html data-theme>`. Night additionally desaturates the accents for a 1am
closing shift. All three clear 7:1 on body text; there is a test that fails if
that regresses.

The two wall pages (`tpn-dine-in-floor`, `tpn-kitchen-station`) carry their
own dark styling and are deliberately left out of the theme system.

**If you add a component with a hardcoded colour, add a dark note for it.**
The `html[data-theme="dark"] …` block near the end of the theme stylesheet is
where the exceptions live — anything that leaned on white translucency reads
as haze on a dark ground.

---

## ⚠️ CUSTOMER ORDERING: NEVER READ BACK THROUGH THE TABLES

`anon` has **INSERT but not SELECT** on `orders` and `order_items`. Any code
doing `.insert(...).select()` therefore fails with **"permission denied for
table order_items"** — the write succeeds and the read-back is refused.

This is why migration 18 did not actually fix ordering: it fixed the RLS
policy, and I verified it by testing the INSERT in isolation. The app's real
call is a round trip. **Test the round trip, not the statement.**

Do **not** "fix" this by granting anon SELECT. `orders_anon_read` is
`using (true)`, so that would expose every order in the business — names,
phone numbers, delivery addresses — to any anonymous visitor. Customers are
anonymous by architecture here.

Instead, all customer order traffic goes through two SECURITY DEFINER
functions (sql/24):

- `submit_order(...)` — creates or extends an order, returns
  `{ id, order_number, joined_existing, total }`.
- `track_order(order_number)` — returns exactly one order. No listing
  endpoint, and no phone or address in the payload.

Customer progress polls `track_order` every 8s rather than subscribing.
Realtime is delivered through the same RLS as a SELECT, so a subscription
from a customer device would silently never fire. `TPN.subscribeToOrder()`
is the polling version and takes an **order_number**;
`TPN.subscribeToOrderRealtime()` is the staff one and takes a uuid.

### Shared table bills
`submit_order` appends to whatever dine-in order is already open on that
table, so several phones at one table share one bill. Every line carries
`guest_name` and `device_id` (a random id the browser stores for itself —
not a fingerprint, and not a secret). `table_bill(table_id)` groups a bill
by phone; `split_order_by_device(order_id, device_id)` moves one phone's
lines onto their own order.

Splitting is **staff-gated on purpose**. device_id travels in the request
payload, so if a guest could split by passing an id they could move somebody
else's food onto a separate bill. A guest asks; staff performs.

**Still to build:** the split UI on `tpn-dine-in-floor.html`. The RPCs and
`TPN.getTableBill()` / `TPN.splitTableBill()` exist and are tested; nothing
calls them yet.

---

## Two table-menu bugs worth remembering (both fixed)

1. **The menu rendered blank until you tapped a category.** `loadMenuFromDB`
   and `renderMenuLoadingState` both guarded on `#menu-grid`, which does not
   exist — the container is `#menu-body`. So `renderMenu()` was skipped on
   load, and tapping a chip was the only thing that called it. If you ever
   see a "blank until interaction" bug, check the guard ids first.

2. **Every "+ Add" needed two taps on iOS.** `.dish-card:hover` with no
   `touch-action` makes Safari spend the first tap applying hover.
   `.qty-btn` already had `touch-action: manipulation` — the fix had been
   applied there and nowhere else. Hover rules are now inside
   `@media (hover:hover) and (pointer:fine)`.

---

## Payroll (sql/25)

`payroll.run` (admin+) builds and pays. `payroll.edit` (CEO only) changes
rates. A director can run payroll without being able to give a raise.

`draft → approved → paid → reversed`, enforced in `set_payroll_status`, not
in the UI. A paid run's lines are frozen by trigger — which also means a paid
run can never be deleted, even by cascade. That is deliberate: reverse it.

**The build function had a bug worth not repeating.** The first version used
an INNER join to `staff_compensation` and filtered
`employment_status = 'active'`. In the live data those sets were disjoint —
the only staff with rates were disabled, and the only active staff had no
rates — so it produced an **empty run with no error**. It now LEFT JOINs the
rate (a missing rate becomes a zero line *with a note*), includes anyone who
clocked in during the period whatever their current status, and raises
`nobody_to_pay` if there is genuinely nobody.

---

## Badges you can clear

Two different things wore the same red circle. Real unread state
(notifications, messages) is cleared by marking read in the database.
Derived counts (new enquiries, pending voids, pending accounts, my open
tasks, low stock) have nothing to read, so clearing writes a per-browser
acknowledgement in `localStorage` under `tpn.badgeAck`.

**The subtle part:** if the count later *falls*, the acknowledgement is
discarded and the badge shows again. Counting cannot distinguish "the same
2 as before" from "2 different ones", so without that rule, acking 4 pending
voids would keep the badge hidden after all 4 were resolved and a 5th
arrived. Re-showing a badge somebody has seen is a much safer error than
silently swallowing a new one.

---

## ⚠️ BUMP THE ASSET VERSION ON EVERY RELEASE

`index.html` loads its two scripts with a hand-written cache-buster:

```html
<script src="config.js?v=20260822"></script>
<script src="tpn-supabase.js?v=20260822"></script>
```

**If you change `tpn-supabase.js` and do not bump that string, returning users
get the new `index.html` against the OLD cached `tpn-supabase.js`.** GitHub
Pages revalidates the HTML but the querystring-versioned JS is cached hard.

This bit for real on the 22 Aug release. `index.html` called
`await TPN.loadPermissions()` during login; the cached bundle predated that
function; the sign-in button died with **"TPN.loadPermissions is not a
function"** and nobody could get into the portal. The database was fine, the
push was fine — it was a stale script.

Two defences are now in place, and both should stay:

1. **`preloadPermissions()` in `index.html` never throws.** It checks the
   function exists, catches anything, and sets `TPN._permsFailed`. Sign-in
   continues regardless. **Never call `TPN.loadPermissions()` directly from
   the login path again** — go through the wrapper.
2. **`TPN.can()` falls back to pre-19 tier gating** when permissions could not
   be loaded (`TPN._fallbackCan`), so a failure looks like the old app instead
   of an empty sidebar. That fallback is deliberately a bit generous, and
   that is safe: `can()` only decides what the UI *offers*. RLS and the
   SECURITY DEFINER functions are what actually refuse a write, so a fallback
   showing one tab too many produces a Postgres refusal, not access.

The general rule this teaches: **no new function may be a hard dependency of
the login path.** Anything the sign-in flow awaits must degrade.

---

## Known quirks / gotchas for the next session

- **Always ask for current files before editing.** Uno pushes his own commits between sessions. Never assume Claude's copy matches live. Fetch via `curl https://raw.githubusercontent.com/UnoRfl/tpn-os/main/<file>` before proposing edits.

- **Delivery style:** zips + git push from cmd. Full-file replacements. No surgical edit instructions.

- **Supabase FK ambiguity:** Any table with 2 FKs to the same target needs disambiguation in PostgREST queries. Attendance (`staff_id` + `corrected_by`), Schedules (`staff_id` + `updated_by`), Messages (`from_staff_id` + `to_staff_id`). Use `staff:staff_id(...)` syntax not `staff:staff(...)`.

- **Extensionless URLs:** GitHub Pages resolves `/tpn-table-menu` → `tpn-table-menu.html` automatically. All internal links use extensionless. A small script at the top of each page strips `.html` from any URL that has it (for old bookmarks and old QR codes). Actual filenames on disk remain `.html`.

- **Boot overlay:** Injected at the very top of `<head>` via inline `<style>`, DOM node injected right after `<body>`. Dismissed by `hideBootOverlay()` after session restore completes, or after 4s safety-net timeout. Do not remove the safety-net — a Supabase hang would otherwise leave the user stuck.

- **Role enum (DB source of truth):** `kitchen_display, dine_in_display, dining, kitchen, supervisor, manager, admin, director, ceo`. All lowercase, lowest privilege first. Any UI that uses different casing or extra values (`cashier`, `service`) is a bug — fix it, don't add code around it.

- **The enum ORDER is the permission model.** `private.has_role()` compares `array_position(enum_range(...))`. Moving a value, or adding one in the wrong place, silently changes what every account can do. The two `*_display` roles sit below `dining` on purpose. Four files mirror this list and must never drift: `sql/01-schema.sql` + `sql/15a`, `tpn-supabase.js` (`TPN.ROLE_HIERARCHY`), `index.html` (`DISPLAY_ROLES`/`ROLE_LABELS`), `supabase/functions/create-staff/index.ts`.

- **Enum migrations must run alone.** Postgres won't let you `ALTER TYPE … ADD VALUE` and then use that value in the same transaction, and the Supabase SQL Editor runs a paste as one transaction. That's why 15a and 15b are separate files with a hard warning at the top of 15a.

- **Bottom-of-enum is not the whole lock.** Several policies from earlier migrations gate on BRANCH alone, not role — a display account passes those. `sql/15b` section 7 closes them: no direct `UPDATE` on `order_items` for anyone (voiding goes through SECURITY DEFINER functions only), a column-level trigger guard on `orders`, `actor_role` pinned on audit inserts, and branch-broadcast reads excluded for display roles. If you add a new table with a branch-only policy, ask what a screen account can do with it.

- **Known limitations of the void/display work (deliberate, documented):**
  - `order_items` non-negativity is enforced by a BEFORE **INSERT** trigger, not a CHECK constraint. A CHECK — even `NOT VALID` — is re-checked on every later UPDATE, which would make any pre-existing negative or zero-quantity row permanently impossible to void. The trigger closes the attack going forward but does not clean history. Run `select count(*) from public.order_items where total_price < 0 or unit_price < 0 or quantity <= 0;` once; if it returns 0, adding the validated CHECK becomes safe and strictly stronger.
  - `apply_discount` / `remove_discount` / `applied_discounts` / `discount_templates` are called from `tpn-supabase.js` but exist in **no SQL file in this repo** — they were applied straight to production. `sql/15b` now enforces `adjustments_require_supervisor` on `orders.discount_amount` / `service_charge`, which matches their documented gating, but if either RPC writes those columns on behalf of a below-supervisor caller it will start failing. Version them as a migration to close this blind spot.
  - `display_cannot_close_orders` in `trg_guard_order_update()` is effectively unreachable via the app: the jsonb column comparison trips first because `TPN.updateOrderStatus` always sends the timestamp column alongside `status`. It's belt-and-braces for a hand-written UPDATE. Blocked either way; just don't expect that error name in logs.
  - `sql/11-security-hardening.sql` has two pre-existing bugs that block a **from-scratch** deploy (unrelated to this change): line ~343's index uses non-`IMMUTABLE` `date_trunc`, and `signal_call_staff` / `signal_bill_request` change return type without a `DROP FUNCTION` first. The live database is fine; only a fresh rebuild hits these.

- **`orders.total` and `orders.subtotal` are locked.** They can only be written by `private.recompute_order_totals()`, which sets a transaction-local GUC (`tpn.recompute`) that `trg_guard_order_update` checks. A role check would break ordinary service — those columns are written as a side effect of a *dining* staffer adding an item. If you add another legitimate writer, it must set that flag the same way. Break-glass for a DBA: `alter table public.orders disable trigger trg_guard_order_update;`

- **Audit rows for money belong inside the function that moves the money.** `apply_discount`, `remove_discount`, the void functions and `trg_audit_order_money` all write their own audit row server-side, so a caller who bypasses the UI cannot skip it. The 18 client-written `TPN.logAudit` actions are advisory only. Do not add a new financial action that relies on the browser to log it.

- **Two Supabase advisor warnings are correct and must stay.** `signal_call_staff` and `signal_bill_request` are anon-callable by design — that is the customer "Call staff" / "Bill" buttons. Revoking them breaks the QR menu.

- **Voiding has exactly two doors:** `public.void_order_item()` (manager+, direct) and `public.approve_void_request()` (manager+, via a request). Both SECURITY DEFINER, both write to `audit_log`. Don't add a third.

- **Never assume Menu Manager categories match hardcoded lists** anywhere. All menu display code reads from `menu_items` + `menu_categories` tables.

- **`config.js` should never be regenerated blindly.** It's committed to the repo with the anon key. Only edit if the Supabase project ref itself changes (i.e., after the uncle transfer).

---

## Migration order (Supabase SQL Editor)

Run these once in order on any fresh Supabase project:

```
sql/01-schema.sql             base schema, staff/branches/menu/orders/inquiries
sql/02-seed.sql               initial branches + menu categories + featured items
sql/03-security-fixes.sql     RLS tightening
sql/04-signals.sql            call-staff + bill-request signals table
sql/05-anon-orders.sql        allow anonymous checkout for pickup/delivery
sql/06-menu-fields.sql        pax_options JSON column on menu_items
sql/07-single-branch.sql      remove Bacoor/TGT, tighten branches
sql/08-schedules.sql          weekly schedules table
sql/09-order-fields-and-attendance.sql   delivery_address, scheduled_for, attendance, messages
sql/10-notifications.sql      notifications feed + triggers
sql/11-security-hardening.sql RLS tightening, void_order_item, audit archive
sql/12-advisor-cleanup.sql    Supabase advisor fixes
sql/13-fix-audit-daily-counts.sql
sql/14-restaurant-performance.sql
sql/15a-display-roles.sql     ⚠️ RUN ALONE, FIRST — adds the two display roles to the enum
sql/15b-void-requests.sql     void_requests table + RPCs + display guard rails
sql/16-discounts.sql          discount subsystem, versioned from production + audited
sql/17-hardening.sql          totals lock, TRUNCATE revoke, order audit, advisor cleanup
```

As of migration 17, `sql/01` → `sql/17` replays on a **fresh** database
with no workarounds. Two long-standing defects in `sql/11` that blocked
any rebuild (a non-IMMUTABLE index expression, and two functions changing
return type without a DROP) are fixed at source.

Edge function to deploy once via Supabase CLI:
```
supabase functions deploy create-staff
```

---

## When restarting a session, prompt Claude with:

> "Working on TPN OS. Deployed at unorfl.github.io/tpn-os. Repo UnoRfl/tpn-os. Please fetch the current index.html, tpn-supabase.js, tpn-table-menu.html, and tpn-dine-in-floor.html from raw.githubusercontent.com before proposing any edits, since I push commits between sessions. Also read HANDOFF.md for context on what's done vs. deferred."
