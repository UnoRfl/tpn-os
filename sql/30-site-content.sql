-- ═══════════════════════════════════════════════════════════════
-- 30 · Website content the restaurant edits without a deploy
--
--   site_settings   contact details, hours, socials, feature switches.
--                   PUBLIC by design: never put a secret here. Secrets
--                   (HitPay keys) live in Supabase Edge Function secrets.
--   faqs            the FAQ page.
--   testimonials    real customer quotes ONLY. A row cannot be published
--                   without a consent date: the three invented quotes on
--                   the old homepage are what this prevents.
--   event_packages  "starts at ₱" cards on the Events page. The page
--                   states the final quote comes after a consultation.
--
-- Everything is audited through private.audit_row().
-- Requires 29b.
-- ═══════════════════════════════════════════════════════════════

select private.add_permission('site.edit', 'Administration', 'Edit the website', 'Baguhin ang website',
  'Change FAQs, testimonials, event packages and contact details shown to the public.', 'manager', 95);

-- ── settings ─────────────────────────────────────────────────
create table if not exists public.site_settings (
  key         text primary key check (key ~ '^[a-z0-9_.]+$'),
  value       jsonb not null,
  updated_at  timestamptz not null default now(),
  updated_by  uuid references public.staff(id) on delete set null
);
comment on table public.site_settings is
  'Public website settings. Readable by anyone. Never store secrets here.';

insert into public.site_settings (key, value) values
  ('contact.phone',     '"0999 888 7817"'),
  ('contact.email',     'null'),
  ('contact.address',   '"KM 19, 316 Real St., Talon Uno, Las Piñas City"'),
  ('contact.landmark',  '"Facing Shell, near the Robinsons Las Piñas exit"'),
  ('contact.map_url',   '"https://maps.google.com/?q=316+Real+St,+Talon+Uno,+Las+Pi%C3%B1as"'),
  ('contact.facebook',  '"https://www.facebook.com/TyoPaengNyo2019.ph"'),
  ('contact.instagram', '"https://www.instagram.com/tyopaengnyo"'),
  ('contact.parking',   '"Free on-site parking for diners"'),
  ('hours.text',        '"Mon – Sun · 10:00 AM – 9:00 PM"'),
  ('legal.sec_no',      'null'),
  ('legal.tin',         'null'),
  ('legal.company',     '"Tyo Paeng Nyo Restaurant and Catering Studio"')
on conflict (key) do nothing;

-- ── FAQs ─────────────────────────────────────────────────────
create table if not exists public.faqs (
  id            uuid primary key default gen_random_uuid(),
  category      text not null default 'General',
  question      text not null check (length(question) between 3 and 300),
  question_tl   text,
  answer        text not null check (length(answer) between 1 and 4000),
  answer_tl     text,
  sort          int not null default 100,
  is_published  boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now()
);

-- Seeded from what the site already states. Questions whose answers only
-- the restaurant knows are seeded UNPUBLISHED with an obvious marker, so
-- nothing invented reaches the public.
insert into public.faqs (category, question, question_tl, answer, answer_tl, sort, is_published)
select * from (values
  ('Visiting', 'Where are you located?', 'Saan kayo matatagpuan?',
   'KM 19, 316 Real St., Talon Uno, Las Piñas City — facing Shell, near the Robinsons Las Piñas exit. We moved here in October 2026 to a bigger space.',
   'KM 19, 316 Real St., Talon Uno, Las Piñas City — tapat ng Shell, malapit sa exit ng Robinsons Las Piñas. Lumipat kami dito noong Oktubre 2026 sa mas malaking lugar.', 10, true),
  ('Visiting', 'Is there parking?', 'May parking ba?',
   'Yes. Our new location has on-site parking for diners.', 'Oo. May parking na para sa mga kumakain sa aming bagong lugar.', 20, true),
  ('Visiting', 'What are your opening hours?', 'Anong oras kayo bukas?',
   'Monday to Sunday, 10:00 AM – 9:00 PM.', 'Lunes hanggang Linggo, 10:00 AM – 9:00 PM.', 30, true),
  ('Ordering', 'How do I pay?', 'Paano magbayad?',
   'Cash, or online through HitPay: QR Ph, GCash, Maya and cards. Event and office catering clients can also pay by bank transfer.',
   'Cash, o online sa HitPay: QR Ph, GCash, Maya at card. Puwede ring bank transfer para sa event at office catering.', 40, true),
  ('Ordering', 'How far do you deliver, and how much is the delivery fee?', 'Hanggang saan kayo nagde-deliver?',
   '[Fill in: delivery radius and fee]', null, 50, false),
  ('Events', 'What is the minimum number of guests for catering?', 'Ilan ang minimum na bisita sa catering?',
   '[Fill in: minimum pax]', null, 60, false),
  ('Events', 'How far ahead should I book an event?', 'Gaano kaaga dapat mag-book?',
   '[Fill in: lead time]', null, 70, false),
  ('Events', 'Can we do a food tasting first?', 'Puwede bang mag-food tasting muna?',
   'Yes. Use "Request a food tasting" on the Events page and we will call you to set a schedule.',
   'Oo. Pindutin ang "Request a food tasting" sa Events page at tatawagan namin kayo para sa schedule.', 80, true),
  ('Rewards', 'How does the stamp card work?', 'Paano gumagana ang stamp card?',
   'Every paid order that meets the minimum earns a stamp on the card linked to your phone number. Stamps are added by our system when payment is confirmed, so they cannot be added by hand or copied.',
   'Bawat bayad na order na umabot sa minimum ay may stamp sa card na naka-link sa phone number mo. Ang sistema ang naglalagay ng stamp kapag kumpirmado na ang bayad.', 90, true)
) v(category, question, question_tl, answer, answer_tl, sort, is_published)
where not exists (select 1 from public.faqs);

-- ── Testimonials ─────────────────────────────────────────────
create table if not exists public.testimonials (
  id              uuid primary key default gen_random_uuid(),
  quote           text not null check (length(quote) between 5 and 600),
  author_display  text not null check (length(author_display) between 1 and 60),  -- e.g. "Ana R." — first name + initial
  context         text check (length(context) <= 80),                              -- e.g. "Regular since 2019"
  source          text not null default 'in_person'
                  check (source in ('in_person', 'facebook', 'messenger', 'google', 'instagram', 'email', 'other')),
  consent_on      date,
  consent_note    text,          -- how consent was given; staff-only
  rating          int check (rating between 1 and 5),
  sort            int not null default 100,
  is_published    boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now(),
  constraint testimonials_publish_needs_consent check (not is_published or consent_on is not null)
);

-- ── Event packages ───────────────────────────────────────────
create table if not exists public.event_packages (
  id            uuid primary key default gen_random_uuid(),
  name          text not null check (length(name) between 2 and 80),
  name_tl       text,
  description   text check (length(description) <= 600),
  from_price    numeric(10,2) check (from_price is null or from_price >= 0),
  price_unit    text not null default 'per_pax' check (price_unit in ('per_pax', 'per_event', 'per_tray')),
  min_pax       int check (min_pax is null or min_pax > 0),
  inclusions    text[] not null default '{}',
  badge         text check (length(badge) <= 24),
  sort          int not null default 100,
  is_published  boolean not null default false,
  created_at    timestamptz not null default now(),
  updated_at    timestamptz not null default now(),
  constraint event_packages_publish_needs_price check (not is_published or from_price is not null)
);

-- Draft packages: names only, no invented prices, unpublished.
insert into public.event_packages (name, name_tl, description, sort)
select * from (values
  ('Celebrations', 'Selebrasyon', 'Birthdays, baptisms, anniversaries, graduations and despedidas.', 10),
  ('Weddings & Debuts', 'Kasal at Debut', 'Plated or buffet menus for the big milestones.', 20),
  ('Corporate Events', 'Corporate Events', 'Office parties, seminars and packed meals for teams.', 30),
  ('Customize', 'Ikaw ang Bahala', 'Build your own menu with our team.', 40)
) v(name, name_tl, description, sort)
where not exists (select 1 from public.event_packages);

-- ── Shared plumbing ──────────────────────────────────────────
do $$
declare t text;
begin
  foreach t in array array['site_settings', 'faqs', 'testimonials', 'event_packages'] loop
    execute format('alter table public.%I enable row level security', t);
    execute format('drop trigger if exists trg_audit_%1$s on public.%1$I', t);
    execute format('create trigger trg_audit_%1$s after insert or update or delete on public.%1$I
                    for each row execute function private.audit_row()', t);
    execute format('revoke all on public.%I from anon, authenticated', t);
    execute format('grant select on public.%I to anon, authenticated', t);
    execute format('grant insert, update, delete on public.%I to authenticated', t);
  end loop;
  foreach t in array array['faqs', 'testimonials', 'event_packages'] loop
    execute format('drop trigger if exists trg_touch_%1$s on public.%1$I', t);
    execute format('create trigger trg_touch_%1$s before update on public.%1$I
                    for each row execute function public.tg_touch_updated()', t);
  end loop;
end $$;

create or replace function public.trg_site_settings_stamp()
returns trigger language plpgsql set search_path = '' as $$
begin
  new.updated_at := now();
  new.updated_by := auth.uid();
  return new;
end $$;
revoke all on function public.trg_site_settings_stamp() from public, anon, authenticated;
drop trigger if exists trg_site_settings_stamp on public.site_settings;
create trigger trg_site_settings_stamp before insert or update on public.site_settings
  for each row execute function public.trg_site_settings_stamp();

-- Public reads: settings always; content only when published.
-- Staff with site.edit see drafts too.
drop policy if exists site_settings_read on public.site_settings;
create policy site_settings_read on public.site_settings for select to anon, authenticated using (true);
drop policy if exists site_settings_write on public.site_settings;
create policy site_settings_write on public.site_settings for all to authenticated
  using (private.can('site.edit')) with check (private.can('site.edit'));

drop policy if exists faqs_read on public.faqs;
create policy faqs_read on public.faqs for select to anon, authenticated
  using (is_published or private.can('site.edit'));
drop policy if exists faqs_write on public.faqs;
create policy faqs_write on public.faqs for all to authenticated
  using (private.can('site.edit')) with check (private.can('site.edit'));

-- consent_note is staff-only: the public reads testimonials through a view
-- that leaves it (and the consent date) out.
drop policy if exists testimonials_read on public.testimonials;
create policy testimonials_read on public.testimonials for select to authenticated
  using (private.can('site.edit'));
revoke select on public.testimonials from anon;
drop policy if exists testimonials_write on public.testimonials;
create policy testimonials_write on public.testimonials for all to authenticated
  using (private.can('site.edit')) with check (private.can('site.edit'));

create or replace function public.public_testimonials()
returns table (id uuid, quote text, author_display text, context text, source text, rating int)
language sql stable security definer set search_path = '' as $$
  select id, quote, author_display, context, source, rating
    from public.testimonials
   where is_published and consent_on is not null
   order by sort, created_at desc
   limit 12;
$$;
revoke all on function public.public_testimonials() from public;
grant execute on function public.public_testimonials() to anon, authenticated;

drop policy if exists event_packages_read on public.event_packages;
create policy event_packages_read on public.event_packages for select to anon, authenticated
  using (is_published or private.can('site.edit'));
drop policy if exists event_packages_write on public.event_packages;
create policy event_packages_write on public.event_packages for all to authenticated
  using (private.can('site.edit')) with check (private.can('site.edit'));

-- ── Food tasting requests ─────────────────────────────────────
-- Use the existing inquiries table (event_date + expected_pax already
-- exist). Allow the new 'tasting' type through the anonymous insert path.
-- (inquiry_type 'tasting' was added in 29a.)
