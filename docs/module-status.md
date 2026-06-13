# Module Status

Status date: 2026-06-13

| Module | Current State | Next Priority |
| --- | --- | --- |
| JPY accounts | Existing UI/RPC behavior unchanged | Keep ordinary account management stable |
| JPY transactions | Existing ordinary flows unchanged; external JPY DB/RPC insert support added; E2E test transaction created, idempotency-verified, then cleaned | Future UI should display external rows as externally owned if needed |
| CNY transactions | Unchanged | No Phase 1 external support |
| Fixed templates/month items | Unchanged | Keep fixed-item linkage separate |
| FX linkage | Unchanged | Keep FX linkage separate |
| External school linkage | Phase 1 manual E2E sync completed for personal-business teacher wage JPY payment; test DB residue cleaned | Reversal sync / retry UI require separate guarded phases; personal tuition income is a Phase 2 design candidate |

## External JPY Transaction Support

Implemented through `supabase-update-20260613-external-jpy-1.sql`.

Allowed external events:

- `teacher_wage_payment_confirm` -> `transaction_type = expense`
- `teacher_wage_payment_reverse` -> `transaction_type = income`

Required source metadata:

- `external_source = aozora_school`
- `external_source_id`
- `external_event_type`
- `external_idempotency_key`
- `external_reference_type = school_payment_requests`
- `external_reference_id`

Idempotency:

- Duplicate `external_idempotency_key` returns the existing transaction when payload matches.
- Duplicate external source event returns the existing transaction when payload matches.
- Payload mismatch returns an error object and does not create a new row.

Verified E2E test row, later cleaned:

- Cash test account: `94000000-0000-4000-8000-000000150501`
- school payment request: `94000000-0000-4000-8000-000000150101`
- Cash JPY transaction: `fbd3e5df-14be-4b3b-9a0b-319f4416968b`
- `transaction_type = expense`
- `amount = 6789`
- duplicate school sync run left transaction count at 1.
- cleanup verification later confirmed the target Cash transaction/account counts are 0, and school target linkage/payment/mapping/business entity counts are 0.

Phase 1 does not link 青空塾, 青空塾 teacher wages, 青空塾 reimbursements, company account spending, CNY, non-`teacher_wage`, personal tuition income, or part-time wage income.

Phase 2 candidate: personal-business tuition income -> Cash System JPY income transaction. Design first, reuse external/idempotency/linkage event/outbox patterns, and continue to exclude 青空塾 and CNY.

## Hard Stops

- Do not use `supabase-schema.sql` for incremental external linkage updates.
- Do not add CNY/school/cross-DB writes in this repository without a separate design.
- Do not add personal tuition income linkage without a Phase 2 design.
- Do not delete existing transactions as a reversal mechanism.
- Do not change ordinary page modules for this DB/RPC-only checkpoint.
- Do not add automatic retry/background sync in Cash System; school owns the manual sync executor and outbox state.
