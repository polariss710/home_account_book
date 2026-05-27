create extension if not exists "pgcrypto";

create table if not exists home_accounts (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('cash', 'wallet', 'bank', 'credit')),
  opening_balance numeric(14, 2) not null default 0,
  currency text not null default 'JPY',
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists home_categories (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  kind text not null check (kind in ('income', 'expense', 'transfer', 'adjustment')),
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table if not exists home_months (
  month_key text primary key,
  status text not null default 'open' check (status in ('open', 'locked')),
  created_at timestamptz not null default now()
);

create table if not exists home_transactions (
  id uuid primary key default gen_random_uuid(),
  date date not null,
  type text not null check (type in ('income', 'expense', 'transfer', 'adjustment')),
  amount numeric(14, 2) not null check (amount >= 0 or type = 'adjustment'),
  category_id uuid references home_categories(id) on delete set null,
  source_account_id uuid references home_accounts(id) on delete set null,
  target_account_id uuid references home_accounts(id) on delete set null,
  status text not null default 'paid' check (status in ('paid', 'unpaid')),
  description text not null default '',
  created_at timestamptz not null default now()
);

create index if not exists home_transactions_date_idx on home_transactions(date);
create index if not exists home_transactions_status_idx on home_transactions(status);
create index if not exists home_transactions_type_idx on home_transactions(type);

alter table home_accounts
  add column if not exists user_id uuid references auth.users(id) on delete cascade;

alter table home_categories
  add column if not exists user_id uuid references auth.users(id) on delete cascade;

alter table home_months
  add column if not exists user_id uuid references auth.users(id) on delete cascade;

alter table home_transactions
  add column if not exists user_id uuid references auth.users(id) on delete cascade;

do $$
begin
  if exists (
    select 1
    from pg_constraint
    where conname = 'home_months_pkey'
      and conrelid = 'home_months'::regclass
  ) then
    alter table home_months drop constraint home_months_pkey;
  end if;
end $$;

create unique index if not exists home_months_user_month_key
  on home_months(user_id, month_key);

create index if not exists home_accounts_user_id_idx on home_accounts(user_id);
create index if not exists home_categories_user_id_idx on home_categories(user_id);
create index if not exists home_months_user_id_idx on home_months(user_id);
create index if not exists home_transactions_user_id_idx on home_transactions(user_id);

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on home_accounts to anon, authenticated;
grant select, insert, update, delete on home_categories to anon, authenticated;
grant select, insert, update, delete on home_months to anon, authenticated;
grant select, insert, update, delete on home_transactions to anon, authenticated;

alter table home_accounts enable row level security;
alter table home_categories enable row level security;
alter table home_months enable row level security;
alter table home_transactions enable row level security;

drop policy if exists home_accounts_anon_all on home_accounts;
drop policy if exists home_accounts_user_all on home_accounts;
create policy home_accounts_user_all
  on home_accounts
  for all
  to authenticated
  using (user_id = auth.uid() or user_id is null)
  with check (user_id = auth.uid());

drop policy if exists home_categories_anon_all on home_categories;
drop policy if exists home_categories_user_all on home_categories;
create policy home_categories_user_all
  on home_categories
  for all
  to authenticated
  using (user_id = auth.uid() or user_id is null)
  with check (user_id = auth.uid());

drop policy if exists home_months_anon_all on home_months;
drop policy if exists home_months_user_all on home_months;
create policy home_months_user_all
  on home_months
  for all
  to authenticated
  using (user_id = auth.uid() or user_id is null)
  with check (user_id = auth.uid());

drop policy if exists home_transactions_anon_all on home_transactions;
drop policy if exists home_transactions_user_all on home_transactions;
create policy home_transactions_user_all
  on home_transactions
  for all
  to authenticated
  using (user_id = auth.uid() or user_id is null)
  with check (user_id = auth.uid());

create or replace function home_get_month_page(p_month_key text)
returns jsonb
language sql
stable
security invoker
as $$
with bounds as (
  select
    to_date(p_month_key || '-01', 'YYYY-MM-DD') as start_date,
    (to_date(p_month_key || '-01', 'YYYY-MM-DD') + interval '1 month - 1 day')::date as end_date
),
month_txs as (
  select t.*
  from home_transactions t
  cross join bounds b
  where t.user_id = auth.uid()
    and t.date >= b.start_date
    and t.date <= b.end_date
),
month_metrics as (
  select
    coalesce(sum(amount) filter (where type = 'income' and status = 'paid'), 0) as income,
    coalesce(sum(amount) filter (where type = 'expense' and status = 'paid'), 0) as expense,
    coalesce(sum(amount) filter (where status = 'unpaid'), 0) as unpaid
  from month_txs
),
balance_movements as (
  select
    a.id as account_id,
    coalesce(sum(
      case
        when t.type = 'income' and t.target_account_id = a.id then t.amount
        when t.type = 'expense' and t.source_account_id = a.id then -t.amount
        when t.type = 'transfer' and t.source_account_id = a.id then -t.amount
        when t.type = 'transfer' and t.target_account_id = a.id then t.amount
        when t.type = 'adjustment' and t.target_account_id = a.id then t.amount
        else 0
      end
    ), 0) as movement
  from home_accounts a
  cross join bounds b
  left join home_transactions t
    on t.user_id = auth.uid()
   and t.status = 'paid'
   and t.date <= b.end_date
   and (
      t.source_account_id = a.id
      or t.target_account_id = a.id
   )
  where a.user_id = auth.uid()
  group by a.id
),
account_balances as (
  select
    a.id,
    a.name,
    a.kind,
    a.sort_order,
    (a.opening_balance + coalesce(m.movement, 0)) as balance
  from home_accounts a
  left join balance_movements m on m.account_id = a.id
  where a.user_id = auth.uid()
),
pending_rows as (
  select
    t.id,
    t.date,
    t.description,
    t.amount,
    t.status,
    c.name as category_name
  from month_txs t
  left join home_categories c on c.id = t.category_id and c.user_id = auth.uid()
  where t.status = 'unpaid'
  order by t.date asc, t.created_at asc
),
transaction_rows as (
  select
    t.id,
    t.date,
    t.type,
    t.description,
    t.amount,
    t.status,
    t.category_id,
    c.name as category_name,
    t.source_account_id,
    source_account.name as source_account_name,
    t.target_account_id,
    target_account.name as target_account_name,
    case
      when t.type = 'income' then coalesce(target_account.name, '-')
      when t.type = 'expense' then coalesce(source_account.name, '-')
      when t.type = 'transfer' then coalesce(source_account.name, '-') || ' -> ' || coalesce(target_account.name, '-')
      else coalesce(target_account.name, '-')
    end as account_label,
    t.created_at
  from month_txs t
  left join home_categories c on c.id = t.category_id and c.user_id = auth.uid()
  left join home_accounts source_account on source_account.id = t.source_account_id and source_account.user_id = auth.uid()
  left join home_accounts target_account on target_account.id = t.target_account_id and target_account.user_id = auth.uid()
  order by t.date desc, t.created_at desc
)
select jsonb_build_object(
  'metrics', jsonb_build_object(
    'income', (select income from month_metrics),
    'expense', (select expense from month_metrics),
    'unpaid', (select unpaid from month_metrics),
    'balance', coalesce((select sum(balance) from account_balances), 0)
  ),
  'balances', coalesce((select jsonb_agg(jsonb_build_object(
    'id', id,
    'name', name,
    'kind', kind,
    'balance', balance
  ) order by sort_order, name) from account_balances), '[]'::jsonb),
  'pending', coalesce((select jsonb_agg(to_jsonb(pending_rows)) from pending_rows), '[]'::jsonb),
  'transactions', coalesce((select jsonb_agg(to_jsonb(transaction_rows)) from transaction_rows), '[]'::jsonb)
);
$$;

grant execute on function home_get_month_page(text) to authenticated;
