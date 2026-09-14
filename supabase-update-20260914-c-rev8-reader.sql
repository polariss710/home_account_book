-- C rev8 step 6: own pending advances across months. No new table or business column.
\set ON_ERROR_STOP on
begin;
set local lock_timeout='3s';
create or replace function public.home_list_pending_fixed_advances()
returns table(advance_id uuid,month_key text,currency text,payment_group text,account_id uuid,account_name text,amount numeric,paid_at date)
language sql security invoker stable set search_path=pg_catalog,public
as $function$
  select a.id,a.month_key,a.currency,a.payment_group,a.account_id,b.name,a.amount,a.paid_at
  from public.home_fixed_advance_payments a
  left join public.home_accounts b on b.id=a.account_id and b.user_id=a.user_id
  where a.user_id=auth.uid() and a.status='pending'
  order by a.month_key,a.paid_at,a.id;
$function$;
alter function public.home_list_pending_fixed_advances() owner to postgres;
revoke all on function public.home_list_pending_fixed_advances() from public,anon,service_role;
grant execute on function public.home_list_pending_fixed_advances() to authenticated;
commit;
