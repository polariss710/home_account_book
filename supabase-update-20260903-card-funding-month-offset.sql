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
-- 关于配置字段冻结
-- ===========================================================================
--
-- home_card_instruments_validate 触发器会冻结卡的配置字段（cutoff_day 等）。
-- funding_month_offset 在语义上属于同类——它是卡的固有属性，设定后不应更改，
-- 改动会让历史固定项的月份归属失去依据。
--
-- 本脚本未将它纳入冻结检查，因为那要改动触发器函数本体，与本次的推导修正混在
-- 一起会让回滚变复杂。**这是一处有意留下的缺口**，建议作为独立后续处理。
--
-- ===========================================================================
-- 回滚
-- ===========================================================================
--
--   从 ~/aozora-security-20260827/cash-baseline/home_calculate_card_fixed_schedule.sql
--   原样 CREATE OR REPLACE 覆盖函数，然后：
--
--   alter table public.home_card_instruments
--     drop constraint if exists home_card_instruments_funding_month_offset_chk;
--   alter table public.home_card_instruments
--     drop column if exists funding_month_offset;
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
-- 2. 改推导
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
--   3. 函数 proacl 与部署前一致
--   4. home_card_instruments 的其余列、RLS、policy、触发器均未变
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
