# TPN OS v2 — Go-live checklist

## Status (2026-10-16)

| Step | State |
|---|---|
| 0 Leaked password protection | **Skipped**: needs a paid Supabase plan. Revisit if the plan is upgraded. |
| 0 Backups | ✅ Free nightly encrypted `pg_dump` on the headless PC at 03:00, 30 kept, restore-tested Oct 20. See HANDOFF.md → "Backups". |
| 1 Database (29a–41) | ✅ Live. Advisors clean apart from the intended public functions. 35 (pay a whole table at Close table), 36 (per-person read receipts), 37a/37b (manual payments), 38 (delivery), 39–40 (menu) and 41 (order idempotency) added Oct 17. 40 and 41 were applied to `xjlqfpnzobfqxetgkkai` on Oct 17 as migrations `40_…` and `41_order_idempotency`. |
| 2 Website + portal | ✅ Merged to `main` and live. FAQs with `[Fill in]` stay unpublished (open questions on hold). |
| 3 Clock-in | ⏸ Waiting: needs someone at the restaurant (trust Wi-Fi, phone camera test). |
| 4 HitPay | ⏸ Not used for now: every payment (cash, GCash/Maya, QR Ph, card, bank) is taken by hand and recorded with its reference. Update the "How do I pay?" FAQ (Website tab) to say GCash/Maya/QR Ph/card are accepted. |
| Delivery | ✅ Live. Set your areas and fees in Service → Deliveries → Areas & fees before announcing delivery. |
| iMin counter | ⏳ See section 8. |
| 5 POS / cash drawer | ✅ Usable now — the Counter is a tab on the floor screen (Floor & Counter); dine-in tables pay at Close table. No add-ons set up; add them only when the menu actually has paid extras. |
| 6 Stamp cards | ⏸ Off on purpose: the reward (₱300 min, 10 stamps, free dish ≤ ₱300) is a placeholder and costs real money. When the owner approves an offer: Rewards → set it, tick on. The footer link appears by itself; re-publish the stamp-card FAQ in the Website tab. |
| Open questions | On hold. |

Do the steps in order. Each one is safe to stop after: nothing later is required for earlier steps to work.

## 0. Before you start (5 minutes)

- [ ] Supabase → Authentication → Settings → **Leaked password protection: ON**.
- [x] Take a database backup: runs nightly on the headless PC (HANDOFF.md → "Backups"). Before a risky migration, run one by hand there: `schtasks /Run /TN "TPN OS Backup (nightly)"`.
- [ ] Run the tests on your PC: `cd tests/db && npm install && node run.mjs` → `123 passed, 0 failed`.

## 1. Database (Supabase → SQL Editor)

Run each file **on its own**, in this order. All are safe to re-run.

| File | What it adds |
|---|---|
| `sql/29a-enum-values.sql` | ⚠️ run alone first — new values: payment `hitpay`, `bank`; inquiry `tasting` |
| `sql/29b-platform-helpers.sql` | shared audit/permission helpers |
| `sql/30-site-content.sql` | contact details, FAQs, testimonials, event packages (Website tab) |
| `sql/31-payments.sql` | payments ledger, cash/bank/HitPay, refunds, service charge, **senior/PWD VAT fix**, daily close on received cash |
| `sql/32-pos-cash-modifiers.sql` | counter POS, cash drawer shifts, add-ons & choices, 86 |
| `sql/33-clockin-verification.sql` | trusted network + clock-in photo (creates the private `attendance-photos` bucket) |
| `sql/34-stamp-cards.sql` | stamp cards (starts **off**) |
| `sql/35-table-settle.sql` | Close table takes cash for the whole table in one go |
| `sql/36-read-receipts.sql` | notifications and branch messages stay read per person |
| `sql/37a-payment-enum.sql` | ⚠️ run alone first — payment method `qrph` |
| `sql/37b-manual-payments.sql` | GCash / Maya / QR Ph / card / bank recorded by hand with a reference |
| `sql/38-delivery.sql` | delivery areas & fees, dispatch (our rider / Lalamove / Grab), tracking |
| `sql/39-menu-oct-2026.sql` | the real menu from the October boards |
| `sql/40-menu-descriptions.sql` | short descriptions for the 42 dishes that had none (fills blanks only) |
| `sql/41-order-idempotency.sql` | a retried order (dropped connection, refresh, second tap) returns the first order instead of placing a second one. Run it before or with the site release; the old site keeps working on it |
| `sql/42-silog-menu.sql` | Chicken Silog is renamed Chicksilog; Tocilog (₱115) is back on the menu. Data only. Applied to production Oct 17 as `42_silog_menu` |
| `sql/43-bir-invoices.sql` | booklet invoice numbers on orders, the end-of-day invoice, and which sales need one (VAT setting in Website). Applied to production Oct 21 as `43_bir_invoices` |

Then: Supabase → Advisors → Security. Expected warnings only: the customer functions (`submit_order`, `track_order`, `claim_stamp_card`, `my_stamp_card`, `stamp_card_code`, `my_guest_profile`, `addon_suggestions`, `signal_*`) are public on purpose.

## 2. Website + portal

- [ ] Merge `feature/tpn-v2-overhaul` into `main` and push. GitHub Pages updates in ~1 minute.
- [ ] Open the site once with `?nc=1` and check the menu, the FAQ page and Events.
- [ ] Portal → **Website**: check the phone, address, hours; answer the FAQs marked `[Fill in]` and publish them; add real testimonials only with the customer's OK; set package prices and publish.

## 3. Clock-in (needs a phone at the restaurant)

- [ ] As a manager, **on the restaurant Wi-Fi**: Portal → Clock-in review → **Trust this network**.
- [ ] Ask one crew member to clock in with the camera. It should show “verified”.
- [ ] Clock in once from mobile data: it should land in the review queue.
- [ ] Optional: Website → `hr.uniform_checklist` is the list on the review cards.
- Note: the camera was tested only in a browser without a camera. **Test the photo on a real phone first.**

## 4. HitPay (online payments)

1. HitPay dashboard (sandbox first) → Developers → copy the **API key** and **salt**.
2. Supabase → Edge Functions → Secrets:
   - `HITPAY_API_KEY` = the key
   - `HITPAY_SALT` = the salt
   - `HITPAY_MODE` = `sandbox` (later `live`)
   - `SITE_URL` = `https://unorfl.github.io/tpn-os/`
3. Deploy the functions (Supabase CLI, from the repo folder):
   ```
   supabase functions deploy hitpay-create
   supabase functions deploy hitpay-refund
   supabase functions deploy hitpay-webhook --no-verify-jwt
   ```
4. HitPay → Developers → Webhook Endpoints → add
   `https://xjlqfpnzobfqxetgkkai.supabase.co/functions/v1/hitpay-webhook`, event **payment_request.completed**.
5. Test: place a small order, choose Pay online, pay in sandbox. The order must turn **Paid** by itself (Payments tab).
6. Only then: Portal → Website → “Online payments (HitPay)” → type `yes`. Customers now see Pay online on the website and the QR menu.
7. When ready for real money: same steps with the live key/salt and `HITPAY_MODE=live`.

## 5. Counter POS and cash drawer

- [ ] Portal → **Add-ons & choices**: set up any extras (e.g. Extra rice +₱25). Link each group to its dishes.
- [ ] Portal → **Counter (POS)** → Open shift with the opening float. Close it at the end of the day (Z read).
- [ ] Daily close now expects **cash actually received**, and lists unpaid orders and unconfirmed bank transfers.

## 6. Stamp cards (when you are ready to announce them)

- [ ] Portal → **Rewards**: set the minimum order, stamps needed, the reward; tick **Stamp card is on**; Save.
- [ ] Customers: website footer → Stamp card. Counter customers scan the QR on their printed bill.

## 7. If something goes wrong

- Pages: revert the merge on `main` and push (the database changes are backwards-compatible with the old pages).
- One feature off without a deploy: Website → Online payments blank (HitPay off); Rewards → untick (stamps stop).
- A wall screen stuck: reload it; screens re-sync on reconnect.

## Open questions for the owner

- “Established 2003 / 20+ years”: the Facebook page name says 2019. Which is right?
- Real email and SEC / TIN numbers, if you want them shown (the badges appear automatically once filled in).
- Delivery radius and fee, minimum pax, booking lead time (FAQ answers).
- Senior/PWD at shared tables: staff now enter the guest's share. Confirm this matches your accountant's practice.

## 8. The iMin D4 at the counter

The counter runs the floor screen in Chrome. Nothing needs to be built or sideloaded.

1. On the iMin, open **iMin App Store** and install **iMinprinterplugin** (iMin's print service). Open it once.
2. Open **Chrome** → `https://unorfl.github.io/tpn-os/tpn-dine-in-floor` → sign in with a counter account (dining staff or above; not the wall-screen account, which cannot take money).
3. Chrome menu ⋮ → **Add to Home screen / Install app**. It opens full-screen as "TPN Counter".
4. On the floor screen's top bar the printer chip should read **🖨 Printer ready**. Tap it → **Test print**, then **Open drawer**.
   - "No printer service" = the plugin is not installed or not running. "Printer offline" = tap Reconnect.
5. Tap it → **Auto-print receipts: On** if you want a bill printed after every payment.
6. Cash payments pop the drawer by themselves. Every drawer open is in the audit log.
7. Optional: Android Settings → Display → keep the screen on while charging.

If the iMin is plugged into this PC by USB with **USB debugging** on (Settings → About → tap Build number 7×, then Developer options → USB debugging), Claude can open the page on it and check the setup with `adb`.

## 9. Moving the website to Vercel

GitHub keeps the code, Supabase keeps the data, and Vercel serves the pages. Do this **before** printing table QR codes or installing the counter app, because both remember the web address they were made on.

1. vercel.com → sign in with the GitHub account that owns `UnoRfl/tpn-os` → **Add New → Project** → import `tpn-os`.
2. Framework preset **Other**. No build command, output directory = the repo root (leave blank). Deploy. `vercel.json` already sets clean URLs and headers.
3. Open the new address and check the menu, the portal sign-in, `/tpn-table-menu?table=1` and `/tpn-kitchen-station`.
4. Optional: Settings → Domains → add the restaurant's own domain.
5. Then: print the table QR codes from the portal on the new address, install the counter from the new address, and update `og:image` in `index.html` to the new domain.
6. Leave GitHub Pages on for a week as a fallback, then turn it off (repo Settings → Pages).

Supabase needs no change: staff sign in with a password, so there are no redirect URLs to update.
