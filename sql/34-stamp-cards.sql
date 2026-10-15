-- ═══════════════════════════════════════════════════════════════
-- 34 · Digital stamp cards (hard to fake)
--
-- Requires 29 (track_token, rate_limit), 29b, 30 (site_settings), 31
-- (payment_status is derived from real payments).
--
-- How it resists cheating:
--  • Stamps are written ONLY by a trigger when an order's payment_status
--    becomes 'paid' (which sql/31 only does when confirmed money covers
--    the bill) and the total is at least the minimum. One per order.
--    A refund or cancellation writes a reversal. No client can insert.
--  • A card is the customer's phone number, stored only as a salted
--    hash plus the last 4 digits. Nobody can look a card up by phone from
--    the outside: claiming a card on a device needs proof of purchase —
--    the private tracking token of a paid order on that phone (sql/29).
--  • The device gets a random secret (stored hashed). Viewing the card
--    needs it.
--  • Redeeming is staff-only (rewards.redeem). The customer shows a QR /
--    6-digit code that changes every 30 seconds, derived from a server
--    secret; each code works once. A screenshot is useless half a minute
--    later.
--
-- Settings (site_settings, editable in the Rewards tab):
--   rewards.enabled, rewards.min_order, rewards.stamps_needed,
--   rewards.reward_text, rewards.card_days (stamps expire after N days)
-- ═══════════════════════════════════════════════════════════════

select private.add_permission('rewards.redeem', 'Money', 'Redeem stamp-card rewards', 'Mag-redeem ng reward',
  'Scan a customer''s rotating rewards code and give the reward.', 'supervisor', 350);
select private.add_permission('rewards.manage', 'Money', 'Manage the stamp card', 'Pamahalaan ang stamp card',
  'Change the minimum order, stamps needed and the reward.', 'manager', 351);

insert into public.site_settings (key, value) values
  ('rewards.enabled',       'false'),
  ('rewards.min_order',     '300'),
  ('rewards.stamps_needed', '10'),
  ('rewards.reward_text',   '"Free dish of your choice (up to ₱300)"'),
  ('rewards.card_days',     '365')
on conflict (key) do nothing;

-- Server secret for codes and phone hashing. Lives in private, which the
-- API never exposes. Generated once.
create table if not exists private.loyalty_secret (
  id     int primary key default 1 check (id = 1),
  secret text not null
);
insert into private.loyalty_secret (secret)
select encode(sha256((gen_random_uuid()::text || clock_timestamp()::text || random()::text)::bytea), 'hex')
where not exists (select 1 from private.loyalty_secret);

create or replace function private.loyalty_hash(p text)
returns text language sql stable security definer set search_path = '' as $$
  select encode(sha256(((select secret from private.loyalty_secret) || ':' || p)::bytea), 'hex')
$$;
create or replace function private.norm_phone(p text)
returns text language sql immutable set search_path = '' as $$
  -- 09171234567 / +639171234567 / 639171234567 / 9171234567 → +639171234567
  select case
    when d ~ '^09\d{9}$'  then '+63' || substr(d, 2)
    when d ~ '^639\d{9}$' then '+' || d
    when d ~ '^9\d{9}$'   then '+63' || d
    else null end
  from (select regexp_replace(coalesce(p, ''), '\D', '', 'g') as d) x
$$;
create or replace function private.setting_num(k text, dflt numeric)
returns numeric language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}')::numeric from public.site_settings where key = k), dflt)
$$;
create or replace function private.setting_bool(k text)
returns boolean language sql stable security definer set search_path = '' as $$
  select coalesce((select (value #>> '{}') in ('true', 'yes', '1') from public.site_settings where key = k), false)
$$;
revoke all on function private.loyalty_hash(text) from public, anon, authenticated;
revoke all on function private.norm_phone(text) from public, anon, authenticated;
revoke all on function private.setting_num(text, numeric) from public, anon, authenticated;
revoke all on function private.setting_bool(text) from public, anon, authenticated;

-- ── Tables ───────────────────────────────────────────────────
create table if not exists public.loyalty_cards (
  id          uuid primary key default gen_random_uuid(),
  phone_hash  text not null unique,
  phone_last4 text not null check (phone_last4 ~ '^\d{4}$'),
  created_at  timestamptz not null default now()
);
create table if not exists public.loyalty_devices (
  id           uuid primary key default gen_random_uuid(),
  card_id      uuid not null references public.loyalty_cards(id) on delete cascade,
  secret_hash  text not null unique,
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  revoked_at   timestamptz
);
create table if not exists public.loyalty_ledger (
  id          uuid primary key default gen_random_uuid(),
  card_id     uuid not null references public.loyalty_cards(id) on delete cascade,
  order_id    uuid references public.orders(id) on delete set null,
  kind        text not null check (kind in ('stamp', 'reversal', 'redeem', 'adjust')),
  delta       int not null,
  note        text check (length(note) <= 200),
  created_by  uuid references public.staff(id),
  created_at  timestamptz not null default now(),
  expires_at  timestamptz
);
create unique index if not exists uq_ledger_order_kind on public.loyalty_ledger (order_id, kind) where order_id is not null;
create index if not exists idx_ledger_card on public.loyalty_ledger (card_id, created_at desc);
create table if not exists private.loyalty_used_codes (
  card_id uuid not null,
  win     bigint not null,
  used_at timestamptz not null default now(),
  primary key (card_id, win)
);

do $$
declare t text;
begin
  foreach t in array array['loyalty_cards', 'loyalty_devices', 'loyalty_ledger'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to authenticated', t);
    execute format('drop policy if exists %1$s_staff_read on public.%1$I', t);
    execute format('create policy %1$s_staff_read on public.%1$I for select to authenticated using (private.can(''rewards.redeem'') or private.can(''rewards.manage''))', t);
  end loop;
end $$;
drop trigger if exists trg_audit_loyalty_ledger on public.loyalty_ledger;
create trigger trg_audit_loyalty_ledger after insert on public.loyalty_ledger
  for each row execute function private.audit_row();

-- Balance counts only unexpired stamps; redemptions spend the oldest first
-- simply by being negative.
create or replace function private.card_balance(p_card uuid)
returns int language sql stable security definer set search_path = '' as $$
  select coalesce(sum(delta) filter (where expires_at is null or expires_at > now()), 0)::int
    from public.loyalty_ledger where card_id = p_card
$$;
revoke all on function private.card_balance(uuid) from public, anon, authenticated;

create or replace function private.card_for_phone(p_phone text, p_create boolean)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v_norm text := private.norm_phone(p_phone); v_id uuid;
begin
  if v_norm is null then return null; end if;
  select id into v_id from public.loyalty_cards where phone_hash = private.loyalty_hash(v_norm);
  if v_id is null and p_create then
    insert into public.loyalty_cards (phone_hash, phone_last4) values (private.loyalty_hash(v_norm), right(v_norm, 4))
    on conflict (phone_hash) do update set phone_hash = excluded.phone_hash
    returning id into v_id;
  end if;
  return v_id;
end $$;
revoke all on function private.card_for_phone(text, boolean) from public, anon, authenticated;

-- ── The only way a stamp appears ─────────────────────────────
create or replace function private.trg_order_stamp()
returns trigger language plpgsql security definer set search_path = '' as $$
declare v_card uuid; v_days int;
begin
  -- Earned: became paid.
  if new.payment_status = 'paid' and old.payment_status is distinct from 'paid'
     and private.setting_bool('rewards.enabled')
     and new.total >= private.setting_num('rewards.min_order', 300)
     and new.customer_phone is not null then
    v_card := private.card_for_phone(new.customer_phone, true);
    if v_card is not null then
      v_days := private.setting_num('rewards.card_days', 365)::int;
      insert into public.loyalty_ledger (card_id, order_id, kind, delta, expires_at)
      values (v_card, new.id, 'stamp', 1, case when v_days > 0 then now() + make_interval(days => v_days) end)
      on conflict do nothing;
    end if;
  end if;
  -- Taken back: refunded or cancelled after a stamp was given.
  if (new.payment_status = 'refunded' and old.payment_status is distinct from 'refunded')
     or (new.status = 'cancelled' and old.status is distinct from 'cancelled') then
    insert into public.loyalty_ledger (card_id, order_id, kind, delta, note)
    select l.card_id, new.id, 'reversal', -1, 'Order ' || coalesce(new.order_number, '') || ' refunded/cancelled'
      from public.loyalty_ledger l where l.order_id = new.id and l.kind = 'stamp'
    on conflict do nothing;
  end if;
  return new;
end $$;
revoke all on function private.trg_order_stamp() from public, anon, authenticated;
drop trigger if exists trg_order_stamp on public.orders;
create trigger trg_order_stamp after update of payment_status, status on public.orders
  for each row execute function private.trg_order_stamp();

-- ── Customer side (anonymous, rate limited) ──────────────────
-- Claim this phone's card on this device with proof of purchase.
create or replace function public.claim_stamp_card(p_phone text, p_order_number text, p_track_token uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare o public.orders%rowtype; v_card uuid; v_secret text;
begin
  perform private.rate_limit('loyalty_claim', 10, interval '30 minutes');
  if private.norm_phone(p_phone) is null then raise exception 'bad_phone'; end if;
  select * into o from public.orders
   where upper(order_number) = upper(btrim(p_order_number)) and track_token = p_track_token;
  if not found then raise exception 'proof_not_found'; end if;
  if private.norm_phone(o.customer_phone) is distinct from private.norm_phone(p_phone) then
    raise exception 'phone_does_not_match_order';
  end if;
  v_card := private.card_for_phone(p_phone, true);
  v_secret := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  insert into public.loyalty_devices (card_id, secret_hash) values (v_card, private.loyalty_hash('dev:' || v_secret));
  return jsonb_build_object('card_id', v_card, 'device_secret', v_secret);
end $$;

create or replace function private.card_for_device(p_card uuid, p_secret text)
returns uuid language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  update public.loyalty_devices set last_seen_at = now()
   where card_id = p_card and secret_hash = private.loyalty_hash('dev:' || coalesce(p_secret, '')) and revoked_at is null
  returning card_id into v;
  if v is null then raise exception 'card_not_on_this_device'; end if;
  return v;
end $$;
revoke all on function private.card_for_device(uuid, text) from public, anon, authenticated;

create or replace function public.my_stamp_card(p_card uuid, p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid;
begin
  perform private.rate_limit('loyalty_view', 120, interval '10 minutes');
  v := private.card_for_device(p_card, p_secret);
  return jsonb_build_object(
    'card_id', v, 'last4', (select phone_last4 from public.loyalty_cards where id = v),
    'stamps', private.card_balance(v),
    'needed', private.setting_num('rewards.stamps_needed', 10)::int,
    'reward', (select value #>> '{}' from public.site_settings where key = 'rewards.reward_text'),
    'min_order', private.setting_num('rewards.min_order', 300),
    'enabled', private.setting_bool('rewards.enabled'),
    'history', coalesce((select jsonb_agg(jsonb_build_object('kind', kind, 'delta', delta, 'at', created_at,
                                 'expires_at', expires_at) order by created_at desc)
                           from (select * from public.loyalty_ledger where card_id = v order by created_at desc limit 20) h), '[]'::jsonb));
end $$;

-- Rotating code: 6 digits, new every 30 seconds.
create or replace function private.card_code(p_card uuid, p_win bigint)
returns text language sql stable security definer set search_path = '' as $$
  select lpad((abs(('x' || substr(encode(sha256(((select secret from private.loyalty_secret) || ':code:' || p_card::text || ':' || p_win::text)::bytea), 'hex'), 1, 8))::bit(32)::bigint) % 1000000)::text, 6, '0')
$$;
revoke all on function private.card_code(uuid, bigint) from public, anon, authenticated;

create or replace function public.stamp_card_code(p_card uuid, p_secret text)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v uuid; w bigint := floor(extract(epoch from now()) / 30);
begin
  perform private.rate_limit('loyalty_code', 240, interval '10 minutes');
  v := private.card_for_device(p_card, p_secret);
  return jsonb_build_object('card_id', v, 'code', private.card_code(v, w),
                            'valid_for', 30 - (floor(extract(epoch from now()))::bigint % 30));
end $$;

-- ── Staff side ───────────────────────────────────────────────
-- Accepts the current or previous 30-second code (a slow scan), once.
create or replace function public.redeem_stamp_reward(p_card uuid, p_code text, p_note text default null)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare w bigint := floor(extract(epoch from now()) / 30); v_win bigint; v_need int; v_bal int;
begin
  if not private.can('rewards.redeem') then raise exception 'permission_denied: rewards.redeem' using errcode = '42501'; end if;
  if not exists (select 1 from public.loyalty_cards where id = p_card) then raise exception 'card_not_found'; end if;
  select x into v_win from unnest(array[w, w - 1]) x where private.card_code(p_card, x) = btrim(coalesce(p_code, '')) limit 1;
  if v_win is null then raise exception 'code_expired_or_wrong'; end if;
  begin
    insert into private.loyalty_used_codes (card_id, win) values (p_card, v_win);
  exception when unique_violation then
    raise exception 'code_already_used';
  end;
  v_need := private.setting_num('rewards.stamps_needed', 10)::int;
  v_bal := private.card_balance(p_card);
  if v_bal < v_need then raise exception 'not_enough_stamps: % of %', v_bal, v_need; end if;
  insert into public.loyalty_ledger (card_id, kind, delta, note, created_by)
  values (p_card, 'redeem', -v_need, left(coalesce(p_note, 'Reward given'), 200), auth.uid());
  return jsonb_build_object('ok', true, 'reward', (select value #>> '{}' from public.site_settings where key = 'rewards.reward_text'),
                            'stamps_left', private.card_balance(p_card));
end $$;

-- Staff lookup by phone (for "how many stamps do I have?" at the counter).
create or replace function public.stamp_card_lookup(p_phone text)
returns jsonb language plpgsql stable security definer set search_path = '' as $$
declare v uuid;
begin
  if not (private.can('rewards.redeem') or private.can('rewards.manage')) then raise exception 'permission_denied' using errcode = '42501'; end if;
  v := private.card_for_phone(p_phone, false);
  if v is null then return null; end if;
  return jsonb_build_object('card_id', v, 'stamps', private.card_balance(v),
    'needed', private.setting_num('rewards.stamps_needed', 10)::int,
    'devices', (select count(*) from public.loyalty_devices where card_id = v and revoked_at is null),
    'history', coalesce((select jsonb_agg(jsonb_build_object('kind', l.kind, 'delta', l.delta, 'at', l.created_at,
                 'order_number', o.order_number, 'note', l.note) order by l.created_at desc)
               from public.loyalty_ledger l left join public.orders o on o.id = l.order_id where l.card_id = v), '[]'::jsonb));
end $$;

create or replace function public.revoke_stamp_devices(p_card uuid)
returns int language plpgsql security definer set search_path = '' as $$
declare n int;
begin
  if not private.can('rewards.manage') then raise exception 'permission_denied' using errcode = '42501'; end if;
  update public.loyalty_devices set revoked_at = now() where card_id = p_card and revoked_at is null;
  get diagnostics n = row_count; return n;
end $$;

do $$
declare f text;
begin
  foreach f in array array['public.claim_stamp_card(text, text, uuid)', 'public.my_stamp_card(uuid, text)', 'public.stamp_card_code(uuid, text)'] loop
    execute 'revoke all on function ' || f || ' from public';
    execute 'grant execute on function ' || f || ' to anon, authenticated';
  end loop;
  foreach f in array array['public.redeem_stamp_reward(uuid, text, text)', 'public.stamp_card_lookup(text)', 'public.revoke_stamp_devices(uuid)'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

-- Reward settings are public (the card page shows them) but only
-- rewards.manage may change them, on top of site.edit.
create or replace function private.trg_rewards_settings_guard()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if coalesce(new.key, old.key) like 'rewards.%' and auth.uid() is not null and not private.can('rewards.manage') then
    raise exception 'permission_denied: rewards.manage' using errcode = '42501';
  end if;
  return coalesce(new, old);
end $$;
revoke all on function private.trg_rewards_settings_guard() from public, anon, authenticated;
drop trigger if exists trg_rewards_settings_guard on public.site_settings;
create trigger trg_rewards_settings_guard before insert or update or delete on public.site_settings
  for each row execute function private.trg_rewards_settings_guard();
drop policy if exists site_settings_rewards_write on public.site_settings;
create policy site_settings_rewards_write on public.site_settings for all to authenticated
  using (key like 'rewards.%' and private.can('rewards.manage'))
  with check (key like 'rewards.%' and private.can('rewards.manage'));
