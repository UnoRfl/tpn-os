-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 27: returning-guest memory
--
-- WHAT THIS IS
-- The QR menu and the delivery checkout both send a device_id -- a random
-- value the browser generated and stored for itself. That is enough to
-- know "this phone has ordered 7 times, usually the Kare-Kare, and once
-- never collected". It carries across shifts, so whoever is on tonight
-- sees what the regular server would already know.
--
-- WHAT THIS IS NOT
-- Not a fingerprint, not tracking, not an identity. It is a value the
-- guest can clear, and clearing it makes them a new guest -- which is the
-- correct trade. Nothing here is used to price differently, and the flag
-- is a note about behaviour, not a credit score.
--
-- PRIVACY LINES, drawn deliberately:
--   staff only        phone, staff notes, flags, no-show count
--   guest's own device first name, visit count, their usuals
--   anon              cannot read the tables at all -- one function,
--                     scoped to the device id it already has, returning
--                     no phone and no flags
--
-- TWO HONEST LIMITS, worth repeating wherever this is surfaced:
--   * clearing the browser resets the guest
--   * one phone can be several people, which is why known_names keeps
--     every name used instead of overwriting
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.customer_devices (
  device_id      text primary key,
  branch_id      uuid references public.branches(id) on delete set null,
  first_seen_at  timestamptz not null default now(),
  last_seen_at   timestamptz not null default now(),
  order_count    int      not null default 0,
  lifetime_spend numeric(12,2) not null default 0,
  last_order_at  timestamptz,
  last_name      text,
  last_phone     text,
  known_names    text[]   not null default '{}',
  -- staff judgement
  no_show_count  int      not null default 0,
  is_flagged     boolean  not null default false,
  flag_reason    text,
  flagged_by     uuid references public.staff(id) on delete set null,
  flagged_at     timestamptz,
  staff_note     text,
  updated_at     timestamptz default now()
);
create index if not exists idx_cust_dev_last  on public.customer_devices(last_order_at desc nulls last);
create index if not exists idx_cust_dev_phone on public.customer_devices(last_phone) where last_phone is not null;
create index if not exists idx_cust_dev_flag  on public.customer_devices(is_flagged) where is_flagged;

comment on table public.customer_devices is
  'One row per guest browser. device_id is a random value the browser stores
   for itself -- clearable, and clearing it simply makes them a new guest.';

create table if not exists public.customer_device_items (
  device_id       text not null references public.customer_devices(device_id) on delete cascade,
  item_name       text not null,
  menu_item_id    uuid references public.menu_items(id) on delete set null,
  times_ordered   int  not null default 0,
  total_qty       int  not null default 0,
  last_ordered_at timestamptz,
  primary key (device_id, item_name)
);
create index if not exists idx_cust_items_dev on public.customer_device_items(device_id, times_ordered desc);


-- Called from submit_order(), so the memory fills itself from ordinary
-- ordering rather than needing a call the client could forget to make.
create or replace function private.remember_device(
  p_device text, p_branch uuid, p_name text, p_phone text,
  p_order_total numeric, p_items jsonb)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_item jsonb;
begin
  if coalesce(btrim(p_device), '') = '' then return; end if;

  insert into public.customer_devices
    (device_id, branch_id, last_name, last_phone, order_count,
     lifetime_spend, last_order_at, known_names, last_seen_at)
  values
    (p_device, p_branch, nullif(btrim(coalesce(p_name,'')),''),
     nullif(btrim(coalesce(p_phone,'')),''), 1,
     coalesce(p_order_total, 0), now(),
     case when coalesce(btrim(coalesce(p_name,'')),'') = '' then '{}'::text[]
          else array[btrim(p_name)] end,
     now())
  on conflict (device_id) do update set
    order_count    = public.customer_devices.order_count + 1,
    lifetime_spend = public.customer_devices.lifetime_spend + coalesce(p_order_total, 0),
    last_order_at  = now(),
    last_seen_at   = now(),
    last_name      = coalesce(nullif(btrim(coalesce(p_name,'')),''),  public.customer_devices.last_name),
    last_phone     = coalesce(nullif(btrim(coalesce(p_phone,'')),''), public.customer_devices.last_phone),
    branch_id      = coalesce(public.customer_devices.branch_id, p_branch),
    -- keep every name this phone has used; people order for other people
    known_names    = case
                       when coalesce(btrim(coalesce(p_name,'')),'') = '' then public.customer_devices.known_names
                       when btrim(p_name) = any(public.customer_devices.known_names) then public.customer_devices.known_names
                       else public.customer_devices.known_names || btrim(p_name)
                     end,
    updated_at     = now();

  for v_item in select * from jsonb_array_elements(coalesce(p_items, '[]'::jsonb)) loop
    insert into public.customer_device_items
      (device_id, item_name, menu_item_id, times_ordered, total_qty, last_ordered_at)
    values
      (p_device,
       coalesce(nullif(btrim(coalesce(v_item->>'name','')),''), 'Item'),
       nullif(v_item->>'menu_item_id','')::uuid,
       1, greatest(1, coalesce((v_item->>'quantity')::int, 1)), now())
    on conflict (device_id, item_name) do update set
      times_ordered   = public.customer_device_items.times_ordered + 1,
      total_qty       = public.customer_device_items.total_qty
                        + greatest(1, coalesce((v_item->>'quantity')::int, 1)),
      last_ordered_at = now(),
      menu_item_id    = coalesce(public.customer_device_items.menu_item_id,
                                 nullif(v_item->>'menu_item_id','')::uuid);
  end loop;
end $$;

-- NOTE: submit_order() in sql/24 is redefined at the end of this file to
-- call remember_device(). Keep the two in step.


-- ── Staff view: phone, flags and no-shows included ───────────
create or replace function public.guest_profile(p_device text, p_phone text default null)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb; v_dev text := nullif(btrim(coalesce(p_device,'')),'');
begin
  if not private.can('orders.view') then
    raise exception 'permission_denied: orders.view' using errcode = '42501';
  end if;
  -- Same person, new browser: fall back to the phone number.
  if v_dev is null and coalesce(btrim(coalesce(p_phone,'')),'') <> '' then
    select device_id into v_dev from public.customer_devices
     where last_phone = btrim(p_phone) order by last_order_at desc nulls last limit 1;
  end if;
  if v_dev is null then return null; end if;

  select jsonb_build_object(
      'device_id', d.device_id, 'is_returning', d.order_count > 1,
      'order_count', d.order_count, 'lifetime_spend', d.lifetime_spend,
      'avg_spend', case when d.order_count > 0 then round(d.lifetime_spend / d.order_count, 2) else 0 end,
      'first_seen_at', d.first_seen_at, 'last_order_at', d.last_order_at,
      'name', d.last_name, 'known_names', to_jsonb(d.known_names), 'phone', d.last_phone,
      'no_show_count', d.no_show_count, 'is_flagged', d.is_flagged,
      'flag_reason', d.flag_reason, 'staff_note', d.staff_note,
      'usuals', coalesce((
        select jsonb_agg(jsonb_build_object('name', i.item_name, 'times', i.times_ordered,
                 'qty', i.total_qty, 'last', i.last_ordered_at)
               order by i.times_ordered desc, i.last_ordered_at desc)
          from (select * from public.customer_device_items
                 where device_id = d.device_id order by times_ordered desc limit 5) i), '[]'::jsonb))
    into v from public.customer_devices d where d.device_id = v_dev;
  return v;
end $$;


-- ── The guest's own device: no phone, no flags, no spend ─────
create or replace function public.my_guest_profile(p_device text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v jsonb;
begin
  if coalesce(btrim(coalesce(p_device,'')),'') = '' then return null; end if;
  select jsonb_build_object(
      'is_returning', d.order_count > 1, 'order_count', d.order_count, 'name', d.last_name,
      'usuals', coalesce((
        select jsonb_agg(jsonb_build_object('name', i.item_name, 'times', i.times_ordered)
               order by i.times_ordered desc)
          from (select * from public.customer_device_items
                 where device_id = d.device_id order by times_ordered desc limit 3) i), '[]'::jsonb))
    into v from public.customer_devices d where d.device_id = btrim(p_device);
  return v;   -- null on a first visit
end $$;

comment on function public.my_guest_profile is
  'Powers "Welcome back, Maria" on the guest''s own device. Returns no phone,
   no flags and no spend -- someone who guessed another device id would learn
   a first name and a favourite dish, nothing more.';


-- ── Staff judgement ──────────────────────────────────────────
create or replace function public.flag_guest_device(
  p_device text, p_reason text, p_no_show boolean default false)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.can('orders.manage') then
    raise exception 'permission_denied: orders.manage' using errcode = '42501';
  end if;
  update public.customer_devices
     set is_flagged = true,
         flag_reason = nullif(btrim(coalesce(p_reason,'')),''),
         flagged_by = auth.uid(), flagged_at = now(),
         no_show_count = no_show_count + case when p_no_show then 1 else 0 end,
         updated_at = now()
   where device_id = p_device;
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'guest.flag', 'customer_device', null,
          jsonb_build_object('device_id', p_device, 'reason', p_reason, 'no_show', p_no_show));
end $$;

create or replace function public.unflag_guest_device(p_device text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.can('orders.manage') then
    raise exception 'permission_denied: orders.manage' using errcode = '42501';
  end if;
  update public.customer_devices
     set is_flagged = false, flag_reason = null, flagged_by = null,
         flagged_at = null, updated_at = now()
   where device_id = p_device;
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'guest.unflag', 'customer_device', null,
          jsonb_build_object('device_id', p_device));
end $$;

create or replace function public.set_guest_note(p_device text, p_note text)
returns void language plpgsql security definer set search_path = '' as $$
begin
  if not private.can('orders.manage') then
    raise exception 'permission_denied: orders.manage' using errcode = '42501';
  end if;
  update public.customer_devices
     set staff_note = nullif(btrim(coalesce(p_note,'')),''), updated_at = now()
   where device_id = p_device;
end $$;


-- ── The Guests tab list ──────────────────────────────────────
create or replace function public.guest_list(
  p_search text default null, p_flagged_only boolean default false, p_limit int default 100)
returns table (
  device_id text, name text, phone text, order_count int,
  lifetime_spend numeric, avg_spend numeric, last_order_at timestamptz,
  first_seen_at timestamptz, no_show_count int, is_flagged boolean,
  flag_reason text, staff_note text, usual text)
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.can('orders.view') then
    raise exception 'permission_denied: orders.view' using errcode = '42501';
  end if;
  return query
    select d.device_id, d.last_name, d.last_phone, d.order_count, d.lifetime_spend,
           case when d.order_count > 0 then round(d.lifetime_spend / d.order_count, 2) else 0 end,
           d.last_order_at, d.first_seen_at, d.no_show_count, d.is_flagged,
           d.flag_reason, d.staff_note,
           (select i.item_name from public.customer_device_items i
             where i.device_id = d.device_id
             order by i.times_ordered desc, i.last_ordered_at desc limit 1)
      from public.customer_devices d
     where (not p_flagged_only or d.is_flagged)
       and (coalesce(btrim(coalesce(p_search,'')),'') = ''
            or d.last_name  ilike '%' || btrim(p_search) || '%'
            or d.last_phone ilike '%' || btrim(p_search) || '%'
            or d.device_id  ilike '%' || btrim(p_search) || '%')
     order by d.is_flagged desc, d.last_order_at desc nulls last
     limit greatest(1, least(coalesce(p_limit, 100), 500));
end $$;


-- ── RLS + grants ─────────────────────────────────────────────
alter table public.customer_devices      enable row level security;
alter table public.customer_device_items enable row level security;

drop policy if exists cd_read on public.customer_devices;
create policy cd_read on public.customer_devices for select to authenticated
  using (private.can('orders.view'));
drop policy if exists cd_write on public.customer_devices;
create policy cd_write on public.customer_devices for update to authenticated
  using (private.can('orders.manage')) with check (private.can('orders.manage'));
drop policy if exists cdi_read on public.customer_device_items;
create policy cdi_read on public.customer_device_items for select to authenticated
  using (private.can('orders.view'));

grant select, update on public.customer_devices      to authenticated;
grant select         on public.customer_device_items to authenticated;
revoke all on public.customer_devices      from anon;
revoke all on public.customer_device_items from anon;

-- Remember: `revoke ... from anon` alone does not close a function. See sql/23.
revoke execute on function private.remember_device(text, uuid, text, text, numeric, jsonb) from public, anon, authenticated;
revoke execute on function public.guest_profile(text, text)              from public, anon;
revoke execute on function public.guest_list(text, boolean, int)         from public, anon;
revoke execute on function public.flag_guest_device(text, text, boolean) from public, anon;
revoke execute on function public.unflag_guest_device(text)              from public, anon;
revoke execute on function public.set_guest_note(text, text)             from public, anon;
revoke execute on function public.my_guest_profile(text)                 from public;

grant execute on function public.guest_profile(text, text)              to authenticated;
grant execute on function public.guest_list(text, boolean, int)         to authenticated;
grant execute on function public.flag_guest_device(text, text, boolean) to authenticated;
grant execute on function public.unflag_guest_device(text)              to authenticated;
grant execute on function public.set_guest_note(text, text)             to authenticated;
grant execute on function public.my_guest_profile(text)                 to anon, authenticated;

-- ── submit_order() now records the visit ─────────────────────
-- Identical to sql/24 apart from the remember_device() call and the
-- device_flagged flag in the return value. Kept here rather than editing
-- sql/24 so the migrations stay append-only and replay in order.
create or replace function public.submit_order(
  p_branch_id uuid, p_order_type text, p_items jsonb,
  p_table_id uuid default null, p_customer_name text default null,
  p_customer_phone text default null, p_notes text default null,
  p_payment_method text default null, p_delivery_address text default null,
  p_scheduled_for timestamptz default null, p_device_id text default null,
  p_join_table_bill boolean default true)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare
  v_order_id uuid; v_number text; v_item jsonb;
  v_appended boolean := false; v_qty int; v_price numeric;
  v_batch numeric := 0; v_flagged boolean := false;
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
  if p_table_id is not null and not exists (
       select 1 from public.restaurant_tables t
        where t.id = p_table_id and t.branch_id = p_branch_id) then
    raise exception 'table_not_in_branch' using errcode = '22023';
  end if;

  if p_order_type = 'dine_in' and p_table_id is not null and p_join_table_bill then
    select id into v_order_id from public.orders
     where table_id = p_table_id and order_type = 'dine_in'
       and status not in ('completed','cancelled') and payment_status <> 'paid'
     order by placed_at limit 1;
    v_appended := v_order_id is not null;
  end if;

  if v_order_id is null then
    insert into public.orders (
      branch_id, table_id, order_type, customer_name, customer_phone,
      subtotal, total, payment_method, notes, delivery_address, scheduled_for)
    values (
      p_branch_id, p_table_id, p_order_type::public.order_type_enum,
      nullif(btrim(coalesce(p_customer_name,'')), ''),
      nullif(btrim(coalesce(p_customer_phone,'')), ''), 0, 0,
      nullif(btrim(coalesce(p_payment_method,'')), '')::public.payment_method,
      nullif(btrim(coalesce(p_notes,'')), ''),
      nullif(btrim(coalesce(p_delivery_address,'')), ''), p_scheduled_for)
    returning id into v_order_id;
  elsif coalesce(btrim(p_notes), '') <> '' then
    update public.orders set notes = concat_ws(E'\n', nullif(notes, ''), btrim(p_notes))
     where id = v_order_id;
  end if;

  for v_item in select * from jsonb_array_elements(p_items) loop
    v_qty   := greatest(1, coalesce((v_item->>'quantity')::int, 1));
    v_price := coalesce((v_item->>'unit_price')::numeric, 0);
    if v_price < 0 then raise exception 'negative_price' using errcode = '22023'; end if;
    v_batch := v_batch + (v_price * v_qty);
    insert into public.order_items (
      order_id, menu_item_id, name_snapshot, price_snapshot,
      quantity, pax_size, unit_price, total_price, notes, guest_name, device_id)
    values (
      v_order_id, nullif(v_item->>'menu_item_id','')::uuid,
      coalesce(nullif(btrim(coalesce(v_item->>'name','')), ''), 'Item'),
      v_price, v_qty, nullif(btrim(coalesce(v_item->>'pax_size','')), ''),
      v_price, v_price * v_qty, nullif(btrim(coalesce(v_item->>'notes','')), ''),
      nullif(btrim(coalesce(p_customer_name,'')), ''),
      nullif(btrim(coalesce(p_device_id,'')), ''));
  end loop;

  -- Scored on THIS batch, not the running table total, so a shared bill does
  -- not credit one phone with everyone else's spend.
  perform private.remember_device(p_device_id, p_branch_id, p_customer_name,
                                  p_customer_phone, v_batch, p_items);

  select order_number into v_number from public.orders where id = v_order_id;
  select is_flagged into v_flagged from public.customer_devices
   where device_id = nullif(btrim(coalesce(p_device_id,'')),'');

  return jsonb_build_object('id', v_order_id, 'order_number', v_number,
    'joined_existing', v_appended, 'device_flagged', coalesce(v_flagged, false),
    'total',    (select total    from public.orders where id = v_order_id),
    'subtotal', (select subtotal from public.orders where id = v_order_id));
end $$;

revoke execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean) from public;
grant  execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean) to anon, authenticated;
