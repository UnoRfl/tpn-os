-- ═══════════════════════════════════════════════════════════════
-- after-restore — run ONCE on the NEW Supabase project, after the
-- schema and data are in (MIGRATION.md, step B5). Safe to re-run.
--
-- A Supabase dump only carries the app's own schemas (public, private).
-- The pieces below live in Supabase-managed places (auth, storage,
-- the realtime publication) and are not copied by the dump, so they are
-- put back here exactly as the migrations made them:
--   1. extensions      pgcrypto + uuid-ossp in schema extensions
--   2. auth trigger    on_auth_user_created → public.handle_new_user (sql/01)
--   3. storage         private bucket attendance-photos + 3 policies (sql/33)
--   4. realtime        the 10 tables production broadcasts (Nov 7, 2026)
--   5. checks          one row per item, all should say ok = true
-- ═══════════════════════════════════════════════════════════════

-- ── 1. Extensions ────────────────────────────────────────────────
create extension if not exists pgcrypto with schema extensions;
create extension if not exists "uuid-ossp" with schema extensions;

-- ── 2. New login → staff row (sql/01) ───────────────────────────
drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ── 3. Clock-in photo bucket + policies (sql/33) ────────────────
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

-- ── 4. Realtime: the tables the screens listen to ───────────────
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

-- ── 5. Checks (every row should say ok = true) ──────────────────
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
