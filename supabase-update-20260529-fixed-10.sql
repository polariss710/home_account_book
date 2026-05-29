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
  select i.template_id
  from eligible_templates t
  join home_fixed_month_items i
    on i.user_id = auth.uid()
   and i.month_key = p_month_key
   and i.currency = p_currency
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
  where not exists (
    select 1
    from existing_items i
    where i.template_id = t.id
  )
  on conflict do nothing
  returning id, template_id
)
select jsonb_build_object(
  'eligible_count', (select count(*) from eligible_templates),
  'existing_count', (select count(*) from existing_items),
  'inserted_count', (select count(*) from inserted_items),
  'all_generated', (
    (select count(*) from eligible_templates) > 0
    and (select count(*) from eligible_templates) = (select count(*) from existing_items)
  ),
  'eligible_templates', coalesce((
    select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by sort_order, created_at, name)
    from eligible_templates
  ), '[]'::jsonb),
  'existing_template_ids', coalesce((
    select jsonb_agg(template_id)
    from existing_items
  ), '[]'::jsonb),
  'inserted_template_ids', coalesce((
    select jsonb_agg(template_id)
    from inserted_items
  ), '[]'::jsonb)
);
$$;

grant execute on function home_generate_fixed_month(text, text) to authenticated;
