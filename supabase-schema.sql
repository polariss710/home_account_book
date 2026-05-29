create extension if not exists "pgcrypto";

drop function if exists home_get_month_page(text);
drop function if exists home_get_fixed_month_page(text, text);
drop function if exists home_generate_fixed_month(text, text);

drop table if exists home_transactions cascade;
drop table if exists home_categories cascade;
drop table if exists home_months cascade;
drop table if exists home_fixed_month_items cascade;
drop table if exists home_fixed_templates cascade;
drop table if exists home_accounts cascade;

create table home_accounts (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  currency text not null check (currency in ('JPY', 'CNY')),
  name text not null,
  account_type text not null check (account_type in ('cash', 'bank', 'wallet', 'pass_through', 'investment')),
  opening_balance numeric(14, 2) not null default 0,
  is_active boolean not null default true,
  sort_order integer not null default 0,
  created_at timestamptz not null default now()
);

create table home_fixed_templates (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  currency text not null check (currency in ('JPY', 'CNY')),
  direction text not null check (direction in ('income', 'expense')),
  name text not null,
  fixed_type text not null check (fixed_type in ('long_term', 'short_term')),
  default_amount numeric(14, 2) not null default 0,
  default_account_id uuid references home_accounts(id) on delete set null,
  payment_group text,
  due_day integer check (due_day between 1 and 31),
  start_month text,
  end_month text,
  total_terms integer check (total_terms is null or total_terms > 0),
  sort_order integer not null default 0,
  is_active boolean not null default true,
  created_at timestamptz not null default now()
);

create table home_fixed_month_items (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  template_id uuid references home_fixed_templates(id) on delete set null,
  month_key text not null,
  currency text not null check (currency in ('JPY', 'CNY')),
  direction text not null check (direction in ('income', 'expense')),
  name text not null,
  amount numeric(14, 2) not null default 0,
  status text not null default 'unpaid' check (status in ('unpaid', 'paid', 'settled')),
  account_id uuid references home_accounts(id) on delete set null,
  payment_group text,
  due_date date,
  term_no integer,
  total_terms integer,
  note text not null default '',
  created_at timestamptz not null default now()
);

create unique index home_fixed_month_items_template_month_unique
  on home_fixed_month_items(user_id, month_key, template_id)
  where template_id is not null;

create index home_accounts_user_currency_idx on home_accounts(user_id, currency);
create index home_fixed_templates_user_currency_idx on home_fixed_templates(user_id, currency);
create index home_fixed_month_items_user_month_idx on home_fixed_month_items(user_id, month_key, currency);

grant usage on schema public to anon, authenticated;
grant select, insert, update, delete on home_accounts to authenticated;
grant select, insert, update, delete on home_fixed_templates to authenticated;
grant select, insert, update, delete on home_fixed_month_items to authenticated;

alter table home_accounts enable row level security;
alter table home_fixed_templates enable row level security;
alter table home_fixed_month_items enable row level security;

create policy home_accounts_user_all
  on home_accounts
  for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy home_fixed_templates_user_all
  on home_fixed_templates
  for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create policy home_fixed_month_items_user_all
  on home_fixed_month_items
  for all
  to authenticated
  using (user_id = auth.uid())
  with check (user_id = auth.uid());

create or replace function home_generate_fixed_month(p_month_key text, p_currency text default 'JPY')
returns jsonb
language sql
security invoker
as $$
with eligible_templates as (
  select
    t.*,
    case
      when t.due_day is null then null
      else (
        to_date(p_month_key || '-01', 'YYYY-MM-DD')
        + (least(t.due_day, extract(day from (to_date(p_month_key || '-01', 'YYYY-MM-DD') + interval '1 month - 1 day'))::integer) - 1) * interval '1 day'
      )::date
    end as generated_due_date,
    case
      when t.fixed_type = 'short_term' and t.start_month is not null then
        ((extract(year from to_date(p_month_key || '-01', 'YYYY-MM-DD'))::integer * 12 + extract(month from to_date(p_month_key || '-01', 'YYYY-MM-DD'))::integer)
        - (extract(year from to_date(t.start_month || '-01', 'YYYY-MM-DD'))::integer * 12 + extract(month from to_date(t.start_month || '-01', 'YYYY-MM-DD'))::integer)
        + 1)
      else null
    end as generated_term_no
  from home_fixed_templates t
  where t.user_id = auth.uid()
    and t.currency = p_currency
    and t.is_active
    and (t.start_month is null or t.start_month <= p_month_key)
    and (t.end_month is null or t.end_month >= p_month_key)
    and (
      t.fixed_type = 'long_term'
      or t.total_terms is null
      or t.start_month is null
      or (
        ((extract(year from to_date(p_month_key || '-01', 'YYYY-MM-DD'))::integer * 12 + extract(month from to_date(p_month_key || '-01', 'YYYY-MM-DD'))::integer)
        - (extract(year from to_date(t.start_month || '-01', 'YYYY-MM-DD'))::integer * 12 + extract(month from to_date(t.start_month || '-01', 'YYYY-MM-DD'))::integer)
        + 1) between 1 and t.total_terms
      )
    )
),
existing_items as (
  select count(*) as existing_count
  from eligible_templates t
  join home_fixed_month_items i
    on i.user_id = auth.uid()
   and i.month_key = p_month_key
   and i.template_id = t.id
),
inserted_items as (
  insert into home_fixed_month_items (
    user_id,
    template_id,
    month_key,
    currency,
    direction,
    name,
    amount,
    status,
    account_id,
    payment_group,
    due_date,
    term_no,
    total_terms,
    note
  )
  select
    t.user_id,
    t.id,
    p_month_key,
    t.currency,
    t.direction,
    t.name,
    t.default_amount,
    'unpaid',
    t.default_account_id,
    t.payment_group,
    t.generated_due_date,
    t.generated_term_no,
    t.total_terms,
    ''
  from eligible_templates t
  on conflict do nothing
  returning id
)
select jsonb_build_object(
  'eligible_count', (select count(*) from eligible_templates),
  'existing_count', (select existing_count from existing_items),
  'inserted_count', (select count(*) from inserted_items)
);
$$;

create or replace function home_get_fixed_month_page(p_month_key text, p_currency text default 'JPY')
returns jsonb
language sql
stable
security invoker
as $$
with month_items as (
  select *
  from home_fixed_month_items
  where user_id = auth.uid()
    and month_key = p_month_key
    and currency = p_currency
),
metrics as (
  select
    coalesce(sum(amount) filter (where direction = 'income'), 0) as income,
    coalesce(sum(amount) filter (where direction = 'expense'), 0) as expense,
    coalesce(sum(amount) filter (where direction = 'expense' and status = 'unpaid'), 0) as unpaid_expense
  from month_items
),
expense_groups as (
  select
    coalesce(payment_group, '未分组') as payment_group,
    coalesce(sum(amount), 0) as total,
    coalesce(sum(amount) filter (where status in ('paid', 'settled')), 0) as paid,
    coalesce(sum(amount) filter (where status = 'unpaid'), 0) as unpaid
  from month_items
  where direction = 'expense'
  group by coalesce(payment_group, '未分组')
)
select jsonb_build_object(
  'metrics', jsonb_build_object(
    'income', (select income from metrics),
    'expense', (select expense from metrics),
    'balance', (select income - expense from metrics),
    'unpaid_expense', (select unpaid_expense from metrics)
  ),
  'expense_groups', coalesce((
    select jsonb_agg(to_jsonb(expense_groups) order by payment_group)
    from expense_groups
  ), '[]'::jsonb),
  'income_items', coalesce((
    select jsonb_agg(to_jsonb(month_items) order by created_at, name)
    from month_items
    where direction = 'income'
  ), '[]'::jsonb),
  'expense_items', coalesce((
    select jsonb_agg(to_jsonb(month_items) order by payment_group, due_date, created_at, name)
    from month_items
    where direction = 'expense'
  ), '[]'::jsonb),
  'templates', coalesce((
    select jsonb_agg(to_jsonb(t) order by sort_order, created_at, name)
    from home_fixed_templates t
    where t.user_id = auth.uid()
      and t.currency = p_currency
      and t.is_active
  ), '[]'::jsonb),
  'accounts', coalesce((
    select jsonb_agg(to_jsonb(a) order by sort_order, created_at, name)
    from home_accounts a
    where a.user_id = auth.uid()
      and a.currency = p_currency
      and a.is_active
  ), '[]'::jsonb)
);
$$;

grant execute on function home_generate_fixed_month(text, text) to authenticated;
grant execute on function home_get_fixed_month_page(text, text) to authenticated;
