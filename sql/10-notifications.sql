-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 10: Notifications
--
-- A unified notifications feed used by the portal Bell + Notifications
-- tab. Rows are auto-created by triggers on orders, inquiries,
-- messages, and attendance so the frontend doesn't need to remember
-- to push them.
--
-- Safe to run multiple times. All CREATE TABLE / TRIGGER statements
-- use IF NOT EXISTS / DROP IF EXISTS guards.
-- ═══════════════════════════════════════════════════════════════

-- ── enum ──────────────────────────────────────────────────────
do $$ begin
  if not exists (select 1 from pg_type where typname = 'notification_priority') then
    create type notification_priority as enum ('low', 'normal', 'high', 'urgent');
  end if;
end $$;

-- ── table ─────────────────────────────────────────────────────
create table if not exists public.notifications (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid references public.staff(id) on delete cascade,   -- null = branch broadcast
  branch_id    uuid references public.branches(id) on delete cascade,
  kind         text not null,           -- 'order_new','order_ready','inquiry_new','message_new', etc.
  title        text not null,
  body         text,
  link         text,                    -- optional deep-link route in the portal (e.g. 'orders', 'inquiries')
  entity_type  text,                    -- 'order','inquiry','message','attendance','staff','table'
  entity_id    uuid,
  priority     notification_priority default 'normal',
  read_at      timestamptz,
  created_at   timestamptz default now()
);

create index if not exists idx_notif_user_created   on public.notifications(user_id, created_at desc);
create index if not exists idx_notif_branch_created on public.notifications(branch_id, created_at desc);
create index if not exists idx_notif_unread_user    on public.notifications(user_id) where read_at is null;
create index if not exists idx_notif_unread_branch  on public.notifications(branch_id) where read_at is null and user_id is null;
create index if not exists idx_notif_entity         on public.notifications(entity_type, entity_id);

-- ── RLS ───────────────────────────────────────────────────────
alter table public.notifications enable row level security;

drop policy if exists notif_read on public.notifications;
create policy notif_read on public.notifications
  for select to authenticated using (
    user_id = auth.uid()
    or (user_id is null and branch_id = private.my_branch())
    or private.has_role('admin')
  );

drop policy if exists notif_update on public.notifications;
create policy notif_update on public.notifications
  for update to authenticated using (
    user_id = auth.uid()
    or (user_id is null and branch_id = private.my_branch() and private.has_role('manager'))
    or private.has_role('admin')
  ) with check (
    user_id = auth.uid()
    or (user_id is null and branch_id = private.my_branch() and private.has_role('manager'))
    or private.has_role('admin')
  );

drop policy if exists notif_delete on public.notifications;
create policy notif_delete on public.notifications
  for delete to authenticated using (
    user_id = auth.uid() or private.has_role('admin')
  );

-- Managers+ can push notifications to their branch; anyone auth can push to themselves.
drop policy if exists notif_insert on public.notifications;
create policy notif_insert on public.notifications
  for insert to authenticated with check (
    (user_id = auth.uid())
    or (private.has_role('manager') and (
         branch_id = private.my_branch() or private.has_role('admin')
       ))
  );

-- Triggers (below) need to insert as background/system, so we use
-- SECURITY DEFINER helper functions that bypass RLS cleanly.
grant insert on public.notifications to authenticated;

-- ── realtime ──────────────────────────────────────────────────
do $$ begin
  begin
    alter publication supabase_realtime add table public.notifications;
  exception when duplicate_object then null;
  end;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- HELPER: insert a notification bypassing RLS (used from triggers).
-- Safe because triggers only fire on validated business events.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.notify_push(
  p_user_id     uuid,
  p_branch_id   uuid,
  p_kind        text,
  p_title       text,
  p_body        text,
  p_link        text,
  p_entity_type text,
  p_entity_id   uuid,
  p_priority    notification_priority default 'normal'
) returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  new_id uuid;
begin
  insert into public.notifications
    (user_id, branch_id, kind, title, body, link, entity_type, entity_id, priority)
  values
    (p_user_id, p_branch_id, p_kind, p_title, p_body, p_link, p_entity_type, p_entity_id, p_priority)
  returning id into new_id;
  return new_id;
end $$;

revoke execute on function public.notify_push(uuid,uuid,text,text,text,text,text,uuid,notification_priority) from public, anon, authenticated;

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: new order → notify branch (kitchen + dining + manager)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_notify_order_new()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  ot text;
  tbl_num int;
begin
  ot := coalesce(new.order_type::text, 'order');
  if new.table_id is not null then
    select table_number into tbl_num from public.restaurant_tables where id = new.table_id;
  end if;
  perform public.notify_push(
    null,                            -- broadcast to branch
    new.branch_id,
    'order_new',
    case
      when new.order_type = 'dine_in' and tbl_num is not null
        then 'New dine-in order · Table ' || tbl_num
      when new.order_type = 'delivery' then 'New delivery order'
      when new.order_type = 'pickup'   then 'New pickup order'
      else 'New order'
    end,
    coalesce('₱' || to_char(new.total, 'FM999,999.00'), '') ||
      case when new.customer_name is not null then ' · ' || new.customer_name else '' end,
    'orders',
    'order',
    new.id,
    'normal'
  );
  return new;
end $$;
drop trigger if exists trg_orders_notify_new on public.orders;
create trigger trg_orders_notify_new
  after insert on public.orders
  for each row execute function public.trg_notify_order_new();

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: order status change → notify branch for 'ready' and
-- 'cancelled'. Skips no-op updates.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_notify_order_status()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  tbl_num int;
begin
  if new.status = old.status then return new; end if;

  if new.table_id is not null then
    select table_number into tbl_num from public.restaurant_tables where id = new.table_id;
  end if;

  if new.status = 'ready' then
    perform public.notify_push(
      null, new.branch_id, 'order_ready',
      'Order ready · ' || new.order_number,
      case when tbl_num is not null then 'Table ' || tbl_num
           when new.order_type = 'pickup' then 'Awaiting pickup'
           when new.order_type = 'delivery' then 'Ready for dispatch'
           else null end,
      'orders', 'order', new.id, 'high'
    );
  elsif new.status = 'cancelled' then
    perform public.notify_push(
      null, new.branch_id, 'order_cancelled',
      'Order cancelled · ' || new.order_number,
      new.cancel_reason,
      'orders', 'order', new.id, 'normal'
    );
  end if;
  return new;
end $$;
drop trigger if exists trg_orders_notify_status on public.orders;
create trigger trg_orders_notify_status
  after update of status on public.orders
  for each row execute function public.trg_notify_order_status();

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: new inquiry → notify manager+ at the routed branch.
-- If no branch is set (general inquiry), broadcast to Las Piñas.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_notify_inquiry_new()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  target_branch uuid;
begin
  target_branch := coalesce(
    new.branch_id,
    (select id from public.branches where code = 'laspinas' limit 1)
  );
  perform public.notify_push(
    null, target_branch, 'inquiry_new',
    'New inquiry · ' || new.inquiry_type::text,
    left(coalesce(new.message,''), 140) ||
      case when length(coalesce(new.message,'')) > 140 then '…' else '' end,
    'inquiries', 'inquiry', new.id, 'normal'
  );
  return new;
end $$;
drop trigger if exists trg_inquiries_notify_new on public.inquiries;
create trigger trg_inquiries_notify_new
  after insert on public.inquiries
  for each row execute function public.trg_notify_inquiry_new();

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: new message → notify the recipient (direct) or branch
-- (broadcast). Skips if the sender is the recipient (self-note).
-- Assumes public.messages exists (from migration 09). If it does
-- not yet exist, this trigger creation is skipped silently.
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if to_regclass('public.messages') is not null then
    execute $ddl$
      create or replace function public.trg_notify_message_new()
      returns trigger language plpgsql security definer set search_path = '' as $body$
      declare
        sender_name text;
      begin
        select full_name into sender_name from public.staff where id = new.from_staff_id;
        if new.to_staff_id is not null then
          if new.to_staff_id = new.from_staff_id then return new; end if;
          perform public.notify_push(
            new.to_staff_id, null, 'message_new',
            'New message from ' || coalesce(sender_name, 'a teammate'),
            coalesce(new.subject, left(new.body, 100)),
            'staff-messages', 'message', new.id, 'normal'
          );
        else
          perform public.notify_push(
            null, new.branch_id, 'message_new',
            'Broadcast from ' || coalesce(sender_name, 'management'),
            coalesce(new.subject, left(new.body, 100)),
            'staff-messages', 'message', new.id, 'normal'
          );
        end if;
        return new;
      end $body$;
    $ddl$;
    execute 'drop trigger if exists trg_messages_notify_new on public.messages';
    execute 'create trigger trg_messages_notify_new after insert on public.messages for each row execute function public.trg_notify_message_new()';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: attendance corrected → notify the affected staff.
-- Same conditional as messages: only wire up if the table exists.
-- ═══════════════════════════════════════════════════════════════
do $$ begin
  if to_regclass('public.attendance') is not null then
    execute $ddl$
      create or replace function public.trg_notify_attendance_correction()
      returns trigger language plpgsql security definer set search_path = '' as $body$
      declare
        corrector_name text;
      begin
        if new.corrected_by is null then return new; end if;
        if old.corrected_by = new.corrected_by
           and old.clock_in_at = new.clock_in_at
           and coalesce(old.clock_out_at, 'epoch'::timestamptz) = coalesce(new.clock_out_at, 'epoch'::timestamptz) then
          return new;
        end if;
        select full_name into corrector_name from public.staff where id = new.corrected_by;
        perform public.notify_push(
          new.staff_id, null, 'attendance_correction',
          'Your attendance was corrected',
          'Adjusted by ' || coalesce(corrector_name, 'a manager'),
          'staff-attendance', 'attendance', new.id, 'normal'
        );
        return new;
      end $body$;
    $ddl$;
    execute 'drop trigger if exists trg_attendance_notify_correction on public.attendance';
    execute 'create trigger trg_attendance_notify_correction after update on public.attendance for each row execute function public.trg_notify_attendance_correction()';
  end if;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: pending-account created → notify admin+ so they can
-- validate. Uses employment_status transition to 'pending'.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_notify_staff_pending()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  laspinas_branch uuid;
begin
  if new.employment_status <> 'pending' then return new; end if;
  select id into laspinas_branch from public.branches where code = 'laspinas' limit 1;
  perform public.notify_push(
    null, coalesce(new.branch_id, laspinas_branch), 'staff_pending',
    'New staff awaiting validation',
    new.full_name || ' · ' || new.role::text,
    'accounts', 'staff', new.id, 'high'
  );
  return new;
end $$;
drop trigger if exists trg_staff_notify_pending on public.staff;
create trigger trg_staff_notify_pending
  after insert or update of employment_status on public.staff
  for each row execute function public.trg_notify_staff_pending();

-- ═══════════════════════════════════════════════════════════════
-- TRIGGER: table signal (call staff / bill request) → notify branch.
-- Fires on the timestamp transitioning null → non-null so an
-- acknowledged-then-called-again cycle produces separate rows.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_notify_table_signal()
returns trigger language plpgsql security definer set search_path = '' as $$
declare
  br uuid;
begin
  br := new.branch_id;
  if old.call_staff_at is null and new.call_staff_at is not null then
    perform public.notify_push(
      null, br, 'table_signal',
      'Table ' || new.table_number || ' is calling staff',
      null, 'orders', 'table', new.id, 'high'
    );
  end if;
  if old.bill_requested_at is null and new.bill_requested_at is not null then
    perform public.notify_push(
      null, br, 'table_signal',
      'Table ' || new.table_number || ' requested the bill',
      coalesce('₱' || to_char(new.bill_total, 'FM999,999.00'), '') ||
        case when new.bill_payment_method is not null then ' · ' || new.bill_payment_method else '' end,
      'orders', 'table', new.id, 'high'
    );
  end if;
  return new;
end $$;
drop trigger if exists trg_tables_notify_signal on public.restaurant_tables;
create trigger trg_tables_notify_signal
  after update on public.restaurant_tables
  for each row execute function public.trg_notify_table_signal();

-- ═══════════════════════════════════════════════════════════════
-- MAINTENANCE: auto-prune read notifications older than 60 days
-- and unread ones older than 180 days. Call from Supabase cron or
-- manually.
-- ═══════════════════════════════════════════════════════════════
create or replace function public.notifications_prune()
returns integer
language plpgsql security definer set search_path = '' as $$
declare
  n int;
begin
  delete from public.notifications
   where (read_at is not null and read_at < now() - interval '60 days')
      or (read_at is null     and created_at < now() - interval '180 days');
  get diagnostics n = row_count;
  return n;
end $$;

-- Done.
