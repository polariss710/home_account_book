-- 配对删除 步骤 B —— core 写入配对流水 id + 触发器读出并传给 eligibility
--
-- 日期：2026-09-01
-- 前序：supabase-update-20260901-pair-delete-step-a-eligibility.sql（4a32aee）
-- 基线：2026-09-01 从生产 pg_get_functiondef 导出的
--         home_delete_fixed_month_item_core
--         home_guard_fixed_month_item_delete_contract
--
-- ===========================================================================
-- 这一步做什么
-- ===========================================================================
--
-- 步骤 A 已让 eligibility 支持第三参数 p_pair_transaction_id，但没有任何
-- 调用方传它，所以配对豁免至今不可达。本步把这条通路接上：
--
--   core     新增第四参数 p_pair_transaction_id，透传给 eligibility，
--            并写入 authorization 记录
--   触发器   从 authorization 记录读出该值，传给它自己那次 eligibility 调用
--
-- 两者必须同时改：core 写入而触发器不读，配对删除会在触发器层被拒；
-- 触发器读了而 core 不写，读到的永远是 NULL。
--
-- 部署后配对删除机制就位，但仍无人调用——home_delete_jpy_transaction 要到
-- 步骤 C 才传参。因此本步对现有功能仍是零影响。
--
-- ===========================================================================
-- 触发器为什么多一次 select 而不是调换顺序
-- ===========================================================================
--
-- 基线顺序是：先跑 eligibility（第 11 行），再删 authorization 并 returning
-- （第 18-24 行）。而 pair_transaction_id 存在 authorization 记录里，需要在
-- eligibility 之前拿到。
--
-- 最直接的改法是把 delete...returning 提到前面，一次拿到两个值。但那会改变
-- 错误码：无授权直接 DELETE 一个 paid 项时，基线报
-- HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN（eligibility 先失败），调换后会报
-- HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED。那是行为变化。
--
-- 因此改为先 select 读出、eligibility 之后再 delete 消费。多一次查询，
-- 但检查顺序与错误码与基线完全一致。
--
-- ===========================================================================
-- core 的参数位置
-- ===========================================================================
--
-- p_pair_transaction_id 加在末位并带 default null，因此现有两个调用方
-- home_delete_fixed_month_item 与 home_delete_cny_fixed_item 的三参数调用
-- 不受影响，走的仍是 p_pair_transaction_id = null 的普通删除路径。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   从 ~/aozora-security-20260827/cash-baseline/ 取
--     home_delete_fixed_month_item_core.sql
--     home_guard_fixed_month_item_delete_contract.sql
--   两份原定义 CREATE OR REPLACE 覆盖。
--
--   注意 core 需先 drop 四参数版本再恢复三参数版本（参数列表变化，
--   CREATE OR REPLACE 会形成重载共存）。
--   authorization 表的 pair_transaction_id 列可保留，无写入即无影响。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. core：新增第四参数，写入 authorization，透传给 eligibility
--
-- 与基线的差异仅三处：参数表加一项、eligibility 调用多传一个参数、
-- insert authorization 多写一列。其余逐字保留，包括 for update 锁、
-- authorization 消费校验、以及返回值结构。
-- ---------------------------------------------------------------------------

drop function if exists public.home_delete_fixed_month_item_core(uuid, uuid, text);

create function public.home_delete_fixed_month_item_core(
  p_item_id uuid,
  p_actor_id uuid,
  p_expected_currency text default null::text,
  p_pair_transaction_id uuid default null::uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_item public.home_fixed_month_items%rowtype;
  v_check jsonb;
  v_deleted_count integer := 0;
  v_expected_currency text := nullif(upper(btrim(coalesce(p_expected_currency, ''))), '');
  v_authorization_id uuid := gen_random_uuid();
  v_core_nonce uuid := gen_random_uuid();
  v_transaction_id xid8;
begin
  if p_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  if p_item_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_ALREADY_ABSENT',
      'message', '该固定项已不存在，请刷新页面。'
    );
  end if;

  select * into v_item
  from public.home_fixed_month_items i
  where i.id = p_item_id
    and i.user_id = p_actor_id
    and (v_expected_currency is null or i.currency = v_expected_currency)
  for update;

  if not found then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_ALREADY_ABSENT',
      'message', '该固定项已不存在，请刷新页面。'
    );
  end if;

  v_check := public.home_check_fixed_month_item_delete_eligibility(
    v_item, p_actor_id, p_pair_transaction_id);
  if not coalesce((v_check ->> 'ok')::boolean, false) then
    return v_check;
  end if;

  v_transaction_id := pg_current_xact_id();

  insert into public.home_fixed_month_item_delete_authorizations(
    authorization_id,
    transaction_id,
    fixed_month_item_id,
    actor_id,
    operation_type,
    currency,
    core_nonce,
    pair_transaction_id
  ) values (
    v_authorization_id,
    v_transaction_id,
    v_item.id,
    p_actor_id,
    'delete',
    v_item.currency,
    v_core_nonce,
    p_pair_transaction_id
  );

  delete from public.home_fixed_month_items i
  where i.id = v_item.id
    and i.user_id = p_actor_id;
  get diagnostics v_deleted_count = row_count;

  if v_deleted_count <> 1 then
    raise exception using
      errcode = '55000',
      message = 'HOME_FIXED_ITEM_DELETE_INTERNAL_CONTRACT_ERROR';
  end if;

  if exists (
    select 1
    from public.home_fixed_month_item_delete_authorizations a
    where a.authorization_id = v_authorization_id
  ) then
    raise exception using
      errcode = '55000',
      message = 'HOME_FIXED_ITEM_DELETE_AUTHORIZATION_NOT_CONSUMED';
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'HOME_FIXED_ITEM_DELETED',
    'deleted_count', 1,
    'item_id', v_item.id,
    'currency', v_item.currency,
    'message', case
      when v_item.currency = 'CNY' then '人民币固定项已删除。'
      else '固定项已删除。'
    end
  );
end;
$function$;

-- ACL 还原为基线：core 是内部函数，由 home_delete_fixed_month_item 与
-- home_delete_cny_fixed_item 调用，不对外暴露。
-- 见 docs/lessons.md A3——重建函数时 Supabase default privileges 会自动授予
-- anon / authenticated / service_role，必须显式撤销。
revoke all on function public.home_delete_fixed_month_item_core(
  uuid, uuid, text, uuid) from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- 2. 触发器：读出配对流水 id，传给 eligibility
--
-- 与基线的差异仅两处：eligibility 调用前先 select 出 pair_transaction_id，
-- 以及该调用多传一个参数。检查顺序、错误码、authorization 消费逻辑均不变。
-- ---------------------------------------------------------------------------

create or replace function public.home_guard_fixed_month_item_delete_contract()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_authorization_id uuid;
  v_check jsonb;
  v_pair_transaction_id uuid;
begin
  -- 先读不删：pair_transaction_id 需要在 eligibility 之前拿到，而消费
  -- authorization 必须留在 eligibility 之后，否则无授权删除的错误码会变。
  select a.pair_transaction_id
  into v_pair_transaction_id
  from public.home_fixed_month_item_delete_authorizations a
  where a.transaction_id = pg_current_xact_id()
    and a.fixed_month_item_id = old.id
    and a.actor_id = old.user_id
    and a.operation_type = 'delete'
    and a.currency = old.currency
  limit 1;

  v_check := public.home_check_fixed_month_item_delete_eligibility(
    old, old.user_id, v_pair_transaction_id);
  if not coalesce((v_check ->> 'ok')::boolean, false) then
    raise exception using
      errcode = '42501',
      message = coalesce(v_check ->> 'code', 'HOME_FIXED_ITEM_DELETE_INTERNAL_CONTRACT_ERROR');
  end if;

  delete from public.home_fixed_month_item_delete_authorizations a
  where a.transaction_id = pg_current_xact_id()
    and a.fixed_month_item_id = old.id
    and a.actor_id = old.user_id
    and a.operation_type = 'delete'
    and a.currency = old.currency
  returning a.authorization_id into v_authorization_id;

  if v_authorization_id is null then
    raise exception using
      errcode = '42501',
      message = 'HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED';
  end if;

  return old;
end;
$function$;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 本步的验收标准仍是【现有功能零变化】，外加【配对机制已就位但未启用】。
--
-- 一、结构
--   1. core 只剩四参数一个版本，两/三参数版本不存在
--   2. core 的 proacl 精确等于部署前的值（预期 {postgres=X/postgres}），
--      三个角色任一残留都算失败
--   3. 触发器函数定义已更新；触发器本身（tgname/tgtype/tgenabled）未变
--
-- 二、行为不变（rollback-only fixture）
--   1. 删除普通 unpaid 固定项 → 仍 ok:true
--   2. 删除 paid 固定项 → 仍 HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN
--   3. 删除关联流水的固定项 → 仍 HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN
--   4. 删除 projection 项 → 仍 HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN
--   5. home_delete_fixed_month_item / home_delete_cny_fixed_item 的三参数调用
--      仍正常工作（它们未改，走 p_pair_transaction_id = null 路径）
--
-- 三、配对机制已就位（本步新增能力，直接调 core 验证）
--   构造 fixture：一个 status='paid' 且 linked_jpy_transaction_id 指向流水 T
--   的固定项 F。
--   1. home_delete_fixed_month_item_core(F, actor, currency, null)
--      → 应 ok:false / HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN（未传配对 id）
--   2. home_delete_fixed_month_item_core(F, actor, currency, T)
--      → 应 ok:true，F 被删除
--   3. home_delete_fixed_month_item_core(F, actor, currency, 其他流水 id)
--      → 应 ok:false / HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN
--         这一条最关键：证明豁免只对所传的那一笔生效，不是笼统放行
--   4. 构造 F2：paid + 有 projection + linked 到 T2
--      home_delete_fixed_month_item_core(F2, actor, currency, T2)
--      → 应 ok:false / HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN
--         证明配对豁免不影响其余七条检查
--
-- 四、目标流水仍不可删（预期如此，步骤 C 才打通）
--   ed902ac4-1307-4184-945f-ba36ebdef318 仍报 permission denied
--
-- ===========================================================================
