// ═══════════════════════════════════════════════════════════════
// create-staff Edge Function
//
// Called from the TPN staff portal when an admin clicks "+ Add Staff".
// Validates that the caller is authenticated AND has manager+ role,
// then uses service_role to create the user. Public signups are
// disabled in Supabase Auth settings, so this is the ONLY path to
// account creation.
//
// Deploy: Supabase Dashboard → Edge Functions → New function
//         name: create-staff  → paste this file → Deploy
// ═══════════════════════════════════════════════════════════════

import { createClient } from 'https://esm.sh/@supabase/supabase-js@2'

const corsHeaders = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

// MUST match the staff_role enum order in Postgres
// (sql/01-schema.sql + sql/15a-display-roles.sql).
// kitchen_display / dine_in_display are shared device logins for the wall
// screens. They sit at the BOTTOM so every private.has_role() check fails
// for them — no voiding, no menu edits, no staff records.
const ROLE_HIERARCHY = [
  'kitchen_display','dine_in_display',
  'dining','kitchen','supervisor','manager','admin','director','ceo'
]

const DISPLAY_ROLES = ['kitchen_display','dine_in_display']

function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json' }
  })
}

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') {
    return new Response('ok', { headers: corsHeaders })
  }
  if (req.method !== 'POST') {
    return json({ error: 'Method not allowed' }, 405)
  }

  try {
    // ── Step 1: Identify the caller and verify they are an admin ──
    const authHeader = req.headers.get('Authorization')
    if (!authHeader) return json({ error: 'Missing Authorization header' }, 401)

    const supabaseUrl = Deno.env.get('SUPABASE_URL')!
    const anonKey    = Deno.env.get('SUPABASE_ANON_KEY')!
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!

    const userClient = createClient(supabaseUrl, anonKey, {
      global: { headers: { Authorization: authHeader } }
    })

    const { data: userData, error: userErr } = await userClient.auth.getUser()
    if (userErr || !userData?.user) {
      return json({ error: 'Not authenticated' }, 401)
    }
    const callerId = userData.user.id

    // Look up caller's role from staff table
    const { data: callerRow, error: roleErr } = await userClient
      .from('staff')
      .select('role')
      .eq('id', callerId)
      .single()
    if (roleErr || !callerRow) {
      return json({ error: 'No staff profile for caller' }, 403)
    }
    const callerLevel = ROLE_HIERARCHY.indexOf(callerRow.role)
    if (callerLevel < ROLE_HIERARCHY.indexOf('manager')) {
      return json({ error: 'Insufficient permissions to create accounts' }, 403)
    }

    // ── Step 2: Read and validate the request body ──
    const body = await req.json().catch(() => ({}))
    const { email, password, name, phone, role, branch_code } = body

    if (!email || !password || !name || !role) {
      return json({ error: 'Missing required fields: email, password, name, role' }, 400)
    }
    if (typeof password !== 'string' || password.length < 6) {
      return json({ error: 'Password must be at least 6 characters' }, 400)
    }
    if (!ROLE_HIERARCHY.includes(role)) {
      return json({ error: `Invalid role: ${role}` }, 400)
    }
    // Callers can only grant roles at or below their own level
    const grantedLevel = ROLE_HIERARCHY.indexOf(role)
    if (grantedLevel > callerLevel) {
      return json({ error: `You can only grant roles at or below your own level` }, 403)
    }

    // Display screens are infrastructure, not staff. They are set up once,
    // they are shared logins that never change password, and they must be
    // usable the instant they're created (a wall screen can't "wait for
    // validation"). So: admin+ only, and they skip the pending workflow.
    const isDisplay = DISPLAY_ROLES.includes(role)
    if (isDisplay && callerLevel < ROLE_HIERARCHY.indexOf('admin')) {
      return json({ error: 'Only admin, director, or CEO can create a display device account.' }, 403)
    }

    // ── Step 3: Use service_role to create the user ──
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { autoRefreshToken: false, persistSession: false }
    })

    const { data: created, error: createErr } = await admin.auth.admin.createUser({
      email,
      password,
      email_confirm: true,           // no email verification needed
      user_metadata: { full_name: name, phone: phone || null }
    })
    if (createErr) {
      return json({ error: createErr.message }, 400)
    }
    if (!created?.user?.id) {
      return json({ error: 'User created but no ID returned' }, 500)
    }

    // The handle_new_user trigger already inserted a staff row with role='dining' and employment_status='active'.
    // Now update it with the correct role, branch, and profile fields.
    // Business rule: accounts created BY a manager start as 'pending' and need CEO/admin/director validation.
    // Accounts created BY an admin+ (admin, director, ceo) are already trusted → 'active'.
    // Display accounts are always created by admin+ (checked above), so they
    // are always 'active'.
    const initialStatus = callerLevel >= ROLE_HIERARCHY.indexOf('admin') ? 'active' : 'pending';

    let branchId: string | null = null
    if (branch_code) {
      const { data: branch } = await admin
        .from('branches')
        .select('id')
        .eq('code', branch_code)
        .single()
      branchId = branch?.id ?? null
    }

    const { error: updErr } = await admin
      .from('staff')
      .update({
        full_name: name,
        phone: phone || null,
        role,
        branch_id: branchId,
        employment_status: initialStatus
      })
      .eq('id', created.user.id)

    if (updErr) {
      // Try to clean up the auth user so we don't leave an orphan
      await admin.auth.admin.deleteUser(created.user.id)
      return json({ error: 'Failed to set staff role: ' + updErr.message }, 500)
    }

    // Log the action (best-effort, non-fatal if it fails)
    await admin.from('audit_log').insert({
      actor_id: callerId,
      actor_role: callerRow.role,
      action: 'staff.create',
      entity_type: 'staff',
      entity_id: created.user.id,
      metadata: { email, role, branch_code: branch_code || null, initial_status: initialStatus, created_by_edge_fn: true }
    }).select().maybeSingle()

    return json({
      ok: true,
      user_id: created.user.id,
      initial_status: initialStatus,
      is_display: isDisplay,
      // Where this account should be pointed once it signs in.
      display_home: role === 'kitchen_display' ? 'tpn-kitchen-station'
                  : role === 'dine_in_display' ? 'tpn-dine-in-floor'
                  : null
    })
  } catch (e) {
    console.error('create-staff error:', e)
    return json({ error: (e as Error).message || 'Unknown error' }, 500)
  }
})
