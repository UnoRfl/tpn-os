-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 15b: Void requests
--
-- ⚠️  RUN sql/15a-display-roles.sql FIRST, on its own, and wait for
--     it to succeed. This file uses the enum values that one adds.
--
-- WHAT THIS DOES
--
-- Before this migration there was exactly one way to void an item:
-- public.void_order_item(), which is manager+ only. Anyone below
-- manager had no path at all — they had to physically find a manager
-- and have them do it on another device.
--
-- This adds the missing half: a REQUEST. Anyone on an active staff
-- account (including the new kitchen_display / dine_in_display screen
-- accounts) can file a void request. It lands as a pending row plus a
-- notification for every manager+ in that branch. Only manager+ can
-- approve it, and approval is what actually performs the void.
--
-- The screens therefore cannot void themselves — which is the whole
-- point. They can only ask.
--
-- Two scopes:
--   'item'  — one line off a ticket (wrong item fired, wrong pax size)
--   'order' — the entire order (walkout, duplicate ticket). Approval
--             voids every remaining item AND marks the order cancelled.
--
-- Safe to re-run. All objects use IF NOT EXISTS / OR REPLACE guards.
-- ═══════════════════════════════════════════════════════════════

-- ── ENUMS ─────────────────────────────────────────────────────
do $$ begin
  if not exists (select 1 from pg_type where typname = 'void_request_status') then
    create type public.void_request_status as enum ('pending','approved','denied','cancelled');
  end if;
end $$;

do $$ begin
  if not exists (select 1 from pg_type where typname = 'void_request_scope') then
    create type public.void_request_scope as enum ('item','order');
  end if;
end $$;

-- ── TABLE ─────────────────────────────────────────────────────
create table if not exists public.void_requests (
  id                uuid primary key default gen_random_uuid(),
  branch_id         uuid not null references public.branches(id) on delete cascade,
  order_id          uuid not null references public.orders(id) on delete cascade,
  order_item_id     uuid references public.order_items(id) on delete cascade,  -- null when scope = 'order'
  scope             public.void_request_scope not null default 'item',
  status            public.void_request_status not null default 'pending',

  -- Snapshots so the request still reads correctly after the item changes
  item_name         text,
  item_qty          int,
  item_amount       numeric(10,2),
  order_number      text,

  reason            text not null,
  requested_by      uuid references public.staff(id) on delete set null,
  requested_by_role public.staff_role,
  requested_at      timestamptz not null default now(),

  reviewed_by       uuid references public.staff(id) on delete set null,
  reviewed_at       timestamptz,
  review_note       text,

  created_at        timestamptz not null default now()
);

create index if not exists idx_void_req_branch_status
  on public.void_requests(branch_id, status, requested_at desc);
create index if not exists idx_void_req_pending
  on public.void_requests(branch_id, requested_at desc) where status = 'pending';
create index if not exists idx_void_req_order
  on public.void_requests(order_id);
create index if not exists idx_void_req_requester
  on public.void_requests(requested_by, requested_at desc);

-- One open request per item at a time. Whole-order requests are keyed
-- on the order with a null item, so they get their own guard below.
create unique index if not exists uniq_void_req_pending_item
  on public.void_requests(order_item_id)
  where status = 'pending' and order_item_id is not null;

create unique index if not exists uniq_void_req_pending_order
  on public.void_requests(order_id)
  where status = 'pending' and scope = 'order';

-- ── RLS ───────────────────────────────────────────────────────
-- Reads: your own requests, or everything in your branch if manager+.
-- Writes: NONE directly. All mutation goes through the SECURITY DEFINER
-- functions below, so a display account cannot craft an "approved" row
-- by hand even with a stolen anon key.
alter table public.void_requests enable row level security;

drop policy if exists void_req_read on public.void_requests;
create policy void_req_read on public.void_requests
  for select to authenticated using (
    requested_by = auth.uid()
    or (private.has_role('manager') and branch_id = private.my_branch())
    or private.has_role('admin')
  );

-- TRUNCATE is listed explicitly: Supabase's default
-- `grant all on all tables in schema public to authenticated` includes it,
-- and TRUNCATE bypasses RLS entirely. Without this, any signed-in account
-- could erase the whole void trail in one statement.
revoke insert, update, delete, truncate on public.void_requests from anon, authenticated;
grant select on public.void_requests to authenticated;

-- ── REALTIME ──────────────────────────────────────────────────
do $$ begin
  begin
    alter publication supabase_realtime add table public.void_requests;
  exception when duplicate_object then null;
  end;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- HELPER: notify every manager+ in a branch
-- ═══════════════════════════════════════════════════════════════
create or replace function private.notify_managers(
  p_branch_id uuid,
  p_kind      text,
  p_title     text,
  p_body      text,
  p_link      text,
  p_entity_id uuid,
  p_priority  public.notification_priority default 'high'
) returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m record;
begin
  for m in
    select id from public.staff
     where branch_id = p_branch_id
       and role >= 'manager'
       and coalesce(employment_status, 'active') = 'active'
  loop
    perform public.notify_push(
      m.id, p_branch_id, p_kind, p_title, p_body, p_link,
      'void_request', p_entity_id, p_priority
    );
  end loop;
end $$;

-- ═══════════════════════════════════════════════════════════════
-- 1. REQUEST A VOID  (any active staff account, including screens)
-- ═══════════════════════════════════════════════════════════════
-- p_item_id null  → whole-order request
-- p_item_id set   → single-item request
create or replace function public.request_void(
  p_order_id uuid,
  p_item_id  uuid,
  p_reason   text
) returns public.void_requests
language plpgsql security definer set search_path = ''
as $$
declare
  me         public.staff%rowtype;
  order_row  public.orders%rowtype;
  item       public.order_items%rowtype;
  req        public.void_requests%rowtype;
  v_scope    public.void_request_scope;
  v_title    text;
  v_body     text;
begin
  select * into me from public.staff where id = auth.uid();
  if not found then
    raise exception 'no_staff_profile' using errcode = '42501';
  end if;
  if coalesce(me.employment_status, 'active') <> 'active' then
    raise exception 'account_not_active' using errcode = '42501';
  end if;

  if p_reason is null or length(trim(p_reason)) < 3 then
    raise exception 'void_reason_required' using errcode = '22023';
  end if;

  select * into order_row from public.orders where id = p_order_id;
  if not found then
    raise exception 'order_not_found' using errcode = 'P0002';
  end if;

  -- You can only raise requests against your own branch.
  if order_row.branch_id <> me.branch_id and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  if order_row.status in ('completed','cancelled') then
    raise exception 'order_terminal' using errcode = '23514';
  end if;

  -- Checked explicitly rather than caught as a unique_violation, because
  -- 'already_voided' below is ALSO raised with errcode 23505 and a blanket
  -- handler would rewrite it into the wrong message.
  if exists (
    select 1 from public.void_requests
     where status = 'pending'
       and order_id = order_row.id
       and (
         (p_item_id is null and scope = 'order')
         or (p_item_id is not null and order_item_id = p_item_id)
       )
  ) then
    raise exception 'request_already_pending' using errcode = '23505';
  end if;

  if p_item_id is null then
    v_scope := 'order';
    v_title := 'Void request — whole order ' || coalesce(order_row.order_number, '');
    v_body  := coalesce(me.full_name, 'A staff member')
               || ' is asking to void the entire order (₱'
               || to_char(coalesce(order_row.total, 0), 'FM999999990.00')
               || '). Reason: ' || trim(p_reason);

    insert into public.void_requests
      (branch_id, order_id, order_item_id, scope, reason,
       order_number, item_amount,
       requested_by, requested_by_role)
    values
      (order_row.branch_id, order_row.id, null, 'order', trim(p_reason),
       order_row.order_number, order_row.total,
       me.id, me.role)
    returning * into req;
  else
    select * into item from public.order_items where id = p_item_id;
    if not found then
      raise exception 'item_not_found' using errcode = 'P0002';
    end if;
    if item.order_id <> order_row.id then
      raise exception 'item_order_mismatch' using errcode = '22023';
    end if;
    if item.voided_at is not null then
      raise exception 'already_voided' using errcode = '23505';
    end if;

    v_scope := 'item';
    v_title := 'Void request — ' || coalesce(item.name_snapshot, 'item');
    v_body  := coalesce(me.full_name, 'A staff member') || ' is asking to void '
               || item.quantity || '× ' || coalesce(item.name_snapshot, 'item')
               || ' (₱' || to_char(coalesce(item.total_price, 0), 'FM999999990.00')
               || ') from ' || coalesce(order_row.order_number, 'an order')
               || '. Reason: ' || trim(p_reason);

    insert into public.void_requests
      (branch_id, order_id, order_item_id, scope, reason,
       item_name, item_qty, item_amount, order_number,
       requested_by, requested_by_role)
    values
      (order_row.branch_id, order_row.id, item.id, 'item', trim(p_reason),
       item.name_snapshot, item.quantity, item.total_price, order_row.order_number,
       me.id, me.role)
    returning * into req;
  end if;

  perform private.notify_managers(
    order_row.branch_id, 'void_request', v_title, v_body,
    'void-requests', req.id, 'high'
  );

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, after_state, metadata)
  values
    (me.id, me.role, 'void_request.create', 'void_request', req.id,
     jsonb_build_object('scope', v_scope, 'reason', trim(p_reason)),
     jsonb_build_object('order_id', order_row.id, 'order_item_id', p_item_id,
                        'branch_id', order_row.branch_id));

  return req;
end $$;

revoke execute on function public.request_void(uuid, uuid, text) from public, anon;
grant   execute on function public.request_void(uuid, uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 2. APPROVE  (manager+ only — this is what actually voids)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.approve_void_request(
  p_request_id uuid,
  p_note       text default null
) returns public.void_requests
language plpgsql security definer set search_path = ''
as $$
declare
  req        public.void_requests%rowtype;
  order_row  public.orders%rowtype;
  it         record;
  n_voided   int := 0;
  v_cancel_order boolean := false;
begin
  -- Managerial and higher only. Supervisor is intentionally excluded,
  -- matching public.void_order_item().
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  select * into req from public.void_requests where id = p_request_id for update;
  if not found then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
  if req.status <> 'pending' then
    raise exception 'request_not_pending' using errcode = '23514';
  end if;
  if not private.has_role('admin') and req.branch_id <> private.my_branch() then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  select * into order_row from public.orders where id = req.order_id;
  if order_row.status in ('completed','cancelled') then
    raise exception 'order_terminal' using errcode = '23514';
  end if;

  if req.scope = 'item' then
    -- Delegate to the existing manager-only void so there is exactly one
    -- code path that mutates order_items, and one audit shape.
    perform public.void_order_item(req.order_item_id, req.reason);
    n_voided := 1;
  else
    for it in
      select id from public.order_items
       where order_id = req.order_id and voided_at is null
    loop
      perform public.void_order_item(it.id, req.reason);
      n_voided := n_voided + 1;
    end loop;

    -- Any per-item requests still pending on this order are now moot:
    -- their items were just voided as part of the whole. Left alone they
    -- would sit in the queue forever, unapprovable (the order is about to
    -- go terminal) and keeping the manager's badge lit.
    update public.void_requests
       set status      = 'approved',
           reviewed_by = auth.uid(),
           reviewed_at = now(),
           review_note = 'Covered by the whole-order void'
     where order_id = req.order_id
       and status   = 'pending'
       and id      <> p_request_id;

    v_cancel_order := true;
  end if;

  update public.void_requests
     set status      = 'approved',
         reviewed_by = auth.uid(),
         reviewed_at = now(),
         review_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_request_id
  returning * into req;

  -- Cancel the order LAST, deliberately. trg_close_void_requests_on_terminal
  -- sweeps any still-pending request on an order that goes terminal — if we
  -- cancelled the order first, that sweep would mislabel the very requests
  -- this call just approved.
  if v_cancel_order then
    update public.orders
       set status        = 'cancelled',
           cancelled_at  = now(),
           cancel_reason = req.reason
     where id = req.order_id;
  end if;

  -- Tell the person who asked.
  if req.requested_by is not null then
    perform public.notify_push(
      req.requested_by, req.branch_id, 'void_request_approved',
      'Void approved',
      coalesce(req.item_name, 'Order ' || coalesce(req.order_number, ''))
        || ' has been voided by a manager.',
      null, 'void_request', req.id, 'normal'
    );
  end if;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'void_request.approve', 'void_request', req.id,
     jsonb_build_object('status', 'approved', 'items_voided', n_voided),
     jsonb_build_object('order_id', req.order_id, 'scope', req.scope,
                        'requested_by', req.requested_by, 'note', p_note));

  return req;
end $$;

revoke execute on function public.approve_void_request(uuid, text) from public, anon;
grant   execute on function public.approve_void_request(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 3. DENY  (manager+ only)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.deny_void_request(
  p_request_id uuid,
  p_note       text default null
) returns public.void_requests
language plpgsql security definer set search_path = ''
as $$
declare
  req public.void_requests%rowtype;
begin
  if not private.has_role('manager') then
    raise exception 'insufficient_privileges' using errcode = '42501';
  end if;

  select * into req from public.void_requests where id = p_request_id for update;
  if not found then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
  if req.status <> 'pending' then
    raise exception 'request_not_pending' using errcode = '23514';
  end if;
  if not private.has_role('admin') and req.branch_id <> private.my_branch() then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;

  update public.void_requests
     set status      = 'denied',
         reviewed_by = auth.uid(),
         reviewed_at = now(),
         review_note = nullif(trim(coalesce(p_note, '')), '')
   where id = p_request_id
  returning * into req;

  if req.requested_by is not null then
    perform public.notify_push(
      req.requested_by, req.branch_id, 'void_request_denied',
      'Void request denied',
      coalesce(req.item_name, 'Order ' || coalesce(req.order_number, ''))
        || ' was not voided.'
        || coalesce(' Manager note: ' || req.review_note, ''),
      null, 'void_request', req.id, 'normal'
    );
  end if;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'void_request.deny', 'void_request', req.id,
     jsonb_build_object('status', 'denied'),
     jsonb_build_object('order_id', req.order_id, 'requested_by', req.requested_by,
                        'note', p_note));

  return req;
end $$;

revoke execute on function public.deny_void_request(uuid, text) from public, anon;
grant   execute on function public.deny_void_request(uuid, text) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 4. CANCEL  (the requester withdrawing their own pending request)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.cancel_void_request(p_request_id uuid)
returns public.void_requests
language plpgsql security definer set search_path = ''
as $$
declare
  req public.void_requests%rowtype;
begin
  select * into req from public.void_requests where id = p_request_id for update;
  if not found then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
  -- Either you filed it, or you are a manager in the same branch.
  -- `is distinct from` so a null requested_by (staff row deleted) does not
  -- make the comparison null and fall through to the manager branch check
  -- with nobody actually authorised.
  if req.requested_by is distinct from auth.uid() then
    if not private.has_role('manager') then
      raise exception 'insufficient_privileges' using errcode = '42501';
    end if;
    if not private.has_role('admin') and req.branch_id <> private.my_branch() then
      raise exception 'wrong_branch' using errcode = '42501';
    end if;
  end if;
  if req.status <> 'pending' then
    raise exception 'request_not_pending' using errcode = '23514';
  end if;

  update public.void_requests
     set status      = 'cancelled',
         reviewed_by = auth.uid(),
         reviewed_at = now()
   where id = p_request_id
  returning * into req;

  return req;
end $$;

revoke execute on function public.cancel_void_request(uuid) from public, anon;
grant   execute on function public.cancel_void_request(uuid) to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 5. PENDING COUNT  (cheap badge query for the manager sidebar)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.pending_void_request_count()
returns int
language sql security definer stable set search_path = ''
as $$
  select count(*)::int
    from public.void_requests
   where status = 'pending'
     and (
       private.has_role('admin')
       or (private.has_role('manager') and branch_id = private.my_branch())
     )
$$;

revoke execute on function public.pending_void_request_count() from public, anon;
grant   execute on function public.pending_void_request_count() to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 6. READABLE VIEW  (joins the requester + reviewer names)
-- ═══════════════════════════════════════════════════════════════
create or replace view public.v_void_requests
with (security_invoker = true) as
select
  vr.*,
  rq.full_name as requested_by_name,
  rv.full_name as reviewed_by_name,
  rv.role      as reviewed_by_role,
  o.status     as order_status,
  o.order_type as order_type
from public.void_requests vr
left join public.staff  rq on rq.id = vr.requested_by
left join public.staff  rv on rv.id = vr.reviewed_by
left join public.orders o  on o.id  = vr.order_id;

grant select on public.v_void_requests to authenticated;

-- ═══════════════════════════════════════════════════════════════
-- 7. GUARD RAILS
--
-- Sitting at the bottom of the enum only stops has_role() checks.
-- Several policies in earlier migrations gate on BRANCH alone, not on
-- role — orders_staff_update, order_items_update, notif_read,
-- messages_read. A display account passes every one of those, which
-- would let it void an item with a plain UPDATE and never touch the
-- request flow at all. This section closes each of those doors.
--
--   7a. no new orders or order lines from a screen
--   7b. no direct UPDATE on order_items by anyone — voiding now has
--       exactly two doors, both of them audited functions
--   7c. column-level trigger guard on orders
--   7d. no forged audit rows
--   7e. no reading branch broadcasts / branch notifications
-- ═══════════════════════════════════════════════════════════════

-- ── 7a ────────────────────────────────────────────────────────
-- A wall-mounted screen reads and advances tickets. It does not open
-- new checks. (Drop these two policies back to the sql/03 versions if
-- you ever want the floor screen to take orders directly.)
--
-- NOTE: these two REPLACE the versions from sql/03-security-fixes.sql.
-- The original branch checks are preserved verbatim; the only addition
-- is the trailing display-role exclusion.
drop policy if exists orders_auth_create on public.orders;
create policy orders_auth_create on public.orders
  for insert to authenticated
  with check (
    (branch_id = private.my_branch() or private.has_role('admin'))
    and private.my_role() not in ('kitchen_display', 'dine_in_display')
  );

drop policy if exists order_items_auth_insert on public.order_items;
create policy order_items_auth_insert on public.order_items
  for insert to authenticated
  with check (
    exists (
      select 1 from public.orders o
      where o.id = order_id
        and (o.branch_id = private.my_branch() or private.has_role('admin'))
    )
    and private.my_role() not in ('kitchen_display', 'dine_in_display')
  );

-- ── 7b. NO DIRECT UPDATE ON order_items ───────────────────────
-- This is the important one. order_items_update (sql/01) gated on
-- branch only, so ANY authenticated account in the branch — including
-- a screen — could run:
--     update order_items set voided_at = now() where id = '…'
-- and the recompute trigger would obediently drop the order total,
-- with no void_requests row and no audit_log entry.
--
-- Nothing in the app has ever updated an order line except voiding.
-- So the policy goes away entirely. Voiding keeps working because both
-- of its doors are SECURITY DEFINER functions, which are not subject
-- to RLS:
--     public.void_order_item()      — manager+, direct
--     public.approve_void_request() — manager+, via a request
drop policy if exists order_items_update on public.order_items;
-- TRUNCATE included deliberately — it bypasses RLS, and Supabase's default
-- grant hands it to `authenticated`. Without it, "no direct UPDATE" is
-- decoration: any staffer could truncate order_items (cascading into
-- void_requests) and erase the evidence instead of voiding.
revoke update, delete, truncate on public.order_items from anon, authenticated;
revoke truncate on public.orders, public.audit_log from anon, authenticated;

-- ── 7c. COLUMN GUARD ON orders ────────────────────────────────
-- orders_staff_update also gates on branch alone. RLS is row-level and
-- what's needed here is column-level plus role-level, so this is a
-- trigger rather than a policy.
create or replace function public.trg_guard_order_update()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  r public.staff_role;
begin
  r := private.my_role();
  -- No staff row = the anonymous customer checkout path. RLS has
  -- already scoped that; nothing here applies.
  if r is null then
    return new;
  end if;

  -- Nobody below manager cancels an order. That is exactly what a
  -- whole-order void request is for.
  if new.status = 'cancelled'
     and old.status is distinct from 'cancelled'
     and not private.has_role('manager') then
    raise exception 'cancel_requires_manager' using errcode = '42501';
  end if;

  -- Discounts are a supervisor+ decision. The Live Orders UI has always
  -- gated the button at supervisor, but nothing enforced it server-side,
  -- so a dining account could zero a ₱900 bill with one UPDATE and leave
  -- no audit row — the same outcome voiding is supposed to control.
  if not private.has_role('supervisor')
     and (coalesce(new.discount_amount, 0) is distinct from coalesce(old.discount_amount, 0)
          or coalesce(new.service_charge, 0) is distinct from coalesce(old.service_charge, 0)) then
    raise exception 'adjustments_require_supervisor' using errcode = '42501';
  end if;

  -- Screens may advance the workflow status and nothing else. Every
  -- other column has to come back unchanged — no totals, no discounts,
  -- no payment fields, no customer edits.
  if r in ('kitchen_display', 'dine_in_display') then
    if (to_jsonb(new) - '{status,confirmed_at,ready_at,served_at,updated_at}'::text[])
       is distinct from
       (to_jsonb(old) - '{status,confirmed_at,ready_at,served_at,updated_at}'::text[])
    then
      raise exception 'display_may_only_advance_status' using errcode = '42501';
    end if;
    -- ...and it stops short of closing the check. 'completed' means payment
    -- was taken; a shared wall screen should not be the thing that says so.
    -- It also closed a loophole: a screen could file a void request, then
    -- immediately complete the order, leaving the request permanently
    -- unapprovable (void_order_item refuses terminal orders).
    --
    -- In practice the jsonb check above fires first, because the app always
    -- writes completed_at alongside status. This is the belt to that braces:
    -- it catches a hand-written `set status = 'completed'` with no stamp.
    if new.status in ('completed', 'cancelled')
       and old.status is distinct from new.status then
      raise exception 'display_cannot_close_orders' using errcode = '42501';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_guard_order_update on public.orders;
create trigger trg_guard_order_update
  before update on public.orders
  for each row execute function public.trg_guard_order_update();

-- ── 7d. NO FORGED AUDIT ROWS ──────────────────────────────────
-- audit_write (sql/03) only checked actor_id, so any account could
-- write a row claiming actor_role = 'ceo'. Pin the role to the truth.
drop policy if exists audit_write on public.audit_log;
create policy audit_write on public.audit_log
  for insert to authenticated
  with check (
    actor_id = auth.uid()
    and (actor_role is null or actor_role = private.my_role())
  );

-- ── 7e. SCREENS DON'T READ BRANCH BROADCASTS ──────────────────
-- A tablet on a wall in a public dining room should not be one tap
-- away from HR messages or notifications about other people. Direct
-- messages addressed TO the screen still work (that's how it learns a
-- void verdict); branch-wide broadcasts do not.
drop policy if exists notif_read on public.notifications;
create policy notif_read on public.notifications
  for select to authenticated using (
    user_id = auth.uid()
    or (user_id is null
        and branch_id = private.my_branch()
        and private.my_role() not in ('kitchen_display', 'dine_in_display'))
    or private.has_role('admin')
  );

drop policy if exists messages_read on public.messages;
create policy messages_read on public.messages
  for select to authenticated using (
    to_staff_id = auth.uid()
    or from_staff_id = auth.uid()
    or (to_staff_id is null
        and branch_id = private.my_branch()
        and private.my_role() not in ('kitchen_display', 'dine_in_display'))
    or private.has_role('admin')
  );

drop policy if exists messages_update_read on public.messages;
create policy messages_update_read on public.messages
  for update to authenticated using (
    to_staff_id = auth.uid()
    or (to_staff_id is null
        and branch_id = private.my_branch()
        and private.my_role() not in ('kitchen_display', 'dine_in_display'))
    or private.has_role('admin')
  );

drop policy if exists audit_summary_read on public.audit_daily_summary;
create policy audit_summary_read on public.audit_daily_summary
  for select to authenticated using (
    private.has_role('manager')
    and (branch_id = private.my_branch() or private.has_role('admin'))
  );

-- ── 7f. NO NEGATIVE LINES ─────────────────────────────────────
-- Another way to reach a zero bill without voiding: insert a line with a
-- negative total_price and let recompute_order_totals do the work.
--
-- This is a BEFORE INSERT trigger and NOT a CHECK constraint, on purpose.
-- A CHECK — even one added NOT VALID — is enforced on every later UPDATE
-- of a pre-existing row. If any legacy row in this database already has a
-- negative or zero-quantity line, a CHECK would make that row permanently
-- impossible to void: void_order_item() UPDATEs the row, the constraint
-- refuses, and a manager can never clear it. An insert-only trigger closes
-- the attack without booby-trapping the fix.
--
-- If you want the stronger guarantee later, clean up first, then add the
-- constraint knowingly:
--   select count(*) from public.order_items
--    where total_price < 0 or unit_price < 0 or quantity <= 0;
create or replace function public.trg_order_items_nonneg()
returns trigger
language plpgsql set search_path = ''
as $$
begin
  if new.total_price < 0 or new.unit_price < 0 or new.quantity <= 0 then
    raise exception 'order_line_must_be_positive' using errcode = '23514';
  end if;
  return new;
end $$;

drop trigger if exists trg_order_items_nonneg on public.order_items;
create trigger trg_order_items_nonneg
  before insert on public.order_items
  for each row execute function public.trg_order_items_nonneg();

-- Clean up the constraint if an earlier run of this file created it.
alter table public.order_items drop constraint if exists order_items_nonneg;

-- ═══════════════════════════════════════════════════════════════
-- 8. DON'T STRAND REQUESTS ON A CLOSED ORDER
--
-- void_order_item() refuses completed/cancelled orders, so a request
-- still pending when its order closes can never be approved — it would
-- sit in the queue forever with the manager's badge lit, and the only
-- way out would be to deny a void they actually wanted to approve.
--
-- When an order goes terminal, close out whatever is still pending on it.
-- (Section 7c already stops a display account from being the one to close
-- an order; this covers the ordinary case where dining staff complete a
-- check while a request is in flight.)
-- ═══════════════════════════════════════════════════════════════
create or replace function public.trg_close_void_requests_on_terminal()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  if new.status in ('completed', 'cancelled')
     and old.status is distinct from new.status then
    update public.void_requests
       set status      = 'cancelled',
           reviewed_by = coalesce(reviewed_by, auth.uid()),
           reviewed_at = now(),
           review_note = coalesce(review_note,
             'Order was ' || new.status::text || ' before a manager reviewed this. '
             || 'Correct it through a refund instead.')
     where order_id = new.id
       and status   = 'pending';
  end if;
  return new;
end $$;

drop trigger if exists trg_close_void_requests_on_terminal on public.orders;
create trigger trg_close_void_requests_on_terminal
  after update of status on public.orders
  for each row execute function public.trg_close_void_requests_on_terminal();

-- ═══════════════════════════════════════════════════════════════
-- 9. ADVISOR HYGIENE
--
-- sql/12-advisor-cleanup.sql revokes EXECUTE on every trigger function
-- from anon/authenticated so the Supabase linter stays quiet. It works
-- off a hardcoded list, so the three trigger functions added above have
-- to be revoked here too — otherwise the advisor WARN count creeps up
-- from the documented 0-ERROR / 3-WARN baseline and stops being a useful
-- signal. (Calling a trigger function directly is harmless — Postgres
-- refuses it outside a trigger — this is purely to keep the baseline
-- meaningful. Add these three names to 12's array if you ever rebuild
-- from scratch.)
-- ═══════════════════════════════════════════════════════════════
revoke execute on function public.trg_guard_order_update()              from public, anon, authenticated;
revoke execute on function public.trg_close_void_requests_on_terminal() from public, anon, authenticated;
revoke execute on function public.trg_order_items_nonneg()              from public, anon, authenticated;
revoke execute on function private.notify_managers(uuid,text,text,text,text,uuid,public.notification_priority) from public, anon, authenticated;

-- Done. Verify with:
--   select unnest(enum_range(null::public.staff_role));
--   select * from public.v_void_requests order by requested_at desc limit 5;
--   select public.pending_void_request_count();
--
-- And confirm the lock actually holds — signed in as a display account,
-- this must fail:
--   update public.order_items set voided_at = now() where id = '<any>';
--   → ERROR: permission denied for table order_items
