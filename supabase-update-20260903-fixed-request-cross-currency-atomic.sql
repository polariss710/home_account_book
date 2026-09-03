-- 跨库固定请求支持跨币种 —— 工行卡（JPY 消费 / CNY 结算），Cash 单侧原子落地
--
-- 日期：2026-09-03
-- 取代：supabase-update-20260903-external-request-original-amount.sql
--       supabase-update-20260903-projection-cross-currency.sql
--       supabase-update-20260903-cross-currency-fixed-approval.sql
--       上述三个文件已被审核驳回并加作废头，保留仅为轨迹，禁止执行。
--
-- 基线：五个函数均取自 2026-09-03 生产 pg_get_functiondef 导出，
--       归档于 ~/aozora-security-20260827/cash-baseline/，逐份核过 SHA-256：
--
--   home_create_external_fixed_transaction_request   md5 dd50ebe732932670c07656a4dd1d1abe
--   home_validate_external_request_payment_route     md5 a6720c24d99c14fc090dcdd502babdd0
--   home_validate_external_fixed_projection          md5 cd6e4a7e3b814a942c8eda100f283855
--   home_build_external_fixed_approval_evidence      md5 4e805ca332a5d7df4a35fb9c82176743
--   home_apply_external_fixed_transaction_approval   md5 edd41ae6488737e6fb2068605fd1b614
--
-- ===========================================================================
-- 为什么是一个事务
-- ===========================================================================
--
-- 首版拆成三个文件分事务部署，被驳回。根因：新 CHECK 要求 fixed 请求必须有
-- original_*，而 writer 在后面的文件里才改——School 固定卡 Gate 已开，
-- 中间那段时间西武卡提交会直接 23514。**那不是中间态，是生产中断窗口。**
--
-- 本文件把基线断言、加列、回填、约束、五个函数改动全部放进一个事务。任一步失败
-- 则整体回滚，生产不存在「约束已加但 writer 未改」的时刻。
--
-- ===========================================================================
-- 语义声明（业务模型扩展，需业务负责人批准后方可执行）
-- ===========================================================================
--
-- home_external_transaction_requests 新增两列：
--
--   original_amount   numeric  null   原币（消费币种）金额
--   original_currency text     null   原币币种，JPY 或 CNY
--
-- 权威来源：School 支出记录，经 payload_snapshot 传递（见下节）。
-- 可变性：创建后冻结，纳入 home_validate_external_request_payment_route()
--         的不可变字段比较。
-- 权限：不新增任何 grant，沿用本表既有 ACL 与 RLS。
--
-- **现有 amount / currency 语义不变**，但需明确记录：它们表达的是**结算币种下
-- 的金额**，即用户实际还款的那笔钱。对 immediate 路线与同币种 fixed 路线，
-- 这与今天完全一致；本次只是把一直隐含的语义写明。
--
-- ===========================================================================
-- 为什么原币从 payload_snapshot 读，而不是给创建器加入参
-- ===========================================================================
--
-- 加入参意味着 School Edge 必须同波次改，而两个仓库的部署无法原子，
-- 于是必须拆成三波（Cash 接受可选 → School 开始传 → Cash 收紧必填），
-- 中间会有一段「Cash 允许 NULL」的窗口，那段时间创建的请求到批准时会被拒。
--
-- 而原币事实**早就传过来了**：School prepare RPC 写进 payload_snapshot 的 31 个键
-- 里，original_amount / original_currency / settlement_amount / settlement_currency
-- 四个全在；School 的 fixed fingerprint 也覆盖这四个字段（审核已实证），
-- 因此快照对这四项是防篡改的。而创建器第 58–65 行本来就在把 11 个字段与快照
-- 逐一比对——把这两列也纳入比对并落库，是沿用既有机制，不是新增通道。
--
-- 代价：这两列的来源与其他字段不一致（别人是参数，它俩是快照）。
-- 已在创建器与触发器的相应位置写明，避免后来者误以为是遗漏。
--
-- ===========================================================================
-- 为什么按 request_type 分界，以及 Correction-P 为什么不动
-- ===========================================================================
--
-- 首版打算「所有 fixed 请求统一从快照读」，审核在前置条件处硬停止：
-- 生产里那条 approved 的 Correction-P 请求（8f2a9aff…，202,991 JPY）
-- **快照里四个键一个都没有**。它的 payload 是另一套形状。
--
-- 分界线用的是表里已有的契约维度，不是新造的：
--
--   home_external_transaction_requests_correction_link_check
--     correction_id 非空 ⇔ request_type = 'expense_fixed_correction_p'
--   home_validate_external_request_payment_route()
--     correction_id 为空 ⇒ request_type 必须是 'expense_paid'
--   home_apply_external_fixed_transaction_approval
--     契约检查 request_type <> 'expense_paid' 直接拒
--
-- 审核已实证：在现行约束、触发器与 writer 下**不存在第三种合法的 fixed
-- request_type**；且 Correction-P 走
-- home_prepare_external_transaction_correction_p_core 自建 request + item +
-- projection 并自行置为 approved，**完全不经过本文件修改的批准核心**。
--
-- 因此：
--
--   expense_paid              → 新列必填，从快照读，本轮支持跨币种
--   expense_fixed_correction_p → 新列保持 NULL，本轮完全不碰
--   immediate_account          → 新列保持 NULL（第三个 writer
--                                home_create_external_transaction_request 不写它们）
--
-- **遗留项：Correction-P 将来若要用于跨币种支出，需要单独一轮，届时要给它定
-- 原币的来源。** 现在它的请求两列是 NULL，这是有意的，不是漏了。
--
-- ===========================================================================
-- 执行顺序里的一个陷阱
-- ===========================================================================
--
-- 回填（第 3 步）必须排在替换 route validate 触发器（第 5 步）**之前**。
--
-- 因为第 5 步要把 original_amount / original_currency 加进该触发器的不可变字段
-- 比较，而回填本身是对历史行的 UPDATE——顺序一旦反过来，回填会被自己刚加的
-- 冻结拦成 42501 / FIXED_CARD_REQUEST_EVIDENCE_IMMUTABLE。
--
-- 同理，第 4 步（加 CHECK）要在第 3 步之后，否则历史行不满足约束。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
-- 五个函数全部恢复至 ~/aozora-security-20260827/cash-baseline/ 下 2026-09-03
-- 的生产导出，然后：
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
--   alter table public.home_external_transaction_requests
--     drop constraint if exists home_external_requests_original_amount_contract_check;
--   alter table public.home_external_transaction_requests
--     drop column if exists original_currency,
--     drop column if exists original_amount;
--
-- **顺序不能反**：触发器与创建器引用新列，必须先恢复函数再删列。
-- 删列即抹掉回填结果，无需反向回填。
-- 恢复 projection 原约束前须确认表内没有跨币种行。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 0. 生产基线断言（审核 P2-1）
--
-- 首版把「生产与文件头五个 MD5 一致」当成已知条件，靠部署流程保证。审核指出这
-- 不够：审核通过与实际部署之间若有别的生产改动，本文件会**静默覆盖**新定义。
-- 把断言写进原子文件本身，比依赖流程可靠——它跟改动同生共死。
--
-- 全部失败关闭。任一条不符即整个事务回滚，不会留下半部署状态。
--
-- 注：本节全部基于 pg_get_constraintdef(oid) 的 **canonical（非 pretty）形式**。
-- 2026-09-03 首次部署尝试在这里硬停止过——当时文件里的两个 md5 取自审核报告，
-- 而审核算的是 pg_get_constraintdef(oid, true)，两者不同，脚本会误报漂移。
-- 已统一到非 pretty 一侧：pretty 的换行缩进是给人看的，不保证跨版本稳定。
--
-- 那次停止本身是这套断言起作用的证据：它没有放行，也没有自作主张改常量。
-- ---------------------------------------------------------------------------

do $$
declare
  v_expected constant jsonb := jsonb_build_object(
    'home_apply_external_fixed_transaction_approval', 'edd41ae6488737e6fb2068605fd1b614',
    'home_build_external_fixed_approval_evidence',    '4e805ca332a5d7df4a35fb9c82176743',
    'home_create_external_fixed_transaction_request', 'dd50ebe732932670c07656a4dd1d1abe',
    'home_validate_external_fixed_projection',        'cd6e4a7e3b814a942c8eda100f283855',
    'home_validate_external_request_payment_route',   'a6720c24d99c14fc090dcdd502babdd0'
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
      raise exception 'ABORT: % 在生产中有 % 个重载，本文件只针对唯一重载', v_name, v_count;
    end if;

    select md5(p.prosrc) into v_actual
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public' and p.proname = v_name;

    if v_actual is distinct from (v_expected ->> v_name) then
      raise exception 'ABORT: % 的生产定义已漂移，期望 md5 %，实际 %',
        v_name, v_expected ->> v_name, v_actual;
    end if;
  end loop;
end $$;

do $$
declare
  v_def text;
begin
  -- 两列必须尚未存在。有了这条，ADD COLUMN 不会接受一个类型/可空性不符预期的
  -- 半部署状态（下面的 add column 也已去掉 IF NOT EXISTS，两层保护）。
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name = 'home_external_transaction_requests'
      and column_name in ('original_amount', 'original_currency')
  ) then
    raise exception 'ABORT: original_amount / original_currency 已存在，可能是半部署状态';
  end if;

  -- 本文件要改的两条 projection 约束，定义必须与基线逐字相同
  select pg_get_constraintdef(oid) into v_def from pg_constraint
  where conrelid = 'public.home_external_fixed_payment_projections'::regclass
    and conname = 'home_external_fixed_projections_amount_check';
  if v_def is distinct from
     'CHECK (((original_amount > (0)::numeric) AND (settlement_amount > (0)::numeric) AND (original_amount = settlement_amount)))' then
    raise exception 'ABORT: projection amount_check 已漂移：%', coalesce(v_def, '(不存在)');
  end if;

  select pg_get_constraintdef(oid) into v_def from pg_constraint
  where conrelid = 'public.home_external_fixed_payment_projections'::regclass
    and conname = 'home_external_fixed_projections_same_currency_check';
  if v_def is distinct from 'CHECK ((original_currency = settlement_currency))' then
    raise exception 'ABORT: projection same_currency_check 已漂移：%', coalesce(v_def, '(不存在)');
  end if;

  -- 方案乙的边界。本文件不碰它，但它若已被别人放开，本文件的前提就不成立。
  select pg_get_constraintdef(oid) into v_def from pg_constraint
  where conrelid = 'public.home_external_fixed_payment_projections'::regclass
    and conname = 'home_external_fixed_projections_amount_status_check';
  if v_def is distinct from 'CHECK ((settlement_amount_status = ''confirmed''::text))' then
    raise exception 'ABORT: projection amount_status_check 已漂移：%', coalesce(v_def, '(不存在)');
  end if;

  -- 本文件一字不碰的两条巨型约束，用 md5 钉住。
  --
  -- 哈希的是 pg_get_constraintdef(oid)，**不带 pretty 参数**。
  -- 2026-09-03 部署前核对时发现审核给的两个 md5 算的是
  -- pg_get_constraintdef(oid, true)，两者不同，脚本会在这里误报。
  -- 选非 pretty 一侧的理由：pretty 形式的换行与缩进是给人看的，PostgreSQL 不保证
  -- 它跨版本稳定，拿它当指纹将来会无故失败。canonical 形式才适合做断言。
  select md5(pg_get_constraintdef(oid)) into v_def from pg_constraint
  where conrelid = 'public.home_external_transaction_requests'::regclass
    and conname = 'home_external_requests_route_fields_check';
  if v_def is distinct from '00ad41cb72d3ee7a1de29f7f8781f4f9' then
    raise exception 'ABORT: route_fields_check 已漂移，实际 md5 %', coalesce(v_def, '(不存在)');
  end if;

  select md5(pg_get_constraintdef(oid)) into v_def from pg_constraint
  where conrelid = 'public.home_external_transaction_requests'::regclass
    and conname = 'home_external_transaction_requests_correction_link_check';
  if v_def is distinct from '2bc0f3da90d9f0cf9aa7c701e0beaad9' then
    raise exception 'ABORT: correction_link_check 已漂移，实际 md5 %', coalesce(v_def, '(不存在)');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 1. 数据前置断言
--
-- E3：如果我对历史语义的理解是错的，这些检查必须失败。
-- ---------------------------------------------------------------------------

-- 1a. 已批准的 fixed 请求与其 projection 金额同源（inner join）
do $$
declare v_bad integer;
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
    raise exception 'ABORT: % 条历史 projection 与其 request 金额不同源', v_bad;
  end if;
end $$;

-- 1b. 反连接盲区（首版被指出的 P2-2）：有没有 approved 的 fixed 请求根本没有
--     projection。上面 1a 用 inner join，检查不到这类行。
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
  from public.home_external_transaction_requests r
  where r.payment_route = 'fixed_credit_card'
    and r.status = 'approved'
    and not exists (
      select 1 from public.home_external_fixed_payment_projections p
      where p.external_request_id = r.id);
  if v_bad > 0 then
    raise exception 'ABORT: % 条 approved fixed 请求没有 projection，回填缺交叉验证', v_bad;
  end if;
end $$;

-- 1c. 待回填的行（expense_paid）在快照里必须四键齐全、数值可解析，且与行值一致。
--     若不成立，说明「原币事实早就在快照里」这个前提不成立，整个方案作废。
--
--     两处数值比较都套在 case 里先做形状判断再 cast。裸 cast 遇到非数字文本会抛
--     22P02，中止方向虽然是对的，但报出来的是不知所云的类型转换错误而不是这里
--     写的中止信息。case 会短路，能保证走到 cast 的一定是数字形状。
--     （与审核 P2-2 在创建器里指出的是同一类问题。）
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
  from public.home_external_transaction_requests r
  where r.payment_route = 'fixed_credit_card'
    and r.request_type = 'expense_paid'
    and (r.payload_snapshot ->> 'original_amount' is null
      or r.payload_snapshot ->> 'original_currency' is null
      or r.payload_snapshot ->> 'settlement_amount' is null
      or r.payload_snapshot ->> 'settlement_currency' is null
      or case
           when r.payload_snapshot ->> 'original_amount' ~ '^[0-9]+(\.[0-9]+)?$'
             then (r.payload_snapshot ->> 'original_amount')::numeric <= 0
           else true
         end
      or case
           when r.payload_snapshot ->> 'settlement_amount' ~ '^[0-9]+(\.[0-9]+)?$'
             then (r.payload_snapshot ->> 'settlement_amount')::numeric is distinct from r.amount
           else true
         end
      or r.payload_snapshot ->> 'settlement_currency' is distinct from r.currency);
  if v_bad > 0 then
    raise exception 'ABORT: % 条 expense_paid fixed 请求的快照缺四键、数值不可解析或与行值不符', v_bad;
  end if;
end $$;

-- 1d. 不存在第三种 fixed request_type。审核已按约束与触发器论证过，此处做运行时
--     兜底——将来若有人加了新类型而忘了改本文件的分界，这条会立刻失败。
do $$
declare v_bad integer;
begin
  select count(*) into v_bad
  from public.home_external_transaction_requests r
  where r.payment_route = 'fixed_credit_card'
    and r.request_type not in ('expense_paid', 'expense_fixed_correction_p');
  if v_bad > 0 then
    raise exception 'ABORT: 出现了本文件未覆盖的第三种 fixed request_type，共 % 条', v_bad;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- 2. 加列
--
-- 两列都可空：immediate 与 Correction-P 永远不填。「expense_paid 必填」由下面的
-- CHECK 表达，而不是 NOT NULL——NOT NULL 无法区分路线与请求类型。
-- ---------------------------------------------------------------------------

-- 不用 IF NOT EXISTS：第 0 步已断言两列不存在，此处让半部署状态直接报错，
-- 而不是被静默接受（审核 P2-1）。
alter table public.home_external_transaction_requests
  add column original_amount numeric,
  add column original_currency text;

comment on column public.home_external_transaction_requests.original_amount is
  'Amount in the original (charged) currency. Required for fixed_credit_card + expense_paid; NULL for immediate_account and for Correction-P. Source: payload_snapshot, itself covered by the School fingerprint.';
comment on column public.home_external_transaction_requests.original_currency is
  'Original (charged) currency, JPY or CNY. Same nullability contract as original_amount.';
comment on column public.home_external_transaction_requests.amount is
  'Amount in the settlement currency — the money actually paid or repaid. For fixed_credit_card this is the card statement amount in the card settlement currency.';

-- ---------------------------------------------------------------------------
-- 3. 回填
--
-- **必须在第 5 步替换触发器之前**，否则会被自己刚加的冻结拦下（见文件头）。
-- 范围：仅 fixed + expense_paid。immediate 与 Correction-P 一行不碰。
-- 值来自快照，已由 1c 断言其存在且与行值一致——不是构造数据。
-- ---------------------------------------------------------------------------

update public.home_external_transaction_requests
set original_amount = (payload_snapshot ->> 'original_amount')::numeric,
    original_currency = payload_snapshot ->> 'original_currency'
where payment_route = 'fixed_credit_card'
  and request_type = 'expense_paid'
  and original_amount is null;

-- ---------------------------------------------------------------------------
-- 4. CHECK 约束：三分支，把上面那张分界表写成声明式
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
      and request_type = 'expense_fixed_correction_p'
      and original_amount is null
      and original_currency is null
    )
    or
    (
      payment_route = 'fixed_credit_card'
      and request_type = 'expense_paid'
      and original_amount is not null
      and original_amount > 0
      and original_currency = any (array['JPY', 'CNY'])
      -- 同币种时两个金额必须相等：西武卡不变式的表级表达。
      -- 没有它，同币种也能写出 original ≠ settlement 的行，而那种行没有业务含义。
      and (original_currency <> currency or original_amount = amount)
    )
  );

-- ---------------------------------------------------------------------------
-- 5. route validate 触发器
--
-- 与基线的差异只有两处：
--   ① 两个 row() 各增加 original_amount / original_currency —— 纳入不可变冻结
--   ② 新增一段「非 Correction-P 时把原币/结算两组与快照绑定」
--
-- ① 是首版 P1-3 的直接修复。表是 RLS 非 FORCE，service_role 有表级 UPDATE 且
-- 绕过 RLS，所以 CHECK 拦不住「改成另一个合法值」——只有这里的不可变比较能拦。
-- 这也是 2026-09-03 当天第二次犯同一个错（第一次是 funding_month_offset），
-- 已作为 E6 写进 docs/lessons.md。
--
-- ② 关死「列值与快照漂移」：School 的指纹覆盖这四个字段，把列绑到快照上之后，
-- 跨库完整性才真正端到端成立。Correction-P 的快照没有这四个键，故跳过。
--
-- 其余逐字未改：immediate 早返回、correction 契约比对、School 身份检查、
-- 卡与 schedule 校验、target/override 规则、funding_date 解析、
-- Correction-P 授权消费、异常映射。
-- ---------------------------------------------------------------------------

create or replace function public.home_validate_external_request_payment_route()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_schedule record;
  v_snapshot_funding_date date;
  v_correction public.home_external_transaction_corrections%rowtype;
  v_is_correction boolean := new.correction_id is not null;
  v_consumed_authorization_id uuid;
  v_snapshot_original_amount numeric;
  v_snapshot_settlement_amount numeric;
begin
  if new.payment_route = 'immediate_account' then
    if new.correction_id is not null then
      raise exception using errcode='23514', message='IMMEDIATE_REQUEST_CANNOT_LINK_CORRECTION';
    end if;
    return new;
  end if;

  -- ① original_amount / original_currency 已纳入冻结集
  if tg_op='UPDATE' and row(
    new.user_id,new.external_source,new.external_event_id,
    new.external_reference_type,new.external_reference_id,
    new.request_type,new.transaction_type,new.currency,new.amount,
    new.original_amount,new.original_currency,
    new.account_id,new.transacted_at,new.idempotency_key,
    new.payload_snapshot,new.accounting_scope,new.payment_route,
    new.card_instrument_id,new.charge_date,new.suggested_fixed_month,
    new.funding_account_id,new.correction_id
  ) is distinct from row(
    old.user_id,old.external_source,old.external_event_id,
    old.external_reference_type,old.external_reference_id,
    old.request_type,old.transaction_type,old.currency,old.amount,
    old.original_amount,old.original_currency,
    old.account_id,old.transacted_at,old.idempotency_key,
    old.payload_snapshot,old.accounting_scope,old.payment_route,
    old.card_instrument_id,old.charge_date,old.suggested_fixed_month,
    old.funding_account_id,old.correction_id
  ) then
    raise exception using errcode='42501', message='FIXED_CARD_REQUEST_EVIDENCE_IMMUTABLE';
  end if;

  if v_is_correction then
    select * into v_correction
    from public.home_external_transaction_corrections c
    where c.id=new.correction_id;
    if not found
       or v_correction.status not in ('preparing','prepared','completed')
       or v_correction.original_home_request_id is distinct from
          (new.payload_snapshot->>'original_home_request_id')::uuid
       or v_correction.original_home_transaction_id is distinct from
          (new.payload_snapshot->>'original_home_transaction_id')::uuid
       or v_correction.school_expense_id is distinct from new.external_reference_id
       or v_correction.school_attempt_id is distinct from
          (new.payload_snapshot->>'school_attempt_id')::uuid
       or v_correction.external_event_id is distinct from new.external_event_id
       or v_correction.amount is distinct from new.amount
       or v_correction.currency is distinct from new.currency
       or new.request_type is distinct from 'expense_fixed_correction_p' then
      raise exception using errcode='23514', message='CORRECTION_P_REPLACEMENT_REQUEST_MISMATCH';
    end if;
  elsif new.request_type is distinct from 'expense_paid' then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_REQUIRES_SCHOOL_EXPENSE';
  end if;

  if new.transaction_type is distinct from 'expense'
     or new.external_source is distinct from 'aozora_school'
     or new.external_reference_type is distinct from 'school_expense_records'
     or new.accounting_scope is distinct from 'school'
     or new.account_id is not null
     or new.funding_account_id is not null then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_REQUIRES_SCHOOL_EXPENSE';
  end if;

  select * into v_card
  from public.home_card_instruments
  where id=new.card_instrument_id
  for key share;

  if not found
     or v_card.user_id is distinct from new.user_id
     or v_card.settlement_currency is distinct from new.currency
     or v_card.is_active is not true
     or (tg_op='INSERT' and v_card.is_school_fixed_route_enabled is not true and not v_is_correction) then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_DISABLED_OR_INVALID';
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(new.card_instrument_id,new.charge_date);

  if new.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_INVALID_SUGGESTED_MONTH';
  end if;
  if tg_op='INSERT' and (
    new.target_fixed_month is distinct from v_schedule.suggested_fixed_month
    or new.fixed_month_override_reason is not null
  ) then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_INITIAL_TARGET_MUST_MATCH_SUGGESTED';
  end if;
  if tg_op='UPDATE' and row(new.target_fixed_month,new.fixed_month_override_reason)
     is distinct from row(old.target_fixed_month,old.fixed_month_override_reason) then
    raise exception using errcode='42501', message='FIXED_CARD_ROUTE_OVERRIDE_REQUIRES_ADMIN_WRITER';
  end if;

  begin
    v_snapshot_funding_date := (new.payload_snapshot->>'funding_date')::date;
  exception when others then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_INVALID_FUNDING_DATE';
  end;

  if v_snapshot_funding_date is distinct from v_schedule.funding_date
     or new.payload_snapshot->>'payment_route' is distinct from 'fixed_credit_card'
     or new.payload_snapshot->>'card_instrument_id' is distinct from new.card_instrument_id::text
     or new.payload_snapshot->>'charge_date' is distinct from new.charge_date::text
     or new.payload_snapshot->>'suggested_fixed_month' is distinct from new.suggested_fixed_month::text
     or new.payload_snapshot->>'target_fixed_month' is distinct from new.target_fixed_month::text
     or coalesce(new.payload_snapshot->>'school_attempt_payload_fingerprint','') !~ '^[0-9a-f]{64}$' then
    raise exception using errcode='23514', message='FIXED_CARD_ROUTE_PAYLOAD_SNAPSHOT_MISMATCH';
  end if;

  -- ② 原币/结算两组金额与快照绑定（仅 expense_paid）
  --
  -- Correction-P 的 payload 是另一套形状，四个键都没有，故跳过；其两列由
  -- home_external_requests_original_amount_contract_check 强制为 NULL。
  --
  -- 这两列的值来自快照而非入参，与本表其他字段的来源不同——这是有意的，
  -- 理由见文件头「为什么原币从 payload_snapshot 读」。
  if not v_is_correction then
    begin
      v_snapshot_original_amount := (new.payload_snapshot->>'original_amount')::numeric;
      v_snapshot_settlement_amount := (new.payload_snapshot->>'settlement_amount')::numeric;
    exception when others then
      raise exception using errcode='23514', message='FIXED_CARD_ROUTE_INVALID_SNAPSHOT_AMOUNT';
    end;
    if v_snapshot_original_amount is distinct from new.original_amount
       or new.payload_snapshot->>'original_currency' is distinct from new.original_currency
       or v_snapshot_settlement_amount is distinct from new.amount
       or new.payload_snapshot->>'settlement_currency' is distinct from new.currency then
      raise exception using errcode='23514', message='FIXED_CARD_ROUTE_SNAPSHOT_AMOUNT_MISMATCH';
    end if;
  end if;

  if v_is_correction and tg_op='INSERT' then
    delete from public.home_correction_replacement_authorizations a
    where a.original_transaction_id=v_correction.original_home_transaction_id
      and a.operation_id=v_correction.operation_id
      and a.correction_id=v_correction.id
      and a.request_id=new.id
      and a.actor_id=v_correction.actor_id
      and a.replacement_type=new.request_type
      and a.fixed_month=new.target_fixed_month
      and a.card_instrument_id=new.card_instrument_id
      and a.payment_channel_id=v_card.funding_payment_channel_id
    returning a.id into v_consumed_authorization_id;
    if v_consumed_authorization_id is null then
      raise exception using errcode='42501', message='CORRECTION_P_REPLACEMENT_AUTHORIZATION_REQUIRED';
    end if;
  end if;
  return new;
exception
  when invalid_text_representation then
    raise exception using errcode='23514', message='CORRECTION_P_REPLACEMENT_REQUEST_MISMATCH';
end;
$function$;

-- ---------------------------------------------------------------------------
-- 6. 常规 fixed 请求创建器
--
-- 与基线的差异：
--   ① 新增两个局部变量，从 payload_snapshot 解析原币金额/币种
--   ② 幂等比对（正常分支与 unique_violation 分支各一处）纳入两列
--   ③ 既有的 payload 一致性检查扩充四个键
--   ④ INSERT 写入两列
--
-- **签名逐字未变**（仍是 18 参数），所以 School Edge 一行不用改，
-- 也就没有首版被驳回的那个生产中断窗口。
--
-- 本函数入口已经要求 request_type='expense_paid'，因此不需要按类型分岔。
-- ---------------------------------------------------------------------------

create or replace function public.home_create_external_fixed_transaction_request(
  p_user_id uuid, p_external_source text, p_external_event_id uuid,
  p_external_reference_type text, p_external_reference_id uuid,
  p_request_type text, p_transaction_type text, p_card_instrument_id uuid,
  p_charge_date date, p_suggested_fixed_month date, p_target_fixed_month date,
  p_funding_date date, p_amount numeric, p_currency text, p_idempotency_key text,
  p_description text default null::text, p_note text default null::text,
  p_payload_snapshot jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_card public.home_card_instruments%rowtype; v_schedule record;
  v_existing public.home_external_transaction_requests%rowtype; v_request_id uuid;
  v_source text:=lower(trim(coalesce(p_external_source,'')));
  v_reference_type text:=lower(trim(coalesce(p_external_reference_type,'')));
  v_request_type text:=lower(trim(coalesce(p_request_type,'')));
  v_transaction_type text:=lower(trim(coalesce(p_transaction_type,'')));
  v_currency text:=upper(trim(coalesce(p_currency,'')));
  v_key text:=nullif(trim(coalesce(p_idempotency_key,'')),'');
  v_description text:=coalesce(nullif(trim(coalesce(p_description,'')),''),'School信用卡固定支出请求');
  v_note text:=coalesce(p_note,''); v_payload jsonb:=coalesce(p_payload_snapshot,'{}'::jsonb);
  -- ① 原币事实来自快照，不是入参。理由见文件头。
  v_original_amount numeric;
  v_original_currency text;
  -- 结算额也先解析到局部变量再比较：直接在比较式里做 cast，遇到非数字文本会在
  -- INSERT 之前抛裸 22P02，而那时还到不了 route 触发器的受控异常映射，
  -- 新创建器的错误合同就不完整了（审核 P2-2）。
  v_settlement_amount numeric;
begin
  if coalesce(auth.role(),'')<>'service_role' then return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_SERVICE_ROLE_REQUIRED','message','service_role is required'); end if;
  if p_user_id is null or p_external_event_id is null or p_external_reference_id is null or p_card_instrument_id is null
     or p_charge_date is null or p_suggested_fixed_month is null or p_target_fixed_month is null
     or p_funding_date is null or coalesce(p_amount,0)<=0 or v_key is null then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_INPUT_REQUIRED','message','fixed request input is incomplete');
  end if;
  if v_source<>'aozora_school' or v_reference_type<>'school_expense_records' or v_request_type<>'expense_paid' or v_transaction_type<>'expense' then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_IDENTITY_INVALID','message','fixed request must reference a School expense');
  end if;

  -- ① 解析原币。放在幂等比对之前，因为下面两处比对都要用到它。
  --    解析失败一律失败关闭，不做任何默认值推导。
  begin
    v_original_amount := (v_payload->>'original_amount')::numeric;
  exception when others then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_ORIGINAL_AMOUNT_INVALID','message','payload snapshot original_amount is missing or not numeric');
  end;
  begin
    v_settlement_amount := (v_payload->>'settlement_amount')::numeric;
  exception when others then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_PAYLOAD_MISMATCH','message','payload snapshot settlement_amount is not numeric');
  end;
  v_original_currency := upper(trim(coalesce(v_payload->>'original_currency','')));
  if v_original_amount is null or v_original_amount<=0 or v_original_currency not in ('JPY','CNY') then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_ORIGINAL_AMOUNT_INVALID','message','payload snapshot original amount or currency is invalid');
  end if;

  select * into v_existing from public.home_external_transaction_requests r
  where r.idempotency_key=v_key or (r.external_source=v_source and r.external_event_id=p_external_event_id and r.request_type=v_request_type)
  order by (r.idempotency_key=v_key) desc limit 1;
  if found then
    if v_existing.user_id is distinct from p_user_id or v_existing.payment_route is distinct from 'fixed_credit_card'
       or v_existing.external_source is distinct from v_source or v_existing.external_event_id is distinct from p_external_event_id
       or v_existing.external_reference_type is distinct from v_reference_type or v_existing.external_reference_id is distinct from p_external_reference_id
       or v_existing.request_type is distinct from v_request_type or v_existing.transaction_type is distinct from v_transaction_type
       or v_existing.currency is distinct from v_currency or v_existing.amount is distinct from p_amount
       or v_existing.original_amount is distinct from v_original_amount
       or v_existing.original_currency is distinct from v_original_currency
       or v_existing.account_id is not null or v_existing.funding_account_id is not null
       or v_existing.card_instrument_id is distinct from p_card_instrument_id or v_existing.charge_date is distinct from p_charge_date
       or v_existing.suggested_fixed_month is distinct from p_suggested_fixed_month or v_existing.target_fixed_month is distinct from p_target_fixed_month
       or v_existing.fixed_month_override_reason is not null or v_existing.payload_snapshot is distinct from v_payload then
      return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_IDENTITY_PAYLOAD_CONFLICT','message','fixed request identity already exists with different payload','request_id',v_existing.id);
    end if;
    return jsonb_build_object('ok',true,'inserted',false,'request_id',v_existing.id,'status',v_existing.status,'payment_route',v_existing.payment_route,'created_transaction_id',v_existing.created_transaction_id,'message','fixed request already exists');
  end if;
  select * into v_card from public.home_card_instruments where id=p_card_instrument_id for key share;
  if not found or v_card.user_id is distinct from p_user_id or v_card.settlement_currency is distinct from v_currency or v_card.is_active is not true then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_CARD_INVALID','message','fixed request card is missing, inactive, wrong owner, or wrong currency');
  end if;
  if v_card.is_school_fixed_route_enabled is not true then return jsonb_build_object('ok',false,'code','HOME_FIXED_CARD_ROUTE_DISABLED','message','School fixed credit-card route is disabled'); end if;
  select * into v_schedule from public.home_calculate_card_fixed_schedule(p_card_instrument_id,p_charge_date);
  if p_suggested_fixed_month is distinct from v_schedule.suggested_fixed_month or p_target_fixed_month is distinct from v_schedule.suggested_fixed_month or p_funding_date is distinct from v_schedule.funding_date then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_SCHEDULE_MISMATCH','message','School fixed schedule does not match Cash DB authority');
  end if;
  perform public.home_lock_card_fixed_month(v_card.id,p_target_fixed_month);
  if exists(select 1 from public.home_card_statement_cycles c where c.user_id=p_user_id and c.card_instrument_id=v_card.id and c.target_fixed_month=p_target_fixed_month and c.amount_status='confirmed') then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_REOPEN_REQUIRED','message','statement is confirmed; reopen before creating a new fixed request');
  end if;
  -- ③ 既有的 payload 一致性检查，扩充结算两键（原币两键上面已校验过取值合法性，
  --    此处补上「快照结算额必须等于入参金额」这条跨字段绑定）
  if v_payload->>'external_source' is distinct from v_source or v_payload->>'external_reference_type' is distinct from v_reference_type
     or v_payload->>'external_reference_id' is distinct from p_external_reference_id::text or v_payload->>'request_type' is distinct from v_request_type
     or v_payload->>'transaction_type' is distinct from v_transaction_type or v_payload->>'payment_route' is distinct from 'fixed_credit_card'
     or v_payload->>'card_instrument_id' is distinct from p_card_instrument_id::text or v_payload->>'charge_date' is distinct from p_charge_date::text
     or v_payload->>'suggested_fixed_month' is distinct from p_suggested_fixed_month::text or v_payload->>'target_fixed_month' is distinct from p_target_fixed_month::text
     or v_payload->>'funding_date' is distinct from p_funding_date::text or coalesce(v_payload->>'school_attempt_payload_fingerprint','') !~ '^[0-9a-f]{64}$'
     or v_settlement_amount is distinct from p_amount
     or upper(trim(coalesce(v_payload->>'settlement_currency',''))) is distinct from v_currency then
    return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_PAYLOAD_MISMATCH','message','fixed request payload snapshot does not match canonical input');
  end if;
  select * into v_existing from public.home_external_transaction_requests r
  where r.external_source=v_source and r.external_reference_type=v_reference_type and r.external_reference_id=p_external_reference_id
    and r.request_type=v_request_type and r.status in ('pending','approved') limit 1;
  if found then return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_ACTIVE_REFERENCE_EXISTS','message','active or approved request already exists for this School expense','request_id',v_existing.id,'status',v_existing.status); end if;
  -- ④ 写入两列
  insert into public.home_external_transaction_requests(
    user_id,external_source,external_event_id,external_reference_type,external_reference_id,request_type,transaction_type,
    currency,amount,original_currency,original_amount,
    account_id,transacted_at,status,idempotency_key,payload_snapshot,description,note,accounting_scope,
    payment_route,card_instrument_id,charge_date,suggested_fixed_month,target_fixed_month,fixed_month_override_reason,
    funding_account_id,fixed_projection_id,projection_status
  ) values (
    p_user_id,v_source,p_external_event_id,v_reference_type,p_external_reference_id,v_request_type,v_transaction_type,
    v_currency,p_amount,v_original_currency,v_original_amount,
    null,p_charge_date,'pending',v_key,v_payload,v_description,v_note,'school','fixed_credit_card',
    p_card_instrument_id,p_charge_date,p_suggested_fixed_month,p_target_fixed_month,null,null,null,'pending'
  ) returning id into v_request_id;
  return jsonb_build_object('ok',true,'inserted',true,'request_id',v_request_id,'status','pending','payment_route','fixed_credit_card','message','fixed request created');
exception when unique_violation then
  select * into v_existing from public.home_external_transaction_requests r
  where r.idempotency_key=v_key or (r.external_source=v_source and r.external_event_id=p_external_event_id and r.request_type=v_request_type)
     or (r.external_source=v_source and r.external_reference_type=v_reference_type and r.external_reference_id=p_external_reference_id and r.request_type=v_request_type and r.status in ('pending','approved'))
  order by (r.idempotency_key=v_key) desc limit 1;
  if found and v_existing.user_id is not distinct from p_user_id and v_existing.payment_route is not distinct from 'fixed_credit_card'
     and v_existing.external_event_id is not distinct from p_external_event_id and v_existing.external_reference_type is not distinct from v_reference_type
     and v_existing.external_reference_id is not distinct from p_external_reference_id and v_existing.request_type is not distinct from v_request_type
     and v_existing.transaction_type is not distinct from v_transaction_type and v_existing.currency is not distinct from v_currency
     and v_existing.amount is not distinct from p_amount
     and v_existing.original_amount is not distinct from v_original_amount
     and v_existing.original_currency is not distinct from v_original_currency
     and v_existing.account_id is null and v_existing.funding_account_id is null
     and v_existing.card_instrument_id is not distinct from p_card_instrument_id and v_existing.charge_date is not distinct from p_charge_date
     and v_existing.suggested_fixed_month is not distinct from p_suggested_fixed_month and v_existing.target_fixed_month is not distinct from p_target_fixed_month
     and v_existing.payload_snapshot is not distinct from v_payload then
    return jsonb_build_object('ok',true,'inserted',false,'request_id',v_existing.id,'status',v_existing.status,'payment_route',v_existing.payment_route,'created_transaction_id',v_existing.created_transaction_id,'message','fixed request already exists');
  end if;
  return jsonb_build_object('ok',false,'code','HOME_FIXED_REQUEST_IDENTITY_PAYLOAD_CONFLICT','message','fixed request identity already exists with different payload','request_id',v_existing.id);
end;
$function$;

-- ---------------------------------------------------------------------------
-- 7. projection 表两条跨币种约束（docs/lessons.md D1）
--
-- 基线：
--   amount_check        original_amount > 0 and settlement_amount > 0
--                       and original_amount = settlement_amount
--   same_currency_check original_currency = settlement_currency
--
-- 放开「相等」，但把「同币种时金额必须相等」改成条件式保留——直接删两条最省事，
-- 那样西武卡也能写出 original ≠ settlement 的行，而那种行没有业务含义。
--
-- **amount_status_check 有意不动**，仍锁 settlement_amount_status = 'confirmed'。
-- 这是方案乙的边界：业务口径已定为「等工行 28 日出账单、金额确定后再提交」，
-- 结算额落库即确定，因此不需要 'pending'，也就不需要开发修正通道
-- （Phase D 已论证那是约 2000 行 SQL + Edge 协调器的量级，且批准后不可逆）。
--
-- 新约束改名是有意的：新旧语义不同，沿用旧名会让 pg_get_constraintdef 的读者
-- 以为它没变过。
-- ---------------------------------------------------------------------------

alter table public.home_external_fixed_payment_projections
  drop constraint if exists home_external_fixed_projections_amount_check;

alter table public.home_external_fixed_payment_projections
  add constraint home_external_fixed_projections_amount_check
  check (original_amount > 0 and settlement_amount > 0);

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

-- ---------------------------------------------------------------------------
-- 8. projection 校验触发器
--
-- 与基线的差异只有一处：新增原币同源检查，按 request_type 分岔。
--
-- 基线已经核对 request.amount/currency = projection.settlement_*，但完全没核对
-- original_*。表级约束放开跨币种之后，request 与 projection 的原币事实就可以分叉，
-- 必须在这里堵住。
--
-- 分岔的理由是两类请求的原币权威位置不同（审核已实证）：
--   expense_paid               request.original_*（本文件新加的两列）
--   expense_fixed_correction_p request.amount/currency —— 该类型的两列恒为 NULL，
--                              projection 的原币由 correction_p_core 写成被修正的
--                              原始 Home JPY 流水金额，与 request.amount 同源
--
-- 顺带记录一个已核实的事实：本触发器**本来就是币种无关的**——第 64、73、89 行
-- 比的都是 new.settlement_currency 而不是字面量 JPY。所以它不需要去 JPY 化，
-- 只缺这一条。
--
-- 其余逐字未改。
-- ---------------------------------------------------------------------------

create or replace function public.home_validate_external_fixed_projection()
returns trigger
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_account public.home_accounts%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_schedule record;
  v_superseded public.home_external_fixed_payment_projections%rowtype;
  v_correction public.home_external_transaction_corrections%rowtype;
  v_is_correction boolean;
begin
  select * into v_request from public.home_external_transaction_requests
  where id=new.external_request_id;
  v_is_correction := found and v_request.correction_id is not null;

  if not found
     or v_request.user_id is distinct from new.user_id
     or v_request.payment_route is distinct from 'fixed_credit_card'
     or v_request.status not in ('pending','approved')
     or v_request.external_source is distinct from new.external_source
     or v_request.external_reference_type is distinct from new.external_reference_type
     or v_request.external_reference_id is distinct from new.external_reference_id
     or v_request.external_event_id is distinct from new.external_event_id
     or v_request.idempotency_key is distinct from new.external_idempotency_key
     or v_request.card_instrument_id is distinct from new.card_instrument_id
     or v_request.account_id is not null or v_request.funding_account_id is not null
     or v_request.charge_date is distinct from new.charge_date
     or v_request.suggested_fixed_month is distinct from new.suggested_fixed_month
     or v_request.target_fixed_month is distinct from new.target_fixed_month
     or v_request.amount is distinct from new.settlement_amount
     or v_request.currency is distinct from new.settlement_currency then
    raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_REQUEST_MISMATCH';
  end if;

  if v_is_correction then
    select * into v_correction from public.home_external_transaction_corrections
    where id=v_request.correction_id;
    if not found
       or v_request.request_type <> 'expense_fixed_correction_p'
       or v_correction.school_expense_id is distinct from new.school_expense_id
       or v_correction.status not in ('preparing','prepared','completed') then
      raise exception using errcode='23514', message='CORRECTION_P_PROJECTION_MISMATCH';
    end if;
  end if;

  -- 新增：原币同源
  if v_is_correction then
    if new.original_amount is distinct from v_request.amount
       or new.original_currency is distinct from v_request.currency then
      raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_ORIGINAL_MISMATCH';
    end if;
  else
    if v_request.original_amount is null
       or v_request.original_currency is null
       or new.original_amount is distinct from v_request.original_amount
       or new.original_currency is distinct from v_request.original_currency then
      raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_ORIGINAL_MISMATCH';
    end if;
  end if;

  select * into v_card from public.home_card_instruments where id=new.card_instrument_id;
  if not found
     or v_card.user_id is distinct from new.user_id
     or v_card.settlement_currency is distinct from new.settlement_currency
     or v_card.funding_payment_channel_id is distinct from new.funding_payment_channel_id
     or v_card.is_active is not true
     or (v_card.is_school_fixed_route_enabled is not true and not v_is_correction) then
    raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_CARD';
  end if;

  select * into v_channel from public.home_payment_channels where id=new.funding_payment_channel_id;
  if not found or v_channel.user_id is distinct from new.user_id
     or v_channel.currency is distinct from new.settlement_currency
     or v_channel.is_active is not true then
    raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_CHANNEL';
  end if;

  if new.funding_account_id is not null then
    select * into v_account from public.home_accounts where id=new.funding_account_id;
    if not found or v_account.user_id is distinct from new.user_id
       or v_account.currency is distinct from new.settlement_currency
       or v_account.is_active is not true or v_account.allow_school_requests is not true then
      raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_ACCOUNT';
    end if;
  end if;

  select * into v_item from public.home_fixed_month_items where id=new.fixed_month_item_id;
  if not found or v_item.user_id is distinct from new.user_id
     or v_item.currency is distinct from new.settlement_currency
     or v_item.month_key is distinct from to_char(new.target_fixed_month,'YYYY-MM')
     or v_item.direction is distinct from 'expense'
     or v_item.accounting_scope is distinct from 'school'
     or v_item.amount is distinct from new.settlement_amount
     or v_item.payment_group is distinct from v_channel.name then
    raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_FIXED_ITEM';
  end if;

  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(new.card_instrument_id,new.charge_date);
  if new.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or new.funding_date is distinct from v_schedule.funding_date then
    raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_SCHEDULE';
  end if;

  if new.fixed_month_override_actor is not null
     and new.fixed_month_override_actor is distinct from new.user_id then
    raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_OVERRIDE_ACTOR';
  end if;
  if new.supersedes_projection_id is not null then
    if new.supersedes_projection_id=new.id then
      raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_CANNOT_SUPERSEDE_SELF';
    end if;
    select * into v_superseded from public.home_external_fixed_payment_projections
    where id=new.supersedes_projection_id;
    if not found or v_superseded.projection_status is distinct from 'corrected'
       or v_superseded.user_id is distinct from new.user_id
       or v_superseded.card_instrument_id is distinct from new.card_instrument_id
       or v_superseded.school_expense_id is distinct from new.school_expense_id then
      raise exception using errcode='23514', message='EXTERNAL_FIXED_PROJECTION_INVALID_SUPERSEDED_PROJECTION';
    end if;
  end if;
  return new;
end;
$function$;

-- ---------------------------------------------------------------------------
-- 9. 批准证据构造器（首版 P1-2）
--
-- 首版把它列为「未验证假设」，审核实证为**确定不兼容 CNY**：它硬性要求
-- projection 原币额/币种 = request.amount/currency、固定项币种 JPY、
-- 卡结算币种 JPY、渠道币种 JPY。所以首版即使成功写入 CNY 固定项与跨币种
-- projection，也会在这里抛错、**整笔批准事务回滚**；已批准请求的幂等分支同样
-- 调它，同样失败。
--
-- 返回的 JSON 本身已经含 original / settlement 两组字段，所以要改的是校验逻辑，
-- 不是返回结构——返回段逐字未动。
--
-- 与基线的差异共 5 处：
--   ① 请求检查新增 request_type <> 'expense_paid' 则拒
--   ② 原币比对改为 request.original_*（原来是 request.amount/currency）
--   ③ 固定项币种：'JPY' → projection.settlement_currency
--   ④ 卡结算币种：'JPY' → request.currency
--   ⑤ 渠道币种：'JPY' → card.settlement_currency
--
-- ① 是把「本函数只服务常规 fixed 批准」这条已实证的事实写成失败关闭的守卫。
-- 审核确认 Correction-P 走 home_prepare_external_transaction_correction_p_core
-- 自建全套并自行置 approved，不经过本函数；有了 ①，即使将来有人把它接过来，
-- 也会明确报错而不是拿 NULL 原币去比对。
-- ---------------------------------------------------------------------------

create or replace function public.home_build_external_fixed_approval_evidence(p_request_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_projection public.home_external_fixed_payment_projections%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_schedule record;
  v_business_month date;
begin
  select * into v_request
  from public.home_external_transaction_requests r
  where r.id = p_request_id;

  if not found or v_request.status <> 'approved'
     or v_request.payment_route <> 'fixed_credit_card'
     or v_request.request_type <> 'expense_paid'
     or v_request.fixed_projection_id is null
     or v_request.projection_status <> 'projected'
     or v_request.created_transaction_id is not null
     or v_request.account_id is not null
     or v_request.funding_account_id is not null
     or v_request.approved_at is null then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_REQUEST_INVALID';
  end if;

  select * into v_projection
  from public.home_external_fixed_payment_projections p
  where p.id = v_request.fixed_projection_id
    and p.external_request_id = v_request.id;

  if not found
     or v_projection.user_id is distinct from v_request.user_id
     or v_projection.external_source is distinct from v_request.external_source
     or v_projection.external_reference_type is distinct from v_request.external_reference_type
     or v_projection.external_reference_id is distinct from v_request.external_reference_id
     or v_projection.external_event_id is distinct from v_request.external_event_id
     or v_projection.external_idempotency_key is distinct from v_request.idempotency_key
     or v_projection.school_expense_id is distinct from v_request.external_reference_id
     or v_projection.payment_route <> 'fixed_credit_card'
     or v_projection.card_instrument_id is distinct from v_request.card_instrument_id
     or v_projection.charge_date is distinct from v_request.charge_date
     or v_projection.suggested_fixed_month is distinct from v_request.suggested_fixed_month
     or v_projection.target_fixed_month is distinct from v_request.target_fixed_month
     or v_projection.original_amount is distinct from v_request.original_amount
     or v_projection.original_currency is distinct from v_request.original_currency
     or v_projection.settlement_amount is distinct from v_request.amount
     or v_projection.settlement_currency is distinct from v_request.currency
     or v_projection.settlement_amount_status <> 'confirmed'
     or v_projection.projection_status <> 'projected'
     or v_projection.funding_status <> 'unfunded'
     or v_projection.funding_account_id is not null
     or v_projection.funding_transaction_id is not null
     or v_projection.funded_at is not null
     or v_projection.fixed_month_override_reason is not null
     or v_projection.fixed_month_override_actor is not null
     or v_projection.fixed_month_overridden_at is not null
     or v_projection.supersedes_projection_id is not null
     or v_projection.version <> 1 then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_PROJECTION_INVALID';
  end if;

  select * into v_item
  from public.home_fixed_month_items i
  where i.id = v_projection.fixed_month_item_id;

  if not found
     or v_item.user_id is distinct from v_request.user_id
     or v_item.template_id is not null
     or v_item.accounting_scope <> 'school'
     or v_item.currency is distinct from v_projection.settlement_currency
     or v_item.direction <> 'expense'
     or v_item.amount is distinct from v_request.amount
     or v_item.month_key is distinct from to_char(v_request.target_fixed_month, 'YYYY-MM')
     or v_item.due_date is distinct from v_projection.funding_date
     or v_item.status <> 'unpaid'
     or v_item.account_id is not null
     or v_item.linked_jpy_transaction_id is not null
     or v_item.linked_cny_transaction_id is not null
     or nullif(btrim(v_item.name), '') is null then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_ITEM_INVALID';
  end if;

  select * into v_card
  from public.home_card_instruments c
  where c.id = v_request.card_instrument_id;
  select * into v_channel
  from public.home_payment_channels c
  where c.id = v_projection.funding_payment_channel_id;
  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_request.card_instrument_id, v_request.charge_date);

  if v_card.id is null
     or v_card.user_id is distinct from v_request.user_id
     or v_card.settlement_currency is distinct from v_request.currency
     or v_channel.id is null
     or v_channel.user_id is distinct from v_request.user_id
     or v_channel.currency is distinct from v_card.settlement_currency
     or v_projection.funding_payment_channel_id is distinct from v_card.funding_payment_channel_id
     or v_item.payment_group is distinct from v_channel.name
     or v_request.suggested_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_request.target_fixed_month is distinct from v_schedule.suggested_fixed_month
     or v_projection.funding_date is distinct from v_schedule.funding_date then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_CARD_OR_SCHEDULE_INVALID';
  end if;

  begin
    if coalesce(v_request.payload_snapshot ->> 'year_month', '') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception using errcode = '22007', message = 'invalid year_month';
    end if;
    v_business_month := to_date(v_request.payload_snapshot ->> 'year_month' || '-01', 'YYYY-MM-DD');
  exception when others then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_BUSINESS_MONTH_INVALID';
  end;
  if v_projection.business_month is distinct from v_business_month then
    raise exception using errcode = '55000', message = 'HOME_FIXED_APPROVAL_EVIDENCE_BUSINESS_MONTH_MISMATCH';
  end if;

  return jsonb_build_object(
    'ok', true,
    'request_id', v_request.id,
    'user_id', v_request.user_id,
    'request_status', v_request.status,
    'payment_route', v_request.payment_route,
    'external_source', v_request.external_source,
    'external_event_id', v_request.external_event_id,
    'external_reference_type', v_request.external_reference_type,
    'external_reference_id', v_request.external_reference_id,
    'request_type', v_request.request_type,
    'transaction_type', v_request.transaction_type,
    'idempotency_key', v_request.idempotency_key,
    'request_payload_fingerprint', v_request.payload_snapshot ->> 'school_attempt_payload_fingerprint',
    'card_instrument_id', v_request.card_instrument_id,
    'charge_date', v_request.charge_date,
    'suggested_fixed_month', v_request.suggested_fixed_month,
    'target_fixed_month', v_request.target_fixed_month,
    'funding_date', v_projection.funding_date,
    'business_month', v_projection.business_month,
    'original_amount', v_projection.original_amount,
    'original_currency', v_projection.original_currency,
    'settlement_amount', v_projection.settlement_amount,
    'settlement_currency', v_projection.settlement_currency,
    'created_transaction_id', v_request.created_transaction_id,
    'fixed_projection_id', v_projection.id,
    'projection_status', v_projection.projection_status,
    'projection_version', v_projection.version,
    'funding_payment_channel_id', v_projection.funding_payment_channel_id,
    'funding_account_id', v_projection.funding_account_id,
    'funding_status', v_projection.funding_status,
    'funding_transaction_id', v_projection.funding_transaction_id,
    'fixed_item_id', v_item.id,
    'fixed_item_template_id', v_item.template_id,
    'fixed_item_scope', v_item.accounting_scope,
    'fixed_item_currency', v_item.currency,
    'fixed_item_direction', v_item.direction,
    'fixed_item_name', v_item.name,
    'fixed_item_amount', v_item.amount,
    'fixed_item_month_key', v_item.month_key,
    'fixed_item_due_date', v_item.due_date,
    'fixed_item_payment_group', v_item.payment_group,
    'fixed_item_status', v_item.status,
    'fixed_item_account_id', v_item.account_id,
    'fixed_item_linked_jpy_transaction_id', v_item.linked_jpy_transaction_id,
    'fixed_item_linked_cny_transaction_id', v_item.linked_cny_transaction_id,
    'approved_by', v_request.user_id,
    'approved_at', v_request.approved_at
  );
end;
$function$;

-- ---------------------------------------------------------------------------
-- 10. 批准核心
--
-- 与基线的差异恰好 4 处（注释另计）：
--   ① 契约检查：删 `v_request.currency <> 'JPY'`，加原币四项校验
--   ② 渠道检查：`v_channel.currency <> 'JPY'` → 等于卡的 settlement_currency
--   ③ 固定项 insert：币种由写死的 'JPY' 改为 v_request.currency
--   ④ projection insert：original 两列取 v_request.original_*，不再与 settlement 同源
--
-- 删掉 ① 里那行 JPY 字面量是安全的：本函数在此之前已有
-- `v_card.settlement_currency is distinct from v_request.currency` → CARD_INVALID，
-- 西武卡 settlement_currency='JPY'，所以判定结果逐字相同，只是非 JPY 请求的
-- 错误码从 CONTRACT_INVALID 变成 CARD_INVALID。加上表级 currency_check 只允许
-- JPY/CNY，取值范围本来就封闭。
--
-- ② 改成跟卡的 settlement_currency 走而不是跟 request 走，是因为渠道属于卡的
-- 配置、与单次请求无关。这与 home_validate_card_instrument 写卡时的既有规则
-- 一致（v_channel.currency is distinct from new.settlement_currency 则拒），
-- 也与 home_validate_external_fixed_projection 第 73 行一致。
--
-- ③ 固定项是「这个月要还的那笔钱」，所以币种必须是结算币种：
-- 工行卡 CNY（支付宝还），西武卡 JPY（存进邮局卡）。
-- home_fixed_month_items_currency_check 本来就允许 CNY，无需改约束。
--
-- **对西武卡四处全部退化为恒等变换**（settlement_currency='JPY'、
-- original ≡ settlement），这是可证伪的，见部署后验证第三节。
--
-- 其余逐字未改：锁顺序、幂等分支、九项前置拒绝、schedule 一致性比对、
-- advance 冲突检查、身份冲突检查、business_month 解析、证据构造、异常处理。
-- ---------------------------------------------------------------------------

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

  -- 预付/垫付冲突按**结算币种**匹配：工行卡查 CNY，西武卡查 JPY。逐字未改。
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

  -- 币种守卫。删掉契约检查里的 JPY 字面量后，这里是币种唯一的把关点。
  if v_card.user_id is distinct from v_request.user_id
     or v_card.settlement_currency is distinct from v_request.currency
     or v_card.is_active is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_APPROVAL_CARD_INVALID', 'message', 'fixed card is inactive, wrong owner, or wrong currency');
  end if;
  if v_card.is_school_fixed_route_enabled is not true then
    return jsonb_build_object('ok', false, 'code', 'HOME_FIXED_CARD_ROUTE_DISABLED', 'message', 'School fixed credit-card route is disabled');
  end if;

  -- ① 契约检查
  --    加的原币四项与表级 CHECK、route 触发器重复，是有意的：批准是不可逆写入，
  --    这道关失败关闭比依赖上游更稳。
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

  -- ② 渠道币种跟卡的结算币种走：西武卡 → 邮局卡（JPY），工行卡 → 支付宝（CNY）
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

  -- ③ 固定项币种 = 结算币种
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

  -- ④ projection 两组金额不再同源
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
-- 零、基线断言本身要能证伪（E3）
--   第 0 步那组断言如果任何情况下都通过，等于没写。在 rollback-only 事务里
--   逐条构造漂移并确认它们**会失败**：
--     a. 随便 create or replace 其中一个函数（加一行注释即可改变 prosrc）
--        → 期望 ABORT: … 的生产定义已漂移
--     b. 先 add column original_amount 再跑本文件 → 期望 ABORT: … 可能是半部署状态
--     c. 改掉 projection amount_check 的定义 → 期望 ABORT: projection amount_check 已漂移
--     d. 改掉 route_fields_check → 期望 ABORT: route_fields_check 已漂移
--   全部基于 canonical（非 pretty）形式，见第 0 步的注释。
--
-- 一、逐行 diff（E2）—— 先做这项，diff 不符就别往下验
--   与 ~/aozora-security-20260827/cash-baseline/ 下 2026-09-03 的五份导出逐行比，
--   期望的功能改动数（注释与换行重排另计）：
--
--     home_validate_external_request_payment_route     2 处（冻结集 + 快照绑定块）
--     home_create_external_fixed_transaction_request   4 处（变量 / 解析 / 两处幂等 / payload 检查 / INSERT，
--                                                          其中幂等两处算一类）
--     home_validate_external_fixed_projection          1 处（原币同源块）
--     home_build_external_fixed_approval_evidence      5 处
--     home_apply_external_fixed_transaction_approval   4 处
--
--   **出现计划外的差异 = 我的转录错误，立即回滚。**
--   注：创建器我做了换行重排（原生产定义是压缩单行风格），diff 会很吵，
--   建议用「语义 diff」或先统一格式化再比。这是本文件最容易藏错的地方。
--
-- 二、结构与权限
--   1. 两列存在、可空、无 default；三分支 CHECK 存在且定义与本文件逐字一致
--   2. **home_external_requests_route_fields_check 与
--      home_external_transaction_requests_correction_link_check 的
--      pg_get_constraintdef 与部署前逐字相同** —— 本文件没碰它们
--   3. projection：amount_check 为两个 > 0；same_currency_amount_check 为条件式；
--      **same_currency_check 旧名已不存在**；
--      **amount_status_check 仍为 settlement_amount_status = 'confirmed'**
--      ← 方案乙的边界，必须证明没被顺手放开
--   4. projection 其余 10 条 CHECK、全部 FK/PK/索引与部署前逐字相同
--   5. 五个函数的 owner / prosecdef / proconfig / **proacl** 与部署前逐字相同。
--      特别注意创建器的 proacl 应仍为
--      {postgres=X/postgres,service_role=X/postgres}，其余四个为 {postgres=X/postgres}
--      （create or replace 不应用 default privileges，但 docs/lessons.md A3
--       要求实测而非假定）
--   6. 两张表的 relacl、RLS、policy、触发器绑定（tgname/tgtype/tgenabled）未变
--
-- 三、回填正确且范围受限
--   1. fixed + expense_paid 的行：original_* 非空，且等于其快照里的对应键
--   2. **fixed + expense_fixed_correction_p 的行：original_* 仍为 NULL**
--      （即 8f2a9aff… 那条 approved 的 Correction-P 一字未动）
--   3. **immediate 路线 52 条：original_* 全为 NULL**
--   4. 除这两列外，本表其余列逐行与部署前相同
--
-- 四、西武卡逐字不变（比工行卡能不能跑通更重要）
--   rollback-only 事务里用同币种 JPY fixture 走完整链路：
--     1. 创建器：入参与今天完全相同（18 参数、不传原币），应当成功创建，
--        且 original_* 被写成与 amount/currency 相同的值
--     2. 批准：固定项 currency='JPY'、amount/month_key/due_date/payment_group/
--        accounting_scope 全部与基线行为相同
--     3. projection：original 与 settlement 两组值相等
--     4. evidence 返回结构与基线相同
--   **任何一项不同都说明向后兼容被破坏。**
--
-- 五、该失败的仍然失败（E4，rollback-only，错误码必须精确匹配）
--   新增守卫：
--     a. 快照缺 original_amount                → HOME_FIXED_REQUEST_ORIGINAL_AMOUNT_INVALID
--     a2. 快照 original_amount 为非数字文本     → 同上（**不得泄漏裸 22P02**）
--     b. 快照 original_currency='USD'          → 同上
--     c. 快照 settlement_amount ≠ 入参 p_amount → HOME_FIXED_REQUEST_PAYLOAD_MISMATCH
--     c2. 快照 settlement_amount 为非数字文本   → 同上（审核 P2-2 的修复，
--         **必须验**：修复前这里会在 INSERT 之前抛裸 22P02，
--         而那时还到不了 route 触发器的受控异常映射）
--     d. 创建后 service_role 改 original_amount → 42501 FIXED_CARD_REQUEST_EVIDENCE_IMMUTABLE
--        ← **这条是首版 P1-3 的直接修复，必须验**
--     e. projection 的 original 与 request 不符 → EXTERNAL_FIXED_PROJECTION_ORIGINAL_MISMATCH
--     f. 批准时 request.original_amount 为 NULL → HOME_FIXED_APPROVAL_REQUEST_CONTRACT_INVALID
--     g. 同币种但 original ≠ settlement         → 23514（表级）与 CONTRACT_INVALID（函数级）
--     h. evidence 对 request_type ≠ expense_paid → HOME_FIXED_APPROVAL_EVIDENCE_REQUEST_INVALID
--   未改动的守卫（必须全部照旧）：
--     i. 卡币种不符 → CARD_INVALID     j. 卡 route 未开 → ROUTE_DISABLED
--     k. schedule 不符 → SCHEDULE_MISMATCH   l. 重复批准 → 幂等返回不重复写
--     m. rejected 请求批准 → ALREADY_REJECTED
--
-- 六、Correction-P 不受影响
--   1. home_prepare_external_transaction_correction_p_core **本轮未修改**
--   2. 其产生的 request（original_* 为 NULL、request_type='expense_fixed_correction_p'）
--      满足新 CHECK 的第二分支
--   3. 其产生的 projection 满足新的原币同源检查的 correction 分支
--      （core 写 projection.original_amount = v_transaction.amount，
--        request.amount 亦为 v_transaction.amount，两者同源）
--   4. rollback-only 跑一次完整 Correction-P，行为与部署前一致
--
-- 七、immediate 路线不受影响
--   home_create_external_transaction_request 未修改，其创建的请求 original_* 为
--   NULL，满足新 CHECK 第一分支。rollback-only 跑一次 immediate 创建 + 批准。
--
-- 八、工行卡形态可跑通（rollback-only fixture，最后做）
--   造 CNY 渠道 + CNY 家庭固定模板 + CNY 卡（cutoff 28 inclusive、funding 15、
--   offset 1），快照 original JPY 166100 / settlement CNY 8000，charge 2026-09-15：
--     1. 固定项 currency='CNY'、amount=8000、month_key='2026-10'、
--        due_date=2026-10-15、payment_group='支付宝'
--     2. projection original JPY 166100 / settlement CNY 8000、
--        settlement_amount_status='confirmed'、funding_status='unfunded'
--     3. evidence 正常返回，original/settlement 两组字段各自正确
--
-- ===========================================================================
-- 假设与其结论
-- ===========================================================================
--
-- 首版列的第 1～4 条已由 2026-09-03 第二轮审核逐条实证，**不再是假设**：
--
--   1. **correction guard 不会挡回填。** 实际触发器函数是
--      home_guard_correction_replacement_request()（md5
--      c6b8a615dad439fc7f8f036dd60724eb），只在 old.correction_id is not null
--      时执行不可变检查。3b926e75 是 rejected 的非 Correction-P 行，不会被拦，
--      **无需 disable 任何触发器**。
--   2. **回填经旧 route trigger 可通过。** 对 3b926e75 逐项只读预演全部成立：
--      卡存在 / owner / 币种 / active / route enabled、schedule
--      2026-10-01 与 2026-10-25、payload 的 funding/card/charge/suggested/target
--      五键一致、fingerprint 为 64 位 hex。
--   3. **创建器语义 diff 通过。** 除声明的四类变化外无隐藏改动，
--      参数名/顺序/类型/默认值/返回类型/安全属性均未变。
--   4. **异常交互通过。** 内层块把 cast 异常转成 23514，外层只捕 22P02
--      （invalid_text_representation），不会被错误改写成 Correction-P 错误码。
--
-- 以下三条仍然是未验证的假设，编号沿用首版：
--
-- 5. **Cash 前端对 CNY projection 固定项的渲染与筛选。**
--    docs/lessons.md D2 已记：CNY 前端仍调通用的
--    home_update_cny_fixed_item_status，而它对 projection 项明确拒绝。
--    所以**将来的 CNY projection 项从现有 CNY 页面点「已付」会被拒**，
--    需要补前端分岔。本轮不涉及，但工行卡真正投用前必须解决。
--
-- 6. **Phase 3E 账单确认链路的 JPY 硬编码**
--    （supabase-concurrency-20260819-phase3e-card-statement.zsh:57）。
--    工行卡要不要接这条链路，口径未定。本文件改的批准核心只读
--    v_cycle.amount_status，不受影响；但建工行卡记录需要一条 CNY 家庭固定模板，
--    而那条模板正是这条链路的锚点。
--
-- 7. **工行卡、支付宝渠道、CNY 家庭固定模板在生产中都不存在。**
--    home_validate_card_instrument 要求模板 currency = 卡的 settlement_currency、
--    direction='expense'、accounting_scope='household'、
--    payment_group = 渠道名、is_active。第八节的 fixture 需要现造。
--
-- ===========================================================================
