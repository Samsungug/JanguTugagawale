-- Admin-controlled expiry for package wallets and dashboard snapshots.
-- Preserve existing earnings, accounts, payments, withdrawals and referral rewards.
-- No stored user records are changed; future credits stop only after explicit admin expiry.
begin;
create table if not exists public.jtg_manual_expiry_policy (
 id integer primary key check (id=1),
 effective_at timestamptz not null default clock_timestamp()
);
alter table public.jtg_manual_expiry_policy enable row level security;
revoke all on public.jtg_manual_expiry_policy from public,anon,authenticated;
do $copy$
begin
 if to_regprocedure('public.jtg_earning_state_before_manual_expiry(uuid,timestamptz)') is null then
  execute replace(pg_get_functiondef('public.jtg_earning_state(uuid,timestamptz)'::regprocedure),
   'public.jtg_earning_state(', 'public.jtg_earning_state_before_manual_expiry(');
 end if;
end;
$copy$;
revoke all on function public.jtg_earning_state_before_manual_expiry(uuid,timestamptz) from public,anon,authenticated;
insert into public.jtg_manual_expiry_policy(id) values(1) on conflict do nothing;
-- Seed from the exact prior balance; retain original 24-hour approval anniversaries.
do $manual$
declare v_definition text;
begin
 v_definition:=pg_get_functiondef('public.jtg_earning_state_before_manual_expiry(uuid,timestamptz)'::regprocedure);
 if position('public.jtg_daily_rate_policy' in v_definition)=0
  or position('public.jtg_earning_state_before_ten(' in v_definition)=0
  or position('''dailyRate'',0.10,''termDays'',30' in v_definition)=0 then
  raise exception 'Previous earnings policy could not be verified.';
 end if;
 v_definition:=replace(v_definition,'public.jtg_earning_state_before_manual_expiry(', 'public.jtg_earning_state(');
 v_definition:=replace(v_definition,'public.jtg_daily_rate_policy','public.jtg_manual_expiry_policy');
 v_definition:=replace(v_definition,'public.jtg_earning_state_before_ten(', 'public.jtg_earning_state_before_manual_expiry(');
 v_definition:=replace(v_definition,
  'least(p_as_of,p.approved_at+interval ''720 hours'',coalesce(p.expired_at-interval ''1 microsecond'',p_as_of))',
  'least(p_as_of,coalesce(p.expired_at-interval ''1 microsecond'',p_as_of))');
 v_definition:=replace(v_definition,'p.approved_at+interval ''720 hours''>=e.t and ','');
 v_definition:=replace(v_definition,'p.approved_at+interval ''720 hours''>p_as_of and ','');
 v_definition:=replace(v_definition,'''dailyRate'',0.10,''termDays'',30','''dailyRate'',0.10,''expiryMode'',''manual''');
 v_definition:=replace(v_definition,'''daily_gross'',0)',
  '''daily_gross'',coalesce((v_seed->''products''->r.id::text->>''daily_gross'')::numeric,0))');
 if position('720 hours' in v_definition)>0 then
  raise exception 'Automatic expiry must not remain in the active earnings policy.';
 end if;
 execute v_definition;
end;
$manual$;
revoke all on function public.jtg_earning_state(uuid,timestamptz) from public,anon,authenticated;

-- Members receive only package status, not expiry timestamps, countdowns or term limits.
create or replace function public.jtg_financial_snapshot()
returns jsonb language plpgsql stable security definer set search_path='public' as $f$
declare v_user uuid:=public.jtg_require_member(); v_admin boolean:=public.jtg_is_admin(); v_wallets jsonb:='{}'; v_states jsonb:='{}'; r record; v_state jsonb;
begin
 for r in select user_id from public.jtg_member_accounts where v_admin or user_id=v_user loop
  v_state:=public.jtg_earning_state(r.user_id,now());
  v_wallets:=jsonb_set(v_wallets,array[r.user_id::text],v_state->'wallet');
  v_states:=v_states||(v_state->'products');
 end loop;
 return jsonb_build_object('serverTime',now(),
 'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.submitted_at) from public.jtg_payments p where (v_admin or p.user_id=v_user) and p.archived_at is null),'[]'::jsonb),
 'products',coalesce((select jsonb_agg(
  (to_jsonb(p)-'expired_at'-'expired_by')
  ||case when v_admin then jsonb_build_object('expired_at',p.expired_at,'expired_by',p.expired_by) else '{}'::jsonb end
  ||jsonb_build_object(
   'capital',pay.price,'earned',coalesce((v_states->p.id::text->>'earned')::numeric,0),
   'daily_gross',coalesce((v_states->p.id::text->>'daily_gross')::numeric,0),
   'daily_net',coalesce((v_states->p.id::text->>'daily_gross')::numeric,0)-round(coalesce((v_states->p.id::text->>'daily_gross')::numeric,0)*0.15,2),
   'status',case when p.expired_at is not null then 'Package Expired' else 'Active' end
  ) order by p.approved_at)
  from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id where v_admin or p.user_id=v_user),'[]'::jsonb),
 'withdrawals',coalesce((select jsonb_agg(to_jsonb(w)||jsonb_build_object(
  'charge',case when w.status='Pending' then round(w.amount*0.15,2) else coalesce(w.charge,w.tax) end,
  'net_to_pay',case when w.status='Pending' then w.amount-round(w.amount*0.15,2) else coalesce(w.net_to_pay,w.net) end,
  'charge_percent',case when w.status='Pending' or w.charge is not null then 15 else w.tax_percent end
 ) order by w.submitted_at) from public.jtg_withdrawals w where (v_admin or w.user_id=v_user) and w.archived_at is null),'[]'::jsonb),
 'wallets',v_wallets,'referralCredits',coalesce((select jsonb_agg(to_jsonb(c) order by c.credited_at) from public.jtg_referral_credits c where v_admin or c.user_id=v_user),'[]'::jsonb));
end;
$f$;

do $checks$
begin
 if position('''expiryMode'',''manual''' in pg_get_functiondef('public.jtg_earning_state(uuid,timestamptz)'::regprocedure))=0 then
  raise exception 'Manual expiry contract is missing.';
 end if;
 if position('720 hours' in pg_get_functiondef('public.jtg_financial_snapshot()'::regprocedure))>0 then
  raise exception 'Automatic snapshot expiry must be removed.';
 end if;
 if has_function_privilege('anon','public.jtg_earning_state_before_manual_expiry(uuid,timestamptz)','execute')
  or has_function_privilege('authenticated','public.jtg_earning_state_before_manual_expiry(uuid,timestamptz)','execute') then
  raise exception 'Historical earnings replay must remain private.';
 end if;
 if position('if not public.jtg_is_admin()' in pg_get_functiondef('public.jtg_expire_product(uuid)'::regprocedure))=0 then
  raise exception 'Only the administrator may expire a package.';
 end if;
end;
$checks$;
commit;
