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

// Init client
const sb = window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY, {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: false }
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

  hasRole(minRole) {
    if (!this._user) return false;
    const H = ['dining','kitchen','supervisor','manager','admin','director','ceo'];
    return H.indexOf(this._user.role) >= H.indexOf(minRole);
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
  async createOrder(opts) {
    const subtotal = opts.items.reduce((s, i) => s + (i.unit_price * i.quantity), 0);
    const total = subtotal;  // extend with service charge / discount later

    const { data: order, error: orderErr } = await sb.from('orders').insert({
      branch_id:        opts.branchId,
      table_id:         opts.tableId ?? null,
      order_type:       opts.orderType,
      customer_name:    opts.customerName ?? null,
      customer_phone:   opts.customerPhone ?? null,
      subtotal, total,
      payment_method:   opts.paymentMethod ?? null,
      notes:            opts.notes ?? null,
      delivery_address: opts.deliveryAddress ?? null,
      scheduled_for:    opts.scheduledFor ?? null
    }).select().single();
    if (orderErr) throw orderErr;

    const rows = opts.items.map(i => ({
      order_id:        order.id,
      menu_item_id:    i.menu_item_id,
      name_snapshot:   i.name,
      price_snapshot:  i.unit_price,
      quantity:        i.quantity,
      pax_size:        i.pax_size ?? null,
      unit_price:      i.unit_price,
      total_price:     i.unit_price * i.quantity,
      notes:           i.notes ?? null
    }));
    const { error: itemsErr } = await sb.from('order_items').insert(rows);
    if (itemsErr) {
      // rollback
      await sb.from('orders').delete().eq('id', order.id);
      throw itemsErr;
    }
    return order;
  },

  async getOrder(id) {
    const { data, error } = await sb.from('orders')
      .select('*, order_items(*), restaurant_tables(*)').eq('id', id).single();
    if (error) throw error;
    return data;
  },

  // Look up an order by its human-readable order_number (TPN-LP-YYYYMMDD-0001).
  // Used by the public "Track My Order" input — anonymous users can hit this
  // thanks to the orders_anon_read RLS policy.
  async getOrderByNumber(orderNumber) {
    const { data, error } = await sb.from('orders')
      .select('*, order_items(*), restaurant_tables(table_number)')
      .eq('order_number', orderNumber)
      .maybeSingle();
    if (error) throw error;
    return data;
  },

  // Realtime subscription filtered to a single order (used by customer's
  // QR-menu progress bar so the "your food is ready" toast is real, not simulated).
  subscribeToOrder(orderId, callback) {
    const chan = sb.channel(`order:${orderId}`)
      .on('postgres_changes', {
        event: 'UPDATE', schema: 'public', table: 'orders',
        filter: `id=eq.${orderId}`
      }, payload => callback(payload))
      .subscribe();
    return () => sb.removeChannel(chan);
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
TPN.unvoidOrderItem = async function (itemId) {
  const { data, error } = await sb.rpc('unvoid_order_item', { p_item_id: itemId });
  if (error) throw error;
  return data;
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

// Trigger the monthly archive on demand (also runnable via pg_cron).
TPN.archiveAuditLog = async function (daysToKeep = 31) {
  const { data, error } = await sb.rpc('audit_log_archive_old', { p_days_to_keep: daysToKeep });
  if (error) throw error;
  return data;
};

// Restore session on load
sb.auth.onAuthStateChange((event) => {
  if (event === 'SIGNED_IN' || event === 'INITIAL_SESSION') TPN.loadProfile();
  if (event === 'SIGNED_OUT') { TPN._user = null; TPN._branches = null; TPN._menu = null; }
});

// Expose globals
window.TPN = TPN;
window.sb  = sb;
