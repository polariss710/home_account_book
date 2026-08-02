-- Cash external transaction immutability hardening, 2026-08-02.
-- Status: reviewed draft; execute only against CASH_SUPABASE_DB_URL.
-- Enforces the approved contract without changing existing transaction rows.
\set ON_ERROR_STOP on
\pset pager off

begin;
set local lock_timeout = '10s';
set local statement_timeout = '120s';

create or replace function public.home_guard_external_transaction_immutable()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
begin
  if old.created_by_external is true
     or nullif(btrim(old.external_source), '') is not null
     or old.external_source_id is not null
     or nullif(btrim(old.external_event_type), '') is not null
     or nullif(btrim(old.external_idempotency_key), '') is not null
     or nullif(btrim(old.external_reference_type), '') is not null
     or old.external_reference_id is not null
     or nullif(btrim(old.external_note), '') is not null
     or nullif(btrim(old.external_payload_hash), '') is not null
     or old.external_created_at is not null then
    raise exception using
      errcode = 'P0001',
      message = 'EXTERNAL_TRANSACTION_IMMUTABLE',
      detail = format('%s %s is owned by an external-system ledger link', tg_table_name, old.id);
  end if;

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$function$;

alter function public.home_guard_external_transaction_immutable() owner to postgres;
revoke all on function public.home_guard_external_transaction_immutable()
  from public, anon, authenticated, service_role;

drop trigger if exists home_cny_external_transaction_immutable
  on public.home_cny_transactions;
create trigger home_cny_external_transaction_immutable
before update or delete on public.home_cny_transactions
for each row execute function public.home_guard_external_transaction_immutable();

drop trigger if exists home_jpy_external_transaction_immutable
  on public.home_jpy_transactions;
create trigger home_jpy_external_transaction_immutable
before update or delete on public.home_jpy_transactions
for each row execute function public.home_guard_external_transaction_immutable();

alter table public.home_cny_transactions enable row level security;
drop policy if exists home_cny_transactions_user_all on public.home_cny_transactions;
drop policy if exists home_cny_transactions_owner_select on public.home_cny_transactions;
drop policy if exists home_cny_transactions_manual_insert on public.home_cny_transactions;
drop policy if exists home_cny_transactions_manual_update on public.home_cny_transactions;
drop policy if exists home_cny_transactions_manual_delete on public.home_cny_transactions;

create policy home_cny_transactions_owner_select
on public.home_cny_transactions
for select to authenticated
using (user_id = auth.uid());

create policy home_cny_transactions_manual_insert
on public.home_cny_transactions
for insert to authenticated
with check (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
);

create policy home_cny_transactions_manual_update
on public.home_cny_transactions
for update to authenticated
using (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
)
with check (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
);

create policy home_cny_transactions_manual_delete
on public.home_cny_transactions
for delete to authenticated
using (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
);

alter table public.home_jpy_transactions enable row level security;
drop policy if exists home_jpy_transactions_user_all on public.home_jpy_transactions;
drop policy if exists home_jpy_transactions_owner_select on public.home_jpy_transactions;
drop policy if exists home_jpy_transactions_manual_insert on public.home_jpy_transactions;
drop policy if exists home_jpy_transactions_manual_update on public.home_jpy_transactions;
drop policy if exists home_jpy_transactions_manual_delete on public.home_jpy_transactions;

create policy home_jpy_transactions_owner_select
on public.home_jpy_transactions
for select to authenticated
using (user_id = auth.uid());

create policy home_jpy_transactions_manual_insert
on public.home_jpy_transactions
for insert to authenticated
with check (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
);

create policy home_jpy_transactions_manual_update
on public.home_jpy_transactions
for update to authenticated
using (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
)
with check (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
);

create policy home_jpy_transactions_manual_delete
on public.home_jpy_transactions
for delete to authenticated
using (
  user_id = auth.uid()
  and created_by_external is not true
  and nullif(btrim(external_source), '') is null
  and external_source_id is null
  and nullif(btrim(external_event_type), '') is null
  and nullif(btrim(external_idempotency_key), '') is null
  and nullif(btrim(external_reference_type), '') is null
  and external_reference_id is null
  and nullif(btrim(external_note), '') is null
  and nullif(btrim(external_payload_hash), '') is null
  and external_created_at is null
);

revoke insert, update, delete, truncate, references, trigger
  on public.home_cny_transactions, public.home_jpy_transactions
  from public, anon;
revoke truncate, references, trigger
  on public.home_cny_transactions, public.home_jpy_transactions
  from authenticated;
grant select, insert, update, delete
  on public.home_cny_transactions, public.home_jpy_transactions
  to authenticated;

create or replace function public.home_update_cny_transaction(
  p_transaction_id uuid,
  p_account_id uuid,
  p_transfer_account_id uuid,
  p_transacted_at date,
  p_amount numeric,
  p_description text,
  p_note text
)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_transaction public.home_cny_transactions%rowtype;
begin
  select *
  into v_transaction
  from public.home_cny_transactions
  where id = p_transaction_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到可更新的人民币流水。');
  end if;

  if v_transaction.created_by_external is true
     or nullif(btrim(v_transaction.external_source), '') is not null
     or v_transaction.external_source_id is not null
     or nullif(btrim(v_transaction.external_event_type), '') is not null
     or nullif(btrim(v_transaction.external_idempotency_key), '') is not null
     or nullif(btrim(v_transaction.external_reference_type), '') is not null
     or v_transaction.external_reference_id is not null
     or nullif(btrim(v_transaction.external_note), '') is not null
     or nullif(btrim(v_transaction.external_payload_hash), '') is not null
     or v_transaction.external_created_at is not null then
    return jsonb_build_object(
      'ok', false, 'code', 'EXTERNAL_TRANSACTION_IMMUTABLE',
      'message', 'EXTERNAL_TRANSACTION_IMMUTABLE'
    );
  end if;

  if v_transaction.user_id is distinct from auth.uid() then
    return jsonb_build_object('ok', false, 'message', '没有找到可更新的人民币流水。');
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'message', '流水金额必须大于 0。');
  end if;

  if v_transaction.linked_fixed_month_item_id is not null then
    return jsonb_build_object('ok', false, 'message', '固定项生成的人民币流水请在固定收支中修改。');
  end if;

  if v_transaction.linked_jpy_transaction_id is not null then
    return jsonb_build_object('ok', false, 'message', '购汇联动流水请使用购汇编辑。');
  end if;

  if not exists (
    select 1
    from public.home_accounts
    where id = p_account_id
      and user_id = auth.uid()
      and currency = 'CNY'
      and is_active
  ) then
    return jsonb_build_object('ok', false, 'message', '人民币账户无效或已停用。');
  end if;

  if v_transaction.transaction_type = 'transfer' and (
    p_transfer_account_id is null
    or p_transfer_account_id = p_account_id
    or not exists (
      select 1
      from public.home_accounts
      where id = p_transfer_account_id
        and user_id = auth.uid()
        and currency = 'CNY'
        and is_active
    )
  ) then
    return jsonb_build_object('ok', false, 'message', '账户间转账需要选择有效且不同的转入账户。');
  end if;

  update public.home_cny_transactions
  set
    account_id = p_account_id,
    transfer_account_id = case when v_transaction.transaction_type = 'transfer' then p_transfer_account_id else null end,
    transacted_at = p_transacted_at,
    amount = p_amount,
    description = coalesce(p_description, ''),
    note = coalesce(p_note, '')
  where id = v_transaction.id
    and user_id = auth.uid();

  return jsonb_build_object('ok', true, 'updated_count', 1, 'message', '人民币流水已更新。');
end;
$function$;

create or replace function public.home_delete_cny_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_transaction public.home_cny_transactions%rowtype;
begin
  select *
  into v_transaction
  from public.home_cny_transactions
  where id = p_transaction_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到可删除的人民币流水。');
  end if;

  if v_transaction.created_by_external is true
     or nullif(btrim(v_transaction.external_source), '') is not null
     or v_transaction.external_source_id is not null
     or nullif(btrim(v_transaction.external_event_type), '') is not null
     or nullif(btrim(v_transaction.external_idempotency_key), '') is not null
     or nullif(btrim(v_transaction.external_reference_type), '') is not null
     or v_transaction.external_reference_id is not null
     or nullif(btrim(v_transaction.external_note), '') is not null
     or nullif(btrim(v_transaction.external_payload_hash), '') is not null
     or v_transaction.external_created_at is not null then
    return jsonb_build_object(
      'ok', false, 'code', 'EXTERNAL_TRANSACTION_IMMUTABLE',
      'message', 'EXTERNAL_TRANSACTION_IMMUTABLE'
    );
  end if;

  if v_transaction.user_id is distinct from auth.uid() then
    return jsonb_build_object('ok', false, 'message', '没有找到可删除的人民币流水。');
  end if;

  if v_transaction.linked_fixed_month_item_id is not null then
    return jsonb_build_object('ok', false, 'message', '固定项生成的人民币流水请在固定收支中删除。');
  end if;

  if v_transaction.linked_jpy_transaction_id is not null then
    return public.home_delete_cny_to_jpy_fx(v_transaction.id);
  end if;

  delete from public.home_cny_transactions
  where id = v_transaction.id
    and user_id = auth.uid();

  return jsonb_build_object('ok', true, 'deleted_count', 1, 'message', '人民币流水已删除。');
end;
$function$;

create or replace function public.home_update_jpy_transaction(
  p_transaction_id uuid,
  p_account_id uuid,
  p_transfer_account_id uuid,
  p_transacted_at date,
  p_amount numeric,
  p_description text,
  p_note text
)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_transaction public.home_jpy_transactions%rowtype;
  v_linked_fixed_month_item_id uuid;
  v_item public.home_fixed_month_items%rowtype;
  v_description text;
  v_reset jsonb := jsonb_build_object('reset_expense_status', false);
begin
  select *
  into v_transaction
  from public.home_jpy_transactions
  where id = p_transaction_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到可更新的日元流水。');
  end if;

  if v_transaction.created_by_external is true
     or nullif(btrim(v_transaction.external_source), '') is not null
     or v_transaction.external_source_id is not null
     or nullif(btrim(v_transaction.external_event_type), '') is not null
     or nullif(btrim(v_transaction.external_idempotency_key), '') is not null
     or nullif(btrim(v_transaction.external_reference_type), '') is not null
     or v_transaction.external_reference_id is not null
     or nullif(btrim(v_transaction.external_note), '') is not null
     or nullif(btrim(v_transaction.external_payload_hash), '') is not null
     or v_transaction.external_created_at is not null then
    return jsonb_build_object(
      'ok', false, 'code', 'EXTERNAL_TRANSACTION_IMMUTABLE',
      'message', 'EXTERNAL_TRANSACTION_IMMUTABLE'
    );
  end if;

  if v_transaction.user_id is distinct from auth.uid() then
    return jsonb_build_object('ok', false, 'message', '没有找到可更新的日元流水。');
  end if;

  if v_transaction.transaction_type in ('fixed_advance_out', 'fixed_advance_in') then
    return jsonb_build_object('ok', false, 'message', '固定垫付流水由固定收支流程控制，不能在零散收支中编辑。');
  end if;

  if v_transaction.transaction_type = 'investment_pnl' and coalesce(p_amount, 0) = 0 then
    return jsonb_build_object('ok', false, 'message', '投资损益金额不能为 0。');
  end if;

  if v_transaction.transaction_type <> 'investment_pnl' and coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'message', '流水金额必须大于 0。');
  end if;

  v_linked_fixed_month_item_id := public.home_resolve_fixed_transfer_item_id(v_transaction);

  if v_linked_fixed_month_item_id is null then
    update public.home_jpy_transactions
    set
      account_id = p_account_id,
      transfer_account_id = case when v_transaction.transaction_type = 'transfer' then p_transfer_account_id else null end,
      transacted_at = p_transacted_at,
      amount = p_amount,
      description = coalesce(p_description, ''),
      note = coalesce(p_note, '')
    where id = v_transaction.id
      and user_id = auth.uid();

    return jsonb_build_object(
      'ok', true, 'updated_count', 1, 'linked_updated', false,
      'reset_expense_status', false, 'message', '日元流水已更新。'
    );
  end if;

  select *
  into v_item
  from public.home_fixed_month_items
  where id = v_linked_fixed_month_item_id
    and user_id = auth.uid();

  if not found then
    return jsonb_build_object('ok', false, 'message', '调拨记录链接的固定项不存在，请删除后重新生成。');
  end if;

  if to_char(p_transacted_at, 'YYYY-MM') <> v_item.month_key then
    return jsonb_build_object('ok', false, 'message', '调拨记录不能跨月修改，请删除后重新生成。');
  end if;

  if v_transaction.transaction_type = 'fixed_out' and exists (
    select 1
    from public.home_fixed_month_items i
    where i.user_id = auth.uid()
      and i.month_key = v_item.month_key
      and i.currency = v_item.currency
      and i.direction = 'income'
      and i.name = '固定赤字补充'
      and i.id <> v_item.id
  ) then
    return jsonb_build_object('ok', false, 'message', '本月已存在固定赤字补充，可在日元零散流水中编辑或删除。');
  end if;

  v_description := public.home_fixed_transfer_name(v_transaction.transaction_type);

  update public.home_jpy_transactions
  set
    account_id = p_account_id,
    transfer_account_id = null,
    transacted_at = p_transacted_at,
    amount = p_amount,
    description = v_description,
    note = coalesce(p_note, '')
  where id = v_transaction.id
    and user_id = auth.uid();

  update public.home_fixed_month_items
  set
    account_id = p_account_id,
    due_date = p_transacted_at,
    amount = p_amount,
    name = v_description,
    note = coalesce(p_note, ''),
    status = 'paid'
  where id = v_item.id
    and user_id = auth.uid();

  v_reset := public.home_reset_plain_fixed_expenses_if_deficit(v_item.month_key, v_item.currency);

  return jsonb_build_object(
    'ok', true,
    'updated_count', 1,
    'linked_updated', true,
    'reset_expense_status', coalesce((v_reset ->> 'reset_expense_status')::boolean, false),
    'message', case
      when coalesce((v_reset ->> 'reset_expense_status')::boolean, false)
        then '调拨流水及固定收支记录已同步更新；更新后重新出现赤字，普通固定支出已改回未付。'
      else '调拨流水及固定收支记录已同步更新。'
    end
  );
end;
$function$;

create or replace function public.home_delete_jpy_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_transaction public.home_jpy_transactions%rowtype;
  v_linked_fixed_month_item_id uuid;
  v_item public.home_fixed_month_items%rowtype;
  v_reset jsonb := jsonb_build_object('reset_expense_status', false);
  v_linked_deleted boolean := false;
  v_message text := '已删除。';
begin
  select *
  into v_transaction
  from public.home_jpy_transactions
  where id = p_transaction_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到可删除的日元流水。');
  end if;

  if v_transaction.created_by_external is true
     or nullif(btrim(v_transaction.external_source), '') is not null
     or v_transaction.external_source_id is not null
     or nullif(btrim(v_transaction.external_event_type), '') is not null
     or nullif(btrim(v_transaction.external_idempotency_key), '') is not null
     or nullif(btrim(v_transaction.external_reference_type), '') is not null
     or v_transaction.external_reference_id is not null
     or nullif(btrim(v_transaction.external_note), '') is not null
     or nullif(btrim(v_transaction.external_payload_hash), '') is not null
     or v_transaction.external_created_at is not null then
    return jsonb_build_object(
      'ok', false, 'code', 'EXTERNAL_TRANSACTION_IMMUTABLE',
      'message', 'EXTERNAL_TRANSACTION_IMMUTABLE'
    );
  end if;

  if v_transaction.user_id is distinct from auth.uid() then
    return jsonb_build_object('ok', false, 'message', '没有找到可删除的日元流水。');
  end if;

  if v_transaction.transaction_type in ('fixed_advance_out', 'fixed_advance_in') then
    return jsonb_build_object('ok', false, 'message', '固定垫付流水由固定收支流程控制，不能在零散收支中删除。');
  end if;

  v_linked_fixed_month_item_id := public.home_resolve_fixed_transfer_item_id(v_transaction);

  if v_linked_fixed_month_item_id is not null then
    select *
    into v_item
    from public.home_fixed_month_items
    where id = v_linked_fixed_month_item_id
      and user_id = auth.uid();

    if not found then
      return jsonb_build_object('ok', false, 'message', '调拨流水链接的固定项不存在，请检查旧数据后再删除。');
    end if;

    delete from public.home_fixed_month_items
    where id = v_linked_fixed_month_item_id
      and user_id = auth.uid();

    v_linked_deleted := true;
  elsif v_transaction.transaction_type in ('fixed_in', 'fixed_out') then
    v_message := '已删除日元流水，但旧数据链接不完整，未能唯一匹配固定项。';
  end if;

  delete from public.home_jpy_transactions
  where id = v_transaction.id
    and user_id = auth.uid();

  if v_linked_deleted then
    v_reset := public.home_reset_plain_fixed_expenses_if_deficit(v_item.month_key, v_item.currency);
  end if;

  return jsonb_build_object(
    'ok', true,
    'deleted_count', 1,
    'linked_deleted', v_linked_deleted,
    'reset_expense_status', coalesce((v_reset ->> 'reset_expense_status')::boolean, false),
    'message', case
      when v_linked_deleted and coalesce((v_reset ->> 'reset_expense_status')::boolean, false)
        then '已同步删除固定收支记录；删除后重新出现赤字，普通固定支出已改回未付。'
      when v_linked_deleted
        then '已同步删除固定收支记录。'
      else v_message
    end
  );
end;
$function$;

alter function public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text) owner to postgres;
alter function public.home_delete_cny_transaction(uuid) owner to postgres;
alter function public.home_update_jpy_transaction(uuid,uuid,uuid,date,numeric,text,text) owner to postgres;
alter function public.home_delete_jpy_transaction(uuid) owner to postgres;

revoke all on function public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)
  from public, anon;
revoke all on function public.home_delete_cny_transaction(uuid)
  from public, anon;
revoke all on function public.home_update_jpy_transaction(uuid,uuid,uuid,date,numeric,text,text)
  from public, anon;
revoke all on function public.home_delete_jpy_transaction(uuid)
  from public, anon;

grant execute on function public.home_update_cny_transaction(uuid,uuid,uuid,date,numeric,text,text)
  to authenticated, service_role;
grant execute on function public.home_delete_cny_transaction(uuid)
  to authenticated, service_role;
grant execute on function public.home_update_jpy_transaction(uuid,uuid,uuid,date,numeric,text,text)
  to authenticated, service_role;
grant execute on function public.home_delete_jpy_transaction(uuid)
  to authenticated, service_role;

commit;
