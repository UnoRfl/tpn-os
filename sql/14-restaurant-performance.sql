-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 14: Restaurant Performance Analytics
--
-- One function → one round trip → a full monthly performance
-- report. Returns JSONB with the following sections:
--
--   overview       — headline numbers (revenue, orders, AOV, etc.)
--   prev_overview  — same numbers for the prior month, for %-change
--   daily          — revenue + order count per day of the month
--   top_items      — top 12 dishes by revenue (with qty + share %)
--   categories     — sales grouped by menu category
--   order_types    — dine-in / pickup / delivery split
--   hours          — orders + revenue per hour of day (0-23)
--   payment_methods — breakdown by payment method
--   voids          — voided item count, amount, top void reasons
--
-- Manager+ only. RLS-safe via internal role check.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.sales_performance_month(
  p_month     date,
  p_branch_id uuid default null
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  m_start   timestamptz;
  m_end     timestamptz;
  pm_start  timestamptz;   -- previous month
  pm_end    timestamptz;
  tz        text := 'Asia/Manila';
  result    jsonb := '{}'::jsonb;
begin
  -- Manager+ only. History = for staff; Performance = for management.
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  -- Compute month boundaries as Manila-local dates cast to UTC timestamptz.
  m_start  := (date_trunc('month', p_month)                             at time zone tz);
  m_end    := ((date_trunc('month', p_month) + interval '1 month')      at time zone tz);
  pm_start := ((date_trunc('month', p_month) - interval '1 month')      at time zone tz);
  pm_end   := m_start;

  -- ═════════════════════════════════════════════════════════════
  -- 1. OVERVIEW (current + previous month)
  -- ═════════════════════════════════════════════════════════════
  with cur as (
    select
      coalesce(sum(total), 0)::numeric(12,2)         as revenue,
      count(*)::int                                   as order_count,
      case when count(*) = 0 then 0
           else round(sum(total) / count(*), 2) end   as avg_order
    from public.orders
    where placed_at >= m_start and placed_at < m_end
      and status <> 'cancelled'
      and (p_branch_id is null or branch_id = p_branch_id)
  ),
  prev as (
    select
      coalesce(sum(total), 0)::numeric(12,2)         as revenue,
      count(*)::int                                   as order_count,
      case when count(*) = 0 then 0
           else round(sum(total) / count(*), 2) end   as avg_order
    from public.orders
    where placed_at >= pm_start and placed_at < pm_end
      and status <> 'cancelled'
      and (p_branch_id is null or branch_id = p_branch_id)
  ),
  best_day as (
    select
      (placed_at at time zone tz)::date  as day,
      sum(total)::numeric(12,2)          as revenue
    from public.orders
    where placed_at >= m_start and placed_at < m_end
      and status <> 'cancelled'
      and (p_branch_id is null or branch_id = p_branch_id)
    group by 1
    order by 2 desc
    limit 1
  ),
  peak_hour as (
    select
      extract(hour from placed_at at time zone tz)::int as hr,
      count(*)::int as orders
    from public.orders
    where placed_at >= m_start and placed_at < m_end
      and status <> 'cancelled'
      and (p_branch_id is null or branch_id = p_branch_id)
    group by 1
    order by 2 desc
    limit 1
  ),
  void_totals as (
    select
      count(*)::int                              as void_count,
      coalesce(sum(oi.total_price), 0)::numeric  as void_amount
    from public.order_items oi
    join public.orders o on o.id = oi.order_id
    where oi.voided_at is not null
      and oi.voided_at >= m_start and oi.voided_at < m_end
      and (p_branch_id is null or o.branch_id = p_branch_id)
  )
  select jsonb_build_object(
    'overview', jsonb_build_object(
      'revenue',          cur.revenue,
      'orders',           cur.order_count,
      'avg_order',        cur.avg_order,
      'best_day',         best_day.day,
      'best_day_revenue', coalesce(best_day.revenue, 0),
      'peak_hour',        peak_hour.hr,
      'peak_hour_orders', coalesce(peak_hour.orders, 0),
      'void_count',       void_totals.void_count,
      'void_amount',      void_totals.void_amount,
      'void_rate', case
        when cur.order_count = 0 then 0
        else round((void_totals.void_amount / nullif(cur.revenue, 0)) * 100, 2)
      end
    ),
    'prev_overview', jsonb_build_object(
      'revenue',   prev.revenue,
      'orders',    prev.order_count,
      'avg_order', prev.avg_order
    )
  )
  into result
  from cur, prev
  left join best_day  on true
  left join peak_hour on true
  left join void_totals on true;

  -- ═════════════════════════════════════════════════════════════
  -- 2. DAILY series — every day of the month with 0-fill so the
  -- bar chart renders continuously.
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'daily',
    coalesce((
      select jsonb_agg(row_to_json(t))
      from (
        select
          d::date                                   as day,
          coalesce(sum(o.total), 0)::numeric(12,2)  as revenue,
          count(o.id)::int                          as orders
        from generate_series(
               date_trunc('month', p_month)::date,
               (date_trunc('month', p_month) + interval '1 month - 1 day')::date,
               interval '1 day'
             ) as d
        left join public.orders o
          on (o.placed_at at time zone tz)::date = d::date
         and o.status <> 'cancelled'
         and (p_branch_id is null or o.branch_id = p_branch_id)
        group by d
        order by d
      ) t
    ), '[]'::jsonb)
  );

  -- ═════════════════════════════════════════════════════════════
  -- 3. TOP ITEMS (by revenue). Includes qty + share of month.
  -- Groups by name_snapshot so items renamed/deleted later still
  -- show correctly.
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'top_items',
    coalesce((
      select jsonb_agg(row_to_json(t))
      from (
        select
          oi.name_snapshot                              as name,
          sum(oi.quantity)::int                         as qty,
          sum(oi.total_price)::numeric(12,2)            as revenue
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        where o.placed_at >= m_start and o.placed_at < m_end
          and o.status <> 'cancelled'
          and oi.voided_at is null
          and (p_branch_id is null or o.branch_id = p_branch_id)
        group by oi.name_snapshot
        order by revenue desc
        limit 12
      ) t
    ), '[]'::jsonb)
  );

  -- ═════════════════════════════════════════════════════════════
  -- 4. CATEGORY breakdown. Falls back to 'Uncategorized' if the
  -- menu_item was deleted or wasn't linked.
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'categories',
    coalesce((
      select jsonb_agg(row_to_json(t))
      from (
        select
          coalesce(mc.name, 'Uncategorized')          as category,
          sum(oi.total_price)::numeric(12,2)          as revenue,
          sum(oi.quantity)::int                       as qty
        from public.order_items oi
        join public.orders o        on o.id = oi.order_id
        left join public.menu_items mi on mi.id = oi.menu_item_id
        left join public.menu_categories mc on mc.id = mi.category_id
        where o.placed_at >= m_start and o.placed_at < m_end
          and o.status <> 'cancelled'
          and oi.voided_at is null
          and (p_branch_id is null or o.branch_id = p_branch_id)
        group by coalesce(mc.name, 'Uncategorized')
        order by revenue desc
      ) t
    ), '[]'::jsonb)
  );

  -- ═════════════════════════════════════════════════════════════
  -- 5. ORDER TYPES split (dine-in / pickup / delivery)
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'order_types',
    coalesce((
      select jsonb_agg(row_to_json(t))
      from (
        select
          order_type::text                       as type,
          count(*)::int                          as orders,
          coalesce(sum(total), 0)::numeric(12,2) as revenue
        from public.orders
        where placed_at >= m_start and placed_at < m_end
          and status <> 'cancelled'
          and (p_branch_id is null or branch_id = p_branch_id)
        group by order_type
        order by revenue desc
      ) t
    ), '[]'::jsonb)
  );

  -- ═════════════════════════════════════════════════════════════
  -- 6. PEAK HOURS — all 24 hours, 0-filled so the bars render.
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'hours',
    coalesce((
      select jsonb_agg(row_to_json(t) order by t.hour)
      from (
        select
          h                                        as hour,
          coalesce(x.orders, 0)                    as orders,
          coalesce(x.revenue, 0)::numeric(12,2)    as revenue
        from generate_series(0, 23) as h
        left join (
          select
            extract(hour from placed_at at time zone tz)::int as hr,
            count(*)::int                                       as orders,
            coalesce(sum(total), 0)::numeric(12,2)              as revenue
          from public.orders
          where placed_at >= m_start and placed_at < m_end
            and status <> 'cancelled'
            and (p_branch_id is null or branch_id = p_branch_id)
          group by 1
        ) x on x.hr = h
      ) t
    ), '[]'::jsonb)
  );

  -- ═════════════════════════════════════════════════════════════
  -- 7. PAYMENT METHODS
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'payment_methods',
    coalesce((
      select jsonb_agg(row_to_json(t))
      from (
        select
          coalesce(payment_method::text, 'unspecified') as method,
          count(*)::int                                 as orders,
          coalesce(sum(total), 0)::numeric(12,2)        as revenue
        from public.orders
        where placed_at >= m_start and placed_at < m_end
          and status <> 'cancelled'
          and (p_branch_id is null or branch_id = p_branch_id)
        group by payment_method
        order by revenue desc
      ) t
    ), '[]'::jsonb)
  );

  -- ═════════════════════════════════════════════════════════════
  -- 8. VOIDS — reasons breakdown (top 8)
  -- ═════════════════════════════════════════════════════════════
  result := result || jsonb_build_object(
    'void_reasons',
    coalesce((
      select jsonb_agg(row_to_json(t))
      from (
        select
          coalesce(oi.void_reason, 'unspecified') as reason,
          count(*)::int                            as count,
          sum(oi.total_price)::numeric(12,2)       as amount
        from public.order_items oi
        join public.orders o on o.id = oi.order_id
        where oi.voided_at is not null
          and oi.voided_at >= m_start and oi.voided_at < m_end
          and (p_branch_id is null or o.branch_id = p_branch_id)
        group by coalesce(oi.void_reason, 'unspecified')
        order by count desc
        limit 8
      ) t
    ), '[]'::jsonb)
  );

  return result;
end $$;

grant execute on function public.sales_performance_month(date, uuid) to authenticated;
revoke execute on function public.sales_performance_month(date, uuid) from public, anon;

-- ═══════════════════════════════════════════════════════════════
-- Helpful indexes for the analytics workload. All are conditional
-- on the underlying tables existing to keep this idempotent.
-- ═══════════════════════════════════════════════════════════════
create index if not exists idx_orders_placed_at_status
  on public.orders(placed_at, status)
  where status <> 'cancelled';

create index if not exists idx_orders_branch_placed
  on public.orders(branch_id, placed_at desc);

create index if not exists idx_order_items_voided_at
  on public.order_items(voided_at)
  where voided_at is not null;

-- Done.
