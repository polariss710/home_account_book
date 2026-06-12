# Current Status

Status date: 2026-06-13

This document keeps the current Cash System implementation checkpoint, safety notes, and active backlog.

## Current State

- Cash System is a static Supabase-backed household ledger using `home_` tables.
- Normal JPY/CNY account and transaction UI remains unchanged.
- Phase 1 external JPY transaction support for aozora school personal-business teacher wage linkage is now available at the DB/RPC layer only.
- No school DB writes or cross-project writes are implemented in this repository.

## Latest Update

2026-06-13 external JPY transaction RPC checkpoint:

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

## Boundaries

- No CNY external transaction support.
- No FX support.
- No school DB writes.
- No cross-DB transaction.
- No automatic retry worker.
- No page/UI changes.
- No change to ordinary JPY transaction create/update/delete paths.
- Do not run `supabase-schema.sql` for this update; it is an incremental migration checkpoint.

## Next Steps

- School project can later add mapping/outbox and call this Cash RPC from a server-side integration path.
- If reversal is wired, use a separate external event with `transaction_type = income`; do not delete the original Cash transaction.
- Any future Cash UI display for external rows should treat them as externally owned and avoid ordinary edit/delete unless a guarded edit/reversal design exists.
