-- ═══════════════════════════════════════════════════════════════
-- 53 — a sold-out dish stays on the menu, marked sold out (Oct 25, 2026)
--
-- menu_items.is_available meant two things: "sold out today" (the 86
-- button) and "not on the menu". The read policy (sql/01) returned only
-- available dishes, so:
--   • guests: an 86'd dish vanished from the website and the table QR menu
--     instead of showing "Sold out" (Rev 36 finding). Both pages already
--     draw sold-out cards; they never received any.
--   • kitchen and dining staff: the 86 list (Kitchen queue → Sold out, and
--     the floor's Menu tab) read the same table, so a dish a cook marked
--     sold out disappeared from that cook's own list and only a manager
--     could switch it back on.
--
-- Now two columns, two meanings:
--   is_listed     on the menu at all (Menu → edit dish → "On the menu").
--                 Off = gone from every menu. Managers only (menu_items_write).
--   is_available  available today. Off = sold out: still listed, greyed
--                 out, no add button. set_item_available (menu.86) as before.
-- Everyone reads listed dishes. submit_order still refuses a sold-out one.
-- On Oct 25 production had no unavailable dishes, so nothing moves.
-- ═══════════════════════════════════════════════════════════════

alter table public.menu_items add column if not exists is_listed boolean not null default true;
comment on column public.menu_items.is_listed is
  'On the menu at all. False hides the dish everywhere. is_available = false only marks it sold out (sql/53).';

drop policy if exists menu_items_read on public.menu_items;
create policy menu_items_read on public.menu_items
  for select to anon, authenticated using (is_listed);

-- submit_order checks is_available only. A dish taken off the menu is
-- never orderable (an old cart or a direct call could still name it), so
-- unlisting also switches it off; relisting leaves that to the manager.
create or replace function private.trg_menu_unlisted_unavailable()
returns trigger language plpgsql set search_path = '' as $$
begin
  if not new.is_listed then new.is_available := false; end if;
  return new;
end $$;
revoke all on function private.trg_menu_unlisted_unavailable() from public, anon, authenticated;
drop trigger if exists trg_menu_unlisted_unavailable on public.menu_items;
create trigger trg_menu_unlisted_unavailable before insert or update of is_listed, is_available on public.menu_items
  for each row execute function private.trg_menu_unlisted_unavailable();
