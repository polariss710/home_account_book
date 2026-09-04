-- queried_at_jst: 2026-09-05T01:53:56.798532
-- LEFT JOIN rollback baseline before adding funding_month_offset.
-- {"name": "home_get_card_route_catalog", "owner": "postgres", "proacl": ["postgres=X/postgres"], "proconfig": ["search_path=pg_catalog, public"], "prosecdef": false, "signature": "home_get_card_route_catalog(uuid)", "prosrc_md5": "5d7de5ebd366a535367fff859be17f1c", "queried_at_jst": "2026-09-05T01:53:56.798532"}
CREATE OR REPLACE FUNCTION public.home_get_card_route_catalog(p_user_id uuid DEFAULT NULL::uuid)
 RETURNS TABLE(card_instrument_id uuid, user_id uuid, card_name text, settlement_currency text, cutoff_day integer, cutoff_inclusive boolean, funding_day integer, funding_payment_channel_id uuid, funding_payment_channel_name text, household_statement_template_id uuid, household_statement_template_name text, is_active boolean, is_school_fixed_route_enabled boolean, version bigint)
 LANGUAGE sql
 STABLE
 SET search_path TO 'pg_catalog', 'public'
AS $function$
  select
    c.id,
    c.user_id,
    c.name,
    c.settlement_currency,
    c.cutoff_day,
    c.cutoff_inclusive,
    c.funding_day,
    c.funding_payment_channel_id,
    pc.name,
    c.household_statement_template_id,
    ft.name,
    c.is_active,
    c.is_school_fixed_route_enabled,
    c.version
  from public.home_card_instruments c
  join public.home_payment_channels pc on pc.id = c.funding_payment_channel_id
  left join public.home_fixed_templates ft on ft.id = c.household_statement_template_id
  where p_user_id is null or c.user_id = p_user_id
  order by c.user_id, c.settlement_currency, c.name, c.id;
$function$;
