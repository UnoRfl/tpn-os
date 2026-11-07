-- ═══════════════════════════════════════════════════════════════
-- 50 — menu engineering: food cost per dish, stars and dogs (Oct 22, 2026)
--
-- RECOVERED Nov 7, 2026. Production ran this on Oct 22 (Supabase
-- migrations 50_menu_engineering and 50_menu_engineering_size_names) but
-- the file never reached GitHub. Both parts below are copied byte for
-- byte from supabase_migrations.schema_migrations on project
-- xjlqfpnzobfqxetgkkai (md5 8f15de07… and f5642787…), in order.
--
--   public.menu_item_costs   food cost per dish, or per size (pax_costs)
--   set_menu_item_cost       menu.edit, audited
--   menu_engineering         finance.view; sorts sold dishes into
--                            star / plowhorse / puzzle / dog by
--                            popularity and margin (price when a cost
--                            is missing). Manila days.
-- Part 2 reads old "2-3 pax" order lines as size "2-3". Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── Part 1: 50_menu_engineering ─────────────────────────────────
-- sql/50-menu-engineering.sql (see repo for the full header)
create table if not exists public.menu_item_costs (
  menu_item_id uuid primary key references public.menu_items(id) on delete cascade,
  food_cost    numeric(10,2) check (food_cost is null or (food_cost >= 0 and food_cost < 100000)),
  pax_costs    jsonb check (pax_costs is null or jsonb_typeof(pax_costs) = 'object'),
  updated_at   timestamptz not null default now(),
  updated_by   uuid references public.staff(id)
);
alter table public.menu_item_costs enable row level security;
revoke all on public.menu_item_costs from public, anon, authenticated;
grant select on public.menu_item_costs to authenticated;
drop policy if exists menu_item_costs_read on public.menu_item_costs;
create policy menu_item_costs_read on public.menu_item_costs
  for select to authenticated
  using (private.can('menu.edit') or private.can('finance.view'));

create or replace function public.set_menu_item_cost(
  p_item uuid, p_food_cost numeric, p_pax_costs jsonb default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_mi public.menu_items%rowtype;
  v_before jsonb;
  v_after  jsonb;
  v_pax    jsonb := '{}'::jsonb;
  k text; v jsonb;
begin
  if not private.can('menu.edit') then
    raise exception 'permission_denied: menu.edit' using errcode = '42501';
  end if;
  select * into v_mi from public.menu_items where id = p_item;
  if not found then raise exception 'unknown_item' using errcode = '22023'; end if;
  if p_food_cost is not null and (p_food_cost < 0 or p_food_cost >= 100000) then
    raise exception 'bad_cost: %', p_food_cost using errcode = '22023';
  end if;
  if p_pax_costs is not null and jsonb_typeof(p_pax_costs) <> 'null' then
    if jsonb_typeof(p_pax_costs) <> 'object' then
      raise exception 'bad_cost: sizes must be an object' using errcode = '22023';
    end if;
    for k, v in select * from jsonb_each(p_pax_costs) loop
      if jsonb_typeof(v) = 'null' or (jsonb_typeof(v) = 'string' and btrim(v #>> '{}') = '') then
        continue;
      end if;
      if v_mi.pax_options is null or jsonb_typeof(v_mi.pax_options) <> 'object' or not (v_mi.pax_options ? k) then
        raise exception 'unknown_size: %', k using errcode = '22023';
      end if;
      if (v #>> '{}') !~ '^\s*\d+(\.\d+)?\s*$' or (v #>> '{}')::numeric >= 100000 then
        raise exception 'bad_cost: %', v #>> '{}' using errcode = '22023';
      end if;
      v_pax := v_pax || jsonb_build_object(k, round((v #>> '{}')::numeric, 2));
    end loop;
  end if;

  select to_jsonb(c) into v_before from public.menu_item_costs c where c.menu_item_id = p_item;
  if p_food_cost is null and v_pax = '{}'::jsonb then
    delete from public.menu_item_costs where menu_item_id = p_item;
    v_after := null;
  else
    insert into public.menu_item_costs (menu_item_id, food_cost, pax_costs, updated_at, updated_by)
    values (p_item, round(p_food_cost, 2), nullif(v_pax, '{}'::jsonb), now(), auth.uid())
    on conflict (menu_item_id) do update
      set food_cost = excluded.food_cost, pax_costs = excluded.pax_costs,
          updated_at = excluded.updated_at, updated_by = excluded.updated_by;
    select to_jsonb(c) into v_after from public.menu_item_costs c where c.menu_item_id = p_item;
  end if;

  if v_before is distinct from v_after then
    insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, before_state, after_state, metadata)
    values (auth.uid(), private.my_role(), 'menu_item_cost.set', 'menu_items', p_item, v_before, v_after,
            jsonb_build_object('name', v_mi.name));
  end if;
  return coalesce(v_after, jsonb_build_object('menu_item_id', p_item, 'food_cost', null, 'pax_costs', null));
end $$;
revoke all on function public.set_menu_item_cost(uuid, numeric, jsonb) from public, anon;
grant execute on function public.set_menu_item_cost(uuid, numeric, jsonb) to authenticated;

create or replace function public.menu_engineering(p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_lo timestamptz;
  v_hi timestamptz;
  v jsonb;
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;
  if p_branch is not null and p_branch is distinct from private.my_branch()
     and not private.can('settings.manage') then
    raise exception 'permission_denied: other branch' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'bad_range' using errcode = '22023';
  end if;
  v_lo := (p_from::timestamp at time zone 'Asia/Manila');
  v_hi := ((p_to + 1)::timestamp at time zone 'Asia/Manila');

  with lines as (
    select oi.menu_item_id, oi.pax_size, oi.quantity, oi.total_price, oi.name_snapshot,
           case when oi.pax_size is null then c.food_cost
                else (c.pax_costs ->> oi.pax_size)::numeric end as unit_cost
      from public.order_items oi
      join public.orders o on o.id = oi.order_id
      left join public.menu_item_costs c on c.menu_item_id = oi.menu_item_id
     where o.branch_id = v_branch
       and o.status = 'completed'
       and o.placed_at >= v_lo and o.placed_at < v_hi
       and oi.voided_at is null
       and oi.menu_item_id is not null
       and oi.quantity > 0
  ), rows as (
    select l.menu_item_id, l.pax_size as size,
           coalesce(max(mi.name), max(l.name_snapshot)) as name, max(mc.name) as category,
           sum(l.quantity)::numeric as qty, sum(l.total_price) as revenue,
           sum(l.quantity * coalesce(l.unit_cost, 0)) as cost,
           bool_or(l.unit_cost is null) as cost_missing
      from lines l
      left join public.menu_items mi on mi.id = l.menu_item_id
      left join public.menu_categories mc on mc.id = mi.category_id
     group by l.menu_item_id, l.pax_size
  ), tot as (
    select count(*) as n, coalesce(sum(qty), 0) as qty, coalesce(sum(revenue), 0) as revenue,
           coalesce(sum(revenue - cost), 0) as margin,
           count(*) filter (where cost_missing) as missing
      from rows
  ), k as (
    select t.*, case when t.missing = 0 then 'margin' else 'price' end as basis,
           case when t.n > 0 then 0.7 / t.n end as pop,
           case when t.missing = 0 then t.margin else t.revenue end / nullif(t.qty, 0) as prof
      from tot t
  ), scored as (
    select r.*, r.qty / nullif(k.qty, 0) as share,
           case when k.basis = 'margin' then (r.revenue - r.cost) / r.qty else r.revenue / r.qty end as val,
           k.pop, k.prof
      from rows r cross join k
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'branch_id', v_branch,
    'basis', k.basis,
    'dishes', k.n, 'items_sold', k.qty, 'revenue', round(k.revenue, 2),
    'total_margin', case when k.basis = 'margin' then round(k.margin, 2) end,
    'popularity_threshold', round(k.pop, 4),
    'profit_threshold', round(k.prof, 2),
    'cost_missing_count', k.missing,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'menu_item_id', s.menu_item_id, 'size', s.size, 'name', s.name, 'category', s.category,
               'qty', s.qty, 'revenue', round(s.revenue, 2),
               'share', round(s.share, 4), 'avg_price', round(s.revenue / s.qty, 2),
               'unit_cost', case when not s.cost_missing then round(s.cost / s.qty, 2) end,
               'unit_margin', case when not s.cost_missing then round((s.revenue - s.cost) / s.qty, 2) end,
               'total_margin', case when not s.cost_missing then round(s.revenue - s.cost, 2) end,
               'value', round(s.val, 2),
               'cost_missing', s.cost_missing,
               'popular', s.share >= s.pop, 'profitable', s.val >= s.prof,
               'group', case when s.share >= s.pop and s.val >= s.prof then 'star'
                             when s.share >= s.pop then 'plowhorse'
                             when s.val >= s.prof then 'puzzle'
                             else 'dog' end)
             order by s.qty desc, s.revenue desc, s.name)
        from scored s), '[]'::jsonb))
    into v
    from k;
  return v;
end $$;
revoke all on function public.menu_engineering(date, date, uuid) from public, anon;
grant execute on function public.menu_engineering(date, date, uuid) to authenticated;

-- ── Part 2: 50_menu_engineering_size_names ──────────────────────
-- sql/50 (final): menu_engineering reads old "2-3 pax" lines as "2-3".
create or replace function public.menu_engineering(p_from date, p_to date, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_lo timestamptz;
  v_hi timestamptz;
  v jsonb;
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;
  if p_branch is not null and p_branch is distinct from private.my_branch()
     and not private.can('settings.manage') then
    raise exception 'permission_denied: other branch' using errcode = '42501';
  end if;
  if p_from is null or p_to is null or p_from > p_to or p_to - p_from > 366 then
    raise exception 'bad_range' using errcode = '22023';
  end if;
  v_lo := (p_from::timestamp at time zone 'Asia/Manila');
  v_hi := ((p_to + 1)::timestamp at time zone 'Asia/Manila');

  with raw as (
    select oi.*, nullif(regexp_replace(btrim(coalesce(oi.pax_size, '')), '\s*pax$', '', 'i'), '') as size_key
      from public.order_items oi
  ), lines as (
    select oi.menu_item_id, oi.size_key as pax_size, oi.quantity, oi.total_price, oi.name_snapshot,
           case when oi.size_key is null then c.food_cost
                else (c.pax_costs ->> oi.size_key)::numeric end as unit_cost
      from raw oi
      join public.orders o on o.id = oi.order_id
      left join public.menu_item_costs c on c.menu_item_id = oi.menu_item_id
     where o.branch_id = v_branch
       and o.status = 'completed'
       and o.placed_at >= v_lo and o.placed_at < v_hi
       and oi.voided_at is null
       and oi.menu_item_id is not null
       and oi.quantity > 0
  ), rows as (
    select l.menu_item_id, l.pax_size as size,
           coalesce(max(mi.name), max(l.name_snapshot)) as name, max(mc.name) as category,
           sum(l.quantity)::numeric as qty, sum(l.total_price) as revenue,
           sum(l.quantity * coalesce(l.unit_cost, 0)) as cost,
           bool_or(l.unit_cost is null) as cost_missing
      from lines l
      left join public.menu_items mi on mi.id = l.menu_item_id
      left join public.menu_categories mc on mc.id = mi.category_id
     group by l.menu_item_id, l.pax_size
  ), tot as (
    select count(*) as n, coalesce(sum(qty), 0) as qty, coalesce(sum(revenue), 0) as revenue,
           coalesce(sum(revenue - cost), 0) as margin,
           count(*) filter (where cost_missing) as missing
      from rows
  ), k as (
    select t.*, case when t.missing = 0 then 'margin' else 'price' end as basis,
           case when t.n > 0 then 0.7 / t.n end as pop,
           case when t.missing = 0 then t.margin else t.revenue end / nullif(t.qty, 0) as prof
      from tot t
  ), scored as (
    select r.*, r.qty / nullif(k.qty, 0) as share,
           case when k.basis = 'margin' then (r.revenue - r.cost) / r.qty else r.revenue / r.qty end as val,
           k.pop, k.prof
      from rows r cross join k
  )
  select jsonb_build_object(
    'from', p_from, 'to', p_to, 'branch_id', v_branch,
    'basis', k.basis,
    'dishes', k.n, 'items_sold', k.qty, 'revenue', round(k.revenue, 2),
    'total_margin', case when k.basis = 'margin' then round(k.margin, 2) end,
    'popularity_threshold', round(k.pop, 4),
    'profit_threshold', round(k.prof, 2),
    'cost_missing_count', k.missing,
    'items', coalesce((
      select jsonb_agg(jsonb_build_object(
               'menu_item_id', s.menu_item_id, 'size', s.size, 'name', s.name, 'category', s.category,
               'qty', s.qty, 'revenue', round(s.revenue, 2),
               'share', round(s.share, 4), 'avg_price', round(s.revenue / s.qty, 2),
               'unit_cost', case when not s.cost_missing then round(s.cost / s.qty, 2) end,
               'unit_margin', case when not s.cost_missing then round((s.revenue - s.cost) / s.qty, 2) end,
               'total_margin', case when not s.cost_missing then round(s.revenue - s.cost, 2) end,
               'value', round(s.val, 2),
               'cost_missing', s.cost_missing,
               'popular', s.share >= s.pop, 'profitable', s.val >= s.prof,
               'group', case when s.share >= s.pop and s.val >= s.prof then 'star'
                             when s.share >= s.pop then 'plowhorse'
                             when s.val >= s.prof then 'puzzle'
                             else 'dog' end)
             order by s.qty desc, s.revenue desc, s.name)
        from scored s), '[]'::jsonb))
    into v
    from k;
  return v;
end $$;
revoke all on function public.menu_engineering(date, date, uuid) from public, anon;
grant execute on function public.menu_engineering(date, date, uuid) to authenticated;
