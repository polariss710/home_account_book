drop function if exists home_generate_fixed_month(text, text);

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
  'stopped_templates', coalesce((
    select jsonb_agg(to_jsonb(t) order by sort_order, created_at, name)
    from home_fixed_templates t
    where t.user_id = auth.uid()
      and t.currency = p_currency
      and not t.is_active
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
