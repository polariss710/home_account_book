\set ON_ERROR_STOP on

-- Home / Cash：固定项 projection helper 带数据行为验证（全事务 ROLLBACK）
-- 仅创建 codex-test 固定 UUID / 2099 数据；不读取或修改真实业务行。

begin;
set local statement_timeout = '120s';

insert into auth.users(id) values
  ('42501000-0000-4000-8000-000000000001'),
  ('42501000-0000-4000-8000-000000000002');

insert into public.home_accounts(
  id,user_id,currency,name,account_type,opening_balance,is_active,allow_school_requests
) values (
  '42501000-0000-4000-8000-000000000011',
  '42501000-0000-4000-8000-000000000001',
  'JPY','codex-test 42501 account','cash',0,true,true
);

insert into public.home_payment_channels(
  id,user_id,currency,name,default_due_day,is_active
) values (
  '42501000-0000-4000-8000-000000000012',
  '42501000-0000-4000-8000-000000000001',
  'JPY','codex-test-group-A',25,true
);

insert into public.home_fixed_templates(
  id,user_id,currency,direction,name,fixed_type,default_amount,payment_group,
  due_day,start_month,is_active,accounting_scope
) values (
  '42501000-0000-4000-8000-000000000013',
  '42501000-0000-4000-8000-000000000001',
  'JPY','expense','codex-test statement template','long_term',0,
  'codex-test-group-A',25,'2099-01',true,'household'
);

insert into public.home_card_instruments(
  id,user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,
  funding_payment_channel_id,household_statement_template_id,is_active,
  is_school_fixed_route_enabled,version
) values (
  '42501000-0000-4000-8000-000000000014',
  '42501000-0000-4000-8000-000000000001',
  'codex-test 42501 card','JPY',10,true,25,
  '42501000-0000-4000-8000-000000000012',
  '42501000-0000-4000-8000-000000000013',true,true,1
);

create or replace function pg_temp.create_42501_projection_fixture()
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_card_id uuid := '42501000-0000-4000-8000-000000000014';
  v_user_id uuid := '42501000-0000-4000-8000-000000000001';
  v_event_id uuid := '42501000-0000-4000-8000-000000000021';
  v_expense_id uuid := '42501000-0000-4000-8000-000000000022';
  v_schedule record;
  v_result jsonb;
begin
  select * into strict v_schedule
  from public.home_calculate_card_fixed_schedule(v_card_id, '2099-01-09');

  perform set_config('request.jwt.claim.sub', v_user_id::text, true);
  perform set_config('request.jwt.claim.role', 'service_role', true);
  select public.home_create_external_fixed_transaction_request(
    v_user_id,'aozora_school',v_event_id,'school_expense_records',v_expense_id,
    'expense_paid','expense',v_card_id,'2099-01-09',
    v_schedule.suggested_fixed_month,v_schedule.suggested_fixed_month,
    v_schedule.funding_date,3101,'JPY','codex-test:42501:projection',
    'codex-test 42501 projected expense','codex-test 42501',
    jsonb_build_object(
      'external_source','aozora_school','external_event_id',v_event_id,
      'external_reference_type','school_expense_records',
      'external_reference_id',v_expense_id,
      'request_type','expense_paid','transaction_type','expense',
      'payment_route','fixed_credit_card','card_instrument_id',v_card_id,
      'charge_date','2099-01-09','suggested_fixed_month',v_schedule.suggested_fixed_month,
      'target_fixed_month',v_schedule.suggested_fixed_month,
      'funding_date',v_schedule.funding_date,'year_month','2099-01',
      'expense_category','codex-test','source_type','manual_cash',
      'payee_name_snapshot','codex-test payee','description','codex-test 42501',
      'school_attempt_payload_fingerprint',repeat('4',64),'note','codex-test 42501'
    )
  ) into v_result;
  if not coalesce((v_result->>'ok')::boolean,false) then
    raise exception 'BEHAVIOR_FIXTURE_REQUEST_FAILED: %',v_result;
  end if;

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  v_result := public.home_approve_external_fixed_transaction_request(
    (v_result->>'request_id')::uuid
  );
  if not coalesce((v_result->>'ok')::boolean,false) then
    raise exception 'BEHAVIOR_FIXTURE_APPROVAL_FAILED: %',v_result;
  end if;
  return v_result;
end
$function$;

create temporary table test_42501_ids on commit drop as
select pg_temp.create_42501_projection_fixture() as approval;
grant select on test_42501_ids to authenticated;

insert into public.home_fixed_month_items(
  id,user_id,template_id,month_key,currency,direction,name,amount,status,
  account_id,payment_group,due_date,note,accounting_scope
) values
(
  '42501000-0000-4000-8000-000000000031',
  '42501000-0000-4000-8000-000000000001',null,
  '2099-01','JPY','expense','codex-test group B expense',2200,'unpaid',null,
  'codex-test-group-B','2099-01-25','codex-test 42501 group isolation','household'
),
(
  '42501000-0000-4000-8000-000000000032',
  '42501000-0000-4000-8000-000000000001',null,
  '2026-08','JPY','income','codex-test 2026-08 余额调整',1000,'unpaid',null,
  'codex-test-balance','2026-08-25','codex-test original-path equivalent','household'
);

select set_config(
  'request.jwt.claim.sub','42501000-0000-4000-8000-000000000001',true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $authenticated_behavior$
declare
  v_projection_item uuid := (
    select (approval->>'fixed_item_id')::uuid from test_42501_ids
  );
  v_result jsonb;
  v_bool boolean;
begin
  -- 1. Projection 关联项必须返回原业务文案，而不是 42501 或放行。
  v_result := public.home_update_fixed_month_item_status(v_projection_item,'paid');
  if v_result->>'code' <> 'HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN' then
    raise exception 'BEHAVIOR_SINGLE_GUARD_FAILED: %',v_result;
  end if;
  v_result := public.home_update_fixed_month_items_status(
    '2099-01','JPY','expense','paid'
  );
  if v_result->>'code' <> 'HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN' then
    raise exception 'BEHAVIOR_BULK_GUARD_FAILED: %',v_result;
  end if;
  v_result := public.home_sync_fixed_month_items('2099-01','JPY');
  if v_result->>'code' <> 'HOME_PROJECTION_FIXED_ITEM_SYNC_FORBIDDEN' then
    raise exception 'BEHAVIOR_SYNC_GUARD_FAILED: %',v_result;
  end if;

  -- 2. 同月同币种：B 组无 projection，必须成功；A 组必须按原文案拦截。
  v_bool := public.home_fixed_scope_has_external_projection(
    '2099-01','JPY','expense','codex-test-group-B'
  );
  if v_bool then raise exception 'BEHAVIOR_GROUP_B_FALSE_POSITIVE'; end if;
  v_bool := public.home_fixed_scope_has_external_projection(
    '2099-01','JPY','expense','codex-test-group-A'
  );
  if not v_bool then raise exception 'BEHAVIOR_GROUP_A_FALSE_NEGATIVE'; end if;

  v_result := public.home_create_fixed_advance_payment(
    '2099-01','JPY','codex-test-group-B',
    '42501000-0000-4000-8000-000000000011','2099-01-25',
    'codex-test 42501 group B'
  );
  if not coalesce((v_result->>'ok')::boolean,false) then
    raise exception 'BEHAVIOR_GROUP_B_ADVANCE_FAILED: %',v_result;
  end if;
  v_result := public.home_create_fixed_advance_payment(
    '2099-01','JPY','codex-test-group-A',
    '42501000-0000-4000-8000-000000000011','2099-01-25',
    'codex-test 42501 group A'
  );
  if v_result->>'code' <> 'HOME_PROJECTION_FIXED_ITEM_ADVANCE_FORBIDDEN' then
    raise exception 'BEHAVIOR_GROUP_A_ADVANCE_NOT_BLOCKED: %',v_result;
  end if;

  -- 3. 原始复现场景的独立白名单等价项：未付 -> 已付必须成功。
  v_result := public.home_update_fixed_month_item_status(
    '42501000-0000-4000-8000-000000000032','paid'
  );
  if not coalesce((v_result->>'ok')::boolean,false) then
    raise exception 'BEHAVIOR_BALANCE_ADJUSTMENT_FAILED: %',v_result;
  end if;
end
$authenticated_behavior$;

reset role;

-- 2/3 的持久效果只存在于本回滚事务内，精确核对后统一回滚。
do $owner_verify$
declare
  v_projection_item uuid := (
    select (approval->>'fixed_item_id')::uuid from test_42501_ids
  );
begin
  if (select status from public.home_fixed_month_items
      where id='42501000-0000-4000-8000-000000000031') <> 'paid'
     or (select status from public.home_fixed_month_items
         where id='42501000-0000-4000-8000-000000000032') <> 'paid'
     or (select status from public.home_fixed_month_items
         where id=v_projection_item) <> 'unpaid'
     or (select count(*) from public.home_fixed_advance_payments
         where user_id='42501000-0000-4000-8000-000000000001'
           and month_key='2099-01' and payment_group='codex-test-group-B') <> 1
     or (select count(*) from public.home_fixed_advance_payments
         where user_id='42501000-0000-4000-8000-000000000001'
           and month_key='2099-01' and payment_group='codex-test-group-A') <> 0 then
    raise exception 'BEHAVIOR_OWNER_SIDE_EFFECT_CONTRACT_FAILED';
  end if;
end
$owner_verify$;

-- 4. 归属隔离：第二用户不得探测或修改第一用户的 projection 项。
select set_config(
  'request.jwt.claim.sub','42501000-0000-4000-8000-000000000002',true
);
select set_config('request.jwt.claim.role','authenticated',true);
set local role authenticated;

do $ownership$
declare
  v_projection_item uuid := (
    select (approval->>'fixed_item_id')::uuid from test_42501_ids
  );
  v_result jsonb;
begin
  if public.home_fixed_item_has_external_projection(v_projection_item) then
    raise exception 'BEHAVIOR_OWNERSHIP_ITEM_LEAKED';
  end if;
  if public.home_fixed_scope_has_external_projection('2099-01','JPY') then
    raise exception 'BEHAVIOR_OWNERSHIP_SCOPE_LEAKED';
  end if;
  v_result := public.home_update_fixed_month_item_status(v_projection_item,'paid');
  if coalesce((v_result->>'ok')::boolean,false)
     or v_result->>'message' <> '没有找到可更新的固定项。' then
    raise exception 'BEHAVIOR_OWNERSHIP_WRITER_LEAKED: %',v_result;
  end if;
end
$ownership$;

reset role;

do $done$
begin
  raise notice 'fixed projection privilege helper behavior rollback tests: all passed';
end
$done$;

rollback;
