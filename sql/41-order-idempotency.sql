-- ═══════════════════════════════════════════════════════════════
-- 41 · Order idempotency: a retry can't place a second order
--
-- Problem  The connection drops after submit_order() saved the order but
--          before the reply arrives. The customer taps Place Order again
--          and a second order is created.
-- Key      The browser makes one random key per checkout attempt
--          (crypto.randomUUID) and sends it as p_client_key. It is kept
--          in the tab's checkout state, so a refresh reuses it.
-- Stored   orders.client_key (unique) for an order this call opened, and
--          order_items.client_key on every line it added, which also
--          covers a round appended to a table's open bill.
-- Repeat   A call with a key already used in this branch inserts nothing
--          and returns the original order in the same jsonb shape.
-- Rules    Server pricing, the rate limit and the grants are unchanged.
--          The key is checked after the rate limit and the branch checks.
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

alter table public.orders      add column if not exists client_key text;
alter table public.order_items add column if not exists client_key text;
create unique index if not exists orders_client_key_uniq on public.orders (client_key) where client_key is not null;
create index if not exists order_items_client_key_idx on public.order_items (client_key) where client_key is not null;

-- The reply submit_order() gives, rebuilt for an order that already exists.
create or replace function private.submit_order_reply(p_order_id uuid, p_appended boolean, p_device text)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select jsonb_build_object(
    'id', o.id, 'order_number', o.order_number, 'track_token', o.track_token,
    'joined_existing', p_appended,
    'device_flagged', coalesce((select d.is_flagged from public.customer_devices d where d.device_id = p_device), false),
    'total', o.total, 'subtotal', o.subtotal,
    'delivery_fee', case when p_appended then 0 else coalesce(o.delivery_fee, 0) end)
    from public.orders o where o.id = p_order_id
$$;
revoke all on function private.submit_order_reply(uuid, boolean, text) from public, anon, authenticated;

-- New signature (adds p_client_key). Drop the old one so a call by name is
-- never ambiguous.
drop function if exists public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid);
create or replace function public.submit_order(
  p_branch_id uuid, p_order_type text, p_items jsonb,
  p_table_id uuid default null, p_customer_name text default null,
  p_customer_phone text default null, p_notes text default null,
  p_payment_method text default null, p_delivery_address text default null,
  p_scheduled_for timestamptz default null, p_device_id text default null,
  p_join_table_bill boolean default true, p_source text default null,
  p_delivery_zone_id uuid default null, p_client_key text default null)
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
  v_key      text := nullif(btrim(coalesce(p_client_key, '')), '');
  v_found    uuid; v_con text;
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

  -- Idempotency (sql/41): a key this branch has seen means this is a retry.
  -- Answer with the original order before validating anything else, so a
  -- dish that sold out in between can't turn a retry into an error.
  if v_key is not null then
    if v_key !~ '^[A-Za-z0-9-]{16,64}$' then
      raise exception 'bad_client_key' using errcode = '22023';
    end if;
    select o.id into v_found from public.orders o where o.client_key = v_key and o.branch_id = p_branch_id;
    if v_found is not null then return private.submit_order_reply(v_found, false, v_device); end if;
    select oi.order_id into v_found from public.order_items oi
      join public.orders o on o.id = oi.order_id and o.branch_id = p_branch_id
     where oi.client_key = v_key limit 1;
    if v_found is not null then return private.submit_order_reply(v_found, true, v_device); end if;
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
    -- Two copies of one round racing: the second waits on the lock above,
    -- then sees the first one's lines here.
    if v_appended and v_key is not null
       and exists (select 1 from public.order_items oi where oi.order_id = v_order_id and oi.client_key = v_key) then
      return private.submit_order_reply(v_order_id, true, v_device);
    end if;
  end if;

  if v_order_id is null then
    -- Two copies of one order racing: the unique index makes the second
    -- wait for the first, then fail here, and it answers with the first.
    begin
      insert into public.orders (branch_id, table_id, order_type, customer_name, customer_phone,
        subtotal, total, payment_method, notes, delivery_address, scheduled_for, source,
        delivery_zone_id, delivery_fee, client_key)
      values (p_branch_id, p_table_id, p_order_type::public.order_type_enum, v_name, v_phone, 0, 0,
        nullif(btrim(coalesce(p_payment_method, '')), '')::public.payment_method,
        v_notes, v_address, p_scheduled_for, v_source, v_zone.id, v_fee, v_key)
      returning id into v_order_id;
    exception when unique_violation then
      get stacked diagnostics v_con = constraint_name;
      if v_con is distinct from 'orders_client_key_uniq' then raise; end if;
      select o.id into v_found from public.orders o where o.client_key = v_key and o.branch_id = p_branch_id;
      if v_found is null then raise exception 'client_key_in_use' using errcode = '22023'; end if;
      return private.submit_order_reply(v_found, false, v_device);
    end;
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
      quantity, pax_size, unit_price, total_price, notes, guest_name, device_id, modifiers, client_key)
    values (v_order_id, (v_item->>'menu_item_id')::uuid, v_item->>'name', v_price,
      v_qty, v_item->>'pax_size', v_price, v_price * v_qty, v_item->>'notes', v_name, v_device,
      coalesce(v_item->'modifiers', '[]'::jsonb), v_key);
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
revoke all on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid, text) from public;
grant execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid, text) to anon, authenticated;

comment on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text, uuid, text) is
  'The one door for orders (web, QR, counter). Prices on the server. p_client_key makes a retry return the original order instead of a second one (sql/41).';
