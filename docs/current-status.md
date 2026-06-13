# Current Status

Status date: 2026-06-13

This document keeps the current Cash System implementation checkpoint, safety notes, and active backlog.

## Current State

- Cash System is a static Supabase-backed household ledger using `home_` tables.
- Normal JPY/CNY account and transaction UI remains unchanged.
- External JPY transaction support for aozora school now covers Phase 1 personal-business teacher wage payments and Phase 2 personal-business tuition JPY income.
- A school-side manual sync executor successfully called the Cash RPC for both supported flows, verified idempotent duplicate execution, and later cleaned the whitelist test transaction/account residue.
- The manual sync executor is now classified as a verification/operations tool, not the final daily business entry point.
- Cash linkage v2 target is page-driven confirmation embedded in the real School business pages: the School income record page selects a Cash 收款账户 for personal tuition JPY income, and the School teacher wage payment page selects a Cash 支付账户 for personal teacher_wage JPY payment. Cash System keeps the separate `外部待确认` page as the ledger-side approve/reject entry, and only approval creates a Cash transaction and changes Cash balance.
- Cash-side pending request table, create/approve/reject RPCs, and Cash approval UI are implemented in this repository.
- No school DB writes, School-side Edge Function deployment, School embedded income/payment page action, background worker, or automatic scheduler is implemented in this repository.

## Latest Update

2026-06-13 Cash linkage v2 stage 1 implementation:

- Added formal SQL file `supabase-update-20260613-external-requests.sql`.
- Added Cash-owned table `home_external_transaction_requests` for aozora school external transaction requests.
- Added RPCs:
  - `home_create_external_transaction_request(...)`
  - `home_approve_external_transaction_request(uuid)`
  - `home_reject_external_transaction_request(uuid, text)`
  - `home_get_external_transaction_requests(text, integer)`
- Added Cash UI page `外部待确认` for request list, filtering, approve, and reject.
- Pending requests do not create `home_jpy_transactions` and do not change balances.
- Approve is the only path that calls existing `home_create_external_jpy_transaction(...)`; idempotent duplicate behavior remains owned by that RPC.
- Reject records `rejected` state/reason and does not create a transaction or change balance.
- Supported request families remain narrow:
  - `school_payment_requests` + `teacher_wage_payment_confirm` -> JPY `expense`
  - `school_payment_requests` + `teacher_wage_payment_reverse` -> JPY `income`
  - `school_income_records` + `tuition_income_received` -> JPY `income`
- School -> Cash request entry belongs inside the School income/payment business pages, not a standalone School sync page. The intended bridge is still a Supabase Edge Function behind those business actions, not direct School-browser writes to Cash DB.
- This checkpoint adds code/SQL/docs; the SQL was applied and rollback-verified in a later guarded DB apply phase.

2026-06-13 Cash linkage v2 UI/business direction correction:

- Corrected the product direction for School-originated requests:
  - personal-business tuition JPY income starts from the School income record page with a Cash 收款账户 selection
  - personal-business teacher_wage JPY payment starts from the School teacher wage payment page with a Cash 支付账户 selection
  - School should not add a separate sync entry for ordinary users
  - School should use business labels such as `提交到 Cash 确认`, `Cash待确认`, `Cash已确认`, and `Cash已拒绝`
- Cash System still owns the separate `外部待确认` page. This is the ledger-side confirmation entry where the Cash user approves or rejects.
- Approve remains the only path that creates a Cash transaction and affects balances.
- Reject still creates no transaction and does not affect balances.
- The zsh/manual sync path remains a verification/operations tool only.

2026-06-13 Cash linkage v2 direction checkpoint:

- Documented the target external school linkage flow:
  - School income/payment business page submits a Cash confirmation request after the user selects the Cash 收款账户 / 支付账户.
  - Cash System stores a pending external transaction request.
  - Cash page displays pending requests and allows approve/reject.
  - Approve calls existing `home_create_external_jpy_transaction(...)`, creates the JPY transaction, and changes Cash balance.
  - Reject stores rejection state/reason and creates no transaction.
- The existing `home_create_external_jpy_transaction(...)` remains the idempotent transaction creation primitive, but should be called by the Cash approval flow, not directly by the School daily business page.
- Recommended next architecture:
  - add `home_external_transaction_requests` or equivalent
  - add approve/reject RPCs
  - add Cash pending request list/detail UI
  - use a Supabase Edge Function as the backend bridge behind School income/payment business actions
- Do not let the School browser directly write the Cash DB with Cash anon credentials.
- Do not make the Cash frontend directly read the School DB.
- Continue excluding 青空塾, CNY, non-target linkage, reimbursement, company account spending, and arbitrary school events.

2026-06-13 Phase 2 tuition income E2E checkpoint:

- Executed incremental SQL file `supabase-update-20260613-external-jpy-2.sql`.
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
- School-side COMMIT E2E sync successfully created one Cash JPY income transaction:
  - Cash test account: `95000000-0000-4000-8000-000000160501`
  - school income record: `484e9ecf-e48d-4f8a-8812-3b32fdef0df6`
  - school income linkage event: `36a6108f-e638-4107-9a1f-0023de536bd7`
  - Cash JPY transaction: `2430846f-e8d2-4e31-b9c6-6fb05279dbc5`
  - transaction type: `income`
  - amount: `6789`
  - duplicate school sync run left Cash transaction count at 1.
- Phase 2 cleanup completed after verification:
  - target Cash JPY transaction count: 0
  - target Cash account count: 0
  - target Cash external event/reference counts: 0
  - `home_cny_transactions` marker count: 0
  - school-side target business/student/mapping/income/event counts: 0

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
- Personal tuition income support is limited to personal-business `tuition` JPY income through the school outbox and manual sync executor.
- Cash pending external transaction request table/RPC/UI has been applied and rollback-verified; full School page embedded approve/reject E2E remains pending.
- No FX support.
- No school DB writes.
- No Edge Function bridge from School to Cash request creation.
- No School income/payment page embedded request action yet.
- No cross-DB transaction.
- No automatic retry worker.
- No School-originated income/payment page action or Edge Function request bridge yet.
- No reversal sync.
- No change to ordinary JPY transaction create/update/delete paths.
- Do not run `supabase-schema.sql` for this update; it is an incremental migration checkpoint.

## Next Steps

- School project owns mapping/outbox and has a manual sync executor for Phase 1. Future work should add guarded retry/operator workflow only if needed.
- `supabase-update-20260613-external-requests.sql` has been applied and rollback-verified; full embedded School page E2E remains pending.
- Next implementation phase should add or deploy the Supabase Edge Function bridge behind School income/payment business submissions.
- Then update the School income record and teacher wage payment page flows so personal-business JPY tuition income / teacher wage payment create Cash pending requests through embedded 收款账户 / 支付账户 selection instead of exposing a standalone sync entry.
- If reversal is wired, use a separate external event with `transaction_type = income`; do not delete the original Cash transaction.
- Any future Cash UI display for external rows should treat them as externally owned and avoid ordinary edit/delete unless a guarded edit/reversal design exists.
- For the planned 2026-05 teacher wage trial, first read-only confirm the two pending personal-business `teacher_wage` JPY candidates, then use one approve test and one reject test after the pending request flow exists. Real data should not be cleaned up; whitelist test data still requires cleanup.
