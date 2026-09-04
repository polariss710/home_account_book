-- Deployment acceptance: isolated codex-test user, all fixtures ROLLBACK.
-- No production guard is disabled or replaced; real business rows are untouched.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '60s';
insert into auth.users(id) values ('cd090500-0000-4000-8000-000000000001');
select set_config('request.jwt.claim.sub','cd090500-0000-4000-8000-000000000001',true);
do $fixture$
declare
  u uuid := 'cd090500-0000-4000-8000-000000000001';
  c text; a uuid; ch uuid; t uuid; card uuid; ev uuid; ex uuid; s record; r jsonb;
begin
  foreach c in array array['JPY','CNY'] loop
    insert into public.home_accounts(user_id,currency,name,account_type,opening_balance,is_active)
      values(u,c,'codex-test bulk '||c,'cash',100000,true) returning id into a;
    insert into public.home_payment_channels(user_id,currency,name,default_due_day,is_active)
      values(u,c,'codex-test bulk '||c,25,true) returning id into ch;
    insert into public.home_fixed_templates(user_id,currency,direction,name,fixed_type,default_amount,payment_group,due_day,start_month,is_active,accounting_scope)
      values(u,c,'expense','codex-test bulk '||c,'long_term',0,'codex-test bulk '||c,25,'2099-01',true,'household') returning id into t;
    insert into public.home_card_instruments(user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,funding_month_offset,funding_payment_channel_id,household_statement_template_id,is_active,is_school_fixed_route_enabled)
      values(u,'codex-test bulk '||c,c,10,true,25,0,ch,t,true,true) returning id into card;
    select * into strict s from public.home_calculate_card_fixed_schedule(card,'2099-01-09');
    ev:=gen_random_uuid(); ex:=gen_random_uuid();
    perform set_config('request.jwt.claim.role','service_role',true);
    r:=public.home_create_external_fixed_transaction_request(u,'aozora_school',ev,'school_expense_records',ex,
      'expense_paid','expense',card,'2099-01-09',s.suggested_fixed_month,s.suggested_fixed_month,s.funding_date,
      100,c,'codex-test:bulk-20260905:'||c,'codex-test projection '||c,'codex-test rollback',
      jsonb_build_object('external_source','aozora_school','external_event_id',ev,'external_reference_type','school_expense_records',
        'external_reference_id',ex,'request_type','expense_paid','transaction_type','expense','payment_route','fixed_credit_card',
        'card_instrument_id',card,'charge_date','2099-01-09','suggested_fixed_month',s.suggested_fixed_month,
        'target_fixed_month',s.suggested_fixed_month,'funding_date',s.funding_date,'year_month','2099-01',
        'expense_category','classroom','source_type','manual_cash','school_attempt_payload_fingerprint',repeat('a',64),
        'original_amount',case when c='JPY' then 100 else 2000 end,'original_currency','JPY','settlement_amount',100,'settlement_currency',c));
    if r->>'ok' is distinct from 'true' then raise exception 'FIXTURE_REQUEST: %',r; end if;
    perform set_config('request.jwt.claim.role','authenticated',true);
    r:=public.home_approve_external_fixed_transaction_request((r->>'request_id')::uuid);
    if r->>'ok' is distinct from 'true' then raise exception 'FIXTURE_APPROVE: %',r; end if;
    insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,account_id,payment_group,due_date,accounting_scope)
    values(u,'2099-01',c,'expense','codex-test ordinary '||c,100,'unpaid',a,'codex-test bulk '||c,'2099-01-25','household'),
          (u,'2099-01',c,'income','codex-test income '||c,100000,'paid',a,'codex-test bulk '||c,'2099-01-01','household');
  end loop;
end $fixture$;
set local role authenticated;
do $verify$
declare r jsonb; c text; before_rows jsonb; after_rows jsonb;
begin
  foreach c in array array['JPY','CNY'] loop
    select jsonb_agg(to_jsonb(i) order by id) into before_rows from public.home_fixed_month_items i
      where user_id=auth.uid() and currency=c and accounting_scope='school';
    if c='JPY' then r:=public.home_update_fixed_month_items_status('2099-01',c,'expense','paid');
    else r:=public.home_update_cny_fixed_items_status('2099-01','expense','paid'); end if;
    if r->>'ok' is distinct from 'true' or (r->>'updated_count')::int<>1 or (r->>'skipped_projection_count')::int<>1
      then raise exception 'MIXED_BULK_%: %',c,r; end if;
    select jsonb_agg(to_jsonb(i) order by id) into after_rows from public.home_fixed_month_items i
      where user_id=auth.uid() and currency=c and accounting_scope='school';
    if before_rows is distinct from after_rows then raise exception 'PROJECTION_CHANGED_%',c; end if;
    if not exists(select 1 from public.home_fixed_month_items where user_id=auth.uid() and name='codex-test ordinary '||c and status='paid')
      then raise exception 'ORDINARY_UNCHANGED_%',c; end if;
    raise notice 'MIXED_%_PASS: %',c,r;
  end loop;
  r:=public.home_update_fixed_month_items_status('2099-01','JPY','invalid','paid');
  if r->>'ok' is distinct from 'false' then raise exception 'INVALID_DIRECTION'; end if;
  r:=public.home_update_cny_fixed_items_status('2099-01','expense','invalid');
  if r->>'ok' is distinct from 'false' then raise exception 'INVALID_STATUS'; end if;
end $verify$;
reset role;
insert into public.home_fixed_month_items(user_id,month_key,currency,direction,name,amount,status,accounting_scope)
values('cd090500-0000-4000-8000-000000000001','2099-02','CNY','expense','codex-test no account',1,'unpaid','household'),
      ('cd090500-0000-4000-8000-000000000001','2099-02','JPY','expense','codex-test no income',1,'unpaid','household');
set local role authenticated;
do $negative$
declare r jsonb; expected jsonb;
begin
  r:=public.home_update_cny_fixed_items_status('2099-02','expense','paid');
  if r->>'ok' is distinct from 'false' or r->>'invalid_count'<>'1' then raise exception 'CNY_ACCOUNT_GUARD: %',r; end if;
  raise notice 'NON_PROJECTION_ACCOUNT_GUARD_PASS: %',r;
  expected:=public.home_check_fixed_paid_balance('2099-02','JPY',null,null,'expense','paid');
  r:=public.home_update_fixed_month_items_status('2099-02','JPY','expense','paid');
  if r is distinct from expected or r->>'ok' is distinct from 'false' then raise exception 'BALANCE_GUARD: %',r; end if;
  raise notice 'BALANCE_GUARD_PASS: %',r;
end $negative$;
reset role;
-- Valid pending cycles for isolated fixtures. This is the normal transaction-local
-- cycle-write context; all validation triggers remain installed and enabled.
select set_config('home.phase3e_cycle_write','on',true);
with new_items as (
  insert into public.home_fixed_month_items(user_id,template_id,month_key,currency,direction,name,amount,status,account_id,payment_group,due_date,accounting_scope)
  select c.user_id,c.household_statement_template_id,'2099-03',c.settlement_currency,'expense','codex-test statement '||c.settlement_currency,0,'unpaid',a.id,pc.name,'2099-03-25','household'
  from public.home_card_instruments c join public.home_payment_channels pc on pc.id=c.funding_payment_channel_id
  join public.home_accounts a on a.user_id=c.user_id and a.currency=c.settlement_currency
  where c.user_id='cd090500-0000-4000-8000-000000000001' returning *
)
insert into public.home_card_statement_cycles(user_id,card_instrument_id,target_fixed_month,settlement_currency,amount_status,household_remainder_fixed_item_id)
select i.user_id,c.id,'2099-03-01',i.currency,'pending',i.id from new_items i
join public.home_card_instruments c on c.user_id=i.user_id and c.settlement_currency=i.currency;
select set_config('home.phase3e_cycle_write','off',true);
set local role authenticated;
do $statement$
declare r jsonb; denied boolean:=false;
begin
  r:=public.home_update_fixed_month_items_status('2099-03','JPY','expense','paid');
  if r->>'code' is distinct from 'HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN' then raise exception 'JPY_STATEMENT: %',r; end if;
  raise notice 'JPY_STATEMENT_PASS: %',r;
  begin
    r:=public.home_update_cny_fixed_items_status('2099-03','expense','paid');
  exception when sqlstate '42501' then
    if sqlerrm<>'HOME_CARD_STATEMENT_ITEM_UPDATE_FORBIDDEN' then raise; end if;
    denied:=true;
  end;
  if not denied then raise exception 'CNY_STATEMENT_NOT_DENIED: %',r; end if;
  if exists(select 1 from public.home_fixed_month_items where user_id=auth.uid() and month_key='2099-03' and status<>'unpaid') then raise exception 'STATEMENT_PARTIAL_WRITE'; end if;
  raise notice 'CNY_STATEMENT_EXCEPTION_AND_ROLLBACK_PASS';
end $statement$;
reset role;
rollback;
select count(*) as fixture_user_residue from auth.users where id='cd090500-0000-4000-8000-000000000001';
select count(*) as fixture_item_residue from public.home_fixed_month_items where user_id='cd090500-0000-4000-8000-000000000001';
