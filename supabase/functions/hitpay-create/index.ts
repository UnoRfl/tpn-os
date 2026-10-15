// hitpay-create — start an online payment for an order.
//
// Customer (QR menu / website): { order_number, track_token }  — the
//   private token from checkout proves the order is theirs.
// Staff (portal / POS):         { order_id }  with their session token;
//   needs the payments.take permission.
//
// The amount is ALWAYS what the database says is due (hitpay_begin);
// nothing from the browser decides it. Returns { checkout_url }.
import { cors, json, env, serviceClient, userClient, hitpayPost, friendly } from '../_shared/hitpay.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  try {
    const body = await req.json().catch(() => ({}))
    const admin = serviceClient()
    let begin: any

    if (body.order_id) {
      const auth = req.headers.get('Authorization') ?? ''
      const user = userClient(auth)
      const { data: u } = await user.auth.getUser()
      if (!u?.user) return json({ error: 'Please sign in again.' }, 401)
      const { data: perms, error: pe } = await user.rpc('my_permissions')
      if (pe) return json({ error: friendly(pe.message) }, 403)
      if (!(perms ?? []).includes('payments.take')) return json({ error: friendly('permission_denied') }, 403)
      const { data, error } = await admin.rpc('hitpay_begin', { p_order_id: body.order_id, p_actor: u.user.id })
      if (error) return json({ error: friendly(error.message) }, 400)
      begin = data
    } else {
      if (typeof body.order_number !== 'string' || typeof body.track_token !== 'string') {
        return json({ error: 'order_number and track_token are required' }, 400)
      }
      const { data, error } = await admin.rpc('hitpay_begin', {
        p_order_number: body.order_number.slice(0, 64), p_token: body.track_token,
      })
      if (error) return json({ error: friendly(error.message) }, 400)
      begin = data
    }

    if (begin.reused && begin.checkout_url) return json({ checkout_url: begin.checkout_url, amount: begin.amount })

    const site = env('SITE_URL', 'https://unorfl.github.io/tpn-os/')
    const back = new URL(body.return_path === 'table' ? 'tpn-table-menu' : '', site)
    back.searchParams.set('paid', begin.order_number)
    if (body.return_query && typeof body.return_query === 'string') {
      for (const [k, v] of new URLSearchParams(body.return_query.slice(0, 200))) if (/^(branch|table)$/.test(k)) back.searchParams.set(k, v)
    }

    const form: Record<string, string | string[]> = {
      amount: Number(begin.amount).toFixed(2),
      currency: 'PHP',
      reference_number: begin.payment_id,            // our payments.id
      redirect_url: back.toString(),
      purpose: `Tyo Paeng Nyo order ${begin.order_number}`.slice(0, 100),
    }
    if (begin.customer_name) form.name = String(begin.customer_name).slice(0, 60)
    const methods = (Deno.env.get('HITPAY_METHODS') ?? '').split(',').map(s => s.trim()).filter(Boolean)
    if (methods.length) form.payment_methods = methods

    const pr = await hitpayPost('/payment-requests', form)
    if (!pr?.id || !pr?.url) return json({ error: 'HitPay did not return a checkout link.' }, 502)
    await admin.rpc('hitpay_attach', { p_payment_id: begin.payment_id, p_request_id: pr.id, p_url: pr.url })
    return json({ checkout_url: pr.url, amount: begin.amount })
  } catch (e) {
    console.error('hitpay-create', e)
    return json({ error: friendly((e as Error).message) }, 500)
  }
})
