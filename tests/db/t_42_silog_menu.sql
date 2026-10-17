-- Silog menu (sql/42): Chicksilog renamed, Tocilog on the menu once.
insert into public.t_results values
  ('chicksilog on the menu', exists (select 1 from public.menu_items where name = 'Chicksilog' and is_available), ''),
  ('no chicken silog left', not exists (select 1 from public.menu_items where name = 'Chicken Silog'), ''),
  ('tocilog on the menu once', (select count(*) from public.menu_items where lower(name) = 'tocilog' and is_available) = 1
    and (select price from public.menu_items where name = 'Tocilog') = 115, '');
select name, ok, detail from public.t_results;
