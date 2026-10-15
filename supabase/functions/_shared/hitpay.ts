// Shared HitPay + Supabase helpers for the hitpay-* edge functions.
//
// Secrets (Supabase → Edge Functions → Secrets). Never put these in
// config.js or any page:
//   HITPAY_API_KEY   business API key (sandbox or live)
//   HITPAY_SALT      webhook salt from the HitPay dashboard
//   HITPAY_MODE      'sandbox' (default) or 'live'
//   SITE_URL         e.g. https://unorfl.github.io/tpn-os/  (where customers return)
//   HITPAY_METHODS   optional, comma list passed as payment_methods[];
//                    leave unset to offer every method enabled on the account
import { createClient, SupabaseClient } from 'https://esm.sh/@supabase/supabase-js@2.117.2'

export const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
}

export function json(data: unknown, status = 200) {
  return new Response(JSON.stringify(data), { status, headers: { ...cors, 'Content-Type': 'application/json' } })
}

export function env(name: string, fallback?: string): string {
  const v = Deno.env.get(name) ?? fallback
  if (v === undefined || v === '') throw new Error(`Missing secret ${name}`)
  return v
}

export function hitpayBase(): string {
  return (Deno.env.get('HITPAY_MODE') ?? 'sandbox') === 'live'
    ? 'https://api.hit-pay.com/v1'
    : 'https://api.sandbox.hit-pay.com/v1'
}

export function serviceClient(): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_SERVICE_ROLE_KEY'), {
    auth: { autoRefreshToken: false, persistSession: false },
  })
}

// A client acting as the caller, so RLS and private.can() apply to them.
export function userClient(authHeader: string): SupabaseClient {
  return createClient(env('SUPABASE_URL'), env('SUPABASE_ANON_KEY'), {
    global: { headers: { Authorization: authHeader } },
    auth: { autoRefreshToken: false, persistSession: false },
  })
}

export async function hitpayPost(path: string, form: Record<string, string | string[]>) {
  const body = new URLSearchParams()
  for (const [k, v] of Object.entries(form)) {
    if (Array.isArray(v)) v.forEach(x => body.append(k + '[]', x))
    else body.append(k, v)
  }
  const res = await fetch(hitpayBase() + path, {
    method: 'POST',
    headers: {
      'X-BUSINESS-API-KEY': env('HITPAY_API_KEY'),
      'X-Requested-With': 'XMLHttpRequest',
      'Content-Type': 'application/x-www-form-urlencoded',
    },
    body,
    signal: AbortSignal.timeout(15000),
  })
  const text = await res.text()
  let data: any = null
  try { data = JSON.parse(text) } catch { data = { raw: text } }
  if (!res.ok) throw new Error(`HitPay ${res.status}: ${(data && (data.message || JSON.stringify(data.errors || data))) || text}`.slice(0, 400))
  return data
}

// HMAC-SHA256 of the RAW request body with the salt, hex-encoded.
export async function hmacHex(secret: string, message: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', new TextEncoder().encode(secret),
    { name: 'HMAC', hash: 'SHA-256' }, false, ['sign'])
  const sig = await crypto.subtle.sign('HMAC', key, new TextEncoder().encode(message))
  return [...new Uint8Array(sig)].map(b => b.toString(16).padStart(2, '0')).join('')
}

export function safeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false
  let r = 0
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i)
  return r === 0
}

// Turn a Postgres error into something a guest or cashier can act on.
export function friendly(msg: string): string {
  if (/nothing_due/.test(msg)) return 'This bill is already fully paid.'
  if (/order_not_found/.test(msg)) return 'We could not find that order. Please ask our staff.'
  if (/order_cancelled/.test(msg)) return 'This order was cancelled.'
  if (/permission_denied/.test(msg)) return 'Your account cannot take payments.'
  if (/Missing secret/.test(msg)) return 'Online payment is not set up yet. Please pay at the counter.'
  return msg
}
