-- 运维卡目录：家庭模板改为 LEFT JOIN —— 配合模板可空，避免整行漏卡
--
-- 日期：2026-09-05
-- 配套：supabase-update-20260904-card-household-template-optional.sql
--       **两个文件必须一起部署**，顺序不限但不能只上一个：
--         只上可空 → 没有家庭模板的卡从本目录消失（审核 P2 指出的就是这个）
--         只上本文件 → LEFT JOIN 生效但列仍 NOT NULL，行为与今天完全相同，无害
--       所以真要拆，也应当先上本文件。
--
-- 基线（2026-09-05 00:14 生产只读导出）：
--   home_get_card_route_catalog(uuid)  md5 12c2cc7794e8329e74887d1825231d5e
--
-- ===========================================================================
-- 改什么
-- ===========================================================================
--
-- 一个关键字：
--
--   join public.home_fixed_templates ft on ft.id = c.household_statement_template_id
--   →
--   left join public.home_fixed_templates ft on ft.id = c.household_statement_template_id
--
-- 其余逐字未改：返回列表、还款渠道那个 INNER JOIN、where、order by、
-- STABLE、search_path、语言。
--
-- **还款渠道保持 INNER JOIN**：funding_payment_channel_id 仍是 NOT NULL，
-- 卡必然有还款渠道。只有家庭模板变成可选。
--
-- ===========================================================================
-- 空模板时返回什么
-- ===========================================================================
--
-- `household_statement_template_id` 与 `household_statement_template_name` 均为 NULL。
--
-- **不塞占位文案**（审核建议，采纳）。这是原始目录 reader，「没有绑定」就该老实
-- 返回 NULL；要显示成「（无家庭消费）」之类是展示层的事。在 reader 里编一个字符串，
-- 会让下游无法区分「没绑定」与「绑了一个叫这个名字的模板」。
--
-- 顺带说明这两列的来源不同，容易看混：
--   household_statement_template_id   来自 **c**（卡表本身）
--   household_statement_template_name 来自 **ft**（模板表，本次改成 LEFT JOIN 的那个）
-- 所以 LEFT JOIN 之后 id 仍会返回卡上存的值——只是当它为 NULL 时 name 也跟着 NULL。
--
-- ===========================================================================
-- 顺带记录一个不在本轮范围的缺口
-- ===========================================================================
--
-- **本目录的返回列里没有 funding_month_offset。**
--
-- 那一列 2026-09-03 加入 home_card_instruments，且已纳入
-- home_validate_card_instrument 的引用后冻结集——也就是说它和 cutoff_day /
-- funding_day 一样，是决定固定项落在哪个月、哪天扣款的配置字段。
--
-- 而这个目录返回了 cutoff_day、cutoff_inclusive、funding_day，唯独漏了它。
-- 用这个目录核对卡配置的人会看到一份**不完整的日期规则**。
--
-- ⚠️ 措辞订正（审核 2026-09-05）：初稿写「工行卡与西武卡的区别恰恰就在这一列」，
-- **不准确**。两张卡的币种、截账日、还款日、还款渠道全都不同，offset 只是其中
-- 一个关键项。写成「唯一不同」会诱导验收时只盯这一列——建卡后仍须逐项核对。
--
-- 本文件**有意不补**：往 RETURNS TABLE 加列会改变返回类型，
-- create or replace 会直接报错，必须 DROP + CREATE，还要重建 ACL
-- （目标 {postgres=X/postgres}）。那是另一类改动，不该混进一个一关键字的修复里。
-- 建议单独一轮，且在建工行卡**之前**做完——否则第一次用这个目录核对新卡时，
-- 看到的就是缺了关键一列的配置。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   从 cash-baseline/home_get_card_route_catalog-production-20260905-0014.sql
--   恢复（该文件本身就是可执行的 CREATE OR REPLACE）。
--
--   签名与 ACL 不变，回滚只是换回函数体。
--   ⚠️ 若此时已存在家庭模板为 NULL 的卡，恢复 INNER JOIN 之后它们会从目录里消失
--   ——这正是本文件要修的症状。回滚前先确认可空那个文件是否也要一起回滚。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 0. 生产基线断言（失败关闭）
-- ---------------------------------------------------------------------------

do $$
declare
  v_actual text;
  v_count integer;
begin
  select count(*) into v_count
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'home_get_card_route_catalog';
  if v_count <> 1 then
    raise exception 'ABORT: home_get_card_route_catalog 有 % 个重载，本文件假定唯一', v_count;
  end if;

  select md5(p.prosrc) into v_actual
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'home_get_card_route_catalog';
  if v_actual is distinct from '12c2cc7794e8329e74887d1825231d5e' then
    raise exception 'ABORT: home_get_card_route_catalog 已漂移，期望 12c2cc7794e8329e74887d1825231d5e，实际 %', v_actual;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. 只把模板那个 JOIN 改成 LEFT JOIN
--
-- 与基线的差异**恰好 1 个词**。返回列表逐字未改，因此返回类型不变，
-- create or replace 可用、ACL 自动保留（目标 {postgres=X/postgres}）。
-- ---------------------------------------------------------------------------

create or replace function public.home_get_card_route_catalog(p_user_id uuid default null::uuid)
returns table(card_instrument_id uuid, user_id uuid, card_name text, settlement_currency text, cutoff_day integer, cutoff_inclusive boolean, funding_day integer, funding_payment_channel_id uuid, funding_payment_channel_name text, household_statement_template_id uuid, household_statement_template_name text, is_active boolean, is_school_fixed_route_enabled boolean, version bigint)
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

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 零、基线断言能证伪（E3）
--   rollback-only 改动函数正文 → 期望 ABORT: … 已漂移
--
-- 一、逐行 diff（E2）
--   与 cash-baseline/home_get_card_route_catalog-production-20260905-0014.sql 比，
--   **期望恰好 1 个词的差异**（join → left join）。
--   返回列表、还款渠道 JOIN、where、order by 必须逐字相同。
--   出现第 2 处即为转录错误。
--
-- 二、结构与权限
--   1. 只有一个重载；返回类型（14 列及其类型顺序）与部署前逐字相同
--   2. **proacl 仍为 {postgres=X/postgres}** —— 本文件用 create or replace，
--      不该出现任何权限变化。三个客户端角色的有效 EXECUTE 应仍为 false
--   3. owner=postgres、prosecdef=false（INVOKER）、
--      proconfig={search_path=pg_catalog, public}、STABLE 均未变
--
-- 三、现有数据逐行不变（最重要的一条）
--   目前生产只有西武卡一行，且它**有**家庭模板，所以 LEFT JOIN 与 INNER JOIN
--   的结果必须**完全相同**。
--   部署前后各跑一次 `select * from home_get_card_route_catalog()`，
--   逐列比对应当零差异。**这一条不过就说明我改坏了别的地方。**
--
-- 四、空模板不再漏行（rollback-only）
--   前提：模板可空那个文件已部署。
--   在 rollback-only 事务里建一张 household_statement_template_id 为 NULL 的卡，
--   然后查本目录：
--     1. 该卡**出现**在结果里（这就是本文件要修的）
--     2. 它的 household_statement_template_id 与 household_statement_template_name
--        **都是 NULL**，没有被塞进任何占位文案
--     3. 其余列正常，特别是 funding_payment_channel_name 有值
--        （还款渠道仍是 INNER JOIN，卡必然有渠道）
--
-- 五、还款渠道那个 INNER JOIN 没被顺手改掉
--   构造一张卡指向不存在的 funding_payment_channel_id 是不可能的（有 FK），
--   所以改判：直接读函数体确认 `join public.home_payment_channels` 前面
--   **没有** left 字样。
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 1. **这个目录是否真的只有人工在用。** 审核已查：函数体引用、catalog 依赖、
--    视图与物化视图引用均为 0，三个客户端角色无 EXECUTE，注释写明 owner-only。
--    但审核也说明「未核查外部脚本或完整历史日志」。若某个仓库外的运维脚本
--    依赖「模板必然非空」这个隐含前提，LEFT JOIN 之后它会拿到 NULL。
--    风险低（该列本来就要变成可空），但值得在部署报告里点一句。
--
-- 2. **funding_month_offset 缺列的影响面。** 见上文「顺带记录」。我没有查过
--    是否有人正在用这个目录核对卡配置，只是从「它列出了其余日期字段却漏了这个」
--    推断它本该在。若确认无人使用，补列的优先级可以降低；
--    但工行卡建卡前后一定会有人来看这张表。
--
-- ===========================================================================
