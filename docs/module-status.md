# Module Status

Status date: 2026-06-14

| Module | Current State | Next Priority |
| --- | --- | --- |
| JPY accounts | Existing UI/RPC behavior unchanged | Keep ordinary account management stable |
| JPY transactions | Existing ordinary flows unchanged; external JPY DB/RPC insert support added for historical Phase 1 teacher wage and Phase 2 tuition income | Keep `home_create_external_jpy_transaction` as approval-time primitive while aligning policy coverage |
| CNY transactions | Existing ordinary flows unchanged; no external school support yet | Add CNY/RMB support later for user-controlled account movements such as Alipay |
| Fixed templates/month items | Unchanged | Keep fixed-item linkage separate |
| FX linkage | Unchanged | Keep FX linkage separate |
| External school linkage | Historical Phase 1/2 manual E2E sync verified; Cash linkage v2 pending request table/RPC/UI implemented; business policy now requires all user-controlled-account School movements to enter Cash | Align implementation with unified personal/青空塾, JPY/CNY policy before real wage trial |

## External JPY Transaction Support

Implemented through `supabase-update-20260613-external-jpy-1.sql`; Phase 2 tuition income guard extension was executed through `supabase-update-20260613-external-jpy-2.sql`.

Current role:

- `home_create_external_jpy_transaction(...)` is the idempotent transaction creation primitive.
- The zsh sync executor that calls it directly is a verification/operations tool, not the final daily business entry point.
- In Cash linkage v2, this RPC should be called only after a Cash user approves a pending external request from the Cash page.
- Current external implementation is still JPY-only and historically narrowed.
  The 2026-06-14 business policy requires later support for every School money
  movement that actually passes through a user-controlled Cash account,
  including 青空塾 and CNY/RMB movements.

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

Phase 2 tuition income guard is narrow in current code: only personal-business school income records may use `tuition_income_received`, it must create a JPY `income` transaction, and it does not support expense, CNY, 青空塾, reimbursement, company account, or arbitrary school events. This guard must be broadened later for real user-controlled-account movements while still rejecting arbitrary school events without account movement.

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
5. Approve calls existing `home_create_external_jpy_transaction(...)`, creates a Cash transaction, and changes balance.
6. Reject stores rejection state/reason and creates no Cash transaction.

Design principles:

- Cash balance can change only after Cash-side approval.
- School business submission to Cash is not Cash approval/payment confirmation.
- Idempotency starts at pending request creation and continues at transaction creation.
- Do not exclude 青空塾 or CNY/RMB when actual money moves through a user-controlled account. Continue excluding arbitrary school events without real account movement.

Likely Cash objects:

- `home_external_transaction_requests`: implemented in `supabase-update-20260613-external-requests.sql`
- `home_create_external_transaction_request(...)`: implemented; idempotently creates `pending`
- `home_approve_external_transaction_request(...)`: implemented; only pending requests can approve, then it calls `home_create_external_jpy_transaction(...)`
- `home_reject_external_transaction_request(...)`: implemented; only pending requests can reject and no Cash transaction is created
- `home_get_external_transaction_requests(...)`: implemented for the Cash UI
- Cash UI view `外部待确认`: implemented for list/filter/approve/reject

Recommended bridge:

- Supabase Edge Function behind School income/payment business actions.
- Do not expose Cash service credentials in the School browser.
- Do not make the Cash frontend directly read School DB.

Current implementation boundary:

- Pending request creation does not change Cash balance.
- Approve is the only path that creates/reuses a JPY transaction.
- Reject records status/reason and leaves Cash balance unchanged.
- After local approve/reject succeeds, the Cash UI calls the School-owned
  `sync-cash-request-result` Edge Function through API wrapper
  `syncCashRequestResultToSchool(...)`.
- If School writeback fails, Cash request remains approved/rejected and the UI
  reports that School writeback should be retried later.
- The browser does not write School DB directly and does not receive
  service-role keys.
- The SQL has been applied and rollback-verified; callback Function deployment
  and full School embedded approve/reject E2E remain pending.

Planned 2026-05 teacher wage trial:

- Paused until School and Cash implementation match the unified policy.
- The old two-row personal-business `teacher_wage` JPY trial plan remains only
  as historical planning context.
- Real data should not be cleaned up; cleanup applies only to clearly marked whitelist test data.

## Hard Stops

- Do not use `supabase-schema.sql` for incremental external linkage updates.
- Do not add CNY/school/cross-DB writes in this repository without a separate design.
- Do not broaden current Phase 2 tuition implementation beyond personal + tuition + JPY without a separate guarded implementation workflow, even though the business policy requires that broader coverage later.
- Do not delete existing transactions as a reversal mechanism.
- Do not change ordinary JPY/CNY page modules while adding external request confirmation.
- Do not add automatic retry/background sync before the page-driven pending request flow is implemented and tested.
