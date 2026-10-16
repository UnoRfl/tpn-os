-- ═══════════════════════════════════════════════════════════════
-- 36 · Read receipts per person (notifications + broadcast messages)
--
-- Two bugs shared one cause: a branch-wide notification or message is a
-- single row with a single read_at.
--   • Crew could see branch notifications but not mark them read (only a
--     manager may update them), so "read" ones came back on every load.
--   • When a manager did mark one read, it vanished for everybody; and the
--     first person to open a branch message marked it read for the branch.
-- Worse, any branch member could UPDATE a broadcast message — subject and
-- body included — because the grant and the policy were not column-bound.
--
-- Now: personal rows keep read_at; branch-wide rows get a receipt per
-- person (read, or dismissed = hidden for me). Staff may only touch
-- read_at, and only on rows addressed to them.
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

create table if not exists public.read_receipts (
  kind          text not null check (kind in ('notification', 'message')),
  item_id       uuid not null,
  user_id       uuid not null default auth.uid() references auth.users(id) on delete cascade,
  read_at       timestamptz not null default now(),
  dismissed_at  timestamptz,
  primary key (kind, item_id, user_id)
);
create index if not exists read_receipts_user_idx on public.read_receipts (user_id, kind);
alter table public.read_receipts enable row level security;

drop policy if exists read_receipts_own on public.read_receipts;
create policy read_receipts_own on public.read_receipts for all to authenticated
  using (user_id = auth.uid()) with check (user_id = auth.uid());
revoke all on public.read_receipts from anon;
grant select, insert, update on public.read_receipts to authenticated;

-- ── Writes on the shared rows: read_at only, own rows only ─────────
revoke update on public.messages from authenticated;
grant update (read_at) on public.messages to authenticated;
drop policy if exists messages_update_read on public.messages;      -- let any branch member edit a broadcast
-- messages_mark_read (to_staff_id = auth.uid()) stays.

revoke update on public.notifications from authenticated;
grant update (read_at) on public.notifications to authenticated;
drop policy if exists notif_update on public.notifications;
create policy notif_update on public.notifications for update to authenticated
  using (user_id = auth.uid() or private.has_role('admin'))
  with check (user_id = auth.uid() or private.has_role('admin'));

-- ── What I see ─────────────────────────────────────────────────────
-- SECURITY INVOKER: the table policies still decide what is visible.
-- A branch row read before this migration (shared read_at) stays read.
create or replace function public.my_notifications(p_limit int default 100, p_unread_only boolean default false)
returns setof jsonb
language sql stable security invoker set search_path = ''
as $$
  select to_jsonb(n) || jsonb_build_object('read_at',
           coalesce(case when n.user_id is not null then n.read_at end, r.read_at,
                    case when n.user_id is null then n.read_at end),
           'shared', n.user_id is null)
    from public.notifications n
    left join public.read_receipts r on r.kind = 'notification' and r.item_id = n.id and r.user_id = auth.uid()
   where r.dismissed_at is null
     and (not p_unread_only or coalesce(case when n.user_id is not null then n.read_at end, r.read_at,
                                        case when n.user_id is null then n.read_at end) is null)
   order by n.created_at desc
   limit least(greatest(coalesce(p_limit, 100), 1), 500)
$$;

create or replace function public.my_unread_counts()
returns jsonb
language sql stable security invoker set search_path = ''
as $$
  select jsonb_build_object(
    'notifications', (select count(*) from public.notifications n
                        left join public.read_receipts r on r.kind = 'notification' and r.item_id = n.id and r.user_id = auth.uid()
                       where r.dismissed_at is null
                         and coalesce(case when n.user_id is not null then n.read_at end, r.read_at,
                                      case when n.user_id is null then n.read_at end) is null),
    'messages', (select count(*) from public.messages m
                   left join public.read_receipts r on r.kind = 'message' and r.item_id = m.id and r.user_id = auth.uid()
                  where (m.to_staff_id = auth.uid() or m.to_staff_id is null)
                    and m.from_staff_id is distinct from auth.uid()
                    and r.dismissed_at is null
                    and coalesce(case when m.to_staff_id is not null then m.read_at end, r.read_at,
                                 case when m.to_staff_id is null then m.read_at end) is null))
$$;

-- ── Mark read / dismiss ────────────────────────────────────────────
-- p_ids null = everything visible to me of that kind.
create or replace function public.mark_read(p_kind text, p_ids uuid[] default null)
returns int
language plpgsql security invoker set search_path = ''
as $$
declare v int := 0; n int;
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  if p_kind = 'notification' then
    update public.notifications set read_at = now()
     where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
    get diagnostics n = row_count; v := v + n;
    insert into public.read_receipts (kind, item_id, user_id)
    select 'notification', id, auth.uid() from public.notifications
     where user_id is null and (p_ids is null or id = any(p_ids))
    on conflict (kind, item_id, user_id) do nothing;
    get diagnostics n = row_count; v := v + n;
  elsif p_kind = 'message' then
    update public.messages set read_at = now()
     where to_staff_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
    get diagnostics n = row_count; v := v + n;
    insert into public.read_receipts (kind, item_id, user_id)
    select 'message', id, auth.uid() from public.messages
     where to_staff_id is null and (p_ids is null or id = any(p_ids))
    on conflict (kind, item_id, user_id) do nothing;
    get diagnostics n = row_count; v := v + n;
  else
    raise exception 'bad_kind';
  end if;
  return v;
end $$;

-- Mine: deleted. Branch-wide: hidden for me only.
create or replace function public.dismiss_notification(p_id uuid)
returns void
language plpgsql security invoker set search_path = ''
as $$
begin
  if auth.uid() is null then raise exception 'not_signed_in' using errcode = '42501'; end if;
  delete from public.notifications where id = p_id and user_id = auth.uid();
  if not found then
    insert into public.read_receipts (kind, item_id, user_id, dismissed_at)
    select 'notification', id, auth.uid(), now() from public.notifications where id = p_id
    on conflict (kind, item_id, user_id) do update set dismissed_at = now();
  end if;
end $$;

revoke all on function public.my_notifications(int, boolean) from public, anon;
revoke all on function public.my_unread_counts() from public, anon;
revoke all on function public.mark_read(text, uuid[]) from public, anon;
revoke all on function public.dismiss_notification(uuid) from public, anon;
grant execute on function public.my_notifications(int, boolean) to authenticated;
grant execute on function public.my_unread_counts() to authenticated;
grant execute on function public.mark_read(text, uuid[]) to authenticated;
grant execute on function public.dismiss_notification(uuid) to authenticated;
