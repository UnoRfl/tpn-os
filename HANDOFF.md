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

**Edge Function deployed:**
- Name: `create-staff` (exact spelling — frontend calls this)
- Manager+ can create, can only grant roles ≤ own level, logs to `audit_log`
- New accounts default to `employment_status = 'active'` (not pending)

## Files in the repo

```
tpn-os/
├── config.js                    ← credentials (SUPABASE_URL + anon key) — gitignored
├── index.html                   ← public site + staff portal (~4500 lines)
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
│   └── 07-single-branch.sql
└── supabase/functions/create-staff/
    └── index.ts
```

No new SQL migrations were added this session — all changes were client-side against the existing schema.

## Roles

`dining` < `kitchen` < `supervisor` < `manager` < `admin` < `director` < `ceo`

- `dining` — staff portal sidebar, Live Orders + personal home/schedule
- `kitchen` — staff portal sidebar, Kitchen Display (KDS) + personal home/schedule
- `manager`+ — admin portal (dashboard, orders, KDS, staff board, menu manager, accounts, inquiries, audit, table QR)
- `ceo`/`director` — same as manager+ but sees revenue tile on dashboard

## What's wired end-to-end

- ✅ Login (real Supabase Auth, email + password)
- ✅ **Session restore on refresh** — if you're logged in and refresh, you drop straight back onto the tab you were viewing (last route persisted in `localStorage`)
- ✅ Add Staff (via edge function, admin-only)
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

## What's NOT wired (known gaps)

- ⏳ Staff schedule / attendance — placeholder UI only; no persistence
- ⏳ Recognition Panel — orphaned in code, route removed from sidebar
- ⏳ Payment confirmation webhooks — GCash / PayMaya QRs are display-only
- ⏳ SMS 2FA — bypassed for MVP
- ⏳ BIR-compliant receipts — StoreHub handles this side
- ⏳ New staff default to `employment_status = 'active'` — no "pending → validate" flow currently. The Accounts UI has a Pending tab that will be empty until the edge function is changed to set `'pending'` for new accounts.

## Known quirks to remember

- **Windows path issues:** don't `cd path\to\tpn-os` — it's placeholder text. Use `cd /d "C:\Users\User 1\Downloads\tpn-os\tpn-os"`.
- **Git first-time push:** GitHub auto-added README/LICENSE; if this ever comes up, `git pull origin main --rebase --allow-unrelated-histories` then resolve README conflict with `git checkout --ours README.md`.
- **Vim escape:** Esc → `:wq` → Enter. Or run `git config --global core.editor notepad` once.
- **VPN + Supabase:** some VPNs cause "Failed to fetch" errors. If auth breaks unexpectedly, try disabling the VPN.
- **LF/CRLF warnings on git add:** harmless on Windows, ignore.
- **Session-restore key:** `localStorage["tpn.lastRoute.admin"]` / `localStorage["tpn.lastRoute.staff"]`. Cleared on logout.

## Session boot checklist for next Claude

1. Ask Uno to upload his current `index.html`, `tpn-supabase.js`, and `config.js` from the local folder. **Never assume the working copy matches his** — he pushes his own commits between sessions.
2. Never regenerate `config.js` without warning first (would wipe credentials).
3. Prefer surgical `str_replace` edits over full-file regenerations for `index.html`.
4. Always syntax-check after edits: extract `<script>` blocks, run `node --check`.
5. Deliver changes as a zip + push instructions, not inline paste. Uno's workflow: extract → overwrite local → `git add . && git commit && git push`.

## Immediate next-session priorities (in order)

1. **Test the current build.** Verify session restore works across refresh from multiple tabs (Menu Manager, Accounts, Live Orders). Verify Staff Board move persists across refresh. Verify Accounts state changes persist.
2. **Persistent schedule** — new `schedules` table (Mon-Sun × shift times per staff), CRUD in portal, view in staff sidebar
3. **Pending-account flow** — one-line edge function change + Accounts UI updates so new accounts wait for CEO validation
4. **Payment webhook flow** — GCash Business API integration when uncle's paid Supabase is ready
5. **Optional: roles collapse 7→3** — DB enum rename migration, UI simplification

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
