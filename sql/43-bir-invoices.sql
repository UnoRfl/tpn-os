-- ═══════════════════════════════════════════════════════════════
-- 43 · BIR invoices written by hand (the booklet), recorded here
--
-- TPN OS has no BIR Permit to Use, so the official invoice is still
-- written from the BIR-registered booklet. This keeps the record:
--   orders.invoice_no     the booklet number written for that order
--   bir_day_invoices      the end-of-day invoice for small sales
-- and tells staff which sales need one (invoice_day_summary):
--   VAT-registered        every sale
--   not VAT-registered    any sale over the threshold (₱500, RR 7-2024
--                         as amended by RR 11-2024) or when the customer
--                         asks; the rest go on one invoice at day's end
-- site_settings 'bir.vat_registered' = 'yes' | 'no' (blank = not set,
-- treated as not VAT-registered and flagged on screen).
-- Additive only. Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

alter table public.orders add column if not exists invoice_no text;
alter table public.orders add column if not exists invoice_at timestamptz;
alter table public.orders add column if not exists invoice_by uuid references public.staff(id) on delete set null;

-- Only record_order_invoice writes these, so every change is audited.
create or replace function private.trg_guard_invoice_no()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if (new.invoice_no is distinct from old.invoice_no
      or new.invoice_at is distinct from old.invoice_at
      or new.invoice_by is distinct from old.invoice_by)
     and coalesce(current_setting('tpn.invoice', true), 'off') <> 'on' then
    raise exception 'invoice_no_is_set_by_rpc: use record_order_invoice' using errcode = '42501';
  end if;
  return new;
end $$;
revoke all on function private.trg_guard_invoice_no() from public, anon, authenticated;
drop trigger if exists trg_guard_invoice_no on public.orders;
create trigger trg_guard_invoice_no before update on public.orders
  for each row execute function private.trg_guard_invoice_no();

create table if not exists public.bir_day_invoices (
  id            uuid primary key default gen_random_uuid(),
  branch_id     uuid not null references public.branches(id) on delete cascade,
  business_date date not null,
  invoice_no    text not null check (length(btrim(invoice_no)) between 1 and 40),
  amount        numeric(12,2) not null check (amount > 0),
  recorded_by   uuid references public.staff(id) on delete set null,
  recorded_at   timestamptz not null default now(),
  unique (branch_id, business_date, invoice_no)
);
comment on table public.bir_day_invoices is
  'End-of-day BIR invoice(s) covering small sales that got no invoice of their own. Written only through record_day_invoice.';
alter table public.bir_day_invoices enable row level security;
revoke all on public.bir_day_invoices from anon, authenticated;
grant select on public.bir_day_invoices to authenticated;
drop policy if exists bir_day_invoices_read on public.bir_day_invoices;
create policy bir_day_invoices_read on public.bir_day_invoices for select to authenticated
  using (private.can('payments.take') or private.can('finance.view'));

create or replace function private.bir_threshold()
returns numeric language sql immutable set search_path = '' as $$ select 500::numeric $$;

create or replace function private.bir_vat_registered()
returns boolean language sql stable security definer set search_path = '' as $$
  select lower(coalesce(s.value #>> '{}', '')) in ('yes', 'true', 'y', 'oo')
    from public.site_settings s where s.key = 'bir.vat_registered'
$$;
revoke all on function private.bir_vat_registered() from public, anon, authenticated;

-- One order's booklet invoice number. Blank clears a mistake. Audited.
create or replace function public.record_order_invoice(p_order_id uuid, p_invoice_no text)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  o     public.orders%rowtype;
  v_no  text := nullif(btrim(coalesce(p_invoice_no, '')), '');
begin
  if not private.can('payments.take') then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if v_no is not null and length(v_no) > 40 then
    raise exception 'invoice_no_too_long' using errcode = '22023';
  end if;
  select * into o from public.orders where id = p_order_id for update;
  if not found then
    raise exception 'order_not_found' using errcode = 'P0002';
  end if;
  if o.branch_id is distinct from private.my_branch() and private.my_role() not in ('admin', 'director', 'ceo') then
    raise exception 'permission_denied: other branch' using errcode = '42501';
  end if;

  perform set_config('tpn.invoice', 'on', true);
  update public.orders
     set invoice_no = v_no,
         invoice_at = case when v_no is null then null else now() end,
         invoice_by = case when v_no is null then null else auth.uid() end
   where id = p_order_id;
  perform set_config('tpn.invoice', 'off', true);

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'invoice.record', 'order', p_order_id,
          jsonb_build_object('order_number', o.order_number, 'invoice_no', v_no, 'was', o.invoice_no));
  return jsonb_build_object('order_id', p_order_id, 'invoice_no', v_no);
end $$;
revoke all on function public.record_order_invoice(uuid, text) from public, anon;
grant execute on function public.record_order_invoice(uuid, text) to authenticated;

-- The end-of-day invoice for the small sales. Audited.
create or replace function public.record_day_invoice(p_date date, p_invoice_no text, p_amount numeric, p_branch uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_no     text := nullif(btrim(coalesce(p_invoice_no, '')), '');
  v_id     uuid;
begin
  if not (private.can('payments.take') or private.can('finance.view')) then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;
  if v_branch is distinct from private.my_branch() and private.my_role() not in ('admin', 'director', 'ceo') then
    raise exception 'permission_denied: other branch' using errcode = '42501';
  end if;
  if v_no is null or length(v_no) > 40 then
    raise exception 'invoice_no_required' using errcode = '22023';
  end if;
  if coalesce(p_amount, 0) <= 0 then
    raise exception 'amount_must_be_positive' using errcode = '22023';
  end if;

  insert into public.bir_day_invoices (branch_id, business_date, invoice_no, amount, recorded_by)
  values (v_branch, p_date, v_no, round(p_amount, 2), auth.uid())
  returning id into v_id;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'invoice.day', 'bir_day_invoice', v_id,
          jsonb_build_object('date', p_date, 'invoice_no', v_no, 'amount', round(p_amount, 2)));
  return jsonb_build_object('id', v_id);
end $$;
revoke all on function public.record_day_invoice(date, text, numeric, uuid) from public, anon;
grant execute on function public.record_day_invoice(date, text, numeric, uuid) to authenticated;

-- What the day still needs. Paid, not cancelled, placed that Manila day.
create or replace function public.invoice_day_summary(p_date date default null, p_branch uuid default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare
  v_branch uuid := coalesce(p_branch, private.my_branch());
  v_date   date := coalesce(p_date, (now() at time zone 'Asia/Manila')::date);
  v_lo     timestamptz := (v_date::timestamp at time zone 'Asia/Manila');
  v_hi     timestamptz := ((v_date + 1)::timestamp at time zone 'Asia/Manila');
  v_vat    boolean := private.bir_vat_registered();
  v_set    boolean := exists (select 1 from public.site_settings s
                               where s.key = 'bir.vat_registered' and nullif(s.value #>> '{}', '') is not null);
  v_min    numeric := private.bir_threshold();
  v        jsonb;
begin
  if not (private.can('payments.take') or private.can('finance.view')) then
    raise exception 'permission_denied: payments.take' using errcode = '42501';
  end if;

  with day as (
    select o.id, o.order_number, o.total, o.invoice_no
      from public.orders o
     where o.branch_id = v_branch and o.status <> 'cancelled' and o.payment_status = 'paid'
       and o.placed_at >= v_lo and o.placed_at < v_hi)
  select jsonb_build_object(
    'date', v_date,
    'vat_registered', v_vat,
    'vat_status_set', v_set,
    'threshold', v_min,
    'invoiced', (select count(*) from day where invoice_no is not null),
    'missing', coalesce((select jsonb_agg(jsonb_build_object('id', d.id, 'order_number', d.order_number, 'total', d.total)
                                          order by d.order_number)
                           from day d where d.invoice_no is null and (v_vat or d.total > v_min)), '[]'::jsonb),
    'small_total', case when v_vat then 0
                        else coalesce((select sum(d.total) from day d where d.invoice_no is null and d.total <= v_min), 0) end,
    'small_count', case when v_vat then 0
                        else (select count(*) from day d where d.invoice_no is null and d.total <= v_min) end,
    'day_invoices', coalesce((select jsonb_agg(jsonb_build_object('invoice_no', b.invoice_no, 'amount', b.amount,
                                                                  'recorded_at', b.recorded_at) order by b.recorded_at)
                                from public.bir_day_invoices b
                               where b.branch_id = v_branch and b.business_date = v_date), '[]'::jsonb)
  ) into v;
  return v;
end $$;
revoke all on function public.invoice_day_summary(date, uuid) from public, anon;
grant execute on function public.invoice_day_summary(date, uuid) to authenticated;

insert into public.site_settings (key, value) values ('bir.vat_registered', null)
on conflict (key) do nothing;
