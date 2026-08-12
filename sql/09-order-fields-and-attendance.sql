-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 09: Order fields + Attendance + Messages
--
-- This is the migration that was previously absent from the repo
-- but has been LIVE in the production DB. Reconstructed from the
-- code's field usage (tpn-supabase.js) so a fresh deploy can spin
-- up without missing tables.
--
-- Safe to run on Uno's existing production DB — every column,
-- table, index, and policy is guarded with IF NOT EXISTS / DROP-
-- IF-EXISTS.
-- ═══════════════════════════════════════════════════════════════

-- ── ORDER field extensions ────────────────────────────────────
-- These columns are referenced by createOrder + KDS but never made
-- it into 01-schema.sql.
alter table public.orders
  add column if not exists customer_email    text,
  add column if not exists customer_phone    text,
  add column if not exists delivery_address  text,
  add column if not exists scheduled_for     timestamptz,
  add column if not exists payment_method    text,
  add column if not exists cancel_reason     text,
  add column if not exists discount_amount   numeric(10,2) default 0,
  add column if not exists service_charge    numeric(10,2) default 0;

-- ── ATTENDANCE ────────────────────────────────────────────────
create table if not exists public.attendance (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid references public.staff(id) on delete cascade not null,
  clock_in_at    timestamptz not null default now(),
  clock_out_at   timestamptz,
  work_date      date generated always as (
                   (clock_in_at at time zone 'Asia/Manila')::date
                 ) stored,
  notes          text,
  corrected_by   uuid references public.staff(id),
  corrected_at   timestamptz,
  correction_note text,
  created_at     timestamptz default now()
);

create index if not exists idx_attend_staff_date on public.attendance(staff_id, work_date desc);
create index if not exists idx_attend_open       on public.attendance(staff_id) where clock_out_at is null;

-- Unique index: at most one open shift per staff at a time.
create unique index if not exists uniq_attendance_open_per_staff
  on public.attendance(staff_id) where clock_out_at is null;

alter table public.attendance enable row level security;

drop policy if exists attendance_self_read on public.attendance;
create policy attendance_self_read on public.attendance
  for select to authenticated using (
    staff_id = auth.uid()
    or (private.has_role('manager') and
        exists (select 1 from public.staff s where s.id = attendance.staff_id and s.branch_id = private.my_branch()))
    or private.has_role('admin')
  );

drop policy if exists attendance_self_insert on public.attendance;
create policy attendance_self_insert on public.attendance
  for insert to authenticated with check (
    staff_id = auth.uid()
  );

drop policy if exists attendance_self_update on public.attendance;
create policy attendance_self_update on public.attendance
  for update to authenticated using (
    (staff_id = auth.uid() and clock_out_at is null)   -- self can only close open shifts
    or (private.has_role('manager') and
        exists (select 1 from public.staff s where s.id = attendance.staff_id and s.branch_id = private.my_branch()))
    or private.has_role('admin')
  );

drop policy if exists attendance_admin_delete on public.attendance;
create policy attendance_admin_delete on public.attendance
  for delete to authenticated using (private.has_role('admin'));

-- Add to realtime publication
do $$ begin
  begin
    alter publication supabase_realtime add table public.attendance;
  exception when duplicate_object then null;
  end;
end $$;

-- ── MESSAGES ─────────────────────────────────────────────────
create table if not exists public.messages (
  id             uuid primary key default gen_random_uuid(),
  from_staff_id  uuid references public.staff(id) on delete set null not null,
  to_staff_id    uuid references public.staff(id) on delete cascade,   -- null = branch broadcast
  branch_id      uuid references public.branches(id) on delete set null,
  subject        text,
  body           text not null check (length(body) between 1 and 5000),
  read_at        timestamptz,
  created_at     timestamptz default now()
);

create index if not exists idx_msg_to_created     on public.messages(to_staff_id, created_at desc);
create index if not exists idx_msg_branch_created on public.messages(branch_id,   created_at desc) where to_staff_id is null;
create index if not exists idx_msg_from_created   on public.messages(from_staff_id, created_at desc);

alter table public.messages enable row level security;

drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages
  for select to authenticated using (
    to_staff_id = auth.uid()
    or from_staff_id = auth.uid()
    or (to_staff_id is null and branch_id = private.my_branch())
    or private.has_role('admin')
  );

drop policy if exists messages_insert on public.messages;
create policy messages_insert on public.messages
  for insert to authenticated with check (
    from_staff_id = auth.uid()
    and (
      -- direct message to anyone in your branch
      (to_staff_id is not null and exists (
         select 1 from public.staff s where s.id = to_staff_id
           and (s.branch_id = private.my_branch() or private.has_role('admin'))))
      -- broadcast: manager+ only, to their own branch
      or (to_staff_id is null and (
         (private.has_role('manager') and branch_id = private.my_branch())
         or private.has_role('admin')
      ))
    )
  );

drop policy if exists messages_update_read on public.messages;
create policy messages_update_read on public.messages
  for update to authenticated using (
    to_staff_id = auth.uid()
    or (to_staff_id is null and branch_id = private.my_branch())
    or private.has_role('admin')
  );

drop policy if exists messages_delete on public.messages;
create policy messages_delete on public.messages
  for delete to authenticated using (
    from_staff_id = auth.uid()
    or private.has_role('admin')
  );

do $$ begin
  begin
    alter publication supabase_realtime add table public.messages;
  exception when duplicate_object then null;
  end;
end $$;

-- Done.
