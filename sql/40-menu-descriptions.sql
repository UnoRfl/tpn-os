-- ═══════════════════════════════════════════════════════════════
-- 40 · Short descriptions for the dishes that had none
-- Data only. Safe to re-run: fills a description only where it is empty,
-- so anything typed in the portal's Menu Manager is never overwritten.
-- The Tagalog for each line is in tpn-i18n.js (PHRASES), which swaps the
-- text on screen; there is no Tagalog description column.
-- Wording is generic on purpose: correct any dish in Menu Manager.
-- ═══════════════════════════════════════════════════════════════
update public.menu_items m
   set description = v.d
  from (values
  ('Adobong Pusit with Gata', 'Squid stewed in vinegar and soy, finished in coconut milk'),
  ('Bagoong', 'Sautéed shrimp paste on the side'),
  ('Beef Bistek', 'Beef in soy sauce and calamansi with onion rings'),
  ('Beef Nilaga', 'Boiled beef soup with potatoes, cabbage and pechay'),
  ('Beef Sinigang', 'Beef in tamarind-based sour broth with vegetables'),
  ('Beef Tripe Kare-Kare', 'Beef tripe in peanut stew with vegetables'),
  ('Bicol Express', 'Pork in coconut milk with chili'),
  ('Bottled Water', 'Still drinking water'),
  ('Buffalo Thigh Fillet', 'Crispy chicken thigh fillet in buffalo sauce'),
  ('Buffalo Wings', 'Chicken wings tossed in buffalo sauce'),
  ('Buttered Shrimp', 'Shrimp sautéed in garlic butter'),
  ('Calamares', 'Crispy fried squid rings with dip'),
  ('Chicken Adobo with Gata', 'Chicken adobo finished in coconut milk'),
  ('Chicken Bistek', 'Chicken in soy sauce and calamansi with onion rings'),
  ('Chicken Curry', 'Chicken, potatoes and carrots in curry sauce'),
  ('Fish & Fries', 'Breaded fish fillet with fries'),
  ('Garlic Parmesan Thigh Fillet', 'Crispy chicken thigh fillet in garlic parmesan'),
  ('Garlic Parmesan Wings', 'Chicken wings tossed in garlic parmesan'),
  ('Garlic Rice', 'Rice fried with toasted garlic'),
  ('Ginataang Hipon', 'Shrimp in coconut milk'),
  ('Ginataang Sitaw at Kalabasa', 'String beans and squash in coconut milk'),
  ('Juice Drink', 'Chilled juice drink'),
  ('Kalderetang Bulacan', 'Bulacan-style chicken caldereta in tomato sauce'),
  ('Lechon Kawali', 'Crispy deep-fried pork belly'),
  ('Mayo Dip', 'Creamy mayo dip'),
  ('Mixed Vegetables', 'Sautéed mixed vegetables'),
  ('Pancit Bihon', 'Rice noodles stir-fried with vegetables'),
  ('Pancit Canton', 'Egg noodles stir-fried with vegetables'),
  ('Pancit Malabon', 'Thick rice noodles in shrimp sauce with toppings'),
  ('Pancit Malabon with Lechon Kawali', 'Pancit Malabon topped with crispy lechon kawali'),
  ('Pancit Sotanghon', 'Glass noodles stir-fried with vegetables'),
  ('Plain Rice', 'Steamed white rice'),
  ('Pork Binagoongan', 'Pork cooked in sautéed shrimp paste'),
  ('Pork Caldereta', 'Pork braised in tomato sauce with vegetables'),
  ('Pork Nilaga', 'Boiled pork soup with potatoes, cabbage and pechay'),
  ('Pork Sisig', 'Sizzling chopped pork with onion, chili and egg'),
  ('Salted Egg Thigh Fillet', 'Crispy chicken thigh fillet in salted egg sauce'),
  ('Salted Egg Wings', 'Chicken wings in salted egg sauce'),
  ('Shrimp in Salted Egg', 'Shrimp tossed in salted egg sauce'),
  ('Sinigang na Hipon', 'Shrimp in tamarind-based sour broth with vegetables'),
  ('Sinigang na Salmon', 'Salmon in tamarind-based sour broth with vegetables'),
  ('Teriyaki Wings', 'Chicken wings glazed in teriyaki with sesame')
  ) as v(n, d)
 where m.name = v.n
   and coalesce(btrim(m.description), '') = '';
