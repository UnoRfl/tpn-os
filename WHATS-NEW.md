# What's new in this build

Two big features this round: **persistent schedules** and a proper **pending-account workflow**.

## Persistent schedules (Tier 1)

**New database table** `public.schedules` — one row per (staff, week), day-shifts stored as a jsonb map so any cell can be updated on its own. RLS: staff can read their own row, manager+ can read/write all rows for staff in their branch.

**Admin: Schedules editor.** New "Schedules" tab in the manager sidebar between Staff Board and Menu Manager. Every active staff member appears as a row with 7 day columns. Click any cell, type a shift like `9:45a-6p` or leave blank/OFF, tab out — it saves. Green border flashes on success, red on error. Prev/Next/This-Week navigation. "Copy from prev week" bulk-clones last week's shifts across all active staff.

**Per-staff notes.** Click the note button on any row to attach a message that only that staff sees on their My Schedule tab.

**Staff: My Schedule.** No longer hardcoded — pulls the current week's row from Supabase and renders the day grid. Prev/Next/This-Week buttons let staff scroll ahead or check previous weeks. If no schedule is posted yet, shows a friendly empty state.

**SQL migration** `sql/08-schedules.sql` — run this in Supabase SQL Editor before using the new tabs.

## Pending-account validation workflow

**Manager-created accounts now start as `pending`.** They cannot sign in until validated. Admin+ created accounts still start `active` (Admin/Director/CEO are trusted).

**Login refuses non-active accounts** with a clear message:
- Pending → "Your account is awaiting validation…"
- Suspended / Recommended / Disabled → status-specific rejection

**Session restore also refuses non-active accounts.** If a signed-in user gets suspended by admin, their next page refresh silently signs them out.

**Create Staff flow** in the Accounts panel now reads `initial_status` from the edge function response and jumps to the correct tab (Pending or Active) after creating the account.

**Edge function must be redeployed** — see setup below.

## Backend additions (`tpn-supabase.js`)

New schedule helpers:
- `TPN.weekStartISO(date)` — Monday of a given date as `YYYY-MM-DD`
- `TPN.getSchedule(staffId, weekStart)`
- `TPN.listSchedulesForWeek(weekStart, branchId?)`
- `TPN.upsertSchedule({ staffId, weekStart, shifts, notes })`
- `TPN.deleteSchedule(id)`

All persistent actions log to `audit_log` on success.

---

## Setup checklist (in order)

1. **Extract the zip and overwrite local files** (keep your own `config.js` — don't overwrite it).
2. **Run the new SQL migration** in Supabase SQL Editor:
   ```
   sql/08-schedules.sql
   ```
3. **Redeploy the edge function** so new accounts start as `pending`:
   - Supabase Dashboard → Edge Functions → `create-staff` → replace the code with the contents of `supabase/functions/create-staff/index.ts` → Deploy.
4. **Push to GitHub:**
   ```
   git add .
   git commit -m "persistent schedules + pending-account workflow"
   git push
   ```

## Still not wired (next session)

- Staff attendance — still placeholder (needs clock-in/out flow + attendance table)
- Payment webhooks — waiting on uncle's paid Supabase and GCash Business API
- SMS 2FA
