# TPN OS — Post-Update Testing Checklist

Walk this end-to-end after extracting `phase3-6.zip` over your local files and pushing to GitHub Pages. Test in this order — earlier tests unblock later ones.

## Prerequisites

- SQL migration `sql/09-order-fields-and-attendance.sql` already ran successfully. If you haven't run it yet, do that first.
- `config.js` untouched (still has your Supabase URL + anon key).
- All 4 files overwritten: `index.html`, `tpn-supabase.js`, `tpn-table-menu.html`, `tpn-dine-in-floor.html`.
- Hard-refresh the deployed site (Ctrl+Shift+R) after `git push`.

---

## 🔴 Phase 2 — Customer-facing (already tested previously, verify still working)

- [ ] Table QR from portal opens `tpn-table-menu.html` (not 404)
- [ ] Delivery order persists `delivery_address` in DB
- [ ] Special requests persist to `notes` in DB
- [ ] Track My Order works for anonymous users (paste order_number)
- [ ] Table order progress bar updates in real time when staff advances in KDS

## 🔴 Phase 3 — Floor panel auth

- [ ] Open `tpn-dine-in-floor.html` **in a private/incognito window** (no logged-in session)
  - Should show "Checking your login…" briefly, then "You need to be signed in…" with a "Go to Staff Login" button
  - **NO customer data should be visible before login**
- [ ] Log into a **dining or kitchen** account, then visit the floor URL
  - Should show "The floor panel is for manager+ staff only"
- [ ] Log in as a manager+, then visit the floor URL
  - Should reveal the full floor panel with your role in the top-right badge

## 🟡 Phase 4 — Structural fixes

- [ ] **Staff Board** (log in as CEO/Director):
  - Every role slot label matches the DB enum: Manager, Supervisor, Dining, Kitchen
  - Any admin/director/ceo accounts appear in a gold-tinted **Leadership** row at the top of the column
  - Drag a dining staffer onto the Kitchen slot → refresh page → still shows in Kitchen
- [ ] **Inquiries persist**:
  - Log in as manager+, open Inquiries
  - Click "Mark In Progress" on any inquiry
  - Refresh the page → status should still be "in-progress"
  - Same test with "Close"
- [ ] **Inquiry Call/Email buttons**:
  - Click "📞 Call" on an inquiry with a phone number → should open your phone dialer / prompt Skype-etc
  - Click "✉️ Email" → should open your default mail client with subject pre-filled
- [ ] **Table QR page**:
  - Should now say "N tables" next to each branch name (not hardcoded 12)
  - Click "+ Add Table" → enter 13 → new QR should appear
  - Refresh → Table 13 still there
  - In Supabase Table Editor → `restaurant_tables` → row exists with `table_number = 13`

## 🟢 Phase 5 — Placeholder cleanup

- [ ] **Change Password**:
  - Log into any staff account → Settings → Change Password
  - Enter same password twice with < 6 chars → error inline
  - Enter different passwords → error inline
  - Enter valid password → success toast → log out → log back in with new password ✅
  - Reset it back if this was your admin account
- [ ] **2FA screen**:
  - The "Demo: Enter 123456" hint is gone
  - Now says "SMS 2FA is bypassed for MVP — press Verify to continue"
- [ ] **Staff Board chips** no longer show fake "5★" stars or "100% attendance"
  - Now show role name

## 🟢 Phase 6 — Attendance & Messages (the big new feature)

### Attendance — staff side

- [ ] Log in as a dining or kitchen account
- [ ] Home tab → "Today's Shift" card should show "Not clocked in"
- [ ] Hit "🕐 Clock In" → toast → card updates to "On Shift · 0h 0m"
- [ ] Refresh page → still on shift (persisted)
- [ ] "This Week" and "This Month" counters increment
- [ ] Home tab → wait a minute → "On Shift · 0h 1m"
- [ ] Hit "🕐 Clock Out" → toast → card back to "Off Shift"
- [ ] Try clocking in twice without clocking out first → should error with clear message

### Attendance — My Attendance page (staff side)

- [ ] Open "My Attendance" from staff sidebar
- [ ] Shows: This Month tile, Streak tile, Avg Clock-In tile — all with **real** numbers
- [ ] Table shows your clock in/out entries with duration column
- [ ] After you've clocked in and out a few times over multiple sessions, verify streak, avg time computes correctly

### Attendance — Admin view

- [ ] Log in as manager+ (or CEO)
- [ ] Sidebar → TEAM section → **Attendance** tab
- [ ] Today's date shows in the header
- [ ] Tiles: Staff Clocked In today / Total Shifts / Still On Shift
- [ ] Table lists all clock-in records for today from all your staff
- [ ] Click "← Prev" → yesterday's date; "Next →" → tomorrow (blank); "Today" → back to today
- [ ] Scroll down: 30-day summary table shows totals per staff
- [ ] As admin+ only: "Correct" button appears on each row
  - Click it → modal with datetime pickers
  - Change the clock-in time slightly → Save → row updates
  - "✎ corrected" note appears on the row
- [ ] Delete Entry button in modal actually deletes (with confirm)

### Messages — staff side

- [ ] Log in as manager, open Messages tab
- [ ] Click "Compose" → dropdown "To" shows: 📣 Broadcast + every active staff by name
- [ ] Send a broadcast: subject "Test broadcast", body "Hello team"
- [ ] Toast: "✓ Broadcast sent to Las Piñas"
- [ ] Refresh → your sent message still visible

- [ ] Log in as a **dining** account (recipient)
- [ ] Home tab → "Recent Messages" panel should preview the new broadcast
- [ ] Sidebar → Messages tab → shows unread indicator (highlighted)
- [ ] Click the message → modal opens showing full body
- [ ] Close modal → refresh → message is no longer highlighted (read state persisted)

### Messages — realtime

- [ ] Open two browsers (or normal + incognito): manager in one, dining staff in the other
- [ ] Manager sends a **direct message** (pick the specific staff, not broadcast)
- [ ] Within ~1s the dining staff should see a toast "✉️ New message from a teammate"
- [ ] Sidebar badge on "Messages" increments
- [ ] Click the badge → new message is at the top of the inbox

### Messages — Admin view

- [ ] Log in as manager+ → sidebar → TEAM → **Messages** tab
- [ ] Toggle "📥 Inbox" and "📤 Sent" tabs
- [ ] Sent tab shows all your outgoing messages (broadcasts labeled "To: 📣 All Las Piñas")
- [ ] Click any sent message → detail modal

---

## Post-testing

Once all boxes are checked:

```
git add .
git commit -m "phase 3-6: floor auth gate, staff board fix, attendance + messages system, password change, table QR dynamic"
git push
```

If any test fails:
1. Open browser console (F12 → Console tab)
2. Screenshot the errors
3. Paste back to Claude with the phase + test name

---

## Known deferred (blocked, not tested)

- **Payment webhooks** — GCash/PayMaya QRs still display-only (waiting on paid Supabase + GCash Business API)
- **SMS 2FA** — bypassed cleanly (waiting on SMS provider)
- **BIR receipts** — StoreHub handles this side

These will be addressed in a future session once dependencies unblock.
