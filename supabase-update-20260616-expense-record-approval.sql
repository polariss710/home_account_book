-- supabase-update-20260616-expense-record-approval.sql
-- Status: executed on Cash DB 2026-06-16.
-- Purpose:
-- - Extend approval-time external JPY/CNY transaction primitives so approved
--   canonical School expense record requests can create Cash expense rows.
-- - Extend external-created JPY/CNY transaction table guards for the same
--   canonical expense request family.
-- - Scope is limited to:
--   external_reference_type = school_expense_records
--   request_type = expense_paid
--   transaction_type = expense
-- - Does not remove legacy request families and does not create transactions.

begin;

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
            external_reference_type = 'school_payment_requests'
            and external_event_type = 'teacher_wage_payment_confirm'
            and transaction_type = 'expense'
          )
          or (
            external_reference_type = 'school_payment_requests'
            and external_event_type = 'teacher_wage_payment_reverse'
            and transaction_type = 'income'
          )
          or (
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
            external_reference_type = 'school_payment_requests'
            and external_event_type = 'teacher_wage_payment_confirm'
            and transaction_type = 'expense'
          )
          or (
            external_reference_type = 'school_payment_requests'
            and external_event_type = 'teacher_wage_payment_reverse'
            and transaction_type = 'income'
          )
          or (
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
  v_signature regprocedure;
  v_original text;
  v_definition text;
  v_reference_guard_old text := 'if v_external_reference_type not in (''school_payment_requests'', ''school_income_records'', ''school_part_time_work_income_requests'') then';
  v_reference_guard_new text := 'if v_external_reference_type not in (''school_payment_requests'', ''school_income_records'', ''school_part_time_work_income_requests'', ''school_expense_records'') then';
  v_part_time_branch_old text := '  elsif v_external_event_type = ''part_time_work_income_received'' then
    if v_external_reference_type <> ''school_part_time_work_income_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''part_time_work_income_received must reference school_part_time_work_income_requests and create income'');
    end if;
  else';
  v_part_time_branch_new text := '  elsif v_external_event_type = ''part_time_work_income_received'' then
    if v_external_reference_type <> ''school_part_time_work_income_requests'' or v_transaction_type <> ''income'' then
      return jsonb_build_object(''ok'', false, ''message'', ''part_time_work_income_received must reference school_part_time_work_income_requests and create income'');
    end if;
  elsif v_external_event_type = ''expense_paid'' then
    if v_external_reference_type <> ''school_expense_records'' or v_transaction_type <> ''expense'' then
      return jsonb_build_object(''ok'', false, ''message'', ''expense_paid must reference school_expense_records and create expense'');
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

    if position('school_expense_records' in v_definition) = 0 then
      v_definition := replace(v_definition, v_reference_guard_old, v_reference_guard_new);
      v_definition := replace(v_definition, v_part_time_branch_old, v_part_time_branch_new);

      if v_definition = v_original then
        raise exception 'Could not patch function definition: %', v_signature::text;
      end if;

      if position('school_expense_records' in v_definition) = 0
         or position('expense_paid' in v_definition) = 0 then
        raise exception 'Patched function definition is missing expense record support: %', v_signature::text;
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
  'Creates one idempotent external-source JPY transaction for aozora school requests after Cash approval. Supports teacher wage legacy, ordinary income, external part-time work income legacy, and canonical expense record requests.';

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
  'Creates one idempotent external-source CNY transaction for aozora school requests after Cash approval. Supports teacher wage legacy, ordinary income, external part-time work income legacy, and canonical expense record requests.';

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
