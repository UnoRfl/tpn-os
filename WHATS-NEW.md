# What's new in this build — hardening release

No new features. This release closes security holes, fixes defects, and
brings the discount subsystem into the repository for the first time.

Everything here was verified on a local PostgreSQL 16 cluster rebuilt
from these migrations, with each permission exercised as each of the
nine roles. Three defects were found in the first draft of this work and
fixed before delivery — see "How this was tested" at the end.

---

## The headline: two real holes

**1. Anyone in your branch could rewrite an order total.**
`update orders set total = 1` persisted, for every role from dining
upward. The update policy checks only the branch, and the guard trigger
covered status and discounts but not `total` or `subtotal`. This is the
same "pay ₱1 for a ₱1500 order" attack migration 11 was written to
close — just reachable by writing the total instead of adding a cheap
line.

Fixed by locking both columns to the recompute path. A role check would
have broken ordinary service, because those columns are legitimately
written as a side effect of a **dining** staffer adding an item. So the
recompute function now announces itself with a transaction-local flag
and the guard trusts only that.

**2. `audit_log_archive_old()` had no role check.**
Its two siblings both check manager+. This one did not, and it was
granted to every signed-in account. Now guarded, with a minimum
retention window so nobody can pass -1 and archive today's rows.

While fixing it we found it had **never worked at all** — an ambiguous
`created_at` between two joined tables meant it always threw. So the
"Archive now" button in History has been broken since it shipped. It
works now.

---

## Also fixed

| # | What |
|---|---|
| 3 | The floor panel stored raw database statuses but compared against UI lane names, so a freshly loaded order showed **no advance button at all** and could never leave `confirmed` from that surface. |
| 4 | **Close Table wrote nothing to the database.** No order was completed, no table signal cleared. A refresh brought the table back, occupied and still flagged for billing. It now completes the orders and clears the signals. |
| 5 | The dining-floor screen could display "Table 4 is calling staff" but not dismiss it — `ack_call_staff` required `dining` and the screen role sits below that. Both ack functions now accept the floor screen, and gained a branch check they never had. |
| 6 | **Every customer QR order was saved with a null menu item link and a null pax size.** The submit mapper read fields that do not exist on a cart line. Per-dish sales reporting has been silently empty; item-level special requests never reached the kitchen. |
| 7 | `cancel_void_request` was the only void mutator that logged nothing. Now audited, and it notifies the requester if a manager withdrew their request. |
| 8 | `unvoid_order_item` could restore an item onto a **closed** order and change its total after the fact. Now refuses terminal orders, like its counterpart. |
| 9 | A failed order rollback silently deleted nothing (no DELETE policy), leaving orphan ₱0 orders. Now works, via a policy narrow enough to only ever reach an order with no lines. |
| 10 | TRUNCATE was granted to `anon` and `authenticated` on 14 tables including `staff`. TRUNCATE bypasses RLS entirely. Revoked, and the default that re-grants it is switched off. |

---

## New: discounts are audited, and finally in the repo

`sql/16-discounts.sql` reconstructs the discount subsystem, which had
been applied straight to production and existed in **no file** in this
repository. A rebuild from this repo would have produced a database with
no discounts at all, and nobody could review what those functions
enforced.

Two things were added while versioning it:

- **Audit rows on apply and remove.** Discounts are the biggest cash
  shrinkage vector in a restaurant after voids, and the live functions
  wrote nothing. Template edits were logged; discounting a live check
  was not.
- **A branch guard.** A supervisor in one branch could discount another
  branch's check.

We also found **two generations of the discount system running at once**
— an older `discount_presets` pair that wrote `orders.total` directly,
behind the recompute chain's back. It was already broken (it wrote to an
`audit_log.details` column that does not exist, so it threw on every
call). Removed.

---

## Order lifecycle is now audited

Nothing recorded order completion, cancellation or payment. There was no
way to answer "who closed this check, and for how much?".

Deliberately narrow — only the financially significant transitions.
Moving a ticket through the kitchen lanes writes nothing. Measured: one
audit row per order created, three per discount applied.

---

## Security housekeeping

- Password minimum raised from 6 to 8 characters, everywhere.
- **30-minute idle timeout** on back-office sessions, with a 2-minute
  warning. The wall screens are exempt on purpose — a screen that logs
  itself out mid-service is worse than one nobody is watching.
- Logout now tears down the void-request subscription and badge, which
  previously survived a re-login as a different user.
- All 18 trigger functions are no longer exposed as REST endpoints. Done
  by shape rather than a hardcoded list, so future ones are covered too.
- `search_path` pinned on the last unpinned function.

### Two Supabase advisor warnings will remain, correctly

`signal_call_staff` and `signal_bill_request` stay callable without
signing in. That is how a customer at a table taps "Call staff" and
"Bill". Both take only a table id and are rate-limited to one per 90
seconds. **Do not "fix" these** or the customer buttons stop working.

---

## Setup

1. **Run `sql/16-discounts.sql`** in the Supabase SQL Editor. Wait for
   Success.
2. **Run `sql/17-hardening.sql`.** Run it separately so a failure is easy
   to read.
3. **Redeploy the `create-staff` edge function** (password minimum).
4. **In the Supabase dashboard → Authentication → Policies, turn on
   "Leaked password protection".** This is the one warning in your list
   that is a dashboard toggle, not code — it checks new passwords against
   HaveIBeenPwned.
5. Push the frontend (see below).

### Verify

```sql
-- must be 0
select count(*) from information_schema.role_table_grants
 where table_schema='public' and grantee in ('anon','authenticated')
   and privilege_type='TRUNCATE';

-- must WORK now (it never has)
select * from public.audit_log_archive_old(31);
```

Signed in as a dining account, this must fail with `totals_are_derived`:

```sql
update public.orders set total = 1 where id = '<any order>';
```

...while adding an order item must still work and still recompute.

---

## Deliberately NOT in this release

These are architectural changes, not additions, and each needs its own
testing cycle:

**offline order queueing · structured modifiers · split bills · cash
drawer and shift reconciliation · inventory · labor cost**

Offline mode in particular is the single biggest remaining gap against
how commercial restaurant POS systems work, and it is a change to the
order pipeline rather than something that can be bolted on safely.

Three more are account actions, not code: **nightly backups with a
tested restore**, **error monitoring** (Sentry), and **a staging Supabase
project** so migrations stop going straight into production by paste.

---

## How this was tested

A PostgreSQL 16 cluster was built from scratch, Supabase's roles and
default grants stubbed, and migrations 01→17 replayed. Every permission
was then exercised as each of the nine roles.

The first draft of migration 17 contained a **blocker**: a Postgres array
append that resolved to the wrong operator and would have made the audit
trigger throw on every order line, checkout, void, discount and payment
— for every role. It was caught here, not in production. Two smaller
regressions were caught the same way: a null-comparison that let an
account with no staff row clear table signals, and the ambiguous column
in the archive function.

Migrations 01→17 now replay on a fresh database with **no workarounds**
— two long-standing defects in `sql/11` that blocked any rebuild are
fixed at source. Both 16 and 17 are idempotent across three consecutive
runs.
