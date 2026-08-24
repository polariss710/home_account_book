\set ON_ERROR_STOP on

-- Home / Cash：固定项 projection 权限 helper 的回滚测试
--
-- 不读写任何业务表、不调用任何 writer RPC。仅读系统目录，并对两个 helper 做
-- 无数据的 smoke test。事务末尾 rollback。
--
-- 执行顺序：先跑 supabase-update-20260824-fixed-projection-privilege-helper.sql
-- 与该文件文末的四处调用点替换，再跑本文件。T5 在替换完成前会失败，这是预期——
-- 它正是替换的验收条件。
--
-- 2026-08-24 修正：初版 T6 的注释声称检查四个 writer，实际数组只有两个；且把
-- 删除 writer 误当作受影响入口，遗漏了真正的第四个 invoker
-- home_create_fixed_advance_payment。签名以 Codex 的生产目录查询为准。
--
-- Run:
--   psql "$CASH_SUPABASE_DB_URL" -v ON_ERROR_STOP=1 \
--     -f supabase-test-20260824-fixed-projection-privilege-helper-rollback.sql

begin;
set local statement_timeout = '120s';

-- ---------------------------------------------------------------------------
-- T1  两个 helper 存在，且各只有一个重载。
-- ---------------------------------------------------------------------------
do $t1$
declare
  v_name text;
  v_count integer;
begin
  foreach v_name in array array[
    'home_fixed_item_has_external_projection',
    'home_fixed_scope_has_external_projection'
  ] loop
    select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    if v_count = 0 then
      raise exception 'T1_HELPER_MISSING: %', v_name;
    end if;
    if v_count > 1 then
      raise exception 'T1_HELPER_OVERLOADED: % has % overloads', v_name, v_count;
    end if;
  end loop;

  -- scope helper 必须是四参数版本；三参数版本无法表达固定垫付的
  -- payment_group 过滤，用上去会放大拦截范围。
  if to_regprocedure(
       'public.home_fixed_scope_has_external_projection(text,text,text,text)'
     ) is null then
    raise exception 'T1_SCOPE_HELPER_WRONG_ARITY: expected (text,text,text,text)';
  end if;
end
$t1$;

-- ---------------------------------------------------------------------------
-- T2  helper 必须是 security definer、owner 为 postgres、search_path 已固定、
--     stable。四者缺一都无法安全地代替原内联查询。
-- ---------------------------------------------------------------------------
do $t2$
declare
  v_name text;
  v_rec record;
begin
  foreach v_name in array array[
    'home_fixed_item_has_external_projection',
    'home_fixed_scope_has_external_projection'
  ] loop
    select p.prosecdef, p.proowner, p.proconfig, p.provolatile
      into strict v_rec
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    if not v_rec.prosecdef then
      raise exception 'T2_NOT_SECURITY_DEFINER: %', v_name;
    end if;
    if v_rec.proowner <> 'postgres'::regrole then
      raise exception 'T2_OWNER_NOT_POSTGRES: %', v_name;
    end if;
    if v_rec.proconfig is distinct from array['search_path=pg_catalog, public']::text[] then
      raise exception 'T2_SEARCH_PATH_NOT_PINNED: % has %', v_name, v_rec.proconfig;
    end if;
    if v_rec.provolatile <> 's' then
      raise exception 'T2_NOT_STABLE: %', v_name;
    end if;
  end loop;
end
$t2$;

-- ---------------------------------------------------------------------------
-- T3  execute 只授予 authenticated 与 service_role；public / anon 无权。
-- ---------------------------------------------------------------------------
do $t3$
declare
  v_oid oid;
  v_name text;
  v_role text;
begin
  foreach v_name in array array[
    'home_fixed_item_has_external_projection',
    'home_fixed_scope_has_external_projection'
  ] loop
    select p.oid into strict v_oid
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    foreach v_role in array array['authenticated', 'service_role'] loop
      if not has_function_privilege(v_role, v_oid, 'EXECUTE') then
        raise exception 'T3_EXECUTE_MISSING: % for %', v_name, v_role;
      end if;
    end loop;

    foreach v_role in array array['public', 'anon'] loop
      if has_function_privilege(v_role, v_oid, 'EXECUTE') then
        raise exception 'T3_EXECUTE_LEAKED: % to %', v_name, v_role;
      end if;
    end loop;
  end loop;
end
$t3$;

-- ---------------------------------------------------------------------------
-- T4  回归守卫：projection 表本身仍不得对 authenticated / anon 授予任何表权限，
--     也不得新增 RLS policy。
--
--     本次修复刻意不走「整表授权」那条捷径。该表 RLS 已启用且零 policy，
--     授予 SELECT 会让查询被过滤为空集，exists() 恒为 false，守卫将静默放行——
--     那是业务违规，比 42501 严重。加 policy 同样会扩大数据可见范围。
-- ---------------------------------------------------------------------------
do $t4$
declare
  v_role text;
  v_priv text;
  v_policies integer;
begin
  foreach v_role in array array['authenticated', 'anon', 'public'] loop
    foreach v_priv in array array['SELECT', 'INSERT', 'UPDATE', 'DELETE'] loop
      if has_table_privilege(
           v_role, 'public.home_external_fixed_payment_projections', v_priv
         ) then
        raise exception
          'T4_TABLE_PRIVILEGE_LEAKED: % has % on home_external_fixed_payment_projections; '
          'the fix must stay function-scoped, not table-wide',
          v_role, v_priv;
      end if;
    end loop;
  end loop;

  select count(*) into v_policies
  from pg_policies
  where schemaname = 'public'
    and tablename = 'home_external_fixed_payment_projections';
  if v_policies <> 0 then
    raise exception
      'T4_UNEXPECTED_RLS_POLICY: % policies present; the fix must not add any',
      v_policies;
  end if;
end
$t4$;

-- ---------------------------------------------------------------------------
-- T5  核心不变式：public 下任何 security invoker 函数都不得直接引用
--     home_external_fixed_payment_projections。
--
--     这正是本次缺陷的一般形式——对无授权的表做 select，调用者身份必然 42501。
--     本断言覆盖全部四个受影响 writer，也覆盖将来任何新写的 invoker 函数，
--     不依赖我们是否枚举全了受影响的函数名。初版正是靠这条才会暴露出
--     home_create_fixed_advance_payment 被遗漏。
-- ---------------------------------------------------------------------------
do $t5$
declare
  v_rec record;
  v_offenders text := '';
begin
  for v_rec in
    select p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and not p.prosecdef
      and p.prokind = 'f'
      and pg_get_functiondef(p.oid)
          like '%home_external_fixed_payment_projections%'
    order by 1
  loop
    v_offenders := v_offenders || E'\n  ' || v_rec.sig;
  end loop;

  if v_offenders <> '' then
    raise exception
      'T5_INVOKER_TOUCHES_UNGRANTED_TABLE: 下列 security invoker 函数直接引用了 '
      'home_external_fixed_payment_projections，调用者无表权限时必然 42501：%',
      v_offenders;
  end if;
end
$t5$;

-- ---------------------------------------------------------------------------
-- T6  四个受影响 writer 必须保持 security invoker——修复不得靠整体提权蒙混
--     过关。签名为 2026-08-24 生产目录确认值。
-- ---------------------------------------------------------------------------
do $t6$
declare
  v_sig text;
  v_oid oid;
begin
  foreach v_sig in array array[
    'public.home_update_fixed_month_item_status(uuid,text)',
    'public.home_update_fixed_month_items_status(text,text,text,text)',
    'public.home_sync_fixed_month_items(text,text)',
    'public.home_create_fixed_advance_payment(text,text,text,uuid,date,text)'
  ] loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise exception 'T6_WRITER_MISSING: %', v_sig;
    end if;
    if (select prosecdef from pg_proc where oid = v_oid) then
      raise exception
        'T6_WRITER_SILENTLY_PROMOTED: % 变成了 security definer；'
        '修复应为窄范围 helper，而非整体提权', v_sig;
    end if;
  end loop;
end
$t6$;

-- ---------------------------------------------------------------------------
-- T7  删除链必须保持 security definer——本次不动它，但要防止将来有人「顺手
--     统一」把它改成 invoker，那会立刻引入同一个 42501。
-- ---------------------------------------------------------------------------
do $t7$
declare
  v_sig text;
  v_oid oid;
begin
  foreach v_sig in array array[
    'public.home_delete_fixed_month_item(uuid)',
    'public.home_delete_fixed_month_item_core(uuid,uuid,text)',
    'public.home_check_fixed_month_item_delete_eligibility(public.home_fixed_month_items,uuid)'
  ] loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise exception 'T7_DELETE_CHAIN_MISSING: %', v_sig;
    end if;
    if not (select prosecdef from pg_proc where oid = v_oid) then
      raise exception
        'T7_DELETE_CHAIN_DEMOTED: % 不再是 security definer；'
        'projection 读取会暴露给调用者身份', v_sig;
    end if;
  end loop;
end
$t7$;

-- ---------------------------------------------------------------------------
-- T8  helper 方案的前提条件守卫。
--
--     helper 能读到数据，靠的是「表 owner 为 postgres 且未 FORCE RLS」——
--     RLS 对表 owner 不生效。若有人日后设置 FORCE ROW LEVEL SECURITY，或更换
--     表 owner，helper 会静默返回 false 而不是报错，四个守卫将无声失效，
--     projection 关联的固定项会被普通 writer 放行。
--     这是本方案唯一的静默失效路径，必须有断言守着。
-- ---------------------------------------------------------------------------
do $t8$
declare
  v_rel record;
begin
  select c.relrowsecurity, c.relforcerowsecurity, c.relowner
    into strict v_rel
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public'
    and c.relname = 'home_external_fixed_payment_projections';

  if v_rel.relowner <> 'postgres'::regrole then
    raise exception
      'T8_TABLE_OWNER_CHANGED: definer helper 将受 RLS 过滤并静默返回 false';
  end if;
  if v_rel.relforcerowsecurity then
    raise exception
      'T8_FORCE_RLS_ENABLED: definer helper 将被过滤为空集，四个 projection '
      '守卫会静默放行；必须重新设计';
  end if;
  if not v_rel.relrowsecurity then
    raise exception
      'T8_RLS_DISABLED: 与 2026-08-24 生产事实不符，请重新核实本方案前提';
  end if;
end
$t8$;

-- ---------------------------------------------------------------------------
-- T9  helper 的无数据 smoke test：不存在的 id / 月份必须返回 false，且不抛
--     权限错误。这一条直接证明 42501 已消除。
--     同时覆盖 payment_group 参数的四种传法。
-- ---------------------------------------------------------------------------
do $t9$
declare
  v_result boolean;
begin
  select public.home_fixed_item_has_external_projection(
    '00000000-0000-0000-0000-000000000000'::uuid
  ) into v_result;
  if v_result is not false then
    raise exception 'T9_ITEM_HELPER_UNEXPECTED: %', v_result;
  end if;

  select public.home_fixed_scope_has_external_projection('1900-01', 'JPY')
    into v_result;
  if v_result is not false then
    raise exception 'T9_SCOPE_BARE_UNEXPECTED: %', v_result;
  end if;

  select public.home_fixed_scope_has_external_projection('1900-01', 'JPY', 'expense')
    into v_result;
  if v_result is not false then
    raise exception 'T9_SCOPE_DIRECTION_UNEXPECTED: %', v_result;
  end if;

  select public.home_fixed_scope_has_external_projection(
    '1900-01', 'JPY', 'expense', '未分组'
  ) into v_result;
  if v_result is not false then
    raise exception 'T9_SCOPE_GROUP_UNEXPECTED: %', v_result;
  end if;

  select public.home_fixed_scope_has_external_projection(
    '1900-01', 'JPY', null, '乐天卡'
  ) into v_result;
  if v_result is not false then
    raise exception 'T9_SCOPE_GROUP_ONLY_UNEXPECTED: %', v_result;
  end if;
end
$t9$;

-- ---------------------------------------------------------------------------
-- T10 一般不变式：authenticated 可调用的 security invoker 函数，不得引用任何
--     authenticated 无 SELECT 权限的表。
--
--     T5 把表名写死成 home_external_fixed_payment_projections，那是个错误。
--     修掉 projection 表之后，端到端测试立刻在同一批 writer 上撞到第二张表
--     home_card_statement_cycles，症状完全相同——因为真正的不变式从来不是
--     「不许碰这张表」，而是「不许碰任何调用者没权限的表」。
--
--     本断言表达完整形式。它在整个缺陷类清理完成前会失败，这是预期：
--     失败输出即为剩余工作清单。先跑
--     supabase-readonly-20260824-invoker-privilege-audit.sql 确定爆炸半径。
-- ---------------------------------------------------------------------------
do $t10$
declare
  v_rec record;
  v_offenders text := '';
  v_count integer := 0;
begin
  for v_rec in
    with ungranted as (
      select c.oid, c.relname
      from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relkind in ('r', 'p')
        and not has_table_privilege('authenticated', c.oid, 'SELECT')
    ),
    invokers as (
      select p.oid, p.oid::regprocedure::text as sig,
             pg_get_functiondef(p.oid) as def
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and not p.prosecdef and p.prokind = 'f'
        and has_function_privilege('authenticated', p.oid, 'EXECUTE')
    )
    select i.sig, string_agg(u.relname, ', ' order by u.relname) as tables
    from invokers i
    join ungranted u on i.def ~ ('\m' || u.relname || '\M')
    group by i.sig
    order by i.sig
  loop
    v_count := v_count + 1;
    v_offenders := v_offenders || E'\n  ' || v_rec.sig || ' → ' || v_rec.tables;
  end loop;

  if v_count > 0 then
    raise exception
      'T10_INVOKER_TOUCHES_UNGRANTED_TABLE: % 个 authenticated 可调用的 invoker '
      '函数引用了无权限表，每一处都是潜在 42501：%',
      v_count, v_offenders;
  end if;
end
$t10$;

do $done$
begin
  raise notice 'fixed projection privilege helper rollback tests: all passed';
end
$done$;

rollback;

-- ===========================================================================
-- 未覆盖，须由执行方补做（Claude 无生产访问，写不出可靠的带数据测试）
-- ===========================================================================
--
-- 1. 行为等价性：以真实 authenticated 身份，对一个「有 projection 关联」的
--    固定项调用 home_update_fixed_month_item_status，必须返回
--    HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN 的业务文案，而不是 42501，
--    也不是放行。批量状态与月份同步同理。
--
-- 2. 固定垫付的分组隔离（本次最关键的行为验证）：
--    构造同月同币种、两个不同 payment_group 的固定支出，其中只有 A 组关联
--    projection。对 B 组调用 home_create_fixed_advance_payment 必须成功；
--    对 A 组必须返回原业务文案。
--    若 B 组也被拦，说明 v_group 没有正确传入 helper，拦截范围被放大了——
--    这正是初版方案被否决的原因，必须实测确认修正版没有重蹈。
--
-- 3. 正常路径：对一个「无 projection 关联」的固定项（例如用户报告的
--    2026-08「余额调整」）执行未付 → 已付，必须成功。这是缺陷的原始复现场景。
--
-- 4. 归属隔离：helper 新增了 auth.uid() 归属限定，而单项分支的原内联查询没有。
--    Codex 已从生产定义确认该调用点在此前已按 auth.uid() 取得 v_item，
--    执行替换后请再复核一次实际行为。
-- ===========================================================================
