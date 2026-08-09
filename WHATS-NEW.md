# What's new in this build

## Session persistence (the big one)

**Refresh no longer boots you back to the login screen or dashboard.**
If you're logged in and hit refresh — from Menu Manager, Live Orders, Accounts, anywhere — the app now:
1. Detects your existing Supabase session on page load
2. Drops you straight back into the portal
3. Restores the exact sidebar tab you were on

Powered by an existing Supabase session + a saved-route pointer in `localStorage`. Signing out clears it.

## Actions that now write to the database

**Staff Board drag & drop.**
Moving a staff chip between branches or role slots writes the new `role` and `branch_id` to Supabase and logs the change to `audit_log`. Optimistic UI with rollback if the save fails.

**Account state actions.**
Every button in the Accounts panel now hits the DB:
- Validate (approve pending) → sets `employment_status = active`
- Reject → `disabled`
- Recommend Disable (CEO/Admin) → `recommended`
- Disable Now (Director) → `disabled`
- Reinstate → `active`
- Cancel Recommendation → `active`

All logged to `audit_log`. Optimistic UI with rollback on failure. RLS: admin+ only, matching current UI gating.

**Prep-time analytics — real numbers.**
The Kitchen Performance drilldown no longer shows a placeholder. It computes real averages from the `confirmed_at → ready_at` timestamps that Supabase already writes when staff advance orders through the workflow. Shows: avg prep time, fastest & slowest, orders today, orders completed.

Prep-time timestamps (`confirmed_at`, `ready_at`, `served_at`, `completed_at`) are now carried into the client order objects, and the realtime UPDATE handler keeps them in sync.

## Backend additions (`tpn-supabase.js`)

New helpers:
- `TPN.updateStaffEmploymentStatus(staffId, newStatus, reason?)`
- `TPN.updateStaffBranch(staffId, branchId)`
- `TPN.updateStaffAssignment(staffId, { role, branchId })`

All log to `audit_log` on success.

---

## Setup reminder

No new SQL migrations this session. Just:
1. Extract, overwrite local files
2. Paste keys into `config.js` (still gitignored)
3. `git add . && git commit -m "session persistence + staff/account DB wiring" && git push`

## Still not wired (next session)

- Persistent schedule table (needs new `schedules` DB table + CRUD UI)
- Payment webhooks (GCash/Maya QRs still display-only)
- SMS 2FA
- New staff still default to `employment_status = 'active'`. If you want a "pending → CEO validates" flow, the `create-staff` edge function needs a one-line change and the Accounts UI needs to know about it.
