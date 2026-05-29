create table if not exists home_jpy_transactions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  currency text not null default 'JPY' check (currency = 'JPY'),
  transaction_type text not null check (transaction_type in ('income', 'expense', 'transfer', 'fx_in', 'fx_out', 'fixed_in', 'fixed_out')),
  account_id uuid not null references home_accounts(id) on delete cascade,
  transfer_account_id uuid references home_accounts(id) on delete cascade,
  transacted_at date not null,
  amount numeric(14, 2) not null check (amount > 0),
  description text not null default '',
  note text not null default '',
  created_at timestamptz not null default now(),
  check (
    (transaction_type = 'transfer' and transfer_account_id is not null and transfer_account_id <> account_id)
    or (transaction_type <> 'transfer' and transfer_account_id is null)
  )
);

create index if not exists home_jpy_transactions_user_date_idx on home_jpy_transactions(user_id, transacted_at);

grant select, insert, update, delete on home_jpy_transactions to authenticated;

alter table home_jpy_transactions enable row level security;

do $$
begin
  if not exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename = 'home_jpy_transactions'
      and policyname = 'home_jpy_transactions_user_all'
  ) then
    create policy home_jpy_transactions_user_all
      on home_jpy_transactions
      for all
      to authenticated
      using (user_id = auth.uid())
      with check (user_id = auth.uid());
  end if;
end $$;

create or replace function home_get_jpy_account_page(p_month_key text)
returns jsonb
language sql
stable
security invoker
as $$
with month_range as (
  select
    to_date(p_month_key || '-01', 'YYYY-MM-DD') as month_start,
    (to_date(p_month_key || '-01', 'YYYY-MM-DD') + interval '1 month')::date as next_month
),
accounts as (
  select *
  from home_accounts
  where user_id = auth.uid()
    and currency = 'JPY'
    and account_type in ('cash', 'bank')
    and is_active
),
movements as (
  select
    a.id as account_id,
    a.opening_balance as amount
  from accounts a
  union all
  select
    t.account_id,
    case
      when t.transaction_type in ('income', 'fx_in', 'fixed_in') then t.amount
      when t.transaction_type in ('expense', 'fx_out', 'fixed_out', 'transfer') then -t.amount
      else 0
    end as amount
  from home_jpy_transactions t, month_range r
  where t.user_id = auth.uid()
    and t.currency = 'JPY'
    and t.transacted_at < r.next_month
  union all
  select
    t.transfer_account_id as account_id,
    t.amount
  from home_jpy_transactions t, month_range r
  where t.user_id = auth.uid()
    and t.currency = 'JPY'
    and t.transaction_type = 'transfer'
    and t.transfer_account_id is not null
    and t.transacted_at < r.next_month
),
account_balances as (
  select
    a.*,
    coalesce(sum(m.amount), 0) as current_balance
  from accounts a
  left join movements m on m.account_id = a.id
  group by a.id
),
month_transactions as (
  select
    t.*,
    a.name as account_name,
    ta.name as transfer_account_name
  from home_jpy_transactions t
  join home_accounts a on a.id = t.account_id
  left join home_accounts ta on ta.id = t.transfer_account_id
  cross join month_range r
  where t.user_id = auth.uid()
    and t.currency = 'JPY'
    and t.transacted_at >= r.month_start
    and t.transacted_at < r.next_month
)
select jsonb_build_object(
  'accounts', coalesce((
    select jsonb_agg(to_jsonb(account_balances) order by sort_order, created_at, name)
    from account_balances
  ), '[]'::jsonb),
  'transactions', coalesce((
    select jsonb_agg(to_jsonb(month_transactions) order by transacted_at desc, created_at desc)
    from month_transactions
  ), '[]'::jsonb)
);
$$;

grant execute on function home_get_jpy_account_page(text) to authenticated;
