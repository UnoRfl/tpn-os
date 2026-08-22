/* ═══════════════════════════════════════════════════════════════
   TPN OS — Supabase Data Layer

   Credentials live in config.js (loaded before this file), so this
   file can be updated freely without ever touching your keys.

   Load order in each HTML file:
     <script src="https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2"></script>
     <script src="config.js"></script>
     <script src="tpn-supabase.js"></script>
   ═══════════════════════════════════════════════════════════════ */

const SUPABASE_URL      = (window.TPN_CONFIG && window.TPN_CONFIG.SUPABASE_URL)      || 'https://YOUR-PROJECT-REF.supabase.co';
const SUPABASE_ANON_KEY = (window.TPN_CONFIG && window.TPN_CONFIG.SUPABASE_ANON_KEY) || 'PASTE-YOUR-ANON-KEY-HERE';

// Customer-facing surfaces must never inherit a lingering staff session.
// If a staff member (or Uno testing on his own phone) had ever signed in
// on this origin, persistSession would restore their JWT and RLS would
// route anon dine-in inserts through the AUTHENTICATED policy path —
// which requires branch_id = private.my_branch(), causing "permission
// denied for table orders" toasts on the QR menu. Isolating the client
// (no persist + different storage key) guarantees the QR menu always
// acts as a true anonymous customer, without disturbing the staff app
// session in other tabs.
const _TPN_CUSTOMER_SURFACE = /tpn-table-menu/i.test(location.pathname);

// Init client
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: _TPN_CUSTOMER_SURFACE
    ? { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false, storageKey: 'sb-tpn-anon' }
    : { persistSession: true,  autoRefreshToken: true,  detectSessionInUrl: false }
});

const TPN = {
  // ── Cached state ─────────────────────────────────────────────
  _user: null,        // current staff profile
  _menu: null,        // { categories, items }
  _branches: null,

  // ═════ AUTH ═════════════════════════════════════════════════
  async login(email, password) {
    const { data, error } = await sb.auth.signInWithPassword({ email, password });
    if (error) throw error;
    await this.loadProfile();
    return this._user;
  },

  async logout() {
    await sb.auth.signOut();
    this._user = null;
  },

  async loadProfile() {
    const { data: { user } } = await sb.auth.getUser();
    if (!user) { this._user = null; return null; }
    const { data, error } = await sb.from('staff')
      .select('*, branches(*)').eq('id', user.id).single();
    if (error) { console.warn('No staff profile:', error.message); return null; }
    this._user = data;
    return data;
  },

  currentUser() { return this._user; },

  // Role hierarchy — MUST match the order of the staff_role enum in Postgres
  // (sql/01-schema.sql + sql/15a-display-roles.sql). private.has_role() in the
  // database compares enum positions, so any drift here is a security bug.
  // The two *_display roles sit at the BOTTOM on purpose: they are shared
  // device logins for the wall screens, so every hasRole() check fails for
  // them — including hasRole('manager'), which is what gates voiding.
  ROLE_HIERARCHY: ['kitchen_display','dine_in_display','dining','kitchen','supervisor','manager','admin','director','ceo'],
  DISPLAY_ROLES:  ['kitchen_display','dine_in_display'],

  hasRole(minRole) {
    if (!this._user) return false;
    const H = this.ROLE_HIERARCHY;
    return H.indexOf(this._user.role) >= H.indexOf(minRole);
  },

  // True when the signed-in account is a wall-mounted screen, not a person.
  isDisplayAccount(role) {
    const r = role || (this._user && this._user.role);
    return !!r && this.DISPLAY_ROLES.indexOf(r) !== -1;
  },

  // Which surface a display account belongs on. Null for real people.
  displayHome(role) {
    const r = role || (this._user && this._user.role);
    if (r === 'kitchen_display') return 'tpn-kitchen-station';
    if (r === 'dine_in_display') return 'tpn-dine-in-floor';
    return null;
  },

  // ═════ BRANCHES ═════════════════════════════════════════════
  async getBranches() {
    if (this._branches) return this._branches;
    const { data, error } = await sb.from('branches').select('*').eq('is_active', true).order('name');
    if (error) throw error;
    this._branches = data;
    return data;
  },

  async getBranchByCode(code) {
    const all = await this.getBranches();
    return all.find(b => b.code === code);
  },

  // ═════ MENU ═════════════════════════════════════════════════
  async loadMenu(branchCode = null) {
    const [cats, items] = await Promise.all([
      sb.from('menu_categories').select('*').eq('is_active', true).order('display_order'),
      sb.from('menu_items').select('*').eq('is_available', true).order('display_order')
    ]);
    if (cats.error) throw cats.error;
    if (items.error) throw items.error;

    let filteredItems = items.data;
    if (branchCode) {
      filteredItems = items.data.filter(i =>
        !i.branch_availability || i.branch_availability[branchCode] === true
      );
    }

    this._menu = { categories: cats.data, items: filteredItems };
    return this._menu;
  },

  itemsInCategory(categoryId) {
    if (!this._menu) return [];
    return this._menu.items.filter(i => i.category_id === categoryId);
  },

  // Return menu grouped by category, in the format the HTML files expect:
  // [ { cat, catName, catSub, items:[{ id, name, desc, emoji, price?, pricePax?, best?, available }, ...] }, ... ]
  async loadGroupedMenu(branchCode = null) {
    await this.loadMenu(branchCode);
    const cats = this._menu.categories;
    return cats.map(c => {
      const items = this._menu.items
        .filter(i => i.category_id === c.id)
        .map(i => {
          const base = {
            id:     i.id,
            name:   i.name,
            nameTl: i.name_tagalog || '',
            desc:   i.description || '',
            emoji:  i.emoji || (c.icon || '🍽️'),
            available: i.is_available !== false,
            best:   !!i.is_featured,
            featuredTag: i.featured_tag || null
          };
          if (i.is_shareable && i.pax_options) base.pricePax = i.pax_options;
          else base.price = Number(i.price);
          return base;
        });
      // Derive a stable string "code" for the category (used by HTML filters)
      const cat = (c.name || '').toLowerCase().replace(/[^a-z0-9]+/g, '_').replace(/^_+|_+$/g, '');
      return { cat, catName: c.name, catNameTl: c.name_tagalog || c.name, catSub: '', items };
    });
  },

  async getFeaturedItems() {
    const { data, error } = await sb.from('menu_items')
      .select('*, menu_categories(name)')
      .eq('is_available', true).eq('is_featured', true)
      .order('display_order');
    if (error) throw error;
    return (data || []).map(i => ({
      name:  i.name,
      emoji: i.emoji || '🍽️',
      tag:   i.featured_tag || 'Featured',
      price: i.pax_options
        ? `₱${i.pax_options['2-3'] || Object.values(i.pax_options)[0]} / ₱${i.pax_options['4-6'] || Object.values(i.pax_options).slice(-1)[0]} pax`
        : `₱${Number(i.price)}`
    }));
  },

  // ═════ RESTAURANT TABLES ═════════════════════════════════════
  async getTablesForBranch(branchId) {
    const { data, error } = await sb.from('restaurant_tables')
      .select('*').eq('branch_id', branchId).eq('is_active', true).order('table_number');
    if (error) throw error;
    return data;
  },

  async getTableByNumber(branchCode, tableNumber) {
    const branch = await this.getBranchByCode(branchCode);
    if (!branch) return null;
    const { data, error } = await sb.from('restaurant_tables')
      .select('*').eq('branch_id', branch.id).eq('table_number', tableNumber).single();
    if (error) return null;
    return data;
  },

  // ═════ ORDERS ═══════════════════════════════════════════════
  /**
   * Create a new order (works for anon dine-in and authed staff).
   * @param {object} opts
   * @param {string} opts.branchId
   * @param {string} [opts.tableId]
   * @param {'dine_in'|'pickup'|'delivery'} opts.orderType
   * @param {string} [opts.customerName]
   * @param {string} [opts.customerPhone]
   * @param {Array<{menu_item_id, name, unit_price, quantity, pax_size?, notes?}>} opts.items
   * @param {string} [opts.paymentMethod]
   * @param {string} [opts.notes]
   * @param {string} [opts.deliveryAddress]  // required for delivery orders
   * @param {string} [opts.scheduledFor]     // ISO timestamp for scheduled orders
   */
  // A stable, random id for THIS browser. Not a fingerprint -- it is a
  // value the browser made up for itself. It exists so one table's bill can
  // be grouped by phone, and so a split is a grouping rather than a guess.
  deviceId() {
    try {
      let d = localStorage.getItem('tpn.device');
      if (!d) {
        d = (crypto && crypto.randomUUID) ? crypto.randomUUID()
            : 'dev-' + Math.random().toString(36).slice(2) + Date.now().toString(36);
        localStorage.setItem('tpn.device', d);
      }
      return d;
    } catch (e) { return null; }
  },

  /**
   * Place an order.
   *
   * Goes through the submit_order() RPC rather than inserting into the
   * tables. Two reasons:
   *
   *  1. `anon` has INSERT on orders/order_items but NOT SELECT, and the old
   *     code did `.insert(...).select().single()`. PostgREST asks for the
   *     inserted row back, which needs SELECT, so every customer order died
   *     with "permission denied for table order_items". Granting anon SELECT
   *     would have been the easy patch and the wrong one -- orders_anon_read
   *     is `using (true)`, so it would expose every order in the business,
   *     names and phone numbers included.
   *  2. Several phones at one table should share one bill. The function
   *     appends to the table's open order instead of opening a second one.
   *
   * @param {boolean} [opts.joinTableBill=true] false starts a separate bill
   *        for this guest even though the table already has one open.
   */
  async createOrder(opts) {
    const { data, error } = await sb.rpc('submit_order', {
      p_branch_id:        opts.branchId,
      p_order_type:       opts.orderType,
      p_items:            (opts.items || []).map(i => ({
                            menu_item_id: i.menu_item_id || null,
                            name:         i.name,
                            unit_price:   i.unit_price,
                            quantity:     i.quantity,
                            pax_size:     i.pax_size || null,
                            notes:        i.notes || null
                          })),
      p_table_id:         opts.tableId ?? null,
      p_customer_name:    opts.customerName ?? null,
      p_customer_phone:   opts.customerPhone ?? null,
      p_notes:            opts.notes ?? null,
      p_payment_method:   opts.paymentMethod ?? null,
      p_delivery_address: opts.deliveryAddress ?? null,
      p_scheduled_for:    opts.scheduledFor ?? null,
      p_device_id:        this.deviceId(),
      p_join_table_bill:  opts.joinTableBill !== false
    });
    if (error) throw new Error(this.prettyOrderError(error.message));
    // Shape kept compatible with the old return value so callers that read
    // order.order_number / order.id keep working.
    return data;
  },

  // Turn a Postgres error into something a customer can act on.
  prettyOrderError(msg) {
    msg = msg || 'Could not place the order';
    if (/no_items/.test(msg))              return 'Your order is empty.';
    if (/delivery_needs_address/.test(msg))return 'Please add a delivery address.';
    if (/table_not_in_branch/.test(msg))   return 'That table QR is not valid for this branch — please call staff.';
    if (/bad_order_type/.test(msg))        return 'Something went wrong with the order type. Please try again.';
    if (/negative_price/.test(msg))        return 'One of the prices looked wrong. Please reload the menu.';
    if (/row-level security/i.test(msg))   return 'The kitchen could not accept that order. Please call staff.';
    if (/permission denied/i.test(msg))    return 'The kitchen could not accept that order. Please call staff.';
    if (/Failed to fetch|NetworkError/i.test(msg)) return 'No connection — check your signal and try again.';
    return msg;
  },

  async getOrder(id) {
    const { data, error } = await sb.from('orders')
      .select('*, order_items(*), restaurant_tables(*)').eq('id', id).single();
    if (error) throw error;
    return data;
  },

  // Look up one order by its human-readable order_number.
  // Uses the track_order() RPC because anon holds no SELECT on orders --
  // see createOrder above. Returns null when the number does not exist.
  // Deliberately no listing endpoint: one exact number in, one order out.
  async getOrderByNumber(orderNumber) {
    const { data, error } = await sb.rpc('track_order', { p_order_number: orderNumber });
    if (error) throw error;
    if (!data) return null;
    // Shape it like the old row-with-join so existing callers keep working.
    return Object.assign({}, data, {
      order_items: data.items || [],
      restaurant_tables: data.table_number ? { table_number: data.table_number } : null
    });
  },

  /**
   * Watch one order's progress from a customer device.
   *
   * Polls track_order() rather than using a realtime subscription. Realtime
   * delivers changes through the same RLS as a SELECT, and `anon` has no
   * SELECT on orders by design, so a subscription would silently never fire.
   * Polling is honest and, at 8 seconds, plenty for "is my food ready".
   *
   * Staff surfaces should keep using subscribeToOrders() -- they are
   * authenticated and realtime works for them.
   *
   * @returns {function} call it to stop polling
   */
  subscribeToOrder(orderIdOrNumber, callback, opts) {
    const everyMs = (opts && opts.intervalMs) || 8000;
    let stopped = false;
    let lastStatus = null;

    const tick = async () => {
      if (stopped) return;
      try {
        const row = await this.getOrderByNumber(orderIdOrNumber);
        if (row && row.status !== lastStatus) {
          lastStatus = row.status;
          callback({ new: row, eventType: 'UPDATE' });
        }
      } catch (e) {
        // A customer's phone losing signal must not spam the console or
        // break the screen — just try again on the next tick.
      }
      if (!stopped) setTimeout(tick, everyMs);
    };
    tick();
    return () => { stopped = true; };
  },

  // Staff-side realtime. Needs an authenticated session.
  subscribeToOrderRealtime(orderId, callback) {
    const chan = sb.channel(`order:${orderId}`)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'orders',
        filter: `id=eq.${orderId}`
      }, payload => callback(payload))
      .subscribe();
    return () => sb.removeChannel(chan);
  },

  // ── Shared table bills ──────────────────────────────────────
  // Staff view of one table's open bill, grouped by phone.
  async getTableBill(tableId) {
    const { data, error } = await sb.rpc('table_bill', { p_table_id: tableId });
    if (error) throw error;
    return data;
  },

  // Move one phone's lines onto their own bill. Staff only, on request --
  // device_id travels in the payload and is not a secret, so letting a guest
  // do this would let them move somebody else's food.
  async splitTableBill(orderId, deviceId) {
    const { data, error } = await sb.rpc('split_order_by_device', {
      p_order_id: orderId, p_device_id: deviceId
    });
    if (error) throw error;
    return data;
  },

  async listActiveOrders(branchId = null) {
    let q = sb.from('orders')
      .select('*, order_items(*), restaurant_tables(table_number)')
      .in('status', ['pending','confirmed','preparing','ready'])
      .order('placed_at', { ascending: true });
    if (branchId) q = q.eq('branch_id', branchId);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  },

  async listTodayOrders(branchId = null) {
    const start = new Date(); start.setHours(0,0,0,0);
    let q = sb.from('orders')
      .select('*, order_items(*), restaurant_tables(table_number)')
      .gte('placed_at', start.toISOString())
      .order('placed_at', { ascending: false });
    if (branchId) q = q.eq('branch_id', branchId);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  },

  async updateOrderStatus(orderId, newStatus) {
    const stampMap = {
      confirmed: 'confirmed_at',
      ready:     'ready_at',
      served:    'served_at',
      completed: 'completed_at',
      cancelled: 'cancelled_at'
    };
    const update = { status: newStatus };
    if (stampMap[newStatus]) update[stampMap[newStatus]] = new Date().toISOString();
    const { data, error } = await sb.from('orders').update(update).eq('id', orderId).select().single();
    if (error) throw error;
    return data;
  },

  // ═════ REALTIME ═════════════════════════════════════════════
  /** Subscribe to order changes. Returns unsubscribe fn. */
  subscribeOrders(branchId, callback) {
    const chan = sb.channel(`orders:${branchId || 'all'}`)
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'orders',
        filter: branchId ? `branch_id=eq.${branchId}` : undefined
      }, payload => callback(payload))
      .subscribe();
    return () => sb.removeChannel(chan);
  },

  subscribeInquiries(callback) {
    const chan = sb.channel('inquiries:all')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'inquiries' },
          payload => callback(payload))
      .subscribe();
    return () => sb.removeChannel(chan);
  },

  // ═════ INQUIRIES ════════════════════════════════════════════
  async createInquiry({ type, name, phone, email, organization, message, eventDate, expectedPax, branchId }) {
    const { data, error } = await sb.from('inquiries').insert({
      inquiry_type:   type,
      contact_name:   name,
      contact_phone:  phone ?? null,
      contact_email:  email ?? null,
      organization:   organization ?? null,
      message,
      event_date:     eventDate ?? null,
      expected_pax:   expectedPax ?? null,
      branch_id:      branchId ?? null
    }).select().single();
    if (error) throw error;
    return data;
  },

  async listInquiries(status = null) {
    let q = sb.from('inquiries').select('*, assigned_to:staff(full_name)').order('created_at', { ascending: false });
    if (status) q = q.eq('status', status);
    const { data, error } = await q;
    if (error) throw error;
    return data;
  },

  // ═════ SCHEDULES ════════════════════════════════════════════
  // Returns Monday of the week containing the given date, as ISO 'YYYY-MM-DD'.
  weekStartISO(d) {
    const x = new Date(d);
    const day = x.getDay();           // 0=Sun..6=Sat
    const diff = (day === 0 ? -6 : 1 - day);
    x.setDate(x.getDate() + diff);
    x.setHours(0, 0, 0, 0);
    return x.toISOString().slice(0, 10);
  },

  // Get one staff's schedule for a given week (null if none set).
  async getSchedule(staffId, weekStart) {
    const { data, error } = await sb.from('schedules')
      .select('*').eq('staff_id', staffId).eq('week_start', weekStart).maybeSingle();
    if (error) throw error;
    return data;
  },

  // Get every staff schedule for one week (manager+ view).
  async listSchedulesForWeek(weekStart, branchId = null) {
    let q = sb.from('schedules')
      .select('*, staff:staff_id(id, full_name, role, branch_id, employment_status)')
      .eq('week_start', weekStart);
    const { data, error } = await q;
    if (error) throw error;
    let rows = data || [];
    if (branchId) rows = rows.filter(r => r.staff?.branch_id === branchId);
    return rows;
  },

  async upsertSchedule({ staffId, weekStart, shifts, notes }) {
    const payload = {
      staff_id:   staffId,
      week_start: weekStart,
      shifts:     shifts || {},
      notes:      notes ?? null,
      updated_by: this._user?.id || null
    };
    const { data, error } = await sb.from('schedules')
      .upsert(payload, { onConflict: 'staff_id,week_start' })
      .select().single();
    if (error) throw error;
    await this.logAudit('schedule.upsert', 'schedule', data.id, {
      staff_id: staffId, week_start: weekStart
    });
    return data;
  },

  async deleteSchedule(id) {
    const { error } = await sb.from('schedules').delete().eq('id', id);
    if (error) throw error;
    await this.logAudit('schedule.delete', 'schedule', id, {});
    return true;
  },

  // ═════ STAFF (admin views) ═══════════════════════════════════
  async listStaff() {
    const { data, error } = await sb.from('staff').select('*, branches(name)').order('full_name');
    if (error) throw error;
    return data;
  },

  async updateStaffRole(staffId, newRole) {
    const { data, error } = await sb.from('staff').update({ role: newRole }).eq('id', staffId).select().single();
    if (error) throw error;
    await this.logAudit('staff.role_change', 'staff', staffId, { new_role: newRole });
    return data;
  },

  async updateStaffEmploymentStatus(staffId, newStatus, reason = null) {
    const { data, error } = await sb.from('staff')
      .update({ employment_status: newStatus })
      .eq('id', staffId).select().single();
    if (error) throw error;
    await this.logAudit('staff.status_change', 'staff', staffId, { new_status: newStatus, reason });
    return data;
  },

  async updateStaffBranch(staffId, branchId) {
    const { data, error } = await sb.from('staff')
      .update({ branch_id: branchId })
      .eq('id', staffId).select().single();
    if (error) throw error;
    await this.logAudit('staff.branch_change', 'staff', staffId, { new_branch_id: branchId });
    return data;
  },

  // Combined: role + branch (used by Staff Board drag/drop)
  async updateStaffAssignment(staffId, { role, branchId }) {
    const patch = {};
    if (role !== undefined && role !== null)     patch.role      = role;
    if (branchId !== undefined && branchId !== null) patch.branch_id = branchId;
    if (!Object.keys(patch).length) return null;
    const { data, error } = await sb.from('staff').update(patch).eq('id', staffId).select().single();
    if (error) throw error;
    await this.logAudit('staff.assignment_change', 'staff', staffId, patch);
    return data;
  },

  // ═════ ATTENDANCE ═══════════════════════════════════════════
  // Clock in. Throws if there's already an open shift for this user (DB unique index enforces).
  async clockIn(notes = null) {
    if (!this._user) throw new Error('Not logged in');
    const { data, error } = await sb.from('attendance').insert({
      staff_id: this._user.id,
      notes:    notes ?? null
    }).select().single();
    if (error) {
      // Friendly message for the unique-index collision
      if (/uniq_attendance_open_per_staff|duplicate/i.test(error.message||'')) {
        throw new Error('You already have an open shift. Clock out first.');
      }
      throw error;
    }
    await this.logAudit('attendance.clock_in', 'attendance', data.id, {});
    return data;
  },

  // Close the currently-open shift for this user. Returns null if there was none.
  async clockOut() {
    if (!this._user) throw new Error('Not logged in');
    // Find the open one
    const { data: openRows, error: findErr } = await sb.from('attendance')
      .select('*').eq('staff_id', this._user.id).is('clock_out_at', null).limit(1);
    if (findErr) throw findErr;
    if (!openRows || !openRows.length) return null;
    const row = openRows[0];
    const { data, error } = await sb.from('attendance')
      .update({ clock_out_at: new Date().toISOString() })
      .eq('id', row.id).select().single();
    if (error) throw error;
    await this.logAudit('attendance.clock_out', 'attendance', data.id, {});
    return data;
  },

  // Currently-open shift for this user (null if not clocked in).
  async getOpenShift() {
    if (!this._user) return null;
    const { data, error } = await sb.from('attendance')
      .select('*').eq('staff_id', this._user.id).is('clock_out_at', null).maybeSingle();
    if (error) throw error;
    return data;
  },

  // Last N days of attendance for this user (or a specific staffId, admin+).
  async getMyAttendance(days = 7, staffId = null) {
    const uid = staffId || this._user?.id;
    if (!uid) return [];
    const since = new Date(Date.now() - days * 86400000).toISOString();
    const { data, error } = await sb.from('attendance')
      .select('*').eq('staff_id', uid).gte('clock_in_at', since)
      .order('clock_in_at', { ascending: false });
    if (error) throw error;
    return data || [];
  },

  // Attendance summary counts for the manager dashboard: past 30 days per staff.
  async getAttendanceSummary(staffIds, days = 30) {
    if (!staffIds || !staffIds.length) return {};
    const since = new Date(Date.now() - days * 86400000).toISOString();
    const { data, error } = await sb.from('attendance')
      .select('staff_id, clock_in_at, clock_out_at')
      .in('staff_id', staffIds).gte('clock_in_at', since);
    if (error) throw error;
    const summary = {};
    staffIds.forEach(id => summary[id] = { shifts: 0, complete: 0, open: 0 });
    (data || []).forEach(r => {
      const s = summary[r.staff_id];
      if (!s) return;
      s.shifts++;
      if (r.clock_out_at) s.complete++;
      else s.open++;
    });
    return summary;
  },

  // Manager+ list attendance for a given work_date, across their branch (RLS enforced).
  async listAttendanceForDate(workDate) {
    const { data, error } = await sb.from('attendance')
      .select('*, staff:staff_id(id, full_name, role, branch_id, employment_status)')
      .eq('work_date', workDate)
      .order('clock_in_at', { ascending: false });
    if (error) throw error;
    return data || [];
  },

  // Admin-only: correct an entry (e.g. staff forgot to clock out).
  async correctAttendance(id, patch) {
    const p = { ...patch, corrected_by: this._user?.id || null, corrected_at: new Date().toISOString() };
    const { data, error } = await sb.from('attendance').update(p).eq('id', id).select().single();
    if (error) throw error;
    await this.logAudit('attendance.correct', 'attendance', id, patch);
    return data;
  },

  subscribeAttendance(callback) {
    const chan = sb.channel('attendance:all')
      .on('postgres_changes', { event: '*', schema: 'public', table: 'attendance' },
          payload => callback(payload))
      .subscribe();
    return () => sb.removeChannel(chan);
  },

  // ═════ MESSAGES ═════════════════════════════════════════════
  // Inbox: to me directly + branch broadcasts to my branch. Ordered newest first.
  async listMyMessages(limit = 50) {
    if (!this._user) return [];
    const { data, error } = await sb.from('messages')
      .select('*, from_staff:from_staff_id(id, full_name, role), to_staff:to_staff_id(id, full_name)')
      .or(`to_staff_id.eq.${this._user.id},and(to_staff_id.is.null,branch_id.eq.${this._user.branch_id || '00000000-0000-0000-0000-000000000000'})`)
      .order('created_at', { ascending: false })
      .limit(limit);
    if (error) throw error;
    return data || [];
  },

  // Sent messages (manager+ view of what they've sent).
  async listSentMessages(limit = 50) {
    if (!this._user) return [];
    const { data, error } = await sb.from('messages')
      .select('*, to_staff:to_staff_id(id, full_name)')
      .eq('from_staff_id', this._user.id)
      .order('created_at', { ascending: false })
      .limit(limit);
    if (error) throw error;
    return data || [];
  },

  // Send. If toStaffId is null, this is a branch broadcast.
  async sendMessage({ toStaffId = null, branchId = null, subject = null, body }) {
    if (!this._user) throw new Error('Not logged in');
    if (!body || !body.trim()) throw new Error('Message body cannot be empty');
    const payload = {
      from_staff_id: this._user.id,
      to_staff_id:   toStaffId,
      branch_id:     branchId || this._user.branch_id || null,
      subject:       subject || null,
      body:          body.trim()
    };
    const { data, error } = await sb.from('messages').insert(payload).select().single();
    if (error) throw error;
    await this.logAudit('message.send', 'message', data.id, {
      to_staff_id: toStaffId, broadcast: toStaffId === null
    });
    return data;
  },

  async markMessageRead(id) {
    const { data, error } = await sb.from('messages')
      .update({ read_at: new Date().toISOString() })
      .eq('id', id).is('read_at', null).select().maybeSingle();
    if (error) throw error;
    return data;
  },

  async unreadMessageCount() {
    if (!this._user) return 0;
    const { count, error } = await sb.from('messages')
      .select('id', { count: 'exact', head: true })
      .or(`to_staff_id.eq.${this._user.id},and(to_staff_id.is.null,branch_id.eq.${this._user.branch_id || '00000000-0000-0000-0000-000000000000'})`)
      .is('read_at', null);
    if (error) return 0;
    return count || 0;
  },

  subscribeMessages(callback) {
    if (!this._user) return () => {};
    const chan = sb.channel('messages:' + this._user.id)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'messages' },
          payload => callback(payload))
      .subscribe();
    return () => sb.removeChannel(chan);
  },

  // ═════ AUDIT ════════════════════════════════════════════════
  async logAudit(action, entityType, entityId, metadata = {}) {
    if (!this._user) return;
    await sb.from('audit_log').insert({
      actor_id:    this._user.id,
      actor_role:  this._user.role,
      action, entity_type: entityType, entity_id: entityId,
      metadata,
      user_agent:  navigator.userAgent
    });
  }
};

// ═════════════════════════════════════════════════════════════
// UnoSys: XSS-safe HTML escape. Wrap ANY string that came from
// user input or the DB before inserting into innerHTML. Safe on
// null / undefined / numbers.
// ═════════════════════════════════════════════════════════════
TPN.esc = function (v) {
  if (v === null || v === undefined) return '';
  const ESC_MAP = { '&':'&amp;', '<':'&lt;', '>':'&gt;', '"':'&quot;', "'":'&#39;' };
  return String(v).replace(/[&<>"']/g, c => ESC_MAP[c]);
};
// Convenience: escape for use inside JS string literals in inline onclick=""
// Only used where we cannot avoid inline handlers. Callers should prefer
// data-* attributes + addEventListener, but we retain this for legacy sites.
TPN.escAttr = function (v) {
  return TPN.esc(v).replace(/`/g, '&#96;');
};

// ═════════════════════════════════════════════════════════════
// UnoSys: Cache invalidation for branches (avoids stuck empty cache
// from a transient error on first load).
// ═════════════════════════════════════════════════════════════
TPN.invalidateBranchCache = function () { TPN._branches = null; };

// ═════════════════════════════════════════════════════════════
// UnoSys: Cross-device / cross-tab broadcast. Used to sync UI
// state (cart, current route) between tabs on the SAME browser.
// Cross-DEVICE sync for real data is handled by Supabase realtime
// on the underlying tables (orders, messages, notifications).
// Safe on browsers without BroadcastChannel: falls back to storage
// events via localStorage ping.
// ═════════════════════════════════════════════════════════════
TPN._bcChannel = (typeof BroadcastChannel !== 'undefined')
  ? new BroadcastChannel('tpn-os-sync') : null;
TPN.broadcast = function (kind, payload) {
  const msg = { kind, payload, at: Date.now(), from: TPN._user?.id || null };
  try {
    if (TPN._bcChannel) TPN._bcChannel.postMessage(msg);
    else localStorage.setItem('tpn.bcast', JSON.stringify(msg));
  } catch (e) { /* silent */ }
};
TPN.onBroadcast = function (handler) {
  if (typeof handler !== 'function') return () => {};
  if (TPN._bcChannel) {
    const fn = (ev) => { try { handler(ev.data); } catch(e){ console.warn('bc handler:', e); } };
    TPN._bcChannel.addEventListener('message', fn);
    return () => TPN._bcChannel.removeEventListener('message', fn);
  }
  const fn = (ev) => {
    if (ev.key !== 'tpn.bcast' || !ev.newValue) return;
    try { handler(JSON.parse(ev.newValue)); } catch(e){}
  };
  window.addEventListener('storage', fn);
  return () => window.removeEventListener('storage', fn);
};

// ═════════════════════════════════════════════════════════════
// UnoSys: Realtime reconnection health. Supabase realtime can
// silently drop after a laptop sleep or a phone tab suspend.
// This heartbeat re-subscribes any channel-holders when the tab
// wakes up. Consumers just need to expose a re-subscribe fn.
// ═════════════════════════════════════════════════════════════
TPN._resubHandlers = new Set();
TPN.registerResub = function (fn) {
  if (typeof fn !== 'function') return () => {};
  TPN._resubHandlers.add(fn);
  return () => TPN._resubHandlers.delete(fn);
};
TPN._runResub = function () {
  TPN._resubHandlers.forEach(fn => { try { fn(); } catch(e){ console.warn('resub:', e); } });
};
if (typeof document !== 'undefined') {
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') TPN._runResub();
  });
  window.addEventListener('online', () => TPN._runResub());
}

// ═════════════════════════════════════════════════════════════
// UnoSys: Safer active-order query. Includes all live states, plus
// completed/cancelled within the last `sinceMinutes` (default 60)
// so terminal orders don't linger forever in Live Orders lanes.
// Callers can pass sinceMinutes=null to get an unbounded window.
// ═════════════════════════════════════════════════════════════
TPN.listOrdersSince = async function (opts = {}) {
  const sinceMinutes = opts.sinceMinutes ?? 60;
  const branchId = opts.branchId ?? null;
  const cutoff = sinceMinutes == null
    ? new Date(0).toISOString()
    : new Date(Date.now() - sinceMinutes * 60000).toISOString();
  let q = sb.from('orders')
    .select('*, order_items(*), restaurant_tables(table_number)')
    .or(`status.in.(pending,confirmed,preparing,ready),placed_at.gte.${cutoff}`)
    .order('placed_at', { ascending: false })
    .limit(200);
  if (branchId) q = q.eq('branch_id', branchId);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};

// ═════════════════════════════════════════════════════════════
// UnoSys: NOTIFICATIONS
// Backed by public.notifications (sql/10-notifications.sql).
// Rows shape: { id, user_id, branch_id, kind, title, body, link,
//               entity_type, entity_id, priority, read_at,
//               created_at }
// kind values: 'order_new','order_ready','order_cancelled',
//              'inquiry_new','message_new','attendance_correction',
//              'table_signal','staff_pending','system'
// ═════════════════════════════════════════════════════════════
TPN.listNotifications = async function ({ limit = 50, includeRead = true } = {}) {
  if (!this._user) return [];
  try {
    let q = sb.from('notifications')
      .select('*')
      .order('created_at', { ascending: false })
      .limit(limit);
    if (!includeRead) q = q.is('read_at', null);
    const { data, error } = await q;
    if (error) throw error;
    return data || [];
  } catch (e) {
    console.warn('listNotifications:', e.message || e);
    return [];   // never break the UI on a fetch error
  }
};

TPN.unreadNotifCount = async function () {
  if (!this._user) return 0;
  try {
    const { count, error } = await sb.from('notifications')
      .select('id', { count: 'exact', head: true })
      .is('read_at', null);
    if (error) return 0;
    return count || 0;
  } catch (e) { return 0; }
};

TPN.markNotifRead = async function (id) {
  if (!id) return null;
  try {
    const { data, error } = await sb.from('notifications')
      .update({ read_at: new Date().toISOString() })
      .eq('id', id).is('read_at', null).select().maybeSingle();
    if (error) throw error;
    return data;
  } catch (e) { console.warn('markNotifRead:', e.message||e); return null; }
};

TPN.markAllNotifsRead = async function () {
  try {
    const { error } = await sb.from('notifications')
      .update({ read_at: new Date().toISOString() })
      .is('read_at', null);
    if (error) throw error;
    return true;
  } catch (e) { console.warn('markAllNotifsRead:', e.message||e); return false; }
};

TPN.deleteNotification = async function (id) {
  if (!id) return false;
  try {
    const { error } = await sb.from('notifications').delete().eq('id', id);
    if (error) throw error;
    return true;
  } catch (e) { console.warn('deleteNotification:', e.message||e); return false; }
};

// Insert a notification directly (for cases the DB triggers don't cover).
// Server-side rules (sql/10) still enforce who can insert to whom.
TPN.pushNotification = async function ({ userId = null, branchId = null, kind, title, body = null, link = null, entityType = null, entityId = null, priority = 'normal' }) {
  try {
    const { data, error } = await sb.from('notifications').insert({
      user_id:     userId,
      branch_id:   branchId,
      kind, title, body, link,
      entity_type: entityType,
      entity_id:   entityId,
      priority
    }).select().maybeSingle();
    if (error) throw error;
    return data;
  } catch (e) { console.warn('pushNotification:', e.message||e); return null; }
};

// Realtime subscribe. Returns unsubscribe fn. Auto-resubscribes on
// tab wake via registerResub.
TPN.subscribeNotifications = function (callback) {
  if (!this._user) return () => {};
  let chan = null;
  const build = () => {
    if (chan) { try { sb.removeChannel(chan); } catch(e){} }
    chan = sb.channel('notifications:' + TPN._user.id)
      .on('postgres_changes', {
        event: '*', schema: 'public', table: 'notifications'
      }, payload => { try { callback(payload); } catch(e){ console.warn('notif cb:', e); } })
      .subscribe();
  };
  build();
  const off = TPN.registerResub(build);
  return () => { off(); if (chan) { try { sb.removeChannel(chan); } catch(e){} } };
};

// ═════════════════════════════════════════════════════════════
// UnoSys: On sign-out, wipe user-scoped caches too, so a re-login
// as a different user on the same device doesn't leak state.
// ═════════════════════════════════════════════════════════════
const _origLogout = TPN.logout.bind(TPN);
TPN.logout = async function () {
  TPN._branches = null;
  TPN._menu     = null;
  await _origLogout();
};

// ═════════════════════════════════════════════════════════════
// UnoSys: Manager-only void order item. Server enforces role via
// void_order_item() SECURITY DEFINER fn (sql/11). Returns the
// updated item, or throws with one of these error names:
//   insufficient_privileges   (not manager+)
//   void_reason_required      (< 3 chars)
//   item_not_found
//   already_voided
//   wrong_branch
//   order_terminal            (order is completed/cancelled)
// ═════════════════════════════════════════════════════════════
TPN.voidOrderItem = async function (itemId, reason) {
  const { data, error } = await sb.rpc('void_order_item', { p_item_id: itemId, p_reason: reason });
  if (error) throw error;
  return data;
};
// ═════════════════════════════════════════════════════════════
// UnoSys: Table signal acknowledgement. Clears the call-staff and
// bill-request flags on restaurant_tables. Dining+ and, since sql/17,
// the dine_in_display screen — the surface mounted where customers
// press "Call staff" needs to be able to dismiss what it displays.
// ═════════════════════════════════════════════════════════════
TPN.ackCallStaff = async function (tableId) {
  const { error } = await sb.rpc('ack_call_staff', { p_table_id: tableId });
  if (error) throw error;
};
TPN.ackBillRequest = async function (tableId) {
  const { error } = await sb.rpc('ack_bill_request', { p_table_id: tableId });
  if (error) throw error;
};

TPN.unvoidOrderItem = async function (itemId) {
  const { data, error } = await sb.rpc('unvoid_order_item', { p_item_id: itemId });
  if (error) throw error;
  return data;
};

// ═════════════════════════════════════════════════════════════
// UnoSys: VOID REQUESTS (sql/15b)
//
// Everyone below manager — dining, kitchen, supervisor, and the two
// display-screen accounts — cannot void. They file a request instead,
// which notifies every manager+ in the branch. Approval is what
// actually performs the void, under the manager's own identity.
//
// Error names thrown by request_void:
//   no_staff_profile / account_not_active
//   void_reason_required      (< 3 chars)
//   order_not_found / item_not_found / item_order_mismatch
//   already_voided
//   request_already_pending   (one open request per item / per order)
//   wrong_branch
//   order_terminal
// ═════════════════════════════════════════════════════════════

// Pass itemId = null to request voiding the WHOLE order.
TPN.requestVoid = async function ({ orderId, itemId = null, reason }) {
  const { data, error } = await sb.rpc('request_void', {
    p_order_id: orderId,
    p_item_id:  itemId,
    p_reason:   reason
  });
  if (error) throw error;
  return data;
};

// Friendly message for any error the void-request RPCs can throw.
TPN.voidRequestErrorText = function (e) {
  const map = {
    insufficient_privileges: 'You need manager access to do that.',
    no_staff_profile:        'This login is not linked to a staff profile.',
    account_not_active:      'This account is not active. Ask a manager to validate it.',
    void_reason_required:    'Give a reason of at least 3 characters.',
    order_not_found:         'That order no longer exists.',
    item_not_found:          'That item no longer exists.',
    item_order_mismatch:     'That item does not belong to this order.',
    already_voided:          'That item is already voided.',
    request_already_pending: 'A void request for this is already waiting for a manager.',
    request_not_found:       'That request no longer exists.',
    request_not_pending:     'That request has already been handled.',
    wrong_branch:            'That order belongs to a different branch.',
    order_terminal:          'This order is already closed or cancelled.'
  };
  const key = String((e && (e.message || e.code)) || '');
  const hit = Object.keys(map).find(k => key.indexOf(k) !== -1);
  return hit ? map[hit] : ('Something went wrong: ' + (key || 'unknown error'));
};

// status: 'pending' | 'approved' | 'denied' | 'cancelled' | null (all)
TPN.listVoidRequests = async function ({ status = null, limit = 100, mineOnly = false } = {}) {
  let q = sb.from('v_void_requests').select('*').order('requested_at', { ascending: false }).limit(limit);
  if (status) q = q.eq('status', status);
  if (mineOnly && TPN._user) q = q.eq('requested_by', TPN._user.id);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};

TPN.pendingVoidRequestCount = async function () {
  const { data, error } = await sb.rpc('pending_void_request_count');
  if (error) { console.warn('pendingVoidRequestCount:', error.message); return 0; }
  return Number(data) || 0;
};

TPN.approveVoidRequest = async function (requestId, note = null) {
  const { data, error } = await sb.rpc('approve_void_request', {
    p_request_id: requestId, p_note: note
  });
  if (error) throw error;
  return data;
};

TPN.denyVoidRequest = async function (requestId, note = null) {
  const { data, error } = await sb.rpc('deny_void_request', {
    p_request_id: requestId, p_note: note
  });
  if (error) throw error;
  return data;
};

TPN.cancelVoidRequest = async function (requestId) {
  const { data, error } = await sb.rpc('cancel_void_request', { p_request_id: requestId });
  if (error) throw error;
  return data;
};

// Realtime: fires on insert/update so a manager's badge updates without
// a refresh, and the requesting screen learns the verdict immediately.
TPN.subscribeVoidRequests = function (callback) {
  const ch = sb.channel('void-requests-' + Math.random().toString(36).slice(2))
    .on('postgres_changes', { event: '*', schema: 'public', table: 'void_requests' }, callback)
    .subscribe();
  return () => sb.removeChannel(ch);
};

// ═════════════════════════════════════════════════════════════
// UnoSys: Audit log — daily/monthly rollups for the History tab.
// audit_daily_counts is manager+ only (enforced server-side).
// ═════════════════════════════════════════════════════════════
TPN.getAuditDailyCounts = async function (monthDate, branchId = null) {
  const { data, error } = await sb.rpc('audit_daily_counts', {
    p_month: monthDate, p_branch_id: branchId
  });
  if (error) throw error;
  return data || [];
};

// Full audit rows for a specific day (uses the unified view — hot + archive).
TPN.listAuditForDay = async function (day, branchId = null, limit = 500) {
  const start = new Date(day + 'T00:00:00+08:00').toISOString();
  const end   = new Date(new Date(day + 'T00:00:00+08:00').getTime() + 86400000).toISOString();
  let q = sb.from('v_audit_log_all')
    .select('*, actor:staff!audit_log_actor_id_fkey(full_name, role)')
    .gte('created_at', start).lt('created_at', end)
    .order('created_at', { ascending: false })
    .limit(limit);
  // The view can't be joined to staff via FK — do a two-step lookup instead if needed.
  const { data, error } = await sb.from('v_audit_log_all')
    .select('*')
    .gte('created_at', start).lt('created_at', end)
    .order('created_at', { ascending: false })
    .limit(limit);
  if (error) throw error;
  return data || [];
};

// ═════════════════════════════════════════════════════════════
// UnoSys: Restaurant performance report. One RPC → one JSON blob
// with all sections needed for the Performance dashboard.
// Manager+ only (enforced server-side). Returns {} on any error
// so the UI can render its empty-state without crashing.
// ═════════════════════════════════════════════════════════════
TPN.getSalesPerformanceMonth = async function (monthDate, branchId = null) {
  try {
    const { data, error } = await sb.rpc('sales_performance_month', {
      p_month: monthDate, p_branch_id: branchId
    });
    if (error) throw error;
    return data || {};
  } catch (e) {
    console.warn('getSalesPerformanceMonth:', e.message || e);
    return {};
  }
};

// Trigger the monthly archive on demand (also runnable via pg_cron).
TPN.archiveAuditLog = async function (daysToKeep = 31) {
  const { data, error } = await sb.rpc('audit_log_archive_old', { p_days_to_keep: daysToKeep });
  if (error) throw error;
  return data;
};

// ═════════════════════════════════════════════════════════════
// UnoSys: Discount templates (sql/15).
// Manager+ can create / edit / delete. Legal-locked templates
// (with a non-null legal_law) can only be deactivated, not deleted
// — RLS enforces this. requires_id templates prompt the cashier
// for a physical ID number at apply time.
// ═════════════════════════════════════════════════════════════
TPN.listDiscountTemplates = async function (activeOnly = false) {
  let q = sb.from('discount_templates').select('*').order('legal_law', { nullsFirst: false }).order('name');
  if (activeOnly) q = q.eq('is_active', true);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};
TPN.createDiscountTemplate = async function (payload) {
  const row = {
    code:          payload.code,
    name:          payload.name,
    description:   payload.description || null,
    kind:          payload.kind || 'percent',
    value:         Number(payload.value),
    requires_id:   !!payload.requires_id,
    min_subtotal:  payload.min_subtotal != null ? Number(payload.min_subtotal) : 0,
    max_discount:  payload.max_discount != null && payload.max_discount !== '' ? Number(payload.max_discount) : null,
    stackable:     payload.stackable !== false,
    is_active:     payload.is_active !== false,
    icon:          payload.icon || '💸',
    vat_treatment: payload.vat_treatment === 'net_of_vat' ? 'net_of_vat' : 'gross',
    created_by:    (TPN._user && TPN._user.id) || null
  };
  const { data, error } = await sb.from('discount_templates').insert(row).select().single();
  if (error) throw error;
  await TPN.logAudit('discount_template.create', 'discount_template', data.id, { code: data.code, name: data.name });
  return data;
};
TPN.updateDiscountTemplate = async function (id, patch) {
  const clean = {};
  ['code','name','description','kind','value','requires_id','min_subtotal','max_discount','stackable','is_active','icon','vat_treatment']
    .forEach(k => { if (patch[k] !== undefined) clean[k] = patch[k]; });
  if (clean.value != null) clean.value = Number(clean.value);
  if (clean.min_subtotal != null) clean.min_subtotal = Number(clean.min_subtotal);
  if (clean.max_discount === '' ) clean.max_discount = null;
  if (clean.max_discount != null) clean.max_discount = Number(clean.max_discount);
  const { data, error } = await sb.from('discount_templates').update(clean).eq('id', id).select().single();
  if (error) throw error;
  await TPN.logAudit('discount_template.update', 'discount_template', id, clean);
  return data;
};
TPN.deleteDiscountTemplate = async function (id) {
  const { error } = await sb.from('discount_templates').delete().eq('id', id);
  if (error) throw error;
  await TPN.logAudit('discount_template.delete', 'discount_template', id, {});
};

// ═════════════════════════════════════════════════════════════
// Applied discounts on a specific order.
// applyDiscount → apply_discount RPC (supervisor+, server-computed amount)
// removeDiscount → remove_discount RPC (manager+, soft-delete)
// Error names surfaced from the server:
//   insufficient_privileges, template_not_found, template_inactive,
//   id_ref_required, order_not_found, order_terminal,
//   below_min_subtotal, not_stackable, already_removed
// ═════════════════════════════════════════════════════════════
TPN.listAppliedDiscounts = async function (orderId, opts) {
  opts = opts || {};
  let q = sb.from('applied_discounts')
    .select('*, template:discount_templates(id, code, name, icon, legal_law)')
    .eq('order_id', orderId)
    .order('applied_at', { ascending: true });
  if (!opts.includeRemoved) q = q.is('removed_at', null);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};
TPN.applyDiscount = async function (orderId, templateId, idRef) {
  const { data, error } = await sb.rpc('apply_discount', {
    p_order_id: orderId,
    p_template_id: templateId,
    p_id_ref: idRef || null
  });
  if (error) throw error;
  return data;
};
TPN.removeDiscount = async function (appliedId, reason) {
  const { data, error } = await sb.rpc('remove_discount', {
    p_applied_id: appliedId,
    p_reason: reason || null
  });
  if (error) throw error;
  return data;
};


/* ═══════════════════════════════════════════════════════════════
   ACCESS CONTROL  (sql/19-access-control.sql)

   TPN.can('orders.cancel') is the browser-side mirror of
   private.can() in the database. It decides what the portal OFFERS.
   It is NOT the lock — every write is still gated by RLS and by the
   SECURITY DEFINER functions, so a tampered client gets a refusal
   from Postgres, not access. Hiding a button is courtesy; the
   database is the security boundary.
   ═══════════════════════════════════════════════════════════════ */

TPN._perms       = null;    // Set of permission keys, or null until loaded
TPN._permsFailed = false;   // true when we could not load them at all

TPN.loadPermissions = async function () {
  if (!this._user) { this._perms = new Set(); this._permsFailed = false; return this._perms; }
  const { data, error } = await sb.rpc('my_permissions');
  if (error) {
    // Could not determine what this person may do. Do NOT offer nothing --
    // that reads as a broken portal. Flag it and let can() fall back to the
    // tier gating this app used before migration 19. Safe, because can()
    // only decides what the UI offers; RLS is what actually refuses writes.
    console.warn('[TPN] my_permissions failed, falling back to tier gating:', error.message);
    this._perms = null;
    this._permsFailed = true;
    return null;
  }
  // rpc() on a setof-scalar returns either an array of scalars or of
  // one-key objects depending on the PostgREST version. Handle both.
  this._perms = new Set(
    (data || []).map(r => (typeof r === 'string' ? r : (r && (r.my_permissions ?? r.key))))
                .filter(Boolean)
  );
  this._permsFailed = false;
  return this._perms;
};

/* ── The degraded fallback ─────────────────────────────────────
   Used ONLY when my_permissions could not be loaded (offline, a stale
   cached bundle, an RPC error). It reproduces the tier gating this app
   shipped with before migration 19, so a transient failure looks like
   the old app rather than an empty sidebar.

   Yes, this mirrors part of the permissions catalogue, and the project
   rightly warns about mirrored lists drifting. It is tolerable here for
   one reason: nothing depends on it being correct. It decides which tabs
   to draw. Every write behind those tabs is still gated by RLS and by the
   SECURITY DEFINER functions, so if this list is too generous the user
   gets a refusal from Postgres, not access they should not have.
   ──────────────────────────────────────────────────────────── */
TPN.FALLBACK_CREW_KEYS = [
  'dashboard.view', 'orders.view', 'orders.manage',
  'kds.view', 'kds.advance', 'floor.view', 'kitchen_station.view',
  'voids.request', 'schedules.view', 'attendance.view',
  'messages.view', 'notifications.view', 'tasks.view',
  'menu.view', 'staff.view'
];
TPN.FALLBACK_ADMIN_KEYS = [
  'performance.view', 'history.view', 'audit.view',
  'roles.view', 'roles.edit', 'accounts.deactivate',
  'staff.assign', 'finance.edit', 'payroll.view', 'settings.manage'
];

TPN._fallbackCan = function (key) {
  if (key === 'payroll.edit')                     return this.hasRole('ceo');
  if (this.FALLBACK_ADMIN_KEYS.indexOf(key) !== -1) return this.hasRole('admin');
  if (this.FALLBACK_CREW_KEYS.indexOf(key) !== -1)  return this.hasRole('dining');
  return this.hasRole('manager');
};

TPN.can = function (key) {
  if (!this._user) return false;
  if (this._user.role === 'ceo') return true;      // mirrors the DB short-circuit
  if (this._permsFailed || !this._perms) return this._fallbackCan(key);
  return this._perms.has(key);
};

TPN.canAny = function (...keys) { return keys.some(k => this.can(k)); };

// ── Roles editor ─────────────────────────────────────────────
TPN.getAccessRoles = async function () {
  const { data, error } = await sb.from('access_roles')
    .select('*').order('display_order').order('label');
  if (error) throw error;
  return data || [];
};

TPN.getAccessMatrix = async function () {
  const { data, error } = await sb.rpc('access_matrix');
  if (error) throw error;
  return data || [];
};

TPN.getPermissionCatalogue = async function () {
  const { data, error } = await sb.from('permissions')
    .select('*').order('category').order('display_order');
  if (error) throw error;
  return data || [];
};

TPN.createAccessRole = async function (row) {
  const { data, error } = await sb.from('access_roles').insert({
    key:           row.key,
    label:         row.label,
    label_tl:      row.label_tl || null,
    description:   row.description || null,
    base_tier:     row.base_tier,
    color:         row.color || '#8B1A0E',
    display_order: row.display_order ?? 100,
    created_by:    this._user ? this._user.id : null
  }).select().single();
  if (error) throw error;
  return data;
};

TPN.updateAccessRole = async function (id, patch) {
  const { data, error } = await sb.from('access_roles')
    .update({ ...patch, updated_by: this._user ? this._user.id : null })
    .eq('id', id).select().single();
  if (error) throw error;
  return data;
};

TPN.deleteAccessRole = async function (id) {
  const { error } = await sb.from('access_roles').delete().eq('id', id);
  if (error) throw error;   // trg_protect_system_roles refuses the nine built-ins
};

// One cell of the matrix. Upsert so ticking a box that was never
// stored behaves the same as changing one that was.
TPN.setRolePermission = async function (roleId, permissionKey, allowed) {
  const { error } = await sb.from('access_role_permissions').upsert({
    role_id:        roleId,
    permission_key: permissionKey,
    allowed:        !!allowed,
    updated_at:     new Date().toISOString(),
    updated_by:     this._user ? this._user.id : null
  }, { onConflict: 'role_id,permission_key' });
  if (error) throw error;   // trg_arp_floor refuses grants above the role's tier
};

TPN.assignAccessRole = async function (staffId, roleId) {
  const { error } = await sb.from('staff')
    .update({ access_role_id: roleId }).eq('id', staffId);
  if (error) throw error;
};

TPN.getStaffOverrides = async function (staffId) {
  let q = sb.from('staff_permission_overrides').select('*');
  if (staffId) q = q.eq('staff_id', staffId);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};

TPN.setStaffOverride = async function (staffId, permissionKey, allowed, reason) {
  const { error } = await sb.from('staff_permission_overrides').upsert({
    staff_id:       staffId,
    permission_key: permissionKey,
    allowed:        !!allowed,
    reason:         reason || null,
    granted_by:     this._user ? this._user.id : null,
    granted_at:     new Date().toISOString()
  }, { onConflict: 'staff_id,permission_key' });
  if (error) throw error;
};

TPN.clearStaffOverride = async function (staffId, permissionKey) {
  const { error } = await sb.from('staff_permission_overrides')
    .delete().eq('staff_id', staffId).eq('permission_key', permissionKey);
  if (error) throw error;
};

// Minimal roster — readable by anyone who may assign a task, which the
// staff table itself does not permit below manager. See sql/22.
TPN.getStaffDirectory = async function () {
  const { data, error } = await sb.rpc('staff_directory');
  if (error) throw error;
  return data || [];
};


/* ═══════════════════════════════════════════════════════════════
   TASK BOARD  (sql/20-tasks.sql)
   ═══════════════════════════════════════════════════════════════ */

TPN.getTasks = async function (includeDone = false) {
  const { data, error } = await sb.rpc('task_board', { p_include_done: !!includeDone });
  if (error) throw error;
  return data || [];
};

TPN.createTask = async function (row) {
  const branchId = row.branchId || (this._user && this._user.branch_id);
  const { data, error } = await sb.from('tasks').insert({
    branch_id:   branchId,
    title:       row.title,
    description: row.description || null,
    category:    row.category || null,
    priority:    row.priority || 'normal',
    due_at:      row.dueAt || null,
    checklist:   row.checklist || [],
    created_by:  this._user ? this._user.id : null
  }).select().single();
  if (error) throw error;

  if (row.assignees && row.assignees.length) {
    await this.setTaskAssignees(data.id, row.assignees);
  }
  return data;
};

TPN.updateTask = async function (id, patch) {
  const { data, error } = await sb.from('tasks').update(patch).eq('id', id).select().single();
  if (error) throw error;
  return data;
};

TPN.deleteTask = async function (id) {
  const { error } = await sb.from('tasks').delete().eq('id', id);
  if (error) throw error;
};

// Replace the whole assignee set. Diffing keeps each person's existing
// progress instead of resetting everyone to "assigned" on every edit.
TPN.setTaskAssignees = async function (taskId, staffIds) {
  const wanted = new Set(staffIds || []);
  const { data: existing, error: readErr } = await sb.from('task_assignees')
    .select('staff_id').eq('task_id', taskId);
  if (readErr) throw readErr;
  const have = new Set((existing || []).map(r => r.staff_id));

  const toAdd    = [...wanted].filter(id => !have.has(id));
  const toRemove = [...have].filter(id => !wanted.has(id));

  if (toAdd.length) {
    const { error } = await sb.from('task_assignees').insert(
      toAdd.map(id => ({
        task_id: taskId, staff_id: id,
        assigned_by: this._user ? this._user.id : null
      }))
    );
    if (error) throw error;
  }
  if (toRemove.length) {
    const { error } = await sb.from('task_assignees')
      .delete().eq('task_id', taskId).in('staff_id', toRemove);
    if (error) throw error;
  }
};

// An assignee marking their own progress. Needs no permission — the
// function refuses anyone who is not on the task.
TPN.setMyTaskState = async function (taskId, state, note) {
  const { error } = await sb.rpc('set_my_task_state', {
    p_task: taskId, p_state: state, p_note: note || null
  });
  if (error) throw error;
};

TPN.getTaskActivity = async function (taskId) {
  const { data, error } = await sb.from('task_activity')
    .select('*, staff:actor_id(full_name)')
    .eq('task_id', taskId).order('created_at', { ascending: false });
  if (error) throw error;
  return data || [];
};

TPN.subscribeToTasks = function (onChange) {
  return sb.channel('tpn-tasks')
    .on('postgres_changes', { event: '*', schema: 'public', table: 'tasks' }, onChange)
    .on('postgres_changes', { event: '*', schema: 'public', table: 'task_assignees' }, onChange)
    .subscribe();
};


/* ═══════════════════════════════════════════════════════════════
   INVENTORY  (sql/21-inventory-and-finance.sql)
   ═══════════════════════════════════════════════════════════════ */

TPN.getInventory = async function () {
  const { data, error } = await sb.rpc('inventory_board');
  if (error) throw error;
  return data || [];
};

TPN.getSuppliers = async function () {
  const { data, error } = await sb.from('suppliers')
    .select('*').eq('is_active', true).order('name');
  if (error) throw error;
  return data || [];
};

TPN.saveSupplier = async function (row, id) {
  const payload = {
    branch_id:      row.branchId || (this._user && this._user.branch_id),
    name:           row.name,
    contact_person: row.contactPerson || null,
    phone:          row.phone || null,
    email:          row.email || null,
    address:        row.address || null,
    notes:          row.notes || null
  };
  const q = id
    ? sb.from('suppliers').update(payload).eq('id', id)
    : sb.from('suppliers').insert({ ...payload, created_by: this._user ? this._user.id : null });
  const { data, error } = await q.select().single();
  if (error) throw error;
  return data;
};

TPN.saveIngredient = async function (row, id) {
  const payload = {
    branch_id:           row.branchId || (this._user && this._user.branch_id),
    name:                row.name,
    name_tagalog:        row.nameTagalog || null,
    category:            row.category || null,
    unit:                row.unit || 'kg',
    reorder_level:       row.reorderLevel ?? 0,
    default_supplier_id: row.supplierId || null,
    notes:               row.notes || null
  };
  // current_stock is deliberately absent: it is derived from movements.
  const q = id
    ? sb.from('ingredients').update(payload).eq('id', id)
    : sb.from('ingredients').insert(payload);
  const { data, error } = await q.select().single();
  if (error) throw error;
  return data;
};

TPN.deleteIngredient = async function (id) {
  const { error } = await sb.from('ingredients').update({ is_active: false }).eq('id', id);
  if (error) throw error;
};

// The only way stock ever moves. quantity is always positive; the type
// decides the direction (see private.stock_direction).
TPN.recordStockMovement = async function (row) {
  const payload = {
    ingredient_id: row.ingredientId,
    branch_id:     row.branchId || (this._user && this._user.branch_id),
    movement_type: row.type,
    quantity:      Math.abs(Number(row.quantity)),
    unit_cost:     row.unitCost  != null && row.unitCost  !== '' ? Number(row.unitCost)  : null,
    total_cost:    row.totalCost != null && row.totalCost !== '' ? Number(row.totalCost) : null,
    supplier_id:   row.supplierId || null,
    reference:     row.reference || null,
    occurred_at:   row.occurredAt || new Date().toISOString(),
    recorded_by:   this._user ? this._user.id : null,
    notes:         row.notes || null
  };
  const { data, error } = await sb.from('stock_movements').insert(payload).select().single();
  if (error) throw error;
  return data;
};

TPN.getStockMovements = async function (ingredientId, limit = 100) {
  let q = sb.from('stock_movements')
    .select('*, ingredients(name, unit), suppliers(name), staff:recorded_by(full_name)')
    .order('occurred_at', { ascending: false }).limit(limit);
  if (ingredientId) q = q.eq('ingredient_id', ingredientId);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};


/* ═══════════════════════════════════════════════════════════════
   FINANCE  (sql/21-inventory-and-finance.sql)
   ═══════════════════════════════════════════════════════════════ */

TPN.getFinanceSummary = async function (from, to, granularity = 'day') {
  const { data, error } = await sb.rpc('finance_summary', {
    p_from: from, p_to: to, p_granularity: granularity
  });
  if (error) throw error;
  return data || [];
};

TPN.getExpenseBreakdown = async function (from, to) {
  const { data, error } = await sb.rpc('expense_breakdown', { p_from: from, p_to: to });
  if (error) throw error;
  return data || [];
};

TPN.getFinanceSettings = async function () {
  const { data, error } = await sb.from('finance_settings').select('*').limit(1).maybeSingle();
  if (error) throw error;
  return data;
};

TPN.saveFinanceSettings = async function (patch) {
  const branchId = this._user && this._user.branch_id;
  const { data, error } = await sb.from('finance_settings').upsert({
    branch_id:  branchId,
    ...patch,
    updated_at: new Date().toISOString(),
    updated_by: this._user ? this._user.id : null
  }, { onConflict: 'branch_id' }).select().single();
  if (error) throw error;
  return data;
};

TPN.getExpenses = async function (from, to) {
  let q = sb.from('operating_expenses')
    .select('*, suppliers(name), staff:recorded_by(full_name)')
    .order('incurred_on', { ascending: false });
  if (from) q = q.gte('incurred_on', from);
  if (to)   q = q.lte('incurred_on', to);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};

TPN.saveExpense = async function (row, id) {
  const payload = {
    branch_id:   row.branchId || (this._user && this._user.branch_id),
    category:    row.category || 'other',
    label:       row.label,
    amount:      Number(row.amount),
    incurred_on: row.incurredOn,
    supplier_id: row.supplierId || null,
    reference:   row.reference || null,
    notes:       row.notes || null
  };
  const q = id
    ? sb.from('operating_expenses').update(payload).eq('id', id)
    : sb.from('operating_expenses').insert({ ...payload, recorded_by: this._user ? this._user.id : null });
  const { data, error } = await q.select().single();
  if (error) throw error;
  return data;
};

TPN.deleteExpense = async function (id) {
  const { error } = await sb.from('operating_expenses').delete().eq('id', id);
  if (error) throw error;
};

// Pay rates are history, not current state: a change closes the old row
// and opens a new one, so a report about last month uses last month's rate.
TPN.getCompensation = async function (staffId) {
  let q = sb.from('staff_compensation')
    .select('*, staff:staff_id(full_name, role)')
    .order('effective_from', { ascending: false });
  if (staffId) q = q.eq('staff_id', staffId);
  const { data, error } = await q;
  if (error) throw error;
  return data || [];
};

TPN.setCompensation = async function (row) {
  const today = new Date().toISOString().slice(0, 10);
  const from  = row.effectiveFrom || today;

  // Close any open rate that starts before the new one.
  const { error: closeErr } = await sb.from('staff_compensation')
    .update({ effective_to: from })
    .eq('staff_id', row.staffId)
    .is('effective_to', null)
    .lt('effective_from', from);
  if (closeErr) throw closeErr;

  const { data, error } = await sb.from('staff_compensation').insert({
    staff_id:       row.staffId,
    pay_type:       row.payType || 'monthly',
    rate:           Number(row.rate),
    allowance:      Number(row.allowance || 0),
    effective_from: from,
    notes:          row.notes || null,
    created_by:     this._user ? this._user.id : null
  }).select().single();
  if (error) throw error;
  return data;
};


/* ═══════════════════════════════════════════════════════════════
   PAYROLL  (sql/25-payroll.sql)

   A pay run is a SNAPSHOT. Rates, days and hours are copied onto the
   lines when it is built, so what somebody was paid in July does not
   change because their rate changed in August. Once a run is marked
   paid its lines are frozen by trigger -- reverse it, never edit it.

   Two permissions, deliberately separate:
     payroll.run   build a period, approve it, record it paid  (admin+)
     payroll.edit  change what a person is paid                (CEO only)
   A director can run payroll without being able to give a raise.
   ═══════════════════════════════════════════════════════════════ */

TPN.getPayrollRuns = async function () {
  const { data, error } = await sb.from('payroll_runs')
    .select('*').order('period_start', { ascending: false });
  if (error) throw error;
  return data || [];
};

TPN.getPayrollItems = async function (runId) {
  const { data, error } = await sb.from('payroll_items')
    .select('*').eq('run_id', runId).order('staff_name');
  if (error) throw error;
  return data || [];
};

TPN.buildPayrollRun = async function (periodStart, periodEnd) {
  const { data, error } = await sb.rpc('build_payroll_run', {
    p_period_start: periodStart, p_period_end: periodEnd
  });
  if (error) throw new Error(TPN.prettyPayrollError(error.message));
  return data;
};

TPN.rebuildPayrollRun = async function (runId) {
  const { data, error } = await sb.rpc('rebuild_payroll_run', { p_run: runId });
  if (error) throw new Error(TPN.prettyPayrollError(error.message));
  return data;
};

TPN.setPayrollStatus = async function (runId, status, method) {
  const { error } = await sb.rpc('set_payroll_status', {
    p_run: runId, p_status: status, p_method: method || null
  });
  if (error) throw new Error(TPN.prettyPayrollError(error.message));
};

// Edit one line before approval — an adjustment, a deduction, a note.
TPN.updatePayrollItem = async function (id, patch) {
  const gross = Number(patch.gross ?? 0);
  const ded   = Number(patch.deductions ?? 0);
  const { error } = await sb.from('payroll_items').update({
    gross, deductions: ded, net: Math.max(0, gross - ded),
    note: patch.note ?? null
  }).eq('id', id);
  if (error) throw new Error(TPN.prettyPayrollError(error.message));
};

TPN.deletePayrollRun = async function (runId) {
  const { error } = await sb.from('payroll_runs').delete().eq('id', runId);
  if (error) throw new Error(TPN.prettyPayrollError(error.message));
};

TPN.prettyPayrollError = function (msg) {
  msg = msg || 'Payroll action failed';
  if (/nobody_to_pay/.test(msg))
    return 'Nobody to pay in that period — no active staff, and nobody clocked in.';
  if (/approve_before_marking_paid/.test(msg))
    return 'Approve the run before recording it as paid.';
  if (/only_a_draft_can_be_approved/.test(msg))
    return 'Only a draft can be approved.';
  if (/only_a_paid_run_can_be_reversed/.test(msg))
    return 'Only a paid run can be reversed.';
  if (/only_a_draft_can_be_recalculated/.test(msg))
    return 'Only a draft can be recalculated. Reverse the run first.';
  if (/payroll_run_locked/.test(msg))
    return 'This run is already paid, so its lines are locked. Reverse it if something was wrong.';
  if (/bad_period/.test(msg))       return 'The end date must be on or after the start date.';
  if (/permission_denied/.test(msg))return 'You do not have permission to run payroll.';
  if (/row-level security/i.test(msg)) return 'You do not have permission to do that.';
  return msg;
};

// Restore session on load
sb.auth.onAuthStateChange((event) => {
  if (event === 'SIGNED_IN' || event === 'INITIAL_SESSION') {
    TPN.loadProfile().then(() => TPN.loadPermissions()).catch(() => {});
  }
  if (event === 'SIGNED_OUT') {
    TPN._user = null; TPN._branches = null; TPN._menu = null;
    TPN._perms = null; TPN._permsFailed = false;
  }
});

// Expose globals
window.TPN = TPN;
window.sb  = sb;
