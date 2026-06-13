-- supabase-update-20260613-school-account-eligibility-and-multicurrency.sql
-- Purpose:
-- - Add Cash-account eligibility for School-originated external requests.
-- - Extend Cash external transaction requests from JPY-only to JPY/CNY.
-- - Keep Cash-owned approval semantics: pending requests do not change balances;
--   approve creates/reuses the matching currency transaction; reject creates none.
-- - Incremental migration only. Do not run supabase-schema.sql for this change.

alter table public.home_accounts
  add column if not exists allow_school_requests boolean not null default false;

do $$
declare
  v_actual_names text[];
  v_expected_names text[] := array[
    '余利宝',
    '余额宝',
    '医生处兑换日元先行支付',
    '日元三菱卡',
    '日元乐天卡',
    '日元现金'
  ];
  v_missing_names text[];
begin
  select coalesce(array_agg(name order by name), array[]::text[])
  into v_actual_names
  from public.home_accounts;

  select coalesce(array_agg(expected_name order by expected_name), array[]::text[])
  into v_missing_names
  from unnest(v_expected_names) as expected_name
  where not exists (
    select 1
    from public.home_accounts a
    where a.name = expected_name
  );

  if coalesce(array_length(v_missing_names, 1), 0) > 0 then
    raise exception 'Cash account names do not match expected whitelist. actual names: %, missing names: %',
      v_actual_names,
      v_missing_names;
  end if;
end $$;

update public.home_accounts
set allow_school_requests = case
  when name in ('余额宝', '日元现金', '日元三菱卡', '日元乐天卡') then true
  when name in ('余利宝', '医生处兑换日元先行支付') then false
  else false
end;

comment on column public.home_accounts.allow_school_requests is
  'Whether this active Cash account may be selected by School-originated external request flows. School reads this as a whitelist and does not maintain Cash balances.';

alter table public.home_cny_transactions
  add column if not exists external_source text,
  add column if not exists external_source_id uuid,
  add column if not exists external_event_type text,
  add column if not exists external_idempotency_key text,
  add column if not exists external_reference_type text,
  add column if not exists external_reference_id uuid,
  add column if not exists external_note text,
  add column if not exists external_payload_hash text,
  add column if not exists external_created_at timestamptz,
  add column if not exists created_by_external boolean not null default false;

create unique index if not exists home_cny_transactions_external_idempotency_unique
  on public.home_cny_transactions (external_idempotency_key)
  where created_by_external is true
    and external_idempotency_key is not null;

create unique index if not exists home_cny_transactions_external_source_event_unique
  on public.home_cny_transactions (
    external_source,
    external_reference_type,
    external_reference_id,
    external_event_type
  )
  where created_by_external is true
    and external_source is not null
    and external_reference_type is not null
    and external_reference_id is not null
    and external_event_type is not null;

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
          and external_event_type in ('tuition_income_received', 'income_received')
          and transaction_type = 'income'
        )
      )
    )
  );

alter table public.home_cny_transactions
  drop constraint if exists home_cny_transactions_external_required_check;

alter table public.home_cny_transactions
  add constraint home_cny_transactions_external_required_check
  check (
    created_by_external is not true
    or (
      external_source = 'aozora_school'
      and external_source_id is not null
      and external_idempotency_key is not null
      and external_reference_id is not null
      and currency = 'CNY'
      and amount > 0
      and transfer_account_id is null
      and linked_fixed_month_item_id is null
      and linked_jpy_transaction_id is null
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
          and external_event_type in ('tuition_income_received', 'income_received')
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
    if v_external_reference_type <> 'school_payment_requests' or v_transaction_type <> 'expense' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_confirm must reference school_payment_requests and create expense');
    end if;
  elsif v_external_event_type = 'teacher_wage_payment_reverse' then
    if v_external_reference_type <> 'school_payment_requests' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_reverse must reference school_payment_requests and create income');
    end if;
  elsif v_external_event_type in ('tuition_income_received', 'income_received') then
    if v_external_reference_type <> 'school_income_records' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'income received requests must reference school_income_records and create income');
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
    and is_active is true
    and allow_school_requests is true;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'school-eligible JPY account not found or inactive');
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
  'Creates one idempotent external-source JPY transaction for aozora school requests after Cash approval. Requires a school-eligible active JPY account.';

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

create or replace function public.home_create_external_cny_transaction(
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
  v_existing public.home_cny_transactions%rowtype;
  v_transaction_id uuid;
  v_transaction_type text := lower(trim(coalesce(p_transaction_type, '')));
  v_external_source text := lower(trim(coalesce(p_external_source, '')));
  v_external_event_type text := lower(trim(coalesce(p_external_event_type, '')));
  v_external_reference_type text := lower(trim(coalesce(p_external_reference_type, '')));
  v_external_idempotency_key text := nullif(trim(coalesce(p_external_idempotency_key, '')), '');
  v_description text := coalesce(nullif(trim(coalesce(p_description, '')), ''), '外部来源人民币流水');
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
    if v_external_reference_type <> 'school_payment_requests' or v_transaction_type <> 'expense' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_confirm must reference school_payment_requests and create expense');
    end if;
  elsif v_external_event_type = 'teacher_wage_payment_reverse' then
    if v_external_reference_type <> 'school_payment_requests' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'teacher_wage_payment_reverse must reference school_payment_requests and create income');
    end if;
  elsif v_external_event_type in ('tuition_income_received', 'income_received') then
    if v_external_reference_type <> 'school_income_records' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'income received requests must reference school_income_records and create income');
    end if;
  else
    return jsonb_build_object('ok', false, 'message', 'unsupported external_event_type');
  end if;

  select *
  into v_account
  from public.home_accounts
  where id = p_account_id
    and user_id = p_user_id
    and currency = 'CNY'
    and is_active is true
    and allow_school_requests is true;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'school-eligible CNY account not found or inactive');
  end if;

  select *
  into v_existing
  from public.home_cny_transactions
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
      'message', 'external CNY transaction already exists'
    );
  end if;

  select *
  into v_existing
  from public.home_cny_transactions
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
      'message', 'external CNY transaction already exists'
    );
  end if;

  insert into public.home_cny_transactions (
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
    'CNY',
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
    'message', 'external CNY transaction created'
  );
exception
  when unique_violation then
    select *
    into v_existing
    from public.home_cny_transactions
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
        'message', 'external CNY transaction already exists'
      );
    end if;

    raise;
end;
$$;

comment on function public.home_create_external_cny_transaction(
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
  'Creates one idempotent external-source CNY transaction for aozora school requests after Cash approval. Requires a school-eligible active CNY account.';

revoke all on function public.home_create_external_cny_transaction(
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

grant execute on function public.home_create_external_cny_transaction(
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

alter table public.home_external_transaction_requests
  drop constraint if exists home_external_transaction_requests_created_transaction_id_fkey,
  drop constraint if exists home_external_transaction_requests_currency_check,
  drop constraint if exists home_external_transaction_requests_reference_check;

alter table public.home_external_transaction_requests
  add constraint home_external_transaction_requests_currency_check
    check (currency in ('JPY', 'CNY')),
  add constraint home_external_transaction_requests_reference_check
    check (
      (
        external_reference_type = 'school_payment_requests'
        and request_type = 'teacher_wage_payment_confirm'
        and transaction_type = 'expense'
      )
      or (
        external_reference_type = 'school_payment_requests'
        and request_type = 'teacher_wage_payment_reverse'
        and transaction_type = 'income'
      )
      or (
        external_reference_type = 'school_income_records'
        and request_type in ('tuition_income_received', 'income_received')
        and transaction_type = 'income'
      )
    );

comment on column public.home_external_transaction_requests.created_transaction_id is
  'Transaction id created only after Cash-side approval. For JPY it references home_jpy_transactions.id by convention; for CNY it references home_cny_transactions.id by convention. Null for pending and rejected requests.';

drop function if exists public.home_create_external_transaction_request(
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
  jsonb
);

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
  'Creates an idempotent pending external transaction request for JPY/CNY school-eligible Cash accounts. Does not create Cash transactions or change balances.';

grant execute on function public.home_create_external_transaction_request(
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
) to authenticated, service_role;

create or replace function public.home_approve_external_transaction_request(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_transaction_result jsonb;
  v_transaction_id uuid;
begin
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'message', 'request_id is required');
  end if;

  select *
  into v_request
  from public.home_external_transaction_requests
  where id = p_request_id
  for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', 'external transaction request not found');
  end if;

  if auth.uid() is not null and auth.uid() is distinct from v_request.user_id then
    return jsonb_build_object('ok', false, 'message', 'authenticated user does not match request owner');
  end if;

  if v_request.status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'only pending requests can be approved', 'status', v_request.status);
  end if;

  if v_request.currency = 'JPY' then
    select public.home_create_external_jpy_transaction(
      v_request.user_id,
      v_request.account_id,
      v_request.transaction_type,
      v_request.transacted_at,
      v_request.amount,
      v_request.description,
      v_request.note,
      v_request.external_source,
      v_request.external_event_id,
      v_request.request_type,
      v_request.idempotency_key,
      v_request.external_reference_type,
      v_request.external_reference_id,
      v_request.note,
      md5(v_request.payload_snapshot::text)
    )
    into v_transaction_result;
  elsif v_request.currency = 'CNY' then
    select public.home_create_external_cny_transaction(
      v_request.user_id,
      v_request.account_id,
      v_request.transaction_type,
      v_request.transacted_at,
      v_request.amount,
      v_request.description,
      v_request.note,
      v_request.external_source,
      v_request.external_event_id,
      v_request.request_type,
      v_request.idempotency_key,
      v_request.external_reference_type,
      v_request.external_reference_id,
      v_request.note,
      md5(v_request.payload_snapshot::text)
    )
    into v_transaction_result;
  else
    return jsonb_build_object('ok', false, 'message', 'unsupported request currency', 'currency', v_request.currency);
  end if;

  if coalesce((v_transaction_result->>'ok')::boolean, false) is not true then
    return v_transaction_result;
  end if;

  v_transaction_id := (v_transaction_result->>'transaction_id')::uuid;

  update public.home_external_transaction_requests
  set
    status = 'approved',
    approved_at = now(),
    created_transaction_id = v_transaction_id,
    updated_at = now()
  where id = v_request.id;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_request.id,
    'status', 'approved',
    'currency', v_request.currency,
    'transaction_id', v_transaction_id,
    'transaction_inserted', coalesce((v_transaction_result->>'inserted')::boolean, false),
    'message', 'external transaction request approved'
  );
end;
$$;

comment on function public.home_approve_external_transaction_request(uuid) is
  'Approves one pending external transaction request and then creates/reuses the idempotent JPY or CNY transaction.';

grant execute on function public.home_approve_external_transaction_request(uuid) to authenticated, service_role;

create or replace function public.home_list_school_eligible_cash_accounts()
returns jsonb
language sql
security invoker
set search_path = public
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', id,
        'name', name,
        'currency', currency,
        'account_type', account_type,
        'is_active', is_active,
        'allow_school_requests', allow_school_requests
      )
      order by currency, sort_order, name
    ),
    '[]'::jsonb
  )
  from public.home_accounts
  where user_id = auth.uid()
    and is_active is true
    and allow_school_requests is true;
$$;

comment on function public.home_list_school_eligible_cash_accounts() is
  'Reads active Cash accounts that may be selected by School-originated external request flows.';

grant execute on function public.home_list_school_eligible_cash_accounts() to authenticated;
