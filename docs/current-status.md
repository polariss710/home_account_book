# Current Status

Status date: 2026-08-19

This document keeps the current Cash System implementation checkpoint, safety notes, and active backlog.

## Current State

- Cash System is a static Supabase-backed household ledger using `home_` tables.
- Phase 2A-P is deployed: fixed templates, fixed month items, JPY/CNY transactions, fixed advances, and external transaction requests now carry `accounting_scope` with the only allowed values `household` and `school`. The column is `NOT NULL` with defensive default `household`; School external requests and transactions are database-forced to `school`.
- Phase 2B1 is deployed in code and production readers: JPY fixed details/templates, JPY casual transactions, and the combined CNY fixed/casual view show `School`／`家庭` labels and support module-local `all / school / household` visibility filters. Filters do not recalculate totals or balances.
- External JPY/CNY transaction request infrastructure for aozora school now accepts new requests only from canonical School income and expense records: `school_income_records / income_received` and `school_expense_records / expense_paid`. Historical `tuition_income_received` income-record requests remain compatible.
- Legacy business-module direct request families are deprecated for new creation: `school_payment_requests / teacher_wage_payment_confirm`, `school_payment_requests / teacher_wage_payment_reverse`, and `school_part_time_work_income_requests / part_time_work_income_received`. Existing historical rows remain readable for audit.
- A school-side manual sync executor successfully called the Cash RPC for both supported flows, verified idempotent duplicate execution, and later cleaned the whitelist test transaction/account residue.
- The manual sync executor is now classified as a verification/operations tool, not the final daily business entry point.
- Cash linkage v1 business policy is unified as of 2026-06-14: School is the business ledger and stores business ownership; Cash System's original position remains the user's household/private account ledger, and it records real user-controlled account movement. Any money that passes through a user-controlled account should enter Cash, regardless of whether School ownership is personal business or 青空塾. Business ownership no longer decides Cash eligibility. Cash System only accepts external requests; it does not proactively create School business records or initiate School business requests. Cash keeps the separate `收支确认` page as the ledger-side approve/reject entry, and only approval creates a Cash transaction and changes Cash balance.
- Cash-side pending request table, create/approve/reject RPCs, and Cash approval UI are implemented in this repository.
- CNY/JPY external transactions are now immutable after creation. Database triggers are the final UPDATE/DELETE defense; RLS rejects authenticated external mutation and forged external inserts; ordinary update/delete RPCs fail closed with `EXTERNAL_TRANSACTION_IMMUTABLE`; anon/PUBLIC execute and table write privileges are removed. Ordinary manual CNY/JPY CRUD remains available.
- Cash UI version `20260819-accounting-scope-filter-1` renders canonical external rows as read-only, keeps the `School同步生成` badge, exposes no edit/copy/delete controls, and adds accounting-scope labels/filters. CNY display uses two decimal places (`1120.50` -> `1,120.50 CNY`); JPY remains zero-decimal.
- Cash accounts now include `allow_school_requests`. School-facing account selection must use active accounts with this flag enabled. Current School-eligible accounts are `余额宝`, `日元现金`, `日元三菱卡`, and `日元乐天卡`; `余利宝` and `医生处兑换日元先行支付` are explicitly excluded.
- Cash approval UI now calls a School-owned Edge Function after local approve/reject: approve creates the Cash transaction first, then requests School writeback; reject records Cash rejection first, then requests School writeback. If School writeback fails, Cash state is not rolled back and the UI tells the operator to retry later.
- No direct School DB writes, School-side Edge Function deployment, background worker, or automatic scheduler is implemented in this repository.

## Latest Update

2026-08-19 Phase 2B1 accounting scope display and detail filtering:

- Replaced the three production reader definitions `home_get_fixed_month_page(text,text)`, `home_get_jpy_account_page(text)`, and `home_get_cny_account_page(text)` so target item/template/transaction objects explicitly construct `accounting_scope`. Function signatures, sorting, calculations, owner `postgres`, security-invoker mode, settings, and EXECUTE ACLs are unchanged.
- Rollback precheck and production postcheck compared recursive page JSON fingerprints after removing `accounting_scope`; JPY fixed, CNY fixed, JPY account, and CNY account pages all matched their prechange fingerprints. No amount, status, grouping, balance, or existing JSON key changed.
- Added `School`／`家庭` row badges and independent in-memory filters to JPY fixed, JPY casual, and CNY views. CNY uses one scope filter for fixed items/templates and casual/external transactions. Month switching preserves each module filter; reload resets it to `全部`.
- Fixed payment-group sections with no visible matching item are hidden. Group totals remain database-provided all-record totals. Empty filtered lists show `当前没有符合该账务归属的记录。`; invalid/missing scope renders `归属异常` and emits an explicit console error without inference or writeback.
- No writer/RPC signature, writer payload, annual summary, balance algorithm, fixed settlement/advance rule, School V2 object, or production data row changed. Phase 2B2 entry support, Phase 2B3 statistics, Phase 2B4 annual scope reporting, and mixed-scope advance rules remain deferred.

2026-08-19 Phase 2A-P accounting scope production migration:

- Added `accounting_scope text NOT NULL DEFAULT 'household'` and an allowed-values CHECK to `home_fixed_templates`, `home_fixed_month_items`, `home_jpy_transactions`, `home_cny_transactions`, `home_fixed_advance_payments`, and `home_external_transaction_requests`. The field was intentionally not added to accounts or payment channels because those can carry both scopes.
- Deterministic production backfill completed: fixed templates `26 household / 0 school`; fixed month items `70 / 0`; JPY transactions `31 / 4`; CNY transactions `37 / 38`; fixed advances `2 / 0`; external requests `0 / 50`. All target rows are classified and no name/note inference was used.
- Installed `home_assign_accounting_scope()` as postgres-owned, security invoker, fixed `search_path = pg_catalog, public`, with direct execute revoked from PUBLIC, anon, authenticated, and service_role. Four enabled `BEFORE INSERT` triggers provide old-client household compatibility, fixed template-to-month inheritance, linked CNY/FX inheritance, and database-forced School external scope.
- Added the invariant that `external_source = 'aozora_school'` requires `accounting_scope = 'school'` on JPY/CNY transactions and external requests. Existing CNY/JPY external immutable triggers remain enabled and continue to reject updates/deletes.
- Final rollback precheck and committed migration both passed the isolated 2099 fixture matrix. Commit-time fixture residue was 0. Postcommit row counts, primary-key sets, all pre-existing business-field fingerprints, amount totals, account balances, fixed statuses/payment groups, 16 existing RPC definitions/ACLs, and existing reader amount/balance outputs matched the pre-migration baseline.
- No HTML/CSS/JS, reader definition, RPC signature, balance algorithm, annual-statistics rule, fixed settlement, fixed advance, or School V2 behavior changed in Phase 2A-P itself. Phase 2B1 later added reader/UI display filtering only; Phase 2B2+ and Phase 3/4 remain deferred.
- Pre-existing audit fact retained without data correction: request `475b2b7f-2e86-415f-87a0-580759fb50a4` has request date `2026-05-31`, while linked CNY transaction `f8bec66d-e03c-45aa-9eef-329ac604ca54` has transaction date `2026-06-15`. Reference, event, idempotency, currency, amount, account, type, and transaction ID remain canonically matched.

2026-08-02 external transaction immutability hardening:

- Deployed `supabase-update-20260802-external-transaction-immutability.sql`; installed enabled CNY/JPY immutable triggers, split each ledger into four minimum RLS policies, tightened table/function ACL, fixed function owner/search path, and hardened the four ordinary update/delete RPCs.
- Backend rollback matrix passed 24/24 and rolled back every `f3f10000-*` fixture; residue is 0. Local browser UI contract passed 7/7, covering external-control suppression, ordinary controls, CNY precision, and unchanged JPY display.
- Postdeploy protected baseline passed: accounts `7 / 89b057e2cdeb7324ef73f73e252174f1`, requests `35 / 4a7319eb294222cb5057ecfe262a885f`, CNY transactions `64 / 8e5f62d1e256228b956ca7155bed65db`, JPY transactions `31 / 95ab7cf8a8d167e9b052d3fc6b64614b`.
- 袁振轩 transaction `2feb333c-6228-4f57-a1fa-c8aa3d40616c` remains `1120.50 CNY / 2026-08-02 / 余额宝`, row MD5 `7c94d3e343e26713a54e779e1d3b53da`.
- Business owner confirmed the prior `400.00 CNY` 余额宝 expense delta as legitimate ordinary Cash operation. The approved balance baseline is `111041.82 CNY`, expense count `37`, expense sum `124069.05 CNY`; hardening did not modify or roll back that operation.

2026-07-24 JPY investment profit/loss support:

- JPY casual transactions now include `投资增减` for stock/investment account valuation changes.
- `投资增减` is the only JPY transaction type that may store a signed amount: positive values increase the selected JPY account balance, negative values decrease it.
- Ordinary income/expense/transfer/FX/fixed-linked JPY transactions still keep positive amount semantics; their balance direction is determined by `transaction_type`.
- Investment P/L affects account balances and annual account-balance totals, but it is not included in ordinary JPY casual income/expense statistics.

2026-07-24 JPY fixed expense advance-payment flow:

- Added a grouped fixed-expense advance-payment design for cases where a JPY casual account pays a fixed expense group before the monthly fixed income date.
- The advance unit is the fixed expense payment group, not a single fixed item. The RPC sums all ordinary expense items in that group and rounds the group total up to the nearest 1,000 JPY.
- Advance and repayment amounts must match exactly. Extra account allocation should use ordinary account transfer, not the advance flow.
- Advance outflow and repayment inflow affect JPY account balances only. They are excluded from JPY casual income/expense statistics so fixed expenses are not double-counted.
- Fixed items inside an advanced group are locked from single-row edit/delete/status changes in the UI; the linked JPY transactions are also locked from casual-ledger edit/delete.

2026-06-16 transaction delete confirmation guard:

- CNY/JPY transaction delete actions now require a full confirmation message that includes date, amount, currency, account, transaction type, and memo/description. FX-linked and fixed-transfer deletes also state the linked-row impact before deletion.
- School-originated Cash transactions, detected through external/source metadata, now require a second risk confirmation explaining that deletion may leave School and Cash out of sync. Cash remains manually editable/deletable; this is an accidental-delete guard, not a hard lock.
- Read-only investigation of the accidental 2026-06 `厦门吕同学` CNY income deletion found that School income record `ac685f46-e924-435f-99e9-6797cca7e922` still exists as `received / Cash已确认` for `7,740 CNY`, while Cash request `93c36048-754a-491b-8a52-8e987b4efc07` remains `approved` with `created_transaction_id = 1d89c880-afd3-484a-ba73-3f158fef44de`. The matching Cash CNY/JPY transaction no longer exists, so the Cash balance no longer includes that row. No restore/rebuild was performed in this phase.

2026-06-16 School request display and transaction visibility cleanup:

- Cash UI renamed the former `外部待确认` entry to `收支确认`; the page title is now `School 收支确认请求`.
- Pending rows are presented as School confirmation requests, while canonical income rows show `收入确认 / School 收入记录`, canonical expense rows show `支出确认 / School 支出记录`, and legacy rows remain `旧链路记录`.
- School-originated CNY/JPY transaction rows now show a compact `School同步生成` badge. Cash still keeps ordinary manual maintenance capabilities; the badge is a source hint, not a hard edit/delete lock.
- The real 2026-05 诺应教育 canonical income request `475b2b7f-2e86-415f-87a0-580759fb50a4` is approved and linked to CNY transaction `f8bec66d-e03c-45aa-9eef-329ac604ca54`, amount `3,670 CNY`, account `余额宝`. The request date is `2026-05-31`; the current immutable transaction date is `2026-06-15`, so it appears in the `2026-06` RMB transaction view. This pre-existing date difference was documented during Phase 2A-P and was not corrected.

2026-06-16 finalized canonical School/Cash flow:

- Canonical income and expense flows have passed smoke/regression from the School side. Cash currently has no pending aozora school external requests.
- Smoke baseline HEADs: School `ce3ff67`, Cash `cdfb8a1`.
- New Cash request creation is limited to canonical School records only: `school_income_records / income_received` or compatible historical `tuition_income_received`, and `school_expense_records / expense_paid`.
- Legacy direct business-module request types are historical reads only and cannot be newly created: `school_payment_requests / teacher_wage_payment_confirm`, `school_payment_requests / teacher_wage_payment_reverse`, and `school_part_time_work_income_requests / part_time_work_income_received`.
- Cash UI display is converged: canonical income rows show `收入确认 / School 收入记录`, canonical expense rows show `支出确认 / School 支出记录`, and legacy direct rows show `旧链路记录 / 历史业务请求`.
- Cash does not judge School business type. Business category, business month, source module, locked snapshot, and original business amount belong to School income/expense records. Cash records only actual account movement date, account, currency, amount, and external reference payload.

2026-06-16 canonical external request restriction:

- Cash new request creation is now restricted to canonical School records: `school_income_records` with `income_received` / compatible `tuition_income_received`, and `school_expense_records` with `expense_paid`.
- `home_create_external_transaction_request(...)`, approval-time JPY/CNY transaction primitives, and external-created transaction table guards now reject legacy business-module direct request families with a clear deprecation message.
- The Cash request table constraint still preserves non-pending legacy request rows for historical audit; no request or transaction data was deleted.
- Cash UI keeps legacy request rows readable and labels old teacher-wage / direct part-time-work request types as `旧链路记录`.

2026-06-16 expense-record Cash approval:

- Approval-time JPY/CNY external transaction primitives now accept canonical School expense requests: `external_reference_type = school_expense_records`, `request_type = expense_paid`, `transaction_type = expense`.
- External-created JPY/CNY transaction table guards were updated for the same canonical expense request family.
- Cash approve can now create the actual expense transaction for approved `school_expense_records` requests, and School `school_expense_records` writeback RPCs were rollback-tested for approved/rejected sync.
- Legacy teacher-wage and part-time-work request families were still present in this phase; they were restricted for new creation in the later 2026-06-16 canonical external request restriction step.

2026-06-15 expense-record Cash pending request:

- Cash now accepts canonical School expense requests: `external_reference_type = school_expense_records`, `request_type = expense_paid`, `transaction_type = expense`.
- This flow creates only a pending external request; Cash transaction and balance changes happen only after Cash UI approve.
- Cash UI `收支确认` labels this request as `支出确认` and displays the School expense category, payee, month, original amount, actual payment amount/currency, and note from `payload_snapshot`.
- This is the target path for School expense records, including teacher wage after migration to `school_expense_records`. Legacy `school_payment_requests` teacher-wage requests are now historical read-only and are not supported for new creation.

2026-06-15 part-time work income Cash pending request (legacy path, now deprecated):

- Cash previously accepted `external_reference_type = school_part_time_work_income_requests`, `request_type = part_time_work_income_received`, `transaction_type = income`; this direct business-module path is now deprecated for new request creation.
- This flow records the actual Cash receipt amount/currency supplied by School and does not infer Cash amount from the locked School JPY wage total.
- Cash UI historical request display labels this request as a legacy direct part-time-work request and displays workplace, month, original JPY wage, actual received amount/currency, exchange rate, and note from `payload_snapshot`.
- Approval-time JPY/CNY external transaction primitives also accept this request family, so Cash approve can create the actual income transaction instead of returning `unsupported external_reference_type`.
- Real 2026-05 诺应教育 direct-path request `19ba6cbd-9588-486b-8b2a-b4b7c573f252`, amount `3,670 CNY`, original School wage `86,760 JPY`, exchange rate `0.0423006`, was rejected and is retained only as historical wrong-path evidence.

2026-06-14 external request retry attempts:

- Cash rejected external requests remain terminal history and are not reused.
- `home_external_transaction_requests` now keeps `idempotency_key` and `external_event_id` unique per request attempt, while the reference guard for `external_source + external_reference_type + external_reference_id + request_type` is partial for `pending` / `approved` only.
- This allows School to create a later retry attempt after a rejected teacher-wage Cash request, while still blocking duplicate active pending attempts and any new attempt after an approved request.
- `home_create_external_transaction_request(...)` now explicitly returns an error when a pending/approved request already exists for the same external reference and request type; exact idempotent repeats still return the existing request.
- Whitelist E2E used only 2026-06 codex-test teacher-wage data: attempt 1 rejected, attempt 2 approved, duplicate active creation returned the existing pending request, and the approved JPY expense was cleaned. Cleanup removed 2 Cash requests and 1 JPY transaction; target residue is 0 and `日元现金` returned to `202500.00`.
- Rejected Cash requests are terminal and cannot be approved later. School keeps the payment request pending, shows the rejection reason, and can submit a new attempt / Cash request. Old rejected attempts remain as history, and a single School payment request can have only one active attempt at a time.

2026-06-14 teacher-wage all-scope Cash request integration (historical, superseded by canonical expense records):

- This phase temporarily submitted pending `teacher_wage` payment requests through the external request flow when the actual payment account was Cash-eligible. It has been superseded by the canonical `teacher_wage -> school_expense_records -> Cash request` flow.
- Cash continues to accept external requests only; it does not create School business requests or School business records.
- Supported teacher-wage payment currencies:
  - `JPY` expense -> approved into `home_jpy_transactions`
  - `CNY` expense -> approved into `home_cny_transactions`
- Historical request creation in that superseded phase required:
  - `external_source = aozora_school`
  - `external_reference_type = school_payment_requests`
  - `request_type = teacher_wage_payment_confirm`
  - `transaction_type = expense`
  - active account matching request currency
  - `home_accounts.allow_school_requests = true`
- Historical Cash confirmation UI now displays teacher-wage payload details when available: School JPY wage cost, exchange rate, and actual Cash payment amount.
- Cash approve remains the only point that creates a Cash transaction and changes balance. Cash reject creates no transaction and changes no balance. School writeback is still called only after the local Cash approve/reject succeeds.
- School rollback, Cash JPY/CNY request rollback, and rejected -> retry -> approved backend E2E have passed. Cleanup is complete with School/Cash target residue 0. Real 2026-05 wage data was not used.

2026-06-14 School account eligibility and multicurrency request foundation:

- Added formal SQL file `supabase-update-20260613-school-account-eligibility-and-multicurrency.sql`.
- Added `home_accounts.allow_school_requests boolean not null default false`.
- Current account eligibility:
  - allowed for School requests: `余额宝`, `日元现金`, `日元三菱卡`, `日元乐天卡`
  - excluded from School requests: `余利宝`, `医生处兑换日元先行支付`
- School must read this Cash-owned whitelist for future income/payment account selectors. School must not maintain Cash balances.
- Extended `home_external_transaction_requests.currency` from JPY-only to `JPY` / `CNY`.
- `home_create_external_transaction_request(...)` now requires the selected account to be active, match the request currency, and have `allow_school_requests = true`.
- Added `home_create_external_cny_transaction(...)` and CNY external idempotency metadata on `home_cny_transactions`.
- `home_approve_external_transaction_request(...)` now dispatches by request currency:
  - `JPY` -> `home_jpy_transactions`
  - `CNY` -> `home_cny_transactions`
- `home_reject_external_transaction_request(...)` remains unchanged: rejection creates no transaction and changes no balance.
- Added read-only RPC `home_list_school_eligible_cash_accounts()` and JS helper `listSchoolEligibleCashAccounts()` for future School-side account selection.
- Historical note: at this checkpoint the event/reference guards still included `school_payment_requests` teacher wage payment events. Current guards have since been narrowed to canonical `school_income_records` / `school_expense_records` creation only; arbitrary external events remain rejected.

2026-06-14 unified School/Cash flow policy:

- Corrected the Cash linkage business policy:
  - School system = business ledger.
  - Cash System = actual funds-account ledger.
  - School stores business ownership.
  - Cash stores account movement.
- Deprecated old policy:
  - only personal business enters Cash
  - 青空塾 does not enter Cash
  - personal + `teacher_wage` + JPY only
  - personal tuition JPY only
- Tuition income:
  - personal and 青空塾 tuition are both School business income
  - if actual money is received through Alipay, JPY cash, or JPY bank, Cash records the corresponding account income
  - 青空塾 tuition received through a user-controlled account should be marked as `青空塾代收学费`
  - later transfer to the corporate account should be recorded as `转给法人账户 / 学费提交 / 代收款清算`, not ordinary household expense
- Teacher wage payments:
  - all wages paid from user-controlled accounts enter Cash, including personal, 青空塾, mixed ownership, JPY cash/bank, and RMB/Alipay payments
  - 青空塾 wage payments should be identifiable as `青空塾工资垫付`
  - later corporate reimbursement should be recorded as `法人账户报销 / 青空塾工资垫付报销`
- CNY/JPY exchange and account allocation remain manual Cash operations for now, usually monthly; School does not automate them.
- External request rule:
  - School sends external requests from tuition/payment business flows.
  - Cash shows pending requests.
  - approve creates the Cash transaction and changes balance.
  - reject creates no transaction and changes no balance.
  - Cash does not proactively generate School business requests or create School business records.
- Internal clearing / profit rule:
  - Cash transfer to corporate account for 青空塾 tuition submission is `支出 / 转给法人账户 / 学费提交 / 代收款清算`.
  - Corporate reimbursement for Cash-advanced 青空塾 wages is `收入 / 法人账户报销 / 青空塾工资垫付报销`.
  - Cash-to-corporate transfer, corporate reimbursement, CNY/JPY exchange, user-account transfer, entrusted-funds clearing, and wage-advance recovery are internal clearing/allocation and should not be treated as operating profit.
- Current School code may still be personal-only / JPY-only. Those are School-side implementation gaps to fix later. The real 2026-05 wage trial remains paused until School and Cash implementation match the corrected policy.

2026-06-13 Cash linkage v2 stage 1 implementation (historical implementation note):

- Added formal SQL file `supabase-update-20260613-external-requests.sql`.
- Added Cash-owned table `home_external_transaction_requests` for aozora school external transaction requests.
- Added RPCs:
  - `home_create_external_transaction_request(...)`
  - `home_approve_external_transaction_request(uuid)`
  - `home_reject_external_transaction_request(uuid, text)`
  - `home_get_external_transaction_requests(text, integer)`
- Added the Cash UI confirmation page, now named `收支确认`, for request list, filtering, approve, and reject.
- Pending requests do not create `home_jpy_transactions` and do not change balances.
- Approve is the only path that calls existing `home_create_external_jpy_transaction(...)`; idempotent duplicate behavior remains owned by that RPC.
- Reject records `rejected` state/reason and does not create a transaction or change balance.
- The supported request families at that historical checkpoint were:
  - `school_payment_requests` + `teacher_wage_payment_confirm` -> JPY/CNY `expense`
  - `school_payment_requests` + `teacher_wage_payment_reverse` -> JPY/CNY `income`
  - `school_income_records` + `tuition_income_received` / `income_received` -> JPY/CNY `income`
  - `school_part_time_work_income_requests` + `part_time_work_income_received` -> JPY/CNY `income`
- School -> Cash request entry belongs inside the School income/payment business pages, not a standalone School sync page. The intended bridge is still a Supabase Edge Function behind those business actions, not direct School-browser writes to Cash DB.
- Current canonical policy has since narrowed new creation to `school_income_records` and `school_expense_records`; legacy direct families from this checkpoint are readable history only.
- This checkpoint adds code/SQL/docs; the SQL was applied and rollback-verified in a later guarded DB apply phase.

2026-06-13 Cash linkage v2 approve/reject School writeback code:

- Cash external request approve/reject UI now calls `syncCashRequestResultToSchool(...)` after the local Cash RPC succeeds.
- The wrapper posts to the School-owned `sync-cash-request-result` Edge Function with `cash_request_id` and `action = approved | rejected`.
- Cash approve still owns Cash transaction creation through `home_approve_external_transaction_request(...)`.
- Cash reject still creates no transaction and does not change balance.
- The browser does not write School DB directly and does not receive service-role keys.
- The School callback Function URL is configured in `js/config.js`; no School key is committed. The School Function is expected to validate the Cash bearer token internally.
- If callback fails, Cash request remains approved/rejected and the UI shows: Cash has been processed, but School writeback failed; retry later.

2026-06-13 Cash linkage v2 UI/business direction correction (historical implementation note):

- Corrected the product direction for School-originated requests:
  - personal-business tuition JPY income starts from the School income record page with a Cash 收款账户 selection
  - historical personal-business teacher_wage JPY payment started from the School teacher wage payment page; current teacher wage payments must start from `school_expense_records`
  - School should not add a separate sync entry for ordinary users
  - School should use business labels such as `提交到 Cash 确认`, `Cash待确认`, `Cash已确认`, and `Cash已拒绝`
- Cash System still owns the separate `收支确认` page. This is the ledger-side confirmation entry where the Cash user approves or rejects.
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
- Historical implementation continued excluding 青空塾, CNY, non-target linkage, reimbursement, company account spending, and arbitrary school events. Under the corrected 2026-06-14 business policy, 青空塾 and CNY/RMB should enter Cash when actual money moves through a user-controlled account; arbitrary school events without real account movement still must not enter Cash.

2026-06-13 Phase 2 tuition income E2E checkpoint (historical implementation note):

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

- Historical note: this older teacher-wage direct Cash confirmation path has been superseded. Current teacher-wage Cash payment must start from `school_expense_records`; old `school_payment_requests` request types are legacy read-only and cannot be newly created.
- Current income implementation may still exclude 青空塾 and CNY/RMB income linkage.
- These are implementation limits, not the corrected business policy. The policy is: real movement through user-controlled accounts enters Cash; School keeps business ownership.
- Historical personal tuition income support is limited to personal-business `tuition` JPY income through the school outbox and manual sync executor; the new Cash-side CNY support is infrastructure for the next School implementation phase.
- Cash pending external transaction request table/RPC/UI has been applied and rollback-verified. Teacher-wage rejected -> retry -> approved backend E2E has passed; browser automation remains unstable, so page paths may be operated manually and verified through DB checks.
- Cash accepts external requests only. It must not be the originator of School business requests and must not create School business records.
- No automatic FX/account-allocation support; CNY/JPY exchange and account transfers remain manual Cash operations.
- No school DB writes.
- Teacher-wage School Edge Function bridge exists; income all-scope Cash request bridge is not complete.
- Teacher-wage payment page action exists; income page all-scope request action is not complete.
- No cross-DB transaction.
- No automatic retry worker.
- No reversal sync.
- Internal clearing / corporate-account profit-stat exclusion is not implemented yet.
- No change to ordinary JPY transaction create/update/delete paths.
- Do not run `supabase-schema.sql` for this update; it is an incremental migration checkpoint.

## Next Steps

- Real 2026-05 teacher wage trial has not been executed yet.
- Broaden School income record Cash linkage so all user-controlled-account tuition/income movements can submit Cash requests with eligible accounts. The historical personal-business JPY path is only the first implemented subset and must be broadened to the unified policy.
- Implement internal clearing / corporate-account settlement reporting exclusions separately.
- If reversal is wired, use a separate external event with `transaction_type = income`; do not delete the original Cash transaction.
- Any future Cash UI display for external rows should treat them as externally owned and avoid ordinary edit/delete unless a guarded edit/reversal design exists.
- Browser automation remains unstable for some page flows; manual page operation plus DB verification is acceptable for the current implemented path.
