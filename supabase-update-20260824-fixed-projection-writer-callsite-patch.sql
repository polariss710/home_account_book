\set ON_ERROR_STOP on

-- Home / Cash：固定项 projection helper 四处生产 writer 调用点补丁
--
-- 本文件不照抄仓库旧 SQL。它以 2026-08-24 生产 pg_get_functiondef 为输入，
-- 先核对确切签名与定义 MD5，再对每个定义做一次且仅一次的谓词替换。
-- 任一 hash、旧片段、owner、security、search_path 或 ACL 漂移均中止整个事务。

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
    'd963fb21c7ce29035b3cb30ec7055bb5',
    'af4492d1daffe4fec4e87890b38c143e',
    '0860e558a3dad057e97b8a0063c66955',
    'dd0769a1f99dc0fcc5fa2923aeff0fb1'
  ];
  v_old text[] := array[
    'if exists(select 1 from public.home_external_fixed_payment_projections p where p.fixed_month_item_id=v_item.id) then',
    'if exists(select 1 from public.home_external_fixed_payment_projections p join public.home_fixed_month_items i on i.id=p.fixed_month_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=p_direction) then',
    'if exists(select 1 from public.home_external_fixed_payment_projections p join public.home_fixed_month_items i on i.id=p.fixed_month_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency) then',
    'if exists(select 1 from public.home_external_fixed_payment_projections p join public.home_fixed_month_items i on i.id=p.fixed_month_item_id where i.user_id=auth.uid() and i.month_key=p_month_key and i.currency=p_currency and i.direction=''expense'' and coalesce(i.payment_group,''未分组'')=v_group) then'
  ];
  v_new text[] := array[
    'if public.home_fixed_item_has_external_projection(v_item.id) then',
    'if public.home_fixed_scope_has_external_projection(p_month_key,p_currency,p_direction) then',
    'if public.home_fixed_scope_has_external_projection(p_month_key,p_currency) then',
    'if public.home_fixed_scope_has_external_projection(p_month_key,p_currency,''expense'',v_group) then'
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
  if to_regprocedure('public.home_fixed_item_has_external_projection(uuid)') is null
     or to_regprocedure(
       'public.home_fixed_scope_has_external_projection(text,text,text,text)'
     ) is null then
    raise exception 'FIXED_PROJECTION_HELPER_MISSING_BEFORE_WRITER_PATCH';
  end if;

  for v_i in 1..array_length(v_sigs, 1) loop
    v_oid := to_regprocedure(v_sigs[v_i]);
    if v_oid is null then
      raise exception 'FIXED_PROJECTION_WRITER_MISSING: %', v_sigs[v_i];
    end if;

    select pg_get_functiondef(p.oid), p.proowner, p.prosecdef, p.proconfig, p.proacl
      into strict v_definition, v_owner, v_security_definer, v_config, v_acl
    from pg_proc p
    where p.oid = v_oid;

    if md5(v_definition) <> v_expected_md5[v_i] then
      raise exception
        'FIXED_PROJECTION_WRITER_DEFINITION_DRIFT: % expected % got %',
        v_sigs[v_i], v_expected_md5[v_i], md5(v_definition);
    end if;
    if v_owner <> 'postgres'::regrole
       or v_security_definer
       or v_config is distinct from array['search_path=pg_catalog, public']::text[] then
      raise exception 'FIXED_PROJECTION_WRITER_SECURITY_DRIFT: %', v_sigs[v_i];
    end if;

    v_occurrences := (
      length(v_definition) - length(replace(v_definition, v_old[v_i], ''))
    ) / length(v_old[v_i]);
    if v_occurrences <> 1 then
      raise exception
        'FIXED_PROJECTION_WRITER_OLD_PREDICATE_COUNT: % count %',
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
      raise exception 'FIXED_PROJECTION_WRITER_BOUNDARY_CHANGED: %', v_sigs[v_i];
    end if;
    if v_after.definition like '%home_external_fixed_payment_projections%'
       or v_after.definition not like '%' || v_new[v_i] || '%' then
      raise exception 'FIXED_PROJECTION_WRITER_PATCH_CONTRACT_FAILED: %', v_sigs[v_i];
    end if;
  end loop;
end
$patch$;

commit;
