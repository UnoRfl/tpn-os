-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 24: customers order through a function, not the tables
--
-- THE BUG THIS FIXES
-- "Could not send order: permission denied for table order_items."
--
-- `anon` holds INSERT on orders and order_items but NOT SELECT. The client
-- did `.insert(...).select().single()`, and PostgREST asks for the inserted
-- row back — which needs SELECT. The write was fine; the read-back was
-- refused. Migration 18 fixed the RLS policy and was verified by testing
-- the INSERT in isolation, which is exactly why this survived that pass:
-- the failure is in the read-back, not the write. Test the round trip.
--
-- WHY NOT JUST `grant select on orders to anon`
-- Because orders_anon_read is `using (true)`. Granting SELECT would let any
-- anonymous visitor list every order in the business, with customer names,
-- phone numbers and delivery addresses. Customers are anonymous by
-- architecture here (see sql/05 and the signups-off note in README) and
-- that has to hold.
--
-- So anon gets no table read at all, and two functions instead:
--   submit_order()  create or extend an order, return its number
--   track_order()   read back exactly one order, by its full number
--
-- SHARED TABLE SESSIONS
-- Several people at one table each scan the QR and should land on the SAME
-- bill. submit_order() looks for an order already open on that table and
-- appends to it. Every line records who added it and from which device, so
-- the floor can see who ordered what — and so splitting later is a grouping
-- rather than a guess.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

alter table public.order_items add column if not exists guest_name text;
alter table public.order_items add column if not exists device_id  text;

comment on column public.order_items.device_id is
  'Opaque per-browser id from the QR menu. Lets one table bill be grouped by
   phone. NOT a device fingerprint — it is a random id the browser generated
   and stored for itself, and it is not a secret.';

create index if not exists idx_order_items_device on public.order_items(order_id, device_id);


create or replace function public.submit_order(
  p_branch_id        uuid,
  p_order_type       text,
  p_items            jsonb,
  p_table_id         uuid    default null,
  p_customer_name    text    default null,
  p_customer_phone   text    default null,
  p_notes            text    default null,
  p_payment_method   text    default null,
  p_delivery_address text    default null,
  p_scheduled_for    timestamptz default null,
  p_device_id        text    default null,
  p_join_table_bill  boolean default true
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order_id uuid;
  v_number   text;
  v_item     jsonb;
  v_appended boolean := false;
  v_qty      int;
  v_price    numeric;
begin
  if p_items is null or jsonb_typeof(p_items) <> 'array' or jsonb_array_length(p_items) = 0 then
    raise exception 'no_items: an order needs at least one line' using errcode = '22023';
  end if;
  if p_order_type not in ('dine_in','pickup','delivery') then
    raise exception 'bad_order_type: %', p_order_type using errcode = '22023';
  end if;
  if p_order_type = 'delivery' and coalesce(btrim(p_delivery_address), '') = '' then
    raise exception 'delivery_needs_address' using errcode = '22023';
  end if;

  -- A tampered QR must not be able to attach an order to another branch.
  if p_table_id is not null and not exists (
       select 1 from public.restaurant_tables t
        where t.id = p_table_id and t.branch_id = p_branch_id) then
    raise exception 'table_not_in_branch' using errcode = '22023';
  end if;

  -- Shared table session: reuse the bill already open on this table.
  if p_order_type = 'dine_in' and p_table_id is not null and p_join_table_bill then
    select id into v_order_id
      from public.orders
     where table_id = p_table_id
       and order_type = 'dine_in'
       and status not in ('completed','cancelled')
       and payment_status <> 'paid'
     order by placed_at
     limit 1;
    v_appended := v_order_id is not null;
  end if;

  if v_order_id is null then
    insert into public.orders (
      branch_id, table_id, order_type, customer_name, customer_phone,
      subtotal, total, payment_method, notes, delivery_address, scheduled_for
    ) values (
      p_branch_id, p_table_id, p_order_type::public.order_type_enum,
      nullif(btrim(coalesce(p_customer_name,'')), ''),
      nullif(btrim(coalesce(p_customer_phone,'')), ''),
      0, 0,
      nullif(btrim(coalesce(p_payment_method,'')), '')::public.payment_method,
      nullif(btrim(coalesce(p_notes,'')), ''),
      nullif(btrim(coalesce(p_delivery_address,'')), ''),
      p_scheduled_for
    ) returning id into v_order_id;
  elsif coalesce(btrim(p_notes), '') <> '' then
    -- A later guest's special request must not overwrite the first one.
    update public.orders
       set notes = concat_ws(E'\n', nullif(notes, ''), btrim(p_notes))
     where id = v_order_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty   := greatest(1, coalesce((v_item->>'quantity')::int, 1));
    v_price := coalesce((v_item->>'unit_price')::numeric, 0);
    if v_price < 0 then
      raise exception 'negative_price' using errcode = '22023';
    end if;
    insert into public.order_items (
      order_id, menu_item_id, name_snapshot, price_snapshot,
      quantity, pax_size, unit_price, total_price, notes, guest_name, device_id
    ) values (
      v_order_id,
      nullif(v_item->>'menu_item_id','')::uuid,
      coalesce(nullif(btrim(coalesce(v_item->>'name','')), ''), 'Item'),
      v_price, v_qty,
      nullif(btrim(coalesce(v_item->>'pax_size','')), ''),
      v_price, v_price * v_qty,
      nullif(btrim(coalesce(v_item->>'notes','')), ''),
      nullif(btrim(coalesce(p_customer_name,'')), ''),
      nullif(btrim(coalesce(p_device_id,'')), '')
    );
  end loop;

  -- trg_order_items_recompute has already derived subtotal/total.
  select order_number into v_number from public.orders where id = v_order_id;

  return jsonb_build_object(
    'id', v_order_id, 'order_number', v_number,
    'joined_existing', v_appended,
    'total',    (select total    from public.orders where id = v_order_id),
    'subtotal', (select subtotal from public.orders where id = v_order_id)
  );
end $$;

comment on function public.submit_order is
  'The only path a customer has to create an order. SECURITY DEFINER so anon
   needs no table privileges. Appends to an open dine-in bill on the same
   table so several phones at one table share one bill.';


create or replace function public.track_order(p_order_number text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_row jsonb;
begin
  if coalesce(btrim(p_order_number), '') = '' then return null; end if;
  select jsonb_build_object(
           'id', o.id, 'order_number', o.order_number, 'status', o.status,
           'order_type', o.order_type, 'payment_status', o.payment_status,
           'placed_at', o.placed_at, 'ready_at', o.ready_at, 'served_at', o.served_at,
           'subtotal', o.subtotal, 'discount_amount', o.discount_amount, 'total', o.total,
           'customer_name', o.customer_name, 'table_number', t.table_number, 'notes', o.notes,
           'items', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'name', i.name_snapshot, 'quantity', i.quantity,
                      'pax_size', i.pax_size, 'unit_price', i.unit_price,
                      'total', i.total_price, 'notes', i.notes,
                      'guest', i.guest_name, 'device_id', i.device_id,
                      'voided', (i.voided_at is not null))
                    order by i.created_at)
               from public.order_items i where i.order_id = o.id), '[]'::jsonb))
    into v_row
    from public.orders o
    left join public.restaurant_tables t on t.id = o.table_id
   where upper(o.order_number) = upper(btrim(p_order_number));
  return v_row;
end $$;

comment on function public.track_order is
  'Anonymous order tracking. Keyed on the FULL order_number and returns exactly
   one order — no listing, no enumeration, and no phone number or delivery
   address in the payload.';


-- ── Splitting a shared table bill ─────────────────────────────
-- Deliberately staff-gated. device_id travels in the payload and is not a
-- secret, so if a guest could split by passing an id they could move
-- somebody else's food onto a separate bill. A guest asks; staff performs.
create or replace function public.split_order_by_device(p_order_id uuid, p_device_id text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_src public.orders; v_new uuid; v_moved int;
begin
  if not private.can('orders.manage') then
    raise exception 'permission_denied: orders.manage' using errcode = '42501';
  end if;
  select * into v_src from public.orders where id = p_order_id;
  if v_src.id is null then raise exception 'order_not_found' using errcode = '22023'; end if;
  if v_src.status in ('completed','cancelled') or v_src.payment_status = 'paid' then
    raise exception 'order_already_closed' using errcode = '22023';
  end if;

  select count(*) into v_moved from public.order_items
   where order_id = p_order_id
     and coalesce(device_id,'') = coalesce(p_device_id,'') and voided_at is null;
  if v_moved = 0 then
    raise exception 'nothing_to_split: that phone has no open lines on this bill'
      using errcode = '22023';
  end if;
  if v_moved = (select count(*) from public.order_items
                 where order_id = p_order_id and voided_at is null) then
    raise exception 'split_would_empty_original: every open line belongs to that phone'
      using errcode = '22023';
  end if;

  insert into public.orders (branch_id, table_id, order_type, customer_name,
                             customer_phone, subtotal, total, payment_method, notes)
  values (v_src.branch_id, v_src.table_id, v_src.order_type,
    coalesce((select guest_name from public.order_items
               where order_id = p_order_id
                 and coalesce(device_id,'') = coalesce(p_device_id,'')
                 and guest_name is not null limit 1), v_src.customer_name),
    v_src.customer_phone, 0, 0, v_src.payment_method,
    'Split from ' || v_src.order_number)
  returning id into v_new;

  update public.order_items set order_id = v_new
   where order_id = p_order_id
     and coalesce(device_id,'') = coalesce(p_device_id,'') and voided_at is null;

  -- The source's rows LEFT rather than changed, so it needs an explicit
  -- recompute; the destination gets one from the UPDATE trigger anyway.
  perform private.recompute_order_totals(p_order_id);
  perform private.recompute_order_totals(v_new);

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'order.split', 'order', p_order_id,
          jsonb_build_object('new_order', v_new, 'device_id', p_device_id, 'lines_moved', v_moved));

  return jsonb_build_object('new_order_id', v_new,
    'new_order_number', (select order_number from public.orders where id = v_new),
    'lines_moved', v_moved,
    'original_total', (select total from public.orders where id = p_order_id),
    'new_total', (select total from public.orders where id = v_new));
end $$;


-- One table's open bill, grouped by phone — what the floor panel needs.
create or replace function public.table_bill(p_table_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_out jsonb;
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
  into v_out
  from public.orders o
  where o.table_id = p_table_id and o.order_type = 'dine_in'
    and o.status not in ('completed','cancelled') and o.payment_status <> 'paid'
  order by o.placed_at limit 1;
  return v_out;
end $$;


-- ── Grants ────────────────────────────────────────────────────
-- NOTE: `revoke ... from anon` alone is NOT enough — Postgres grants EXECUTE
-- to PUBLIC by default and Supabase grants it to anon directly. Revoke both.
-- See sql/23 for the full write-up of that trap.
revoke execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean) from public;
revoke execute on function public.track_order(text) from public;
grant  execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean) to anon, authenticated;
grant  execute on function public.track_order(text) to anon, authenticated;

revoke execute on function public.split_order_by_device(uuid, text) from public, anon;
revoke execute on function public.table_bill(uuid) from public, anon;
grant  execute on function public.split_order_by_device(uuid, text) to authenticated;
grant  execute on function public.table_bill(uuid) to authenticated;
