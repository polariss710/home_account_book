-- Correction-P Home isolated PostgreSQL 17 matrix. Caller has installed the
-- production schema clone plus the local migration. This file retains nothing.

begin;

insert into auth.users(id) values
  ('8596a708-d99f-4264-8f8c-5b89af9254b6'),
  ('25331ae9-3412-48b9-bdc3-e516caeaeba4'),
  ('c0de0000-0000-4000-8000-00000000ee01');
insert into public.home_accounts(id,user_id,currency,name,account_type,opening_balance,is_active,allow_school_requests)
values ('b06f29c4-67cd-4d55-b39c-7cff0eab99a1','8596a708-d99f-4264-8f8c-5b89af9254b6','JPY','日元现金','cash',0,true,true);
insert into public.home_payment_channels(id,user_id,currency,name,default_due_day,is_active)
values ('53af0c53-03d3-477a-944e-a9bdfbe441fc','8596a708-d99f-4264-8f8c-5b89af9254b6','JPY','邮局卡',25,true);
insert into public.home_fixed_templates(id,user_id,currency,direction,name,fixed_type,default_amount,payment_group,due_day,start_month,is_active,accounting_scope)
values ('1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f','8596a708-d99f-4264-8f8c-5b89af9254b6','JPY','expense','西武卡消费','long_term',0,'邮局卡',25,'2099-01',true,'household');
insert into public.home_card_instruments(id,user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,funding_payment_channel_id,household_statement_template_id,is_active,is_school_fixed_route_enabled,version)
values ('9b27347e-2dce-4caf-bac0-67f053ef6c3b','8596a708-d99f-4264-8f8c-5b89af9254b6','西武卡','JPY',10,true,25,'53af0c53-03d3-477a-944e-a9bdfbe441fc','1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f',true,false,1);

-- B2.2 unrelated-business control: every identity, user, card, month and marker
-- differs from the Correction-P fixture. These rows must survive byte-for-byte.
insert into public.home_accounts(id,user_id,currency,name,account_type,opening_balance,is_active,allow_school_requests)
values ('c0de0000-0000-4000-8000-00000000ee02','c0de0000-0000-4000-8000-00000000ee01','JPY','B2.2 unrelated account','cash',0,true,true);
insert into public.home_payment_channels(id,user_id,currency,name,default_due_day,is_active)
values ('c0de0000-0000-4000-8000-00000000ee03','c0de0000-0000-4000-8000-00000000ee01','JPY','B2.2 unrelated channel',24,true);
insert into public.home_fixed_templates(id,user_id,currency,direction,name,fixed_type,default_amount,payment_group,due_day,start_month,is_active,accounting_scope)
values ('c0de0000-0000-4000-8000-00000000ee04','c0de0000-0000-4000-8000-00000000ee01','JPY','expense','B2.2 unrelated template','long_term',0,'B2.2 unrelated channel',24,'2098-01',true,'household');
insert into public.home_card_instruments(id,user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,funding_payment_channel_id,household_statement_template_id,is_active,is_school_fixed_route_enabled,version)
values ('c0de0000-0000-4000-8000-00000000ee05','c0de0000-0000-4000-8000-00000000ee01','B2.2 unrelated card','JPY',10,true,24,'c0de0000-0000-4000-8000-00000000ee03','c0de0000-0000-4000-8000-00000000ee04',true,false,1);

do $fixture$
declare
  v_payload jsonb:=jsonb_build_object(
    'external_source','aozora_school','external_event_id','fa3aad38-5886-4154-a7d4-8c8331fb71fe',
    'external_reference_type','school_expense_records','external_reference_id','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'request_type','expense_paid','transaction_type','expense','payment_route','immediate_account',
    'year_month','2099-08','expense_category','classroom','source_type','manual_cash',
    'school_attempt_id','b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',
    'school_attempt_payload_fingerprint',repeat('a',64)
  );
begin
  insert into public.home_jpy_transactions(
    id,user_id,transaction_type,account_id,transacted_at,amount,description,note,
    external_source,external_source_id,external_event_type,external_idempotency_key,
    external_reference_type,external_reference_id,external_payload_hash,
    external_created_at,created_by_external,accounting_scope
  ) values (
    '01e910b8-bf54-486c-a13a-597ca9dbf684','8596a708-d99f-4264-8f8c-5b89af9254b6',
    'expense','b06f29c4-67cd-4d55-b39c-7cff0eab99a1','2099-08-13',202991,
    'correction-p-b22-fixture','correction-p-b22-fixture','aozora_school','fa3aad38-5886-4154-a7d4-8c8331fb71fe',
    'expense_paid','aozora_school:school_expense_records:ed23a346-2ba5-47fb-a496-4c4ba781ec86:expense_paid:attempt:1',
    'school_expense_records','ed23a346-2ba5-47fb-a496-4c4ba781ec86',md5(v_payload::text),
    statement_timestamp(),true,'school'
  );
  insert into public.home_external_transaction_requests(
    id,user_id,external_source,external_event_id,external_reference_type,
    external_reference_id,request_type,transaction_type,currency,amount,account_id,
    transacted_at,status,approved_at,created_transaction_id,idempotency_key,
    payload_snapshot,description,note,accounting_scope,payment_route,projection_status
  ) values (
    'ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc','8596a708-d99f-4264-8f8c-5b89af9254b6',
    'aozora_school','fa3aad38-5886-4154-a7d4-8c8331fb71fe','school_expense_records',
    'ed23a346-2ba5-47fb-a496-4c4ba781ec86','expense_paid','expense','JPY',202991,
    'b06f29c4-67cd-4d55-b39c-7cff0eab99a1','2099-08-13','approved',statement_timestamp(),
    '01e910b8-bf54-486c-a13a-597ca9dbf684',
    'aozora_school:school_expense_records:ed23a346-2ba5-47fb-a496-4c4ba781ec86:expense_paid:attempt:1',
    v_payload,'correction-p-b22-fixture','correction-p-b22-fixture','school','immediate_account','not_applicable'
  );
end;
$fixture$;

do $unrelated_source_fixture$
declare
  v_payload jsonb:=jsonb_build_object(
    'external_source','aozora_school','external_event_id','c0de0000-0000-4000-8000-00000000ee13',
    'external_reference_type','school_expense_records','external_reference_id','c0de0000-0000-4000-8000-00000000ee14',
    'request_type','expense_paid','transaction_type','expense','payment_route','immediate_account',
    'year_month','2098-08','expense_category','unrelated','source_type','manual_cash',
    'school_attempt_id','c0de0000-0000-4000-8000-00000000ee15',
    'school_attempt_payload_fingerprint',repeat('b',64),
    'test_marker','correction-p-b22-unrelated'
  );
begin
  insert into public.home_jpy_transactions(
    id,user_id,transaction_type,account_id,transacted_at,amount,description,note,
    external_source,external_source_id,external_event_type,external_idempotency_key,
    external_reference_type,external_reference_id,external_payload_hash,
    external_created_at,created_by_external,accounting_scope
  ) values (
    'c0de0000-0000-4000-8000-00000000ee11','c0de0000-0000-4000-8000-00000000ee01',
    'expense','c0de0000-0000-4000-8000-00000000ee02','2098-08-13',777,
    'correction-p-b22-unrelated','correction-p-b22-unrelated','aozora_school','c0de0000-0000-4000-8000-00000000ee13',
    'expense_paid','correction-p-b22-unrelated:expense-paid:attempt:1',
    'school_expense_records','c0de0000-0000-4000-8000-00000000ee14',md5(v_payload::text),
    statement_timestamp(),true,'school'
  );
  insert into public.home_external_transaction_requests(
    id,user_id,external_source,external_event_id,external_reference_type,
    external_reference_id,request_type,transaction_type,currency,amount,account_id,
    transacted_at,status,approved_at,created_transaction_id,idempotency_key,
    payload_snapshot,description,note,accounting_scope,payment_route,projection_status
  ) values (
    'c0de0000-0000-4000-8000-00000000ee12','c0de0000-0000-4000-8000-00000000ee01',
    'aozora_school','c0de0000-0000-4000-8000-00000000ee13','school_expense_records',
    'c0de0000-0000-4000-8000-00000000ee14','expense_paid','expense','JPY',777,
    'c0de0000-0000-4000-8000-00000000ee02','2098-08-13','approved',statement_timestamp(),
    'c0de0000-0000-4000-8000-00000000ee11','correction-p-b22-unrelated:expense-paid:attempt:1',
    v_payload,'correction-p-b22-unrelated','correction-p-b22-unrelated','school','immediate_account','not_applicable'
  );
end;
$unrelated_source_fixture$;

do $acl$
begin
  if has_table_privilege('service_role','public.home_external_transaction_corrections','INSERT,UPDATE,DELETE')
     or has_table_privilege('service_role','public.home_account_correction_entries','INSERT,UPDATE,DELETE')
     or has_table_privilege('service_role','public.home_external_correction_route_policies','INSERT,UPDATE,DELETE')
     or has_table_privilege('service_role','public.home_correction_replacement_authorizations','INSERT,UPDATE,DELETE')
     or has_function_privilege('public','public.home_prepare_external_transaction_correction_p(uuid,uuid,uuid,uuid,uuid,text,uuid)','EXECUTE')
     or has_function_privilege('anon','public.home_prepare_external_transaction_correction_p(uuid,uuid,uuid,uuid,uuid,text,uuid)','EXECUTE')
     or has_function_privilege('authenticated','public.home_prepare_external_transaction_correction_p(uuid,uuid,uuid,uuid,uuid,text,uuid)','EXECUTE')
     or not has_function_privilege('service_role','public.home_prepare_external_transaction_correction_p(uuid,uuid,uuid,uuid,uuid,text,uuid)','EXECUTE') then
    raise exception 'HOME_CORRECTION_P_ACL_INVALID';
  end if;
end;
$acl$;

select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
select set_config('request.jwt.claim.role','service_role',true);

do $policy_contract$
declare r jsonb;
begin
  r:=public.home_prepare_external_transaction_correction_p(
    'c0de0000-0000-4000-8000-000000000099','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
    '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
    '25331ae9-3412-48b9-bdc3-e516caeaeba4');
  if r->>'code'<>'HOME_CORRECTION_ROUTE_POLICY_NOT_CONFIGURED' then
    raise exception 'HOME_CORRECTION_P_UNCONFIGURED_POLICY_NOT_BLOCKED:%',r;
  end if;
  insert into public.home_external_correction_route_policies(
    id,operation_kind,user_id,accounting_scope,currency,card_instrument_id,
    payment_channel_id,effective_from,is_active,approved_by,approval_reference
  ) values
  ('c0de0000-0000-4000-8000-000000000401','school_expense_immediate_to_fixed',
   '8596a708-d99f-4264-8f8c-5b89af9254b6','school','JPY',
   '9b27347e-2dce-4caf-bac0-67f053ef6c3b','53af0c53-03d3-477a-944e-a9bdfbe441fc',
   '2099-01-01',true,'25331ae9-3412-48b9-bdc3-e516caeaeba4','local Phase B2.2 fixture'),
  ('c0de0000-0000-4000-8000-000000000402','school_expense_immediate_to_fixed',
   '8596a708-d99f-4264-8f8c-5b89af9254b6','school','JPY',
   '9b27347e-2dce-4caf-bac0-67f053ef6c3b','53af0c53-03d3-477a-944e-a9bdfbe441fc',
   '2099-01-01',true,'25331ae9-3412-48b9-bdc3-e516caeaeba4','local conflict fixture'),
  ('c0de0000-0000-4000-8000-000000000403','school_expense_immediate_to_fixed',
   'c0de0000-0000-4000-8000-00000000ee01','school','JPY',
   'c0de0000-0000-4000-8000-00000000ee05','c0de0000-0000-4000-8000-00000000ee03',
   '2098-01-01',true,'25331ae9-3412-48b9-bdc3-e516caeaeba4','correction-p-b22-unrelated');
  r:=public.home_prepare_external_transaction_correction_p(
    'c0de0000-0000-4000-8000-000000000099','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
    '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
    '25331ae9-3412-48b9-bdc3-e516caeaeba4');
  if r->>'code'<>'HOME_CORRECTION_ROUTE_POLICY_CONFLICT' then
    raise exception 'HOME_CORRECTION_P_POLICY_CONFLICT_NOT_BLOCKED:%',r;
  end if;
  delete from public.home_external_correction_route_policies
  where id='c0de0000-0000-4000-8000-000000000402';
end;
$policy_contract$;

do $unrelated_correction_fixture$
declare r jsonb;
begin
  r:=public.home_prepare_external_transaction_correction_p(
    'c0de0000-0000-4000-8000-00000000ee17','c0de0000-0000-4000-8000-00000000ee12',
    'c0de0000-0000-4000-8000-00000000ee11','c0de0000-0000-4000-8000-00000000ee14',
    'c0de0000-0000-4000-8000-00000000ee15',repeat('b',64),
    '25331ae9-3412-48b9-bdc3-e516caeaeba4');
  if not coalesce((r->>'ok')::boolean,false) or r->>'status'<>'prepared' then
    raise exception 'HOME_CORRECTION_P_UNRELATED_PREPARE_FAILED:%',r;
  end if;
end;
$unrelated_correction_fixture$;

create temp table correction_p_test_identity(
  test_run_id uuid primary key,
  operation_id uuid not null,
  fixture_user_id uuid not null,
  source_request_id uuid not null,
  source_transaction_id uuid not null,
  school_expense_id uuid not null,
  school_attempt_id uuid not null,
  card_id uuid not null,
  payment_channel_id uuid not null,
  template_id uuid not null,
  statement_cycle_id uuid not null,
  statement_revision_id uuid not null,
  advance_payment_id uuid not null,
  fixture_month date not null,
  fixture_marker text not null
) on commit drop;
insert into correction_p_test_identity values (
  'c0de0000-0000-4000-8000-00000000b222','c0de0000-0000-4000-8000-000000000001',
  '8596a708-d99f-4264-8f8c-5b89af9254b6','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
  '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
  'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5','9b27347e-2dce-4caf-bac0-67f053ef6c3b',
  '53af0c53-03d3-477a-944e-a9bdfbe441fc','1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f',
  'c0de0000-0000-4000-8000-000000000501','c0de0000-0000-4000-8000-000000000502',
  'c0de0000-0000-4000-8000-000000000503','2099-09-01','correction-p-b22-fixture'
);

create temp table correction_p_test_control(step text not null) on commit drop;
create or replace function pg_temp.correction_p_test_raise()
returns trigger language plpgsql as $$
begin
  raise exception using errcode='P0001',message='CORRECTION_P_TEST_TRIGGER_FAILURE';
end;
$$;

create or replace function pg_temp.correction_p_fixture_residue_counts(p_operation_id uuid)
returns table(
  correction_count bigint,
  effect_count bigint,
  replacement_request_count bigint,
  fixed_item_count bigint,
  projection_count bigint,
  authorization_count bigint,
  statement_cycle_count bigint,
  statement_revision_count bigint,
  advance_payment_count bigint
)
language sql stable
set search_path=pg_catalog,public,pg_temp
as $$
  with scoped_corrections as (
    select c.id
    from public.home_external_transaction_corrections c
    where c.operation_id=p_operation_id
       or c.original_home_request_id='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc'
       or c.original_home_transaction_id='01e910b8-bf54-486c-a13a-597ca9dbf684'
       or c.school_expense_id='ed23a346-2ba5-47fb-a496-4c4ba781ec86'
       or c.school_attempt_id='b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5'
  )
  select
    (select count(*) from scoped_corrections),
    (select count(*)
     from public.home_account_correction_entries e
     where e.correction_id in (select id from scoped_corrections)
        or (e.original_transaction_id='01e910b8-bf54-486c-a13a-597ca9dbf684'
            and e.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6')),
    (select count(*)
     from public.home_external_transaction_requests r
     where r.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
       and r.request_type='expense_fixed_correction_p'
       and (
         r.correction_id in (select id from scoped_corrections)
         or (
           r.payload_snapshot->>'original_home_request_id'='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc'
           and r.payload_snapshot->>'original_home_transaction_id'='01e910b8-bf54-486c-a13a-597ca9dbf684'
           and r.payload_snapshot->>'school_expense_id'='ed23a346-2ba5-47fb-a496-4c4ba781ec86'
           and r.payload_snapshot->>'school_attempt_id'='b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5'
         )
       )),
    (select count(*)
     from public.home_fixed_month_items i
     where i.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
       and i.template_id is null
       and i.month_key='2099-09'
       and i.currency='JPY'
       and i.direction='expense'
       and i.name='correction-p-b22-fixture'
       and i.payment_group='邮局卡'
       and i.due_date='2099-09-25'
       and i.accounting_scope='school'),
    (select count(*)
     from public.home_external_fixed_payment_projections p
     where p.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
       and p.school_expense_id='ed23a346-2ba5-47fb-a496-4c4ba781ec86'
       and p.card_instrument_id='9b27347e-2dce-4caf-bac0-67f053ef6c3b'
       and p.funding_payment_channel_id='53af0c53-03d3-477a-944e-a9bdfbe441fc'
       and p.charge_date='2099-08-13'
       and p.target_fixed_month='2099-09-01'
       and p.original_amount=202991
       and p.original_currency='JPY'),
    (select count(*)
     from public.home_correction_replacement_authorizations a
     where a.original_transaction_id='01e910b8-bf54-486c-a13a-597ca9dbf684'
       and a.actor_id='25331ae9-3412-48b9-bdc3-e516caeaeba4'
       and a.card_instrument_id='9b27347e-2dce-4caf-bac0-67f053ef6c3b'
       and a.payment_channel_id='53af0c53-03d3-477a-944e-a9bdfbe441fc'
       and (a.operation_id=p_operation_id
            or a.correction_id in (select id from scoped_corrections))),
    (select count(*)
     from public.home_card_statement_cycles s
     where (s.id='c0de0000-0000-4000-8000-000000000501'
            or (s.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
                and s.card_instrument_id='9b27347e-2dce-4caf-bac0-67f053ef6c3b'
                and s.target_fixed_month='2099-09-01'))),
    (select count(*)
     from public.home_card_statement_cycle_revisions r
     left join public.home_card_statement_cycles s on s.id=r.cycle_id
     where r.id='c0de0000-0000-4000-8000-000000000502'
        or (r.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
            and s.card_instrument_id='9b27347e-2dce-4caf-bac0-67f053ef6c3b'
            and s.target_fixed_month='2099-09-01')),
    (select count(*)
     from public.home_fixed_advance_payments a
     where a.id='c0de0000-0000-4000-8000-000000000503'
        or (a.user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
            and a.month_key='2099-09'
            and a.currency='JPY'
            and a.payment_group='邮局卡'
            and a.account_id='b06f29c4-67cd-4d55-b39c-7cff0eab99a1'));
$$;

create or replace function pg_temp.correction_p_assert_no_fixture_residue(
  p_operation_id uuid,
  p_step text
)
returns void language plpgsql
set search_path=pg_catalog,public,pg_temp
as $$
declare v record;
begin
  select * into v from pg_temp.correction_p_fixture_residue_counts(p_operation_id);
  if row(v.correction_count,v.effect_count,v.replacement_request_count,
         v.fixed_item_count,v.projection_count,v.authorization_count,
         v.statement_cycle_count,v.statement_revision_count,v.advance_payment_count)
     is distinct from row(0::bigint,0::bigint,0::bigint,0::bigint,0::bigint,
                          0::bigint,0::bigint,0::bigint,0::bigint) then
    raise exception 'HOME_CORRECTION_P_SCOPED_RESIDUE:%/%/%/%/%/%/%/%/%/%',
      p_step,v.correction_count,v.effect_count,v.replacement_request_count,
      v.fixed_item_count,v.projection_count,v.authorization_count,
      v.statement_cycle_count,v.statement_revision_count,v.advance_payment_count;
  end if;
end;
$$;

create or replace function pg_temp.correction_p_assert_fixture_category_zero(
  p_operation_id uuid,
  p_category text
)
returns void language plpgsql
set search_path=pg_catalog,public,pg_temp
as $$
declare v record; n bigint;
begin
  select * into v from pg_temp.correction_p_fixture_residue_counts(p_operation_id);
  n:=case p_category
    when 'correction' then v.correction_count
    when 'effect' then v.effect_count
    when 'replacement_request' then v.replacement_request_count
    when 'fixed_item' then v.fixed_item_count
    when 'projection' then v.projection_count
    when 'authorization' then v.authorization_count
    when 'statement_cycle' then v.statement_cycle_count
    when 'statement_revision' then v.statement_revision_count
    when 'advance_payment' then v.advance_payment_count
    else null end;
  if n is null then
    raise exception 'HOME_CORRECTION_P_UNKNOWN_RESIDUE_CATEGORY:%',p_category;
  elsif n<>0 then
    raise exception 'HOME_CORRECTION_P_SCOPED_CATEGORY_RESIDUE:%/%',p_category,n;
  end if;
end;
$$;

insert into public.home_fixed_month_items(
  id,user_id,template_id,month_key,currency,direction,name,amount,status,
  account_id,payment_group,due_date,note,accounting_scope
) values
('c0de0000-0000-4000-8000-00000000f101','c0de0000-0000-4000-8000-00000000ee01',null,
 '2098-01','JPY','expense','correction-p-b22-unrelated-1',11,'unpaid',null,
 'unrelated-group','2098-01-25','correction-p-b22-unrelated','household'),
('c0de0000-0000-4000-8000-00000000f102','c0de0000-0000-4000-8000-00000000ee01',null,
 '2098-02','JPY','expense','correction-p-b22-unrelated-2',12,'unpaid',null,
 'unrelated-group','2098-02-25','correction-p-b22-unrelated','household'),
('c0de0000-0000-4000-8000-00000000f103','c0de0000-0000-4000-8000-00000000ee01',null,
 '2098-03','JPY','expense','correction-p-b22-unrelated-3',13,'unpaid',null,
 'unrelated-group','2098-03-25','correction-p-b22-unrelated','household'),
('c0de0000-0000-4000-8000-00000000f104','c0de0000-0000-4000-8000-00000000ee01',null,
 '2098-04','JPY','expense','correction-p-b22-unrelated-4',14,'unpaid',null,
 'unrelated-group','2098-04-25','correction-p-b22-unrelated','household');

insert into public.home_fixed_month_items(
  id,user_id,template_id,month_key,currency,direction,name,amount,status,
  account_id,payment_group,due_date,note,accounting_scope
) values (
  'c0de0000-0000-4000-8000-00000000ee21','c0de0000-0000-4000-8000-00000000ee01',
  'c0de0000-0000-4000-8000-00000000ee04','2098-10','JPY','expense',
  'correction-p-b22-unrelated-statement',88,'unpaid',null,'B2.2 unrelated channel',
  '2098-10-24','correction-p-b22-unrelated','household'
);
select set_config('home.phase3e_cycle_write','on',true);
insert into public.home_card_statement_cycles(
  id,user_id,card_instrument_id,target_fixed_month,settlement_currency,
  amount_status,household_remainder_fixed_item_id,version
) values (
  'c0de0000-0000-4000-8000-00000000ee22','c0de0000-0000-4000-8000-00000000ee01',
  'c0de0000-0000-4000-8000-00000000ee05','2098-10-01','JPY','pending',
  'c0de0000-0000-4000-8000-00000000ee21',0
);
select set_config('home.phase3e_cycle_write','off',true);
select set_config('home.phase3e_revision_write','on',true);
insert into public.home_card_statement_cycle_revisions(
  id,user_id,cycle_id,cycle_version,action,statement_total_amount,
  school_subtotal_amount,household_remainder_amount,school_manifest,
  school_manifest_fingerprint,household_remainder_fixed_item_id,
  household_item_amount_before,household_item_amount_after,actor_id,
  reason,operation_idempotency_key,payload_fingerprint
) values (
  'c0de0000-0000-4000-8000-00000000ee23','c0de0000-0000-4000-8000-00000000ee01',
  'c0de0000-0000-4000-8000-00000000ee22',1,'confirm',88,0,88,'[]'::jsonb,
  repeat('2',64),'c0de0000-0000-4000-8000-00000000ee21',88,88,
  '25331ae9-3412-48b9-bdc3-e516caeaeba4',null,
  'correction-p-b22-unrelated:revision',repeat('3',64)
);
select set_config('home.phase3e_revision_write','off',true);
insert into public.home_fixed_advance_payments(
  id,user_id,month_key,currency,payment_group,account_id,amount,status,paid_at,note,accounting_scope
) values (
  'c0de0000-0000-4000-8000-00000000ee24','c0de0000-0000-4000-8000-00000000ee01',
  '2098-12','JPY','b22-unrelated-group','c0de0000-0000-4000-8000-00000000ee02',
  88,'pending','2098-12-24','correction-p-b22-unrelated','household'
);

create or replace function pg_temp.correction_p_unrelated_fingerprint()
returns text language sql stable
set search_path=pg_catalog,public,pg_temp
as $$
  select md5(string_agg(x.payload,'' order by x.kind,x.id))
  from (
    select 'request' kind,r.id::text id,to_jsonb(r)::text payload from public.home_external_transaction_requests r where r.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'transaction',t.id::text,to_jsonb(t)::text from public.home_jpy_transactions t where t.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'correction',c.id::text,to_jsonb(c)::text from public.home_external_transaction_corrections c
      where c.original_home_request_id in (select r.id from public.home_external_transaction_requests r where r.user_id='c0de0000-0000-4000-8000-00000000ee01')
    union all select 'effect',e.id::text,to_jsonb(e)::text from public.home_account_correction_entries e where e.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'fixed',i.id::text,to_jsonb(i)::text from public.home_fixed_month_items i where i.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'projection',p.id::text,to_jsonb(p)::text from public.home_external_fixed_payment_projections p where p.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'cycle',s.id::text,to_jsonb(s)::text from public.home_card_statement_cycles s where s.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'revision',v.id::text,to_jsonb(v)::text from public.home_card_statement_cycle_revisions v where v.user_id='c0de0000-0000-4000-8000-00000000ee01'
    union all select 'advance',a.id::text,to_jsonb(a)::text from public.home_fixed_advance_payments a where a.user_id='c0de0000-0000-4000-8000-00000000ee01'
  ) x;
$$;

do $residue_detector_control$
declare
  r jsonb;
  detector_rejected boolean:=false;
  category text;
  category_rejected boolean;
  authorization_rejected boolean:=false;
begin
  begin
    r:=public.home_prepare_external_transaction_correction_p(
      'c0de0000-0000-4000-8000-0000000000f1','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
      '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
      'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
      '25331ae9-3412-48b9-bdc3-e516caeaeba4');
    if not coalesce((r->>'ok')::boolean,false) then
      raise exception 'HOME_CORRECTION_P_RESIDUE_CONTROL_PREPARE_FAILED:%',r;
    end if;
    begin
      perform pg_temp.correction_p_assert_no_fixture_residue(
        'c0de0000-0000-4000-8000-0000000000f1','anti-weakening-control');
    exception when others then
      if sqlerrm like 'HOME_CORRECTION_P_SCOPED_RESIDUE:anti-weakening-control/%' then
        detector_rejected:=true;
      else
        raise;
      end if;
    end;
    if not detector_rejected then
      raise exception 'HOME_CORRECTION_P_RESIDUE_DETECTOR_WAS_WEAKENED';
    end if;
    foreach category in array array['correction','effect','replacement_request','fixed_item','projection'] loop
      category_rejected:=false;
      begin
        perform pg_temp.correction_p_assert_fixture_category_zero(
          'c0de0000-0000-4000-8000-0000000000f1',category);
      exception when others then
        if sqlerrm='HOME_CORRECTION_P_SCOPED_CATEGORY_RESIDUE:'||category||'/1' then
          category_rejected:=true;
        else
          raise;
        end if;
      end;
      if not category_rejected then
        raise exception 'HOME_CORRECTION_P_CATEGORY_DETECTOR_WAS_WEAKENED:%',category;
      end if;
    end loop;
    begin
      insert into public.home_correction_replacement_authorizations(
        original_transaction_id,operation_id,correction_id,request_id,actor_id,
        replacement_type,fixed_month,card_instrument_id,payment_channel_id
      ) values (
        '01e910b8-bf54-486c-a13a-597ca9dbf684','c0de0000-0000-4000-8000-0000000000f1',
        (r->>'correction_id')::uuid,'c0de0000-0000-4000-8000-000000000504',
        '25331ae9-3412-48b9-bdc3-e516caeaeba4','expense_fixed_correction_p','2099-09-01',
        '9b27347e-2dce-4caf-bac0-67f053ef6c3b','53af0c53-03d3-477a-944e-a9bdfbe441fc'
      );
      perform pg_temp.correction_p_assert_fixture_category_zero(
        'c0de0000-0000-4000-8000-0000000000f1','authorization');
    exception when others then
      if sqlerrm='HOME_CORRECTION_P_SCOPED_CATEGORY_RESIDUE:authorization/1' then
        authorization_rejected:=true;
      else
        raise;
      end if;
    end;
    if not authorization_rejected then
      raise exception 'HOME_CORRECTION_P_AUTHORIZATION_DETECTOR_WAS_WEAKENED';
    end if;
    perform pg_temp.correction_p_assert_fixture_category_zero(
      'c0de0000-0000-4000-8000-0000000000f1','authorization');
    raise exception 'HOME_CORRECTION_P_EXPECTED_CONTROL_ROLLBACK';
  exception when others then
    if sqlerrm<>'HOME_CORRECTION_P_EXPECTED_CONTROL_ROLLBACK' then raise; end if;
  end;
  perform pg_temp.correction_p_assert_no_fixture_residue(
    'c0de0000-0000-4000-8000-0000000000f1','anti-weakening-control-after-rollback');
  if (select count(*) from public.home_fixed_month_items
      where id in ('c0de0000-0000-4000-8000-00000000f101',
                   'c0de0000-0000-4000-8000-00000000f102',
                   'c0de0000-0000-4000-8000-00000000f103',
                   'c0de0000-0000-4000-8000-00000000f104'))<>4 then
    raise exception 'HOME_CORRECTION_P_UNRELATED_CONTROL_MISSING';
  end if;
end;
$residue_detector_control$;

do $statement_revision_advance_residue_controls$
declare rejected boolean;
begin
  -- Statement cycle: a fixture-scoped fact must trip only the cycle category.
  rejected:=false;
  begin
    insert into public.home_fixed_month_items(
      id,user_id,template_id,month_key,currency,direction,name,amount,status,
      account_id,payment_group,due_date,note,accounting_scope
    ) values (
      'c0de0000-0000-4000-8000-000000000505','8596a708-d99f-4264-8f8c-5b89af9254b6',
      '1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f','2099-09','JPY','expense',
      'correction-p-b22-fixture',0,'unpaid',null,'邮局卡','2099-09-25',
      'correction-p-b22-fixture','household'
    );
    perform set_config('home.phase3e_cycle_write','on',true);
    insert into public.home_card_statement_cycles(
      id,user_id,card_instrument_id,target_fixed_month,settlement_currency,
      amount_status,household_remainder_fixed_item_id,version
    ) values (
      'c0de0000-0000-4000-8000-000000000501','8596a708-d99f-4264-8f8c-5b89af9254b6',
      '9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-09-01','JPY','pending',
      'c0de0000-0000-4000-8000-000000000505',0
    );
    perform set_config('home.phase3e_cycle_write','off',true);
    perform pg_temp.correction_p_assert_fixture_category_zero(
      'c0de0000-0000-4000-8000-000000000001','statement_cycle');
  exception when others then
    if sqlerrm='HOME_CORRECTION_P_SCOPED_CATEGORY_RESIDUE:statement_cycle/1' then rejected:=true; else raise; end if;
  end;
  if not rejected then raise exception 'HOME_CORRECTION_P_CYCLE_DETECTOR_WAS_WEAKENED'; end if;
  perform pg_temp.correction_p_assert_fixture_category_zero('c0de0000-0000-4000-8000-000000000001','statement_cycle');

  -- Revision: the prerequisite cycle and the revision are both rolled back by
  -- the exception subtransaction after the category-specific stable error.
  rejected:=false;
  begin
    insert into public.home_fixed_month_items(
      id,user_id,template_id,month_key,currency,direction,name,amount,status,
      account_id,payment_group,due_date,note,accounting_scope
    ) values (
      'c0de0000-0000-4000-8000-000000000505','8596a708-d99f-4264-8f8c-5b89af9254b6',
      '1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f','2099-09','JPY','expense',
      'correction-p-b22-fixture',0,'unpaid',null,'邮局卡','2099-09-25',
      'correction-p-b22-fixture','household'
    );
    perform set_config('home.phase3e_cycle_write','on',true);
    insert into public.home_card_statement_cycles(
      id,user_id,card_instrument_id,target_fixed_month,settlement_currency,
      amount_status,household_remainder_fixed_item_id,version
    ) values (
      'c0de0000-0000-4000-8000-000000000501','8596a708-d99f-4264-8f8c-5b89af9254b6',
      '9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-09-01','JPY','pending',
      'c0de0000-0000-4000-8000-000000000505',0
    );
    perform set_config('home.phase3e_cycle_write','off',true);
    perform set_config('home.phase3e_revision_write','on',true);
    insert into public.home_card_statement_cycle_revisions(
      id,user_id,cycle_id,cycle_version,action,statement_total_amount,
      school_subtotal_amount,household_remainder_amount,school_manifest,
      school_manifest_fingerprint,household_remainder_fixed_item_id,
      household_item_amount_before,household_item_amount_after,actor_id,
      reason,operation_idempotency_key,payload_fingerprint
    ) values (
      'c0de0000-0000-4000-8000-000000000502','8596a708-d99f-4264-8f8c-5b89af9254b6',
      'c0de0000-0000-4000-8000-000000000501',1,'confirm',0,0,0,'[]'::jsonb,
      repeat('4',64),'c0de0000-0000-4000-8000-000000000505',0,0,
      '25331ae9-3412-48b9-bdc3-e516caeaeba4',
      null,'correction-p-b22:revision-control',repeat('5',64)
    );
    perform set_config('home.phase3e_revision_write','off',true);
    perform pg_temp.correction_p_assert_fixture_category_zero(
      'c0de0000-0000-4000-8000-000000000001','statement_revision');
  exception when others then
    if sqlerrm='HOME_CORRECTION_P_SCOPED_CATEGORY_RESIDUE:statement_revision/1' then rejected:=true; else raise; end if;
  end;
  if not rejected then raise exception 'HOME_CORRECTION_P_REVISION_DETECTOR_WAS_WEAKENED'; end if;
  perform pg_temp.correction_p_assert_fixture_category_zero('c0de0000-0000-4000-8000-000000000001','statement_revision');
  perform pg_temp.correction_p_assert_fixture_category_zero('c0de0000-0000-4000-8000-000000000001','statement_cycle');

  rejected:=false;
  begin
    insert into public.home_fixed_advance_payments(
      id,user_id,month_key,currency,payment_group,account_id,amount,status,paid_at,note,accounting_scope
    ) values (
      'c0de0000-0000-4000-8000-000000000503','8596a708-d99f-4264-8f8c-5b89af9254b6',
      '2099-09','JPY','邮局卡','b06f29c4-67cd-4d55-b39c-7cff0eab99a1',
      1,'pending','2099-09-25','correction-p-b22-fixture','school'
    );
    perform pg_temp.correction_p_assert_fixture_category_zero(
      'c0de0000-0000-4000-8000-000000000001','advance_payment');
  exception when others then
    if sqlerrm='HOME_CORRECTION_P_SCOPED_CATEGORY_RESIDUE:advance_payment/1' then rejected:=true; else raise; end if;
  end;
  if not rejected then raise exception 'HOME_CORRECTION_P_ADVANCE_DETECTOR_WAS_WEAKENED'; end if;
  perform pg_temp.correction_p_assert_fixture_category_zero('c0de0000-0000-4000-8000-000000000001','advance_payment');
end;
$statement_revision_advance_residue_controls$;

do $prepare_failure_injection$
declare
  step text;
  target_table text;
  operation_id uuid;
  unrelated_before text;
  unrelated_after text;
begin
  unrelated_before:=pg_temp.correction_p_unrelated_fingerprint();
  foreach step in array array['after_correction','after_effect','after_request','after_item','after_projection'] loop
    target_table:=case step
      when 'after_correction' then 'home_external_transaction_corrections'
      when 'after_effect' then 'home_account_correction_entries'
      when 'after_request' then 'home_external_transaction_requests'
      when 'after_item' then 'home_fixed_month_items'
      else 'home_external_fixed_payment_projections' end;
    operation_id:=case step
      when 'after_correction' then 'c0de0000-0000-4000-8000-0000000000a1'::uuid
      when 'after_effect' then 'c0de0000-0000-4000-8000-0000000000a2'::uuid
      when 'after_request' then 'c0de0000-0000-4000-8000-0000000000a3'::uuid
      when 'after_item' then 'c0de0000-0000-4000-8000-0000000000a4'::uuid
      else 'c0de0000-0000-4000-8000-0000000000a5'::uuid end;
    execute format('create trigger correction_p_test_failure after insert on public.%I for each row execute function pg_temp.correction_p_test_raise()',target_table);
    begin
      perform public.home_prepare_external_transaction_correction_p(
        operation_id,'ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
        '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
        'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
        '25331ae9-3412-48b9-bdc3-e516caeaeba4');
      raise exception 'HOME_CORRECTION_P_FAILURE_INJECTION_MISSED:%',step;
    exception when others then
      if sqlerrm like 'HOME_CORRECTION_P_FAILURE_INJECTION_MISSED:%' then raise; end if;
    end;
    execute format('drop trigger correction_p_test_failure on public.%I',target_table);
    perform pg_temp.correction_p_assert_no_fixture_residue(operation_id,step);
    unrelated_after:=pg_temp.correction_p_unrelated_fingerprint();
    if unrelated_after is distinct from unrelated_before then
      raise exception 'HOME_CORRECTION_P_UNRELATED_CONTROL_CHANGED:%',step;
    end if;
  end loop;
end;
$prepare_failure_injection$;

do $prepare$
declare
  v_result jsonb;
  v_replay jsonb;
  v_schedule record;
begin
  select * into v_schedule from public.home_calculate_card_fixed_schedule(
    '9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-08-13');
  if v_schedule.suggested_fixed_month<>'2099-09-01' or v_schedule.funding_date<>'2099-09-25' then
    raise exception 'HOME_CORRECTION_P_SCHEDULE_INVALID';
  end if;
  v_result:=public.home_prepare_external_transaction_correction_p(
    'c0de0000-0000-4000-8000-000000000001','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
    '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
    '25331ae9-3412-48b9-bdc3-e516caeaeba4');
  if not coalesce((v_result->>'ok')::boolean,false) or v_result->>'status'<>'prepared'
     or (v_result->'replacement'->>'fixed_item_month_key')<>'2099-09'
     or (v_result->'replacement'->>'fixed_item_due_date')<>'2099-09-25'
     or (v_result->'replacement'->>'fixed_item_payment_group')<>'邮局卡'
     or (v_result->'replacement'->>'projection_funding_status')<>'unfunded'
     or v_result->'replacement'->>'funding_account_id' is not null
     or v_result->'replacement'->>'funding_transaction_id' is not null then
    raise exception 'HOME_CORRECTION_P_PREPARE_INVALID:%',v_result;
  end if;
  v_replay:=public.home_prepare_external_transaction_correction_p(
    'c0de0000-0000-4000-8000-000000000001','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
    '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
    '25331ae9-3412-48b9-bdc3-e516caeaeba4');
  if not coalesce((v_replay->>'idempotent')::boolean,false)
     or v_replay->>'correction_id'<>v_result->>'correction_id'
     or (select count(*) from public.home_external_transaction_corrections c
         where c.operation_id='c0de0000-0000-4000-8000-000000000001')<>1
     or (select count(*) from public.home_account_correction_entries e
         where e.correction_id=(v_result->>'correction_id')::uuid)<>1
     or (select count(*) from public.home_external_transaction_requests r
         where r.correction_id=(v_result->>'correction_id')::uuid)<>1
     or (select count(*) from public.home_external_fixed_payment_projections p
         where p.id=(v_result->'replacement'->>'projection_id')::uuid)<>1 then
    raise exception 'HOME_CORRECTION_P_REPLAY_INVALID';
  end if;
  v_replay:=public.home_prepare_external_transaction_correction_p(
    'c0de0000-0000-4000-8000-000000000001','ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
    '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('d',64),
    '25331ae9-3412-48b9-bdc3-e516caeaeba4');
  if v_replay->>'code'<>'HOME_CORRECTION_OPERATION_PAYLOAD_CONFLICT' then
    raise exception 'HOME_CORRECTION_P_CONFLICT_NOT_STABLE:%',v_replay;
  end if;
  v_replay:=public.home_create_external_fixed_transaction_request(
    '8596a708-d99f-4264-8f8c-5b89af9254b6','aozora_school',
    'c0de0000-0000-4000-8000-000000000301','school_expense_records',
    'c0de0000-0000-4000-8000-000000000302','expense_paid','expense',
    '9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-08-13','2099-09-01',
    '2099-09-01','2099-09-25',1000,'JPY','correction-p:general-gate-negative',
    'general fixed must remain blocked','',jsonb_build_object(
      'external_source','aozora_school','external_reference_type','school_expense_records',
      'external_reference_id','c0de0000-0000-4000-8000-000000000302',
      'request_type','expense_paid','transaction_type','expense','payment_route','fixed_credit_card',
      'card_instrument_id','9b27347e-2dce-4caf-bac0-67f053ef6c3b','charge_date','2099-08-13',
      'suggested_fixed_month','2099-09-01','target_fixed_month','2099-09-01',
      'funding_date','2099-09-25','school_attempt_payload_fingerprint',repeat('e',64)
    ));
  if v_replay->>'code'<>'HOME_FIXED_CARD_ROUTE_DISABLED' then
    raise exception 'HOME_CORRECTION_P_GENERAL_GATE_BYPASS:%',v_replay;
  end if;
end;
$prepare$;

create or replace function public.correction_p_test_future_definer_insert()
returns void language plpgsql security definer
set search_path=pg_catalog,public as $$
declare r public.home_external_transaction_requests%rowtype;
begin
  select * into r from public.home_external_transaction_requests
  where user_id='8596a708-d99f-4264-8f8c-5b89af9254b6'
    and request_type='expense_fixed_correction_p'
    and payload_snapshot->>'operation_id'='c0de0000-0000-4000-8000-000000000001';
  insert into public.home_external_transaction_requests(
    id,user_id,external_source,external_event_id,external_reference_type,
    external_reference_id,request_type,transaction_type,currency,amount,
    account_id,transacted_at,status,requested_at,idempotency_key,payload_snapshot,
    description,note,created_at,updated_at,accounting_scope,payment_route,
    card_instrument_id,charge_date,suggested_fixed_month,target_fixed_month,
    fixed_month_override_reason,funding_account_id,fixed_projection_id,
    projection_status,correction_id
  ) values (
    gen_random_uuid(),r.user_id,r.external_source,r.external_event_id,r.external_reference_type,
    r.external_reference_id,r.request_type,r.transaction_type,r.currency,r.amount,
    r.account_id,r.transacted_at,'pending',statement_timestamp(),
    'correction-p:forged:'||gen_random_uuid(),r.payload_snapshot,r.description,r.note,
    statement_timestamp(),statement_timestamp(),r.accounting_scope,r.payment_route,
    r.card_instrument_id,r.charge_date,r.suggested_fixed_month,r.target_fixed_month,
    r.fixed_month_override_reason,r.funding_account_id,null,'pending',r.correction_id
  );
end;
$$;
revoke all on function public.correction_p_test_future_definer_insert() from public,anon,authenticated;
grant execute on function public.correction_p_test_future_definer_insert() to service_role;

do $request_forgery$
declare denied integer:=0; original_id uuid; original_tx text; original_request text;
begin
  select id::text into original_id from public.home_external_transaction_corrections
  where operation_id='c0de0000-0000-4000-8000-000000000001';
  original_request:=md5((select to_jsonb(r)::text from public.home_external_transaction_requests r where id='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc'));
  original_tx:=md5((select to_jsonb(t)::text from public.home_jpy_transactions t where id='01e910b8-bf54-486c-a13a-597ca9dbf684'));
  perform set_config('home.fixed_request_month_override_writer','enabled',true);
  begin perform public.correction_p_test_future_definer_insert();
  exception when sqlstate '42501' then denied:=denied+1; end;
  if denied<>1
     or (select count(*) from public.home_external_transaction_requests where correction_id=original_id)<>1
     or (select correction_id from public.home_external_transaction_requests where id='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc') is not null
     or md5((select to_jsonb(r)::text from public.home_external_transaction_requests r where id='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc'))<>original_request
     or md5((select to_jsonb(t)::text from public.home_jpy_transactions t where id='01e910b8-bf54-486c-a13a-597ca9dbf684'))<>original_tx
     or exists(select 1 from public.home_correction_replacement_authorizations a
               where a.original_transaction_id='01e910b8-bf54-486c-a13a-597ca9dbf684'
                 and a.operation_id='c0de0000-0000-4000-8000-000000000001') then
    raise exception 'HOME_CORRECTION_P_REQUEST_FORGERY_NOT_BLOCKED';
  end if;
end;
$request_forgery$;

set local role authenticated;
do $prepared_readers$
declare p jsonb; y jsonb; a jsonb;
begin
  p:=public.home_get_fixed_month_page('2099-09','JPY');
  y:=public.home_get_year_summary(2099);
  a:=public.home_get_jpy_account_page('2099-08');
  if jsonb_array_length(p->'expense_items')<>0
     or (select (x->>'jpy_casual_expense')::numeric from jsonb_array_elements(y->'months') x where x->>'month_key'='2099-08')<>202991
     or (select (x->>'jpy_fixed_amount')::numeric from jsonb_array_elements(y->'months') x where x->>'month_key'='2099-09')<>0
     or (select (x->>'current_balance')::numeric from jsonb_array_elements(a->'accounts') x where x->>'id'='b06f29c4-67cd-4d55-b39c-7cff0eab99a1')<>-202991
     or (select x->>'correction_status' from jsonb_array_elements(a->'transactions') x where x->>'id'='01e910b8-bf54-486c-a13a-597ca9dbf684')<>'prepared' then
    raise exception 'HOME_CORRECTION_P_PREPARED_READER_SWITCHED_EARLY';
  end if;
end;
$prepared_readers$;
reset role;

do $complete$
declare c public.home_external_transaction_corrections%rowtype; e_id uuid:=gen_random_uuid(); t timestamptz:=statement_timestamp(); fp text; s jsonb; r jsonb; step text; a jsonb; authorization_count bigint;
begin
  select * into c from public.home_external_transaction_corrections
  where operation_id='c0de0000-0000-4000-8000-000000000001';
  fp:=public.home_correction_p_evidence_fingerprint_v1(
    e_id,c.id,c.operation_id,c.correction_type,c.original_home_request_id,
    c.original_home_transaction_id,c.balance_effect_id,c.replacement_request_id,
    c.replacement_fixed_item_id,c.replacement_projection_id,c.school_expense_id,
    c.school_attempt_id,c.amount,c.currency,c.original_effective_date,c.accounting_scope,
    c.external_event_id,c.original_idempotency_key,c.school_fingerprint,c.home_payload_hash,
    c.replacement_fingerprint,c.actor_id,t);
  s:=jsonb_build_object('ok',true,'school_evidence_id',e_id,'operation_id',c.operation_id,
    'home_correction_id',c.id,'correction_type',c.correction_type,
    'original_home_request_id',c.original_home_request_id,
    'original_home_transaction_id',c.original_home_transaction_id,
    'home_balance_effect_id',c.balance_effect_id,'replacement_request_id',c.replacement_request_id,
    'replacement_fixed_item_id',c.replacement_fixed_item_id,
    'replacement_projection_id',c.replacement_projection_id,'school_expense_id',c.school_expense_id,
    'school_attempt_id',c.school_attempt_id,'amount',c.amount,'currency',c.currency,
    'charge_date',c.original_effective_date,'accounting_scope',c.accounting_scope,
    'external_event_id',c.external_event_id,'original_idempotency_key',c.original_idempotency_key,
    'school_fingerprint',c.school_fingerprint,'home_payload_hash',c.home_payload_hash,
    'replacement_fingerprint',c.replacement_fingerprint,'actor_id',c.actor_id,
    'school_finalized_at',t,'school_evidence_fingerprint',fp);
  foreach step in array array['before_complete','after_complete'] loop
    execute format(
      'create trigger correction_p_test_complete_failure %s update on public.home_external_transaction_corrections for each row when (new.status=''' || 'completed' || ''') execute function pg_temp.correction_p_test_raise()',
      case step when 'before_complete' then 'before' else 'after' end
    );
    begin
      perform public.home_complete_external_transaction_correction_p(
        c.id,c.operation_id,e_id,fp,t,c.actor_id,s);
      raise exception 'HOME_CORRECTION_P_COMPLETE_FAILURE_INJECTION_MISSED:%',step;
    exception when others then
      if sqlerrm like 'HOME_CORRECTION_P_COMPLETE_FAILURE_INJECTION_MISSED:%' then raise; end if;
    end;
    drop trigger correction_p_test_complete_failure
      on public.home_external_transaction_corrections;
    if (select status from public.home_external_transaction_corrections where id=c.id)<>'prepared'
       or (select completed_at from public.home_external_transaction_corrections where id=c.id) is not null
       or (select school_evidence_id from public.home_external_transaction_corrections where id=c.id) is not null
       or (select school_evidence_fingerprint from public.home_external_transaction_corrections where id=c.id) is not null
       or (select school_evidence_snapshot from public.home_external_transaction_corrections where id=c.id) is not null then
      raise exception 'HOME_CORRECTION_P_COMPLETE_FAILURE_NOT_ROLLED_BACK:%',step;
    end if;
    select x.authorization_count into authorization_count
    from pg_temp.correction_p_fixture_residue_counts(c.operation_id) x;
    a:=public.home_get_jpy_account_page('2099-08');
    if authorization_count<>0
       or (select (x->>'current_balance')::numeric
           from jsonb_array_elements(a->'accounts') x
           where x->>'id'='b06f29c4-67cd-4d55-b39c-7cff0eab99a1')<>-202991
       or (select x->>'correction_status'
           from jsonb_array_elements(a->'transactions') x
           where x->>'id'='01e910b8-bf54-486c-a13a-597ca9dbf684')<>'prepared' then
      raise exception 'HOME_CORRECTION_P_COMPLETE_FAILURE_READER_OR_AUTH_CHANGED:%',step;
    end if;
  end loop;
  r:=public.home_complete_external_transaction_correction_p(c.id,c.operation_id,e_id,fp,t,c.actor_id,s);
  if not coalesce((r->>'ok')::boolean,false) or r->>'status'<>'completed' then
    raise exception 'HOME_CORRECTION_P_COMPLETE_INVALID:%',r;
  end if;
  r:=public.home_complete_external_transaction_correction_p(c.id,c.operation_id,e_id,fp,t,c.actor_id,s);
  if not coalesce((r->>'idempotent')::boolean,false) then
    raise exception 'HOME_CORRECTION_P_COMPLETE_REPLAY_INVALID:%',r;
  end if;
  select x.authorization_count into authorization_count
  from pg_temp.correction_p_fixture_residue_counts(c.operation_id) x;
  if authorization_count<>0 then
    raise exception 'HOME_CORRECTION_P_AUTHORIZATION_RESIDUE';
  end if;
end;
$complete$;

set local role authenticated;
do $completed_readers$
declare p jsonb; y jsonb; a jsonb;
begin
  p:=public.home_get_fixed_month_page('2099-09','JPY');
  y:=public.home_get_year_summary(2099);
  a:=public.home_get_jpy_account_page('2099-08');
  if jsonb_array_length(p->'expense_items')<>1
     or (p->'metrics'->>'expense')::numeric<>203000
     or (select (x->>'jpy_casual_expense')::numeric from jsonb_array_elements(y->'months') x where x->>'month_key'='2099-08')<>0
     or (select (x->>'jpy_fixed_amount')::numeric from jsonb_array_elements(y->'months') x where x->>'month_key'='2099-09')<>203000
     or (select (x->>'current_balance')::numeric from jsonb_array_elements(a->'accounts') x where x->>'id'='b06f29c4-67cd-4d55-b39c-7cff0eab99a1')<>0
     or (select (x->>'is_corrected')::boolean from jsonb_array_elements(a->'transactions') x where x->>'id'='01e910b8-bf54-486c-a13a-597ca9dbf684') is not true then
    raise exception 'HOME_CORRECTION_P_COMPLETED_READER_INVALID:%/%/%',p,y,a;
  end if;
end;
$completed_readers$;
reset role;

do $completed_statement_manifest$
declare m jsonb;
begin
  m:=public.home_build_card_statement_school_manifest(
    '8596a708-d99f-4264-8f8c-5b89af9254b6',
    '9b27347e-2dce-4caf-bac0-67f053ef6c3b','2099-09-01');
  if m->>'school_item_count'<>'1' or (m->>'school_subtotal')::numeric<>202991 then
    raise exception 'HOME_CORRECTION_P_COMPLETED_MANIFEST_INVALID:%',m;
  end if;
end;
$completed_statement_manifest$;

do $immutability$
declare c public.home_external_transaction_corrections%rowtype; denied int:=0; r jsonb;
  unrelated_before text:=pg_temp.correction_p_unrelated_fingerprint();
begin
  select * into c from public.home_external_transaction_corrections
  where operation_id='c0de0000-0000-4000-8000-000000000001';
  begin update public.home_external_transaction_corrections set amount=1 where id=c.id;
  exception when sqlstate '42501' then denied:=denied+1; end;
  begin delete from public.home_account_correction_entries where correction_id=c.id;
  exception when sqlstate '42501' then denied:=denied+1; end;
  begin delete from public.home_external_transaction_corrections where id=c.id;
  exception when sqlstate '42501' then denied:=denied+1; end;
  r:=public.home_delete_fixed_month_item(c.replacement_fixed_item_id);
  if denied<>3 or r->>'code'<>'HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN'
     or (select status from public.home_external_transaction_requests where id=c.original_home_request_id)<>'approved'
     or (select count(*) from public.home_jpy_transactions where id=c.original_home_transaction_id)<>1
     or (select x.statement_cycle_count from pg_temp.correction_p_fixture_residue_counts(c.operation_id) x)<>0
     or (select x.statement_revision_count from pg_temp.correction_p_fixture_residue_counts(c.operation_id) x)<>0
     or (select x.advance_payment_count from pg_temp.correction_p_fixture_residue_counts(c.operation_id) x)<>0
     or pg_temp.correction_p_unrelated_fingerprint() is distinct from unrelated_before
     or (select is_school_fixed_route_enabled from public.home_card_instruments where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b') then
    raise exception 'HOME_CORRECTION_P_IMMUTABILITY_OR_ZERO_SIDE_EFFECT_INVALID';
  end if;
end;
$immutability$;

rollback;
