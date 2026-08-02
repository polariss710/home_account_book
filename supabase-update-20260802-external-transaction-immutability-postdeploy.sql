-- Cash external transaction immutability read-only postdeploy, 2026-08-02.
\set ON_ERROR_STOP on
\pset pager off

begin transaction isolation level repeatable read read only;

select t.tgname, t.tgenabled, t.tgrelid::regclass as relation
from pg_trigger t
where t.tgname in (
  'home_cny_external_transaction_immutable',
  'home_jpy_external_transaction_immutable'
)
order by t.tgname;

select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename in ('home_cny_transactions', 'home_jpy_transactions')
order by tablename, policyname;

select p.oid::regprocedure as signature,
       md5(pg_get_functiondef(p.oid)) as definition_md5,
       p.prosecdef,
       p.proconfig,
       pg_get_userbyid(p.proowner) as owner,
       p.proacl
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname = 'public'
  and p.proname in (
    'home_guard_external_transaction_immutable',
    'home_update_cny_transaction',
    'home_delete_cny_transaction',
    'home_update_jpy_transaction',
    'home_delete_jpy_transaction'
  )
order by p.oid::regprocedure::text;

do $assert$
declare
  v_yuebao_balance numeric;
begin
  if (select count(*) from pg_trigger t
      where t.tgname in (
        'home_cny_external_transaction_immutable',
        'home_jpy_external_transaction_immutable'
      ) and t.tgenabled = 'O') <> 2 then
    raise exception 'POSTDEPLOY_TRIGGER_FAILED';
  end if;

  if (select count(*) from pg_policies
      where schemaname = 'public'
        and tablename in ('home_cny_transactions', 'home_jpy_transactions')) <> 8
     or (select count(*) from pg_policies
         where schemaname = 'public'
           and policyname in (
             'home_cny_transactions_owner_select',
             'home_cny_transactions_manual_insert',
             'home_cny_transactions_manual_update',
             'home_cny_transactions_manual_delete',
             'home_jpy_transactions_owner_select',
             'home_jpy_transactions_manual_insert',
             'home_jpy_transactions_manual_update',
             'home_jpy_transactions_manual_delete'
           )) <> 8 then
    raise exception 'POSTDEPLOY_RLS_FAILED';
  end if;

  if has_table_privilege('anon', 'public.home_cny_transactions', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('anon', 'public.home_jpy_transactions', 'INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('authenticated', 'public.home_cny_transactions', 'TRUNCATE,REFERENCES,TRIGGER')
     or has_table_privilege('authenticated', 'public.home_jpy_transactions', 'TRUNCATE,REFERENCES,TRIGGER')
     or not has_table_privilege('authenticated', 'public.home_cny_transactions', 'SELECT')
     or not has_table_privilege('authenticated', 'public.home_cny_transactions', 'INSERT')
     or not has_table_privilege('authenticated', 'public.home_cny_transactions', 'UPDATE')
     or not has_table_privilege('authenticated', 'public.home_cny_transactions', 'DELETE')
     or not has_table_privilege('authenticated', 'public.home_jpy_transactions', 'SELECT')
     or not has_table_privilege('authenticated', 'public.home_jpy_transactions', 'INSERT')
     or not has_table_privilege('authenticated', 'public.home_jpy_transactions', 'UPDATE')
     or not has_table_privilege('authenticated', 'public.home_jpy_transactions', 'DELETE')
     or exists (
       select 1
       from pg_class c
       join pg_namespace n on n.oid = c.relnamespace
       cross join lateral aclexplode(coalesce(c.relacl, acldefault('r', c.relowner))) acl
       where n.nspname = 'public'
         and c.relname in ('home_cny_transactions', 'home_jpy_transactions')
         and acl.grantee = 0
         and acl.privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE', 'REFERENCES', 'TRIGGER')
     ) then
    raise exception 'POSTDEPLOY_TABLE_ACL_FAILED';
  end if;

  if has_function_privilege('anon', 'public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.home_delete_cny_transaction(uuid)', 'EXECUTE')
     or has_function_privilege('anon', 'public.home_update_jpy_transaction(uuid,uuid,uuid,date,numeric,text,text)', 'EXECUTE')
     or has_function_privilege('anon', 'public.home_delete_jpy_transaction(uuid)', 'EXECUTE')
     or not has_function_privilege('authenticated', 'public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)', 'EXECUTE')
     or not has_function_privilege('service_role', 'public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)', 'EXECUTE')
     or exists (
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
     ) then
    raise exception 'POSTDEPLOY_FUNCTION_ACL_FAILED';
  end if;

  if md5(pg_get_functiondef('public.home_guard_external_transaction_immutable()'::regprocedure)) <> '01cbde762c23b3023470b9543bb073a5'
     or md5(pg_get_functiondef('public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)'::regprocedure)) <> 'd4e95f9237d686e6a702f074560e4232'
     or md5(pg_get_functiondef('public.home_delete_cny_transaction(uuid)'::regprocedure)) <> '1a090b86e32739745d81898636d45a1a'
     or md5(pg_get_functiondef('public.home_update_jpy_transaction(uuid,uuid,uuid,date,numeric,text,text)'::regprocedure)) <> '975cf134473f6c7c49771049d2c8825f'
     or md5(pg_get_functiondef('public.home_delete_jpy_transaction(uuid)'::regprocedure)) <> '7b1e9910eaa38e30d47ef3377716ac84' then
    raise exception 'POSTDEPLOY_FUNCTION_DEFINITION_FAILED';
  end if;

  if (select count(*) from public.home_accounts) <> 7
     or (select md5(coalesce(string_agg(md5(to_jsonb(t)::text), '' order by t.id::text), ''))
         from public.home_accounts t) <> '89b057e2cdeb7324ef73f73e252174f1'
     or (select count(*) from public.home_external_transaction_requests) <> 35
     or (select md5(coalesce(string_agg(md5(to_jsonb(t)::text), '' order by t.id::text), ''))
         from public.home_external_transaction_requests t) <> '4a7319eb294222cb5057ecfe262a885f'
     or (select count(*) from public.home_cny_transactions) <> 64
     or (select md5(coalesce(string_agg(md5(to_jsonb(t)::text), '' order by t.id::text), ''))
         from public.home_cny_transactions t) <> '8e5f62d1e256228b956ca7155bed65db'
     or (select count(*) from public.home_jpy_transactions) <> 31
     or (select md5(coalesce(string_agg(md5(to_jsonb(t)::text), '' order by t.id::text), ''))
         from public.home_jpy_transactions t) <> '95ab7cf8a8d167e9b052d3fc6b64614b' then
    raise exception 'POSTDEPLOY_COLLECTION_FINGERPRINT_FAILED';
  end if;

  if not exists (
    select 1
    from public.home_cny_transactions t
    join public.home_accounts a on a.id = t.account_id
    where t.id = '2feb333c-6228-4f57-a1fa-c8aa3d40616c'
      and t.amount = 1120.50
      and t.currency = 'CNY'
      and t.transacted_at = date '2026-08-02'
      and a.name = '余额宝'
      and t.created_by_external is true
      and t.external_source = 'aozora_school'
      and md5(to_jsonb(t)::text) = '7c94d3e343e26713a54e779e1d3b53da'
  ) then
    raise exception 'POSTDEPLOY_PROTECTED_TRANSACTION_FAILED';
  end if;

  select a.opening_balance + coalesce(sum(
    case
      when t.account_id = a.id and t.transaction_type in ('income', 'fx_in') then t.amount
      when t.account_id = a.id and t.transaction_type in ('expense', 'fx_out', 'transfer') then -t.amount
      when t.transfer_account_id = a.id and t.transaction_type = 'transfer' then t.amount
      else 0
    end
  ), 0)
  into v_yuebao_balance
  from public.home_accounts a
  left join public.home_cny_transactions t
    on t.account_id = a.id or t.transfer_account_id = a.id
  where a.id = 'c61781cf-dd07-40d1-ab00-7f76eb581034'
  group by a.id, a.opening_balance;

  if v_yuebao_balance <> 111041.82
     or (select count(*) from public.home_cny_transactions
         where account_id = 'c61781cf-dd07-40d1-ab00-7f76eb581034'
           and transaction_type = 'expense') <> 37
     or (select coalesce(sum(amount), 0) from public.home_cny_transactions
         where account_id = 'c61781cf-dd07-40d1-ab00-7f76eb581034'
           and transaction_type = 'expense') <> 124069.05 then
    raise exception 'POSTDEPLOY_YUEBAO_BASELINE_FAILED';
  end if;

  if exists (select 1 from public.home_accounts where id::text like 'f3f10000-%')
     or exists (select 1 from public.home_external_transaction_requests where id::text like 'f3f10000-%')
     or exists (select 1 from public.home_cny_transactions where id::text like 'f3f10000-%')
     or exists (select 1 from public.home_jpy_transactions where id::text like 'f3f10000-%') then
    raise exception 'POSTDEPLOY_FIXTURE_RESIDUE_FAILED';
  end if;
end
$assert$;

select 'POSTDEPLOY_PASS' as result,
       64 as cny_count,
       '8e5f62d1e256228b956ca7155bed65db' as cny_md5,
       31 as jpy_count,
       '95ab7cf8a8d167e9b052d3fc6b64614b' as jpy_md5,
       111041.82::numeric as yuebao_balance,
       '7c94d3e343e26713a54e779e1d3b53da' as protected_transaction_md5;

rollback;
