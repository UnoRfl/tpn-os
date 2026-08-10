# TPN OS — Session Handoff

**Last updated:** Aug 10, 2026
**Deployed:** https://unorfl.github.io/tpn-os/
**Repo:** https://github.com/UnoRfl/tpn-os
**Supabase project ref:** `xjlqfpnzobfqxetgkkai` (single project, single branch)

---

## Current state

**MVP is functionally complete.** The site handles the full restaurant-management workflow end-to-end using real Supabase data. Zero hardcoded/fake demo data remains. All 4 files pass Node syntax checks.

### File layout
```
tpn-os/
├── index.html                 ~5500 lines — public site + staff portal (single-page app)
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
| Dashboard tiles + revenue drilldown + prep-time analytics | ✅ live |
| Session restore with **branded boot overlay** (no flicker) | ✅ live |
| **Extensionless URLs** (`/tpn-table-menu`, `/tpn-dine-in-floor`) | ✅ live |

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

## Known quirks / gotchas for the next session

- **Always ask for current files before editing.** Uno pushes his own commits between sessions. Never assume Claude's copy matches live. Fetch via `curl https://raw.githubusercontent.com/UnoRfl/tpn-os/main/<file>` before proposing edits.

- **Delivery style:** zips + git push from cmd. Full-file replacements. No surgical edit instructions.

- **Supabase FK ambiguity:** Any table with 2 FKs to the same target needs disambiguation in PostgREST queries. Attendance (`staff_id` + `corrected_by`), Schedules (`staff_id` + `updated_by`), Messages (`from_staff_id` + `to_staff_id`). Use `staff:staff_id(...)` syntax not `staff:staff(...)`.

- **Extensionless URLs:** GitHub Pages resolves `/tpn-table-menu` → `tpn-table-menu.html` automatically. All internal links use extensionless. A small script at the top of each page strips `.html` from any URL that has it (for old bookmarks and old QR codes). Actual filenames on disk remain `.html`.

- **Boot overlay:** Injected at the very top of `<head>` via inline `<style>`, DOM node injected right after `<body>`. Dismissed by `hideBootOverlay()` after session restore completes, or after 4s safety-net timeout. Do not remove the safety-net — a Supabase hang would otherwise leave the user stuck.

- **Role enum (DB source of truth):** `dining, kitchen, supervisor, manager, admin, director, ceo`. All lowercase. Any UI that uses different casing or extra values (`cashier`, `service`) is a bug — fix it, don't add code around it.

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
```

Edge function to deploy once via Supabase CLI:
```
supabase functions deploy create-staff
```

---

## When restarting a session, prompt Claude with:

> "Working on TPN OS. Deployed at unorfl.github.io/tpn-os. Repo UnoRfl/tpn-os. Please fetch the current index.html, tpn-supabase.js, tpn-table-menu.html, and tpn-dine-in-floor.html from raw.githubusercontent.com before proposing any edits, since I push commits between sessions. Also read HANDOFF.md for context on what's done vs. deferred."
