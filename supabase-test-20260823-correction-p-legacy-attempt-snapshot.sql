-- Phase E-Compat-Rapid local PostgreSQL 17 matrix. The caller installs a
-- production schema-only clone and the compatibility migration. Nothing is
-- retained: every case uses a PL/pgSQL subtransaction and the file rolls back.

begin;

insert into auth.users(id) values
  ('8596a708-d99f-4264-8f8c-5b89af9254b6'),
  ('25331ae9-3412-48b9-bdc3-e516caeaeba4');

insert into public.home_accounts(
  id,user_id,currency,name,account_type,opening_balance,is_active,allow_school_requests
) values (
  'b06f29c4-67cd-4d55-b39c-7cff0eab99a1','8596a708-d99f-4264-8f8c-5b89af9254b6',
  'JPY','compat cash','cash',0,true,true
);
insert into public.home_payment_channels(
  id,user_id,currency,name,default_due_day,is_active
) values (
  '53af0c53-03d3-477a-944e-a9bdfbe441fc','8596a708-d99f-4264-8f8c-5b89af9254b6',
  'JPY','compat channel',25,true
);
insert into public.home_fixed_templates(
  id,user_id,currency,direction,name,fixed_type,default_amount,payment_group,
  due_day,start_month,is_active,accounting_scope
) values (
  '1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f','8596a708-d99f-4264-8f8c-5b89af9254b6',
  'JPY','expense','compat card expense','long_term',0,'compat channel',25,'2099-01',true,'household'
);
insert into public.home_card_instruments(
  id,user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,
  funding_payment_channel_id,household_statement_template_id,is_active,
  is_school_fixed_route_enabled,version
) values (
  '9b27347e-2dce-4caf-bac0-67f053ef6c3b','8596a708-d99f-4264-8f8c-5b89af9254b6',
  'compat card','JPY',10,true,25,'53af0c53-03d3-477a-944e-a9bdfbe441fc',
  '1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f',true,false,1
);

create or replace function pg_temp.compat_insert_source(
  p_payload jsonb,
  p_request_amount numeric default 202991,
  p_transaction_amount numeric default 202991
)
returns void
language plpgsql
as $fixture$
begin
  insert into public.home_jpy_transactions(
    id,user_id,transaction_type,account_id,transacted_at,amount,description,note,
    external_source,external_source_id,external_event_type,external_idempotency_key,
    external_reference_type,external_reference_id,external_payload_hash,
    external_created_at,created_by_external,accounting_scope
  ) values (
    '01e910b8-bf54-486c-a13a-597ca9dbf684','8596a708-d99f-4264-8f8c-5b89af9254b6',
    'expense','b06f29c4-67cd-4d55-b39c-7cff0eab99a1','2099-08-13',p_transaction_amount,
    'compat fixture','compat fixture','aozora_school','fa3aad38-5886-4154-a7d4-8c8331fb71fe',
    'expense_paid','aozora_school:school_expense_records:ed23a346-2ba5-47fb-a496-4c4ba781ec86:expense_paid:attempt:1',
    'school_expense_records','ed23a346-2ba5-47fb-a496-4c4ba781ec86',md5(p_payload::text),
    statement_timestamp(),true,'school'
  );
  insert into public.home_external_transaction_requests(
    id,user_id,external_source,external_event_id,external_reference_type,
    external_reference_id,request_type,transaction_type,currency,amount,account_id,
    transacted_at,status,approved_at,created_transaction_id,idempotency_key,
    payload_snapshot,description,note,accounting_scope,payment_route,projection_status
  )
  select
    'ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc','8596a708-d99f-4264-8f8c-5b89af9254b6',
    'aozora_school','fa3aad38-5886-4154-a7d4-8c8331fb71fe','school_expense_records',
    'ed23a346-2ba5-47fb-a496-4c4ba781ec86','expense_paid','expense','JPY',p_request_amount,
    'b06f29c4-67cd-4d55-b39c-7cff0eab99a1','2099-08-13','approved',statement_timestamp(),
    '01e910b8-bf54-486c-a13a-597ca9dbf684',
    'aozora_school:school_expense_records:ed23a346-2ba5-47fb-a496-4c4ba781ec86:expense_paid:attempt:1',
    p_payload,'compat fixture','compat fixture','school','immediate_account','not_applicable';
end;
$fixture$;

insert into public.home_external_correction_route_policies(
  id,operation_kind,user_id,accounting_scope,currency,card_instrument_id,
  payment_channel_id,effective_from,is_active,approved_by,approval_reference
) values (
  'c0de0000-0000-4000-8000-000000000401','school_expense_immediate_to_fixed',
  '8596a708-d99f-4264-8f8c-5b89af9254b6','school','JPY',
  '9b27347e-2dce-4caf-bac0-67f053ef6c3b','53af0c53-03d3-477a-944e-a9bdfbe441fc',
  '2099-01-01',true,'25331ae9-3412-48b9-bdc3-e516caeaeba4','compat local fixture'
);

select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
select set_config('request.jwt.claim.role','service_role',true);

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
    raise exception 'COMPAT_RAPID_ACL_INVALID';
  end if;
end;
$acl$;

do $matrix$
declare
  v_base jsonb:=jsonb_build_object(
    'external_source','aozora_school',
    'external_event_id','fa3aad38-5886-4154-a7d4-8c8331fb71fe',
    'external_reference_type','school_expense_records',
    'external_reference_id','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
    'request_type','expense_paid','transaction_type','expense',
    'payment_route','immediate_account','year_month','2099-08',
    'expense_category','classroom','source_type','manual_cash',
    'school_attempt_id','b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',
    'school_attempt_payload_fingerprint',repeat('a',64)
  );
  v_case record;
  v_payload jsonb;
  v_result jsonb;
  v_replay jsonb;
  v_operation_id uuid;
  v_request_before text;
  v_transaction_before text;
  v_correction_id uuid;
begin
  for v_case in
    select * from (values
      (1,'both_absent',v_base-'school_attempt_id'-'school_attempt_payload_fingerprint',true),
      (2,'modern_exact',v_base,true),
      (3,'attempt_only_absent',v_base-'school_attempt_id',false),
      (4,'fingerprint_only_absent',v_base-'school_attempt_payload_fingerprint',false),
      (5,'both_null',jsonb_set(jsonb_set(v_base,'{school_attempt_id}','null'::jsonb),'{school_attempt_payload_fingerprint}','null'::jsonb),false),
      (6,'both_empty',jsonb_set(jsonb_set(v_base,'{school_attempt_id}','""'::jsonb),'{school_attempt_payload_fingerprint}','""'::jsonb),false),
      (7,'attempt_mismatch',jsonb_set(v_base,'{school_attempt_id}',to_jsonb('c0de0000-0000-4000-8000-000000000777'::text)),false),
      (8,'fingerprint_mismatch',jsonb_set(v_base,'{school_attempt_payload_fingerprint}',to_jsonb(repeat('b',64))),false)
    ) as cases(case_no,case_name,payload,expect_ok)
    order by case_no
  loop
    begin
      v_payload:=v_case.payload;
      v_operation_id:=('c0de0000-0000-4000-8000-'||lpad((100+v_case.case_no)::text,12,'0'))::uuid;
      perform pg_temp.compat_insert_source(v_payload);
      select md5(to_jsonb(r)::text) into v_request_before
      from public.home_external_transaction_requests r
      where r.id='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc';
      select md5(to_jsonb(t)::text) into v_transaction_before
      from public.home_jpy_transactions t
      where t.id='01e910b8-bf54-486c-a13a-597ca9dbf684';

      v_result:=public.home_prepare_external_transaction_correction_p(
        v_operation_id,'ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
        '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
        'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
        '25331ae9-3412-48b9-bdc3-e516caeaeba4'
      );

      if v_case.expect_ok then
        if not coalesce((v_result->>'ok')::boolean,false) or v_result->>'status'<>'prepared' then
          raise exception 'COMPAT_RAPID_SUCCESS_CASE_REJECTED:%:%',v_case.case_name,v_result;
        end if;
        v_correction_id:=(v_result->>'correction_id')::uuid;
        if (select md5(to_jsonb(r)::text) from public.home_external_transaction_requests r
              where r.id='ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc') is distinct from v_request_before
           or (select md5(to_jsonb(t)::text) from public.home_jpy_transactions t
              where t.id='01e910b8-bf54-486c-a13a-597ca9dbf684') is distinct from v_transaction_before
           or (select count(*) from public.home_external_transaction_corrections c where c.operation_id=v_operation_id)<>1
           or (select count(*) from public.home_account_correction_entries e where e.correction_id=v_correction_id)<>1
           or (select count(*) from public.home_external_transaction_requests r where r.correction_id=v_correction_id)<>1
           or (select count(*) from public.home_fixed_month_items i where i.id=(v_result->'replacement'->>'fixed_item_id')::uuid)<>1
           or (select count(*) from public.home_external_fixed_payment_projections p where p.id=(v_result->'replacement'->>'projection_id')::uuid)<>1
           or (select count(*) from public.home_correction_replacement_authorizations a where a.correction_id=v_correction_id)<>0 then
          raise exception 'COMPAT_RAPID_SUCCESS_INTEGRITY_INVALID:%',v_case.case_name;
        end if;
        v_replay:=public.home_prepare_external_transaction_correction_p(
          v_operation_id,'ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
          '01e910b8-bf54-486c-a13a-597ca9dbf684','ed23a346-2ba5-47fb-a496-4c4ba781ec86',
          'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
          '25331ae9-3412-48b9-bdc3-e516caeaeba4'
        );
        if not coalesce((v_replay->>'idempotent')::boolean,false)
           or v_replay->>'correction_id'<>v_result->>'correction_id'
           or (select count(*) from public.home_external_transaction_corrections c where c.operation_id=v_operation_id)<>1 then
          raise exception 'COMPAT_RAPID_REPLAY_INVALID:%:%',v_case.case_name,v_replay;
        end if;
      else
        if v_result->>'code'<>'HOME_CORRECTION_ORIGINAL_REQUEST_MISMATCH'
           or exists(select 1 from public.home_external_transaction_corrections c where c.operation_id=v_operation_id) then
          raise exception 'COMPAT_RAPID_NEGATIVE_CASE_NOT_BLOCKED:%:%',v_case.case_name,v_result;
        end if;
      end if;
      raise exception 'COMPAT_RAPID_CASE_ROLLBACK';
    exception when others then
      if sqlerrm<>'COMPAT_RAPID_CASE_ROLLBACK' then raise; end if;
    end;
  end loop;

  -- Cross-record identities and immutable transaction facts stay strict.
  for v_case in
    select * from (values
      (9,'school_expense_mismatch'),
      (10,'request_amount_mismatch'),
      (11,'transaction_amount_mismatch')
    ) as cases(case_no,case_name)
  loop
    begin
      v_operation_id:=('c0de0000-0000-4000-8000-'||lpad((100+v_case.case_no)::text,12,'0'))::uuid;
      perform pg_temp.compat_insert_source(
        v_base,
        case when v_case.case_no=10 then 202992 else 202991 end,
        case when v_case.case_no=11 then 202992 else 202991 end
      );
      v_result:=public.home_prepare_external_transaction_correction_p(
        v_operation_id,'ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc',
        '01e910b8-bf54-486c-a13a-597ca9dbf684',
        case when v_case.case_no=9 then 'c0de0000-0000-4000-8000-000000000999'::uuid
             else 'ed23a346-2ba5-47fb-a496-4c4ba781ec86'::uuid end,
        'b6c8a4ca-0a27-4e4c-aae3-7498d0c18cd5',repeat('a',64),
        '25331ae9-3412-48b9-bdc3-e516caeaeba4'
      );
      if v_result->>'code' not in ('HOME_CORRECTION_ORIGINAL_REQUEST_MISMATCH','HOME_CORRECTION_ORIGINAL_TRANSACTION_MISMATCH')
         or exists(select 1 from public.home_external_transaction_corrections c where c.operation_id=v_operation_id) then
        raise exception 'COMPAT_RAPID_CROSS_RECORD_CASE_NOT_BLOCKED:%:%',v_case.case_name,v_result;
      end if;
      raise exception 'COMPAT_RAPID_CASE_ROLLBACK';
    exception when others then
      if sqlerrm<>'COMPAT_RAPID_CASE_ROLLBACK' then raise; end if;
    end;
  end loop;
end;
$matrix$;

do $final_zero_residue$
begin
  if exists(select 1 from public.home_external_transaction_corrections)
     or exists(select 1 from public.home_account_correction_entries)
     or exists(select 1 from public.home_external_transaction_requests where correction_id is not null)
     or exists(select 1 from public.home_external_fixed_payment_projections)
     or exists(select 1 from public.home_correction_replacement_authorizations) then
    raise exception 'COMPAT_RAPID_FINAL_RESIDUE_NOT_ZERO';
  end if;
end;
$final_zero_residue$;

select 'COMPAT_RAPID_LOCAL_MATRIX_PASS' as result,11 as case_count;

rollback;
