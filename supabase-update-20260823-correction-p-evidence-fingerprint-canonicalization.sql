create or replace function public.home_correction_p_evidence_fingerprint_v1(
  p_evidence_id uuid,
  p_home_correction_id uuid,
  p_operation_id uuid,
  p_correction_type text,
  p_original_home_request_id uuid,
  p_original_home_transaction_id uuid,
  p_home_balance_effect_id uuid,
  p_replacement_request_id uuid,
  p_replacement_fixed_item_id uuid,
  p_replacement_projection_id uuid,
  p_school_expense_id uuid,
  p_school_attempt_id uuid,
  p_amount numeric,
  p_currency text,
  p_charge_date date,
  p_accounting_scope text,
  p_external_event_id uuid,
  p_original_idempotency_key text,
  p_school_fingerprint text,
  p_home_payload_hash text,
  p_replacement_fingerprint text,
  p_actor_id uuid,
  p_finalized_at timestamptz
)
returns text
language sql
immutable
parallel safe
set search_path = pg_catalog, public
as $$
  select encode(extensions.digest(convert_to(jsonb_build_object(
    'evidence_id',p_evidence_id,
    'home_correction_id',p_home_correction_id,
    'operation_id',p_operation_id,
    'correction_type',p_correction_type,
    'original_home_request_id',p_original_home_request_id,
    'original_home_transaction_id',p_original_home_transaction_id,
    'home_balance_effect_id',p_home_balance_effect_id,
    'replacement_request_id',p_replacement_request_id,
    'replacement_fixed_item_id',p_replacement_fixed_item_id,
    'replacement_projection_id',p_replacement_projection_id,
    'school_expense_id',p_school_expense_id,
    'school_attempt_id',p_school_attempt_id,
    'amount',trim_scale(p_amount)::text,
    'currency',p_currency,
    'charge_date',p_charge_date::text,
    'accounting_scope',p_accounting_scope,
    'external_event_id',p_external_event_id,
    'original_idempotency_key',p_original_idempotency_key,
    'school_fingerprint',p_school_fingerprint,
    'home_payload_hash',p_home_payload_hash,
    'replacement_fingerprint',p_replacement_fingerprint,
    'actor_id',p_actor_id,
    'finalized_at_utc',to_char(p_finalized_at at time zone 'UTC','YYYY-MM-DD"T"HH24:MI:SS.US"Z"')
  )::text,'UTF8'),'sha256'),'hex');
$$;
