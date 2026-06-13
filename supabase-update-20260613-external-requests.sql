-- supabase-update-20260613-external-requests.sql
-- Purpose:
-- - Add Cash-owned pending external transaction requests for Cash linkage v2.
-- - School-originated requests stay pending until a Cash user approves/rejects.
-- - Approval calls the existing idempotent home_create_external_jpy_transaction RPC.
-- - Rejection records state/reason and creates no Cash transaction.
-- - Incremental migration only. Do not run supabase-schema.sql for this change.

create table if not exists public.home_external_transaction_requests (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  external_source text not null,
  external_event_id uuid not null,
  external_reference_type text not null,
  external_reference_id uuid not null,
  request_type text not null,
  transaction_type text not null,
  currency text not null default 'JPY',
  amount numeric(14, 2) not null,
  account_id uuid not null references public.home_accounts(id) on delete restrict,
  transacted_at date not null default current_date,
  status text not null default 'pending',
  requested_at timestamptz not null default now(),
  approved_at timestamptz,
  rejected_at timestamptz,
  rejected_reason text,
  created_transaction_id uuid references public.home_jpy_transactions(id) on delete restrict,
  idempotency_key text not null,
  payload_snapshot jsonb not null default '{}'::jsonb,
  description text not null default '外部待确认请求',
  note text not null default '',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint home_external_transaction_requests_source_check
    check (external_source = 'aozora_school'),
  constraint home_external_transaction_requests_currency_check
    check (currency = 'JPY'),
  constraint home_external_transaction_requests_amount_check
    check (amount > 0),
  constraint home_external_transaction_requests_transaction_type_check
    check (transaction_type in ('income', 'expense')),
  constraint home_external_transaction_requests_status_check
    check (status in ('pending', 'approved', 'rejected')),
  constraint home_external_transaction_requests_reference_check
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
        and request_type = 'tuition_income_received'
        and transaction_type = 'income'
      )
    ),
  constraint home_external_transaction_requests_lifecycle_check
    check (
      (
        status = 'pending'
        and approved_at is null
        and rejected_at is null
        and rejected_reason is null
        and created_transaction_id is null
      )
      or (
        status = 'approved'
        and approved_at is not null
        and rejected_at is null
        and rejected_reason is null
        and created_transaction_id is not null
      )
      or (
        status = 'rejected'
        and approved_at is null
        and rejected_at is not null
        and created_transaction_id is null
      )
    )
);

create unique index if not exists home_external_transaction_requests_idempotency_unique
  on public.home_external_transaction_requests (idempotency_key);

create unique index if not exists home_external_transaction_requests_source_event_unique
  on public.home_external_transaction_requests (external_source, external_event_id, request_type);

create unique index if not exists home_external_transaction_requests_reference_request_unique
  on public.home_external_transaction_requests (external_source, external_reference_type, external_reference_id, request_type);

create index if not exists home_external_transaction_requests_user_status_idx
  on public.home_external_transaction_requests (user_id, status, requested_at desc);

create index if not exists home_external_transaction_requests_account_idx
  on public.home_external_transaction_requests (account_id);

grant select on public.home_external_transaction_requests to authenticated;

alter table public.home_external_transaction_requests enable row level security;

drop policy if exists home_external_transaction_requests_user_select on public.home_external_transaction_requests;

create policy home_external_transaction_requests_user_select
  on public.home_external_transaction_requests
  for select
  to authenticated
  using (user_id = auth.uid());

comment on table public.home_external_transaction_requests is
  'Cash-owned pending external transaction requests from aozora school. Pending requests do not create Cash transactions or change balances until approved in Cash System.';

comment on column public.home_external_transaction_requests.request_type is
  'External school event type used when approval calls home_create_external_jpy_transaction.';

comment on column public.home_external_transaction_requests.created_transaction_id is
  'JPY transaction created only after Cash-side approval. Null for pending and rejected requests.';

create or replace function public.home_get_external_transaction_requests(
  p_status text default null,
  p_limit integer default 100
)
returns jsonb
language sql
security invoker
set search_path = public
as $$
  with normalized as (
    select
      nullif(lower(trim(coalesce(p_status, ''))), '') as status_filter,
      greatest(1, least(coalesce(p_limit, 100), 200)) as row_limit
  )
  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', r.id,
        'external_source', r.external_source,
        'external_event_id', r.external_event_id,
        'external_reference_type', r.external_reference_type,
        'external_reference_id', r.external_reference_id,
        'request_type', r.request_type,
        'transaction_type', r.transaction_type,
        'currency', r.currency,
        'amount', r.amount,
        'account_id', r.account_id,
        'account_name', a.name,
        'transacted_at', r.transacted_at,
        'status', r.status,
        'requested_at', r.requested_at,
        'approved_at', r.approved_at,
        'rejected_at', r.rejected_at,
        'rejected_reason', r.rejected_reason,
        'created_transaction_id', r.created_transaction_id,
        'idempotency_key', r.idempotency_key,
        'description', r.description,
        'note', r.note,
        'payload_snapshot', r.payload_snapshot
      )
      order by
        case r.status when 'pending' then 0 when 'rejected' then 1 else 2 end,
        r.requested_at desc
    ),
    '[]'::jsonb
  )
  from normalized n
  join lateral (
    select *
    from public.home_external_transaction_requests
    where user_id = auth.uid()
      and (n.status_filter is null or status = n.status_filter)
    order by
      case status when 'pending' then 0 when 'rejected' then 1 else 2 end,
      requested_at desc
    limit n.row_limit
  ) r on true
  left join public.home_accounts a
    on a.id = r.account_id
   and a.user_id = auth.uid();
$$;

comment on function public.home_get_external_transaction_requests(text, integer) is
  'Reads current user external transaction requests for the Cash approval UI.';

grant execute on function public.home_get_external_transaction_requests(text, integer) to authenticated;

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
  p_payload_snapshot jsonb default '{}'::jsonb
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
  elsif v_request_type = 'tuition_income_received' then
    if v_external_reference_type <> 'school_income_records' or v_transaction_type <> 'income' then
      return jsonb_build_object('ok', false, 'message', 'tuition_income_received must reference school_income_records and create income');
    end if;
  else
    return jsonb_build_object('ok', false, 'message', 'unsupported request_type');
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

  v_payload_snapshot := case
    when p_payload_snapshot is null or p_payload_snapshot = '{}'::jsonb then
      jsonb_build_object(
        'external_source', v_external_source,
        'external_event_id', p_external_event_id,
        'external_reference_type', v_external_reference_type,
        'external_reference_id', p_external_reference_id,
        'request_type', v_request_type,
        'transaction_type', v_transaction_type,
        'currency', 'JPY',
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
      or v_existing.currency is distinct from 'JPY'
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
    'JPY',
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
        or v_existing.currency is distinct from 'JPY'
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
  jsonb
) is
  'Creates an idempotent pending external transaction request. Does not create Cash transactions or change balances.';

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
  jsonb
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
    'transaction_id', v_transaction_id,
    'transaction_inserted', coalesce((v_transaction_result->>'inserted')::boolean, false),
    'message', 'external transaction request approved'
  );
end;
$$;

comment on function public.home_approve_external_transaction_request(uuid) is
  'Approves one pending external transaction request and then creates/reuses the idempotent JPY transaction.';

grant execute on function public.home_approve_external_transaction_request(uuid) to authenticated, service_role;

create or replace function public.home_reject_external_transaction_request(
  p_request_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
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
    return jsonb_build_object('ok', false, 'message', 'only pending requests can be rejected', 'status', v_request.status);
  end if;

  update public.home_external_transaction_requests
  set
    status = 'rejected',
    rejected_at = now(),
    rejected_reason = v_reason,
    updated_at = now()
  where id = v_request.id;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_request.id,
    'status', 'rejected',
    'message', 'external transaction request rejected'
  );
end;
$$;

comment on function public.home_reject_external_transaction_request(uuid, text) is
  'Rejects one pending external transaction request. Does not create Cash transactions or change balances.';

grant execute on function public.home_reject_external_transaction_request(uuid, text) to authenticated, service_role;
