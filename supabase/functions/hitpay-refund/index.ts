// hitpay-refund — refund all or part of an online payment.
// Body: { payment_id, amount, reason }  with a manager's session token.
// refund_check() runs AS the caller, so the payments.refund permission,
// branch and remaining-balance rules all apply before HitPay is called.
import { cors, json, serviceClient, userClient, hitpayPost, friendly } from '../_shared/hitpay.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)
  try {
    const { payment_id, amount, reason } = await req.json().catch(() => ({}))
    if (!payment_id || !(Number(amount) > 0)) return json({ error: 'payment_id and amount are required' }, 400)
    if (typeof reason !== 'string' || reason.trim().length < 3) return json({ error: 'Please give a reason.' }, 400)

    const user = userClient(req.headers.get('Authorization') ?? '')
    const { data: chk, error } = await user.rpc('refund_check', { p_payment_id: payment_id, p_amount: Number(amount) })
    if (error) return json({ error: friendly(error.message) }, 403)
    if (chk.method !== 'hitpay' || !chk.provider_payment_id) return json({ error: 'Not an online payment.' }, 400)

    const r = await hitpayPost('/refund', { payment_id: chk.provider_payment_id, amount: Number(amount).toFixed(2) })
    const { data: state, error: e2 } = await serviceClient().rpc('hitpay_refund_recorded', {
      p_payment_id: payment_id, p_amount: Number(amount), p_reason: reason.trim().slice(0, 500),
      p_actor: chk.actor, p_provider_ref: String(r?.id ?? ''), p_payload: r,
    })
    if (e2) {
      // HitPay refunded but our record failed: say so loudly; staff must
      // not refund twice.
      console.error('hitpay-refund record failed', e2.message)
      return json({ error: 'HitPay accepted the refund, but saving it failed. Do NOT refund again — tell the manager.', hitpay_refund_id: r?.id }, 500)
    }
    return json({ ok: true, payment_status: state, hitpay_refund_id: r?.id })
  } catch (e) {
    console.error('hitpay-refund', e)
    return json({ error: friendly((e as Error).message) }, 500)
  }
})
