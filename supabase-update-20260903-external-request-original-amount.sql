-- ###########################################################################
-- ##  作废，禁止执行 —— 2026-09-03 审核驳回（P1-1 / P1-3）
-- ##
-- ##  本文件加的约束要求 fixed 请求必须有 original_amount / original_currency，
-- ##  但两个 writer 都不写这两列：
-- ##    home_create_external_fixed_transaction_request
-- ##    home_prepare_external_transaction_correction_p_core
-- ##  School 固定卡 Gate 已开，执行本文件会让西武卡提交立刻 23514——
-- ##  这不是中间态，是生产中断。文件里「第 3 步会补上入参」那句是错的。
-- ##
-- ##  另：新增两列未纳入 home_validate_external_request_payment_route() 的
-- ##  不可变比较，service_role 可在创建后随意改；也未与 payload_snapshot 绑定。
-- ##
-- ##  替代方案：Cash 单侧一个事务原子落地，original 两列从 payload_snapshot
-- ##  读取（那四个键 School 早就在传）。本文件保留仅为审核轨迹。
-- ###########################################################################

-- 跨库固定请求的双金额模型 —— 为 JPY 消费 / CNY 结算的工行卡做准备（第 1 步 / 共 3 步）
--
-- 日期：2026-09-03
-- 部署顺序：**本文件必须最先执行。**
--   1. 本文件                                          加 original_amount / original_currency
--   2. supabase-update-20260903-projection-cross-currency.sql   放开 projection 两条 CHECK
--   3. supabase-update-20260903-cross-currency-fixed-approval.sql 改审批核心 4 处
-- 三者都部署完之前，跨币种请求无法产生（School 侧还没改），因此中间态是安全的。
--
-- 基线：home_external_transaction_requests 的列与 CHECK 取自 2026-09-03 生产只读导出。
--
-- ===========================================================================
-- 为什么需要
-- ===========================================================================
--
-- 工行卡是「日本教室租金 JPY 计价 → 工行按自己汇率折成 CNY 出账单 → 支付宝还
-- CNY」。原币与结算币不同，且两个金额都是**已知事实**：
--
--   original  = 租金合同金额（JPY），来自 School 支出记录
--   settlement = 工行账单上印的人民币数字（CNY），用户从账单抄
--
-- 而本表今天只有一组 amount / currency，承载不了两个事实。
-- 下游 home_external_fixed_payment_projections 却有 original_* 与 settlement_*
-- 两组列——审批核心目前把它们都填成 v_request.amount，两组列同源，等于没用。
--
-- ===========================================================================
-- 语义声明（业务模型扩展，需业务负责人批准后方可执行）
-- ===========================================================================
--
-- 新增两列，权威来源唯一，均由 School 侧在创建请求时一次性写入，此后不可变：
--
--   original_amount   numeric  null   原币金额。fixed 路线必填且 > 0；
--                                     immediate 路线恒为 NULL。
--   original_currency text     null   原币币种，JPY 或 CNY。同上。
--
-- **现有 amount / currency 的语义不变，但需明确记录**：它们表达的是
-- **结算币种下的金额**，即用户实际还款的那笔钱。对 immediate 路线这与今天
-- 完全一致（实际支付额）；对 fixed 路线在同币种时也与今天完全一致。
-- 这不是改语义，是把一直隐含的语义写明。
--
-- 可变性：两列不提供任何 UPDATE 通道，与 amount / currency 同级。
-- 权限：不新增任何 grant，沿用本表既有 ACL 与 RLS。
--
-- ===========================================================================
-- 为什么不改 route_fields_check，而是新加一条约束
-- ===========================================================================
--
-- home_external_requests_route_fields_check 是一条二十余个子句的巨型 CHECK，
-- 覆盖两条路线的全部字段互斥规则。把新列塞进去要整条重写，而重写一条这种长度
-- 的守卫，最可能的失败模式不是报错，是**某个子句在转录中被悄悄削弱**。
--
-- 因此新加一条只谈新列的窄约束，原约束逐字不动。
-- 部署后可用 pg_get_constraintdef 证明 route_fields_check 未变。
--
-- ===========================================================================
-- 回填 —— 这是本文件唯一触碰历史数据的动作
-- ===========================================================================
--
-- 新约束要求 fixed 路线的 original_* 非空，而历史 fixed 请求这两列是 NULL，
-- 所以必须先回填才能加约束。
--
-- 回填内容为 original := amount / currency，**这不是构造数据，是把一直成立的
-- 恒等式materialize 出来**：在本次改动之前，fixed 路线只允许同币种，且
-- home_apply_external_fixed_transaction_approval 就是把 projection 的
-- original_amount 填成 v_request.amount 的。
--
-- 交叉验证（部署前必须先跑，不通过则停止）：
--   对每一条已批准的 fixed 请求，其 projection 的 original_amount / original_currency
--   应当已经等于 request 的 amount / currency。若存在不等的行，说明我对历史语义的
--   理解有误，回填不能进行。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   alter table public.home_external_transaction_requests
--     drop constraint if exists home_external_requests_original_amount_contract_check;
--   alter table public.home_external_transaction_requests
--     drop column if exists original_currency,
--     drop column if exists original_amount;
--
--   删列即抹掉回填结果，无需单独反向回填。
--   回滚前须确认第 3 步（审批核心）已先行回滚——那个版本读这两列。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 0. 前置断言：历史 fixed 请求与其 projection 的原币金额确实同源
--
-- 这条如果失败，说明「历史上 original 恒等于 settlement」这个前提不成立，
-- 下面的回填就是在编数据。E3：这个检查在改动是错的时候一定会失败。
-- ---------------------------------------------------------------------------

do $$
declare
  v_bad integer;
begin
  select count(*) into v_bad
  from public.home_external_transaction_requests r
  join public.home_external_fixed_payment_projections p
    on p.external_request_id = r.id
  where r.payment_route = 'fixed_credit_card'
    and (p.original_amount is distinct from r.amount
      or p.original_currency is distinct from r.currency
      or p.settlement_amount is distinct from r.amount
      or p.settlement_currency is distinct from r.currency);

  if v_bad > 0 then
    raise exception
      'ABORT: % 条历史 projection 的金额/币种与其 request 不同源，回填前提不成立', v_bad;
  end if;
end
$$;

-- ---------------------------------------------------------------------------
-- 1. 加列
--
-- 两列都可空：immediate 路线永远不填，且历史行在回填之前也是空的。
-- 「fixed 必填」由下面的窄约束表达，而不是靠 NOT NULL——NOT NULL 无法区分路线。
-- ---------------------------------------------------------------------------

alter table public.home_external_transaction_requests
  add column if not exists original_amount numeric,
  add column if not exists original_currency text;

comment on column public.home_external_transaction_requests.original_amount is
  'Amount in the original (charged) currency. Required for fixed_credit_card, NULL for immediate_account. Authoritative source: School expense record.';
comment on column public.home_external_transaction_requests.original_currency is
  'Original (charged) currency, JPY or CNY. Required for fixed_credit_card, NULL for immediate_account.';

comment on column public.home_external_transaction_requests.amount is
  'Amount in the settlement currency — the money actually paid or repaid. For fixed_credit_card this is the card statement amount in the card settlement currency.';

-- ---------------------------------------------------------------------------
-- 2. 回填历史 fixed 请求
--
-- 范围限定在 payment_route = 'fixed_credit_card' 且 original_amount is null。
-- immediate 路线一行不碰。
-- ---------------------------------------------------------------------------

update public.home_external_transaction_requests
set original_amount = amount,
    original_currency = currency
where payment_route = 'fixed_credit_card'
  and original_amount is null;

-- ---------------------------------------------------------------------------
-- 3. 窄约束
--
-- 最后一个子句是西武卡不变式的表级表达：同币种时两个金额必须相等。
-- 没有它，同币种路线也能写出 original ≠ settlement 的行，而那种行在业务上
-- 没有任何含义。
-- ---------------------------------------------------------------------------

alter table public.home_external_transaction_requests
  drop constraint if exists home_external_requests_original_amount_contract_check;

alter table public.home_external_transaction_requests
  add constraint home_external_requests_original_amount_contract_check check (
    (
      payment_route = 'immediate_account'
      and original_amount is null
      and original_currency is null
    )
    or
    (
      payment_route = 'fixed_credit_card'
      and original_amount is not null
      and original_amount > 0
      and original_currency = any (array['JPY', 'CNY'])
      and (original_currency <> currency or original_amount = amount)
    )
  );

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、结构
--   1. 两列存在、均可空、无 default
--   2. 新约束存在，定义与本文件逐字一致
--   3. **home_external_requests_route_fields_check 的 pg_get_constraintdef 与
--      部署前逐字相同**——证明没有顺手动到那条巨型守卫
--   4. 本表的 relacl、RLS、policy、触发器均未变
--
-- 二、回填正确且范围受限
--   1. fixed 路线的行：original_amount = amount 且 original_currency = currency，
--      无 NULL 残留
--   2. immediate 路线的行：original_amount 与 original_currency 全部为 NULL
--      （历史上有 52 条 immediate 请求，应当一条未变）
--   3. 除这两列外，本表其余列的值与部署前逐行相同
--
-- 三、约束确实拦得住（rollback-only，E4：该失败的比该成功的更重要）
--   在事务里构造并期望全部被拒：
--     a. fixed 路线、original_amount 为 NULL                → 期望 23514
--     b. fixed 路线、original_amount = 0                    → 期望 23514
--     c. fixed 路线、original_currency = 'USD'              → 期望 23514
--     d. fixed 路线、同币种但 original_amount <> amount     → 期望 23514  ← 西武卡不变式
--     e. immediate 路线、original_amount 非空               → 期望 23514
--   对照组（应当成功）：
--     f. fixed 路线、original JPY 166100 / settlement CNY 8000  ← 工行卡形态
--     g. fixed 路线、original JPY 166100 / settlement JPY 166100 ← 西武卡形态
--
-- 四、不受影响
--   1. 那条 pending 的真实请求 3b926e75-a690-4a07-9a75-01cafba2edc1 除新增两列
--      被回填为 JPY / 166100 外，其余字段一字未动，status 仍为 pending
--   2. home_create_external_fixed_transaction_request 本轮未改动，因此现有提交
--      路径会因新约束而**失败**——这是预期的，第 3 步会补上入参。在三步全部
--      部署完之前不要从 School 提交新请求。
--      ↑ 这一条务必确认：若不能接受中间态阻塞提交，应把三个文件在同一个事务里执行。
--
-- ===========================================================================
-- 我没能验证的假设（交审时的攻击点）
-- ===========================================================================
--
-- 1. **本表是否有阻止 UPDATE 的守卫触发器。** 第 2 步的回填会 UPDATE 历史行，
--    其中包含 status = 'approved' / 'rejected' 的行。若存在「已定案请求不可改」
--    的触发器或 RLS UPDATE policy，回填会失败。我在写本文件时无法查询生产
--    （只读查询被安全策略拦截），未能列出本表的触发器清单。
--    **这是本文件最可能失败的地方，请先查 pg_trigger 与 pg_policies。**
--    若确实被挡：备选方案是把约束加成 NOT VALID、跳过回填，但那样历史行
--    永远处于豁免状态，需要单独判断是否接受。
--
-- 2. **fixed 路线历史请求的条数。** 已知至少有 1 条 pending
--    （3b926e75…）与若干 rejected。回填影响行数应在部署报告中给出实数。
--
-- 3. **是否存在 fixed 路线但无 projection 的已批准请求。** 第 0 步的断言用
--    join 实现，这类行不会被它检查到。若存在，回填对它们缺少交叉验证。
--
-- 4. 本表是否被任何视图、物化视图或 `select *` 的函数引用——加列本身安全，
--    但 `select *` into rowtype 的调用方在列数变化后行为需确认（
--    home_apply_external_fixed_transaction_approval 用的就是 %rowtype，
--    这是安全用法，但其余调用方未逐一排查）。
--
-- ===========================================================================
