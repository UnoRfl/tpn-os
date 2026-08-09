-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 06: Menu enhancements
-- Adds emoji + is_featured + featured_tag to menu_items so the
-- customer surfaces can render everything from the DB.
-- ═══════════════════════════════════════════════════════════════

alter table public.menu_items
  add column if not exists emoji text,
  add column if not exists is_featured boolean default false,
  add column if not exists featured_tag text;

-- Backfill emojis + featured flags on the items already seeded
update public.menu_items set emoji = '🥜', is_featured = true,  featured_tag = 'Bestseller'         where name = 'Kare-Kareng Lechon Kawali';
update public.menu_items set emoji = '🥬', is_featured = true,  featured_tag = 'Lutong Bicol'       where name = 'Laing';
update public.menu_items set emoji = '🍲', is_featured = true,  featured_tag = 'Customer Favorite'  where name = 'Beef Caldereta';
update public.menu_items set emoji = '🍳' where name = 'Tapsilog';
update public.menu_items set emoji = '🍳' where name = 'Longsilog';
update public.menu_items set emoji = '🐟' where name = 'Bangsilog';
update public.menu_items set emoji = '🥫' where name = 'Cornsilog';
update public.menu_items set emoji = '🍚' where name = 'Unli Rice';
update public.menu_items set emoji = '🥣' where name = 'Sinigang na Baboy';
