-- ═══════════════════════════════════════════════════════════════
-- 42 · Silog menu: Chicksilog and Tocilog
--
-- Rename  "Chicken Silog" is called Chicksilog on the menu.
-- Tocilog is back on the menu (it went missing on production); the
--         price, order and description are the ones from sql/39.
-- Data only. Dishes are matched by name. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

update public.menu_items set name = 'Chicksilog', updated_at = now()
 where name = 'Chicken Silog'
   and not exists (select 1 from public.menu_items where name = 'Chicksilog');

insert into public.menu_items (category_id, name, price, pax_options, is_shareable, is_available,
                               is_featured, featured_tag, emoji, description, display_order, branch_availability)
select c.id, 'Tocilog', 115, null, false, true, false, null, '🍳', 'Sweet tocino, garlic rice and egg', 4,
       '{"tgt": true, "bacoor": true, "laspinas": true}'::jsonb
  from public.menu_categories c
 where c.name = 'All-Day Breakfast Silog'
   and not exists (select 1 from public.menu_items where lower(name) = 'tocilog');
