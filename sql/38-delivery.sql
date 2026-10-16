-- ═══════════════════════════════════════════════════════════════
-- 38 · Delivery: zones, fee on the bill, dispatch and tracking
--
-- Zones   delivery_zones: an area (city or barangays) with its fee,
--         minimum order and usual travel time. The website and counter
--         list the active ones; the fee is added by the server.
-- Fee     orders.delivery_fee is part of the total (recompute below) and
--         can only change through set_delivery_fee (supervisor+).
-- Dispatch deliveries: one row per delivery order — our own rider or a
--         courier booked by hand (Lalamove / Grab / other) with the
--         tracking link and what the courier charged.
--         waiting → assigned → on_the_way → delivered (or failed).
-- Track   track_delivery(order_number, token) for the customer.
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

select private.add_permission('delivery.dispatch', 'Orders', 'Dispatch deliveries', 'Mag-dispatch ng delivery',
  'Assign a rider or courier and move a delivery along.', 'dining', 145);
select private.add_permission('delivery.manage', 'Orders', 'Manage delivery zones', 'Pamahalaan ang delivery zone',
  'Set delivery areas, fees and minimum orders.', 'manager', 146);

create table if not exists public.delivery_zones (
  id           uuid primary key default gen_random_uuid(),
  branch_id    uuid not null references public.branches(id) on delete cascade,
  name         text not null check (length(btrim(name)) between 2 and 60),
  name_tl      text,
  areas        text,                                  -- barangays / landmarks, shown to the customer
  fee          numeric(10,2) not null default 0 check (fee >= 0 and fee <= 5000),
  min_order    numeric(10,2) not null default 0 check (min_order >= 0),
  eta_minutes  int check (eta_minutes is null or eta_minutes between 5 and 600),
  is_active    boolean not null default true,
  sort         int not null default 100,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);
alter table public.delivery_zones enable row level security;
drop policy if exists delivery_zones_read on public.delivery_zones;
create policy delivery_zones_read on public.delivery_zones for select to anon, authenticated
  using (is_active or private.can('delivery.manage'));
drop policy if exists delivery_zones_write on public.delivery_zones;
create policy delivery_zones_write on public.delivery_zones for all to authenticated
  using (private.can('delivery.manage') and (branch_id = private.my_branch() or private.has_role('admin')))
  with check (private.can('delivery.manage') and (branch_id = private.my_branch() or private.has_role('admin')));
revoke all on public.delivery_zones from anon;
grant select on public.delivery_zones to anon;
grant select, insert, update, delete on public.delivery_zones to authenticated;
drop trigger if exists trg_delivery_zones_audit on public.delivery_zones;
create trigger trg_delivery_zones_audit after insert or update or delete on public.delivery_zones
  for each row execute function private.audit_row();

alter table public.orders add column if not exists delivery_zone_id uuid references public.delivery_zones(id) on delete set null;
alter table public.orders add column if not exists delivery_fee numeric(10,2) not null default 0;

-- The fee is part of the bill, so only the server writes it.
create or replace function private.trg_guard_delivery_fee()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.delivery_fee is distinct from old.delivery_fee or new.delivery_zone_id is distinct from old.delivery_zone_id)
     and coalesce(current_setting('tpn.delivery', true), 'off') <> 'on' then
    raise exception 'delivery_fee_is_set_by_zone: use set_delivery_fee' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function private.trg_guard_delivery_fee() from public, anon, authenticated;
drop trigger if exists trg_guard_delivery_fee on public.orders;
create trigger trg_guard_delivery_fee before update on public.orders
  for each row execute function private.trg_guard_delivery_fee();

-- Totals now include the delivery fee.
create or replace function private.recompute_order_totals(p_order_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  new_subtotal numeric(10,2);
  disc         numeric(10,2);
  svc          numeric(10,2);
  fee          numeric(10,2);
begin
  select coalesce(sum(total_price), 0) into new_subtotal
    from public.order_items
   where order_id = p_order_id and voided_at is null;

  select coalesce(discount_amount, 0), coalesce(service_charge, 0), coalesce(delivery_fee, 0)
    into disc, svc, fee
    from public.orders where id = p_order_id;

  perform set_config('tpn.recompute', 'on', true);
  update public.orders
     set subtotal = new_subtotal,
         total    = greatest(0, new_subtotal - coalesce(disc,0) + coalesce(svc,0) + coalesce(fee,0))
   where id = p_order_id;
  perform set_config('tpn.recompute', 'off', true);
end $$;
revoke execute on function private.recompute_order_totals(uuid) from public, anon, authenticated;

create table if not exists public.deliveries (
  order_id      uuid primary key references public.orders(id) on delete cascade,
  branch_id     uuid not null references public.branches(id),
  status        text not null default 'waiting' check (status in ('waiting', 'assigned', 'on_the_way', 'delivered', 'failed')),
  courier       text check (courier in ('own', 'lalamove', 'grab', 'other')),
  rider_staff_id uuid references public.staff(id) on delete set null,
  rider_name    text,
  rider_phone   text,
  tracking_url  text check (tracking_url is null or tracking_url ~ '^https://'),
  courier_cost  numeric(10,2) check (courier_cost is null or courier_cost >= 0),
  note          text,
  fail_reason   text,
  assigned_at   timestamptz,
  picked_up_at  timestamptz,
  delivered_at  timestamptz,
  updated_by    uuid,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);
create index if not exists deliveries_branch_status_idx on public.deliveries (branch_id, status);
alter table public.deliveries enable row level security;
drop policy if exists deliveries_read on public.deliveries;
create policy deliveries_read on public.deliveries for select to authenticated
  using ((private.can('orders.view') or private.can('delivery.dispatch') or rider_staff_id = auth.uid())
         and (branch_id = private.my_branch() or private.has_role('admin')));
revoke all on public.deliveries from anon, authenticated;
grant select on public.deliveries to authenticated;
drop trigger if exists trg_deliveries_audit on public.deliveries;
create trigger trg_deliveries_audit after insert or update or delete on public.deliveries
  for each row execute function private.audit_row();

-- Existing open delivery orders get a dispatch row.
insert into public.deliveries (order_id, branch_id)
select o.id, o.branch_id from public.orders o
 where o.order_type = 'delivery' and o.status not in ('completed', 'cancelled')
on conflict (order_id) do nothing;

-- New signature (adds p_delivery_zone_id). Drop the old one so a call by
-- name is never ambiguous.
drop function if exists public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text);
create or replace function public.submit_order(
  p_branch_id uuid, p_order_type text, p_items jsonb,
  p_table_id uuid default null, p_customer_name text default null,
  p_customer_phone text default null, p_notes text default null,
  p_payment_method text default null, p_delivery_address text default null,
  p_scheduled_for timestamptz default null, p_device_id text default null,
  p_join_table_bill boolean default true, p_source text default null,
  p_delivery_zone_id uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid; v_number text; v_token uuid; v_item jsonb;
  v_appended boolean := false; v_qty int; v_price numeric; v_batch numeric := 0;
  v_flagged boolean := false; v_mi public.menu_items%rowtype; v_pax text;
  v_clean jsonb := '[]'::jsonb; v_mods jsonb; v_mod_total numeric; v_g record;
  v_source text;
  v_zone public.delivery_zones%rowtype; v_fee numeric(10,2) := 0;
  v_device   text := private.clean_device_id(p_device_id);
  v_name     text := left(nullif(btrim(coalesce(p_customer_name, '')), ''), 60);
  v_phone    text := left(nullif(regexp_replace(coalesce(p_customer_phone, ''), '[^0-9+]', '', 'g'), ''), 16);
  v_notes    text := left(nullif(btrim(coalesce(p_notes, '')), ''), 500);
  v_address  text := left(nullif(btrim(coalesce(p_delivery_address, '')), ''), 300);
  v_staff    boolean := private.my_role() is not null;
begin
  -- A signed-in staff member ringing up at the counter is not rate limited;
  -- an anonymous caller is.
  if not v_staff then
    perform private.rate_limit('submit_order', 20, interval '10 minutes');
  elsif not (private.can('pos.use') or private.can('orders.manage')) then
    raise exception 'permission_denied: pos.use' using errcode = '42501';
  end if;
  v_source := case when p_source in ('web', 'qr', 'pos', 'phone') then p_source
                   when v_staff then 'pos' when p_table_id is not null then 'qr' else 'web' end;
  if not v_staff and v_source in ('pos', 'phone') then v_source := 'web'; end if;

  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'no_items: an order needs at least one line' using errcode = '22023';
  end if;
  if jsonb_array_length(p_items) > 40 then
    raise exception 'too_many_lines: split this into two orders' using errcode = '22023';
  end if;
  if p_order_type not in ('dine_in', 'pickup', 'delivery') then
    raise exception 'bad_order_type: %', p_order_type using errcode = '22023';
  end if;
  if p_order_type = 'delivery' and v_address is null then
    raise exception 'delivery_needs_address' using errcode = '22023';
  end if;
  if not exists (select 1 from public.branches b where b.id = p_branch_id and b.is_active) then
    raise exception 'branch_not_found' using errcode = '22023';
  end if;
  if v_staff and p_branch_id is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  if p_table_id is not null and not exists (
       select 1 from public.restaurant_tables t
        where t.id = p_table_id and t.branch_id = p_branch_id and t.is_active) then
    raise exception 'table_not_in_branch' using errcode = '22023';
  end if;
  if p_scheduled_for is not null
     and (p_scheduled_for < now() - interval '5 minutes' or p_scheduled_for > now() + interval '60 days') then
    raise exception 'bad_schedule_time' using errcode = '22023';
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      select * into v_mi from public.menu_items where id = nullif(v_item->>'menu_item_id', '')::uuid;
    exception when invalid_text_representation then
      raise exception 'unknown_item' using errcode = '22023';
    end;
    if not found then raise exception 'unknown_item' using errcode = '22023'; end if;
    if not coalesce(v_mi.is_available, true) then
      raise exception 'item_sold_out: %', v_mi.name using errcode = '22023';
    end if;
    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 50 then
      raise exception 'bad_quantity: % (1 to 50 per line)', v_mi.name using errcode = '22023';
    end if;
    -- Size as in sql/29c: "2-3" or "2-3 pax"; listed size → its price,
    -- no size → the menu price.
    v_pax := nullif(regexp_replace(btrim(coalesce(v_item->>'pax_size', '')), '\s*pax$', '', 'i'), '');
    if v_pax is not null then
      if v_mi.pax_options is null or jsonb_typeof(v_mi.pax_options) <> 'object' or not (v_mi.pax_options ? v_pax) then
        raise exception 'unknown_size: % (%)', v_mi.name, v_pax using errcode = '22023';
      end if;
      v_price := (v_mi.pax_options->>v_pax)::numeric;
    else
      v_price := v_mi.price;
    end if;
    if v_price is null or v_price < 0 then
      raise exception 'item_has_no_price: %', v_mi.name using errcode = '22023';
    end if;

    -- Modifiers: only ones linked to this dish, available, within each
    -- group's min/max. Priced here.
    v_mods := '[]'::jsonb; v_mod_total := 0;
    if jsonb_typeof(v_item->'modifiers') = 'array' and jsonb_array_length(v_item->'modifiers') > 0 then
      if jsonb_array_length(v_item->'modifiers') > 20 then raise exception 'too_many_modifiers' using errcode = '22023'; end if;
      select coalesce(jsonb_agg(jsonb_build_object('id', m.id, 'group', g.name, 'name', m.name, 'price', m.price_delta)
                                order by g.sort, m.sort), '[]'::jsonb),
             coalesce(sum(m.price_delta), 0)
        into v_mods, v_mod_total
        from public.modifiers m
        join public.modifier_groups g on g.id = m.group_id and g.is_active
        join public.menu_item_modifier_groups l on l.group_id = g.id and l.menu_item_id = v_mi.id
       where m.is_available
         and m.id in (select (x #>> '{}')::uuid from jsonb_array_elements(v_item->'modifiers') x);
      if jsonb_array_length(v_mods) <> (select count(distinct x #>> '{}') from jsonb_array_elements(v_item->'modifiers') x) then
        raise exception 'unknown_modifier: %', v_mi.name using errcode = '22023';
      end if;
    end if;
    for v_g in
      select g.id, g.name, g.min_select, g.max_select,
             (select count(*) from jsonb_array_elements(v_mods) s
               join public.modifiers m2 on m2.id = (s->>'id')::uuid where m2.group_id = g.id) as picked
        from public.modifier_groups g
        join public.menu_item_modifier_groups l on l.group_id = g.id and l.menu_item_id = v_mi.id
       where g.is_active
    loop
      if v_g.picked < v_g.min_select or v_g.picked > v_g.max_select then
        raise exception 'modifier_choice: % needs % to % from "%"', v_mi.name, v_g.min_select, v_g.max_select, v_g.name using errcode = '22023';
      end if;
    end loop;
    v_price := v_price + v_mod_total;
    if v_price < 0 then v_price := 0; end if;

    v_clean := v_clean || jsonb_build_object(
      'menu_item_id', v_mi.id, 'name', v_mi.name, 'unit_price', v_price, 'quantity', v_qty,
      'pax_size', v_pax, 'modifiers', v_mods,
      'notes', left(nullif(btrim(coalesce(v_item->>'notes', '')), ''), 200));
  end loop;

  -- Delivery: when the branch has zones, one must be picked; its fee goes on
  -- the bill and its minimum order applies (sql/38).
  if p_order_type = 'delivery'
     and exists (select 1 from public.delivery_zones z where z.branch_id = p_branch_id and z.is_active) then
    if p_delivery_zone_id is null then raise exception 'delivery_needs_zone' using errcode = '22023'; end if;
    select * into v_zone from public.delivery_zones z
     where z.id = p_delivery_zone_id and z.branch_id = p_branch_id and z.is_active;
    if not found then raise exception 'delivery_zone_unknown' using errcode = '22023'; end if;
    if v_zone.min_order > 0 and (select coalesce(sum((x->>'unit_price')::numeric * (x->>'quantity')::int), 0)
                                   from jsonb_array_elements(v_clean) x) < v_zone.min_order then
      raise exception 'delivery_min_order: %', v_zone.min_order using errcode = '22023';
    end if;
    v_fee := v_zone.fee;
  end if;

  if p_order_type = 'dine_in' and p_table_id is not null and p_join_table_bill then
    select id into v_order_id from public.orders
     where table_id = p_table_id and order_type = 'dine_in'
       and status not in ('completed', 'cancelled') and payment_status <> 'paid'
     order by placed_at limit 1 for update;
    v_appended := v_order_id is not null;
  end if;

  if v_order_id is null then
    insert into public.orders (branch_id, table_id, order_type, customer_name, customer_phone,
      subtotal, total, payment_method, notes, delivery_address, scheduled_for, source,
      delivery_zone_id, delivery_fee)
    values (p_branch_id, p_table_id, p_order_type::public.order_type_enum, v_name, v_phone, 0, 0,
      nullif(btrim(coalesce(p_payment_method, '')), '')::public.payment_method,
      v_notes, v_address, p_scheduled_for, v_source, v_zone.id, v_fee)
    returning id into v_order_id;
    if p_order_type = 'delivery' then
      insert into public.deliveries (order_id, branch_id) values (v_order_id, p_branch_id) on conflict (order_id) do nothing;
    end if;
  elsif v_notes is not null then
    update public.orders set notes = left(concat_ws(E'\n', nullif(notes, ''), v_notes), 2000) where id = v_order_id;
  end if;

  for v_item in select * from jsonb_array_elements(v_clean) loop
    v_qty := (v_item->>'quantity')::int;
    v_price := (v_item->>'unit_price')::numeric;
    v_batch := v_batch + (v_price * v_qty);
    insert into public.order_items (order_id, menu_item_id, name_snapshot, price_snapshot,
      quantity, pax_size, unit_price, total_price, notes, guest_name, device_id, modifiers)
    values (v_order_id, (v_item->>'menu_item_id')::uuid, v_item->>'name', v_price,
      v_qty, v_item->>'pax_size', v_price, v_price * v_qty, v_item->>'notes', v_name, v_device,
      coalesce(v_item->'modifiers', '[]'::jsonb));
  end loop;

  if not v_staff then
    perform private.remember_device(v_device, p_branch_id, v_name, v_phone, v_batch, v_clean);
  end if;

  select order_number, track_token into v_number, v_token from public.orders where id = v_order_id;
  select is_flagged into v_flagged from public.customer_devices where device_id = v_device;

  return jsonb_build_object(
    'id', v_order_id, 'order_number', v_number, 'track_token', v_token,
    'joined_existing', v_appended, 'device_flagged', coalesce(v_flagged, false),
    'total',    (select total    from public.orders where id = v_order_id),
    'subtotal', (select subtotal from public.orders where id = v_order_id),
    'delivery_fee', v_fee);
end $$;
revoke all on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid) from public;
grant execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid) to anon, authenticated;

-- Change a delivery order's zone (or waive the fee) after the fact.
create or replace function public.set_delivery_fee(p_order_id uuid, p_zone_id uuid default null, p_fee numeric default null, p_reason text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; z public.delivery_zones%rowtype; v_fee numeric(10,2);
begin
  if not private.has_role('supervisor') then raise exception 'permission_denied: supervisor' using errcode = '42501'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.order_type <> 'delivery' then raise exception 'not_a_delivery'; end if;
  perform private.assert_order_access(o);
  if o.payment_status = 'paid' then raise exception 'order_already_paid'; end if;
  if p_zone_id is not null then
    select * into z from public.delivery_zones where id = p_zone_id and branch_id = o.branch_id;
    if not found then raise exception 'delivery_zone_unknown'; end if;
  end if;
  v_fee := round(coalesce(p_fee, z.fee, o.delivery_fee), 2);
  if v_fee < 0 or v_fee > 5000 then raise exception 'bad_amount'; end if;
  if p_fee is not null and length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  perform set_config('tpn.delivery', 'on', true);
  update public.orders set delivery_fee = v_fee, delivery_zone_id = coalesce(p_zone_id, delivery_zone_id) where id = o.id;
  perform set_config('tpn.delivery', 'off', true);
  perform private.recompute_order_totals(o.id);
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'order.delivery_fee', 'order', o.id,
          jsonb_build_object('before', o.delivery_fee, 'after', v_fee, 'zone', p_zone_id, 'reason', p_reason));
  return jsonb_build_object('delivery_fee', v_fee, 'total', (select total from public.orders where id = o.id));
end $$;

-- Hand a delivery to our rider or a courier.
create or replace function public.delivery_assign(
  p_order_id uuid, p_courier text, p_rider_staff_id uuid default null, p_rider_name text default null,
  p_rider_phone text default null, p_tracking_url text default null, p_courier_cost numeric default null, p_note text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; v_name text := left(nullif(btrim(coalesce(p_rider_name, '')), ''), 60);
begin
  if not private.can('delivery.dispatch') then raise exception 'permission_denied: delivery.dispatch' using errcode = '42501'; end if;
  if p_courier not in ('own', 'lalamove', 'grab', 'other') then raise exception 'bad_courier'; end if;
  if p_tracking_url is not null and btrim(p_tracking_url) <> '' and p_tracking_url !~ '^https://' then raise exception 'bad_tracking_url'; end if;
  select * into o from public.orders where id = p_order_id;
  if not found or o.order_type <> 'delivery' then raise exception 'not_a_delivery'; end if;
  perform private.assert_order_access(o);
  if o.status in ('completed', 'cancelled') then raise exception 'order_closed'; end if;
  if p_courier = 'own' and p_rider_staff_id is not null then
    select coalesce(v_name, full_name) into v_name from public.staff where id = p_rider_staff_id;
  end if;
  insert into public.deliveries (order_id, branch_id) values (o.id, o.branch_id) on conflict (order_id) do nothing;
  update public.deliveries
     set status = case when status in ('waiting', 'failed') then 'assigned' else status end,
         courier = p_courier, rider_staff_id = case when p_courier = 'own' then p_rider_staff_id end,
         rider_name = v_name, rider_phone = left(nullif(regexp_replace(coalesce(p_rider_phone, ''), '[^0-9+]', '', 'g'), ''), 16),
         tracking_url = nullif(btrim(coalesce(p_tracking_url, '')), ''),
         courier_cost = case when p_courier_cost is null then null else round(p_courier_cost, 2) end,
         note = left(nullif(btrim(coalesce(p_note, '')), ''), 300), fail_reason = null,
         assigned_at = coalesce(assigned_at, now()), updated_by = auth.uid(), updated_at = now()
   where order_id = o.id;
end $$;

-- Move it along: on_the_way / delivered / failed / waiting.
-- The rider assigned to it may update it too.
create or replace function public.delivery_update(p_order_id uuid, p_status text, p_reason text default null)
returns void
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; d public.deliveries%rowtype;
begin
  if p_status not in ('waiting', 'on_the_way', 'delivered', 'failed') then raise exception 'bad_status'; end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found or o.order_type <> 'delivery' then raise exception 'not_a_delivery'; end if;
  perform private.assert_order_access(o);
  select * into d from public.deliveries where order_id = o.id for update;
  if not found then raise exception 'not_dispatched'; end if;
  if not (private.can('delivery.dispatch') or d.rider_staff_id = auth.uid()) then
    raise exception 'permission_denied: delivery.dispatch' using errcode = '42501';
  end if;
  if p_status = 'failed' and length(btrim(coalesce(p_reason, ''))) < 3 then raise exception 'reason_required'; end if;
  if p_status in ('on_the_way', 'delivered') and d.courier is null then raise exception 'assign_first'; end if;

  update public.deliveries
     set status = p_status,
         picked_up_at = case when p_status = 'on_the_way' then coalesce(picked_up_at, now()) else picked_up_at end,
         delivered_at = case when p_status = 'delivered' then now() else delivered_at end,
         fail_reason = case when p_status = 'failed' then left(btrim(p_reason), 300) end,
         updated_by = auth.uid(), updated_at = now()
   where order_id = o.id;

  -- The order itself follows: on the way = served, delivered = completed.
  if p_status = 'on_the_way' and o.status in ('pending', 'confirmed', 'preparing', 'ready') then
    update public.orders set status = 'served', served_at = coalesce(served_at, now()) where id = o.id;
  elsif p_status = 'delivered' and o.status not in ('completed', 'cancelled') then
    update public.orders set status = 'completed', completed_at = now(),
           served_at = coalesce(served_at, now()) where id = o.id;
  end if;
end $$;

-- What the customer sees on their tracking page.
create or replace function public.track_delivery(p_order_number text, p_token uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare o public.orders%rowtype; d public.deliveries%rowtype; z public.delivery_zones%rowtype;
begin
  perform private.rate_limit('track_delivery', 60, interval '10 minutes');
  select * into o from public.orders where order_number = left(p_order_number, 40) and track_token = p_token;
  if not found or o.order_type <> 'delivery' then return null; end if;
  select * into d from public.deliveries where order_id = o.id;
  select * into z from public.delivery_zones where id = o.delivery_zone_id;
  return jsonb_build_object(
    'status', coalesce(d.status, 'waiting'),
    'courier', d.courier,
    'rider', split_part(coalesce(d.rider_name, ''), ' ', 1),
    'tracking_url', d.tracking_url,
    'zone', z.name, 'eta_minutes', z.eta_minutes, 'fee', o.delivery_fee,
    'on_the_way_at', d.picked_up_at, 'delivered_at', d.delivered_at);
end $$;

revoke all on function public.set_delivery_fee(uuid, uuid, numeric, text) from public, anon;
revoke all on function public.delivery_assign(uuid, text, uuid, text, text, text, numeric, text) from public, anon;
revoke all on function public.delivery_update(uuid, text, text) from public, anon;
revoke all on function public.track_delivery(text, uuid) from public;
grant execute on function public.set_delivery_fee(uuid, uuid, numeric, text) to authenticated;
grant execute on function public.delivery_assign(uuid, text, uuid, text, text, text, numeric, text) to authenticated;
grant execute on function public.delivery_update(uuid, text, text) to authenticated;
grant execute on function public.track_delivery(text, uuid) to anon, authenticated;
