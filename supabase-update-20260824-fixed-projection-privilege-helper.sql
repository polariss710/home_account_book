\set ON_ERROR_STOP on

-- Home / Cash：修复固定项 writer 因无法读取 projection 表而报 42501
--
-- 修订记录
-- --------
-- 2026-08-24 初稿由 Claude Code 依据仓库 SQL 编写，其中四处判断被 Codex 的生产
-- 只读审计推翻，本文件为修正版。被推翻的内容与更正见「诊断」一节的脚注。
-- 本文件所有生产事实均出自 2026-08-24 Codex 的 pg_get_functiondef 与目录查询。
--
-- 诊断
-- ----
-- public.home_external_fixed_payment_projections 建于 2026-08-19 的 phase3c3b。
-- 生产实际状态：
--
--   authenticated SELECT/INSERT/UPDATE/DELETE = false / false / false / false
--   relrowsecurity      = true
--   relforcerowsecurity = false
--   policy_count        = 0
--   relacl              = {postgres=arwdDxtm/postgres}
--
-- 即：表启用了 RLS 但没有任何 policy，且 authenticated 对该表无任何权限。
--
-- 三个 security invoker 函数直接 select 该表，调用者身份必然失败：
--
--   home_update_fixed_month_item_status(uuid, text)                单项状态
--   home_update_fixed_month_items_status(text, text, text, text)   批量状态
--   home_sync_fixed_month_items(text, text)                        月份/模板同步
--
-- 第四个受影响入口是固定垫付：
--
--   home_create_fixed_advance_payment(text, text, text, uuid, date, text)
--
-- 用户可复现的症状：日元固定收支页把固定收入状态从未付改为已付，报
--   固定项状态更新失败：permission denied for table home_external_fixed_payment_projections
--
-- 这些 select 的本意是拒绝 School 信用卡 projection 关联的固定项走普通 writer，
-- 应返回 HOME_PROJECTION_FIXED_ITEM_*_FORBIDDEN 之类的业务文案。守卫读不到自己
-- 要守的表，结果是对所有固定项无差别 42501。按 AGENTS.md「Privilege And
-- Function Security Boundary」属 P0 缺陷。
--
-- 初稿被推翻的四点（保留记录，避免重蹈）：
--   1. 初稿称该表「未启用 RLS」。实际 relrowsecurity=true、policy_count=0。
--      这使「整表授权」比初稿判断的更危险：即使授予 SELECT，RLS 在零 policy 下
--      会把结果过滤为空集，exists() 恒为 false，守卫将静默放行——业务违规，
--      比 42501 严重。
--   2. 初稿把删除 writer 列为受影响入口。生产的 home_delete_fixed_month_item(uuid)
--      及其 _core 与 eligibility helper 均为 security definer，projection 读取
--      已在 definer 链内部，不受此缺陷影响。删除链本次不改动。
--   3. 初稿遗漏了真正的第四个 invoker：home_create_fixed_advance_payment。
--      其谓词除用户/月份/币种/direction 外，还按
--      coalesce(i.payment_group,'未分组') 过滤。
--   4. 初稿的 scope helper 没有 payment_group 参数，用于固定垫付会把
--      「只拦当前支付分组」变成「同月同币种任一分组有 projection 就全拦」，
--      属未批准的业务行为变更。本修正版补上该参数。
--
-- 修法
-- ----
-- 不给 authenticated 授予该表权限，也不新增 RLS policy：在 RLS 已启用且零
-- policy 的现状下，授权只会让守卫读到空集从而静默放行。
-- 也不把三个 invoker 整体改为 security definer：那会让函数内所有读取与 DML
-- 一并绕过调用者权限与 RLS，权限面过大。
-- 改为抽取两个只返回布尔值的窄范围 security definer helper。
--
-- 本方案成立的前提（已由生产证据支撑，且由回滚测试守护）：
--   表 owner 为 postgres 且 relforcerowsecurity=false，因此 owner 为 postgres 的
--   security definer helper 不受 RLS 过滤。若将来有人对该表设置 FORCE ROW LEVEL
--   SECURITY，helper 会静默返回 false 而非报错，守卫将无声失效。回滚测试 T8
--   专门守护这一点。
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
-- - 业务负责人已于 2026-08-24 批准本修正合同，含 scope helper 的
--   p_payment_group 参数与上述四处替换集合。

begin;
set local lock_timeout = '8s';
set local statement_timeout = '120s';

-- 前置：核实生产状态与本诊断一致，任一项不符即停止。
do $preflight$
declare
  v_rel record;
begin
  if to_regclass('public.home_external_fixed_payment_projections') is null then
    raise exception 'FIXED_PROJECTION_HELPER_TABLE_MISSING';
  end if;

  if has_table_privilege(
       'authenticated', 'public.home_external_fixed_payment_projections', 'SELECT'
     ) then
    raise exception
      'FIXED_PROJECTION_HELPER_UNEXPECTED_GRANT: authenticated already has SELECT; '
      'diagnosis assumed no grant, stop and re-verify';
  end if;

  select c.relforcerowsecurity, c.relowner
    into strict v_rel
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'home_external_fixed_payment_projections';

  -- helper 依赖「owner 为 postgres 且未 FORCE RLS」才能读到数据。
  -- 任一条不成立，helper 会静默返回 false 而非报错，守卫将无声失效。
  if v_rel.relowner <> 'postgres'::regrole then
    raise exception
      'FIXED_PROJECTION_HELPER_TABLE_OWNER_UNEXPECTED: definer helper would be '
      'subject to RLS filtering and silently return false';
  end if;
  if v_rel.relforcerowsecurity then
    raise exception
      'FIXED_PROJECTION_HELPER_FORCE_RLS_ENABLED: definer helper would be filtered '
      'to an empty set and the guard would silently pass; redesign required';
  end if;
end
$preflight$;

-- ---------------------------------------------------------------------------
-- helper 1：单个固定项是否关联 External projection
--
-- 用于 home_update_fixed_month_item_status。
-- 相比原先的内联 exists，本函数额外按 auth.uid() 限定归属：该调用点已在此前用
-- id=p_item_id and user_id=auth.uid() 取到 v_item（生产定义已确认），因此语义
-- 不变；同时避免本 helper 被用来探测他人的固定项。
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
  'home_external_fixed_payment_projections, which has RLS enabled with zero '
  'policies. Returns a boolean only.';

-- ---------------------------------------------------------------------------
-- helper 2：某月份 / 币种 /（可选）方向 /（可选）支付分组范围内是否存在
--           External projection
--
-- 用于批量状态更新（传 direction）、月份/模板同步（都不传）、固定垫付
-- （传 direction='expense' 与该次垫付的 payment_group）。
--
-- p_payment_group 为 NULL 时不按分组过滤，保持批量状态与同步的原行为；
-- 非 NULL 时按 coalesce(i.payment_group,'未分组') 精确匹配，与固定垫付原谓词
-- 一致。归属恒按 auth.uid() 限定，与三处原内联查询一致。
-- ---------------------------------------------------------------------------
create or replace function public.home_fixed_scope_has_external_projection(
  p_month_key text,
  p_currency text,
  p_direction text default null,
  p_payment_group text default null
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
      and (
        p_payment_group is null
        or coalesce(i.payment_group, '未分组') = p_payment_group
      )
  );
$function$;

comment on function public.home_fixed_scope_has_external_projection(text, text, text, text) is
  'Narrow security definer predicate: does the caller own any fixed month item '
  'in this month/currency, optionally narrowed to a direction and to a payment '
  'group, that has an external fixed payment projection. Pass NULL for either '
  'optional argument to skip that filter. Payment group matching normalises '
  'NULL to 未分組 the same way the advance payment writer does. Returns a '
  'boolean only.';

-- ---------------------------------------------------------------------------
-- 权限：owner 固定为 postgres，仅授 execute，不触碰任何表权限、不新增 policy。
-- ---------------------------------------------------------------------------
alter function public.home_fixed_item_has_external_projection(uuid)
  owner to postgres;
alter function public.home_fixed_scope_has_external_projection(text, text, text, text)
  owner to postgres;

revoke all on function public.home_fixed_item_has_external_projection(uuid)
  from public, anon;
revoke all on function public.home_fixed_scope_has_external_projection(text, text, text, text)
  from public, anon;

grant execute on function public.home_fixed_item_has_external_projection(uuid)
  to authenticated, service_role;
grant execute on function public.home_fixed_scope_has_external_projection(text, text, text, text)
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
--   code / message 保持 HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN 不变。
--   前置条件：该分支之前已用 id=p_item_id and user_id=auth.uid() 取得 v_item，
--   Codex 已于生产定义确认。
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
-- 替换 C — public.home_sync_fixed_month_items(text, text)
--   原：
--     if exists(select 1 from public.home_external_fixed_payment_projections p
--               join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
--               where i.user_id=auth.uid() and i.month_key=p_month_key
--                 and i.currency=p_currency) then
--   改：
--     if public.home_fixed_scope_has_external_projection(
--          p_month_key, p_currency) then
--   code / message 保持 HOME_PROJECTION_FIXED_ITEM_SYNC_FORBIDDEN 不变。
--   注意 direction 与 payment_group 都不传，保持「整月整币种」的原范围。
--
-- 替换 D — public.home_create_fixed_advance_payment(text, text, text, uuid, date, text)
--   原：
--     if exists(select 1 from public.home_external_fixed_payment_projections p
--               join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
--               where i.user_id=auth.uid() and i.month_key=... and i.currency=...
--                 and i.direction='expense'
--                 and coalesce(i.payment_group,'未分组')=v_group) then
--   改：
--     if public.home_fixed_scope_has_external_projection(
--          <月份参数>, <币种参数>, 'expense', v_group) then
--   原 code / message 保持不变。
--   关键：v_group 必须原样传入。漏传会把「只拦当前支付分组」放大成
--   「同月同币种任一分组有 projection 就全拦」，属未批准的业务行为变更。
--   月份与币种参数名以生产定义为准。
--
-- 不替换 — public.home_delete_fixed_month_item(uuid) 及其调用链
--   该 wrapper、home_delete_fixed_month_item_core(uuid,uuid,text) 与
--   home_check_fixed_month_item_delete_eligibility(home_fixed_month_items,uuid)
--   均为 security definer，projection 读取已在 definer 链内部，不受本缺陷影响。
--   且 eligibility helper 返回 corrected / replacement / funding 等分级业务文案，
--   不能替换成单一布尔判断。本次不动删除链。
--
-- 替换后须逐个确认：四个 writer 的 security invoker 属性、owner、search_path
-- 与 grant 均未改变；函数体除上述谓词外无其他差异。
-- ===========================================================================
