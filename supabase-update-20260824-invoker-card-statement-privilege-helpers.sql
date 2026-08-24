\set ON_ERROR_STOP on

-- Home / Cash：security invoker 固定项 writer 的 card statement 权限窄化修复
--
-- 生产只读审计（2026-08-24）确认：
--   * home_card_statement_cycles 与 home_card_instruments 均启用 RLS；
--   * 两表均无 policy，authenticated 均无 SELECT；
--   * 两表 owner 均为 postgres，且均未 FORCE RLS；
--   * 四个 authenticated 可调用的 security invoker writer 直接读取上述表，
--     因而存在与 projection 表相同的 42501 缺陷。
--
-- 本文件只新增三个返回 boolean 的窄范围 SECURITY DEFINER helper。
-- 不授予表权限、不新增 policy，也不改变任何既有 writer 的 owner/security/ACL。
-- 四个 writer 的调用点替换由配套 callsite patch 在独立事务中完成。
--
-- 业务负责人于 2026-08-24 明确批准本权限边界变更及以下函数合同：
--   home_fixed_item_has_card_statement(uuid)
--   home_fixed_scope_has_card_statement(text,text,text default null)
--   home_fixed_advance_group_has_card_statement(text,text,text)

begin;
set local lock_timeout = '8s';
set local statement_timeout = '120s';

-- 两张表只要 owner/RLS/FORCE/policy/SELECT 任一事实漂移，就不能继续使用
-- postgres-owned definer helper；尤其 owner 漂移会令 helper 被 RLS 静默过滤。
do $preflight$
declare
  v_table text;
  v_rel record;
begin
  foreach v_table in array array[
    'home_card_instruments',
    'home_card_statement_cycles'
  ] loop
    select c.oid, c.relrowsecurity, c.relforcerowsecurity, c.relowner,
           (select count(*) from pg_policy p where p.polrelid = c.oid) as policy_count
      into strict v_rel
    from pg_class c
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public'
      and c.relname = v_table
      and c.relkind in ('r', 'p');

    if has_table_privilege('authenticated', v_rel.oid, 'SELECT') then
      raise exception
        'CARD_STATEMENT_HELPER_UNEXPECTED_SELECT_GRANT: authenticated can SELECT %',
        v_table;
    end if;
    if not v_rel.relrowsecurity then
      raise exception 'CARD_STATEMENT_HELPER_RLS_DISABLED: %', v_table;
    end if;
    if v_rel.relforcerowsecurity then
      raise exception
        'CARD_STATEMENT_HELPER_FORCE_RLS_ENABLED: % would be silently filtered; '
        'redesign required', v_table;
    end if;
    if v_rel.relowner <> 'postgres'::regrole then
      raise exception
        'CARD_STATEMENT_HELPER_TABLE_OWNER_UNEXPECTED: % owner is %, expected '
        'postgres; definer helper would be subject to RLS and silently return false',
        v_table, pg_get_userbyid(v_rel.relowner);
    end if;
    if v_rel.policy_count <> 0 then
      raise exception
        'CARD_STATEMENT_HELPER_POLICY_DRIFT: % has % policies, expected 0',
        v_table, v_rel.policy_count;
    end if;
  end loop;
end
$preflight$;

-- 单个、且属于当前调用者的固定项是否已被 statement cycle 关联。
create or replace function public.home_fixed_item_has_card_statement(
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
    from public.home_card_statement_cycles c
    join public.home_fixed_month_items i
      on i.id = c.household_remainder_fixed_item_id
    where c.household_remainder_fixed_item_id = p_item_id
      and i.user_id = auth.uid()
  );
$function$;

comment on function public.home_fixed_item_has_card_statement(uuid) is
  'Narrow postgres-owned security definer predicate: whether the caller-owned '
  'fixed month item is referenced by a card statement cycle. Returns boolean only.';

-- 当前调用者的月份/币种范围内是否含 statement 关联项；direction 为 NULL 时
-- 不过滤方向，与月份同步 writer 的原谓词一致。
create or replace function public.home_fixed_scope_has_card_statement(
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
    from public.home_card_statement_cycles c
    join public.home_fixed_month_items i
      on i.id = c.household_remainder_fixed_item_id
    where i.user_id = auth.uid()
      and i.month_key = p_month_key
      and i.currency = p_currency
      and (p_direction is null or i.direction = p_direction)
  );
$function$;

comment on function public.home_fixed_scope_has_card_statement(text, text, text) is
  'Narrow postgres-owned security definer predicate: whether the caller owns a '
  'card-statement-linked fixed item in the month/currency and optional direction. '
  'Returns boolean only.';

-- 固定垫付的分组来自 card -> funding payment_channel 的 ch.name，不来自固定项
-- payment_group。此谓词逐字保持生产 writer 的原过滤语义。
create or replace function public.home_fixed_advance_group_has_card_statement(
  p_month_key text,
  p_currency text,
  p_payment_group text
)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $function$
  select exists (
    select 1
    from public.home_card_statement_cycles c
    join public.home_card_instruments card on card.id = c.card_instrument_id
    join public.home_payment_channels ch
      on ch.id = card.funding_payment_channel_id
    where c.user_id = auth.uid()
      and to_char(c.target_fixed_month, 'YYYY-MM') = p_month_key
      and c.settlement_currency = p_currency
      and coalesce(ch.name, '未分组') = p_payment_group
      and c.household_remainder_fixed_item_id is not null
  );
$function$;

comment on function public.home_fixed_advance_group_has_card_statement(text, text, text) is
  'Narrow postgres-owned security definer predicate: whether the caller has a '
  'card statement linked to a fixed item in the month/currency/payment-channel '
  'group. Group authority is payment_channels.name. Returns boolean only.';

alter function public.home_fixed_item_has_card_statement(uuid) owner to postgres;
alter function public.home_fixed_scope_has_card_statement(text, text, text)
  owner to postgres;
alter function public.home_fixed_advance_group_has_card_statement(text, text, text)
  owner to postgres;

revoke all on function public.home_fixed_item_has_card_statement(uuid)
  from public, anon;
revoke all on function public.home_fixed_scope_has_card_statement(text, text, text)
  from public, anon;
revoke all on function public.home_fixed_advance_group_has_card_statement(text, text, text)
  from public, anon;

grant execute on function public.home_fixed_item_has_card_statement(uuid)
  to authenticated, service_role;
grant execute on function public.home_fixed_scope_has_card_statement(text, text, text)
  to authenticated, service_role;
grant execute on function public.home_fixed_advance_group_has_card_statement(text, text, text)
  to authenticated, service_role;

-- 确认三个 helper 的安全属性与 EXECUTE 边界；事务内失败会回滚全部创建。
do $postcheck$
declare
  v_sig text;
  v_oid oid;
  v_proc record;
begin
  foreach v_sig in array array[
    'public.home_fixed_item_has_card_statement(uuid)',
    'public.home_fixed_scope_has_card_statement(text,text,text)',
    'public.home_fixed_advance_group_has_card_statement(text,text,text)'
  ] loop
    v_oid := to_regprocedure(v_sig);
    if v_oid is null then
      raise exception 'CARD_STATEMENT_HELPER_MISSING_AFTER_CREATE: %', v_sig;
    end if;

    select p.proowner, p.prosecdef, p.provolatile, p.proconfig, p.proacl
      into strict v_proc
    from pg_proc p where p.oid = v_oid;

    if v_proc.proowner <> 'postgres'::regrole
       or not v_proc.prosecdef
       or v_proc.provolatile <> 's'
       or v_proc.proconfig is distinct from
          array['search_path=pg_catalog, public']::text[] then
      raise exception 'CARD_STATEMENT_HELPER_SECURITY_CONTRACT_FAILED: %', v_sig;
    end if;
    if exists (
         select 1
         from aclexplode(
           coalesce(v_proc.proacl, acldefault('f', v_proc.proowner))
         ) a
         where a.grantee = 0 and a.privilege_type = 'EXECUTE'
       )
       or has_function_privilege('anon', v_oid, 'EXECUTE')
       or not has_function_privilege('authenticated', v_oid, 'EXECUTE')
       or not has_function_privilege('service_role', v_oid, 'EXECUTE') then
      raise exception 'CARD_STATEMENT_HELPER_ACL_CONTRACT_FAILED: %', v_sig;
    end if;
  end loop;
end
$postcheck$;

commit;
