-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 28: add-ons, prep targets, low-stock alerts,
--                        daily close, stock variance
--
-- ADD-ONS (the upsell that never fired)
-- index.html shipped a working upsell card in the first release and it NEVER
-- matched once. `upsellRules` keyed on short codes ('tap', 'ur') while
-- menu_items.id is a uuid, so cartIds.includes('tap') was always false. The
-- giveaway: `const sugItem = findItem(rule.suggest)` — assigned, never used.
-- Any claim that TPN upsells was untrue. Fixed by making add-ons DATA, so
-- the kitchen changes the offer in Menu Manager with no deploy.
--
-- PREP TARGETS
-- The kitchen queue aged every ticket on one generic timer, so a lechon
-- kawali and a bowl of rice turned red together. prep_minutes lets a ticket
-- be judged against the slowest dish on it. Null falls back to the old
-- behaviour, so an unconfigured menu is unaffected.
--
-- LOW STOCK
-- Stock levels were visible only to whoever opened Inventory. Now a crossing
-- reaches the notification feed. On the CROSSING only — otherwise every
-- later movement on an already-low item re-alerts and the feed becomes noise.
--
-- DAILY CLOSE
-- One screen at end of shift so a shortfall is caught the same night.
-- READ THIS BEFORE TRUSTING THE NUMBERS: orders.payment_method is what the
-- CUSTOMER SELECTED, not a confirmed receipt — payment confirmation is not
-- built (another developer owns it). The report labels the breakdown
-- "declared" and reconciles the drawer against declared CASH only. When
-- confirmed receipts land, expected_cash should move to those, and the
-- warning in the UI should move with it.
--
-- STOCK VARIANCE
-- Deliberately NOT a yield report. Theoretical usage needs recipes (how much
-- pork a kare-kare consumes) and there is no recipe table. What IS knowable:
-- every movement, and how much loss was DISCOVERED by a stock count rather
-- than recorded as it happened. found_short is the number worth chasing.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── Add-ons and prep targets ─────────────────────────────────
alter table public.menu_items add column if not exists is_addon     boolean not null default false;
alter table public.menu_items add column if not exists addon_group  text;
alter table public.menu_items add column if not exists prep_minutes int;

comment on column public.menu_items.is_addon is
  'Offer this at checkout as an add-on (rice, drinks, extra sauce). Data, not
   a hardcoded list, so Menu Manager can change the upsell without a deploy.';
comment on column public.menu_items.addon_group is
  'Optional grouping, e.g. "Rice", "Drinks", "Sauces". Orders and labels the
   suggestions only.';
comment on column public.menu_items.prep_minutes is
  'Target minutes from order to ready, per dish. A ticket is aged against its
   SLOWEST item. Null falls back to the generic thresholds.';

create index if not exists idx_menu_items_addon
  on public.menu_items(addon_group) where is_addon;

create or replace function public.addon_suggestions(
  p_exclude uuid[] default '{}', p_limit int default 4)
returns table (id uuid, name text, name_tagalog text, price numeric, addon_group text)
language sql stable security definer set search_path = '' as $$
  select m.id, m.name, m.name_tagalog, m.price, m.addon_group
    from public.menu_items m
   where m.is_addon and coalesce(m.is_available, true)
     and not (m.id = any(coalesce(p_exclude, '{}'::uuid[])))
   order by m.addon_group nulls last, m.price
   limit greatest(1, least(coalesce(p_limit, 4), 12))
$$;
revoke execute on function public.addon_suggestions(uuid[], int) from public;
grant  execute on function public.addon_suggestions(uuid[], int) to anon, authenticated;

create or replace function public.order_prep_target(p_order uuid)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce(max(m.prep_minutes), 0)
    from public.order_items i
    left join public.menu_items m on m.id = i.menu_item_id
   where i.order_id = p_order and i.voided_at is null
$$;
revoke execute on function public.order_prep_target(uuid) from public, anon;
grant  execute on function public.order_prep_target(uuid) to authenticated;


-- ── Low stock → notification feed ────────────────────────────
-- to_char(8.000,'FM999999.99') returns "8." — FM strips padding but keeps
-- the decimal point, which made alerts read "8. kg left (reorder at 10.)".
create or replace function private.fmt_qty(p numeric)
returns text language sql immutable set search_path = '' as $$
  select rtrim(rtrim(to_char(coalesce(p, 0), 'FM999999999.999'), '0'), '.')
$$;
comment on function private.fmt_qty is
  '3.500 -> "3.5", 8.000 -> "8". For alert text, where a trailing decimal
   point looks like a typo.';

create or replace function public.trg_low_stock_notify()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_was numeric;
begin
  if new.reorder_level is null or new.reorder_level <= 0 then return new; end if;
  v_was := coalesce(old.current_stock, 0);
  -- CROSSING only: see the header note about feed noise.
  if v_was > new.reorder_level and new.current_stock <= new.reorder_level then
    perform public.notify_push(
      null, new.branch_id, 'low_stock',
      'Low stock · ' || new.name,
      private.fmt_qty(new.current_stock) || ' ' || btrim(coalesce(new.unit,'')) ||
        ' left · reorder at ' || private.fmt_qty(new.reorder_level),
      'inventory', 'ingredient', new.id, 'high');
  end if;
  return new;
end $$;

drop trigger if exists trg_ingredients_low_stock on public.ingredients;
create trigger trg_ingredients_low_stock
  after update of current_stock on public.ingredients
  for each row execute function public.trg_low_stock_notify();

revoke execute on function public.trg_low_stock_notify() from public, anon, authenticated;
revoke execute on function private.fmt_qty(numeric)     from public, anon, authenticated;


-- ── Daily close ──────────────────────────────────────────────
create table if not exists public.daily_closes (
  id            uuid primary key default gen_random_uuid(),
  branch_id     uuid not null references public.branches(id) on delete cascade,
  close_date    date not null,
  expected_cash numeric(12,2) not null default 0,
  counted_cash  numeric(12,2) not null default 0,
  variance      numeric(12,2) not null default 0,
  gross_sales   numeric(12,2) not null default 0,
  discounts     numeric(12,2) not null default 0,
  net_sales     numeric(12,2) not null default 0,
  order_count   int           not null default 0,
  void_count    int           not null default 0,
  voided_value  numeric(12,2) not null default 0,
  notes         text,
  closed_by     uuid references public.staff(id) on delete set null,
  closed_at     timestamptz default now(),
  unique (branch_id, close_date)
);
create index if not exists idx_daily_closes on public.daily_closes(branch_id, close_date desc);

comment on table public.daily_closes is
  'One row per branch per day, written when someone closes the till. Figures
   are SNAPSHOTTED at close so a later void cannot silently rewrite what was
   reconciled on the night.';

create or replace function public.daily_close_report(
  p_date date default current_date, p_branch uuid default null)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_lo timestamptz := p_date::timestamptz;
  v_hi timestamptz := (p_date + 1)::timestamptz;
  v jsonb;
begin
  if not private.can('finance.view') and not private.can('orders.view') then
    raise exception 'permission_denied: orders.view' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'date', p_date,
    'gross_sales', coalesce(sum(o.subtotal), 0),
    'discounts',   coalesce(sum(o.discount_amount), 0),
    'net_sales',   coalesce(sum(o.total), 0),
    'order_count', count(*),
    'avg_ticket',  case when count(*) > 0 then round(coalesce(sum(o.total),0)/count(*), 2) else 0 end,
    -- DECLARED, not collected. See the header.
    'by_method', coalesce((
      select jsonb_agg(jsonb_build_object('method', coalesce(x.payment_method::text,'unspecified'),
               'orders', x.n, 'total', x.amt) order by x.amt desc)
        from (select o2.payment_method, count(*) n, sum(o2.total) amt from public.orders o2
               where o2.branch_id = v_branch and o2.status <> 'cancelled'
                 and o2.placed_at >= v_lo and o2.placed_at < v_hi
               group by o2.payment_method) x), '[]'::jsonb),
    'by_type', coalesce((
      select jsonb_agg(jsonb_build_object('type', y.order_type::text, 'orders', y.n, 'total', y.amt)
               order by y.amt desc)
        from (select o3.order_type, count(*) n, sum(o3.total) amt from public.orders o3
               where o3.branch_id = v_branch and o3.status <> 'cancelled'
                 and o3.placed_at >= v_lo and o3.placed_at < v_hi
               group by o3.order_type) y), '[]'::jsonb),
    'declared_cash', coalesce((select sum(o4.total) from public.orders o4
       where o4.branch_id = v_branch and o4.status <> 'cancelled'
         and o4.payment_method = 'cash'
         and o4.placed_at >= v_lo and o4.placed_at < v_hi), 0),
    'cancelled', coalesce((select jsonb_build_object('orders', count(*), 'value', coalesce(sum(o5.total),0))
        from public.orders o5 where o5.branch_id = v_branch and o5.status = 'cancelled'
         and o5.placed_at >= v_lo and o5.placed_at < v_hi), '{}'::jsonb),
    'voided_items', coalesce((select jsonb_build_object('lines', count(*), 'value', coalesce(sum(i.total_price),0))
        from public.order_items i join public.orders o6 on o6.id = i.order_id
       where o6.branch_id = v_branch and i.voided_at is not null
         and i.voided_at >= v_lo and i.voided_at < v_hi), '{}'::jsonb),
    'top_items', coalesce((
      select jsonb_agg(jsonb_build_object('name', z.name_snapshot, 'qty', z.q, 'total', z.amt)
               order by z.q desc)
        from (select i2.name_snapshot, sum(i2.quantity) q, sum(i2.total_price) amt
                from public.order_items i2 join public.orders o7 on o7.id = i2.order_id
               where o7.branch_id = v_branch and o7.status <> 'cancelled' and i2.voided_at is null
                 and o7.placed_at >= v_lo and o7.placed_at < v_hi
               group by i2.name_snapshot order by sum(i2.quantity) desc limit 5) z), '[]'::jsonb),
    'already_closed', exists (select 1 from public.daily_closes d
       where d.branch_id = v_branch and d.close_date = p_date)
  ) into v
  from public.orders o
  where o.branch_id = v_branch and o.status <> 'cancelled'
    and o.placed_at >= v_lo and o.placed_at < v_hi;
  return v;
end $$;

create or replace function public.record_daily_close(
  p_date date, p_counted_cash numeric, p_notes text default null, p_branch uuid default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_branch uuid := coalesce(p_branch, private.my_branch());
        v_rep jsonb; v_expected numeric; v_id uuid;
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;
  v_rep := public.daily_close_report(p_date, v_branch);
  v_expected := coalesce((v_rep->>'declared_cash')::numeric, 0);

  insert into public.daily_closes (branch_id, close_date, expected_cash, counted_cash,
    variance, gross_sales, discounts, net_sales, order_count, void_count, voided_value, notes, closed_by)
  values (v_branch, p_date, v_expected, coalesce(p_counted_cash,0),
    coalesce(p_counted_cash,0) - v_expected,
    coalesce((v_rep->>'gross_sales')::numeric,0), coalesce((v_rep->>'discounts')::numeric,0),
    coalesce((v_rep->>'net_sales')::numeric,0),  coalesce((v_rep->>'order_count')::int,0),
    coalesce((v_rep->'voided_items'->>'lines')::int,0),
    coalesce((v_rep->'voided_items'->>'value')::numeric,0),
    nullif(btrim(coalesce(p_notes,'')),''), auth.uid())
  on conflict (branch_id, close_date) do update set
    expected_cash=excluded.expected_cash, counted_cash=excluded.counted_cash,
    variance=excluded.variance, gross_sales=excluded.gross_sales,
    discounts=excluded.discounts, net_sales=excluded.net_sales,
    order_count=excluded.order_count, void_count=excluded.void_count,
    voided_value=excluded.voided_value, notes=excluded.notes,
    closed_by=auth.uid(), closed_at=now()
  returning id into v_id;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'till.close', 'daily_close', v_id,
          jsonb_build_object('date', p_date, 'expected', v_expected,
            'counted', p_counted_cash, 'variance', coalesce(p_counted_cash,0) - v_expected));

  return jsonb_build_object('id', v_id, 'expected_cash', v_expected,
    'counted_cash', coalesce(p_counted_cash,0),
    'variance', coalesce(p_counted_cash,0) - v_expected);
end $$;

create or replace function public.list_daily_closes(p_limit int default 30, p_branch uuid default null)
returns setof public.daily_closes
language sql stable security definer set search_path = '' as $$
  select * from public.daily_closes
   where branch_id = coalesce(p_branch, private.my_branch())
     and private.can('finance.view')
   order by close_date desc
   limit greatest(1, least(coalesce(p_limit, 30), 365))
$$;


-- ── Stock variance ───────────────────────────────────────────
create or replace function public.inventory_variance(
  p_from date, p_to date, p_branch uuid default null)
returns table (
  ingredient_id uuid, name text, unit text, delivered numeric, used numeric,
  wasted numeric, found_short numeric, found_over numeric, returned numeric,
  closing_stock numeric, discovered_loss_value numeric, waste_value numeric)
language plpgsql stable security definer set search_path = '' as $$
declare v_branch uuid := coalesce(p_branch, private.my_branch());
begin
  if not private.can('inventory.view') then
    raise exception 'permission_denied: inventory.view' using errcode = '42501';
  end if;
  return query
    select i.id, i.name, i.unit,
           coalesce(m.delivered,0), coalesce(m.used,0), coalesce(m.wasted,0),
           coalesce(m.found_short,0), coalesce(m.found_over,0), coalesce(m.returned,0),
           i.current_stock,
           round(coalesce(m.found_short,0) * coalesce(i.avg_unit_cost, i.last_unit_cost, 0), 2),
           round(coalesce(m.wasted,0)      * coalesce(i.avg_unit_cost, i.last_unit_cost, 0), 2)
      from public.ingredients i
      left join (
        select sm.ingredient_id,
               sum(case when sm.movement_type='delivery_in' then sm.quantity else 0 end) delivered,
               sum(case when sm.movement_type='usage'       then sm.quantity else 0 end) used,
               sum(case when sm.movement_type='wastage'     then sm.quantity else 0 end) wasted,
               sum(case when sm.movement_type='adjust_down' then sm.quantity else 0 end) found_short,
               sum(case when sm.movement_type='adjust_up'   then sm.quantity else 0 end) found_over,
               sum(case when sm.movement_type='return_out'  then sm.quantity else 0 end) returned
          from public.stock_movements sm
         where sm.branch_id = v_branch
           and sm.occurred_at >= p_from::timestamptz
           and sm.occurred_at <  (p_to + 1)::timestamptz
         group by sm.ingredient_id) m on m.ingredient_id = i.id
     where i.branch_id = v_branch and i.is_active
     order by round(coalesce(m.found_short,0) * coalesce(i.avg_unit_cost, i.last_unit_cost, 0), 2) desc,
              round(coalesce(m.wasted,0)      * coalesce(i.avg_unit_cost, i.last_unit_cost, 0), 2) desc,
              i.name;
end $$;

comment on function public.inventory_variance is
  'Movement-based variance. found_short is stock a count discovered missing --
   the leakage signal. NOT theoretical yield variance: that needs recipes,
   and there is no recipe table yet.';


-- ── Shared-bill breakdown keyed on an order ──────────────────
-- table_bill() is keyed on the table uuid, which the floor panel does not
-- hold: its state is keyed by branch + table NUMBER and carries order ids.
create or replace function public.order_bill_breakdown(p_order_id uuid)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v jsonb;
begin
  if not private.can('orders.view') then
    raise exception 'permission_denied: orders.view' using errcode = '42501';
  end if;
  select jsonb_build_object(
    'order_id', o.id, 'order_number', o.order_number,
    'status', o.status, 'total', o.total,
    'guests', coalesce((
      select jsonb_agg(g order by g->>'guest') from (
        select jsonb_build_object('device_id', i.device_id,
                 'guest', coalesce(max(i.guest_name), 'Walk-in'),
                 'lines', count(*), 'subtotal', sum(i.total_price)) as g
          from public.order_items i
         where i.order_id = o.id and i.voided_at is null
         group by i.device_id) s), '[]'::jsonb))
  into v from public.orders o where o.id = p_order_id;
  return v;
end $$;


-- ── RLS + grants ─────────────────────────────────────────────
alter table public.daily_closes enable row level security;
drop policy if exists dc_read on public.daily_closes;
create policy dc_read on public.daily_closes for select to authenticated
  using (private.can('finance.view') and (branch_id = private.my_branch() or private.can('settings.manage')));

grant select on public.daily_closes to authenticated;
revoke all on public.daily_closes from anon;

revoke execute on function public.daily_close_report(date, uuid)                from public, anon;
revoke execute on function public.record_daily_close(date, numeric, text, uuid) from public, anon;
revoke execute on function public.list_daily_closes(int, uuid)                  from public, anon;
revoke execute on function public.inventory_variance(date, date, uuid)          from public, anon;
revoke execute on function public.order_bill_breakdown(uuid)                    from public, anon;
grant execute on function public.daily_close_report(date, uuid)                to authenticated;
grant execute on function public.record_daily_close(date, numeric, text, uuid) to authenticated;
grant execute on function public.list_daily_closes(int, uuid)                  to authenticated;
grant execute on function public.inventory_variance(date, date, uuid)          to authenticated;
grant execute on function public.order_bill_breakdown(uuid)                    to authenticated;
