# Module Status

Status date: 2026-06-13

| Module | Current State | Next Priority |
| --- | --- | --- |
| JPY accounts | Existing UI/RPC behavior unchanged | Keep ordinary account management stable |
| JPY transactions | Existing ordinary flows unchanged; external JPY DB/RPC insert support added for Phase 1 teacher wage, with Phase 2 tuition income guard SQL prepared | Future UI should display external rows as externally owned if needed |
| CNY transactions | Unchanged | No Phase 1 external support |
| Fixed templates/month items | Unchanged | Keep fixed-item linkage separate |
| FX linkage | Unchanged | Keep FX linkage separate |
| External school linkage | Phase 1 manual E2E sync completed for personal-business teacher wage JPY payment; test DB residue cleaned; Phase 2 tuition income Cash guard SQL prepared | School-side tuition income implementation, reversal sync, and retry UI require separate guarded phases |

## External JPY Transaction Support

Implemented through `supabase-update-20260613-external-jpy-1.sql`; Phase 2 tuition income guard extension is prepared in `supabase-update-20260613-external-jpy-2.sql`.

Allowed external events:

- `school_payment_requests` + `teacher_wage_payment_confirm` -> `transaction_type = expense`
- `school_payment_requests` + `teacher_wage_payment_reverse` -> `transaction_type = income`
- `school_income_records` + `tuition_income_received` -> `transaction_type = income`

Required source metadata:

- `external_source = aozora_school`
- `external_source_id`
- `external_event_type`
- `external_idempotency_key`
- `external_reference_type = school_payment_requests` for teacher wage payment events
- `external_reference_type = school_income_records` for tuition income events
- `external_reference_id`
- active JPY account
- positive amount

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

Phase 2 tuition income guard is narrow: only personal-business school income records may use `tuition_income_received`, it must create a JPY `income` transaction, and it must not be used for expense, CNY, 青空塾, reimbursement, company account, or arbitrary school events.

## Hard Stops

- Do not use `supabase-schema.sql` for incremental external linkage updates.
- Do not add CNY/school/cross-DB writes in this repository without a separate design.
- Do not execute the Phase 2 tuition income Cash SQL or add school-side tuition income linkage without the separate guarded implementation workflow.
- Do not delete existing transactions as a reversal mechanism.
- Do not change ordinary page modules for this DB/RPC-only checkpoint.
- Do not add automatic retry/background sync in Cash System; school owns the manual sync executor and outbox state.
