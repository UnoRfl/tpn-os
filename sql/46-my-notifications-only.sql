-- ═══════════════════════════════════════════════════════════════
-- 46 — the bell shows only my notifications (Oct 22, 2026)
--
-- notif_read lets admin and up read every notification, including
-- someone else's personal ones (a void request sent to the CEO, say).
-- my_notifications / my_unread_counts listed everything readable, but
-- mark_read can only mark my own or the shared branch rows, so an
-- admin's bell kept other people's notifications unread forever: "read
-- notifications come back after a refresh" (owner, Oct 22).
--
-- Now both list my own plus the shared ones. The table policy is
-- unchanged (admin screens may still read all of them).
-- ═══════════════════════════════════════════════════════════════

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
     and (n.user_id is null or n.user_id = auth.uid())
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
                         and (n.user_id is null or n.user_id = auth.uid())
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
