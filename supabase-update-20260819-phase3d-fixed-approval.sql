-- Phase 3D home/Cash fixed approval, projection and one-time fixed-item chain.
-- Status: production deployed 2026-08-19; fixed route remains disabled.
-- Production precondition: both fixed routes remain closed and no fixed route
-- business rows exist. This file never enables a route and creates no business
-- row by itself.

lock table public.home_external_transaction_requests,
  public.home_external_fixed_payment_projections,
  public.home_fixed_month_items,
  public.home_card_statement_cycles,
  public.home_card_instruments,
  public.home_fixed_advance_payments in access exclusive mode;

do $phase3d_precheck$
begin
  if exists (select 1 from public.home_external_transaction_requests where payment_route = 'fixed_credit_card') then
    raise exception using errcode = '55000', message = 'PHASE3D_FIXED_REQUEST_PREEXISTS';
  end if;
  if exists (select 1 from public.home_external_fixed_payment_projections) then
    raise exception using errcode = '55000', message = 'PHASE3D_FIXED_PROJECTION_PREEXISTS';
  end if;
  if exists (select 1 from public.home_card_statement_cycles) then
    raise exception using errcode = '55000', message = 'PHASE3D_CARD_CYCLE_PREEXISTS';
  end if;
  if exists (select 1 from public.home_fixed_month_items where accounting_scope = 'school') then
    raise exception using errcode = '55000', message = 'PHASE3D_SCHOOL_FIXED_ITEM_PREEXISTS';
  end if;
  if exists (select 1 from public.home_card_instruments where is_school_fixed_route_enabled) then
    raise exception using errcode = '55000', message = 'PHASE3D_CARD_ROUTE_ALREADY_ENABLED';
  end if;
end;
$phase3d_precheck$;

create unique index if not exists home_external_requests_fixed_projection_unique
  on public.home_external_transaction_requests(fixed_projection_id)
  where fixed_projection_id is not null;

create or replace function public.home_lock_card_fixed_month(
  p_card_instrument_id uuid,
  p_target_fixed_month date
)
returns void
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
begin
  if p_card_instrument_id is null
     or p_target_fixed_month is null
     or p_target_fixed_month <> date_trunc('month', p_target_fixed_month)::date then
    raise exception using errcode = '22023', message = 'HOME_CARD_FIXED_MONTH_LOCK_KEY_INVALID';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtextextended(
      p_card_instrument_id::text || '|' || p_target_fixed_month::text,
      74368019
    )
  );
end;
$function$;

create or replace function public.home_guard_projection_linked_fixed_item()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
begin
  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = old.id
  ) then
    raise exception using
      errcode = '42501',
      message = case tg_op
        when 'DELETE' then 'HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN'
        else 'HOME_PROJECTION_FIXED_ITEM_UPDATE_FORBIDDEN'
      end;
  end if;
  return case when tg_op = 'DELETE' then old else new end;
end;
$function$;

drop trigger if exists home_fixed_month_items_projection_guard
  on public.home_fixed_month_items;
create trigger home_fixed_month_items_projection_guard
before update or delete on public.home_fixed_month_items
for each row execute function public.home_guard_projection_linked_fixed_item();

create or replace function public.home_build_external_fixed_approval_evidence(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_projection public.home_external_fixed_payment_projections%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_schedule record;
  v_business_month date;
begin
  select * into v_request
  from public.home_external_transaction_requests r
  where r.id = p_request_id;

  if not found or v_request.status <> 'approved'
     or v_request.payment_route <> 'fixed_credit_card'
     or v_request.fixed_projection_id is null
     or v_request.projection_status <> 'projected'
     or v_request.created_transaction_id is not null
     or v_request.account_id is not null
     or v_request.funding_account_id is not null
     or v_request.approved_at is null then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_REQUEST_INVALID';
  end if;

  select * into v_projection
  from public.home_external_fixed_payment_projections p
  where p.id = v_request.fixed_projection_id
    and p.external_request_id = v_request.id;

  if not found
     or v_projection.user_id is distinct from v_request.user_id
     or v_projection.external_source is distinct from v_request.external_source
     or v_projection.external_reference_type is distinct from v_request.external_reference_type
     or v_projection.external_reference_id is distinct from v_request.external_reference_id
     or v_projection.external_event_id is distinct from v_request.external_event_id
     or v_projection.external_idempotency_key is distinct from v_request.idempotency_key
     or v_projection.school_expense_id is distinct from v_request.external_reference_id
     or v_projection.payment_route <> 'fixed_credit_card'
     or v_projection.card_instrument_id is distinct from v_request.card_instrument_id
     or v_projection.charge_date is distinct from v_request.charge_date
     or v_projection.suggested_fixed_month is distinct from v_request.suggested_fixed_month
     or v_projection.target_fixed_month is distinct from v_request.target_fixed_month
     or v_projection.original_amount is distinct from v_request.amount
     or v_projection.original_currency is distinct from v_request.currency
     or v_projection.settlement_amount is distinct from v_request.amount
     or v_projection.settlement_currency is distinct from v_request.currency
     or v_projection.settlement_amount_status <> 'confirmed'
     or v_projection.projection_status <> 'projected'
     or v_projection.funding_status <> 'unfunded'
     or v_projection.funding_account_id is not null
     or v_projection.funding_transaction_id is not null
     or v_projection.funded_at is not null
     or v_projection.fixed_month_override_reason is not null
     or v_projection.fixed_month_override_actor is not null
     or v_projection.fixed_month_overridden_at is not null
     or v_projection.supersedes_projection_id is not null
     or v_projection.version <> 1 then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_PROJECTION_INVALID';
  end if;

  select * into v_item
  from public.home_fixed_month_items i
  where i.id = v_projection.fixed_month_item_id;

  if not found
     or v_item.user_id is distinct from v_request.user_id
     or v_item.template_id is not null
     or v_item.accounting_scope <> 'school'
     or v_item.currency <> 'JPY'
     or v_item.direction <> 'expense'
     or v_item.amount is distinct from v_request.amount
     or v_item.month_key is distinct from to_char(v_request.target_fixed_month, 'YYYY-MM')
     or v_item.due_date is distinct from v_projection.funding_date
     or v_item.status <> 'unpaid'
     or v_item.account_id is not null
     or v_item.linked_jpy_transaction_id is not null
     or v_item.linked_cny_transaction_id is not null
     or nullif(btrim(v_item.name), '') is null then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_ITEM_INVALID';
  end if;

  select * into v_card
  from public.home_card_instruments c
  where c.id = v_request.card_instrument_id;
  select * into v_channel
  from public.home_payment_channels c
  where c.id = v_projection.funding_payment_channel_id;
  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_request.card_instrument_id, v_request.charge_date);

  if v_card.id is null
     or v_card.user_id is distinct from v_request.user_id
     or v_card.settlement_currency <> 'JPY'
     or v_channel.id is null
     or v_channel.user_id is distinct from v_request.user_id
     or v_channel.currency <> 'JPY'
     or v_projection.funding_payment_channel_id is distinct from v_card.funding_payment_channel_id
     or v_item.payment_group is distinct from v_channel.name
     or v_request.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_request.target_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_projection.funding_date is distinct from v_schedule.funding_date then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_CARD_OR_SCHEDULE_INVALID';
  end if;

  begin
    if coalesce(v_request.payload_snapshot ->> 'year_month', '') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception using errcode = '22007', message = 'invalid year_month';
    end if;
    v_business_month := to_date(v_request.payload_snapshot ->> 'year_month' || '-01', 'YYYY-MM-DD');
  exception when others then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_BUSINESS_MONTH_INVALID';
  end;
  if v_projection.business_month is distinct from v_business_month then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_BUSINESS_MONTH_MISMATCH';
  end if;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_request.id,
    'user_id', v_request.user_id,
    'request_status', v_request.status,
    'payment_route', v_request.payment_route,
    'external_source', v_request.external_source,
    'external_event_id', v_request.external_event_id,
    'external_reference_type', v_request.external_reference_type,
    'external_reference_id', v_request.external_reference_id,
    'request_type', v_request.request_type,
    'transaction_type', v_request.transaction_type,
    'idempotency_key', v_request.idempotency_key,
    'request_payload_fingerprint', v_request.payload_snapshot ->> 'school_attempt_payload_fingerprint',
    'card_instrument_id', v_request.card_instrument_id,
    'charge_date', v_request.charge_date,
    'suggested_fixed_month', v_request.suggested_fixed_month,
    'target_fixed_month', v_request.target_fixed_month,
    'funding_date', v_projection.funding_date,
    'business_month', v_projection.business_month,
    'original_amount', v_projection.original_amount,
    'original_currency', v_projection.original_currency,
    'settlement_amount', v_projection.settlement_amount,
    'settlement_currency', v_projection.settlement_currency,
    'created_transaction_id', v_request.created_transaction_id,
    'fixed_projection_id', v_projection.id,
    'projection_status', v_projection.projection_status,
    'projection_version', v_projection.version,
    'funding_payment_channel_id', v_projection.funding_payment_channel_id,
    'funding_account_id', v_projection.funding_account_id,
    'funding_status', v_projection.funding_status,
    'funding_transaction_id', v_projection.funding_transaction_id,
    'fixed_item_id', v_item.id,
    'fixed_item_template_id', v_item.template_id,
    'fixed_item_scope', v_item.accounting_scope,
    'fixed_item_currency', v_item.currency,
    'fixed_item_direction', v_item.direction,
    'fixed_item_name', v_item.name,
    'fixed_item_amount', v_item.amount,
    'fixed_item_month_key', v_item.month_key,
    'fixed_item_due_date', v_item.due_date,
    'fixed_item_payment_group', v_item.payment_group,
    'fixed_item_status', v_item.status,
    'fixed_item_account_id', v_item.account_id,
    'fixed_item_linked_jpy_transaction_id', v_item.linked_jpy_transaction_id,
    'fixed_item_linked_cny_transaction_id', v_item.linked_cny_transaction_id,
    'approved_by', v_request.user_id,
    'approved_at', v_request.approved_at
  );
end;
$function$;

create or replace function public.home_apply_external_fixed_transaction_approval(
  p_request_id uuid,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_cycle public.home_card_statement_cycles%rowtype;
  v_projection public.home_external_fixed_payment_projections%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_advance public.home_fixed_advance_payments%rowtype;
  v_schedule record;
  v_business_month date;
  v_projection_id uuid := gen_random_uuid();
  v_item_id uuid := gen_random_uuid();
  v_now timestamptz := statement_timestamp();
  v_evidence jsonb;
begin
  if p_request_id is null or p_actor_id is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_REQUIRED_INPUT', 'message', 'request and actor are required');
  end if;

  select * into v_request
  from public.home_external_transaction_requests r
  where r.id = p_request_id
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_REQUEST_NOT_FOUND', 'message', 'fixed request not found');
  end if;
  if v_request.user_id is distinct from p_actor_id then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_OWNER_MISMATCH', 'message', 'authenticated user does not own the fixed request');
  end if;
  if v_request.payment_route <> 'fixed_credit_card' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_WRONG_ROUTE', 'message', 'request is not a fixed credit-card request');
  end if;
  if v_request.status = 'rejected' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ALREADY_REJECTED', 'message', 'rejected fixed request cannot be approved');
  end if;

  select * into v_card
  from public.home_card_instruments c
  where c.id = v_request.card_instrument_id
  for share;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CARD_INVALID', 'message', 'fixed card does not exist');
  end if;

  perform public.home_lock_card_fixed_month(v_card.id, v_request.target_fixed_month);

  select * into v_cycle
  from public.home_card_statement_cycles c
  where c.card_instrument_id = v_card.id
    and c.target_fixed_month = v_request.target_fixed_month
  for update;

  if v_request.fixed_projection_id is not null then
    select * into v_projection
    from public.home_external_fixed_payment_projections p
    where p.id = v_request.fixed_projection_id
    for update;
    if found then
      select * into v_item
      from public.home_fixed_month_items i
      where i.id = v_projection.fixed_month_item_id
      for update;
    end if;
  end if;

  select * into v_advance
  from public.home_fixed_advance_payments a
  where a.user_id = v_request.user_id
    and a.month_key = to_char(v_request.target_fixed_month, 'YYYY-MM')
    and a.currency = v_request.currency
    and a.payment_group = (
      select c.name from public.home_payment_channels c
      where c.id = v_card.funding_payment_channel_id
    )
  for update;

  if v_request.status = 'approved' then
    begin
      v_evidence := public.home_build_external_fixed_approval_evidence(v_request.id);
    exception when others then
      raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_IDEMPOTENCY_INTEGRITY_ERROR', detail = sqlerrm;
    end;
    return v_evidence || jsonb_build_object('inserted', false, 'idempotent', true, 'message', 'fixed request approval already exists');
  end if;
  if v_request.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_STATUS_INVALID', 'message', 'only pending fixed requests can be approved');
  end if;
  if v_request.account_id is not null or v_request.funding_account_id is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ACCOUNT_UNEXPECTED', 'message', 'fixed request must not contain an account or funding account');
  end if;
  if v_request.created_transaction_id is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ORDINARY_TRANSACTION_EXISTS', 'message', 'fixed request unexpectedly contains an ordinary transaction');
  end if;
  if v_request.fixed_projection_id is not null or v_request.projection_status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_PROJECTION_CONFLICT', 'message', 'pending fixed request already contains projection evidence');
  end if;
  if v_card.user_id is distinct from v_request.user_id
     or v_card.settlement_currency is distinct from v_request.currency
     or v_card.is_active is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CARD_INVALID', 'message', 'fixed card is inactive, wrong owner, or wrong currency');
  end if;
  if v_card.is_school_fixed_route_enabled is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_CARD_ROUTE_DISABLED', 'message', 'School fixed credit-card route is disabled');
  end if;
  if v_request.transaction_type <> 'expense'
     or v_request.external_source <> 'aozora_school'
     or v_request.external_reference_type <> 'school_expense_records'
     or v_request.request_type <> 'expense_paid'
     or v_request.accounting_scope <> 'school'
     or v_request.currency <> 'JPY'
     or v_request.amount <= 0
     or v_request.charge_date is null
     or v_request.target_fixed_month is distinct from v_request.suggested_fixed_month
     or v_request.fixed_month_override_reason is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_REQUEST_CONTRACT_INVALID', 'message', 'fixed request route, identity, amount, currency, or target contract is invalid');
  end if;

  select * into v_channel
  from public.home_payment_channels c
  where c.id = v_card.funding_payment_channel_id
  for key share;
  if not found
     or v_channel.user_id is distinct from v_request.user_id
     or v_channel.currency <> 'JPY'
     or v_channel.is_active is not true
     or nullif(btrim(v_channel.name), '') is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CHANNEL_INVALID', 'message', 'card funding channel is invalid');
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_card.id, v_request.charge_date);
  if v_request.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_request.target_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_request.payload_snapshot ->> 'funding_date' is distinct from v_schedule.funding_date::text
     or v_request.payload_snapshot ->> 'card_instrument_id' is distinct from v_card.id::text
     or v_request.payload_snapshot ->> 'charge_date' is distinct from v_request.charge_date::text
     or v_request.payload_snapshot ->> 'suggested_fixed_month' is distinct from v_request.suggested_fixed_month::text
     or v_request.payload_snapshot ->> 'target_fixed_month' is distinct from v_request.target_fixed_month::text then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_SCHEDULE_MISMATCH', 'message', 'fixed request schedule does not match current Cash DB authority');
  end if;
  if found and v_cycle.amount_status = 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_STATEMENT_CONFIRMED', 'message', 'statement cycle is already confirmed');
  end if;
  if v_advance.id is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_GROUP_ALREADY_FUNDED', 'message', 'target month and payment group already has an advance/funding record');
  end if;

  if exists (
    select 1 from public.home_external_fixed_payment_projections p
    where p.external_request_id = v_request.id
       or p.external_event_id = v_request.external_event_id
       or p.external_idempotency_key = v_request.idempotency_key
       or p.school_expense_id = v_request.external_reference_id
  ) then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_PROJECTION_CONFLICT', 'message', 'conflicting fixed projection already exists');
  end if;

  begin
    if coalesce(v_request.payload_snapshot ->> 'year_month', '') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception using errcode = '22007', message = 'invalid year_month';
    end if;
    v_business_month := to_date(v_request.payload_snapshot ->> 'year_month' || '-01', 'YYYY-MM-DD');
  exception when others then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_BUSINESS_MONTH_INVALID', 'message', 'School expense business month is missing or invalid');
  end;
  if nullif(btrim(v_request.description), '') is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ITEM_NAME_INVALID', 'message', 'School expense display name is missing');
  end if;

  insert into public.home_fixed_month_items(
    id, user_id, template_id, month_key, currency, direction, name, amount,
    status, account_id, payment_group, due_date, term_no, total_terms, note,
    linked_jpy_transaction_id, linked_cny_transaction_id, accounting_scope
  ) values (
    v_item_id, v_request.user_id, null, to_char(v_request.target_fixed_month, 'YYYY-MM'),
    'JPY', 'expense', v_request.description, v_request.amount, 'unpaid', null,
    v_channel.name, v_schedule.funding_date, null, null, v_request.note,
    null, null, 'school'
  );

  insert into public.home_external_fixed_payment_projections(
    id, user_id, external_request_id, external_source,
    external_reference_type, external_reference_id, external_event_id,
    external_idempotency_key, school_expense_id, payment_route,
    card_instrument_id, funding_payment_channel_id, funding_account_id,
    business_month, charge_date, suggested_fixed_month, target_fixed_month,
    funding_date, original_amount, original_currency, settlement_amount,
    settlement_currency, settlement_amount_status, fixed_month_item_id,
    projection_status, funding_status, funding_transaction_id,
    supersedes_projection_id, fixed_month_override_reason,
    fixed_month_override_actor, fixed_month_overridden_at, created_at,
    approved_at, funded_at, updated_at, version
  ) values (
    v_projection_id, v_request.user_id, v_request.id, v_request.external_source,
    v_request.external_reference_type, v_request.external_reference_id,
    v_request.external_event_id, v_request.idempotency_key,
    v_request.external_reference_id, 'fixed_credit_card', v_card.id,
    v_channel.id, null, v_business_month, v_request.charge_date,
    v_request.suggested_fixed_month, v_request.target_fixed_month,
    v_schedule.funding_date, v_request.amount, v_request.currency,
    v_request.amount, v_request.currency, 'confirmed', v_item_id,
    'projected', 'unfunded', null, null, null, null, null,
    v_now, v_now, null, v_now, 1
  );

  update public.home_external_transaction_requests r
  set status = 'approved', approved_at = v_now,
      fixed_projection_id = v_projection_id,
      projection_status = 'projected', updated_at = v_now
  where r.id = v_request.id;

  v_evidence := public.home_build_external_fixed_approval_evidence(v_request.id);
  return v_evidence || jsonb_build_object('inserted', true, 'idempotent', false, 'message', 'fixed request approved and projected');
exception
  when unique_violation then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_IDENTITY_CONFLICT', detail = sqlerrm;
end;
$function$;

create or replace function public.home_approve_external_fixed_transaction_request(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_actor uuid := auth.uid();
begin
  if v_actor is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_AUTH_REQUIRED', 'message', 'authenticated user is required');
  end if;
  return public.home_apply_external_fixed_transaction_approval(p_request_id, v_actor);
end;
$function$;

create or replace function public.home_get_external_fixed_approval_evidence(
  p_request_id uuid
)
returns jsonb
language sql
security definer
set search_path = pg_catalog, public
as $function$
  select public.home_build_external_fixed_approval_evidence(p_request_id);
$function$;

alter function public.home_lock_card_fixed_month(uuid,date) owner to postgres;
alter function public.home_guard_projection_linked_fixed_item() owner to postgres;
alter function public.home_build_external_fixed_approval_evidence(uuid) owner to postgres;
alter function public.home_apply_external_fixed_transaction_approval(uuid,uuid) owner to postgres;
alter function public.home_approve_external_fixed_transaction_request(uuid) owner to postgres;
alter function public.home_get_external_fixed_approval_evidence(uuid) owner to postgres;

revoke all on function public.home_lock_card_fixed_month(uuid,date) from public, anon, authenticated, service_role;
revoke all on function public.home_guard_projection_linked_fixed_item() from public, anon, authenticated, service_role;
revoke all on function public.home_build_external_fixed_approval_evidence(uuid) from public, anon, authenticated, service_role;
revoke all on function public.home_apply_external_fixed_transaction_approval(uuid,uuid) from public, anon, authenticated, service_role;
revoke all on function public.home_approve_external_fixed_transaction_request(uuid) from public, anon, authenticated, service_role;
grant execute on function public.home_approve_external_fixed_transaction_request(uuid) to authenticated;
revoke all on function public.home_get_external_fixed_approval_evidence(uuid) from public, anon, authenticated, service_role;
grant execute on function public.home_get_external_fixed_approval_evidence(uuid) to service_role;

comment on function public.home_lock_card_fixed_month(uuid,date) is
  'Phase 3D owner-only shared card/month transaction advisory lock. Every future statement confirm/reopen writer must call this same helper after locking the card row.';
comment on function public.home_approve_external_fixed_transaction_request(uuid) is
  'Phase 3D authenticated fixed approval wrapper. Creates one projection and one one-time School fixed item atomically; creates no ordinary transaction and changes no account balance.';
comment on function public.home_get_external_fixed_approval_evidence(uuid) is
  'Phase 3D service-only canonical approved-fixed evidence reader for sync-cash-request-result.';

-- Existing generic fixed-item writers must reject projection-linked items
-- before any side effect. The row trigger above remains the final defense for
-- direct table DML and any writer missed by a future code path.
create or replace function public.home_create_fixed_advance_payment(
  p_month_key text,
  p_currency text,
  p_payment_group text,
  p_account_id uuid,
  p_transacted_at date,
  p_note text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_group text := coalesce(nullif(trim(p_payment_group), ''), '未分组');
  v_amount numeric := 0;
  v_transaction_id uuid := gen_random_uuid();
  v_advance_id uuid := gen_random_uuid();
  v_item_count integer := 0;
begin
  if p_currency <> 'JPY' then
    return jsonb_build_object('ok', false, 'message', '固定垫付目前只支持日元。');
  end if;
  if to_char(p_transacted_at, 'YYYY-MM') <> p_month_key then
    return jsonb_build_object('ok', false, 'message', '垫付日期必须在当前账期内。');
  end if;
  if not exists (
    select 1 from public.home_accounts
    where id = p_account_id and user_id = auth.uid()
      and currency = p_currency and is_active
  ) then
    return jsonb_build_object('ok', false, 'message', '没有找到可使用的日元垫付账户。');
  end if;
  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    join public.home_fixed_month_items i on i.id = p.fixed_month_item_id
    where i.user_id = auth.uid() and i.month_key = p_month_key
      and i.currency = p_currency and i.direction = 'expense'
      and coalesce(i.payment_group, '未分组') = v_group
  ) then
    return jsonb_build_object('ok', false, 'code', 'HOME_PROJECTION_FIXED_ITEM_ADVANCE_FORBIDDEN', 'message', '该支付分组包含School信用卡projection固定项，Phase 3F前不能垫付。');
  end if;
  if exists (
    select 1 from public.home_fixed_advance_payments
    where user_id = auth.uid() and month_key = p_month_key
      and currency = p_currency and payment_group = v_group
  ) then
    return jsonb_build_object('ok', false, 'message', '本账期该支付分组已经生成过垫付记录。');
  end if;

  select count(*), public.home_round_up_1000(coalesce(sum(amount), 0))
  into v_item_count, v_amount
  from public.home_fixed_month_items
  where user_id = auth.uid() and month_key = p_month_key
    and currency = p_currency and direction = 'expense'
    and linked_jpy_transaction_id is null
    and coalesce(payment_group, '未分组') = v_group;
  if v_item_count <= 0 or v_amount <= 0 then
    return jsonb_build_object('ok', false, 'message', '该支付分组没有可垫付的固定支出。');
  end if;

  insert into public.home_jpy_transactions(
    id,user_id,transaction_type,account_id,transfer_account_id,currency,
    transacted_at,amount,description,note,created_at
  ) values (
    v_transaction_id,auth.uid(),'fixed_advance_out',p_account_id,null,p_currency,
    p_transacted_at,v_amount,format('%s 固定支出垫付',v_group),coalesce(p_note,''),now()
  );
  insert into public.home_fixed_advance_payments(
    id,user_id,month_key,currency,payment_group,account_id,amount,status,
    paid_at,out_transaction_id,note,created_at
  ) values (
    v_advance_id,auth.uid(),p_month_key,p_currency,v_group,p_account_id,v_amount,
    'pending',p_transacted_at,v_transaction_id,coalesce(p_note,''),now()
  );
  update public.home_fixed_month_items
  set status = 'paid'
  where user_id = auth.uid() and month_key = p_month_key
    and currency = p_currency and direction = 'expense'
    and linked_jpy_transaction_id is null
    and coalesce(payment_group, '未分组') = v_group;

  return jsonb_build_object(
    'ok',true,'message',format('%s 固定支出已垫付，金额 %s。',v_group,v_amount),
    'advance_id',v_advance_id,'jpy_transaction_id',v_transaction_id,
    'amount',v_amount,'item_count',v_item_count
  );
end;
$function$;

create or replace function public.home_update_fixed_month_item_status(
  p_item_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_item public.home_fixed_month_items%rowtype;
  v_check jsonb;
begin
  if p_status not in ('unpaid','paid','settled') then
    return jsonb_build_object('ok',false,'message','固定项状态无效。');
  end if;
  select * into v_item from public.home_fixed_month_items
  where id=p_item_id and user_id=auth.uid();
  if not found then
    return jsonb_build_object('ok',false,'message','没有找到可更新的固定项。');
  end if;
  if exists (select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=v_item.id) then
    return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN','message','School信用卡projection固定项不能使用普通状态writer。');
  end if;
  if v_item.linked_jpy_transaction_id is not null then
    return jsonb_build_object('ok',false,'message','调拨记录状态固定为已付。');
  end if;
  if v_item.direction='expense' and exists (
    select 1 from public.home_fixed_advance_payments ap
    where ap.user_id=auth.uid() and ap.month_key=v_item.month_key
      and ap.currency=v_item.currency
      and ap.payment_group=coalesce(v_item.payment_group,'未分组')
  ) then
    return jsonb_build_object('ok',false,'message','该固定支出分组已进入垫付流程，状态不能单独修改。');
  end if;
  if v_item.direction='expense' and p_status in ('paid','settled') then
    v_check := public.home_check_fixed_paid_balance(v_item.month_key,v_item.currency,p_item_id,p_status);
    if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if;
  end if;
  update public.home_fixed_month_items set status=p_status
  where id=p_item_id and user_id=auth.uid() and linked_jpy_transaction_id is null;
  return jsonb_build_object('ok',true,'message','固定项状态已更新。','updated_count',1);
end;
$function$;

create or replace function public.home_update_fixed_month_items_status(
  p_month_key text,
  p_currency text,
  p_direction text,
  p_status text
)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_updated_count integer := 0;
  v_check jsonb;
begin
  if p_direction not in ('income','expense') then
    return jsonb_build_object('ok',false,'message','固定项收支方向无效。');
  end if;
  if p_status not in ('unpaid','paid','settled') then
    return jsonb_build_object('ok',false,'message','固定项状态无效。');
  end if;
  if exists (
    select 1 from public.home_external_fixed_payment_projections p
    join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
    where i.user_id=auth.uid() and i.month_key=p_month_key
      and i.currency=p_currency and i.direction=p_direction
  ) then
    return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含School信用卡projection固定项，不能使用批量状态writer。');
  end if;
  if p_direction='expense' and p_status in ('paid','settled') then
    v_check := public.home_check_fixed_paid_balance(p_month_key,p_currency,null,null,p_direction,p_status);
    if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if;
  end if;
  update public.home_fixed_month_items i set status=p_status
  where i.user_id=auth.uid() and i.month_key=p_month_key
    and i.currency=p_currency and i.direction=p_direction
    and i.linked_jpy_transaction_id is null
    and not (p_direction='expense' and exists (
      select 1 from public.home_fixed_advance_payments ap
      where ap.user_id=auth.uid() and ap.month_key=i.month_key
        and ap.currency=i.currency
        and ap.payment_group=coalesce(i.payment_group,'未分组')
    ));
  get diagnostics v_updated_count = row_count;
  return jsonb_build_object('ok',true,'message','固定项状态已批量更新。','updated_count',v_updated_count);
end;
$function$;

create or replace function public.home_delete_fixed_month_item(p_item_id uuid)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_item public.home_fixed_month_items%rowtype;
  v_linked_jpy_transaction_id uuid;
  v_deleted_count integer := 0;
  v_linked_deleted boolean := false;
  v_reset jsonb := jsonb_build_object('reset_expense_status',false);
  v_message text := '已删除。';
begin
  select * into v_item from public.home_fixed_month_items
  where id=p_item_id and user_id=auth.uid();
  if not found then
    return jsonb_build_object('ok',false,'message','没有找到可删除的固定项。');
  end if;
  if exists (select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=v_item.id) then
    return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN','message','School信用卡projection固定项不能使用普通删除writer。');
  end if;
  if v_item.direction='expense' and exists (
    select 1 from public.home_fixed_advance_payments ap
    where ap.user_id=auth.uid() and ap.month_key=v_item.month_key
      and ap.currency=v_item.currency
      and ap.payment_group=coalesce(v_item.payment_group,'未分组')
  ) then
    return jsonb_build_object('ok',false,'message','该固定支出分组已进入垫付流程，不能删除单条固定项。');
  end if;
  v_linked_jpy_transaction_id := public.home_resolve_fixed_transfer_jpy_id(v_item);
  if v_linked_jpy_transaction_id is not null then
    delete from public.home_jpy_transactions
    where id=v_linked_jpy_transaction_id and user_id=auth.uid();
    get diagnostics v_deleted_count = row_count;
    v_linked_deleted := v_deleted_count>0;
    if not v_linked_deleted then v_message := '已删除固定项，但链接的日元流水不存在。'; end if;
  elsif v_item.name in ('固定赤字补充','固定盈余转入') and v_item.template_id is null then
    v_message := '已删除固定项，但旧数据链接不完整，未能唯一匹配日元流水。';
  end if;
  delete from public.home_fixed_month_items where id=v_item.id and user_id=auth.uid();
  v_reset := public.home_reset_plain_fixed_expenses_if_deficit(v_item.month_key,v_item.currency);
  return jsonb_build_object(
    'ok',true,'deleted_count',1,'linked_deleted',v_linked_deleted,
    'reset_expense_status',coalesce((v_reset->>'reset_expense_status')::boolean,false),
    'message',case
      when v_linked_deleted and coalesce((v_reset->>'reset_expense_status')::boolean,false) then '已同步删除日元流水；删除后重新出现赤字，普通固定支出已改回未付。'
      when v_linked_deleted then '已同步删除日元流水。'
      when coalesce((v_reset->>'reset_expense_status')::boolean,false) then v_message||' 删除后重新出现赤字，普通固定支出已改回未付。'
      else v_message end
  );
end;
$function$;

create or replace function public.home_sync_fixed_month_items(
  p_month_key text,
  p_currency text default 'JPY'
)
returns jsonb
language plpgsql
security invoker
set search_path = pg_catalog, public
as $function$
declare
  v_updated_count integer := 0;
begin
  if exists (
    select 1 from public.home_external_fixed_payment_projections p
    join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
    where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency
  ) then
    return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_SYNC_FORBIDDEN','message','范围内包含School信用卡projection固定项，不能使用普通月份/模板同步writer。');
  end if;
  with month_context as (
    select extract(year from month_start)::int as year_no,
      extract(month from month_start)::int as month_no,
      extract(day from (month_start+interval '1 month - 1 day'))::int as days_in_month
    from (select to_date(p_month_key||'-01','YYYY-MM-DD') as month_start) d
  ), updated_items as (
    update public.home_fixed_month_items i set
      direction=t.direction,name=t.name,amount=t.default_amount,
      account_id=t.default_account_id,payment_group=t.payment_group,
      due_date=case when t.due_day is null then null else make_date(c.year_no,c.month_no,least(t.due_day,c.days_in_month)) end,
      term_no=case when t.fixed_type='short_term' and t.start_month is not null and t.total_terms is not null then
        ((substring(p_month_key,1,4)::int-substring(t.start_month,1,4)::int)*12
        +(substring(p_month_key,6,2)::int-substring(t.start_month,6,2)::int)+1) else null end,
      total_terms=case when t.fixed_type='short_term' then t.total_terms else null end
    from public.home_fixed_templates t cross join month_context c
    where i.template_id=t.id and i.user_id=auth.uid() and t.user_id=auth.uid()
      and i.month_key=p_month_key and i.currency=p_currency and t.currency=p_currency
    returning i.id
  ) select count(*) into v_updated_count from updated_items;
  return jsonb_build_object('updated_count',v_updated_count);
end;
$function$;

alter function public.home_create_fixed_advance_payment(text,text,text,uuid,date,text) owner to postgres;
alter function public.home_update_fixed_month_item_status(uuid,text) owner to postgres;
alter function public.home_update_fixed_month_items_status(text,text,text,text) owner to postgres;
alter function public.home_delete_fixed_month_item(uuid) owner to postgres;
alter function public.home_sync_fixed_month_items(text,text) owner to postgres;

-- CREATE OR REPLACE preserves each legacy writer's existing EXECUTE ACL. Do
-- not widen or narrow those unrelated compatibility permissions in Phase 3D.
