-- 信用卡还款月偏移 —— 支持账单月与还款月不在同一个月的卡
--
-- 日期：2026-09-03
-- 基线：home_calculate_card_fixed_schedule 取自 2026-09-01 生产导出
--       归档于 ~/aozora-security-20260827/cash-baseline/
--
-- ===========================================================================
-- 为什么需要
-- ===========================================================================
--
-- 现有推导假设「还款发生在账单月当月」：
--
--   suggested_fixed_month := v_month          -- 账单月
--   funding_date          := 账单月的 funding_day
--
-- 西武卡成立：9/15 刷卡 → 10 月账单 → 10/25 扣款，账单月与还款月同为 10 月。
--
-- 工行卡不成立：28 日出账单、次月 15 日还款。9/15 刷卡 → 9 月账单 → **10/15**
-- 还款。按现有逻辑会算成 9 月账单、9/15 扣款——整整差一个月。
--
-- 用户 2026-09-03 确认：两张卡长期混用，每月 15 号按手上的人民币/日元余额决定
-- 刷哪张。因此这不是一次性适配，是常态。
--
-- ===========================================================================
-- 为什么 offset 必须同时作用于两个输出
-- ===========================================================================
--
-- month_key 的语义是**还款月**，不是消费月，也不是账单月
-- （见 docs/lessons.md D3）。
--
-- 西武卡的账单月恰好等于还款月，所以 `suggested_fixed_month := v_month` 一直
-- 是对的——但那是巧合，不是规则。工行卡一旦接入，账单月与还款月分离，若只把
-- offset 加在 funding_date 上，固定项会落在账单月而非还款月，与 month_key 的
-- 定义冲突，并让「本月人民币固定支出」列表显示错月份。
--
-- 因此改为先算还款月，再由还款月同时决定 suggested_fixed_month 与 funding_date。
--
-- ===========================================================================
-- 向后兼容
-- ===========================================================================
--
-- 新列默认 0。西武卡 offset=0 时 v_funding_month 恒等于 v_statement_month，
-- 两个输出与改动前逐字节相同。已通过的生产验证仍然成立：
--
--   09-02 → 2026-09 / 09-25      09-10 → 2026-09 / 09-25      09-11 → 2026-10 / 10-25
--
-- ===========================================================================
-- 配置字段冻结必须同轮完成
-- ===========================================================================
--
-- home_validate_card_instrument 在卡被 home_external_transaction_requests、
-- home_card_statement_cycles 或 home_external_fixed_payment_projections 引用之后，
-- 冻结它的配置字段——settlement_currency、cutoff_day、cutoff_inclusive、
-- funding_day、funding_payment_channel_id、household_statement_template_id。
--
-- funding_month_offset 属于同类：它和 cutoff_day / funding_day 共同决定固定项落在
-- 哪个月、哪天扣款。若不冻结，改动它会让已生成固定项的月份归属与重新计算的结果
-- 漂移，而那些固定项已经进了账、可能已经还过款。
--
-- 本文件初稿把冻结留作「独立后续」，被审核以硬阻断驳回，理由是：文件自己声明
-- 该列「设定后不应更改」，却不给它任何强制手段，等于承认了一个能改历史月份归属
-- 的口子。这个判断是对的——西武卡此刻已被那条 pending 请求引用，其余日期字段
-- 已经锁住，唯独新加的这个敞开着。
--
-- 因此本轮把加列、冻结、推导三者放在同一个事务里原子完成。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   **顺序不能反**：触发器函数引用了 funding_month_offset，必须先把它恢复成不
--   引用该列的版本，才能删列。反过来会因依赖而失败，或留下引用不存在列的函数。
--
--   1. 恢复 home_validate_card_instrument 至部署前定义
--      （本次基于 supabase-update-20260819-phase3c3b-fixed-entry.sql 第 136–209 行
--        的版本；部署前须已确认它与生产逐字一致）
--   2. 恢复 home_calculate_card_fixed_schedule
--      （~/aozora-security-20260827/cash-baseline/ 下 2026-09-01 的生产导出）
--   3. 删约束与列：
--        alter table public.home_card_instruments
--          drop constraint if exists home_card_instruments_funding_month_offset_chk;
--        alter table public.home_card_instruments
--          drop column if exists funding_month_offset;
--
--   回滚前须确认没有 offset 非 0 的卡在用——若工行卡已建立并产生过固定项，
--   删列会使那些固定项的月份归属失去依据，此时应先处理数据再回滚。
--
-- ===========================================================================

\set ON_ERROR_STOP on

begin;

-- ---------------------------------------------------------------------------
-- 1. 加列
--
-- 限定 0 或 1：现实中没有「账单出来两个月后才还款」的信用卡，放开范围只会让
-- 错误配置有机会写进去。若将来真有此类卡，改约束比修数据容易。
-- ---------------------------------------------------------------------------

alter table public.home_card_instruments
  add column if not exists funding_month_offset integer not null default 0;

alter table public.home_card_instruments
  drop constraint if exists home_card_instruments_funding_month_offset_chk;

alter table public.home_card_instruments
  add constraint home_card_instruments_funding_month_offset_chk
  check (funding_month_offset in (0, 1));

comment on column public.home_card_instruments.funding_month_offset is
  'Months from statement month to funding month. 0 = same month (西武卡), 1 = next month (工行卡).';

-- ---------------------------------------------------------------------------
-- 2. 把新列纳入引用后的配置冻结
--
-- 与基线的差异仅两行：两个 row() 各增加一个 funding_month_offset。冻结的触发
-- 条件、错误码、其余校验逻辑逐字未变。
--
-- 必须在加列之后执行：函数体引用该列，列不存在时创建会失败。
-- ---------------------------------------------------------------------------

create or replace function public.home_validate_card_instrument()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
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

-- ---------------------------------------------------------------------------
-- 3. 改推导
--
-- 与基线的差异：变量 v_month 更名为 v_statement_month（原名掩盖了它是账单月而
-- 非还款月这一事实），新增 v_funding_month，两个输出改由后者决定。
-- cutoff 判定逻辑逐字未变。
-- ---------------------------------------------------------------------------

create or replace function public.home_calculate_card_fixed_schedule(
  p_card_instrument_id uuid,
  p_charge_date date
)
returns table(suggested_fixed_month date, funding_date date)
language plpgsql
stable
set search_path to 'pg_catalog', 'public'
as $function$
declare
  v_card public.home_card_instruments%rowtype;
  v_statement_month date;
  v_funding_month date;
  v_last_day integer;
begin
  if p_card_instrument_id is null or p_charge_date is null then
    raise exception using errcode = '22004', message = 'CARD_SCHEDULE_INPUT_REQUIRED';
  end if;

  select * into v_card
  from public.home_card_instruments
  where id = p_card_instrument_id;

  if not found then
    raise exception using errcode = 'P0002', message = 'CARD_INSTRUMENT_NOT_FOUND';
  end if;

  -- 账单月：刷卡日落在 cutoff 之前（含或不含由 cutoff_inclusive 决定）则计入当月
  -- 账单，否则进入下一期。此段与基线逐字相同。
  if (v_card.cutoff_inclusive and extract(day from p_charge_date)::integer <= v_card.cutoff_day)
     or (not v_card.cutoff_inclusive and extract(day from p_charge_date)::integer < v_card.cutoff_day) then
    v_statement_month := date_trunc('month', p_charge_date)::date;
  else
    v_statement_month := (date_trunc('month', p_charge_date) + interval '1 month')::date;
  end if;

  -- 还款月 = 账单月 + offset。西武卡 offset=0（当月扣），工行卡 offset=1（次月还）。
  v_funding_month := (
    v_statement_month + make_interval(months => coalesce(v_card.funding_month_offset, 0))
  )::date;

  v_last_day := extract(day from (v_funding_month + interval '1 month - 1 day'))::integer;

  -- 两个输出都由还款月决定。month_key 是还款月，不是账单月。
  suggested_fixed_month := v_funding_month;
  funding_date := make_date(
    extract(year from v_funding_month)::integer,
    extract(month from v_funding_month)::integer,
    least(v_card.funding_day, v_last_day)
  );
  return next;
end;
$function$;

commit;

-- ===========================================================================
-- 部署后验证
-- ===========================================================================
--
-- 一、结构
--   1. funding_month_offset 存在，not null，default 0，现有行全部为 0
--   2. CHECK 约束存在且只允许 0 / 1
--   3. 两个函数的 proacl 与部署前一致
--   4. home_card_instruments 的其余列、RLS、policy 均未变；触发器
--      home_card_instruments_validate 的 tgname / tgtype / tgenabled 未变，
--      只有其函数体改变
--
-- 一之附、冻结确实生效（这一条是本轮被驳回后新增的，必须能证伪）
--   西武卡当前已被那条 pending 请求引用，因此配置字段应处于冻结状态。
--   在 rollback-only 事务中尝试：
--
--     update public.home_card_instruments
--     set funding_month_offset = 1, version = version + 1
--     where id = '9b27347e-2dce-4caf-bac0-67f053ef6c3b';
--
--   → 期望 42501 / CARD_INSTRUMENT_REFERENCED_CONFIG_IMMUTABLE
--
--   若这条 UPDATE 成功，说明冻结没生效，本轮的核心目的未达成，应立即回滚。
--
--   对照组：同一事务内改一个**未被引用**的 fixture 卡的 offset，应当成功——
--   证明冻结只在被引用后生效，而不是把这一列变成完全只读。
--
-- 二、西武卡行为完全不变（offset=0，只读验证）
--   卡 9b27347e-2dce-4caf-bac0-67f053ef6c3b，cutoff 10 inclusive、funding 25：
--
--     2026-09-02 → suggested 2026-09-01、funding 2026-09-25
--     2026-09-10 → suggested 2026-09-01、funding 2026-09-25   ← cutoff 当天
--     2026-09-11 → suggested 2026-10-01、funding 2026-10-25
--
--   这三组与 2026-09-02 用户在生产界面验证过的结果必须逐字相同。
--   **任何一组不同都说明向后兼容被破坏，应立即回滚。**
--
-- 三、offset=1 的推导正确（rollback-only fixture）
--   构造 cutoff 28 inclusive、funding 15、offset 1 的 CNY 卡：
--
--     2026-09-15 → suggested 2026-10-01、funding 2026-10-15
--     2026-09-28 → suggested 2026-10-01、funding 2026-10-15   ← cutoff 当天
--     2026-09-29 → suggested 2026-11-01、funding 2026-11-15
--
--   第二组最关键：它同时检验 cutoff_inclusive 与 offset 两个维度。
--
-- 四、月末边界（rollback-only fixture）
--   构造 funding_day = 31、offset = 1 的卡，charge_date 取 2026-01-15
--   → 账单月 2026-01，还款月 2026-02，funding_date 应为 2026-02-28（least 生效）
--   证明 v_last_day 取的是还款月的天数而不是账单月的
--
-- 五、不受影响
--   1. home_get_school_fixed_card_schedule 未改动，仍原样转发
--   2. 用户那条 School 支出记录（rejected 状态）未被触碰
--   3. Cash 现有固定项、projection、statement 均未改动
--
-- ===========================================================================
