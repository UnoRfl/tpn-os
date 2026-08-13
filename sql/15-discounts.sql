-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 15: Discount Templates + Applied Discounts
--
-- Introduces reusable discount presets and a per-order line of
-- discounts that were actually applied at checkout. The existing
-- orders.discount_amount column (added in sql/09) is now driven
-- automatically by a trigger that sums applied_discounts.
--
-- Idempotent — safe to re-run.
--
-- Roles:
--   • read templates            → any authenticated staff
--   • create/edit/delete templates → manager+ (legal-locked ones cannot be
--                                    deleted, only deactivated)
--   • apply discount            → supervisor+ (via RPC)
--   • remove applied discount   → manager+  (via RPC — treated like a void)
--
-- Seeds three legally-mandated Philippine discounts. See notes at
-- the bottom about VAT: this migration only touches the % / peso
-- reduction — VAT-exempt-input handling is a future concern.
-- ═══════════════════════════════════════════════════════════════

-- ── ENUM: discount kinds ───────────────────────────────────────
do $$
begin
  if not exists (select 1 from pg_type where typname = 'discount_kind') then
    create type discount_kind as enum ('percent', 'fixed');
  end if;
end $$;

-- ── TABLE: discount_templates (the presets Uno creates in the UI) ──
create table if not exists public.discount_templates (
  id           uuid primary key default gen_random_uuid(),
  code         text unique not null,               -- short slug, e.g. 'senior-citizen'
  name         text not null,                      -- display name
  description  text,
  kind         discount_kind not null default 'percent',
  value        numeric(10,2) not null,             -- percent (0-100) or peso amount
  legal_law    text,                               -- e.g. 'RA 9994' — non-null = locked template
  requires_id  boolean not null default false,     -- prompt cashier for ID number at apply time
  min_subtotal numeric(10,2) default 0,            -- optional order minimum
  max_discount numeric(10,2),                      -- optional cap (peso)
  stackable    boolean not null default true,      -- combine with other applied discounts on same order
  is_active    boolean not null default true,
  icon         text default '💸',
  -- 'gross'      → percent applied to the full subtotal (default; matches how StoreHub
  --                and most casual PH restaurants ring up promos)
  -- 'net_of_vat' → subtotal is first divided by 1.12 before the percent is applied.
  --                Required by BIR for Senior Citizen (RA 9994) and PWD (RA 10754)
  --                when issuing official receipts.
  -- Only affects percent kinds; fixed peso amounts are always literal.
  vat_treatment text not null default 'gross'
    check (vat_treatment in ('gross','net_of_vat')),
  created_by   uuid references public.staff(id),
  created_at   timestamptz default now(),
  updated_at   timestamptz default now(),
  constraint discount_value_bounds check (
    value >= 0
    and (kind <> 'percent' or value <= 100)
  )
);
-- Idempotent add for any envs that ran an earlier draft of this migration
alter table public.discount_templates
  add column if not exists vat_treatment text not null default 'gross';
do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'discount_templates_vat_treatment_check'
       and conrelid = 'public.discount_templates'::regclass
  ) then
    alter table public.discount_templates
      add constraint discount_templates_vat_treatment_check
      check (vat_treatment in ('gross','net_of_vat'));
  end if;
end $$;
create index if not exists idx_discount_templates_active on public.discount_templates(is_active);
create index if not exists idx_discount_templates_code   on public.discount_templates(code);

-- Auto-touch updated_at
create or replace function public.trg_discount_templates_touch()
returns trigger language plpgsql as $$
begin new.updated_at := now(); return new; end $$;
drop trigger if exists trg_discount_templates_touch on public.discount_templates;
create trigger trg_discount_templates_touch before update on public.discount_templates
  for each row execute function public.trg_discount_templates_touch();

-- ── TABLE: applied_discounts (the discounts actually on an order) ──
create table if not exists public.applied_discounts (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  template_id    uuid references public.discount_templates(id) on delete set null,
  name_snapshot  text not null,               -- captured at apply time — templates can change later
  kind_snapshot  discount_kind not null,
  value_snapshot numeric(10,2) not null,
  amount_applied numeric(10,2) not null,      -- the actual peso reduction at time of apply
  id_ref         text,                        -- e.g. Senior Citizen ID, PWD ID
  legal_law      text,                        -- carried from template for the receipt
  applied_by     uuid references public.staff(id),
  applied_at     timestamptz default now(),
  removed_at     timestamptz,
  removed_by     uuid references public.staff(id),
  remove_reason  text
);
create index if not exists idx_applied_discounts_order on public.applied_discounts(order_id)
  where removed_at is null;
create index if not exists idx_applied_discounts_by    on public.applied_discounts(applied_by);

-- ═══════════════════════════════════════════════════════════════
-- Recompute: sum non-removed applied_discounts into orders.discount_amount
-- ═══════════════════════════════════════════════════════════════
create or replace function private.recompute_order_discount(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_disc numeric(10,2);
begin
  select coalesce(sum(amount_applied), 0) into new_disc
    from public.applied_discounts
   where order_id = p_order_id and removed_at is null;

  -- Setting discount_amount fires the existing trg_orders_adjustments_recompute
  -- (see sql/11) which then updates subtotal → total. So we only need to write here.
  update public.orders
     set discount_amount = new_disc
   where id = p_order_id
     and coalesce(discount_amount, 0) is distinct from new_disc;
end $$;
revoke execute on function private.recompute_order_discount(uuid) from public, anon, authenticated;

create or replace function public.trg_applied_discounts_recompute()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'DELETE' then
    perform private.recompute_order_discount(old.order_id);
    return old;
  else
    perform private.recompute_order_discount(new.order_id);
    return new;
  end if;
end $$;
drop trigger if exists trg_applied_discounts_recompute_ins on public.applied_discounts;
drop trigger if exists trg_applied_discounts_recompute_upd on public.applied_discounts;
drop trigger if exists trg_applied_discounts_recompute_del on public.applied_discounts;
create trigger trg_applied_discounts_recompute_ins after insert on public.applied_discounts
  for each row execute function public.trg_applied_discounts_recompute();
create trigger trg_applied_discounts_recompute_upd after update on public.applied_discounts
  for each row execute function public.trg_applied_discounts_recompute();
create trigger trg_applied_discounts_recompute_del after delete on public.applied_discounts
  for each row execute function public.trg_applied_discounts_recompute();

-- ═══════════════════════════════════════════════════════════════
-- RPC: apply_discount — used by cashier at checkout
-- Server computes amount_applied so the client cannot fudge the number.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.apply_discount(
  p_order_id     uuid,
  p_template_id  uuid,
  p_id_ref       text default null
) returns applied_discounts
language plpgsql
security definer
set search_path = ''
as $$
declare
  t              public.discount_templates%rowtype;
  o              public.orders%rowtype;
  live_subtotal  numeric(10,2);
  cur_discount   numeric(10,2);
  base           numeric(10,2);
  computed       numeric(10,2);
  result         public.applied_discounts%rowtype;
begin
  if not private.has_role('supervisor') then
    raise exception 'insufficient_privileges';
  end if;
  if p_order_id is null or p_template_id is null then
    raise exception 'invalid_input';
  end if;

  select * into t from public.discount_templates where id = p_template_id;
  if not found then raise exception 'template_not_found'; end if;
  if not t.is_active then raise exception 'template_inactive'; end if;
  if t.requires_id and (p_id_ref is null or length(trim(p_id_ref)) < 3) then
    raise exception 'id_ref_required';
  end if;

  select * into o from public.orders where id = p_order_id;
  if not found then raise exception 'order_not_found'; end if;
  if o.status in ('completed','cancelled') then raise exception 'order_terminal'; end if;

  -- Live subtotal = sum of non-voided items. Same source of truth as recompute_order_totals.
  select coalesce(sum(total_price), 0) into live_subtotal
    from public.order_items where order_id = p_order_id and voided_at is null;

  if live_subtotal < coalesce(t.min_subtotal, 0) then
    raise exception 'below_min_subtotal';
  end if;

  -- If this template is non-stackable, refuse when other active discounts exist.
  if not t.stackable then
    if exists (select 1 from public.applied_discounts
                where order_id = p_order_id and removed_at is null) then
      raise exception 'not_stackable';
    end if;
  end if;

  -- Compute peso amount off the *remaining* subtotal after already-applied discounts,
  -- so stacking 20% + 10% doesn't over-discount past zero.
  select coalesce(sum(amount_applied), 0) into cur_discount
    from public.applied_discounts
   where order_id = p_order_id and removed_at is null;
  base := greatest(0, live_subtotal - cur_discount);

  if t.kind = 'percent' then
    -- BIR-compliant net-of-VAT: strip the 12% VAT from the base before applying rate.
    -- This mirrors the standard SC/PWD receipt calculation.
    if t.vat_treatment = 'net_of_vat' then
      computed := round((base / 1.12) * (t.value / 100.0), 2);
    else
      computed := round(base * (t.value / 100.0), 2);
    end if;
  else
    -- Fixed peso discounts: literal amount, VAT treatment is a no-op.
    computed := round(t.value, 2);
  end if;
  if t.max_discount is not null then
    computed := least(computed, t.max_discount);
  end if;
  computed := least(computed, base);   -- never negative total

  insert into public.applied_discounts
    (order_id, template_id, name_snapshot, kind_snapshot, value_snapshot,
     amount_applied, id_ref, legal_law, applied_by)
  values
    (p_order_id, t.id, t.name, t.kind, t.value,
     computed, nullif(trim(coalesce(p_id_ref,'')), ''), t.legal_law, auth.uid())
  returning * into result;

  return result;
end $$;
revoke execute on function public.apply_discount(uuid, uuid, text) from public, anon;
grant   execute on function public.apply_discount(uuid, uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- RPC: remove_discount — manager+ only (treat like a void)
-- Soft-delete so the audit trail survives.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.remove_discount(
  p_applied_id  uuid,
  p_reason      text default null
) returns applied_discounts
language plpgsql
security definer
set search_path = ''
as $$
declare
  a  public.applied_discounts%rowtype;
  o  public.orders%rowtype;
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges';
  end if;
  select * into a from public.applied_discounts where id = p_applied_id;
  if not found then raise exception 'not_found'; end if;
  if a.removed_at is not null then raise exception 'already_removed'; end if;
  select * into o from public.orders where id = a.order_id;
  if o.status in ('completed','cancelled') then raise exception 'order_terminal'; end if;

  update public.applied_discounts
     set removed_at    = now(),
         removed_by    = auth.uid(),
         remove_reason = nullif(trim(coalesce(p_reason,'')), '')
   where id = p_applied_id
   returning * into a;
  return a;
end $$;
revoke execute on function public.remove_discount(uuid, text) from public, anon;
grant   execute on function public.remove_discount(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- RLS
-- ═══════════════════════════════════════════════════════════════
alter table public.discount_templates enable row level security;
alter table public.applied_discounts  enable row level security;

drop policy if exists discount_templates_read      on public.discount_templates;
drop policy if exists discount_templates_write_ins on public.discount_templates;
drop policy if exists discount_templates_write_upd on public.discount_templates;
drop policy if exists discount_templates_write_del on public.discount_templates;

create policy discount_templates_read on public.discount_templates
  for select to authenticated using (true);

-- Manager+ can create / edit; legal-locked rows cannot be deleted (only deactivated).
create policy discount_templates_write_ins on public.discount_templates
  for insert to authenticated with check (private.has_role('manager'));
create policy discount_templates_write_upd on public.discount_templates
  for update to authenticated
  using  (private.has_role('manager'))
  with check (private.has_role('manager'));
create policy discount_templates_write_del on public.discount_templates
  for delete to authenticated using (
    private.has_role('manager') and legal_law is null
  );

-- Applied discounts: read same as order (any staff), write via RPC only.
drop policy if exists applied_discounts_read    on public.applied_discounts;
drop policy if exists applied_discounts_no_ins  on public.applied_discounts;
drop policy if exists applied_discounts_no_upd  on public.applied_discounts;
drop policy if exists applied_discounts_no_del  on public.applied_discounts;

create policy applied_discounts_read on public.applied_discounts
  for select to authenticated using (true);
-- No direct writes — everything goes through the SECURITY DEFINER RPCs above.
create policy applied_discounts_no_ins on public.applied_discounts
  for insert to authenticated with check (false);
create policy applied_discounts_no_upd on public.applied_discounts
  for update to authenticated using (false) with check (false);
create policy applied_discounts_no_del on public.applied_discounts
  for delete to authenticated using (false);

-- ═══════════════════════════════════════════════════════════════
-- SEEDS — Philippine legally-mandated discounts
-- Only inserted if the code doesn't already exist. is_active can be
-- flipped in the UI but the row itself cannot be deleted (RLS check
-- on delete requires legal_law is null).
-- ═══════════════════════════════════════════════════════════════
insert into public.discount_templates
  (code, name, description, kind, value, legal_law, requires_id, stackable, icon, vat_treatment)
values
  ('senior-citizen',
   'Senior Citizen',
   'Republic Act 9994 — 20% off for senior citizens (60+). Applied net-of-VAT per BIR. Requires senior citizen ID at checkout.',
   'percent', 20, 'RA 9994', true, false, '👴', 'net_of_vat'),
  ('pwd',
   'Person with Disability',
   'Republic Act 10754 — 20% off for PWDs. Applied net-of-VAT per BIR. Requires PWD ID at checkout.',
   'percent', 20, 'RA 10754', true, false, '♿', 'net_of_vat'),
  ('solo-parent',
   'Solo Parent',
   'Republic Act 11861 — 10% off for solo parents earning below the poverty threshold. Applied on gross (not VAT-exempt by law). Requires Solo Parent ID.',
   'percent', 10, 'RA 11861', true, true, '👨‍👧', 'gross')
on conflict (code) do nothing;

-- Backfill vat_treatment for the two legal-locked templates in case a previous
-- draft of this migration seeded them without the column.
update public.discount_templates set vat_treatment = 'net_of_vat'
 where code in ('senior-citizen','pwd') and vat_treatment = 'gross';

-- ═══════════════════════════════════════════════════════════════
-- NOTE: VAT handling is per-template via the vat_treatment column.
--   • 'gross'      → percent applied to full subtotal.  Use for
--                    marketing promos (Loyalty 10%, Wrapsa Dahon
--                    launch, etc.) and Solo Parent (not VAT-exempt).
--   • 'net_of_vat' → subtotal ÷ 1.12 before percent applied.  BIR-
--                    correct for Senior Citizen and PWD when issuing
--                    official receipts.
-- The VAT rate is hardcoded to 12% (PH standard).  Fixed peso
-- discounts ignore vat_treatment — the amount is literal.
-- ═══════════════════════════════════════════════════════════════

-- ═══════════════════════════════════════════════════════════════
-- Backfill: recompute discount for every order (no-op for orders
-- with no applied_discounts rows).
-- ═══════════════════════════════════════════════════════════════
do $$
declare r record;
begin
  for r in select id from public.orders loop
    perform private.recompute_order_discount(r.id);
  end loop;
end $$;
