# Module Status

Status date: 2026-06-13

| Module | Current State | Next Priority |
| --- | --- | --- |
| JPY accounts | Existing UI/RPC behavior unchanged | Keep ordinary account management stable |
| JPY transactions | Existing ordinary flows unchanged; external JPY DB/RPC insert support added | Future UI should display external rows as externally owned if needed |
| CNY transactions | Unchanged | No Phase 1 external support |
| Fixed templates/month items | Unchanged | Keep fixed-item linkage separate |
| FX linkage | Unchanged | Keep FX linkage separate |
| External school linkage | DB/RPC support complete for idempotent JPY insert only | Wait for school-side mapping/outbox and server-side integration |

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

## Hard Stops

- Do not use `supabase-schema.sql` for incremental external linkage updates.
- Do not add CNY/school/cross-DB writes in this repository without a separate design.
- Do not delete existing transactions as a reversal mechanism.
- Do not change ordinary page modules for this DB/RPC-only checkpoint.
