-- Owner authorization: 2026-09-05 deployment request, step 6.
-- Six read-only schedule cases passed before this file was executed.
\set ON_ERROR_STOP on
begin;
do $enable_route$
declare n integer;
begin
  update public.home_card_instruments set is_school_fixed_route_enabled=true,version=version+1
  where id='a9e44d31-d82c-4ac1-8a67-10de98740585'
    and user_id='8596a708-d99f-4264-8f8c-5b89af9254b6' and name='工行卡'
    and settlement_currency='CNY' and cutoff_day=28 and cutoff_inclusive=true
    and funding_day=15 and funding_month_offset=1
    and funding_payment_channel_id='89f922b4-7d10-4204-b4b7-5c111a562b0d'
    and household_statement_template_id is null and is_active=true
    and is_school_fixed_route_enabled=false and version=1;
  get diagnostics n=row_count;
  if n<>1 then raise exception 'ABORT: exact authorized card configuration no longer matches'; end if;
end $enable_route$;
select id,is_school_fixed_route_enabled,version,updated_at AT TIME ZONE 'Asia/Tokyo' as gate_enabled_at_jst
from public.home_card_instruments where id='a9e44d31-d82c-4ac1-8a67-10de98740585';
commit;
