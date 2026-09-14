-- C rev8 authorized definitions. Transaction controlled by wrapper. Durably deployed 2026-09-14 11:56:46 UTC; exact body checked after deployment. Re-run only with fresh baseline authorization.
create or replace function public.home_fixed_transferable_surplus(p_user_id uuid,p_month_key text,p_currency text)
returns numeric language plpgsql security invoker volatile
set search_path=pg_catalog,public as $function$
declare v_result numeric;
begin
  if auth.uid() is null then
    raise exception using errcode='55000', message='HOME_FIXED_SURPLUS_AUTH_REQUIRED';
  end if;
  if p_user_id is distinct from auth.uid() then
    raise exception using errcode='55000', message='HOME_FIXED_SURPLUS_ACTOR_MISMATCH';
  end if;
  with items as (
    select i.* from public.home_fixed_month_items i
    where i.user_id=p_user_id and i.month_key=p_month_key and i.currency=p_currency
      and public.home_is_fixed_item_visible_to_business_reader(i.id)
  ), expenses as (
    select public.home_round_up_1000(sum(amount)) amount
    from items where direction='expense' group by coalesce(payment_group,'未分组')
  )
  select coalesce((select sum(amount) from items where direction='income' and status in ('paid','settled')),0)
    - coalesce((select sum(amount) from expenses),0)
    + coalesce((select sum(a.amount) from public.home_fixed_advance_payments a
        where a.user_id=p_user_id and a.currency=p_currency and to_char(a.paid_at,'YYYY-MM')=p_month_key),0)
    - coalesce((select sum(a.amount) from public.home_fixed_advance_payments a
        where a.user_id=p_user_id and a.currency=p_currency and a.status='repaid'
          and to_char(a.repaid_at,'YYYY-MM')=p_month_key),0) into v_result;
  return v_result;
end;
$function$;
alter function public.home_fixed_transferable_surplus(uuid,text,text) owner to postgres;
revoke all on function public.home_fixed_transferable_surplus(uuid,text,text) from public,anon,service_role;
grant execute on function public.home_fixed_transferable_surplus(uuid,text,text) to authenticated;

create or replace function public.home_fixed_consumed_surplus(p_user_id uuid,p_month_key text,p_currency text)
returns numeric language plpgsql security invoker volatile
set search_path=pg_catalog,public as $function$
declare v_result numeric;
begin
  if auth.uid() is null then
    raise exception using errcode='55000', message='HOME_FIXED_SURPLUS_AUTH_REQUIRED';
  end if;
  if p_user_id is distinct from auth.uid() then
    raise exception using errcode='55000', message='HOME_FIXED_SURPLUS_ACTOR_MISMATCH';
  end if;
  select coalesce((select sum(a.amount) from public.home_fixed_advance_payments a
      where a.user_id=p_user_id and a.currency=p_currency and a.status='repaid'
        and to_char(a.repaid_at,'YYYY-MM')=p_month_key),0)
    + coalesce((select sum(t.amount) from public.home_jpy_transactions t
      where t.user_id=p_user_id and t.currency=p_currency and t.transaction_type='fixed_in'
        and to_char(t.transacted_at,'YYYY-MM')=p_month_key),0) into v_result;
  return v_result;
end;
$function$;
alter function public.home_fixed_consumed_surplus(uuid,text,text) owner to postgres;
revoke all on function public.home_fixed_consumed_surplus(uuid,text,text) from public,anon,service_role;
grant execute on function public.home_fixed_consumed_surplus(uuid,text,text) to authenticated;

create or replace function public.home_guard_fixed_income_reduction()
returns trigger language plpgsql security invoker volatile
set search_path=pg_catalog,public as $function$
declare v_old numeric; v_new numeric; v_consumed numeric;
begin
  v_old:=case when old.direction='income' and old.status in ('paid','settled') then old.amount else 0 end;
  if tg_op='UPDATE' then
    v_new:=case when new.direction='income' and new.status in ('paid','settled') then new.amount else 0 end;
    if row(old.user_id,old.month_key,old.currency) is not distinct from row(new.user_id,new.month_key,new.currency) then
      if v_new>=v_old then return null; end if;
    elsif v_old<=0 then return null;
    end if;
  elsif v_old<=0 then return null;
  end if;
  v_consumed:=public.home_fixed_consumed_surplus(old.user_id,old.month_key,old.currency);
  if v_consumed>0 and public.home_fixed_transferable_surplus(old.user_id,old.month_key,old.currency)<0 then
    raise exception using errcode='55000', message='HOME_FIXED_SURPLUS_ALREADY_CONSUMED',
      detail=format('本月已有 %s 的固定收支盈余用于补回或转出，此操作会使这部分资金失去来源，因此未执行。请核对本月的资金安排后再调整。',v_consumed);
  end if;
  return null;
end;
$function$;
alter function public.home_guard_fixed_income_reduction() owner to postgres;
revoke all on function public.home_guard_fixed_income_reduction() from public,anon,authenticated,service_role;
create trigger home_fixed_income_reduction_guard after update or delete on public.home_fixed_month_items
for each row execute function public.home_guard_fixed_income_reduction();

CREATE OR REPLACE FUNCTION public.home_fixed_settlement_status(p_month_key text, p_currency text DEFAULT 'JPY'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_planned_income numeric := 0;
  v_planned_expense numeric := 0;
  v_actual_income numeric := 0;
  v_actual_expense numeric := 0;
  v_balance numeric := 0;
  v_advance_amount_in_month numeric; v_repaid_amount_in_month numeric;
  v_funding numeric; v_surplus numeric;
begin
  with month_items as (
    select
      i.*,
      case
        when i.linked_jpy_transaction_id is not null then 'paid'
        else i.status
      end as effective_status
    from home_fixed_month_items i
    where i.user_id = auth.uid()
      and i.month_key = p_month_key
      and i.currency = p_currency
  ),
  planned_expense_groups as (
    select
      coalesce(payment_group, '未分组') as payment_group,
      home_round_up_1000(coalesce(sum(amount), 0)) as planned_amount
    from month_items
    where direction = 'expense'
    group by coalesce(payment_group, '未分组')
  ),
  paid_expense_groups as (
    select
      coalesce(payment_group, '未分组') as payment_group,
      home_round_up_1000(coalesce(sum(amount), 0)) as paid_amount
    from month_items
    where direction = 'expense'
      and effective_status in ('paid', 'settled')
    group by coalesce(payment_group, '未分组')
  )
  select
    coalesce(sum(amount) filter (where direction = 'income'), 0),
    coalesce((select sum(planned_amount) from planned_expense_groups), 0),
    coalesce(sum(amount) filter (where direction = 'income' and effective_status in ('paid', 'settled')), 0),
    coalesce((select sum(paid_amount) from paid_expense_groups), 0)
  into v_planned_income, v_planned_expense, v_actual_income, v_actual_expense
  from month_items;

  select coalesce(sum(a.amount) filter(where to_char(a.paid_at,'YYYY-MM')=p_month_key),0),
    coalesce(sum(a.amount) filter(where a.status='repaid' and to_char(a.repaid_at,'YYYY-MM')=p_month_key),0)
  into v_advance_amount_in_month,v_repaid_amount_in_month
  from public.home_fixed_advance_payments a where a.user_id=auth.uid() and a.currency=p_currency;
  v_balance := v_planned_income - v_planned_expense;
  v_funding:= -v_balance-v_advance_amount_in_month+v_repaid_amount_in_month;
  v_surplus:=public.home_fixed_transferable_surplus(auth.uid(),p_month_key,p_currency);

  return jsonb_build_object(
    'advance_amount_in_month',v_advance_amount_in_month,
    'repaid_amount_in_month',v_repaid_amount_in_month,
    'funding_required',v_funding,
    'funding_state',case when v_funding>0 then 'deficit' when v_funding<0 then 'surplus' else 'balanced' end,
    'funding_transfer_amount',case when v_funding>0 then v_funding else 0 end,
    'transferable_surplus',v_surplus,
    'transferable_transfer_amount',case when v_surplus>=1000 then floor(v_surplus/1000)*1000 else 0 end,
    'funding_transaction_type',case when v_funding>0 then 'fixed_out' when v_surplus>=1000 then 'fixed_in' else null end,
    'planned_income', v_planned_income,
    'planned_expense', v_planned_expense,
    'actual_income', v_actual_income,
    'actual_expense', v_actual_expense,
    'balance', v_balance,
    'state', case
      when v_balance < 0 then 'deficit'
      when v_balance > 0 then 'surplus'
      else 'balanced'
    end,
    'transaction_type', case
      when v_balance < 0 then 'fixed_out'
      when v_balance > 0 then 'fixed_in'
      else null
    end,
    'transfer_amount', abs(v_balance),
    'message', case
      when v_balance < 0 then format('结算赤字 %s。', abs(v_balance))
      when v_balance > 0 then format('结算盈余 %s。', v_balance)
      else '本月固定收支结算已平衡。'
    end
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_check_fixed_paid_balance(p_month_key text, p_currency text DEFAULT 'JPY'::text, p_target_item_id uuid DEFAULT NULL::uuid, p_target_status text DEFAULT NULL::text, p_bulk_direction text DEFAULT NULL::text, p_bulk_status text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 STABLE
AS $function$
declare
  v_actual_income numeric := 0;
  v_actual_expense numeric := 0;
  v_advance_amount_in_month numeric; v_repaid_amount_in_month numeric;
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

  select coalesce(sum(a.amount) filter(where to_char(a.paid_at,'YYYY-MM')=p_month_key),0),
    coalesce(sum(a.amount) filter(where a.status='repaid' and to_char(a.repaid_at,'YYYY-MM')=p_month_key),0)
  into v_advance_amount_in_month,v_repaid_amount_in_month
  from public.home_fixed_advance_payments a where a.user_id=auth.uid() and a.currency=p_currency;
  if v_actual_income < v_actual_expense-v_advance_amount_in_month+v_repaid_amount_in_month then
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

CREATE OR REPLACE FUNCTION public.home_create_fixed_transfer(p_month_key text, p_currency text, p_transaction_type text, p_account_id uuid, p_transacted_at date, p_amount numeric DEFAULT NULL::numeric, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_description text;
  v_direction text;
  v_payment_group text;
  v_jpy_transaction_id uuid := gen_random_uuid();
  v_fixed_item_id uuid := gen_random_uuid();
  v_status jsonb;
  v_amount numeric := 0;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),p_month_key,p_currency),0));
  if p_transaction_type not in ('fixed_in', 'fixed_out') then
    return jsonb_build_object('ok', false, 'message', '固定资金调拨类型无效。');
  end if;

  if not exists (
    select 1
    from home_accounts
    where id = p_account_id
      and user_id = auth.uid()
      and currency = p_currency
      and is_active
  ) then
    return jsonb_build_object('ok', false, 'message', '没有找到可使用的日元账户。');
  end if;

  if to_char(p_transacted_at, 'YYYY-MM') <> p_month_key then
    return jsonb_build_object('ok', false, 'message', '固定资金调拨日期必须在当前账期内。');
  end if;

  v_status := home_fixed_settlement_status(p_month_key, p_currency);
  if p_transaction_type is distinct from (v_status->>'funding_transaction_type') then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_TRANSFER_DIRECTION_STALE','message','资金调拨方向已变化，请刷新页面。');
  end if;
  v_amount:=case when p_transaction_type='fixed_out' then (v_status->>'funding_transfer_amount')::numeric
    else (v_status->>'transferable_transfer_amount')::numeric end;

  if p_transaction_type = 'fixed_out' and coalesce(v_status ->> 'funding_state', '') <> 'deficit' then
    return jsonb_build_object('ok', false, 'message', '本月结算没有赤字，不需要补充。');
  end if;

  if p_transaction_type = 'fixed_in' and ((v_status->>'funding_required')::numeric>0 or (v_status->>'transferable_surplus')::numeric<1000) then
    return jsonb_build_object('ok', false, 'message', '本月结算没有盈余，不能转入。');
  end if;

  if v_amount <= 0 then
    return jsonb_build_object('ok', false, 'message', '本月固定收支结算已平衡，不需要调拨。');
  end if;

  v_description := home_fixed_transfer_name(p_transaction_type);
  v_direction := home_fixed_transfer_direction(p_transaction_type);
  v_payment_group := case when p_transaction_type = 'fixed_in' then v_description else null end;

  if exists (
    select 1
    from home_fixed_month_items
    where user_id = auth.uid()
      and month_key = p_month_key
      and currency = p_currency
      and direction = v_direction
      and name = v_description
  ) then
    return jsonb_build_object('ok', false, 'message', format('本月已存在%s，请先删除后重新生成。', v_description));
  end if;

  insert into home_jpy_transactions (
    id,
    user_id,
    transaction_type,
    account_id,
    transfer_account_id,
    currency,
    transacted_at,
    amount,
    description,
    note,
    created_at
  )
  values (
    v_jpy_transaction_id,
    auth.uid(),
    p_transaction_type,
    p_account_id,
    null,
    p_currency,
    p_transacted_at,
    v_amount,
    v_description,
    coalesce(p_note, ''),
    now()
  );

  insert into home_fixed_month_items (
    id,
    user_id,
    template_id,
    month_key,
    currency,
    direction,
    name,
    amount,
    status,
    account_id,
    payment_group,
    due_date,
    term_no,
    total_terms,
    note,
    linked_jpy_transaction_id,
    created_at
  )
  values (
    v_fixed_item_id,
    auth.uid(),
    null,
    p_month_key,
    p_currency,
    v_direction,
    v_description,
    v_amount,
    'paid',
    p_account_id,
    v_payment_group,
    p_transacted_at,
    null,
    null,
    coalesce(p_note, ''),
    v_jpy_transaction_id,
    now()
  );

  update home_jpy_transactions
  set linked_fixed_month_item_id = v_fixed_item_id
  where id = v_jpy_transaction_id
    and user_id = auth.uid();

  return jsonb_build_object(
    'ok', true,
    'message', format('%s已生成，金额 %s。', v_description, v_amount),
    'amount', v_amount,
    'fixed_item_id', v_fixed_item_id,
    'jpy_transaction_id', v_jpy_transaction_id
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_settle_fixed_advance_repayment(p_advance_id uuid, p_repaid_at date, p_note text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
AS $function$
declare
  v_advance public.home_fixed_advance_payments%rowtype;
  v_transaction_id uuid := gen_random_uuid();
  v_currency text;
begin
  if p_repaid_at is null then return jsonb_build_object('ok',false,'message','请选择补回日期。'); end if;
  select currency into v_currency from public.home_fixed_advance_payments where id=p_advance_id and user_id=auth.uid();
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),to_char(p_repaid_at,'YYYY-MM'),v_currency),0));
  select *
  into v_advance
  from public.home_fixed_advance_payments
  where id = p_advance_id
    and user_id = auth.uid() for update;

  if not found then
    return jsonb_build_object('ok', false, 'message', '没有找到可补回的固定垫付记录。');
  end if;

  if v_advance.status is distinct from 'pending' then
    return jsonb_build_object('ok', false, 'message', '这笔固定垫付已经补回。');
  end if;

  if p_repaid_at < v_advance.paid_at then
    return jsonb_build_object('ok', false, 'message', '补回日期不得早于垫付日。');
  end if;

  if v_currency is distinct from v_advance.currency then
    raise exception using errcode='55000',message='HOME_FIXED_SCOPE_CHANGED';
  end if;
  if v_advance.amount>public.home_fixed_transferable_surplus(auth.uid(),to_char(p_repaid_at,'YYYY-MM'),v_advance.currency) then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_ADVANCE_REPAY_INSUFFICIENT_SURPLUS','message','补回月份的可转出盈余不足。');
  end if;
  insert into public.home_jpy_transactions (
    id,
    user_id,
    transaction_type,
    account_id,
    transfer_account_id,
    currency,
    transacted_at,
    amount,
    description,
    note,
    created_at
  )
  values (
    v_transaction_id,
    auth.uid(),
    'fixed_advance_in',
    v_advance.account_id,
    null,
    v_advance.currency,
    p_repaid_at,
    v_advance.amount,
    format('%s 固定垫付补回', v_advance.payment_group),
    coalesce(p_note, v_advance.note, ''),
    now()
  );

  update public.home_fixed_advance_payments
  set
    status = 'repaid',
    repaid_at = p_repaid_at,
    in_transaction_id = v_transaction_id
  where id = v_advance.id
    and user_id = auth.uid();

  return jsonb_build_object(
    'ok', true,
    'message', format('%s 固定垫付已按原金额补回，金额 %s。', v_advance.payment_group, v_advance.amount),
    'advance_id', v_advance.id,
    'jpy_transaction_id', v_transaction_id,
    'amount', v_advance.amount
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_update_fixed_month_items_status(p_month_key text, p_currency text, p_direction text, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_updated_count integer:=0; v_skipped integer:=0; v_check jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),p_month_key,p_currency),0));
  if p_direction not in ('income','expense') then return jsonb_build_object('ok',false,'message','固定项收支方向无效。'); end if;
  if p_status not in ('unpaid','paid','settled') then return jsonb_build_object('ok',false,'message','固定项状态无效。'); end if;
  -- ① 原来这里是整批拒绝。改为跳过：projection 项由前端随后单独走
  --    home_confirm_projection_fixed_item_status，那是它们唯一合法的入口。
  if public.home_fixed_scope_has_card_statement(p_month_key,p_currency,p_direction) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含信用卡statement关联固定项，不能使用批量状态writer。'); end if;
  if p_direction='expense' and p_status in ('paid','settled') then v_check:=public.home_check_fixed_paid_balance(p_month_key,p_currency,null,null,p_direction,p_status); if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if; end if;
  -- ③ 先数清楚这次会跳过几条，返回里报出去，前端据此决定要不要补那一步
  select count(*) into v_skipped
  from public.home_fixed_month_items i
  where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency
    and i.direction=p_direction
    and public.home_fixed_item_has_external_projection(i.id);
  -- ② 排除 projection 项
  update public.home_fixed_month_items i set status=p_status where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction and i.linked_jpy_transaction_id is null and not public.home_fixed_item_has_external_projection(i.id) and not(p_direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=i.month_key and ap.currency=i.currency and ap.payment_group=coalesce(i.payment_group,'未分组')));
  get diagnostics v_updated_count=row_count;
  return jsonb_build_object('ok',true,'message','固定项状态已批量更新。','updated_count',v_updated_count,'skipped_projection_count',v_skipped);
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_sync_fixed_month_items(p_month_key text, p_currency text DEFAULT 'JPY'::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_updated_count integer:=0;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),p_month_key,p_currency),0));
  if public.home_fixed_scope_has_external_projection(p_month_key,p_currency) then return jsonb_build_object('ok',false,'code','HOME_PROJECTION_FIXED_ITEM_SYNC_FORBIDDEN','message','范围内包含School信用卡projection固定项，不能使用普通月份/模板同步writer。'); end if;
  if public.home_fixed_scope_has_card_statement(p_month_key,p_currency) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_SYNC_FORBIDDEN','message','范围内包含信用卡statement关联固定项，不能使用普通月份/模板同步writer。'); end if;
  with month_context as(select extract(year from month_start)::int year_no,extract(month from month_start)::int month_no,extract(day from(month_start+interval '1 month - 1 day'))::int days_in_month from(select to_date(p_month_key||'-01','YYYY-MM-DD') month_start)d),
  updated_items as(update public.home_fixed_month_items i set direction=t.direction,name=t.name,amount=t.default_amount,account_id=t.default_account_id,payment_group=t.payment_group,due_date=case when t.due_day is null then null else make_date(c.year_no,c.month_no,least(t.due_day,c.days_in_month)) end,term_no=case when t.fixed_type='short_term' and t.start_month is not null and t.total_terms is not null then((substring(p_month_key,1,4)::int-substring(t.start_month,1,4)::int)*12+(substring(p_month_key,6,2)::int-substring(t.start_month,6,2)::int)+1) else null end,total_terms=case when t.fixed_type='short_term' then t.total_terms else null end from public.home_fixed_templates t cross join month_context c where i.template_id=t.id and i.user_id=auth.uid() and t.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and t.currency=p_currency returning i.id)
  select count(*) into v_updated_count from updated_items;
  return jsonb_build_object('updated_count',v_updated_count);
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_update_fixed_month_item_status(p_item_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare v_item public.home_fixed_month_items%rowtype; v_check jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),i.month_key,i.currency),0))
  from public.home_fixed_month_items i where i.id=p_item_id and i.user_id=auth.uid();
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
$function$;

CREATE OR REPLACE FUNCTION public.home_confirm_projection_fixed_item_status(p_item_id uuid, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_item public.home_fixed_month_items%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),i.month_key,i.currency),0))
  from public.home_fixed_month_items i where i.id=p_item_id and i.user_id=auth.uid();
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

CREATE OR REPLACE FUNCTION public.home_delete_fixed_month_item(p_item_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_actor_id uuid := auth.uid();
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),i.month_key,i.currency),0))
  from public.home_fixed_month_items i where i.id=p_item_id and i.user_id=auth.uid();
  if v_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  return public.home_delete_fixed_month_item_core(p_item_id, v_actor_id, 'JPY');
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_delete_fixed_transfer_pair_item(p_item_id uuid, p_pair_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_actor uuid := auth.uid();
  v_item public.home_fixed_month_items%rowtype;
  v_txn public.home_jpy_transactions%rowtype;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),i.month_key,i.currency),0))
  from public.home_fixed_month_items i where i.id=p_item_id and i.user_id=auth.uid();
  if v_actor is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  if p_item_id is null or p_pair_transaction_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_TRANSFER_PAIR_INVALID',
      'message', '配对删除需要同时指定固定项与流水。'
    );
  end if;

  -- 流水：必须属于本人，且是固定资金调拨
  select * into v_txn
  from public.home_jpy_transactions
  where id = p_pair_transaction_id
    and user_id = v_actor;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_TRANSFER_PAIR_INVALID',
      'message', '配对流水不存在或不属于当前用户。'
    );
  end if;

  if v_txn.transaction_type not in ('fixed_in', 'fixed_out') then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_TRANSFER_PAIR_INVALID',
      'message', '配对流水不是固定资金调拨，不能使用本入口。'
    );
  end if;

  -- 固定项：必须属于本人
  select * into v_item
  from public.home_fixed_month_items
  where id = p_item_id
    and user_id = v_actor;

  if not found then
    -- 用 PAIR_INVALID 而非 ALREADY_ABSENT：本入口的语义是「校验配对关系」，
    -- 而 user_id = auth.uid() 是查询条件的一部分。项不存在与项属于他人在
    -- 这里不作区分，也不应区分——区分会泄露「该 id 确实存在但不属于你」。
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_TRANSFER_PAIR_INVALID',
      'message', '配对固定项不存在或不属于当前用户。'
    );
  end if;

  -- 必须构成真实配对：两个方向都成立。
  -- 生产核查确认 5 组配对全部双向完整，无单向情形，故用 AND。
  -- 详见文件头设计说明三。
  if not (
       v_item.linked_jpy_transaction_id is not distinct from v_txn.id
       and v_txn.linked_fixed_month_item_id is not distinct from v_item.id
     ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_TRANSFER_PAIR_INVALID',
      'message', '该固定项与所传流水不构成配对关系。'
    );
  end if;

  if v_item.currency is distinct from v_txn.currency then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_TRANSFER_PAIR_INVALID',
      'message', '配对双方币种不一致。'
    );
  end if;

  -- 其余七条检查全部交给 core，本入口不做任何豁免
  return public.home_delete_fixed_month_item_core(
    v_item.id,
    v_actor,
    v_item.currency,
    v_txn.id
  );
end;
$function$;

CREATE OR REPLACE FUNCTION public.home_delete_jpy_transaction(p_transaction_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SET search_path TO 'pg_catalog', 'public'
AS $function$
declare
  v_transaction public.home_jpy_transactions%rowtype;
  v_linked_fixed_month_item_id uuid;
  v_item public.home_fixed_month_items%rowtype;
  v_reset jsonb := jsonb_build_object('reset_expense_status', false);
  v_linked_deleted boolean := false;
  v_message text := '已删除。';
  v_core jsonb;
begin
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),
    coalesce(i.month_key,to_char(t.transacted_at,'YYYY-MM')),coalesce(i.currency,t.currency)),0))
  from public.home_jpy_transactions t left join public.home_fixed_month_items i
    on i.id=t.linked_fixed_month_item_id and i.user_id=auth.uid()
  where t.id=p_transaction_id and t.user_id=auth.uid();
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

    -- 2026-09-01 Step D：经窄 DEFINER 入口删除配对固定项。
    -- 本函数是 INVOKER，无权直接调 postgres-only 的 core；窄入口内部从
    -- auth.uid() 取 actor 并校验配对关系，再转调 core。
    v_core := public.home_delete_fixed_transfer_pair_item(
      v_linked_fixed_month_item_id,
      v_transaction.id
    );

    -- 失败原样上抛。projection / statement / correction / funded / 垫付等
    -- 保护命中时必须让整个删除失败；同一事务内 return 会连带回滚，
    -- 流水不会被误删。
    if not coalesce((v_core ->> 'ok')::boolean, false) then
      return v_core;
    end if;

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

create or replace function public.home_update_fixed_month_item_amount(p_item_id uuid,p_amount numeric)
returns jsonb language plpgsql security invoker volatile set search_path=pg_catalog,public
as $function$
declare v_item public.home_fixed_month_items%rowtype; v_count integer;
begin
  if auth.uid() is null then raise exception using errcode='55000',message='HOME_FIXED_SURPLUS_AUTH_REQUIRED'; end if;
  if p_amount is null or p_amount<0 or p_amount::text in ('NaN','Infinity','-Infinity') then
    return jsonb_build_object('ok',false,'message','固定项金额无效。');
  end if;
  perform pg_advisory_xact_lock(hashtextextended(format('home_fixed_surplus:%s:%s:%s',auth.uid(),i.month_key,i.currency),0))
    from public.home_fixed_month_items i where i.id=p_item_id and i.user_id=auth.uid();
  select * into v_item from public.home_fixed_month_items where id=p_item_id and user_id=auth.uid() for update;
  if not found then return jsonb_build_object('ok',false,'message','没有找到可更新的固定项。'); end if;
  if v_item.linked_jpy_transaction_id is not null or v_item.linked_cny_transaction_id is not null then
    return jsonb_build_object('ok',false,'message','关联流水的固定项金额不能单独修改。');
  end if;
  if v_item.direction='expense' and exists(select 1 from public.home_fixed_advance_payments a
    where a.user_id=auth.uid() and a.month_key=v_item.month_key and a.currency=v_item.currency
      and a.payment_group=coalesce(v_item.payment_group,'未分组')) then
    return jsonb_build_object('ok',false,'message','已进入垫付流程的固定项金额不能单独修改。');
  end if;
  update public.home_fixed_month_items set amount=p_amount where id=p_item_id and user_id=auth.uid();
  get diagnostics v_count=row_count;
  return jsonb_build_object('ok',v_count=1,'updated_count',v_count,'message','固定项金额已更新。');
end;
$function$;
alter function public.home_update_fixed_month_item_amount(uuid,numeric) owner to postgres;
revoke all on function public.home_update_fixed_month_item_amount(uuid,numeric) from public,anon,service_role;
grant execute on function public.home_update_fixed_month_item_amount(uuid,numeric) to authenticated;
