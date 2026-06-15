-- supabase-update-20260616-canonical-external-request-types.sql
-- Status: executed on Cash DB 2026-06-16.
-- Purpose:
-- - Restrict new Cash external request creation to canonical School income and
--   expense records.
-- - Preserve historical legacy request rows for read-only audit.
-- - Restrict approval-time JPY/CNY transaction primitives to canonical
--   external transaction families.
-- - Does not delete requests or transactions and does not approve/reject data.

begin;

alter table public.home_external_transaction_requests
  drop constraint if exists home_external_transaction_requests_reference_check,
  add constraint home_external_transaction_requests_reference_check
    check (
      (
        external_reference_type = 'school_income_records'
        and request_type in ('tuition_income_received', 'income_received')
        and transaction_type = 'income'
      )
      or (
        external_reference_type = 'school_expense_records'
        and request_type = 'expense_paid'
        and transaction_type = 'expense'
      )
      or (
        status <> 'pending'
        and (
          (
            external_reference_type = 'school_payment_requests'
            and request_type in (
              'teacher_wage_payment_confirm',
              'teacher_wage_payment_reverse'
            )
          )
          or (
            external_reference_type = 'school_part_time_work_income_requests'
            and request_type = 'part_time_work_income_received'
          )
        )
      )
    );

alter table public.home_jpy_transactions
  drop constraint if exists home_jpy_transactions_external_required_check,
  add constraint home_jpy_transactions_external_required_check
    check (
      created_by_external is not true
      or (
        external_source = 'aozora_school'
        and external_source_id is not null
        and external_idempotency_key is not null
        and external_reference_id is not null
        and currency = 'JPY'
        and amount > 0
        and transfer_account_id is null
        and linked_fixed_month_item_id is null
        and linked_cny_transaction_id is null
        and (
          (
            external_reference_type = 'school_income_records'
            and external_event_type in ('tuition_income_received', 'income_received')
            and transaction_type = 'income'
          )
          or (
            external_reference_type = 'school_expense_records'
            and external_event_type = 'expense_paid'
            and transaction_type = 'expense'
          )
        )
      )
    );

alter table public.home_cny_transactions
  drop constraint if exists home_cny_transactions_external_required_check,
  add constraint home_cny_transactions_external_required_check
    check (
      created_by_external is not true
      or (
        external_source = 'aozora_school'
        and external_source_id is not null
        and external_idempotency_key is not null
        and external_reference_id is not null
        and currency = 'CNY'
        and amount > 0
        and transfer_account_id is null
        and linked_fixed_month_item_id is null
        and linked_jpy_transaction_id is null
        and (
          (
            external_reference_type = 'school_income_records'
            and external_event_type in ('tuition_income_received', 'income_received')
            and transaction_type = 'income'
          )
          or (
            external_reference_type = 'school_expense_records'
            and external_event_type = 'expense_paid'
            and transaction_type = 'expense'
          )
        )
      )
    );

do $$
declare
  v_original text;
  v_definition text;
  v_old_guard_block text := '  if v_external_reference_type not in (
    ''school_payment_requests'',
    ''school_income_records'',
    ''school_part_time_work_income_requests'',
    ''school_expense_records''
  ) then
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported external_reference_type'');
  end if;

  if v_request_type = ''teacher_wage_payment_confirm'' then
    if v_external_reference_type <> ''school_payment_requests'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''teacher_wage_payment_confirm must reference school_payment_requests and create expense'');
    end if;
  elsif v_request_type = ''teacher_wage_payment_reverse'' then
    if v_external_reference_type <> ''school_payment_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''teacher_wage_payment_reverse must reference school_payment_requests and create income'');
    end if;
  elsif v_request_type in (''tuition_income_received'', ''income_received'') then
    if v_external_reference_type <> ''school_income_records'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''income received requests must reference school_income_records and create income'');
    end if;
  elsif v_request_type = ''part_time_work_income_received'' then
    if v_external_reference_type <> ''school_part_time_work_income_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''part_time_work_income_received must reference school_part_time_work_income_requests and create income'');
    end if;
  elsif v_request_type = ''expense_paid'' then
    if v_external_reference_type <> ''school_expense_records'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''expense_paid must reference school_expense_records and create expense'');
    end if;
  else
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported request_type'');
  end if;';
  v_new_guard_block text := '  if v_external_reference_type in (
    ''school_payment_requests'',
    ''school_part_time_work_income_requests''
  )
     or v_request_type in (
       ''teacher_wage_payment_confirm'',
       ''teacher_wage_payment_reverse'',
       ''part_time_work_income_received''
     ) then
    return jsonb_build_object(
      ''ok'', false,
      ''message'', ''legacy business module direct Cash requests are deprecated; use school_income_records or school_expense_records''
    );
  end if;

  if v_external_reference_type not in (
    ''school_income_records'',
    ''school_expense_records''
  ) then
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported external_reference_type'');
  end if;

  if v_request_type in (''tuition_income_received'', ''income_received'') then
    if v_external_reference_type <> ''school_income_records'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''income received requests must reference school_income_records and create income'');
    end if;
  elsif v_request_type = ''expense_paid'' then
    if v_external_reference_type <> ''school_expense_records'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''expense_paid must reference school_expense_records and create expense'');
    end if;
  else
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported request_type'');
  end if;';
begin
  select pg_get_functiondef(
    'public.home_create_external_transaction_request(uuid, uuid, text, uuid, text, uuid, text, text, date, numeric, text, text, text, jsonb, text)'::regprocedure
  )
    into v_original;

  v_definition := replace(v_original, v_old_guard_block, v_new_guard_block);

  if v_definition = v_original then
    raise exception 'Could not patch home_create_external_transaction_request guard.';
  end if;

  if position('legacy business module direct Cash requests are deprecated' in v_definition) = 0
     or position('school_part_time_work_income_requests'', ''school_expense_records' in v_definition) > 0 then
    raise exception 'Patched home_create_external_transaction_request guard failed validation.';
  end if;

  execute v_definition;
end $$;

do $$
declare
  v_signature regprocedure;
  v_original text;
  v_definition text;
  v_reference_guard_old text := '  if v_external_reference_type not in (''school_payment_requests'', ''school_income_records'', ''school_part_time_work_income_requests'', ''school_expense_records'') then
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported external_reference_type'');
  end if;';
  v_reference_guard_new text := '  if v_external_reference_type in (
    ''school_payment_requests'',
    ''school_part_time_work_income_requests''
  ) then
    return jsonb_build_object(
      ''ok'', false,
      ''message'', ''legacy business module direct Cash requests are deprecated; use school_income_records or school_expense_records''
    );
  end if;

  if v_external_reference_type not in (''school_income_records'', ''school_expense_records'') then
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported external_reference_type'');
  end if;';
  v_event_guard_old text := '  if v_external_event_type = ''teacher_wage_payment_confirm'' then
    if v_external_reference_type <> ''school_payment_requests'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''teacher_wage_payment_confirm must reference school_payment_requests and create expense'');
    end if;
  elsif v_external_event_type = ''teacher_wage_payment_reverse'' then
    if v_external_reference_type <> ''school_payment_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''teacher_wage_payment_reverse must reference school_payment_requests and create income'');
    end if;
  elsif v_external_event_type in (''tuition_income_received'', ''income_received'') then
    if v_external_reference_type <> ''school_income_records'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''income received requests must reference school_income_records and create income'');
    end if;
  elsif v_external_event_type = ''part_time_work_income_received'' then
    if v_external_reference_type <> ''school_part_time_work_income_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''part_time_work_income_received must reference school_part_time_work_income_requests and create income'');
    end if;
  elsif v_external_event_type = ''expense_paid'' then
    if v_external_reference_type <> ''school_expense_records'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''expense_paid must reference school_expense_records and create expense'');
    end if;
  else
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported external_event_type'');
  end if;';
  v_event_guard_new text := '  if v_external_event_type in (
    ''teacher_wage_payment_confirm'',
    ''teacher_wage_payment_reverse'',
    ''part_time_work_income_received''
  ) then
    return jsonb_build_object(
      ''ok'', false,
      ''message'', ''legacy business module direct Cash requests are deprecated; use school_income_records or school_expense_records''
    );
  end if;

  if v_external_event_type in (''tuition_income_received'', ''income_received'') then
    if v_external_reference_type <> ''school_income_records'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''income received requests must reference school_income_records and create income'');
    end if;
  elsif v_external_event_type = ''expense_paid'' then
    if v_external_reference_type <> ''school_expense_records'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''expense_paid must reference school_expense_records and create expense'');
    end if;
  else
    return jsonb_build_object(''ok'', false, ''message'', ''unsupported external_event_type'');
  end if;';
begin
  foreach v_signature in array array[
    'public.home_create_external_jpy_transaction(uuid, uuid, text, date, numeric, text, text, text, uuid, text, text, text, uuid, text, text)'::regprocedure,
    'public.home_create_external_cny_transaction(uuid, uuid, text, date, numeric, text, text, text, uuid, text, text, text, uuid, text, text)'::regprocedure
  ]
  loop
    select pg_get_functiondef(v_signature) into v_original;
    v_definition := replace(v_original, v_reference_guard_old, v_reference_guard_new);
    v_definition := replace(v_definition, v_event_guard_old, v_event_guard_new);

    if v_definition = v_original then
      raise exception 'Could not patch transaction primitive guard: %', v_signature::text;
    end if;

    if position('legacy business module direct Cash requests are deprecated' in v_definition) = 0
       or position('school_part_time_work_income_requests'', ''school_expense_records' in v_definition) > 0 then
      raise exception 'Patched transaction primitive guard failed validation: %', v_signature::text;
    end if;

    execute v_definition;
  end loop;
end $$;

comment on function public.home_create_external_transaction_request(
  uuid,
  uuid,
  text,
  uuid,
  text,
  uuid,
  text,
  text,
  date,
  numeric,
  text,
  text,
  text,
  jsonb,
  text
) is
  'Creates Cash pending external requests for canonical aozora school income and expense records only. Legacy business-module direct request families are deprecated and retained only for historical reads.';

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
  'Creates one idempotent external-source JPY transaction for canonical aozora school income and expense record requests after Cash approval.';

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
  'Creates one idempotent external-source CNY transaction for canonical aozora school income and expense record requests after Cash approval.';

revoke all on function public.home_create_external_transaction_request(
  uuid,
  uuid,
  text,
  uuid,
  text,
  uuid,
  text,
  text,
  date,
  numeric,
  text,
  text,
  text,
  jsonb,
  text
) from public;

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

grant execute on function public.home_create_external_transaction_request(
  uuid,
  uuid,
  text,
  uuid,
  text,
  uuid,
  text,
  text,
  date,
  numeric,
  text,
  text,
  text,
  jsonb,
  text
) to authenticated, service_role;

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
