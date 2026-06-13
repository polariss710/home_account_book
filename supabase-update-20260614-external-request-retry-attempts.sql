-- supabase-update-20260614-external-request-retry-attempts.sql
-- Status: pending apply on Cash DB.
-- Purpose:
-- - Allow a rejected external request to remain as history while School creates
--   a later retry attempt for the same external_reference_id.
-- - Keep idempotency_key and external_event_id unique per attempt.
-- - Keep at most one pending/approved request for the same School reference.

drop index if exists public.home_external_transaction_requests_reference_request_unique;

create unique index if not exists home_external_transaction_requests_reference_active_unique
  on public.home_external_transaction_requests (
    external_source,
    external_reference_type,
    external_reference_id,
    request_type
  )
  where status in ('pending', 'approved');

create or replace function public.home_create_external_transaction_request(
  p_user_id uuid,
  p_account_id uuid,
  p_external_source text,
  p_external_event_id uuid,
  p_external_reference_type text,
  p_external_reference_id uuid,
  p_request_type text,
  p_transaction_type text,
  p_transacted_at date,
  p_amount numeric,
  p_idempotency_key text,
  p_description text default null,
  p_note text default null,
  p_payload_snapshot jsonb default '{}'::jsonb,
  p_currency text default 'JPY'
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_account public.home_accounts%rowtype;
  v_existing public.home_external_transaction_requests%rowtype;
  v_request_id uuid;
  v_external_source text := lower(trim(coalesce(p_external_source, '')));
  v_external_reference_type text := lower(trim(coalesce(p_external_reference_type, '')));
  v_request_type text := lower(trim(coalesce(p_request_type, '')));
  v_transaction_type text := lower(trim(coalesce(p_transaction_type, '')));
  v_currency text := upper(trim(coalesce(p_currency, 'JPY')));
  v_idempotency_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_description text := coalesce(nullif(trim(coalesce(p_description, '')), ''), '外部待确认请求');
  v_note text := coalesce(p_note, '');
  v_payload_snapshot jsonb;
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

  if p_external_event_id is null then
    return jsonb_build_object('ok', false, 'message', 'external_event_id is required');
  end if;

  if p_external_reference_id is null then
    return jsonb_build_object('ok', false, 'message', 'external_reference_id is required');
  end if;

  if p_transacted_at is null then
    return jsonb_build_object('ok', false, 'message', 'transacted_at is required');
  end if;

  if coalesce(p_amount, 0) <= 0 then
    return jsonb_build_object('ok', false, 'message', 'amount must be greater than 0');
  end if;

  if v_idempotency_key is null then
    return jsonb_build_object('ok', false, 'message', 'idempotency_key is required');
  end if;

  if v_currency not in ('JPY', 'CNY') then
    return jsonb_build_object('ok', false, 'message', 'currency must be JPY or CNY');
  end if;

  if v_external_source <> 'aozora_school' then
    return jsonb_build_object('ok', false, 'message', 'external_source must be aozora_school');
  end if;

  if v_external_reference_type not in ('school_payment_requests', 'school_income_records') then
    return jsonb_build_object('ok', false, 'message', 'unsupported external_reference_type');
  end if;

  if v_request_type = 'teacher_wage_payment_confirm' then
    if v_external_reference_type <> 'school_payment_requests' or v_transaction_type <> 'expense' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_confirm must reference school_payment_requests and create expense');
    end if;
  elsif v_request_type = 'teacher_wage_payment_reverse' then
    if v_external_reference_type <> 'school_payment_requests' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_reverse must reference school_payment_requests and create income');
    end if;
  elsif v_request_type in ('tuition_income_received', 'income_received') then
    if v_external_reference_type <> 'school_income_records' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'income received requests must reference school_income_records and create income');
    end if;
  else
    return jsonb_build_object('ok', false, 'message', 'unsupported request_type');
  end if;

  select *
  into v_account
  from public.home_accounts
  where id = p_account_id
    and user_id = p_user_id
    and currency = v_currency
    and is_active is true
    and allow_school_requests is true;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'school-eligible account not found, inactive, or currency mismatch');
  end if;

  v_payload_snapshot := case
    when p_payload_snapshot is null or p_payload_snapshot = '{}'::jsonb then
      jsonb_build_object(
        'external_source', v_external_source,
        'external_event_id', p_external_event_id,
        'external_reference_type', v_external_reference_type,
        'external_reference_id', p_external_reference_id,
        'request_type', v_request_type,
        'transaction_type', v_transaction_type,
        'currency', v_currency,
        'amount', p_amount,
        'account_id', p_account_id,
        'transacted_at', p_transacted_at,
        'description', v_description,
        'note', v_note
      )
    else p_payload_snapshot
  end;

  select *
  into v_existing
  from public.home_external_transaction_requests
  where idempotency_key = v_idempotency_key
  limit 1;

  if found then
    if v_existing.user_id is distinct from p_user_id
      or v_existing.account_id is distinct from p_account_id
      or v_existing.external_source is distinct from v_external_source
      or v_existing.external_event_id is distinct from p_external_event_id
      or v_existing.external_reference_type is distinct from v_external_reference_type
      or v_existing.external_reference_id is distinct from p_external_reference_id
      or v_existing.request_type is distinct from v_request_type
      or v_existing.transaction_type is distinct from v_transaction_type
      or v_existing.currency is distinct from v_currency
      or v_existing.amount is distinct from p_amount
      or v_existing.transacted_at is distinct from p_transacted_at then
      return jsonb_build_object(
        'ok', false,
        'message', 'external request idempotency key already exists with different payload',
        'request_id', v_existing.id
      );
    end if;

    return jsonb_build_object(
      'ok', true,
      'inserted', false,
      'request_id', v_existing.id,
      'status', v_existing.status,
      'created_transaction_id', v_existing.created_transaction_id,
      'message', 'external transaction request already exists'
    );
  end if;

  select *
  into v_existing
  from public.home_external_transaction_requests
  where external_source = v_external_source
    and external_reference_type = v_external_reference_type
    and external_reference_id = p_external_reference_id
    and request_type = v_request_type
    and status in ('pending', 'approved')
  limit 1;

  if found then
    return jsonb_build_object(
      'ok', false,
      'message', 'active or approved external transaction request already exists for this reference',
      'request_id', v_existing.id,
      'status', v_existing.status,
      'created_transaction_id', v_existing.created_transaction_id
    );
  end if;

  insert into public.home_external_transaction_requests (
    user_id,
    external_source,
    external_event_id,
    external_reference_type,
    external_reference_id,
    request_type,
    transaction_type,
    currency,
    amount,
    account_id,
    transacted_at,
    status,
    idempotency_key,
    payload_snapshot,
    description,
    note
  )
  values (
    p_user_id,
    v_external_source,
    p_external_event_id,
    v_external_reference_type,
    p_external_reference_id,
    v_request_type,
    v_transaction_type,
    v_currency,
    p_amount,
    p_account_id,
    p_transacted_at,
    'pending',
    v_idempotency_key,
    v_payload_snapshot,
    v_description,
    v_note
  )
  returning id into v_request_id;

  return jsonb_build_object(
    'ok', true,
    'inserted', true,
    'request_id', v_request_id,
    'status', 'pending',
    'message', 'external transaction request created'
  );
exception
  when unique_violation then
    select *
    into v_existing
    from public.home_external_transaction_requests
    where idempotency_key = v_idempotency_key
       or (
         external_source = v_external_source
         and external_event_id = p_external_event_id
         and request_type = v_request_type
       )
       or (
         external_source = v_external_source
         and external_reference_type = v_external_reference_type
         and external_reference_id = p_external_reference_id
         and request_type = v_request_type
         and status in ('pending', 'approved')
       )
    limit 1;

    if found then
      if v_existing.user_id is distinct from p_user_id
        or v_existing.account_id is distinct from p_account_id
        or v_existing.external_source is distinct from v_external_source
        or v_existing.external_event_id is distinct from p_external_event_id
        or v_existing.external_reference_type is distinct from v_external_reference_type
        or v_existing.external_reference_id is distinct from p_external_reference_id
        or v_existing.request_type is distinct from v_request_type
        or v_existing.transaction_type is distinct from v_transaction_type
        or v_existing.currency is distinct from v_currency
        or v_existing.amount is distinct from p_amount
        or v_existing.transacted_at is distinct from p_transacted_at then
        return jsonb_build_object(
          'ok', false,
          'message', 'external transaction request already exists with different payload',
          'request_id', v_existing.id
        );
      end if;

      return jsonb_build_object(
        'ok', true,
        'inserted', false,
        'request_id', v_existing.id,
        'status', v_existing.status,
        'created_transaction_id', v_existing.created_transaction_id,
        'message', 'external transaction request already exists'
      );
    end if;

    raise;
end;
$$;

comment on index public.home_external_transaction_requests_reference_active_unique is
  'Allows rejected external requests to remain as history while preventing more than one pending/approved request for the same external reference and request type.';

comment on function public.home_create_external_transaction_request(
  uuid,
  uuid,
  text,
  uuid,
  text,
  uuid,
  text,
  text,
  date,
  numeric,
  text,
  text,
  text,
  jsonb,
  text
) is
  'Idempotently creates one pending external request attempt. Rejected attempts do not block later attempts; pending or approved requests for the same external reference do.';
