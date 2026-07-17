# Module Status

Status date: 2026-07-18

| Module | Current State | Next Priority |
| --- | --- | --- |
| JPY accounts | Existing UI/RPC behavior unchanged; `allow_school_requests` marks School-eligible accounts | Keep ordinary account management stable |
| JPY transactions | Existing ordinary flows unchanged; external JPY DB/RPC insert support added and now requires School-eligible active JPY accounts | Keep `home_create_external_jpy_transaction` as approval-time primitive while aligning policy coverage |
| CNY transactions | Existing ordinary flows unchanged; external CNY approval primitive supports canonical School income/expense requests for School-eligible active CNY accounts | Keep ordinary CNY flows stable |
| Fixed templates/month items | Unchanged | Keep fixed-item linkage separate |
| FX linkage | CNY→JPY pair can be verified by School and recorded in `home_school_fx_syncs`; synced pairs are DB-locked against update/delete, Cash dev exposes guarded School writeback, and the 2026-07-18 dev E2E passed | Keep the verified dev chain immutable; reproduce migration, credentials and E2E only during staging/prod rollout |
| Teacher wage aggregate | Same-teacher/month/currency/account/date canonical wage requests can be approved as one Cash transaction with batch/item audit mappings; School-synced batches are immutable, retry-idempotent, and the 2026-07-18 JPY 59,100 dev E2E passed | Keep School canonical expense granularity; reproduce schema, callback config and E2E during staging/prod rollout |
| School 收支确认 | Cash linkage v2 pending request table/RPC/UI implemented. New request creation is restricted to canonical School income/expense records: `school_income_records / income_received` and `school_expense_records / expense_paid`; compatible `tuition_income_received` income-record history remains supported. Legacy teacher-wage payment requests and direct part-time-work income requests are historical read-only paths only. | Keep canonical flow stable; any legacy removal requires separate historical audit |

## Final System Boundary

- School System is the business ledger. It records tuition income, teacher wages,
  student/teacher/month, personal vs 青空塾 ownership, cost attribution,
  corporate-account clearing records, and company expense records.
- Cash System remains the user's household/private account ledger. It records
  actual user-controlled account movement for Alipay, JPY cash,
  Mitsubishi/Rakuten and other JPY accounts, RMB accounts, actual receipts,
  actual payments, CNY/JPY allocation, transfers to corporate accounts, and
  corporate reimbursements.
- Cash System does not judge School business ownership. School owns business
  attribution.
- Cash System accepts external requests only. School initiates requests; Cash
  users approve/reject; approve creates Cash transactions and changes balances;
  reject creates no transaction and changes no balance.
- Cash System must not proactively create School business records or initiate
  School business requests.
- A teacher-wage aggregate is a Cash payment optimization only. School keeps one
  canonical expense per wage snapshot/business attribution, while Cash keeps one
  aggregate transaction plus an immutable item mapping back to every expense.
- The Cash UI entry for School-originated confirmation requests is `收支确认`.
  Canonical income rows are displayed as `收入确认 / School 收入记录`,
  canonical expense rows as `支出确认 / School 支出记录`, and deprecated direct
  module rows as `旧链路记录`.
- Internal clearing is not operating profit: Cash-to-corporate transfer,
  corporate reimbursement to Cash, CNY/JPY exchange, user-account transfer,
  entrusted tuition clearing, and wage-advance recovery are excluded from
  profit statistics.

## School-Eligible Cash Accounts

Cash owns the account whitelist for School-originated external requests through
`home_accounts.allow_school_requests`.

Current active accounts allowed for School requests:

- `余额宝` (`CNY`, wallet)
- `日元现金` (`JPY`, cash)
- `日元三菱卡` (`JPY`, bank)
- `日元乐天卡` (`JPY`, cash)

Current active accounts excluded from School requests:

- `余利宝` (`CNY`, wallet)
- `医生处兑换日元先行支付` (`JPY`, cash)

School should read active accounts where `allow_school_requests = true` for
future income/payment selectors. School must not maintain Cash balances.

## External JPY/CNY Transaction Support

Implemented through `supabase-update-20260613-external-jpy-1.sql`; Phase 2 tuition income guard extension was executed through `supabase-update-20260613-external-jpy-2.sql`.
The multicurrency foundation is added through `supabase-update-20260613-school-account-eligibility-and-multicurrency.sql`.

Current role:

- `home_create_external_jpy_transaction(...)` is the JPY idempotent transaction creation primitive.
- `home_create_external_cny_transaction(...)` is the CNY idempotent transaction creation primitive.
- The zsh sync executor that calls it directly is a verification/operations tool, not the final daily business entry point.
- In Cash linkage v2, these transaction primitives should be called only after a Cash user approves a pending external request from the Cash page.
- Cash request/approval infrastructure supports JPY and CNY. New School-originated requests must come from canonical income/expense records. Legacy direct teacher-wage payment requests and direct external part-time-work income requests are deprecated for new creation and retained only for historical reads.

Allowed external events for new creation:

- `school_income_records` + `tuition_income_received` / `income_received` -> `transaction_type = income`
- `school_expense_records` + `expense_paid` -> `transaction_type = expense`

Legacy direct request families retained only for historical reads:

- `school_payment_requests` + `teacher_wage_payment_confirm`
- `school_payment_requests` + `teacher_wage_payment_reverse`
- `school_part_time_work_income_requests` + `part_time_work_income_received`

Required source metadata:

- `external_source = aozora_school`
- `external_source_id`
- `external_event_type`
- `external_idempotency_key`
- `external_reference_type = school_income_records` for income events
- `external_reference_type = school_expense_records` for expense events
- `external_reference_id`
- active account matching request currency
- `home_accounts.allow_school_requests = true`
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

Verified Phase 2 E2E test row, later cleaned:

- Cash test account: `95000000-0000-4000-8000-000000160501`
- school income record: `484e9ecf-e48d-4f8a-8812-3b32fdef0df6`
- school income linkage event: `36a6108f-e638-4107-9a1f-0023de536bd7`
- Cash JPY transaction: `2430846f-e8d2-4e31-b9c6-6fb05279dbc5`
- `transaction_type = income`
- `amount = 6789`
- duplicate school sync run left transaction count at 1.
- cleanup verification later confirmed target Cash transaction/account counts are 0, Cash external event/reference counts are 0, `home_cny_transactions` marker count is 0, and school target business/student/mapping/income/event counts are 0.

Historical Phase 1 did not link 青空塾, 青空塾 teacher wages, 青空塾 reimbursements, company account spending, CNY, non-`teacher_wage`, or part-time wage income. Historical Phase 2 only added personal-business `tuition` JPY income. These are implementation history, not current business policy.

Phase 2 tuition income guard is narrow in current School code: only personal-business school income records may use `tuition_income_received`, and School income pages/functions still do not submit CNY or 青空塾 requests. Cash-side request/approval foundation now supports JPY/CNY for whitelisted event families and School-eligible accounts. Teacher-wage payment requests are now broadened on the School side for eligible JPY/CNY Cash accounts. Income implementation must be broadened later for real user-controlled-account movements while still rejecting arbitrary school events without account movement.

Unified policy targets:

- 青空塾 tuition received through a user-controlled account enters Cash as
  `青空塾代收学费`.
- Transfer of entrusted 青空塾 tuition to the corporate account is recorded as
  `转给法人账户 / 学费提交 / 代收款清算`, not ordinary household expense.
- 青空塾 teacher wages paid from user-controlled accounts enter Cash as
  `青空塾工资垫付`.
- Corporate reimbursement is recorded as
  `法人账户报销 / 青空塾工资垫付报销`.
- CNY/RMB receipts and payments, such as Alipay movements, enter Cash when
  they use a user-controlled account.
- CNY/JPY exchange and account allocation remain manual Cash operations for
  now.

## Cash Linkage v2 Pending Request Direction

Target flow:

1. School income/payment business page submits a Cash confirmation request after the user selects the Cash 收款账户 / 支付账户.
2. Cash System stores a pending external transaction request.
3. Cash page shows pending request list/detail.
4. Cash user approves or rejects.
5. Approve calls the matching currency primitive, creates a Cash transaction, and changes balance.
6. Reject stores rejection state/reason and creates no Cash transaction.

Design principles:

- Cash balance can change only after Cash-side approval.
- School business submission to Cash is not Cash approval/payment confirmation.
- School initiates external requests; Cash does not proactively generate
  School requests.
- Cash does not create School business records.
- Idempotency starts at pending request creation and continues at transaction creation.
- Do not exclude 青空塾 or CNY/RMB when actual money moves through a user-controlled account. Continue excluding arbitrary school events without real account movement.

Likely Cash objects:

- `home_external_transaction_requests`: implemented in `supabase-update-20260613-external-requests.sql`
- `home_create_external_transaction_request(...)`: implemented; idempotently creates `pending` for JPY/CNY School-eligible accounts
- `home_approve_external_transaction_request(...)`: implemented; only pending requests can approve, then it calls `home_create_external_jpy_transaction(...)` or `home_create_external_cny_transaction(...)`
- `home_reject_external_transaction_request(...)`: implemented; only pending requests can reject and no Cash transaction is created
- `home_get_external_transaction_requests(...)`: implemented for the Cash UI
- `home_list_school_eligible_cash_accounts()`: implemented for reading active School-eligible accounts
- Cash UI view `收支确认`: implemented for list/filter/approve/reject

Recommended bridge:

- Supabase Edge Function behind School income/payment business actions.
- Do not expose Cash service credentials in the School browser.
- Do not make the Cash frontend directly read School DB.

Current implementation boundary:

- Pending request creation does not change Cash balance.
- Approve is the only path that creates/reuses a JPY/CNY external transaction.
- Reject records status/reason and leaves Cash balance unchanged.
- Canonical income requests use `school_income_records` with
  `income_received` or compatible historical `tuition_income_received`.
- Canonical expense requests use `school_expense_records` with `expense_paid`.
- `teacher_wage_payment_confirm`, `teacher_wage_payment_reverse`, and
  `part_time_work_income_received` are legacy historical request types only and
  must not be newly created.
- After local approve/reject succeeds, the Cash UI calls the School-owned
  `sync-cash-request-result` Edge Function through API wrapper
  `syncCashRequestResultToSchool(...)`.
- If School writeback fails, Cash request remains approved/rejected and the UI
  reports that School writeback should be retried later.
- The browser does not write School DB directly and does not receive
  service-role keys.
- Rejected Cash requests are terminal, cannot be approved later, and can be
  retried only by creating a new School attempt / Cash request. Old rejected
  attempts remain history, and only one active attempt is allowed for the same
  payment request at the same time.
- School rollback, Cash JPY/CNY request rollback, and rejected -> retry ->
  approved backend E2E have passed. Cleanup is complete with School/Cash target
  residue 0. Real 2026-05 wage data was not used.

Historical teacher-wage direct-request trial:

- The old two-row personal-business `teacher_wage` JPY plan remains only as
  historical planning context.
- Current teacher wage payments use `school_expense_records`.
- Real data should not be cleaned up from Cash without a separate historical
  audit and dry-run.

## Hard Stops

- Do not use `supabase-schema.sql` for incremental external linkage updates.
- Do not add school/cross-DB writes in this repository without a separate design.
- Do not broaden School-side current Phase 2 tuition implementation beyond personal + tuition + JPY without a separate guarded implementation workflow, even though Cash-side CNY request foundation now exists.
- Do not delete existing transactions as a reversal mechanism.
- Do not change ordinary JPY/CNY page modules while adding external request confirmation.
- Do not add automatic retry/background sync before the page-driven pending request flow is implemented and tested.
