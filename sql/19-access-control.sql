-- ═══════════════════════════════════════════════════════════════
-- TPN OS — Migration 19: granular access control
--
-- WHAT THIS ADDS
-- A permission layer on top of the existing staff_role enum, so you
-- can build your own roles ("Floor Lead", "Weekend Cashier") and tick
-- exactly which parts of the system each one reaches -- instead of
-- being limited to the nine fixed tiers.
--
-- HOW IT RELATES TO THE ENUM (read this before changing anything)
-- The staff_role enum is NOT replaced and its ORDER still is the
-- permission model for everything that moves money. Every existing
-- SECURITY DEFINER function -- void_order_item, approve_void_request,
-- apply_discount, remove_discount, trg_guard_order_update -- keeps its
-- own has_role() gate. This layer sits ON TOP as a second lock:
--
--   enum tier   = the floor. What the database will physically permit.
--   permission  = the ceiling. What this person's role is allowed to
--                 reach in the portal, and what the new tables in
--                 migrations 20-22 enforce.
--
-- So a permission can TAKE AWAY access a tier would have allowed. It
-- can never GRANT access the tier forbids. That is deliberate: it
-- means a mistake in the roles UI can lock someone out, but can never
-- let a dishwasher approve a void. `permissions.min_tier` records that
-- floor per permission, and a trigger refuses to attach a permission
-- to a role whose base tier sits below it -- so you cannot build a
-- role that looks powerful in the UI and then fails at the database.
--
-- LOCKOUT PROTECTION
-- private.can() short-circuits to TRUE for ceo, always, before any
-- table is consulted. There is no combination of settings in the roles
-- editor that can lock the CEO out of the roles editor.
--
-- Safe to re-run.
-- ═══════════════════════════════════════════════════════════════


-- ═════════════════════════════════════════════════════════════
-- 1. THE PERMISSION CATALOGUE
--    Seeded here, not user-editable. A permission exists because
--    some code checks for it; inventing rows does nothing.
-- ═════════════════════════════════════════════════════════════
create table if not exists public.permissions (
  key            text primary key,
  category       text not null,
  label          text not null,
  label_tl       text,
  description    text,
  min_tier       public.staff_role not null,
  display_order  int not null default 100,
  created_at     timestamptz default now()
);

comment on table public.permissions is
  'Catalogue of every gate in the system. min_tier is the hard floor the
   database itself enforces elsewhere -- a role below that tier cannot be
   granted this permission (see trg_role_perm_floor).';

create index if not exists idx_permissions_category
  on public.permissions(category, display_order);


-- ═════════════════════════════════════════════════════════════
-- 2. ROLES
--    Nine system roles mirror the enum and cannot be deleted.
--    Everything else is yours to create and remove.
-- ═════════════════════════════════════════════════════════════
create table if not exists public.access_roles (
  id             uuid primary key default gen_random_uuid(),
  key            text not null unique,
  label          text not null,
  label_tl       text,
  description    text,
  base_tier      public.staff_role not null,
  color          text not null default '#8B1A0E',
  icon           text,
  is_system      boolean not null default false,
  is_active      boolean not null default true,
  display_order  int not null default 100,
  created_at     timestamptz default now(),
  created_by     uuid references public.staff(id) on delete set null,
  updated_at     timestamptz default now(),
  updated_by     uuid references public.staff(id) on delete set null
);

comment on column public.access_roles.base_tier is
  'The staff_role this custom role inherits its database-level floor from.
   Determines which permissions may be attached to it.';
comment on column public.access_roles.is_system is
  'True for the nine roles that mirror the staff_role enum. These cannot be
   deleted, renamed at the key level, or re-tiered.';

create index if not exists idx_access_roles_active
  on public.access_roles(is_active, display_order);

drop trigger if exists trg_access_roles_touch on public.access_roles;
create trigger trg_access_roles_touch before update on public.access_roles
  for each row execute function public.tg_touch_updated();


-- ═════════════════════════════════════════════════════════════
-- 3. ROLE -> PERMISSION GRID
--    This is what the Access Matrix tab renders.
-- ═════════════════════════════════════════════════════════════
create table if not exists public.access_role_permissions (
  role_id         uuid not null references public.access_roles(id) on delete cascade,
  permission_key  text not null references public.permissions(key) on delete cascade,
  allowed         boolean not null default true,
  updated_at      timestamptz default now(),
  updated_by      uuid references public.staff(id) on delete set null,
  primary key (role_id, permission_key)
);

create index if not exists idx_arp_role on public.access_role_permissions(role_id);


-- ═════════════════════════════════════════════════════════════
-- 4. PER-PERSON EXCEPTIONS
--    "Everyone on Kitchen, plus let Jannelle see Finance."
--    Beats cloning a whole role for one person.
-- ═════════════════════════════════════════════════════════════
create table if not exists public.staff_permission_overrides (
  staff_id        uuid not null references public.staff(id) on delete cascade,
  permission_key  text not null references public.permissions(key) on delete cascade,
  allowed         boolean not null,
  reason          text,
  granted_by      uuid references public.staff(id) on delete set null,
  granted_at      timestamptz default now(),
  primary key (staff_id, permission_key)
);

comment on table public.staff_permission_overrides is
  'Highest-priority answer in private.can(). Use sparingly -- an override is
   invisible in the role matrix, so it is the thing that makes access hard to
   reason about later. The Roles tab flags anyone who has one.';


-- ═════════════════════════════════════════════════════════════
-- 5. ATTACH A ROLE TO A PERSON
--    Nullable: a staff row with no access_role_id falls back to the
--    system role matching its enum tier, which is exactly today's
--    behaviour. Nothing changes until you assign a custom role.
-- ═════════════════════════════════════════════════════════════
alter table public.staff
  add column if not exists access_role_id uuid references public.access_roles(id) on delete set null;

create index if not exists idx_staff_access_role on public.staff(access_role_id);


-- ═════════════════════════════════════════════════════════════
-- 6. GUARD: a permission cannot exceed its role's tier floor
-- ═════════════════════════════════════════════════════════════
create or replace function public.trg_role_perm_floor()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_tier  public.staff_role;
  v_floor public.staff_role;
  v_sys   boolean;
begin
  if new.allowed is not true then
    return new;                       -- revoking is always allowed
  end if;

  select base_tier, is_system into v_tier, v_sys
    from public.access_roles where id = new.role_id;
  select min_tier into v_floor
    from public.permissions where key = new.permission_key;

  if v_tier is null or v_floor is null then
    return new;
  end if;

  if array_position(enum_range(null::public.staff_role), v_tier)
     < array_position(enum_range(null::public.staff_role), v_floor) then
    raise exception
      'permission_above_role_tier: "%" needs at least the % tier, but this role is based on %',
      new.permission_key, v_floor, v_tier
      using errcode = '42501';
  end if;

  return new;
end $$;

drop trigger if exists trg_arp_floor on public.access_role_permissions;
create trigger trg_arp_floor before insert or update on public.access_role_permissions
  for each row execute function public.trg_role_perm_floor();


-- ═════════════════════════════════════════════════════════════
-- 7. GUARD: system roles are structural, not editable
--    Labels, colours and their permission grid stay editable --
--    the key, the tier and their existence do not.
-- ═════════════════════════════════════════════════════════════
create or replace function public.trg_protect_system_roles()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.is_system then
      raise exception 'cannot_delete_system_role: % mirrors the staff_role enum', old.key
        using errcode = '42501';
    end if;
    return old;
  end if;

  if old.is_system then
    if new.key is distinct from old.key then
      raise exception 'cannot_rekey_system_role' using errcode = '42501';
    end if;
    if new.base_tier is distinct from old.base_tier then
      raise exception 'cannot_retier_system_role' using errcode = '42501';
    end if;
    if new.is_system is distinct from old.is_system then
      raise exception 'cannot_unflag_system_role' using errcode = '42501';
    end if;
    if new.is_active is distinct from old.is_active and new.is_active = false then
      raise exception 'cannot_deactivate_system_role' using errcode = '42501';
    end if;
  end if;

  return new;
end $$;

drop trigger if exists trg_access_roles_protect on public.access_roles;
create trigger trg_access_roles_protect before update or delete on public.access_roles
  for each row execute function public.trg_protect_system_roles();


-- ═════════════════════════════════════════════════════════════
-- 8. THE RESOLVER
-- ═════════════════════════════════════════════════════════════
create or replace function private.can(p_key text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_role_id uuid;
  v_tier    public.staff_role;
  v_allowed boolean;
begin
  select role, access_role_id into v_tier, v_role_id
    from public.staff where id = auth.uid();

  -- not a staff account at all
  if v_tier is null then
    return false;
  end if;

  -- lockout protection: the top of the enum always keeps every key,
  -- including the ones that repair a broken roles configuration.
  if v_tier = 'ceo' then
    return true;
  end if;

  -- 1. a personal override wins outright
  select allowed into v_allowed
    from public.staff_permission_overrides
   where staff_id = auth.uid() and permission_key = p_key;
  if v_allowed is not null then
    return v_allowed;
  end if;

  -- 2. an explicitly assigned custom role
  if v_role_id is not null then
    select arp.allowed into v_allowed
      from public.access_role_permissions arp
      join public.access_roles r on r.id = arp.role_id
     where arp.role_id = v_role_id
       and arp.permission_key = p_key
       and r.is_active;
    return coalesce(v_allowed, false);
  end if;

  -- 3. no custom role: fall back to the system role for their enum tier.
  --    This is what makes the migration a no-op on day one.
  select arp.allowed into v_allowed
    from public.access_role_permissions arp
    join public.access_roles r on r.id = arp.role_id
   where r.key = v_tier::text
     and r.is_system
     and arp.permission_key = p_key;

  return coalesce(v_allowed, false);
end $$;

comment on function private.can(text) is
  'Single source of truth for "may this person do X". Consulted by RLS on the
   tables added in migrations 20-22 and mirrored to the browser by
   public.my_permissions() so the portal can hide what it must not offer.';


-- ═════════════════════════════════════════════════════════════
-- 9. WHAT THE BROWSER ASKS FOR
-- ═════════════════════════════════════════════════════════════

-- Every permission key the caller currently holds. One round trip on login.
create or replace function public.my_permissions()
returns setof text
language sql
stable
security definer
set search_path = ''
as $$
  select p.key
    from public.permissions p
   where private.can(p.key)
$$;

-- The full grid for the Access Matrix tab: one row per role x permission.
-- Roles the caller may not see are filtered by the RLS on access_roles.
create or replace function public.access_matrix()
returns table (
  role_id        uuid,
  role_key       text,
  role_label     text,
  role_color     text,
  base_tier      public.staff_role,
  is_system      boolean,
  is_active      boolean,
  role_order     int,
  permission_key text,
  category       text,
  label          text,
  label_tl       text,
  description    text,
  min_tier       public.staff_role,
  perm_order     int,
  allowed        boolean,
  grantable      boolean
)
language sql
stable
security definer
set search_path = ''
as $$
  select r.id, r.key, r.label, r.color, r.base_tier, r.is_system, r.is_active,
         r.display_order,
         p.key, p.category, p.label, p.label_tl, p.description, p.min_tier,
         p.display_order,
         coalesce(arp.allowed, false) as allowed,
         array_position(enum_range(null::public.staff_role), r.base_tier)
           >= array_position(enum_range(null::public.staff_role), p.min_tier)
           as grantable
    from public.access_roles r
   cross join public.permissions p
    left join public.access_role_permissions arp
           on arp.role_id = r.id and arp.permission_key = p.key
   where private.can('roles.view')
   order by r.display_order, r.label, p.category, p.display_order
$$;

comment on function public.access_matrix() is
  'Powers the Access Matrix tab. `grantable` is false where the permission sits
   above the role''s tier floor -- the UI renders those cells as locked rather
   than as an unticked box you can tick, because ticking them would be refused
   by trg_role_perm_floor.';


-- ═════════════════════════════════════════════════════════════
-- 10. SEED — the permission catalogue
-- ═════════════════════════════════════════════════════════════
insert into public.permissions (key, category, label, label_tl, description, min_tier, display_order) values
  -- Workspace
  ('dashboard.view',        'Workspace', 'See the dashboard',          'Tingnan ang dashboard',            'Open the portal home with its summary tiles.',                  'dining',         10),
  ('orders.view',           'Workspace', 'See live orders',            'Tingnan ang mga order',            'Open the Live Orders board.',                                   'dining',         20),
  ('orders.manage',         'Workspace', 'Move orders along',          'Iusad ang mga order',              'Advance an order through preparing, ready and served.',          'dining',         30),
  ('orders.cancel',         'Workspace', 'Cancel an order',            'I-kansela ang order',              'Also hard-gated at manager in trg_guard_order_update.',          'manager',        40),
  ('kds.view',              'Workspace', 'See the kitchen queue',      'Tingnan ang kitchen queue',        'Open the in-portal kitchen ticket queue.',                       'kitchen_display', 50),
  ('kds.advance',           'Workspace', 'Move kitchen tickets',       'Iusad ang tiket sa kusina',        'Start cooking and mark ready from the kitchen queue.',           'kitchen_display', 60),
  ('floor.view',            'Workspace', 'Open the dine-in floor',     'Buksan ang dine-in floor',         'Open the full-screen floor panel.',                              'kitchen_display', 70),
  ('kitchen_station.view',  'Workspace', 'Open the kitchen screen',    'Buksan ang kitchen screen',        'Open the full-screen wall display for the kitchen.',             'kitchen_display', 80),
  ('voids.request',         'Workspace', 'Ask for a void',             'Mag-request ng void',              'File a void request for a manager to approve.',                  'kitchen_display', 90),
  ('voids.approve',         'Workspace', 'Approve a void',             'Aprubahan ang void',               'Also hard-gated at manager in approve_void_request.',            'manager',       100),
  ('inquiries.view',        'Workspace', 'See enquiries',              'Tingnan ang mga tanong',           'Read catering, events and concession enquiries.',                'supervisor',    110),
  ('inquiries.manage',      'Workspace', 'Handle enquiries',           'Sagutin ang mga tanong',           'Change an enquiry status and record follow-up.',                 'supervisor',    120),

  -- Team
  ('staff.view',            'Team', 'See the team',                    'Tingnan ang team',                 'Open the Staff Board and see who works where.',                  'dining',         10),
  ('staff.assign',          'Team', 'Move people between roles',       'Ilipat ang tao ng role',           'Drag a person into another role on the Staff Board.',            'admin',          20),
  ('schedules.view',        'Team', 'See schedules',                   'Tingnan ang schedule',             'Read the weekly shift roster.',                                  'dining',         30),
  ('schedules.edit',        'Team', 'Write schedules',                 'Baguhin ang schedule',             'Edit shifts and copy a week forward.',                            'manager',        40),
  ('attendance.view',       'Team', 'See attendance',                  'Tingnan ang attendance',           'Read clock-in and clock-out records.',                            'dining',         50),
  ('attendance.edit',       'Team', 'Correct attendance',              'Itama ang attendance',             'Amend a clock-in or clock-out after the fact.',                   'manager',        60),
  ('messages.view',         'Team', 'Read messages',                   'Magbasa ng mensahe',               'Open the staff inbox.',                                           'dining',         70),
  ('messages.broadcast',    'Team', 'Send to everyone',                'Magpadala sa lahat',               'Send a branch-wide announcement.',                                'manager',        80),
  ('notifications.view',    'Team', 'See notifications',               'Tingnan ang notification',         'Open the notification feed.',                                     'dining',         90),
  ('tasks.view',            'Team', 'See the task board',              'Tingnan ang task board',           'Read tasks for the branch.',                                      'dining',        100),
  ('tasks.create',          'Team', 'Create tasks',                    'Gumawa ng task',                   'Add a new task to the board.',                                    'supervisor',    110),
  ('tasks.assign',          'Team', 'Assign tasks',                    'Mag-assign ng task',               'Put people on a task, including several at once.',                'supervisor',    120),
  ('tasks.close_any',       'Team', 'Close anyone''s task',            'Isara ang task ng iba',            'Mark a task done even when not assigned to it.',                  'manager',       130),

  -- Menu & pricing
  ('menu.view',             'Menu & Pricing', 'See the menu manager',  'Tingnan ang menu manager',         'Open Menu Manager read-only.',                                    'dining',         10),
  ('menu.edit',             'Menu & Pricing', 'Edit the menu',         'Baguhin ang menu',                 'Add, edit, 86 or delete menu items and categories.',               'manager',        20),
  ('discounts.view',        'Menu & Pricing', 'See discounts',         'Tingnan ang discount',             'Read discount templates and promos.',                             'supervisor',     30),
  ('discounts.manage',      'Menu & Pricing', 'Build discounts',       'Gumawa ng discount',               'Create and retire discount templates.',                           'manager',        40),
  ('discounts.apply',       'Menu & Pricing', 'Apply a discount',      'Mag-apply ng discount',            'Also hard-gated at supervisor in apply_discount.',                 'supervisor',     50),
  ('tables.manage',         'Menu & Pricing', 'Manage tables and QRs', 'Pamahalaan ang mesa at QR',        'Add tables and reprint table QR codes.',                          'manager',        60),

  -- Money
  ('finance.view',          'Money', 'See the money view',             'Tingnan ang pera',                 'Open Finance: sales, costs and what was actually made.',          'manager',        10),
  ('finance.edit',          'Money', 'Set costing rules',              'Itakda ang costing',               'Change how cost of goods and labour are calculated.',              'admin',          20),
  ('expenses.record',       'Money', 'Record an expense',              'Magtala ng gastos',                'Log rent, gas, utilities and other operating costs.',              'manager',        30),
  ('payroll.view',          'Money', 'See pay rates',                  'Tingnan ang sahod',                'See what each person is paid. Sensitive.',                         'admin',          40),
  ('payroll.edit',          'Money', 'Set pay rates',                  'Itakda ang sahod',                 'Change a person''s pay rate. Sensitive.',                          'ceo',            50),

  -- Inventory
  ('inventory.view',        'Inventory', 'See stock',                  'Tingnan ang stock',                'Read ingredient levels and delivery history.',                    'kitchen',        10),
  ('inventory.receive',     'Inventory', 'Receive a delivery',         'Tanggapin ang delivery',           'Book in ingredients that arrived.',                                'kitchen',        20),
  ('inventory.adjust',      'Inventory', 'Adjust or write off stock',  'I-adjust ang stock',               'Record wastage, spoilage and stock-count corrections.',            'manager',        30),
  ('inventory.manage',      'Inventory', 'Manage ingredients',         'Pamahalaan ang sangkap',           'Add ingredients, units, reorder levels and suppliers.',            'manager',        40),

  -- Administration
  ('accounts.view',         'Administration', 'See accounts',          'Tingnan ang accounts',             'Read the staff account list.',                                    'manager',        10),
  ('accounts.create',       'Administration', 'Create accounts',       'Gumawa ng account',                'Also hard-gated in the create-staff edge function.',               'manager',        20),
  ('accounts.deactivate',   'Administration', 'Deactivate accounts',   'I-deactivate ang account',         'Switch off someone''s access.',                                    'admin',          30),
  ('roles.view',            'Administration', 'See roles and access',  'Tingnan ang roles',                'Open Roles and the Access Matrix.',                               'manager',        40),
  ('roles.edit',            'Administration', 'Change roles and access','Baguhin ang roles',               'Create roles and decide what each one reaches.',                   'admin',          50),
  ('audit.view',            'Administration', 'Read the audit log',    'Tingnan ang audit log',            'Read the record of who did what.',                                'admin',          60),
  ('performance.view',      'Administration', 'See performance',       'Tingnan ang performance',          'Open the performance and prep-time analytics.',                    'manager',        70),
  ('history.view',          'Administration', 'See history',           'Tingnan ang history',              'Browse past days and closed orders.',                             'manager',        80),
  ('settings.manage',       'Administration', 'Change settings',       'Baguhin ang settings',             'Branch-level settings and integrations.',                          'admin',          90)
on conflict (key) do update set
  category      = excluded.category,
  label         = excluded.label,
  label_tl      = excluded.label_tl,
  description   = excluded.description,
  min_tier      = excluded.min_tier,
  display_order = excluded.display_order;


-- ═════════════════════════════════════════════════════════════
-- 11. SEED — the nine system roles, mirroring the enum
-- ═════════════════════════════════════════════════════════════
insert into public.access_roles (key, label, label_tl, description, base_tier, color, icon, is_system, display_order) values
  ('kitchen_display', 'Kitchen Screen',  'Kitchen Screen',  'Shared login for the wall-mounted kitchen display. Not a person.', 'kitchen_display', '#6B7280', 'screen',   true, 10),
  ('dine_in_display', 'Floor Screen',    'Floor Screen',    'Shared login for the wall-mounted floor display. Not a person.',   'dine_in_display', '#6B7280', 'screen',   true, 20),
  ('dining',          'Dining Crew',     'Dining Crew',     'Front of house. Takes and serves orders.',                         'dining',          '#2D7A4F', 'server',   true, 30),
  ('kitchen',         'Kitchen Crew',    'Kusinero',        'Back of house. Cooks and books in deliveries.',                    'kitchen',         '#B45309', 'chef',     true, 40),
  ('supervisor',      'Supervisor',      'Superbisor',      'Runs a shift. Can discount and raise tasks.',                      'supervisor',      '#0E7490', 'clipboard',true, 50),
  ('manager',         'Manager',         'Manedyer',        'Runs the branch. Approves voids, edits the menu, sees the money.',  'manager',         '#8B1A0E', 'shield',   true, 60),
  ('admin',           'Admin',           'Admin',           'System administrator. Creates accounts and sets access.',           'admin',           '#5B21B6', 'key',      true, 70),
  ('director',        'Director',        'Direktor',        'Oversight across the business.',                                    'director',        '#1E3A8A', 'compass',  true, 80),
  ('ceo',             'CEO',             'CEO',             'Full access, always. Cannot be locked out by design.',              'ceo',             '#111827', 'crown',    true, 90)
on conflict (key) do update set
  label       = excluded.label,
  label_tl    = excluded.label_tl,
  description = excluded.description,
  color       = excluded.color,
  icon        = excluded.icon;


-- ═════════════════════════════════════════════════════════════
-- 12. SEED — the default grid
--
--    allowed = "is this role's tier at or above the permission's
--    floor". That reproduces exactly what each enum tier can do
--    today, so switching this migration on changes nobody's access.
--    Only rows that do not already exist are written, so a hand-tuned
--    grid survives a re-run.
-- ═════════════════════════════════════════════════════════════
insert into public.access_role_permissions (role_id, permission_key, allowed)
select r.id, p.key,
       array_position(enum_range(null::public.staff_role), r.base_tier)
         >= array_position(enum_range(null::public.staff_role), p.min_tier)
  from public.access_roles r
 cross join public.permissions p
 where r.is_system
on conflict (role_id, permission_key) do nothing;

-- The two screen accounts are deliberately narrower than their tier
-- position implies: they may watch and advance tickets and ask for a
-- void, and nothing else. Mirrors sql/15b section 7.
update public.access_role_permissions arp
   set allowed = false
  from public.access_roles r
 where arp.role_id = r.id
   and r.key in ('kitchen_display', 'dine_in_display')
   and arp.permission_key not in
       ('kds.view', 'kds.advance', 'floor.view', 'kitchen_station.view',
        'voids.request', 'orders.view');


-- ═════════════════════════════════════════════════════════════
-- 13. RLS
-- ═════════════════════════════════════════════════════════════
alter table public.permissions               enable row level security;
alter table public.access_roles              enable row level security;
alter table public.access_role_permissions   enable row level security;
alter table public.staff_permission_overrides enable row level security;

-- The catalogue is reference data. Any signed-in staff member may read
-- it so the portal can label things; nobody may write it from the app.
drop policy if exists perms_read on public.permissions;
create policy perms_read on public.permissions
  for select to authenticated using (true);

-- Roles: readable by anyone who can open the Roles tab. Writable only
-- with roles.edit, which itself floors at admin.
drop policy if exists roles_read on public.access_roles;
create policy roles_read on public.access_roles
  for select to authenticated using (private.can('roles.view'));

drop policy if exists roles_write_ins on public.access_roles;
create policy roles_write_ins on public.access_roles
  for insert to authenticated with check (private.can('roles.edit'));

drop policy if exists roles_write_upd on public.access_roles;
create policy roles_write_upd on public.access_roles
  for update to authenticated
  using (private.can('roles.edit')) with check (private.can('roles.edit'));

drop policy if exists roles_write_del on public.access_roles;
create policy roles_write_del on public.access_roles
  for delete to authenticated using (private.can('roles.edit'));

drop policy if exists arp_read on public.access_role_permissions;
create policy arp_read on public.access_role_permissions
  for select to authenticated using (private.can('roles.view'));

drop policy if exists arp_write_ins on public.access_role_permissions;
create policy arp_write_ins on public.access_role_permissions
  for insert to authenticated with check (private.can('roles.edit'));

drop policy if exists arp_write_upd on public.access_role_permissions;
create policy arp_write_upd on public.access_role_permissions
  for update to authenticated
  using (private.can('roles.edit')) with check (private.can('roles.edit'));

drop policy if exists arp_write_del on public.access_role_permissions;
create policy arp_write_del on public.access_role_permissions
  for delete to authenticated using (private.can('roles.edit'));

-- Overrides: you may always see your own. Changing one needs roles.edit.
drop policy if exists spo_read on public.staff_permission_overrides;
create policy spo_read on public.staff_permission_overrides
  for select to authenticated
  using (staff_id = auth.uid() or private.can('roles.view'));

drop policy if exists spo_write_ins on public.staff_permission_overrides;
create policy spo_write_ins on public.staff_permission_overrides
  for insert to authenticated with check (private.can('roles.edit'));

drop policy if exists spo_write_upd on public.staff_permission_overrides;
create policy spo_write_upd on public.staff_permission_overrides
  for update to authenticated
  using (private.can('roles.edit')) with check (private.can('roles.edit'));

drop policy if exists spo_write_del on public.staff_permission_overrides;
create policy spo_write_del on public.staff_permission_overrides
  for delete to authenticated using (private.can('roles.edit'));


-- ═════════════════════════════════════════════════════════════
-- 14. GRANTS
--    Read-only for the browser; every write path is RLS-gated above.
-- ═════════════════════════════════════════════════════════════
grant select on public.permissions                to authenticated;
grant select, insert, update, delete on public.access_roles              to authenticated;
grant select, insert, update, delete on public.access_role_permissions   to authenticated;
grant select, insert, update, delete on public.staff_permission_overrides to authenticated;

revoke all on public.permissions               from anon;
revoke all on public.access_roles              from anon;
revoke all on public.access_role_permissions   from anon;
revoke all on public.staff_permission_overrides from anon;

grant execute on function public.my_permissions()  to authenticated;
grant execute on function public.access_matrix()   to authenticated;
revoke all on function public.my_permissions()     from anon;
revoke all on function public.access_matrix()      from anon;


-- ═════════════════════════════════════════════════════════════
-- 15. AUDIT — every access change is recorded server-side
--
--    NOTE: one shared trigger function across all three tables does
--    NOT work. plpgsql resolves OLD/NEW field references against a
--    concrete row type, so a single function containing both `old.id`
--    and `old.role_id` fails at runtime with
--      record "old" has no field "role_id"
--    the moment it fires on the wrong table. Found the hard way.
--    Three explicit functions, one per table.
-- ═════════════════════════════════════════════════════════════
create or replace function private.log_access_change(
  p_entity text, p_id uuid, p_op text, p_before jsonb, p_after jsonb)
returns void
language sql
security definer
set search_path = ''
as $$
  insert into public.audit_log
    (actor_id, actor_role, action, entity_type, entity_id, before_state, after_state)
  values
    (auth.uid(), private.my_role(), 'access.' || lower(p_op), p_entity, p_id, p_before, p_after);
$$;

create or replace function public.trg_audit_access_role()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log_access_change('access_role', new.id, tg_op, null, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    perform private.log_access_change('access_role', new.id, tg_op, to_jsonb(old), to_jsonb(new));
    return new;
  else
    perform private.log_access_change('access_role', old.id, tg_op, to_jsonb(old), null);
    return old;
  end if;
end $$;

create or replace function public.trg_audit_role_permission()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log_access_change('role_permission', new.role_id, tg_op, null, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    perform private.log_access_change('role_permission', new.role_id, tg_op, to_jsonb(old), to_jsonb(new));
    return new;
  else
    perform private.log_access_change('role_permission', old.role_id, tg_op, to_jsonb(old), null);
    return old;
  end if;
end $$;

create or replace function public.trg_audit_staff_override()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  if tg_op = 'INSERT' then
    perform private.log_access_change('staff_permission_override', new.staff_id, tg_op, null, to_jsonb(new));
    return new;
  elsif tg_op = 'UPDATE' then
    perform private.log_access_change('staff_permission_override', new.staff_id, tg_op, to_jsonb(old), to_jsonb(new));
    return new;
  else
    perform private.log_access_change('staff_permission_override', old.staff_id, tg_op, to_jsonb(old), null);
    return old;
  end if;
end $$;

drop trigger if exists trg_audit_roles on public.access_roles;
create trigger trg_audit_roles after insert or update or delete on public.access_roles
  for each row execute function public.trg_audit_access_role();

drop trigger if exists trg_audit_arp on public.access_role_permissions;
create trigger trg_audit_arp after insert or update or delete on public.access_role_permissions
  for each row execute function public.trg_audit_role_permission();

drop trigger if exists trg_audit_spo on public.staff_permission_overrides;
create trigger trg_audit_spo after insert or update or delete on public.staff_permission_overrides
  for each row execute function public.trg_audit_staff_override();


-- ═════════════════════════════════════════════════════════════
-- 16. SEED CORRECTION — do not widen anybody's access on day one
--
--    Section 12 grants every permission at or above a role's tier.
--    For Manager that would have QUIETLY WIDENED access: before this
--    migration the sidebar gated Performance, History and the audit
--    log at admin+, so a manager never saw them. Switching this
--    release on must not change what anyone can reach.
--
--    These three keep min_tier = 'manager' on purpose — the database
--    genuinely permits a manager to hold them, so an admin can now
--    tick them on for one person or for a custom role. They simply
--    start OFF, matching the behaviour before migration 19.
-- ═════════════════════════════════════════════════════════════
update public.access_role_permissions arp
   set allowed = false
  from public.access_roles r
 where arp.role_id = r.id
   and r.key = 'manager'
   and r.is_system
   and arp.permission_key in ('performance.view', 'history.view', 'roles.view');
