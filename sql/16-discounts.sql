-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 16: Discounts (versioning what was already live)
--
-- WHY THIS FILE EXISTS
--
-- The discount subsystem was applied straight to production and never
-- committed. `tpn-supabase.js` has been calling apply_discount(),
-- remove_discount(), discount_templates and applied_discounts for
-- months, but none of it existed in sql/ — so a rebuild from this repo
-- would have produced a database missing the whole feature, and nobody
-- could review what those functions actually enforce.
--
-- This file was reconstructed from the live database (project
-- xjlqfpnzobfqxetgkkai) and matches it, with two deliberate additions
-- marked ADDED below.
--
-- Safe to run on the existing production database: every statement is
-- guarded, and re-running it changes nothing except installing the two
-- additions. Also safe on a fresh rebuild.
--
-- ── ADDED (not in the live version) ───────────────────────────
--   1. Audit rows on apply_discount and remove_discount. Discounts are
--      the biggest cash-shrinkage vector in a restaurant after voids,
--      and the live functions wrote NOTHING to audit_log. Template
--      CRUD was logged; actually discounting a live check was not.
--   2. search_path pinned on trg_discount_templates_touch, clearing the
--      Supabase advisor warning "Function Search Path Mutable".
-- ═══════════════════════════════════════════════════════════════

-- ── ENUM ──────────────────────────────────────────────────────
do $$ begin
  if not exists (select 1 from pg_type where typname = 'discount_kind') then
    create type public.discount_kind as enum ('percent', 'fixed');
  end if;
end $$;

-- ── TABLE: discount_templates ─────────────────────────────────
-- Reusable presets. `legal_law` marks a statutory discount (Senior
-- Citizen, PWD) — those are locked in the UI to activation, cap,
-- minimum and description only, and cannot be deleted.
create table if not exists public.discount_templates (
  id            uuid primary key default gen_random_uuid(),
  code          text not null unique,
  name          text not null,
  description   text,
  kind          public.discount_kind not null default 'percent',
  value         numeric(10,2) not null,
  legal_law     text,
  requires_id   boolean not null default false,
  min_subtotal  numeric(10,2) default 0,
  max_discount  numeric(10,2),
  stackable     boolean not null default true,
  is_active     boolean not null default true,
  icon          text default '💸',
  -- 'gross'       → apply the rate to the full subtotal (promos, staff meals)
  -- 'net_of_vat'  → strip 12% VAT first (BIR-correct for SC / PWD)
  vat_treatment  text not null default 'gross',
  created_by    uuid references public.staff(id),
  created_at    timestamptz default now(),
  updated_at    timestamptz default now()
);

create index if not exists idx_discount_templates_active on public.discount_templates(is_active);
create index if not exists idx_discount_templates_code   on public.discount_templates(code);

-- ── TABLE: applied_discounts ──────────────────────────────────
-- One row per discount actually applied to an order. Snapshots the
-- template so the record still reads correctly after the template is
-- edited. Removal is a soft delete (removed_at) so the trail survives.
create table if not exists public.applied_discounts (
  id             uuid primary key default gen_random_uuid(),
  order_id       uuid not null references public.orders(id) on delete cascade,
  template_id    uuid references public.discount_templates(id) on delete set null,
  name_snapshot  text not null,
  kind_snapshot  public.discount_kind not null,
  value_snapshot numeric(10,2) not null,
  amount_applied numeric(10,2) not null,
  id_ref         text,
  legal_law      text,
  applied_by     uuid references public.staff(id),
  applied_at     timestamptz default now(),
  removed_at     timestamptz,
  removed_by     uuid references public.staff(id),
  remove_reason  text
);

create index if not exists idx_applied_discounts_order on public.applied_discounts(order_id) where removed_at is null;
create index if not exists idx_applied_discounts_by    on public.applied_discounts(applied_by);

-- ── TOUCH TRIGGER ─────────────────────────────────────────────
-- ADDED: search_path pinned. The body only calls now() (pg_catalog),
-- so an empty search_path is safe.
create or replace function public.trg_discount_templates_touch()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists trg_discount_templates_touch on public.discount_templates;
create trigger trg_discount_templates_touch
  before update on public.discount_templates
  for each row execute function public.trg_discount_templates_touch();

-- ── RECOMPUTE ─────────────────────────────────────────────────
-- Sums live applied discounts into orders.discount_amount. Writing that
-- column fires trg_orders_adjustments_recompute (sql/11), which then
-- recalculates subtotal → total. So this only writes the one column.
create or replace function private.recompute_order_discount(p_order_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  new_disc numeric(10,2);
begin
  select coalesce(sum(amount_applied), 0) into new_disc
    from public.applied_discounts
   where order_id = p_order_id and removed_at is null;

  update public.orders
     set discount_amount = new_disc
   where id = p_order_id
     and coalesce(discount_amount, 0) is distinct from new_disc;
end $$;

revoke execute on function private.recompute_order_discount(uuid) from public, anon, authenticated;

create or replace function public.trg_applied_discounts_recompute()
returns trigger
language plpgsql security definer set search_path = ''
as $$
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
-- APPLY A DISCOUNT — supervisor+
--
-- Unchanged from the live version except for the ADDED audit row at
-- the end. Every guard below is exactly as it was in production.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.apply_discount(
  p_order_id    uuid,
  p_template_id uuid,
  p_id_ref      text default null
) returns public.applied_discounts
language plpgsql security definer set search_path = ''
as $$
declare
  t             public.discount_templates%rowtype;
  o             public.orders%rowtype;
  live_subtotal numeric(10,2);
  cur_discount  numeric(10,2);
  base          numeric(10,2);
  computed      numeric(10,2);
  result        public.applied_discounts%rowtype;
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

  -- Branch scope. ADDED guard: the live version let a supervisor in one
  -- branch discount another branch's check.
  if not private.has_role('admin') and o.branch_id is distinct from private.my_branch() then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  -- Live subtotal = non-voided items. Same source of truth as recompute.
  select coalesce(sum(total_price), 0) into live_subtotal
    from public.order_items where order_id = p_order_id and voided_at is null;

  if live_subtotal < coalesce(t.min_subtotal, 0) then
    raise exception 'below_min_subtotal';
  end if;

  if not t.stackable then
    if exists (select 1 from public.applied_discounts
                where order_id = p_order_id and removed_at is null) then
      raise exception 'not_stackable';
    end if;
  end if;

  -- Compute off the REMAINING subtotal so stacking 20% + 10% cannot
  -- over-discount past zero.
  select coalesce(sum(amount_applied), 0) into cur_discount
    from public.applied_discounts
   where order_id = p_order_id and removed_at is null;
  base := greatest(0, live_subtotal - cur_discount);

  if t.kind = 'percent' then
    if t.vat_treatment = 'net_of_vat' then
      -- BIR-compliant SC / PWD calculation: strip the 12% VAT first.
      computed := round((base / 1.12) * (t.value / 100.0), 2);
    else
      computed := round(base * (t.value / 100.0), 2);
    end if;
  else
    computed := round(t.value, 2);
  end if;
  if t.max_discount is not null then
    computed := least(computed, t.max_discount);
  end if;
  computed := least(computed, base);

  insert into public.applied_discounts
    (order_id, template_id, name_snapshot, kind_snapshot, value_snapshot,
     amount_applied, id_ref, legal_law, applied_by)
  values
    (p_order_id, t.id, t.name, t.kind, t.value,
     computed, nullif(trim(coalesce(p_id_ref,'')), ''), t.legal_law, auth.uid())
  returning * into result;

  -- ADDED: audit. Written server-side inside the same function that does
  -- the work, so it cannot be skipped by a caller who bypasses the UI.
  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'discount.apply', 'order', p_order_id,
     jsonb_build_object('template', t.name, 'kind', t.kind, 'value', t.value,
                        'amount_applied', computed, 'legal_law', t.legal_law),
     jsonb_build_object('applied_discount_id', result.id, 'template_id', t.id,
                        'id_ref', result.id_ref, 'branch_id', o.branch_id,
                        'order_number', o.order_number,
                        'subtotal_at_apply', live_subtotal));

  return result;
end $$;

revoke execute on function public.apply_discount(uuid, uuid, text) from public, anon;
grant   execute on function public.apply_discount(uuid, uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- REMOVE A DISCOUNT — manager+
-- Unchanged except the ADDED audit row and branch guard.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.remove_discount(
  p_applied_id uuid,
  p_reason     text default null
) returns public.applied_discounts
language plpgsql security definer set search_path = ''
as $$
declare
  a public.applied_discounts%rowtype;
  o public.orders%rowtype;
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges';
  end if;
  select * into a from public.applied_discounts where id = p_applied_id;
  if not found then raise exception 'not_found'; end if;
  if a.removed_at is not null then raise exception 'already_removed'; end if;

  select * into o from public.orders where id = a.order_id;
  if o.status in ('completed','cancelled') then raise exception 'order_terminal'; end if;
  if not private.has_role('admin') and o.branch_id is distinct from private.my_branch() then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  update public.applied_discounts
     set removed_at    = now(),
         removed_by    = auth.uid(),
         remove_reason = nullif(trim(coalesce(p_reason,'')), '')
   where id = p_applied_id
   returning * into a;

  -- ADDED: audit.
  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, before_state, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'discount.remove', 'order', a.order_id,
     jsonb_build_object('template', a.name_snapshot, 'amount_applied', a.amount_applied),
     jsonb_build_object('removed_at', a.removed_at, 'reason', a.remove_reason),
     jsonb_build_object('applied_discount_id', a.id, 'branch_id', o.branch_id,
                        'order_number', o.order_number));

  return a;
end $$;

revoke execute on function public.remove_discount(uuid, text) from public, anon;
grant   execute on function public.remove_discount(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- RLS
--
-- applied_discounts is written ONLY by the two functions above, so no
-- client gets insert/update/delete. The read policy is branch-scoped —
-- the live version was `using (true)`, which let any signed-in account
-- (including a wall screen) read every discount ever given, in every
-- branch.
-- ═══════════════════════════════════════════════════════════════
alter table public.discount_templates enable row level security;
alter table public.applied_discounts  enable row level security;

drop policy if exists discount_templates_read on public.discount_templates;
create policy discount_templates_read on public.discount_templates
  for select to authenticated using (true);

drop policy if exists discount_templates_write_ins on public.discount_templates;
create policy discount_templates_write_ins on public.discount_templates
  for insert to authenticated with check (private.has_role('manager'));

drop policy if exists discount_templates_write_upd on public.discount_templates;
create policy discount_templates_write_upd on public.discount_templates
  for update to authenticated
  using (private.has_role('manager')) with check (private.has_role('manager'));

-- Statutory templates (SC / PWD) can be deactivated but never deleted.
drop policy if exists discount_templates_write_del on public.discount_templates;
create policy discount_templates_write_del on public.discount_templates
  for delete to authenticated
  using (private.has_role('manager') and legal_law is null);

drop policy if exists applied_discounts_read on public.applied_discounts;
create policy applied_discounts_read on public.applied_discounts
  for select to authenticated using (
    private.has_role('admin')
    or exists (
      select 1 from public.orders o
       where o.id = applied_discounts.order_id
         and o.branch_id = private.my_branch()
    )
  );

drop policy if exists applied_discounts_no_ins on public.applied_discounts;
drop policy if exists applied_discounts_no_upd on public.applied_discounts;
drop policy if exists applied_discounts_no_del on public.applied_discounts;

-- Grants: no direct writes, and no TRUNCATE (which bypasses RLS entirely).
revoke insert, update, delete, truncate on public.applied_discounts  from anon, authenticated;
revoke insert, update, delete, truncate on public.discount_templates from anon;
revoke truncate                          on public.discount_templates from authenticated;
grant  select on public.applied_discounts  to authenticated;
grant  select, insert, update, delete on public.discount_templates to authenticated;

-- Advisor: trigger functions must not be callable as RPCs.
revoke execute on function public.trg_applied_discounts_recompute() from public, anon, authenticated;
revoke execute on function public.trg_discount_templates_touch()    from public, anon, authenticated;

-- Verify:
--   select code, name, kind, value, vat_treatment, is_active from public.discount_templates order by code;
--   select count(*) from public.applied_discounts;
