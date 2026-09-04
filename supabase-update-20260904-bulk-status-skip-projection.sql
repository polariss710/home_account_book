-- 批量状态 writer：遇到 School projection 固定项改为「跳过并报告」，不再整批失败
--
-- 日期：2026-09-04
--
-- 基线（2026-09-04 19:07 生产只读导出，归档于 ~/aozora-security-20260827/cash-baseline/）：
--
--   home_update_fixed_month_items_status   md5 ea4e2dbacfec0c7a833f8af1559470dd
--   home_update_cny_fixed_items_status     md5 fc3f7782d244b64c5ef3ffb10978d33d
--   home_fixed_item_has_external_projection md5 cd5bc9b5f579193962b1082d6347f3a7（只调用，不改）
--
-- ===========================================================================
-- 症状
-- ===========================================================================
--
-- 用户的日元固定支出里现在有一条 School projection 项（教室费用 202,991 JPY，
-- 2026-09-25 到期）。它是每月都会有的——教室租金每个月都会生成一条。
--
-- 于是：
--
--   日元「一键未付/已付/结清」  → 整批拒绝 HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN
--                                  **且 School 项即使先单独标记已付，仍然阻断**
--   人民币「一键已付/结清」      → 账户预检就失败：projection 项的 account_id 恒为 null，
--                                  被判成「存在未选择有效账户的固定项」
--   人民币「一键未付」          → 进循环后中止，**且此前已改的保留**（部分生效）
--
-- 也就是说这几个按钮从这个月起等于废了，而且人民币那边的失败信息完全看不出
-- 跟 School 有关。
--
-- ===========================================================================
-- 修法与它有意不做的事
-- ===========================================================================
--
-- **保持「批量 writer 永不触碰 projection 项」这条不变式**，只把「遇到就整个失败」
-- 改成「遇到就跳过并报告」。
--
-- 不走另一条路（让批量内部分岔去写 projection 项）的理由：那道 GUC 守卫
-- （home_fixed_month_items_projection_guard）当初就是为了让 projection 的写入
-- **显式且窄**——它要求事务里挂着 phase3f_projection_status_write=on，且除 status
-- 外整行逐字节未变。把批量路径也放进那扇门，等于放宽守卫边界，而理由只是
-- 「按钮更顺手」。这个交换不划算。
--
-- School 项仍然只能通过 home_confirm_projection_fixed_item_status 改状态。
-- 前端会在批量之后自动补这一步（另一个提交），所以用户那边仍是点一下。
--
-- ===========================================================================
-- 本文件有意不动的三件事
-- ===========================================================================
--
-- 1. **home_check_fixed_paid_balance 的调用范围不变。**
--    它按月份/币种/方向检查已付余额，projection 项本来就在范围内——那是对的，
--    教室租金是真实支出，该算进去。改动它会改变一个业务计算的口径，不在本轮范围。
--
-- 2. **信用卡 statement 关联项仍然整批拒绝**
--    （HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN 那条保持原样）。
--    那是另一类对象，Phase 3E 的账单确认链路会动它们的金额，不是「只改状态」
--    这么简单，不能照搬本文件的跳过逻辑。
--
-- 3. **CNY 批量的两个既有缺陷保持原样**，仅记录：
--    a. 循环中途失败会 return 而不是 raise，**此前成功的更新保留**——非原子。
--       本文件让 projection 项不再触发这条路径，但别的失败原因仍会。
--       要改成原子需把 return 换成 raise，那会改变错误在前端的呈现形状，
--       是独立的一轮。
--    b. 该函数 **proconfig 为 null，没有固定 search_path**（日元那个有）。
--       本文件用 create or replace 时保持不加，避免把一个安全加固混进功能修复。
--       新增的调用一律写全 `public.` 前缀，不依赖 search_path。
--
-- 另记一条与本轮无关的观察：这两个批量函数的 proacl 都是
-- `{=X/postgres,postgres,anon,authenticated,service_role}` —— **PUBLIC 与 anon 都有
-- EXECUTE**。两者都是 INVOKER 且用 auth.uid() 过滤，anon 调进去匹配不到行、改不动
-- 数据，但这是不必要的暴露面。PROGRESS 里 Cash 的 anon 收口本就记着未完成，
-- 应当并入那一轮，不在本文件顺手处理。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   begin;
--   -- 从归档恢复两个函数（两份文件本身就是可执行的 CREATE OR REPLACE）：
--   --   cash-baseline/home_update_fixed_month_items_status-production-20260904-1907.sql
--   --   cash-baseline/home_update_cny_fixed_items_status-production-20260904-1907.sql
--   commit;
--
--   两个函数都不改签名、不改 ACL，所以回滚只是换回函数体，没有权限动作。
--   恢复后应重新核对 md5 等于本文件头部那两个值。
--
--   前端那个提交可以独立回滚：批量返回里多出来的 skipped_projection_count 字段
--   旧前端读不到，也不会因此报错。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 0. 生产基线断言（失败关闭）
-- ---------------------------------------------------------------------------

do $$
declare
  v_expected constant jsonb := jsonb_build_object(
    'home_update_fixed_month_items_status',    'ea4e2dbacfec0c7a833f8af1559470dd',
    'home_update_cny_fixed_items_status',      'fc3f7782d244b64c5ef3ffb10978d33d',
    'home_fixed_item_has_external_projection', 'cd5bc9b5f579193962b1082d6347f3a7'
  );
  v_name text;
  v_actual text;
  v_count integer;
begin
  for v_name in select jsonb_object_keys(v_expected) loop
    select count(*) into v_count
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    if v_count <> 1 then
      raise exception 'ABORT: % 在生产中有 % 个重载，本文件假定唯一', v_name, v_count;
    end if;

    select md5(p.prosrc) into v_actual
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;
    if v_actual is distinct from (v_expected ->> v_name) then
      raise exception 'ABORT: % 已漂移，期望 %，实际 %', v_name, v_expected ->> v_name, v_actual;
    end if;
  end loop;
end $$;

-- 本文件依赖 home_fixed_item_has_external_projection 能被这两个 INVOKER 函数调用。
-- 它是 DEFINER，但 EXECUTE 权限仍需覆盖调用者（docs/lessons.md C4）。
do $$
begin
  if not has_function_privilege(
       'authenticated',
       'public.home_fixed_item_has_external_projection(uuid)',
       'EXECUTE') then
    raise exception 'ABORT: authenticated 无法 EXECUTE home_fixed_item_has_external_projection，跳过逻辑会 42501';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. 日元批量
--
-- 与基线的差异 3 处：
--   ① 删掉 home_fixed_scope_has_external_projection 那条整批拒绝
--   ② UPDATE 的 where 增加 `and not public.home_fixed_item_has_external_projection(i.id)`
--   ③ 新增 v_skipped 统计并写进返回
--
-- 其余逐字未改：方向/状态校验、statement 整批拒绝、已付余额检查、
-- linked_jpy_transaction_id 与 advance 的排除条件、search_path。
-- ---------------------------------------------------------------------------

create or replace function public.home_update_fixed_month_items_status(
  p_month_key text, p_currency text, p_direction text, p_status text
)
returns jsonb
language plpgsql
set search_path to 'pg_catalog', 'public'
as $function$
declare v_updated_count integer:=0; v_skipped integer:=0; v_check jsonb;
begin
  if p_direction not in ('income','expense') then return jsonb_build_object('ok',false,'message','固定项收支方向无效。'); end if;
  if p_status not in ('unpaid','paid','settled') then return jsonb_build_object('ok',false,'message','固定项状态无效。'); end if;
  -- ① 原来这里是整批拒绝。改为跳过：projection 项由前端随后单独走
  --    home_confirm_projection_fixed_item_status，那是它们唯一合法的入口。
  if public.home_fixed_scope_has_card_statement(p_month_key,p_currency,p_direction) then return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN','message','范围内包含信用卡statement关联固定项，不能使用批量状态writer。'); end if;
  if p_direction='expense' and p_status in ('paid','settled') then v_check:=public.home_check_fixed_paid_balance(p_month_key,p_currency,null,null,p_direction,p_status); if not coalesce((v_check->>'ok')::boolean,false) then return v_check; end if; end if;
  -- ③ 先数清楚这次会跳过几条，返回里报出去，前端据此决定要不要补那一步
  select count(*) into v_skipped
  from public.home_fixed_month_items i
  where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency
    and i.direction=p_direction
    and public.home_fixed_item_has_external_projection(i.id);
  -- ② 排除 projection 项
  update public.home_fixed_month_items i set status=p_status where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction and i.linked_jpy_transaction_id is null and not public.home_fixed_item_has_external_projection(i.id) and not(p_direction='expense' and exists(select 1 from public.home_fixed_advance_payments ap where ap.user_id=auth.uid() and ap.month_key=i.month_key and ap.currency=i.currency and ap.payment_group=coalesce(i.payment_group,'未分组')));
  get diagnostics v_updated_count=row_count;
  return jsonb_build_object('ok',true,'message','固定项状态已批量更新。','updated_count',v_updated_count,'skipped_projection_count',v_skipped);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 2. 人民币批量
--
-- 与基线的差异 3 处：
--   ① 账户预检排除 projection 项 —— 它们的 account_id 恒为 null 是**设计**
--      （不走账户，用户自己拿钱去还），不是「忘了选账户」
--   ② 循环里跳过 projection 项，不再调用会拒绝它的单条 writer
--   ③ 新增 v_skipped 统计并写进返回
--
-- 其余逐字未改：方向/状态校验、账户预检的其余条件、循环顺序、失败时的返回形状。
--
-- **proconfig 保持 null**（基线就没有 SET search_path）。新增调用写全 public. 前缀。
-- ---------------------------------------------------------------------------

create or replace function public.home_update_cny_fixed_items_status(
  p_month_key text, p_direction text, p_status text
)
returns jsonb
language plpgsql
as $function$
declare
  v_item record;
  v_result jsonb;
  v_updated_count integer := 0;
  v_invalid_count integer := 0;
  v_skipped integer := 0;
begin
  if p_direction not in ('income', 'expense') then
    return jsonb_build_object('ok', false, 'message', '人民币固定项收支方向无效。');
  end if;

  if p_status not in ('unpaid', 'paid', 'settled') then
    return jsonb_build_object('ok', false, 'message', '人民币固定项状态无效。');
  end if;

  if p_status in ('paid', 'settled') then
    select count(*)
    into v_invalid_count
    from home_fixed_month_items i
    left join home_accounts a on a.id = i.account_id
      and a.user_id = auth.uid()
      and a.currency = 'CNY'
      and a.is_active
    where i.user_id = auth.uid()
      and i.month_key = p_month_key
      and i.currency = 'CNY'
      and i.direction = p_direction
      and a.id is null
      -- ① projection 项没有账户是设计，不该被算成「未选择有效账户」
      and not public.home_fixed_item_has_external_projection(i.id);

    if v_invalid_count > 0 then
      return jsonb_build_object(
        'ok', false,
        'message', '存在未选择有效账户的人民币固定项，不能一键结算。',
        'invalid_count', v_invalid_count
      );
    end if;
  end if;

  for v_item in
    select id, name
    from home_fixed_month_items
    where user_id = auth.uid()
      and month_key = p_month_key
      and currency = 'CNY'
      and direction = p_direction
    order by due_date nulls last, created_at, name
  loop
    -- ② 跳过 projection 项。基线在这里会调用单条 writer 并被它拒绝，
    --    然后 return，把前面已经改掉的留在库里（部分生效）。
    if public.home_fixed_item_has_external_projection(v_item.id) then
      v_skipped := v_skipped + 1;
      continue;
    end if;

    v_result := home_update_cny_fixed_item_status(v_item.id, p_status);
    if not coalesce((v_result ->> 'ok')::boolean, false) then
      return jsonb_build_object(
        'ok', false,
        'message', coalesce(v_result ->> 'message', '人民币固定项批量状态更新失败。'),
        'failed_item', v_item.name,
        'updated_count', v_updated_count,
        'skipped_projection_count', v_skipped
      );
    end if;

    v_updated_count := v_updated_count + 1;
  end loop;

  return jsonb_build_object(
    'ok', true,
    'message', '人民币固定项状态已批量更新。',
    'updated_count', v_updated_count,
    'skipped_projection_count', v_skipped
  );
end;
$function$;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 零、基线断言能证伪（E3）
--   rollback-only 改动任一函数正文 → 期望 ABORT: … 已漂移
--   rollback-only 撤掉 authenticated 对 has_external_projection 的 EXECUTE
--     → 期望 ABORT: … 跳过逻辑会 42501
--
-- 一、逐行 diff（E2）
--   两个函数与 cash-baseline 下 20260904-1907 的导出比，期望**各 3 处**改动。
--   出现第 4 处即为转录错误。
--   **单独确认**：日元那个的 statement 整批拒绝与已付余额检查逐字仍在；
--   人民币那个的 proconfig **仍为 null**（没被顺手加上 search_path）。
--
-- 二、结构与权限
--   两个函数的签名、owner、prosecdef、proacl 与部署前逐字相同。
--   proacl 应仍为 {=X/postgres,postgres=X/postgres,anon=X/postgres,
--   authenticated=X/postgres,service_role=X/postgres} —— 本文件不收窄它，
--   那属于 anon 收口那一轮。
--
-- 三、真实数据回归（只读为主）
--   用户当前日元 2026-09 支出范围内有 1 条 School projection 项。
--     1. 一键已付 → ok=true，updated_count 为普通项数量，
--        **skipped_projection_count = 1**
--     2. 那条 School 项状态**未被改动**，仍是操作前的值
--     3. 其余项按预期变更
--   ⚠️ 这一条会真的改生产数据。**先在 rollback-only 事务里跑一遍确认形状，
--      再决定是否真提交**，或等用户当月实际操作时观察。
--
-- 四、该失败的仍然失败（E4，rollback-only）
--     a. 方向非法 / 状态非法 → 原错误信息
--     b. 范围内有 statement 关联项 → 仍整批拒绝
--        HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN
--     c. 日元支出转已付但余额不足 → 仍返回 home_check_fixed_paid_balance 的结果
--     d. 人民币有**非 projection** 项未选账户 → 仍返回「存在未选择有效账户…」
--        ← 这条证明 ① 是**缩小了判定范围**而不是**取消了判定**
--     e. 带 linked_jpy_transaction_id 的项仍不被批量改动
--
-- 五、跳过是真的跳过，不是漏改
--   构造一个范围内既有 projection 项、又有普通项的场景，
--   确认 updated_count + skipped_projection_count = 范围内应处理的总数。
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 1. **每行调用 home_fixed_item_has_external_projection 的代价。** 日元那条
--    UPDATE 的 where 里现在多了一个 DEFINER 函数调用，人民币的预检与循环里也有。
--    固定项表规模应该很小（每月十几条），但我没查过行数与执行计划。
--    若表远大于预期，应改成一次 join 而不是逐行调用。
--
-- 2. **home_fixed_item_has_external_projection 的语义**是否恰好等于
--    「不能被通用 writer 改的那类项」。两个单条 writer 用的也是它，所以一致；
--    但我是从函数名与调用处推断的，没读它的函数体。
--
-- 3. **人民币账户预检改动的边界。** 我只在那个 count 里加了排除条件。若还有别处
--    按 account_id 是否为空来判断 CNY 固定项是否可结算，那里会保留旧行为。
--    未全查。
--
-- 4. 日元批量对 income 方向同样生效。目前 projection 项都是 expense，
--    但代码路径共用，income 方向的行为变化未实测。
--
-- ===========================================================================
