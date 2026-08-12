-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 15: Discounts
--
-- What this adds:
--   - `public.discount_presets` — manager-configurable list of discount
--     types (Senior Citizen 20%, PWD 20%, Employee %, Custom, etc.)
--   - Columns on `public.orders` for the applied discount (label,
--     preset_id, reference number for Senior/PWD ID)
--   - RPCs `apply_discount` and `remove_discount` — enforce the rules
--     (validity, min order, usage limit, reference required) and
--     recompute the order total.
--   - Seeds the common Philippine discount types.
--
-- Design notes:
--   - One discount per order (stacking not supported yet).
--   - `orders.discount` is still the actual peso amount; the trigger
--     from migration 11 already recomputes `total` when it changes.
--   - Special / limited / exclusive discounts are just presets with
--     restrictions filled in (validity dates, min amount, usage cap,
--     manager-only role gate).
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- 1. PRESETS TABLE
-- ═══════════════════════════════════════════════════════════════

do $$ begin
  if not exists (select 1 from pg_type where typname = 'discount_kind') then
    create type discount_kind as enum ('percent', 'fixed');
  end if;
end $$;

create table if not exists public.discount_presets (
  id                  uuid primary key default gen_random_uuid(),
  name                text not null,                -- "Senior Citizen"
  description         text,                          -- shown on hover in the picker
  kind                discount_kind not null,        -- percent or fixed peso
  value               numeric(10,2) not null,        -- 20 for 20%, or 100 for ₱100
  applies_to          text not null default 'subtotal' check (applies_to in ('subtotal','total')),
  requires_reference  boolean default false,         -- must staff enter a Senior/PWD ID?
  reference_label     text,                          -- "Senior Citizen ID #"
  is_active           boolean default true,          -- master on/off
  is_special          boolean default false,         -- promo / limited-time / exclusive
  role_required       staff_role default 'dining',   -- min role to apply
  valid_from          timestamptz,                   -- null = no start restriction
  valid_until         timestamptz,                   -- null = no end restriction
  min_order_amount    numeric(10,2),                 -- null = no minimum
  max_discount_amount numeric(10,2),                 -- null = no cap
  usage_limit         int,                            -- total times allowed; null = unlimited
  usage_count         int default 0,
  branch_id           uuid references public.branches(id) on delete cascade,  -- null = all branches
  color               text default '#B8800F',        -- for the picker chip
  emoji               text default '🎟️',
  sort_order          int default 0,
  created_by          uuid references public.staff(id) on delete set null,
  created_at          timestamptz default now(),
  updated_at          timestamptz default now()
);

create index if not exists idx_discount_presets_active on public.discount_presets(is_active, sort_order);
create index if not exists idx_discount_presets_branch on public.discount_presets(branch_id);

-- RLS: authenticated staff read; manager+ writes.
alter table public.discount_presets enable row level security;

drop policy if exists discount_presets_read on public.discount_presets;
create policy discount_presets_read on public.discount_presets
  for select to authenticated using (
    branch_id is null
    or branch_id = private.my_branch()
    or private.has_role('admin')
  );

drop policy if exists discount_presets_write on public.discount_presets;
create policy discount_presets_write on public.discount_presets
  for all to authenticated using (
    private.has_role('manager')
  ) with check (
    private.has_role('manager')
  );

-- ═══════════════════════════════════════════════════════════════
-- 2. ORDER COLUMNS for the applied discount
-- ═══════════════════════════════════════════════════════════════
alter table public.orders
  add column if not exists discount_label       text,
  add column if not exists discount_preset_id   uuid references public.discount_presets(id) on delete set null,
  add column if not exists discount_reference   text,   -- e.g. Senior Citizen ID #
  add column if not exists discount_applied_by  uuid references public.staff(id) on delete set null,
  add column if not exists discount_applied_at  timestamptz;

-- ═══════════════════════════════════════════════════════════════
-- 3. APPLY / REMOVE RPCs
-- ═══════════════════════════════════════════════════════════════

create or replace function public.apply_discount(
  p_order_id     uuid,
  p_preset_id    uuid,
  p_reference    text default null,
  p_custom_value numeric default null    -- only used when preset.kind='percent' and preset.value=0 (Custom preset)
)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o          public.orders%rowtype;
  ps         public.discount_presets%rowtype;
  eff_value  numeric;
  disc_amt   numeric;
  base       numeric;
  who        uuid;
begin
  who := auth.uid();
  if who is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;

  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found' using errcode = 'P0002';
  end if;

  -- Must not modify a terminal order.
  if o.status in ('completed', 'cancelled') then
    raise exception 'order_is_%_cannot_modify', o.status using errcode = 'P0001';
  end if;

  select * into ps from public.discount_presets where id = p_preset_id;
  if not found then
    raise exception 'preset_not_found' using errcode = 'P0002';
  end if;

  -- Preset activation checks
  if not ps.is_active then
    raise exception 'preset_inactive' using errcode = 'P0001';
  end if;

  -- Role check: staff calling this must meet the preset's required role.
  if not private.has_role(ps.role_required) then
    raise exception 'preset_requires_%_role', ps.role_required using errcode = '42501';
  end if;

  -- Validity window
  if ps.valid_from is not null and now() < ps.valid_from then
    raise exception 'preset_not_yet_valid' using errcode = 'P0001';
  end if;
  if ps.valid_until is not null and now() > ps.valid_until then
    raise exception 'preset_expired' using errcode = 'P0001';
  end if;

  -- Usage limit
  if ps.usage_limit is not null and ps.usage_count >= ps.usage_limit then
    raise exception 'preset_usage_limit_reached' using errcode = 'P0001';
  end if;

  -- Branch match
  if ps.branch_id is not null and ps.branch_id <> o.branch_id then
    raise exception 'preset_wrong_branch' using errcode = 'P0001';
  end if;

  -- Reference requirement (Senior / PWD ID etc.)
  if ps.requires_reference and (p_reference is null or trim(p_reference) = '') then
    raise exception 'preset_requires_reference' using errcode = 'P0001';
  end if;

  -- Minimum order
  if ps.min_order_amount is not null and o.subtotal < ps.min_order_amount then
    raise exception 'order_below_minimum' using errcode = 'P0001';
  end if;

  -- Effective value: for Custom preset (percent with value=0), take p_custom_value.
  eff_value := ps.value;
  if ps.kind = 'percent' and ps.value = 0 and p_custom_value is not null then
    eff_value := p_custom_value;
  end if;
  if ps.kind = 'fixed'   and ps.value = 0 and p_custom_value is not null then
    eff_value := p_custom_value;
  end if;

  -- Compute amount
  base := case when ps.applies_to = 'total' then (o.subtotal + coalesce(o.service_charge, 0))
                                             else o.subtotal end;
  if ps.kind = 'percent' then
    disc_amt := round(base * (eff_value / 100.0), 2);
  else
    disc_amt := round(eff_value, 2);
  end if;

  -- Cap
  if ps.max_discount_amount is not null and disc_amt > ps.max_discount_amount then
    disc_amt := ps.max_discount_amount;
  end if;

  -- Never let discount push total below zero
  if disc_amt > (o.subtotal + coalesce(o.service_charge, 0)) then
    disc_amt := o.subtotal + coalesce(o.service_charge, 0);
  end if;

  -- Apply. Order.total will be recomputed by trigger from migration 11.
  update public.orders
     set discount             = disc_amt,
         discount_label       = ps.name,
         discount_preset_id   = ps.id,
         discount_reference   = nullif(trim(p_reference), ''),
         discount_applied_by  = who,
         discount_applied_at  = now(),
         total                = greatest(0, subtotal + coalesce(service_charge, 0) - disc_amt),
         updated_at           = now()
   where id = p_order_id;

  -- Bump usage counter (best-effort; not fatal if it fails).
  update public.discount_presets
     set usage_count = usage_count + 1, updated_at = now()
   where id = ps.id;

  -- Audit entry (audit_log table exists from migration 01).
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, details)
    values (who,
           (select role from public.staff where id = who),
           'discount.applied', 'order', p_order_id,
           jsonb_build_object(
             'preset_id', ps.id,
             'label',     ps.name,
             'amount',    disc_amt,
             'reference', p_reference));

  return jsonb_build_object(
    'order_id',       p_order_id,
    'discount_label', ps.name,
    'discount',       disc_amt,
    'new_total',      greatest(0, o.subtotal + coalesce(o.service_charge, 0) - disc_amt));
end $$;

grant execute on function public.apply_discount(uuid, uuid, text, numeric) to authenticated;
revoke execute on function public.apply_discount(uuid, uuid, text, numeric) from public, anon;

-- Remove a previously applied discount.
create or replace function public.remove_discount(p_order_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o    public.orders%rowtype;
  who  uuid := auth.uid();
begin
  if who is null then
    raise exception 'not_authenticated' using errcode = '42501';
  end if;
  select * into o from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found' using errcode = 'P0002';
  end if;
  if o.status in ('completed', 'cancelled') then
    raise exception 'order_is_%_cannot_modify', o.status using errcode = 'P0001';
  end if;

  update public.orders
     set discount            = 0,
         discount_label      = null,
         discount_preset_id  = null,
         discount_reference  = null,
         discount_applied_by = null,
         discount_applied_at = null,
         total               = subtotal + coalesce(service_charge, 0),
         updated_at          = now()
   where id = p_order_id;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, details)
    values (who,
           (select role from public.staff where id = who),
           'discount.removed', 'order', p_order_id,
           jsonb_build_object('previous_amount', o.discount, 'previous_label', o.discount_label));

  return jsonb_build_object('order_id', p_order_id, 'discount', 0, 'new_total', o.subtotal + coalesce(o.service_charge, 0));
end $$;

grant execute on function public.remove_discount(uuid) to authenticated;
revoke execute on function public.remove_discount(uuid) from public, anon;

-- ═══════════════════════════════════════════════════════════════
-- 4. SEED — common Philippine discount presets
-- Only inserted if the table has no rows yet (fresh install).
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if not exists (select 1 from public.discount_presets) then
    insert into public.discount_presets
      (name, description, kind, value, requires_reference, reference_label, role_required, sort_order, emoji, color)
    values
      ('Senior Citizen', 'RA 9994 — 20% on food, valid Senior ID required.', 'percent', 20, true,  'Senior Citizen ID #', 'dining',  10, '👴', '#8B1A0E'),
      ('PWD',            'RA 10754 — 20% on food, valid PWD ID required.',  'percent', 20, true,  'PWD ID #',            'dining',  20, '♿', '#5C8A3A'),
      ('Solo Parent',    'RA 11861 — 10% on food, valid Solo Parent ID.',   'percent', 10, true,  'Solo Parent ID #',    'dining',  30, '👨‍👧', '#3A5C8A'),
      ('Employee',       'Staff meal — 15% off.',                            'percent', 15, false, null,                   'dining',  40, '👨‍🍳', '#B8800F'),
      ('Loyalty Regular','Frequent guest — 5% off.',                         'percent',  5, false, null,                   'dining',  50, '⭐', '#D4960F'),
      ('Custom (₱)',     'Enter a custom peso amount off.',                  'fixed',    0, false, null,                   'manager', 90, '✏️', '#6B4A35'),
      ('Custom (%)',     'Enter a custom percentage off.',                   'percent',  0, false, null,                   'manager', 91, '✏️', '#6B4A35');
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 5. LIST helper — returns only presets applicable RIGHT NOW.
-- Used by the picker so expired / not-yet-valid promos don't appear.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.list_active_discount_presets(p_branch_id uuid default null)
returns setof public.discount_presets
language sql security invoker set search_path = ''
as $$
  select * from public.discount_presets
   where is_active
     and (valid_from  is null or now() >= valid_from)
     and (valid_until is null or now() <= valid_until)
     and (usage_limit is null or usage_count < usage_limit)
     and (branch_id   is null or branch_id  = coalesce(p_branch_id, branch_id))
   order by sort_order, name;
$$;

grant execute on function public.list_active_discount_presets(uuid) to authenticated;

-- Done.
