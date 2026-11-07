# Moving TPN OS to another Supabase account

This is the full plan for moving the TPN OS database off the current Supabase project. It covers the "uncle transfer" that HANDOFF.md lists under Deferred, and any later move. Everything a person or a Claude needs is in this repo:

- **MIGRATION.md** (this file): the steps, the code changes, the checks and the rollback.
- **[MIGRATION-SQL.md](MIGRATION-SQL.md)**: every SQL file in full, in run order, with an md5 for each.
- **`ops/migration/after-restore.sql`**: puts back what a dump leaves out (auth trigger, storage, realtime) and checks the result.
- **`ops/migration/count-rows.sql`**: exact row counts, to compare old and new.
- **`ops/migration/build-sql-bundle.mjs`**: rebuilds MIGRATION-SQL.md after a new migration.

Written Nov 7, 2026 against production as it was that day (main = Rev 41, plus the recovered sql/49 and sql/50).

## What is moving

| Piece | Today |
|---|---|
| Supabase project | `tpn-os`, ref `xjlqfpnzobfqxetgkkai`, region `ap-southeast-1` (Singapore), Postgres 17.6, created Aug 8, 2026 |
| Schemas the app owns | `public` (56 tables, 142 functions) and `private` (5 tables, 57 functions) |
| Logins | 4 users in `auth.users`, 4 rows in `auth.identities`. Email and password only, no SMS, no social sign-in, no redirect URLs |
| Extensions | `pgcrypto`, `uuid-ossp` (schema `extensions`), `pg_stat_statements`, `supabase_vault` (empty). No `pg_cron`, no `pg_net` |
| Storage | One private bucket, `attendance-photos` (1 MB, JPEG only, 3 policies), 0 files |
| Realtime | 10 tables: attendance, inquiries, menu_items, messages, notifications, order_items, orders, payments, restaurant_tables, void_requests |
| Edge functions | `create-staff` only (version 4, verify JWT on). The `hitpay-*` functions are in the repo but **not deployed**, because online payments are off |
| Function secrets | `create-staff` uses only `SUPABASE_URL`, `SUPABASE_ANON_KEY` and `SUPABASE_SERVICE_ROLE_KEY`, which every project sets by itself. HitPay would also need `HITPAY_*` keys, but it is not live |
| Secret data | `private.loyalty_secret` (signs stamp-card codes) and `private.staff_pins` (manager PIN hashes). Both must move as they are, or old stamp cards and PINs stop working |
| Biggest tables | access_role_permissions 576, audit_log 280, private.rate_hits 114, permissions 64, menu_items 62, order_items 27, notifications 25, orders 11 |
| Migrations | 60 files in `sql/` (01 to 53, plus the drift file). Production's own history lists every one from 16 to 53. 01 to 15b and 39 were run by hand in the SQL Editor before tracking began |

**Still open on production (Nov 7).** These are not blockers, but close them before the move so day one on the new project starts clean:

- 1 cash drawer still open (the Counter, since Oct 22).
- 1 person still clocked in (since Oct 22).
- 10 orders that are not both completed and paid, including "Testing 2" (₱145). **All orders on production are test orders (owner, Nov 7), so ignore them.** They can move as they are; nobody needs to settle or cancel them.

## Choose the path

| | **A. Transfer the project** (recommended) | **B. Copy to a new project** | **C. Rebuild empty** |
|---|---|---|---|
| What happens | Supabase moves the same project into your uncle's organization | A new project is made in your uncle's organization, and the whole database is dumped and restored into it | A new project is built from the SQL files, without the old data |
| Data, logins, PINs, stamp cards | All kept, untouched | All copied | **Lost**: staff accounts, orders and the audit log start empty |
| URL and keys | Same. No code change | New. Code and devices change (B7) | New. Code and devices change |
| Downtime | A few minutes, or none | About 1 to 2 hours, best done after closing | About 1 to 2 hours plus re-entering staff and the menu |
| Risk | Lowest | Medium, but the old project stays as a fallback | Highest |

Use **A** if your uncle's organization can own the project directly. That is what "transfer" means in Supabase, and nothing in the app changes. Use **B** only if a fresh project is wanted, for example in another region or under a different account setup. **C** is a last resort, for when the old project is gone and there is no backup.

---

## Path A: transfer the project

1. **Your uncle** creates a Supabase account and an organization, and picks the paid plan he wants (Pro or higher).
2. **Your uncle** invites the current owner's Supabase account into that organization as **Owner**. The person doing the transfer has to be an owner in both organizations. The Transfer screen states the exact rule and any plan limits.
3. **Current owner:** before the transfer, take a backup by hand (HANDOFF.md → Backups), and run `ops/migration/count-rows.sql` in the SQL Editor. Save the result.
4. **Current owner:** Supabase → project `tpn-os` → Project Settings → General → **Transfer project**, then pick the uncle's organization. Supabase warns that the project may restart. Do it after closing time.
5. **Check:**
   - Run `count-rows.sql` again. It should be identical.
   - Open the website, the portal, the floor screen and the kitchen screen, and sign in once on each.
   - Place a test order from the QR menu, pay it with cash at the Counter, then void the test.
6. **After:**
   - Billing now goes to your uncle's organization. Turn on **Authentication → Leaked password protection** now that the plan is paid (GO-LIVE §0).
   - The nightly backup keeps working, because the address and database password are unchanged. Check `C:\TPNBackup\backup.log` the next morning.
   - Remove the old owner from the organization only when your uncle says so.
   - Update the "Owner of the Supabase account" line in SYSTEM-GUIDE.md and add a HANDOFF rev.

Nothing in the repo changes for Path A: the ref `xjlqfpnzobfqxetgkkai`, `config.js`, the apps and the backups all stay as they are.

---

## Path B: copy everything to a new project

You need:

- **The Supabase CLI.** On Mac: `brew install supabase/tap/supabase`. On Windows: `scoop install supabase`. The CLI may ask for Docker Desktop for `db dump`. If it does, install Docker, or use the `pg_dump` fallback in B4.
- **PostgreSQL 17 client tools** (`psql`, `pg_dump`). The headless backup PC already has them in `C:\TPNBackup\bin`.
- **Both database passwords.** Type them yourself when asked. Never paste them into a chat, a file in this repo, or a URL.
- **A quiet window**, after closing, with the drawer closed and everyone clocked out.

### B1. Freeze and record

1. Close the open drawer and clock out whoever is still in (Daily close → Close the day lists both). The open orders are test data: leave them.
2. Take a backup by hand: on the headless PC, run the `TPN OS Backup (nightly)` task now (HANDOFF.md → Backups).
3. Run `ops/migration/count-rows.sql` on the **old** project and save the result as `counts-old.txt`.
4. From here until B8, nobody uses the system. Put a note on the counter.

### B2. Make the new project

1. In your uncle's organization: New project. Name it `tpn-os`, pick region **Southeast Asia (Singapore) `ap-southeast-1`**, and a strong database password (keep it in a password manager).
2. Wait until it says Healthy. Note the new **ref** (the part before `.supabase.co`) and, from Project Settings → API, the new **anon / publishable key**. Never copy the service-role key anywhere.
3. Connection strings: Project Settings → Database → Connection string → **Session pooler**. They look like this:
   - old: `postgresql://postgres.xjlqfpnzobfqxetgkkai:[PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres`
   - new: `postgresql://postgres.[NEW_REF]:[PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres`

   (The pooler host for the new project can differ, for example `aws-1-…`. Copy the one the dashboard shows.)

### B3. Dump the old project (Supabase's own method)

Run in an empty folder outside the repo, because the dumps hold customer names and phone numbers. Set the two URLs in your shell, so the password is not saved in the command history (zsh/bash: start the line with a space):

```bash
 export OLD_DB_URL='postgresql://postgres.xjlqfpnzobfqxetgkkai:[OLD_PASSWORD]@aws-0-ap-southeast-1.pooler.supabase.com:5432/postgres'
 export NEW_DB_URL='postgresql://postgres.[NEW_REF]:[NEW_PASSWORD]@[NEW_POOLER_HOST]:5432/postgres'
```

```bash
supabase db dump --db-url "$OLD_DB_URL" -f roles.sql --role-only
```

```bash
supabase db dump --db-url "$OLD_DB_URL" -f schema.sql
```

```bash
supabase db dump --db-url "$OLD_DB_URL" -f data.sql --use-copy --data-only
```

`schema.sql` holds `public` and `private` (tables, functions, policies, grants, enums). `data.sql` holds the rows, including `auth.users` and `auth.identities`, so passwords carry over as they are.

### B4. Restore into the new project

```bash
psql --single-transaction --variable ON_ERROR_STOP=1 --file roles.sql --file schema.sql --command 'SET session_replication_role = replica' --file data.sql --dbname "$NEW_DB_URL"
```

`session_replication_role = replica` loads rows without firing triggers. Without it, the audit triggers would write a fake "change" for every restored row, and `on_auth_user_created` would try to make a second staff row for each login.

If it stops on an error, nothing is half-written, because it runs as one transaction. Read the error, fix it, and run it again. Errors about objects Supabase manages itself (`supabase_admin`, `pgsodium`, the `realtime` schema) can be removed from the dump file and the command run again.

**Fallback without the Supabase CLI** (this is step 5 of HANDOFF → Backups → Restore, written out in full):

```bash
pg_dump "$OLD_DB_URL" --format=custom --no-owner --file=tpn.dump
```

```bash
pg_restore --no-owner --data-only -n auth -t users -t identities --dbname "$NEW_DB_URL" tpn.dump
```

```bash
pg_restore --no-owner -n public -n private --dbname "$NEW_DB_URL" tpn.dump
```

Logins go first, because `staff.id` points at `auth.users.id`. Expect a few errors on Supabase-managed objects. B6 shows whether anything that matters was missed.

### B5. Put back what the dump leaves out

In the **new** project: SQL Editor → paste `ops/migration/after-restore.sql` (shown in full below) → Run. The last result must show `ok = true` on all 11 rows. The same checks were run on production on Nov 7 and all passed.

```sql
-- ═══════════════════════════════════════════════════════════════
-- after-restore — run ONCE on the NEW Supabase project, after the
-- schema and data are in (MIGRATION.md, step B5). Safe to re-run.
-- (full file: ops/migration/after-restore.sql)
-- ═══════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attendance-photos', 'attendance-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

drop policy if exists clockin_photo_upload on storage.objects;
create policy clockin_photo_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'attendance-photos'
    and split_part(name, '/', 3) = auth.uid()::text
    and exists (select 1 from public.attendance a
                 where a.staff_id = auth.uid()
                   and name like '%/' || a.id::text || '.jpg'
                   and a.photo_path is null
                   and a.clock_in_at > now() - interval '10 minutes')
  );
drop policy if exists clockin_photo_read on storage.objects;
create policy clockin_photo_read on storage.objects for select to authenticated
  using (bucket_id = 'attendance-photos' and private.can('attendance.verify'));
drop policy if exists clockin_photo_delete on storage.objects;
create policy clockin_photo_delete on storage.objects for delete to authenticated
  using (bucket_id = 'attendance-photos' and private.can('attendance.verify'));

do $$
declare t text;
begin
  foreach t in array array['attendance', 'inquiries', 'menu_items', 'messages', 'notifications',
                           'order_items', 'orders', 'payments', 'restaurant_tables', 'void_requests']
  loop
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = t) then
      execute format('alter publication supabase_realtime add table public.%I', t);
    end if;
  end loop;
end $$;

select 'pgcrypto installed' as name, exists (select 1 from pg_extension where extname = 'pgcrypto') as ok
union all
select 'auth trigger', exists (select 1 from pg_trigger where tgname = 'on_auth_user_created')
union all
select 'photo bucket private', exists (select 1 from storage.buckets where id = 'attendance-photos' and not public)
union all
select 'photo policies = 3', (select count(*) from pg_policies where schemaname = 'storage' and policyname like 'clockin_photo_%') = 3
union all
select 'realtime tables = 10', (select count(*) from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public') >= 10
union all
select 'staff_role enum order', (select string_agg(e.enumlabel, ',' order by e.enumsortorder) from pg_enum e join pg_type t on t.oid = e.enumtypid where t.typname = 'staff_role')
  = 'kitchen_display,dine_in_display,dining,kitchen,supervisor,manager,admin,director,ceo'
union all
select 'manager PIN (sql/49)', to_regprocedure('public.pin_check(text, text)') is not null
union all
select 'menu engineering (sql/50)', to_regclass('public.menu_item_costs') is not null
union all
select 'close the day (sql/52)', exists (select 1 from pg_proc where proname = 'close_day_checklist')
union all
select 'sold out stays listed (sql/53)', exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'menu_items' and column_name = 'is_listed')
union all
select 'stamp card secret kept', (select count(*) from private.loyalty_secret) > 0;
```

### B6. Compare row counts

Run `ops/migration/count-rows.sql` on the **new** project, save the result as `counts-new.txt`, and compare it with `counts-old.txt`. Every line must match. On Nov 7 the top lines were: access_role_permissions 576, audit_log 280, rate_hits 114, permissions 64, menu_items 62, order_items 27, notifications 25, auth.users 4, staff 4.

```sql
select table_schema || '.' || table_name as "table",
       (xpath('/row/c/text()',
              query_to_xml(format('select count(*) as c from %I.%I', table_schema, table_name), false, true, '')))[1]::text::bigint as "rows"
  from information_schema.tables
 where table_type = 'BASE TABLE'
   and (table_schema in ('public', 'private')
        or (table_schema, table_name) in (('auth', 'users'), ('auth', 'identities'),
                                          ('storage', 'buckets'), ('storage', 'objects')))
 order by 1;
```

Then Supabase → **Advisors → Security** on the new project. The only expected warnings are the customer functions that are public on purpose (`submit_order`, `track_order`, `claim_stamp_card`, `my_stamp_card`, `stamp_card_code`, `my_guest_profile`, `addon_suggestions`, `signal_*`), plus leaked-password protection until it is switched on.

### B7. Point the code at the new project

Do this on a `feature/` branch, test it, then merge to `main`. Pushing to `main` puts it live on GitHub Pages in about a minute. These are the only places the old project is written:

| File | What to change |
|---|---|
| `config.js` | `SUPABASE_URL` → `https://[NEW_REF].supabase.co`, `SUPABASE_ANON_KEY` → the new anon key |
| `index.html`, `portal.html`, `tpn-dine-in-floor.html`, `tpn-kitchen-station.html`, `tpn-table-menu.html`, `tpn-rewards.html` | Line 5, the CSP `<meta>`: both `https://xjlqfpnzobfqxetgkkai.supabase.co` and `wss://xjlqfpnzobfqxetgkkai.supabase.co` |
| `tpn-counter-sw.js` | `const SUPA = 'https://…supabase.co'` (line 29), and bump `VERSION` so the Counter drops its old offline cache |
| `tpn-kitchen-sw.js` | Bump `VERSION` (it has no URL, but the kitchen screen must reload fresh) |
| every page | Bump the `?v=` on script and style tags, as on every release |
| `ops/backup/install.ps1` | Line 6, the pooler user `postgres.xjlqfpnzobfqxetgkkai` (and the host if the new pooler is `aws-1-…`) |

One command does the URL part of the first three rows. It leaves `config.js`'s key and the version bumps to you:

```bash
grep -rlI 'xjlqfpnzobfqxetgkkai' --include='*.html' --include='*.js' --include='*.ps1' . | grep -v node_modules | xargs sed -i '' 's/xjlqfpnzobfqxetgkkai/NEW_REF/g'
```

(On Linux or Git Bash, use `sed -i` without the `''`.) Leave the old ref in `sql/16`, `sql/17`, HANDOFF.md and SYSTEM-GUIDE.md: there it is history, not configuration.

### B8. Edge function, auth settings, backups

1. **Edge function:** `supabase functions deploy create-staff --project-ref [NEW_REF]` from the repo root. Leave the `hitpay-*` functions undeployed, as on the old project.
2. **Authentication settings** (dashboard, not SQL). Copy these from the old project's screens to the new one:
   - Providers → Email: enabled. Confirm email and other switches set as on the old project.
   - Leaked password protection: **on** (it needs a paid plan, which this is).
   - Sessions / JWT expiry: 3600 seconds (old value).
   - Site URL: `https://unorfl.github.io/tpn-os/` (or the Vercel address if that move happened first).
   - No redirect URLs, SMS or social providers are used.
3. **Backups:** on the headless PC, update `install.ps1` (B7), then run `ssh -t headless powershell -NoProfile -File C:\TPNBackup\set-password.ps1` and type the **new** database password yourself. Run the backup task once by hand and check `C:\TPNBackup\backup.log`.

### B9. Devices and staff

- **Everyone signs in again.** Passwords are the same, but the old sessions belonged to the old project.
- **Counter (iMin) and Kitchen apps** open the website, not Supabase, so no new APK is needed. On each device: open the app while online, sign in, close it, and open it again. The second load caches the new menu for offline use.
- **Table QR codes** point at the website, so they keep working.
- **Manager PINs and stamp cards** keep working, because their secrets were copied in B4.

### B10. Check it live

1. Sign in on the portal as the CEO account, then as a cashier.
2. Floor screen: open a shift (float), place a dine-in order at the Counter, see it on the kitchen screen in real time, pay it in cash, and close the table.
3. QR menu on a phone: place an order, then press "Ask for the bill". The floor screen should show it at once.
4. Clock in on a phone on the restaurant Wi-Fi. The photo should upload to the bucket.
5. Void the test items with a manager PIN, then run Daily close → Close the day.
6. Look at Audit log: the test actions are there, with the right names.

### B11. Rollback and clean-up

- **If anything in B10 fails and can't be fixed in the window**, revert the B7 commit on `main`. The site points at the old project again within a minute. The old project was never changed, so it is still exact as of B1. Anything typed into the new project during testing stays only there.
- **Keep the old project for at least a week.** Then pause it (Project Settings → General → Pause), and delete it only after a later backup restores cleanly from the new project.
- Add a HANDOFF rev (Path B, the date, the new ref) and update SYSTEM-GUIDE.md's project line, GO-LIVE.md and the "Migration order" section.

---

## Path C: rebuild from the SQL files (no data)

Only if the old project is gone and no dump restores.

1. New project, as in B2.
2. Supabase → SQL Editor. Run the files **in the order of [MIGRATION-SQL.md](MIGRATION-SQL.md)**, one Run per file:
   - `sql/01-schema.sql` to `sql/17-hardening.sql`, then `tests/db/prod-drift-after-17.sql`, then `sql/18-anon-order-fix.sql` onward, up to `sql/53`.
   - `15a`, `29a` and `37a` are **RUN ALONE** (enum values). Run each one by itself, then the next file.
3. Run `ops/migration/after-restore.sql`. All rows should be `ok = true`. `sql/34` makes a **new** stamp-card secret, so stamp cards issued on the old project will not scan.
4. Create the first CEO login: Authentication → Users → Add user. Then in SQL, `update public.staff set role = 'ceo' where id = '<that user id>';`. After that, add the rest of the staff from the portal (it uses `create-staff`).
5. Then do B7 to B10. The menu comes back from `sql/02`, `39`, `40` and `42`. Prices or dishes changed in the portal after Oct 17 must be re-entered.

The same order is proven on every test run: `cd tests/db && npm install && node run.mjs` replays all 60 files into an empty Postgres and runs the 220 tests (220/220 on Nov 7).

---

## Notes for the Claude doing the move

- Read this file, then HANDOFF.md's newest rev, then the playbook rules in HANDOFF.md (one ordering door, server-side pricing, role enum order, paid bills frozen, bank needs a second person, no cash without a shift). None of them change in a move.
- `sql/49-manager-pin.sql` and `sql/50-menu-engineering.sql` were recovered on Nov 7, 2026 from production's own migration history (`supabase_migrations.schema_migrations`). They match it byte for byte (md5 in each file header). Before that they existed only on production. Only the SQL was recovered: the screens that use them (manager PIN at the counter, the menu engineering report) were never pushed, so the website does not call these functions yet. The move is not affected.
- Next free migration number: **54**.
- Never put a database password, the service-role key or the APK signing key in the repo, a chat or a URL. The owner types passwords in.
- After a Path B move, the project ref in this file and in SYSTEM-GUIDE.md is out of date. Update both in the same commit as B7.
