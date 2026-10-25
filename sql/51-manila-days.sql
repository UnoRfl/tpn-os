-- ═══════════════════════════════════════════════════════════════
-- 51 — every report's day is the Manila day (Oct 25, 2026)
--
-- (49 manager PIN and 50 menu engineering are on production from the
-- Mac checkout; their files had not reached main when this was written.)
--
-- 1. REPORTS CUT DAYS AT 8 AM MANILA. The database runs on UTC (checked on
--    production: TimeZone = UTC). Wherever a function compares a timestamp
--    with a plain date, or casts a timestamp to a date, Postgres uses that
--    zone, so a "day" ran from 8:00 AM to 8:00 AM Manila time:
--      • finance_summary: sales, COGS, labour (attendance) and expenses
--      • inventory_variance: stock movements
--      • build_payroll_run: days worked (clock_in_at::date)
--      • set_order_number: the date inside TPN-XXX-YYYYMMDD-NNNN, so an
--        order at 7 AM carried yesterday's date
--      • daily_close_report / record_daily_close / record_day_invoice /
--        invoice_day_summary: already cut at Manila midnight, but their
--        "current_date" default was the UTC day
--    Each now runs with TimeZone = Asia/Manila (a per-function setting, so
--    nothing else in the database changes). Manila has no daylight saving.
--
-- 2. SCHEDULE WEEKS WERE SAVED AS SUNDAYS. The portal turned "Monday 00:00
--    local" into a date with toISOString(), which in UTC+8 is the Sunday
--    before. The portal now sends the Manila date (TPN.today), so rows
--    saved before have to move forward one day, or every saved schedule
--    would vanish from the screen. Production had 1 such row on Oct 25.
--    A Sunday row whose Monday already exists for that person is left.
-- ═══════════════════════════════════════════════════════════════

alter function public.finance_summary(date, date, text, uuid)        set timezone to 'Asia/Manila';
alter function public.inventory_variance(date, date, uuid)            set timezone to 'Asia/Manila';
alter function public.build_payroll_run(date, date, uuid)             set timezone to 'Asia/Manila';
alter function public.set_order_number()                              set timezone to 'Asia/Manila';
alter function public.daily_close_report(date, uuid)                  set timezone to 'Asia/Manila';
alter function public.record_daily_close(date, numeric, text, uuid)   set timezone to 'Asia/Manila';
alter function public.record_day_invoice(date, text, numeric, uuid)  set timezone to 'Asia/Manila';
alter function public.invoice_day_summary(date, uuid)                 set timezone to 'Asia/Manila';

update public.schedules s
   set week_start = s.week_start + 1
 where extract(dow from s.week_start) = 0
   and not exists (select 1 from public.schedules m
                    where m.staff_id = s.staff_id and m.week_start = s.week_start + 1);
