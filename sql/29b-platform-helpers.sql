-- ═══════════════════════════════════════════════════════════════
-- 29b · Shared helpers for migrations 30+
--
--   private.audit_row()      one audit trigger for any table with an `id`.
--                            It reads the row through to_jsonb(), never
--                            through OLD.<field>, so it can safely be shared.
--                            (HANDOFF explains why a shared trigger that
--                            names fields directly broke in sql/19.)
--   private.add_permission() adds a permission and grants it to each system
--                            role at or above its floor, the same rule as
--                            sql/19 section 12. The two screen accounts
--                            never get it.
--   private.setting(key)     reads site_settings (created in sql/30).
-- ═══════════════════════════════════════════════════════════════

create schema if not exists private;

create or replace function private.audit_row()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_new jsonb := case when tg_op <> 'DELETE' then to_jsonb(new) end;
  v_old jsonb := case when tg_op <> 'INSERT' then to_jsonb(old) end;
  v_id  text  := coalesce(v_new->>'id', v_old->>'id');
begin
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, before_state, after_state)
  values (auth.uid(), private.my_role(), tg_table_name || '.' || lower(tg_op), tg_table_name,
          case when v_id ~* '^[0-9a-f-]{36}$' then v_id::uuid end, v_old, v_new);
  return coalesce(new, old);
end $$;
revoke all on function private.audit_row() from public, anon, authenticated;

create or replace function private.add_permission(
  p_key text, p_category text, p_label text, p_label_tl text,
  p_description text, p_min_tier public.staff_role, p_order int default 100)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  insert into public.permissions (key, category, label, label_tl, description, min_tier, display_order)
  values (p_key, p_category, p_label, p_label_tl, p_description, p_min_tier, p_order)
  on conflict (key) do update set
    category = excluded.category, label = excluded.label, label_tl = excluded.label_tl,
    description = excluded.description, min_tier = excluded.min_tier,
    display_order = excluded.display_order;

  -- Only rows that do not exist yet, so a hand-tuned grid survives a re-run.
  insert into public.access_role_permissions (role_id, permission_key, allowed)
  select r.id, p_key,
         r.key not in ('kitchen_display', 'dine_in_display')
         and array_position(enum_range(null::public.staff_role), r.base_tier)
             >= array_position(enum_range(null::public.staff_role), p_min_tier)
    from public.access_roles r
   where r.is_system
  on conflict (role_id, permission_key) do nothing;
end $$;
revoke all on function private.add_permission(text, text, text, text, text, public.staff_role, int) from public, anon, authenticated;

-- private.client_ip() and private.rate_limit() live in sql/29.
