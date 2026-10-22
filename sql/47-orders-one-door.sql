-- ═══════════════════════════════════════════════════════════════
-- 47 — orders have one door: submit_order (Oct 22, 2026)
--
-- Found in the Oct 22 full test: policy orders_auth_create still let any
-- signed-in staff account (dining tier up) insert a row into orders
-- directly through the API — any total, already 'paid' and 'completed',
-- no items, no payment. Checked on production in a rolled-back
-- transaction: a dining account inserted a ₱1 order marked paid.
--
-- Nothing in the app inserts into orders directly: the website, the QR
-- menu, the counter and the offline outbox all call submit_order
-- (SECURITY DEFINER, server-side prices, idempotency key), which runs as
-- the table owner and is not affected by this change.
-- ═══════════════════════════════════════════════════════════════

drop policy if exists orders_auth_create on public.orders;
drop policy if exists orders_anon_create on public.orders;
revoke insert on public.orders from anon, authenticated;
