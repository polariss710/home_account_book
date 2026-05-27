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
