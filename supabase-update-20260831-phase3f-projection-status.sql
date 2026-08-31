-- Phase 3F —— School 信用卡 projection 固定项的还款状态推进
--
-- 日期：2026-08-31
-- 基线：supabase-baseline-20260831-fixed-chain-production.sql（生产实际定义）
--
-- ===========================================================================
-- 解决什么问题
-- ===========================================================================
--
-- Phase 3C3-B / 3D / 3E 建成了「School 支出 → 固定请求 → 批准 → 固定项 + 投影」
-- 这条链，但缺最后一步：用户还款后无法把固定项从 unpaid 改为 paid。
--
-- 触发器 home_fixed_month_items_projection_guard 对 projection 关联的固定项
-- 无条件拒绝任何 UPDATE；JPY 状态 writer 更在执行前就返回
-- HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN。因此生产上那笔 2026-09 的
-- 教室租金固定项（202,991 JPY）自 Correction-P 建立以来一直卡在 unpaid，
-- 用户点「已付」会被拒。
--
-- 本次新增一条极窄的放行通道：专用 writer + 事务级 GUC，只允许改 status。
--
-- ===========================================================================
-- 设计取舍（写下来，避免以后被当成疏漏）
-- ===========================================================================
--
-- 一、为什么不推进 projection.funding_status 到 funded
--
--   约束 home_external_fixed_projections_funding_lifecycle_check 要求
--   funding_status='funded' 时 funding_account_id / funding_transaction_id /
--   funded_at 三者均非空。而本系统的 JPY 还款动作（把钱存入扣款卡）不产生
--   任何交易记录，没有可填的 funding_transaction_id。
--
--   与其伪造一个交易 id 来满足约束，不如让 status 与 funding_status 各自
--   陈述各自的事实：
--     status = paid         用户确实已还款
--     funding_status = unfunded  系统确实没有资金交易记录
--   两者都为真，不构成矛盾。
--
--   **因此在本系统中 funding_status 恒为 unfunded**，它是 Phase 3D 为将来的
--   资金追踪预留的字段，当前业务不使用。看到满屏 unfunded 不是异常。
--
--   注：CNY 侧情况不同。home_update_cny_fixed_item_status 标记已付时会经
--   home_upsert_cny_fixed_transaction 自动生成一笔 CNY 流水，那笔流水可以
--   充当 funding_transaction_id。因此工行卡（阶段二）的 projection 有条件
--   真正推进到 funded，与西武卡不对称。届时另行设计。
--
-- 二、为什么不做余额校验
--
--   普通 JPY writer 在标记已付前会调 home_check_fixed_paid_balance 校验账户
--   余额。本 writer 不做，原因是两类固定项性质不同：普通固定项记录的是
--   计划中的家庭支出，余额校验有意义；School projection 项记录的是已经刷卡
--   发生的外部支出，是既成事实，余额不足也不应阻止如实记账。
--
--   实际操作中用户只在付款完成后才点已付，该校验永远不会触发——一个永不触发
--   的检查只会让后来者误以为它在防什么。
--
-- 三、为什么放行 settled
--
--   settled 是早期 Excel 迁移遗留的展示状态，在 Cash 系统中无实际作用。
--   放行它是为了与普通固定项行为一致，不制造「School 项不能结清」这类
--   需要专门记忆的例外。
--
-- 四、失败方向
--
--   GUC 默认不存在，current_setting(...,true) 返回 NULL，
--   NULL is distinct from 'on' 为真 → 拒绝。
--   即任何未经本 writer 的路径，行为与改动前完全一致。
--   改动的失败方向是「继续拒绝」，不是「意外放行」。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   1. 从 supabase-baseline-20260831-fixed-chain-production.sql 取
--      home_guard_projection_linked_fixed_item / home_update_cny_fixed_item_status /
--      home_reset_plain_fixed_expenses_if_deficit 的原定义，CREATE OR REPLACE 覆盖
--   2. drop function public.home_confirm_projection_fixed_item_status(uuid, text)
--   不涉及任何数据变更。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. 触发器：projection 分支加 GUC 例外
--
-- 与基线的差异仅在 projection 分支：DELETE 仍无条件拒绝，UPDATE 增加
-- 「GUC 为 on 且除 status 外其余字段未变」这一条放行路径。
-- statement 分支与返回值原样保留。
-- ---------------------------------------------------------------------------

create or replace function public.home_guard_projection_linked_fixed_item()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
begin
  if exists (select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=old.id) then
    if tg_op='DELETE' then
      raise exception using errcode='42501',message='HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN';
    end if;
    -- Phase 3F：仅 home_confirm_projection_fixed_item_status 可改 status
    if current_setting('home.phase3f_projection_status_write',true) is distinct from 'on'
       or (to_jsonb(new)-'status') is distinct from (to_jsonb(old)-'status') then
      raise exception using errcode='42501',message='HOME_PROJECTION_FIXED_ITEM_UPDATE_FORBIDDEN';
    end if;
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

-- ---------------------------------------------------------------------------
-- 2. 新增：projection 固定项专用状态 writer
--
-- SECURITY DEFINER 因此必须自行校验 auth.uid()。
-- set_config 第三参为 true，GUC 仅在当前事务有效，不会泄漏到后续语句。
-- 反向拒绝非 projection 项，避免本 writer 被用于绕过普通项的校验。
-- ---------------------------------------------------------------------------

create or replace function public.home_confirm_projection_fixed_item_status(
  p_item_id uuid,
  p_status text
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
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

revoke all on function public.home_confirm_projection_fixed_item_status(uuid, text) from public;
grant execute on function public.home_confirm_projection_fixed_item_status(uuid, text) to authenticated;

-- ---------------------------------------------------------------------------
-- 3. CNY 状态 writer：补 projection 前置检查
--
-- 基线版本没有该检查，projection 关联的 CNY 项会一路执行到 UPDATE 并撞上
-- 触发器的 42501，用户看到的是原始 SQLSTATE 而非可读提示。
--
-- 当前生产没有 CNY projection 项（工行卡尚未开通），因此这段是预防性的。
-- 阶段二开通工行卡时需要重新设计：CNY writer 标记已付会经
-- home_upsert_cny_fixed_transaction 自动生成流水，那是 JPY 侧没有的行为，
-- 届时应决定 CNY projection 项是复用该机制还是走本文件的专用 writer。
-- ---------------------------------------------------------------------------

create or replace function public.home_update_cny_fixed_item_status(p_item_id uuid, p_status text)
returns jsonb
language plpgsql
as $function$
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

-- ---------------------------------------------------------------------------
-- 4. 赤字重置：排除 projection 项
--
-- 该函数在删除固定项后若重新出现赤字，会把未进入垫付流程的普通固定支出
-- 批量改回 unpaid。基线版本没有 projection 排除，当前靠触发器无条件拒绝
-- 而不会误伤；但 Phase 3F 放开 status 之后，若本函数在 GUC 开启的事务内
-- 被调用，就可能把已还款的 School 项重置回未付。
--
-- 加上显式排除，使其不依赖触发器兜底。
-- ---------------------------------------------------------------------------

create or replace function public.home_reset_plain_fixed_expenses_if_deficit(p_month_key text, p_currency text DEFAULT 'JPY'::text)
returns jsonb
language plpgsql
as $function$
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
    -- Phase 3F：School 投影项不参与赤字重置
    and not public.home_fixed_item_has_external_projection(i.id)
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
$function$;

commit;

-- ===========================================================================
-- 部署后验证清单
-- ===========================================================================
--
-- 应该成功：
--   select home_confirm_projection_fixed_item_status(
--     '4e9977b9-9e0e-412f-99b5-d0a4a1b52e3c', 'paid');
--   → ok:true, updated_count:1
--
--   改回：同一函数传 'unpaid' → ok:true
--
-- 应该仍被拒绝：
--   1. 普通 JPY writer 改 projection 项
--      home_update_fixed_month_item_status(同一 id, 'paid')
--      → ok:false, HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN
--   2. 删除 projection 项
--      home_delete_fixed_month_item(同一 id)
--      → 仍被 DELETE 分支拒绝
--   3. 本 writer 用于非 projection 项
--      → ok:false, HOME_NOT_PROJECTION_FIXED_ITEM
--
-- 应该不受影响：
--   任意家庭固定项经普通 writer 改状态 → 照常成功
--
-- ===========================================================================
