-- 配对删除 步骤 A —— authorization 表加列 + eligibility 支持配对豁免
--
-- 日期：2026-09-01
-- 基线：2026-09-01 从生产 pg_get_functiondef 导出的
--         home_check_fixed_month_item_delete_eligibility（2 参数版）
--         home_delete_fixed_month_item_core
--         home_guard_fixed_month_item_delete_contract
--
-- ===========================================================================
-- 这一步做什么
-- ===========================================================================
--
-- 只做两件事，且**部署后系统行为零变化**：
--   1. home_fixed_month_item_delete_authorizations 增加 pair_transaction_id 列
--   2. eligibility 增加第三参数 p_pair_transaction_id（default null）
--
-- core 与触发器本步不改，它们仍以两个参数调用 eligibility，落到新版的
-- default null 上，走的还是原来那条全检查路径。
--
-- ===========================================================================
-- 为什么需要配对豁免（背景）
-- ===========================================================================
--
-- home_create_fixed_transfer 生成的固定调拨项，创建时就写死 status='paid'
-- 且带 linked_jpy_transaction_id。而 eligibility 的两条检查正好挡住它：
--
--   第 3 条  HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN        仅允许 unpaid
--   第 9 条  HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN 拒绝关联流水
--
-- 因此「删除固定调拨流水并同步撤销固定项」这个操作在现行边界下无法完成。
-- 原实现（home_delete_jpy_transaction 直接 DELETE 固定项）在 2026-08-21
-- 撤销 authenticated 的表级 DELETE 之后失效，报 permission denied。
--
-- 固定调拨本质是「流水 + 固定项」一对，同生同死。本次为这个场景开一条
-- 精确的豁免路径，而不是放宽通用规则。
--
-- ===========================================================================
-- 豁免的边界
-- ===========================================================================
--
-- p_pair_transaction_id 非空时，只豁免两条，其余七条原样生效：
--
--   status 检查        整条跳过（调拨项必然是 paid）
--   linked 检查        **只豁免所传的那一笔流水**，关联其他流水仍然拒绝
--
-- 第二条的精确性是关键。若笼统豁免「有关联流水」，则固定项 A 关联流水 X 时，
-- 删流水 Y 会连带删掉 A。因此实现上逐个链接字段比对：
--
--   linked_jpy_transaction_id  必须等于 p_pair_transaction_id 才放行
--   linked_cny_transaction_id  一律拒绝（配对删除只处理 JPY 调拨）
--   反向引用                    只允许所传的那一笔，其他流水引用即拒绝
--
-- 保持生效的七条：未登录、已不存在、correction 链、已 funded、有 projection、
-- 有 statement、垫付流程。固定调拨项若沾上这些，同样不该删。
--
-- ===========================================================================
-- 为什么 DROP 而不是 CREATE OR REPLACE
-- ===========================================================================
--
-- PostgreSQL 的 CREATE OR REPLACE FUNCTION 不能改变参数列表。若直接建三参数
-- 版本，会与原两参数版本形成重载共存，而 core 与触发器的两参数调用会精确
-- 匹配到旧版，改动不生效。
--
-- DROP 与 CREATE 放在同一事务内，外部观察不到中间态，不存在「函数暂时不存在」
-- 的窗口。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   begin;
--   drop function public.home_check_fixed_month_item_delete_eligibility(
--     public.home_fixed_month_items, uuid, uuid);
--   -- 再从 cash-baseline/home_check_fixed_month_item_delete_eligibility.sql
--   -- 恢复两参数版本
--   alter table public.home_fixed_month_item_delete_authorizations
--     drop column if exists pair_transaction_id;
--   commit;
--
--   注：列为 nullable 且本步无人写入，先 drop 函数再 drop 列即可，无数据影响。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. authorization 表增加配对流水列
--
-- nullable，本步不写入。步骤 B 中 core 会在配对删除场景写入，触发器据此
-- 判断是否豁免。
-- ---------------------------------------------------------------------------

alter table public.home_fixed_month_item_delete_authorizations
  add column if not exists pair_transaction_id uuid;

comment on column public.home_fixed_month_item_delete_authorizations.pair_transaction_id is
  '配对删除场景下同事务内一并删除的 home_jpy_transactions.id；普通删除为 NULL。';

-- ---------------------------------------------------------------------------
-- 2. eligibility 换为三参数版本
--
-- 与基线的差异仅两处：第 3 条 status 检查在配对场景下跳过；第 9 条 linked
-- 检查在配对场景下逐字段比对、只放行所传的那一笔。其余七条逐字保留。
-- ---------------------------------------------------------------------------

drop function if exists public.home_check_fixed_month_item_delete_eligibility(
  public.home_fixed_month_items, uuid);

create function public.home_check_fixed_month_item_delete_eligibility(
  p_item public.home_fixed_month_items,
  p_actor_id uuid,
  p_pair_transaction_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
begin
  if p_actor_id is null then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED',
      'message', '请先登录后再删除固定项。'
    );
  end if;

  if p_item.id is null or p_item.user_id is distinct from p_actor_id then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_ALREADY_ABSENT',
      'message', '该固定项已不存在，请刷新页面。'
    );
  end if;

  -- 配对删除场景跳过状态检查：固定调拨项由 home_create_fixed_transfer 创建，
  -- 状态写死 paid，永远无法满足「仅 unpaid」。
  if p_pair_transaction_id is null and p_item.status is distinct from 'unpaid' then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN',
      'message', '仅未支付的普通固定项可以删除。已支付或已结算项目请先撤销支付或使用纠正流程。'
    );
  end if;

  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = p_item.id
      and (
        p.projection_status = 'corrected'
        or p.supersedes_projection_id is not null
        or exists (
          select 1
          from public.home_external_fixed_payment_projections replacement
          where replacement.supersedes_projection_id = p.id
        )
      )
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_CORRECTION_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项属于纠正或replacement链路，不能直接删除。'
    );
  end if;

  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = p_item.id
      and (
        p.funding_status is distinct from 'unfunded'
        or p.funding_account_id is not null
        or p.funding_transaction_id is not null
        or p.funded_at is not null
      )
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_FUNDED_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项已经进入资金处理流程，不能直接删除。'
    );
  end if;

  if exists (
    select 1
    from public.home_external_fixed_payment_projections p
    where p.fixed_month_item_id = p_item.id
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项来自外部固定支付链路，不能直接删除。'
    );
  end if;

  if exists (
    select 1
    from public.home_card_statement_cycles c
    where c.household_remainder_fixed_item_id = p_item.id
  ) or exists (
    select 1
    from public.home_card_statement_cycle_revisions r
    where r.household_remainder_fixed_item_id = p_item.id
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项已经进入账单处理流程，不能直接删除。'
    );
  end if;

  if p_item.direction = 'expense' and exists (
    select 1
    from public.home_fixed_advance_payments a
    where a.user_id = p_item.user_id
      and a.month_key = p_item.month_key
      and a.currency = p_item.currency
      and a.payment_group = coalesce(p_item.payment_group, '未分组')
  ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_ADVANCE_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项所在支付分组已经进入垫付流程，不能直接删除。'
    );
  end if;

  -- 关联流水检查。
  -- 普通场景（p_pair_transaction_id 为 NULL）：任何关联即拒绝，与基线一致。
  -- 配对场景：仅放行所传的那一笔 JPY 流水，其余关联一律拒绝——不能笼统豁免，
  -- 否则固定项关联流水 X 时删流水 Y 会误删。
  if (
       p_item.linked_jpy_transaction_id is not null
       and (p_pair_transaction_id is null
            or p_item.linked_jpy_transaction_id is distinct from p_pair_transaction_id)
     )
     or p_item.linked_cny_transaction_id is not null
     or exists (
       select 1
       from public.home_jpy_transactions t
       where t.linked_fixed_month_item_id = p_item.id
         and (p_pair_transaction_id is null
              or t.id is distinct from p_pair_transaction_id)
     )
     or exists (
       select 1
       from public.home_cny_transactions t
       where t.linked_fixed_month_item_id = p_item.id
     ) then
    return jsonb_build_object(
      'ok', false,
      'code', 'HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN',
      'message', '该固定项已经关联Cash流水，不能直接删除。'
    );
  end if;

  return jsonb_build_object(
    'ok', true,
    'code', 'HOME_FIXED_ITEM_DELETE_ELIGIBLE'
  );
end;
$function$;

-- ACL 必须还原为基线状态：{postgres=X/postgres}
--
-- 该函数是纯内部 helper，只被 home_delete_fixed_month_item_core 与
-- home_guard_fixed_month_item_delete_contract 调用，二者均为 SECURITY DEFINER、
-- 以 postgres 身份运行，因此不需要任何外部角色的 EXECUTE。
--
-- Supabase 的 default privileges 会给 postgres 新建的函数自动授予
-- anon / authenticated / service_role，若只撤 public 与 anon，就会给
-- authenticated 和 service_role 开出一个原本不存在的入口——那是权限边界变化，
-- 与本步「行为零变化」的验收标准冲突。
--
-- 教训：撤到什么程度取决于该对象**原本**的 ACL，不能套固定模板。
-- 新建/重建函数前先查 proacl，再决定 revoke 的范围。
revoke all on function public.home_check_fixed_month_item_delete_eligibility(
  public.home_fixed_month_items, uuid, uuid) from public, anon, authenticated, service_role;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 本步的验收标准是【系统行为零变化】，因此重点验「没坏」而不是「新功能可用」。
--
-- 一、结构
--   1. authorization 表存在 pair_transaction_id 列，nullable
--   2. eligibility 只剩三参数一个版本，两参数版本已不存在：
--        select pg_get_function_identity_arguments(oid) from pg_proc
--        where proname='home_check_fixed_month_item_delete_eligibility';
--      → 应只返回一行，含 p_pair_transaction_id
--   3. proacl 必须精确等于 {postgres=X/postgres}，与部署前一致。
--      不能只查「有没有 anon」——Supabase default privileges 会同时授予
--      anon / authenticated / service_role 三个角色，任一残留都是权限边界变化。
--
-- 二、行为不变（关键）
--   1. 删除一个普通 unpaid 固定项 → 照常成功
--   2. 删除一个 paid 固定项 → 仍 HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN
--   3. 删除一个关联流水的固定项 → 仍 HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN
--   4. 删除 projection 项 → 仍 HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN
--   以上均走 home_delete_fixed_month_item / home_delete_cny_fixed_item，
--   它们本步未改、仍传两个参数，应与部署前完全一致
--
-- 三、配对豁免尚不可用（预期如此）
--   目标流水 ed902ac4-1307-4184-945f-ba36ebdef318 仍无法删除，
--   仍报 permission denied —— 因为 home_delete_jpy_transaction 未改（步骤 C）
--
-- 建议用 rollback-only fixture 验证第二组，避免动真实数据。
--
-- ===========================================================================
