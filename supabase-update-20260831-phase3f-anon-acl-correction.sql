-- Phase 3F 补正 —— 收回新 writer 的 anon 执行权限
--
-- 日期：2026-08-31
-- 前序：supabase-update-20260831-phase3f-projection-status.sql
--
-- ===========================================================================
-- 为什么需要补这一条
-- ===========================================================================
--
-- Phase 3F 主文件里写的是：
--     revoke all on function ... from public;
--     grant execute on function ... to authenticated;
--
-- 只撤了 PUBLIC，没有撤 anon。而 Supabase 的 default privileges 会把新建函数
-- 自动授予 anon / authenticated / service_role，因此部署后实际 ACL 仍包含 anon。
--
-- PostgreSQL 语义提醒（同一天在 School 侧刚栽过）：
--     revoke ... from public  只撤 PUBLIC 伪角色
--     revoke ... from anon    只撤直接授予 anon 的部分
--   二者互不覆盖。Supabase 的 default privileges 属于「直接授予 anon」，
--   所以必须显式 revoke from anon，撤 public 不管用。
--
-- ===========================================================================
-- 实际风险等级：低，但仍应收回
-- ===========================================================================
--
-- home_confirm_projection_fixed_item_status 函数体内以 auth.uid() 自校验：
--     where id = p_item_id and user_id = auth.uid()
-- anon 调用时 auth.uid() 为 NULL，该条件永不匹配，只会返回
-- 「没有找到可更新的固定项」，改不动任何数据。
--
-- 因此这不是可利用的漏洞，而是不符合最小权限原则。收回的理由是：
--   1. 该函数是 SECURITY DEFINER，以 postgres 权限运行，攻击面不应对匿名开放
--   2. 与 2026-08-28 在 School 侧完成的 anon 权限收口保持一致
--   3. 依赖「函数体内碰巧有自校验」来保证安全，属于隐式防护，不该作为设计前提
--
-- ===========================================================================
-- 新建 / 重建函数时的检查项（记下来，避免重复）
-- ===========================================================================
--
-- 【2026-09-01 修正】本节最初写的是一条固定模板：
--     revoke all on function <fn> from public, anon;
--     grant execute on function <fn> to authenticated;
-- 那是错的。它假定目标状态一定是「authenticated 可执行」，对业务 writer 成立，
-- 对内部 helper 不成立。
--
-- 实例：home_check_fixed_month_item_delete_eligibility 的 proacl 本来是
-- {postgres=X/postgres}，只被两个 SECURITY DEFINER 函数以 postgres 身份调用，
-- 从不对外暴露。重建它时若套用上面的模板，Supabase default privileges 会自动
-- 授予 anon / authenticated / service_role，而模板只撤前两者，等于凭空给
-- authenticated 和 service_role 开了一个入口。
--
-- 正确做法：
--   1. 动手前先查该对象**原本**的 ACL
--        select proacl from pg_proc where proname = '<fn>';
--   2. 按原 ACL 决定 revoke 到什么程度，而不是套模板
--        对外 writer      → revoke from public, anon; grant to authenticated
--        内部 helper      → revoke from public, anon, authenticated, service_role
--   3. 部署后复核 proacl 是否与预期精确相等，不要只查「有没有 anon」——
--      default privileges 一次授予三个角色，任一残留都是权限边界变化
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

revoke all on function public.home_confirm_projection_fixed_item_status(uuid, text) from anon;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
--   select has_function_privilege('anon','public.home_confirm_projection_fixed_item_status(uuid,text)'::regprocedure,'EXECUTE');
--     → 期望 false
--
--   select has_function_privilege('authenticated','public.home_confirm_projection_fixed_item_status(uuid,text)'::regprocedure,'EXECUTE');
--     → 期望 true（不得被误伤）
--
--   select proacl from pg_proc where proname='home_confirm_projection_fixed_item_status';
--     → ACL 中不应再出现 anon= 项
--
-- 回滚（若确需恢复）：
--   grant execute on function public.home_confirm_projection_fixed_item_status(uuid, text) to anon;
-- ===========================================================================
