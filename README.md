# TPN OS

Production-ready MVP of the Tyo Paeng Nyo three-surface web system. All data lives in Supabase; menu, staff, orders, and inquiries load dynamically. No hardcoded content.

- **`index.html`** — public site + staff portal
- **`tpn-table-menu.html`** — dine-in customer menu (opens via table QR)
- **`tpn-dine-in-floor.html`** — live floor panel for staff
- **`tpn-supabase.js`** — shared Supabase data layer
- **`supabase/functions/create-staff/`** — Edge Function for admin-only account creation

## First-time setup

### 1. Run the SQL migrations (in order)
In Supabase SQL Editor:

1. `sql/01-schema.sql` — tables, RLS, triggers
2. `sql/02-seed.sql` — branches, menu categories, sample menu items, physical tables
3. `sql/03-security-fixes.sql` — hardens the schema
4. `sql/04-signals.sql` — call-staff / bill-request signals
5. `sql/05-anon-orders.sql` — lets anonymous customers place orders
6. `sql/06-menu-fields.sql` — adds emoji + featured columns for menu items
7. `sql/07-single-branch.sql` … `sql/14-restaurant-performance.sql` — in order
8. `sql/15a-display-roles.sql` — **run this one ON ITS OWN, alone.** It adds the two display-device roles to the `staff_role` enum, and Postgres refuses to add an enum value and use it in the same transaction. The SQL Editor runs your whole paste as one transaction, so pasting 15a and 15b together makes 15b fail.
9. `sql/15b-void-requests.sql` — void request workflow + the guard rails that keep display accounts from voiding
10. `sql/16-discounts.sql` — the discount subsystem (templates, applied discounts, apply/remove), versioned from production and given audit rows
11. `sql/17-hardening.sql` — locks order totals to the recompute path, revokes TRUNCATE, audits the order lifecycle, clears the Supabase advisor warnings
12. `sql/18-anon-order-fix.sql` — **restores anonymous pickup/delivery ordering.** Production was running the original dine-in-only policy from `sql/01`, so every pickup and delivery order from the public site failed with a permissions error. Also pins what an anonymous order may assert: it must arrive pending, unpaid and undiscounted.
13. `sql/19-access-control.sql` — custom roles, the permission catalogue, the role/permission grid and `private.can()`
14. `sql/20-tasks.sql` — the task board: many assignees per task, each with their own progress
15. `sql/21-inventory-and-finance.sql` — ingredients, stock movements, suppliers, pay rates, operating expenses and `finance_summary()`
16. `sql/22-board-read-helpers.sql` — `staff_directory()`, `task_board()` and `inventory_board()`; these exist because staff RLS is tighter than the boards need
17. `sql/23-function-grant-hardening.sql` — closes the new RPCs to anonymous callers. **Do not skip this one:** `revoke ... from anon` alone does not close a function, because Postgres also grants EXECUTE to PUBLIC by default.

### 2. Disable public signups
Supabase Dashboard → **Authentication → Providers → Email** → find **"Enable signups"** (or "Enable email signups") → **toggle OFF**.

Once this is off, `sb.auth.signUp()` from anywhere on the internet will be blocked. Account creation only happens through the Edge Function (next step).

### 3. Deploy the create-staff Edge Function
This is the ONLY way to create accounts after step 2.

Supabase Dashboard → **Edge Functions** → **Deploy a new function**:
- Function name: `create-staff`
- Copy the entire contents of `supabase/functions/create-staff/index.ts`
- Paste into the code editor
- Click **Deploy function**

The function automatically gets access to `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` from Supabase's built-in secrets. You don't set these manually.

### 4. Paste your Supabase credentials into the frontend
Open `tpn-supabase.js` and replace the two placeholder values at the top with values from Supabase → Project Settings → API. (Only the URL and the **anon public** key — never the service_role key.)

### 5. Create your first admin user
Since public signup is off, you can't sign up through the website. Create your account manually:

Supabase → **Authentication → Users → Add user** → **Create new user**
- Email: your email
- Password: your choice
- Auto Confirm User: ✓ ticked

Then promote yourself in SQL Editor:
```sql
update public.staff
set role = 'ceo',
    full_name = 'Your Name Here',
    branch_id = (select id from public.branches where code = 'laspinas')
where id = (select id from auth.users where email = 'YOUR-EMAIL');
```

That user is now CEO. From now on, all future accounts get created through the app (Portal → Accounts → + Add Staff).

## Adding staff (once set up)

Log in as CEO/admin/manager → **Accounts → + Add Staff**.

Fill in name, email, temporary password, role, branch. The edge function will:
1. Verify your session is valid and your role is manager+
2. Reject if you try to grant a role higher than your own
3. Create the auth user + staff row
4. Log the action to `audit_log`

The staff member logs in with that email + password at the same login screen and should change their password from Settings after.

## Managing the menu

**Menu Manager** in the portal sidebar. Add, edit, "86", or delete items. Changes reflect immediately on all customer surfaces.

## Do I need Vercel?

**No.** GitHub Pages hosts the frontend (static HTML/JS), Supabase hosts the database + auth + realtime + edge functions. That's a full-stack setup with no additional hosting service needed.

Vercel would be relevant if you wanted:
- Server-side rendering (this site is client-rendered)
- Serverless functions co-located with the frontend (Supabase Edge Functions cover this)
- Its analytics or preview deployments

For this project, GitHub Pages + Supabase is enough and cheaper (both free tiers).

## Test locally

```
python -m http.server 8000
```

Then visit:
- Public site + staff portal: <http://localhost:8000/>
- Table menu: <http://localhost:8000/tpn-table-menu.html?table=3&branch=Las%20Pi%C3%B1as&branchId=laspinas>
- Floor panel: <http://localhost:8000/tpn-dine-in-floor.html>

## Push updates to GitHub

From the folder in cmd:
```
git add .
git commit -m "your message"
git push
```

GitHub Pages auto-redeploys in ~30 seconds.

**Note:** The `supabase/functions/create-staff/` folder is bundled in the repo for reference and future edits, but GitHub Pages doesn't run it. It runs on Supabase's edge network after you deploy it via the dashboard.

## Security model summary

| Action | Who can do it | Where it runs |
|---|---|---|
| Sign up | Nobody (disabled) | — |
| Log in | Anyone with valid credentials | Supabase Auth |
| Place order (dine-in) | Anonymous customer at a table | Supabase (RLS-gated) |
| Place order (pickup/delivery) | Anonymous customer via website | Supabase (RLS-gated) |
| Submit inquiry | Anyone | Supabase (RLS-gated) |
| View orders/inquiries | Authenticated staff (branch-scoped) | Supabase (RLS-gated) |
| Manage menu | Manager+ | Supabase (RLS-gated) |
| **Create staff accounts** | **Manager+ (can only grant roles ≤ own level)** | **Edge Function** |
| Create a display device account | Admin+ only | Edge Function |
| Void an item / order | **Manager+ only** | Supabase (SECURITY DEFINER fn) |
| Request a void | Any active staff account, incl. display screens | Supabase (SECURITY DEFINER fn) |
| Approve / deny a void request | **Manager+ only** (supervisor excluded) | Supabase (SECURITY DEFINER fn) |
| Apply a discount | Supervisor+, own branch, audited | Supabase (SECURITY DEFINER fn) |
| Remove an applied discount | Manager+, own branch, audited | Supabase (SECURITY DEFINER fn) |
| Change an order total directly | **Nobody** — derived from items and discounts | Supabase (trigger) |
| Create or change a role | `roles.edit` (floors at admin) | Supabase (RLS + trigger) |
| Assign a task to several people | `tasks.assign` (floors at supervisor) | Supabase (RLS) |
| Mark *your own* progress on a task | Any assignee, no permission needed | Supabase (SECURITY DEFINER fn) |
| Book in a delivery | `inventory.receive` (floors at kitchen) | Supabase (RLS) |
| Write off or adjust stock | `inventory.adjust` (floors at manager) | Supabase (RLS) |
| See what the business actually made | `finance.view` (floors at manager) | Supabase (SECURITY DEFINER fn) |
| See or change pay rates | `payroll.view` / `payroll.edit` (edit is CEO-only) | Supabase (RLS) |

## Roles

### Two layers, and which one is the lock

As of migration 19 there are two things called a "role", and the difference matters:

| | `staff_role` enum | `access_roles` row |
|---|---|---|
| What it is | Nine fixed tiers baked into Postgres | Roles you create in the portal |
| What it controls | What the database will **physically permit** | What the portal **offers**, and the new tables in migrations 20–22 |
| Can it be changed from the UI | No | Yes |
| Is it the security boundary | **Yes** | No |

A custom role can take away access its tier would have allowed. It can never
grant access the tier forbids — `permissions.min_tier` records that floor and
`trg_role_perm_floor` refuses any grant above it, so you cannot build a role
that looks powerful in the Access Matrix and then fails at the database.

`private.can()` short-circuits to true for `ceo` before it reads any table, so
no combination of settings in the roles editor can lock the CEO out of the
roles editor.

### The enum

The `staff_role` enum, lowest privilege first:

```
kitchen_display, dine_in_display, dining, kitchen,
supervisor, manager, admin, director, ceo
```

Position matters. `private.has_role(min_role)` compares positions in this
enum, so a role's place in that list *is* its permission set. The two
`*_display` roles sit at the bottom deliberately: they're shared logins for
the wall-mounted screens, so every `has_role()` check fails for them —
including `has_role('manager')`, which is what gates voiding.

Three places mirror this list and must stay in lockstep with the database:
`tpn-supabase.js` (`TPN.ROLE_HIERARCHY`), `index.html` (`DISPLAY_ROLES` /
`ROLE_LABELS`), and `supabase/functions/create-staff/index.ts`
(`ROLE_HIERARCHY`). Drift between them is a security bug, not a cosmetic one.

### Display device accounts

`kitchen_display` and `dine_in_display` are accounts for screens, not
people — one shared login per mounted device. On sign-in they go straight
to their own surface (Kitchen Station / Dine-In Floor) and cannot reach the
staff portal at all. They can read and advance tickets. They cannot void,
cancel, open orders, touch money columns, or see any staff data.

To void anything they file a **void request**, which only manager+ can
approve. See WHATS-NEW.md for the full workflow.

## What's still simplified for MVP

- Staff Board, Recognition Panel, Audit Log — panels render; writing not yet wired
- No SMS 2FA — password-only login for now
- Payment webhooks — GCash/Maya QRs display-only

## Production checklist

- [ ] Move Supabase to Pro tier ($25/mo) — free tier pauses after 1 week idle
- [ ] Wire real payment webhook (GCash Business API)
- [ ] Add SMS 2FA for manager+ (Semaphore)
- [ ] BIR-compliant receipts still via StoreHub
- [ ] Nightly Supabase backups
