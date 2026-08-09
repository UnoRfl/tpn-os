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
