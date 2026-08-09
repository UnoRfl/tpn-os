# TPN OS — Session Handoff

Written at the end of a build session so the next Claude conversation can pick up cleanly. Read this before doing anything.

## Current state

**Deployment:**
- Repo: https://github.com/UnoRfl/tpn-os (public)
- Live: https://unorfl.github.io/tpn-os/ via GitHub Pages
- Supabase project ref: `xjlqfpnzobfqxetgkkai` (free tier, will migrate to uncle's paid org later)
- Local working folder: `C:\Users\User 1\Downloads\tpn-os\tpn-os`

**Credentials architecture:**
- All Supabase keys live in `config.js` (one file, one job, gitignored)
- `tpn-supabase.js` reads from `window.TPN_CONFIG`
- Anon key is safe to commit publicly (RLS protects data)
- Service role key is only in Supabase's edge function env (NEVER put anywhere in the repo)

**Supabase Auth state:**
- Public signups: **DISABLED** in Auth → Providers → Email
- Account creation ONLY path: `create-staff` edge function
- First CEO was created manually and promoted via SQL
- Non-active accounts (pending/suspended/recommended/disabled) are blocked at login AND at session-restore

**Edge Function deployed:**
- Name: `create-staff` (exact spelling — frontend calls this)
- Manager+ can create, can only grant roles ≤ own level, logs to `audit_log`
- **Manager-created accounts start as `pending`; admin+ created accounts start `active`.**
- Response includes `initial_status` so the UI knows which tab to jump to.

## Files in the repo

```
tpn-os/
├── config.js                    ← credentials (SUPABASE_URL + anon key) — gitignored
├── index.html                   ← public site + staff portal (~4900 lines)
├── tpn-table-menu.html          ← dine-in QR menu
├── tpn-dine-in-floor.html       ← floor panel
├── tpn-supabase.js              ← data layer (reads config.js)
├── README.md
├── WHATS-NEW.md                 ← last session's changelog
├── HANDOFF.md                   ← THIS FILE
├── .gitignore
├── sql/
│   ├── 01-schema.sql
│   ├── 02-seed.sql
│   ├── 03-security-fixes.sql
│   ├── 04-signals.sql
│   ├── 05-anon-orders.sql
│   ├── 06-menu-fields.sql
│   ├── 07-single-branch.sql
│   └── 08-schedules.sql         ← NEW: schedules table + RLS
└── supabase/functions/create-staff/
    └── index.ts                 ← UPDATED: pending-flow logic
```

## Roles

`dining` < `kitchen` < `supervisor` < `manager` < `admin` < `director` < `ceo`

- `dining` — staff portal sidebar, Live Orders + Home + My Schedule + Attendance + Settings
- `kitchen` — staff portal sidebar, Kitchen Display (KDS) + Home + My Schedule + Attendance + Settings
- `manager`+ — admin portal (dashboard, inquiries, orders, KDS, staff board, schedules, menu manager, accounts, table QR, [audit — admin+ only])
- `ceo`/`director` — same as manager+ but sees revenue tile on dashboard

## What's wired end-to-end

- ✅ Login (real Supabase Auth, email + password). Blocks non-active accounts with a status-specific message.
- ✅ **Session restore on refresh** — if you're logged in and refresh, you drop straight back onto the tab you were viewing (last route persisted in `localStorage`).
- ✅ Add Staff (via edge function). **Manager creations start `pending`, admin+ creations start `active`.**
- ✅ Menu Manager (portal → CRUD on menu_items, reflects on customer surfaces)
- ✅ Customer menu on public site + table QR (loads from DB)
- ✅ Featured carousel (loads is_featured items from DB)
- ✅ Place order from public checkout → DB
- ✅ Place order from table QR → DB
- ✅ Order status changes (advance/rollback) → DB + realtime to all screens
- ✅ Kitchen Display System (own route + chime on new orders)
- ✅ Live Orders kanban with realtime updates
- ✅ Call-staff / request-bill signals from table → floor panel + portal toast
- ✅ B2B / event inquiry forms → DB
- ✅ Inquiry Inbox reads from DB
- ✅ Accounts panel reads real staff from DB
- ✅ **Account actions persist to DB** — validate / reject / recommend disable / disable / reinstate all write `employment_status` and log to `audit_log`
- ✅ **Staff Board drag/drop persists to DB** — role + branch update, logged to `audit_log`
- ✅ Audit Log reads from DB (`audit_log` table, needs migration 07 for manager+ read)
- ✅ Dashboard tiles + sales drilldown computed from real orders
- ✅ **Prep-time analytics** — real avg / fastest / slowest computed from `confirmed_at → ready_at` timestamps
- ✅ **Schedules (staff view)** — pulls current week from DB, prev/next navigation, per-staff manager notes
- ✅ **Schedules (admin editor)** — new "Schedules" sidebar tab, inline cell editing with immediate save, prev/next/this-week nav, copy-from-prev-week

## What's NOT wired (known gaps)

- ⏳ Staff attendance — placeholder UI only; no clock-in/out flow or attendance table
- ⏳ Recognition Panel — orphaned in code, route removed from sidebar
- ⏳ Payment confirmation webhooks — GCash / PayMaya QRs are display-only
- ⏳ SMS 2FA — bypassed for MVP
- ⏳ BIR-compliant receipts — StoreHub handles this side

## Known quirks to remember

- **Windows path issues:** `cd /d "C:\Users\User 1\Downloads\tpn-os\tpn-os"` (the `/d` handles drive change, quotes handle the space).
- **Git first-time push:** GitHub auto-added README/LICENSE. If encountered again: `git pull origin main --rebase --allow-unrelated-histories`, resolve README with `git checkout --ours README.md`.
- **Vim escape:** Esc → `:wq` → Enter. Or run `git config --global core.editor notepad` once.
- **VPN + Supabase:** some VPNs cause "Failed to fetch" errors. Disable VPN if auth breaks unexpectedly.
- **LF/CRLF warnings on git add:** harmless on Windows, ignore.
- **localStorage keys:** `tpn.lastRoute.admin` / `tpn.lastRoute.staff`. Cleared on logout.
- **Schedule edit UX:** the cell input saves on `change` (blur or Enter). Tab-through works. Green flash = saved, red border = error.
- **`updated_by` in schedules:** set to the caller's staff.id via `TPN._user`. Loaded on session restore.

## Session boot checklist for next Claude

1. Ask Uno to upload his current `index.html`, `tpn-supabase.js`, and `config.js` from his local folder. **Never assume the working copy matches his** — he pushes his own commits between sessions.
2. Never regenerate `config.js` without warning first (would wipe credentials).
3. Prefer surgical `str_replace` edits over full-file regenerations for `index.html`.
4. Always syntax-check after edits: extract inline `<script>` blocks and run `node --check`.
5. Deliver changes as a zip + push instructions, not inline paste. Uno's workflow: extract → overwrite local → `git add . && git commit && git push`.
6. **Remind him to redeploy the `create-staff` edge function whenever `supabase/functions/create-staff/index.ts` is edited** (Supabase Dashboard → Edge Functions → paste → Deploy).

## Immediate next-session priorities (in order)

1. **Test the current build.** Verify:
   - Session restore across refresh from Schedules, Menu Manager, Accounts, Live Orders
   - Manager creates staff → account lands in Pending → CEO validates → account becomes Active → they can sign in
   - Schedule cell edits save (green flash) and read back correctly on staff side
   - "Copy from prev week" duplicates shifts for all active staff
2. **Attendance flow** — clock-in/out UI + new `attendance` table + reports view
3. **Payment webhook flow** — GCash Business API integration when uncle's paid Supabase is ready
4. **Optional: roles collapse 7→3** — DB enum rename migration, UI simplification

## Uno's working style

- Terse, directive prompts. Wants immediate action, not discussion.
- Prefers surgical `str_replace` edits with zip delivery over full-file paste.
- Filipino English patterns: "off the site" often means "from the site"; "shits" is casual filler.
- First-year BSIT at UPHSD Las Piñas. Self-taught. Familiar with GitHub Pages, Supabase (from Orbit), Tauri (Jarvis), Luau (Unoryx PVP).
- TPN is his family's real restaurant. This is a real deployment, not a school project.

## Contact points

- Uncle has paid Supabase org (project transfer planned when ready)
- StoreHub still runs POS/receipts/inventory in parallel
- TPN OS is the online + operational layer alongside StoreHub
