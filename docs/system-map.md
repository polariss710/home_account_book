# System Map

Status date: 2026-06-14

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

Currently allowed school event families:

- `school_payment_requests` + `teacher_wage_payment_confirm` -> JPY `expense`
- `school_payment_requests` + `teacher_wage_payment_reverse` -> JPY `income`
- `school_income_records` + `tuition_income_received` -> JPY `income`

This is current implementation scope only. The corrected 2026-06-14 business
policy is broader: any School-related money movement that actually passes
through a user-controlled account should enter Cash, including 青空塾 and
CNY/RMB movements. Current JPY-only guards must be broadened in later guarded
phases.

## Balance Rule

Balances remain read-time calculations from `opening_balance` plus transaction movements. The external JPY RPC only inserts a normal JPY `income` or `expense` row with external metadata; it does not store a cached account balance.

## Cross-Project Boundary

School System is the business ledger. It records operating facts: tuition
income, teacher wages, student/teacher/month, personal vs 青空塾 ownership, cost
attribution, corporate-account clearing records, and company expense records.

Cash System remains the user's household/private account ledger. Because many
school receipts and payments actually pass through user-controlled accounts,
Cash records those real account movements: Alipay, JPY cash, Mitsubishi/Rakuten
and other JPY accounts, RMB accounts, actual receipts, actual payments,
CNY/JPY allocation, transfer to corporate accounts, and corporate reimbursement
back to user-controlled accounts.

Cash System does not judge business attribution. School business ownership does
not decide Cash eligibility; actual movement through a user-controlled account
does.

Cash System now has the DB/RPC primitive needed by the school project for the
historical JPY paths. The school project owns mapping/outbox state and the
manual sync executor for those paths. Cash System receives idempotent RPC calls
and stores external JPY rows with `created_by_external = true`.

Deprecated old policy:

- only personal business enters Cash
- 青空塾 does not enter Cash
- personal + `teacher_wage` + JPY only
- personal tuition JPY only

Correct policy examples:

- 青空塾 tuition received in Alipay, JPY cash, or JPY bank enters Cash as
  `青空塾代收学费`.
- Transfer of that tuition to the corporate account is recorded as
  `转给法人账户 / 学费提交 / 代收款清算`, not ordinary household expense.
- 青空塾 teacher wages paid from user-controlled accounts enter Cash as
  `青空塾工资垫付`.
- Corporate reimbursement is recorded as
  `法人账户报销 / 青空塾工资垫付报销`.
- CNY/JPY exchange and account allocation remain manual Cash operations for
  now; School does not automate them.

External request-only rule:

- School initiates external Cash requests from School business flows.
- Cash System stores and displays pending requests.
- Cash user approval creates the Cash transaction and changes balance.
- Cash user rejection creates no transaction and changes no balance.
- Cash System does not proactively create School business records.
- Cash System does not proactively initiate School business requests.

Profit and clearing boundary:

- Operating profit includes real tuition income, teacher wages, and real
  business expenses.
- Operating profit excludes Cash transfer to corporate accounts, corporate
  reimbursement to Cash, CNY/JPY exchange, user-account transfers,
  entrusted-funds clearing, and wage-advance recovery.
- Cash transfer to corporate account for 青空塾 tuition submission is
  `支出 / 转给法人账户 / 学费提交 / 代收款清算`.
- Corporate reimbursement for Cash-advanced 青空塾 wages is
  `收入 / 法人账户报销 / 青空塾工资垫付报销`.

The current school zsh sync executor is a verification/operations tool. The
target daily business flow is page-driven and embedded in the real School
business pages, not a separate School sync page:

1. School income/payment business page submits an external Cash request when
   actual money will move through a user-controlled Cash account.
2. Cash System creates a pending external transaction request.
3. Cash page approves or rejects.
4. Approval creates the Cash JPY transaction and changes Cash balance.
5. Rejection creates no transaction and leaves Cash balance unchanged.
6. School displays business labels such as `Cash待确认`, `Cash已确认`, or
   `Cash已拒绝`.

Recommended bridge: Supabase Edge Function. The School browser should not
directly write the Cash project with Cash credentials, and the Cash frontend
should not directly read the School DB.

Cash approve/reject callback boundary:

- The Cash page first calls Cash RPCs:
  - approve: `home_approve_external_transaction_request(...)`
  - reject: `home_reject_external_transaction_request(...)`
- After the Cash RPC succeeds, the Cash page calls the School-owned
  `sync-cash-request-result` Edge Function with:
  - `cash_request_id`
  - `action = approved | rejected`
- The Edge Function, not the Cash browser, reads the Cash request with service
  role and calls School confirmed/rejected RPCs with School service role.
- If School writeback fails, Cash request state and any approved Cash
  transaction are not rolled back. The UI instructs the operator to retry the
  School writeback later.

Cash-side v2 stage 1 implemented objects:

- Formal SQL file: `supabase-update-20260613-external-requests.sql`
- Request table: `home_external_transaction_requests`
- Create/approve/reject/read RPCs listed above
- UI view: `外部待确认`

Important boundary: the code path now includes the School request Edge Function
and the Cash-result callback Edge Function, but deployment/configuration and
approve/reject E2E testing remain separate guarded phases.

Historical Phase 1 completed scope:

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

Remaining out of historical Phase 1 included 青空塾, 青空塾 teacher wages, 青空塾 reimbursements, company account spending, CNY, non-`teacher_wage`, personal tuition income, part-time wage income, reversal sync, automatic background retry, Cash UI changes for external rows, and cross-DB strong transactions. Under the corrected policy, 青空塾 and CNY/RMB should be added later when they represent real user-controlled-account movement.

Phase 2 Cash guard extension is prepared for personal-business tuition income -> Cash System JPY income transaction. It is limited in current code to `school_income_records` + `tuition_income_received` and must create a positive JPY `income` transaction. It currently excludes 青空塾, CNY, reimbursement, company account spending, and arbitrary school events. This is an implementation limit; only arbitrary school events without real account movement should remain excluded as policy.

Cash linkage v2 implementation order:

1. Cash DB: add pending external transaction request table and approve/reject RPCs. Implemented, applied, and rollback-verified.
2. Cash UI: add pending request list, detail, approve, reject, and approve confirmation. Implemented in code.
3. Edge Function: School income/payment page action -> Cash pending request. Implemented for the historical personal JPY teacher wage request code path in School repo.
4. School DB/UI: extend payment linkage lifecycle and embed Cash account selection in the business pages. The current implemented subset is personal JPY teacher wage payment with Cash 支付账户 and `提交到 Cash 确认`; the target policy must broaden this to all School money movement that passes through user-controlled accounts, including 青空塾 and CNY/RMB.
5. Cash approve/reject -> School result callback. Code added through School `sync-cash-request-result` Edge Function and Cash UI wrapper.
6. ROLLBACK whitelist tests.
7. COMMIT whitelist E2E approve/reject tests.
8. Real 2026-05 teacher wage trial remains paused until School and Cash implementation match the unified policy. Real data should not be cleaned up; whitelist test data should be cleaned up.
