# System Map

Status date: 2026-06-16

## Core Tables

- `home_accounts`: account master data for JPY/CNY accounts, including `allow_school_requests` for School-originated external request eligibility.
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
- `home_create_external_jpy_transaction(...)`: creates idempotent external-source JPY transactions for guarded aozora school linkages after Cash approval.
- `home_create_external_cny_transaction(...)`: creates idempotent external-source CNY transactions for guarded aozora school linkages after Cash approval.
- `home_create_external_transaction_request(...)`: idempotently creates a pending JPY/CNY external request for a School-eligible account. It does not create a transaction.
- `home_approve_external_transaction_request(uuid)`: approves a pending request and then calls the matching JPY/CNY external transaction primitive.
- `home_reject_external_transaction_request(uuid, text)`: rejects a pending request without creating a transaction.
- `home_get_external_transaction_requests(text, integer)`: reads requests for the Cash approval UI.
- `home_list_school_eligible_cash_accounts()`: reads active Cash accounts allowed for School-originated request selectors.

## School Account Eligibility

Cash owns the School account whitelist through `home_accounts.allow_school_requests`.
School should read active accounts where this flag is true and should not store
or maintain Cash balances.

Current allowed accounts:

- `余额宝` (`CNY`, wallet)
- `日元现金` (`JPY`, cash)
- `日元三菱卡` (`JPY`, bank)
- `日元乐天卡` (`JPY`, cash)

Current excluded accounts:

- `余利宝` (`CNY`, wallet)
- `医生处兑换日元先行支付` (`JPY`, cash)

## External JPY/CNY RPC Boundary

`home_create_external_jpy_transaction(...)` only writes `home_jpy_transactions`.
`home_create_external_cny_transaction(...)` only writes `home_cny_transactions`.

In the Cash linkage v2 target architecture, this RPC is not the first business
entry point. It should run only after a Cash user approves a pending external
request in the Cash System UI.

These transaction primitives do not write:

- `home_fixed_month_items`
- `home_fixed_templates`
- `home_payment_channels`
- any school table

They require an active `home_accounts` row matching the request currency,
`allow_school_requests = true`, and a positive amount.

Currently allowed school event families for new creation:

- `school_income_records` + `tuition_income_received` / `income_received` -> JPY/CNY `income`
- `school_expense_records` + `expense_paid` -> JPY/CNY `expense`

Legacy direct request families retained only for historical reads:

- `school_payment_requests` + `teacher_wage_payment_confirm`
- `school_payment_requests` + `teacher_wage_payment_reverse`
- `school_part_time_work_income_requests` + `part_time_work_income_received`

The corrected 2026-06 business policy is canonical-record based: any
School-related money movement that actually passes through a user-controlled
account should enter Cash through a School income record or expense record.
Cash does not accept new business-module direct requests for teacher wage or
external part-time work. Arbitrary School events without real account movement
remain excluded.

## Balance Rule

Balances remain read-time calculations from `opening_balance` plus transaction movements. The external JPY/CNY RPCs only insert normal `income` or `expense` rows with external metadata; they do not store a cached account balance.

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

Cash System now has the DB/RPC primitives needed by the school project for
JPY/CNY pending external requests. The historical school mapping/outbox and
manual sync executor remain JPY verification/operations tools. Cash System
receives idempotent pending requests and stores approved external rows with
`created_by_external = true`.

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
target daily business flow is page-driven from canonical School income/expense
records, not a separate School sync page:

1. School income record or expense record page submits an external Cash request
   when actual money will move through a user-controlled Cash account.
2. Cash System creates a pending external transaction request.
3. Cash page approves or rejects.
4. Approval creates the matching JPY/CNY Cash transaction and changes Cash balance.
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

Canonical request payload convention:

- `school_income_records / income_received` and compatible
  `tuition_income_received` requests are Cash `income` requests.
- `school_expense_records / expense_paid` requests are Cash `expense` requests.
- `currency = JPY` approves into `home_jpy_transactions`; `currency = CNY`
  approves into `home_cny_transactions`.
- School keeps business category, business month, locked snapshot, source
  module, original business amount/currency, and any exchange/adjustment note in
  the income/expense record and payload snapshot.
- Cash uses only the actual account, actual Cash date, actual currency, and
  actual amount for ledger movement.
- Legacy `teacher_wage_payment_confirm`, `teacher_wage_payment_reverse`, and
  `part_time_work_income_received` request types are readable history only and
  must not be newly created.

Cash-side v2 stage 1 implemented objects:

- Formal SQL files: `supabase-update-20260613-external-requests.sql`,
  `supabase-update-20260613-school-account-eligibility-and-multicurrency.sql`
- Request table: `home_external_transaction_requests`
- Create/approve/reject/read RPCs listed above, plus School-eligible account reader
- UI view: `收支确认`

Important boundary: the code path now includes School request Edge Functions for
canonical income/expense records and the Cash-result callback Edge Function.
Canonical income approve/reject and canonical expense approve/reject have passed
rollback smoke with residue 0. Browser automation remains unstable, so page
paths can be operated manually and verified through DB checks.

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

Phase 2 Cash guard extension is historical context. Current new request creation is canonical-record based: `school_income_records` for income and `school_expense_records` for expense. Arbitrary School events without real account movement remain excluded.

Cash linkage v2 implementation order and current status:

1. Cash DB: add pending external transaction request table and approve/reject RPCs. Implemented, applied, and rollback-verified.
2. Cash UI: add pending request list, detail, approve, reject, and approve confirmation. Implemented in code.
3. Edge Function: School canonical income/expense record action -> Cash pending request. Implemented for `school_income_records` and `school_expense_records`.
4. School DB/UI: Cash account selection is embedded in income/expense record pages. Teacher wage now reaches Cash through `school_expense_records`; external part-time work income reaches Cash through `school_income_records`.
5. Cash approve/reject -> School result callback. Code added through School `sync-cash-request-result` Edge Function and Cash UI wrapper.
6. ROLLBACK whitelist tests. Completed for School and Cash JPY/CNY request paths.
7. Smoke/regression tests. Canonical income approve/reject and canonical expense approve/reject rollback smoke passed with residue 0.
8. Legacy direct request families are retained only as historical reads and cannot be newly created.
