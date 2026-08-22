# TPN OS — Review of the CEOs' 18 Suggestions

Checked against the live code on 22 Aug 2026. Every verdict below was verified
by reading the actual file, not assumed. File and line references are given so
anything here can be checked.

**Headline:** three of the eighteen are already built and working. Seven are
an afternoon's work between them. Two need a business decision before any code
gets written. One should not be built as described.

---

## Already built — worth showing them

### #15 · Kitchen display, first-in-first-out, preparing / done
**Already works.** `renderKDS()` sorts oldest-first (`index.html:4291`,
comment reads `// oldest first`). NEW / COOKING badges, a "Start Cooking" and
a "Mark Ready" button, a 15-second refresh and an audio chime are all there.
The wall screen does the same in three columns (`tpn-kitchen-station.html:493`).

The only real gap is vocabulary: the code says Received → Preparing → **Ready**,
not "done". If they want the word "Done", that is a label change, 10 minutes.

### #16 · Void requests should show who asked and who approved
**Already works, with a catch worth fixing.** Both names, both roles, the
reason, the reviewer's note and the timestamps all render
(`index.html:5583–5598`), fed by the `v_void_requests` view which joins staff
twice (`sql/15b:517`).

The catch: the reviewer's name comes back **blank for anyone below manager**,
because that join is RLS-scoped. So a supervisor who raised a request sees
"Approved · 2h ago" with no name. If the complaint came from looking at a
staff login rather than their own, that is the actual bug. Small fix, needs a
migration to snapshot the reviewer's name onto the row.

### #6 · Keep the "Let's Make It Special" event form
**Agreed, and it already exists** (`index.html:2001`), writing real rows to
`inquiries` and returning a `TPN-E-XXXXXX` reference. No change needed.

One gap: it captures **no email address**, even though `inquiries.contact_email`
exists in the schema. Phone-only follow-up loses leads. Worth adding a field.

---

## Quick wins — one afternoon covers all of these

| # | Change | Where | Effort |
|---|---|---|---|
| 2 | Reword the Events→Concessions box to "Need a concessionaire for an office canteen?" | `index.html:1986` | 10 min |
| 3 | Date beside the day name in the **admin** Schedules grid | `index.html:3836` | 15 min |
| 8 | Make the four "Built for Business Scale" cards clickable | `index.html:1846–1870` | 20 min |
| 9 | Trim the Concessions "Service Type" dropdown | `index.html:1929–1938` | 10 min |
| 13 | Rename Cart → Tray | nav, drawer, FAB | 20 min |
| 17 | Rename Kitchen Display → "Kitchen Queue", Kitchen Station → "Kitchen Screen" | nav labels | 10 min |

Notes on three of them:

**#2 is a routing bug, not a style nit.** Today that box sends a corporate
catering enquiry to the B2B concessions form, where the pricing model is
different. The CEOs are right.

**#3 — the staff view already shows dates** (`index.html:7183`). It is only the
admin grid that does not, which is the one they were looking at.

**#9 is zero-risk.** `submitConcession()` drops the value into a free-text
message string, so no enum or constraint depends on those option labels.

---

## #13 · Cart → "TRAY" — yes to half of it

**Yes to "Tray" as the container name.** It is a genuine improvement, not just
branding: a tray is the physical thing a Filipino restaurant hands you, and it
reinforces the shareable pax-pricing the menu is already built around. Swap the
🛒 supermarket trolley for 🍽️ and the metaphor explains itself.

**No to ALL CAPS, and no to "ADD TO TRAY".** Three reasons:

1. **There is no "Add to Cart" button to rename.** The website's buttons read
   `+ Add` (`index.html:2420`) and the QR menu's reads "Add to Order". Replacing
   a 5-character button with a 12-character one, in a row that repeats once per
   pax size, breaks the mobile layout and adds reading work to the most-tapped
   control on the site.
2. **All caps measurably slows reading** and some screen readers spell short
   capitalised words out. If they want the visual weight, do it with
   `text-transform: uppercase` in CSS so the accessible text stays "Tray" — the
   codebase already does this in a dozen places.
3. **"Your Order" and "Add to Order" are already clearer.** A diner at table 4
   who taps "Add to Order" understands it is going to the kitchen. Tray is a
   great name for *the thing you review*; Order is the right word for *the thing
   you send*.

**Recommendation:** rename the nav button, the FAB and the drawer heading to
Tray. Leave `+ Add` and "Add to Order" alone. ~90% of the personality for ~20%
of the change surface. *(The nav rename is already done in this release.)*

### #4 · Six event cards → four
**Not built** — the Events page has six static cards (Birthdays, Baptisms &
Christenings, Debuts, Despedidas, Anniversaries, Graduations,
`index.html:1993`). Consolidating to Weddings/Debuts, Corporate Events,
Celebrations and Customize is three coupled markup edits: the card grid, the
page subtitle that lists the old six (`1982`), and the inquiry form's Event
Type dropdown (`2032`). Because `submitEvent()` writes that dropdown value as
free text, renaming the options breaks nothing.

Do it in the same pass as #5 Phase 1 so the fourth card ("Customize") is not a
dead tile. **~1 hour.**

---

## #7 · Language on both the public site and the portal — **done in this release**

Worth being precise about what was wrong and what now works, because the old
behaviour was misleading.

**What was wrong:** the login screen had an English / Tagalog toggle that
**did nothing**. `setLang()` set a variable that no other line in the file
read, then showed a toast saying "Tagalog naka-set na". The public marketing
site had no language control at all. The QR dine-in menu had a real toggle
whose entire dictionary was two strings.

**What works now:** a real dictionary, a `T()` lookup, a `data-i18n` pass over
the DOM and a re-render of whatever is on screen. There is now a switch in the
public nav and in the mobile menu, and the choice is remembered between visits.

**Coverage is honest, not total.** Fully translated: both navs, the login
screen, the whole sidebar, and all five new tabs (Roles, Access Matrix, Tasks,
Inventory, Finance). Database text that carries a Tagalog column — menu item
names, ingredient names, role labels — switches too.

**Not yet translated:** the pre-existing public marketing copy (hero, About,
Concessions, Events, the two inquiry forms) and the older portal tabs. Those
are still hardcoded English/Taglish. It is mechanical work — wrap the string,
add the key — but there are several hundred of them, so it is a scoped follow-on
rather than something to slip in. A missing key renders as the key itself, not
as a blank label, so gaps are obvious in testing.

**One recommendation:** do the **public site** copy next and consider stopping
there. Staff use the portal daily and are already fluent in it; the paying
customer is the one who benefits from reading the Events page in Tagalog.

---

## Worth building

### #14 · FAQ tab — build it
Nothing like it exists anywhere in the codebase. Adding a page is mechanical:
`navigate()` just toggles `.page` divs by id, so a new `<div class="page"
id="page-faq">` plus three nav entries is the whole change. Mostly copywriting.
It will deflect the phone calls a `tel:`-first business actually pays for. Seed
it from real repeat questions: delivery radius, minimum pax, lead time, payment
methods, parking. **~1 hour.**

### #11 · Bank transfer — build it, and note it is half-wired already
The reporting layer **already knows about it**: `_prettyPayment()` maps
`bank: 'Bank Transfer'` (`index.html:5988`). Nothing ever writes `'bank'`, so
that is dead code — someone started this and stopped.

Bank transfer is how PH corporate and catering clients actually settle, so it
belongs. **It needs a migration and that migration must run alone in its own
file** — `payment_method` is a Postgres enum, and Postgres refuses to add an
enum value and use it in the same transaction (the same reason `sql/15a` has a
warning at the top).

**Also, while in that function:** it maps `maya` but checkout writes `paymaya`,
so **every PayMaya order currently shows as the raw string `paymaya` in
Performance reports.** One-word fix, unrelated to this request. **~1 hour.**

### #12 · Food trays and platters — mostly data entry, not development
The pricing mechanism already exists. `menu_items.pax_options` is free-form
JSON, so `{"Small Tray (8-10 pax)": 1200, "Large Tray (15-20 pax)": 2200}`
works **today with no code change** and renders one "+ Add" button per size.

The one real gap: **Menu Manager has no category CRUD**, so creating a "Trays &
Platters" section needs a developer to run SQL. Worth fixing so the kitchen
never has to call anyone to add a menu section. **Items: 30 min of typing.
Category CRUD: ~1 hour.**

### #18c · Pre-checkout upsell — the most important finding in this review
**The feature is already written and has never once run in production.**

`upsellRules` at `index.html:2506` defines Unli Rice, Calamansi, Garlic Rice,
Soft Drinks and Extra Egg, with matching logic and a styled card. It cannot
ever match: the rules key on short codes (`'tap'`, `'long'`, `'tos'`) but `id`
comes from the database and is a UUID. `cartIds.includes('tap')` is always
false. The tell is that `const sugItem = findItem(rule.suggest)` is assigned
and never used. This is leftover pre-Supabase demo code that survived the
"purge fake data" pass — **so any claim that TPN currently upsells is false.**

Build it properly: mark add-on items as data (an `is_addon` flag) so the
kitchen can change the upsell list from Menu Manager, rather than hardcoding
IDs. And put it in the **QR dine-in menu first** — that surface has no upsell
at all today and a diner mid-meal is a far better target than a takeout
customer.

**One design objection:** they asked for a **pop-up before checkout**. Don't. A
modal that interrupts the checkout tap is the most-disliked pattern in food
ordering and measurably increases abandonment. The existing inline card inside
the cart drawer is the right placement — ignoring it costs one scroll instead
of one dismissal. Fix the placement they have. **~half a day.**

### #18b · Food tasting booking — build the cheap version first
Only mentioned in marketing copy (`index.html:1972`); no booking UI, no table.
The `schedules` table is staff shift rosters, not a customer calendar.

Do a "Request a food tasting" form that writes an `inquiries` row — `event_date`
and `expected_pax` already exist, so **no migration needed** — and let staff
confirm by phone from the Inquiries tab. Resist building a real availability
calendar until the volume justifies it: a tasting is a kitchen-capacity
negotiation, not a self-service slot. **~1 hour for the form.**

---

## Needs a decision before anyone writes code

### #5 + #18a · "Customize" with sample rates and a rough estimate
These are the same feature and it is the biggest ask in the batch.

**It contradicts a positioning choice already live on the site.** The Events
page says, in so many words, **"This isn't an auto-quote — we'll have a real
conversation"** (`index.html:1878`), and the 4-step process puts the formal
quote *after* a human call. There are no rates published anywhere in the
codebase or the schema.

Publishing sample rates and an estimator reverses that deliberately. That may
well be the right call — self-serve estimates capture price-shoppers who
otherwise bounce rather than fill in a form — but it should be made knowingly,
not discovered after launch.

**If you go ahead, phase it:**
- **Phase 1 (~1 hour, no migration):** a static "Sample Rates" block on the
  Events page — three or four packages, a per-pax range, a clear "final quote
  after consultation" line. This alone satisfies most of what #5 asks for.
- **Phase 2 (several days, migration required):** the interactive builder with
  a live running total. Needs tables for packages, add-ons and rates, plus
  manager-facing rate CRUD — otherwise every price change is a code deploy.

Whatever the estimator shows must be a clearly-labelled **range**. A Filipino
catering quote that firms up too early is a margin leak, and an estimate the
kitchen cannot honour is worse than no estimate.

### #1 · VIP login with membership and free deliveries
**Four systems wearing one hat**, and it collides with two known blockers.

There is **no customer identity in this system at all** — no `customers` table
anywhere across all 22 migrations; orders carry a bare `customer_name` text
field. Customers are anonymous *by architecture*: `sql/05` exists specifically
to let unauthenticated visitors order, tracking is by order number, and the
setup instructions require public signups be switched **off** in Supabase Auth.

Building this means: customer accounts (new auth principal, new RLS, and
reversing the signups-off decision), a membership tier, a **delivery-credit
ledger** (10 free deliveries a month means counting, decrementing, resetting
and reconciling — the hardest and least obvious piece), and an outbound
notification channel to customers. That last one is blocked on the same
unstarted SMS provider signup as 2FA, and payment automation is still waiting
on the GCash Business API.

A membership programme with no automated payment and no notification channel
is a spreadsheet.

**Start here instead, today, with zero development:** create a "VIP" discount
template in Discounts & Promos — the discount system is already built, audited
and gated at supervisor — and have cashiers apply it to known regulars. That
tests whether the *loyalty* idea earns money before anyone builds the *login*
to support it. **Revisit after the payment webhook ships.**

---

## Don't build this one

### #10 · Replace testimonial cards with "screenshots of real customer messages"

**The premise needs correcting first: the current testimonials are not real.**

Three hardcoded cards at `index.html:1735–1749` carry named, titled, star-rated
attribution — "Rosa Manalili, Las Piñas resident, 22 years", "Jenny Castillo,
HR Manager, BPO Las Piñas", "Mark Reyes, Birthday celebrant". They are the only
hardcoded content blocks left on the public site; `git log -S'Rosa Manalili'`
returns exactly one commit, the initial scaffold whose other sample content was
deliberately removed later. They were missed by the fake-data purge.

**Why the suggestion is a mistake as written:** it asks to make invented reviews
*look more authentic* by rendering them as screenshots of messages nobody sent.
A typed quote card reads as marketing copy. A screenshot of a Messenger thread
presents itself as a record of a specific real conversation. Moving from the
first to the second, with content that was never received, is manufacturing
evidence of customer endorsement rather than designing a page. It is also
exposed to DTI rules on deceptive advertising, and screenshots invite exactly
the scrutiny that makes it discoverable — a named "HR Manager at a BPO in Las
Piñas" is a small, checkable population. The upside is a slightly warmer
homepage; the downside is a screenshot of the fake screenshot circulating.

**The honest version gets them the authenticity they actually want:**

1. **Use messages you genuinely received, with permission.** Ask five regulars
   and the office-catering clients. Screenshot the real thread, get written
   consent, redact surname, number and profile photo. Real messages read as
   authentic *because they are* — the typos and the Taglish are the credibility,
   and you cannot write them convincingly.
2. **Or keep text quotes, but only real ones.** A real first name and a real
   context is perfectly persuasive and carries none of this risk.
3. **Either way, take the three invented ones down now.** They are live on the
   production homepage today. That is a separate issue from the screenshot
   question.
4. **Move testimonials into the database** while you are in there, so staff can
   add a genuine quote without a deploy.

---

## Three things nobody asked about, found while checking

1. **Placeholder contact details are live on the homepage.** `+63 917 123 4567`
   (`index.html:2098`), `hello@tyopaengnyo.ph` (`2099`) and
   **`SEC Reg. No. 2003-XXXXXXX`** (`2113`) — sitting directly beside a "SEC
   Registered" trust badge. Fix today; this is a bigger credibility problem
   than the testimonial format.

2. **Every PayMaya order mislabels itself in Performance reports.** See #11.
   One-word fix.

3. **A seeded menu item is invisible on a fresh deploy.** In `sql/02-seed.sql:58`
   the Sinigang na Baboy row has its pax-pricing JSON landing in the
   `branch_availability` column, so `loadMenu()` filters it out and its pax
   pricing is lost. Only affects rebuilds from scratch — live data is fine.

---

## Suggested order of work

1. **Today, 15 minutes:** delete the three invented testimonials and fix the
   footer placeholders.
2. **One afternoon:** the six quick wins in the table above, plus the PayMaya
   label fix. That closes eight of the eighteen suggestions.
3. **Next:** #14 FAQ, #12 trays as data entry, #4 event cards with #5 Phase 1,
   #11 bank transfer.
4. **Then:** #18c — make the upsell code that already exists actually run.
5. **Hold for a decision:** #1 VIP, #18a rate estimator.
