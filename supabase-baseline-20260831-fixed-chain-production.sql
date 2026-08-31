-- 固定信用卡链路 —— 生产定义基线快照
--
-- 导出时间：2026-08-31（从生产库 pg_get_functiondef / pg_get_triggerdef 读出）
-- 用途：Phase 3F（projection 固定项还款状态推进）的改动基线
--
-- ===========================================================================
-- 为什么需要这个文件
-- ===========================================================================
--
-- 磁盘上的 supabase-update-20260819-phase3c3b / 3d / 3e 三个文件是 08-19 的
-- 历史快照，且长期未纳入 git（.gitignore 的 *.sql 规则）。经与生产逐函数比对，
-- 其中 home_update_fixed_month_item_status 已经过时：
--
--   08-19 磁盘版：  if exists (select 1 from home_external_fixed_payment_projections ...)
--                   if exists (select 1 from home_card_statement_cycles ...)
--   当前生产版：    if home_fixed_item_has_external_projection(v_item.id)
--                   if home_fixed_item_has_card_statement(v_item.id)
--
-- 差异来自 08-24 的 invoker privilege 修复：原先在 SECURITY INVOKER 函数里直接
-- 查封闭的 projection / statement 表会撞 42501，故抽成两个 SECURITY DEFINER
-- helper 来读。
--
-- 直接拿 08-19 快照当基线去改，会把这次修复覆盖回去。因此以本文件为准。
--
-- 其余五个函数经比对与生产一致（忽略空白与 := 排版差异）。
--
-- ===========================================================================
-- 本文件的性质
-- ===========================================================================
--
-- 这是【只读快照】，不是可重跑的 migration：
--   * 内容为生产实际定义的原样导出，未经改写
--   * 不含建表语句、约束、ACL、索引、数据迁移
--   * 重建环境不能只跑这一个文件
--
-- 已知仍在版本控制之外的对象（本次未导出，需要时另行反查生产）：
--   * home_external_fixed_payment_projections 建表语句 —— 磁盘全项目均无定义
--   * home_fixed_item_has_external_projection / home_fixed_item_has_card_statement
--     两个 helper 的定义
--   * Phase 3C3-B / 3D / 3E 的表、约束、索引、ACL
--
-- ===========================================================================
-- Phase 3F 相关的关键约束（供设计时参考，非本文件内容）
-- ===========================================================================
--
-- home_external_fixed_projections_funding_lifecycle_check：
--   funding_status='funded' 要求 funding_account_id / funding_transaction_id /
--   funded_at 三者均非空。本系统的还款动作不产生资金交易记录，因此 Phase 3F
--   只推进 home_fixed_month_items.status，projection 保持 unfunded。
--
-- home_external_fixed_projections_amount_check
-- home_external_fixed_projections_same_currency_check：
--   两者强制 original_amount = settlement_amount 且 original_currency =
--   settlement_currency，即当前设计不支持跨币种。工行卡（JPY 消费 / CNY 结算）
--   需要先放开这两条约束，属阶段二范围。
--
-- ===========================================================================


-- ---------------------------------------------------------------------------
-- 触发器定义（home_fixed_month_items）
-- ---------------------------------------------------------------------------
-- CREATE TRIGGER home_fixed_month_items_assign_accounting_scope BEFORE INSERT ON public.home_fixed_month_items FOR EACH ROW EXECUTE FUNCTION home_assign_accounting_scope()
-- CREATE TRIGGER home_fixed_month_items_projection_guard BEFORE DELETE OR UPDATE ON public.home_fixed_month_items FOR EACH ROW EXECUTE FUNCTION home_guard_projection_linked_fixed_item()
-- CREATE TRIGGER zz_home_fixed_month_items_delete_contract_guard BEFORE DELETE ON public.home_fixed_month_items FOR EACH ROW EXECUTE FUNCTION home_guard_fixed_month_item_delete_contract()


-- ---------------------------------------------------------------------------
-- home_guard_projection_linked_fixed_item
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_guard_projection_linked_fixed_item()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
$function$



-- ---------------------------------------------------------------------------
-- home_update_fixed_month_item_status
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_update_fixed_month_item_status(p_item_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_item public.home_fixed_month_items%rowtype; v_check jsonb;
begin
  if p_status not in ('unpaid','paid','settled') then return jsonb_build_object('ok',false,'message','固定项状态无效。'); end if;
  select * into v_item from public.home_fixed_month_items where id=p_item_id and user_id=auth.uid();
  if not found then return jsonb_build_object('ok',false,'message','没有找到可更新的固定项。'); end if;
  if public.home_fixed_item_has_external_projection(v_item.id) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN','message','School信用卡projection固定项不能使用普通状态writer。'); end if;
  if public.home_fixed_item_has_card_statement(v_item.id) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_STATUS_FORBIDDEN','message','信用卡statement关联固定项不能使用普通状态writer。'); end if;
  if v_item.linked_jpy_transaction_id is not null then return jsonb_build_object('ok',false,'message','调拨记录状态固定为已付。'); end if;
  if v_item.direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=v_item.month_key and ap.currency=v_item.currency and ap.payment_group=coalesce(v_item.payment_group,'未分组')) then return jsonb_build_object('ok',false,'message','该固定支出分组已进入垫付流程，状态不能单独修改。'); end if;
  if v_item.direction='expense' and p_status in ('paid','settled') then v_check:=public.home_check_fixed_paid_balance(v_item.month_key,v_item.currency,p_item_id,p_status); if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if; end if;
  update public.home_fixed_month_items set status=p_status where id=p_item_id and user_id=auth.uid() and linked_jpy_transaction_id is null;
  return jsonb_build_object('ok',true,'message','固定项状态已更新。','updated_count',1);
end;
$function$



-- ---------------------------------------------------------------------------
-- home_update_cny_fixed_item_status
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_update_cny_fixed_item_status(p_item_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_item home_fixed_month_items%rowtype;
  v_sync jsonb;
begin
  if p_status not in ('unpaid', 'paid', 'settled') then
    return jsonb_build_object('ok', false, 'message', '人民币固定项状态无效。');
  end if;

  select *
  into v_item
  from home_fixed_month_items
  where id = p_item_id
    and user_id = auth.uid()
    and currency = 'CNY';

  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到可更新的人民币固定项。');
  end if;

  if p_status = 'unpaid' then
    if v_item.linked_cny_transaction_id is not null then
      delete from home_cny_transactions
      where id = v_item.linked_cny_transaction_id
        and user_id = auth.uid();
    end if;

    update home_fixed_month_items
    set
      status = 'unpaid',
      linked_cny_transaction_id = null
    where id = v_item.id
      and user_id = auth.uid();

    return jsonb_build_object('ok', true, 'message', '人民币固定项已改为未付，并已撤销统一流水。');
  end if;

  if v_item.account_id is null then
    return jsonb_build_object('ok', false, 'message', '人民币固定项需要先选择账户，才能改为已付或已结清。');
  end if;

  if not exists (
    select 1
    from home_accounts
    where id = v_item.account_id
      and user_id = auth.uid()
      and currency = 'CNY'
      and is_active
  ) then
    return jsonb_build_object('ok', false, 'message', '人民币固定项账户无效或已停用。');
  end if;

  update home_fixed_month_items
  set status = p_status
  where id = v_item.id
    and user_id = auth.uid();

  v_sync := home_upsert_cny_fixed_transaction(v_item.id);
  if not coalesce((v_sync ->> 'ok')::boolean, false) then
    return v_sync;
  end if;

  return jsonb_build_object('ok', true, 'message', '人民币固定项已结算并同步到统一流水。');
end;
$function$



-- ---------------------------------------------------------------------------
-- home_reset_plain_fixed_expenses_if_deficit
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_reset_plain_fixed_expenses_if_deficit(p_month_key text, p_currency text DEFAULT 'JPY'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_check jsonb;
  v_updated_count integer := 0;
begin
  v_check := public.home_check_fixed_paid_balance(p_month_key, p_currency);

  if coalesce((v_check ->> 'ok')::boolean, false) then
    return jsonb_build_object(
      'reset_expense_status', false,
      'reset_count', 0,
      'message', '删除后固定收支仍满足已付结算条件。'
    );
  end if;

  update public.home_fixed_month_items i
  set status = 'unpaid'
  where i.user_id = auth.uid()
    and i.month_key = p_month_key
    and i.currency = p_currency
    and i.direction = 'expense'
    and i.linked_jpy_transaction_id is null
    and i.status <> 'unpaid'
    and not exists (
      select 1
      from public.home_fixed_advance_payments ap
      where ap.user_id = auth.uid()
        and ap.month_key = i.month_key
        and ap.currency = i.currency
        and ap.payment_group = coalesce(i.payment_group, '未分组')
    );

  get diagnostics v_updated_count = row_count;

  return jsonb_build_object(
    'reset_expense_status', true,
    'reset_count', v_updated_count,
    'message', '删除后固定收支重新出现赤字，未进入垫付流程的普通固定支出已改回未付。'
  );
end;
$function$



-- ---------------------------------------------------------------------------
-- home_create_external_fixed_transaction_request
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_create_external_fixed_transaction_request(p_user_id uuid, p_external_source text, p_external_event_id uuid, p_external_reference_type text, p_external_reference_id uuid, p_request_type text, p_transaction_type text, p_card_instrument_id uuid, p_charge_date date, p_suggested_fixed_month date, p_target_fixed_month date, p_funding_date date, p_amount numeric, p_currency text, p_idempotency_key text, p_description text DEFAULT NULL::text, p_note text DEFAULT NULL::text, p_payload_snapshot jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
$function$



-- ---------------------------------------------------------------------------
-- home_apply_external_fixed_transaction_approval
-- ---------------------------------------------------------------------------

CREATE OR REPLACE FUNCTION public.home_apply_external_fixed_transaction_approval(p_request_id uuid, p_actor_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
$function$

