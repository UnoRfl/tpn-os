-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 18: restore anonymous pickup/delivery ordering
--
-- BUG THIS FIXES
-- Placing a pickup or delivery order from the public website failed
-- with "new row violates row-level security policy for table orders",
-- which surfaces in the UI as a permissions error.
--
-- CAUSE
-- The live database was running the ORIGINAL policy from
-- sql/01-schema.sql, which permits anonymous inserts only when
-- order_type = 'dine_in'. sql/05-anon-orders.sql widened that to
-- ('dine_in','pickup','delivery') but its effect was not present in
-- production -- either 01 was replayed after 05, or 05 never ran.
-- Verified before this migration by inserting as role `anon`:
--   dine_in  -> OK
--   pickup   -> 42501 new row violates row-level security policy
--   delivery -> 42501 new row violates row-level security policy
--
-- WHILE WE ARE HERE
-- The old policy also let an anonymous caller assert anything else on
-- the row: status = 'done', payment_status = 'paid', a discount, or a
-- backdated completed_at. Nothing in the app does that, but the policy
-- allowed it. This migration pins every one of those to its default,
-- so an anonymous order can only ever arrive as an unpaid, pending,
-- undiscounted order. Money and lifecycle stay staff-only.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

-- ── orders ────────────────────────────────────────────────────
drop policy if exists orders_anon_create on public.orders;

create policy orders_anon_create on public.orders
  for insert to anon
  with check (
    -- the three order types a member of the public may create
    order_type in ('dine_in', 'pickup', 'delivery')

    -- a fresh order, never a pre-completed one
    and coalesce(status, 'pending') = 'pending'
    and coalesce(payment_status, 'pending') = 'pending'

    -- customers cannot price their own order
    and coalesce(service_charge, 0)   = 0
    and coalesce(discount, 0)         = 0
    and coalesce(discount_amount, 0)  = 0
    and discount_label       is null
    and discount_preset_id   is null
    and discount_reference   is null
    and discount_applied_by  is null
    and discount_applied_at  is null

    -- lifecycle timestamps belong to staff actions, not to the insert
    and confirmed_at is null
    and ready_at     is null
    and served_at    is null
    and completed_at is null
    and cancelled_at is null
  );

comment on policy orders_anon_create on public.orders is
  'Public checkout. Dine-in, pickup and delivery only; the row must arrive
   pending, unpaid and undiscounted. Totals are recomputed server-side from
   order_items by trg_order_items_recompute, so a client-supplied subtotal or
   total cannot survive.';

-- ── order_items ───────────────────────────────────────────────
-- Mirrors the parent policy: an anonymous caller may add lines to an
-- order only while that order is one of the three public types.
drop policy if exists order_items_anon_insert on public.order_items;

create policy order_items_anon_insert on public.order_items
  for insert to anon
  with check (
    exists (
      select 1
      from public.orders o
      where o.id = order_items.order_id
        and o.order_type in ('dine_in', 'pickup', 'delivery')
    )
  );

comment on policy order_items_anon_insert on public.order_items is
  'Public checkout line items. Non-negative quantities and prices are enforced
   separately by trg_order_items_nonneg.';
