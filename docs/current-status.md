# Current Status

Status date: 2026-06-13

This document keeps the current Cash System implementation checkpoint, safety notes, and active backlog.

## Current State

- Cash System is a static Supabase-backed household ledger using `home_` tables.
- Normal JPY/CNY account and transaction UI remains unchanged.
- External JPY transaction support for aozora school now covers the Phase 1 personal-business teacher wage linkage and has a Phase 2 guard extension prepared for personal-business tuition income.
- A school-side manual sync executor successfully called the Cash RPC, inserted one whitelisted external JPY test transaction, verified idempotent duplicate execution, then cleaned the Phase 1 test transaction/account residue.
- No school DB writes, background worker, or page/UI changes are implemented in this repository.

## Latest Update

2026-06-13 Phase 2 tuition income guard SQL checkpoint:

- Added incremental SQL file `supabase-update-20260613-external-jpy-2.sql`.
- This SQL has not been executed in this documentation checkpoint.
- It preserves existing Phase 1 support:
  - `external_reference_type = school_payment_requests`
  - `external_event_type = teacher_wage_payment_confirm` -> `transaction_type = expense`
  - `external_event_type = teacher_wage_payment_reverse` -> `transaction_type = income`
- It extends the allowed Cash RPC/constraint guard for Phase 2:
  - `external_reference_type = school_income_records`
  - `external_event_type = tuition_income_received`
  - `transaction_type = income`
  - JPY account only
  - positive amount only
- Idempotency keys, external source event uniqueness, duplicate return behavior, and payload mismatch behavior remain unchanged.
- The guard is intentionally narrow and does not allow arbitrary school events.

2026-06-13 external JPY transaction RPC and E2E checkpoint:

- Executed incremental SQL file `supabase-update-20260613-external-jpy-1.sql` against polariss710's Cash System.
- Added external/idempotency metadata columns to `home_jpy_transactions`:
  - `external_source`
  - `external_source_id`
  - `external_event_type`
  - `external_idempotency_key`
  - `external_reference_type`
  - `external_reference_id`
  - `external_note`
  - `external_payload_hash`
  - `external_created_at`
  - `created_by_external`
- Added partial unique indexes for external idempotency and external source event uniqueness.
- Added `home_jpy_transactions_external_required_check` for external rows.
- Added RPC `home_create_external_jpy_transaction(...)`.
- Verified schema/RPC existence after execution.
- Verified idempotency by rollback test: first call inserted a temporary external JPY expense, second call with the same idempotency key returned the same transaction id with `inserted=false`, count stayed 1 inside the transaction, and rollback residue was 0.
- School-side manual E2E sync later called `home_create_external_jpy_transaction(...)` successfully for whitelist test data:
  - Cash test account: `94000000-0000-4000-8000-000000150501`
  - school payment request: `94000000-0000-4000-8000-000000150101`
  - Cash JPY transaction: `fbd3e5df-14be-4b3b-9a0b-319f4416968b`
  - transaction type: `expense`
  - amount: `6789`
  - duplicate script run left Cash transaction count at 1.
- Phase 1 cleanup completed after verification:
  - target Cash JPY transaction count: 0
  - target Cash account count: 0
  - school-side target linkage/payment/mapping/business entity counts: 0
  - older school income-edit `codex-test` data was intentionally not touched.

## Boundaries

- No CNY external transaction support.
- No 青空塾, company account spending, reimbursement, non-`teacher_wage`, or part-time wage income linkage.
- Personal tuition income is only prepared as a Phase 2 JPY income guard in Cash SQL; the school-side implementation and DB execution remain separate future work.
- No FX support.
- No school DB writes.
- No cross-DB transaction.
- No automatic retry worker.
- No page/UI changes.
- No reversal sync.
- No change to ordinary JPY transaction create/update/delete paths.
- Do not run `supabase-schema.sql` for this update; it is an incremental migration checkpoint.

## Next Steps

- School project owns mapping/outbox and has a manual sync executor for Phase 1. Future work should add guarded retry/operator workflow only if needed.
- If reversal is wired, use a separate external event with `transaction_type = income`; do not delete the original Cash transaction.
- Any future Cash UI display for external rows should treat them as externally owned and avoid ordinary edit/delete unless a guarded edit/reversal design exists.
- Phase 2 next step is school-side implementation for personal-business tuition income -> Cash System JPY income transaction. Reuse external/idempotency/linkage event/outbox patterns, and continue to exclude 青空塾 and CNY.
