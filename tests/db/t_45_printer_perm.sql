-- Printer tools (sql/45): managers and up by default, never crew or the screen accounts.
insert into public.t_results
select 'printer.manage: ' || r.key || ' is ' || case when v.expect then 'allowed' else 'not allowed' end,
       coalesce(p.allowed, false) = v.expect, coalesce(p.allowed::text, 'no row')
  from (values ('dining', false), ('kitchen', false), ('kitchen_display', false), ('dine_in_display', false),
               ('manager', true), ('admin', true)) v(k, expect)
  join public.access_roles r on r.key = v.k and r.is_system
  left join public.access_role_permissions p on p.role_id = r.id and p.permission_key = 'printer.manage';

select name, ok, detail from public.t_results order by name;
