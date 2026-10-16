# TPN OS v2 — Go-live checklist

## Status (2026-10-16)

| Step | State |
|---|---|
| 0 Leaked password protection, backups | **Skipped**: needs a paid Supabase plan. Revisit if the plan is upgraded. |
| 1 Database (29a–34) | ✅ Live. Advisors clean apart from the intended public functions. |
| 2 Website + portal | ✅ Merged to `main` and live. FAQs with `[Fill in]` stay unpublished (open questions on hold). |
| 3 Clock-in | ⏸ Waiting: needs someone at the restaurant (trust Wi-Fi, phone camera test). |
| 4 HitPay | ⏸ Waiting on the HitPay meeting. "How do I pay?" FAQ says cash/bank only until then — put online payment back in when it goes live. |
| 5 POS / cash drawer | ✅ Usable now. No add-ons set up; add them only when the menu actually has paid extras. |
| 6 Stamp cards | ⏸ Off on purpose: the reward (₱300 min, 10 stamps, free dish ≤ ₱300) is a placeholder and costs real money. When the owner approves an offer: Rewards → set it, tick on. The footer link appears by itself; re-publish the stamp-card FAQ in the Website tab. |
| Open questions | On hold. |

Do the steps in order. Each one is safe to stop after: nothing later is required for earlier steps to work.

## 0. Before you start (5 minutes)

- [ ] Supabase → Authentication → Settings → **Leaked password protection: ON**.
- [ ] Take a database backup: Supabase → Database → Backups (or `pg_dump`).
- [ ] Run the tests on your PC: `cd tests/db && npm install && node run.mjs` → `82 passed, 0 failed`.

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
