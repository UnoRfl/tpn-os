-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 20: task board
--
-- A task can have MANY assignees and each of them carries their own
-- state, so two people cleaning the storeroom together each mark
-- their own progress instead of fighting over one status field. The
-- task's own status is derived from theirs by trigger:
--
--   nobody started        -> todo
--   at least one working  -> in_progress
--   every assignee done   -> done   (stamps completed_at)
--
-- A task with no assignees keeps whatever status was set by hand, so
-- an unassigned backlog item still works.
--
-- Access is governed by private.can() from migration 19:
--   tasks.view       read the board
--   tasks.create     add a task
--   tasks.assign     put people on a task
--   tasks.close_any  close a task you are not on
-- An assignee can always update THEIR OWN row without tasks.assign --
-- that is the whole point of the board.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

do $$ begin
  create type public.task_status as enum ('todo','in_progress','blocked','done','cancelled');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.task_priority as enum ('low','normal','high','urgent');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.task_assignee_state as enum ('assigned','working','done');
exception when duplicate_object then null; end $$;


-- ── the task ──────────────────────────────────────────────────
create table if not exists public.tasks (
  id            uuid primary key default gen_random_uuid(),
  branch_id     uuid not null references public.branches(id) on delete cascade,
  title         text not null,
  description   text,
  category      text,                                  -- free text: 'Cleaning', 'Prep', 'Admin'
  status        public.task_status   not null default 'todo',
  priority      public.task_priority not null default 'normal',
  due_at        timestamptz,
  checklist     jsonb not null default '[]'::jsonb,    -- [{"text":"...","done":false}]
  created_by    uuid references public.staff(id) on delete set null,
  created_at    timestamptz default now(),
  updated_at    timestamptz default now(),
  started_at    timestamptz,
  completed_at  timestamptz,
  completed_by  uuid references public.staff(id) on delete set null,
  constraint tasks_title_not_blank check (length(btrim(title)) > 0)
);

create index if not exists idx_tasks_branch_status on public.tasks(branch_id, status);
create index if not exists idx_tasks_due           on public.tasks(due_at) where due_at is not null;

drop trigger if exists trg_tasks_touch on public.tasks;
create trigger trg_tasks_touch before update on public.tasks
  for each row execute function public.tg_touch_updated();


-- ── who is on it ──────────────────────────────────────────────
create table if not exists public.task_assignees (
  task_id           uuid not null references public.tasks(id) on delete cascade,
  staff_id          uuid not null references public.staff(id) on delete cascade,
  state             public.task_assignee_state not null default 'assigned',
  note              text,
  assigned_by       uuid references public.staff(id) on delete set null,
  assigned_at       timestamptz default now(),
  state_changed_at  timestamptz default now(),
  primary key (task_id, staff_id)
);

create index if not exists idx_task_assignees_staff on public.task_assignees(staff_id, state);


-- ── activity trail ────────────────────────────────────────────
create table if not exists public.task_activity (
  id          uuid primary key default gen_random_uuid(),
  task_id     uuid not null references public.tasks(id) on delete cascade,
  actor_id    uuid references public.staff(id) on delete set null,
  action      text not null,
  detail      text,
  created_at  timestamptz default now()
);

create index if not exists idx_task_activity_task on public.task_activity(task_id, created_at desc);


-- ═════════════════════════════════════════════════════════════
-- Roll the task status up from its assignees
-- ═════════════════════════════════════════════════════════════
create or replace function private.roll_up_task(p_task uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  n_total   int;
  n_done    int;
  n_working int;
  cur       public.task_status;
begin
  select status into cur from public.tasks where id = p_task;

  -- a hand-set terminal state is respected, not fought over
  if cur = 'cancelled' then
    return;
  end if;

  select count(*),
         count(*) filter (where state = 'done'),
         count(*) filter (where state = 'working')
    into n_total, n_done, n_working
    from public.task_assignees where task_id = p_task;

  if n_total = 0 then
    return;                         -- unassigned: leave the manual status alone
  end if;

  if n_done = n_total then
    update public.tasks
       set status = 'done',
           completed_at = coalesce(completed_at, now())
     where id = p_task and status <> 'done';
  elsif n_working > 0 then
    update public.tasks
       set status = 'in_progress',
           started_at = coalesce(started_at, now()),
           completed_at = null
     where id = p_task and status not in ('in_progress','blocked');
  else
    update public.tasks
       set status = 'todo',
           completed_at = null
     where id = p_task and status not in ('todo','blocked');
  end if;
end $$;

-- Two concerns, two functions. state_changed_at must be stamped BEFORE the
-- row lands; the roll-up must run AFTER it, or it would read the old state.
-- Sharing one function across both timings made the roll-up run twice per
-- update and read a row that had not been written yet.
create or replace function public.trg_task_assignee_stamp()
returns trigger
language plpgsql
as $$
begin
  if new.state is distinct from old.state then
    new.state_changed_at := now();
  end if;
  return new;
end $$;

create or replace function public.trg_task_assignee_rollup()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.roll_up_task(old.task_id);
    return old;
  end if;
  perform private.roll_up_task(new.task_id);
  return new;
end $$;

drop trigger if exists trg_task_assignee_stamp on public.task_assignees;
create trigger trg_task_assignee_stamp before update on public.task_assignees
  for each row execute function public.trg_task_assignee_stamp();

drop trigger if exists trg_task_assignee_rollup on public.task_assignees;
create trigger trg_task_assignee_rollup
  after insert or update or delete on public.task_assignees
  for each row execute function public.trg_task_assignee_rollup();

drop trigger if exists trg_task_assignee_rollup_upd on public.task_assignees;


-- ═════════════════════════════════════════════════════════════
-- The one call the board needs: I am marking my own progress
-- ═════════════════════════════════════════════════════════════
create or replace function public.set_my_task_state(p_task uuid, p_state public.task_assignee_state, p_note text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if not exists (select 1 from public.task_assignees
                  where task_id = p_task and staff_id = auth.uid()) then
    raise exception 'not_assigned_to_this_task' using errcode = '42501';
  end if;

  update public.task_assignees
     set state = p_state,
         note  = coalesce(p_note, note)
   where task_id = p_task and staff_id = auth.uid();

  insert into public.task_activity (task_id, actor_id, action, detail)
  values (p_task, auth.uid(), 'state.' || p_state::text, p_note);
end $$;

comment on function public.set_my_task_state is
  'An assignee marking their own progress. Refuses if the caller is not on the
   task, so it needs no permission of its own.';


-- ═════════════════════════════════════════════════════════════
-- RLS
-- ═════════════════════════════════════════════════════════════
alter table public.tasks          enable row level security;
alter table public.task_assignees enable row level security;
alter table public.task_activity  enable row level security;

-- Read: your branch, if you may see the board at all. Plus: you can
-- always see a task you are on, even without tasks.view.
--
-- IMPORTANT: these two policies must NOT reference each other's table
-- directly. tasks_read referencing task_assignees while ta_read
-- referenced tasks produced
--   42P17 infinite recursion detected in policy for relation "tasks"
-- on the first insert. The two SECURITY DEFINER helpers below read past
-- RLS, so neither policy has to consult the other table.
create or replace function private.am_i_on_task(p_task uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.task_assignees
                  where task_id = p_task and staff_id = auth.uid())
$$;

create or replace function private.task_branch(p_task uuid)
returns uuid language sql stable security definer set search_path = '' as $$
  select branch_id from public.tasks where id = p_task
$$;

drop policy if exists tasks_read on public.tasks;
create policy tasks_read on public.tasks
  for select to authenticated using (
    (private.can('tasks.view')
      and (branch_id = private.my_branch() or private.can('settings.manage')))
    or private.am_i_on_task(id)
  );

drop policy if exists tasks_insert on public.tasks;
create policy tasks_insert on public.tasks
  for insert to authenticated with check (
    private.can('tasks.create')
    and (branch_id = private.my_branch() or private.can('settings.manage'))
  );

-- Update: whoever may assign, or whoever may close anything. An
-- assignee changing only their own state goes through
-- set_my_task_state() instead, which is SECURITY DEFINER.
drop policy if exists tasks_update on public.tasks;
create policy tasks_update on public.tasks
  for update to authenticated using (
    (private.can('tasks.assign') or private.can('tasks.close_any'))
    and (branch_id = private.my_branch() or private.can('settings.manage'))
  ) with check (
    branch_id = private.my_branch() or private.can('settings.manage')
  );

drop policy if exists tasks_delete on public.tasks;
create policy tasks_delete on public.tasks
  for delete to authenticated using (
    private.can('tasks.close_any')
    and (branch_id = private.my_branch() or private.can('settings.manage'))
  );

drop policy if exists ta_read on public.task_assignees;
create policy ta_read on public.task_assignees
  for select to authenticated using (
    staff_id = auth.uid()
    or (private.can('tasks.view')
        and (private.task_branch(task_id) = private.my_branch()
             or private.can('settings.manage')))
  );

drop policy if exists ta_write_ins on public.task_assignees;
create policy ta_write_ins on public.task_assignees
  for insert to authenticated with check (private.can('tasks.assign'));

drop policy if exists ta_write_upd on public.task_assignees;
create policy ta_write_upd on public.task_assignees
  for update to authenticated
  using (private.can('tasks.assign')) with check (private.can('tasks.assign'));

drop policy if exists ta_write_del on public.task_assignees;
create policy ta_write_del on public.task_assignees
  for delete to authenticated using (private.can('tasks.assign'));

drop policy if exists tact_read on public.task_activity;
create policy tact_read on public.task_activity
  for select to authenticated using (
    private.am_i_on_task(task_id)
    or (private.can('tasks.view')
        and (private.task_branch(task_id) = private.my_branch()
             or private.can('settings.manage')))
  );

drop policy if exists tact_write on public.task_activity;
create policy tact_write on public.task_activity
  for insert to authenticated with check (actor_id = auth.uid());


-- ═════════════════════════════════════════════════════════════
-- Grants
-- ═════════════════════════════════════════════════════════════
grant select, insert, update, delete on public.tasks          to authenticated;
grant select, insert, update, delete on public.task_assignees to authenticated;
grant select, insert                 on public.task_activity  to authenticated;
revoke all on public.tasks          from anon;
revoke all on public.task_assignees from anon;
revoke all on public.task_activity  from anon;
grant execute on function public.set_my_task_state(uuid, public.task_assignee_state, text) to authenticated;
revoke all on function public.set_my_task_state(uuid, public.task_assignee_state, text) from anon;
