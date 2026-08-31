-- Phase 3E card statement preview, confirm/reopen and household remainder.
-- Status: production deployed 2026-08-19; no production statement operation executed.
-- This migration never enables the School fixed route and creates no business cycle by itself.

lock table public.home_card_statement_cycles,
  public.home_card_instruments,
  public.home_payment_channels,
  public.home_fixed_templates,
  public.home_external_transaction_requests,
  public.home_external_fixed_payment_projections,
  public.home_fixed_month_items,
  public.home_fixed_advance_payments in access exclusive mode;

do $phase3e_precheck$
begin
  if exists (select 1 from public.home_external_transaction_requests where payment_route='fixed_credit_card') then
    raise exception using errcode='55000',message='PHASE3E_FIXED_REQUEST_PREEXISTS';
  end if;
  if exists (select 1 from public.home_external_fixed_payment_projections) then
    raise exception using errcode='55000',message='PHASE3E_PROJECTION_PREEXISTS';
  end if;
  if exists (select 1 from public.home_card_statement_cycles) then
    raise exception using errcode='55000',message='PHASE3E_CYCLE_PREEXISTS';
  end if;
  if exists (select 1 from public.home_fixed_month_items where accounting_scope='school') then
    raise exception using errcode='55000',message='PHASE3E_SCHOOL_FIXED_ITEM_PREEXISTS';
  end if;
  if exists (select 1 from public.home_card_instruments where is_school_fixed_route_enabled) then
    raise exception using errcode='55000',message='PHASE3E_CARD_ROUTE_ALREADY_ENABLED';
  end if;
end;
$phase3e_precheck$;

alter table public.home_card_statement_cycles
  drop constraint home_card_statement_cycles_confirmation_check,
  drop constraint home_card_statement_cycles_version_check,
  alter column version set default 0,
  add column school_subtotal_amount numeric,
  add column household_remainder_amount numeric,
  add column school_manifest_fingerprint text,
  add column current_confirm_revision_id uuid,
  add column last_operation_idempotency_key text,
  add column last_operation_payload_fingerprint text,
  add column last_operation_at timestamptz,
  add constraint home_card_statement_cycles_version_check check (version>=0),
  add constraint home_card_statement_cycles_amount_identity_check check (
    school_subtotal_amount is null or school_subtotal_amount>=0
  ),
  add constraint home_card_statement_cycles_remainder_check check (
    household_remainder_amount is null or household_remainder_amount>=0
  ),
  add constraint home_card_statement_cycles_manifest_fingerprint_check check (
    school_manifest_fingerprint is null or school_manifest_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  add constraint home_card_statement_cycles_operation_fingerprint_check check (
    last_operation_payload_fingerprint is null or last_operation_payload_fingerprint ~ '^[0-9a-f]{64}$'
  ),
  add constraint home_card_statement_cycles_snapshot_check check (
    (
      amount_status='pending'
      and statement_total_amount is null
      and school_subtotal_amount is null
      and household_remainder_amount is null
      and school_manifest_fingerprint is null
      and current_confirm_revision_id is null
      and confirmed_at is null
      and confirmed_by is null
    ) or (
      amount_status='confirmed'
      and statement_total_amount is not null
      and school_subtotal_amount is not null
      and household_remainder_amount is not null
      and statement_total_amount=school_subtotal_amount+household_remainder_amount
      and school_manifest_fingerprint is not null
      and household_remainder_fixed_item_id is not null
      and current_confirm_revision_id is not null
      and confirmed_at is not null
      and confirmed_by is not null
    )
  ),
  add constraint home_card_statement_cycles_operation_snapshot_check check (
    (version=0 and last_operation_idempotency_key is null and last_operation_payload_fingerprint is null and last_operation_at is null)
    or
    (version>0 and nullif(btrim(last_operation_idempotency_key),'') is not null and last_operation_payload_fingerprint is not null and last_operation_at is not null)
  );

create table public.home_card_statement_cycle_revisions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  cycle_id uuid not null references public.home_card_statement_cycles(id) on delete restrict,
  cycle_version bigint not null check (cycle_version>0),
  action text not null check (action in ('confirm','reopen','reconfirm')),
  statement_total_amount numeric not null check (statement_total_amount>=0),
  school_subtotal_amount numeric not null check (school_subtotal_amount>=0),
  household_remainder_amount numeric not null check (household_remainder_amount>=0),
  school_manifest jsonb not null check (jsonb_typeof(school_manifest)='array'),
  school_manifest_fingerprint text not null check (school_manifest_fingerprint ~ '^[0-9a-f]{64}$'),
  household_remainder_fixed_item_id uuid not null references public.home_fixed_month_items(id) on delete restrict,
  household_item_amount_before numeric not null,
  household_item_amount_after numeric not null,
  actor_id uuid not null references auth.users(id) on delete restrict,
  action_at timestamptz not null default statement_timestamp(),
  reason text,
  operation_idempotency_key text not null check (nullif(btrim(operation_idempotency_key),'') is not null),
  payload_fingerprint text not null check (payload_fingerprint ~ '^[0-9a-f]{64}$'),
  created_at timestamptz not null default statement_timestamp(),
  constraint home_card_statement_cycle_revisions_amount_identity check (
    statement_total_amount=school_subtotal_amount+household_remainder_amount
  ),
  constraint home_card_statement_cycle_revisions_reason_check check (
    (action='reopen' and nullif(btrim(reason),'') is not null)
    or (action in ('confirm','reconfirm') and reason is null)
  ),
  constraint home_card_statement_cycle_revisions_cycle_version_unique unique(cycle_id,cycle_version),
  constraint home_card_statement_cycle_revisions_operation_unique unique(user_id,operation_idempotency_key)
);

alter table public.home_card_statement_cycles
  add constraint home_card_statement_cycles_current_revision_fkey
  foreign key(current_confirm_revision_id)
  references public.home_card_statement_cycle_revisions(id) on delete restrict;

create unique index home_card_statement_cycles_current_revision_unique
  on public.home_card_statement_cycles(current_confirm_revision_id)
  where current_confirm_revision_id is not null;

alter table public.home_card_statement_cycle_revisions enable row level security;
revoke all on table public.home_card_statement_cycle_revisions from public,anon,authenticated,service_role;

create or replace function public.home_guard_card_statement_revision()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception using errcode='42501',message='HOME_CARD_STATEMENT_REVISION_APPEND_ONLY';
  end if;
  if current_setting('home.phase3e_revision_write',true) is distinct from 'on' then
    raise exception using errcode='42501',message='HOME_CARD_STATEMENT_REVISION_DIRECT_INSERT_FORBIDDEN';
  end if;
  return new;
end;
$function$;

create trigger home_card_statement_cycle_revisions_guard
before insert or update or delete on public.home_card_statement_cycle_revisions
for each row execute function public.home_guard_card_statement_revision();

create or replace function public.home_validate_card_statement_cycle()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_revision public.home_card_statement_cycle_revisions%rowtype;
begin
  if tg_op='DELETE' then
    raise exception using errcode='42501',message='HOME_CARD_STATEMENT_CYCLE_DELETE_FORBIDDEN';
  end if;
  if current_setting('home.phase3e_cycle_write',true) is distinct from 'on' then
    raise exception using errcode='42501',message='HOME_CARD_STATEMENT_DIRECT_WRITE_FORBIDDEN';
  end if;
  select * into v_card from public.home_card_instruments where id=new.card_instrument_id;
  if not found or v_card.user_id is distinct from new.user_id
     or v_card.settlement_currency is distinct from new.settlement_currency
     or v_card.is_active is not true then
    raise exception using errcode='23514',message='CARD_STATEMENT_INVALID_INSTRUMENT';
  end if;
  if new.confirmed_by is not null and new.confirmed_by is distinct from new.user_id then
    raise exception using errcode='23514',message='CARD_STATEMENT_INVALID_CONFIRMER';
  end if;
  if new.household_remainder_fixed_item_id is not null then
    select * into v_item from public.home_fixed_month_items where id=new.household_remainder_fixed_item_id;
    if not found or v_item.user_id is distinct from new.user_id
       or v_item.currency is distinct from new.settlement_currency
       or v_item.month_key is distinct from to_char(new.target_fixed_month,'YYYY-MM')
       or v_item.direction is distinct from 'expense'
       or v_item.accounting_scope is distinct from 'household'
       or v_item.template_id is distinct from v_card.household_statement_template_id
       or coalesce(v_item.payment_group,'未分组') is distinct from (
         select coalesce(c.name,'未分组') from public.home_payment_channels c where c.id=v_card.funding_payment_channel_id
       ) then
      raise exception using errcode='23514',message='CARD_STATEMENT_INVALID_HOUSEHOLD_REMAINDER_ITEM';
    end if;
  end if;
  if new.version>0 then
    select * into v_revision
    from public.home_card_statement_cycle_revisions r
    where r.cycle_id=new.id and r.cycle_version=new.version;
    if not found or v_revision.operation_idempotency_key is distinct from new.last_operation_idempotency_key
       or v_revision.payload_fingerprint is distinct from new.last_operation_payload_fingerprint then
      raise exception using errcode='23514',message='CARD_STATEMENT_REVISION_SNAPSHOT_MISMATCH';
    end if;
    if new.amount_status='confirmed' and (
      v_revision.id is distinct from new.current_confirm_revision_id
      or v_revision.action not in ('confirm','reconfirm')
      or v_revision.statement_total_amount is distinct from new.statement_total_amount
      or v_revision.school_subtotal_amount is distinct from new.school_subtotal_amount
      or v_revision.household_remainder_amount is distinct from new.household_remainder_amount
      or v_revision.school_manifest_fingerprint is distinct from new.school_manifest_fingerprint
      or v_revision.household_remainder_fixed_item_id is distinct from new.household_remainder_fixed_item_id
    ) then
      raise exception using errcode='23514',message='CARD_STATEMENT_CONFIRMED_REVISION_MISMATCH';
    end if;
    if new.amount_status='pending' and v_revision.action<>'reopen' then
      raise exception using errcode='23514',message='CARD_STATEMENT_PENDING_REVISION_MISMATCH';
    end if;
  end if;
  return new;
end;
$function$;

drop trigger if exists home_card_statement_cycles_validate on public.home_card_statement_cycles;
create trigger home_card_statement_cycles_validate
before insert or update or delete on public.home_card_statement_cycles
for each row execute function public.home_validate_card_statement_cycle();

create or replace function public.home_guard_projection_linked_fixed_item()
returns trigger
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
begin
  if exists (select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=old.id) then
    raise exception using errcode='42501',message=case when tg_op='DELETE' then 'HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN' else 'HOME_PROJECTION_FIXED_ITEM_UPDATE_FORBIDDEN' end;
  end if;
  if exists (select 1 from public.home_card_statement_cycles c where c.household_remainder_fixed_item_id=old.id) then
    if tg_op='DELETE' then
      raise exception using errcode='42501',message='HOME_CARD_STATEMENT_ITEM_DELETE_FORBIDDEN';
    end if;
    if current_setting('home.phase3e_statement_item_write',true) is distinct from 'on'
       or (to_jsonb(new)-'amount') is distinct from (to_jsonb(old)-'amount') then
      raise exception using errcode='42501',message='HOME_CARD_STATEMENT_ITEM_UPDATE_FORBIDDEN';
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$function$;

create or replace function public.home_build_card_statement_school_manifest(
  p_user_id uuid,p_card_instrument_id uuid,p_target_fixed_month date
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_request_count integer;
  v_projection_count integer;
  v_valid_count integer;
  v_manifest jsonb;
  v_subtotal numeric;
  v_fingerprint text;
begin
  select * into v_card from public.home_card_instruments c
  where c.id=p_card_instrument_id and c.user_id=p_user_id;
  if not found or p_target_fixed_month is null
     or p_target_fixed_month<>date_trunc('month',p_target_fixed_month)::date then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CARD_OR_MONTH_INVALID','message','card or target month is invalid');
  end if;
  select * into v_channel from public.home_payment_channels c
  where c.id=v_card.funding_payment_channel_id;
  if not found then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CHANNEL_INVALID','message','card payment channel is missing');
  end if;
  select count(*) into v_request_count
  from public.home_external_transaction_requests r
  where r.user_id=p_user_id and r.payment_route='fixed_credit_card'
    and r.card_instrument_id=p_card_instrument_id
    and r.target_fixed_month=p_target_fixed_month and r.status='approved';
  select count(*) into v_projection_count
  from public.home_external_fixed_payment_projections p
  where p.user_id=p_user_id and p.card_instrument_id=p_card_instrument_id
    and p.target_fixed_month=p_target_fixed_month and p.projection_status='projected';
  with valid as (
    select r.id request_id,p.id projection_id,i.id fixed_item_id,
      p.school_expense_id,r.external_event_id,p.settlement_amount amount,
      p.settlement_currency currency,p.card_instrument_id card_instrument_id,
      p.target_fixed_month target_fixed_month
    from public.home_external_transaction_requests r
    join public.home_external_fixed_payment_projections p
      on p.external_request_id=r.id and r.fixed_projection_id=p.id
    join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
    where r.user_id=p_user_id and p.user_id=p_user_id
      and r.payment_route='fixed_credit_card' and p.payment_route='fixed_credit_card'
      and r.status='approved' and r.projection_status='projected'
      and r.card_instrument_id=p_card_instrument_id and p.card_instrument_id=p_card_instrument_id
      and r.target_fixed_month=p_target_fixed_month and p.target_fixed_month=p_target_fixed_month
      and p.projection_status='projected' and p.funding_status='unfunded'
      and p.funding_account_id is null and p.funding_transaction_id is null and p.funded_at is null
      and p.fixed_month_override_reason is null and p.supersedes_projection_id is null
      and p.external_reference_type='school_expense_records'
      and p.school_expense_id=p.external_reference_id
      and p.external_reference_id=r.external_reference_id
      and p.external_event_id=r.external_event_id
      and p.external_idempotency_key=r.idempotency_key
      and p.original_amount=r.amount and p.settlement_amount=r.amount
      and p.original_currency=r.currency and p.settlement_currency=r.currency
      and i.user_id=p_user_id and i.accounting_scope='school'
      and i.currency=v_card.settlement_currency and i.direction='expense'
      and i.month_key=to_char(p_target_fixed_month,'YYYY-MM')
      and coalesce(i.payment_group,'未分组')=coalesce(v_channel.name,'未分组')
      and i.amount=p.settlement_amount and i.status='unpaid'
      and i.account_id is null and i.linked_jpy_transaction_id is null and i.linked_cny_transaction_id is null
  )
  select count(*),coalesce(sum(amount),0),coalesce(jsonb_agg(jsonb_build_object(
    'request_id',request_id,'projection_id',projection_id,'fixed_item_id',fixed_item_id,
    'school_expense_id',school_expense_id,'external_event_id',external_event_id,
    'amount',amount,'currency',currency,'card_instrument_id',card_instrument_id,
    'target_fixed_month',target_fixed_month
  ) order by request_id),'[]'::jsonb)
  into v_valid_count,v_subtotal,v_manifest from valid;
  if v_request_count<>v_valid_count or v_projection_count<>v_valid_count then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_SCHOOL_MANIFEST_INTEGRITY_ERROR','message','approved School projection facts are incomplete or inconsistent');
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_manifest::text,'UTF8'),'sha256'),'hex');
  return jsonb_build_object('ok',true,'school_subtotal',v_subtotal,'school_manifest',v_manifest,'school_manifest_fingerprint',v_fingerprint,'school_item_count',v_valid_count);
end;
$function$;

create or replace function public.home_build_card_statement_preview(
  p_user_id uuid,p_card_instrument_id uuid,p_target_fixed_month date,
  p_statement_total numeric,p_lock_item boolean default false
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_cycle public.home_card_statement_cycles%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_manifest_result jsonb;
  v_candidate_count integer;
  v_subtotal numeric;
  v_remainder numeric;
  v_blockers jsonb:='[]'::jsonb;
begin
  if p_user_id is null or p_card_instrument_id is null or p_target_fixed_month is null
     or p_target_fixed_month<>date_trunc('month',p_target_fixed_month)::date
     or p_statement_total is null or p_statement_total<0 then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_PREVIEW_INPUT_INVALID','message','card, month and nonnegative statement total are required');
  end if;
  select * into v_card from public.home_card_instruments c
  where c.id=p_card_instrument_id and c.user_id=p_user_id;
  if not found or v_card.is_active is not true then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CARD_INVALID','message','active owned card is required');
  end if;
  select * into v_channel from public.home_payment_channels c where c.id=v_card.funding_payment_channel_id;
  if not found then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CHANNEL_INVALID','message','card channel is missing');
  end if;
  select * into v_cycle from public.home_card_statement_cycles c
  where c.user_id=p_user_id and c.card_instrument_id=p_card_instrument_id
    and c.target_fixed_month=p_target_fixed_month;
  v_manifest_result:=public.home_build_card_statement_school_manifest(p_user_id,p_card_instrument_id,p_target_fixed_month);
  if not coalesce((v_manifest_result->>'ok')::boolean,false) then return v_manifest_result; end if;
  v_subtotal:=(v_manifest_result->>'school_subtotal')::numeric;
  v_remainder:=p_statement_total-v_subtotal;
  select count(*) into v_candidate_count from public.home_fixed_month_items i
  where i.user_id=p_user_id and i.template_id=v_card.household_statement_template_id
    and i.month_key=to_char(p_target_fixed_month,'YYYY-MM');
  if v_candidate_count=1 then
    if p_lock_item then
      select * into v_item from public.home_fixed_month_items i
      where i.user_id=p_user_id and i.template_id=v_card.household_statement_template_id
        and i.month_key=to_char(p_target_fixed_month,'YYYY-MM') for update;
    else
      select * into v_item from public.home_fixed_month_items i
      where i.user_id=p_user_id and i.template_id=v_card.household_statement_template_id
        and i.month_key=to_char(p_target_fixed_month,'YYYY-MM');
    end if;
  elsif v_candidate_count=0 then
    v_blockers:=v_blockers||jsonb_build_array('HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_MISSING');
  else
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_DUPLICATE','message','household statement item is not unique');
  end if;
  if v_candidate_count=1 and (
    v_item.accounting_scope<>'household' or v_item.currency<>v_card.settlement_currency
    or v_item.direction<>'expense' or coalesce(v_item.payment_group,'未分组')<>coalesce(v_channel.name,'未分组')
    or v_item.status<>'unpaid' or v_item.account_id is not null
    or v_item.linked_jpy_transaction_id is not null or v_item.linked_cny_transaction_id is not null
    or exists(select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=v_item.id)
  ) then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_INVALID','message','household statement item identity or state is invalid');
  end if;
  if v_candidate_count=1 and exists(
    select 1 from public.home_card_statement_cycles c
    where c.household_remainder_fixed_item_id=v_item.id
      and (v_cycle.id is null or c.id<>v_cycle.id)
  ) then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_ALREADY_LINKED','message','household item belongs to another card cycle');
  end if;
  if exists(select 1 from public.home_fixed_advance_payments a
    where a.user_id=p_user_id and a.month_key=to_char(p_target_fixed_month,'YYYY-MM')
      and a.currency=v_card.settlement_currency and a.payment_group=coalesce(v_channel.name,'未分组')) then
    v_blockers:=v_blockers||jsonb_build_array('HOME_CARD_STATEMENT_GROUP_ALREADY_ADVANCED');
  end if;
  if v_remainder<0 then v_blockers:=v_blockers||jsonb_build_array('HOME_CARD_STATEMENT_TOTAL_BELOW_SCHOOL_SUBTOTAL'); end if;
  if v_cycle.id is not null and v_cycle.amount_status='confirmed' then
    v_blockers:=v_blockers||jsonb_build_array('HOME_CARD_STATEMENT_REOPEN_REQUIRED');
  end if;
  return jsonb_build_object(
    'ok',true,'card_instrument_id',v_card.id,'target_fixed_month',p_target_fixed_month,
    'cycle_id',v_cycle.id,'cycle_status',coalesce(v_cycle.amount_status,'pending'),
    'cycle_version',coalesce(v_cycle.version,0),'statement_total',p_statement_total,
    'school_subtotal',v_subtotal,'household_remainder',v_remainder,
    'school_manifest',v_manifest_result->'school_manifest',
    'school_manifest_fingerprint',v_manifest_result->>'school_manifest_fingerprint',
    'school_item_count',(v_manifest_result->>'school_item_count')::integer,
    'household_remainder_fixed_item_id',v_item.id,'household_item_current_amount',v_item.amount,
    'needs_household_item_generation',(v_candidate_count=0),
    'has_confirmed_cycle',(v_cycle.id is not null and v_cycle.amount_status='confirmed'),
    'blockers',v_blockers,'can_confirm',(jsonb_array_length(v_blockers)=0)
  );
end;
$function$;

create or replace function public.home_preview_card_statement(
  p_card_instrument_id uuid,p_target_fixed_month date,p_statement_total numeric
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_AUTH_REQUIRED','message','authenticated user is required'); end if;
  return public.home_build_card_statement_preview(v_actor,p_card_instrument_id,p_target_fixed_month,p_statement_total,false);
end;
$function$;

create or replace function public.home_card_statement_revision_result(p_revision_id uuid)
returns jsonb
language sql
security definer
set search_path=pg_catalog,public
as $function$
  select jsonb_build_object(
    'ok',true,'revision_id',r.id,'cycle_id',r.cycle_id,'cycle_version',r.cycle_version,
    'action',r.action,'statement_total',r.statement_total_amount,
    'school_subtotal',r.school_subtotal_amount,'household_remainder',r.household_remainder_amount,
    'school_manifest',r.school_manifest,'school_manifest_fingerprint',r.school_manifest_fingerprint,
    'household_remainder_fixed_item_id',r.household_remainder_fixed_item_id,
    'household_item_amount_before',r.household_item_amount_before,
    'household_item_amount_after',r.household_item_amount_after,
    'actor_id',r.actor_id,'action_at',r.action_at,'reason',r.reason,
    'operation_idempotency_key',r.operation_idempotency_key,'payload_fingerprint',r.payload_fingerprint
  ) from public.home_card_statement_cycle_revisions r where r.id=p_revision_id;
$function$;

create or replace function public.home_apply_card_statement_confirm(
  p_actor_id uuid,p_card_instrument_id uuid,p_target_fixed_month date,
  p_statement_total numeric,p_expected_cycle_version bigint,p_operation_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_cycle public.home_card_statement_cycles%rowtype;
  v_revision public.home_card_statement_cycle_revisions%rowtype;
  v_preview jsonb;
  v_item public.home_fixed_month_items%rowtype;
  v_cycle_id uuid:=gen_random_uuid();
  v_revision_id uuid:=gen_random_uuid();
  v_new_version bigint;
  v_action text;
  v_cycle_exists boolean:=false;
  v_key text:=nullif(btrim(coalesce(p_operation_idempotency_key,'')),'');
  v_payload_fp text;
  v_now timestamptz:=statement_timestamp();
begin
  if p_actor_id is null or p_card_instrument_id is null or p_target_fixed_month is null
     or p_statement_total is null or p_statement_total<0 or p_expected_cycle_version is null
     or p_expected_cycle_version<0 or v_key is null then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CONFIRM_INPUT_INVALID','message','confirm input is incomplete');
  end if;
  v_payload_fp:=encode(extensions.digest(convert_to(jsonb_build_object(
    'action','confirm','actor_id',p_actor_id,'card_instrument_id',p_card_instrument_id,
    'target_fixed_month',p_target_fixed_month,'statement_total',p_statement_total,
    'expected_cycle_version',p_expected_cycle_version
  )::text,'UTF8'),'sha256'),'hex');
  select * into v_revision from public.home_card_statement_cycle_revisions r
  where r.user_id=p_actor_id and r.operation_idempotency_key=v_key;
  if found then
    if v_revision.payload_fingerprint<>v_payload_fp or v_revision.action not in ('confirm','reconfirm') then
      return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_OPERATION_CONFLICT','message','operation key already exists with different payload');
    end if;
    return public.home_card_statement_revision_result(v_revision.id)||jsonb_build_object('idempotent',true);
  end if;
  select * into v_card from public.home_card_instruments c
  where c.id=p_card_instrument_id and c.user_id=p_actor_id for update;
  if not found or v_card.is_active is not true then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CARD_INVALID','message','active owned card is required');
  end if;
  perform public.home_lock_card_fixed_month(v_card.id,p_target_fixed_month);
  select * into v_revision from public.home_card_statement_cycle_revisions r
  where r.user_id=p_actor_id and r.operation_idempotency_key=v_key;
  if found then
    if v_revision.payload_fingerprint<>v_payload_fp or v_revision.action not in ('confirm','reconfirm') then
      return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_OPERATION_CONFLICT','message','operation key already exists with different payload');
    end if;
    return public.home_card_statement_revision_result(v_revision.id)||jsonb_build_object('idempotent',true);
  end if;
  select * into v_cycle from public.home_card_statement_cycles c
  where c.user_id=p_actor_id and c.card_instrument_id=v_card.id and c.target_fixed_month=p_target_fixed_month for update;
  v_cycle_exists:=found;
  if not v_cycle_exists then
    if p_expected_cycle_version<>0 then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_VERSION_CONFLICT','message','cycle version changed','actual_version',0); end if;
    v_cycle.version:=0;
    v_cycle.amount_status:='pending';
  else
    if v_cycle.version<>p_expected_cycle_version then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_VERSION_CONFLICT','message','cycle version changed','actual_version',v_cycle.version); end if;
    if v_cycle.amount_status='confirmed' then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_REOPEN_REQUIRED','message','statement is confirmed; reopen is required before another confirm'); end if;
  end if;
  v_preview:=public.home_build_card_statement_preview(p_actor_id,v_card.id,p_target_fixed_month,p_statement_total,true);
  if not coalesce((v_preview->>'ok')::boolean,false) then return v_preview; end if;
  if not coalesce((v_preview->>'can_confirm')::boolean,false) then
    return jsonb_build_object('ok',false,'code',coalesce(v_preview->'blockers'->>0,'HOME_CARD_STATEMENT_CONFIRM_BLOCKED'),'message','statement confirm is blocked','preview',v_preview);
  end if;
  if not v_cycle_exists then
    perform set_config('home.phase3e_cycle_write','on',true);
    insert into public.home_card_statement_cycles(
      id,user_id,card_instrument_id,target_fixed_month,settlement_currency,
      statement_total_amount,amount_status,household_remainder_fixed_item_id,
      version,confirmed_at,confirmed_by
    ) values (v_cycle_id,p_actor_id,v_card.id,p_target_fixed_month,v_card.settlement_currency,null,'pending',null,0,null,null)
    returning * into v_cycle;
    perform set_config('home.phase3e_cycle_write','off',true);
  end if;
  select * into v_item from public.home_fixed_month_items i where i.id=(v_preview->>'household_remainder_fixed_item_id')::uuid for update;
  v_new_version:=v_cycle.version+1;
  v_action:=case when exists(select 1 from public.home_card_statement_cycle_revisions r where r.cycle_id=v_cycle.id and r.action in ('confirm','reconfirm')) then 'reconfirm' else 'confirm' end;
  perform set_config('home.phase3e_statement_item_write','on',true);
  update public.home_fixed_month_items set amount=(v_preview->>'household_remainder')::numeric where id=v_item.id;
  perform set_config('home.phase3e_statement_item_write','off',true);
  perform set_config('home.phase3e_revision_write','on',true);
  insert into public.home_card_statement_cycle_revisions(
    id,user_id,cycle_id,cycle_version,action,statement_total_amount,school_subtotal_amount,
    household_remainder_amount,school_manifest,school_manifest_fingerprint,
    household_remainder_fixed_item_id,household_item_amount_before,household_item_amount_after,
    actor_id,action_at,reason,operation_idempotency_key,payload_fingerprint,created_at
  ) values (
    v_revision_id,p_actor_id,v_cycle.id,v_new_version,v_action,p_statement_total,
    (v_preview->>'school_subtotal')::numeric,(v_preview->>'household_remainder')::numeric,
    v_preview->'school_manifest',v_preview->>'school_manifest_fingerprint',v_item.id,v_item.amount,
    (v_preview->>'household_remainder')::numeric,p_actor_id,v_now,null,v_key,v_payload_fp,v_now
  );
  perform set_config('home.phase3e_revision_write','off',true);
  perform set_config('home.phase3e_cycle_write','on',true);
  update public.home_card_statement_cycles set
    statement_total_amount=p_statement_total,school_subtotal_amount=(v_preview->>'school_subtotal')::numeric,
    household_remainder_amount=(v_preview->>'household_remainder')::numeric,
    school_manifest_fingerprint=v_preview->>'school_manifest_fingerprint',
    household_remainder_fixed_item_id=v_item.id,amount_status='confirmed',version=v_new_version,
    confirmed_at=v_now,confirmed_by=p_actor_id,current_confirm_revision_id=v_revision_id,
    last_operation_idempotency_key=v_key,last_operation_payload_fingerprint=v_payload_fp,
    last_operation_at=v_now,updated_at=v_now where id=v_cycle.id;
  perform set_config('home.phase3e_cycle_write','off',true);
  return public.home_card_statement_revision_result(v_revision_id)||jsonb_build_object('idempotent',false);
exception when unique_violation then
  select * into v_revision from public.home_card_statement_cycle_revisions r where r.user_id=p_actor_id and r.operation_idempotency_key=v_key;
  if found and v_revision.payload_fingerprint=v_payload_fp and v_revision.action in ('confirm','reconfirm') then
    return public.home_card_statement_revision_result(v_revision.id)||jsonb_build_object('idempotent',true);
  end if;
  raise exception using errcode='55000',message='HOME_CARD_STATEMENT_CONFIRM_IDENTITY_CONFLICT',detail=sqlerrm;
end;
$function$;

create or replace function public.home_confirm_card_statement(
  p_card_instrument_id uuid,p_target_fixed_month date,p_statement_total numeric,
  p_expected_cycle_version bigint,p_operation_idempotency_key text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_AUTH_REQUIRED','message','authenticated user is required'); end if;
  return public.home_apply_card_statement_confirm(v_actor,p_card_instrument_id,p_target_fixed_month,p_statement_total,p_expected_cycle_version,p_operation_idempotency_key);
end;
$function$;

create or replace function public.home_apply_card_statement_reopen(
  p_actor_id uuid,p_card_instrument_id uuid,p_target_fixed_month date,
  p_expected_cycle_version bigint,p_operation_idempotency_key text,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_cycle public.home_card_statement_cycles%rowtype;
  v_confirm public.home_card_statement_cycle_revisions%rowtype;
  v_revision public.home_card_statement_cycle_revisions%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_manifest jsonb;
  v_revision_id uuid:=gen_random_uuid();
  v_new_version bigint;
  v_key text:=nullif(btrim(coalesce(p_operation_idempotency_key,'')),'');
  v_reason text:=nullif(btrim(coalesce(p_reason,'')),'');
  v_payload_fp text;
  v_now timestamptz:=statement_timestamp();
begin
  if p_actor_id is null or p_card_instrument_id is null or p_target_fixed_month is null
     or p_expected_cycle_version is null or p_expected_cycle_version<1 or v_key is null or v_reason is null then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_REOPEN_INPUT_INVALID','message','reopen input and reason are required');
  end if;
  v_payload_fp:=encode(extensions.digest(convert_to(jsonb_build_object(
    'action','reopen','actor_id',p_actor_id,'card_instrument_id',p_card_instrument_id,
    'target_fixed_month',p_target_fixed_month,'expected_cycle_version',p_expected_cycle_version,'reason',v_reason
  )::text,'UTF8'),'sha256'),'hex');
  select * into v_revision from public.home_card_statement_cycle_revisions r
  where r.user_id=p_actor_id and r.operation_idempotency_key=v_key;
  if found then
    if v_revision.payload_fingerprint<>v_payload_fp or v_revision.action<>'reopen' then
      return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_OPERATION_CONFLICT','message','operation key already exists with different payload');
    end if;
    return public.home_card_statement_revision_result(v_revision.id)||jsonb_build_object('idempotent',true,'cycle_status','pending');
  end if;
  select * into v_card from public.home_card_instruments c where c.id=p_card_instrument_id and c.user_id=p_actor_id for update;
  if not found then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CARD_INVALID','message','owned card is required'); end if;
  perform public.home_lock_card_fixed_month(v_card.id,p_target_fixed_month);
  select * into v_revision from public.home_card_statement_cycle_revisions r
  where r.user_id=p_actor_id and r.operation_idempotency_key=v_key;
  if found then
    if v_revision.payload_fingerprint<>v_payload_fp or v_revision.action<>'reopen' then
      return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_OPERATION_CONFLICT','message','operation key already exists with different payload');
    end if;
    return public.home_card_statement_revision_result(v_revision.id)||jsonb_build_object('idempotent',true,'cycle_status','pending');
  end if;
  select * into v_cycle from public.home_card_statement_cycles c
  where c.user_id=p_actor_id and c.card_instrument_id=v_card.id and c.target_fixed_month=p_target_fixed_month for update;
  if not found then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CYCLE_NOT_FOUND','message','statement cycle does not exist'); end if;
  if v_cycle.version<>p_expected_cycle_version then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_VERSION_CONFLICT','message','cycle version changed','actual_version',v_cycle.version); end if;
  if v_cycle.amount_status<>'confirmed' then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_NOT_CONFIRMED','message','only a confirmed statement can be reopened'); end if;
  select * into v_confirm from public.home_card_statement_cycle_revisions r where r.id=v_cycle.current_confirm_revision_id;
  if not found or v_confirm.action not in ('confirm','reconfirm') then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CONFIRM_REVISION_MISSING','message','current confirm revision is missing');
  end if;
  select * into v_item from public.home_fixed_month_items i where i.id=v_cycle.household_remainder_fixed_item_id for update;
  if not found or v_item.amount<>v_confirm.household_item_amount_after or v_item.status<>'unpaid'
     or v_item.linked_jpy_transaction_id is not null or v_item.linked_cny_transaction_id is not null then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_STATE_CHANGED','message','household statement item no longer matches confirmed evidence');
  end if;
  if exists(select 1 from public.home_fixed_advance_payments a
    where a.user_id=p_actor_id and a.month_key=v_item.month_key and a.currency=v_item.currency
      and a.payment_group=coalesce(v_item.payment_group,'未分组')) then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_REOPEN_GROUP_FUNDED','message','advanced or funded group cannot be reopened');
  end if;
  v_manifest:=public.home_build_card_statement_school_manifest(p_actor_id,v_card.id,p_target_fixed_month);
  if not coalesce((v_manifest->>'ok')::boolean,false)
     or v_manifest->>'school_manifest_fingerprint'<>v_confirm.school_manifest_fingerprint then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_REOPEN_SCHOOL_FACT_CHANGED','message','School projection facts changed or entered funding/correction');
  end if;
  v_new_version:=v_cycle.version+1;
  perform set_config('home.phase3e_statement_item_write','on',true);
  update public.home_fixed_month_items set amount=v_confirm.household_item_amount_before where id=v_item.id;
  perform set_config('home.phase3e_statement_item_write','off',true);
  perform set_config('home.phase3e_revision_write','on',true);
  insert into public.home_card_statement_cycle_revisions(
    id,user_id,cycle_id,cycle_version,action,statement_total_amount,school_subtotal_amount,
    household_remainder_amount,school_manifest,school_manifest_fingerprint,
    household_remainder_fixed_item_id,household_item_amount_before,household_item_amount_after,
    actor_id,action_at,reason,operation_idempotency_key,payload_fingerprint,created_at
  ) values (
    v_revision_id,p_actor_id,v_cycle.id,v_new_version,'reopen',v_confirm.statement_total_amount,
    v_confirm.school_subtotal_amount,v_confirm.household_remainder_amount,v_confirm.school_manifest,
    v_confirm.school_manifest_fingerprint,v_item.id,v_item.amount,v_confirm.household_item_amount_before,
    p_actor_id,v_now,v_reason,v_key,v_payload_fp,v_now
  );
  perform set_config('home.phase3e_revision_write','off',true);
  perform set_config('home.phase3e_cycle_write','on',true);
  update public.home_card_statement_cycles set
    statement_total_amount=null,school_subtotal_amount=null,household_remainder_amount=null,
    school_manifest_fingerprint=null,amount_status='pending',version=v_new_version,
    confirmed_at=null,confirmed_by=null,current_confirm_revision_id=null,
    last_operation_idempotency_key=v_key,last_operation_payload_fingerprint=v_payload_fp,
    last_operation_at=v_now,updated_at=v_now where id=v_cycle.id;
  perform set_config('home.phase3e_cycle_write','off',true);
  return public.home_card_statement_revision_result(v_revision_id)||jsonb_build_object('idempotent',false,'cycle_status','pending');
end;
$function$;

create or replace function public.home_reopen_card_statement(
  p_card_instrument_id uuid,p_target_fixed_month date,p_expected_cycle_version bigint,
  p_operation_idempotency_key text,p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare v_actor uuid:=auth.uid();
begin
  if v_actor is null then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_AUTH_REQUIRED','message','authenticated user is required'); end if;
  return public.home_apply_card_statement_reopen(v_actor,p_card_instrument_id,p_target_fixed_month,p_expected_cycle_version,p_operation_idempotency_key,p_reason);
end;
$function$;

-- New fixed requests join the same card/month serialization domain. Exact
-- identity replay remains recoverable; only a genuinely new request is blocked.
create or replace function public.home_create_external_fixed_transaction_request(
  p_user_id uuid,p_external_source text,p_external_event_id uuid,p_external_reference_type text,
  p_external_reference_id uuid,p_request_type text,p_transaction_type text,p_card_instrument_id uuid,
  p_charge_date date,p_suggested_fixed_month date,p_target_fixed_month date,p_funding_date date,
  p_amount numeric,p_currency text,p_idempotency_key text,p_description text default null,
  p_note text default null,p_payload_snapshot jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path=pg_catalog,public
as $function$
declare
  v_card public.home_card_instruments%rowtype; v_schedule record;
  v_existing public.home_external_transaction_requests%rowtype; v_request_id uuid;
  v_source text:=lower(trim(coalesce(p_external_source,'')));
  v_reference_type text:=lower(trim(coalesce(p_external_reference_type,'')));
  v_request_type text:=lower(trim(coalesce(p_request_type,'')));
  v_transaction_type text:=lower(trim(coalesce(p_transaction_type,'')));
  v_currency text:=upper(trim(coalesce(p_currency,'')));
  v_key text:=nullif(trim(coalesce(p_idempotency_key,'')),'');
  v_description text:=coalesce(nullif(trim(coalesce(p_description,'')),''),'School信用卡固定支出请求');
  v_note text:=coalesce(p_note,''); v_payload jsonb:=coalesce(p_payload_snapshot,'{}'::jsonb);
begin
  if coalesce(auth.role(),'')<>'service_role' then return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_SERVICE_ROLE_REQUIRED','message','service_role is required'); end if;
  if p_user_id is null or p_external_event_id is null or p_external_reference_id is null or p_card_instrument_id is null
     or p_charge_date is null or p_suggested_fixed_month is null or p_target_fixed_month is null
     or p_funding_date is null or coalesce(p_amount,0)<=0 or v_key is null then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_INPUT_REQUIRED','message','fixed request input is incomplete');
  end if;
  if v_source<>'aozora_school' or v_reference_type<>'school_expense_records' or v_request_type<>'expense_paid' or v_transaction_type<>'expense' then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_IDENTITY_INVALID','message','fixed request must reference a School expense');
  end if;
  select * into v_existing from public.home_external_transaction_requests r
  where r.idempotency_key=v_key or (r.external_source=v_source and r.external_event_id=p_external_event_id and r.request_type=v_request_type)
  order by (r.idempotency_key=v_key) desc limit 1;
  if found then
    if v_existing.user_id is distinct from p_user_id or v_existing.payment_route is distinct from 'fixed_credit_card'
       or v_existing.external_source is distinct from v_source or v_existing.external_event_id is distinct from p_external_event_id
       or v_existing.external_reference_type is distinct from v_reference_type or v_existing.external_reference_id is distinct from p_external_reference_id
       or v_existing.request_type is distinct from v_request_type or v_existing.transaction_type is distinct from v_transaction_type
       or v_existing.currency is distinct from v_currency or v_existing.amount is distinct from p_amount
       or v_existing.account_id is not null or v_existing.funding_account_id is not null
       or v_existing.card_instrument_id is distinct from p_card_instrument_id or v_existing.charge_date is distinct from p_charge_date
       or v_existing.suggested_fixed_month is distinct from p_suggested_fixed_month or v_existing.target_fixed_month is distinct from p_target_fixed_month
       or v_existing.fixed_month_override_reason is not null or v_existing.payload_snapshot is distinct from v_payload then
      return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_IDENTITY_PAYLOAD_CONFLICT','message','fixed request identity already exists with different payload','request_id',v_existing.id);
    end if;
    return jsonb_build_object('ok',true,'inserted',false,'request_id',v_existing.id,'status',v_existing.status,'payment_route',v_existing.payment_route,'created_transaction_id',v_existing.created_transaction_id,'message','fixed request already exists');
  end if;
  select * into v_card from public.home_card_instruments where id=p_card_instrument_id for key share;
  if not found or v_card.user_id is distinct from p_user_id or v_card.settlement_currency is distinct from v_currency or v_card.is_active is not true then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_CARD_INVALID','message','fixed request card is missing, inactive, wrong owner, or wrong currency');
  end if;
  if v_card.is_school_fixed_route_enabled is not true then return jsonb_build_object('ok',false,'code','HOME_FIXED_CARD_ROUTE_DISABLED','message','School fixed credit-card route is disabled'); end if;
  select * into v_schedule from public.home_calculate_card_fixed_schedule(p_card_instrument_id,p_charge_date);
  if p_suggested_fixed_month is distinct from v_schedule.suggested_fixed_month or p_target_fixed_month is distinct from v_schedule.suggested_fixed_month or p_funding_date is distinct from v_schedule.funding_date then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_SCHEDULE_MISMATCH','message','School fixed schedule does not match Cash DB authority');
  end if;
  perform public.home_lock_card_fixed_month(v_card.id,p_target_fixed_month);
  if exists(select 1 from public.home_card_statement_cycles c where c.user_id=p_user_id and c.card_instrument_id=v_card.id and c.target_fixed_month=p_target_fixed_month and c.amount_status='confirmed') then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_REOPEN_REQUIRED','message','statement is confirmed; reopen before creating a new fixed request');
  end if;
  if v_payload->>'external_source' is distinct from v_source or v_payload->>'external_reference_type' is distinct from v_reference_type
     or v_payload->>'external_reference_id' is distinct from p_external_reference_id::text or v_payload->>'request_type' is distinct from v_request_type
     or v_payload->>'transaction_type' is distinct from v_transaction_type or v_payload->>'payment_route' is distinct from 'fixed_credit_card'
     or v_payload->>'card_instrument_id' is distinct from p_card_instrument_id::text or v_payload->>'charge_date' is distinct from p_charge_date::text
     or v_payload->>'suggested_fixed_month' is distinct from p_suggested_fixed_month::text or v_payload->>'target_fixed_month' is distinct from p_target_fixed_month::text
     or v_payload->>'funding_date' is distinct from p_funding_date::text or coalesce(v_payload->>'school_attempt_payload_fingerprint','') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_PAYLOAD_MISMATCH','message','fixed request payload snapshot does not match canonical input');
  end if;
  select * into v_existing from public.home_external_transaction_requests r
  where r.external_source=v_source and r.external_reference_type=v_reference_type and r.external_reference_id=p_external_reference_id
    and r.request_type=v_request_type and r.status in ('pending','approved') limit 1;
  if found then return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_ACTIVE_REFERENCE_EXISTS','message','active or approved request already exists for this School expense','request_id',v_existing.id,'status',v_existing.status); end if;
  insert into public.home_external_transaction_requests(
    user_id,external_source,external_event_id,external_reference_type,external_reference_id,request_type,transaction_type,
    currency,amount,account_id,transacted_at,status,idempotency_key,payload_snapshot,description,note,accounting_scope,
    payment_route,card_instrument_id,charge_date,suggested_fixed_month,target_fixed_month,fixed_month_override_reason,
    funding_account_id,fixed_projection_id,projection_status
  ) values (
    p_user_id,v_source,p_external_event_id,v_reference_type,p_external_reference_id,v_request_type,v_transaction_type,
    v_currency,p_amount,null,p_charge_date,'pending',v_key,v_payload,v_description,v_note,'school','fixed_credit_card',
    p_card_instrument_id,p_charge_date,p_suggested_fixed_month,p_target_fixed_month,null,null,null,'pending'
  ) returning id into v_request_id;
  return jsonb_build_object('ok',true,'inserted',true,'request_id',v_request_id,'status','pending','payment_route','fixed_credit_card','message','fixed request created');
exception when unique_violation then
  select * into v_existing from public.home_external_transaction_requests r
  where r.idempotency_key=v_key or (r.external_source=v_source and r.external_event_id=p_external_event_id and r.request_type=v_request_type)
     or (r.external_source=v_source and r.external_reference_type=v_reference_type and r.external_reference_id=p_external_reference_id and r.request_type=v_request_type and r.status in ('pending','approved'))
  order by (r.idempotency_key=v_key) desc limit 1;
  if found and v_existing.user_id is not distinct from p_user_id and v_existing.payment_route is not distinct from 'fixed_credit_card'
     and v_existing.external_event_id is not distinct from p_external_event_id and v_existing.external_reference_type is not distinct from v_reference_type
     and v_existing.external_reference_id is not distinct from p_external_reference_id and v_existing.request_type is not distinct from v_request_type
     and v_existing.transaction_type is not distinct from v_transaction_type and v_existing.currency is not distinct from v_currency
     and v_existing.amount is not distinct from p_amount and v_existing.account_id is null and v_existing.funding_account_id is null
     and v_existing.card_instrument_id is not distinct from p_card_instrument_id and v_existing.charge_date is not distinct from p_charge_date
     and v_existing.suggested_fixed_month is not distinct from p_suggested_fixed_month and v_existing.target_fixed_month is not distinct from p_target_fixed_month
     and v_existing.payload_snapshot is not distinct from v_payload then
    return jsonb_build_object('ok',true,'inserted',false,'request_id',v_existing.id,'status',v_existing.status,'payment_route',v_existing.payment_route,'created_transaction_id',v_existing.created_transaction_id,'message','fixed request already exists');
  end if;
  return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_IDENTITY_PAYLOAD_CONFLICT','message','fixed request identity already exists with different payload','request_id',v_existing.id);
end;
$function$;

alter function public.home_guard_card_statement_revision() owner to postgres;
alter function public.home_validate_card_statement_cycle() owner to postgres;
alter function public.home_guard_projection_linked_fixed_item() owner to postgres;
alter function public.home_build_card_statement_school_manifest(uuid,uuid,date) owner to postgres;
alter function public.home_build_card_statement_preview(uuid,uuid,date,numeric,boolean) owner to postgres;
alter function public.home_preview_card_statement(uuid,date,numeric) owner to postgres;
alter function public.home_card_statement_revision_result(uuid) owner to postgres;
alter function public.home_apply_card_statement_confirm(uuid,uuid,date,numeric,bigint,text) owner to postgres;
alter function public.home_confirm_card_statement(uuid,date,numeric,bigint,text) owner to postgres;
alter function public.home_apply_card_statement_reopen(uuid,uuid,date,bigint,text,text) owner to postgres;
alter function public.home_reopen_card_statement(uuid,date,bigint,text,text) owner to postgres;
alter function public.home_create_external_fixed_transaction_request(uuid,text,uuid,text,uuid,text,text,uuid,date,date,date,date,numeric,text,text,text,text,jsonb) owner to postgres;

revoke all on function public.home_guard_card_statement_revision() from public,anon,authenticated,service_role;
revoke all on function public.home_validate_card_statement_cycle() from public,anon,authenticated,service_role;
revoke all on function public.home_guard_projection_linked_fixed_item() from public,anon,authenticated,service_role;
revoke all on function public.home_build_card_statement_school_manifest(uuid,uuid,date) from public,anon,authenticated,service_role;
revoke all on function public.home_build_card_statement_preview(uuid,uuid,date,numeric,boolean) from public,anon,authenticated,service_role;
revoke all on function public.home_card_statement_revision_result(uuid) from public,anon,authenticated,service_role;
revoke all on function public.home_apply_card_statement_confirm(uuid,uuid,date,numeric,bigint,text) from public,anon,authenticated,service_role;
revoke all on function public.home_apply_card_statement_reopen(uuid,uuid,date,bigint,text,text) from public,anon,authenticated,service_role;
revoke all on function public.home_preview_card_statement(uuid,date,numeric) from public,anon,authenticated,service_role;
grant execute on function public.home_preview_card_statement(uuid,date,numeric) to authenticated;
revoke all on function public.home_confirm_card_statement(uuid,date,numeric,bigint,text) from public,anon,authenticated,service_role;
grant execute on function public.home_confirm_card_statement(uuid,date,numeric,bigint,text) to authenticated;
revoke all on function public.home_reopen_card_statement(uuid,date,bigint,text,text) from public,anon,authenticated,service_role;
grant execute on function public.home_reopen_card_statement(uuid,date,bigint,text,text) to authenticated;

comment on table public.home_card_statement_cycle_revisions is 'Phase 3E append-only statement confirm/reopen/reconfirm evidence. No ledger or funding fact.';
comment on function public.home_preview_card_statement(uuid,date,numeric) is 'Phase 3E authenticated read-only DB-authoritative statement preview.';
comment on function public.home_confirm_card_statement(uuid,date,numeric,bigint,text) is 'Phase 3E authenticated atomic statement confirm/reconfirm writer.';
comment on function public.home_reopen_card_statement(uuid,date,bigint,text,text) is 'Phase 3E authenticated atomic statement reopen writer; restores the prior household item amount.';

-- Existing generic fixed-item writers keep their signatures and legacy ACLs,
-- but cycle-linked items must fail before any side effect.
create or replace function public.home_create_fixed_advance_payment(
  p_month_key text,p_currency text,p_payment_group text,p_account_id uuid,p_transacted_at date,p_note text default null
)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public
as $function$
declare v_group text:=coalesce(nullif(trim(p_payment_group),''),'未分组'); v_amount numeric:=0;
  v_transaction_id uuid:=gen_random_uuid(); v_advance_id uuid:=gen_random_uuid(); v_item_count integer:=0;
begin
  if p_currency<>'JPY' then return jsonb_build_object('ok',false,'message','固定垫付目前只支持日元。'); end if;
  if to_char(p_transacted_at,'YYYY-MM')<>p_month_key then return jsonb_build_object('ok',false,'message','垫付日期必须在当前账期内。'); end if;
  if not exists(select 1 from public.home_accounts where id=p_account_id and user_id=auth.uid() and currency=p_currency and is_active) then return jsonb_build_object('ok',false,'message','没有找到可使用的日元垫付账户。'); end if;
  if exists(select 1 from public.home_card_statement_cycles c join public.home_card_instruments card on card.id=c.card_instrument_id join public.home_payment_channels ch on ch.id=card.funding_payment_channel_id
    where c.user_id=auth.uid() and to_char(c.target_fixed_month,'YYYY-MM')=p_month_key and c.settlement_currency=p_currency and coalesce(ch.name,'未分组')=v_group and c.household_remainder_fixed_item_id is not null) then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_GROUP_ADVANCE_FORBIDDEN','message','该支付分组包含信用卡statement关联固定项，Phase 3F前不能垫付。');
  end if;
  if exists(select 1 from public.home_external_fixed_payment_projections p join public.home_fixed_month_items i on i.id=p.fixed_month_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction='expense' and coalesce(i.payment_group,'未分组')=v_group) then
    return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_ADVANCE_FORBIDDEN','message','该支付分组包含School信用卡projection固定项，Phase 3F前不能垫付。');
  end if;
  if exists(select 1 from public.home_fixed_advance_payments where user_id=auth.uid() and month_key=p_month_key and currency=p_currency and payment_group=v_group) then return jsonb_build_object('ok',false,'message','本账期该支付分组已经生成过垫付记录。'); end if;
  select count(*),public.home_round_up_1000(coalesce(sum(amount),0)) into v_item_count,v_amount from public.home_fixed_month_items where user_id=auth.uid() and month_key=p_month_key and currency=p_currency and direction='expense' and linked_jpy_transaction_id is null and coalesce(payment_group,'未分组')=v_group;
  if v_item_count<=0 or v_amount<=0 then return jsonb_build_object('ok',false,'message','该支付分组没有可垫付的固定支出。'); end if;
  insert into public.home_jpy_transactions(id,user_id,transaction_type,account_id,transfer_account_id,currency,transacted_at,amount,description,note,created_at)
  values(v_transaction_id,auth.uid(),'fixed_advance_out',p_account_id,null,p_currency,p_transacted_at,v_amount,format('%s 固定支出垫付',v_group),coalesce(p_note,''),now());
  insert into public.home_fixed_advance_payments(id,user_id,month_key,currency,payment_group,account_id,amount,status,paid_at,out_transaction_id,note,created_at)
  values(v_advance_id,auth.uid(),p_month_key,p_currency,v_group,p_account_id,v_amount,'pending',p_transacted_at,v_transaction_id,coalesce(p_note,''),now());
  update public.home_fixed_month_items set status='paid' where user_id=auth.uid() and month_key=p_month_key and currency=p_currency and direction='expense' and linked_jpy_transaction_id is null and coalesce(payment_group,'未分组')=v_group;
  return jsonb_build_object('ok',true,'message',format('%s 固定支出已垫付，金额 %s。',v_group,v_amount),'advance_id',v_advance_id,'jpy_transaction_id',v_transaction_id,'amount',v_amount,'item_count',v_item_count);
end;
$function$;

create or replace function public.home_update_fixed_month_item_status(p_item_id uuid,p_status text)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public
as $function$
declare v_item public.home_fixed_month_items%rowtype; v_check jsonb;
begin
  if p_status not in ('unpaid','paid','settled') then return jsonb_build_object('ok',false,'message','固定项状态无效。'); end if;
  select * into v_item from public.home_fixed_month_items where id=p_item_id and user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'message','没有找到可更新的固定项。'); end if;
  if exists(select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=v_item.id) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN','message','School信用卡projection固定项不能使用普通状态writer。'); end if;
  if exists(select 1 from public.home_card_statement_cycles c where c.household_remainder_fixed_item_id=v_item.id) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_STATUS_FORBIDDEN','message','信用卡statement关联固定项不能使用普通状态writer。'); end if;
  if v_item.linked_jpy_transaction_id is not null then return jsonb_build_object('ok',false,'message','调拨记录状态固定为已付。'); end if;
  if v_item.direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=v_item.month_key and ap.currency=v_item.currency and ap.payment_group=coalesce(v_item.payment_group,'未分组')) then return jsonb_build_object('ok',false,'message','该固定支出分组已进入垫付流程，状态不能单独修改。'); end if;
  if v_item.direction='expense' and p_status in ('paid','settled') then v_check:=public.home_check_fixed_paid_balance(v_item.month_key,v_item.currency,p_item_id,p_status); if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if; end if;
  update public.home_fixed_month_items set status=p_status where id=p_item_id and user_id=auth.uid() and linked_jpy_transaction_id is null;
  return jsonb_build_object('ok',true,'message','固定项状态已更新。','updated_count',1);
end;
$function$;

create or replace function public.home_update_fixed_month_items_status(p_month_key text,p_currency text,p_direction text,p_status text)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public
as $function$
declare v_updated_count integer:=0; v_check jsonb;
begin
  if p_direction not in ('income','expense') then return jsonb_build_object('ok',false,'message','固定项收支方向无效。'); end if;
  if p_status not in ('unpaid','paid','settled') then return jsonb_build_object('ok',false,'message','固定项状态无效。'); end if;
  if exists(select 1 from public.home_external_fixed_payment_projections p join public.home_fixed_month_items i on i.id=p.fixed_month_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含School信用卡projection固定项，不能使用批量状态writer。'); end if;
  if exists(select 1 from public.home_card_statement_cycles c join public.home_fixed_month_items i on i.id=c.household_remainder_fixed_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含信用卡statement关联固定项，不能使用批量状态writer。'); end if;
  if p_direction='expense' and p_status in ('paid','settled') then v_check:=public.home_check_fixed_paid_balance(p_month_key,p_currency,null,null,p_direction,p_status); if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if; end if;
  update public.home_fixed_month_items i set status=p_status where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction and i.linked_jpy_transaction_id is null and not(p_direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=i.month_key and ap.currency=i.currency and ap.payment_group=coalesce(i.payment_group,'未分组')));
  get diagnostics v_updated_count=row_count;
  return jsonb_build_object('ok',true,'message','固定项状态已批量更新。','updated_count',v_updated_count);
end;
$function$;

create or replace function public.home_delete_fixed_month_item(p_item_id uuid)
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public
as $function$
declare v_item public.home_fixed_month_items%rowtype; v_linked_jpy_transaction_id uuid; v_deleted_count integer:=0; v_linked_deleted boolean:=false; v_reset jsonb:=jsonb_build_object('reset_expense_status',false); v_message text:='已删除。';
begin
  select * into v_item from public.home_fixed_month_items where id=p_item_id and user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'message','没有找到可删除的固定项。'); end if;
  if exists(select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=v_item.id) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN','message','School信用卡projection固定项不能使用普通删除writer。'); end if;
  if exists(select 1 from public.home_card_statement_cycles c where c.household_remainder_fixed_item_id=v_item.id) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_DELETE_FORBIDDEN','message','信用卡statement关联固定项不能使用普通删除writer。'); end if;
  if v_item.direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=v_item.month_key and ap.currency=v_item.currency and ap.payment_group=coalesce(v_item.payment_group,'未分组')) then return jsonb_build_object('ok',false,'message','该固定支出分组已进入垫付流程，不能删除单条固定项。'); end if;
  v_linked_jpy_transaction_id:=public.home_resolve_fixed_transfer_jpy_id(v_item);
  if v_linked_jpy_transaction_id is not null then delete from public.home_jpy_transactions where id=v_linked_jpy_transaction_id and user_id=auth.uid(); get diagnostics v_deleted_count=row_count; v_linked_deleted:=v_deleted_count>0; if not v_linked_deleted then v_message:='已删除固定项，但链接的日元流水不存在。'; end if;
  elsif v_item.name in ('固定赤字补充','固定盈余转入') and v_item.template_id is null then v_message:='已删除固定项，但旧数据链接不完整，未能唯一匹配日元流水。'; end if;
  delete from public.home_fixed_month_items where id=v_item.id and user_id=auth.uid();
  v_reset:=public.home_reset_plain_fixed_expenses_if_deficit(v_item.month_key,v_item.currency);
  return jsonb_build_object('ok',true,'deleted_count',1,'linked_deleted',v_linked_deleted,'reset_expense_status',coalesce((v_reset->>'reset_expense_status')::boolean,false),'message',case when v_linked_deleted and coalesce((v_reset->>'reset_expense_status')::boolean,false) then '已同步删除日元流水；删除后重新出现赤字，普通固定支出已改回未付。' when v_linked_deleted then '已同步删除日元流水。' when coalesce((v_reset->>'reset_expense_status')::boolean,false) then v_message||' 删除后重新出现赤字，普通固定支出已改回未付。' else v_message end);
end;
$function$;

create or replace function public.home_sync_fixed_month_items(p_month_key text,p_currency text default 'JPY')
returns jsonb language plpgsql security invoker set search_path=pg_catalog,public
as $function$
declare v_updated_count integer:=0;
begin
  if exists(select 1 from public.home_external_fixed_payment_projections p join public.home_fixed_month_items i on i.id=p.fixed_month_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_SYNC_FORBIDDEN','message','范围内包含School信用卡projection固定项，不能使用普通月份/模板同步writer。'); end if;
  if exists(select 1 from public.home_card_statement_cycles c join public.home_fixed_month_items i on i.id=c.household_remainder_fixed_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_SYNC_FORBIDDEN','message','范围内包含信用卡statement关联固定项，不能使用普通月份/模板同步writer。'); end if;
  with month_context as(select extract(year from month_start)::int year_no,extract(month from month_start)::int month_no,extract(day from(month_start+interval '1 month - 1 day'))::int days_in_month from(select to_date(p_month_key||'-01','YYYY-MM-DD') month_start)d),
  updated_items as(update public.home_fixed_month_items i set direction=t.direction,name=t.name,amount=t.default_amount,account_id=t.default_account_id,payment_group=t.payment_group,due_date=case when t.due_day is null then null else make_date(c.year_no,c.month_no,least(t.due_day,c.days_in_month)) end,term_no=case when t.fixed_type='short_term' and t.start_month is not null and t.total_terms is not null then((substring(p_month_key,1,4)::int-substring(t.start_month,1,4)::int)*12+(substring(p_month_key,6,2)::int-substring(t.start_month,6,2)::int)+1) else null end,total_terms=case when t.fixed_type='short_term' then t.total_terms else null end from public.home_fixed_templates t cross join month_context c where i.template_id=t.id and i.user_id=auth.uid() and t.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and t.currency=p_currency returning i.id)
  select count(*) into v_updated_count from updated_items;
  return jsonb_build_object('updated_count',v_updated_count);
end;
$function$;

alter function public.home_create_fixed_advance_payment(text,text,text,uuid,date,text) owner to postgres;
alter function public.home_update_fixed_month_item_status(uuid,text) owner to postgres;
alter function public.home_update_fixed_month_items_status(text,text,text,text) owner to postgres;
alter function public.home_delete_fixed_month_item(uuid) owner to postgres;
alter function public.home_sync_fixed_month_items(text,text) owner to postgres;
