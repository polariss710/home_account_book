\set ON_ERROR_STOP on

-- Home / Cash：四个 security invoker writer 的 card statement guard 调用点补丁
--
-- 输入是 2026-08-24 生产 pg_get_functiondef。每个定义先核对 MD5，再一次性替换
-- 它引用的全部无 SELECT 权限表。任何定义、owner、security、search_path、ACL
-- 或旧谓词漂移都会令整个事务回滚。

begin;
set local lock_timeout = '8s';
set local statement_timeout = '120s';

do $patch$
declare
  v_sigs text[] := array[
    'public.home_update_fixed_month_item_status(uuid,text)',
    'public.home_update_fixed_month_items_status(text,text,text,text)',
    'public.home_sync_fixed_month_items(text,text)',
    'public.home_create_fixed_advance_payment(text,text,text,uuid,date,text)'
  ];
  v_expected_md5 text[] := array[
    '1274044962844a310f5131487d67a025',
    '2b0f1ef0e81eb05e3bd0257856f8ffdf',
    '544c08587bd26209cfe6ec5fe92b1042',
    '1dbb0c4dd7f87853cb4318c7f79bcefa'
  ];
  v_old text[] := array[
    $old1$if exists(select 1 from public.home_card_statement_cycles c where c.household_remainder_fixed_item_id=v_item.id) then$old1$,
    $old2$if exists(select 1 from public.home_card_statement_cycles c join public.home_fixed_month_items i on i.id=c.household_remainder_fixed_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction) then$old2$,
    $old3$if exists(select 1 from public.home_card_statement_cycles c join public.home_fixed_month_items i on i.id=c.household_remainder_fixed_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency) then$old3$,
    $old4$if exists(select 1 from public.home_card_statement_cycles c join public.home_card_instruments card on card.id=c.card_instrument_id join public.home_payment_channels ch on ch.id=card.funding_payment_channel_id
    where c.user_id=auth.uid() and to_char(c.target_fixed_month,'YYYY-MM')=p_month_key and c.settlement_currency=p_currency and coalesce(ch.name,'未分组')=v_group and c.household_remainder_fixed_item_id is not null) then$old4$
  ];
  v_new text[] := array[
    'if public.home_fixed_item_has_card_statement(v_item.id) then',
    'if public.home_fixed_scope_has_card_statement(p_month_key,p_currency,p_direction) then',
    'if public.home_fixed_scope_has_card_statement(p_month_key,p_currency) then',
    'if public.home_fixed_advance_group_has_card_statement(p_month_key,p_currency,v_group) then'
  ];
  v_forbidden_tables text[] := array[
    'home_card_statement_cycles',
    'home_card_statement_cycles',
    'home_card_statement_cycles',
    'home_card_statement_cycles|home_card_instruments'
  ];
  v_i integer;
  v_oid oid;
  v_definition text;
  v_occurrences integer;
  v_owner oid;
  v_security_definer boolean;
  v_config text[];
  v_acl aclitem[];
  v_after record;
begin
  if to_regprocedure('public.home_fixed_item_has_card_statement(uuid)') is null
     or to_regprocedure(
       'public.home_fixed_scope_has_card_statement(text,text,text)'
     ) is null
     or to_regprocedure(
       'public.home_fixed_advance_group_has_card_statement(text,text,text)'
     ) is null then
    raise exception 'CARD_STATEMENT_HELPERS_MISSING_BEFORE_WRITER_PATCH';
  end if;

  for v_i in 1..array_length(v_sigs, 1) loop
    v_oid := to_regprocedure(v_sigs[v_i]);
    if v_oid is null then
      raise exception 'CARD_STATEMENT_WRITER_MISSING: %', v_sigs[v_i];
    end if;

    select pg_get_functiondef(p.oid), p.proowner, p.prosecdef, p.proconfig, p.proacl
      into strict v_definition, v_owner, v_security_definer, v_config, v_acl
    from pg_proc p where p.oid = v_oid;

    if md5(v_definition) <> v_expected_md5[v_i] then
      raise exception
        'CARD_STATEMENT_WRITER_DEFINITION_DRIFT: % expected % got %',
        v_sigs[v_i], v_expected_md5[v_i], md5(v_definition);
    end if;
    if v_owner <> 'postgres'::regrole
       or v_security_definer
       or v_config is distinct from
          array['search_path=pg_catalog, public']::text[] then
      raise exception 'CARD_STATEMENT_WRITER_SECURITY_DRIFT: %', v_sigs[v_i];
    end if;

    v_occurrences := (
      length(v_definition) - length(replace(v_definition, v_old[v_i], ''))
    ) / length(v_old[v_i]);
    if v_occurrences <> 1 then
      raise exception
        'CARD_STATEMENT_WRITER_OLD_PREDICATE_COUNT: % count %',
        v_sigs[v_i], v_occurrences;
    end if;

    execute replace(v_definition, v_old[v_i], v_new[v_i]);

    select p.proowner, p.prosecdef, p.proconfig, p.proacl,
           pg_get_functiondef(p.oid) as definition
      into strict v_after
    from pg_proc p
    where p.oid = to_regprocedure(v_sigs[v_i]);

    if v_after.proowner is distinct from v_owner
       or v_after.prosecdef is distinct from v_security_definer
       or v_after.proconfig is distinct from v_config
       or v_after.proacl is distinct from v_acl then
      raise exception 'CARD_STATEMENT_WRITER_BOUNDARY_CHANGED: %', v_sigs[v_i];
    end if;
    if v_after.definition ~ v_forbidden_tables[v_i]
       or v_after.definition not like '%' || v_new[v_i] || '%' then
      raise exception 'CARD_STATEMENT_WRITER_PATCH_CONTRACT_FAILED: %', v_sigs[v_i];
    end if;
  end loop;
end
$patch$;

commit;
