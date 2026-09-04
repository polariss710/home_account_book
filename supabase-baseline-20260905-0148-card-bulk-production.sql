-- queried_at_jst: 2026-09-05T01:48:27.209499
-- Production rollback baseline; export only, not executed.

-- home_calculate_card_fixed_schedule(uuid,date)
-- {"name": "home_calculate_card_fixed_schedule", "owner": "postgres", "proacl": ["postgres=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": false, "signature": "home_calculate_card_fixed_schedule(uuid,date)", "prosrc_md5": "534a2f70fdbb76bfa176e5427edb7919"}
CREATE OR REPLACE FUNCTION public.home_calculate_card_fixed_schedule(p_card_instrument_id uuid, p_charge_date date)
 RETURNS TABLE(suggested_fixed_month date, funding_date date)
 LANGUAGE plpgsql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_statement_month date;
  v_funding_month date;
  v_last_day integer;
begin
  if p_card_instrument_id is null or p_charge_date is null then
    raise exception using errcode = '22004', message = 'CARD_SCHEDULE_INPUT_REQUIRED';
  end if;

  select * into v_card
  from public.home_card_instruments
  where id = p_card_instrument_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'CARD_INSTRUMENT_NOT_FOUND';
  end if;

  -- 账单月：刷卡日落在 cutoff 之前（含或不含由 cutoff_inclusive 决定）则计入当月
  -- 账单，否则进入下一期。此段与基线逐字相同。
  if (v_card.cutoff_inclusive and extract(day from p_charge_date)::integer <= v_card.cutoff_day)
     or (not v_card.cutoff_inclusive and extract(day from p_charge_date)::integer < v_card.cutoff_day) then
    v_statement_month := date_trunc('month', p_charge_date)::date;
  else
    v_statement_month := (date_trunc('month', p_charge_date) + interval '1 month')::date;
  end if;

  -- 还款月 = 账单月 + offset。西武卡 offset=0（当月扣），工行卡 offset=1（次月还）。
  v_funding_month := (
    v_statement_month + make_interval(months => coalesce(v_card.funding_month_offset, 0))
  )::date;

  v_last_day := extract(day from (v_funding_month + interval '1 month - 1 day'))::integer;

  -- 两个输出都由还款月决定。month_key 是还款月，不是账单月。
  suggested_fixed_month := v_funding_month;
  funding_date := make_date(
    extract(year from v_funding_month)::integer,
    extract(month from v_funding_month)::integer,
    least(v_card.funding_day, v_last_day)
  );
  return next;
end;
$function$;


-- home_check_fixed_paid_balance(text,text,uuid,text,text,text)
-- {"name": "home_check_fixed_paid_balance", "owner": "postgres", "proacl": ["=X/postgres", "postgres=X/postgres", "anon=X/postgres", "authenticated=X/postgres", "service_role=X/postgres"], "proconfig": null, "prosecdef": false, "signature": "home_check_fixed_paid_balance(text,text,uuid,text,text,text)", "prosrc_md5": "50b35cf617c15da7ee4988926fe5b16f"}
CREATE OR REPLACE FUNCTION public.home_check_fixed_paid_balance(p_month_key text, p_currency text DEFAULT 'JPY'::text, p_target_item_id uuid DEFAULT NULL::uuid, p_target_status text DEFAULT NULL::text, p_bulk_direction text DEFAULT NULL::text, p_bulk_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_actual_income numeric := 0;
  v_actual_expense numeric := 0;
begin
  if p_target_status is not null and p_target_status not in ('unpaid', 'paid', 'settled') then
    return jsonb_build_object('ok', false, 'message', '固定项状态无效。');
  end if;

  if p_bulk_status is not null and p_bulk_status not in ('unpaid', 'paid', 'settled') then
    return jsonb_build_object('ok', false, 'message', '固定项状态无效。');
  end if;

  if p_bulk_direction is not null and p_bulk_direction not in ('income', 'expense') then
    return jsonb_build_object('ok', false, 'message', '固定项收支方向无效。');
  end if;

  with month_items as (
    select
      i.*,
      case
        when i.linked_jpy_transaction_id is not null then 'paid'
        when p_target_item_id is not null and i.id = p_target_item_id then p_target_status
        when p_bulk_direction is not null and i.direction = p_bulk_direction then p_bulk_status
        else i.status
      end as next_status
    from home_fixed_month_items i
    where i.user_id = auth.uid()
      and i.month_key = p_month_key
      and i.currency = p_currency
  ),
  paid_expense_groups as (
    select
      coalesce(payment_group, '未分组') as payment_group,
      home_round_up_1000(coalesce(sum(amount), 0)) as paid_amount
    from month_items
    where direction = 'expense'
      and next_status in ('paid', 'settled')
    group by coalesce(payment_group, '未分组')
  )
  select
    coalesce(sum(amount) filter (where direction = 'income' and next_status in ('paid', 'settled')), 0),
    coalesce((select sum(paid_amount) from paid_expense_groups), 0)
  into v_actual_income, v_actual_expense
  from month_items;

  if v_actual_income < v_actual_expense then
    return jsonb_build_object(
      'ok', false,
      'message', format('当前收入不足，请补充赤字后结算。当前已收 %s，取整后已付支出 %s。', v_actual_income, v_actual_expense),
      'actual_income', v_actual_income,
      'actual_expense', v_actual_expense
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'message', '收入足以覆盖已付固定支出。',
    'actual_income', v_actual_income,
    'actual_expense', v_actual_expense
  );
end;
$function$;


-- home_confirm_projection_fixed_item_status(uuid,text)
-- {"name": "home_confirm_projection_fixed_item_status", "owner": "postgres", "proacl": ["postgres=X/postgres", "authenticated=X/postgres", "service_role=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": true, "signature": "home_confirm_projection_fixed_item_status(uuid,text)", "prosrc_md5": "eeb124c92fd5d629d4dd85d4d264a9e4"}
CREATE OR REPLACE FUNCTION public.home_confirm_projection_fixed_item_status(p_item_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_item public.home_fixed_month_items%rowtype;
begin
  if p_status not in ('unpaid','paid','settled') then
    return jsonb_build_object('ok',false,'message','固定项状态无效。');
  end if;

  select * into v_item
  from public.home_fixed_month_items
  where id=p_item_id and user_id=auth.uid();

  if not found then
    return jsonb_build_object('ok',false,'message','没有找到可更新的固定项。');
  end if;

  if not public.home_fixed_item_has_external_projection(v_item.id) then
    return jsonb_build_object(
      'ok',false,
      'code','HOME_NOT_PROJECTION_FIXED_ITEM',
      'message','该固定项不是School投影项，请使用普通状态writer。');
  end if;

  if public.home_fixed_item_has_card_statement(v_item.id) then
    return jsonb_build_object(
      'ok',false,
      'code','HOME_CARD_STATEMENT_ITEM_STATUS_FORBIDDEN',
      'message','信用卡statement关联固定项不能使用本writer。');
  end if;

  if v_item.linked_jpy_transaction_id is not null then
    return jsonb_build_object('ok',false,'message','调拨记录状态固定为已付。');
  end if;

  if v_item.status = p_status then
    return jsonb_build_object('ok',true,'message','状态未变化。','updated_count',0);
  end if;

  perform set_config('home.phase3f_projection_status_write','on',true);

  update public.home_fixed_month_items
  set status=p_status
  where id=v_item.id and user_id=auth.uid();

  perform set_config('home.phase3f_projection_status_write','off',true);

  return jsonb_build_object(
    'ok',true,
    'message','School投影固定项状态已更新。',
    'updated_count',1,
    'item_id',v_item.id,
    'status',p_status);
end;
$function$;


-- home_fixed_item_has_external_projection(uuid)
-- {"name": "home_fixed_item_has_external_projection", "owner": "postgres", "proacl": ["postgres=X/postgres", "authenticated=X/postgres", "service_role=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": true, "signature": "home_fixed_item_has_external_projection(uuid)", "prosrc_md5": "cd5bc9b5f579193962b1082d6347f3a7"}
CREATE OR REPLACE FUNCTION public.home_fixed_item_has_external_projection(p_item_id uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select exists (
    select 1
    from public.home_external_fixed_payment_projections p
    join public.home_fixed_month_items i on i.id = p.fixed_month_item_id
    where p.fixed_month_item_id = p_item_id
      and i.user_id = auth.uid()
  );
$function$;


-- home_get_card_route_catalog(uuid)
-- {"name": "home_get_card_route_catalog", "owner": "postgres", "proacl": ["postgres=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": false, "signature": "home_get_card_route_catalog(uuid)", "prosrc_md5": "12c2cc7794e8329e74887d1825231d5e"}
CREATE OR REPLACE FUNCTION public.home_get_card_route_catalog(p_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(card_instrument_id uuid, user_id uuid, card_name text, settlement_currency text, cutoff_day integer, cutoff_inclusive boolean, funding_day integer, funding_payment_channel_id uuid, funding_payment_channel_name text, household_statement_template_id uuid, household_statement_template_name text, is_active boolean, is_school_fixed_route_enabled boolean, version bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select
    c.id,
    c.user_id,
    c.name,
    c.settlement_currency,
    c.cutoff_day,
    c.cutoff_inclusive,
    c.funding_day,
    c.funding_payment_channel_id,
    pc.name,
    c.household_statement_template_id,
    ft.name,
    c.is_active,
    c.is_school_fixed_route_enabled,
    c.version
  from public.home_card_instruments c
  join public.home_payment_channels pc on pc.id = c.funding_payment_channel_id
  join public.home_fixed_templates ft on ft.id = c.household_statement_template_id
  where p_user_id is null or c.user_id = p_user_id
  order by c.user_id, c.settlement_currency, c.name, c.id;
$function$;


-- home_update_cny_fixed_item_status(uuid,text)
-- {"name": "home_update_cny_fixed_item_status", "owner": "postgres", "proacl": ["=X/postgres", "postgres=X/postgres", "anon=X/postgres", "authenticated=X/postgres", "service_role=X/postgres"], "proconfig": null, "prosecdef": false, "signature": "home_update_cny_fixed_item_status(uuid,text)", "prosrc_md5": "e33be772e1cbe70759d30824efad7693"}
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

  -- Phase 3F：projection 项不能使用普通状态 writer
  if public.home_fixed_item_has_external_projection(v_item.id) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN',
      'message', 'School信用卡projection固定项不能使用普通状态writer。');
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
$function$;


-- home_update_cny_fixed_items_status(text,text,text)
-- {"name": "home_update_cny_fixed_items_status", "owner": "postgres", "proacl": ["=X/postgres", "postgres=X/postgres", "anon=X/postgres", "authenticated=X/postgres", "service_role=X/postgres"], "proconfig": null, "prosecdef": false, "signature": "home_update_cny_fixed_items_status(text,text,text)", "prosrc_md5": "fc3f7782d244b64c5ef3ffb10978d33d"}
CREATE OR REPLACE FUNCTION public.home_update_cny_fixed_items_status(p_month_key text, p_direction text, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_item record;
  v_result jsonb;
  v_updated_count integer := 0;
  v_invalid_count integer := 0;
begin
  if p_direction not in ('income', 'expense') then
    return jsonb_build_object('ok', false, 'message', '人民币固定项收支方向无效。');
  end if;

  if p_status not in ('unpaid', 'paid', 'settled') then
    return jsonb_build_object('ok', false, 'message', '人民币固定项状态无效。');
  end if;

  if p_status in ('paid', 'settled') then
    select count(*)
    into v_invalid_count
    from home_fixed_month_items i
    left join home_accounts a on a.id = i.account_id
      and a.user_id = auth.uid()
      and a.currency = 'CNY'
      and a.is_active
    where i.user_id = auth.uid()
      and i.month_key = p_month_key
      and i.currency = 'CNY'
      and i.direction = p_direction
      and a.id is null;

    if v_invalid_count > 0 then
      return jsonb_build_object(
        'ok', false,
        'message', '存在未选择有效账户的人民币固定项，不能一键结算。',
        'invalid_count', v_invalid_count
      );
    end if;
  end if;

  for v_item in
    select id, name
    from home_fixed_month_items
    where user_id = auth.uid()
      and month_key = p_month_key
      and currency = 'CNY'
      and direction = p_direction
    order by due_date nulls last, created_at, name
  loop
    v_result := home_update_cny_fixed_item_status(v_item.id, p_status);
    if not coalesce((v_result ->> 'ok')::boolean, false) then
      return jsonb_build_object(
        'ok', false,
        'message', coalesce(v_result ->> 'message', '人民币固定项批量状态更新失败。'),
        'failed_item', v_item.name,
        'updated_count', v_updated_count
      );
    end if;

    v_updated_count := v_updated_count + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'message', '人民币固定项状态已批量更新。',
    'updated_count', v_updated_count
  );
end;
$function$;


-- home_update_fixed_month_items_status(text,text,text,text)
-- {"name": "home_update_fixed_month_items_status", "owner": "postgres", "proacl": ["=X/postgres", "postgres=X/postgres", "anon=X/postgres", "authenticated=X/postgres", "service_role=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": false, "signature": "home_update_fixed_month_items_status(text,text,text,text)", "prosrc_md5": "ea4e2dbacfec0c7a833f8af1559470dd"}
CREATE OR REPLACE FUNCTION public.home_update_fixed_month_items_status(p_month_key text, p_currency text, p_direction text, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_updated_count integer:=0; v_check jsonb;
begin
  if p_direction not in ('income','expense') then return jsonb_build_object('ok',false,'message','固定项收支方向无效。'); end if;
  if p_status not in ('unpaid','paid','settled') then return jsonb_build_object('ok',false,'message','固定项状态无效。'); end if;
  if public.home_fixed_scope_has_external_projection(p_month_key,p_currency,p_direction) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含School信用卡projection固定项，不能使用批量状态writer。'); end if;
  if public.home_fixed_scope_has_card_statement(p_month_key,p_currency,p_direction) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含信用卡statement关联固定项，不能使用批量状态writer。'); end if;
  if p_direction='expense' and p_status in ('paid','settled') then v_check:=public.home_check_fixed_paid_balance(p_month_key,p_currency,null,null,p_direction,p_status); if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if; end if;
  update public.home_fixed_month_items i set status=p_status where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction and i.linked_jpy_transaction_id is null and not(p_direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=i.month_key and ap.currency=i.currency and ap.payment_group=coalesce(i.payment_group,'未分组')));
  get diagnostics v_updated_count=row_count;
  return jsonb_build_object('ok',true,'message','固定项状态已批量更新。','updated_count',v_updated_count);
end;
$function$;


-- home_validate_card_instrument()
-- {"name": "home_validate_card_instrument", "owner": "postgres", "proacl": ["postgres=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": true, "signature": "home_validate_card_instrument()", "prosrc_md5": "2cf77fcaee68b80d3623e975901b1506"}
CREATE OR REPLACE FUNCTION public.home_validate_card_instrument()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
      new.funding_day, new.funding_month_offset, new.funding_payment_channel_id,
      new.household_statement_template_id
    ) is distinct from row(
      old.settlement_currency, old.cutoff_day, old.cutoff_inclusive,
      old.funding_day, old.funding_month_offset, old.funding_payment_channel_id,
      old.household_statement_template_id
    ) then
      raise exception using errcode = '42501', message = 'CARD_INSTRUMENT_REFERENCED_CONFIG_IMMUTABLE';
    end if;

    new.updated_at := statement_timestamp();
  end if;

  return new;
end;
$function$;


-- home_validate_card_statement_cycle()
-- {"name": "home_validate_card_statement_cycle", "owner": "postgres", "proacl": ["postgres=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": true, "signature": "home_validate_card_statement_cycle()", "prosrc_md5": "1c762855466ce47edce40d1092885195"}
CREATE OR REPLACE FUNCTION public.home_validate_card_statement_cycle()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
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
