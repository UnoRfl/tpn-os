-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 21: inventory in, money out
--
-- Two halves of the same question -- "what did we actually make?" --
-- so they ship together: you cannot answer it without knowing what
-- the ingredients cost and what the staff were paid.
--
-- INVENTORY
-- Everything is a movement. Stock levels are never written by hand;
-- ingredients.current_stock is maintained by trigger from the ledger,
-- the same way orders.total is derived from order_items. That means a
-- stock level and its history can never disagree.
--
--   delivery_in   ingredients arrived (adds, has a cost)
--   usage         consumed by service (removes)
--   wastage       spoiled or thrown (removes, still a cost)
--   adjust_up     stock count found MORE than the system said
--   adjust_down   stock count found LESS than the system said
--   return_out    sent back to the supplier (removes)
--
-- adjust_up and adjust_down are two types rather than one signed
-- "adjustment" on purpose: quantity is CHECK-constrained positive, so a
-- single adjustment type could only ever add stock -- which would make a
-- downward stock-count correction impossible to record.
--
-- FINANCE
-- finance_summary() is the one call behind the money view. It buckets
-- by day, week or month and returns sales, cost of goods, labour and
-- other operating costs, so net income is arithmetic rather than a
-- guess. Costing method is configurable per branch because a kitchen
-- that does not log usage yet still needs a usable number -- see
-- finance_settings.cogs_method.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════

do $$ begin
  create type public.stock_movement_type as enum
    ('delivery_in','usage','wastage','adjust_up','adjust_down','return_out');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.pay_type as enum ('monthly','daily','hourly');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.expense_category as enum
    ('rent','utilities','gas_fuel','supplies','transport','marketing',
     'repairs','permits','equipment','other');
exception when duplicate_object then null; end $$;

do $$ begin
  create type public.cogs_method as enum ('actual','percent_of_sales');
exception when duplicate_object then null; end $$;


-- ═════════════════════════════════════════════════════════════
-- INVENTORY
-- ═════════════════════════════════════════════════════════════
create table if not exists public.suppliers (
  id             uuid primary key default gen_random_uuid(),
  branch_id      uuid references public.branches(id) on delete cascade,
  name           text not null,
  contact_person text,
  phone          text,
  email          text,
  address        text,
  notes          text,
  is_active      boolean not null default true,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now(),
  created_by     uuid references public.staff(id) on delete set null
);
create index if not exists idx_suppliers_branch on public.suppliers(branch_id, is_active);
drop trigger if exists trg_suppliers_touch on public.suppliers;
create trigger trg_suppliers_touch before update on public.suppliers
  for each row execute function public.tg_touch_updated();

create table if not exists public.ingredients (
  id             uuid primary key default gen_random_uuid(),
  branch_id      uuid not null references public.branches(id) on delete cascade,
  name           text not null,
  name_tagalog   text,
  category       text,                      -- 'Meat', 'Vegetables', 'Dry goods', 'Packaging'
  unit           text not null default 'kg',-- kg, g, L, mL, pc, tray, sack, box
  current_stock  numeric(12,3) not null default 0,   -- derived; see trg_stock_apply
  reorder_level  numeric(12,3) not null default 0,
  last_unit_cost numeric(12,2),
  avg_unit_cost  numeric(12,2),
  default_supplier_id uuid references public.suppliers(id) on delete set null,
  is_active      boolean not null default true,
  notes          text,
  created_at     timestamptz default now(),
  updated_at     timestamptz default now(),
  unique (branch_id, name)
);
create index if not exists idx_ingredients_branch on public.ingredients(branch_id, is_active);
create index if not exists idx_ingredients_low
  on public.ingredients(branch_id) where current_stock <= reorder_level;
drop trigger if exists trg_ingredients_touch on public.ingredients;
create trigger trg_ingredients_touch before update on public.ingredients
  for each row execute function public.tg_touch_updated();

comment on column public.ingredients.current_stock is
  'Derived from stock_movements by trg_stock_apply. Never write this directly --
   record an adjustment movement instead, so the history explains the number.';

create table if not exists public.stock_movements (
  id             uuid primary key default gen_random_uuid(),
  ingredient_id  uuid not null references public.ingredients(id) on delete cascade,
  branch_id      uuid not null references public.branches(id) on delete cascade,
  movement_type  public.stock_movement_type not null,
  quantity       numeric(12,3) not null,      -- always positive; direction comes from the type
  unit_cost      numeric(12,2),
  total_cost     numeric(12,2),
  supplier_id    uuid references public.suppliers(id) on delete set null,
  reference      text,                        -- DR number, invoice number
  occurred_at    timestamptz not null default now(),
  recorded_by    uuid references public.staff(id) on delete set null,
  notes          text,
  created_at     timestamptz default now(),
  constraint stock_qty_positive check (quantity > 0)
);
create index if not exists idx_stock_ing  on public.stock_movements(ingredient_id, occurred_at desc);
create index if not exists idx_stock_when on public.stock_movements(branch_id, occurred_at desc);
create index if not exists idx_stock_type on public.stock_movements(branch_id, movement_type, occurred_at);

comment on column public.stock_movements.quantity is
  'Always a positive magnitude. movement_type decides the sign, so a delivery
   of 5 and a wastage of 5 both store 5 and cannot be confused for each other.';


-- Sign convention in one place, so nothing else has to remember it.
create or replace function private.stock_direction(p_type public.stock_movement_type)
returns int
language sql
immutable
set search_path = ''
as $$
  select case p_type
           when 'delivery_in'  then  1
           when 'adjust_up'    then  1
           when 'usage'        then -1
           when 'wastage'      then -1
           when 'adjust_down'  then -1
           when 'return_out'   then -1
         end
$$;

comment on function private.stock_direction is
  'The only place the sign convention lives. quantity is always a positive
   magnitude; this decides whether it adds or removes.';

-- BEFORE INSERT/UPDATE only: complete the cost arithmetic so the caller may
-- send either a unit cost or a line total and get both stored.
create or replace function public.trg_stock_apply()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.total_cost is null and new.unit_cost is not null then
    new.total_cost := round(new.unit_cost * new.quantity, 2);
  elsif new.unit_cost is null and new.total_cost is not null and new.quantity <> 0 then
    new.unit_cost := round(new.total_cost / new.quantity, 2);
  end if;
  return new;
end $$;

-- BEFORE: fill in the cost arithmetic. AFTER: move the stock.
create or replace function public.trg_stock_level()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    update public.ingredients
       set current_stock = current_stock
             - (private.stock_direction(old.movement_type) * old.quantity)
     where id = old.ingredient_id;
    return old;
  end if;

  update public.ingredients
     set current_stock = current_stock
           + (private.stock_direction(new.movement_type) * new.quantity),
         last_unit_cost = case
           when new.movement_type = 'delivery_in' and new.unit_cost is not null
             then new.unit_cost else last_unit_cost end,
         avg_unit_cost = case
           when new.movement_type = 'delivery_in' and new.unit_cost is not null
             then coalesce((
               select round(sum(total_cost) / nullif(sum(quantity), 0), 2)
                 from public.stock_movements
                where ingredient_id = new.ingredient_id
                  and movement_type = 'delivery_in'
                  and total_cost is not null
             ), new.unit_cost)
           else avg_unit_cost end
   where id = new.ingredient_id;
  return new;
end $$;

drop trigger if exists trg_stock_cost  on public.stock_movements;
create trigger trg_stock_cost before insert or update on public.stock_movements
  for each row execute function public.trg_stock_apply();

drop trigger if exists trg_stock_level on public.stock_movements;
create trigger trg_stock_level after insert or delete on public.stock_movements
  for each row execute function public.trg_stock_level();


-- ═════════════════════════════════════════════════════════════
-- MONEY
-- ═════════════════════════════════════════════════════════════
create table if not exists public.staff_compensation (
  id             uuid primary key default gen_random_uuid(),
  staff_id       uuid not null references public.staff(id) on delete cascade,
  pay_type       public.pay_type not null default 'monthly',
  rate           numeric(12,2) not null,
  allowance      numeric(12,2) not null default 0,   -- per period, same cadence as rate
  effective_from date not null default current_date,
  effective_to   date,
  notes          text,
  created_at     timestamptz default now(),
  created_by     uuid references public.staff(id) on delete set null,
  constraint comp_rate_positive check (rate >= 0),
  constraint comp_dates_sane check (effective_to is null or effective_to >= effective_from)
);
create index if not exists idx_comp_staff on public.staff_compensation(staff_id, effective_from desc);

comment on table public.staff_compensation is
  'History, not current state -- a rate change adds a row and closes the old
   one, so a report about last month uses last month''s rate.';

create table if not exists public.operating_expenses (
  id           uuid primary key default gen_random_uuid(),
  branch_id    uuid not null references public.branches(id) on delete cascade,
  category     public.expense_category not null default 'other',
  label        text not null,
  amount       numeric(12,2) not null,
  incurred_on  date not null default current_date,
  supplier_id  uuid references public.suppliers(id) on delete set null,
  reference    text,
  notes        text,
  recorded_by  uuid references public.staff(id) on delete set null,
  created_at   timestamptz default now(),
  updated_at   timestamptz default now(),
  constraint expense_amount_positive check (amount >= 0)
);
create index if not exists idx_expenses_when on public.operating_expenses(branch_id, incurred_on desc);
drop trigger if exists trg_expenses_touch on public.operating_expenses;
create trigger trg_expenses_touch before update on public.operating_expenses
  for each row execute function public.tg_touch_updated();

create table if not exists public.finance_settings (
  branch_id      uuid primary key references public.branches(id) on delete cascade,
  cogs_method    public.cogs_method not null default 'percent_of_sales',
  cogs_percent   numeric(5,2) not null default 35.00,
  include_wastage_in_cogs boolean not null default true,
  updated_at     timestamptz default now(),
  updated_by     uuid references public.staff(id) on delete set null,
  constraint cogs_percent_sane check (cogs_percent >= 0 and cogs_percent <= 100)
);

comment on column public.finance_settings.cogs_method is
  '"actual" totals real usage and wastage movements -- only honest once the
   kitchen logs usage daily. "percent_of_sales" applies cogs_percent, which is
   the sane default until then. The money view says which one produced the
   number so nobody mistakes an estimate for a measurement.';

insert into public.finance_settings (branch_id)
select id from public.branches
on conflict (branch_id) do nothing;


-- ═════════════════════════════════════════════════════════════
-- THE MONEY VIEW
-- ═════════════════════════════════════════════════════════════
create or replace function public.finance_summary(
  p_from        date,
  p_to          date,
  p_granularity text default 'day',      -- 'day' | 'week' | 'month'
  p_branch      uuid default null
)
returns table (
  period_start   date,
  gross_sales    numeric,
  discounts      numeric,
  net_sales      numeric,
  order_count    bigint,
  cogs           numeric,
  cogs_basis     text,
  labour_cost    numeric,
  other_expenses numeric,
  net_income     numeric
)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_branch  uuid := coalesce(p_branch, private.my_branch());
  v_trunc   text := case lower(p_granularity)
                      when 'week' then 'week' when 'month' then 'month' else 'day' end;
  v_method  public.cogs_method;
  v_percent numeric;
  v_waste   boolean;
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;

  select cogs_method, cogs_percent, include_wastage_in_cogs
    into v_method, v_percent, v_waste
    from public.finance_settings where branch_id = v_branch;
  v_method  := coalesce(v_method, 'percent_of_sales');
  v_percent := coalesce(v_percent, 35.00);
  v_waste   := coalesce(v_waste, true);

  return query
  with periods as (
    select generate_series(
             date_trunc(v_trunc, p_from::timestamp),
             date_trunc(v_trunc, p_to::timestamp),
             ('1 ' || v_trunc)::interval
           )::date as pstart
  ),
  bounds as (
    select pstart,
           pstart as lo,
           (date_trunc(v_trunc, pstart::timestamp) + ('1 ' || v_trunc)::interval)::date as hi
      from periods
  ),
  sales as (
    select b.pstart,
           coalesce(sum(o.subtotal), 0)        as gross,
           coalesce(sum(o.discount_amount), 0) as disc,
           coalesce(sum(o.total), 0)           as net,
           count(o.id)                         as orders
      from bounds b
      left join public.orders o
             on o.branch_id = v_branch
            and o.status not in ('cancelled')
            and o.placed_at >= b.lo and o.placed_at < b.hi
     group by b.pstart
  ),
  actual_cogs as (
    select b.pstart,
           coalesce(sum(sm.total_cost), 0) as amt
      from bounds b
      left join public.stock_movements sm
             on sm.branch_id = v_branch
            and sm.occurred_at >= b.lo and sm.occurred_at < b.hi
            and (sm.movement_type = 'usage'
                 or (v_waste and sm.movement_type = 'wastage'))
     group by b.pstart
  ),
  labour as (
    -- monthly rates prorated across the bucket; daily and hourly rates
    -- read real attendance so a quiet week costs less than a busy one
    select b.pstart,
           coalesce(sum(
             case c.pay_type
               when 'monthly' then (c.rate + c.allowance) / 30.4375 * (b.hi - b.lo)
               when 'daily'   then (c.rate + c.allowance) * (
                      select count(distinct a.clock_in_at::date)
                        from public.attendance a
                       where a.staff_id = c.staff_id
                         and a.clock_in_at >= b.lo and a.clock_in_at < b.hi)
               when 'hourly'  then c.rate * coalesce((
                      select sum(extract(epoch from (a.clock_out_at - a.clock_in_at)) / 3600.0)
                        from public.attendance a
                       where a.staff_id = c.staff_id
                         and a.clock_in_at >= b.lo and a.clock_in_at < b.hi
                         and a.clock_out_at is not null), 0)
             end
           ), 0) as amt
      from bounds b
      left join public.staff_compensation c
             on c.effective_from < b.hi
            and (c.effective_to is null or c.effective_to >= b.lo)
            and exists (select 1 from public.staff s
                         where s.id = c.staff_id and s.branch_id = v_branch)
     group by b.pstart, b.lo, b.hi
  ),
  other as (
    select b.pstart, coalesce(sum(e.amount), 0) as amt
      from bounds b
      left join public.operating_expenses e
             on e.branch_id = v_branch
            and e.incurred_on >= b.lo and e.incurred_on < b.hi
     group by b.pstart
  )
  select s.pstart,
         s.gross, s.disc, s.net, s.orders,
         case when v_method = 'actual' then ac.amt
              else round(s.net * v_percent / 100.0, 2) end,
         case when v_method = 'actual'
              then 'measured from stock usage'
              else 'estimated at ' || v_percent || '% of net sales' end,
         round(l.amt, 2),
         o.amt,
         round(s.net
               - (case when v_method = 'actual' then ac.amt
                       else round(s.net * v_percent / 100.0, 2) end)
               - l.amt - o.amt, 2)
    from sales s
    join actual_cogs ac using (pstart)
    join labour      l  using (pstart)
    join other       o  using (pstart)
   order by s.pstart;
end $$;

comment on function public.finance_summary is
  'The money view. Buckets by day, week or month and returns cogs_basis
   alongside the number so an estimate is never mistaken for a measurement.';


-- Expense breakdown for the same window, for the pie next to the table.
create or replace function public.expense_breakdown(
  p_from date, p_to date, p_branch uuid default null)
returns table (category public.expense_category, total numeric, entries bigint)
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_branch uuid := coalesce(p_branch, private.my_branch());
begin
  if not private.can('finance.view') then
    raise exception 'permission_denied: finance.view' using errcode = '42501';
  end if;
  return query
    select e.category, sum(e.amount), count(*)
      from public.operating_expenses e
     where e.branch_id = v_branch
       and e.incurred_on >= p_from and e.incurred_on <= p_to
     group by e.category
     order by sum(e.amount) desc;
end $$;


-- ═════════════════════════════════════════════════════════════
-- RLS
-- ═════════════════════════════════════════════════════════════
alter table public.suppliers           enable row level security;
alter table public.ingredients         enable row level security;
alter table public.stock_movements     enable row level security;
alter table public.staff_compensation  enable row level security;
alter table public.operating_expenses  enable row level security;
alter table public.finance_settings    enable row level security;

drop policy if exists sup_read on public.suppliers;
create policy sup_read on public.suppliers for select to authenticated
  using (private.can('inventory.view') and (branch_id = private.my_branch() or branch_id is null));
drop policy if exists sup_write_ins on public.suppliers;
create policy sup_write_ins on public.suppliers for insert to authenticated
  with check (private.can('inventory.manage'));
drop policy if exists sup_write_upd on public.suppliers;
create policy sup_write_upd on public.suppliers for update to authenticated
  using (private.can('inventory.manage')) with check (private.can('inventory.manage'));
drop policy if exists sup_write_del on public.suppliers;
create policy sup_write_del on public.suppliers for delete to authenticated
  using (private.can('inventory.manage'));

drop policy if exists ing_read on public.ingredients;
create policy ing_read on public.ingredients for select to authenticated
  using (private.can('inventory.view') and branch_id = private.my_branch());
drop policy if exists ing_write_ins on public.ingredients;
create policy ing_write_ins on public.ingredients for insert to authenticated
  with check (private.can('inventory.manage') and branch_id = private.my_branch());
drop policy if exists ing_write_upd on public.ingredients;
create policy ing_write_upd on public.ingredients for update to authenticated
  using (private.can('inventory.manage') and branch_id = private.my_branch())
  with check (branch_id = private.my_branch());
drop policy if exists ing_write_del on public.ingredients;
create policy ing_write_del on public.ingredients for delete to authenticated
  using (private.can('inventory.manage') and branch_id = private.my_branch());

-- Movements are an append-only ledger: booking one in needs
-- inventory.receive, correcting stock needs inventory.adjust, and
-- deleting history needs the stronger inventory.manage.
drop policy if exists sm_read on public.stock_movements;
create policy sm_read on public.stock_movements for select to authenticated
  using (private.can('inventory.view') and branch_id = private.my_branch());
drop policy if exists sm_write_ins on public.stock_movements;
create policy sm_write_ins on public.stock_movements for insert to authenticated
  with check (
    branch_id = private.my_branch()
    and case
          when movement_type in ('delivery_in','usage') then private.can('inventory.receive')
          else private.can('inventory.adjust')
        end
  );
drop policy if exists sm_write_del on public.stock_movements;
create policy sm_write_del on public.stock_movements for delete to authenticated
  using (private.can('inventory.manage') and branch_id = private.my_branch());

-- Pay is the most sensitive table here: you may always read your own row.
drop policy if exists comp_read on public.staff_compensation;
create policy comp_read on public.staff_compensation for select to authenticated
  using (staff_id = auth.uid() or private.can('payroll.view'));
drop policy if exists comp_write_ins on public.staff_compensation;
create policy comp_write_ins on public.staff_compensation for insert to authenticated
  with check (private.can('payroll.edit'));
drop policy if exists comp_write_upd on public.staff_compensation;
create policy comp_write_upd on public.staff_compensation for update to authenticated
  using (private.can('payroll.edit')) with check (private.can('payroll.edit'));
drop policy if exists comp_write_del on public.staff_compensation;
create policy comp_write_del on public.staff_compensation for delete to authenticated
  using (private.can('payroll.edit'));

drop policy if exists exp_read on public.operating_expenses;
create policy exp_read on public.operating_expenses for select to authenticated
  using (private.can('finance.view') and branch_id = private.my_branch());
drop policy if exists exp_write_ins on public.operating_expenses;
create policy exp_write_ins on public.operating_expenses for insert to authenticated
  with check (private.can('expenses.record') and branch_id = private.my_branch());
drop policy if exists exp_write_upd on public.operating_expenses;
create policy exp_write_upd on public.operating_expenses for update to authenticated
  using (private.can('expenses.record') and branch_id = private.my_branch())
  with check (branch_id = private.my_branch());
drop policy if exists exp_write_del on public.operating_expenses;
create policy exp_write_del on public.operating_expenses for delete to authenticated
  using (private.can('finance.edit') and branch_id = private.my_branch());

drop policy if exists fs_read on public.finance_settings;
create policy fs_read on public.finance_settings for select to authenticated
  using (private.can('finance.view'));
drop policy if exists fs_write_upd on public.finance_settings;
create policy fs_write_upd on public.finance_settings for update to authenticated
  using (private.can('finance.edit')) with check (private.can('finance.edit'));
drop policy if exists fs_write_ins on public.finance_settings;
create policy fs_write_ins on public.finance_settings for insert to authenticated
  with check (private.can('finance.edit'));


-- ═════════════════════════════════════════════════════════════
-- Grants — none of this is ever public
-- ═════════════════════════════════════════════════════════════
grant select, insert, update, delete on public.suppliers          to authenticated;
grant select, insert, update, delete on public.ingredients        to authenticated;
grant select, insert, delete         on public.stock_movements     to authenticated;
grant select, insert, update, delete on public.staff_compensation  to authenticated;
grant select, insert, update, delete on public.operating_expenses  to authenticated;
grant select, insert, update         on public.finance_settings    to authenticated;

revoke all on public.suppliers          from anon;
revoke all on public.ingredients        from anon;
revoke all on public.stock_movements    from anon;
revoke all on public.staff_compensation from anon;
revoke all on public.operating_expenses from anon;
revoke all on public.finance_settings   from anon;

grant execute on function public.finance_summary(date, date, text, uuid) to authenticated;
grant execute on function public.expense_breakdown(date, date, uuid)     to authenticated;
revoke all on function public.finance_summary(date, date, text, uuid) from anon;
revoke all on function public.expense_breakdown(date, date, uuid)     from anon;
