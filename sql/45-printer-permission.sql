-- ═══════════════════════════════════════════════════════════════
-- 45 — printer tools are for managers (Oct 22, 2026)
--
-- The counter's printer menu has test prints, the no-sale drawer
-- button, auto-print and the kitchen printer's address. The owner
-- wants those kept from regular staff: they still see whether the
-- printer is ready and can tap Reconnect.
--
-- Nothing on the server uses this key yet (printing and the no-sale
-- button are on the device); it decides what the menu shows, and the
-- owner can hand it to any role in the roles editor.
-- ═══════════════════════════════════════════════════════════════

select private.add_permission('printer.manage', 'Administration', 'Printer tools', 'Mga gamit ng printer',
  'Test prints, the no-sale drawer button, auto-print and the kitchen printer address on the counter.', 'manager', 95);
