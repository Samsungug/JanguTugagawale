import { corsHeaders } from '../_shared/cors.ts';

// Native HTTP avoids loading a remote SDK before a public login can start.
// Passwords are checked by Auth; no account, role, or credential is fabricated here.
Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
  if (req.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);

  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 22000);
  let stage = 'validation';
  try {
    let payload: { phone?: unknown; password?: unknown };
    try {
      if (Number(req.headers.get('content-length') || 0) > 4096) {
        return reply({ error: 'Login request is too large.' }, 400);
      }
      const raw = await req.text();
      if (raw.length > 4096) return reply({ error: 'Login request is too large.' }, 400);
      const value = JSON.parse(raw);
      if (!value || typeof value !== 'object' || Array.isArray(value)) throw new Error();
      payload = value;
    } catch {
      return reply({ error: 'Enter your phone number and password.' }, 400);
    }
    let phone = typeof payload.phone === 'string' && payload.phone.length <= 32
      ? payload.phone.trim().replace(/[\s()-]/g, '').replace(/^\+/, '') : '';
    if (phone.startsWith('00256')) phone = '0' + phone.slice(5);
    else if (phone.startsWith('256')) phone = '0' + phone.slice(3);
    const password = payload.password;
    if (!/^0[37]\d{8}$/.test(phone) || typeof password !== 'string' || password.length < 6 || password.length > 256) {
      return reply({ error: 'Phone number or password is incorrect.' }, 400);
    }

    const url = (Deno.env.get('SUPABASE_URL') || '').replace(/\/$/, '');
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') || '';
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') || '';
    if (!url || !serviceKey || !anonKey) {
      console.error('JTG login: missing service configuration');
      return reply({ error: 'Account services are temporarily unavailable. Please try again.' }, 503);
    }
    const request = async (path: string, key: string, method = 'GET', body?: unknown, token = key) => {
      const response = await fetch(url + path, {
        method, signal: controller.signal,
        headers: { apikey: key, Authorization: 'Bearer ' + token, 'Content-Type': 'application/json' },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await response.text();
      let data: any = null;
      if (text) { try { data = JSON.parse(text); } catch { throw new Error('Unexpected service response'); } }
      return { ok: response.ok, status: response.status, data };
    };
    const unavailable = () => reply({ error: 'Account services are temporarily unavailable. Please try again. You can also use your registered email in Login help.' }, 503);

    stage = 'member lookup';
    const memberResult = await request('/rest/v1/jtg_member_accounts?select=user_id&phone=eq.' + encodeURIComponent(phone) + '&limit=1', serviceKey);
    if (!memberResult.ok || !Array.isArray(memberResult.data)) return unavailable();
    const member = memberResult.data[0];
    if (!member) return reply({ error: 'Phone number or password is incorrect. New members must finish account creation and confirm I agree.' }, 401);

    stage = 'identity lookup';
    const identity = await request('/auth/v1/admin/users/' + encodeURIComponent(member.user_id), serviceKey);
    if (!identity.ok) return unavailable();
    const user = identity.data?.user || identity.data;
    if (!user?.email || !user.email_confirmed_at) return reply({ error: 'Complete email verification before logging in.' }, 401);

    stage = 'password verification';
    const credentials = await request('/auth/v1/token?grant_type=password', anonKey, 'POST', { email: user.email, password });
    if (!credentials.ok || !credentials.data?.access_token || !credentials.data?.refresh_token) {
      if (credentials.status === 429) return reply({ error: 'Too many login attempts. Please wait before trying again.' }, 429);
      if (credentials.status >= 500) return unavailable();
      return reply({ error: 'Phone number or password is incorrect. Use Forgot password if you cannot remember your password.' }, 401);
    }
    const signed = credentials.data;
    const revoke = async () => {
      try { await request('/auth/v1/logout?scope=local', anonKey, 'POST', undefined, signed.access_token); }
      catch { console.error('JTG login: rejected session revocation unavailable'); }
    };
    if (signed.user?.id !== member.user_id) {
      await revoke();
      return reply({ error: 'Phone number or password is incorrect.' }, 401);
    }

    stage = 'account permissions';
    const [latest, role] = await Promise.all([
      request('/rest/v1/jtg_member_accounts?select=banned,consent_at,adult_confirmed&user_id=eq.' + encodeURIComponent(member.user_id) + '&limit=1', serviceKey),
      request('/rest/v1/rpc/jtg_is_admin', anonKey, 'POST', {}, signed.access_token),
    ]);
    const account = Array.isArray(latest.data) ? latest.data[0] : null;
    if (!latest.ok || !account || !role.ok || typeof role.data !== 'boolean') {
      await revoke();
      return unavailable();
    }
    if (account.banned) {
      await revoke();
      return reply({ error: 'You have been banned contact admin' }, 403);
    }
    if (!account.consent_at || !account.adult_confirmed) {
      await revoke();
      return reply({ error: 'Finish your account details and consent before logging in.' }, 403);
    }
    return reply({ access_token: signed.access_token, refresh_token: signed.refresh_token, is_admin: role.data });
  } catch {
    // Log only the operation stage, never passwords, email addresses, phones, or tokens.
    console.error('JTG login: ' + stage + (controller.signal.aborted ? ' timed out' : ' unavailable'));
    return reply({ error: controller.signal.aborted
      ? 'Login took too long. Try again, or enter your registered email in Login help.'
      : 'Unable to connect to account services. Try again, or enter your registered email in Login help.' }, controller.signal.aborted ? 504 : 503);
  } finally {
    clearTimeout(timeout);
  }
});
