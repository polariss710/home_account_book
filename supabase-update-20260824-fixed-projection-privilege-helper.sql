\set ON_ERROR_STOP on

-- Home / Cash：修复固定项 writer 因无法读取 projection 表而报 42501
--
-- 缺陷
-- ----
-- public.home_external_fixed_payment_projections 建于 2026-08-19 的 phase3c3b，
-- 但仓库中不存在任何针对该表的 GRANT，也未启用 RLS。同日 phase3d / phase3e
-- 在四个 security invoker 函数中加入了对该表的 select：
--
--   home_update_fixed_month_item_status      单个状态更新
--   home_update_fixed_month_items_status     批量状态更新（一键未付/已付/结清）
--   固定项删除 writer
--   月份/模板同步 writer
--
-- 这些 select 的本意是拒绝 School 信用卡 projection 关联的固定项走普通 writer，
-- 应返回 HOME_PROJECTION_FIXED_ITEM_*_FORBIDDEN 之类的业务文案。但由于调用者
-- （authenticated）对该表无任何权限，语句在执行时即失败，实际表现为：
--
--   固定项状态更新失败：permission denied for table home_external_fixed_payment_projections
--
-- 且对所有固定项无差别失败，而不仅是被守卫的那些。守卫读不到自己要守的表，
-- 按 AGENTS.md「Privilege And Function Security Boundary」属 P0 缺陷。
--
-- 修法
-- ----
-- 不给 authenticated 授予该表权限（该表无 RLS，整表授权会暴露全部 projection
-- 数据），也不把四个 writer 整体改为 security definer（过度扩大权限面）。
-- 改为抽取两个窄范围 security definer helper，只返回布尔值，四个 writer 的
-- security 属性保持不变。
--
-- 本文件只创建 helper。四个 writer 的调用点替换见文末规格，须由执行方对照
-- pg_get_functiondef 的生产实际定义套用——仓库 SQL 不等于生产函数体。
--
-- 业务模型扩展声明：
-- - 新业务表 / 列 / 枚举值：none
-- - 业务事实、权威来源、可变性、锁定规则变更：none
-- - 新增函数：两个只读 helper，不引入任何业务事实
-- - 权限边界变更：仅对这两个新函数授予 execute（authenticated, service_role）。
--   未改动任何既有表的 grant、任何 RLS 策略、任何既有函数的 owner 或
--   security 属性。

begin;
set local lock_timeout = '8s';
set local statement_timeout = '120s';

-- 前置：目标表必须存在，且 authenticated 确实不该有直接权限。
-- 若 authenticated 已持有 select，说明生产状态与本诊断不符，停止。
do $preflight$
declare
  v_has_select boolean;
begin
  if to_regclass('public.home_external_fixed_payment_projections') is null then
    raise exception 'FIXED_PROJECTION_HELPER_TABLE_MISSING';
  end if;

  v_has_select := has_table_privilege(
    'authenticated', 'public.home_external_fixed_payment_projections', 'SELECT'
  );
  if v_has_select then
    raise exception
      'FIXED_PROJECTION_HELPER_UNEXPECTED_GRANT: authenticated already has SELECT; '
      'diagnosis assumed no grant, stop and re-verify';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------------
-- helper 1：单个固定项是否关联 External projection
--
-- 用于 home_update_fixed_month_item_status 与固定项删除 writer。
-- 相比原先的内联 exists，本函数额外按 auth.uid() 限定归属：两个调用点都已在
-- 此前用 user_id=auth.uid() 取到 v_item，因此语义不变；同时避免本 helper 被
-- 用来探测他人的固定项。
-- ---------------------------------------------------------------------------
create or replace function public.home_fixed_item_has_external_projection(
  p_item_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select exists (
    select 1
    from public.home_external_fixed_payment_projections p
    join public.home_fixed_month_items i on i.id = p.fixed_month_item_id
    where p.fixed_month_item_id = p_item_id
      and i.user_id = auth.uid()
  );
$function$;

comment on function public.home_fixed_item_has_external_projection(uuid) is
  'Narrow security definer predicate: does this caller-owned fixed month item '
  'have an external fixed payment projection. Exists so that security invoker '
  'writers can run their projection guard without any direct grant on '
  'home_external_fixed_payment_projections. Returns a boolean only.';

-- ---------------------------------------------------------------------------
-- helper 2：某月份 / 币种 /（可选）方向范围内是否存在 External projection
--
-- 用于 home_update_fixed_month_items_status（传 direction）与月份/模板同步
-- writer（不传 direction）。归属恒按 auth.uid() 限定，与原内联查询一致。
-- ---------------------------------------------------------------------------
create or replace function public.home_fixed_scope_has_external_projection(
  p_month_key text,
  p_currency text,
  p_direction text default null
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select exists (
    select 1
    from public.home_external_fixed_payment_projections p
    join public.home_fixed_month_items i on i.id = p.fixed_month_item_id
    where i.user_id = auth.uid()
      and i.month_key = p_month_key
      and i.currency = p_currency
      and (p_direction is null or i.direction = p_direction)
  );
$function$;

comment on function public.home_fixed_scope_has_external_projection(text, text, text) is
  'Narrow security definer predicate: does the caller own any fixed month item '
  'in this month/currency (and optional direction) that has an external fixed '
  'payment projection. Pass NULL direction to cover both directions. Returns a '
  'boolean only.';

-- ---------------------------------------------------------------------------
-- 权限：owner 固定为 postgres，仅授 execute，不触碰任何表权限。
-- ---------------------------------------------------------------------------
alter function public.home_fixed_item_has_external_projection(uuid)
  owner to postgres;
alter function public.home_fixed_scope_has_external_projection(text, text, text)
  owner to postgres;

revoke all on function public.home_fixed_item_has_external_projection(uuid)
  from public, anon;
revoke all on function public.home_fixed_scope_has_external_projection(text, text, text)
  from public, anon;

grant execute on function public.home_fixed_item_has_external_projection(uuid)
  to authenticated, service_role;
grant execute on function public.home_fixed_scope_has_external_projection(text, text, text)
  to authenticated, service_role;

commit;

-- ===========================================================================
-- 调用点替换规格（本文件不执行，须对照生产定义套用）
-- ===========================================================================
--
-- 执行方须先 dump 生产定义再替换，不得照抄仓库 SQL：
--   select pg_get_functiondef(to_regprocedure('<signature>'));
--
-- 替换 A — public.home_update_fixed_month_item_status(uuid, text)
--   原：
--     if exists(select 1 from public.home_external_fixed_payment_projections p
--               where p.fixed_month_item_id=v_item.id) then
--   改：
--     if public.home_fixed_item_has_external_projection(v_item.id) then
--   返回的 code / message 保持 HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN 不变。
--   前置条件：该分支之前已用 user_id=auth.uid() 取得 v_item。执行方须确认。
--
-- 替换 B — public.home_update_fixed_month_items_status(text, text, text, text)
--   原：
--     if exists(select 1 from public.home_external_fixed_payment_projections p
--               join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
--               where i.user_id=auth.uid() and i.month_key=p_month_key
--                 and i.currency=p_currency and i.direction=p_direction) then
--   改：
--     if public.home_fixed_scope_has_external_projection(
--          p_month_key, p_currency, p_direction) then
--   code / message 保持 HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN 不变。
--
-- 替换 C — 固定项删除 writer（生产签名待执行方确认）
--   原：
--     if exists(select 1 from public.home_external_fixed_payment_projections p
--               where p.fixed_month_item_id=v_item.id) then
--   改：
--     if public.home_fixed_item_has_external_projection(v_item.id) then
--   code / message 保持 HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN 不变。
--   前置条件同替换 A：须确认该分支之前已按 auth.uid() 取得 v_item。
--
-- 替换 D — 月份 / 模板同步 writer（生产签名待执行方确认）
--   原：
--     if exists(select 1 from public.home_external_fixed_payment_projections p
--               join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
--               where i.user_id=auth.uid() and i.month_key=p_month_key
--                 and i.currency=p_currency) then
--   改：
--     if public.home_fixed_scope_has_external_projection(
--          p_month_key, p_currency) then
--   code / message 保持 HOME_PROJECTION_FIXED_ITEM_SYNC_FORBIDDEN 不变。
--
-- 替换后须逐个确认：四个 writer 的 security invoker 属性、owner、
-- search_path 与 grant 均未改变；函数体除上述谓词外无其他差异。
-- ===========================================================================
