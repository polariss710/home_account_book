# Home Phase 3D Fixed Approval and Projection

Status date: 2026-08-19

## Outcome

The Cash database now has the dedicated fixed-request approval contract required by the School credit-card route, but the route remains closed. Approval is an atomic database transition from one valid pending fixed request to exactly one unpaid School JPY fixed month item, one immutable projection and one approved request. It does not create a Cash ledger transaction, change an account balance, record funding or enable a Gate.

## Production Objects

- `home_approve_external_fixed_transaction_request(uuid)`: postgres-owned, `SECURITY DEFINER`, fixed `search_path=pg_catalog, public`, executable only by authenticated.
- `home_get_external_fixed_approval_evidence(uuid)`: postgres-owned, `SECURITY DEFINER`, fixed search path, executable only by service_role.
- `home_apply_external_fixed_transaction_approval(uuid,uuid)` and `home_build_external_fixed_approval_evidence(uuid)`: owner-only cores.
- `home_lock_card_fixed_month(uuid,date)`: owner-only transaction-scoped advisory lock helper.
- `home_guard_projection_linked_fixed_item()` plus enabled `home_fixed_month_items_projection_guard`: final defense against UPDATE/DELETE of projection-linked items.
- `home_external_requests_fixed_projection_unique`: one request per non-null projection identity.

The request's immutable `user_id`, which the authenticated entry verifies against `auth.uid()`, is returned as the approval actor. The schema has no separate `approved_by` column; no unapproved column was invented.

## Atomic and Idempotency Contract

Lock order is request row, card row, deterministic card/month advisory lock, cycle, projection/item and advance facts. The writer revalidates route, status, identity, currency, DB-computed schedule, target month, due date, payment group, statement state, existing funding/advance state and one-to-one identities before writing.

Exact replay of an already approved request returns the same typed evidence. Rejected requests, evidence mismatch, duplicate identity, confirmed statement cycle, prior group funding/advance, disabled route, schedule drift and corrupt partial state fail closed. An approve/reject race can have only one terminal result.

Projected items cannot be changed by direct DML or by the existing single-status, bulk-status, delete, template-sync or fixed-advance writers. Ordinary fixed items continue to use the prior settlement, deficit/surplus, one-click-paid and advance contracts.

## Verification

- Exact production SQL body compiled and executed inside a full ROLLBACK rehearsal.
- Positive approval and exact replay passed.
- Three independent forced failures after item insert, projection insert and request update each left no residue.
- Negative coverage passed for route disabled, rejected request, schedule mismatch, confirmed cycle, existing funding/advance, direct mutation and every generic fixed-item writer.
- ACL checks passed; only authenticated can invoke approval and only service_role can read callback evidence.
- An isolated clone with two independent PostgreSQL sessions passed approve/approve and approve/reject races with one projection/item only.
- A first formal invocation omitted an explicit transaction and stopped at the opening `LOCK TABLE` before any DDL. The unchanged state was verified, then the exact file was deployed with explicit `BEGIN/COMMIT` and postchecked.

Formal postcheck: 50 requests, 0 fixed requests, 0 projections, 0 cycles, 0 School fixed items, 70 total fixed items, 35 JPY transactions, 75 CNY transactions and 2 fixed advances. Request fingerprint remains `7885061cf09eee37b62e39670286cc4e`; account fingerprint remains `af7a367cfc163b1a5f4a053887ceb8ce`. The existing 202,991 JPY classroom-rent request/transaction is unchanged.

## Closed Gates and Deferred Work

`西武卡.is_school_fixed_route_enabled=false` at version 1 and School `cash_fixed_credit_card_route_enabled=blocked`. No real fixed request or approval was invoked. Activation, live-path testing, statement entry/funding and any UI entry remain separate later phases. Cash page version remains `20260819-accounting-scope-filter-2`.
