-- 39 · The real menu (October 2026), typed from the printed menu boards.
-- Data only. Safe to re-run: dishes are matched by name and updated.
--   2-3 / 4-6 pax columns → pax_options {"2-3": x, "4-6": y}
--   one price + a 4-6 pax column (rice, soda, juice) → {"1": x, "4-6": y}
--   same price in both columns (nachos, fish & fries, calamares) → one price
--   ★ on the board → is_featured, tag "Bestseller"
-- Dishes no longer on the boards are hidden (or deleted if never ordered).

do $$
declare
  v_branches jsonb := '{"tgt": true, "bacoor": true, "laspinas": true}';
  r record; v_cat uuid; v_id uuid;
begin
  -- Categories: reuse the old rows where they fit, so links stay intact.
  update public.menu_categories set name = 'All-Day Breakfast Silog' where name = 'Silog Meals';
  update public.menu_categories set name = 'Vegetable Dishes' where name = 'Vegetables & Sides';
  update public.menu_categories set name = 'Merienda & Pica-Pica' where name = 'Snacks & Merienda';
  update public.menu_categories set name = 'Drinks' where name = 'Beverages';
  update public.menu_categories set name = 'Additional' where name = 'Rice Bowls';

  for r in select * from (values
    ('All-Day Breakfast Silog', 'Silog (buong araw)', 1, '🍳'),
    ('Pork Dishes',             'Baboy',              2, '🐖'),
    ('Chicken Dishes',          'Manok',              3, '🍗'),
    ('Beef Dishes',             'Baka',               4, '🐄'),
    ('Seafood Dishes',          'Pagkaing-dagat',     5, '🦐'),
    ('Vegetable Dishes',        'Gulay',              6, '🥬'),
    ('Wings & Thigh Fillet',    'Wings at Thigh Fillet', 7, '🍗'),
    ('Merienda & Pica-Pica',    'Meryenda at Pica-Pica', 8, '🍜'),
    ('Additional',              'Dagdag',             9, '🍚'),
    ('Drinks',                  'Inumin',            10, '🥤')
  ) as c(name, tl, ord, icon) loop
    update public.menu_categories set name_tagalog = r.tl, display_order = r.ord, icon = r.icon, is_active = true
     where name = r.name;
    if not found then
      insert into public.menu_categories (name, name_tagalog, display_order, icon, is_active)
      values (r.name, r.tl, r.ord, r.icon, true);
    end if;
  end loop;
  update public.menu_categories set is_active = false
   where name not in ('All-Day Breakfast Silog','Pork Dishes','Chicken Dishes','Beef Dishes','Seafood Dishes',
                      'Vegetable Dishes','Wings & Thigh Fillet','Merienda & Pica-Pica','Additional','Drinks');

  -- Old names that are the same dish under a new name.
  update public.menu_items set name = 'Cornedbeef Silog' where name = 'Cornsilog';
  update public.menu_items set name = 'Chicksilog' where name = 'Chicken Silog'
     and not exists (select 1 from public.menu_items where name = 'Chicksilog');
  update public.menu_items set name = 'Pork Sinigang' where name = 'Sinigang na Baboy';

  create temp table _menu (cat text, name text, price numeric, pax jsonb, star boolean, emoji text, descr text, ord int) on commit drop;
  insert into _menu values
    -- All-day breakfast silog (single plate)
    ('All-Day Breakfast Silog','Tapsilog',          145, null, true,  '🍳', 'Beef tapa, garlic rice and egg', 1),
    ('All-Day Breakfast Silog','Bacon Silog',       145, null, true,  '🥓', 'Bacon, garlic rice and egg', 2),
    ('All-Day Breakfast Silog','Liemposilog',       145, null, true,  '🍳', 'Pork liempo, garlic rice and egg', 3),
    ('All-Day Breakfast Silog','Tocilog',           115, null, false, '🍳', 'Sweet tocino, garlic rice and egg', 4),
    ('All-Day Breakfast Silog','Cornedbeef Silog',  115, null, false, '🥫', 'Corned beef, garlic rice and egg', 5),
    ('All-Day Breakfast Silog','Sisig Silog',       115, null, true,  '🍳', 'Pork sisig, garlic rice and egg', 6),
    ('All-Day Breakfast Silog','Chicksilog',        105, null, true,  '🍗', 'Fried chicken, garlic rice and egg', 7),
    ('All-Day Breakfast Silog','Pares',              95, null, true,  '🍲', 'Braised beef pares with rice', 8),
    ('All-Day Breakfast Silog','Goto Plain',         60, null, false, '🥣', 'Rice porridge with tripe', 9),
    ('All-Day Breakfast Silog','Goto',              100, null, false, '🥣', 'Rice porridge with tripe and egg', 10),
    ('All-Day Breakfast Silog','Goto with Lechon Kawali', 145, null, false, '🥣', 'Goto topped with crispy lechon kawali', 11),
    -- Pork
    ('Pork Dishes','Pork Sisig',                  330, '{"2-3":330,"4-6":600}', true,  '🥘', null, 1),
    ('Pork Dishes','Pork Nilaga',                 330, '{"2-3":330,"4-6":600}', true,  '🍲', null, 2),
    ('Pork Dishes','Pork Sinigang',               330, '{"2-3":330,"4-6":600}', true,  '🥣', null, 3),
    ('Pork Dishes','Lechon Kawali',               330, '{"2-3":330,"4-6":600}', true,  '🐖', null, 4),
    ('Pork Dishes','Pork Caldereta',              360, '{"2-3":360,"4-6":650}', true,  '🍲', null, 5),
    ('Pork Dishes','Bicol Express',               435, '{"2-3":435,"4-6":810}', false, '🌶️', null, 6),
    ('Pork Dishes','Pork Binagoongan',            435, '{"2-3":435,"4-6":810}', false, '🐖', null, 7),
    ('Pork Dishes','Kare-Kareng Lechon Kawali',   435, '{"2-3":435,"4-6":810}', true,  '🥜', 'Crispy pork belly in peanut stew with vegetables', 8),
    -- Chicken
    ('Chicken Dishes','Chicken Bistek',           300, '{"2-3":300,"4-6":555}', true,  '🍗', null, 1),
    ('Chicken Dishes','Chicken Curry',            310, '{"2-3":310,"4-6":570}', false, '🍛', null, 2),
    ('Chicken Dishes','Chicken Adobo with Gata',  310, '{"2-3":310,"4-6":570}', true,  '🍗', null, 3),
    ('Chicken Dishes','Kalderetang Bulacan',      310, '{"2-3":310,"4-6":570}', true,  '🍲', null, 4),
    -- Beef
    ('Beef Dishes','Beef Bistek',                 405, '{"2-3":405,"4-6":750}', true,  '🐄', null, 1),
    ('Beef Dishes','Beef Sinigang',               405, '{"2-3":405,"4-6":750}', true,  '🥣', null, 2),
    ('Beef Dishes','Beef Nilaga',                 405, '{"2-3":405,"4-6":750}', true,  '🍲', null, 3),
    ('Beef Dishes','Beef Caldereta',              435, '{"2-3":435,"4-6":810}', true,  '🍲', null, 4),
    ('Beef Dishes','Beef Tripe Kare-Kare',        435, '{"2-3":435,"4-6":810}', true,  '🥜', null, 5),
    -- Seafood
    ('Seafood Dishes','Adobong Pusit with Gata',  445, '{"2-3":445,"4-6":830}', true,  '🦑', null, 1),
    ('Seafood Dishes','Buttered Shrimp',          485, '{"2-3":485,"4-6":910}', true,  '🦐', null, 2),
    ('Seafood Dishes','Ginataang Hipon',          485, '{"2-3":485,"4-6":910}', false, '🦐', null, 3),
    ('Seafood Dishes','Shrimp in Salted Egg',     485, '{"2-3":485,"4-6":910}', true,  '🦐', null, 4),
    ('Seafood Dishes','Sinigang na Hipon',        485, '{"2-3":485,"4-6":910}', false, '🥣', null, 5),
    ('Seafood Dishes','Sinigang na Salmon',       485, '{"2-3":485,"4-6":910}', false, '🐟', null, 6),
    -- Vegetables
    ('Vegetable Dishes','Laing',                  269, '{"2-3":269,"4-6":478}', true,  '🥬', 'Taro leaves in coconut milk with chili', 1),
    ('Vegetable Dishes','Mixed Vegetables',       279, '{"2-3":279,"4-6":498}', false, '🥦', null, 2),
    ('Vegetable Dishes','Ginataang Sitaw at Kalabasa', 249, '{"2-3":249,"4-6":438}', true, '🎃', null, 3),
    -- Wings & thigh fillet
    ('Wings & Thigh Fillet','Garlic Parmesan Wings',        249, '{"2-3":249,"4-6":460}', true,  '🍗', null, 1),
    ('Wings & Thigh Fillet','Garlic Parmesan Thigh Fillet', 289, '{"2-3":289,"4-6":535}', true,  '🍗', null, 2),
    ('Wings & Thigh Fillet','Salted Egg Wings',             249, '{"2-3":249,"4-6":460}', false, '🍗', null, 3),
    ('Wings & Thigh Fillet','Salted Egg Thigh Fillet',      289, '{"2-3":289,"4-6":535}', false, '🍗', null, 4),
    ('Wings & Thigh Fillet','Buffalo Wings',                249, '{"2-3":249,"4-6":460}', true,  '🍗', null, 5),
    ('Wings & Thigh Fillet','Buffalo Thigh Fillet',         289, '{"2-3":289,"4-6":535}', true,  '🍗', null, 6),
    ('Wings & Thigh Fillet','Teriyaki Wings',               249, '{"2-3":249,"4-6":460}', false, '🍗', null, 7),
    -- Merienda & pica-pica
    ('Merienda & Pica-Pica','Pancit Bihon',       245, '{"2-3":245,"4-6":430}', true,  '🍜', null, 1),
    ('Merienda & Pica-Pica','Pancit Canton',      265, '{"2-3":265,"4-6":460}', false, '🍜', null, 2),
    ('Merienda & Pica-Pica','Pancit Sotanghon',   275, '{"2-3":275,"4-6":490}', true,  '🍜', null, 3),
    ('Merienda & Pica-Pica','Pancit Malabon',     265, '{"2-3":265,"4-6":460}', true,  '🍜', null, 4),
    ('Merienda & Pica-Pica','Pancit Malabon with Lechon Kawali', 365, '{"2-3":365,"4-6":580}', true, '🍜', null, 5),
    ('Merienda & Pica-Pica','Nachos',             245, null, false, '🧀', 'Regular, chicken or sisig', 6),
    ('Merienda & Pica-Pica','Fish & Fries',       265, null, false, '🐟', null, 7),
    ('Merienda & Pica-Pica','Calamares',          265, null, true,  '🦑', null, 8),
    -- Additional
    ('Additional','Plain Rice',   35, '{"1":35,"4-6":200}', false, '🍚', null, 1),
    ('Additional','Garlic Rice',  40, '{"1":40,"4-6":230}', false, '🍚', null, 2),
    ('Additional','Extra Egg',    25, null, false, '🍳', 'Sunny side up, scrambled or boiled', 3),
    ('Additional','Mayo Dip',     25, null, false, '🥣', null, 4),
    ('Additional','Bagoong',      20, null, false, '🥣', null, 5),
    ('Additional','Unli Rice',    29, null, false, '🍚', 'Add to a silog meal. Dine-in only.', 6),
    -- Drinks
    ('Drinks','Brewed Coffee',  90, null, false, '☕', 'Hot or iced', 1),
    ('Drinks','Soda in Can',    65, '{"1":65,"4-6":120}', false, '🥤', 'Coke Regular, Coke Zero, Royal or Sprite', 2),
    ('Drinks','Bottled Water',  30, null, false, '💧', null, 3),
    ('Drinks','Juice Drink',    70, '{"1":70,"4-6":135}', false, '🧃', null, 4);

  for r in select m.*, c.id cat_id from _menu m join public.menu_categories c on c.name = m.cat loop
    select id into v_id from public.menu_items where lower(name) = lower(r.name) limit 1;
    if v_id is null then
      insert into public.menu_items (category_id, name, price, pax_options, is_shareable, is_available,
                                     is_featured, featured_tag, emoji, description, display_order, branch_availability)
      values (r.cat_id, r.name, r.price, r.pax, r.pax is not null, true,
              r.star, case when r.star then 'Bestseller' end, r.emoji, r.descr, r.ord, v_branches);
    else
      update public.menu_items set category_id = r.cat_id, price = r.price, pax_options = r.pax,
             is_shareable = r.pax is not null, is_available = true, is_featured = r.star,
             featured_tag = case when r.star then 'Bestseller' end, emoji = r.emoji,
             description = coalesce(r.descr, description), display_order = r.ord,
             branch_availability = v_branches, updated_at = now()
       where id = v_id;
    end if;
  end loop;

  -- Off the boards: delete if never ordered, otherwise hide.
  delete from public.menu_items mi
   where not exists (select 1 from _menu m where lower(m.name) = lower(mi.name))
     and not exists (select 1 from public.order_items oi where oi.menu_item_id = mi.id)
     and not exists (select 1 from public.customer_device_items d where d.menu_item_id = mi.id);
  update public.menu_items mi set is_available = false, is_featured = false
   where not exists (select 1 from _menu m where lower(m.name) = lower(mi.name));
end $$;
