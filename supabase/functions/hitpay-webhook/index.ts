// hitpay-webhook — HitPay tells us a payment request completed or failed.
//
// Deploy with verify_jwt = false (HitPay sends no Supabase token); the
// HMAC signature is the authentication instead:
//   Hitpay-Signature = hex(HMAC-SHA256(salt, raw request body))
// Register this URL in HitPay → Developers → Webhook Endpoints with the
// payment_request.completed event.
//
// Nothing else marks an online payment as paid. Not the redirect, not
// the browser, not staff.
import { cors, json, env, serviceClient, hmacHex, safeEqual } from '../_shared/hitpay.ts'

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors })
  if (req.method !== 'POST') return json({ error: 'Method not allowed' }, 405)

  const raw = await req.text()
  const sig = (req.headers.get('Hitpay-Signature') ?? '').trim().toLowerCase()
  let expected = ''
  try { expected = await hmacHex(env('HITPAY_SALT'), raw) } catch (e) {
    console.error('hitpay-webhook: salt missing'); return json({ error: 'not configured' }, 503)
  }
  if (!sig || !safeEqual(sig, expected)) {
    console.warn('hitpay-webhook: bad signature')
    return json({ error: 'bad signature' }, 401)
  }

  let p: any
  try { p = JSON.parse(raw) } catch { return json({ error: 'bad payload' }, 400) }
  const pay = Array.isArray(p.payments) && p.payments.length ? p.payments[p.payments.length - 1] : {}

  const { data, error } = await serviceClient().rpc('hitpay_complete', {
    p_request_id: String(p.id ?? p.payment_request_id ?? ''),
    p_status: String(p.status ?? pay.status ?? ''),
    p_amount: Number(p.amount ?? pay.amount),
    p_currency: String(p.currency ?? pay.currency ?? ''),
    p_provider_payment_id: pay.id ? String(pay.id) : null,
    p_provider_method: pay.payment_type ? String(pay.payment_type) : null,
    p_payload: p,
  })
  if (error) {
    console.error('hitpay-webhook rpc', error.message)
    // 500 makes HitPay retry later, which is what we want for a DB hiccup.
    return json({ error: 'temporary' }, 500)
  }
  return json({ received: true, result: data })
})
