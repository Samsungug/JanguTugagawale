-- Package expiry configuration for jtg_products and derived wallet snapshots.
-- No member, payment, product, or withdrawal records are modified.
-- Vitz and Passo use 15 days; prices, daily rates, and other packages remain unchanged.
begin;

create or replace function public.jtg_package_duration(p_package_id integer)
returns integer
language sql
immutable
set search_path to 'public'
as $function$
  select case when p_package_id in (0,1) then 15 else 60 end;
$function$;

comment on function public.jtg_package_duration(integer) is
  'Vitz (UGX 15,000) and Passo (UGX 30,000) expire after 15 days; other packages retain 60 days.';

-- Preserve existing routine ownership, privileges, security mode, and authorization logic.
-- Idempotently replace the old fixed credit caps with package-specific duration caps.
do $migration$
declare
  v_definition text;
begin
  select pg_get_functiondef('public.jtg_wallet(uuid)'::regprocedure)
    into v_definition;
  if position('least(60::bigint' in v_definition) > 0 then
    v_definition := replace(
      v_definition,
      'least(60::bigint',
      'least(public.jtg_package_duration(package_id)::bigint'
    );
    execute v_definition;
  end if;

  select pg_get_functiondef('public.jtg_financial_snapshot()'::regprocedure)
    into v_definition;
  if position('least(60::bigint' in v_definition) > 0 then
    v_definition := replace(
      v_definition,
      'least(60::bigint',
      'least(public.jtg_package_duration(p.package_id)::bigint'
    );
    v_definition := replace(
      v_definition,
      '''completed_days'',',
      '''duration_days'',public.jtg_package_duration(p.package_id),''completed_days'','
    );
    execute v_definition;
  end if;
end;
$migration$;

commit;
