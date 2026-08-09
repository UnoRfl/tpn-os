-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 07: Single-branch adjustments
-- Run after 06. Lets manager+ read the audit log (owner needs it),
-- and cleans up other branches if you seeded them earlier.
-- ═══════════════════════════════════════════════════════════════

-- Allow manager+ to read audit log (was director+)
drop policy if exists audit_read on public.audit_log;
create policy audit_read on public.audit_log
  for select to authenticated using (private.has_role('manager'));

-- OPTIONAL: remove the extra branches if you seeded them and only want Las Piñas.
-- Uncomment the lines below to run. Orders/tables tied to them must be gone first.
-- delete from public.restaurant_tables where branch_id in (select id from public.branches where code in ('bacoor','tgt'));
-- delete from public.branches where code in ('bacoor','tgt');
