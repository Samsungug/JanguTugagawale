-- Eight offered packages, including UGX 150,000, with a new 10% daily earning rate.
-- Preserve account records, earned funds, referral credits, and all existing requests.
-- Historical data cleanup is intentionally not performed by this migration.
begin;
create table if not exists public.jtg_daily_rate_policy (
  id integer primary key check (id=1),
  effective_at timestamptz not null default clock_timestamp()
);
alter table public.jtg_daily_rate_policy enable row level security;
-- Private policy metadata is accessible only through server-authorized routines.
revoke all on public.jtg_daily_rate_policy from public,anon,authenticated;
do $copy$
begin
  if to_regprocedure('public.jtg_earning_state_before_ten(uuid,timestamptz)') is null then
    execute replace(pg_get_functiondef('public.jtg_earning_state(uuid,timestamptz)'::regprocedure),
      'public.jtg_earning_state(', 'public.jtg_earning_state_before_ten(');
  end if;
end;
$copy$;
revoke all on function public.jtg_earning_state_before_ten(uuid,timestamptz) from public,anon,authenticated;
insert into public.jtg_daily_rate_policy(id) values(1) on conflict do nothing;
-- Seed the new policy from the exact pre-change balance; original approval anniversaries and terms are retained.
do $rate$
declare v_definition text;
begin
  v_definition:=pg_get_functiondef('public.jtg_earning_state_before_ten(uuid,timestamptz)'::regprocedure);
  if position('public.jtg_compound_policy' in v_definition)=0
    or position('0.033' in v_definition)=0
    or position('public.jtg_earning_state_legacy(' in v_definition)=0 then
    raise exception 'Previous earnings policy could not be verified.';
  end if;
  v_definition:=replace(v_definition,'public.jtg_earning_state_before_ten(', 'public.jtg_earning_state(');
  v_definition:=replace(v_definition,'public.jtg_compound_policy','public.jtg_daily_rate_policy');
  v_definition:=replace(v_definition,'public.jtg_earning_state_legacy(', 'public.jtg_earning_state_before_ten(');
  v_definition:=replace(v_definition,'0.033','0.10');
  execute v_definition;
end;
$rate$;
revoke all on function public.jtg_earning_state(uuid,timestamptz) from public,anon,authenticated;
create or replace function public.jtg_package_terms(p_package_id integer)
returns table(package_id integer,name text,price bigint,daily bigint)
language sql immutable set search_path='public' as $f$
  select v.id,v.name,v.price,(v.price*0.10)::bigint from (values
    (0,'Vitz',15000::bigint),(1,'Passo',30000::bigint),(2,'Sienta',50000::bigint),
    (3,'Premio',100000::bigint),(4,'Wish',150000::bigint),(5,'Harrier',200000::bigint),
    (8,'Prado',500000::bigint),(13,'Lexus LX',1000000::bigint)
  ) v(id,name,price) where v.id=p_package_id;
$f$;
-- Target only daily metadata; never change one-time 5% inviter and 2.5% invitee rewards.
do $approval$
declare v_definition text:=pg_get_functiondef('public.jtg_decide_payment(uuid,text)'::regprocedure);
begin
  if position('greatest(1,round(r.price*0.033)::bigint)' in v_definition)>0 then
    v_definition:=replace(v_definition,'greatest(1,round(r.price*0.033)::bigint)',
      'greatest(1,round(r.price*0.10)::bigint)');
    execute v_definition;
  elsif position('greatest(1,round(r.price*0.10)::bigint)' in v_definition)=0 then
    raise exception 'Payment approval metadata could not be verified.';
  end if;
  if position('(v_user,p_id,''invitee'',round(r.price*0.025,2),v_time)' in v_definition)=0 then
    raise exception 'One-time invitee reward must remain unchanged.';
  end if;
end;
$approval$;
do $checks$
begin
  if (select count(*) from generate_series(0,14) i cross join lateral public.jtg_package_terms(i))<>8 then
    raise exception 'Expected eight offered packages.';
  end if;
  if (select daily from public.jtg_package_terms(4))<>15000 then
    raise exception 'The UGX 150,000 package daily amount is incorrect.';
  end if;
  if has_function_privilege('anon','public.jtg_earning_state_before_ten(uuid,timestamptz)','execute') then
    raise exception 'Historical earnings replay must remain private.';
  end if;
end;
$checks$;
commit;
