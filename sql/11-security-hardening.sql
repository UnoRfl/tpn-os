-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 11: Security hardening + Void + Audit archive
--
-- Fixes surfaced by the security audit:
--   1. orders.total was client-computed → now server-recomputed
--      from order_items via trigger. Prevents "pay ₱1 for ₱1500 order".
--   2. orders_anon_read exposed customer PII to anyone with the anon
--      key. Column-level grants strip customer_name / phone / email /
--      delivery_address / notes from anonymous SELECTs.
--   3. signal_call_staff + signal_bill_request accepted unlimited
--      requests. 90-second per-table cooldown added.
--   4. Manager-only void: void_order_item(id, reason) marks an item
--      void, recomputes totals, and writes an audit entry.
--   5. audit_log had no TTL. New audit_log_archive table + monthly
--      auto-archive keeps hot table lean while preserving history.
--
-- Safe to run repeatedly.
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- 1. SERVER-SIDE ORDER TOTAL RECOMPUTE
-- ═══════════════════════════════════════════════════════════════

-- New columns on order_items to support voiding without deletion.
alter table public.order_items
  add column if not exists voided_at    timestamptz,
  add column if not exists voided_by    uuid references public.staff(id),
  add column if not exists void_reason  text;

create index if not exists idx_order_items_voided
  on public.order_items(order_id) where voided_at is null;

-- The recompute fn: sums non-voided items into orders.subtotal and total.
-- Discount + service_charge (added in migration 09) participate in the total.
create or replace function private.recompute_order_totals(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_subtotal numeric(10,2);
  disc         numeric(10,2);
  svc          numeric(10,2);
begin
  select coalesce(sum(total_price), 0) into new_subtotal
    from public.order_items
   where order_id = p_order_id and voided_at is null;

  select coalesce(discount_amount, 0), coalesce(service_charge, 0)
    into disc, svc
    from public.orders where id = p_order_id;

  update public.orders
     set subtotal = new_subtotal,
         total    = greatest(0, new_subtotal - coalesce(disc,0) + coalesce(svc,0))
   where id = p_order_id;
end $$;
revoke execute on function private.recompute_order_totals(uuid) from public, anon, authenticated;

-- Trigger fn: recompute on any order_items change
create or replace function public.trg_order_items_recompute()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.recompute_order_totals(old.order_id);
    return old;
  else
    perform private.recompute_order_totals(new.order_id);
    return new;
  end if;
end $$;
drop trigger if exists trg_order_items_recompute_ins on public.order_items;
drop trigger if exists trg_order_items_recompute_upd on public.order_items;
drop trigger if exists trg_order_items_recompute_del on public.order_items;
create trigger trg_order_items_recompute_ins after insert on public.order_items
  for each row execute function public.trg_order_items_recompute();
create trigger trg_order_items_recompute_upd after update on public.order_items
  for each row execute function public.trg_order_items_recompute();
create trigger trg_order_items_recompute_del after delete on public.order_items
  for each row execute function public.trg_order_items_recompute();

-- Also recompute when discount / service_charge changes on the parent order.
create or replace function public.trg_order_adjustments_recompute()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(new.discount_amount,0) is distinct from coalesce(old.discount_amount,0)
     or coalesce(new.service_charge,0) is distinct from coalesce(old.service_charge,0) then
    perform private.recompute_order_totals(new.id);
  end if;
  return new;
end $$;
drop trigger if exists trg_orders_adjustments_recompute on public.orders;
create trigger trg_orders_adjustments_recompute after update of discount_amount, service_charge on public.orders
  for each row execute function public.trg_order_adjustments_recompute();

-- Backfill: recompute totals for every order once, in case any drifted.
do $$
declare r record;
begin
  for r in select id from public.orders loop
    perform private.recompute_order_totals(r.id);
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 2. TIGHTEN orders + order_items ANON READ
--
-- Anon still needs to read their own order status (for the QR "track
-- my order" flow). We keep the row-level policy permissive but strip
-- sensitive columns via GRANT — so PostgREST + realtime only expose
-- non-PII fields to anonymous clients.
--
-- Authenticated staff retain full access via their existing policies.
-- ═══════════════════════════════════════════════════════════════

-- Revoke blanket SELECT from anon on orders + order_items, then re-grant
-- only the columns customers legitimately need.
revoke select on public.orders     from anon;
revoke select on public.order_items from anon;

grant select
  ( id, order_number, branch_id, table_id, order_type,
    subtotal, total, discount_amount, service_charge,
    status,
    placed_at, confirmed_at, ready_at, served_at, completed_at, cancelled_at )
  on public.orders to anon;

grant select
  ( id, order_id, menu_item_id, name_snapshot, price_snapshot,
    quantity, pax_size, unit_price, total_price,
    station, status, created_at,
    voided_at )
  on public.order_items to anon;

-- Fields deliberately withheld from anon:
--   orders:      customer_name, customer_phone, customer_email,
--                delivery_address, notes, cancel_reason, payment_method
--   order_items: notes, void_reason, voided_by

-- ═══════════════════════════════════════════════════════════════
-- 3. SIGNAL RATE LIMITING (per-table cooldown)
-- ═══════════════════════════════════════════════════════════════

-- Reuse call_staff_at / bill_requested_at as the cooldown anchor: a
-- second call within 90 seconds is silently swallowed (returns a
-- boolean so the frontend can toast a friendly message).
-- sql/04 declared these two as `returns void`; here they return boolean so
-- the caller can detect the 90-second cooldown. Postgres will not change a
-- return type in place, so drop first. Without these two lines this file
--   ERROR: cannot change return type of existing function
-- on any project that already ran sql/04.
drop function if exists public.signal_call_staff(uuid);
create or replace function public.signal_call_staff(p_table_id uuid)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  last_at timestamptz;
begin
  select call_staff_at into last_at
    from public.restaurant_tables
   where id = p_table_id and is_active = true;

  if last_at is not null and now() - last_at < interval '90 seconds' then
    return false;
  end if;

  update public.restaurant_tables
     set call_staff_at = now()
   where id = p_table_id and is_active = true;
  return true;
end $$;

drop function if exists public.signal_bill_request(uuid, text, numeric);
drop function if exists public.signal_bill_request(uuid);
create or replace function public.signal_bill_request(
  p_table_id uuid,
  p_payment_method text,
  p_total numeric
) returns boolean
language plpgsql security definer set search_path = ''
as $$
declare
  last_at timestamptz;
begin
  select bill_requested_at into last_at
    from public.restaurant_tables
   where id = p_table_id and is_active = true;

  if last_at is not null and now() - last_at < interval '90 seconds' then
    return false;
  end if;

  -- Basic sanity check: total must not be absurdly large
  if p_total is not null and (p_total < 0 or p_total > 1000000) then
    raise exception 'invalid_bill_total';
  end if;

  update public.restaurant_tables
     set bill_requested_at   = now(),
         bill_payment_method = p_payment_method,
         bill_total          = p_total
   where id = p_table_id and is_active = true;
  return true;
end $$;

-- Grants unchanged from migration 04 (anon + authenticated can call).

-- ═══════════════════════════════════════════════════════════════
-- 4. MANAGER-ONLY VOID ORDER ITEM
--
-- Voiding, not deleting: the row stays for audit / analytics but
-- the total is recomputed to exclude it.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.void_order_item(
  p_item_id uuid,
  p_reason  text
) returns public.order_items
language plpgsql security definer set search_path = ''
as $$
declare
  item         public.order_items%rowtype;
  order_row    public.orders%rowtype;
begin
  -- Managerial only. supervisor is intentionally excluded.
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'void_reason_required' using errcode = '22023';
  end if;

  select * into item from public.order_items where id = p_item_id;
  if not found then
    raise exception 'item_not_found' using errcode = 'P0002';
  end if;
  if item.voided_at is not null then
    raise exception 'already_voided' using errcode = '23505';
  end if;

  -- Branch check: managers can only void within their own branch (admins bypass).
  select * into order_row from public.orders where id = item.order_id;
  if not private.has_role('admin') and order_row.branch_id <> private.my_branch() then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  -- Terminal orders can't be edited — force a new order or refund flow instead.
  if order_row.status in ('completed','cancelled') then
    raise exception 'order_terminal' using errcode = '23514';
  end if;

  update public.order_items
     set voided_at   = now(),
         voided_by   = auth.uid(),
         void_reason = p_reason
   where id = p_item_id
  returning * into item;

  -- Recompute totals happens via trigger. Write to audit log.
  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, before_state, after_state, metadata)
  values
    (auth.uid(), private.my_role(),
     'order_item.void', 'order_item', item.id,
     jsonb_build_object('total_price', item.total_price, 'name', item.name_snapshot),
     jsonb_build_object('voided_at', item.voided_at, 'void_reason', p_reason),
     jsonb_build_object('order_id', item.order_id, 'branch_id', order_row.branch_id));

  return item;
end $$;

revoke execute on function public.void_order_item(uuid, text) from public, anon;
grant   execute on function public.void_order_item(uuid, text) to authenticated;

-- Inverse (undo void). Same guard rails.
create or replace function public.unvoid_order_item(p_item_id uuid)
returns public.order_items
language plpgsql security definer set search_path = ''
as $$
declare
  item      public.order_items%rowtype;
  order_row public.orders%rowtype;
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  select * into item from public.order_items where id = p_item_id;
  if not found then raise exception 'item_not_found'; end if;
  if item.voided_at is null then raise exception 'not_voided'; end if;

  select * into order_row from public.orders where id = item.order_id;
  if not private.has_role('admin') and order_row.branch_id <> private.my_branch() then
    raise exception 'wrong_branch';
  end if;

  update public.order_items
     set voided_at = null, voided_by = null, void_reason = null
   where id = p_item_id
  returning * into item;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values
    (auth.uid(), private.my_role(),
     'order_item.unvoid', 'order_item', item.id,
     jsonb_build_object('order_id', item.order_id));

  return item;
end $$;

revoke execute on function public.unvoid_order_item(uuid) from public, anon;
grant   execute on function public.unvoid_order_item(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 5. AUDIT LOG — daily rollup + monthly archive
--
-- We do NOT partition (would require downtime). Instead:
--   - audit_log stays hot with ~30 days of raw rows
--   - audit_log_archive holds everything older, same schema
--   - audit_daily_summary is a rollup (per-day, per-actor, per-action counts)
--   - audit_log_archive_old(days_to_keep) moves rows > N days into
--     the archive and refreshes the summary
--
-- Suggested Supabase cron (Dashboard → Database → Cron):
--   select cron.schedule('audit-archive-daily', '0 3 * * *',
--                        $$select public.audit_log_archive_old(31)$$);
-- ═══════════════════════════════════════════════════════════════

-- Archive table (identical shape to audit_log)
create table if not exists public.audit_log_archive (
  id           uuid primary key,
  actor_id     uuid,
  actor_role   staff_role,
  action       text not null,
  entity_type  text,
  entity_id    uuid,
  before_state jsonb,
  after_state  jsonb,
  metadata     jsonb,
  ip_address   inet,
  user_agent   text,
  created_at   timestamptz,
  archived_at  timestamptz default now()
);
create index if not exists idx_audit_arch_created on public.audit_log_archive(created_at desc);
create index if not exists idx_audit_arch_actor   on public.audit_log_archive(actor_id);
create index if not exists idx_audit_arch_action  on public.audit_log_archive(action);
-- date_trunc('month', timestamptz) is STABLE (it depends on TimeZone), so
-- it cannot go in an index expression. Pinning the zone makes it
-- IMMUTABLE. The original line raised
--   ERROR: functions in index expression must be marked IMMUTABLE
-- which is one of two reasons this file would not replay on a fresh
-- project.
create index if not exists idx_audit_arch_month   on public.audit_log_archive((date_trunc('month', created_at at time zone 'UTC')));

alter table public.audit_log_archive enable row level security;

drop policy if exists audit_arch_read on public.audit_log_archive;
create policy audit_arch_read on public.audit_log_archive
  for select to authenticated using (private.has_role('manager'));

-- Daily rollup table (populated by the archive fn, but usable on hot rows too).
create table if not exists public.audit_daily_summary (
  day         date not null,
  branch_id   uuid references public.branches(id) on delete cascade,
  action      text not null,
  actor_role  staff_role,
  count       int  not null,
  updated_at  timestamptz default now(),
  primary key (day, branch_id, action, actor_role)
);
create index if not exists idx_audit_daily_day on public.audit_daily_summary(day desc);

alter table public.audit_daily_summary enable row level security;

drop policy if exists audit_summary_read on public.audit_daily_summary;
create policy audit_summary_read on public.audit_daily_summary
  for select to authenticated using (
    branch_id = private.my_branch() or private.has_role('admin')
  );

-- The main archive fn: idempotent, safe to run daily or on-demand.
create or replace function public.audit_log_archive_old(p_days_to_keep int default 31)
returns table (rolled_up int, archived int, deleted int)
language plpgsql security definer set search_path = ''
as $$
declare
  cutoff timestamptz;
  n_roll int;
  n_arch int;
  n_del  int;
begin
  cutoff := now() - (p_days_to_keep::text || ' days')::interval;

  -- 1. Populate daily rollup for anything older than the cutoff (or fill gaps).
  --    We infer branch_id from the actor's current branch. Where actor is null,
  --    we bucket under 'null' branch.
  insert into public.audit_daily_summary (day, branch_id, action, actor_role, count, updated_at)
  select
    (a.created_at at time zone 'Asia/Manila')::date as day,
    s.branch_id,
    a.action,
    a.actor_role,
    count(*) as cnt,
    now()
  from public.audit_log a
  left join public.staff s on s.id = a.actor_id
  where a.created_at < cutoff
  group by 1, 2, 3, 4
  on conflict (day, branch_id, action, actor_role)
    do update set count = excluded.count, updated_at = excluded.updated_at;
  get diagnostics n_roll = row_count;

  -- 2. Copy the raw rows to the archive.
  insert into public.audit_log_archive
    (id, actor_id, actor_role, action, entity_type, entity_id,
     before_state, after_state, metadata, ip_address, user_agent, created_at)
  select
     id, actor_id, actor_role, action, entity_type, entity_id,
     before_state, after_state, metadata, ip_address, user_agent, created_at
  from public.audit_log
  where created_at < cutoff
  on conflict (id) do nothing;
  get diagnostics n_arch = row_count;

  -- 3. Delete the archived rows from the hot table.
  delete from public.audit_log where created_at < cutoff;
  get diagnostics n_del = row_count;

  rolled_up := n_roll;
  archived  := n_arch;
  deleted   := n_del;
  return next;
end $$;

revoke execute on function public.audit_log_archive_old(int) from public, anon;
grant   execute on function public.audit_log_archive_old(int) to authenticated;

-- Helper view: unified read across hot + archive, useful for the History tab.
create or replace view public.v_audit_log_all as
  select id, actor_id, actor_role, action, entity_type, entity_id,
         before_state, after_state, metadata, created_at, false as is_archived
    from public.audit_log
  union all
  select id, actor_id, actor_role, action, entity_type, entity_id,
         before_state, after_state, metadata, created_at, true as is_archived
    from public.audit_log_archive;

-- The view inherits RLS from its underlying tables.
grant select on public.v_audit_log_all to authenticated;

-- Convenience fn: "give me the daily counts for a given month".
-- Uses the summary when the month is fully archived; otherwise computes
-- from the hot table on the fly.
create or replace function public.audit_daily_counts(
  p_month date,           -- any date within the target month
  p_branch_id uuid default null
)
returns table (day date, action text, actor_role staff_role, count bigint)
language plpgsql security definer set search_path = ''
as $$
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  return query
    select day, action, actor_role, count::bigint
      from public.audit_daily_summary
     where day >= date_trunc('month', p_month)::date
       and day <  (date_trunc('month', p_month) + interval '1 month')::date
       and (p_branch_id is null or branch_id = p_branch_id)
    union all
    select
      (created_at at time zone 'Asia/Manila')::date as day,
      a.action, a.actor_role, count(*)::bigint
    from public.audit_log a
    left join public.staff s on s.id = a.actor_id
    where a.created_at >= date_trunc('month', p_month)
      and a.created_at <  date_trunc('month', p_month) + interval '1 month'
      and (p_branch_id is null or s.branch_id = p_branch_id)
    group by 1, 2, 3
    order by day desc, action;
end $$;

grant execute on function public.audit_daily_counts(date, uuid) to authenticated;

-- Done.
