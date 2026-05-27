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

alter table home_accounts enable row level security;
alter table home_categories enable row level security;
alter table home_months enable row level security;
alter table home_transactions enable row level security;

drop policy if exists home_accounts_anon_all on home_accounts;
create policy home_accounts_anon_all
  on home_accounts
  for all
  to anon
  using (true)
  with check (true);

drop policy if exists home_categories_anon_all on home_categories;
create policy home_categories_anon_all
  on home_categories
  for all
  to anon
  using (true)
  with check (true);

drop policy if exists home_months_anon_all on home_months;
create policy home_months_anon_all
  on home_months
  for all
  to anon
  using (true)
  with check (true);

drop policy if exists home_transactions_anon_all on home_transactions;
create policy home_transactions_anon_all
  on home_transactions
  for all
  to anon
  using (true)
  with check (true);
