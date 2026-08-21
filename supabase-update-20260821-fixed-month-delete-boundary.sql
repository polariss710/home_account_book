-- Phase B-Delete: fixed month item physical-delete boundary.
-- Local implementation only. Do not deploy without a separately authorized
-- Phase C-Delete rollback rehearsal and production apply workflow.

-- A fixed month item is financial history. Deleting an auth user must not
-- cascade through this table; account access is disabled with is_active=false.
do $fixed_item_user_fk$
declare
  v_delete_action "char";
begin
  select c.confdeltype
  into v_delete_action
  from pg_constraint c
  where c.conrelid = 'public.home_fixed_month_items'::regclass
    and c.conname = 'home_fixed_month_items_user_id_fkey'
    and c.contype = 'f';

  if v_delete_action is distinct from 'r' then
    if v_delete_action is not null then
      alter table public.home_fixed_month_items
        drop constraint home_fixed_month_items_user_id_fkey;
    end if;

    alter table public.home_fixed_month_items
      add constraint home_fixed_month_items_user_id_fkey
      foreign key (user_id)
      references auth.users(id)
      on delete restrict;
  end if;
end;
$fixed_item_user_fk$;

-- Transaction-bound one-time capabilities. A client cannot create, inspect,
-- mutate, consume or truncate these rows. The owner-only core creates one row
-- immediately before DELETE and the BEFORE DELETE guard atomically consumes it.
create table if not exists public.home_fixed_month_item_delete_authorizations (
  authorization_id uuid primary key default gen_random_uuid(),
  transaction_id xid8 not null,
  fixed_month_item_id uuid not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  operation_type text not null
    constraint home_fixed_month_item_delete_authorizations_operation_check
    check (operation_type = 'delete'),
  currency text not null
    constraint home_fixed_month_item_delete_authorizations_currency_check
    check (currency in ('JPY', 'CNY')),
  core_nonce uuid not null unique,
  created_at timestamptz not null default statement_timestamp(),
  constraint home_fixed_month_item_delete_authorizations_binding_key
    unique (transaction_id, fixed_month_item_id, actor_id, operation_type, currency)
);

alter table public.home_fixed_month_item_delete_authorizations owner to postgres;
alter table public.home_fixed_month_item_delete_authorizations enable row level security;
revoke all on table public.home_fixed_month_item_delete_authorizations
  from public, anon, authenticated, service_role;

create or replace function public.home_check_fixed_month_item_delete_eligibility(
  p_item public.home_fixed_month_items,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
begin
  if p_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  if p_item.id is null or p_item.user_id is distinct from p_actor_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_ALREADY_ABSENT',
      'message', '该固定项已不存在，请刷新页面。'
    );
  end if;

  if p_item.status is distinct from 'unpaid' then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN',
      'message', '仅未支付的普通固定项可以删除。已支付或已结算项目请先撤销支付或使用纠正流程。'
    );
  end if;

  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = p_item.id
      and (
        p.projection_status = 'corrected'
        or p.supersedes_projection_id is not null
        or exists (
          select 1
          from public.home_external_fixed_payment_projections replacement
          where replacement.supersedes_projection_id = p.id
        )
      )
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_CORRECTION_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项属于纠正或replacement链路，不能直接删除。'
    );
  end if;

  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = p_item.id
      and (
        p.funding_status is distinct from 'unfunded'
        or p.funding_account_id is not null
        or p.funding_transaction_id is not null
        or p.funded_at is not null
      )
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FUNDED_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项已经进入资金处理流程，不能直接删除。'
    );
  end if;

  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = p_item.id
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项来自外部固定支付链路，不能直接删除。'
    );
  end if;

  if exists (
    select 1
    from public.home_card_statement_cycles c
    where c.household_remainder_fixed_item_id = p_item.id
  ) or exists (
    select 1
    from public.home_card_statement_cycle_revisions r
    where r.household_remainder_fixed_item_id = p_item.id
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项已经进入账单处理流程，不能直接删除。'
    );
  end if;

  if p_item.direction = 'expense' and exists (
    select 1
    from public.home_fixed_advance_payments a
    where a.user_id = p_item.user_id
      and a.month_key = p_item.month_key
      and a.currency = p_item.currency
      and a.payment_group = coalesce(p_item.payment_group, '未分组')
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_ADVANCE_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项所在支付分组已经进入垫付流程，不能直接删除。'
    );
  end if;

  if p_item.linked_jpy_transaction_id is not null
     or p_item.linked_cny_transaction_id is not null
     or exists (
       select 1
       from public.home_jpy_transactions t
       where t.linked_fixed_month_item_id = p_item.id
     )
     or exists (
       select 1
       from public.home_cny_transactions t
       where t.linked_fixed_month_item_id = p_item.id
     ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项已经关联Cash流水，不能直接删除。'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'HOME_FIXED_ITEM_DELETE_ELIGIBLE'
  );
end;
$function$;

create or replace function public.home_guard_fixed_month_item_delete_contract()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_authorization_id uuid;
  v_check jsonb;
begin
  v_check := public.home_check_fixed_month_item_delete_eligibility(old, old.user_id);
  if not coalesce((v_check ->> 'ok')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = coalesce(v_check ->> 'code', 'HOME_FIXED_ITEM_DELETE_INTERNAL_CONTRACT_ERROR');
  end if;

  delete from public.home_fixed_month_item_delete_authorizations a
  where a.transaction_id = pg_current_xact_id()
    and a.fixed_month_item_id = old.id
    and a.actor_id = old.user_id
    and a.operation_type = 'delete'
    and a.currency = old.currency
  returning a.authorization_id into v_authorization_id;

  if v_authorization_id is null then
    raise exception using
      errcode = '42501',
      message = 'HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED';
  end if;

  return old;
end;
$function$;

drop trigger if exists zz_home_fixed_month_items_delete_contract_guard
  on public.home_fixed_month_items;
create trigger zz_home_fixed_month_items_delete_contract_guard
before delete on public.home_fixed_month_items
for each row execute function public.home_guard_fixed_month_item_delete_contract();

create or replace function public.home_delete_fixed_month_item_core(
  p_item_id uuid,
  p_actor_id uuid,
  p_expected_currency text default null
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_item public.home_fixed_month_items%rowtype;
  v_check jsonb;
  v_deleted_count integer := 0;
  v_expected_currency text := nullif(upper(btrim(coalesce(p_expected_currency, ''))), '');
  v_authorization_id uuid := gen_random_uuid();
  v_core_nonce uuid := gen_random_uuid();
  v_transaction_id xid8;
begin
  if p_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  if p_item_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_ALREADY_ABSENT',
      'message', '该固定项已不存在，请刷新页面。'
    );
  end if;

  select * into v_item
  from public.home_fixed_month_items i
  where i.id = p_item_id
    and i.user_id = p_actor_id
    and (v_expected_currency is null or i.currency = v_expected_currency)
  for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_ALREADY_ABSENT',
      'message', '该固定项已不存在，请刷新页面。'
    );
  end if;

  v_check := public.home_check_fixed_month_item_delete_eligibility(v_item, p_actor_id);
  if not coalesce((v_check ->> 'ok')::boolean, false) then
    return v_check;
  end if;

  v_transaction_id := pg_current_xact_id();

  insert into public.home_fixed_month_item_delete_authorizations(
    authorization_id,
    transaction_id,
    fixed_month_item_id,
    actor_id,
    operation_type,
    currency,
    core_nonce
  ) values (
    v_authorization_id,
    v_transaction_id,
    v_item.id,
    p_actor_id,
    'delete',
    v_item.currency,
    v_core_nonce
  );

  delete from public.home_fixed_month_items i
  where i.id = v_item.id
    and i.user_id = p_actor_id;
  get diagnostics v_deleted_count = row_count;

  if v_deleted_count <> 1 then
    raise exception using
      errcode = '55000',
      message = 'HOME_FIXED_ITEM_DELETE_INTERNAL_CONTRACT_ERROR';
  end if;

  if exists (
    select 1
    from public.home_fixed_month_item_delete_authorizations a
    where a.authorization_id = v_authorization_id
  ) then
    raise exception using
      errcode = '55000',
      message = 'HOME_FIXED_ITEM_DELETE_AUTHORIZATION_NOT_CONSUMED';
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'HOME_FIXED_ITEM_DELETED',
    'deleted_count', 1,
    'item_id', v_item.id,
    'currency', v_item.currency,
    'message', case
      when v_item.currency = 'CNY' then '人民币固定项已删除。'
      else '固定项已删除。'
    end
  );
end;
$function$;

create or replace function public.home_delete_fixed_month_item(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  return public.home_delete_fixed_month_item_core(p_item_id, v_actor_id, 'JPY');
end;
$function$;

create or replace function public.home_delete_cny_fixed_item(p_item_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  return public.home_delete_fixed_month_item_core(p_item_id, v_actor_id, 'CNY');
end;
$function$;

alter function public.home_check_fixed_month_item_delete_eligibility(public.home_fixed_month_items,uuid) owner to postgres;
alter function public.home_guard_fixed_month_item_delete_contract() owner to postgres;
alter function public.home_delete_fixed_month_item_core(uuid,uuid,text) owner to postgres;
alter function public.home_delete_fixed_month_item(uuid) owner to postgres;
alter function public.home_delete_cny_fixed_item(uuid) owner to postgres;

revoke all on function public.home_check_fixed_month_item_delete_eligibility(public.home_fixed_month_items,uuid)
  from public, anon, authenticated, service_role;
revoke all on function public.home_guard_fixed_month_item_delete_contract()
  from public, anon, authenticated, service_role;
revoke all on function public.home_delete_fixed_month_item_core(uuid,uuid,text)
  from public, anon, authenticated, service_role;

revoke all on function public.home_delete_fixed_month_item(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.home_delete_fixed_month_item(uuid) to authenticated;

revoke all on function public.home_delete_cny_fixed_item(uuid)
  from public, anon, authenticated, service_role;
grant execute on function public.home_delete_cny_fixed_item(uuid) to authenticated;

-- Keep the existing reader/insert/update surface, but remove every direct
-- client deletion primitive. TRUNCATE is included because RLS and row triggers
-- do not protect it.
revoke delete, truncate on table public.home_fixed_month_items
  from public, anon, authenticated, service_role;

drop policy if exists home_fixed_month_items_user_all
  on public.home_fixed_month_items;
drop policy if exists home_fixed_month_items_user_select
  on public.home_fixed_month_items;
drop policy if exists home_fixed_month_items_user_insert
  on public.home_fixed_month_items;
drop policy if exists home_fixed_month_items_user_update
  on public.home_fixed_month_items;

create policy home_fixed_month_items_user_select
  on public.home_fixed_month_items
  for select
  to authenticated
  using (user_id = auth.uid());

create policy home_fixed_month_items_user_insert
  on public.home_fixed_month_items
  for insert
  to authenticated
  with check (user_id = auth.uid());

create policy home_fixed_month_items_user_update
  on public.home_fixed_month_items
  for update
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

comment on function public.home_delete_fixed_month_item_core(uuid,uuid,text) is
  'Phase B2-Delete owner-only atomic core. Locks one owned item, creates an unforgeable transaction-bound one-time authorization, and physically deletes it only when unpaid and free of every known downstream fact.';
comment on function public.home_delete_fixed_month_item(uuid) is
  'Phase B2-Delete authenticated JPY wrapper. Actor is auth.uid(); no authorization identity or linked transaction is exposed to the client.';
comment on function public.home_delete_cny_fixed_item(uuid) is
  'Phase B2-Delete authenticated CNY compatibility wrapper. Actor is auth.uid(); no authorization identity or linked transaction is exposed to the client.';
comment on table public.home_fixed_month_item_delete_authorizations is
  'Phase B2-Delete internal transaction-bound one-time capabilities. Client roles have zero privileges; successful guards consume the row atomically and failed statements roll it back.';
