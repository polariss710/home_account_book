-- supabase-update-20260613-external-jpy-2.sql
-- Purpose:
-- - Extend the idempotent external-source JPY transaction guard for Phase 2
--   aozora school personal-business tuition income linkage.
-- - Keeps Phase 1 teacher wage payment confirm/reverse support unchanged.
-- - Incremental migration only. Do not run supabase-schema.sql for this change.
-- - Does not modify CNY, FX, fixed items, school DB, or ordinary page code.

alter table public.home_jpy_transactions
  drop constraint if exists home_jpy_transactions_external_required_check;

alter table public.home_jpy_transactions
  add constraint home_jpy_transactions_external_required_check
  check (
    created_by_external is not true
    or (
      external_source = 'aozora_school'
      and external_source_id is not null
      and external_idempotency_key is not null
      and external_reference_id is not null
      and currency = 'JPY'
      and amount > 0
      and transfer_account_id is null
      and linked_fixed_month_item_id is null
      and linked_cny_transaction_id is null
      and (
        (
          external_reference_type = 'school_payment_requests'
          and external_event_type = 'teacher_wage_payment_confirm'
          and transaction_type = 'expense'
        )
        or (
          external_reference_type = 'school_payment_requests'
          and external_event_type = 'teacher_wage_payment_reverse'
          and transaction_type = 'income'
        )
        or (
          external_reference_type = 'school_income_records'
          and external_event_type = 'tuition_income_received'
          and transaction_type = 'income'
        )
      )
    )
  );

create or replace function public.home_create_external_jpy_transaction(
  p_user_id uuid,
  p_account_id uuid,
  p_transaction_type text,
  p_transacted_at date,
  p_amount numeric,
  p_description text,
  p_note text,
  p_external_source text,
  p_external_source_id uuid,
  p_external_event_type text,
  p_external_idempotency_key text,
  p_external_reference_type text,
  p_external_reference_id uuid,
  p_external_note text default null,
  p_external_payload_hash text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.home_accounts%rowtype;
  v_existing public.home_jpy_transactions%rowtype;
  v_transaction_id uuid;
  v_transaction_type text := lower(trim(coalesce(p_transaction_type, '')));
  v_external_source text := lower(trim(coalesce(p_external_source, '')));
  v_external_event_type text := lower(trim(coalesce(p_external_event_type, '')));
  v_external_reference_type text := lower(trim(coalesce(p_external_reference_type, '')));
  v_external_idempotency_key text := nullif(trim(coalesce(p_external_idempotency_key, '')), '');
  v_description text := coalesce(nullif(trim(coalesce(p_description, '')), ''), '外部来源日元流水');
  v_note text := coalesce(p_note, '');
  v_external_note text := nullif(trim(coalesce(p_external_note, '')), '');
begin
  if p_user_id is null then
    return jsonb_build_object('ok', false, 'message', 'user_id is required');
  end if;

  if auth.uid() is not null and auth.uid() is distinct from p_user_id then
    return jsonb_build_object('ok', false, 'message', 'authenticated user does not match target user');
  end if;

  if p_account_id is null then
    return jsonb_build_object('ok', false, 'message', 'account_id is required');
  end if;

  if p_transacted_at is null then
    return jsonb_build_object('ok', false, 'message', 'transacted_at is required');
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'message', 'amount must be greater than 0');
  end if;

  if v_external_source <> 'aozora_school' then
    return jsonb_build_object('ok', false, 'message', 'external_source must be aozora_school');
  end if;

  if p_external_source_id is null then
    return jsonb_build_object('ok', false, 'message', 'external_source_id is required');
  end if;

  if v_external_reference_type not in ('school_payment_requests', 'school_income_records') then
    return jsonb_build_object('ok', false, 'message', 'unsupported external_reference_type');
  end if;

  if p_external_reference_id is null then
    return jsonb_build_object('ok', false, 'message', 'external_reference_id is required');
  end if;

  if v_external_idempotency_key is null then
    return jsonb_build_object('ok', false, 'message', 'external_idempotency_key is required');
  end if;

  if v_external_event_type = 'teacher_wage_payment_confirm' then
    if v_external_reference_type <> 'school_payment_requests' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_confirm must reference school_payment_requests');
    end if;

    if v_transaction_type <> 'expense' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_confirm must create an expense transaction');
    end if;
  elsif v_external_event_type = 'teacher_wage_payment_reverse' then
    if v_external_reference_type <> 'school_payment_requests' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_reverse must reference school_payment_requests');
    end if;

    if v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_reverse must create an income transaction');
    end if;
  elsif v_external_event_type = 'tuition_income_received' then
    if v_external_reference_type <> 'school_income_records' then
      return jsonb_build_object('ok', false, 'message', 'tuition_income_received must reference school_income_records');
    end if;

    if v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'tuition_income_received must create an income transaction');
    end if;
  else
    return jsonb_build_object('ok', false, 'message', 'unsupported external_event_type');
  end if;

  select *
  into v_account
  from public.home_accounts
  where id = p_account_id
    and user_id = p_user_id
    and currency = 'JPY'
    and is_active is true;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'JPY account not found or inactive');
  end if;

  select *
  into v_existing
  from public.home_jpy_transactions
  where created_by_external is true
    and external_idempotency_key = v_external_idempotency_key
  limit 1;

  if found then
    if v_existing.user_id is distinct from p_user_id
      or v_existing.account_id is distinct from p_account_id
      or v_existing.transaction_type is distinct from v_transaction_type
      or v_existing.transacted_at is distinct from p_transacted_at
      or v_existing.amount is distinct from p_amount
      or v_existing.external_source is distinct from v_external_source
      or v_existing.external_source_id is distinct from p_external_source_id
      or v_existing.external_event_type is distinct from v_external_event_type
      or v_existing.external_reference_type is distinct from v_external_reference_type
      or v_existing.external_reference_id is distinct from p_external_reference_id then
      return jsonb_build_object(
        'ok', false,
        'message', 'external idempotency key already exists with different payload',
        'transaction_id', v_existing.id
      );
    end if;

    return jsonb_build_object(
      'ok', true,
      'inserted', false,
      'transaction_id', v_existing.id,
      'message', 'external JPY transaction already exists'
    );
  end if;

  select *
  into v_existing
  from public.home_jpy_transactions
  where created_by_external is true
    and external_source = v_external_source
    and external_reference_type = v_external_reference_type
    and external_reference_id = p_external_reference_id
    and external_event_type = v_external_event_type
  limit 1;

  if found then
    if v_existing.user_id is distinct from p_user_id
      or v_existing.account_id is distinct from p_account_id
      or v_existing.transaction_type is distinct from v_transaction_type
      or v_existing.transacted_at is distinct from p_transacted_at
      or v_existing.amount is distinct from p_amount then
      return jsonb_build_object(
        'ok', false,
        'message', 'external source event already exists with different payload',
        'transaction_id', v_existing.id
      );
    end if;

    return jsonb_build_object(
      'ok', true,
      'inserted', false,
      'transaction_id', v_existing.id,
      'message', 'external JPY transaction already exists'
    );
  end if;

  insert into public.home_jpy_transactions (
    user_id,
    currency,
    transaction_type,
    account_id,
    transfer_account_id,
    transacted_at,
    amount,
    description,
    note,
    external_source,
    external_source_id,
    external_event_type,
    external_idempotency_key,
    external_reference_type,
    external_reference_id,
    external_note,
    external_payload_hash,
    external_created_at,
    created_by_external
  )
  values (
    p_user_id,
    'JPY',
    v_transaction_type,
    p_account_id,
    null,
    p_transacted_at,
    p_amount,
    v_description,
    v_note,
    v_external_source,
    p_external_source_id,
    v_external_event_type,
    v_external_idempotency_key,
    v_external_reference_type,
    p_external_reference_id,
    v_external_note,
    nullif(trim(coalesce(p_external_payload_hash, '')), ''),
    now(),
    true
  )
  returning id into v_transaction_id;

  return jsonb_build_object(
    'ok', true,
    'inserted', true,
    'transaction_id', v_transaction_id,
    'message', 'external JPY transaction created'
  );
exception
  when unique_violation then
    select *
    into v_existing
    from public.home_jpy_transactions
    where created_by_external is true
      and (
        external_idempotency_key = v_external_idempotency_key
        or (
          external_source = v_external_source
          and external_reference_type = v_external_reference_type
          and external_reference_id = p_external_reference_id
          and external_event_type = v_external_event_type
        )
      )
    limit 1;

    if found then
      return jsonb_build_object(
        'ok', true,
        'inserted', false,
        'transaction_id', v_existing.id,
        'message', 'external JPY transaction already exists'
      );
    end if;

    raise;
end;
$$;

comment on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) is
  'Creates one idempotent external-source JPY transaction for aozora school teacher wage and personal-business tuition income linkage. Does not write CNY, FX, fixed items, or school DB.';

revoke all on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) from public;

revoke all on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) from anon;

grant execute on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) to authenticated, service_role;
