-- ═══════════════════════════════════════════════════════════════
-- 32 · Counter POS: modifiers, cash shifts (X / Z read), 86'ing items
--
-- Requires 29, 29b, 31.
--
-- 1. Modifiers. "Extra rice +₱25", "Spicy level", "No onions". Groups
--    with min/max picks, choices with a price delta, linked to menu items.
--    submit_order() prices them from the database like everything else;
--    the line stores a snapshot so a later price change never rewrites a
--    closed bill.
-- 2. One ordering door for everyone. Staff accounts could still INSERT
--    order_items directly with any price (an insider ₱0 sale). The POS,
--    the QR menu and the website all use submit_order() now, so the
--    direct insert policy goes.
-- 3. Cash shifts. A cashier opens a drawer with a float, records cash in
--    / cash out (petty cash, change top-ups), can print an X read any
--    time, and closes with a Z read: counted vs expected, variance
--    audited. Cash payments (sql/31) attach to the open shift.
-- 4. 86 an item from the kitchen: kitchen crew can mark a dish sold out
--    (and back) without Menu Manager access. Audited.
-- ═══════════════════════════════════════════════════════════════

select private.add_permission('pos.use',      'Workspace', 'Use the counter POS',     'Gamitin ang POS',
  'Ring up walk-in and phone orders at the counter.', 'dining', 25);
select private.add_permission('cash.drawer',  'Money',     'Open and close the cash drawer', 'Buksan at isara ang kaha',
  'Open a shift with a float, record cash in/out, close with a count.', 'dining', 340);
select private.add_permission('menu.86',      'Workspace', 'Mark dishes sold out',    'Markahang ubos na',
  'Turn a dish off (86) or back on from the kitchen screen.', 'kitchen', 65);

-- ── Modifiers ────────────────────────────────────────────────
create table if not exists public.modifier_groups (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (length(name) between 1 and 60),
  name_tl     text,
  min_select  int not null default 0 check (min_select >= 0),
  max_select  int not null default 1 check (max_select >= 1),
  sort        int not null default 100,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  constraint modifier_groups_minmax check (min_select <= max_select)
);
create table if not exists public.modifiers (
  id           uuid primary key default gen_random_uuid(),
  group_id     uuid not null references public.modifier_groups(id) on delete cascade,
  name         text not null check (length(name) between 1 and 60),
  name_tl      text,
  price_delta  numeric(10,2) not null default 0 check (price_delta between -10000 and 10000),
  is_available boolean not null default true,
  sort         int not null default 100
);
create table if not exists public.menu_item_modifier_groups (
  menu_item_id uuid not null references public.menu_items(id) on delete cascade,
  group_id     uuid not null references public.modifier_groups(id) on delete cascade,
  sort         int not null default 100,
  primary key (menu_item_id, group_id)
);
alter table public.order_items add column if not exists modifiers jsonb not null default '[]'::jsonb;

do $$
declare t text;
begin
  foreach t in array array['modifier_groups', 'modifiers', 'menu_item_modifier_groups'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to anon, authenticated', t);
    execute format('grant insert, update, delete on public.%I to authenticated', t);
    execute format('drop policy if exists %1$s_read on public.%1$I', t);
    execute format('create policy %1$s_read on public.%1$I for select to anon, authenticated using (true)', t);
    execute format('drop policy if exists %1$s_write on public.%1$I', t);
    execute format('create policy %1$s_write on public.%1$I for all to authenticated using (private.can(''menu.edit'')) with check (private.can(''menu.edit''))', t);
    execute format('drop trigger if exists trg_audit_%1$s on public.%1$I', t);
    execute format('create trigger trg_audit_%1$s after insert or update or delete on public.%1$I for each row execute function private.audit_row()', t);
  end loop;
end $$;

-- ── submit_order v3: modifiers + order source ────────────────
-- Same as sql/29 plus: items[].modifiers = [modifier_id, …] priced here,
-- group min/max enforced, and p_source ('web','qr','pos') recorded.
alter table public.orders add column if not exists source text
  check (source is null or source in ('web', 'qr', 'pos', 'phone'));

drop function if exists public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean);
create or replace function public.submit_order(
  p_branch_id uuid, p_order_type text, p_items jsonb,
  p_table_id uuid default null, p_customer_name text default null,
  p_customer_phone text default null, p_notes text default null,
  p_payment_method text default null, p_delivery_address text default null,
  p_scheduled_for timestamptz default null, p_device_id text default null,
  p_join_table_bill boolean default true, p_source text default null)
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
    v_pax := nullif(btrim(coalesce(v_item->>'pax_size', '')), '');
    if v_mi.pax_options is not null and jsonb_typeof(v_mi.pax_options) = 'object' and v_mi.pax_options <> '{}'::jsonb then
      if v_pax is null then select key into v_pax from jsonb_each(v_mi.pax_options) limit 1; end if;
      if not (v_mi.pax_options ? v_pax) then
        raise exception 'unknown_size: % (%)', v_mi.name, v_pax using errcode = '22023';
      end if;
      v_price := (v_mi.pax_options->>v_pax)::numeric;
    else
      v_pax := null; v_price := v_mi.price;
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

  if p_order_type = 'dine_in' and p_table_id is not null and p_join_table_bill then
    select id into v_order_id from public.orders
     where table_id = p_table_id and order_type = 'dine_in'
       and status not in ('completed', 'cancelled') and payment_status <> 'paid'
     order by placed_at limit 1 for update;
    v_appended := v_order_id is not null;
  end if;

  if v_order_id is null then
    insert into public.orders (branch_id, table_id, order_type, customer_name, customer_phone,
      subtotal, total, payment_method, notes, delivery_address, scheduled_for, source)
    values (p_branch_id, p_table_id, p_order_type::public.order_type_enum, v_name, v_phone, 0, 0,
      nullif(btrim(coalesce(p_payment_method, '')), '')::public.payment_method,
      v_notes, v_address, p_scheduled_for, v_source)
    returning id into v_order_id;
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
    'subtotal', (select subtotal from public.orders where id = v_order_id));
end $$;
revoke all on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text) from public;
grant execute on function public.submit_order(uuid, text, jsonb, uuid, text, text, text, text, text, timestamptz, text, boolean, text) to anon, authenticated;

-- One ordering door: no direct line inserts from any client.
drop policy if exists order_items_auth_insert on public.order_items;
revoke insert on public.order_items from authenticated;

-- ── 86 an item ───────────────────────────────────────────────
create or replace function public.set_item_available(p_item_id uuid, p_available boolean, p_reason text default null)
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare v_old boolean; v_name text;
begin
  if not (private.can('menu.86') or private.can('menu.edit')) then
    raise exception 'permission_denied: menu.86' using errcode = '42501';
  end if;
  select is_available, name into v_old, v_name from public.menu_items where id = p_item_id for update;
  if not found then raise exception 'item_not_found'; end if;
  update public.menu_items set is_available = p_available where id = p_item_id;
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), case when p_available then 'menu.restock' else 'menu.86' end,
          'menu_item', p_item_id, jsonb_build_object('name', v_name, 'was', v_old, 'reason', left(p_reason, 200)));
  return p_available;
end $$;
revoke all on function public.set_item_available(uuid, boolean, text) from public, anon;
grant execute on function public.set_item_available(uuid, boolean, text) to authenticated;

-- ── Cash shifts ──────────────────────────────────────────────
create table if not exists public.cash_sessions (
  id             uuid primary key default gen_random_uuid(),
  branch_id      uuid not null references public.branches(id),
  register_label text not null default 'Counter' check (length(register_label) between 1 and 30),
  opened_by      uuid not null references public.staff(id),
  opened_at      timestamptz not null default now(),
  opening_float  numeric(10,2) not null check (opening_float >= 0),
  status         text not null default 'open' check (status in ('open', 'closed')),
  closed_by      uuid references public.staff(id),
  closed_at      timestamptz,
  expected_cash  numeric(10,2),
  counted_cash   numeric(10,2),
  variance       numeric(10,2),
  denominations  jsonb,
  notes          text check (length(notes) <= 500)
);
create unique index if not exists uq_cash_session_open on public.cash_sessions (branch_id, register_label) where status = 'open';

create table if not exists public.cash_movements (
  id          uuid primary key default gen_random_uuid(),
  session_id  uuid not null references public.cash_sessions(id) on delete restrict,
  kind        text not null check (kind in ('cash_in', 'cash_out')),
  amount      numeric(10,2) not null check (amount > 0),
  reason      text not null check (length(reason) between 3 and 200),
  created_by  uuid not null references public.staff(id),
  created_at  timestamptz not null default now()
);

alter table public.payments drop constraint if exists payments_cash_session_fk;
alter table public.payments add constraint payments_cash_session_fk
  foreign key (cash_session_id) references public.cash_sessions(id);

do $$
declare t text;
begin
  foreach t in array array['cash_sessions', 'cash_movements'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop trigger if exists trg_audit_%1$s on public.%1$I', t);
    execute format('create trigger trg_audit_%1$s after insert or update on public.%1$I for each row execute function private.audit_row()', t);
  end loop;
end $$;
drop policy if exists cash_sessions_read on public.cash_sessions;
create policy cash_sessions_read on public.cash_sessions for select to authenticated
  using ((private.can('cash.drawer') or private.can('finance.view'))
         and (branch_id = private.my_branch() or private.has_role('admin')));
drop policy if exists cash_movements_read on public.cash_movements;
create policy cash_movements_read on public.cash_movements for select to authenticated
  using (exists (select 1 from public.cash_sessions s where s.id = session_id
                  and (private.can('cash.drawer') or private.can('finance.view'))
                  and (s.branch_id = private.my_branch() or private.has_role('admin'))));

-- Expected cash = float + cash taken (incl. tips) − cash refunds + in − out.
create or replace function public.cash_session_report(p_session uuid)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare s public.cash_sessions%rowtype; v_in numeric; v_ref numeric; v_tip numeric; v_ci numeric; v_co numeric; v_n int;
begin
  if not (private.can('cash.drawer') or private.can('finance.view')) then
    raise exception 'permission_denied: cash.drawer' using errcode = '42501';
  end if;
  select * into s from public.cash_sessions where id = p_session;
  if not found then raise exception 'session_not_found'; end if;
  if s.branch_id is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  select coalesce(sum(amount) filter (where kind = 'payment'), 0),
         coalesce(sum(amount) filter (where kind = 'refund'), 0),
         coalesce(sum(tip) filter (where kind = 'payment'), 0),
         count(*) filter (where kind = 'payment')
    into v_in, v_ref, v_tip, v_n
    from public.payments where cash_session_id = s.id and method = 'cash' and status = 'completed';
  select coalesce(sum(amount) filter (where kind = 'cash_in'), 0),
         coalesce(sum(amount) filter (where kind = 'cash_out'), 0)
    into v_ci, v_co from public.cash_movements where session_id = s.id;
  return jsonb_build_object(
    'session', to_jsonb(s), 'opening_float', s.opening_float, 'cash_sales', v_in, 'tips', v_tip,
    'cash_refunds', v_ref, 'cash_in', v_ci, 'cash_out', v_co, 'sales_count', v_n,
    'expected_cash', s.opening_float + v_in + v_tip - v_ref + v_ci - v_co,
    'other_methods', coalesce((select jsonb_object_agg(method, amt) from (
        select p.method, sum(case when p.kind = 'payment' then p.amount else -p.amount end) amt
          from public.payments p
         where p.branch_id = s.branch_id and p.status = 'completed' and p.method <> 'cash'
           and coalesce(p.confirmed_at, p.created_at) between s.opened_at and coalesce(s.closed_at, now())
         group by p.method) x), '{}'::jsonb),
    'movements', coalesce((select jsonb_agg(to_jsonb(m) order by m.created_at) from public.cash_movements m where m.session_id = s.id), '[]'::jsonb),
    'generated_at', now());
end $$;
revoke all on function public.cash_session_report(uuid) from public, anon;
grant execute on function public.cash_session_report(uuid) to authenticated;

create or replace function public.open_cash_session(p_float numeric, p_register text default 'Counter')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare v_id uuid; v_branch uuid := private.my_branch();
begin
  if not private.can('cash.drawer') then raise exception 'permission_denied: cash.drawer' using errcode = '42501'; end if;
  if v_branch is null then raise exception 'no_branch'; end if;
  if p_float is null or p_float < 0 or p_float > 100000 then raise exception 'bad_float'; end if;
  if exists (select 1 from public.cash_sessions where branch_id = v_branch
              and register_label = coalesce(nullif(btrim(p_register), ''), 'Counter') and status = 'open') then
    raise exception 'drawer_already_open';
  end if;
  insert into public.cash_sessions (branch_id, register_label, opened_by, opening_float)
  values (v_branch, left(coalesce(nullif(btrim(p_register), ''), 'Counter'), 30), auth.uid(), round(p_float, 2))
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.cash_move(p_session uuid, p_kind text, p_amount numeric, p_reason text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare s public.cash_sessions%rowtype; v_id uuid;
begin
  if not private.can('cash.drawer') then raise exception 'permission_denied: cash.drawer' using errcode = '42501'; end if;
  select * into s from public.cash_sessions where id = p_session for update;
  if not found or s.status <> 'open' then raise exception 'session_not_open'; end if;
  if s.branch_id is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  if p_kind not in ('cash_in', 'cash_out') then raise exception 'bad_kind'; end if;
  if p_amount is null or p_amount <= 0 or p_amount > 100000 then raise exception 'bad_amount'; end if;
  if coalesce(length(btrim(p_reason)), 0) < 3 then raise exception 'reason_required'; end if;
  insert into public.cash_movements (session_id, kind, amount, reason, created_by)
  values (s.id, p_kind, round(p_amount, 2), left(btrim(p_reason), 200), auth.uid())
  returning id into v_id;
  return v_id;
end $$;

-- Z read. Counted cash vs expected; the variance is kept forever.
create or replace function public.close_cash_session(p_session uuid, p_counted numeric, p_denominations jsonb default null, p_notes text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare s public.cash_sessions%rowtype; rep jsonb; v_exp numeric;
begin
  if not private.can('cash.drawer') then raise exception 'permission_denied: cash.drawer' using errcode = '42501'; end if;
  select * into s from public.cash_sessions where id = p_session for update;
  if not found or s.status <> 'open' then raise exception 'session_not_open'; end if;
  if s.branch_id is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  if p_counted is null or p_counted < 0 then raise exception 'bad_count'; end if;
  rep := public.cash_session_report(s.id);
  v_exp := (rep->>'expected_cash')::numeric;
  update public.cash_sessions
     set status = 'closed', closed_by = auth.uid(), closed_at = now(),
         expected_cash = v_exp, counted_cash = round(p_counted, 2),
         variance = round(p_counted, 2) - v_exp, denominations = p_denominations,
         notes = left(nullif(btrim(coalesce(p_notes, '')), ''), 500)
   where id = s.id;
  return public.cash_session_report(s.id) || jsonb_build_object('counted', round(p_counted, 2), 'variance', round(p_counted, 2) - v_exp);
end $$;

create or replace function public.my_open_cash_session(p_register text default 'Counter')
returns uuid
language sql stable security definer set search_path = ''
as $$
  select id from public.cash_sessions
   where branch_id = private.my_branch() and register_label = coalesce(nullif(btrim(p_register), ''), 'Counter')
     and status = 'open' and private.can('cash.drawer')
$$;

do $$
declare f text;
begin
  foreach f in array array['public.open_cash_session(numeric, text)', 'public.cash_move(uuid, text, numeric, text)',
                           'public.close_cash_session(uuid, numeric, jsonb, text)', 'public.my_open_cash_session(text)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

-- Cash taken while a drawer is open belongs to that drawer, whoever forgot
-- to pass it: record_cash_payment fills the open session in.
create or replace function private.trg_payment_cash_session()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if new.method = 'cash' and new.cash_session_id is null then
    select id into new.cash_session_id from public.cash_sessions
     where branch_id = new.branch_id and status = 'open'
     order by opened_at desc limit 1;
  end if;
  return new;
end $$;
revoke all on function private.trg_payment_cash_session() from public, anon, authenticated;
drop trigger if exists trg_payment_cash_session on public.payments;
create trigger trg_payment_cash_session before insert on public.payments
  for each row execute function private.trg_payment_cash_session();

do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and tablename = 'menu_items') then
    alter publication supabase_realtime add table public.menu_items;
  end if;
end $$;
