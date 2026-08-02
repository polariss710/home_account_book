-- Cash external transaction immutability rollback matrix, 2026-08-02.
-- Every fixture write is transaction-local and must ROLLBACK.
\set ON_ERROR_STOP on
\pset pager off

begin;
set local lock_timeout = '10s';
set local statement_timeout = '180s';

create temporary table immutability_test_results (
  test_no integer primary key,
  result text not null,
  detail text not null
) on commit drop;
grant select, insert, update on immutability_test_results to authenticated;

insert into public.home_accounts (
  id, user_id, currency, name, account_type, opening_balance,
  is_active, sort_order, allow_school_requests
) values
  ('f3f10000-0000-4000-8000-00000000c001', '8596a708-d99f-4264-8f8c-5b89af9254b6',
   'CNY', 'codex-test external immutable CNY', 'bank', 0, true, 9101, true),
  ('f3f10000-0000-4000-8000-00000000c002', '8596a708-d99f-4264-8f8c-5b89af9254b6',
   'JPY', 'codex-test external immutable JPY', 'bank', 0, true, 9102, true);

select set_config('request.jwt.claims', '{"role":"service_role"}', true);

do $external_fixtures$
declare
  v_request jsonb;
  v_jpy jsonb;
begin
  select public.home_create_external_transaction_request(
    '8596a708-d99f-4264-8f8c-5b89af9254b6',
    'f3f10000-0000-4000-8000-00000000c001',
    'aozora_school', 'f3f10000-0000-4000-8000-00000000e001',
    'school_income_records', 'f3f10000-0000-4000-8000-00000000e002',
    'tuition_income_received', 'income', date '2099-08-02', 1120.50,
    'codex-test:external-immutable:cny:attempt:1',
    'codex-test immutable CNY approve', 'codex-test rollback only',
    jsonb_build_object('payment_currency', 'CNY', 'payment_amount', 1120.50),
    'CNY'
  ) into v_request;

  if coalesce((v_request ->> 'ok')::boolean, false) is not true
     or coalesce((v_request ->> 'inserted')::boolean, false) is not true then
    raise exception 'fixture CNY request creation failed: %', v_request;
  end if;

  select public.home_create_external_jpy_transaction(
    '8596a708-d99f-4264-8f8c-5b89af9254b6',
    'f3f10000-0000-4000-8000-00000000c002',
    'income', date '2099-08-02', 2000,
    'codex-test immutable JPY', 'codex-test rollback only',
    'aozora_school', 'f3f10000-0000-4000-8000-00000000e003',
    'tuition_income_received', 'codex-test:external-immutable:jpy:attempt:1',
    'school_income_records', 'f3f10000-0000-4000-8000-00000000e004',
    'codex-test rollback only', md5('codex-test immutable JPY')
  ) into v_jpy;

  if coalesce((v_jpy ->> 'ok')::boolean, false) is not true
     or coalesce((v_jpy ->> 'inserted')::boolean, false) is not true then
    raise exception 'fixture JPY writer failed: %', v_jpy;
  end if;

  insert into immutability_test_results values
    (22, 'PASS', 'existing controlled external writer created CNY request and JPY transaction fixtures');
end;
$external_fixtures$;

select set_config(
  'request.jwt.claims',
  '{"role":"authenticated","sub":"8596a708-d99f-4264-8f8c-5b89af9254b6"}',
  true
);
set local role authenticated;

do $ordinary_crud$
declare
  v_result jsonb;
begin
  insert into public.home_cny_transactions (
    id, user_id, currency, transaction_type, account_id, transfer_account_id,
    transacted_at, amount, description, note, created_at, created_by_external
  ) values (
    'f3f10000-0000-4000-8000-00000000d101',
    '8596a708-d99f-4264-8f8c-5b89af9254b6', 'CNY', 'income',
    'f3f10000-0000-4000-8000-00000000c001', null,
    date '2099-08-02', 10.25, 'codex-test manual CNY', 'rollback only', now(), false
  );
  insert into immutability_test_results values
    (1, 'PASS', 'authenticated inserted ordinary CNY transaction');

  select public.home_update_cny_transaction(
    'f3f10000-0000-4000-8000-00000000d101',
    'f3f10000-0000-4000-8000-00000000c001', null,
    date '2099-08-03', 11.25, 'codex-test manual CNY updated', 'rollback only updated'
  ) into v_result;
  if coalesce((v_result ->> 'ok')::boolean, false) is not true
     or (select amount from public.home_cny_transactions
         where id = 'f3f10000-0000-4000-8000-00000000d101') <> 11.25 then
    raise exception 'ordinary CNY update failed: %', v_result;
  end if;
  insert into immutability_test_results values
    (2, 'PASS', 'authenticated updated own ordinary CNY transaction');

  insert into public.home_cny_transactions (
    id, user_id, currency, transaction_type, account_id, transfer_account_id,
    transacted_at, amount, description, note, created_at, created_by_external
  )
  select
    'f3f10000-0000-4000-8000-00000000d102', user_id, currency,
    transaction_type, account_id, transfer_account_id, transacted_at, amount,
    description || ' copied', note, now(), false
  from public.home_cny_transactions
  where id = 'f3f10000-0000-4000-8000-00000000d101';
  if (select count(*) from public.home_cny_transactions
      where id = 'f3f10000-0000-4000-8000-00000000d102'
        and created_by_external is false
        and external_source is null
        and external_idempotency_key is null) <> 1 then
    raise exception 'ordinary CNY copy failed';
  end if;
  insert into immutability_test_results values
    (4, 'PASS', 'ordinary CNY transaction copied as a new ordinary transaction');

  select public.home_delete_cny_transaction(
    'f3f10000-0000-4000-8000-00000000d102'
  ) into v_result;
  if coalesce((v_result ->> 'ok')::boolean, false) is not true
     or exists (select 1 from public.home_cny_transactions
                where id = 'f3f10000-0000-4000-8000-00000000d102') then
    raise exception 'ordinary CNY delete failed: %', v_result;
  end if;
  insert into immutability_test_results values
    (3, 'PASS', 'authenticated deleted own ordinary CNY transaction');

  insert into public.home_jpy_transactions (
    id, user_id, currency, transaction_type, account_id, transfer_account_id,
    transacted_at, amount, description, note, created_at, created_by_external
  ) values (
    'f3f10000-0000-4000-8000-00000000d201',
    '8596a708-d99f-4264-8f8c-5b89af9254b6', 'JPY', 'income',
    'f3f10000-0000-4000-8000-00000000c002', null,
    date '2099-08-02', 1000, 'codex-test manual JPY', 'rollback only', now(), false
  );
  select public.home_update_jpy_transaction(
    'f3f10000-0000-4000-8000-00000000d201',
    'f3f10000-0000-4000-8000-00000000c002', null,
    date '2099-08-03', 1100, 'codex-test manual JPY updated', 'rollback only updated'
  ) into v_result;
  if coalesce((v_result ->> 'ok')::boolean, false) is not true then
    raise exception 'ordinary JPY update failed: %', v_result;
  end if;
  select public.home_delete_jpy_transaction(
    'f3f10000-0000-4000-8000-00000000d201'
  ) into v_result;
  if coalesce((v_result ->> 'ok')::boolean, false) is not true
     or exists (select 1 from public.home_jpy_transactions
                where id = 'f3f10000-0000-4000-8000-00000000d201') then
    raise exception 'ordinary JPY delete failed: %', v_result;
  end if;
  insert into immutability_test_results values
    (18, 'PASS', 'ordinary JPY insert/update/delete succeeded');
end;
$ordinary_crud$;

do $approve_idempotency$
declare
  v_request_id uuid;
  v_first jsonb;
  v_second jsonb;
  v_transaction_id uuid;
  v_count_before integer;
  v_count_after integer;
  v_sum_before numeric;
  v_sum_after numeric;
begin
  select id into strict v_request_id
  from public.home_external_transaction_requests
  where external_event_id = 'f3f10000-0000-4000-8000-00000000e001';

  select public.home_approve_external_transaction_request(v_request_id) into v_first;
  v_transaction_id := (v_first ->> 'transaction_id')::uuid;
  select count(*)::integer, sum(amount)
    into v_count_before, v_sum_before
  from public.home_cny_transactions
  where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002';

  select public.home_approve_external_transaction_request(v_request_id) into v_second;
  select count(*)::integer, sum(amount)
    into v_count_after, v_sum_after
  from public.home_cny_transactions
  where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002';

  if coalesce((v_first ->> 'ok')::boolean, false) is not true
     or coalesce((v_first ->> 'transaction_inserted')::boolean, false) is not true
     or (v_second ->> 'transaction_id')::uuid is distinct from v_transaction_id
     or coalesce((v_second ->> 'transaction_inserted')::boolean, true) is not false
     or v_count_before <> 1 or v_count_after <> 1
     or v_sum_before <> 1120.50 or v_sum_after <> 1120.50 then
    raise exception 'approve idempotency failed: first=% second=%', v_first, v_second;
  end if;

  insert into immutability_test_results values
    (23, 'PASS', 'approve created exactly one CNY transaction'),
    (24, 'PASS', 'repeat approve returned the same transaction without balance duplication');
end;
$approve_idempotency$;

do $external_rpc_guards$
declare
  v_cny uuid;
  v_jpy uuid;
  v_result jsonb;
begin
  select id into strict v_cny from public.home_cny_transactions
  where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002';
  select id into strict v_jpy from public.home_jpy_transactions
  where external_reference_id = 'f3f10000-0000-4000-8000-00000000e004';

  select public.home_update_cny_transaction(
    v_cny, 'f3f10000-0000-4000-8000-00000000c001', null,
    date '2099-08-02', 1, 'unchanged', 'unchanged'
  ) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external CNY amount update was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (5, 'PASS', 'external CNY amount update RPC rejected');

  select public.home_update_cny_transaction(
    v_cny, 'f3f10000-0000-4000-8000-00000000c001', null,
    date '2099-08-04', 1120.50, 'unchanged', 'unchanged'
  ) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external CNY date update was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (6, 'PASS', 'external CNY date update RPC rejected');

  select public.home_update_cny_transaction(
    v_cny, 'f3f10000-0000-4000-8000-00000000c002', null,
    date '2099-08-02', 1120.50, 'unchanged', 'unchanged'
  ) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external CNY account update was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (7, 'PASS', 'external CNY account update RPC rejected before account validation');

  select public.home_update_cny_transaction(
    v_cny, 'f3f10000-0000-4000-8000-00000000c001', null,
    date '2099-08-02', 1120.50, 'changed description', 'changed note'
  ) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external CNY text update was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (8, 'PASS', 'external CNY description/note update RPC rejected');

  select public.home_delete_cny_transaction(v_cny) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external CNY delete RPC was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (9, 'PASS', 'external CNY delete RPC rejected');

  select public.home_update_jpy_transaction(
    v_jpy, 'f3f10000-0000-4000-8000-00000000c002', null,
    date '2099-08-02', 1, 'changed', 'changed'
  ) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external JPY update RPC was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (19, 'PASS', 'external JPY update RPC rejected');

  select public.home_delete_jpy_transaction(v_jpy) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'external JPY delete RPC was not rejected: %', v_result;
  end if;
  insert into immutability_test_results values (20, 'PASS', 'external JPY delete RPC rejected');
end;
$external_rpc_guards$;

do $authenticated_direct_guards$
declare
  v_count integer;
  v_blocked boolean := false;
begin
  update public.home_cny_transactions
     set amount = 1
   where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002';
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception 'authenticated direct external CNY update affected % rows', v_count;
  end if;
  insert into immutability_test_results values (10, 'PASS', 'authenticated direct external CNY UPDATE rejected by RLS');

  delete from public.home_cny_transactions
   where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002';
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception 'authenticated direct external CNY delete affected % rows', v_count;
  end if;
  insert into immutability_test_results values (11, 'PASS', 'authenticated direct external CNY DELETE rejected by RLS');

  begin
    insert into public.home_cny_transactions (
      id, user_id, currency, transaction_type, account_id, transacted_at,
      amount, description, note, created_at, created_by_external,
      external_source, external_source_id, external_event_type,
      external_idempotency_key, external_reference_type, external_reference_id,
      external_payload_hash, external_created_at
    ) values (
      'f3f10000-0000-4000-8000-00000000d103',
      '8596a708-d99f-4264-8f8c-5b89af9254b6', 'CNY', 'income',
      'f3f10000-0000-4000-8000-00000000c001', date '2099-08-02',
      1, 'forged external', 'rollback only', now(), true,
      'aozora_school', 'f3f10000-0000-4000-8000-00000000e101',
      'tuition_income_received', 'forged-external-1', 'school_income_records',
      'f3f10000-0000-4000-8000-00000000e102', md5('forged'), now()
    );
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'authenticated forged created_by_external insert succeeded';
  end if;
  insert into immutability_test_results values (12, 'PASS', 'authenticated forged created_by_external insert rejected');

  v_blocked := false;
  begin
    insert into public.home_cny_transactions (
      id, user_id, currency, transaction_type, account_id, transacted_at,
      amount, description, note, created_at, created_by_external,
      external_source, external_reference_type, external_reference_id
    ) values (
      'f3f10000-0000-4000-8000-00000000d104',
      '8596a708-d99f-4264-8f8c-5b89af9254b6', 'CNY', 'income',
      'f3f10000-0000-4000-8000-00000000c001', date '2099-08-02',
      1, 'forged metadata', 'rollback only', now(), false,
      'aozora_school', 'school_income_records',
      'f3f10000-0000-4000-8000-00000000e104'
    );
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'authenticated forged external metadata insert succeeded';
  end if;
  insert into immutability_test_results values (13, 'PASS', 'authenticated forged external metadata insert rejected');

  v_blocked := false;
  begin
    insert into public.home_cny_transactions (
      id, user_id, currency, transaction_type, account_id, transacted_at,
      amount, description, note, created_at, created_by_external, external_note
    ) values (
      'f3f10000-0000-4000-8000-00000000d105',
      '8596a708-d99f-4264-8f8c-5b89af9254b6', 'CNY', 'income',
      'f3f10000-0000-4000-8000-00000000c001', date '2099-08-02',
      1, 'forged external note', 'rollback only', now(), false,
      'forged external metadata'
    );
  exception when others then
    v_blocked := true;
  end;
  if not v_blocked then
    raise exception 'authenticated forged external_note insert succeeded';
  end if;

  update public.home_jpy_transactions
     set amount = 1
   where external_reference_id = 'f3f10000-0000-4000-8000-00000000e004';
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception 'authenticated direct external JPY update affected % rows', v_count;
  end if;
  delete from public.home_jpy_transactions
   where external_reference_id = 'f3f10000-0000-4000-8000-00000000e004';
  get diagnostics v_count = row_count;
  if v_count <> 0 then
    raise exception 'authenticated direct external JPY delete affected % rows', v_count;
  end if;
end;
$authenticated_direct_guards$;

reset role;
select set_config('request.jwt.claims', '{"role":"service_role"}', true);

do $owner_and_service_guards$
declare
  v_cny uuid;
  v_jpy uuid;
  v_result jsonb;
  v_blocked boolean;
begin
  select id into strict v_cny from public.home_cny_transactions
  where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002';
  select id into strict v_jpy from public.home_jpy_transactions
  where external_reference_id = 'f3f10000-0000-4000-8000-00000000e004';

  select public.home_update_cny_transaction(
    v_cny, 'f3f10000-0000-4000-8000-00000000c001', null,
    date '2099-08-02', 1, 'changed', 'changed'
  ) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'service role ordinary CNY update RPC not rejected: %', v_result;
  end if;
  select public.home_delete_cny_transaction(v_cny) into v_result;
  if v_result ->> 'code' <> 'EXTERNAL_TRANSACTION_IMMUTABLE' then
    raise exception 'service role ordinary CNY delete RPC not rejected: %', v_result;
  end if;
  insert into immutability_test_results values
    (16, 'PASS', 'service role ordinary update/delete RPCs cannot mutate external CNY transaction');

  v_blocked := false;
  begin
    update public.home_cny_transactions set amount = 1 where id = v_cny;
  exception when others then
    if sqlerrm = 'EXTERNAL_TRANSACTION_IMMUTABLE' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'owner direct CNY UPDATE bypassed trigger'; end if;

  v_blocked := false;
  begin
    delete from public.home_cny_transactions where id = v_cny;
  exception when others then
    if sqlerrm = 'EXTERNAL_TRANSACTION_IMMUTABLE' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'owner direct CNY DELETE bypassed trigger'; end if;

  v_blocked := false;
  begin
    update public.home_jpy_transactions set amount = 1 where id = v_jpy;
  exception when others then
    if sqlerrm = 'EXTERNAL_TRANSACTION_IMMUTABLE' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'owner direct JPY UPDATE bypassed trigger'; end if;

  v_blocked := false;
  begin
    delete from public.home_jpy_transactions where id = v_jpy;
  exception when others then
    if sqlerrm = 'EXTERNAL_TRANSACTION_IMMUTABLE' then v_blocked := true; else raise; end if;
  end;
  if not v_blocked then raise exception 'owner direct JPY DELETE bypassed trigger'; end if;
end;
$owner_and_service_guards$;

do $catalog_contract$
declare
  v_public_execute boolean;
begin
  if has_function_privilege('anon',
       'public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)', 'EXECUTE')
     or has_function_privilege('anon',
       'public.home_delete_cny_transaction(uuid)', 'EXECUTE')
     or has_function_privilege('anon',
       'public.home_update_jpy_transaction(uuid,uuid,uuid,date,numeric,text,text)', 'EXECUTE')
     or has_function_privilege('anon',
       'public.home_delete_jpy_transaction(uuid)', 'EXECUTE') then
    raise exception 'anon still has ordinary update/delete RPC execute';
  end if;
  insert into immutability_test_results values (14, 'PASS', 'anon cannot execute ordinary update/delete RPCs');

  select exists (
    select 1
    from pg_proc p
    join pg_namespace n on n.oid = p.pronamespace
    cross join lateral aclexplode(coalesce(p.proacl, acldefault('f', p.proowner))) acl
    where n.nspname = 'public'
      and p.proname in (
        'home_update_cny_transaction', 'home_delete_cny_transaction',
        'home_update_jpy_transaction', 'home_delete_jpy_transaction'
      )
      and acl.grantee = 0
      and acl.privilege_type = 'EXECUTE'
  ) into v_public_execute;
  if v_public_execute then
    raise exception 'PUBLIC still has ordinary update/delete RPC execute';
  end if;
  insert into immutability_test_results values (15, 'PASS', 'PUBLIC cannot execute ordinary update/delete RPCs');

  if (select count(*) from pg_trigger t
      where t.tgrelid in ('public.home_cny_transactions'::regclass,
                          'public.home_jpy_transactions'::regclass)
        and t.tgname in ('home_cny_external_transaction_immutable',
                         'home_jpy_external_transaction_immutable')
        and t.tgenabled = 'O') <> 2
     or (select count(*) from pg_policies
         where schemaname = 'public'
           and tablename in ('home_cny_transactions', 'home_jpy_transactions')
           and policyname in (
             'home_cny_transactions_owner_select', 'home_cny_transactions_manual_insert',
             'home_cny_transactions_manual_update', 'home_cny_transactions_manual_delete',
             'home_jpy_transactions_owner_select', 'home_jpy_transactions_manual_insert',
             'home_jpy_transactions_manual_update', 'home_jpy_transactions_manual_delete'
           )) <> 8 then
    raise exception 'CNY/JPY trigger or RLS symmetry failed';
  end if;
  insert into immutability_test_results values (21, 'PASS', 'CNY/JPY trigger, RLS, ACL and RPC protections are symmetric');
end;
$catalog_contract$;

do $unchanged_external$
begin
  if not exists (
    select 1 from public.home_cny_transactions
    where external_reference_id = 'f3f10000-0000-4000-8000-00000000e002'
      and amount = 1120.50 and transacted_at = date '2099-08-02'
      and account_id = 'f3f10000-0000-4000-8000-00000000c001'
      and description = 'codex-test immutable CNY approve'
      and note = 'codex-test rollback only'
      and created_by_external is true
      and external_source = 'aozora_school'
      and external_idempotency_key = 'codex-test:external-immutable:cny:attempt:1'
  ) then
    raise exception 'external CNY fixture changed after rejected mutations';
  end if;
  insert into immutability_test_results values
    (17, 'PASS', 'external CNY fixture remained byte-stable across all rejected operations');
end;
$unchanged_external$;

select * from immutability_test_results order by test_no;
select count(*) as backend_pass_count
from immutability_test_results
where result = 'PASS';

rollback;

begin transaction read only;
select
  (select count(*) from public.home_accounts
   where id in ('f3f10000-0000-4000-8000-00000000c001',
                'f3f10000-0000-4000-8000-00000000c002'))
  +
  (select count(*) from public.home_external_transaction_requests
   where external_event_id in ('f3f10000-0000-4000-8000-00000000e001',
                               'f3f10000-0000-4000-8000-00000000e003'))
  +
  (select count(*) from public.home_cny_transactions
   where id::text like 'f3f10000-0000-4000-8000-00000000d%'
      or external_reference_id = 'f3f10000-0000-4000-8000-00000000e002')
  +
  (select count(*) from public.home_jpy_transactions
   where id::text like 'f3f10000-0000-4000-8000-00000000d%'
      or external_reference_id = 'f3f10000-0000-4000-8000-00000000e004')
  as fixture_residue;
rollback;
