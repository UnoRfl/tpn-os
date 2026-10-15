-- ═══════════════════════════════════════════════════════════════
-- 29a · New enum values                    ⚠️ RUN ALONE, FIRST
--
-- Postgres refuses to use an enum value in the same transaction that
-- added it, and the Supabase SQL Editor runs a paste as one transaction.
-- So this file only adds values; 29b onwards use them. Same reason as
-- sql/15a.
--
--   payment_method  + 'hitpay'  online payment through HitPay (QR Ph,
--                               GCash, Maya, cards). The wallet the guest
--                               actually used is recorded on payments.
--                   + 'bank'    bank transfer, how catering and office
--                               clients settle. (_prettyPayment already
--                               had a label for it; nothing wrote it.)
--   inquiry_type    + 'tasting' food tasting requests from the Events page
-- ═══════════════════════════════════════════════════════════════

alter type public.payment_method add value if not exists 'hitpay';
alter type public.payment_method add value if not exists 'bank';
alter type public.inquiry_type   add value if not exists 'tasting';
