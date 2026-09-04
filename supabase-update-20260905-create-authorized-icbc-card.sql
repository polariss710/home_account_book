-- Owner authorization: 2026-09-05 deployment request, steps 5 and 6.
-- Exactly two records: CNY Alipay channel and ICBC card without household template.
-- No gate activation here. Channel default_due_day remains NULL (not specified).
-- Run first with -v apply=false, inspect rollback evidence, then -v apply=true.
\set ON_ERROR_STOP on
begin;
set local statement_timeout = '30s';
do $create_card$
declare
  u constant uuid := '8596a708-d99f-4264-8f8c-5b89af9254b6';
  ch uuid; card uuid; r record; actual record;
begin
  if exists(select 1 from public.home_payment_channels where user_id=u and name='支付宝')
    or exists(select 1 from public.home_card_instruments where user_id=u and name='工行卡') then
    raise exception 'ABORT: named channel/card already exists; inspect before retry';
  end if;
  insert into public.home_payment_channels(user_id,name,currency,is_active)
    values(u,'支付宝','CNY',true) returning id into ch;
  insert into public.home_card_instruments(user_id,name,settlement_currency,cutoff_day,cutoff_inclusive,funding_day,
    funding_month_offset,funding_payment_channel_id,household_statement_template_id,is_active,is_school_fixed_route_enabled)
    values(u,'工行卡','CNY',28,true,15,1,ch,null,true,false) returning id into card;
  if not exists(select 1 from public.home_get_card_route_catalog(u)
    where card_instrument_id=card and settlement_currency='CNY' and cutoff_day=28 and cutoff_inclusive
      and funding_day=15 and funding_month_offset=1 and funding_payment_channel_id=ch
      and funding_payment_channel_name='支付宝' and household_statement_template_id is null
      and household_statement_template_name is null and is_active and not is_school_fixed_route_enabled) then
    raise exception 'ABORT: card catalog does not exactly match authorized configuration';
  end if;
  for r in select * from (values
    ('2026-09-15'::date,'2026-10-01'::date,'2026-10-15'::date),
    ('2026-09-28'::date,'2026-10-01'::date,'2026-10-15'::date),
    ('2026-09-29'::date,'2026-11-01'::date,'2026-11-15'::date)
  ) expected(charge_day,fixed_month,funding_day) loop
    select * into strict actual from public.home_calculate_card_fixed_schedule(card,r.charge_day);
    if actual.suggested_fixed_month is distinct from r.fixed_month or actual.funding_date is distinct from r.funding_day then
      raise exception 'ABORT: schedule mismatch for %: %',r.charge_day,row_to_json(actual);
    end if;
    raise notice 'ICBC_SCHEDULE_PASS %: %',r.charge_day,row_to_json(actual);
  end loop;
  raise notice 'AUTHORIZED_CHANNEL_ID=% CARD_ID=% GATE=false',ch,card;
end $create_card$;
select 'channel',to_jsonb(c) from public.home_payment_channels c
where user_id='8596a708-d99f-4264-8f8c-5b89af9254b6' and name='支付宝';
select 'card',to_jsonb(c) from public.home_card_instruments c
where user_id='8596a708-d99f-4264-8f8c-5b89af9254b6' and name='工行卡';
\if :apply
commit;
\else
rollback;
\endif
