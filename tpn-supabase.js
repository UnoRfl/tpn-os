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
      .select('*, staff:staff(id, full_name, role, branch_id, employment_status)')
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

// Restore session on load
sb.auth.onAuthStateChange((event) => {
  if (event === 'SIGNED_IN' || event === 'INITIAL_SESSION') TPN.loadProfile();
  if (event === 'SIGNED_OUT') TPN._user = null;
});

// Expose globals
window.TPN = TPN;
window.sb  = sb;
