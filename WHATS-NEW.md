# What's new in this build

## Tier 1 — Core restaurant operations (now functional)

**Order status changes persist to the database.**
When staff advance an order (received → preparing → ready → done), it now writes to Supabase and pushes live to every connected screen. Two devices stay in sync. Previously this only changed local memory.

**Kitchen Display System (KDS).**
New "Kitchen Display" screen built for kitchen staff: big text, ticket-per-order, item quantities, special requests highlighted, order aging with colour warnings (yellow at warn, red pulsing at urgent), and one-tap "Start Cooking" / "Mark Ready". Kitchen staff now land here by default. Plays a chime when new orders arrive.

**Orders show full item breakdowns.**
Each order carries its structured item list (qty, name, pax size, notes) so the kitchen knows exactly what to make.

## Tier 2 — Day-to-day operation

**Single branch (Las Piñas only).**
Removed Bacoor and TGT from the app for this version. Run `sql/07-single-branch.sql` and optionally uncomment the delete lines to remove them from the database too.

**Real sales reporting.**
The revenue breakdown now computes from actual orders: total sales, breakdown by order type, and top items ranked by real quantity sold. No more hardcoded figures.

**Today's orders load on login.**
The portal now pulls all of today's orders (including completed) so sales totals and history are accurate, not just the active queue.

**Audit Log reads from the real database.**
Every account creation (via the edge function) and future logged action shows up here with who, when, and details. Run `sql/07-single-branch.sql` so managers/owners can read it.

## Tier 3 — Cleanup

**Credentials moved to `config.js`.**
Your Supabase URL and anon key now live in one small `config.js` file. Every other file reads from it, so future updates never overwrite your keys. **Paste your keys into `config.js` after extracting.**

**Recognition and daily-quests gamification removed.**
Replaced the corporate "achievements" system with a plain "Needs Attention" list driven by real data (active orders, kitchen backlog, new inquiries) and a "Recent Orders" panel.

**Dashboard simplified and made real.**
Every tile now reflects live data. Cut the fake trend labels ("▲ 12% vs yesterday").

---

## Setup reminder

1. Run new migrations in order: `sql/06-menu-fields.sql` (if not already), then `sql/07-single-branch.sql`
2. Paste your Supabase URL + anon key into **`config.js`**
3. `git add . && git commit -m "..." && git push`

## Still simplified (future work)
- Staff scheduling doesn't persist yet (view only)
- Payment webhooks (GCash/Maya QRs are display-only)
- SMS 2FA
