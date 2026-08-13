-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 15a: Display device roles
--
-- ⚠️  RUN THIS FILE ON ITS OWN, FIRST, AND NOTHING ELSE WITH IT.
--
-- Postgres will not let you ADD a value to an enum and then USE
-- that value inside the same transaction. The Supabase SQL Editor
-- runs whatever you paste as one transaction. So this migration is
-- deliberately tiny: paste it, run it, wait for "Success", THEN
-- open sql/15b-void-requests.sql and run that separately.
--
-- WHAT THIS DOES
-- Adds two new roles to the staff_role enum:
--
--   kitchen_display  — the tablet/TV mounted in the kitchen
--   dine_in_display  — the tablet/TV on the dining floor
--
-- These are DEVICE accounts, not people. One shared login per screen.
-- They are placed BELOW 'dining' in the enum, which matters: the whole
-- permission system (private.has_role) compares enum positions, so
-- sitting at the bottom means these accounts automatically fail every
-- has_role() check in the database — no menu editing, no inquiries,
-- no audit log, no staff records, and critically NO VOIDING.
--
-- Final hierarchy after this migration (lowest → highest):
--   kitchen_display, dine_in_display, dining, kitchen,
--   supervisor, manager, admin, director, ceo
--
-- Nothing about existing accounts changes. This is additive only.
-- ═══════════════════════════════════════════════════════════════

alter type public.staff_role add value if not exists 'dine_in_display' before 'dining';
alter type public.staff_role add value if not exists 'kitchen_display' before 'dine_in_display';

-- Verify (optional — run this after and eyeball the order):
--   select unnest(enum_range(null::public.staff_role));
