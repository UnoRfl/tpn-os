-- ═══════════════════════════════════════════════════════════════
-- 49 — manager PIN at the counter (Oct 22, 2026)
--
-- RECOVERED Nov 7, 2026. Production ran this on Oct 22 (Supabase
-- migrations 49_manager_pin and 49_manager_pin_no_pin_set) but the file
-- never reached GitHub. Both parts below are copied byte for byte from
-- supabase_migrations.schema_migrations on project xjlqfpnzobfqxetgkkai
-- (md5 3f36e509… and ab2e9053…), in the order production ran them.
--
-- A manager (or anyone with voids.approve / payments.refund /
-- printer.manage) sets a 4–6 digit PIN. At the counter a cashier types
-- that PIN to void, discount, refund or pass any permission check
-- without the manager logging in. The action runs as the manager; the
-- audit row keeps the cashier as actor and adds approved_by.
--   private.staff_pins, private.pin_fails (5 misses in 10 min = locked)
--   my_pin_status, set_my_pin, clear_my_pin
--   pin_void_order_item, pin_approve_void_request, pin_apply_discount,
--   pin_remove_discount, pin_refund, pin_check
-- Part 2 makes pin_verify answer no_pin_set when nobody in the branch
-- has a PIN yet. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── Part 1: 49_manager_pin ──────────────────────────────────────
-- ═══════════════════════════════════════════════════════════════
-- 49 — manager PIN at the counter (Oct 22, 2026)
-- See sql/49-manager-pin.sql in the repo for the full header.
-- ═══════════════════════════════════════════════════════════════

create extension if not exists pgcrypto with schema extensions;

create table if not exists private.staff_pins (
  staff_id   uuid primary key references public.staff(id) on delete cascade,
  pin_hash   text not null,
  set_at     timestamptz not null default now()
);
create table if not exists private.pin_fails (
  staff_id uuid not null,
  at       timestamptz not null default now()
);
create index if not exists idx_pin_fails on private.pin_fails (staff_id, at desc);
revoke all on private.staff_pins, private.pin_fails from public, anon, authenticated;

create or replace function private.can_staff(p_staff uuid, p_key text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_role_id uuid;
  v_tier    public.staff_role;
  v_allowed boolean;
begin
  select role, access_role_id into v_tier, v_role_id
    from public.staff
   where id = p_staff and coalesce(employment_status, 'active') = 'active';
  if v_tier is null then return false; end if;
  if v_tier = 'ceo' then return true; end if;

  select allowed into v_allowed
    from public.staff_permission_overrides
   where staff_id = p_staff and permission_key = p_key;
  if v_allowed is not null then return v_allowed; end if;

  if v_role_id is not null then
    select arp.allowed into v_allowed
      from public.access_role_permissions arp
      join public.access_roles r on r.id = arp.role_id
     where arp.role_id = v_role_id and arp.permission_key = p_key and r.is_active;
    return coalesce(v_allowed, false);
  end if;

  select arp.allowed into v_allowed
    from public.access_role_permissions arp
    join public.access_roles r on r.id = arp.role_id
   where r.key = v_tier::text and r.is_system and arp.permission_key = p_key;
  return coalesce(v_allowed, false);
end $$;
revoke all on function private.can_staff(uuid, text) from public, anon, authenticated;

create or replace function private.pin_eligible(p_staff uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.staff s
     where s.id = p_staff and coalesce(s.employment_status, 'active') = 'active'
       and (array_position(enum_range(null::public.staff_role), s.role)
              >= array_position(enum_range(null::public.staff_role), 'manager'::public.staff_role)
            or private.can_staff(s.id, 'voids.approve')
            or private.can_staff(s.id, 'payments.refund')
            or private.can_staff(s.id, 'printer.manage')))
$$;
revoke all on function private.pin_eligible(uuid) from public, anon, authenticated;

create or replace function private.pin_recent_fails(p_staff uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int from private.pin_fails
   where staff_id = p_staff and at > now() - interval '10 minutes'
$$;
revoke all on function private.pin_recent_fails(uuid) from public, anon, authenticated;

create or replace function public.my_pin_status()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'eligible', coalesce(private.pin_eligible(auth.uid()), false),
    'has_pin',  exists (select 1 from private.staff_pins where staff_id = auth.uid()),
    'set_at',   (select set_at from private.staff_pins where staff_id = auth.uid()))
$$;
revoke all on function public.my_pin_status() from public, anon;
grant execute on function public.my_pin_status() to authenticated;

create or replace function public.set_my_pin(p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  me    public.staff%rowtype;
  v_pin text := btrim(coalesce(p_pin, ''));
  had   boolean;
begin
  select * into me from public.staff
   where id = auth.uid() and coalesce(employment_status, 'active') = 'active';
  if not found then raise exception 'no_staff_profile' using errcode = '42501'; end if;
  if not private.pin_eligible(me.id) then
    raise exception 'pin_not_allowed' using errcode = '42501';
  end if;
  if private.pin_recent_fails(me.id) >= 5 then
    return jsonb_build_object('ok', false, 'error', 'pin_locked');
  end if;
  if v_pin !~ '^[0-9]{4,6}$' then raise exception 'pin_format' using errcode = '22023'; end if;
  if v_pin ~ '^(.)\1+$' or strpos('01234567890', v_pin) > 0 or strpos('09876543210', v_pin) > 0 then
    raise exception 'pin_too_simple' using errcode = '22023';
  end if;

  if exists (
    select 1 from private.staff_pins p
      join public.staff s on s.id = p.staff_id
     where s.branch_id is not distinct from me.branch_id
       and p.staff_id <> me.id
       and p.pin_hash = extensions.crypt(v_pin, p.pin_hash)
  ) then
    insert into private.pin_fails (staff_id) values (me.id);
    return jsonb_build_object('ok', false, 'error', 'pin_in_use');
  end if;

  had := exists (select 1 from private.staff_pins where staff_id = me.id);
  insert into private.staff_pins (staff_id, pin_hash, set_at)
  values (me.id, extensions.crypt(v_pin, extensions.gen_salt('bf', 8)), now())
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, set_at = excluded.set_at;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (me.id, me.role, 'pin.set', 'staff', me.id,
          jsonb_build_object('changed', had, 'branch_id', me.branch_id));
  return jsonb_build_object('ok', true, 'changed', had);
end $$;
revoke all on function public.set_my_pin(text) from public, anon;
grant execute on function public.set_my_pin(text) to authenticated;

create or replace function public.clear_my_pin()
returns boolean
language plpgsql security definer set search_path = ''
as $$
declare me public.staff%rowtype;
begin
  select * into me from public.staff where id = auth.uid();
  if not found then raise exception 'no_staff_profile' using errcode = '42501'; end if;
  delete from private.staff_pins where staff_id = me.id;
  if found then
    insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
    values (me.id, me.role, 'pin.clear', 'staff', me.id, jsonb_build_object('branch_id', me.branch_id));
  end if;
  return true;
end $$;
revoke all on function public.clear_my_pin() from public, anon;
grant execute on function public.clear_my_pin() to authenticated;

create or replace function private.pin_verify(p_pin text, p_key text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  me    public.staff%rowtype;
  mgr   public.staff%rowtype;
  v_pin text := btrim(coalesce(p_pin, ''));
begin
  select * into me from public.staff
   where id = auth.uid() and coalesce(employment_status, 'active') = 'active';
  if not found then raise exception 'no_staff_profile' using errcode = '42501'; end if;

  if private.pin_recent_fails(me.id) >= 5 then
    return jsonb_build_object('ok', false, 'error', 'pin_locked');
  end if;

  if v_pin ~ '^[0-9]{4,6}$' then
    select s.* into mgr
      from private.staff_pins p
      join public.staff s on s.id = p.staff_id
     where s.branch_id = me.branch_id
       and coalesce(s.employment_status, 'active') = 'active'
       and p.pin_hash = extensions.crypt(v_pin, p.pin_hash)
     order by p.set_at
     limit 1;
  end if;

  if mgr.id is null then
    insert into private.pin_fails (staff_id) values (me.id);
    insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
    values (me.id, me.role, 'pin.bad', 'staff', me.id,
            jsonb_build_object('permission', p_key, 'misses', private.pin_recent_fails(me.id)));
    if private.pin_recent_fails(me.id) >= 5 then
      return jsonb_build_object('ok', false, 'error', 'pin_locked');
    end if;
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;

  if not private.pin_eligible(mgr.id) or not private.can_staff(mgr.id, p_key) then
    raise exception 'pin_not_allowed: %', p_key using errcode = '42501';
  end if;

  delete from private.pin_fails where staff_id = me.id;
  return jsonb_build_object('ok', true, 'caller', me.id, 'staff_id', mgr.id,
                            'approved_by', mgr.id,
                            'approved_by_name', split_part(btrim(mgr.full_name), ' ', 1));
end $$;
revoke all on function private.pin_verify(text, text) from public, anon, authenticated;

create or replace function private.pin_as_begin(p_v jsonb)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_claims jsonb := coalesce(nullif(current_setting('request.jwt.claims', true), '')::jsonb, '{}'::jsonb);
begin
  perform set_config('tpn.pin_saved_sub', coalesce(current_setting('request.jwt.claim.sub', true), ''), true);
  perform set_config('tpn.pin_saved_claims', coalesce(current_setting('request.jwt.claims', true), ''), true);
  perform set_config('tpn.pin_caller', p_v->>'caller', true);
  perform set_config('tpn.pin_approver', p_v->>'staff_id', true);
  perform set_config('tpn.pin_approver_name', coalesce(p_v->>'approved_by_name', ''), true);
  perform set_config('request.jwt.claim.sub', p_v->>'staff_id', true);
  perform set_config('request.jwt.claims', (v_claims || jsonb_build_object('sub', p_v->>'staff_id'))::text, true);
end $$;
revoke all on function private.pin_as_begin(jsonb) from public, anon, authenticated;

create or replace function private.pin_as_end()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform set_config('request.jwt.claim.sub', coalesce(current_setting('tpn.pin_saved_sub', true), ''), true);
  perform set_config('request.jwt.claims', coalesce(current_setting('tpn.pin_saved_claims', true), ''), true);
  perform set_config('tpn.pin_caller', '', true);
  perform set_config('tpn.pin_approver', '', true);
  perform set_config('tpn.pin_approver_name', '', true);
end $$;
revoke all on function private.pin_as_end() from public, anon, authenticated;

create or replace function private.trg_audit_pin_actor()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare v_caller uuid; v_appr uuid;
begin
  v_appr := nullif(current_setting('tpn.pin_approver', true), '')::uuid;
  if v_appr is null then return new; end if;
  v_caller := nullif(current_setting('tpn.pin_caller', true), '')::uuid;
  if v_caller is null then return new; end if;
  new.actor_id   := v_caller;
  new.actor_role := (select role from public.staff where id = v_caller);
  new.metadata   := coalesce(new.metadata, '{}'::jsonb) || jsonb_build_object(
    'approved_by', v_appr,
    'approved_by_name', nullif(current_setting('tpn.pin_approver_name', true), ''),
    'via', 'manager_pin');
  return new;
end $$;
revoke all on function private.trg_audit_pin_actor() from public, anon, authenticated;
drop trigger if exists trg_audit_pin_actor on public.audit_log;
create trigger trg_audit_pin_actor before insert on public.audit_log
  for each row execute function private.trg_audit_pin_actor();

create or replace function private.pin_assert_branch(p_order uuid)
returns void
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not exists (select 1 from public.orders o join public.staff s on s.id = auth.uid()
                  where o.id = p_order and o.branch_id = s.branch_id) then
    if not exists (select 1 from public.orders where id = p_order) then
      raise exception 'order_not_found' using errcode = 'P0002';
    end if;
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
end $$;
revoke all on function private.pin_assert_branch(uuid) from public, anon, authenticated;

create or replace function public.pin_void_order_item(p_item uuid, p_reason text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb; r public.order_items%rowtype;
begin
  perform private.pin_assert_branch((select order_id from public.order_items where id = p_item));
  v := private.pin_verify(p_pin, 'voids.approve');
  if not (v->>'ok')::boolean then return v; end if;
  perform private.pin_as_begin(v);
  r := public.void_order_item(p_item, p_reason);
  perform private.pin_as_end();
  return jsonb_build_object('ok', true, 'approved_by', v->'approved_by',
                            'approved_by_name', v->'approved_by_name', 'item', to_jsonb(r));
end $$;
revoke all on function public.pin_void_order_item(uuid, text, text) from public, anon;
grant execute on function public.pin_void_order_item(uuid, text, text) to authenticated;

create or replace function public.pin_approve_void_request(p_request uuid, p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb; r public.void_requests%rowtype;
begin
  perform private.pin_assert_branch((select order_id from public.void_requests where id = p_request));
  v := private.pin_verify(p_pin, 'voids.approve');
  if not (v->>'ok')::boolean then return v; end if;
  perform private.pin_as_begin(v);
  r := public.approve_void_request(p_request, 'Manager PIN at the counter');
  perform private.pin_as_end();
  return jsonb_build_object('ok', true, 'approved_by', v->'approved_by',
                            'approved_by_name', v->'approved_by_name', 'request', to_jsonb(r));
end $$;
revoke all on function public.pin_approve_void_request(uuid, text) from public, anon;
grant execute on function public.pin_approve_void_request(uuid, text) to authenticated;

create or replace function public.pin_apply_discount(
  p_order_id uuid, p_template_id uuid, p_id_ref text, p_covered_amount numeric, p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb; r public.applied_discounts%rowtype;
begin
  perform private.pin_assert_branch(p_order_id);
  v := private.pin_verify(p_pin, 'discounts.apply');
  if not (v->>'ok')::boolean then return v; end if;
  perform private.pin_as_begin(v);
  r := public.apply_discount(p_order_id, p_template_id, p_id_ref, p_covered_amount);
  perform private.pin_as_end();
  return jsonb_build_object('ok', true, 'approved_by', v->'approved_by',
                            'approved_by_name', v->'approved_by_name', 'discount', to_jsonb(r));
end $$;
revoke all on function public.pin_apply_discount(uuid, uuid, text, numeric, text) from public, anon;
grant execute on function public.pin_apply_discount(uuid, uuid, text, numeric, text) to authenticated;

create or replace function public.pin_remove_discount(p_applied_id uuid, p_reason text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb; r public.applied_discounts%rowtype;
begin
  perform private.pin_assert_branch((select order_id from public.applied_discounts where id = p_applied_id));
  v := private.pin_verify(p_pin, 'discounts.apply');
  if not (v->>'ok')::boolean then return v; end if;
  perform private.pin_as_begin(v);
  r := public.remove_discount(p_applied_id, p_reason);
  perform private.pin_as_end();
  return jsonb_build_object('ok', true, 'approved_by', v->'approved_by',
                            'approved_by_name', v->'approved_by_name', 'discount', to_jsonb(r));
end $$;
revoke all on function public.pin_remove_discount(uuid, text, text) from public, anon;
grant execute on function public.pin_remove_discount(uuid, text, text) to authenticated;

create or replace function public.pin_refund(p_payment_id uuid, p_amount numeric, p_reason text, p_pin text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb; st text;
begin
  perform private.pin_assert_branch((select order_id from public.payments where id = p_payment_id));
  v := private.pin_verify(p_pin, 'payments.refund');
  if not (v->>'ok')::boolean then return v; end if;
  perform private.pin_as_begin(v);
  st := public.refund_payment(p_payment_id, p_amount, p_reason);
  perform private.pin_as_end();
  return jsonb_build_object('ok', true, 'approved_by', v->'approved_by',
                            'approved_by_name', v->'approved_by_name', 'payment_status', st);
end $$;
revoke all on function public.pin_refund(uuid, numeric, text, text) from public, anon;
grant execute on function public.pin_refund(uuid, numeric, text, text) to authenticated;

create or replace function public.pin_check(p_pin text, p_permission text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v jsonb;
begin
  if not exists (select 1 from public.permissions where key = p_permission) then
    raise exception 'unknown_permission' using errcode = '22023';
  end if;
  v := private.pin_verify(p_pin, p_permission);
  if not (v->>'ok')::boolean then return v; end if;
  perform private.pin_as_begin(v);
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'pin.approve', 'staff', (v->>'caller')::uuid,
          jsonb_build_object('permission', p_permission));
  perform private.pin_as_end();
  return jsonb_build_object('ok', true, 'approved_by', v->'approved_by',
                            'approved_by_name', v->'approved_by_name');
end $$;
revoke all on function public.pin_check(text, text) from public, anon;
grant execute on function public.pin_check(text, text) to authenticated;

-- ── Part 2: 49_manager_pin_no_pin_set ───────────────────────────
-- sql/49-manager-pin.sql, final pin_verify: no_pin_set when nobody in the branch has a PIN yet.
create or replace function private.pin_verify(p_pin text, p_key text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  me    public.staff%rowtype;
  mgr   public.staff%rowtype;
  v_pin text := btrim(coalesce(p_pin, ''));
begin
  select * into me from public.staff
   where id = auth.uid() and coalesce(employment_status, 'active') = 'active';
  if not found then raise exception 'no_staff_profile' using errcode = '42501'; end if;

  if private.pin_recent_fails(me.id) >= 5 then
    return jsonb_build_object('ok', false, 'error', 'pin_locked');
  end if;

  -- Nobody in this branch has a PIN yet: say so (not a miss).
  if not exists (select 1 from private.staff_pins p join public.staff s on s.id = p.staff_id
                  where s.branch_id = me.branch_id and coalesce(s.employment_status, 'active') = 'active') then
    return jsonb_build_object('ok', false, 'error', 'no_pin_set');
  end if;

  if v_pin ~ '^[0-9]{4,6}$' then
    select s.* into mgr
      from private.staff_pins p
      join public.staff s on s.id = p.staff_id
     where s.branch_id = me.branch_id
       and coalesce(s.employment_status, 'active') = 'active'
       and p.pin_hash = extensions.crypt(v_pin, p.pin_hash)
     order by p.set_at
     limit 1;
  end if;

  if mgr.id is null then
    insert into private.pin_fails (staff_id) values (me.id);
    insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
    values (me.id, me.role, 'pin.bad', 'staff', me.id,
            jsonb_build_object('permission', p_key, 'misses', private.pin_recent_fails(me.id)));
    if private.pin_recent_fails(me.id) >= 5 then
      return jsonb_build_object('ok', false, 'error', 'pin_locked');
    end if;
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;

  if not private.pin_eligible(mgr.id) or not private.can_staff(mgr.id, p_key) then
    raise exception 'pin_not_allowed: %', p_key using errcode = '42501';
  end if;

  delete from private.pin_fails where staff_id = me.id;
  return jsonb_build_object('ok', true, 'caller', me.id, 'staff_id', mgr.id,
                            'approved_by', mgr.id,
                            'approved_by_name', split_part(btrim(mgr.full_name), ' ', 1));
end $$;
revoke all on function private.pin_verify(text, text) from public, anon, authenticated;
