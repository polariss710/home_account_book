-- supabase-update-20260615-part-time-work-income-approval.sql
-- Status: executed on Cash DB 2026-06-15.
-- Purpose:
-- - Extend approval-time external JPY/CNY transaction primitives so approved
--   external part-time work income requests can create Cash income rows.
-- - Does not approve/reject requests and does not create transactions.

begin;

do $$
declare
  v_signature regprocedure;
  v_original text;
  v_definition text;
  v_reference_guard_old text := 'if v_external_reference_type not in (''school_payment_requests'', ''school_income_records'') then';
  v_reference_guard_new text := 'if v_external_reference_type not in (''school_payment_requests'', ''school_income_records'', ''school_part_time_work_income_requests'') then';
  v_income_branch_old text := '  elsif v_external_event_type in (''tuition_income_received'', ''income_received'') then
    if v_external_reference_type <> ''school_income_records'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''income received requests must reference school_income_records and create income'');
    end if;
  else';
  v_income_branch_new text := '  elsif v_external_event_type in (''tuition_income_received'', ''income_received'') then
    if v_external_reference_type <> ''school_income_records'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''income received requests must reference school_income_records and create income'');
    end if;
  elsif v_external_event_type = ''part_time_work_income_received'' then
    if v_external_reference_type <> ''school_part_time_work_income_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''part_time_work_income_received must reference school_part_time_work_income_requests and create income'');
    end if;
  else';
begin
  foreach v_signature in array array[
    'public.home_create_external_jpy_transaction(uuid, uuid, text, date, numeric, text, text, text, uuid, text, text, text, uuid, text, text)'::regprocedure,
    'public.home_create_external_cny_transaction(uuid, uuid, text, date, numeric, text, text, text, uuid, text, text, text, uuid, text, text)'::regprocedure
  ]
  loop
    select pg_get_functiondef(v_signature) into v_original;
    v_definition := v_original;

    if position('school_part_time_work_income_requests' in v_definition) = 0 then
      v_definition := replace(v_definition, v_reference_guard_old, v_reference_guard_new);
      v_definition := replace(v_definition, v_income_branch_old, v_income_branch_new);

      if v_definition = v_original then
        raise exception 'Could not patch function definition: %', v_signature::text;
      end if;

      if position('school_part_time_work_income_requests' in v_definition) = 0
         or position('part_time_work_income_received' in v_definition) = 0 then
        raise exception 'Patched function definition is missing part-time work support: %', v_signature::text;
      end if;

      execute v_definition;
    end if;
  end loop;
end $$;

comment on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) is
  'Creates one idempotent external-source JPY transaction for aozora school requests after Cash approval. Supports teacher wage, ordinary income, and external part-time work income requests.';

comment on function public.home_create_external_cny_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) is
  'Creates one idempotent external-source CNY transaction for aozora school requests after Cash approval. Supports teacher wage, ordinary income, and external part-time work income requests.';

revoke all on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) from public;

revoke all on function public.home_create_external_cny_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) from public;

grant execute on function public.home_create_external_jpy_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) to authenticated, service_role;

grant execute on function public.home_create_external_cny_transaction(
  uuid,
  uuid,
  text,
  date,
  numeric,
  text,
  text,
  text,
  uuid,
  text,
  text,
  text,
  uuid,
  text,
  text
) to authenticated, service_role;

commit;
