-- ###########################################################################
-- ##  不完整，暂勿部署 —— 2026-09-04 审核 P2：运维卡目录会漏掉该卡
-- ##
-- ##  生产 home_get_card_route_catalog(uuid) 用的是
-- ##      INNER JOIN home_fixed_templates ft ON ft.id = c.household_statement_template_id
-- ##  解除 NOT NULL 之后，**没有家庭模板的卡会从这个运维目录里整行消失**。
-- ##
-- ##  本文件只改了列与校验器，没覆盖这个 reader。需要配套把它改成 LEFT JOIN
-- ##  并定义空模板时那几列的取值语义——而我手上没有它的生产定义，已请求基线。
-- ##
-- ##  影响范围：School 侧的卡列表直接读 home_card_instruments，**不受影响**
-- ##  （审核已确认）。所以这是运维视图的缺口，不是业务路径的缺口，
-- ##  但「建了一张卡却在目录里看不见」正是那种事后极难想到要去查的问题。
-- ###########################################################################

-- 信用卡的家庭账单模板改为可选 —— 去掉「每张卡都有家庭消费」这个单卡时代的假设
--
-- 日期：2026-09-04
--
-- 基线（2026-09-04 18:16 生产只读导出，归档于 ~/aozora-security-20260827/cash-baseline/）：
--   home_validate_card_instrument()  md5 2cf77fcaee68b80d3623e975901b1506
--
-- ===========================================================================
-- 为什么
-- ===========================================================================
--
-- `home_card_instruments.household_statement_template_id` 目前是 NOT NULL，
-- 且 home_validate_card_instrument 要求它指向一条 active、币种匹配、
-- direction='expense'、accounting_scope='household'、payment_group 等于还款渠道名
-- 的模板。
--
-- 这句约束的含义是「每张卡都有家庭消费」。西武卡成立——它既刷家里也刷教室租金，
-- 那条「西武卡消费」模板就是它的家庭部分（生产里 8 月 119,699 JPY 那条项）。
--
-- **工行卡不成立**：业务负责人 2026-09-04 确认，工行卡只刷教室租金，家庭消费全部
-- 走余额宝账户。所以它没有家庭部分，Phase 3E 的「账单总额 − School 小计 = 家庭余额」
-- 对它没有意义。
--
-- ===========================================================================
-- 为什么不建一条占位模板
-- ===========================================================================
--
-- 那是本来的方案，被审核推翻。生产实证（2026-09-04）：
--
--   home_generate_fixed_month **不排除信用卡绑定的模板，也不看名字**。
--   一条 active 的模板只要落在有效月份区间内就会生成 unpaid 固定项。
--   而所有排除机制（end_month / start_month / short_term 期数）都是**相对目标月**的
--   ——「过去的 end_month 不是永久禁止生成，切回结束月或更早的有效月份仍可能生成」。
--   没有 skip_generation 之类的标志。
--
-- 也就是说**不存在一个「能通过建卡校验、又保证永不生成」的模板配置**。
-- 而建卡校验又强制要求它 active。造一条假模板再想办法骗过生成器，是拿一个
-- 永久的错误数据换一次性的省事。
--
-- ===========================================================================
-- 语义声明（业务模型扩展，需业务负责人批准后方可执行）
-- ===========================================================================
--
-- `household_statement_template_id` 由必填改为可选：
--
--   非 NULL → 语义与今天**逐字不变**，仍然逐条校验那六项
--   NULL    → 表示「这张卡没有家庭消费部分」，跳过模板校验
--
-- 不改 FK、不改该列以外的任何约束、不改冻结规则。
-- 冻结那段的 row(...) 比较用的是 IS DISTINCT FROM，天然正确处理 NULL：
-- NULL→NULL 不算变化，NULL→某个值在卡被引用后仍会被拒。**无需改动。**
--
-- ===========================================================================
-- 对 Phase 3E 的影响
-- ===========================================================================
--
**2026-09-04 审核已实证**，「不会匹配任意模板」这个判断成立，但返回形状我推断错了：

--   preview  用 `i.template_id = v_card.household_statement_template_id`，
--            NULL 命中零条。前置检查通过时返回 **ok=true、can_confirm=false**，
--            blockers 里含 HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_MISSING。
--            **不是抛错，是一个「不能确认」的正常返回。**
--   confirm  调用上面那个 preview 并检查 can_confirm，
--            **在创建 cycle、改动家庭项金额之前就拒绝**。
--   reopen   按已有 cycle 及其家庭项 ID 查找，不按模板模糊匹配。
--            NULL 模板的新卡没有 cycle，返回 HOME_CARD_STATEMENT_CYCLE_NOT_FOUND。
--
-- 所以确实**失败关闭**、不会误算出家庭余额，但**不能说「所有失败都叫
-- HOUSEHOLD_ITEM_MISSING」**——School manifest 校验发生在家庭项查找之前，
-- 跨币种或其他事实不匹配时会先返回 manifest 错误。
--
-- 这条链路至今**没有任何前端入口**（confirm / preview / reopen 三个 RPC 在
-- Cash 前端零引用），两张卡都没真正用过。工行卡也已确认不接。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   begin;
--   -- 1. 先恢复触发器函数（从归档，该文件本身可执行）
--   --    cash-baseline/home_validate_card_instrument-production-20260904-1816.sql
--   -- 2. 再恢复 NOT NULL
--   alter table public.home_card_instruments
--     alter column household_statement_template_id set not null;
--   commit;
--
--   **顺序不能反**：先恢复函数再恢复 NOT NULL。反过来的话，中间那一刻函数还允许
--   NULL 而列已经禁止，行为不一致。
--
--   ⚠️ 恢复 NOT NULL 前必须确认**没有任何卡的该列为 NULL**。若工行卡已经用
--   NULL 建出来，这一步会失败，届时要先决定给它配一条模板还是删卡——
--   那属于业务数据处理，不在本回滚脚本范围。
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
  where n.nspname = 'public' and p.proname = 'home_validate_card_instrument';
  if v_count <> 1 then
    raise exception 'ABORT: home_validate_card_instrument 有 % 个重载，本文件假定唯一', v_count;
  end if;

  select md5(p.prosrc) into v_actual
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.proname = 'home_validate_card_instrument';
  if v_actual is distinct from '2cf77fcaee68b80d3623e975901b1506' then
    raise exception 'ABORT: home_validate_card_instrument 已漂移，期望 2cf77fcaee68b80d3623e975901b1506，实际 %', v_actual;
  end if;

  -- 该列此刻必须仍是 NOT NULL，否则说明已经被别人改过，本文件的前提不成立
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'home_card_instruments'
      and column_name = 'household_statement_template_id'
      and is_nullable = 'YES'
  ) then
    raise exception 'ABORT: household_statement_template_id 已经是可空的，本文件的前提不成立';
  end if;

  -- 现有卡该列必须全部非空。若已有 NULL，说明约束与数据不一致，先查清楚再动。
  if exists (
    select 1 from public.home_card_instruments
    where household_statement_template_id is null
  ) then
    raise exception 'ABORT: 已存在该列为 NULL 的卡，与当前 NOT NULL 约束矛盾';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. 去掉 NOT NULL
--
-- 只动可空性。FK、默认值、类型、该表其余约束一律不动。
-- ---------------------------------------------------------------------------

alter table public.home_card_instruments
  alter column household_statement_template_id drop not null;

comment on column public.home_card_instruments.household_statement_template_id is
  'Household fixed template bound to this card, used only by the Phase 3E statement-confirm split. NULL means the card has no household spending (e.g. a card used solely for School classroom rent); the statement-confirm path then fails closed with HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_MISSING.';

-- ---------------------------------------------------------------------------
-- 2. 校验器：模板为 NULL 时跳过那段校验
--
-- 与基线的差异**只有 1 处**：把模板查找与校验整段包进
-- `if new.household_statement_template_id is not null then ... end if;`。
--
-- 段内六项判定逐字未改——非 NULL 时的行为与今天完全相同，包括错误码
-- CARD_INSTRUMENT_INVALID_HOUSEHOLD_TEMPLATE。
--
-- 其余逐字未改：还款渠道校验、user 不可变、version 必须递增、引用后配置冻结、
-- updated_at 维护、search_path、DEFINER。
--
-- **冻结那段不需要改**：row(...) 用 IS DISTINCT FROM 比较，NULL→NULL 不算变化，
-- NULL→某值在卡被引用后照样被拒。
-- ---------------------------------------------------------------------------

create or replace function public.home_validate_card_instrument()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_channel public.home_payment_channels%rowtype;
  v_template public.home_fixed_templates%rowtype;
  v_is_referenced boolean := false;
begin
  select * into v_channel
  from public.home_payment_channels
  where id = new.funding_payment_channel_id;

  if not found
     or v_channel.user_id is distinct from new.user_id
     or v_channel.currency is distinct from new.settlement_currency
     or v_channel.is_active is not true then
    raise exception using errcode = '23514', message = 'CARD_INSTRUMENT_INVALID_FUNDING_CHANNEL';
  end if;

  -- 家庭账单模板可选。NULL 表示这张卡没有家庭消费部分（例如只用于教室租金的
  -- 工行卡），Phase 3E 的账单确认对它不适用且会失败关闭。
  -- 给了值就仍然逐条校验，六项一字未改。
  if new.household_statement_template_id is not null then
    select * into v_template
    from public.home_fixed_templates
    where id = new.household_statement_template_id;

    if not found
       or v_template.user_id is distinct from new.user_id
       or v_template.currency is distinct from new.settlement_currency
       or v_template.direction is distinct from 'expense'
       or v_template.accounting_scope is distinct from 'household'
       or v_template.is_active is not true
       or v_template.payment_group is distinct from v_channel.name then
      raise exception using errcode = '23514', message = 'CARD_INSTRUMENT_INVALID_HOUSEHOLD_TEMPLATE';
    end if;
  end if;

  if tg_op = 'UPDATE' then
    if new.user_id is distinct from old.user_id then
      raise exception using errcode = '42501', message = 'CARD_INSTRUMENT_USER_IMMUTABLE';
    end if;
    if new.version is distinct from old.version + 1 then
      raise exception using errcode = '40001', message = 'CARD_INSTRUMENT_VERSION_MUST_ADVANCE';
    end if;

    select exists (
      select 1 from public.home_external_transaction_requests r
      where r.card_instrument_id = old.id
      union all
      select 1 from public.home_card_statement_cycles c
      where c.card_instrument_id = old.id
      union all
      select 1 from public.home_external_fixed_payment_projections p
      where p.card_instrument_id = old.id
      limit 1
    ) into v_is_referenced;

    if v_is_referenced and row(
      new.settlement_currency, new.cutoff_day, new.cutoff_inclusive,
      new.funding_day, new.funding_month_offset, new.funding_payment_channel_id,
      new.household_statement_template_id
    ) is distinct from row(
      old.settlement_currency, old.cutoff_day, old.cutoff_inclusive,
      old.funding_day, old.funding_month_offset, old.funding_payment_channel_id,
      old.household_statement_template_id
    ) then
      raise exception using errcode = '42501', message = 'CARD_INSTRUMENT_REFERENCED_CONFIG_IMMUTABLE';
    end if;

    new.updated_at := statement_timestamp();
  end if;

  return new;
end;
$function$;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 零、基线断言能证伪（E3）
--   rollback-only：改动函数正文 → ABORT 已漂移；
--   先 drop not null 再跑本文件 → ABORT「已经是可空的」。
--
-- 一、逐行 diff（E2）
--   与 cash-baseline/home_validate_card_instrument-production-20260904-1816.sql 比，
--   期望**恰好 1 处**改动（多一层 if 包裹）。出现第 2 处即为转录错误。
--   段内六项判定必须逐字可见。
--
-- 二、结构
--   1. 该列 is_nullable = 'YES'，类型、默认值、FK 未变
--   2. 该表其余列、约束、索引、RLS/policy、触发器绑定未变
--   3. 函数的 owner / prosecdef / proconfig / proacl 与部署前逐字相同
--      （proacl 应仍为 {postgres=X/postgres}）
--
-- 三、西武卡逐字不变（比工行卡能不能建更重要）
--   1. 西武卡当前行的 household_statement_template_id 未变，仍指向「西武卡消费」
--   2. rollback-only：尝试把西武卡的 offset 改掉 → 仍报
--      CARD_INSTRUMENT_REFERENCED_CONFIG_IMMUTABLE（它已被那条请求引用）
--   3. rollback-only：建一张**带**合法模板的新卡 → 成功，与改动前行为相同
--
-- 四、该失败的仍然失败（E4，rollback-only，错误码精确匹配）
--     a. 模板非空但币种与卡不符        → CARD_INSTRUMENT_INVALID_HOUSEHOLD_TEMPLATE
--     b. 模板非空但 is_active = false  → 同上
--     c. 模板非空但 accounting_scope 不是 household → 同上
--     d. 模板非空但 payment_group 与渠道名不符 → 同上
--     e. 模板 id 指向不存在的行        → 同上
--        ← a～e 证明这是**加了一个前置条件**，不是**取消了校验**
--     f. 还款渠道币种与卡不符          → CARD_INSTRUMENT_INVALID_FUNDING_CHANNEL
--     g. 卡被引用后改 settlement_currency → CARD_INSTRUMENT_REFERENCED_CONFIG_IMMUTABLE
--
-- 五、NULL 路径（rollback-only）
--   1. 建一张 household_statement_template_id 为 NULL 的卡 → 成功
--   2. 该卡被引用后，尝试把它从 NULL 改成某个模板 → 仍被冻结拒绝
--      ← 证明 IS DISTINCT FROM 对 NULL 的处理是对的，冻结没有因为可空而失效
--   3. 该卡在未被引用时从 NULL 改成合法模板 → 成功且仍走那六项校验
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 首版列的前三条已由 2026-09-04 审核实证，**不再是假设**：
--
--   1. Phase 3E 对 NULL 的行为已查清，见上面「对 Phase 3E 的影响」一节
--      （返回形状我原来推断错了，已订正）。
--   2. 全库 prosrc 搜索，直接引用该列的函数共**四个**：
--        home_validate_card_instrument      ← 本文件已改
--        home_build_card_statement_preview  ← Phase 3E，失败关闭，不改
--        home_validate_card_statement_cycle ← Phase 3E，不改
--        home_get_card_route_catalog        ← **INNER JOIN，会漏卡，见文首阻断说明**
--      我原先只在仓库 grep 过，漏掉了后两个——磁盘不等于生产（lessons B1）。
--   3. FK 确为 **ON DELETE RESTRICT**，模板被引用时删不掉，
--      所以不会出现「模板被删导致变成 NULL」与「本来就没模板」混淆的情况。
--
-- 仍然成立的：
--
-- 4. 建工行卡本身**不在本文件范围**。本文件只解开那道约束，卡与支付宝渠道是
--    单独一轮的业务数据操作，且卡的 cutoff/funding/offset 一旦被引用即冻结，
--    要一次填对。
--
-- 5. **home_get_card_route_catalog 改成 LEFT JOIN 之后，空模板那几列返回什么**
--    ——是 NULL、还是某种占位文案？这决定运维视图上那一行长什么样，
--    需要看到它的定义与调用方才能定。已请求基线。
--
-- ===========================================================================
