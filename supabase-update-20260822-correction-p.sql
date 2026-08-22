-- School V2 x Cash Correction-P
-- Phase B local draft only. NOT DEPLOYED.
-- Production execution is explicitly out of scope for Phase B.

alter table public.home_external_transaction_requests
  add column if not exists correction_id uuid;

create table if not exists public.home_external_transaction_corrections (
  id uuid primary key default gen_random_uuid(),
  correction_type text not null,
  reason_code text not null,
  status text not null,
  version bigint not null default 1,
  source_system text not null,
  business_idempotency_key text not null unique,
  operation_id uuid not null unique,
  original_home_request_id uuid not null unique,
  original_home_transaction_id uuid not null unique,
  school_expense_id uuid not null unique,
  school_attempt_id uuid not null unique,
  balance_effect_id uuid unique,
  replacement_request_id uuid unique,
  replacement_fixed_item_id uuid unique,
  replacement_projection_id uuid unique,
  school_evidence_id uuid unique,
  amount numeric(14,2) not null,
  currency text not null,
  account_id uuid not null,
  original_effective_date date not null,
  accounting_scope text not null,
  external_event_id uuid not null,
  external_reference_type text not null,
  external_reference_id uuid not null,
  original_idempotency_key text not null,
  school_fingerprint text not null,
  home_payload_hash text not null,
  replacement_fingerprint text,
  school_evidence_fingerprint text,
  school_evidence_snapshot jsonb,
  original_request_snapshot jsonb not null,
  original_transaction_snapshot jsonb not null,
  actor_source text not null,
  actor_id uuid not null,
  prepared_at timestamptz,
  completed_at timestamptz,
  retry_count integer not null default 0,
  last_retried_at timestamptz,
  last_error_code text,
  last_error_at timestamptz,
  created_at timestamptz not null default statement_timestamp(),
  constraint home_external_transaction_corrections_type_check
    check (correction_type = 'school_expense_immediate_to_fixed'),
  constraint home_external_transaction_corrections_reason_check
    check (reason_code = 'wrong_immediate_account_route'),
  constraint home_external_transaction_corrections_status_check
    check (status in ('preparing','prepared','completed')),
  constraint home_external_transaction_corrections_version_check
    check (version > 0),
  constraint home_external_transaction_corrections_source_check
    check (source_system = 'aozora_school'),
  constraint home_external_transaction_corrections_amount_check
    check (amount > 0),
  constraint home_external_transaction_corrections_currency_check
    check (currency = 'JPY'),
  constraint home_external_transaction_corrections_scope_check
    check (accounting_scope = 'school'),
  constraint home_external_transaction_corrections_reference_check
    check (external_reference_type = 'school_expense_records'
      and external_reference_id = school_expense_id),
  constraint home_external_transaction_corrections_hash_check
    check (school_fingerprint ~ '^[0-9a-f]{64}$'
      and home_payload_hash ~ '^[0-9a-f]{32}$'
      and (replacement_fingerprint is null or replacement_fingerprint ~ '^[0-9a-f]{64}$')
      and (school_evidence_fingerprint is null or school_evidence_fingerprint ~ '^[0-9a-f]{64}$')),
  constraint home_external_transaction_corrections_prepared_bundle_check
    check (
      status = 'preparing'
      or (
        balance_effect_id is not null
        and replacement_request_id is not null
        and replacement_fixed_item_id is not null
        and replacement_projection_id is not null
        and replacement_fingerprint is not null
        and prepared_at is not null
      )
    ),
  constraint home_external_transaction_corrections_completed_bundle_check
    check (
      status <> 'completed'
      or (
        school_evidence_id is not null
        and school_evidence_fingerprint is not null
        and school_evidence_snapshot is not null
        and completed_at is not null
      )
    ),
  constraint home_external_transaction_corrections_retry_check
    check (retry_count >= 0 and ((last_error_code is null) = (last_error_at is null)))
);

comment on table public.home_external_transaction_corrections is
  'Correction-P authoritative Home saga fact. Original request/transaction remain immutable; completed is the sole reader switch.';

create table if not exists public.home_account_correction_entries (
  id uuid primary key default gen_random_uuid(),
  correction_id uuid not null unique,
  original_transaction_id uuid not null unique,
  user_id uuid not null,
  account_id uuid not null,
  direction text not null,
  amount numeric(14,2) not null,
  currency text not null,
  accounting_scope text not null,
  effective_date date not null,
  source_snapshot_hash text not null,
  created_at timestamptz not null default statement_timestamp(),
  constraint home_account_correction_entries_direction_check
    check (direction = 'credit_restore'),
  constraint home_account_correction_entries_amount_check
    check (amount > 0),
  constraint home_account_correction_entries_currency_check
    check (currency = 'JPY'),
  constraint home_account_correction_entries_scope_check
    check (accounting_scope = 'school'),
  constraint home_account_correction_entries_hash_check
    check (source_snapshot_hash ~ '^[0-9a-f]{64}$')
);

comment on table public.home_account_correction_entries is
  'Append-only balance correction effects. They are not income or ordinary JPY transactions and become effective only through a completed correction.';

create table if not exists public.home_external_correction_route_policies (
  id uuid primary key default gen_random_uuid(),
  operation_kind text not null,
  user_id uuid not null references auth.users(id) on delete restrict,
  accounting_scope text not null,
  currency text not null,
  card_instrument_id uuid not null references public.home_card_instruments(id) on delete restrict,
  payment_channel_id uuid not null references public.home_payment_channels(id) on delete restrict,
  effective_from date not null,
  effective_to date,
  is_active boolean not null default true,
  approved_by uuid not null,
  approval_reference text not null,
  created_at timestamptz not null default statement_timestamp(),
  updated_at timestamptz not null default statement_timestamp(),
  constraint home_external_correction_route_policies_kind_check
    check (operation_kind='school_expense_immediate_to_fixed'),
  constraint home_external_correction_route_policies_scope_check
    check (accounting_scope='school'),
  constraint home_external_correction_route_policies_currency_check
    check (currency='JPY'),
  constraint home_external_correction_route_policies_dates_check
    check (effective_to is null or effective_to>=effective_from),
  constraint home_external_correction_route_policies_audit_check
    check (nullif(btrim(approval_reference),'') is not null)
);

create index if not exists home_external_correction_route_policies_lookup_idx
  on public.home_external_correction_route_policies(
    operation_kind,user_id,accounting_scope,currency,effective_from,effective_to
  ) where is_active;

comment on table public.home_external_correction_route_policies is
  'Owner-configured Correction-P route authority. Schema contains no business mapping; Phase D must insert a separately approved card/payment-channel policy.';

create table if not exists public.home_correction_replacement_authorizations (
  id uuid primary key default gen_random_uuid(),
  nonce uuid not null unique default gen_random_uuid(),
  original_transaction_id uuid not null references public.home_jpy_transactions(id) on delete restrict,
  operation_id uuid not null,
  correction_id uuid not null,
  request_id uuid not null unique,
  actor_id uuid not null,
  replacement_type text not null,
  fixed_month date not null,
  card_instrument_id uuid not null references public.home_card_instruments(id) on delete restrict,
  payment_channel_id uuid not null references public.home_payment_channels(id) on delete restrict,
  created_at timestamptz not null default statement_timestamp(),
  constraint home_correction_replacement_authorizations_type_check
    check (replacement_type='expense_fixed_correction_p'),
  constraint home_correction_replacement_authorizations_month_check
    check (fixed_month=date_trunc('month',fixed_month)::date)
);

comment on table public.home_correction_replacement_authorizations is
  'Owner-only transaction-local capability created by Correction-P core and atomically consumed by the final request guard.';

-- Actor/approver identities originate from the independently authenticated
-- School project and intentionally are not foreign keys to Home auth.users.
alter table public.home_external_correction_route_policies
  drop constraint if exists home_external_correction_route_policies_approved_by_fkey;
alter table public.home_correction_replacement_authorizations
  drop constraint if exists home_correction_replacement_authorizations_actor_id_fkey;

alter table public.home_external_correction_route_policies enable row level security;
alter table public.home_correction_replacement_authorizations enable row level security;
revoke all on table public.home_external_correction_route_policies from public,anon,authenticated,service_role;
revoke all on table public.home_correction_replacement_authorizations from public,anon,authenticated,service_role;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_original_request_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_original_request_fkey
  foreign key (original_home_request_id)
  references public.home_external_transaction_requests(id) on delete restrict;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_original_transaction_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_original_transaction_fkey
  foreign key (original_home_transaction_id)
  references public.home_jpy_transactions(id) on delete restrict;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_account_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_account_fkey
  foreign key (account_id)
  references public.home_accounts(id) on delete restrict;

alter table public.home_external_transaction_requests
  drop constraint if exists home_external_transaction_requests_correction_fkey;
alter table public.home_external_transaction_requests
  add constraint home_external_transaction_requests_correction_fkey
  foreign key (correction_id)
  references public.home_external_transaction_corrections(id) on delete restrict
  deferrable initially deferred;

alter table public.home_account_correction_entries
  drop constraint if exists home_account_correction_entries_correction_fkey;
alter table public.home_account_correction_entries
  add constraint home_account_correction_entries_correction_fkey
  foreign key (correction_id)
  references public.home_external_transaction_corrections(id) on delete restrict;

alter table public.home_account_correction_entries
  drop constraint if exists home_account_correction_entries_transaction_fkey;
alter table public.home_account_correction_entries
  add constraint home_account_correction_entries_transaction_fkey
  foreign key (original_transaction_id)
  references public.home_jpy_transactions(id) on delete restrict;

alter table public.home_account_correction_entries
  drop constraint if exists home_account_correction_entries_account_fkey;
alter table public.home_account_correction_entries
  add constraint home_account_correction_entries_account_fkey
  foreign key (account_id)
  references public.home_accounts(id) on delete restrict;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_effect_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_effect_fkey
  foreign key (balance_effect_id)
  references public.home_account_correction_entries(id) on delete restrict
  deferrable initially deferred;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_replacement_request_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_replacement_request_fkey
  foreign key (replacement_request_id)
  references public.home_external_transaction_requests(id) on delete restrict
  deferrable initially deferred;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_replacement_item_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_replacement_item_fkey
  foreign key (replacement_fixed_item_id)
  references public.home_fixed_month_items(id) on delete restrict
  deferrable initially deferred;

alter table public.home_external_transaction_corrections
  drop constraint if exists home_external_transaction_corrections_replacement_projection_fkey;
alter table public.home_external_transaction_corrections
  add constraint home_external_transaction_corrections_replacement_projection_fkey
  foreign key (replacement_projection_id)
  references public.home_external_fixed_payment_projections(id) on delete restrict
  deferrable initially deferred;

alter table public.home_correction_replacement_authorizations
  drop constraint if exists home_correction_replacement_authorizations_correction_fkey;
alter table public.home_correction_replacement_authorizations
  add constraint home_correction_replacement_authorizations_correction_fkey
  foreign key (correction_id)
  references public.home_external_transaction_corrections(id) on delete restrict
  deferrable initially deferred;

create unique index if not exists home_external_requests_correction_unique
  on public.home_external_transaction_requests(correction_id)
  where correction_id is not null;

alter table public.home_external_transaction_requests
  drop constraint if exists home_external_transaction_requests_reference_check;

alter table public.home_external_transaction_requests
  add constraint home_external_transaction_requests_reference_check check (
    (external_reference_type = 'school_income_records'
      and request_type in ('tuition_income_received','income_received')
      and transaction_type = 'income')
    or (external_reference_type = 'school_expense_records'
      and request_type in ('expense_paid','expense_fixed_correction_p')
      and transaction_type = 'expense')
    or (status <> 'pending' and (
      (external_reference_type = 'school_payment_requests'
        and request_type in ('teacher_wage_payment_confirm','teacher_wage_payment_reverse'))
      or (external_reference_type = 'school_part_time_work_income_requests'
        and request_type = 'part_time_work_income_received')
    ))
  );

alter table public.home_external_transaction_requests
  drop constraint if exists home_external_transaction_requests_correction_link_check;
alter table public.home_external_transaction_requests
  add constraint home_external_transaction_requests_correction_link_check check (
    (correction_id is null and request_type <> 'expense_fixed_correction_p')
    or (correction_id is not null
      and payment_route = 'fixed_credit_card'
      and request_type = 'expense_fixed_correction_p')
  );

alter table public.home_external_transaction_corrections enable row level security;
alter table public.home_account_correction_entries enable row level security;

revoke all on table public.home_external_transaction_corrections from public, anon, authenticated, service_role;
revoke all on table public.home_account_correction_entries from public, anon, authenticated, service_role;

create or replace function public.home_guard_account_correction_entry()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op in ('UPDATE','DELETE') then
    raise exception using errcode='42501', message='HOME_ACCOUNT_CORRECTION_ENTRY_APPEND_ONLY';
  end if;
  return new;
end;
$$;

create or replace function public.home_is_fixed_item_visible_to_business_reader(p_item_id uuid)
returns boolean
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select not exists (
    select 1 from public.home_external_transaction_corrections c
    where c.replacement_fixed_item_id=p_item_id and c.status<>'completed'
  );
$$;

create or replace function public.home_get_year_summary(p_year integer) RETURNS jsonb
    LANGUAGE sql STABLE SECURITY DEFINER
    SET search_path TO 'pg_catalog', 'public'
    AS $$
with month_list as (
  select
    to_char(make_date(p_year, month_number, 1), 'YYYY-MM') as month_key,
    make_date(p_year, month_number, 1) as month_start,
    (make_date(p_year, month_number, 1) + interval '1 month')::date as next_month
  from generate_series(1, 12) as month_number
),
jpy_fixed_stats as (
  with ordinary_items as (
    select *
    from public.home_fixed_month_items
    where user_id = auth.uid()
      and currency = 'JPY'
      and linked_jpy_transaction_id is null
      and public.home_is_fixed_item_visible_to_business_reader(id)
      and month_key >= p_year::text || '-01'
      and month_key <= p_year::text || '-12'
  ),
  expense_groups as (
    select
      month_key,
      coalesce(payment_group, '未分组') as payment_group,
      public.home_round_up_1000(coalesce(sum(amount), 0)) as payment_amount
    from ordinary_items
    where direction = 'expense'
    group by month_key, coalesce(payment_group, '未分组')
  ),
  expense_stats as (
    select
      month_key,
      coalesce(sum(payment_amount), 0) as expense
    from expense_groups
    group by month_key
  ),
  income_stats as (
    select
      month_key,
      coalesce(sum(amount), 0) as income
    from ordinary_items
    where direction = 'income'
    group by month_key
  )
  select
    coalesce(i.month_key, e.month_key) as month_key,
    coalesce(i.income, 0) as income,
    coalesce(e.expense, 0) as expense,
    coalesce(i.income, 0) - coalesce(e.expense, 0) as balance
  from income_stats i
  full join expense_stats e on e.month_key = i.month_key
),
jpy_casual_stats as (
  select
    to_char(t.transacted_at, 'YYYY-MM') as month_key,
    coalesce(sum(t.amount) filter (where t.transaction_type = 'income'), 0) as income,
    coalesce(sum(t.amount) filter (where t.transaction_type = 'expense'), 0) as expense,
    coalesce(sum(t.amount) filter (where t.transaction_type = 'income'), 0)
      - coalesce(sum(t.amount) filter (where t.transaction_type = 'expense'), 0) as balance
  from public.home_jpy_transactions t
  where t.user_id = auth.uid()
    and t.currency = 'JPY'
    and t.transaction_type in ('income', 'expense')
    and not exists (
      select 1 from public.home_external_transaction_corrections c
      where c.original_home_transaction_id=t.id and c.status='completed'
    )
    and t.transacted_at >= make_date(p_year, 1, 1)
    and t.transacted_at < make_date(p_year + 1, 1, 1)
  group by to_char(t.transacted_at, 'YYYY-MM')
),
cny_fixed_stats as (
  select
    i.month_key,
    coalesce(sum(i.amount) filter (where i.direction = 'income'), 0) as income,
    coalesce(sum(i.amount) filter (where i.direction = 'expense'), 0) as expense,
    coalesce(sum(i.amount) filter (where i.direction = 'income'), 0)
      - coalesce(sum(i.amount) filter (where i.direction = 'expense'), 0) as balance
  from public.home_fixed_month_items i
  where i.user_id = auth.uid()
    and i.currency = 'CNY'
    and i.status in ('paid', 'settled')
    and i.month_key >= p_year::text || '-01'
    and i.month_key <= p_year::text || '-12'
  group by i.month_key
),
cny_transaction_stats as (
  select
    to_char(t.transacted_at, 'YYYY-MM') as month_key,
    coalesce(sum(t.amount) filter (where t.transaction_type = 'income'), 0) as income,
    coalesce(sum(t.amount) filter (where t.transaction_type = 'expense'), 0) as expense,
    coalesce(sum(t.amount) filter (where t.transaction_type = 'income'), 0)
      - coalesce(sum(t.amount) filter (where t.transaction_type = 'expense'), 0) as balance
  from public.home_cny_transactions t
  where t.user_id = auth.uid()
    and t.currency = 'CNY'
    and t.transaction_type in ('income', 'expense')
    and t.linked_fixed_month_item_id is null
    and t.transacted_at >= make_date(p_year, 1, 1)
    and t.transacted_at < make_date(p_year + 1, 1, 1)
  group by to_char(t.transacted_at, 'YYYY-MM')
),
cny_stats as (
  select
    m.month_key,
    coalesce(cf.income, 0) + coalesce(ct.income, 0) as income,
    coalesce(cf.expense, 0) + coalesce(ct.expense, 0) as expense,
    coalesce(cf.balance, 0) + coalesce(ct.balance, 0) as balance
  from month_list m
  left join cny_fixed_stats cf on cf.month_key = m.month_key
  left join cny_transaction_stats ct on ct.month_key = m.month_key
),
jpy_accounts as (
  select id, opening_balance
  from public.home_accounts
  where user_id = auth.uid()
    and currency = 'JPY'
),
cny_accounts as (
  select id, opening_balance
  from public.home_accounts
  where user_id = auth.uid()
    and currency = 'CNY'
),
jpy_account_month_balances as (
  select
    m.month_key,
    coalesce(sum(j.opening_balance), 0)
      + coalesce((
        select sum(
          case
            when t.transaction_type in ('income', 'fx_in', 'fixed_in', 'fixed_advance_in', 'investment_pnl') then t.amount
            when t.transaction_type in ('expense', 'fx_out', 'fixed_out', 'fixed_advance_out', 'transfer') then -t.amount
            else 0
          end
        )
        from public.home_jpy_transactions t
        where t.user_id = auth.uid()
          and t.currency = 'JPY'
          and t.account_id in (select id from jpy_accounts)
          and t.transacted_at < m.next_month
      ), 0)
      + coalesce((
        select sum(t.amount)
        from public.home_jpy_transactions t
        where t.user_id = auth.uid()
          and t.currency = 'JPY'
          and t.transaction_type = 'transfer'
          and t.transfer_account_id in (select id from jpy_accounts)
          and t.transacted_at < m.next_month
      ), 0)
      + coalesce((
        select sum(e.amount)
        from public.home_account_correction_entries e
        join public.home_external_transaction_corrections c
          on c.id=e.correction_id and c.balance_effect_id=e.id
        where e.user_id=auth.uid()
          and e.currency='JPY'
          and e.direction='credit_restore'
          and e.account_id in (select id from jpy_accounts)
          and e.effective_date < m.next_month
          and c.status='completed'
      ), 0) as account_balance
  from month_list m
  cross join jpy_accounts j
  group by m.month_key, m.next_month
),
cny_account_month_balances as (
  select
    m.month_key,
    coalesce(sum(c.opening_balance), 0)
      + coalesce((
        select sum(
          case
            when t.transaction_type in ('income', 'fx_in') then t.amount
            when t.transaction_type in ('expense', 'fx_out', 'transfer') then -t.amount
            else 0
          end
        )
        from public.home_cny_transactions t
        where t.user_id = auth.uid()
          and t.currency = 'CNY'
          and t.account_id in (select id from cny_accounts)
          and t.transacted_at < m.next_month
      ), 0)
      + coalesce((
        select sum(t.amount)
        from public.home_cny_transactions t
        where t.user_id = auth.uid()
          and t.currency = 'CNY'
          and t.transaction_type = 'transfer'
          and t.transfer_account_id in (select id from cny_accounts)
          and t.transacted_at < m.next_month
      ), 0) as account_balance
  from month_list m
  cross join cny_accounts c
  group by m.month_key, m.next_month
),
month_stats as (
  select
    m.month_key,
    coalesce(jf.expense, 0) as jpy_fixed_amount,
    coalesce(jf.balance, 0) as jpy_fixed_balance,
    coalesce(jc.income, 0) as jpy_casual_income,
    coalesce(jc.expense, 0) as jpy_casual_expense,
    coalesce(jc.balance, 0) as jpy_casual_balance,
    coalesce(jab.account_balance, 0) as jpy_account_balance,
    coalesce(cs.income, 0) as cny_income,
    coalesce(cs.expense, 0) as cny_expense,
    coalesce(cs.balance, 0) as cny_balance,
    coalesce(cab.account_balance, 0) as cny_account_balance,
    coalesce(jf.income, 0) + coalesce(jc.income, 0) as jpy_income,
    coalesce(jf.expense, 0) + coalesce(jc.expense, 0) as jpy_expense,
    coalesce(jf.balance, 0) + coalesce(jc.balance, 0) as jpy_balance
  from month_list m
  left join jpy_fixed_stats jf on jf.month_key = m.month_key
  left join jpy_casual_stats jc on jc.month_key = m.month_key
  left join cny_stats cs on cs.month_key = m.month_key
  left join jpy_account_month_balances jab on jab.month_key = m.month_key
  left join cny_account_month_balances cab on cab.month_key = m.month_key
),
totals as (
  select
    coalesce(sum(jpy_income), 0) as jpy_income,
    coalesce(sum(jpy_expense), 0) as jpy_expense,
    coalesce(sum(jpy_balance), 0) as jpy_balance,
    coalesce(sum(cny_income), 0) as cny_income,
    coalesce(sum(cny_expense), 0) as cny_expense,
    coalesce(sum(cny_balance), 0) as cny_balance
  from month_stats
)
select jsonb_build_object(
  'year', p_year,
  'totals', jsonb_build_object(
    'jpy', jsonb_build_object(
      'income', totals.jpy_income,
      'expense', totals.jpy_expense,
      'balance', totals.jpy_balance
    ),
    'cny', jsonb_build_object(
      'income', totals.cny_income,
      'expense', totals.cny_expense,
      'balance', totals.cny_balance
    )
  ),
  'months', (
    select jsonb_agg(to_jsonb(month_stats) order by month_key)
    from month_stats
  )
)
from totals;
$$;

drop trigger if exists home_account_correction_entries_append_only
  on public.home_account_correction_entries;
create trigger home_account_correction_entries_append_only
before update or delete on public.home_account_correction_entries
for each row execute function public.home_guard_account_correction_entry();

create or replace function public.home_guard_external_transaction_correction()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if tg_op = 'DELETE' then
    raise exception using errcode='42501', message='HOME_EXTERNAL_TRANSACTION_CORRECTION_DELETE_FORBIDDEN';
  end if;

  if row(
    new.correction_type,new.reason_code,new.source_system,
    new.business_idempotency_key,new.operation_id,
    new.original_home_request_id,new.original_home_transaction_id,
    new.school_expense_id,new.school_attempt_id,
    new.amount,new.currency,new.account_id,new.original_effective_date,
    new.accounting_scope,new.external_event_id,new.external_reference_type,
    new.external_reference_id,new.original_idempotency_key,
    new.school_fingerprint,new.home_payload_hash,
    new.original_request_snapshot,new.original_transaction_snapshot,
    new.actor_source,new.actor_id,new.created_at
  ) is distinct from row(
    old.correction_type,old.reason_code,old.source_system,
    old.business_idempotency_key,old.operation_id,
    old.original_home_request_id,old.original_home_transaction_id,
    old.school_expense_id,old.school_attempt_id,
    old.amount,old.currency,old.account_id,old.original_effective_date,
    old.accounting_scope,old.external_event_id,old.external_reference_type,
    old.external_reference_id,old.original_idempotency_key,
    old.school_fingerprint,old.home_payload_hash,
    old.original_request_snapshot,old.original_transaction_snapshot,
    old.actor_source,old.actor_id,old.created_at
  ) then
    raise exception using errcode='42501', message='HOME_EXTERNAL_TRANSACTION_CORRECTION_IDENTITY_IMMUTABLE';
  end if;

  if new.version <> old.version + 1 then
    raise exception using errcode='40001', message='HOME_EXTERNAL_TRANSACTION_CORRECTION_VERSION_MUST_ADVANCE';
  end if;

  if not (
    (old.status='preparing' and new.status='prepared')
    or (old.status='prepared' and new.status='completed')
    or (old.status=new.status and old.status in ('prepared','completed'))
  ) then
    raise exception using errcode='42501', message='HOME_EXTERNAL_TRANSACTION_CORRECTION_TRANSITION_INVALID';
  end if;

  if old.status <> 'preparing' and row(
    new.balance_effect_id,new.replacement_request_id,
    new.replacement_fixed_item_id,new.replacement_projection_id,
    new.replacement_fingerprint,new.prepared_at
  ) is distinct from row(
    old.balance_effect_id,old.replacement_request_id,
    old.replacement_fixed_item_id,old.replacement_projection_id,
    old.replacement_fingerprint,old.prepared_at
  ) then
    raise exception using errcode='42501', message='HOME_EXTERNAL_TRANSACTION_CORRECTION_PREPARED_FACTS_IMMUTABLE';
  end if;

  if old.status='completed' and row(
    new.school_evidence_id,new.school_evidence_fingerprint,
    new.school_evidence_snapshot,new.completed_at
  ) is distinct from row(
    old.school_evidence_id,old.school_evidence_fingerprint,
    old.school_evidence_snapshot,old.completed_at
  ) then
    raise exception using errcode='42501', message='HOME_EXTERNAL_TRANSACTION_CORRECTION_COMPLETION_IMMUTABLE';
  end if;
  return new;
end;
$$;

drop trigger if exists home_external_transaction_corrections_guard
  on public.home_external_transaction_corrections;
create trigger home_external_transaction_corrections_guard
before update or delete on public.home_external_transaction_corrections
for each row execute function public.home_guard_external_transaction_correction();

create or replace function public.home_guard_correction_replacement_request()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if old.correction_id is not null then
    if tg_op='DELETE' then
      raise exception using errcode='42501', message='HOME_CORRECTION_REPLACEMENT_REQUEST_DELETE_FORBIDDEN';
    end if;
    if new.correction_id is distinct from old.correction_id
       or new.user_id is distinct from old.user_id
       or new.external_event_id is distinct from old.external_event_id
       or new.external_reference_id is distinct from old.external_reference_id
       or new.request_type is distinct from old.request_type
       or new.amount is distinct from old.amount
       or new.currency is distinct from old.currency
       or new.card_instrument_id is distinct from old.card_instrument_id
       or new.charge_date is distinct from old.charge_date
       or new.suggested_fixed_month is distinct from old.suggested_fixed_month
       or new.target_fixed_month is distinct from old.target_fixed_month
       or new.idempotency_key is distinct from old.idempotency_key
       or new.payload_snapshot is distinct from old.payload_snapshot then
      raise exception using errcode='42501', message='HOME_CORRECTION_REPLACEMENT_REQUEST_IMMUTABLE';
    end if;
  end if;
  return case when tg_op='DELETE' then old else new end;
end;
$$;

drop trigger if exists home_external_requests_correction_guard
  on public.home_external_transaction_requests;
create trigger home_external_requests_correction_guard
before update or delete on public.home_external_transaction_requests
for each row execute function public.home_guard_correction_replacement_request();

revoke all on function public.home_guard_account_correction_entry() from public, anon, authenticated, service_role;
revoke all on function public.home_guard_external_transaction_correction() from public, anon, authenticated, service_role;
revoke all on function public.home_guard_correction_replacement_request() from public, anon, authenticated, service_role;

create or replace function public.home_validate_external_request_payment_route()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_card public.home_card_instruments%rowtype;
  v_schedule record;
  v_snapshot_funding_date date;
  v_correction public.home_external_transaction_corrections%rowtype;
  v_is_correction boolean := new.correction_id is not null;
  v_consumed_authorization_id uuid;
begin
  if new.payment_route = 'immediate_account' then
    if new.correction_id is not null then
      raise exception using errcode='23514', message='IMMEDIATE_REQUEST_CANNOT_LINK_CORRECTION';
    end if;
    return new;
  end if;

  if tg_op='UPDATE' and row(
    new.user_id,new.external_source,new.external_event_id,
    new.external_reference_type,new.external_reference_id,
    new.request_type,new.transaction_type,new.currency,new.amount,
    new.account_id,new.transacted_at,new.idempotency_key,
    new.payload_snapshot,new.accounting_scope,new.payment_route,
    new.card_instrument_id,new.charge_date,new.suggested_fixed_month,
    new.funding_account_id,new.correction_id
  ) is distinct from row(
    old.user_id,old.external_source,old.external_event_id,
    old.external_reference_type,old.external_reference_id,
    old.request_type,old.transaction_type,old.currency,old.amount,
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
$$;

revoke all on function public.home_validate_external_request_payment_route()
  from public,anon,authenticated,service_role;

create or replace function public.home_validate_external_fixed_projection()
returns trigger
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
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
$$;

create or replace function public.home_build_external_transaction_correction_p_result(p_correction_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
  select jsonb_build_object(
    'ok',true,
    'correction_id',c.id,
    'correction_type',c.correction_type,
    'reason_code',c.reason_code,
    'status',c.status,
    'version',c.version,
    'business_idempotency_key',c.business_idempotency_key,
    'operation_id',c.operation_id,
    'original_home_request_id',c.original_home_request_id,
    'original_home_transaction_id',c.original_home_transaction_id,
    'school_expense_id',c.school_expense_id,
    'school_attempt_id',c.school_attempt_id,
    'balance_effect_id',c.balance_effect_id,
    'replacement_request_id',c.replacement_request_id,
    'replacement_fixed_item_id',c.replacement_fixed_item_id,
    'replacement_projection_id',c.replacement_projection_id,
    'school_evidence_id',c.school_evidence_id,
    'amount',c.amount,
    'currency',c.currency,
    'account_id',c.account_id,
    'original_effective_date',c.original_effective_date,
    'accounting_scope',c.accounting_scope,
    'external_event_id',c.external_event_id,
    'external_reference_type',c.external_reference_type,
    'external_reference_id',c.external_reference_id,
    'original_idempotency_key',c.original_idempotency_key,
    'school_fingerprint',c.school_fingerprint,
    'home_payload_hash',c.home_payload_hash,
    'replacement_fingerprint',c.replacement_fingerprint,
    'school_evidence_fingerprint',c.school_evidence_fingerprint,
    'school_evidence_snapshot',c.school_evidence_snapshot,
    'actor_source',c.actor_source,
    'actor_id',c.actor_id,
    'prepared_at',c.prepared_at,
    'completed_at',c.completed_at,
    'retry_count',c.retry_count,
    'last_retried_at',c.last_retried_at,
    'created_at',c.created_at,
    'effect',case when e.id is null then null else jsonb_build_object(
      'id',e.id,'direction',e.direction,'amount',e.amount,'currency',e.currency,
      'account_id',e.account_id,'accounting_scope',e.accounting_scope,
      'effective_date',e.effective_date,'created_at',e.created_at,
      'source_snapshot_hash',e.source_snapshot_hash
    ) end,
    'replacement',case when r.id is null then null else jsonb_build_object(
      'request_id',r.id,'request_status',r.status,'request_type',r.request_type,
      'payment_route',r.payment_route,'amount',r.amount,'currency',r.currency,
      'card_instrument_id',r.card_instrument_id,'charge_date',r.charge_date,
      'suggested_fixed_month',r.suggested_fixed_month,
      'target_fixed_month',r.target_fixed_month,
      'fixed_projection_id',r.fixed_projection_id,
      'projection_status',r.projection_status,
      'idempotency_key',r.idempotency_key,
      'fixed_item_id',i.id,'fixed_item_status',i.status,
      'fixed_item_month_key',i.month_key,'fixed_item_due_date',i.due_date,
      'fixed_item_payment_group',i.payment_group,
      'projection_id',p.id,'projection_funding_status',p.funding_status,
      'projection_status_value',p.projection_status,
      'funding_account_id',p.funding_account_id,
      'funding_transaction_id',p.funding_transaction_id,'funded_at',p.funded_at
    ) end
  )
  from public.home_external_transaction_corrections c
  left join public.home_account_correction_entries e on e.id=c.balance_effect_id
  left join public.home_external_transaction_requests r on r.id=c.replacement_request_id
  left join public.home_fixed_month_items i on i.id=c.replacement_fixed_item_id
  left join public.home_external_fixed_payment_projections p on p.id=c.replacement_projection_id
  where c.id=p_correction_id;
$$;

create or replace function public.home_prepare_external_transaction_correction_p_core(
  p_operation_id uuid,
  p_original_home_request_id uuid,
  p_original_home_transaction_id uuid,
  p_school_expense_id uuid,
  p_school_attempt_id uuid,
  p_school_fingerprint text,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_request public.home_external_transaction_requests%rowtype;
  v_transaction public.home_jpy_transactions%rowtype;
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_policy public.home_external_correction_route_policies%rowtype;
  v_policy_ids uuid[];
  v_schedule record;
  v_existing public.home_external_transaction_corrections%rowtype;
  v_correction_id uuid := gen_random_uuid();
  v_effect_id uuid := gen_random_uuid();
  v_replacement_request_id uuid := gen_random_uuid();
  v_item_id uuid := gen_random_uuid();
  v_projection_id uuid := gen_random_uuid();
  v_business_key text;
  v_replacement_key text;
  v_now timestamptz := statement_timestamp();
  v_request_snapshot jsonb;
  v_transaction_snapshot jsonb;
  v_payload jsonb;
  v_payload_hash text;
  v_effect_hash text;
  v_replacement_fingerprint text;
  v_business_month date;
begin
  if p_operation_id is null or p_original_home_request_id is null
     or p_original_home_transaction_id is null or p_school_expense_id is null
     or p_school_attempt_id is null or p_actor_id is null
     or coalesce(p_school_fingerprint,'') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_PREPARE_INPUT_INVALID','message','Correction-P input is incomplete or invalid');
  end if;

  v_business_key := concat_ws(':','correction-p',p_original_home_request_id,
    p_original_home_transaction_id,p_school_expense_id,p_school_attempt_id);
  perform pg_advisory_xact_lock(hashtextextended(v_business_key,22082601));

  select * into v_existing
  from public.home_external_transaction_corrections c
  where c.operation_id=p_operation_id
     or c.business_idempotency_key=v_business_key
  order by (c.operation_id=p_operation_id) desc
  limit 1
  for update;

  if found then
    if v_existing.operation_id is distinct from p_operation_id then
      return jsonb_build_object('ok',false,'code','HOME_CORRECTION_BUSINESS_OPERATION_CONFLICT','message','Correction-P business identity already uses another operation','correction_id',v_existing.id);
    end if;
    if v_existing.original_home_request_id is distinct from p_original_home_request_id
       or v_existing.original_home_transaction_id is distinct from p_original_home_transaction_id
       or v_existing.school_expense_id is distinct from p_school_expense_id
       or v_existing.school_attempt_id is distinct from p_school_attempt_id
       or v_existing.school_fingerprint is distinct from p_school_fingerprint
       or v_existing.actor_id is distinct from p_actor_id then
      return jsonb_build_object('ok',false,'code','HOME_CORRECTION_OPERATION_PAYLOAD_CONFLICT','message','Correction-P operation already exists with different payload','correction_id',v_existing.id);
    end if;
    if v_existing.status='preparing' then
      raise exception using errcode='55000', message='HOME_CORRECTION_PREPARING_PERSISTED_INTEGRITY_ERROR';
    end if;
    update public.home_external_transaction_corrections
    set version=version+1,retry_count=retry_count+1,last_retried_at=statement_timestamp()
    where id=v_existing.id;
    return public.home_build_external_transaction_correction_p_result(v_existing.id)
      || jsonb_build_object('idempotent',true,'inserted',false,'message','Correction-P Home facts already prepared');
  end if;

  select * into v_request
  from public.home_external_transaction_requests r
  where r.id=p_original_home_request_id
  for update;
  if not found then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_ORIGINAL_REQUEST_NOT_FOUND','message','original Home request was not found');
  end if;

  select * into v_transaction
  from public.home_jpy_transactions t
  where t.id=p_original_home_transaction_id
  for update;
  if not found then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_ORIGINAL_TRANSACTION_NOT_FOUND','message','original Home transaction was not found');
  end if;

  v_request_snapshot := to_jsonb(v_request);
  v_transaction_snapshot := to_jsonb(v_transaction);
  v_payload_hash := md5(v_request.payload_snapshot::text);

  if v_request.status<>'approved' or v_request.payment_route<>'immediate_account'
     or v_request.request_type<>'expense_paid' or v_request.transaction_type<>'expense'
     or v_request.external_source<>'aozora_school'
     or v_request.external_reference_type<>'school_expense_records'
     or v_request.external_reference_id is distinct from p_school_expense_id
     or v_request.payload_snapshot->>'school_attempt_id' is distinct from p_school_attempt_id::text
     or v_request.payload_snapshot->>'school_attempt_payload_fingerprint' is distinct from p_school_fingerprint
     or v_request.created_transaction_id is distinct from v_transaction.id
     or v_request.accounting_scope<>'school'
     or v_request.currency<>'JPY'
     or v_request.account_id is null
     or v_request.correction_id is not null then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_ORIGINAL_REQUEST_MISMATCH','message','original Home request no longer matches Correction-P evidence');
  end if;

  if v_transaction.user_id is distinct from v_request.user_id
     or v_transaction.currency<>'JPY' or v_transaction.transaction_type<>'expense'
     or v_transaction.account_id is distinct from v_request.account_id
     or v_transaction.transacted_at is distinct from v_request.transacted_at
     or v_transaction.amount is distinct from v_request.amount
     or v_transaction.accounting_scope<>'school'
     or v_transaction.created_by_external is not true
     or v_transaction.external_source is distinct from v_request.external_source
     or v_transaction.external_source_id is distinct from v_request.external_event_id
     or v_transaction.external_event_type is distinct from v_request.request_type
     or v_transaction.external_idempotency_key is distinct from v_request.idempotency_key
     or v_transaction.external_reference_type is distinct from v_request.external_reference_type
     or v_transaction.external_reference_id is distinct from v_request.external_reference_id
     or v_transaction.external_payload_hash is distinct from v_payload_hash then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_ORIGINAL_TRANSACTION_MISMATCH','message','original Home transaction no longer matches the immutable request');
  end if;

  if exists(select 1 from public.home_external_transaction_corrections c
    where c.original_home_request_id=v_request.id
       or c.original_home_transaction_id=v_transaction.id
       or c.school_expense_id=p_school_expense_id
       or c.school_attempt_id=p_school_attempt_id) then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_DUPLICATE_IDENTITY','message','another Correction-P already owns one of the source identities');
  end if;

  select array_agg(p.id order by p.id) into v_policy_ids
  from public.home_external_correction_route_policies p
  where p.operation_kind='school_expense_immediate_to_fixed'
    and p.user_id=v_request.user_id
    and p.accounting_scope=v_request.accounting_scope
    and p.currency=v_request.currency
    and p.is_active
    and v_transaction.transacted_at>=p.effective_from
    and (p.effective_to is null or v_transaction.transacted_at<=p.effective_to);
  if coalesce(cardinality(v_policy_ids),0)=0 then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_ROUTE_POLICY_NOT_CONFIGURED','message','Correction-P route policy is not configured');
  end if;
  if cardinality(v_policy_ids)<>1 then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_ROUTE_POLICY_CONFLICT','message','Correction-P route policy is ambiguous');
  end if;
  select * into v_policy
  from public.home_external_correction_route_policies p
  where p.id=v_policy_ids[1]
  for share;

  select * into v_card from public.home_card_instruments c
  where c.id=v_policy.card_instrument_id
  for share;
  if not found
     or v_card.user_id is distinct from v_request.user_id
     or v_card.settlement_currency<>'JPY' or v_card.is_active is not true then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_CARD_INVALID','message','Correction-P target card is invalid');
  end if;
  perform public.home_lock_card_fixed_month(v_card.id,
    (select suggested_fixed_month from public.home_calculate_card_fixed_schedule(v_card.id,v_transaction.transacted_at)));
  select * into v_channel from public.home_payment_channels ch
  where ch.id=v_policy.payment_channel_id
  for key share;
  if not found or v_channel.user_id is distinct from v_request.user_id
     or v_channel.currency<>'JPY' or v_channel.is_active is not true
     or v_card.funding_payment_channel_id is distinct from v_channel.id then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_CHANNEL_INVALID','message','Correction-P card funding channel is invalid');
  end if;
  select * into v_schedule
  from public.home_calculate_card_fixed_schedule(v_card.id,v_transaction.transacted_at);

  if exists(select 1 from public.home_card_statement_cycles s
    where s.user_id=v_request.user_id and s.card_instrument_id=v_card.id
      and s.target_fixed_month=v_schedule.suggested_fixed_month) then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_STATEMENT_ALREADY_EXISTS','message','Correction-P cannot attach to an existing statement cycle');
  end if;
  if exists(select 1 from public.home_fixed_advance_payments a
    where a.user_id=v_request.user_id
      and a.month_key=to_char(v_schedule.suggested_fixed_month,'YYYY-MM')
      and a.currency='JPY' and a.payment_group=v_channel.name) then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_GROUP_ALREADY_FUNDED','message','Correction-P target payment group already has funding/advance');
  end if;

  begin
    if coalesce(v_request.payload_snapshot->>'year_month','') !~ '^[0-9]{4}-(0[1-9]|1[0-2])$' then
      raise exception using errcode='22007', message='invalid year_month';
    end if;
    v_business_month := to_date(v_request.payload_snapshot->>'year_month'||'-01','YYYY-MM-DD');
  exception when others then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_BUSINESS_MONTH_INVALID','message','original School business month is invalid');
  end;

  insert into public.home_external_transaction_corrections(
    id,correction_type,reason_code,status,version,source_system,
    business_idempotency_key,operation_id,original_home_request_id,
    original_home_transaction_id,school_expense_id,school_attempt_id,
    amount,currency,account_id,original_effective_date,accounting_scope,
    external_event_id,external_reference_type,external_reference_id,
    original_idempotency_key,school_fingerprint,home_payload_hash,
    original_request_snapshot,original_transaction_snapshot,
    actor_source,actor_id,created_at
  ) values (
    v_correction_id,'school_expense_immediate_to_fixed','wrong_immediate_account_route',
    'preparing',1,'aozora_school',v_business_key,p_operation_id,v_request.id,
    v_transaction.id,p_school_expense_id,p_school_attempt_id,
    v_transaction.amount,'JPY',v_transaction.account_id,v_transaction.transacted_at,'school',
    v_transaction.external_source_id,v_transaction.external_reference_type,
    v_transaction.external_reference_id,v_transaction.external_idempotency_key,
    p_school_fingerprint,v_payload_hash,v_request_snapshot,v_transaction_snapshot,
    'school_active_admin',p_actor_id,v_now
  );

  v_effect_hash := encode(extensions.digest(convert_to(jsonb_build_object(
    'correction_id',v_correction_id,'original_transaction_id',v_transaction.id,
    'account_id',v_transaction.account_id,'amount',v_transaction.amount,
    'currency','JPY','effective_date',v_transaction.transacted_at,
    'direction','credit_restore','accounting_scope','school'
  )::text,'UTF8'),'sha256'),'hex');
  insert into public.home_account_correction_entries(
    id,correction_id,original_transaction_id,user_id,account_id,direction,
    amount,currency,accounting_scope,effective_date,source_snapshot_hash,created_at
  ) values (
    v_effect_id,v_correction_id,v_transaction.id,v_transaction.user_id,
    v_transaction.account_id,'credit_restore',v_transaction.amount,'JPY','school',
    v_transaction.transacted_at,v_effect_hash,v_now
  );

  v_replacement_key := 'correction-p:'||v_correction_id||':replacement';
  v_payload := jsonb_build_object(
    'correction_id',v_correction_id,
    'correction_type','school_expense_immediate_to_fixed',
    'original_home_request_id',v_request.id,
    'original_home_transaction_id',v_transaction.id,
    'school_expense_id',p_school_expense_id,
    'school_attempt_id',p_school_attempt_id,
    'external_source','aozora_school',
    'external_reference_type','school_expense_records',
    'external_reference_id',p_school_expense_id,
    'request_type','expense_fixed_correction_p',
    'transaction_type','expense',
    'payment_route','fixed_credit_card',
    'card_instrument_id',v_card.id,
    'charge_date',v_transaction.transacted_at,
    'suggested_fixed_month',v_schedule.suggested_fixed_month,
    'target_fixed_month',v_schedule.suggested_fixed_month,
    'funding_date',v_schedule.funding_date,
    'year_month',v_request.payload_snapshot->>'year_month',
    'school_attempt_payload_fingerprint',p_school_fingerprint,
    'operation_id',p_operation_id
  );
  insert into public.home_correction_replacement_authorizations(
    original_transaction_id,operation_id,correction_id,request_id,actor_id,
    replacement_type,fixed_month,card_instrument_id,payment_channel_id
  ) values (
    v_transaction.id,p_operation_id,v_correction_id,v_replacement_request_id,p_actor_id,
    'expense_fixed_correction_p',v_schedule.suggested_fixed_month,v_card.id,v_channel.id
  );
  insert into public.home_external_transaction_requests(
    id,user_id,external_source,external_event_id,external_reference_type,
    external_reference_id,request_type,transaction_type,currency,amount,
    account_id,transacted_at,status,requested_at,idempotency_key,payload_snapshot,
    description,note,created_at,updated_at,accounting_scope,payment_route,
    card_instrument_id,charge_date,suggested_fixed_month,target_fixed_month,
    fixed_month_override_reason,funding_account_id,fixed_projection_id,
    projection_status,correction_id
  ) values (
    v_replacement_request_id,v_request.user_id,'aozora_school',v_request.external_event_id,
    'school_expense_records',p_school_expense_id,'expense_fixed_correction_p','expense',
    'JPY',v_transaction.amount,null,v_transaction.transacted_at,'pending',v_now,
    v_replacement_key,v_payload,v_request.description,v_request.note,v_now,v_now,
    'school','fixed_credit_card',v_card.id,v_transaction.transacted_at,
    v_schedule.suggested_fixed_month,v_schedule.suggested_fixed_month,null,null,null,
    'pending',v_correction_id
  );

  insert into public.home_fixed_month_items(
    id,user_id,template_id,month_key,currency,direction,name,amount,status,
    account_id,payment_group,due_date,term_no,total_terms,note,
    linked_jpy_transaction_id,linked_cny_transaction_id,accounting_scope
  ) values (
    v_item_id,v_request.user_id,null,to_char(v_schedule.suggested_fixed_month,'YYYY-MM'),
    'JPY','expense',v_request.description,v_transaction.amount,'unpaid',null,
    v_channel.name,v_schedule.funding_date,null,null,v_request.note,null,null,'school'
  );

  insert into public.home_external_fixed_payment_projections(
    id,user_id,external_request_id,external_source,external_reference_type,
    external_reference_id,external_event_id,external_idempotency_key,
    school_expense_id,payment_route,card_instrument_id,
    funding_payment_channel_id,funding_account_id,business_month,charge_date,
    suggested_fixed_month,target_fixed_month,funding_date,original_amount,
    original_currency,settlement_amount,settlement_currency,
    settlement_amount_status,fixed_month_item_id,projection_status,funding_status,
    funding_transaction_id,supersedes_projection_id,fixed_month_override_reason,
    fixed_month_override_actor,fixed_month_overridden_at,created_at,approved_at,
    funded_at,updated_at,version
  ) values (
    v_projection_id,v_request.user_id,v_replacement_request_id,'aozora_school',
    'school_expense_records',p_school_expense_id,v_request.external_event_id,
    v_replacement_key,p_school_expense_id,'fixed_credit_card',v_card.id,
    v_channel.id,null,v_business_month,v_transaction.transacted_at,
    v_schedule.suggested_fixed_month,v_schedule.suggested_fixed_month,
    v_schedule.funding_date,v_transaction.amount,'JPY',v_transaction.amount,'JPY',
    'confirmed',v_item_id,'projected','unfunded',null,null,null,null,null,
    v_now,v_now,null,v_now,1
  );

  update public.home_external_transaction_requests
  set status='approved',approved_at=v_now,fixed_projection_id=v_projection_id,
      projection_status='projected',updated_at=v_now
  where id=v_replacement_request_id;

  v_replacement_fingerprint := encode(extensions.digest(convert_to(jsonb_build_object(
    'correction_id',v_correction_id,'replacement_request_id',v_replacement_request_id,
    'fixed_item_id',v_item_id,'projection_id',v_projection_id,
    'card_instrument_id',v_card.id,'payment_group',v_channel.name,
    'amount',v_transaction.amount,'currency','JPY','charge_date',v_transaction.transacted_at,
    'target_fixed_month',v_schedule.suggested_fixed_month,
    'funding_date',v_schedule.funding_date,'request_idempotency_key',v_replacement_key
  )::text,'UTF8'),'sha256'),'hex');

  update public.home_external_transaction_corrections
  set status='prepared',version=2,balance_effect_id=v_effect_id,
      replacement_request_id=v_replacement_request_id,
      replacement_fixed_item_id=v_item_id,replacement_projection_id=v_projection_id,
      replacement_fingerprint=v_replacement_fingerprint,prepared_at=v_now
  where id=v_correction_id;

  return public.home_build_external_transaction_correction_p_result(v_correction_id)
    || jsonb_build_object('idempotent',false,'inserted',true,'message','Correction-P Home facts prepared atomically');
exception
  when unique_violation then
    raise exception using errcode='55000', message='HOME_CORRECTION_IDENTITY_CONFLICT', detail=sqlerrm;
end;
$$;

create or replace function public.home_prepare_external_transaction_correction_p(
  p_operation_id uuid,
  p_original_home_request_id uuid,
  p_original_home_transaction_id uuid,
  p_school_expense_id uuid,
  p_school_attempt_id uuid,
  p_school_fingerprint text,
  p_actor_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_SERVICE_ROLE_REQUIRED','message','service_role is required');
  end if;
  return public.home_prepare_external_transaction_correction_p_core(
    p_operation_id,p_original_home_request_id,p_original_home_transaction_id,
    p_school_expense_id,p_school_attempt_id,p_school_fingerprint,p_actor_id
  );
end;
$$;

create or replace function public.home_get_external_transaction_correction_p(p_operation_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = pg_catalog, public
as $$
declare v_id uuid;
begin
  if coalesce(auth.role(),'')<>'service_role' then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_SERVICE_ROLE_REQUIRED','message','service_role is required');
  end if;
  select id into v_id from public.home_external_transaction_corrections
  where operation_id=p_operation_id;
  if v_id is null then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_NOT_FOUND','message','Correction-P operation was not found');
  end if;
  return public.home_build_external_transaction_correction_p_result(v_id);
end;
$$;

create or replace function public.home_correction_p_evidence_fingerprint_v1(
  p_evidence_id uuid,p_home_correction_id uuid,p_operation_id uuid,
  p_correction_type text,p_original_home_request_id uuid,
  p_original_home_transaction_id uuid,p_home_balance_effect_id uuid,
  p_replacement_request_id uuid,p_replacement_fixed_item_id uuid,
  p_replacement_projection_id uuid,p_school_expense_id uuid,
  p_school_attempt_id uuid,p_amount numeric,p_currency text,
  p_charge_date date,p_accounting_scope text,p_external_event_id uuid,
  p_original_idempotency_key text,p_school_fingerprint text,
  p_home_payload_hash text,p_replacement_fingerprint text,
  p_actor_id uuid,p_finalized_at timestamptz
)
returns text
language sql
immutable
parallel safe
set search_path = pg_catalog, public
as $$
  select encode(extensions.digest(convert_to(jsonb_build_object(
    'evidence_id',p_evidence_id,
    'home_correction_id',p_home_correction_id,
    'operation_id',p_operation_id,
    'correction_type',p_correction_type,
    'original_home_request_id',p_original_home_request_id,
    'original_home_transaction_id',p_original_home_transaction_id,
    'home_balance_effect_id',p_home_balance_effect_id,
    'replacement_request_id',p_replacement_request_id,
    'replacement_fixed_item_id',p_replacement_fixed_item_id,
    'replacement_projection_id',p_replacement_projection_id,
    'school_expense_id',p_school_expense_id,
    'school_attempt_id',p_school_attempt_id,
    'amount',p_amount::text,
    'currency',p_currency,
    'charge_date',p_charge_date::text,
    'accounting_scope',p_accounting_scope,
    'external_event_id',p_external_event_id,
    'original_idempotency_key',p_original_idempotency_key,
    'school_fingerprint',p_school_fingerprint,
    'home_payload_hash',p_home_payload_hash,
    'replacement_fingerprint',p_replacement_fingerprint,
    'actor_id',p_actor_id,
    'finalized_at_utc',to_char(p_finalized_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  )::text,'UTF8'),'sha256'),'hex');
$$;

create or replace function public.home_complete_external_transaction_correction_p_core(
  p_correction_id uuid,
  p_operation_id uuid,
  p_school_evidence_id uuid,
  p_school_evidence_fingerprint text,
  p_school_finalized_at timestamptz,
  p_actor_id uuid,
  p_school_evidence_snapshot jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_correction public.home_external_transaction_corrections%rowtype;
  v_request public.home_external_transaction_requests%rowtype;
  v_transaction public.home_jpy_transactions%rowtype;
  v_effect public.home_account_correction_entries%rowtype;
  v_replacement public.home_external_transaction_requests%rowtype;
  v_item public.home_fixed_month_items%rowtype;
  v_projection public.home_external_fixed_payment_projections%rowtype;
  v_expected_fingerprint text;
begin
  if p_correction_id is null or p_operation_id is null
     or p_school_evidence_id is null or p_school_finalized_at is null
     or p_actor_id is null
     or p_school_evidence_snapshot is null
     or coalesce(p_school_evidence_fingerprint,'') !~ '^[0-9a-f]{64}$' then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_COMPLETE_INPUT_INVALID','message','School evidence input is incomplete');
  end if;

  select * into v_correction
  from public.home_external_transaction_corrections c
  where c.id=p_correction_id
  for update;
  if not found then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_NOT_FOUND','message','Correction-P was not found');
  end if;
  if v_correction.operation_id is distinct from p_operation_id
     or v_correction.actor_id is distinct from p_actor_id then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_COMPLETE_OPERATION_CONFLICT','message','Correction-P operation or actor mismatch');
  end if;

  v_expected_fingerprint := public.home_correction_p_evidence_fingerprint_v1(
    p_school_evidence_id,v_correction.id,v_correction.operation_id,
    v_correction.correction_type,v_correction.original_home_request_id,
    v_correction.original_home_transaction_id,v_correction.balance_effect_id,
    v_correction.replacement_request_id,v_correction.replacement_fixed_item_id,
    v_correction.replacement_projection_id,v_correction.school_expense_id,
    v_correction.school_attempt_id,v_correction.amount,v_correction.currency,
    v_correction.original_effective_date,v_correction.accounting_scope,
    v_correction.external_event_id,v_correction.original_idempotency_key,
    v_correction.school_fingerprint,v_correction.home_payload_hash,
    v_correction.replacement_fingerprint,p_actor_id,p_school_finalized_at
  );
  if p_school_evidence_fingerprint is distinct from v_expected_fingerprint then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_SCHOOL_EVIDENCE_FINGERPRINT_MISMATCH','message','School evidence fingerprint does not match prepared Home facts');
  end if;

  if p_school_evidence_snapshot->>'ok'<>'true'
     or (p_school_evidence_snapshot->>'school_evidence_id')::uuid is distinct from p_school_evidence_id
     or (p_school_evidence_snapshot->>'operation_id')::uuid is distinct from v_correction.operation_id
     or (p_school_evidence_snapshot->>'home_correction_id')::uuid is distinct from v_correction.id
     or p_school_evidence_snapshot->>'correction_type' is distinct from v_correction.correction_type
     or (p_school_evidence_snapshot->>'original_home_request_id')::uuid is distinct from v_correction.original_home_request_id
     or (p_school_evidence_snapshot->>'original_home_transaction_id')::uuid is distinct from v_correction.original_home_transaction_id
     or (p_school_evidence_snapshot->>'home_balance_effect_id')::uuid is distinct from v_correction.balance_effect_id
     or (p_school_evidence_snapshot->>'replacement_request_id')::uuid is distinct from v_correction.replacement_request_id
     or (p_school_evidence_snapshot->>'replacement_fixed_item_id')::uuid is distinct from v_correction.replacement_fixed_item_id
     or (p_school_evidence_snapshot->>'replacement_projection_id')::uuid is distinct from v_correction.replacement_projection_id
     or (p_school_evidence_snapshot->>'school_expense_id')::uuid is distinct from v_correction.school_expense_id
     or (p_school_evidence_snapshot->>'school_attempt_id')::uuid is distinct from v_correction.school_attempt_id
     or (p_school_evidence_snapshot->>'amount')::numeric is distinct from v_correction.amount
     or p_school_evidence_snapshot->>'currency' is distinct from v_correction.currency
     or (p_school_evidence_snapshot->>'charge_date')::date is distinct from v_correction.original_effective_date
     or p_school_evidence_snapshot->>'accounting_scope' is distinct from v_correction.accounting_scope
     or (p_school_evidence_snapshot->>'external_event_id')::uuid is distinct from v_correction.external_event_id
     or p_school_evidence_snapshot->>'original_idempotency_key' is distinct from v_correction.original_idempotency_key
     or p_school_evidence_snapshot->>'school_fingerprint' is distinct from v_correction.school_fingerprint
     or p_school_evidence_snapshot->>'home_payload_hash' is distinct from v_correction.home_payload_hash
     or p_school_evidence_snapshot->>'replacement_fingerprint' is distinct from v_correction.replacement_fingerprint
     or (p_school_evidence_snapshot->>'actor_id')::uuid is distinct from p_actor_id
     or (p_school_evidence_snapshot->>'school_finalized_at')::timestamptz is distinct from p_school_finalized_at
     or p_school_evidence_snapshot->>'school_evidence_fingerprint' is distinct from p_school_evidence_fingerprint then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_SCHOOL_EVIDENCE_SNAPSHOT_MISMATCH','message','School evidence snapshot does not match prepared Home facts');
  end if;

  if v_correction.status='completed' then
    if v_correction.school_evidence_id is distinct from p_school_evidence_id
       or v_correction.school_evidence_fingerprint is distinct from p_school_evidence_fingerprint
       or v_correction.school_evidence_snapshot is distinct from p_school_evidence_snapshot then
      return jsonb_build_object('ok',false,'code','HOME_CORRECTION_COMPLETE_TERMINAL_CONFLICT','message','completed Correction-P has different School evidence');
    end if;
    return public.home_build_external_transaction_correction_p_result(v_correction.id)
      || jsonb_build_object('idempotent',true,'message','Correction-P already completed');
  end if;
  if v_correction.status<>'prepared' then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_NOT_PREPARED','message','Correction-P is not prepared');
  end if;

  select * into v_request from public.home_external_transaction_requests
  where id=v_correction.original_home_request_id for share;
  select * into v_transaction from public.home_jpy_transactions
  where id=v_correction.original_home_transaction_id for share;
  select * into v_effect from public.home_account_correction_entries
  where id=v_correction.balance_effect_id for share;
  select * into v_replacement from public.home_external_transaction_requests
  where id=v_correction.replacement_request_id for update;
  select * into v_item from public.home_fixed_month_items
  where id=v_correction.replacement_fixed_item_id for update;
  select * into v_projection from public.home_external_fixed_payment_projections
  where id=v_correction.replacement_projection_id for update;

  if to_jsonb(v_request) is distinct from v_correction.original_request_snapshot
     or to_jsonb(v_transaction) is distinct from v_correction.original_transaction_snapshot
     or v_effect.correction_id is distinct from v_correction.id
     or v_effect.original_transaction_id is distinct from v_transaction.id
     or v_effect.account_id is distinct from v_correction.account_id
     or v_effect.amount is distinct from v_correction.amount
     or v_effect.currency is distinct from v_correction.currency
     or v_effect.effective_date is distinct from v_correction.original_effective_date
     or v_replacement.correction_id is distinct from v_correction.id
     or v_replacement.status<>'approved'
     or v_replacement.request_type<>'expense_fixed_correction_p'
     or v_replacement.fixed_projection_id is distinct from v_projection.id
     or v_replacement.projection_status<>'projected'
     or v_item.id is distinct from v_projection.fixed_month_item_id
     or v_item.status<>'unpaid' or v_item.account_id is not null
     or v_item.linked_jpy_transaction_id is not null
     or v_item.linked_cny_transaction_id is not null
     or v_projection.projection_status<>'projected'
     or v_projection.funding_status<>'unfunded'
     or v_projection.funding_account_id is not null
     or v_projection.funding_transaction_id is not null
     or v_projection.funded_at is not null then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_PREPARED_FACTS_DRIFT','message','prepared Home facts no longer match Correction-P');
  end if;
  if exists(select 1 from public.home_card_statement_cycles s
    where s.card_instrument_id=v_projection.card_instrument_id
      and s.target_fixed_month=v_projection.target_fixed_month) then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_STATEMENT_FACT_UNEXPECTED','message','statement cycle exists before Correction-P completion');
  end if;

  update public.home_external_transaction_corrections
  set status='completed',version=version+1,school_evidence_id=p_school_evidence_id,
      school_evidence_fingerprint=p_school_evidence_fingerprint,
      school_evidence_snapshot=p_school_evidence_snapshot,
      completed_at=statement_timestamp(),last_error_code=null,last_error_at=null
  where id=v_correction.id;

  return public.home_build_external_transaction_correction_p_result(v_correction.id)
    || jsonb_build_object('idempotent',false,'message','Correction-P completed');
end;
$$;

create or replace function public.home_complete_external_transaction_correction_p(
  p_correction_id uuid,p_operation_id uuid,p_school_evidence_id uuid,
  p_school_evidence_fingerprint text,p_school_finalized_at timestamptz,p_actor_id uuid
  ,p_school_evidence_snapshot jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
begin
  if coalesce(auth.role(),'')<>'service_role' then
    return jsonb_build_object('ok',false,'code','HOME_CORRECTION_SERVICE_ROLE_REQUIRED','message','service_role is required');
  end if;
  return public.home_complete_external_transaction_correction_p_core(
    p_correction_id,p_operation_id,p_school_evidence_id,
    p_school_evidence_fingerprint,p_school_finalized_at,p_actor_id,
    p_school_evidence_snapshot
  );
exception when invalid_text_representation or invalid_datetime_format then
  return jsonb_build_object('ok',false,'code','HOME_CORRECTION_SCHOOL_EVIDENCE_SNAPSHOT_MISMATCH','message','School evidence snapshot contains an invalid typed value');
end;
$$;

-- A prepared replacement is an internal saga fact, not a normal fixed item.
-- The existing authenticated reader becomes able to see it atomically when the
-- authoritative correction row reaches completed.
drop policy if exists home_fixed_month_items_user_select on public.home_fixed_month_items;
create policy home_fixed_month_items_user_select
on public.home_fixed_month_items
for select to authenticated
using (
  user_id=auth.uid()
  and public.home_is_fixed_item_visible_to_business_reader(home_fixed_month_items.id)
);

create or replace function public.home_get_jpy_account_page(p_month_key text)
returns jsonb
language sql
stable
security definer
set search_path = pg_catalog, public
as $$
with month_range as (
  select to_date(p_month_key||'-01','YYYY-MM-DD') as month_start,
    (to_date(p_month_key||'-01','YYYY-MM-DD')+interval '1 month')::date as next_month
),
accounts as (
  select * from public.home_accounts
  where user_id=auth.uid() and currency='JPY' and is_active
),
movements as (
  select a.id account_id,a.opening_balance amount from accounts a
  union all
  select t.account_id,
    case
      when t.transaction_type in ('income','fx_in','fixed_in','fixed_advance_in','investment_pnl') then t.amount
      when t.transaction_type in ('expense','fx_out','fixed_out','fixed_advance_out','transfer') then -t.amount
      else 0
    end
  from public.home_jpy_transactions t,month_range r
  where t.user_id=auth.uid() and t.currency='JPY' and t.transacted_at<r.next_month
  union all
  select t.transfer_account_id,t.amount
  from public.home_jpy_transactions t,month_range r
  where t.user_id=auth.uid() and t.currency='JPY'
    and t.transaction_type='transfer' and t.transfer_account_id is not null
    and t.transacted_at<r.next_month
  union all
  select e.account_id,e.amount
  from public.home_account_correction_entries e
  join public.home_external_transaction_corrections c
    on c.id=e.correction_id and c.balance_effect_id=e.id
  cross join month_range r
  where e.user_id=auth.uid() and e.currency='JPY'
    and e.direction='credit_restore' and e.effective_date<r.next_month
    and c.status='completed'
),
account_balances as (
  select a.id,a.user_id,a.currency,a.name,a.account_type,a.opening_balance,
    a.is_active,a.sort_order,a.created_at,coalesce(sum(m.amount),0) current_balance
  from accounts a left join movements m on m.account_id=a.id
  group by a.id,a.user_id,a.currency,a.name,a.account_type,a.opening_balance,
    a.is_active,a.sort_order,a.created_at
),
month_transactions as (
  select t.*,a.name account_name,ta.name transfer_account_name,
    ct.account_id linked_cny_account_id,ca.name linked_cny_account_name,
    ct.amount linked_cny_amount,c.id correction_id,c.status correction_status,
    c.correction_type,c.completed_at correction_completed_at
  from public.home_jpy_transactions t
  join public.home_accounts a on a.id=t.account_id
  left join public.home_accounts ta on ta.id=t.transfer_account_id
  left join public.home_cny_transactions ct
    on ct.id=t.linked_cny_transaction_id and ct.user_id=auth.uid()
  left join public.home_accounts ca on ca.id=ct.account_id and ca.user_id=auth.uid()
  left join public.home_external_transaction_corrections c
    on c.original_home_transaction_id=t.id
  cross join month_range r
  where t.user_id=auth.uid() and t.currency='JPY'
    and t.transacted_at>=r.month_start and t.transacted_at<r.next_month
)
select jsonb_build_object(
  'accounts',coalesce((select jsonb_agg(to_jsonb(account_balances)
    order by sort_order,created_at,name) from account_balances),'[]'::jsonb),
  'transactions',coalesce((select jsonb_agg(
    (to_jsonb(month_transactions)-'accounting_scope')||jsonb_build_object(
      'accounting_scope',month_transactions.accounting_scope,
      'is_corrected',month_transactions.correction_status='completed')
    order by transacted_at desc,created_at desc)
    from month_transactions),'[]'::jsonb)
);
$$;

create or replace function public.home_build_card_statement_school_manifest(
  p_user_id uuid,p_card_instrument_id uuid,p_target_fixed_month date
)
returns jsonb
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
  v_card public.home_card_instruments%rowtype;
  v_channel public.home_payment_channels%rowtype;
  v_request_count integer;
  v_projection_count integer;
  v_valid_count integer;
  v_manifest jsonb;
  v_subtotal numeric;
  v_fingerprint text;
begin
  select * into v_card from public.home_card_instruments c
  where c.id=p_card_instrument_id and c.user_id=p_user_id;
  if not found or p_target_fixed_month is null
     or p_target_fixed_month<>date_trunc('month',p_target_fixed_month)::date then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CARD_OR_MONTH_INVALID','message','card or target month is invalid');
  end if;
  select * into v_channel from public.home_payment_channels c
  where c.id=v_card.funding_payment_channel_id;
  if not found then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_CHANNEL_INVALID','message','card payment channel is missing');
  end if;

  select count(*) into v_request_count
  from public.home_external_transaction_requests r
  where r.user_id=p_user_id and r.payment_route='fixed_credit_card'
    and r.card_instrument_id=p_card_instrument_id
    and r.target_fixed_month=p_target_fixed_month and r.status='approved'
    and (r.correction_id is null or exists (
      select 1 from public.home_external_transaction_corrections c
      where c.id=r.correction_id and c.status='completed'
        and c.replacement_request_id=r.id));

  select count(*) into v_projection_count
  from public.home_external_fixed_payment_projections p
  join public.home_external_transaction_requests r on r.id=p.external_request_id
  where p.user_id=p_user_id and p.card_instrument_id=p_card_instrument_id
    and p.target_fixed_month=p_target_fixed_month and p.projection_status='projected'
    and (r.correction_id is null or exists (
      select 1 from public.home_external_transaction_corrections c
      where c.id=r.correction_id and c.status='completed'
        and c.replacement_request_id=r.id and c.replacement_projection_id=p.id));

  with valid as (
    select r.id request_id,p.id projection_id,i.id fixed_item_id,
      p.school_expense_id,r.external_event_id,p.settlement_amount amount,
      p.settlement_currency currency,p.card_instrument_id,p.target_fixed_month
    from public.home_external_transaction_requests r
    join public.home_external_fixed_payment_projections p
      on p.external_request_id=r.id and r.fixed_projection_id=p.id
    join public.home_fixed_month_items i on i.id=p.fixed_month_item_id
    where r.user_id=p_user_id and p.user_id=p_user_id
      and r.payment_route='fixed_credit_card' and p.payment_route='fixed_credit_card'
      and r.status='approved' and r.projection_status='projected'
      and r.card_instrument_id=p_card_instrument_id and p.card_instrument_id=p_card_instrument_id
      and r.target_fixed_month=p_target_fixed_month and p.target_fixed_month=p_target_fixed_month
      and p.projection_status='projected' and p.funding_status='unfunded'
      and p.funding_account_id is null and p.funding_transaction_id is null and p.funded_at is null
      and p.fixed_month_override_reason is null and p.supersedes_projection_id is null
      and p.external_reference_type='school_expense_records'
      and p.school_expense_id=p.external_reference_id
      and p.external_reference_id=r.external_reference_id
      and p.external_event_id=r.external_event_id
      and p.external_idempotency_key=r.idempotency_key
      and p.original_amount=r.amount and p.settlement_amount=r.amount
      and p.original_currency=r.currency and p.settlement_currency=r.currency
      and i.user_id=p_user_id and i.accounting_scope='school'
      and i.currency=v_card.settlement_currency and i.direction='expense'
      and i.month_key=to_char(p_target_fixed_month,'YYYY-MM')
      and coalesce(i.payment_group,'未分组')=coalesce(v_channel.name,'未分组')
      and i.amount=p.settlement_amount and i.status='unpaid'
      and i.account_id is null and i.linked_jpy_transaction_id is null
      and i.linked_cny_transaction_id is null
      and (r.correction_id is null or exists (
        select 1 from public.home_external_transaction_corrections c
        where c.id=r.correction_id and c.status='completed'
          and c.replacement_request_id=r.id
          and c.replacement_fixed_item_id=i.id
          and c.replacement_projection_id=p.id))
  )
  select count(*),coalesce(sum(amount),0),coalesce(jsonb_agg(jsonb_build_object(
    'request_id',request_id,'projection_id',projection_id,'fixed_item_id',fixed_item_id,
    'school_expense_id',school_expense_id,'external_event_id',external_event_id,
    'amount',amount,'currency',currency,'card_instrument_id',card_instrument_id,
    'target_fixed_month',target_fixed_month
  ) order by request_id),'[]'::jsonb)
  into v_valid_count,v_subtotal,v_manifest from valid;
  if v_request_count<>v_valid_count or v_projection_count<>v_valid_count then
    return jsonb_build_object('ok',false,'code','HOME_CARD_STATEMENT_SCHOOL_MANIFEST_INTEGRITY_ERROR','message','approved School projection facts are incomplete or inconsistent');
  end if;
  v_fingerprint:=encode(extensions.digest(convert_to(v_manifest::text,'UTF8'),'sha256'),'hex');
  return jsonb_build_object('ok',true,'school_subtotal',v_subtotal,
    'school_manifest',v_manifest,'school_manifest_fingerprint',v_fingerprint,
    'school_item_count',v_valid_count);
end;
$$;

revoke all on function public.home_build_external_transaction_correction_p_result(uuid)
  from public,anon,authenticated,service_role;
revoke all on function public.home_prepare_external_transaction_correction_p_core(
  uuid,uuid,uuid,uuid,uuid,text,uuid
) from public,anon,authenticated,service_role;
revoke all on function public.home_correction_p_evidence_fingerprint_v1(
  uuid,uuid,uuid,text,uuid,uuid,uuid,uuid,uuid,uuid,uuid,uuid,numeric,text,date,
  text,uuid,text,text,text,text,uuid,timestamptz
) from public,anon,authenticated,service_role;
revoke all on function public.home_complete_external_transaction_correction_p_core(
  uuid,uuid,uuid,text,timestamptz,uuid,jsonb
) from public,anon,authenticated,service_role;
revoke all on function public.home_prepare_external_transaction_correction_p(
  uuid,uuid,uuid,uuid,uuid,text,uuid
) from public,anon,authenticated;
grant execute on function public.home_prepare_external_transaction_correction_p(
  uuid,uuid,uuid,uuid,uuid,text,uuid
) to service_role;
revoke all on function public.home_get_external_transaction_correction_p(uuid)
  from public,anon,authenticated;
grant execute on function public.home_get_external_transaction_correction_p(uuid)
  to service_role;
revoke all on function public.home_complete_external_transaction_correction_p(
  uuid,uuid,uuid,text,timestamptz,uuid,jsonb
) from public,anon,authenticated;
grant execute on function public.home_complete_external_transaction_correction_p(
  uuid,uuid,uuid,text,timestamptz,uuid,jsonb
) to service_role;
revoke all on function public.home_is_fixed_item_visible_to_business_reader(uuid)
  from public,anon,service_role;
grant execute on function public.home_is_fixed_item_visible_to_business_reader(uuid)
  to authenticated;
comment on function public.home_prepare_external_transaction_correction_p(
  uuid,uuid,uuid,uuid,uuid,text,uuid
) is 'Service-only Correction-P prepare. Atomically creates the append-only effect and one approved/projected/unfunded replacement while all normal readers remain on the original facts.';
comment on function public.home_complete_external_transaction_correction_p(
  uuid,uuid,uuid,text,timestamptz,uuid,jsonb
) is 'Service-only Correction-P complete. Verifies immutable School evidence and atomically activates the completed-only reader switch.';
