# What's new in this build

Two things this round, and they're the same thing seen from two sides:
**display device accounts** for the wall screens, and a **void request
workflow** so those screens (and every staff member below manager) can ask
for a void instead of doing one.

---

## Display device accounts

Two new roles: **`kitchen_display`** and **`dine_in_display`**.

These are accounts for *screens*, not people. One shared login for the
tablet/TV in the kitchen, one for the tablet/TV on the dining floor. Real
staff keep their own personal accounts for schedules, time-in, messages
and announcements — those are untouched.

**What a display account does when it signs in:** nothing but its own
surface. `kitchen_display` lands on the Kitchen Station. `dine_in_display`
lands on the Dine-In Floor panel. Neither can open the staff portal at all
— if one somehow lands on `index.html`, it gets bounced straight back.

**What a display account cannot do:**

- Void anything (the point of the exercise)
- Cancel an order
- Open a new order or add a line to one
- Change totals, discounts, service charge, or payment fields
- 86 a menu item, add a table, or open branch settings
- See schedules, attendance, messages, staff records, inquiries, revenue
  or the audit log
- Read branch-wide broadcast messages or notifications about other people

The dine-in screen shows **Covers Tonight** where a manager sees **Session
Revenue** — a screen in a public dining room shouldn't display takings.

**Where the lock actually lives.** The two roles are inserted at the
*bottom* of the `staff_role` enum, below `dining`. `private.has_role()`
compares enum positions, so every `has_role()` check in the database fails
for them automatically. On top of that, migration 15b closes the policies
that gated on *branch alone* rather than role — that's what would otherwise
have let a screen run a plain `UPDATE order_items SET voided_at = now()`
and quietly drop an order total to zero.

**Creating one:** Accounts → + Add Staff → Role → *Display devices*.
Admin, Director or CEO only — a screen is infrastructure, set up once, and
it goes live immediately rather than sitting in the pending queue.

---

## Void requests

Before this, `void_order_item()` was manager+ only and there was no other
path. Anyone below manager had to physically find a manager with a device.

Now everyone below manager — dining, kitchen, supervisor, and both display
screens — files a **request** instead:

1. Staff or screen taps **✕ / Request void**, types a reason (min 3 chars).
2. Every manager+ in that branch gets a high-priority notification, and the
   sidebar badge lights up under **Void Requests**.
3. A manager approves or denies, with an optional note.
4. Approval is what actually performs the void, recorded under the
   **manager's** name in the audit log. The requester is notified either
   way, in realtime, on whatever surface they're looking at.

Two scopes: a **single item**, or the **whole order** (walkout, duplicate
ticket) — approving a whole-order request voids every remaining line and
marks the order cancelled.

Supervisors can file requests but cannot approve them. This deliberately
matches the existing rule in `void_order_item()`.

**Managers still void directly** from Live Orders, unchanged. Whole-order
voids by a manager run through the same request→approve pipeline so there's
one audit shape for them.

**Where to find it:**

- Manager+ → sidebar **Void Requests** (with pending count badge)
- Supervisor → same tab, showing only their own requests
- Dining/kitchen staff → **My Void Requests** in the staff sidebar
- Kitchen Station → small **✕** on each ticket line
- Dine-In Floor → **✕** in the order detail modal

---

## Setup checklist (in order)

1. **Run the SQL migrations — 15a ON ITS OWN, FIRST.**

   In Supabase SQL Editor, paste `sql/15a-display-roles.sql`, run it, wait
   for Success. Nothing else in that window.

   Postgres won't let you add an enum value and use it in the same
   transaction, and the SQL Editor runs your whole paste as one
   transaction. If you run them together, 15b fails.

   Then, separately, run `sql/15b-void-requests.sql`.

2. **Redeploy the edge function** so it knows the new roles:
   Supabase Dashboard → Edge Functions → `create-staff` → replace with
   `supabase/functions/create-staff/index.ts` → Deploy.

3. **Create the two screen accounts** as Admin/Director/CEO:
   Portal → Accounts → + Add Staff → Role → Display devices.
   Use addresses like `kitchen-screen@tyopaengnyo.com`.

4. **Sign each screen in once** on its device and leave it signed in.

5. **Push to GitHub:**
   ```
   git add .
   git commit -m "display device accounts + void request workflow"
   git push
   ```

### Verify it worked

Signed in as a display account, this must fail:

```sql
update public.order_items set voided_at = now() where id = '<any id>';
-- ERROR: permission denied for table order_items
```

And the enum order should read bottom-to-top:

```sql
select unnest(enum_range(null::public.staff_role));
-- kitchen_display, dine_in_display, dining, kitchen,
-- supervisor, manager, admin, director, ceo
```

---

## Still not wired

- Payment webhooks — waiting on the paid Supabase transfer and GCash
  Business API
- SMS 2FA
