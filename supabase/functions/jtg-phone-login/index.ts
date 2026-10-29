import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';
import { corsHeaders } from '../_shared/cors.ts';

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response(null, { headers: corsHeaders });
  const reply = (body: unknown, status = 200) => new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
  if (req.method !== 'POST') return reply({ error: 'Method not allowed.' }, 405);

  // Limit the entire backend login sequence, not each individual service call.
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 24000);
  const boundedFetch: typeof fetch = (input, options) => fetch(input, {
    ...options, signal: controller.signal,
  });
  try {
    let payload: { phone?: unknown; password?: unknown };
    try {
      if (Number(req.headers.get('content-length') || 0) > 4096) {
        return reply({ error: 'Login request is too large.' }, 400);
      }
      const raw = await req.text();
      if (raw.length > 4096) return reply({ error: 'Login request is too large.' }, 400);
      const parsed = JSON.parse(raw);
      if (!parsed || typeof parsed !== 'object' || Array.isArray(parsed)) {
        return reply({ error: 'Enter your phone number and password.' }, 400);
      }
      payload = parsed;
    } catch {
      return reply({ error: 'Enter your phone number and password.' }, 400);
    }
    const password = payload.password;
    // Accept local and international Ugandan numbers; never normalize passwords.
    let phone = typeof payload.phone === 'string' && payload.phone.length <= 32
      ? payload.phone.trim().replace(/[\s()-]/g, '').replace(/^\+/, '') : '';
    if (phone.startsWith('00256')) phone = '0' + phone.slice(5);
    else if (phone.startsWith('256')) phone = '0' + phone.slice(3);
    if (!/^0[37]\d{8}$/.test(phone) || typeof password !== 'string' || password.length < 6 || password.length > 256) {
      return reply({ error: 'Phone number or password is incorrect.' }, 400);
    }

    const url = Deno.env.get('SUPABASE_URL') ?? '';
    const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';
    const anonKey = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
    if (!url || !serviceKey || !anonKey) {
      console.error('JTG login: account service configuration is incomplete');
      return reply({ error: 'Login service is temporarily unavailable. Please try again.' }, 503);
    }
    const admin = createClient(url, serviceKey, {
      global: { fetch: boundedFetch },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data: member, error: memberError } = await admin.from('jtg_member_accounts')
      .select('user_id, banned').eq('phone', phone).maybeSingle();
    if (memberError) throw memberError;
    if (!member) {
      return reply({ error: 'Phone number or password is incorrect. If you are new, complete account creation and tick I agree first.' }, 401);
    }

    // Read the current identity so returning login also works after an email change.
    const { data: identity, error: identityError } = await admin.auth.admin.getUserById(member.user_id);
    if (identityError) throw identityError;
    if (!identity.user?.email || !identity.user.email_confirmed_at) {
      return reply({ error: 'Complete email verification before logging in.' }, 401);
    }
    const authClient = createClient(url, anonKey, {
      global: { fetch: boundedFetch },
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const { data, error } = await authClient.auth.signInWithPassword({ email: identity.user.email, password });
    if (error || !data.session) {
      if (error?.status === 429) return reply({ error: 'Too many attempts. Please wait before trying again.' }, 429);
      if (controller.signal.aborted || (error && (!error.status || error.status >= 500))) {
        console.error('JTG login: authentication service unavailable');
        return reply({ error: 'Login service is temporarily unavailable. Please try again.' }, 503);
      }
      return reply({ error: 'Phone number or password is incorrect.' }, 401);
    }

    const revokeSession = async () => {
      const { error: logoutError } = await authClient.auth.signOut({ scope: 'local' });
      if (logoutError) console.error('JTG login: rejected-session revocation failed');
    };
    // Password authentication must resolve to the member owning the phone number.
    if (data.session.user.id !== member.user_id) {
      await revokeSession();
      return reply({ error: 'Phone number or password is incorrect.' }, 401);
    }
    // Re-read restrictions after authentication in case the administrator just banned this member.
    const { data: latestMember, error: latestError } = await admin.from('jtg_member_accounts')
      .select('banned').eq('user_id', member.user_id).maybeSingle();
    if (latestError || !latestMember) {
      await revokeSession();
      console.error('JTG login: current account access could not be verified');
      return reply({ error: 'Account access could not be verified. Please try again.' }, 503);
    }
    if (latestMember.banned) {
      await revokeSession();
      return reply({ error: 'You have been banned contact admin' }, 403);
    }

    // The owner-only role check uses the authenticated JWT, never a submitted role or password match.
    const { data: isAdmin, error: roleError } = await authClient.rpc('jtg_is_admin');
    if (roleError || typeof isAdmin !== 'boolean') {
      await revokeSession();
      console.error('JTG login: account permissions could not be verified');
      return reply({ error: 'Account permissions could not be verified. Please try again.' }, 503);
    }
    return reply({
      access_token: data.session.access_token,
      refresh_token: data.session.refresh_token,
      is_admin: isAdmin,
    });
  } catch {
    // Do not log credentials, request bodies, phone numbers, or authentication tokens.
    console.error(controller.signal.aborted ? 'JTG login: service deadline exceeded' : 'JTG login: account service request failed');
    return reply({ error: 'Login service is temporarily unavailable. Please try again.' }, 503);
  } finally {
    clearTimeout(timeout);
  }
});
