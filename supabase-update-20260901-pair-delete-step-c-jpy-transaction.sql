-- 配对删除 步骤 C —— 接通 home_delete_jpy_transaction
--
-- 日期：2026-09-01
-- 前序：Step A（4a32aee）eligibility 支持配对参数
--       Step B（896a6e7）core 写入 authorization、触发器读出并传递
-- 基线：2026-08-31 从生产 pg_get_functiondef 导出的 home_delete_jpy_transaction
--
-- ===========================================================================
-- 这一步做什么
-- ===========================================================================
--
-- 前两步把配对豁免的通路建好了，但至今无人调用。本步让
-- home_delete_jpy_transaction 在删除固定调拨流水时，改调 core 并传入自身的
-- 流水 id 作为配对凭据。
--
-- 原实现直接 delete from home_fixed_month_items，而 2026-08-21 已从
-- authenticated 撤销该表的表级 DELETE，该函数是 SECURITY INVOKER，
-- 因此必然 permission denied。这是本次三步要修的最终故障。
--
-- ===========================================================================
-- 顺序为什么不变
-- ===========================================================================
--
-- 基线顺序是先删固定项、再删流水。本步保持不变。
--
-- 可行的原因是 Step A 的豁免对双向链接都只放行所传的那一笔：
--   正向  p_item.linked_jpy_transaction_id = p_pair_transaction_id  → 放行
--   反向  home_jpy_transactions.id = p_pair_transaction_id          → 放行
-- 所以流水尚未删除时，core 也能通过 eligibility 删掉固定项。
-- Step B 的 fixture 验证已证实这一点（传正确流水 T 时 ok:true）。
--
-- ===========================================================================
-- core 失败为什么必须原样上抛
-- ===========================================================================
--
-- core 会跑其余七条检查——correction 链、已 funded、projection、statement、
-- 垫付分组、未登录、已不存在。任一命中都应让整个删除失败并把原因告诉用户，
-- 而不是留下「流水删了、固定项还在」的半成品状态。
--
-- 因为在同一事务内，return 之前的 delete 会随事务回滚，流水不会被误删。
--
-- ===========================================================================
-- 边界：本函数只处理 JPY 流水
-- ===========================================================================
--
-- 配对豁免只对 linked_jpy_transaction_id 生效，CNY 关联在 eligibility 中一律
-- 拒绝。这与本函数的职责一致——它是 home_delete_jpy_transaction。
-- CNY 侧若将来需要同类能力，需另行设计，不能假定复用本路径。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   从 ~/aozora-security-20260827/cash-baseline/home_delete_jpy_transaction.sql
--   取原定义 CREATE OR REPLACE 覆盖。不涉及数据变更。
--   回滚后该函数恢复到「删不掉固定项」的故障状态，但 Step A / B 建立的
--   配对机制不受影响，仍可由其他调用方使用。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

create or replace function public.home_delete_jpy_transaction(p_transaction_id uuid)
returns jsonb
language plpgsql
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_transaction public.home_jpy_transactions%rowtype;
  v_linked_fixed_month_item_id uuid;
  v_item public.home_fixed_month_items%rowtype;
  v_reset jsonb := jsonb_build_object('reset_expense_status', false);
  v_linked_deleted boolean := false;
  v_message text := '已删除。';
  v_core jsonb;
begin
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

    -- 2026-09-01：改为经删除边界的 core，并传入本流水 id 作为配对凭据。
    -- 原实现直接 DELETE，在 2026-08-21 撤销 authenticated 的表级 DELETE 后
    -- 必然 permission denied。配对豁免只放行这一笔关联，其余七条检查照常。
    v_core := public.home_delete_fixed_month_item_core(
      v_linked_fixed_month_item_id,
      auth.uid(),
      v_item.currency,
      v_transaction.id
    );

    -- core 的失败原样上抛。projection / statement / correction / funded /
    -- 垫付等保护命中时，必须让整个删除失败，不能出现「流水删了、固定项还在」。
    -- 同一事务内 return 会连带回滚，流水不会被误删。
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

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、结构
--   home_delete_jpy_transaction 的 proacl 与部署前一致
--   （该函数对外暴露，预期含 authenticated；CREATE OR REPLACE 不改参数列表，
--     ACL 应自动保留，但仍需核对）
--
-- 二、目标场景 —— 本次三步要修的最终故障
--   删除流水 ed902ac4-1307-4184-945f-ba36ebdef318
--     （2026-08-01，7,000 JPY，关联固定项 5c31f996-4f68-4fbe-a735-aeeb0e8bb80a）
--   期望 ok:true、linked_deleted:true、固定项一并删除、无 permission denied
--
--   ⚠️ 这一步会真实删除生产数据。该记录是用户明确要求删除的旧固定盈余转入，
--      删除是本次修复的目的，不要事后还原。
--
--   删除后请回报 2026-08 的 home_fixed_settlement_status。
--   预期盈余变为 267,000 JPY——原显示的 260,000 已扣除了这笔 7,000 转入，
--   删掉后基数恢复。这不是计算错误。
--
-- 三、保护未被削弱（rollback-only fixture）
--   1. 固定调拨流水，其固定项带 projection
--      → 期望 ok:false / HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN
--      → 且流水本身未被删除（确认事务整体回滚）
--   2. 固定调拨流水，其固定项进了 statement
--      → 期望 ok:false / HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN
--   3. external 来源流水 → 仍 EXTERNAL_TRANSACTION_IMMUTABLE
--   4. 垫付流水 → 仍被拒绝
--   5. 他人流水 → 仍返回「没有找到可删除的日元流水。」
--
-- 四、不受影响
--   1. 不关联固定项的普通日元流水 → 照常删除成功
--   2. fixed_in/fixed_out 但链接不完整的流水
--      → 仍返回「旧数据链接不完整」文案，流水被删、无固定项操作
--   3. 删除后触发的赤字重置行为不变
--
-- ===========================================================================
