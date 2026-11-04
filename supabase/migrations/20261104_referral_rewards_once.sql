-- Correct one-time invited-member rewards without changing existing account or financial records.
-- Daily compounding remains 3.3%; inviter reward remains 5%; invitee reward is 2.5%.
-- Rewards are committed in the same transaction and timestamp as package activation.
-- The approval status guard and unique(payment_id,kind) prevent repeated crediting.
begin;
do $referral$
declare
  v_definition text:=pg_get_functiondef('public.jtg_decide_payment(uuid,text)'::regprocedure);
  v_old text:='(v_user,p_id,''invitee'',round(r.price*0.033,2),v_time)';
  v_new text:='(v_user,p_id,''invitee'',round(r.price*0.025,2),v_time)';
begin
  if position(v_old in v_definition)>0 then
    execute replace(v_definition,v_old,v_new);
  elsif position(v_new in v_definition)=0 then
    raise exception 'Referral approval format could not be verified.';
  end if;
  v_definition:=pg_get_functiondef('public.jtg_decide_payment(uuid,text)'::regprocedure);
  if position('(v_ref,p_id,''inviter'',round(r.price*0.05,2),v_time)' in v_definition)=0
    or position(v_new in v_definition)=0
    or position('if r.status=p_decision then return; end if;' in v_definition)=0
    or position('on conflict(payment_id,kind) do nothing' in v_definition)=0 then
    raise exception 'Immediate one-time referral rewards could not be verified.';
  end if;
end;
$referral$;
commit;
