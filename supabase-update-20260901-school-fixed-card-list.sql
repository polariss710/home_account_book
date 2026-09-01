-- School 固定信用卡路线 —— 可选卡列表 RPC
--
-- 日期：2026-09-01
-- 起因：School 侧新增卡选择入口时，第一版直接从 Edge 用 service_role 查
--       home_card_instruments，被审核拦下。生产实查：
--         表 ACL   {postgres=arwdDxtm/postgres}
--         RLS      启用，0 条 policy
--         实测     42501 permission denied for table home_card_instruments
--       service_role 虽有 BYPASSRLS，但那绕过的是 policy，不是表级 grant，
--       两者不能互相替代。
--
-- ===========================================================================
-- 为什么是窄 RPC 而不是给 service_role 开表级 SELECT
-- ===========================================================================
--
-- home_card_instruments 目前只有 postgres 一个 grant、零 policy，这个配置
-- 本身就是「这张表不打算对外」的表态。给 service_role 开整表 SELECT 会连
-- funding_payment_channel_id、household_statement_template_id、version 这些
-- 与 School 无关的内部字段一并暴露。
--
-- 本函数只返回 School 展示卡列表所必需的四个字段，其余一律不出库。
--
-- ===========================================================================
-- 为什么返回未启用的卡
-- ===========================================================================
--
-- 只按 is_active 过滤，不按 is_school_fixed_route_enabled 过滤。后者是路线
-- Gate，当前西武卡为 false；若一并用作过滤条件，Gate 未开时 School 只会拿到
-- 空列表，无法区分「没有卡」与「卡还没启用」。改为把未启用的卡也返回并带
-- cash_route_enabled 标记，由 School 前端显示成不可选状态。
--
-- ===========================================================================
-- 字段为什么叫 cash_route_enabled 而不是 route_enabled
-- ===========================================================================
--
-- 该值只等于 Cash 侧的一条 Gate：is_active and is_school_fixed_route_enabled，
-- 与 home_get_school_fixed_card_schedule 返回的 route_enabled 同源。
--
-- 但它为 true 并不代表这张卡当下可以提交。完整提交还要过 School Gate
-- cash_fixed_credit_card_route_enabled（当前生产仍为 blocked）、卡币种与支出
-- 币种一致、卡归属与 cash_user_id 一致、funding channel 有效等。
--
-- 叫 route_enabled 会让 School 前端误以为「true 即可选」。带 cash_ 前缀是为了
-- 在字段名上就说明它只是众多条件之一。
--
-- ===========================================================================
-- 单用户假设
-- ===========================================================================
--
-- 本函数不按 user_id 过滤，与 School Edge 既有的 listEligibleAccounts 一致
-- （后者直接查 home_accounts 也未过滤 user）。当前 Cash 是单用户系统，该假设
-- 成立。若将来引入多用户，本函数会跨用户泄漏卡列表，届时须加 user 维度——
-- 但 School 侧并不知道 cash_user_id（它是从 schedule 函数反查得到的），
-- 所以那时需要的是重新设计调用契约，而不是简单加一个参数。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   drop function if exists public.home_list_school_fixed_route_cards();
--
--   本函数为纯新增，不改动任何既有对象。回滚后 School 侧卡列表入口会失败，
--   但固定信用卡提交路径本身不受影响（它走 home_get_school_fixed_card_schedule，
--   与本函数无关）。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

create or replace function public.home_list_school_fixed_route_cards()
returns table(
  card_instrument_id uuid,
  name text,
  settlement_currency text,
  cash_route_enabled boolean
)
language plpgsql
stable
security definer
set search_path to 'pg_catalog', 'public'
as $function$
begin
  -- 与 home_get_school_fixed_card_schedule 同样的调用方限制：只有 School Edge
  -- 持 service_role 时可调。DEFINER 使本函数以 owner 身份读表，因此这道校验
  -- 是唯一的入口约束，不能省。
  if coalesce(auth.role(), '') <> 'service_role' then
    raise exception using
      errcode = '42501',
      message = 'HOME_SCHOOL_CARD_LIST_SERVICE_ROLE_REQUIRED';
  end if;

  return query
  select
    c.id,
    c.name,
    c.settlement_currency,
    (c.is_active and c.is_school_fixed_route_enabled)
  from public.home_card_instruments c
  where c.is_active
  order by c.settlement_currency, c.name;
end;
$function$;

-- 见 docs/lessons.md A3——新建函数时 Supabase default privileges 会自动授予
-- anon / authenticated / service_role，必须显式撤销后再按需授予。
-- 本函数只对 service_role 开放，anon 与 authenticated 一律无权。
revoke all on function public.home_list_school_fixed_route_cards() from public, anon, authenticated, service_role;
grant execute on function public.home_list_school_fixed_route_cards() to service_role;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、ACL —— 必须用 proacl 直接匹配，不能用 has_function_privilege
--     （见 docs/lessons.md：后者把继承权限也算作有权限，测不出 revoke 效果）
--
--     select proacl from pg_proc
--     where proname = 'home_list_school_fixed_route_cards';
--
--     预期恰好为 {postgres=X/postgres,service_role=X/postgres}
--     出现 anon= 或 authenticated= 或 =X/（PUBLIC）任一均算失败
--
-- 二、以 service_role 调用
--     预期返回 1 行：
--       card_instrument_id  9b27347e-2dce-4caf-bac0-67f053ef6c3b
--       name                西武卡
--       settlement_currency JPY
--       cash_route_enabled  false     ← Gate 未开，符合预期
--
-- 三、以 authenticated 调用
--     预期在权限层即被拒（42501 permission denied for function），
--     不应进入函数体、不应看到 HOME_SCHOOL_CARD_LIST_SERVICE_ROLE_REQUIRED。
--     若看到后者，说明 grant 收得不干净。
--
-- 四、以 anon 调用
--     同上，预期权限层拒绝。
--
-- 五、不受影响
--     1. home_card_instruments 的表 ACL / RLS / policy 数量均无变化
--        （本次不碰表，仅新增函数）
--     2. home_get_school_fixed_card_schedule 定义未变
--     3. 固定信用卡提交路径行为不变
--
-- ===========================================================================
