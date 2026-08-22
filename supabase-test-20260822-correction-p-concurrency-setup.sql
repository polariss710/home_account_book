-- Correction-P Home isolated PostgreSQL 17 matrix. Caller has installed the
-- production schema clone plus the local migration. This file retains nothing.

begin;

insert into auth.users(id) values
  ('8596a708-d99f-4264-8f8c-5b89af9254b6'),
  ('25331ae9-3412-48b9-bdc3-e516caeaeba4');
insert into public.home_accounts(id,user_id,currency,name,account_type,opening_balance,is_active,allow_school_requests)
values ('b06f29c4-67cd-4d55-b39c-7cff0eab99a1','8596a708-d99f-4264-8f8c-5b89af9254b6','JPY','日元现金','cash',0,true,true);
insert into public.home_payment_channels(id,user_id,currency,name,default_due_day,is_active)
values ('53af0c53-03d3-477a-944e-a9bdfbe441fc','8596a708-d99f-4264-8f8c-5b89af9254b6','JPY','邮局卡',25,true);
insert into public.home_fixed_templates(id,user_id,currency,direction,name,fixed_type,default_amount,payment_group,due_day,start_month,is_active,accounting_scope)
values ('1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f','8596a708-d99f-4264-8f8c-5b89af9254b6','JPY','expense','西武卡消费','long_term',0,'邮局卡',25,'2026-01',true,'household');
insert into public.home_card_instruments(id,user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,funding_payment_channel_id,household_statement_template_id,is_active,is_school_fixed_route_enabled,version)
values ('9b27347e-2dce-4caf-bac0-67f053ef6c3b','8596a708-d99f-4264-8f8c-5b89af9254b6','西武卡','JPY',10,true,25,'53af0c53-03d3-477a-944e-a9bdfbe441fc','1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f',true,false,1);
insert into public.home_external_correction_route_policies(
  id,operation_kind,user_id,accounting_scope,currency,card_instrument_id,
  payment_channel_id,effective_from,is_active,approved_by,approval_reference
) values (
  'c0de0000-0000-4000-8000-000000000401','school_expense_immediate_to_fixed',
  '8596a708-d99f-4264-8f8c-5b89af9254b6','school','JPY',
  '9b27347e-2dce-4caf-bac0-67f053ef6c3b','53af0c53-03d3-477a-944e-a9bdfbe441fc',
  '2026-01-01',true,'25331ae9-3412-48b9-bdc3-e516caeaeba4','local concurrency fixture'
);

do $fixture$
declare
  v_payload jsonb:=jsonb_build_object(
    'external_source','aozora_school','external_event_id','fa3aad38-5886-4154-a7d4-8c8331fb71fe',
    'external_reference_type','school_expense_records','external_reference_id','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'request_type','expense_paid','transaction_type','expense','payment_route','immediate_account',
    'year_month','2026-08','expense_category','classroom','source_type','manual_cash',
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
    'expense','b06f29c4-67cd-4d55-b39c-7cff0eab99a1','2026-08-13',202991,
    '教室租金','Correction-P target','aozora_school','fa3aad38-5886-4154-a7d4-8c8331fb71fe',
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
    'b06f29c4-67cd-4d55-b39c-7cff0eab99a1','2026-08-13','approved',statement_timestamp(),
    '01e910b8-bf54-486c-a13a-597ca9dbf684',
    'aozora_school:school_expense_records:ed23a346-2ba5-47fb-a496-4c4ba781ec86:expense_paid:attempt:1',
    v_payload,'教室租金','Correction-P target','school','immediate_account','not_applicable'
  );
end;
$fixture$;

commit;
