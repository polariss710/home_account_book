-- ###########################################################################
-- ##  作废，禁止执行 —— 2026-09-03 审核驳回（P1-2）
-- ##
-- ##  函数体与生产基线的 diff 经审核确认恰好 4 组改动、无第五处转录差异，
-- ##  但本文件末尾仍调用生产 home_build_external_fixed_approval_evidence()，
-- ##  而该函数硬性要求：projection 原币额/币种 = request.amount/currency、
-- ##  固定项币种 JPY、卡结算币种 JPY、funding channel 币种 JPY。
-- ##
-- ##  因此即使 CNY 固定项与跨币种 projection 都成功写入，也会在证据构造阶段
-- ##  抛错、整笔批准事务回滚；已批准请求的幂等分支同样调用它，同样失败。
-- ##  该函数的返回 JSON 本身已含 original/settlement 两组字段，要改的是校验
-- ##  逻辑而非返回结构。
-- ##
-- ##  内容将并入 Cash 单侧的原子替代文件。本文件保留仅为审核轨迹。
-- ###########################################################################

-- 审批核心支持跨币种 —— 工行卡（第 3 步 / 共 3 步）
--
-- 日期：2026-09-03
-- 部署顺序：**必须最后执行。** 本文件读 home_external_transaction_requests 的
--           original_amount / original_currency（第 1 步加的），并写出
--           original ≠ settlement 的 projection 行（第 2 步放开的约束）。
--           前两步任一未部署，本文件都会在运行时失败。
--
-- 基线：home_apply_external_fixed_transaction_approval 取自 2026-09-03 生产
--       pg_get_functiondef 导出。
--
-- ===========================================================================
-- 与基线的差异 —— 只有 4 处（E2：改动行数超出预期即说明动了不该动的地方）
-- ===========================================================================
--
--   ① 契约检查：删掉 `v_request.currency <> 'JPY'`，改为校验 original_* 三件事
--   ② 渠道检查：`v_channel.currency <> 'JPY'` → 必须等于卡的 settlement_currency
--   ③ 固定项插入：币种由写死的 'JPY' 改为 v_request.currency
--   ④ projection 插入：original 两列改取 v_request.original_*，不再与 settlement 同源
--
-- 其余全部逐字未改：锁顺序、幂等分支、九项前置拒绝、schedule 一致性比对、
-- advance 冲突检查、身份冲突检查、business_month 解析、证据构造、异常处理。
--
-- ===========================================================================
-- 为什么删掉 `v_request.currency <> 'JPY'` 是安全的
-- ===========================================================================
--
-- 它不是唯一的币种守卫。本函数在此之前已经有：
--
--   if v_card.settlement_currency is distinct from v_request.currency then
--     → HOME_FIXED_APPROVAL_CARD_INVALID
--
-- 即「request 的币种必须等于卡的结算币种」。西武卡 settlement_currency = 'JPY'，
-- 所以对西武卡而言，删掉那行之后的判定结果**逐字相同**——JPY 之外的 request
-- 仍然会在卡检查那里被拒，只是错误码从 CONTRACT_INVALID 变成 CARD_INVALID。
--
-- 加上表级 home_external_transaction_requests_currency_check 只允许 JPY / CNY，
-- 币种的取值范围本来就是封闭的。
--
-- ===========================================================================
-- 为什么渠道检查要跟着卡的结算币种走
-- ===========================================================================
--
-- 西武卡的还款渠道是邮局卡（JPY），工行卡是支付宝（CNY）。硬编码 JPY 会让工行卡
-- 在渠道检查处必然失败。
--
-- 改成「等于卡的 settlement_currency」而不是「等于 request 的 currency」，是因为
-- 渠道属于卡的配置，与单次请求无关。这与 home_validate_card_instrument 的既有
-- 规则一致——那个触发器在写卡时就要求
-- `v_channel.currency is distinct from new.settlement_currency` 则拒绝
-- （见 supabase-update-20260903-card-funding-month-offset.sql 第 140 行）。
--
-- 所以本处实际上是把一条已经在写入侧成立的不变式，在审批侧改成同一种表述，
-- 而不是新增规则。
--
-- ===========================================================================
-- 固定项落在哪个币种
-- ===========================================================================
--
-- 固定项是「用户这个月要还的那笔钱」，所以币种必须是**结算币种**：
-- 工行卡的固定项是 CNY，用支付宝还；西武卡的是 JPY，往邮局卡里存。
--
-- home_fixed_month_items_currency_check 本来就允许 CNY，无需改约束。
-- 标记已付走 home_confirm_projection_fixed_item_status，该函数币种无关、
-- 且不生成任何流水，因此 funding_status 对两张卡都恒为 'unfunded'。
--
--   注：这一点证伪了 docs/lessons.md D2 里「CNY 侧可以真正推进到 funded」的推测。
--   那条推测假定 projection 项走 home_update_cny_fixed_item_status（该函数会经
--   home_upsert_cny_fixed_transaction 生成流水，可充当 funding_transaction_id），
--   但那个函数对 projection 项**明确拒绝**（Phase 3F，
--   HOME_PROJECTION_FIXED_ITEM_STATUS_FORBIDDEN）。两张卡在这一点上是对称的。
--   D2 应据此修订。
--
-- ===========================================================================
-- 向后兼容 —— 西武卡必须逐字不变
-- ===========================================================================
--
-- 第 1 步已把历史 fixed 请求回填成 original = settlement，且表级约束保证同币种时
-- 两者必然相等。因此对西武卡：
--
--   ① 契约检查：新增的三项对 original ≡ settlement 的行全部成立，不改变判定
--   ② 渠道检查：卡的 settlement_currency = 'JPY'，与原来的字面量等价
--   ③ 固定项币种：v_request.currency = 'JPY'，与原来的字面量等价
--   ④ projection：original_* = settlement_*，与原来「两组同源」的结果逐字相同
--
-- 四处改动对西武卡全部退化为恒等变换。这是可证伪的：见部署后验证第三节。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   恢复 home_apply_external_fixed_transaction_approval 至 2026-09-03 生产导出的
--   基线定义（归档于 ~/aozora-security-20260827/cash-baseline/）。
--
--   本文件只 create or replace 一个函数，不改表、不改约束、不改权限，
--   回滚即单纯换回函数体。
--
--   若此时表内已有跨币种 projection 行，回滚后那些行仍然存在且合法（第 2 步的
--   约束还在），只是无法再产生新的。要彻底回到跨币种之前，须按 3→2→1 逆序回滚，
--   且第 2 步回滚前须先处理掉跨币种数据。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

create or replace function public.home_apply_external_fixed_transaction_approval(
  p_request_id uuid,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_cycle public.home_card_statement_cycles%rowtype;
  v_projection public.home_external_fixed_payment_projections%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_advance public.home_fixed_advance_payments%rowtype;
  v_schedule record;
  v_business_month date;
  v_projection_id uuid := gen_random_uuid();
  v_item_id uuid := gen_random_uuid();
  v_now timestamptz := statement_timestamp();
  v_evidence jsonb;
begin
  if p_request_id is null or p_actor_id is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_REQUIRED_INPUT', 'message', 'request and actor are required');
  end if;

  select * into v_request
  from public.home_external_transaction_requests r
  where r.id = p_request_id
  for update;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_REQUEST_NOT_FOUND', 'message', 'fixed request not found');
  end if;
  if v_request.user_id is distinct from p_actor_id then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_OWNER_MISMATCH', 'message', 'authenticated user does not own the fixed request');
  end if;
  if v_request.payment_route <> 'fixed_credit_card' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_WRONG_ROUTE', 'message', 'request is not a fixed credit-card request');
  end if;
  if v_request.status = 'rejected' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ALREADY_REJECTED', 'message', 'rejected fixed request cannot be approved');
  end if;

  select * into v_card
  from public.home_card_instruments c
  where c.id = v_request.card_instrument_id
  for share;
  if not found then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CARD_INVALID', 'message', 'fixed card does not exist');
  end if;

  perform public.home_lock_card_fixed_month(v_card.id, v_request.target_fixed_month);

  select * into v_cycle
  from public.home_card_statement_cycles c
  where c.card_instrument_id = v_card.id
    and c.target_fixed_month = v_request.target_fixed_month
  for update;

  if v_request.fixed_projection_id is not null then
    select * into v_projection
    from public.home_external_fixed_payment_projections p
    where p.id = v_request.fixed_projection_id
    for update;
    if found then
      select * into v_item
      from public.home_fixed_month_items i
      where i.id = v_projection.fixed_month_item_id
      for update;
    end if;
  end if;

  -- 预付/垫付冲突检查按**结算币种**匹配：工行卡查 CNY 的记录，西武卡查 JPY 的。
  -- v_request.currency 恒为结算币种，此处逻辑逐字未改。
  select * into v_advance
  from public.home_fixed_advance_payments a
  where a.user_id = v_request.user_id
    and a.month_key = to_char(v_request.target_fixed_month, 'YYYY-MM')
    and a.currency = v_request.currency
    and a.payment_group = (
      select c.name from public.home_payment_channels c
      where c.id = v_card.funding_payment_channel_id
    )
  for update;

  if v_request.status = 'approved' then
    begin
      v_evidence := public.home_build_external_fixed_approval_evidence(v_request.id);
    exception when others then
      raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_IDEMPOTENCY_INTEGRITY_ERROR', detail = sqlerrm;
    end;
    return v_evidence || jsonb_build_object('inserted', false, 'idempotent', true, 'message', 'fixed request approval already exists');
  end if;
  if v_request.status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_STATUS_INVALID', 'message', 'only pending fixed requests can be approved');
  end if;
  if v_request.account_id is not null or v_request.funding_account_id is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ACCOUNT_UNEXPECTED', 'message', 'fixed request must not contain an account or funding account');
  end if;
  if v_request.created_transaction_id is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ORDINARY_TRANSACTION_EXISTS', 'message', 'fixed request unexpectedly contains an ordinary transaction');
  end if;
  if v_request.fixed_projection_id is not null or v_request.projection_status <> 'pending' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_PROJECTION_CONFLICT', 'message', 'pending fixed request already contains projection evidence');
  end if;

  -- 币种守卫：request 的 currency 必须等于卡的结算币种。这一条在删掉契约检查里的
  -- `currency <> 'JPY'` 之后，成为币种唯一的把关点。
  if v_card.user_id is distinct from v_request.user_id
     or v_card.settlement_currency is distinct from v_request.currency
     or v_card.is_active is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CARD_INVALID', 'message', 'fixed card is inactive, wrong owner, or wrong currency');
  end if;
  if v_card.is_school_fixed_route_enabled is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_CARD_ROUTE_DISABLED', 'message', 'School fixed credit-card route is disabled');
  end if;

  -- ① 契约检查
  --    删：v_request.currency <> 'JPY'（已由上面的卡币种比对覆盖）
  --    加：原币三项——非空、为正、取值合法，以及同币种时两个金额必须相等。
  --    最后一项与表级 home_external_requests_original_amount_contract_check 重复，
  --    是有意的：审批是不可逆写入的最后一道关，此处失败关闭比依赖上游更稳。
  if v_request.transaction_type <> 'expense'
     or v_request.external_source <> 'aozora_school'
     or v_request.external_reference_type <> 'school_expense_records'
     or v_request.request_type <> 'expense_paid'
     or v_request.accounting_scope <> 'school'
     or v_request.amount <= 0
     or v_request.original_amount is null
     or v_request.original_amount <= 0
     or v_request.original_currency is null
     or v_request.original_currency not in ('JPY', 'CNY')
     or (v_request.original_currency = v_request.currency
         and v_request.original_amount is distinct from v_request.amount)
     or v_request.charge_date is null
     or v_request.target_fixed_month is distinct from v_request.suggested_fixed_month
     or v_request.fixed_month_override_reason is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_REQUEST_CONTRACT_INVALID', 'message', 'fixed request route, identity, amount, currency, or target contract is invalid');
  end if;

  -- ② 渠道检查：币种跟卡的结算币种走，不再硬编码 JPY。
  --    西武卡 → 邮局卡（JPY），工行卡 → 支付宝（CNY）。
  select * into v_channel
  from public.home_payment_channels c
  where c.id = v_card.funding_payment_channel_id
  for key share;
  if not found
     or v_channel.user_id is distinct from v_request.user_id
     or v_channel.currency is distinct from v_card.settlement_currency
     or v_channel.is_active is not true
     or nullif(btrim(v_channel.name), '') is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CHANNEL_INVALID', 'message', 'card funding channel is invalid');
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_card.id, v_request.charge_date);
  if v_request.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_request.target_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_request.payload_snapshot ->> 'funding_date' is distinct from v_schedule.funding_date::text
     or v_request.payload_snapshot ->> 'card_instrument_id' is distinct from v_card.id::text
     or v_request.payload_snapshot ->> 'charge_date' is distinct from v_request.charge_date::text
     or v_request.payload_snapshot ->> 'suggested_fixed_month' is distinct from v_request.suggested_fixed_month::text
     or v_request.payload_snapshot ->> 'target_fixed_month' is distinct from v_request.target_fixed_month::text then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_SCHEDULE_MISMATCH', 'message', 'fixed request schedule does not match current Cash DB authority');
  end if;
  if found and v_cycle.amount_status = 'confirmed' then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_STATEMENT_CONFIRMED', 'message', 'statement cycle is already confirmed');
  end if;
  if v_advance.id is not null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_GROUP_ALREADY_FUNDED', 'message', 'target month and payment group already has an advance/funding record');
  end if;

  if exists (
    select 1 from public.home_external_fixed_payment_projections p
    where p.external_request_id = v_request.id
       or p.external_event_id = v_request.external_event_id
       or p.external_idempotency_key = v_request.idempotency_key
       or p.school_expense_id = v_request.external_reference_id
  ) then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_PROJECTION_CONFLICT', 'message', 'conflicting fixed projection already exists');
  end if;

  begin
    if coalesce(v_request.payload_snapshot ->> 'year_month', '') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception using errcode = '22007', message = 'invalid year_month';
    end if;
    v_business_month := to_date(v_request.payload_snapshot ->> 'year_month' || '-01', 'YYYY-MM-DD');
  exception when others then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_BUSINESS_MONTH_INVALID', 'message', 'School expense business month is missing or invalid');
  end;
  if nullif(btrim(v_request.description), '') is null then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_ITEM_NAME_INVALID', 'message', 'School expense display name is missing');
  end if;

  -- ③ 固定项币种 = 结算币种。固定项表达的是「这个月要还的那笔钱」，
  --    工行卡为 CNY（支付宝还），西武卡为 JPY（存进邮局卡）。
  insert into public.home_fixed_month_items(
    id, user_id, template_id, month_key, currency, direction, name, amount,
    status, account_id, payment_group, due_date, term_no, total_terms, note,
    linked_jpy_transaction_id, linked_cny_transaction_id, accounting_scope
  ) values (
    v_item_id, v_request.user_id, null, to_char(v_request.target_fixed_month, 'YYYY-MM'),
    v_request.currency, 'expense', v_request.description, v_request.amount, 'unpaid', null,
    v_channel.name, v_schedule.funding_date, null, null, v_request.note,
    null, null, 'school'
  );

  -- ④ projection 的两组金额不再同源：
  --      original_*   = 原币（工行卡为 JPY 租金合同额）
  --      settlement_* = 结算币（工行卡为 CNY 账单额），也是固定项的金额
  --    settlement_amount_status 仍写 'confirmed'——方案乙下提交时金额已确定。
  insert into public.home_external_fixed_payment_projections(
    id, user_id, external_request_id, external_source,
    external_reference_type, external_reference_id, external_event_id,
    external_idempotency_key, school_expense_id, payment_route,
    card_instrument_id, funding_payment_channel_id, funding_account_id,
    business_month, charge_date, suggested_fixed_month, target_fixed_month,
    funding_date, original_amount, original_currency, settlement_amount,
    settlement_currency, settlement_amount_status, fixed_month_item_id,
    projection_status, funding_status, funding_transaction_id,
    supersedes_projection_id, fixed_month_override_reason,
    fixed_month_override_actor, fixed_month_overridden_at, created_at,
    approved_at, funded_at, updated_at, version
  ) values (
    v_projection_id, v_request.user_id, v_request.id, v_request.external_source,
    v_request.external_reference_type, v_request.external_reference_id,
    v_request.external_event_id, v_request.idempotency_key,
    v_request.external_reference_id, 'fixed_credit_card', v_card.id,
    v_channel.id, null, v_business_month, v_request.charge_date,
    v_request.suggested_fixed_month, v_request.target_fixed_month,
    v_schedule.funding_date, v_request.original_amount, v_request.original_currency,
    v_request.amount, v_request.currency, 'confirmed', v_item_id,
    'projected', 'unfunded', null, null, null, null, null,
    v_now, v_now, null, v_now, 1
  );

  update public.home_external_transaction_requests r
  set status = 'approved', approved_at = v_now,
      fixed_projection_id = v_projection_id,
      projection_status = 'projected', updated_at = v_now
  where r.id = v_request.id;

  v_evidence := public.home_build_external_fixed_approval_evidence(v_request.id);
  return v_evidence || jsonb_build_object('inserted', true, 'idempotent', false, 'message', 'fixed request approved and projected');
exception
  when unique_violation then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_IDENTITY_CONFLICT', detail = sqlerrm;
end;
$function$;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、结构与权限
--   1. prosecdef 仍为 true，proconfig 仍为 {search_path=pg_catalog, public}
--   2. **proacl 与部署前逐字相同**（create or replace 不应用 default privileges，
--      但 docs/lessons.md A3 要求实测而非假定）。部署前先导出 proacl 存档。
--   3. 函数 owner 未变
--   4. home_approve_external_fixed_transaction_request（外层入口）未改动
--
-- 二、逐行 diff（E2）
--   与 2026-09-03 生产基线 diff，**期望恰好 4 处改动**：
--     ① 契约检查块：删 1 行、增 8 行
--     ② 渠道检查：改 1 行
--     ③ 固定项 insert 的 values：改 1 行（'JPY' → v_request.currency）
--     ④ projection insert 的 values：改 1 行
--   注释另计。若出现第 5 处，说明转录出错，立即回滚。
--
-- 三、西武卡逐字不变（这一节比工行卡能不能跑通更重要）
--   在 rollback-only 事务中，用一条同币种 JPY 的 fixture 请求走完整批准：
--     1. 生成的 home_fixed_month_items：currency='JPY'、amount、month_key、
--        due_date、payment_group、accounting_scope 全部与基线行为相同
--     2. 生成的 projection：original 与 settlement 两组值相等
--     3. 返回的 evidence 结构与基线相同
--   **任何一项不同都说明向后兼容被破坏。**
--
-- 四、该失败的仍然失败（E4，rollback-only）
--   逐条构造并期望被拒，错误码必须精确匹配：
--     a. 卡的 settlement_currency 与 request.currency 不符   → CARD_INVALID
--     b. 渠道币种与卡的 settlement_currency 不符             → CHANNEL_INVALID
--     c. original_amount 为 NULL                             → CONTRACT_INVALID
--     d. original_amount <= 0                                → CONTRACT_INVALID
--     e. original_currency = 'USD'                           → CONTRACT_INVALID
--     f. 同币种但 original_amount <> amount                  → CONTRACT_INVALID
--     g. 卡 is_active = false                                → CARD_INVALID
--     h. 卡 route 未开                                       → ROUTE_DISABLED
--     i. schedule 与 payload_snapshot 不一致                 → SCHEDULE_MISMATCH
--     j. 重复批准（status 已 approved）                      → 幂等返回，不重复写
--     k. status = 'rejected'                                 → ALREADY_REJECTED
--   c～f 是本轮新增的守卫，a/b 是被改写的守卫，g～k 是未改动的守卫——
--   后者全部通过才能证明改动没有波及其他分支。
--
-- 五、工行卡形态可跑通（rollback-only fixture，最后做）
--   构造 CNY 渠道 + CNY 卡（cutoff 28 inclusive、funding 15、offset 1）+
--   CNY 家庭固定模板，请求 original JPY 166100 / settlement CNY 8000，
--   charge_date 2026-09-15：
--     1. 固定项：currency='CNY'、amount=8000、month_key='2026-10'、
--        due_date=2026-10-15、payment_group='支付宝'
--     2. projection：original JPY 166100 / settlement CNY 8000、
--        settlement_amount_status='confirmed'、funding_status='unfunded'
--     3. request 变 approved、projection_status='projected'
--
-- 六、不受影响
--   1. 那条真实的 pending 请求 3b926e75-a690-4a07-9a75-01cafba2edc1 不得被批准，
--      全部验证在 rollback-only 事务内进行
--   2. immediate 路线的 writer 未改动
--   3. home_calculate_card_fixed_schedule、home_validate_card_instrument 未改动
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 1. **本文件的函数体是否与生产基线逐字一致（除 4 处外）。** 我是从
--    2026-09-03 的 pg_get_functiondef 导出转录的，但 Cash AGENTS.md 明写
--    「repository SQL 不是生产函数体」。**部署前必须重新导出并逐行 diff**，
--    不要拿本文件当基线。若 diff 出现第 5 处差异，那是我的转录错误。
--
-- 2. **home_build_external_fixed_approval_evidence 是否假定单一金额/币种。**
--    它在批准成功后构造跨库证据、供 School 回写。若它只读 request.amount
--    而不读 original_*，School 侧拿到的证据里就缺原币信息。未查。
--
-- 3. **跨库指纹 request_payload_fingerprint 是否覆盖新增的金额字段。**
--    若不覆盖，original_amount 可以在两边漂移而指纹仍然一致——
--    **这是整个改动里最危险的一条**，指纹的意义就是防漂移。
--    需要查 School 侧指纹计算的输入集合。
--
-- 4. **home_validate_external_fixed_projection 等三个守卫**是否在函数体里重跑
--    「原币 = 结算币」的判断（docs/lessons.md C2 的坑）。第 2 步的文件里也列了
--    这一条，两处需一并确认。
--
-- 5. **home_card_statement_cycles / Phase 3E 账单确认链路的 JPY 假设。**
--    supabase-concurrency-20260819-phase3e-card-statement.zsh:57 在生成家庭账单项
--    时硬编码 'JPY'。本函数只读 v_cycle.amount_status，不受影响；但工行卡一旦
--    要接账单确认，那条链路要单独处理。**该口径尚未定，本轮不涉及。**
--
-- 6. 工行卡记录、支付宝渠道、CNY 家庭固定模板三者**在生产中均不存在**，
--    第五节的 fixture 需要现造。home_validate_card_instrument 要求
--    模板 currency = 卡的 settlement_currency、direction='expense'、
--    accounting_scope='household'、payment_group = 渠道名、is_active。
--
-- ===========================================================================
