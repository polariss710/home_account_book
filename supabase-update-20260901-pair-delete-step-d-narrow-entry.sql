-- 配对删除 步骤 D —— 窄入口打通 INVOKER 到 core 的权限断点
--
-- 日期：2026-09-01
-- 前序：Step A（4a32aee）eligibility 支持配对参数
--       Step B（896a6e7）core 写入 authorization、触发器读出并传递
--       Step C（9a3c275）home_delete_jpy_transaction 改调 core —— 但不可用
-- 基线：2026-09-01 只读权限链说明（HEAD 9a3c275）
--
-- ===========================================================================
-- Step C 为什么不可用
-- ===========================================================================
--
-- home_delete_jpy_transaction 是 SECURITY INVOKER，以 authenticated 身份运行；
-- 而 Step B 把 home_delete_fixed_month_item_core 的 ACL 收成 {postgres=X/postgres}。
-- 于是 Step C 部署后实际返回：
--     42501: permission denied for function home_delete_fixed_month_item_core
--
-- 这个断点是设计时漏看「调用链上的 EXECUTE 权限」造成的：Step B 收 ACL、
-- Step C 让 INVOKER 去调，两步分开看都对，合起来必然失败。
--
-- 生产全量扫描确认这是**个例**——public schema 下没有其他 INVOKER 函数调用
-- authenticated 无权执行的函数，也没有用动态 EXECUTE 隐藏同类调用。
--
-- ===========================================================================
-- 为什么用窄入口，而不是另外两条路
-- ===========================================================================
--
-- 【否决】给 core 授予 authenticated EXECUTE
--   core 的 p_actor_id 是参数，调用方可以传别人的 uuid，形成跨用户删除。
--
-- 【否决】把 home_delete_jpy_transaction 改成 SECURITY DEFINER
--   这些表均为 FORCE RLS = false，postgres owner 会绕过全部 policy。失去的是：
--     home_jpy_transactions   owner_select / manual_update / manual_delete
--     home_fixed_month_items  owner SELECT + business_reader 可见性隐藏
--                             （未完成 correction 的 replacement 项）
--     home_fixed_advance_payments  auth.uid() = user_id
--   更关键的是**连锁效应**：它调用的 INVOKER 子函数
--   （resolve / reset / paid_balance）会继承 postgres 身份，整棵子树一起绕过
--   RLS。等于把「正文校验 + RLS」双层退化为只剩正文校验。
--
-- 【采用】新增窄 DEFINER 入口
--   只把「删配对固定项」这一个动作交给 postgres 权限，外层保持 INVOKER，
--   其余所有 RLS 边界原样保留。
--
-- ===========================================================================
-- 窄入口的安全设计
-- ===========================================================================
--
-- 一、actor 不作为参数
--     从 auth.uid() 内部取。DEFINER 下 current_user 变为 postgres，但
--     auth.uid() 仍从请求 JWT 读取真实用户，不受影响。调用方无法伪造身份。
--
-- 二、双方归属校验
--     固定项与流水都必须 user_id = auth.uid()，缺一不可。
--
-- 三、必须构成真实配对（双向同时成立）
--     校验两个方向都成立：
--       固定项.linked_jpy_transaction_id = 流水.id
--       且 流水.linked_fixed_month_item_id = 固定项.id
--
--     初稿用的是 OR，推断历史数据中存在单向链接，依据是
--     home_resolve_fixed_transfer_item_id 这个解析函数的存在、以及
--     home_delete_jpy_transaction 里「旧数据链接不完整」那个分支。
--
--     生产核查推翻了这个推断（2026-09-01）：
--       fixed_in/fixed_out 配对共 5 组，全部双向完整
--       仅流水→固定项单向：0
--       仅固定项→流水单向：0
--       无固定项链接的固定调拨流水：0
--       两侧断指针：0
--
--     既然单向链接实际不存在，就用更严的 AND。那两处代码痕迹说明**曾经**
--     考虑过链接不完整的情况，不代表当前数据里有。
--
--     若将来真的出现单向链接，本入口会拒绝，用户会看到
--     HOME_FIXED_TRANSFER_PAIR_INVALID——那时应先查清链接为何残缺，
--     而不是放宽这里的判据。
--
-- 四、限定流水类型
--     只接受 fixed_in / fixed_out。本入口的语义是「撤销固定资金调拨」，
--     不应被用于其他类型的流水。
--
-- 五、币种一致
--     配对双方币种必须相同，避免跨币种链接错乱时误删。
--
-- 六、其余检查全部交给 core
--     correction / funded / projection / statement / 垫付分组等七条检查
--     由 core 照常执行，本入口不做任何豁免。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   1. 从 ~/aozora-security-20260827/cash-baseline/home_delete_jpy_transaction.sql
--      取原定义 CREATE OR REPLACE 覆盖（回到 Step C 之前的直接 DELETE 版本，
--      即恢复到「permission denied for table」的故障状态）
--   2. drop function public.home_delete_fixed_transfer_pair_item(uuid, uuid)
--   不涉及数据变更。Step A / B 建立的机制不受影响。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. 新增窄入口
-- ---------------------------------------------------------------------------

create or replace function public.home_delete_fixed_transfer_pair_item(
  p_item_id uuid,
  p_pair_transaction_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_actor uuid := auth.uid();
  v_item public.home_fixed_month_items%rowtype;
  v_txn public.home_jpy_transactions%rowtype;
begin
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

-- 本入口对外暴露，供 INVOKER 层调用。目标 ACL：
--   {postgres=X/postgres,authenticated=X/postgres}
--
-- 必须撤销 public、anon **和 service_role** 三者。Supabase 的 default
-- privileges 会给 postgres 新建的函数一次性授予 anon / authenticated /
-- service_role，只撤前两个会留下 service_role=X。
--
-- 这一点 docs/lessons.md A3 已经写明，本文件初稿仍然漏了 service_role，
-- 由部署前审查拦下。同一个错误在 2026-08-31 到 09-01 之间犯了三次，
-- 说明「记住规则」不管用，必须在写完后回头对照 A3 逐项核对。
revoke all on function public.home_delete_fixed_transfer_pair_item(uuid, uuid)
  from public, anon, service_role;
grant execute on function public.home_delete_fixed_transfer_pair_item(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- 2. home_delete_jpy_transaction 改调窄入口
--
-- 与 Step C 的差异仅一处：core 调用换成窄入口调用，参数由四个减为两个
-- （actor 与 currency 由窄入口内部推导）。其余逻辑不变。
-- 外层保持 SECURITY INVOKER，所有 RLS 边界原样保留。
-- ---------------------------------------------------------------------------

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

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、结构与权限
--   1. home_delete_fixed_transfer_pair_item 存在，SECURITY DEFINER，
--      owner = postgres
--   2. 其 proacl 精确等于 {postgres=X/postgres,authenticated=X/postgres}
--      不含 anon，也不含 service_role —— default privileges 会一次授予三个
--      角色，文件已显式撤销 public / anon / service_role
--   3. home_delete_jpy_transaction 仍为 SECURITY INVOKER，proacl 与部署前一致
--   4. core 的 proacl 仍为 {postgres=X/postgres}，未被放开
--
-- 二、目标场景 —— 三步半要修的最终故障
--   删除流水 ed902ac4-1307-4184-945f-ba36ebdef318
--     （2026-08-01，7,000 JPY，关联固定项 5c31f996-4f68-4fbe-a735-aeeb0e8bb80a）
--   期望 ok:true、linked_deleted:true、固定项一并删除
--
--   ⚠️ 会真实删除生产数据。该记录是用户明确要求删除的旧固定盈余转入，
--      删除是本次修复的目的，不要事后还原。
--
--   删除后回报 2026-08 的 home_fixed_settlement_status。
--   预期盈余变为 267,000 JPY——原显示的 260,000 已扣除这笔 7,000 转入。
--
-- 三、窄入口自身的边界（rollback-only fixture）
--   全部期望 ok:false / HOME_FIXED_TRANSFER_PAIR_INVALID：
--   1. 非本人的流水
--   2. 非本人的固定项（不区分「不存在」与「属于他人」，避免泄露 id 存在性）
--   3. 不构成配对的 item + transaction 组合
--   4. 仅固定项→流水单向链接（另一方向缺失）
--   5. 仅流水→固定项单向链接（另一方向缺失）
--   6. 非 fixed_in / fixed_out 类型的流水
--   7. 币种不一致的配对
--   8. 任一参数为 NULL
--
--   第 4、5 项是本轮从 OR 改为 AND 后新增的：生产核查确认单向链接不存在，
--   故判据收严，单向应被拒绝。
--
-- 四、保护未被削弱（rollback-only fixture）
--   1. 配对固定项带 projection
--      → HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN
--      → ★ 且流水本身未被删除，确认事务整体回滚
--   2. 配对固定项进了 statement
--      → HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN
--   3. external 来源流水 → 仍返回「没有找到可删除的日元流水。」
--
--      注意：不是 EXTERNAL_TRANSACTION_IMMUTABLE。本文件初版的验收标准写错了，
--      2026-09-01 由部署后验证发现。
--
--      原因：函数首行 SELECT ... FOR UPDATE 需要满足 UPDATE policy，而
--      home_jpy_transactions_manual_update 明确排除 external 流水，因此
--      external 行在这一步就返回 0 行，走不到下面那段显式的 external 检查。
--
--      这是基线既有行为，与本次改动无关。真正拦住 external 流水的是 RLS
--      policy 而非那段显式检查——该检查因此是死代码，两者条件等价所以行为
--      上无差别。已单独记入 docs/lessons.md，不在本步处理。
--   4. 垫付流水 → 仍被拒绝
--   5. 他人流水 → 仍「没有找到可删除的日元流水。」
--
-- 五、不受影响
--   1. 不关联固定项的普通日元流水 → 照常删除成功
--      （★ Step C 因硬停止未验到这一项，本次必须补验）
--   2. fixed_in/fixed_out 但链接不完整 → 仍返回「旧数据链接不完整」文案
--   3. 赤字重置行为不变
--   4. home_delete_fixed_month_item / home_delete_cny_fixed_item 仍正常
--
-- ===========================================================================
