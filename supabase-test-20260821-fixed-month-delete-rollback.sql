-- Phase B-Delete isolated rollback matrix.
-- The caller must apply the migration first, own BEGIN/ROLLBACK, and verify
-- zero fixture residue from a fresh connection after ROLLBACK.

create temporary table phaseb_delete_assertions (
  assertion_name text primary key
);

create or replace function pg_temp.phaseb_assert(p_condition boolean, p_name text)
returns void
language plpgsql
security definer
set search_path = pg_catalog, pg_temp
as $function$
begin
  if not coalesce(p_condition, false) then
    raise exception 'PHASEB_DELETE_ASSERTION_FAILED:%', p_name;
  end if;
  insert into pg_temp.phaseb_delete_assertions(assertion_name) values (p_name);
end;
$function$;

create or replace function pg_temp.phaseb_make_projection(
  p_target_month date,
  p_amount numeric,
  p_marker text
)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_schedule record;
  v_event_id uuid := gen_random_uuid();
  v_expense_id uuid := gen_random_uuid();
  v_request_result jsonb;
  v_approval_result jsonb;
  v_charge_date date := p_target_month + 8;
begin
  select * into v_card
  from public.home_card_instruments
  where name = '西武卡' and is_active
  order by version desc
  limit 1;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_card.id, v_charge_date);

  perform set_config('request.jwt.claim.role', 'service_role', true);
  select public.home_create_external_fixed_transaction_request(
    v_card.user_id,
    'aozora_school',
    v_event_id,
    'school_expense_records',
    v_expense_id,
    'expense_paid',
    'expense',
    v_card.id,
    v_charge_date,
    v_schedule.suggested_fixed_month,
    v_schedule.suggested_fixed_month,
    v_schedule.funding_date,
    p_amount,
    'JPY',
    'phaseb-delete:' || p_marker,
    'Phase B-Delete projection fixture',
    p_marker,
    jsonb_build_object(
      'external_source', 'aozora_school',
      'external_reference_type', 'school_expense_records',
      'external_reference_id', v_expense_id,
      'request_type', 'expense_paid',
      'transaction_type', 'expense',
      'payment_route', 'fixed_credit_card',
      'card_instrument_id', v_card.id,
      'charge_date', v_charge_date,
      'suggested_fixed_month', v_schedule.suggested_fixed_month,
      'target_fixed_month', v_schedule.suggested_fixed_month,
      'funding_date', v_schedule.funding_date,
      'year_month', to_char(p_target_month, 'YYYY-MM'),
      'school_attempt_payload_fingerprint', repeat('b', 64)
    )
  ) into v_request_result;

  if not coalesce((v_request_result ->> 'ok')::boolean, false) then
    raise exception 'PHASEB_DELETE_PROJECTION_REQUEST_FAILED:%', v_request_result;
  end if;

  perform set_config('request.jwt.claim.role', 'authenticated', true);
  select public.home_apply_external_fixed_transaction_approval(
    (v_request_result ->> 'request_id')::uuid,
    v_card.user_id
  ) into v_approval_result;

  if not coalesce((v_approval_result ->> 'ok')::boolean, false) then
    raise exception 'PHASEB_DELETE_PROJECTION_APPROVAL_FAILED:%', v_approval_result;
  end if;

  return v_approval_result;
end;
$function$;

create or replace function pg_temp.phaseb_make_funded_projection(
  p_target_month date,
  p_amount numeric,
  p_marker text
)
returns jsonb
language plpgsql
set search_path = pg_catalog, public, pg_temp
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_request public.home_external_transaction_requests%rowtype;
  v_schedule record;
  v_account uuid;
  v_item_id uuid := gen_random_uuid();
  v_projection_id uuid := gen_random_uuid();
  v_transaction_id uuid := gen_random_uuid();
  v_event_id uuid := gen_random_uuid();
  v_expense_id uuid := gen_random_uuid();
  v_request_result jsonb;
  v_charge_date date := p_target_month + 8;
begin
  select * into v_card
  from public.home_card_instruments
  where name='西武卡' and is_active
  order by version desc limit 1;
  select * into v_channel
  from public.home_payment_channels where id=v_card.funding_payment_channel_id;
  select id into v_account
  from public.home_accounts
  where user_id=v_card.user_id and currency=v_card.settlement_currency
    and is_active and allow_school_requests
  order by id limit 1;
  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_card.id,v_charge_date);

  perform set_config('request.jwt.claim.role','service_role',true);
  select public.home_create_external_fixed_transaction_request(
    v_card.user_id,'aozora_school',v_event_id,'school_expense_records',v_expense_id,
    'expense_paid','expense',v_card.id,v_charge_date,
    v_schedule.suggested_fixed_month,v_schedule.suggested_fixed_month,
    v_schedule.funding_date,p_amount,'JPY','phaseb2-delete:'||p_marker,
    'Phase B2 funded projection fixture',p_marker,
    jsonb_build_object(
      'external_source','aozora_school',
      'external_reference_type','school_expense_records',
      'external_reference_id',v_expense_id,
      'request_type','expense_paid',
      'transaction_type','expense',
      'payment_route','fixed_credit_card',
      'card_instrument_id',v_card.id,
      'charge_date',v_charge_date,
      'suggested_fixed_month',v_schedule.suggested_fixed_month,
      'target_fixed_month',v_schedule.suggested_fixed_month,
      'funding_date',v_schedule.funding_date,
      'year_month',to_char(p_target_month,'YYYY-MM'),
      'school_attempt_payload_fingerprint',repeat('c',64)
    )
  ) into v_request_result;
  if not coalesce((v_request_result->>'ok')::boolean,false) then
    raise exception 'PHASEB2_FUNDED_REQUEST_FAILED:%',v_request_result;
  end if;
  select * into v_request from public.home_external_transaction_requests
  where id=(v_request_result->>'request_id')::uuid;

  insert into public.home_fixed_month_items(
    id,user_id,month_key,currency,direction,name,amount,status,payment_group,
    due_date,note,accounting_scope
  ) values (
    v_item_id,v_card.user_id,to_char(v_schedule.suggested_fixed_month,'YYYY-MM'),
    'JPY','expense','Phase B2 funded item',p_amount,'unpaid',v_channel.name,
    v_schedule.funding_date,p_marker,'school'
  );
  insert into public.home_jpy_transactions(
    id,user_id,transaction_type,account_id,currency,transacted_at,amount,
    description,note,accounting_scope
  ) values (
    v_transaction_id,v_card.user_id,'expense',v_account,'JPY',v_schedule.funding_date,
    p_amount,'Phase B2 funded transaction',p_marker,'household'
  );
  insert into public.home_external_fixed_payment_projections(
    id,user_id,external_request_id,external_source,external_reference_type,
    external_reference_id,external_event_id,external_idempotency_key,
    school_expense_id,payment_route,card_instrument_id,funding_payment_channel_id,
    funding_account_id,business_month,charge_date,suggested_fixed_month,
    target_fixed_month,funding_date,original_amount,original_currency,
    settlement_amount,settlement_currency,settlement_amount_status,
    fixed_month_item_id,projection_status,funding_status,funding_transaction_id,
    approved_at,funded_at,version
  ) values (
    v_projection_id,v_request.user_id,v_request.id,v_request.external_source,
    v_request.external_reference_type,v_request.external_reference_id,
    v_request.external_event_id,v_request.idempotency_key,v_request.external_reference_id,
    'fixed_credit_card',v_card.id,v_channel.id,v_account,p_target_month,v_request.charge_date,
    v_request.suggested_fixed_month,v_request.target_fixed_month,v_schedule.funding_date,
    v_request.amount,v_request.currency,v_request.amount,v_request.currency,'confirmed',
    v_item_id,'projected','funded',v_transaction_id,statement_timestamp(),
    statement_timestamp(),1
  );

  return jsonb_build_object(
    'fixed_item_id',v_item_id,
    'fixed_projection_id',v_projection_id,
    'funding_transaction_id',v_transaction_id,
    'request_id',v_request.id
  );
end;
$function$;

do $catalog_contract$
declare
  v_core oid := 'public.home_delete_fixed_month_item_core(uuid,uuid,text)'::regprocedure;
  v_jpy oid := 'public.home_delete_fixed_month_item(uuid)'::regprocedure;
  v_cny oid := 'public.home_delete_cny_fixed_item(uuid)'::regprocedure;
  v_helper oid := 'public.home_check_fixed_month_item_delete_eligibility(public.home_fixed_month_items,uuid)'::regprocedure;
  v_guard oid := 'public.home_guard_fixed_month_item_delete_contract()'::regprocedure;
  v_policy_commands text[];
begin
  perform pg_temp.phaseb_assert(
    (select pg_get_userbyid(proowner) = 'postgres' and prosecdef
       and proconfig = array['search_path=pg_catalog, public']
     from pg_proc where oid = v_core),
    'core_owner_security_search_path'
  );
  perform pg_temp.phaseb_assert(
    not has_function_privilege('anon', v_core, 'EXECUTE')
      and not has_function_privilege('authenticated', v_core, 'EXECUTE')
      and not has_function_privilege('service_role', v_core, 'EXECUTE')
      and has_function_privilege('postgres', v_core, 'EXECUTE'),
    'core_owner_only_acl'
  );
  perform pg_temp.phaseb_assert(
    (select pg_get_userbyid(proowner)='postgres' and prosecdef
       and proconfig=array['search_path=pg_catalog, public']
     from pg_proc where oid=v_helper)
      and (select pg_get_userbyid(proowner)='postgres' and prosecdef
       and proconfig=array['search_path=pg_catalog, public']
     from pg_proc where oid=v_guard),
    'helper_guard_owner_security_search_path'
  );
  perform pg_temp.phaseb_assert(
    not has_function_privilege('anon',v_helper,'EXECUTE')
      and not has_function_privilege('authenticated',v_helper,'EXECUTE')
      and not has_function_privilege('service_role',v_helper,'EXECUTE')
      and not has_function_privilege('anon',v_guard,'EXECUTE')
      and not has_function_privilege('authenticated',v_guard,'EXECUTE')
      and not has_function_privilege('service_role',v_guard,'EXECUTE'),
    'helper_guard_owner_only_acl'
  );
  perform pg_temp.phaseb_assert(
    (select pg_get_userbyid(proowner) = 'postgres' and prosecdef
       and proconfig = array['search_path=pg_catalog, public']
     from pg_proc where oid = v_jpy),
    'jpy_wrapper_owner_security_search_path'
  );
  perform pg_temp.phaseb_assert(
    (select pg_get_userbyid(proowner) = 'postgres' and prosecdef
       and proconfig = array['search_path=pg_catalog, public']
     from pg_proc where oid = v_cny),
    'cny_wrapper_owner_security_search_path'
  );
  perform pg_temp.phaseb_assert(
    not has_function_privilege('public', v_jpy, 'EXECUTE')
      and not has_function_privilege('anon', v_jpy, 'EXECUTE')
      and has_function_privilege('authenticated', v_jpy, 'EXECUTE')
      and not has_function_privilege('service_role', v_jpy, 'EXECUTE'),
    'jpy_wrapper_acl'
  );
  perform pg_temp.phaseb_assert(
    not has_function_privilege('public', v_cny, 'EXECUTE')
      and not has_function_privilege('anon', v_cny, 'EXECUTE')
      and has_function_privilege('authenticated', v_cny, 'EXECUTE')
      and not has_function_privilege('service_role', v_cny, 'EXECUTE'),
    'cny_wrapper_acl'
  );
  perform pg_temp.phaseb_assert(
    has_table_privilege('authenticated', 'public.home_fixed_month_items', 'SELECT')
      and has_table_privilege('authenticated', 'public.home_fixed_month_items', 'INSERT')
      and has_table_privilege('authenticated', 'public.home_fixed_month_items', 'UPDATE'),
    'authenticated_select_insert_update_preserved'
  );
  perform pg_temp.phaseb_assert(
    not has_table_privilege('anon', 'public.home_fixed_month_items', 'DELETE')
      and not has_table_privilege('authenticated', 'public.home_fixed_month_items', 'DELETE')
      and not has_table_privilege('service_role', 'public.home_fixed_month_items', 'DELETE'),
    'client_direct_delete_revoked'
  );
  perform pg_temp.phaseb_assert(
    not has_table_privilege('anon', 'public.home_fixed_month_items', 'TRUNCATE')
      and not has_table_privilege('authenticated', 'public.home_fixed_month_items', 'TRUNCATE')
      and not has_table_privilege('service_role', 'public.home_fixed_month_items', 'TRUNCATE'),
    'client_truncate_revoked'
  );
  perform pg_temp.phaseb_assert(
    (select pg_get_userbyid(c.relowner)='postgres' and c.relrowsecurity
       and not c.relforcerowsecurity
     from pg_class c
     where c.oid='public.home_fixed_month_item_delete_authorizations'::regclass),
    'authorization_table_owner_rls'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1
      from pg_class c
      cross join lateral aclexplode(coalesce(c.relacl,acldefault('r',c.relowner))) x
      where c.oid='public.home_fixed_month_item_delete_authorizations'::regclass
        and x.grantee=0
    )
      and not has_table_privilege('anon','public.home_fixed_month_item_delete_authorizations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      and not has_table_privilege('authenticated','public.home_fixed_month_item_delete_authorizations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      and not has_table_privilege('service_role','public.home_fixed_month_item_delete_authorizations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE')
      and has_table_privilege('postgres','public.home_fixed_month_item_delete_authorizations','SELECT,INSERT,UPDATE,DELETE'),
    'authorization_table_client_zero_acl'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from pg_policy
      where polrelid='public.home_fixed_month_item_delete_authorizations'::regclass
    ),
    'authorization_table_has_no_client_policy'
  );
  perform pg_temp.phaseb_assert(
    (select relrowsecurity from pg_class where oid = 'public.home_fixed_month_items'::regclass),
    'fixed_items_rls_enabled'
  );
  select array_agg(polcmd order by polcmd) into v_policy_commands
  from pg_policy where polrelid = 'public.home_fixed_month_items'::regclass;
  perform pg_temp.phaseb_assert(
    v_policy_commands = array['a'::char, 'r'::char, 'w'::char]::text[],
    'rls_has_select_insert_update_only'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from pg_policy
      where polrelid = 'public.home_fixed_month_items'::regclass
        and polcmd in ('*', 'd')
    ),
    'rls_has_no_delete_policy'
  );
  perform pg_temp.phaseb_assert(
    exists (
      select 1 from pg_trigger
      where tgrelid = 'public.home_fixed_month_items'::regclass
        and tgname = 'home_fixed_month_items_projection_guard' and tgenabled = 'O'
    ) and exists (
      select 1 from pg_trigger
      where tgrelid = 'public.home_fixed_month_items'::regclass
        and tgname = 'zz_home_fixed_month_items_delete_contract_guard' and tgenabled = 'O'
    ),
    'projection_and_delete_contract_triggers_enabled'
  );
  perform pg_temp.phaseb_assert(
    (select array_agg(tgname order by tgname)
     from pg_trigger
     where tgrelid = 'public.home_fixed_month_items'::regclass
       and not tgisinternal
       and (tgtype::int & 8) = 8)
      @> array['home_fixed_month_items_projection_guard', 'zz_home_fixed_month_items_delete_contract_guard']::name[],
    'delete_trigger_order_is_deterministic'
  );
  perform pg_temp.phaseb_assert(
    (select count(*) from pg_constraint
     where contype = 'f'
       and confrelid = 'public.home_fixed_month_items'::regclass
       and conname in (
         'home_external_fixed_payment_projection_fixed_month_item_id_fkey',
         'home_card_statement_cycles_household_remainder_fixed_item__fkey',
         'home_card_statement_cycle_rev_household_remainder_fixed_it_fkey'
       ) and confdeltype = 'r') = 3,
    'protected_foreign_keys_remain_restrict'
  );
  perform pg_temp.phaseb_assert(
    (select confdeltype='r'
     from pg_constraint
     where conrelid='public.home_fixed_month_items'::regclass
       and conname='home_fixed_month_items_user_id_fkey'),
    'fixed_item_user_fk_restricts_history_delete'
  );
  perform pg_temp.phaseb_assert(
    position('home.fixed_month_item_delete_actor' in pg_get_functiondef(v_core))=0
      and position('home.fixed_month_item_delete_writer' in pg_get_functiondef(v_core))=0
      and position('current_setting' in pg_get_functiondef(v_guard))=0
      and position('set_config' in pg_get_functiondef(v_core))=0,
    'delete_authorization_has_no_custom_guc_dependency'
  );
  perform pg_temp.phaseb_assert(
    (select pronargs=1 and proargtypes[0]='uuid'::regtype from pg_proc where oid=v_jpy)
      and (select pronargs=1 and proargtypes[0]='uuid'::regtype from pg_proc where oid=v_cny),
    'wrappers_accept_item_id_only'
  );
  perform pg_temp.phaseb_assert(
    not has_table_privilege('authenticated', 'public.home_external_fixed_payment_projections', 'SELECT')
      and not has_table_privilege('authenticated', 'public.home_card_statement_cycles', 'SELECT')
      and not has_table_privilege('authenticated', 'public.home_card_statement_cycle_revisions', 'SELECT')
      and not has_table_privilege('service_role', 'public.home_external_fixed_payment_projections', 'DELETE'),
    'internal_table_acl_not_widened'
  );
end;
$catalog_contract$;

do $fixture_setup$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_other_user uuid := 'b2100000-0000-4000-8000-000000000002';
begin
  insert into auth.users(id) values (v_other_user) on conflict do nothing;
  insert into public.home_fixed_templates(
    id,user_id,currency,direction,name,fixed_type,default_amount,payment_group,
    due_day,is_active,accounting_scope
  ) values
    ('b2100000-0000-4000-8000-000000000101',v_user,'JPY','income','Phase B-Delete JPY template','long_term',1000,null,5,true,'household'),
    ('b2100000-0000-4000-8000-000000000102',v_user,'CNY','income','Phase B-Delete CNY template','long_term',10,null,5,true,'household');

  insert into public.home_fixed_month_items(
    id,user_id,template_id,month_key,currency,direction,name,amount,status,
    payment_group,due_date,note,accounting_scope
  ) values
    ('b2100000-0000-4000-8000-000000000201',v_user,'b2100000-0000-4000-8000-000000000101','2098-01','JPY','income','normal delete',1000,'unpaid',null,'2098-01-05','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000202',v_user,null,'2098-01','JPY','income','other item',2000,'unpaid',null,'2098-01-06','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000203',v_user,null,'2098-02','JPY','income','other month',3000,'unpaid',null,'2098-02-06','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000204',v_user,'b2100000-0000-4000-8000-000000000102','2098-01','CNY','income','normal CNY delete',10,'unpaid',null,'2098-01-05','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000205',v_user,null,'2098-03','JPY','income','paid blocker',1,'paid',null,'2098-03-01','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000206',v_user,null,'2098-04','JPY','income','settled blocker',1,'settled',null,'2098-04-01','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000207',v_other_user,null,'2098-05','JPY','income','other owner',1,'unpaid',null,'2098-05-01','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000208',v_other_user,null,'2098-06','JPY','income','other owner own delete',1,'unpaid',null,'2098-06-01','phaseb','household');
end;
$fixture_setup$;

do $normal_replay_owner_status$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_other_user uuid := 'b2100000-0000-4000-8000-000000000002';
  v_result jsonb;
  v_page jsonb;
begin
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000201');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_DELETED', 'jpy_normal_delete');
  perform pg_temp.phaseb_assert(not exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000201'), 'jpy_target_deleted_once');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_templates where id='b2100000-0000-4000-8000-000000000101'), 'template_preserved');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000202'), 'other_item_preserved');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000203'), 'other_month_preserved');

  v_page := public.home_get_fixed_month_page('2098-01', 'JPY');
  perform pg_temp.phaseb_assert(v_page is not null and not exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000201'), 'reader_refresh_does_not_regenerate');

  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000201');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_ALREADY_ABSENT', 'exact_replay_already_absent');

  v_result := public.home_delete_cny_fixed_item('b2100000-0000-4000-8000-000000000204');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_DELETED', 'cny_normal_delete');
  perform pg_temp.phaseb_assert(not exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000204'), 'cny_target_deleted_once');

  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000205');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN', 'paid_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000205'), 'paid_item_preserved');

  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000206');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN', 'settled_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000206'), 'settled_item_preserved');

  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000207');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_ALREADY_ABSENT', 'nonowner_uses_nonleaking_absent');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000207'), 'nonowner_item_preserved');

  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000009999');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_ALREADY_ABSENT', 'random_id_absent');

  perform set_config('request.jwt.claim.sub', '', true);
  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000202');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED', 'unauthenticated_wrapper_rejected');

  perform set_config('request.jwt.claim.sub', v_other_user::text, true);
  v_result := public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000208');
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FIXED_ITEM_DELETED', 'other_owner_deletes_own_item');
end;
$normal_replay_owner_status$;

do $projection_correction_funding$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_card uuid := '9b27347e-2dce-4caf-bac0-67f053ef6c3b';
  v_account uuid;
  v_result jsonb;
  v_item uuid;
  v_projection uuid;
  v_funding_tx uuid := 'b2100000-0000-4000-8000-000000000701';
begin
  select id into v_account from public.home_accounts
  where user_id=v_user and currency='JPY' and is_active order by id limit 1;
  update public.home_fixed_templates
  set is_active=true
  where id=(select household_statement_template_id
            from public.home_card_instruments where id=v_card);
  update public.home_card_instruments
  set is_school_fixed_route_enabled=true, version=version+1 where id=v_card;
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  v_result := pg_temp.phaseb_make_projection('2098-07-01', 7100, 'projection');
  v_item := (v_result ->> 'fixed_item_id')::uuid;
  v_result := public.home_delete_fixed_month_item(v_item);
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN', 'projection_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_month_items where id=v_item), 'projection_parent_preserved');

  v_result := pg_temp.phaseb_make_projection('2098-08-01', 7200, 'correction');
  v_item := (v_result ->> 'fixed_item_id')::uuid;
  v_projection := (v_result ->> 'fixed_projection_id')::uuid;
  update public.home_external_fixed_payment_projections
  set projection_status='corrected', version=version+1 where id=v_projection;
  v_result := public.home_delete_fixed_month_item(v_item);
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_CORRECTION_FIXED_ITEM_DELETE_FORBIDDEN', 'correction_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_external_fixed_payment_projections where id=v_projection), 'correction_child_preserved');

  v_result := pg_temp.phaseb_make_funded_projection('2098-09-01', 7300, 'funded');
  v_item := (v_result ->> 'fixed_item_id')::uuid;
  v_projection := (v_result ->> 'fixed_projection_id')::uuid;
  v_funding_tx := (v_result ->> 'funding_transaction_id')::uuid;
  v_result := public.home_delete_fixed_month_item(v_item);
  perform pg_temp.phaseb_assert(v_result ->> 'code' = 'HOME_FUNDED_FIXED_ITEM_DELETE_FORBIDDEN', 'funded_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_jpy_transactions where id=v_funding_tx), 'funding_transaction_preserved');
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from pg_class c join pg_namespace n on n.oid=c.relnamespace
      where n.nspname='public' and c.relkind in ('r','p') and c.relname like 'home%allocation%'
    ),
    'allocation_table_not_present_in_current_schema'
  );
end;
$projection_correction_funding$;

do $statement_revision_advance_linked$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_card public.home_card_instruments%rowtype;
  v_account uuid;
  v_cycle uuid := 'b2100000-0000-4000-8000-000000000801';
  v_revision_cycle uuid := 'b2100000-0000-4000-8000-000000000802';
  v_result jsonb;
  v_jpy_tx uuid := 'b2100000-0000-4000-8000-000000000901';
  v_cny_tx uuid := 'b2100000-0000-4000-8000-000000000902';
begin
  select * into v_card from public.home_card_instruments
  where id='9b27347e-2dce-4caf-bac0-67f053ef6c3b';
  select id into v_account from public.home_accounts
  where user_id=v_user and currency='JPY' and is_active order by id limit 1;
  perform set_config('request.jwt.claim.sub', v_user::text, true);
  perform set_config('request.jwt.claim.role', 'authenticated', true);

  insert into public.home_fixed_month_items(
    id,user_id,template_id,month_key,currency,direction,name,amount,status,payment_group,due_date,note,accounting_scope
  ) values
    ('b2100000-0000-4000-8000-000000000301',v_user,v_card.household_statement_template_id,'2098-10','JPY','expense','statement item',8000,'unpaid','邮局卡','2098-10-25','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000302',v_user,v_card.household_statement_template_id,'2098-11','JPY','expense','revision item',8000,'unpaid','邮局卡','2098-11-25','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000303',v_user,null,'2098-12','JPY','expense','advance item',8000,'unpaid','phaseb advance','2098-12-25','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000304',v_user,null,'2097-01','JPY','income','linked JPY item',8000,'unpaid',null,'2097-01-05','phaseb','household'),
    ('b2100000-0000-4000-8000-000000000305',v_user,null,'2097-02','CNY','income','linked CNY item',80,'unpaid',null,'2097-02-05','phaseb','household');

  perform set_config('home.phase3e_cycle_write','on',true);
  insert into public.home_card_statement_cycles(
    id,user_id,card_instrument_id,target_fixed_month,settlement_currency,
    amount_status,household_remainder_fixed_item_id,version
  ) values (
    v_cycle,v_user,v_card.id,'2098-10-01','JPY','pending',
    'b2100000-0000-4000-8000-000000000301',0
  );
  insert into public.home_card_statement_cycles(
    id,user_id,card_instrument_id,target_fixed_month,settlement_currency,
    amount_status,household_remainder_fixed_item_id,version
  ) values (v_revision_cycle,v_user,v_card.id,'2098-11-01','JPY','pending',null,0);
  perform set_config('home.phase3e_cycle_write','off',true);

  perform set_config('home.phase3e_revision_write','on',true);
  insert into public.home_card_statement_cycle_revisions(
    id,user_id,cycle_id,cycle_version,action,statement_total_amount,
    school_subtotal_amount,household_remainder_amount,school_manifest,
    school_manifest_fingerprint,household_remainder_fixed_item_id,
    household_item_amount_before,household_item_amount_after,actor_id,
    reason,operation_idempotency_key,payload_fingerprint
  ) values (
    'b2100000-0000-4000-8000-000000000803',v_user,v_revision_cycle,1,'confirm',8000,
    0,8000,'[]'::jsonb,repeat('0',64),'b2100000-0000-4000-8000-000000000302',
    8000,8000,v_user,null,'phaseb-delete:revision',repeat('1',64)
  );
  perform set_config('home.phase3e_revision_write','off',true);

  insert into public.home_fixed_advance_payments(
    id,user_id,month_key,currency,payment_group,account_id,amount,status,paid_at,note,accounting_scope
  ) values (
    'b2100000-0000-4000-8000-000000000804',v_user,'2098-12','JPY','phaseb advance',
    v_account,8000,'pending','2098-12-25','phaseb','household'
  );

  insert into public.home_jpy_transactions(
    id,user_id,transaction_type,account_id,currency,transacted_at,amount,
    description,note,linked_fixed_month_item_id,accounting_scope
  ) values (
    v_jpy_tx,v_user,'fixed_out',v_account,'JPY','2097-01-05',8000,
    'phaseb linked JPY','phaseb','b2100000-0000-4000-8000-000000000304','household'
  );
  update public.home_fixed_month_items
  set linked_jpy_transaction_id=v_jpy_tx
  where id='b2100000-0000-4000-8000-000000000304';

  insert into public.home_cny_transactions(
    id,user_id,transaction_type,account_id,currency,transacted_at,amount,
    description,note,linked_fixed_month_item_id,accounting_scope
  ) select
    v_cny_tx,v_user,'income',a.id,'CNY','2097-02-05',80,
    'phaseb linked CNY','phaseb','b2100000-0000-4000-8000-000000000305','household'
  from public.home_accounts a
  where a.user_id=v_user and a.currency='CNY' and a.is_active
  order by a.id limit 1;
  update public.home_fixed_month_items
  set linked_cny_transaction_id=v_cny_tx
  where id='b2100000-0000-4000-8000-000000000305';

  v_result:=public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000301');
  perform pg_temp.phaseb_assert(v_result->>'code'='HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN','statement_cycle_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_card_statement_cycles where id=v_cycle),'statement_cycle_preserved');

  v_result:=public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000302');
  perform pg_temp.phaseb_assert(v_result->>'code'='HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN','statement_revision_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_card_statement_cycle_revisions where cycle_id=v_revision_cycle),'statement_revision_preserved');

  v_result:=public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000303');
  perform pg_temp.phaseb_assert(v_result->>'code'='HOME_ADVANCE_FIXED_ITEM_DELETE_FORBIDDEN','advance_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_fixed_advance_payments where id='b2100000-0000-4000-8000-000000000804'),'advance_preserved');

  v_result:=public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000304');
  perform pg_temp.phaseb_assert(v_result->>'code'='HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN','linked_jpy_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_jpy_transactions where id=v_jpy_tx),'linked_jpy_transaction_preserved');

  v_result:=public.home_delete_cny_fixed_item('b2100000-0000-4000-8000-000000000305');
  perform pg_temp.phaseb_assert(v_result->>'code'='HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN','linked_cny_delete_blocked');
  perform pg_temp.phaseb_assert(exists(select 1 from public.home_cny_transactions where id=v_cny_tx),'linked_cny_transaction_preserved');
end;
$statement_revision_advance_linked$;

do $authorization_binding_attacks$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_other_user uuid := 'b2100000-0000-4000-8000-000000000002';
  v_denied integer := 0;
begin
  insert into public.home_fixed_month_items(
    id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
  ) values
    ('b2100000-0000-4000-8000-000000000601',v_user,'2097-06','JPY','income','binding item A',1,'unpaid','phaseb2','household'),
    ('b2100000-0000-4000-8000-000000000602',v_user,'2097-06','JPY','income','binding item B',1,'unpaid','phaseb2','household'),
    ('b2100000-0000-4000-8000-000000000603',v_user,'2097-06','JPY','income','binding actor',1,'unpaid','phaseb2','household'),
    ('b2100000-0000-4000-8000-000000000604',v_user,'2097-06','JPY','income','binding currency',1,'unpaid','phaseb2','household'),
    ('b2100000-0000-4000-8000-000000000605',v_user,'2097-06','JPY','income','binding old transaction',1,'unpaid','phaseb2','household'),
    ('b2100000-0000-4000-8000-000000000606',v_user,'2097-06','JPY','income','binding consume',1,'unpaid','phaseb2','household');

  insert into public.home_fixed_month_item_delete_authorizations(
    transaction_id,fixed_month_item_id,actor_id,operation_type,currency,core_nonce
  ) values (
    pg_current_xact_id(),'b2100000-0000-4000-8000-000000000601',v_user,'delete','JPY',gen_random_uuid()
  );
  begin
    delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000602';
  exception when sqlstate '42501' then
    if sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED' then v_denied:=v_denied+1; end if;
  end;
  perform pg_temp.phaseb_assert(v_denied=1 and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000602'),'authorization_cannot_cross_item');
  delete from public.home_fixed_month_item_delete_authorizations;

  insert into public.home_fixed_month_item_delete_authorizations(
    transaction_id,fixed_month_item_id,actor_id,operation_type,currency,core_nonce
  ) values (
    pg_current_xact_id(),'b2100000-0000-4000-8000-000000000603',v_other_user,'delete','JPY',gen_random_uuid()
  );
  begin
    delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000603';
  exception when sqlstate '42501' then
    if sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED' then v_denied:=v_denied+1; end if;
  end;
  perform pg_temp.phaseb_assert(v_denied=2 and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000603'),'authorization_cannot_cross_actor');
  delete from public.home_fixed_month_item_delete_authorizations;

  insert into public.home_fixed_month_item_delete_authorizations(
    transaction_id,fixed_month_item_id,actor_id,operation_type,currency,core_nonce
  ) values (
    pg_current_xact_id(),'b2100000-0000-4000-8000-000000000604',v_user,'delete','CNY',gen_random_uuid()
  );
  begin
    delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000604';
  exception when sqlstate '42501' then
    if sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED' then v_denied:=v_denied+1; end if;
  end;
  perform pg_temp.phaseb_assert(v_denied=3 and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000604'),'authorization_cannot_cross_currency');
  delete from public.home_fixed_month_item_delete_authorizations;

  insert into public.home_fixed_month_item_delete_authorizations(
    transaction_id,fixed_month_item_id,actor_id,operation_type,currency,core_nonce
  ) values (
    '1'::xid8,'b2100000-0000-4000-8000-000000000605',v_user,'delete','JPY',gen_random_uuid()
  );
  begin
    delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000605';
  exception when sqlstate '42501' then
    if sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED' then v_denied:=v_denied+1; end if;
  end;
  perform pg_temp.phaseb_assert(v_denied=4 and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000605'),'authorization_cannot_cross_transaction');
  delete from public.home_fixed_month_item_delete_authorizations;

  insert into public.home_fixed_month_item_delete_authorizations(
    transaction_id,fixed_month_item_id,actor_id,operation_type,currency,core_nonce
  ) values (
    pg_current_xact_id(),'b2100000-0000-4000-8000-000000000606',v_user,'delete','JPY',gen_random_uuid()
  );
  delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000606';
  perform pg_temp.phaseb_assert(
    not exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000606')
      and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'authorization_consumed_once_atomically'
  );
end;
$authorization_binding_attacks$;

create or replace function pg_temp.phaseb2_definer_delete_attack(p_item_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
begin
  delete from public.home_fixed_month_items where id=p_item_id;
end;
$function$;
grant execute on function pg_temp.phaseb2_definer_delete_attack(uuid) to authenticated;

insert into public.home_fixed_month_items(
  id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
) values (
  'b2100000-0000-4000-8000-000000000607','8596a708-d99f-4264-8f8c-5b89af9254b6',
  '2097-06','JPY','income','future definer attack',1,'unpaid','phaseb2','household'
);
set local role authenticated;
select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
select set_config('home.fixed_month_item_delete_actor','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
select set_config('home.fixed_month_item_delete_writer','core',true);
select set_config('home.phaseb2.arbitrary_forged_capability','yes',true);
do $future_definer_attack$
declare v_denied boolean:=false;
begin
  begin
    perform pg_temp.phaseb2_definer_delete_attack('b2100000-0000-4000-8000-000000000607');
  exception when sqlstate '42501' then
    v_denied:=sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED';
  end;
  perform pg_temp.phaseb_assert(v_denied,'future_definer_without_authorization_denied');
end;
$future_definer_attack$;
reset role;
select pg_temp.phaseb_assert(
  exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000607')
    and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
  'future_definer_attack_preserves_item_and_zero_authorization'
);
drop function pg_temp.phaseb2_definer_delete_attack(uuid);

-- Actual-role ACL and direct-DML bypass tests.
set local role authenticated;
select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
select set_config('request.jwt.claim.role','authenticated',true);
do $authenticated_acl$
declare v_result jsonb; v_denied integer:=0;
begin
  perform set_config('home.fixed_month_item_delete_actor','b2100000-0000-4000-8000-000000000002',true);
  perform set_config('home.fixed_month_item_delete_writer','core',true);
  perform set_config('home.phaseb2.arbitrary_forged_capability','yes',true);
  insert into public.home_fixed_month_items(
    id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
  ) values (
    'b2100000-0000-4000-8000-000000000401','8596a708-d99f-4264-8f8c-5b89af9254b6',
    '2097-03','JPY','income','authenticated CRUD regression',1,'unpaid','insert','household'
  );
  update public.home_fixed_month_items set note='updated'
  where id='b2100000-0000-4000-8000-000000000401';
  perform pg_temp.phaseb_assert(
    exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000401' and note='updated'),
    'authenticated_insert_update_select_actual_role'
  );
  begin
    delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000401';
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    perform public.home_delete_fixed_month_item_core('b2100000-0000-4000-8000-000000000401',auth.uid(),'JPY');
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    perform count(*) from public.home_external_fixed_payment_projections;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    perform count(*) from public.home_fixed_month_item_delete_authorizations;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    insert into public.home_fixed_month_item_delete_authorizations(
      authorization_id,transaction_id,fixed_month_item_id,actor_id,operation_type,currency,core_nonce
    ) values (gen_random_uuid(),pg_current_xact_id(),'b2100000-0000-4000-8000-000000000401',auth.uid(),'delete','JPY',gen_random_uuid());
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    update public.home_fixed_month_item_delete_authorizations set currency='CNY';
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    delete from public.home_fixed_month_item_delete_authorizations;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin
    truncate table public.home_fixed_month_item_delete_authorizations;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  perform pg_temp.phaseb_assert(v_denied=8,'authenticated_direct_delete_core_internal_authorization_denied');
  v_result:=public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000401');
  perform pg_temp.phaseb_assert(
    v_result->>'code'='HOME_FIXED_ITEM_DELETED'
      and not (v_result ? 'authorization_id')
      and not (v_result ? 'core_nonce'),
    'authenticated_wrapper_actual_role_success_without_capability_exposure'
  );
end;
$authenticated_acl$;
reset role;
select pg_temp.phaseb_assert(
  not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
  'guc_forgery_cannot_create_or_leave_authorization'
);

set local role anon;
do $anon_acl$
declare v_denied integer:=0;
begin
  begin delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000205';
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin perform public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000205');
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin truncate table public.home_fixed_month_items;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin perform count(*) from public.home_fixed_month_item_delete_authorizations;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  perform pg_temp.phaseb_assert(v_denied=4,'anon_delete_wrapper_truncate_authorization_denied');
end;
$anon_acl$;
reset role;

set local role service_role;
do $service_acl$
declare v_denied integer:=0;
begin
  begin delete from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000205';
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin perform public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000205');
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin truncate table public.home_fixed_month_items;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  begin perform count(*) from public.home_fixed_month_item_delete_authorizations;
  exception when insufficient_privilege then v_denied:=v_denied+1; end;
  perform pg_temp.phaseb_assert(v_denied=4,'service_role_delete_wrapper_truncate_authorization_denied');
end;
$service_acl$;
reset role;

do $final_guard_and_forced_rollback$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_result jsonb;
  v_denied boolean := false;
begin
  begin
    delete from public.home_fixed_month_items
    where id='b2100000-0000-4000-8000-000000000202';
  exception when sqlstate '42501' then
    v_denied := sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED';
  end;
  perform pg_temp.phaseb_assert(v_denied,'postgres_direct_delete_hits_final_guard');

  insert into public.home_fixed_month_items(
    id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
  ) values (
    'b2100000-0000-4000-8000-000000000501',v_user,'2097-04','JPY','income',
    'forced rollback item',1,'unpaid','phaseb','household'
  );
  begin
    perform set_config('request.jwt.claim.sub',v_user::text,true);
    v_result:=public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000501');
    if v_result->>'code'<>'HOME_FIXED_ITEM_DELETED' then
      raise exception 'PHASEB_DELETE_FORCED_ROLLBACK_DELETE_FAILED';
    end if;
    raise exception 'PHASEB_DELETE_EXPECTED_FORCED_ROLLBACK';
  exception when others then
    if sqlerrm<>'PHASEB_DELETE_EXPECTED_FORCED_ROLLBACK' then raise; end if;
  end;
  perform pg_temp.phaseb_assert(
    exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000501')
      and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'forced_failure_rolls_back_delete'
  );
end;
$final_guard_and_forced_rollback$;

create or replace function pg_temp.phaseb2_before_item_delete_failure()
returns trigger language plpgsql as $function$
begin
  if old.id='b2100000-0000-4000-8000-000000000701' then
    raise exception 'PHASEB2_INJECT_BEFORE_GUARD_FAILURE';
  end if;
  return old;
end;
$function$;
create trigger zy_phaseb2_before_item_delete_failure
before delete on public.home_fixed_month_items
for each row execute function pg_temp.phaseb2_before_item_delete_failure();

insert into public.home_fixed_month_items(
  id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
) values (
  'b2100000-0000-4000-8000-000000000701','8596a708-d99f-4264-8f8c-5b89af9254b6',
  '2097-07','JPY','income','failure before guard',1,'unpaid','phaseb2','household'
);
do $failure_before_guard$
declare v_failed boolean:=false;
begin
  perform set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
  begin
    perform public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000701');
  exception when others then
    v_failed:=sqlerrm='PHASEB2_INJECT_BEFORE_GUARD_FAILURE';
  end;
  perform pg_temp.phaseb_assert(
    v_failed
      and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000701')
      and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'authorization_create_then_pre_guard_failure_rolls_back'
  );
end;
$failure_before_guard$;
drop trigger zy_phaseb2_before_item_delete_failure on public.home_fixed_month_items;
drop function pg_temp.phaseb2_before_item_delete_failure();

create or replace function pg_temp.phaseb2_after_item_delete_failure()
returns trigger language plpgsql as $function$
begin
  if old.id='b2100000-0000-4000-8000-000000000702' then
    raise exception 'PHASEB2_INJECT_AFTER_GUARD_FAILURE';
  end if;
  return old;
end;
$function$;
create trigger phaseb2_after_item_delete_failure
after delete on public.home_fixed_month_items
for each row execute function pg_temp.phaseb2_after_item_delete_failure();

insert into public.home_fixed_month_items(
  id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
) values (
  'b2100000-0000-4000-8000-000000000702','8596a708-d99f-4264-8f8c-5b89af9254b6',
  '2097-07','JPY','income','failure after guard',1,'unpaid','phaseb2','household'
);
do $failure_after_guard$
declare v_failed boolean:=false;
begin
  begin
    perform public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000702');
  exception when others then
    v_failed:=sqlerrm='PHASEB2_INJECT_AFTER_GUARD_FAILURE';
  end;
  perform pg_temp.phaseb_assert(
    v_failed
      and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000702')
      and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'guard_consume_then_delete_failure_rolls_back'
  );
end;
$failure_after_guard$;
drop trigger phaseb2_after_item_delete_failure on public.home_fixed_month_items;
drop function pg_temp.phaseb2_after_item_delete_failure();

create or replace function pg_temp.phaseb2_reinsert_consumed_authorization()
returns trigger language plpgsql security definer
set search_path=pg_catalog,public
as $function$
begin
  insert into public.home_fixed_month_item_delete_authorizations(
    authorization_id,transaction_id,fixed_month_item_id,actor_id,
    operation_type,currency,core_nonce,created_at
  ) values (
    old.authorization_id,old.transaction_id,old.fixed_month_item_id,old.actor_id,
    old.operation_type,old.currency,old.core_nonce,old.created_at
  );
  return old;
end;
$function$;
create trigger phaseb2_reinsert_consumed_authorization
after delete on public.home_fixed_month_item_delete_authorizations
for each row execute function pg_temp.phaseb2_reinsert_consumed_authorization();

insert into public.home_fixed_month_items(
  id,user_id,month_key,currency,direction,name,amount,status,note,accounting_scope
) values (
  'b2100000-0000-4000-8000-000000000703','8596a708-d99f-4264-8f8c-5b89af9254b6',
  '2097-07','JPY','income','core post assertion failure',1,'unpaid','phaseb2','household'
);
do $core_post_assertion_failure$
declare v_failed boolean:=false;
begin
  begin
    perform public.home_delete_fixed_month_item('b2100000-0000-4000-8000-000000000703');
  exception when sqlstate '55000' then
    v_failed:=sqlerrm='HOME_FIXED_ITEM_DELETE_AUTHORIZATION_NOT_CONSUMED';
  end;
  perform pg_temp.phaseb_assert(
    v_failed
      and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000703')
      and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'core_post_assertion_failure_rolls_back_item_and_authorization'
  );
end;
$core_post_assertion_failure$;
drop trigger phaseb2_reinsert_consumed_authorization on public.home_fixed_month_item_delete_authorizations;
drop function pg_temp.phaseb2_reinsert_consumed_authorization();

do $user_history_and_account_deactivation$
declare
  v_user uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  v_other_user uuid := 'b2100000-0000-4000-8000-000000000002';
  v_user_delete_denied boolean:=false;
begin
  begin
    delete from auth.users where id=v_other_user;
  exception when foreign_key_violation then
    v_user_delete_denied:=true;
  end;
  perform pg_temp.phaseb_assert(
    v_user_delete_denied
      and exists(select 1 from auth.users where id=v_other_user)
      and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000000207')
      and not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'auth_user_delete_restricted_when_fixed_history_exists'
  );

  insert into public.home_accounts(
    id,user_id,currency,name,account_type,opening_balance,is_active,sort_order,allow_school_requests
  ) values (
    'b2100000-0000-4000-8000-000000001001',v_user,'JPY','Phase B2 deactivation account',
    'bank',0,true,9901,false
  );
  insert into public.home_fixed_month_items(
    id,user_id,month_key,currency,direction,name,amount,status,account_id,note,accounting_scope
  ) values (
    'b2100000-0000-4000-8000-000000001002',v_user,'2097-10','JPY','income',
    'account deactivation history',1,'unpaid','b2100000-0000-4000-8000-000000001001','phaseb2','household'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from pg_proc p join pg_namespace n on n.oid=p.pronamespace
      where n.nspname='public' and p.prokind='f'
        and lower(pg_get_functiondef(p.oid)) like '%delete from auth.users%'
    ),
    'no_reachable_public_auth_user_delete_writer'
  );
end;
$user_history_and_account_deactivation$;

select set_config('request.jwt.claim.sub','8596a708-d99f-4264-8f8c-5b89af9254b6',true);
set local role authenticated;
update public.home_accounts set is_active=false
where id='b2100000-0000-4000-8000-000000001001';
reset role;
select pg_temp.phaseb_assert(
  (select is_active=false from public.home_accounts where id='b2100000-0000-4000-8000-000000001001')
    and exists(select 1 from public.home_fixed_month_items where id='b2100000-0000-4000-8000-000000001002'),
  'account_deactivation_preserves_fixed_history'
);

do $integrity_contract$
begin
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from public.home_external_fixed_payment_projections p
      left join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
      where i.id is null
    ),
    'no_projection_orphan'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from public.home_card_statement_cycles c
      left join public.home_fixed_month_items i on i.id=c.household_remainder_fixed_item_id
      where c.household_remainder_fixed_item_id is not null and i.id is null
    ),
    'no_cycle_orphan'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from public.home_card_statement_cycle_revisions r
      left join public.home_fixed_month_items i on i.id=r.household_remainder_fixed_item_id
      where i.id is null
    ),
    'no_revision_orphan'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from public.home_jpy_transactions t
      where t.linked_fixed_month_item_id is not null
        and not exists(select 1 from public.home_fixed_month_items i where i.id=t.linked_fixed_month_item_id)
    ) and not exists (
      select 1 from public.home_cny_transactions t
      where t.linked_fixed_month_item_id is not null
        and not exists(select 1 from public.home_fixed_month_items i where i.id=t.linked_fixed_month_item_id)
    ),
    'no_linked_transaction_orphan'
  );
  perform pg_temp.phaseb_assert(
    (select count(*) from pg_constraint
     where conrelid='public.home_fixed_month_items'::regclass
       and contype='c' and conname='home_fixed_month_items_status_check')=1,
    'status_domain_still_unpaid_paid_settled'
  );
  perform pg_temp.phaseb_assert(
    not exists(select 1 from public.home_fixed_month_item_delete_authorizations),
    'authorization_table_final_residue_zero'
  );
  perform pg_temp.phaseb_assert(
    not exists (
      select 1 from pg_trigger
      where tgname like 'phaseb2_%' or tgname like 'zy_phaseb2_%'
    ),
    'temporary_attack_triggers_removed'
  );
  perform pg_temp.phaseb_assert(
    (select confdeltype='r' from pg_constraint
     where conrelid='public.home_fixed_month_items'::regclass
       and conname='home_fixed_month_items_user_id_fkey'),
    'fixed_history_fk_final_restrict'
  );
end;
$integrity_contract$;

select 'PHASEB_DELETE_ROLLBACK_MATRIX_PASS' as result,
       count(*) as assertion_count
from pg_temp.phaseb_delete_assertions;
