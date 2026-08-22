# TPN OS — Session Handoff

**Last updated:** Aug 22, 2026 (access control, tasks, inventory, finance, real i18n — migrations 18–22)
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
| **Display device accounts** (`kitchen_display`, `dine_in_display`) — screen-only logins, portal-blocked | ✅ live |
| **Void requests** — request → manager approve/deny, realtime both ways, full audit trail | ✅ live |
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
