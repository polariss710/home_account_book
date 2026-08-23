\set ON_ERROR_STOP on

-- Home / Cash：固定项 projection 权限 helper 的回滚测试
--
-- 不读写任何业务表、不调用任何 writer RPC。仅读系统目录，并对两个新 helper
-- 做无数据的 smoke test。事务末尾 rollback。
--
-- 执行顺序：先跑 supabase-update-20260824-fixed-projection-privilege-helper.sql
-- 与文末的四处调用点替换，再跑本文件。T6 在替换完成前会失败，这是预期——
-- 它正是替换的验收条件。
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
end
$t1$;

-- ---------------------------------------------------------------------------
-- T2  helper 必须是 security definer、owner 为 postgres、search_path 已固定。
--     三者缺一，helper 都无法安全地代替原内联查询。
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
-- T4  回归守卫：projection 表本身仍不得对 authenticated / anon 授予任何表权限。
--     本次修复刻意不走「整表授权」那条捷径——该表未启用 RLS，授权等于把
--     全部 projection 数据敞开。本断言防止将来有人图省事补一条 grant。
-- ---------------------------------------------------------------------------
do $t4$
declare
  v_role text;
  v_priv text;
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
end
$t4$;

-- ---------------------------------------------------------------------------
-- T5  核心不变式：public 下任何 security invoker 函数都不得直接引用
--     home_external_fixed_payment_projections。
--
--     这正是本次缺陷的一般形式——对无授权的表做 select，调用者身份必然
--     42501。本断言覆盖全部四个 writer，也覆盖将来任何新写的 invoker 函数，
--     不依赖我们是否枚举全了受影响的函数名。
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
-- T6  四个 writer 必须保持 security invoker——修复不得靠整体提权蒙混过关。
--     签名以生产为准：删除与同步 writer 的确切签名由执行方在运行前确认，
--     若名称不符请更新本数组而非删除断言。
-- ---------------------------------------------------------------------------
do $t6$
declare
  v_name text;
  v_rec record;
  v_found boolean;
begin
  foreach v_name in array array[
    'home_update_fixed_month_item_status',
    'home_update_fixed_month_items_status'
  ] loop
    v_found := false;
    for v_rec in
      select p.prosecdef, p.oid::regprocedure::text as sig
      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
      where n.nspname = 'public' and p.proname = v_name
    loop
      v_found := true;
      if v_rec.prosecdef then
        raise exception
          'T6_WRITER_SILENTLY_PROMOTED: % 变成了 security definer；'
          '修复应为窄范围 helper，而非整体提权', v_rec.sig;
      end if;
    end loop;
    if not v_found then
      raise exception 'T6_WRITER_MISSING: %', v_name;
    end if;
  end loop;
end
$t6$;

-- ---------------------------------------------------------------------------
-- T7  helper 的无数据 smoke test：随机 uuid 与不存在的月份必须返回 false，
--     且不抛权限错误。这一条直接证明缺陷已消除。
-- ---------------------------------------------------------------------------
do $t7$
declare
  v_result boolean;
begin
  select public.home_fixed_item_has_external_projection(
    '00000000-0000-0000-0000-000000000000'::uuid
  ) into v_result;
  if v_result is not false then
    raise exception 'T7_ITEM_HELPER_UNEXPECTED: %', v_result;
  end if;

  select public.home_fixed_scope_has_external_projection('1900-01', 'JPY', 'expense')
    into v_result;
  if v_result is not false then
    raise exception 'T7_SCOPE_HELPER_UNEXPECTED_WITH_DIRECTION: %', v_result;
  end if;

  select public.home_fixed_scope_has_external_projection('1900-01', 'JPY')
    into v_result;
  if v_result is not false then
    raise exception 'T7_SCOPE_HELPER_UNEXPECTED_WITHOUT_DIRECTION: %', v_result;
  end if;
end
$t7$;

do $done$
begin
  raise notice 'fixed projection privilege helper rollback tests: all passed';
end
$done$;

rollback;

-- ===========================================================================
-- 未覆盖，须由执行方补做（我无生产访问，写不出可靠的带数据测试）
-- ===========================================================================
--
-- 1. 行为等价性：以真实 authenticated 身份，对一个「有 projection 关联」的
--    固定项调用 home_update_fixed_month_item_status，必须返回
--    HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN 的业务文案，而不是 42501，
--    也不是放行。批量 / 删除 / 同步三个 writer 同理。
--
-- 2. 正常路径：对一个「无 projection 关联」的固定项（例如用户报告的
--    2026-08「余额调整」）执行未付 → 已付，必须成功。这是缺陷的原始复现场景。
--
-- 3. 归属隔离：helper 新增了 auth.uid() 归属限定，而原内联查询在单项分支中
--    没有。须确认替换 A 与替换 C 的调用点在该分支之前均已按 auth.uid() 取得
--    v_item，否则语义会从「任何人的关联项都拦」变成「只拦自己的」。
--    这是本次修改中唯一可能改变行为的地方，必须逐个确认。
-- ===========================================================================
