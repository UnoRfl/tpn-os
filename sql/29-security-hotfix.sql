-- ═══════════════════════════════════════════════════════════════
-- 29 · Security hotfix (Oct 2026 audit)
--
-- Every item below was confirmed against the LIVE database, not just
-- the repo. Safe to run more than once.
--
--  C1  submit_order trusted the browser's unit_price and item name, so a
--      guest could order anything at ₱0. Prices and names now come from
--      menu_items; unknown or sold-out items are refused; quantities and
--      text lengths are capped.
--  C2  anon still had direct INSERT on orders/order_items, SELECT on
--      orders (orders_anon_read using (true)), and could DELETE empty
--      orders. A visitor could list order ids and push lines onto any bill,
--      paid or not. All customer traffic already goes through
--      submit_order/track_order, so the direct grants and policies go.
--  H1  A disabled or pending account kept full database access; only the
--      login screen checked employment_status. my_role(), my_branch() and
--      can() now treat a non-active account as no account.
--  H3  Any staff login (including the wall screens) could message a
--      manager directly, and the inbox rendered it as HTML. The permissive
--      messages_insert policy goes; messages_send (manager+) remains.
--      (The HTML escaping is fixed in index.html.)
--  M1  track_order returned customer name, notes, guest names and device
--      ids to anyone holding a sequential order number. Without the
--      private tracking token issued at checkout it now returns progress
--      only.
--  M2  device_id is now validated, so it cannot carry script into the
--      staff screens' inline handlers.
--  M4  Anonymous endpoints are rate limited per connection and text is
--      length-capped. Inquiries: anon may only fill the contact columns.
-- ═══════════════════════════════════════════════════════════════

create schema if not exists private;

-- ── Schema catch-up: migration 06 never reached production ───
-- The live menu_items table has no emoji / is_featured / featured_tag, so
-- every menu load from the public site failed with 42703 ("column
-- menu_items.is_featured does not exist") and the site fell back to its
-- built-in list. Found while testing this hotfix. Same for one column
-- from 09.
alter table public.menu_items
  add column if not exists emoji text,
  add column if not exists is_featured boolean default false,
  add column if not exists featured_tag text;
alter table public.attendance add column if not exists correction_note text;

-- 06's original backfill, only where nothing has been set.
update public.menu_items set emoji = '🥜', is_featured = true, featured_tag = 'Bestseller'        where name = 'Kare-Kareng Lechon Kawali' and emoji is null;
update public.menu_items set emoji = '🥬', is_featured = true, featured_tag = 'Lutong Bicol'      where name = 'Laing'                     and emoji is null;
update public.menu_items set emoji = '🍲', is_featured = true, featured_tag = 'Customer Favorite' where name = 'Beef Caldereta'            and emoji is null;
update public.menu_items set emoji = '🍳' where name in ('Tapsilog', 'Longsilog') and emoji is null;
update public.menu_items set emoji = '🐟' where name = 'Bangsilog'         and emoji is null;
update public.menu_items set emoji = '🥫' where name = 'Cornsilog'         and emoji is null;
update public.menu_items set emoji = '🍚' where name = 'Unli Rice'         and emoji is null;
update public.menu_items set emoji = '🥣' where name = 'Sinigang na Baboy' and emoji is null;

-- ── Helpers: caller IP + rate limit ──────────────────────────
-- cf-connecting-ip is set by Cloudflare in front of Supabase and replaces
-- whatever the browser sends. x-forwarded-for is a fallback, read from the
-- right (the left-most entry can be typed by the client).
create or replace function private.client_ip()
returns inet
language plpgsql
stable
set search_path = ''
as $$
declare
  h   json := nullif(current_setting('request.headers', true), '')::json;
  raw text;
begin
  if h is null then return null; end if;
  raw := nullif(trim(h->>'cf-connecting-ip'), '');
  if raw is null then
    raw := nullif(trim(regexp_replace(coalesce(h->>'x-forwarded-for', ''), '^.*,', '')), '');
  end if;
  begin
    return raw::inet;
  exception when others then
    return null;
  end;
end $$;
revoke all on function private.client_ip() from public, anon, authenticated;

create table if not exists private.rate_hits (
  bucket text not null,
  ip     inet,
  at     timestamptz not null default now()
);
create index if not exists idx_rate_hits on private.rate_hits (bucket, ip, at desc);

create or replace function private.rate_limit(p_bucket text, p_max int, p_window interval)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_ip inet := private.client_ip();
  v_n  int;
begin
  -- No IP = a direct database call (SQL editor, trigger, test): no limit.
  if v_ip is null then return; end if;
  if random() < 0.02 then
    delete from private.rate_hits where at < now() - interval '1 day';
  end if;
  select count(*) into v_n from private.rate_hits
   where bucket = p_bucket and ip = v_ip and at > now() - p_window;
  if v_n >= p_max then
    raise exception 'too_many_requests'
      using hint = 'Too many attempts from this connection. Please wait a few minutes and try again.',
            errcode = 'P0429';
  end if;
  insert into private.rate_hits (bucket, ip) values (p_bucket, v_ip);
end $$;
revoke all on function private.rate_limit(text, int, interval) from public, anon, authenticated;

-- ── H1: a non-active account is no account ───────────────────
create or replace function private.my_role()
returns public.staff_role
language sql security definer stable
set search_path = ''
as $$
  select role from public.staff
   where id = auth.uid() and coalesce(employment_status, 'active') = 'active'
$$;

create or replace function private.my_branch()
returns uuid
language sql security definer stable
set search_path = ''
as $$
  select branch_id from public.staff
   where id = auth.uid() and coalesce(employment_status, 'active') = 'active'
$$;

-- Same body as sql/19 apart from the status check on the first lookup.
create or replace function private.can(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role_id uuid;
  v_tier    public.staff_role;
  v_allowed boolean;
begin
  select role, access_role_id into v_tier, v_role_id
    from public.staff
   where id = auth.uid() and coalesce(employment_status, 'active') = 'active';

  if v_tier is null then
    return false;
  end if;

  if v_tier = 'ceo' then
    return true;
  end if;

  select allowed into v_allowed
    from public.staff_permission_overrides
   where staff_id = auth.uid() and permission_key = p_key;
  if v_allowed is not null then
    return v_allowed;
  end if;

  if v_role_id is not null then
    select arp.allowed into v_allowed
      from public.access_role_permissions arp
      join public.access_roles r on r.id = arp.role_id
     where arp.role_id = v_role_id
       and arp.permission_key = p_key
       and r.is_active;
    return coalesce(v_allowed, false);
  end if;

  select arp.allowed into v_allowed
    from public.access_role_permissions arp
    join public.access_roles r on r.id = arp.role_id
   where r.key = v_tier::text
     and r.is_system
     and arp.permission_key = p_key;

  return coalesce(v_allowed, false);
end $$;

-- ── M2: device ids are random tokens the browser made, nothing else ──
create or replace function private.clean_device_id(p text)
returns text
language sql immutable
set search_path = ''
as $$
  select case when btrim(coalesce(p, '')) ~ '^[A-Za-z0-9_-]{8,64}$' then btrim(p) end
$$;
revoke all on function private.clean_device_id(text) from public, anon, authenticated;

-- Existing rows: anything that is not a plain token is dropped, so an old
-- crafted value cannot reach a staff screen.
update public.order_items set device_id = null
 where device_id is not null and private.clean_device_id(device_id) is null;
delete from public.customer_device_items
 where private.clean_device_id(device_id) is null;
delete from public.customer_devices
 where private.clean_device_id(device_id) is null;

-- ── M1: private tracking token ───────────────────────────────
alter table public.orders add column if not exists track_token uuid default gen_random_uuid();
update public.orders set track_token = gen_random_uuid() where track_token is null;
revoke select (track_token) on public.orders from anon;

-- ── C1: server-priced ordering ───────────────────────────────
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

    v_pax := nullif(btrim(coalesce(v_item->>'pax_size', '')), '');
    if v_mi.pax_options is not null and jsonb_typeof(v_mi.pax_options) = 'object'
       and v_mi.pax_options <> '{}'::jsonb then
      if v_pax is null then
        -- No size chosen: the first listed size, same as the menu shows.
        select key into v_pax from jsonb_each(v_mi.pax_options) limit 1;
      end if;
      if not (v_mi.pax_options ? v_pax) then
        raise exception 'unknown_size: % (%)', v_mi.name, v_pax using errcode = '22023';
      end if;
      v_price := (v_mi.pax_options->>v_pax)::numeric;
    else
      v_pax := null;
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

-- ── M1: tracking without the token shows progress only ───────
drop function if exists public.track_order(text);
create or replace function public.track_order(p_order_number text, p_token uuid default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_row  jsonb;
  v_full boolean;
  o      public.orders%rowtype;
begin
  if coalesce(btrim(p_order_number), '') = '' then
    return null;
  end if;
  perform private.rate_limit('track_order', 120, interval '10 minutes');

  select * into o from public.orders where upper(order_number) = upper(btrim(p_order_number));
  if not found then return null; end if;
  v_full := p_token is not null and p_token = o.track_token;

  select jsonb_build_object(
           'id',             o.id,
           'order_number',   o.order_number,
           'status',         o.status,
           'order_type',     o.order_type,
           'payment_status', o.payment_status,
           'placed_at',      o.placed_at,
           'ready_at',       o.ready_at,
           'served_at',      o.served_at,
           'subtotal',       case when v_full then o.subtotal end,
           'discount_amount',case when v_full then o.discount_amount end,
           'total',          case when v_full then o.total end,
           'customer_name',  case when v_full then o.customer_name end,
           'table_number',   t.table_number,
           'notes',          case when v_full then o.notes end,
           'full',           v_full,
           'items', coalesce((
             select jsonb_agg(jsonb_build_object(
                      'name',      i.name_snapshot,
                      'quantity',  i.quantity,
                      'pax_size',  i.pax_size,
                      'unit_price',case when v_full then i.unit_price end,
                      'total',     case when v_full then i.total_price end,
                      'notes',     case when v_full then i.notes end,
                      'guest',     case when v_full then i.guest_name end,
                      'voided',    (i.voided_at is not null)
                    ) order by i.created_at)
               from public.order_items i
              where i.order_id = o.id), '[]'::jsonb)
         )
    into v_row
    from (select 1) x
    left join public.restaurant_tables t on t.id = o.table_id;

  return v_row;
end $$;
revoke all on function public.track_order(text, uuid) from public;
grant execute on function public.track_order(text, uuid) to anon, authenticated;

-- my_guest_profile: same validation as the order path.
create or replace function public.my_guest_profile(p_device text)
returns jsonb
language plpgsql
stable security definer
set search_path = ''
as $$
declare v jsonb; v_dev text := private.clean_device_id(p_device);
begin
  if v_dev is null then return null; end if;
  select jsonb_build_object(
      'is_returning', d.order_count > 1,
      'order_count',  d.order_count,
      'name',         d.last_name,
      'usuals', coalesce((
        select jsonb_agg(jsonb_build_object('name', i.item_name, 'times', i.times_ordered)
               order by i.times_ordered desc)
          from (select * from public.customer_device_items
                 where device_id = d.device_id
                 order by times_ordered desc limit 3) i), '[]'::jsonb))
    into v
    from public.customer_devices d
   where d.device_id = v_dev;
  return v;
end $$;

-- ── C2: no direct customer access to the order tables ────────
drop policy if exists orders_anon_create      on public.orders;
drop policy if exists orders_anon_read        on public.orders;
drop policy if exists order_items_anon_insert on public.order_items;
drop policy if exists orders_cleanup_empty    on public.orders;
revoke insert, update, delete, truncate on public.orders      from anon;
revoke insert, update, delete, truncate on public.order_items from anon;
revoke select on public.orders      from anon;
revoke select on public.order_items from anon;

-- order_items_read let anon through `exists (select 1 from orders ...)`.
-- Staff keep it; anon has no orders rows to see any more anyway.
do $$
begin
  if exists (select 1 from pg_policies where schemaname = 'public' and tablename = 'order_items' and policyname = 'order_items_read') then
    alter policy order_items_read on public.order_items to authenticated;
  end if;
end $$;

-- Staff-only cleanup of an order left with no lines.
create policy orders_cleanup_empty on public.orders for delete to authenticated
  using (
    private.has_role('dining')
    and (branch_id = private.my_branch() or private.has_role('admin'))
    and not exists (select 1 from public.order_items oi where oi.order_id = orders.id)
  );

-- ── H3: only managers start a direct message ─────────────────
drop policy if exists messages_insert on public.messages;

-- ── M4: inquiries — contact columns only, capped, rate limited ──
revoke insert on public.inquiries from anon;
grant insert (id, inquiry_type, branch_id, contact_name, contact_phone, contact_email,
              organization, message, event_date, expected_pax)
  on public.inquiries to anon;
revoke update, delete, truncate on public.inquiries from anon;

create or replace function public.trg_inquiry_guard()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if auth.uid() is null then
    perform private.rate_limit('inquiry', 5, interval '30 minutes');
    new.status := 'pending';
    new.assigned_to := null;
    new.resolution_notes := null;
    new.resolved_at := null;
  end if;
  new.contact_name  := left(btrim(new.contact_name), 80);
  new.contact_phone := left(btrim(new.contact_phone), 20);
  new.contact_email := left(btrim(new.contact_email), 120);
  new.organization  := left(btrim(new.organization), 120);
  new.message       := left(new.message, 3000);
  if new.expected_pax is not null and (new.expected_pax < 1 or new.expected_pax > 5000) then
    raise exception 'bad_pax' using errcode = '22023';
  end if;
  return new;
end $$;
revoke all on function public.trg_inquiry_guard() from public, anon, authenticated;
drop trigger if exists trg_inquiry_guard on public.inquiries;
create trigger trg_inquiry_guard before insert on public.inquiries
  for each row execute function public.trg_inquiry_guard();

-- ── Call-staff / bill buttons ────────────────────────────────
-- Unchanged behaviour (per-table 90 s cool-down) plus a per-connection
-- limit, and the payment method text is capped before the floor shows it.
create or replace function public.signal_call_staff(p_table_id uuid)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  last_at timestamptz;
begin
  perform private.rate_limit('signal', 30, interval '10 minutes');
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

create or replace function public.signal_bill_request(p_table_id uuid, p_payment_method text, p_total numeric)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  last_at timestamptz;
begin
  perform private.rate_limit('signal', 30, interval '10 minutes');
  select bill_requested_at into last_at
    from public.restaurant_tables
   where id = p_table_id and is_active = true;
  if last_at is not null and now() - last_at < interval '90 seconds' then
    return false;
  end if;
  if p_total is not null and (p_total < 0 or p_total > 1000000) then
    raise exception 'invalid_bill_total';
  end if;
  update public.restaurant_tables
     set bill_requested_at   = now(),
         bill_payment_method = left(regexp_replace(coalesce(p_payment_method, ''), '[^A-Za-z _-]', '', 'g'), 20),
         bill_total          = p_total
   where id = p_table_id and is_active = true;
  return true;
end $$;
revoke all on function public.signal_call_staff(uuid) from public;
revoke all on function public.signal_bill_request(uuid, text, numeric) from public;
grant execute on function public.signal_call_staff(uuid) to anon, authenticated;
grant execute on function public.signal_bill_request(uuid, text, numeric) to anon, authenticated;

-- ── Verify after running (as the SQL editor / postgres) ──────
--   select has_table_privilege('anon', 'public.orders', 'select');       -- false
--   select has_table_privilege('anon', 'public.order_items', 'insert');  -- false
--   select count(*) from pg_policies where tablename in ('orders','order_items')
--      and 'anon' = any(roles);                                           -- 0
