-- Package expiry update for jtg_products and derived wallet snapshots.
-- UGX 50,000 through UGX 2,000,000 use 30 days; smaller packages keep 15 days.
-- No member, payment, product, withdrawal, price, or daily-rate records are modified.
begin;

create or replace function public.jtg_package_duration(p_package_id integer)
returns integer
language sql
immutable
set search_path to 'public'
as $function$
  select case when p_package_id in (0,1) then 15 else 30 end;
$function$;

comment on function public.jtg_package_duration(integer) is
  'Vitz (UGX 15,000) and Passo (UGX 30,000) expire after 15 days; packages from UGX 50,000 through UGX 2,000,000 expire after 30 days. Wallet and snapshot credit caps use this duration.';

-- Existing wallet and financial snapshot routines already use this helper.
-- Changing it applies the same expiry and earnings cap to both user and admin views.
commit;
