-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 25: payroll runs
--
-- A pay run is a SNAPSHOT, not a live query. Rate, days and hours are
-- copied onto payroll_items when the run is built, so what somebody was
-- actually paid in July cannot change because their rate changed in
-- August. Once a run is marked paid its lines are frozen by trigger.
--
-- TWO PERMISSIONS ON PURPOSE
--   payroll.edit  change what a person is paid          -- CEO only
--   payroll.run   build a period, approve, record paid  -- admin and up
-- A director should be able to run payroll without being able to give
-- anyone a raise.
--
-- STATE MACHINE (enforced in set_payroll_status, not in the UI)
--   draft -> approved -> paid -> reversed
-- You cannot pay an unapproved run, and you cannot edit a paid one.
-- A paid run is permanent: reverse it, never delete it.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

insert into public.permissions (key, category, label, label_tl, description, min_tier, display_order)
values ('payroll.run', 'Money', 'Run payroll', 'Magpatakbo ng payroll',
        'Build a pay period, approve it and record it as paid. Does not allow changing anyone''s rate.',
        'admin', 45)
on conflict (key) do update set
  label = excluded.label, label_tl = excluded.label_tl,
  description = excluded.description, min_tier = excluded.min_tier,
  display_order = excluded.display_order;

insert into public.access_role_permissions (role_id, permission_key, allowed)
select r.id, 'payroll.run',
       array_position(enum_range(null::public.staff_role), r.base_tier)
         >= array_position(enum_range(null::public.staff_role), 'admin')
  from public.access_roles r where r.is_system
on conflict (role_id, permission_key) do nothing;

do $$ begin
  create type public.payroll_status as enum ('draft','approved','paid','reversed');
exception when duplicate_object then null; end $$;

create table if not exists public.payroll_runs (
  id             uuid primary key default gen_random_uuid(),
  branch_id      uuid not null references public.branches(id) on delete cascade,
  period_start   date not null,
  period_end     date not null,
  status         public.payroll_status not null default 'draft',
  payment_method text,
  notes          text,
  created_by     uuid references public.staff(id) on delete set null,
  created_at     timestamptz default now(),
  approved_by    uuid references public.staff(id) on delete set null,
  approved_at    timestamptz,
  paid_by        uuid references public.staff(id) on delete set null,
  paid_at        timestamptz,
  constraint payroll_period_sane check (period_end >= period_start)
);
create index if not exists idx_payroll_runs_branch on public.payroll_runs(branch_id, period_start desc);

create table if not exists public.payroll_items (
  id           uuid primary key default gen_random_uuid(),
  run_id       uuid not null references public.payroll_runs(id) on delete cascade,
  staff_id     uuid not null references public.staff(id) on delete cascade,
  staff_name   text not null,
  pay_type     public.pay_type not null,
  rate         numeric(12,2) not null default 0,
  allowance    numeric(12,2) not null default 0,
  days_worked  numeric(8,2)  not null default 0,
  hours_worked numeric(8,2)  not null default 0,
  gross        numeric(12,2) not null default 0,
  deductions   numeric(12,2) not null default 0,
  net          numeric(12,2) not null default 0,
  note         text,
  unique (run_id, staff_id),
  constraint payroll_amounts_sane check (gross >= 0 and deductions >= 0)
);
create index if not exists idx_payroll_items_run on public.payroll_items(run_id);

comment on table public.payroll_items is
  'Frozen lines. rate, days and hours are copied in at build time so a later
   rate change cannot rewrite what someone was already paid.';


-- ── Build a draft from rates + attendance ────────────────────
--
-- WATCH THE JOINS. The first version of this produced an EMPTY run and said
-- nothing, because two filters combined to drop every row:
--   * an INNER join to staff_compensation dropped anyone without a rate
--   * `where employment_status = 'active'` dropped people who worked in the
--     period but were since disabled
-- In the live data those sets were disjoint, so the result was zero lines
-- and no explanation. Now: LEFT JOIN the rate so a missing rate shows as a
-- zero line WITH A NOTE, include anyone who clocked in during the period
-- whatever their current status, and raise if there is genuinely nobody.
create or replace function public.build_payroll_run(
  p_period_start date, p_period_end date, p_branch uuid default null)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_run   uuid;
  v_days  numeric := (p_period_end - p_period_start) + 1;
  v_count int;
begin
  if not private.can('payroll.run') then
    raise exception 'permission_denied: payroll.run' using errcode = '42501';
  end if;
  if p_period_end < p_period_start then
    raise exception 'bad_period' using errcode = '22023';
  end if;

  insert into public.payroll_runs (branch_id, period_start, period_end, created_by)
  values (v_branch, p_period_start, p_period_end, auth.uid())
  returning id into v_run;

  insert into public.payroll_items (
    run_id, staff_id, staff_name, pay_type, rate, allowance,
    days_worked, hours_worked, gross, deductions, net, note)
  select v_run, s.id, s.full_name,
         coalesce(c.pay_type, 'monthly'),
         coalesce(c.rate, 0), coalesce(c.allowance, 0),
         att.days, round(att.hours, 2),
         coalesce(g.gross, 0), 0, coalesce(g.gross, 0),
         case
           when c.staff_id is null
             then 'No pay rate set — add one in Pay rates, then recalculate.'
           when coalesce(s.employment_status,'active') <> 'active'
             then 'Not currently active (' || s.employment_status || ') but worked in this period.'
         end
    from public.staff s
    left join lateral (
      select c2.* from public.staff_compensation c2
       where c2.staff_id = s.id
         and c2.effective_from <= p_period_end
         and (c2.effective_to is null or c2.effective_to >= p_period_start)
       order by c2.effective_from desc limit 1) c on true
    cross join lateral (
      select coalesce(count(distinct a.clock_in_at::date), 0)::numeric as days,
             coalesce(sum(extract(epoch from (a.clock_out_at - a.clock_in_at))/3600.0), 0)::numeric as hours
        from public.attendance a
       where a.staff_id = s.id
         and a.clock_in_at::date between p_period_start and p_period_end
         and a.clock_out_at is not null) att
    cross join lateral (
      select round(case coalesce(c.pay_type, 'monthly')
               -- monthly pay is spread across the period, not paid in full
               when 'monthly' then (coalesce(c.rate,0) + coalesce(c.allowance,0)) / 30.4375 * v_days
               when 'daily'   then (coalesce(c.rate,0) + coalesce(c.allowance,0)) * att.days
               when 'hourly'  then  coalesce(c.rate,0) * att.hours + coalesce(c.allowance,0)
             end, 2) as gross) g
   where s.branch_id = v_branch
     and (coalesce(s.employment_status, 'active') = 'active' or att.days > 0);

  select count(*) into v_count from public.payroll_items where run_id = v_run;
  if v_count = 0 then
    delete from public.payroll_runs where id = v_run;
    raise exception 'nobody_to_pay: no active staff, and nobody clocked in between % and %',
      p_period_start, p_period_end using errcode = '22023';
  end if;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'payroll.build', 'payroll_run', v_run,
          jsonb_build_object('period_start', p_period_start,
                             'period_end', p_period_end, 'lines', v_count));
  return v_run;
end $$;

-- Recalculate a draft in place, so a rate added after building is picked up
-- without losing the run or its id.
create or replace function public.rebuild_payroll_run(p_run uuid)
returns int
language plpgsql
security definer
set search_path = ''
as $$
declare v_ps date; v_pe date; v_br uuid; v_status public.payroll_status; v_new uuid; v_n int;
begin
  if not private.can('payroll.run') then
    raise exception 'permission_denied: payroll.run' using errcode = '42501';
  end if;
  select period_start, period_end, branch_id, status
    into v_ps, v_pe, v_br, v_status from public.payroll_runs where id = p_run;
  if v_status is null then raise exception 'run_not_found' using errcode = '22023'; end if;
  if v_status <> 'draft' then
    raise exception 'only_a_draft_can_be_recalculated' using errcode = '22023';
  end if;
  delete from public.payroll_items where run_id = p_run;
  v_new := public.build_payroll_run(v_ps, v_pe, v_br);
  update public.payroll_items set run_id = p_run where run_id = v_new;
  delete from public.payroll_runs where id = v_new;
  select count(*) into v_n from public.payroll_items where run_id = p_run;
  return v_n;
end $$;


create or replace function public.set_payroll_status(
  p_run uuid, p_status text, p_method text default null)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_cur public.payroll_status;
begin
  if not private.can('payroll.run') then
    raise exception 'permission_denied: payroll.run' using errcode = '42501';
  end if;
  select status into v_cur from public.payroll_runs where id = p_run;
  if v_cur is null then raise exception 'run_not_found' using errcode = '22023'; end if;

  if p_status = 'approved' then
    if v_cur <> 'draft' then
      raise exception 'only_a_draft_can_be_approved' using errcode = '22023';
    end if;
    update public.payroll_runs set status='approved', approved_by=auth.uid(), approved_at=now()
     where id = p_run;
  elsif p_status = 'paid' then
    if v_cur <> 'approved' then
      raise exception 'approve_before_marking_paid' using errcode = '22023';
    end if;
    update public.payroll_runs
       set status='paid', paid_by=auth.uid(), paid_at=now(),
           payment_method=coalesce(p_method, payment_method)
     where id = p_run;
  elsif p_status = 'reversed' then
    if v_cur <> 'paid' then
      raise exception 'only_a_paid_run_can_be_reversed' using errcode = '22023';
    end if;
    update public.payroll_runs set status='reversed' where id = p_run;
  else
    raise exception 'bad_status: %', p_status using errcode = '22023';
  end if;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'payroll.' || p_status, 'payroll_run', p_run,
          jsonb_build_object('from', v_cur, 'to', p_status, 'method', p_method));
end $$;


-- A paid run is frozen. This also means a paid run can never be deleted,
-- even by cascade — which is deliberate. Reverse it instead.
create or replace function public.trg_payroll_items_locked()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_status public.payroll_status;
begin
  select status into v_status from public.payroll_runs
   where id = coalesce(new.run_id, old.run_id);
  if v_status in ('paid','reversed') then
    raise exception 'payroll_run_locked: this run is already %', v_status using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists trg_payroll_items_lock on public.payroll_items;
create trigger trg_payroll_items_lock before insert or update or delete on public.payroll_items
  for each row execute function public.trg_payroll_items_locked();


alter table public.payroll_runs  enable row level security;
alter table public.payroll_items enable row level security;

drop policy if exists pr_read on public.payroll_runs;
create policy pr_read on public.payroll_runs for select to authenticated
  using (private.can('payroll.view') and (branch_id = private.my_branch() or private.can('settings.manage')));
drop policy if exists pr_write on public.payroll_runs;
create policy pr_write on public.payroll_runs for update to authenticated
  using (private.can('payroll.run')) with check (private.can('payroll.run'));
drop policy if exists pr_del on public.payroll_runs;
create policy pr_del on public.payroll_runs for delete to authenticated
  using (private.can('payroll.run') and status = 'draft');

-- You may always see your OWN payslip line, even without payroll.view.
drop policy if exists pi_read on public.payroll_items;
create policy pi_read on public.payroll_items for select to authenticated
  using (staff_id = auth.uid() or private.can('payroll.view'));
drop policy if exists pi_write on public.payroll_items;
create policy pi_write on public.payroll_items for update to authenticated
  using (private.can('payroll.run')) with check (private.can('payroll.run'));

grant select, update, delete on public.payroll_runs  to authenticated;
grant select, update         on public.payroll_items to authenticated;
revoke all on public.payroll_runs  from anon;
revoke all on public.payroll_items from anon;

revoke execute on function public.build_payroll_run(date, date, uuid) from public, anon;
revoke execute on function public.rebuild_payroll_run(uuid)          from public, anon;
revoke execute on function public.set_payroll_status(uuid, text, text) from public, anon;
revoke execute on function public.trg_payroll_items_locked() from public, anon, authenticated;
grant execute on function public.build_payroll_run(date, date, uuid) to authenticated;
grant execute on function public.rebuild_payroll_run(uuid)           to authenticated;
grant execute on function public.set_payroll_status(uuid, text, text) to authenticated;
