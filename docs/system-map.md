# System Map

Status date: 2026-06-13

## Core Tables

- `home_accounts`: account master data for JPY/CNY accounts.
- `home_payment_channels`: fixed item payment channel grouping, not a balance ledger.
- `home_jpy_transactions`: JPY ledger movements.
- `home_cny_transactions`: CNY ledger movements.
- `home_fixed_templates`: recurring fixed item templates.
- `home_fixed_month_items`: generated monthly fixed items.
- `home_external_transaction_requests`: Cash-owned pending request table for aozora school external transaction requests. Pending/rejected rows do not affect Cash balances.

## Core RPCs

- `home_get_jpy_account_page(text)`: reads JPY accounts, balances, and month transactions.
- `home_update_jpy_transaction(...)`: updates ordinary JPY transactions.
- `home_delete_jpy_transaction(uuid)`: deletes ordinary JPY transactions.
- `home_create_external_jpy_transaction(...)`: creates idempotent external-source JPY transactions for guarded aozora school linkages.
- `home_create_external_transaction_request(...)`: idempotently creates a pending external request. It does not create a transaction.
- `home_approve_external_transaction_request(uuid)`: approves a pending request and then calls `home_create_external_jpy_transaction(...)`.
- `home_reject_external_transaction_request(uuid, text)`: rejects a pending request without creating a transaction.
- `home_get_external_transaction_requests(text, integer)`: reads requests for the Cash approval UI.

## External JPY RPC Boundary

`home_create_external_jpy_transaction(...)` only writes `home_jpy_transactions`.

In the Cash linkage v2 target architecture, this RPC is not the first business
entry point. It should run only after a Cash user approves a pending external
request in the Cash System UI.

It does not write:

- `home_cny_transactions`
- `home_fixed_month_items`
- `home_fixed_templates`
- `home_payment_channels`
- any school table

It requires an active JPY `home_accounts` row and a positive amount.

Allowed school event families:

- `school_payment_requests` + `teacher_wage_payment_confirm` -> JPY `expense`
- `school_payment_requests` + `teacher_wage_payment_reverse` -> JPY `income`
- `school_income_records` + `tuition_income_received` -> JPY `income`

## Balance Rule

Balances remain read-time calculations from `opening_balance` plus transaction movements. The external JPY RPC only inserts a normal JPY `income` or `expense` row with external metadata; it does not store a cached account balance.

## Cross-Project Boundary

Cash System now has the DB/RPC primitive needed by the school project. The school project owns mapping/outbox state and the manual sync executor. Cash System receives idempotent RPC calls and stores external JPY rows with `created_by_external = true`.

The current school zsh sync executor is a verification/operations tool. The
target daily business flow is page-driven:

1. School page requests sync to Cash System.
2. Cash System creates a pending external transaction request.
3. Cash page approves or rejects.
4. Approval creates the Cash JPY transaction and changes Cash balance.
5. Rejection creates no transaction and leaves Cash balance unchanged.
6. School displays `synced/cash_confirmed` or `cash_rejected`.

Recommended bridge: Supabase Edge Function. The School browser should not
directly write the Cash project with Cash credentials, and the Cash frontend
should not directly read the School DB.

Cash-side v2 stage 1 implemented objects:

- Formal SQL file: `supabase-update-20260613-external-requests.sql`
- Request table: `home_external_transaction_requests`
- Create/approve/reject/read RPCs listed above
- UI view: `外部待确认`

Important boundary: this stage does not implement the School page request
button or the Edge Function bridge. Until that exists, the Cash page can approve
or reject requests already present in Cash DB, but the daily School-triggered
business flow is not complete.

Phase 1 completed scope:

- Personal-business school `teacher_wage` JPY payment only.
- School payment request -> linkage event / outbox -> sync executor -> Cash JPY transaction.
- Successful sync writes one Cash JPY `expense` and marks the school event `synced`.
- Cash RPC failure marks the school event `failed`.
- Duplicate sync execution is idempotent and does not create another Cash transaction.

Verified Phase 1 E2E test, later cleaned:

- Cash account: `94000000-0000-4000-8000-000000150501`
- Cash JPY transaction: `fbd3e5df-14be-4b3b-9a0b-319f4416968b`
- school payment request reference: `94000000-0000-4000-8000-000000150101`
- cleanup verification confirmed target Cash transaction/account counts are 0 and school target linkage/payment/mapping/business entity counts are 0.

Remaining out of Phase 1: 青空塾, 青空塾 teacher wages, 青空塾 reimbursements, company account spending, CNY, non-`teacher_wage`, personal tuition income, part-time wage income, reversal sync, automatic background retry, Cash UI changes for external rows, and cross-DB strong transactions.

Phase 2 Cash guard extension is prepared for personal-business tuition income -> Cash System JPY income transaction. It is limited to `school_income_records` + `tuition_income_received` and must create a positive JPY `income` transaction. It continues to exclude 青空塾, CNY, reimbursement, company account spending, and arbitrary school events.

Cash linkage v2 implementation order:

1. Cash DB: add pending external transaction request table and approve/reject RPCs. Implemented in code; DB apply pending.
2. Cash UI: add pending request list, detail, approve, reject, and approve confirmation. Implemented in code.
3. Edge Function: School request -> Cash pending request.
4. School DB/UI: extend payment linkage lifecycle and change personal JPY teacher wage action from direct confirmation to `请求同步到 Cash System`.
5. ROLLBACK whitelist tests.
6. COMMIT whitelist E2E approve/reject tests.
7. Decide whether to run the 2026-05 real two-row JPY teacher wage trial: one approve, one reject. Real data should not be cleaned up; whitelist test data should be cleaned up.
