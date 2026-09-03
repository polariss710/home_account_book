-- projection 表放开跨币种 —— 工行卡（第 2 步 / 共 3 步）
--
-- 日期：2026-09-03
-- 部署顺序：在 supabase-update-20260903-external-request-original-amount.sql 之后、
--           supabase-update-20260903-cross-currency-fixed-approval.sql 之前。
--
-- 基线：两条 CHECK 的定义取自 2026-09-03 生产 pg_get_constraintdef 只读导出：
--
--   home_external_fixed_projections_amount_check
--     CHECK (original_amount > 0 AND settlement_amount > 0
--            AND original_amount = settlement_amount)
--   home_external_fixed_projections_same_currency_check
--     CHECK (original_currency = settlement_currency)
--
-- 即 docs/lessons.md D1 记录的那两条。
--
-- ===========================================================================
-- 为什么需要
-- ===========================================================================
--
-- 本表有 original_amount / original_currency 与 settlement_amount /
-- settlement_currency 两组列，currency_check 也同时允许 JPY 与 CNY——结构上
-- 完全为跨币种准备好了。但这两条 CHECK 强制两组相等，把这个能力锁死。
--
-- 工行卡是 JPY 消费 / CNY 结算，两组必然不等。
--
-- 这比「审批核心里那行 JPY 判断」更根本：那是函数体里的一行，这是表级约束，
-- 改了函数不改约束，写入照样被拒。
--
-- ===========================================================================
-- 语义声明（业务模型扩展，需业务负责人批准后方可执行）
-- ===========================================================================
--
-- 放开后 original_* 与 settlement_* 成为两个独立的业务事实：
--
--   original_*   原币（消费币种）下的金额，来源为 School 支出记录的合同金额
--   settlement_* 结算币种下的金额，来源为信用卡账单上的实际数字
--
-- 两者各有唯一权威来源，都由 School 侧在提交时给定，本表只做落库。
-- 不引入任何由本系统推导的中间量——**特别是不引入汇率**：两个金额都是已知
-- 事实，从它们反推出的汇率没有业务用途，多一个可写字段只会多一个权威冲突。
--
-- **不改变的事**（这是方案乙的边界，别顺手放开）：
--
--   home_external_fixed_projections_amount_status_check
--     CHECK (settlement_amount_status = 'confirmed')
--
--   本表预留了 settlement_amount_status 这个槽位，配合 projection_status 的
--   'corrected' 与 supersedes_projection_id，本可支持「先按估算金额投影、
--   出账单后修正」。但整个 Cash 仓库没有任何写入器会写这两个值，是空槽。
--
--   业务负责人 2026-09-03 已定口径：**等工行 28 日出账单、金额确定后再提交**。
--   因此结算金额在落库时就是确定值，settlement_amount_status 恒为 'confirmed'，
--   本轮不碰这条约束，也不需要开发修正通道（那是约 2000 行 SQL + Edge 协调器
--   的量级，且批准后不可逆）。
--
-- ===========================================================================
-- 为什么保留「同币种时金额必须相等」
-- ===========================================================================
--
-- 直接删掉两条约束最省事，但那样西武卡（JPY→JPY）也能写出 original ≠ settlement
-- 的行，而这种行在业务上没有任何含义，只会是 bug 的产物。
--
-- 因此改成条件式：币种相同则金额必须相同，币种不同才允许不同。
-- 西武卡的不变式从「表级恒等」降级为「表级条件恒等」，保护强度不变。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   alter table public.home_external_fixed_payment_projections
--     drop constraint if exists home_external_fixed_projections_amount_check,
--     drop constraint if exists home_external_fixed_projections_same_currency_amount_check,
--     add constraint home_external_fixed_projections_amount_check
--       check (original_amount > 0 and settlement_amount > 0
--              and original_amount = settlement_amount),
--     add constraint home_external_fixed_projections_same_currency_check
--       check (original_currency = settlement_currency);
--
--   **回滚前必须确认表内没有跨币种行**，否则恢复原约束会失败。
--   若工行卡已产生 projection，应先处理那些数据再回滚。
--   同时须确认第 3 步（审批核心）已先行回滚。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. amount_check：去掉「两个金额必须相等」，保留两个「必须为正」
-- ---------------------------------------------------------------------------

alter table public.home_external_fixed_payment_projections
  drop constraint if exists home_external_fixed_projections_amount_check;

alter table public.home_external_fixed_payment_projections
  add constraint home_external_fixed_projections_amount_check
  check (original_amount > 0 and settlement_amount > 0);

-- ---------------------------------------------------------------------------
-- 2. same_currency_check → 条件式
--
-- 旧约束禁止跨币种。新约束允许跨币种，但要求同币种时金额一致。
-- 改名是有意的：新旧语义不同，沿用旧名会让 pg_get_constraintdef 的读者
-- 以为约束没变过。
-- ---------------------------------------------------------------------------

alter table public.home_external_fixed_payment_projections
  drop constraint if exists home_external_fixed_projections_same_currency_check;

alter table public.home_external_fixed_payment_projections
  drop constraint if exists home_external_fixed_projections_same_currency_amount_check;

alter table public.home_external_fixed_payment_projections
  add constraint home_external_fixed_projections_same_currency_amount_check
  check (
    original_currency <> settlement_currency
    or original_amount = settlement_amount
  );

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、结构
--   1. amount_check 存在，定义为 original_amount > 0 and settlement_amount > 0
--   2. same_currency_amount_check 存在，定义与本文件逐字一致
--   3. **same_currency_check 已不存在**（旧名彻底消失，不留同名不同义的约束）
--   4. **amount_status_check 仍存在且仍为 settlement_amount_status = 'confirmed'**
--      ← 这是方案乙的边界，必须证明没被顺手放开
--   5. currency_check、month_check、override_check、reference_check、route_check、
--      source_check、status_check、funding_lifecycle_check、funding_status_check、
--      version_check 的 pg_get_constraintdef 与部署前逐字相同
--   6. 全部 FK、PK、索引、relacl、RLS、policy、触发器未变
--
-- 二、历史数据不受影响
--   表内现有行全部为同币种且金额相等，新约束对它们全部成立。
--   部署前后逐行比对 original_amount / settlement_amount / 两个 currency，
--   应当零差异。
--
-- 三、约束确实拦得住（rollback-only，E4）
--   期望被拒：
--     a. original_amount = 0                                  → 23514
--     b. settlement_amount = 0                                → 23514
--     c. original JPY 166100 / settlement JPY 999             → 23514  ← 西武卡不变式
--     d. settlement_amount_status = 'pending'                 → 23514  ← 方案乙边界
--   期望成功：
--     e. original JPY 166100 / settlement CNY 8000            ← 工行卡形态
--     f. original JPY 166100 / settlement JPY 166100          ← 西武卡形态
--
--   c 与 d 比 e 更重要：它们证明放开是**受控的**，而不是把守卫整条拆了。
--
-- 四、不受影响
--   1. home_apply_external_fixed_transaction_approval 本轮未改，仍把两组列填成
--      同一个值，因此现有 JPY 路径行为逐字不变
--   2. home_validate_external_fixed_projection、
--      home_guard_external_fixed_projection_immutable、
--      home_guard_projection_linked_fixed_item 三个守卫未改动
--   3. 那条 pending 请求尚未批准，本表未新增任何行
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 1. **三个守卫函数里是否另有一份「原币 = 结算币」的检查。**
--    表级约束放开了，但 home_validate_external_fixed_projection 若在函数体里
--    重跑同样的判断，放开就是白做——这正是 docs/lessons.md C2 记过的坑
--    （改函数不等于改行为，因为触发器在重跑同一套检查）。
--    我未能导出这三个函数的生产定义（只读查询被安全策略拦截）。
--    **部署前必须 pg_get_functiondef 逐个查一遍。**
--
-- 2. **home_build_external_fixed_approval_evidence 的返回结构**是否假定单一
--    金额/币种。它是审批成功后的证据构造器，跨库回写 School 靠它。未查。
--
-- 3. **Cash 前端「本月人民币固定支出」列表**对 projection 项的渲染与筛选未查。
--    CNY 固定项本身受支持（home_fixed_month_items_currency_check 允许 CNY），
--    且标记已付走的是 home_confirm_projection_fixed_item_status（币种无关、
--    不产流水），但列表页是否按币种分流未确认。
--
-- 4. 本表现有行数与「全部同币种」这个前提，来自 2026-09-03 的只读导出与
--    约束本身的存在（旧 CHECK 保证了这一点），但未逐行点数。
--
-- ===========================================================================
