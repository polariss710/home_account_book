-- Fixtures are isolated synthetic users. This body MUST be run inside a transaction ending ROLLBACK.
insert into auth.users(id) values ('cd091400-0000-4000-8000-000000000001'),('cd091400-0000-4000-8000-000000000002');
select set_config('request.jwt.claim.sub','cd091400-0000-4000-8000-000000000001',true);
select set_config('request.jwt.claim.role','authenticated',true);
insert into public.home_accounts(id,user_id,currency,name,account_type)
values('cd091400-0000-4000-8000-000000000003','cd091400-0000-4000-8000-000000000001','JPY','codex-test C rev8','cash');
-- A second user's large income must not subsidize the first user under DEFINER.
insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status)
values('cd091400-0000-4000-8000-000000000002','2098-01','JPY','income','codex-test other actor',9999999,'paid');
set local role authenticated;
do $test$
declare
 u uuid:=auth.uid(); a uuid:='cd091400-0000-4000-8000-000000000003';
 wage uuid; expense_id uuid; adv uuid; funding_tx uuid; extra uuid;
 r jsonb; s jsonb; before_state jsonb; after_state jsonb; caught boolean; old_month text; old_paid date;
begin
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,payment_group)
 values(u,'2098-01','JPY','income','codex-test salary',410000,'unpaid',null) returning id into wage;
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,payment_group)
 values(u,'2098-01','JPY','expense','codex-test advance expense',397000,'unpaid','codex-test advance'),
       (u,'2098-01','JPY','expense','codex-test remaining expense',720000,'unpaid','codex-test remaining');
 s:=public.home_fixed_settlement_status('2098-01','JPY');
 if (s->>'funding_required')::numeric<>707000 or (s->>'transferable_surplus')::numeric<>-1117000 then raise exception 'C01_NO_ADVANCE %',s; end if;
 r:=public.home_create_fixed_advance_payment('2098-01','JPY','codex-test advance',a,'2098-01-10','codex-test');
 if r->>'ok'<>'true' then raise exception 'C02_ADVANCE %',r; end if;
 adv:=(r->>'advance_id')::uuid;
 s:=public.home_fixed_settlement_status('2098-01','JPY');
 if (s->>'funding_required')::numeric<>310000 or (s->>'transferable_surplus')::numeric<>-720000 then raise exception 'C03_ADVANCE_FORMULA %',s; end if;
 r:=public.home_update_fixed_month_item_status(wage,'paid');
 if r->>'ok'<>'true' then raise exception 'C04_SALARY %',r; end if;
 r:=public.home_settle_fixed_advance_repayment(adv,'2098-01-12',null);
 if r->>'code' is distinct from 'HOME_FIXED_ADVANCE_REPAY_INSUFFICIENT_SURPLUS' then raise exception 'C05_REPAY_MUST_REFUSE %',r; end if;
 r:=public.home_create_fixed_transfer('2098-01','JPY','fixed_in',a,'2098-01-12');
 if r->>'code' is distinct from 'HOME_FIXED_TRANSFER_DIRECTION_STALE' then raise exception 'C06_STALE %',r; end if;
 r:=public.home_create_fixed_transfer('2098-01','JPY','fixed_out',a,'2098-01-12');
 if r->>'ok'<>'true' or (r->>'amount')::numeric<>310000 then raise exception 'C07_FUND %',r; end if;
 funding_tx:=(r->>'jpy_transaction_id')::uuid;
 s:=public.home_fixed_settlement_status('2098-01','JPY');
 if (s->>'funding_required')::numeric<>0 or (s->>'transferable_surplus')::numeric<>0 then raise exception 'C08_FUNDED %',s; end if;
 r:=public.home_update_fixed_month_items_status('2098-01','JPY','expense','paid');
 if r->>'ok'<>'true' then raise exception 'C09_PAYMENT %',r; end if;
 r:=public.home_reset_plain_fixed_expenses_if_deficit('2098-01','JPY');
 if (r->>'reset_expense_status')::boolean then raise exception 'C10_RESET %',r; end if;
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status)
 values(u,'2098-01','JPY','income','codex-test extra received',397000,'paid') returning id into extra;
 r:=public.home_settle_fixed_advance_repayment(adv,'2098-01-15',null);
 if r->>'ok'<>'true' then raise exception 'C11_REPAY %',r; end if;
 s:=public.home_fixed_settlement_status('2098-01','JPY');
 if (s->>'funding_required')::numeric<>0 or (s->>'transferable_surplus')::numeric<>0 then raise exception 'C12_AFTER_REPAY %',s; end if;
 select jsonb_agg(to_jsonb(i) order by id) into before_state from public.home_fixed_month_items i where user_id=u;
 caught:=false;
 begin
   update public.home_fixed_month_items set amount=amount-1 where id=wage;
 exception when sqlstate '55000' then
   if sqlerrm<>'HOME_FIXED_SURPLUS_ALREADY_CONSUMED' then raise; end if;
   caught:=true;
 end;
 if not caught then raise exception 'C13_AUTHENTICATED_SNAPSHOT_NOT_ENFORCED'; end if;
 select jsonb_agg(to_jsonb(i) order by id) into after_state from public.home_fixed_month_items i where user_id=u;
 if before_state is distinct from after_state then raise exception 'C14_REFUSAL_NOT_ATOMIC'; end if;
 -- This traverses authenticated INVOKER -> existing postgres DEFINER paired deletion -> INVOKER guard.
 caught:=false;
 begin
   r:=public.home_delete_jpy_transaction(funding_tx);
 exception when sqlstate '55000' then
   if sqlerrm<>'HOME_FIXED_SURPLUS_ALREADY_CONSUMED' then raise; end if;
   caught:=true;
 end;
 if not caught then raise exception 'C15_DEFINER_GUARD_NOT_ENFORCED %',r; end if;
 if not exists(select 1 from public.home_jpy_transactions where id=funding_tx) then raise exception 'C16_DEFINER_REFUSAL_NOT_ATOMIC'; end if;
 r:=public.home_settle_fixed_advance_repayment(adv,'2098-01-15',null);
 if r->>'ok' is distinct from 'false' then raise exception 'C17_DOUBLE_REPAY'; end if;
 caught:=false;
 begin
   perform public.home_fixed_transferable_surplus('cd091400-0000-4000-8000-000000000002','2098-01','JPY');
 exception when sqlstate '55000' then
   if sqlerrm<>'HOME_FIXED_SURPLUS_ACTOR_MISMATCH' then raise; end if;
   caught:=true;
 end;
 if not caught then raise exception 'C18_ACTOR_CHECK'; end if;
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,payment_group)
 values(u,'2098-01','JPY','expense','codex-test expense after repayment',1000,'unpaid','codex-test later') returning id into expense_id;
 s:=public.home_fixed_settlement_status('2098-01','JPY');
 if (s->>'funding_required')::numeric<>1000 then raise exception 'C19_ADDED_EXPENSE %',s; end if;
 -- Contribution zero: moving an unpaid income must not be blocked by an already-negative surplus.
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status)
 values(u,'2098-01','JPY','income','codex-test unpaid zero contribution',100,'unpaid') returning id into extra;
 update public.home_fixed_month_items set month_key='2098-02' where id=extra;
 r:=public.home_update_fixed_month_item_amount(expense_id,2000);
 if r->>'ok'<>'true' then raise exception 'C20_EXPENSE_AMOUNT %',r; end if;
 -- Whole batch failure must preserve all rows.
 select jsonb_agg(to_jsonb(i) order by id) into before_state from public.home_fixed_month_items i where user_id=u;
 caught:=false;
 begin
   r:=public.home_update_fixed_month_items_status('2098-01','JPY','income','unpaid');
 exception when sqlstate '55000' then
   if sqlerrm<>'HOME_FIXED_SURPLUS_ALREADY_CONSUMED' then raise; end if;
   caught:=true;
 end;
 if not caught then raise exception 'C21_BULK_MUST_REFUSE'; end if;
 select jsonb_agg(to_jsonb(i) order by id) into after_state from public.home_fixed_month_items i where user_id=u;
 if before_state is distinct from after_state then raise exception 'C22_BULK_NOT_ATOMIC'; end if;
 -- Rounding and residual month isolation.
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,payment_group)
 values(u,'2098-03','JPY','income','codex-test rounding',410500,'paid',null),
       (u,'2098-03','JPY','expense','codex-test rounding expense',300000,'unpaid','codex-test round');
 s:=public.home_fixed_settlement_status('2098-03','JPY');
 if (s->>'transferable_surplus')::numeric<>110500 or (s->>'transferable_transfer_amount')::numeric<>110000 then raise exception 'C23_ROUNDING %',s; end if;
 r:=public.home_create_fixed_transfer('2098-03','JPY','fixed_in',a,'2098-03-12');
 if r->>'ok'<>'true' or (r->>'amount')::numeric<>110000 then raise exception 'C24_TRANSFER %',r; end if;
 s:=public.home_fixed_settlement_status('2098-03','JPY');
 if (s->>'funding_required')::numeric<>-500 or (s->>'transferable_surplus')::numeric<>500 or s->>'funding_transaction_type' is not null then raise exception 'C25_RESIDUAL %',s; end if;
 if public.home_fixed_transferable_surplus(u,'2098-04','JPY')<>0 then raise exception 'C26_CARRY'; end if;
 -- Cross-month repayment keeps the original month's advance and identity.
 insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,payment_group)
 values(u,'2098-05','JPY','expense','codex-test crossmonth',1000,'unpaid','codex-test crossmonth'),
       (u,'2098-06','JPY','income','codex-test crossmonth funding',1000,'paid',null);
 r:=public.home_create_fixed_advance_payment('2098-05','JPY','codex-test crossmonth',a,'2098-05-10',null);
 if r->>'ok'<>'true' then raise exception 'C27_CROSS_ADVANCE %',r; end if;
 adv:=(r->>'advance_id')::uuid;
 before_state:=public.home_fixed_settlement_status('2098-05','JPY');
 r:=public.home_settle_fixed_advance_repayment(adv,'2098-06-01',null);
 if r->>'ok'<>'true' then raise exception 'C28_CROSS_REPAY %',r; end if;
 after_state:=public.home_fixed_settlement_status('2098-05','JPY');
 if before_state is distinct from after_state then raise exception 'C29_HISTORICAL_MONTH_CHANGED'; end if;
 select month_key,paid_at into old_month,old_paid from public.home_fixed_advance_payments where id=adv;
 if old_month<>'2098-05' or old_paid<>'2098-05-10'::date then raise exception 'C30_ADVANCE_FACTS_CHANGED'; end if;
 raise notice 'C_REV8_C01_C30_PASS';
end;
$test$;
reset role;
