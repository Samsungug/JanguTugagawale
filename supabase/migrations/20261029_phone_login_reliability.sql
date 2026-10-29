-- phone login reliability: password-checked identity resolution without an edge-function dependency
-- existing member accounts, passwords, admin roles, packages, and financial records are preserved
create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

create table if not exists public.jtg_login_attempts (
  id bigint generated always as identity primary key,
  phone_key text not null,
  ip_key text not null,
  attempted_at timestamptz not null default clock_timestamp()
);
alter table public.jtg_login_attempts enable row level security;
-- no client policies: security metadata is accessible only inside the owner-controlled resolver
revoke all on public.jtg_login_attempts from public, anon, authenticated;
revoke all on sequence public.jtg_login_attempts_id_seq from public, anon, authenticated;
create index if not exists jtg_login_attempts_phone_time on public.jtg_login_attempts (phone_key, attempted_at);
create index if not exists jtg_login_attempts_ip_time on public.jtg_login_attempts (ip_key, attempted_at);
comment on table public.jtg_login_attempts is 'Private throttling metadata. No plaintext phone numbers, emails, passwords, or tokens are stored.';

create or replace function public.jtg_login_identity(p_phone text, p_password text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
  v_phone text;
  v_headers jsonb;
  v_ip text;
  v_phone_key text;
  v_ip_key text;
  v_cutoff timestamptz := clock_timestamp() - interval '5 minutes';
  v_ids uuid[];
  v_id uuid;
  v_email text;
  v_hash text;
  v_candidate text;
  v_verified boolean;
  v_banned boolean;
  v_consent boolean;
  v_auth_banned_until timestamptz;
  v_pending boolean := false;
  v_failure jsonb := jsonb_build_object('ok', false, 'code', 'invalid_credentials', 'error', 'Phone number or password is incorrect. Use your original registered details. If you have not completed registration, select Create Account.');
begin
  if p_phone is null or length(p_phone)>32 or p_password is null or length(p_password)<6 or length(p_password)>256 then
    return v_failure;
  end if;
  v_phone := regexp_replace(trim(p_phone), '[[:space:]()+-]', '', 'g');
  if left(v_phone,5)='00256' then v_phone := '0'||substr(v_phone,6);
  elsif left(v_phone,3)='256' then v_phone := '0'||substr(v_phone,4);
  end if;
  if v_phone !~ '^0[37][0-9]{8}$' then return v_failure; end if;

  begin
    v_headers := coalesce(nullif(current_setting('request.headers',true),''),'{}')::jsonb;
  exception when others then
    v_headers := '{}'::jsonb;
  end;
  v_ip := left(trim(split_part(coalesce(v_headers->>'x-real-ip',v_headers->>'x-forwarded-for','unknown'),',',1)),128);
  v_phone_key := encode(extensions.digest('jtg-phone:'||v_phone,'sha256'),'hex');
  v_ip_key := encode(extensions.digest('jtg-ip:'||v_ip,'sha256'),'hex');
  -- serialize concurrent attempts so request limits cannot be bypassed by parallel calls
  perform pg_advisory_xact_lock(hashtextextended('jtg-phone:'||v_phone_key,0));
  perform pg_advisory_xact_lock(hashtextextended('jtg-ip:'||v_ip_key,0));
  if (select count(*) from public.jtg_login_attempts where phone_key=v_phone_key and attempted_at>=v_cutoff)>=12
    or (v_ip<>'unknown' and (select count(*) from public.jtg_login_attempts where ip_key=v_ip_key and attempted_at>=v_cutoff)>=120) then
    -- return rather than raise: failed logins must not roll back committed attempt counts
    return jsonb_build_object('ok',false,'code','login_rate_limited','retry_after',300,'error','Too many login attempts. Wait five minutes, then try your registered details again.');
  end if;
  insert into public.jtg_login_attempts(phone_key,ip_key) values(v_phone_key,v_ip_key);

  select a.user_id, a.banned, (a.consent_at is not null and a.adult_confirmed)
    into v_id,v_banned,v_consent
    from public.jtg_member_accounts a where a.phone=v_phone;
  if v_id is null then
    -- resume only a unique verified, password-bearing signup; never create or approve an account here
    select array_agg(u.id) into v_ids from auth.users u
    where u.email_confirmed_at is not null
      and coalesce(u.encrypted_password,'')<>''
      and regexp_replace(coalesce(u.raw_user_meta_data->>'jtg_phone',''),'[^0-9]','','g') in (v_phone,'256'||substr(v_phone,2),'00256'||substr(v_phone,2))
      and not exists(select 1 from public.jtg_member_accounts a where a.user_id=u.id);
    if cardinality(v_ids)=1 then v_id:=v_ids[1]; v_pending:=true; end if;
  end if;
  if v_id is not null then
    select u.email, u.encrypted_password, u.email_confirmed_at is not null, u.banned_until
      into v_email,v_hash,v_verified,v_auth_banned_until
      from auth.users u where u.id=v_id;
  end if;
  -- unknown phones still perform bcrypt work; no email is returned without a matching password
  v_candidate := extensions.crypt(p_password,case when coalesce(v_hash,'') ~ '^\$2[aby]\$' then v_hash else extensions.gen_salt('bf',10) end);
  if v_id is null or v_hash is null or v_candidate is distinct from v_hash or v_verified is not true or coalesce(v_email,'')='' then
    return v_failure;
  end if;
  if v_banned is true or v_auth_banned_until>clock_timestamp() then
    return jsonb_build_object('ok',false,'code','account_banned','error','You have been banned contact admin');
  end if;
  if not v_pending and v_consent is not true then
    return jsonb_build_object('ok',false,'code','setup_required','error','Finish your account details and consent before logging in.');
  end if;
  -- no JWT or role is issued by this resolver: Auth still verifies credentials and creates the session
  return jsonb_build_object('ok',true,'email',v_email,'pending_setup',v_pending);
end;
$function$;
revoke all on function public.jtg_login_identity(text,text) from public;
grant execute on function public.jtg_login_identity(text,text) to anon;
grant execute on function public.jtg_login_identity(text,text) to authenticated;
grant execute on function public.jtg_login_identity(text,text) to service_role;
comment on function public.jtg_login_identity(text,text) is 'Throttled password-checked phone identity resolution. Does not create users, change passwords, grant roles, or issue sessions; Auth issues all JWTs.';
notify pgrst, 'reload schema';
