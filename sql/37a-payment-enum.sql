-- ═══════════════════════════════════════════════════════════════
-- 37a · New payment_method values (run ALONE, before 37)
-- An enum value cannot be added and used in the same transaction.
-- ═══════════════════════════════════════════════════════════════
alter type public.payment_method add value if not exists 'qrph';
