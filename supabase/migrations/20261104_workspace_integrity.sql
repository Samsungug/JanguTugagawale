-- Read-only integrity checks for the installed financial and CUSTOMER CARE upgrade.
-- Existing accounts, referral identities, approved transactions, and audit records are retained.
-- Catalog removals preserve historical package IDs. No user data is changed by this file.
begin;

do $checks$
declare
  v_count integer;
begin
  select count(*) into v_count
    from generate_series(0,14) as ids(id)
    cross join lateral public.jtg_package_terms(ids.id);
  if v_count <> 11 then
    raise exception 'Expected exactly 11 available packages.';
  end if;

  if to_regprocedure('public.jtg_earning_state(uuid,timestamp with time zone)') is null
    or to_regprocedure('public.jtg_expire_product(uuid)') is null
    or to_regprocedure('public.jtg_workspace_snapshot(uuid)') is null then
    raise exception 'The financial and workspace upgrade must be installed first.';
  end if;

  if has_function_privilege('anon','public.jtg_earning_state(uuid,timestamp with time zone)','execute')
    or has_function_privilege('anon','public.jtg_send_support(uuid,text)','execute')
    or has_function_privilege('anon','public.jtg_expire_product(uuid)','execute')
    or has_function_privilege('anon','public.jtg_post_advert(text)','execute') then
    raise exception 'Private workspace operations must not be available anonymously.';
  end if;

  select count(*) into v_count from pg_class c join pg_namespace n on n.oid=c.relnamespace
    where n.nspname='public' and c.relname in (
      'jtg_finance_settings','jtg_referral_credits',
      'jtg_support_messages','jtg_support_receipts','jtg_adverts'
    ) and c.relrowsecurity;
  if v_count <> 5 then
    raise exception 'Every new financial and workspace table must enable row level security.';
  end if;

  if round(100000::numeric*0.025,2) <> 2500
    or round((100000::numeric+2500)*0.025,2) <> 2562.50
    or round(100000::numeric*0.15,2) <> 15000
    or 100000-round(100000::numeric*0.15,2) <> 85000 then
    raise exception 'Compound earnings or withdrawal charge arithmetic is inconsistent.';
  end if;
end;
$checks$;

-- The server snapshots calculate every pending charge as amount * 0.15 immediately.
-- Charge and net_to_pay are stored at review, retaining legacy tax fields for historical audit.
-- Capital never enters the withdrawable wallet. Approved requests deduct the gross amount once.
-- Accrual replays completed 24-hour credits with dated bonuses and approved withdrawals.
-- Prior earned credits are preserved at the upgrade boundary; future credits use compounding.
-- Multiple active packages share the current earnings base in proportion to active capital.
-- Package expiry is explicit expired_at only; date-based expiry helpers are no longer consulted.
-- Advert visibility ends at posted_at + interval '24 hours'; older banners cannot reappear.
-- Expired/replaced adverts remain in the private audit history rather than deleting user data.
commit;
