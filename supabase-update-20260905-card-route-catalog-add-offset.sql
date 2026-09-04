-- 运维卡目录补上 funding_month_offset —— 让它能核对完整的日期规则
--
-- 日期：2026-09-05
--
-- **依赖顺序（硬性）**：必须在
--   supabase-update-20260905-card-route-catalog-left-join.sql
-- **之后**部署。本文件第 0 步会断言那一步已经生效，没生效就中止。
--
-- 完整链条：
--   1. card-route-catalog-left-join.sql      模板 JOIN 改 LEFT JOIN
--   2. card-household-template-optional.sql  列去 NOT NULL + 校验器跳过
--   3. **本文件**                            目录补 funding_month_offset
--   4. 建支付宝渠道 + 工行卡                 ← 本文件要赶在这一步之前
--
-- ===========================================================================
-- 为什么赶在建卡之前
-- ===========================================================================
--
-- home_card_instruments.funding_month_offset 是 2026-09-03 加的，已纳入
-- home_validate_card_instrument 的**引用后冻结集**——卡一旦被请求、账单周期或
-- projection 引用，这一列就改不动了，只能作废整张卡重建。
--
-- 而这个运维目录返回了 cutoff_day、cutoff_inclusive、funding_day，唯独漏了它。
-- 也就是说：**第一次用这张表核对新建的工行卡时，看到的是一份缺了关键一列的
-- 日期规则**——而 offset 恰恰是工行卡与西武卡在日期推导上的分野（1 vs 0）。
--
-- ⚠️ 但不要因此把它当成「两张卡唯一的不同」（审核 2026-09-05 订正过我这个说法）。
-- 币种、截账日、还款日、还款渠道全都不同，验收时仍须逐项核对。
-- 补这一列只是让这张表**够格被用来核对**，不是让它成为唯一依据。
--
-- ===========================================================================
-- 为什么必须 DROP + CREATE
-- ===========================================================================
--
-- 往 RETURNS TABLE 加列 = 改返回类型。`create or replace` 会直接报
-- 「cannot change return type of existing function」，只能先 DROP。
--
-- 代价与补偿：
--
--   **DROP 会丢掉 ACL。** 目标是 `{postgres=X/postgres}`——这是个 owner-only
--   运维目录，三个客户端角色都没有 EXECUTE（审核 2026-09-05 实测：
--   authenticated / anon / service_role 的有效 EXECUTE 均为 false）。
--   而 Supabase 的 default privileges 会给新建函数自动授予那三个角色，
--   所以建完必须**全撤且不授**，照 docs/lessons.md **A3** 的「内部 helper」模板。
--
--   注意这与 School 侧那次 DROP+CREATE 不同：那个是 service_role 专用，
--   要「先全撤再单授」；本函数是 owner-only，**只撤，不授**。
--   照抄错模板会凭空开出三个外部入口。
--
-- ===========================================================================
-- 新列放在哪
-- ===========================================================================
--
-- 放在 funding_day 之后、funding_payment_channel_id 之前。
--
-- 理由是让日期规则四件套在结果里连着出现：
--   cutoff_day, cutoff_inclusive, funding_day, funding_month_offset
-- 核对的人一眼扫过去就是完整的「账单月怎么定、扣款日怎么定」。
--
-- **这会改变列的位置，不只是追加。** 任何按位置取值的调用方都会受影响——
-- 审核已确认该函数零调用点（函数体引用、catalog 依赖、视图与物化视图均为 0），
-- 所以按位置插入是安全的。若将来它有了程序调用方，再动列顺序就要另行评估。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   begin;
--   drop function public.home_get_card_route_catalog(uuid);
--   -- 恢复 LEFT JOIN 版本（即依赖链第 1 步部署后的定义）。
--   -- ⚠️ 不要恢复成 cash-baseline/...-production-20260905-0014.sql —— 那是
--   --    LEFT JOIN 之前的版本，恢复它会同时把 LEFT JOIN 一起回退，
--   --    从而重新出现「无模板的卡从目录消失」的问题。
--   -- 正确做法：取第 1 步部署后的生产导出，或按那个文件的函数体重建。
--   revoke all on function public.home_get_card_route_catalog(uuid)
--     from public, anon, authenticated, service_role;
--   commit;
--
--   回滚后应重新核对 proacl 精确等于 {postgres=X/postgres}。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 0. 前置断言
--
-- 这里**不用 md5 钉基线**，因为依赖链第 1 步（LEFT JOIN）此刻可能刚部署，
-- 我拿不到它部署后的 md5——那个值只有执行方在现场才知道。
--
-- 改为断言两个**语义事实**，两条合起来同样能挡住「顺序搞错」和「已经改过」：
--
--   a. 当前定义**已经**是 LEFT JOIN  → 证明第 1 步生效了
--   b. 当前定义**还没有** funding_month_offset → 证明本文件没被重复执行
--
-- 执行方请在部署报告里记下部署前的实际 md5，作为本文件的回滚基线。
-- ---------------------------------------------------------------------------

do $$
declare
  v_src text;
  v_count integer;
begin
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'home_get_card_route_catalog';
  if v_count <> 1 then
    raise exception 'ABORT: home_get_card_route_catalog 有 % 个重载，本文件假定唯一', v_count;
  end if;

  select p.prosrc into v_src
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'home_get_card_route_catalog';

  if v_src !~* 'left\s+join\s+public\.home_fixed_templates' then
    raise exception
      'ABORT: 当前定义还不是 LEFT JOIN，说明 card-route-catalog-left-join.sql 尚未部署。本文件必须排在它之后';
  end if;

  if v_src ~* 'funding_month_offset' then
    raise exception 'ABORT: 当前定义已经含 funding_month_offset，本文件可能已经执行过';
  end if;
end $$;

-- 该列必须存在于卡表上，否则新函数体引用它会失败
do $$
begin
  if not exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'home_card_instruments'
      and column_name = 'funding_month_offset'
  ) then
    raise exception 'ABORT: home_card_instruments 上没有 funding_month_offset 列';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. DROP + CREATE
--
-- 与依赖链第 1 步（LEFT JOIN 版本）的差异恰好 2 处：
--   ① RETURNS TABLE 增加 funding_month_offset integer（位于 funding_day 之后）
--   ② select 列表对应位置增加 c.funding_month_offset
--
-- 其余逐字未改：两个 JOIN（渠道 INNER、模板 LEFT）、where、order by、
-- language sql、stable、search_path。
-- ---------------------------------------------------------------------------

drop function public.home_get_card_route_catalog(uuid);

create function public.home_get_card_route_catalog(p_user_id uuid default null::uuid)
returns table(card_instrument_id uuid, user_id uuid, card_name text, settlement_currency text, cutoff_day integer, cutoff_inclusive boolean, funding_day integer, funding_month_offset integer, funding_payment_channel_id uuid, funding_payment_channel_name text, household_statement_template_id uuid, household_statement_template_name text, is_active boolean, is_school_fixed_route_enabled boolean, version bigint)
language sql
stable
set search_path to 'pg_catalog', 'public'
as $function$
  select
    c.id,
    c.user_id,
    c.name,
    c.settlement_currency,
    c.cutoff_day,
    c.cutoff_inclusive,
    c.funding_day,
    c.funding_month_offset,
    c.funding_payment_channel_id,
    pc.name,
    c.household_statement_template_id,
    ft.name,
    c.is_active,
    c.is_school_fixed_route_enabled,
    c.version
  from public.home_card_instruments c
  join public.home_payment_channels pc on pc.id = c.funding_payment_channel_id
  left join public.home_fixed_templates ft on ft.id = c.household_statement_template_id
  where p_user_id is null or c.user_id = p_user_id
  order by c.user_id, c.settlement_currency, c.name, c.id;
$function$;

-- ---------------------------------------------------------------------------
-- 2. ACL —— DROP 丢掉了原 ACL，必须显式重建
--
-- 目标 `{postgres=X/postgres}`：owner-only 运维目录，**只撤不授**。
-- 这是 docs/lessons.md A3 的「内部 helper」模板，不是「service_role 专用」那个
-- ——照抄错模板会凭空开出三个外部入口。
-- ---------------------------------------------------------------------------

revoke all on function public.home_get_card_route_catalog(uuid)
  from public, anon, authenticated, service_role;

comment on function public.home_get_card_route_catalog(uuid) is
  'Owner-only operations catalog. No client role has direct EXECUTE.';

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 零、前置断言能证伪（E3）
--   a. 在 LEFT JOIN 尚未部署的环境上跑本文件 → 期望 ABORT: 当前定义还不是 LEFT JOIN
--   b. 连跑两次本文件 → 第二次期望 ABORT: 已经含 funding_month_offset
--   c. rollback-only 删掉卡表那一列 → 期望 ABORT: 没有 funding_month_offset 列
--
-- 一、逐行 diff（E2）
--   与依赖链第 1 步部署后的生产定义比，**期望恰好 2 处**：
--   RETURNS TABLE 多一列、select 列表多一行。两个 JOIN、where、order by
--   必须逐字相同。出现第 3 处即为转录错误。
--
-- 二、结构与权限（A3）—— 本文件最容易出错的地方
--   1. 只有一个重载；返回类型为 **15 列**（原 14 列 + funding_month_offset）
--   2. **proacl 精确等于 {postgres=X/postgres}**
--      —— 不要只查「有没有 anon」。authenticated / anon / service_role
--      三者的有效 EXECUTE 都应为 **false**
--   3. owner=postgres、prosecdef=false（INVOKER）、
--      proconfig={search_path=pg_catalog, public}、STABLE 均与部署前一致
--   4. comment 仍为 owner-only operations catalog
--
-- 三、现有数据正确（只读）
--   目前生产只有西武卡一行：
--     funding_month_offset 应返回 **0**
--     其余 14 列与部署前逐列相同
--   若工行卡此时已建（不该，本文件应在建卡之前），它应返回 1。
--
-- 四、列顺序确实变了，且没有调用方受影响
--   1. 确认 funding_month_offset 位于 funding_day 与 funding_payment_channel_id 之间
--   2. 重新跑一遍零调用点核查（函数体引用、catalog 依赖、视图、物化视图），
--      确认仍为 0 —— 按位置插入的前提就是没有程序调用方
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 1. **依赖链第 1 步部署后的实际函数体。** 本文件的「差异恰好 2 处」是相对
--    LEFT JOIN 版本说的，而那个版本此刻还没部署，我比对的是它的源文件而不是
--    生产定义。请在部署本文件前先导出第 1 步部署后的实际定义再做 diff。
--
-- 2. **仓库外是否有脚本按位置读这个目录。** 审核已确认库内零调用点，
--    但也说明「未核查外部脚本或完整历史日志」。插入列会打乱位置，
--    若真有这种脚本，它会静默读错列。风险低（owner-only、客户端角色无 EXECUTE），
--    但插入而非追加是我的选择，代价记在这里。
--
--    追加到末尾可以避免这个风险，代价是日期规则四件套在结果里被拆散。
--    我认为可读性更重要，因为这张表的唯一用途就是给人核对——但这是个判断，
--    不是事实，可以推翻。
--
-- ===========================================================================
