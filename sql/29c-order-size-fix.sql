-- ═══════════════════════════════════════════════════════════════
-- 29c · Ordering fix after the security hotfix (Oct 16 2026)
--
-- After 29 priced orders on the server, two page-side mismatches started
-- refusing real orders:
--   - the QR menu sends sizes as "2-3 pax" while pax_options keys are
--     "2-3" → unknown_size;
--   - the website sent no menu_item_id at all → unknown_item (fixed in
--     index.html in the same release).
-- This accepts both size spellings, and prices a line without a size at
-- the menu price (what the website shows), with a listed size at that
-- size's price. Both still come from the database.
-- ═══════════════════════════════════════════════════════════════

-- ── submit_order, as in sql/29 with the size fix ───────────────────────────────
create or replace function public.submit_order(
  p_branch_id uuid, p_order_type text, p_items jsonb,
  p_table_id uuid default null, p_customer_name text default null,
  p_customer_phone text default null, p_notes text default null,
  p_payment_method text default null, p_delivery_address text default null,
  p_scheduled_for timestamptz default null, p_device_id text default null,
  p_join_table_bill boolean default true)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_number   text;
  v_token    uuid;
  v_item     jsonb;
  v_appended boolean := false;
  v_qty      int;
  v_price    numeric;
  v_batch    numeric := 0;
  v_flagged  boolean := false;
  v_mi       public.menu_items%rowtype;
  v_pax      text;
  v_clean    jsonb := '[]'::jsonb;
  v_device   text := private.clean_device_id(p_device_id);
  v_name     text := left(nullif(btrim(coalesce(p_customer_name, '')), ''), 60);
  v_phone    text := left(nullif(regexp_replace(coalesce(p_customer_phone, ''), '[^0-9+]', '', 'g'), ''), 16);
  v_notes    text := left(nullif(btrim(coalesce(p_notes, '')), ''), 500);
  v_address  text := left(nullif(btrim(coalesce(p_delivery_address, '')), ''), 300);
begin
  perform private.rate_limit('submit_order', 20, interval '10 minutes');

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
  if p_table_id is not null and not exists (
       select 1 from public.restaurant_tables t
        where t.id = p_table_id and t.branch_id = p_branch_id and t.is_active) then
    raise exception 'table_not_in_branch' using errcode = '22023';
  end if;
  if p_scheduled_for is not null
     and (p_scheduled_for < now() - interval '5 minutes' or p_scheduled_for > now() + interval '60 days') then
    raise exception 'bad_schedule_time' using errcode = '22023';
  end if;

  -- Price every line from the menu before anything is written, so a bad
  -- line refuses the whole order instead of leaving half of it behind.
  for v_item in select * from jsonb_array_elements(p_items) loop
    begin
      select * into v_mi from public.menu_items
       where id = nullif(v_item->>'menu_item_id', '')::uuid;
    exception when invalid_text_representation then
      raise exception 'unknown_item' using errcode = '22023';
    end;
    if not found then
      raise exception 'unknown_item' using errcode = '22023';
    end if;
    if not coalesce(v_mi.is_available, true) then
      raise exception 'item_sold_out: %', v_mi.name using errcode = '22023';
    end if;

    v_qty := coalesce((v_item->>'quantity')::int, 1);
    if v_qty < 1 or v_qty > 50 then
      raise exception 'bad_quantity: % (1 to 50 per line)', v_mi.name using errcode = '22023';
    end if;

    -- Size: the pages send "2-3" or "2-3 pax"; both mean the same key.
    -- A size that is on the menu gives that size's price; no size gives
    -- the menu price (what the website shows for non-shareable dishes).
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

    v_clean := v_clean || jsonb_build_object(
      'menu_item_id', v_mi.id, 'name', v_mi.name, 'unit_price', v_price,
      'quantity', v_qty, 'pax_size', v_pax,
      'notes', left(nullif(btrim(coalesce(v_item->>'notes', '')), ''), 200));
  end loop;

  if p_order_type = 'dine_in' and p_table_id is not null and p_join_table_bill then
    select id into v_order_id
      from public.orders
     where table_id = p_table_id and order_type = 'dine_in'
       and status not in ('completed', 'cancelled') and payment_status <> 'paid'
     order by placed_at limit 1
     for update;
    v_appended := v_order_id is not null;
  end if;

  if v_order_id is null then
    insert into public.orders (
      branch_id, table_id, order_type, customer_name, customer_phone,
      subtotal, total, payment_method, notes, delivery_address, scheduled_for
    ) values (
      p_branch_id, p_table_id, p_order_type::public.order_type_enum,
      v_name, v_phone, 0, 0,
      nullif(btrim(coalesce(p_payment_method, '')), '')::public.payment_method,
      v_notes, v_address, p_scheduled_for
    ) returning id into v_order_id;
  elsif v_notes is not null then
    update public.orders
       set notes = left(concat_ws(E'\n', nullif(notes, ''), v_notes), 2000)
     where id = v_order_id;
  end if;

  for v_item in select * from jsonb_array_elements(v_clean) loop
    v_qty   := (v_item->>'quantity')::int;
    v_price := (v_item->>'unit_price')::numeric;
    v_batch := v_batch + (v_price * v_qty);
    insert into public.order_items (
      order_id, menu_item_id, name_snapshot, price_snapshot,
      quantity, pax_size, unit_price, total_price, notes, guest_name, device_id
    ) values (
      v_order_id, (v_item->>'menu_item_id')::uuid, v_item->>'name', v_price,
      v_qty, v_item->>'pax_size', v_price, v_price * v_qty,
      v_item->>'notes', v_name, v_device
    );
  end loop;

  perform private.remember_device(v_device, p_branch_id, v_name, v_phone, v_batch, v_clean);

  select order_number, track_token into v_number, v_token from public.orders where id = v_order_id;
  select is_flagged into v_flagged from public.customer_devices where device_id = v_device;

  return jsonb_build_object(
    'id', v_order_id, 'order_number', v_number,
    'track_token', v_token,
    'joined_existing', v_appended,
    'device_flagged', coalesce(v_flagged, false),
    'total',    (select total    from public.orders where id = v_order_id),
    'subtotal', (select subtotal from public.orders where id = v_order_id)
  );
end $$;
revoke all on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean) from public;
grant execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean) to anon, authenticated;

