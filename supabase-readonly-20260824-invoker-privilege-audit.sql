\set ON_ERROR_STOP on
\pset pager off

-- Home / Cash：security invoker 函数引用无权限表的全量审计（只读）
--
-- 为什么需要这个
-- --------------
-- 2026-08-24 修掉 home_external_fixed_payment_projections 的 42501 之后，
-- 端到端测试立刻在同一批 writer 上撞到第二张表 home_card_statement_cycles，
-- 症状完全相同。两次都是同一个缺陷类：
--
--   security invoker 函数直接引用了调用者没有权限的表
--   → 语句执行即 42501
--   → 若该引用是业务守卫，守卫无法判断，对所有记录无差别失败
--
-- 逐张表修是打地鼠。本脚本一次列出全部组合，用来确定真实爆炸半径，
-- 之后一轮修完。
--
-- 本脚本只读：仅查询系统目录与 has_table_privilege，不读业务数据、
-- 不调用任何 RPC、不写库。可安全在生产执行。
--
-- Run:
--   psql "$CASH_SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
--     -f supabase-readonly-20260824-invoker-privilege-audit.sql

begin read only;
set local statement_timeout = '120s';

\echo ''
\echo '=== 1. public 下 authenticated 缺少 SELECT 的表 ==='
\echo ''

select
  c.relname                                        as table_name,
  c.relrowsecurity                                 as rls_enabled,
  c.relforcerowsecurity                            as rls_forced,
  c.relowner::regrole::text                        as owner,
  (select count(*) from pg_policies pol
    where pol.schemaname = 'public'
      and pol.tablename = c.relname)               as policy_count,
  has_table_privilege('authenticated', c.oid, 'SELECT') as auth_select,
  has_table_privilege('anon', c.oid, 'SELECT')          as anon_select
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relkind in ('r', 'p')
  and not has_table_privilege('authenticated', c.oid, 'SELECT')
order by c.relname;

\echo ''
\echo '=== 2. 爆炸半径：invoker 函数 × 无权限表 ==='
\echo '    每一行都是一个潜在 42501。已修复的引用不会出现在这里。'
\echo ''

with ungranted as (
  select c.oid, c.relname
  from pg_class c
  join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relkind in ('r', 'p')
    and not has_table_privilege('authenticated', c.oid, 'SELECT')
),
invokers as (
  select p.oid, p.oid::regprocedure::text as sig, pg_get_functiondef(p.oid) as def
  from pg_proc p
  join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public'
    and not p.prosecdef
    and p.prokind = 'f'
)
select
  i.sig                                              as invoker_function,
  u.relname                                          as ungranted_table,
  has_function_privilege('authenticated', i.oid, 'EXECUTE') as auth_can_call
from invokers i
join ungranted u
  -- 词边界匹配，避免 foo 命中 foo_bar。宁可多报不可漏报。
  on i.def ~ ('\m' || u.relname || '\M')
order by
  -- authenticated 能调用的排前面：那些是真正会在生产触发的
  has_function_privilege('authenticated', i.oid, 'EXECUTE') desc,
  i.sig,
  u.relname;

\echo ''
\echo '=== 3. 汇总 ==='
\echo ''

with ungranted as (
  select c.oid, c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p')
    and not has_table_privilege('authenticated', c.oid, 'SELECT')
),
invokers as (
  select p.oid, p.oid::regprocedure::text as sig, pg_get_functiondef(p.oid) as def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and not p.prosecdef and p.prokind = 'f'
),
hits as (
  select i.oid as fn_oid, i.sig, u.relname,
         has_function_privilege('authenticated', i.oid, 'EXECUTE') as callable
  from invokers i join ungranted u on i.def ~ ('\m' || u.relname || '\M')
)
select
  (select count(*) from ungranted)                              as ungranted_tables,
  (select count(*) from invokers)                               as invoker_functions,
  (select count(*) from hits)                                   as total_hits,
  (select count(*) from hits where callable)                    as hits_callable_by_authenticated,
  (select count(distinct fn_oid) from hits where callable)       as affected_functions,
  (select count(distinct relname) from hits where callable)      as affected_tables;

\echo ''
\echo '=== 4. 受影响函数按被 authenticated 可调用性分组 ==='
\echo ''

with ungranted as (
  select c.oid, c.relname
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind in ('r', 'p')
    and not has_table_privilege('authenticated', c.oid, 'SELECT')
),
invokers as (
  select p.oid, p.oid::regprocedure::text as sig, pg_get_functiondef(p.oid) as def
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and not p.prosecdef and p.prokind = 'f'
)
select
  i.sig                                        as invoker_function,
  string_agg(u.relname, ', ' order by u.relname) as ungranted_tables,
  count(*)                                     as table_count
from invokers i
join ungranted u on i.def ~ ('\m' || u.relname || '\M')
where has_function_privilege('authenticated', i.oid, 'EXECUTE')
group by i.sig
order by count(*) desc, i.sig;

rollback;

-- ===========================================================================
-- 读法
-- ===========================================================================
--
-- 第 2 节每一行都是一个潜在 42501。`auth_can_call = true` 的那些是真正会在
-- 生产触发的——用户点得到。false 的那些当前不可达，但仍是隐患，因为将来
-- 一旦授予 EXECUTE 就会立刻暴露。
--
-- 第 1 节的 rls_enabled / policy_count 决定了修法：
--   - RLS 启用且 policy_count=0：绝不能靠 grant SELECT 修。授权后查询会被
--     过滤为空集，exists() 恒 false，守卫静默放行——业务违规，比 42501 更糟。
--     必须走 owner 为 postgres 的窄范围 security definer helper。
--   - rls_forced=true：连 definer helper 也会被过滤，必须重新设计。
--   - RLS 未启用：grant 在技术上可行，但要单独评估数据可见范围，
--     且仍需业务负责人批准（属权限边界变更）。
--
-- 修的时候按第 4 节分组，一个函数一次改完它引用的所有无权限表，
-- 不要一张表一张表地试。
-- ===========================================================================
