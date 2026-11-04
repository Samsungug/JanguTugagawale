-- 3.3% daily compounding, seven offered capitals, 30-day terms, and a minimum NET payout of UGX 7,000.
-- Preserve existing accounts, reviewed transactions, referral identities, and earnings accrued before the change.
-- Historical package IDs remain unchanged. No stored member or transaction records are backfilled.
begin;

create table if not exists public.jtg_compound_policy (
  id integer primary key check (id=1),
  effective_at timestamptz not null default clock_timestamp()
);
alter table public.jtg_compound_policy enable row level security;
-- Private policy metadata is read only by security-definer financial routines.
revoke all on public.jtg_compound_policy from public,anon,authenticated;

do $copy$
begin
  if to_regprocedure('public.jtg_earning_state_legacy(uuid,timestamptz)') is null then
    execute replace(pg_get_functiondef('public.jtg_earning_state(uuid,timestamptz)'::regprocedure),
      'public.jtg_earning_state(', 'public.jtg_earning_state_legacy(');
  end if;
end;
$copy$;
revoke all on function public.jtg_earning_state_legacy(uuid,timestamptz) from public,anon,authenticated;
insert into public.jtg_compound_policy(id) values (1) on conflict do nothing;

create or replace function public.jtg_package_terms(p_package_id integer)
returns table(package_id integer,name text,price bigint,daily bigint)
language sql immutable set search_path='public' as $f$
  select v.id,v.name,v.price,(v.price*0.033)::bigint from (values
    (0,'Vitz',15000::bigint),(1,'Passo',30000::bigint),(2,'Sienta',50000::bigint),
    (3,'Premio',100000::bigint),(5,'Harrier',200000::bigint),(8,'Prado',500000::bigint),
    (13,'Lexus LX',1000000::bigint)) v(id,name,price) where v.id=p_package_id;
$f$;
create or replace function public.jtg_package_duration(p_package_id integer)
returns integer language sql immutable set search_path='public' as $f$ select 30; $f$;

-- Credits use original approval anniversaries. Day 30 is credited, then accrual stops.
-- Existing earnings are frozen at the transition; only later credits use 3.3%.
-- Shared earnings are weighted by active capital so multiple packages cannot compound the same base repeatedly.
create or replace function public.jtg_earning_state(p_user_id uuid,p_as_of timestamptz)
returns jsonb language plpgsql stable security definer set search_path='public' as $f$
declare
  v_cut timestamptz; v_seed jsonb; v_products jsonb:='{}';
  v_balance numeric:=0; v_daily numeric:=0; v_bonus numeric:=0; v_paid numeric:=0; v_held numeric:=0;
  v_capital numeric:=0; v_active numeric:=0; v_due numeric; v_profit numeric; v_part numeric; v_left numeric;
  v_count integer; v_initial numeric; r record; e record; d record;
begin
  select effective_at into v_cut from public.jtg_compound_policy where id=1;
  if p_as_of<=v_cut then return public.jtg_earning_state_legacy(p_user_id,p_as_of); end if;
  v_seed:=public.jtg_earning_state_legacy(p_user_id,v_cut);
  v_balance:=coalesce((v_seed->'wallet'->>'accountBalance')::numeric,0);
  v_daily:=coalesce((v_seed->'wallet'->>'dailyEarned')::numeric,0);
  v_bonus:=coalesce((v_seed->'wallet'->>'referralBonuses')::numeric,0);
  v_paid:=coalesce((v_seed->'wallet'->>'approvedWithdrawals')::numeric,0);
  for r in select p.*,pay.price as capital from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id
    where p.user_id=p_user_id and p.approved_at<=p_as_of order by p.approved_at,p.id loop
    v_initial:=coalesce((v_seed->'products'->r.id::text->>'earned')::numeric,0);
    v_products:=jsonb_set(v_products,array[r.id::text],jsonb_build_object('earned',v_initial,'capital',r.capital,'daily_gross',0));
    v_capital:=v_capital+r.capital;
  end loop;
  for e in
    select t,sum(bonus) as bonus,sum(paid) as paid,bool_or(credit) as credit from (
      select c.credited_at as t,c.amount as bonus,0::numeric as paid,false as credit from public.jtg_referral_credits c
        where c.user_id=p_user_id and c.credited_at>v_cut and c.credited_at<=p_as_of
      union all
      select coalesce(w.reviewed_at,w.submitted_at),0::numeric,w.amount::numeric,false from public.jtg_withdrawals w
        where w.user_id=p_user_id and w.status='Approved' and coalesce(w.reviewed_at,w.submitted_at)>v_cut and coalesce(w.reviewed_at,w.submitted_at)<=p_as_of
      union all
      select g.t,0::numeric,0::numeric,true from public.jtg_products p
        cross join lateral generate_series(p.approved_at+interval '24 hours',
          least(p_as_of,p.approved_at+interval '720 hours',coalesce(p.expired_at-interval '1 microsecond',p_as_of)),interval '24 hours') g(t)
        where p.user_id=p_user_id and g.t>v_cut
    ) events group by t order by t
  loop
    v_balance:=v_balance+e.bonus-e.paid; v_bonus:=v_bonus+e.bonus; v_paid:=v_paid+e.paid;
    if e.credit then
      select coalesce(sum(pay.price),0) into v_active from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id
        where p.user_id=p_user_id and p.approved_at<=e.t and p.approved_at+interval '720 hours'>=e.t and (p.expired_at is null or p.expired_at>e.t);
      select coalesce(sum(pay.price),0),count(*) into v_due,v_count from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id
        where p.user_id=p_user_id and p.approved_at+interval '720 hours'>=e.t and (p.expired_at is null or p.expired_at>e.t)
          and e.t>p.approved_at and mod(extract(epoch from (e.t-p.approved_at)),86400)=0;
      if v_active>0 and v_due>0 then
        v_profit:=round((v_due+greatest(v_balance,0)*v_due/v_active)*0.033,2); v_left:=v_profit;
        for d in select p.id,pay.price from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id
          where p.user_id=p_user_id and p.approved_at+interval '720 hours'>=e.t and (p.expired_at is null or p.expired_at>e.t)
            and e.t>p.approved_at and mod(extract(epoch from (e.t-p.approved_at)),86400)=0 order by p.id loop
          v_part:=case when v_count=1 then v_left else round(v_profit*d.price/v_due,2) end;
          v_products:=jsonb_set(v_products,array[d.id::text,'earned'],to_jsonb((v_products->d.id::text->>'earned')::numeric+v_part));
          v_products:=jsonb_set(v_products,array[d.id::text,'daily_gross'],to_jsonb(v_part));
          v_left:=v_left-v_part; v_count:=v_count-1;
        end loop;
        v_balance:=v_balance+v_profit; v_daily:=v_daily+v_profit;
      end if;
    end if;
  end loop;
  select coalesce(sum(amount),0) into v_held from public.jtg_withdrawals where user_id=p_user_id and status='Pending' and archived_at is null;
  select coalesce(sum(pay.price),0) into v_active from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id
    where p.user_id=p_user_id and p.approved_at<=p_as_of and p.approved_at+interval '720 hours'>p_as_of and (p.expired_at is null or p.expired_at>p_as_of);
  v_profit:=case when v_active>0 then round((v_active+greatest(v_balance,0))*0.033,2) else 0 end;
  return jsonb_build_object('products',v_products,'wallet',jsonb_build_object(
    'capitalInvested',v_capital,'activeCapital',v_active,'dailyEarned',v_daily,'referralBonuses',v_bonus,
    'totalEarned',v_daily+v_bonus,'approvedWithdrawals',v_paid,'pendingWithdrawals',v_held,
    'accountBalance',v_balance,'availableBalance',v_balance-v_held,
    'dailyGross',v_profit,'dailyNet',v_profit-round(v_profit*0.15,2),
    'totalGross',v_balance,'charge',round(greatest(v_balance,0)*0.15,2),'net',v_balance-round(greatest(v_balance,0)*0.15,2),
    'availableNet',(v_balance-v_held)-round(greatest(v_balance-v_held,0)*0.15,2),'dailyRate',0.033,'termDays',30));
end;
$f$;
revoke all on function public.jtg_earning_state(uuid,timestamptz) from public,anon,authenticated;

create or replace function public.jtg_financial_snapshot()
returns jsonb language plpgsql stable security definer set search_path='public' as $f$
declare v_user uuid:=public.jtg_require_member(); v_admin boolean:=public.jtg_is_admin(); v_wallets jsonb:='{}'; v_states jsonb:='{}'; r record; v_state jsonb;
begin
  for r in select user_id from public.jtg_member_accounts where v_admin or user_id=v_user loop
    v_state:=public.jtg_earning_state(r.user_id,now());
    v_wallets:=jsonb_set(v_wallets,array[r.user_id::text],v_state->'wallet'); v_states:=v_states||(v_state->'products');
  end loop;
  return jsonb_build_object('serverTime',now(),
    'payments',coalesce((select jsonb_agg(to_jsonb(p) order by p.submitted_at) from public.jtg_payments p where (v_admin or p.user_id=v_user) and p.archived_at is null),'[]'::jsonb),
    'products',coalesce((select jsonb_agg(to_jsonb(p)||jsonb_build_object(
      'capital',pay.price,'earned',coalesce((v_states->p.id::text->>'earned')::numeric,0),
      'daily_gross',coalesce((v_states->p.id::text->>'daily_gross')::numeric,0),
      'daily_net',coalesce((v_states->p.id::text->>'daily_gross')::numeric,0)-round(coalesce((v_states->p.id::text->>'daily_gross')::numeric,0)*0.15,2),
      'completed_days',least(30,greatest(0,floor(extract(epoch from (least(now(),coalesce(p.expired_at,now()))-p.approved_at))/86400))),
      'status',case when p.expired_at is not null or now()>=p.approved_at+interval '720 hours' then 'Package Expired' else 'Active' end,
      'next_credit_at',case when p.expired_at is null and now()<p.approved_at+interval '720 hours' then p.approved_at+(floor(extract(epoch from (now()-p.approved_at))/86400)+1)*interval '24 hours' end
    ) order by p.approved_at) from public.jtg_products p join public.jtg_payments pay on pay.id=p.payment_id where v_admin or p.user_id=v_user),'[]'::jsonb),
    'withdrawals',coalesce((select jsonb_agg(to_jsonb(w)||jsonb_build_object(
      'charge',case when w.status='Pending' then round(w.amount*0.15,2) else coalesce(w.charge,w.tax) end,
      'net_to_pay',case when w.status='Pending' then w.amount-round(w.amount*0.15,2) else coalesce(w.net_to_pay,w.net) end,
      'charge_percent',case when w.status='Pending' or w.charge is not null then 15 else w.tax_percent end
    ) order by w.submitted_at) from public.jtg_withdrawals w where (v_admin or w.user_id=v_user) and w.archived_at is null),'[]'::jsonb),
    'wallets',v_wallets,'referralCredits',coalesce((select jsonb_agg(to_jsonb(c) order by c.credited_at) from public.jtg_referral_credits c where v_admin or c.user_id=v_user),'[]'::jsonb));
end;
$f$;

create or replace function public.jtg_withdrawal_limits()
returns jsonb language plpgsql stable security definer set search_path='public' as $f$
declare v_user uuid:=public.jtg_require_member(); v_start timestamptz:=date_trunc('day',now() at time zone 'Africa/Kampala') at time zone 'Africa/Kampala'; v_end timestamptz:=v_start+interval '1 day'; v_count integer;
begin
  select count(*)::integer into v_count from public.jtg_withdrawals where user_id=v_user and submitted_at>=v_start and submitted_at<v_end;
  return jsonb_build_object('minimumAmount',8236,'minimumNet',7000,'dailyLimit',2,'submittedToday',v_count,'remainingToday',greatest(0,2-v_count),'resetsAt',v_end,'timeZone','Africa/Kampala');
end;
$f$;
create or replace function public.jtg_request_withdrawal(p_amount bigint,p_network text,p_phone text,p_name text)
returns uuid language plpgsql security definer set search_path='public' as $f$
declare v_user uuid:=public.jtg_require_member(); v_id uuid; v_limits jsonb; v_wallet jsonb; v_charge numeric; v_net numeric;
begin
  perform pg_advisory_xact_lock(hashtextextended(v_user::text,0));
  v_charge:=round(p_amount*0.15,2); v_net:=p_amount-v_charge;
  if p_amount is null or p_amount<=0 or v_net<7000 then raise exception 'Minimum withdrawal net is 7,000 UGX after the 15%% charge. Request at least 8,236 UGX.'; end if;
  if p_network is null or p_network not in ('MTN','Airtel') or p_phone is null or p_phone!~'^0[37][0-9]{8}$' or p_name is null or char_length(trim(p_name)) not between 1 and 80 then raise exception 'Enter valid mobile money details.'; end if;
  v_limits:=public.jtg_withdrawal_limits();
  if (v_limits->>'remainingToday')::integer=0 then raise exception 'Only two withdrawal requests are allowed per Uganda day.'; end if;
  v_wallet:=public.jtg_wallet(v_user);
  if (v_wallet->>'availableNet')::numeric<7000 then raise exception 'Minimum withdrawal net is 7,000 UGX after the 15%% charge.'; end if;
  if p_amount>(v_wallet->>'availableBalance')::numeric then raise exception 'Amount exceeds your available Daily Earnings Balance. Capital is not withdrawable.'; end if;
  insert into public.jtg_withdrawals(user_id,amount,network,phone,name,charge,net_to_pay,charge_percent)
    values(v_user,p_amount,p_network,p_phone,trim(p_name),v_charge,v_net,15) returning id into v_id;
  return v_id;
end;
$f$;

-- Change approval metadata only; the 5% inviter and 2.5% invitee referral bonuses are retained.
do $approval$
begin
  execute replace(pg_get_functiondef('public.jtg_decide_payment(uuid,text)'::regprocedure),'r.price*0.025','r.price*0.033');
end;
$approval$;

-- Installation checks are non-mutating.
do $checks$
begin
  if (select count(*) from generate_series(0,14) i cross join lateral public.jtg_package_terms(i))<>7 then
    raise exception 'Expected seven offered capital amounts.';
  end if;
  if 8235-round(8235*0.15,2)>=7000 or 8236-round(8236*0.15,2)<7000 then
    raise exception 'Minimum net withdrawal boundary is inconsistent.';
  end if;
  if has_function_privilege('anon','public.jtg_earning_state_legacy(uuid,timestamptz)','execute') then
    raise exception 'Historical replay must remain private.';
  end if;
end;
$checks$;
commit;
