-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 26: every status change is attributable
--
-- THE GAP
-- TPN.updateOrderStatus() wrote no audit row, and trg_audit_order_money
-- only fires when status reaches 'completed' or 'cancelled'. So the
-- transitions that happen all shift -- pending → confirmed → preparing →
-- ready → served -- had NO record of who moved them. When a manager drives
-- the line because the kitchen screen is down, nothing afterwards said so.
--
-- TWO LAYERS, on purpose:
--   trg_audit_order_status   a TRIGGER, so a direct UPDATE from any client
--                            is recorded whether it wants to be or not.
--                            This is the one that matters.
--   advance_order_status()   an RPC the screens call, which also records
--                            WHICH SCREEN the tap came from. Richer, but
--                            optional -- the trigger is the backstop.
--
-- The trigger deliberately skips completed/cancelled: trg_audit_order_money
-- already logs those with the money detail, and two rows per event makes the
-- log harder to read rather than safer.
--
-- Verified: a plain `update orders set status=...` with no RPC still lands
-- in audit_log, with the actor, just without a source.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

create or replace function public.trg_audit_order_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_tbl int;
begin
  if new.status is not distinct from old.status then return new; end if;
  -- covered in more detail by trg_audit_order_money
  if new.status in ('completed', 'cancelled') then return new; end if;

  if new.table_id is not null then
    select table_number into v_tbl from public.restaurant_tables where id = new.table_id;
  end if;

  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id,
     before_state, after_state, metadata)
  values
    (auth.uid(), private.my_role(), 'order.status', 'order', new.id,
     jsonb_build_object('status', old.status),
     jsonb_build_object('status', new.status),
     jsonb_build_object(
       'order_number', new.order_number,
       'order_type',   new.order_type,
       'table_number', v_tbl,
       'total',        new.total,
       -- set by advance_order_status(); null for a plain UPDATE
       'source', nullif(current_setting('tpn.status_source', true), '')
     ));
  return new;
end $$;

drop trigger if exists trg_orders_audit_status on public.orders;
create trigger trg_orders_audit_status
  after update of status on public.orders
  for each row execute function public.trg_audit_order_status();

revoke execute on function public.trg_audit_order_status() from public, anon, authenticated;


-- What the three screens call. Adds the surface, and refuses a transition
-- the caller may not make -- the same gates trg_guard_order_update enforces,
-- but with an error a human can read.
create or replace function public.advance_order_status(
  p_order_id uuid, p_status text, p_source text default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_old public.order_status; v_new public.order_status; v_branch uuid;
begin
  if not private.can('orders.manage') and not private.can('kds.advance') then
    raise exception 'permission_denied: orders.manage' using errcode = '42501';
  end if;

  begin
    v_new := p_status::public.order_status;
  exception when others then
    raise exception 'bad_status: %', p_status using errcode = '22023';
  end;

  select status, branch_id into v_old, v_branch from public.orders where id = p_order_id;
  if v_old is null then
    raise exception 'order_not_found' using errcode = '22023';
  end if;
  if v_branch is distinct from private.my_branch() and not private.can('settings.manage') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  if v_old = v_new then
    return jsonb_build_object('id', p_order_id, 'status', v_new, 'changed', false);
  end if;
  if v_old in ('completed','cancelled') then
    raise exception 'order_already_closed: it is %', v_old using errcode = '22023';
  end if;
  -- Closing an order is a money event with its own gate.
  if v_new in ('completed','cancelled') and not private.can('orders.cancel') then
    raise exception 'closing_requires_manager' using errcode = '42501';
  end if;

  -- Read by trg_audit_order_status so the log records which screen acted.
  perform set_config('tpn.status_source', coalesce(p_source, ''), true);

  update public.orders
     set status = v_new,
         confirmed_at = case when v_new='confirmed' then coalesce(confirmed_at, now()) else confirmed_at end,
         ready_at     = case when v_new='ready'     then coalesce(ready_at, now())     else ready_at end,
         served_at    = case when v_new='served'    then coalesce(served_at, now())    else served_at end
   where id = p_order_id;

  return jsonb_build_object('id', p_order_id, 'status', v_new, 'from', v_old, 'changed', true);
end $$;

comment on function public.advance_order_status is
  'What the portal queue, floor panel and kitchen screen call to move a ticket.
   Records the surface in the audit row so "who moved this, and from where"
   always has an answer -- including when a manager drives the line because a
   screen is down.';

revoke execute on function public.advance_order_status(uuid, text, text) from public, anon;
grant  execute on function public.advance_order_status(uuid, text, text) to authenticated;

-- Known sources the clients send: portal_kds, portal_orders, kitchen_screen,
-- floor_panel. Free text on purpose -- a new surface should not need a
-- migration to start attributing itself.
