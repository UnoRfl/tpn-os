-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 08: Persistent Schedules
-- One row per (staff, week). Days stored as a jsonb map so we can
-- edit any day inline without a full row rewrite. Editing UI:
--   admin portal → Schedules tab (manager+ writes, staff reads own)
--   staff portal → My Schedule (reads own)
-- ═══════════════════════════════════════════════════════════════

-- Table
create table if not exists public.schedules (
  id          uuid primary key default gen_random_uuid(),
  staff_id    uuid not null references public.staff(id) on delete cascade,
  week_start  date not null,                                  -- Monday of that week
  shifts      jsonb not null default '{}'::jsonb,             -- {"mon":"9:45a-6p","tue":"OFF",...}
  notes       text,
  created_at  timestamptz default now(),
  updated_at  timestamptz default now(),
  updated_by  uuid references public.staff(id),
  unique (staff_id, week_start)
);
create index if not exists idx_schedules_staff on public.schedules(staff_id);
create index if not exists idx_schedules_week  on public.schedules(week_start);

-- Touch updated_at on write
drop trigger if exists trg_schedules_touch on public.schedules;
create trigger trg_schedules_touch before update on public.schedules
  for each row execute function public.tg_touch_updated();

-- RLS
alter table public.schedules enable row level security;

-- Staff can read their own schedule
drop policy if exists sched_self_read on public.schedules;
create policy sched_self_read on public.schedules
  for select to authenticated using (staff_id = auth.uid());

-- Manager+ can read all schedules for staff in their branch
drop policy if exists sched_manager_read on public.schedules;
create policy sched_manager_read on public.schedules
  for select to authenticated using (
    private.has_role('manager') and exists (
      select 1 from public.staff s
      where s.id = staff_id
        and (s.branch_id = private.my_branch() or private.has_role('admin'))
    )
  );

-- Manager+ can write schedules for staff in their branch (admin+ can write for any branch)
drop policy if exists sched_manager_write on public.schedules;
create policy sched_manager_write on public.schedules
  for insert to authenticated with check (
    private.has_role('manager') and exists (
      select 1 from public.staff s
      where s.id = staff_id
        and (s.branch_id = private.my_branch() or private.has_role('admin'))
    )
  );

drop policy if exists sched_manager_update on public.schedules;
create policy sched_manager_update on public.schedules
  for update to authenticated using (
    private.has_role('manager') and exists (
      select 1 from public.staff s
      where s.id = staff_id
        and (s.branch_id = private.my_branch() or private.has_role('admin'))
    )
  ) with check (
    private.has_role('manager') and exists (
      select 1 from public.staff s
      where s.id = staff_id
        and (s.branch_id = private.my_branch() or private.has_role('admin'))
    )
  );

drop policy if exists sched_manager_delete on public.schedules;
create policy sched_manager_delete on public.schedules
  for delete to authenticated using (
    private.has_role('manager') and exists (
      select 1 from public.staff s
      where s.id = staff_id
        and (s.branch_id = private.my_branch() or private.has_role('admin'))
    )
  );
