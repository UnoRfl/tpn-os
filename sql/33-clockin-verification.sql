-- ═══════════════════════════════════════════════════════════════
-- 33 · Verified clock-in: restaurant network + full-body uniform photo
--
-- Requires 29 (client_ip), 29b (add_permission, audit_row), 30
-- (site_settings).
--
-- Decided with the owner:
--  • Network. A browser cannot see which Wi-Fi router it is on, so the
--    server checks the connection's public IP against the restaurant's
--    trusted networks. "Adaptive": a manager taps "Trust this network"
--    while at the restaurant. A clock-in from anywhere else is NOT
--    refused — it is recorded as needs_approval and lands in the
--    manager's queue, so a PLDT/Globe IP change never blocks a shift; the
--    manager approves and can trust the new IP in one tap.
--    IPv4 is matched exactly; IPv6 on the /64 (phones rotate the rest).
--  • Photo. A live-camera, full-body photo at clock-in, stored in a
--    PRIVATE bucket, readable only by managers (attendance.verify),
--    deleted after 60 days (Data Privacy Act: purpose + retention are
--    shown to staff before their first photo). No photo (camera denied,
--    broken phone) → needs_approval, never a dead end.
--
-- Also closes a gap: staff could UPDATE their own open shift row, which
-- included clock_in_at — a back-dated clock-in. Now clock-in and
-- clock-out are server functions that set the time and IP themselves;
-- staff have no direct write on attendance. Manager corrections are
-- unchanged.
-- ═══════════════════════════════════════════════════════════════

select private.add_permission('attendance.verify', 'People', 'Review clock-in photos', 'Suriin ang clock-in',
  'See clock-in photos and network checks; approve or flag; trust the restaurant network.', 'manager', 215);

-- ── Trusted networks ─────────────────────────────────────────
create table if not exists public.trusted_networks (
  id           uuid primary key default gen_random_uuid(),
  branch_id    uuid not null references public.branches(id) on delete cascade,
  label        text not null default 'Restaurant Wi-Fi' check (length(label) between 1 and 60),
  network      cidr not null,
  is_active    boolean not null default true,
  added_by     uuid references public.staff(id),
  created_at   timestamptz not null default now(),
  last_seen_at timestamptz,
  unique (branch_id, network)
);
alter table public.trusted_networks enable row level security;
revoke all on public.trusted_networks from anon, authenticated;
grant select, update, delete on public.trusted_networks to authenticated;
drop policy if exists trusted_networks_manage on public.trusted_networks;
create policy trusted_networks_manage on public.trusted_networks for all to authenticated
  using (private.can('attendance.verify') and (branch_id = private.my_branch() or private.has_role('admin')))
  with check (private.can('attendance.verify') and (branch_id = private.my_branch() or private.has_role('admin')));
drop trigger if exists trg_audit_trusted_networks on public.trusted_networks;
create trigger trg_audit_trusted_networks after insert or update or delete on public.trusted_networks
  for each row execute function private.audit_row();

-- The network an address belongs to, as we store it.
create or replace function private.network_of(p_ip inet)
returns cidr language sql immutable set search_path = '' as $$
  select case when p_ip is null then null
              when family(p_ip) = 4 then set_masklen(p_ip::cidr, 32)
              else network(set_masklen(p_ip, 64))::cidr end
$$;
revoke all on function private.network_of(inet) from public, anon, authenticated;

-- ── Attendance: verification columns ─────────────────────────
alter table public.attendance
  add column if not exists clock_in_ip     inet,
  add column if not exists clock_out_ip    inet,
  add column if not exists network_trusted boolean,
  add column if not exists verify_status   text
      check (verify_status is null or verify_status in ('verified', 'needs_approval', 'approved', 'flagged')),
  add column if not exists verify_reasons  text[] not null default '{}',
  add column if not exists photo_path      text,
  add column if not exists photo_purged_at timestamptz,
  add column if not exists uniform_check   jsonb,
  add column if not exists reviewed_by     uuid references public.staff(id),
  add column if not exists reviewed_at     timestamptz,
  add column if not exists review_note     text check (length(review_note) <= 500);
create index if not exists idx_attendance_review on public.attendance (verify_status) where verify_status = 'needs_approval';

-- Staff lose direct writes; managers keep the correction path.
drop policy if exists attendance_self_insert on public.attendance;
drop policy if exists attendance_self_write on public.attendance;   -- live-only duplicate of self_insert
drop policy if exists attendance_self_update on public.attendance;
drop policy if exists attendance_manager_update on public.attendance;
create policy attendance_manager_update on public.attendance for update to authenticated
  using (private.has_role('manager') and exists (select 1 from public.staff s
           where s.id = attendance.staff_id and (s.branch_id = private.my_branch() or private.has_role('admin'))))
  with check (private.has_role('manager'));
revoke insert on public.attendance from authenticated;

-- Default uniform checklist (editable in Website → settings by managers).
insert into public.site_settings (key, value) values
  ('hr.uniform_checklist', '["Uniform shirt", "Apron", "Cap or hairnet", "Closed shoes", "Name tag"]'),
  ('hr.photo_retention_days', '60')
on conflict (key) do nothing;

-- ── Clock in ─────────────────────────────────────────────────
-- Returns the new row's id, status, reasons and — when a photo is coming —
-- the exact storage path the phone must upload to.
create or replace function public.clock_in_verified(p_expect_photo boolean default true, p_note text default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare
  me       public.staff%rowtype;
  v_ip     inet := private.client_ip();
  v_net    cidr := private.network_of(v_ip);
  v_trust  boolean;
  v_reason text[] := '{}';
  v_id     uuid;
  v_path   text;
begin
  select * into me from public.staff where id = auth.uid();
  if not found or coalesce(me.employment_status, 'active') <> 'active' then
    raise exception 'account_not_active' using errcode = '42501';
  end if;
  if exists (select 1 from public.attendance where staff_id = me.id and clock_out_at is null) then
    raise exception 'already_clocked_in';
  end if;

  select true into v_trust from public.trusted_networks t
   where t.branch_id = me.branch_id and t.is_active and v_net is not null and t.network >>= v_ip limit 1;
  v_trust := coalesce(v_trust, false);
  if v_trust then
    update public.trusted_networks set last_seen_at = now()
     where branch_id = me.branch_id and is_active and network >>= v_ip;
  else
    v_reason := array_append(v_reason, case when v_ip is null then 'network_unknown' else 'untrusted_network' end);
  end if;
  if not coalesce(p_expect_photo, false) then v_reason := array_append(v_reason, 'no_photo'); end if;

  insert into public.attendance (staff_id, clock_in_at, notes, clock_in_ip, network_trusted, verify_status, verify_reasons)
  values (me.id, now(), left(nullif(btrim(coalesce(p_note, '')), ''), 300), v_ip, v_trust,
          -- Never 'verified' at this point: that needs the photo too
          -- (attach_clockin_photo) on a trusted network.
          'needs_approval',
          case when coalesce(p_expect_photo, false) then array_append(v_reason, 'photo_pending') else v_reason end)
  returning id into v_id;

  if coalesce(p_expect_photo, false) then
    v_path := coalesce(me.branch_id::text, 'nobranch') || '/' || to_char(now() at time zone 'Asia/Manila', 'YYYY-MM-DD')
              || '/' || me.id::text || '/' || v_id::text || '.jpg';
  end if;

  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (me.id, me.role, 'attendance.clock_in', 'attendance', v_id,
          jsonb_build_object('ip', host(v_ip), 'trusted', v_trust, 'photo_expected', p_expect_photo));

  return jsonb_build_object('attendance_id', v_id, 'trusted_network', v_trust,
                            'reasons', v_reason, 'upload_path', v_path, 'clock_in_at', now());
end $$;

-- After the upload: the photo must really be in the bucket at the path we
-- issued, uploaded by this person, within 10 minutes of clocking in.
create or replace function public.attach_clockin_photo(p_attendance_id uuid)
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare a public.attendance%rowtype; v_path text; v_status text; v_reasons text[];
begin
  select * into a from public.attendance where id = p_attendance_id and staff_id = auth.uid() for update;
  if not found then raise exception 'attendance_not_found'; end if;
  if a.photo_path is not null then return jsonb_build_object('status', a.verify_status); end if;
  if now() - a.clock_in_at > interval '10 minutes' then raise exception 'photo_too_late'; end if;
  select o.name into v_path from storage.objects o
   where o.bucket_id = 'attendance-photos' and o.name like '%/' || a.id::text || '.jpg'
     and split_part(o.name, '/', 3) = auth.uid()::text
   limit 1;
  if v_path is null then raise exception 'photo_not_uploaded'; end if;
  v_reasons := array_remove(a.verify_reasons, 'photo_pending');
  -- Trusted network + photo = verified. A manager still sees the photo in
  -- the review list and can flag it, but nobody has to act.
  v_status := case when a.network_trusted and cardinality(v_reasons) = 0 then 'verified' else 'needs_approval' end;
  update public.attendance set photo_path = v_path, verify_reasons = v_reasons, verify_status = v_status
   where id = a.id;
  return jsonb_build_object('status', v_status, 'reasons', v_reasons);
end $$;

-- ── Clock out ────────────────────────────────────────────────
create or replace function public.clock_out_verified()
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare a public.attendance%rowtype;
begin
  select * into a from public.attendance where staff_id = auth.uid() and clock_out_at is null
   order by clock_in_at desc limit 1 for update;
  if not found then return null; end if;
  update public.attendance set clock_out_at = now(), clock_out_ip = private.client_ip() where id = a.id;
  insert into public.audit_log (actor_id, actor_role, action, entity_type, entity_id, metadata)
  values (auth.uid(), private.my_role(), 'attendance.clock_out', 'attendance', a.id,
          jsonb_build_object('ip', host(private.client_ip())));
  return jsonb_build_object('attendance_id', a.id, 'clock_out_at', now());
end $$;

-- ── Manager review ───────────────────────────────────────────
create or replace function public.clockin_review_queue(p_include_done boolean default false, p_days int default 7)
returns table (id uuid, staff_id uuid, staff_name text, role public.staff_role, clock_in_at timestamptz,
               clock_out_at timestamptz, ip text, network_trusted boolean, verify_status text,
               verify_reasons text[], photo_path text, photo_purged boolean, uniform_check jsonb,
               reviewed_by_name text, reviewed_at timestamptz, review_note text)
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not private.can('attendance.verify') then raise exception 'permission_denied: attendance.verify' using errcode = '42501'; end if;
  return query
  select a.id, a.staff_id, s.full_name, s.role, a.clock_in_at, a.clock_out_at, host(a.clock_in_ip),
         a.network_trusted, a.verify_status, a.verify_reasons, a.photo_path, a.photo_purged_at is not null,
         a.uniform_check, r.full_name, a.reviewed_at, a.review_note
    from public.attendance a
    join public.staff s on s.id = a.staff_id
    left join public.staff r on r.id = a.reviewed_by
   where (s.branch_id = private.my_branch() or private.has_role('admin'))
     and a.verify_status is not null
     and (p_include_done or a.verify_status = 'needs_approval')
     and a.clock_in_at > now() - make_interval(days => greatest(1, least(coalesce(p_days, 7), 90)))
   order by a.clock_in_at desc;
end $$;

create or replace function public.review_clockin(p_attendance_id uuid, p_approve boolean, p_uniform jsonb default null,
                                                 p_note text default null, p_trust_network boolean default false)
returns text
language plpgsql security definer set search_path = ''
as $$
declare a public.attendance%rowtype; s public.staff%rowtype; v text;
begin
  if not private.can('attendance.verify') then raise exception 'permission_denied: attendance.verify' using errcode = '42501'; end if;
  select * into a from public.attendance where id = p_attendance_id for update;
  if not found then raise exception 'attendance_not_found'; end if;
  select * into s from public.staff where id = a.staff_id;
  if s.branch_id is distinct from private.my_branch() and not private.has_role('admin') then
    raise exception 'wrong_branch' using errcode = '42501';
  end if;
  if a.staff_id = auth.uid() and not private.has_role('director') then
    raise exception 'cannot_review_own_clockin';
  end if;
  if not p_approve and coalesce(length(btrim(p_note)), 0) < 3 then raise exception 'note_required'; end if;
  v := case when p_approve then 'approved' else 'flagged' end;
  update public.attendance
     set verify_status = v, uniform_check = p_uniform, reviewed_by = auth.uid(), reviewed_at = now(),
         review_note = left(nullif(btrim(coalesce(p_note, '')), ''), 500)
   where id = a.id;
  if p_trust_network and a.clock_in_ip is not null then
    insert into public.trusted_networks (branch_id, label, network, added_by)
    values (s.branch_id, 'Approved from clock-in ' || to_char(a.clock_in_at at time zone 'Asia/Manila', 'Mon DD'),
            private.network_of(a.clock_in_ip), auth.uid())
    on conflict (branch_id, network) do update set is_active = true;
  end if;
  if not p_approve then
    insert into public.notifications (user_id, branch_id, kind, title, body, priority, entity_type, entity_id)
    values (a.staff_id, s.branch_id, 'attendance', 'Your clock-in was flagged',
            left(btrim(p_note), 300), 'high', 'attendance', a.id);
  end if;
  return v;
end $$;

-- Trust the network the manager is on right now (at the restaurant).
create or replace function public.trust_current_network(p_label text default 'Restaurant Wi-Fi')
returns jsonb
language plpgsql security definer set search_path = ''
as $$
declare v_ip inet := private.client_ip(); v_branch uuid := private.my_branch(); v_id uuid;
begin
  if not private.can('attendance.verify') then raise exception 'permission_denied: attendance.verify' using errcode = '42501'; end if;
  if v_ip is null then raise exception 'network_unknown'; end if;
  insert into public.trusted_networks (branch_id, label, network, added_by)
  values (v_branch, left(coalesce(nullif(btrim(p_label), ''), 'Restaurant Wi-Fi'), 60), private.network_of(v_ip), auth.uid())
  on conflict (branch_id, network) do update set is_active = true, label = excluded.label
  returning id into v_id;
  return jsonb_build_object('id', v_id, 'network', host(private.network_of(v_ip)), 'family', family(v_ip));
end $$;

-- What network am I on, and is it trusted? (Shown on the clock-in screen.)
create or replace function public.my_network_status()
returns jsonb
language sql stable security definer set search_path = ''
as $$
  select jsonb_build_object(
    'trusted', exists (select 1 from public.trusted_networks t
                        where t.branch_id = private.my_branch() and t.is_active and t.network >>= private.client_ip()),
    'any_trusted', exists (select 1 from public.trusted_networks t where t.branch_id = private.my_branch() and t.is_active))
$$;

-- Photos older than the retention window: list them for deletion (the
-- portal deletes the files through the Storage API, which is the only
-- supported way), then mark them purged.
create or replace function public.clockin_photos_expired(p_limit int default 200)
returns table (attendance_id uuid, photo_path text)
language plpgsql stable security definer set search_path = ''
as $$
declare v_days int := coalesce((select (value #>> '{}')::int from public.site_settings where key = 'hr.photo_retention_days'), 60);
begin
  if not private.can('attendance.verify') then raise exception 'permission_denied' using errcode = '42501'; end if;
  return query select a.id, a.photo_path from public.attendance a
    where a.photo_path is not null and a.photo_purged_at is null
      and a.clock_in_at < now() - make_interval(days => greatest(v_days, 7))
    order by a.clock_in_at limit greatest(1, least(p_limit, 1000));
end $$;
create or replace function public.mark_clockin_photos_purged(p_ids uuid[])
returns int
language plpgsql security definer set search_path = ''
as $$
declare n int;
begin
  if not private.can('attendance.verify') then raise exception 'permission_denied' using errcode = '42501'; end if;
  update public.attendance set photo_purged_at = now() where id = any(p_ids) and photo_path is not null and photo_purged_at is null;
  get diagnostics n = row_count;
  return n;
end $$;

do $$
declare f text;
begin
  foreach f in array array[
    'public.clock_in_verified(boolean, text)', 'public.attach_clockin_photo(uuid)', 'public.clock_out_verified()',
    'public.clockin_review_queue(boolean, int)', 'public.review_clockin(uuid, boolean, jsonb, text, boolean)',
    'public.trust_current_network(text)', 'public.my_network_status()',
    'public.clockin_photos_expired(int)', 'public.mark_clockin_photos_purged(uuid[])'] loop
    execute 'revoke all on function ' || f || ' from public, anon';
    execute 'grant execute on function ' || f || ' to authenticated';
  end loop;
end $$;

-- ── Storage: private bucket + policies ───────────────────────
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('attendance-photos', 'attendance-photos', false, 1048576, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 1048576, allowed_mime_types = array['image/jpeg'];

-- Staff may upload ONE photo, only to the path issued for their own open
-- clock-in (…/<their id>/<attendance id>.jpg), within 10 minutes.
drop policy if exists clockin_photo_upload on storage.objects;
create policy clockin_photo_upload on storage.objects for insert to authenticated
  with check (
    bucket_id = 'attendance-photos'
    and split_part(name, '/', 3) = auth.uid()::text
    and exists (select 1 from public.attendance a
                 where a.staff_id = auth.uid()
                   and name like '%/' || a.id::text || '.jpg'
                   and a.photo_path is null
                   and a.clock_in_at > now() - interval '10 minutes')
  );
drop policy if exists clockin_photo_read on storage.objects;
create policy clockin_photo_read on storage.objects for select to authenticated
  using (bucket_id = 'attendance-photos' and private.can('attendance.verify'));
drop policy if exists clockin_photo_delete on storage.objects;
create policy clockin_photo_delete on storage.objects for delete to authenticated
  using (bucket_id = 'attendance-photos' and private.can('attendance.verify'));
