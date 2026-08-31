-- Phase 3C3-B home/Cash fixed request entry foundation.
-- Status: draft only / not executed.
-- Scope: schema constraints, service-only schedule wrapper and fixed request
-- writer, fixed rejection compatibility, and a fail-closed generic approve guard.
-- This migration creates no production request, projection, item, cycle, or
-- transaction and never enables a card route.

lock table public.home_external_transaction_requests,
  public.home_external_fixed_payment_projections,
  public.home_card_statement_cycles,
  public.home_card_instruments in access exclusive mode;

do $phase3c3b_precheck$
begin
  if exists (
    select 1 from public.home_external_transaction_requests
    where payment_route = 'fixed_credit_card'
  ) then
    raise exception using errcode = '55000', message = 'PHASE3C3B_FIXED_REQUEST_PREEXISTS';
  end if;
  if exists (select 1 from public.home_external_fixed_payment_projections) then
    raise exception using errcode = '55000', message = 'PHASE3C3B_FIXED_PROJECTION_PREEXISTS';
  end if;
  if exists (select 1 from public.home_card_statement_cycles) then
    raise exception using errcode = '55000', message = 'PHASE3C3B_CARD_CYCLE_PREEXISTS';
  end if;
  if exists (
    select 1 from public.home_fixed_month_items
    where accounting_scope = 'school'
  ) then
    raise exception using errcode = '55000', message = 'PHASE3C3B_SCHOOL_FIXED_ITEM_PREEXISTS';
  end if;
  if exists (
    select 1 from public.home_card_instruments
    where is_school_fixed_route_enabled
  ) then
    raise exception using errcode = '55000', message = 'PHASE3C3B_CARD_ROUTE_ALREADY_ENABLED';
  end if;
end;
$phase3c3b_precheck$;

-- A fixed request identifies the future card charge, not a funding account.
-- Keep immediate-account rows on the existing non-null account contract.
alter table public.home_external_transaction_requests
  alter column account_id drop not null,
  drop constraint home_external_requests_route_fields_check,
  add constraint home_external_requests_route_fields_check check (
    (
      payment_route = 'immediate_account'
      and account_id is not null
      and card_instrument_id is null
      and charge_date is null
      and suggested_fixed_month is null
      and target_fixed_month is null
      and fixed_month_override_reason is null
      and funding_account_id is null
      and fixed_projection_id is null
      and projection_status = 'not_applicable'
    )
    or
    (
      payment_route = 'fixed_credit_card'
      and account_id is null
      and funding_account_id is null
      and card_instrument_id is not null
      and charge_date is not null
      and transacted_at = charge_date
      and suggested_fixed_month is not null
      and suggested_fixed_month = date_trunc('month', suggested_fixed_month)::date
      and target_fixed_month is not null
      and target_fixed_month = date_trunc('month', target_fixed_month)::date
      and created_transaction_id is null
      and (
        (target_fixed_month = suggested_fixed_month and fixed_month_override_reason is null)
        or
        (target_fixed_month <> suggested_fixed_month and length(btrim(fixed_month_override_reason)) > 0)
      )
    )
  );

-- Projection funding is deliberately absent until a future group-funding
-- writer assigns and validates it. Replacement direction is new -> old.
alter table public.home_external_fixed_payment_projections
  alter column funding_account_id drop not null;

alter table public.home_external_fixed_payment_projections
  rename column correction_projection_id to supersedes_projection_id;

alter table public.home_external_fixed_payment_projections
  rename constraint home_external_fixed_payment_proje_correction_projection_id_fkey
  to home_external_fixed_payment_proje_supersedes_projection_id_fkey;

alter table public.home_external_fixed_payment_projections
  drop constraint home_external_fixed_projections_funding_lifecycle_check,
  add constraint home_external_fixed_projections_funding_lifecycle_check check (
    (
      funding_status = 'unfunded'
      and funding_account_id is null
      and funding_transaction_id is null
      and funded_at is null
    )
    or
    (
      funding_status in ('funded', 'reversed')
      and funding_account_id is not null
      and funding_transaction_id is not null
      and funded_at is not null
    )
  );

drop index public.home_external_fixed_proj_source_ref_event_active_uq;
drop index public.home_external_fixed_projections_request_active_unique;
drop index public.home_external_fixed_projections_school_expense_active_unique;

create unique index home_external_fixed_proj_source_ref_event_active_uq
  on public.home_external_fixed_payment_projections(
    external_source, external_reference_type, external_reference_id, external_event_id
  ) where projection_status = 'projected';
create unique index home_external_fixed_projections_request_active_unique
  on public.home_external_fixed_payment_projections(external_request_id)
  where projection_status = 'projected';
create unique index home_external_fixed_projections_school_expense_active_unique
  on public.home_external_fixed_payment_projections(school_expense_id)
  where projection_status = 'projected';
create unique index home_external_fixed_projections_supersedes_unique
  on public.home_external_fixed_payment_projections(supersedes_projection_id)
  where supersedes_projection_id is not null;

-- Future effective card versions may reuse a display name after the old
-- version is inactive. Only one active name/currency version is allowed.
drop index public.home_card_instruments_user_currency_name_unique;
create unique index home_card_instruments_user_currency_name_active_unique
  on public.home_card_instruments(user_id, settlement_currency, name)
  where is_active;

create or replace function public.home_validate_card_instrument()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_channel public.home_payment_channels%rowtype;
  v_template public.home_fixed_templates%rowtype;
  v_is_referenced boolean := false;
begin
  select * into v_channel
  from public.home_payment_channels
  where id = new.funding_payment_channel_id;

  if not found
     or v_channel.user_id is distinct from new.user_id
     or v_channel.currency is distinct from new.settlement_currency
     or v_channel.is_active is not true then
    raise exception using errcode = '23514', message = 'CARD_INSTRUMENT_INVALID_FUNDING_CHANNEL';
  end if;

  select * into v_template
  from public.home_fixed_templates
  where id = new.household_statement_template_id;

  if not found
     or v_template.user_id is distinct from new.user_id
     or v_template.currency is distinct from new.settlement_currency
     or v_template.direction is distinct from 'expense'
     or v_template.accounting_scope is distinct from 'household'
     or v_template.is_active is not true
     or v_template.payment_group is distinct from v_channel.name then
    raise exception using errcode = '23514', message = 'CARD_INSTRUMENT_INVALID_HOUSEHOLD_TEMPLATE';
  end if;

  if tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id then
      raise exception using errcode = '42501', message = 'CARD_INSTRUMENT_USER_IMMUTABLE';
    end if;
    if new.version is distinct from old.version + 1 then
      raise exception using errcode = '40001', message = 'CARD_INSTRUMENT_VERSION_MUST_ADVANCE';
    end if;

    select exists (
      select 1 from public.home_external_transaction_requests r
      where r.card_instrument_id = old.id
      union all
      select 1 from public.home_card_statement_cycles c
      where c.card_instrument_id = old.id
      union all
      select 1 from public.home_external_fixed_payment_projections p
      where p.card_instrument_id = old.id
      limit 1
    ) into v_is_referenced;

    if v_is_referenced and row(
      new.settlement_currency, new.cutoff_day, new.cutoff_inclusive,
      new.funding_day, new.funding_payment_channel_id,
      new.household_statement_template_id
    ) is distinct from row(
      old.settlement_currency, old.cutoff_day, old.cutoff_inclusive,
      old.funding_day, old.funding_payment_channel_id,
      old.household_statement_template_id
    ) then
      raise exception using errcode = '42501', message = 'CARD_INSTRUMENT_REFERENCED_CONFIG_IMMUTABLE';
    end if;

    new.updated_at := statement_timestamp();
  end if;

  return new;
end;
$function$;

create or replace function public.home_validate_external_request_payment_route()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_schedule record;
  v_snapshot_funding_date date;
begin
  if new.payment_route = 'immediate_account' then
    return new;
  end if;

  if tg_op = 'UPDATE' and row(
    new.user_id, new.external_source, new.external_event_id,
    new.external_reference_type, new.external_reference_id,
    new.request_type, new.transaction_type, new.currency, new.amount,
    new.account_id, new.transacted_at, new.idempotency_key,
    new.payload_snapshot, new.accounting_scope, new.payment_route,
    new.card_instrument_id, new.charge_date, new.suggested_fixed_month,
    new.funding_account_id
  ) is distinct from row(
    old.user_id, old.external_source, old.external_event_id,
    old.external_reference_type, old.external_reference_id,
    old.request_type, old.transaction_type, old.currency, old.amount,
    old.account_id, old.transacted_at, old.idempotency_key,
    old.payload_snapshot, old.accounting_scope, old.payment_route,
    old.card_instrument_id, old.charge_date, old.suggested_fixed_month,
    old.funding_account_id
  ) then
    raise exception using errcode = '42501', message = 'FIXED_CARD_REQUEST_EVIDENCE_IMMUTABLE';
  end if;

  if new.transaction_type is distinct from 'expense'
     or new.external_source is distinct from 'aozora_school'
     or new.external_reference_type is distinct from 'school_expense_records'
     or new.request_type is distinct from 'expense_paid'
     or new.accounting_scope is distinct from 'school'
     or new.account_id is not null
     or new.funding_account_id is not null then
    raise exception using errcode = '23514', message = 'FIXED_CARD_ROUTE_REQUIRES_SCHOOL_EXPENSE';
  end if;

  select * into v_card
  from public.home_card_instruments
  where id = new.card_instrument_id
  for key share;

  if not found
     or v_card.user_id is distinct from new.user_id
     or v_card.settlement_currency is distinct from new.currency
     or v_card.is_active is not true
     or (tg_op = 'INSERT' and v_card.is_school_fixed_route_enabled is not true) then
    raise exception using errcode = '23514', message = 'FIXED_CARD_ROUTE_DISABLED_OR_INVALID';
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(new.card_instrument_id, new.charge_date);

  if new.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month then
    raise exception using errcode = '23514', message = 'FIXED_CARD_ROUTE_INVALID_SUGGESTED_MONTH';
  end if;

  if tg_op = 'INSERT' and (
    new.target_fixed_month is distinct from v_schedule.suggested_fixed_month
    or new.fixed_month_override_reason is not null
  ) then
    raise exception using errcode = '23514', message = 'FIXED_CARD_ROUTE_INITIAL_TARGET_MUST_MATCH_SUGGESTED';
  end if;

  if tg_op = 'UPDATE' and row(new.target_fixed_month, new.fixed_month_override_reason)
     is distinct from row(old.target_fixed_month, old.fixed_month_override_reason)
     and current_setting('home.fixed_request_month_override_writer', true)
       is distinct from 'enabled' then
    raise exception using errcode = '42501', message = 'FIXED_CARD_ROUTE_OVERRIDE_REQUIRES_ADMIN_WRITER';
  end if;

  begin
    v_snapshot_funding_date := (new.payload_snapshot ->> 'funding_date')::date;
  exception when others then
    raise exception using errcode = '23514', message = 'FIXED_CARD_ROUTE_INVALID_FUNDING_DATE';
  end;

  if v_snapshot_funding_date is distinct from v_schedule.funding_date
     or new.payload_snapshot ->> 'payment_route' is distinct from 'fixed_credit_card'
     or new.payload_snapshot ->> 'card_instrument_id' is distinct from new.card_instrument_id::text
     or new.payload_snapshot ->> 'charge_date' is distinct from new.charge_date::text
     or new.payload_snapshot ->> 'suggested_fixed_month' is distinct from new.suggested_fixed_month::text
     or new.payload_snapshot ->> 'target_fixed_month' is distinct from new.target_fixed_month::text
     or coalesce(new.payload_snapshot ->> 'school_attempt_payload_fingerprint', '')
       !~ '^[0-9a-f]{64}$' then
    raise exception using errcode = '23514', message = 'FIXED_CARD_ROUTE_PAYLOAD_SNAPSHOT_MISMATCH';
  end if;

  return new;
end;
$function$;

create or replace function public.home_validate_external_fixed_projection()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_account public.home_accounts%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_schedule record;
  v_superseded public.home_external_fixed_payment_projections%rowtype;
begin
  select * into v_request
  from public.home_external_transaction_requests
  where id = new.external_request_id;

  if not found
     or v_request.user_id is distinct from new.user_id
     or v_request.payment_route is distinct from 'fixed_credit_card'
     or v_request.status not in ('pending', 'approved')
     or v_request.external_source is distinct from new.external_source
     or v_request.external_reference_type is distinct from new.external_reference_type
     or v_request.external_reference_id is distinct from new.external_reference_id
     or v_request.external_event_id is distinct from new.external_event_id
     or v_request.idempotency_key is distinct from new.external_idempotency_key
     or v_request.card_instrument_id is distinct from new.card_instrument_id
     or v_request.account_id is not null
     or v_request.funding_account_id is not null
     or v_request.charge_date is distinct from new.charge_date
     or v_request.suggested_fixed_month is distinct from new.suggested_fixed_month
     or v_request.target_fixed_month is distinct from new.target_fixed_month
     or v_request.amount is distinct from new.settlement_amount
     or v_request.currency is distinct from new.settlement_currency then
    raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_REQUEST_MISMATCH';
  end if;

  select * into v_card from public.home_card_instruments where id = new.card_instrument_id;
  if not found
     or v_card.user_id is distinct from new.user_id
     or v_card.settlement_currency is distinct from new.settlement_currency
     or v_card.funding_payment_channel_id is distinct from new.funding_payment_channel_id
     or v_card.is_active is not true
     or v_card.is_school_fixed_route_enabled is not true then
    raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_CARD';
  end if;

  select * into v_channel from public.home_payment_channels where id = new.funding_payment_channel_id;
  if not found or v_channel.user_id is distinct from new.user_id
     or v_channel.currency is distinct from new.settlement_currency
     or v_channel.is_active is not true then
    raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_CHANNEL';
  end if;

  if new.funding_account_id is not null then
    select * into v_account from public.home_accounts where id = new.funding_account_id;
    if not found or v_account.user_id is distinct from new.user_id
       or v_account.currency is distinct from new.settlement_currency
       or v_account.is_active is not true
       or v_account.allow_school_requests is not true then
      raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_ACCOUNT';
    end if;
  end if;

  select * into v_item from public.home_fixed_month_items where id = new.fixed_month_item_id;
  if not found
     or v_item.user_id is distinct from new.user_id
     or v_item.currency is distinct from new.settlement_currency
     or v_item.month_key is distinct from to_char(new.target_fixed_month, 'YYYY-MM')
     or v_item.direction is distinct from 'expense'
     or v_item.accounting_scope is distinct from 'school'
     or v_item.amount is distinct from new.settlement_amount
     or v_item.payment_group is distinct from v_channel.name then
    raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_FIXED_ITEM';
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(new.card_instrument_id, new.charge_date);
  if new.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or new.funding_date is distinct from v_schedule.funding_date then
    raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_SCHEDULE';
  end if;

  if new.fixed_month_override_actor is not null
     and new.fixed_month_override_actor is distinct from new.user_id then
    raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_OVERRIDE_ACTOR';
  end if;

  if new.supersedes_projection_id is not null then
    if new.supersedes_projection_id = new.id then
      raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_CANNOT_SUPERSEDE_SELF';
    end if;
    select * into v_superseded
    from public.home_external_fixed_payment_projections
    where id = new.supersedes_projection_id;
    if not found
       or v_superseded.projection_status is distinct from 'corrected'
       or v_superseded.user_id is distinct from new.user_id
       or v_superseded.card_instrument_id is distinct from new.card_instrument_id
       or v_superseded.school_expense_id is distinct from new.school_expense_id then
      raise exception using errcode = '23514', message = 'EXTERNAL_FIXED_PROJECTION_INVALID_SUPERSEDED_PROJECTION';
    end if;
  end if;

  return new;
end;
$function$;

create or replace function public.home_guard_external_fixed_projection_immutable()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
begin
  if tg_op = 'DELETE' then
    raise exception using errcode = '42501', message = 'EXTERNAL_FIXED_PROJECTION_IMMUTABLE';
  end if;

  if row(
    new.user_id, new.external_request_id, new.external_source,
    new.external_reference_type, new.external_reference_id, new.external_event_id,
    new.external_idempotency_key, new.school_expense_id, new.payment_route,
    new.card_instrument_id, new.funding_payment_channel_id, new.funding_account_id,
    new.business_month, new.charge_date, new.suggested_fixed_month,
    new.target_fixed_month, new.funding_date, new.original_amount,
    new.original_currency, new.settlement_amount, new.settlement_currency,
    new.settlement_amount_status, new.fixed_month_item_id,
    new.supersedes_projection_id, new.approved_at, new.created_at
  ) is distinct from row(
    old.user_id, old.external_request_id, old.external_source,
    old.external_reference_type, old.external_reference_id, old.external_event_id,
    old.external_idempotency_key, old.school_expense_id, old.payment_route,
    old.card_instrument_id, old.funding_payment_channel_id, old.funding_account_id,
    old.business_month, old.charge_date, old.suggested_fixed_month,
    old.target_fixed_month, old.funding_date, old.original_amount,
    old.original_currency, old.settlement_amount, old.settlement_currency,
    old.settlement_amount_status, old.fixed_month_item_id,
    old.supersedes_projection_id, old.approved_at, old.created_at
  ) then
    raise exception using errcode = '42501', message = 'EXTERNAL_FIXED_PROJECTION_IMMUTABLE';
  end if;

  if new.version <= old.version then
    raise exception using errcode = '40001', message = 'EXTERNAL_FIXED_PROJECTION_VERSION_MUST_ADVANCE';
  end if;

  return new;
end;
$function$;

-- Narrow service-only schedule/catalog wrapper. Core helpers remain owner-only.
create or replace function public.home_get_school_fixed_card_schedule(
  p_card_instrument_id uuid,
  p_charge_date date
)
returns table (
  cash_user_id uuid,
  card_instrument_id uuid,
  settlement_currency text,
  cutoff_day integer,
  cutoff_inclusive boolean,
  suggested_fixed_month date,
  target_fixed_month date,
  funding_date date,
  route_enabled boolean
)
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_schedule record;
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception using errcode = '42501', message = 'HOME_FIXED_CARD_SCHEDULE_SERVICE_ROLE_REQUIRED';
  end if;
  if p_card_instrument_id is null or p_charge_date is null then
    raise exception using errcode = '22004', message = 'HOME_FIXED_CARD_SCHEDULE_INPUT_REQUIRED';
  end if;

  select * into v_card
  from public.home_card_instruments
  where id = p_card_instrument_id;
  if not found then
    raise exception using errcode = 'P0002', message = 'CARD_INSTRUMENT_NOT_FOUND';
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(p_card_instrument_id, p_charge_date);

  return query select
    v_card.user_id,
    v_card.id,
    v_card.settlement_currency,
    v_card.cutoff_day,
    v_card.cutoff_inclusive,
    v_schedule.suggested_fixed_month,
    v_schedule.suggested_fixed_month,
    v_schedule.funding_date,
    (v_card.is_active and v_card.is_school_fixed_route_enabled);
end;
$function$;

create or replace function public.home_create_external_fixed_transaction_request(
  p_user_id uuid,
  p_external_source text,
  p_external_event_id uuid,
  p_external_reference_type text,
  p_external_reference_id uuid,
  p_request_type text,
  p_transaction_type text,
  p_card_instrument_id uuid,
  p_charge_date date,
  p_suggested_fixed_month date,
  p_target_fixed_month date,
  p_funding_date date,
  p_amount numeric,
  p_currency text,
  p_idempotency_key text,
  p_description text default null,
  p_note text default null,
  p_payload_snapshot jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_schedule record;
  v_existing public.home_external_transaction_requests%rowtype;
  v_request_id uuid;
  v_source text := lower(trim(coalesce(p_external_source, '')));
  v_reference_type text := lower(trim(coalesce(p_external_reference_type, '')));
  v_request_type text := lower(trim(coalesce(p_request_type, '')));
  v_transaction_type text := lower(trim(coalesce(p_transaction_type, '')));
  v_currency text := upper(trim(coalesce(p_currency, '')));
  v_key text := nullif(trim(coalesce(p_idempotency_key, '')), '');
  v_description text := coalesce(nullif(trim(coalesce(p_description, '')), ''), 'School信用卡固定支出请求');
  v_note text := coalesce(p_note, '');
  v_payload jsonb := coalesce(p_payload_snapshot, '{}'::jsonb);
begin
  if coalesce(auth.role(), '') <> 'service_role' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_SERVICE_ROLE_REQUIRED', 'message', 'service_role is required');
  end if;

  if p_user_id is null or p_external_event_id is null or p_external_reference_id is null
     or p_card_instrument_id is null or p_charge_date is null
     or p_suggested_fixed_month is null or p_target_fixed_month is null
     or p_funding_date is null or coalesce(p_amount, 0) <= 0 or v_key is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_INPUT_REQUIRED', 'message', 'fixed request input is incomplete');
  end if;

  if v_source <> 'aozora_school'
     or v_reference_type <> 'school_expense_records'
     or v_request_type <> 'expense_paid'
     or v_transaction_type <> 'expense' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_IDENTITY_INVALID', 'message', 'fixed request must reference a School expense');
  end if;

  -- Resolve an existing identity before current card/Gate validation so an
  -- already-created request remains recoverable after a later Gate close. Any
  -- changed field returns the same deterministic identity conflict.
  select * into v_existing
  from public.home_external_transaction_requests r
  where r.idempotency_key = v_key
     or (r.external_source = v_source and r.external_event_id = p_external_event_id and r.request_type = v_request_type)
  order by (r.idempotency_key = v_key) desc
  limit 1;

  if found then
    if v_existing.user_id is distinct from p_user_id
       or v_existing.payment_route is distinct from 'fixed_credit_card'
       or v_existing.external_source is distinct from v_source
       or v_existing.external_event_id is distinct from p_external_event_id
       or v_existing.external_reference_type is distinct from v_reference_type
       or v_existing.external_reference_id is distinct from p_external_reference_id
       or v_existing.request_type is distinct from v_request_type
       or v_existing.transaction_type is distinct from v_transaction_type
       or v_existing.currency is distinct from v_currency
       or v_existing.amount is distinct from p_amount
       or v_existing.account_id is not null
       or v_existing.funding_account_id is not null
       or v_existing.card_instrument_id is distinct from p_card_instrument_id
       or v_existing.charge_date is distinct from p_charge_date
       or v_existing.suggested_fixed_month is distinct from p_suggested_fixed_month
       or v_existing.target_fixed_month is distinct from p_target_fixed_month
       or v_existing.fixed_month_override_reason is not null
       or v_existing.payload_snapshot is distinct from v_payload then
      return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_IDENTITY_PAYLOAD_CONFLICT', 'message', 'fixed request identity already exists with different payload', 'request_id', v_existing.id);
    end if;
    return jsonb_build_object('ok', true, 'inserted', false, 'request_id', v_existing.id, 'status', v_existing.status, 'payment_route', v_existing.payment_route, 'created_transaction_id', v_existing.created_transaction_id, 'message', 'fixed request already exists');
  end if;

  select * into v_card
  from public.home_card_instruments
  where id = p_card_instrument_id
  for key share;

  if not found or v_card.user_id is distinct from p_user_id
     or v_card.settlement_currency is distinct from v_currency
     or v_card.is_active is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_CARD_INVALID', 'message', 'fixed request card is missing, inactive, wrong owner, or wrong currency');
  end if;
  if v_card.is_school_fixed_route_enabled is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_CARD_ROUTE_DISABLED', 'message', 'School fixed credit-card route is disabled');
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(p_card_instrument_id, p_charge_date);
  if p_suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or p_target_fixed_month is distinct from v_schedule.suggested_fixed_month
     or p_funding_date is distinct from v_schedule.funding_date then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_SCHEDULE_MISMATCH', 'message', 'School fixed schedule does not match Cash DB authority');
  end if;

  if v_payload ->> 'external_source' is distinct from v_source
     or v_payload ->> 'external_reference_type' is distinct from v_reference_type
     or v_payload ->> 'external_reference_id' is distinct from p_external_reference_id::text
     or v_payload ->> 'request_type' is distinct from v_request_type
     or v_payload ->> 'transaction_type' is distinct from v_transaction_type
     or v_payload ->> 'payment_route' is distinct from 'fixed_credit_card'
     or v_payload ->> 'card_instrument_id' is distinct from p_card_instrument_id::text
     or v_payload ->> 'charge_date' is distinct from p_charge_date::text
     or v_payload ->> 'suggested_fixed_month' is distinct from p_suggested_fixed_month::text
     or v_payload ->> 'target_fixed_month' is distinct from p_target_fixed_month::text
     or v_payload ->> 'funding_date' is distinct from p_funding_date::text
     or coalesce(v_payload ->> 'school_attempt_payload_fingerprint', '') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_PAYLOAD_MISMATCH', 'message', 'fixed request payload snapshot does not match canonical input');
  end if;

  select * into v_existing
  from public.home_external_transaction_requests r
  where r.external_source = v_source
    and r.external_reference_type = v_reference_type
    and r.external_reference_id = p_external_reference_id
    and r.request_type = v_request_type
    and r.status in ('pending', 'approved')
  limit 1;
  if found then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_ACTIVE_REFERENCE_EXISTS', 'message', 'active or approved request already exists for this School expense', 'request_id', v_existing.id, 'status', v_existing.status);
  end if;

  insert into public.home_external_transaction_requests(
    user_id, external_source, external_event_id, external_reference_type,
    external_reference_id, request_type, transaction_type, currency, amount,
    account_id, transacted_at, status, idempotency_key, payload_snapshot,
    description, note, accounting_scope, payment_route, card_instrument_id,
    charge_date, suggested_fixed_month, target_fixed_month,
    fixed_month_override_reason, funding_account_id, fixed_projection_id,
    projection_status
  ) values (
    p_user_id, v_source, p_external_event_id, v_reference_type,
    p_external_reference_id, v_request_type, v_transaction_type, v_currency,
    p_amount, null, p_charge_date, 'pending', v_key, v_payload,
    v_description, v_note, 'school', 'fixed_credit_card', p_card_instrument_id,
    p_charge_date, p_suggested_fixed_month, p_target_fixed_month,
    null, null, null, 'pending'
  ) returning id into v_request_id;

  return jsonb_build_object('ok', true, 'inserted', true, 'request_id', v_request_id, 'status', 'pending', 'payment_route', 'fixed_credit_card', 'message', 'fixed request created');
exception
  when unique_violation then
    select * into v_existing
    from public.home_external_transaction_requests r
    where r.idempotency_key = v_key
       or (r.external_source = v_source and r.external_event_id = p_external_event_id and r.request_type = v_request_type)
       or (r.external_source = v_source and r.external_reference_type = v_reference_type
           and r.external_reference_id = p_external_reference_id and r.request_type = v_request_type
           and r.status in ('pending', 'approved'))
    order by (r.idempotency_key = v_key) desc
    limit 1;
    if found and v_existing.user_id is not distinct from p_user_id
       and v_existing.payment_route is not distinct from 'fixed_credit_card'
       and v_existing.external_event_id is not distinct from p_external_event_id
       and v_existing.external_reference_type is not distinct from v_reference_type
       and v_existing.external_reference_id is not distinct from p_external_reference_id
       and v_existing.request_type is not distinct from v_request_type
       and v_existing.transaction_type is not distinct from v_transaction_type
       and v_existing.currency is not distinct from v_currency
       and v_existing.amount is not distinct from p_amount
       and v_existing.account_id is null and v_existing.funding_account_id is null
       and v_existing.card_instrument_id is not distinct from p_card_instrument_id
       and v_existing.charge_date is not distinct from p_charge_date
       and v_existing.suggested_fixed_month is not distinct from p_suggested_fixed_month
       and v_existing.target_fixed_month is not distinct from p_target_fixed_month
       and v_existing.payload_snapshot is not distinct from v_payload then
      return jsonb_build_object('ok', true, 'inserted', false, 'request_id', v_existing.id, 'status', v_existing.status, 'payment_route', v_existing.payment_route, 'created_transaction_id', v_existing.created_transaction_id, 'message', 'fixed request already exists');
    end if;
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_IDENTITY_PAYLOAD_CONFLICT', 'message', 'fixed request identity already exists with different payload', 'request_id', v_existing.id);
end;
$function$;

-- Existing reject signature stays compatible. Fixed rejection moves only the
-- request projection marker to cancelled and creates no projection/ledger row.
create or replace function public.home_reject_external_transaction_request(
  p_request_id uuid,
  p_reason text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_reason text := nullif(trim(coalesce(p_reason, '')), '');
begin
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'message', 'request_id is required');
  end if;
  select * into v_request
  from public.home_external_transaction_requests r
  where r.id = p_request_id
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'external transaction request not found');
  end if;
  if coalesce(auth.role(), '') <> 'service_role' then
    if auth.uid() is null then
      return jsonb_build_object('ok', false, 'message', 'authenticated request owner is required');
    end if;
    if auth.uid() is distinct from v_request.user_id then
      return jsonb_build_object('ok', false, 'message', 'authenticated user does not match request owner');
    end if;
  end if;
  if v_request.status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'only pending requests can be rejected', 'status', v_request.status);
  end if;

  if v_request.payment_route = 'fixed_credit_card' and (
    v_request.created_transaction_id is not null
    or v_request.fixed_projection_id is not null
    or exists (
      select 1 from public.home_external_fixed_payment_projections p
      where p.external_request_id = v_request.id
    )
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_REQUEST_REJECTION_HAS_DOWNSTREAM_FACTS',
      'message', 'fixed request with a transaction or projection cannot use the Phase 3C3-B rejection path'
    );
  end if;

  update public.home_external_transaction_requests
  set status = 'rejected',
      rejected_at = now(),
      rejected_reason = v_reason,
      projection_status = case when v_request.payment_route = 'fixed_credit_card' then 'cancelled' else projection_status end,
      updated_at = now()
  where id = v_request.id;

  return jsonb_build_object('ok', true, 'request_id', v_request.id, 'status', 'rejected', 'message', 'external transaction request rejected');
end;
$function$;

-- Existing approve signature and immediate behavior stay compatible. Fixed
-- requests are rejected before any transaction primitive can be called.
create or replace function public.home_approve_external_transaction_request(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = public
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_transaction_result jsonb;
  v_transaction_id uuid;
  v_transaction_exists boolean;
begin
  if p_request_id is null then
    return jsonb_build_object('ok', false, 'message', 'request_id is required');
  end if;

  select * into v_request
  from public.home_external_transaction_requests request_row
  where request_row.id = p_request_id
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'message', 'external transaction request not found');
  end if;

  if coalesce(auth.role(), '') <> 'service_role' then
    if auth.uid() is null then
      return jsonb_build_object('ok', false, 'message', 'authenticated request owner is required');
    end if;
    if auth.uid() is distinct from v_request.user_id then
      return jsonb_build_object('ok', false, 'message', 'authenticated user does not match request owner');
    end if;
  end if;

  if v_request.payment_route = 'fixed_credit_card' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_REQUEST_APPROVAL_REQUIRES_FIXED_WRITER', 'message', 'fixed credit-card request approval requires the Phase 3D fixed writer');
  end if;

  if v_request.status = 'approved' then
    if v_request.created_transaction_id is null then
      return jsonb_build_object('ok', false, 'message', 'approved request is missing its transaction id');
    end if;
    if v_request.currency = 'JPY' then
      select exists (
        select 1 from public.home_jpy_transactions t
        where t.id = v_request.created_transaction_id
          and t.user_id = v_request.user_id and t.account_id = v_request.account_id
          and t.amount = v_request.amount and t.external_source_id = v_request.external_event_id
          and t.external_idempotency_key = v_request.idempotency_key
      ) into v_transaction_exists;
    elsif v_request.currency = 'CNY' then
      select exists (
        select 1 from public.home_cny_transactions t
        where t.id = v_request.created_transaction_id
          and t.user_id = v_request.user_id and t.account_id = v_request.account_id
          and t.amount = v_request.amount and t.external_source_id = v_request.external_event_id
          and t.external_idempotency_key = v_request.idempotency_key
      ) into v_transaction_exists;
    else
      v_transaction_exists := false;
    end if;
    if not coalesce(v_transaction_exists, false) then
      return jsonb_build_object('ok', false, 'message', 'approved request transaction does not match the canonical request');
    end if;
    return jsonb_build_object('ok', true, 'request_id', v_request.id, 'status', 'approved', 'currency', v_request.currency, 'transaction_id', v_request.created_transaction_id, 'transaction_inserted', false, 'message', 'external transaction request already approved');
  end if;

  if v_request.status <> 'pending' then
    return jsonb_build_object('ok', false, 'message', 'only pending requests can be approved', 'status', v_request.status);
  end if;

  if v_request.currency = 'JPY' then
    select public.home_create_external_jpy_transaction(
      v_request.user_id, v_request.account_id, v_request.transaction_type,
      v_request.transacted_at, v_request.amount, v_request.description,
      v_request.note, v_request.external_source, v_request.external_event_id,
      v_request.request_type, v_request.idempotency_key,
      v_request.external_reference_type, v_request.external_reference_id,
      v_request.note, md5(v_request.payload_snapshot::text)
    ) into v_transaction_result;
  elsif v_request.currency = 'CNY' then
    select public.home_create_external_cny_transaction(
      v_request.user_id, v_request.account_id, v_request.transaction_type,
      v_request.transacted_at, v_request.amount, v_request.description,
      v_request.note, v_request.external_source, v_request.external_event_id,
      v_request.request_type, v_request.idempotency_key,
      v_request.external_reference_type, v_request.external_reference_id,
      v_request.note, md5(v_request.payload_snapshot::text)
    ) into v_transaction_result;
  else
    return jsonb_build_object('ok', false, 'message', 'unsupported request currency', 'currency', v_request.currency);
  end if;

  if coalesce((v_transaction_result ->> 'ok')::boolean, false) is not true then
    return v_transaction_result;
  end if;
  v_transaction_id := (v_transaction_result ->> 'transaction_id')::uuid;

  update public.home_external_transaction_requests
  set status = 'approved', approved_at = now(), created_transaction_id = v_transaction_id, updated_at = now()
  where id = v_request.id;

  return jsonb_build_object('ok', true, 'request_id', v_request.id, 'status', 'approved', 'currency', v_request.currency, 'transaction_id', v_transaction_id, 'transaction_inserted', coalesce((v_transaction_result ->> 'inserted')::boolean, false), 'message', 'external transaction request approved');
end;
$function$;

alter function public.home_validate_card_instrument() owner to postgres;
alter function public.home_validate_external_request_payment_route() owner to postgres;
alter function public.home_validate_external_fixed_projection() owner to postgres;
alter function public.home_guard_external_fixed_projection_immutable() owner to postgres;
alter function public.home_get_school_fixed_card_schedule(uuid,date) owner to postgres;
alter function public.home_create_external_fixed_transaction_request(uuid,text,uuid,text,uuid,text,text,uuid,date,date,date,date,numeric,text,text,text,text,jsonb) owner to postgres;
alter function public.home_reject_external_transaction_request(uuid,text) owner to postgres;
alter function public.home_approve_external_transaction_request(uuid) owner to postgres;

revoke all on function public.home_validate_card_instrument() from public, anon, authenticated, service_role;
revoke all on function public.home_validate_external_request_payment_route() from public, anon, authenticated, service_role;
revoke all on function public.home_validate_external_fixed_projection() from public, anon, authenticated, service_role;
revoke all on function public.home_guard_external_fixed_projection_immutable() from public, anon, authenticated, service_role;
revoke all on function public.home_get_school_fixed_card_schedule(uuid,date) from public, anon, authenticated, service_role;
grant execute on function public.home_get_school_fixed_card_schedule(uuid,date) to service_role;
revoke all on function public.home_create_external_fixed_transaction_request(uuid,text,uuid,text,uuid,text,text,uuid,date,date,date,date,numeric,text,text,text,text,jsonb) from public, anon, authenticated, service_role;
grant execute on function public.home_create_external_fixed_transaction_request(uuid,text,uuid,text,uuid,text,text,uuid,date,date,date,date,numeric,text,text,text,text,jsonb) to service_role;

-- Preserve existing authenticated/service-role approve/reject ACL exactly.
revoke all on function public.home_approve_external_transaction_request(uuid) from public, anon;
revoke all on function public.home_reject_external_transaction_request(uuid,text) from public, anon;
grant execute on function public.home_approve_external_transaction_request(uuid) to authenticated, service_role;
grant execute on function public.home_reject_external_transaction_request(uuid,text) to authenticated, service_role;

comment on function public.home_get_school_fixed_card_schedule(uuid,date) is
  'Phase 3C3-B service-only fixed-card catalog/schedule wrapper. Cash DB is the sole month and funding-date authority; route_enabled is informational and no row is written.';
comment on function public.home_create_external_fixed_transaction_request(uuid,text,uuid,text,uuid,text,text,uuid,date,date,date,date,numeric,text,text,text,text,jsonb) is
  'Phase 3C3-B service-only fixed request writer. Revalidates Cash schedule and card Gate, creates only a pending fixed request, stores no account, and creates no transaction/projection/item/cycle.';
comment on column public.home_external_fixed_payment_projections.funding_account_id is
  'NULL while unfunded. A future narrow group-funding writer must assign and validate the real funding account before funded status.';
comment on column public.home_external_fixed_payment_projections.supersedes_projection_id is
  'For a replacement projection, points from the new projection to the old projection whose status is corrected.';
