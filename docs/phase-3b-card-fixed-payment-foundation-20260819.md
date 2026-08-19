# Phase 3B Credit-Card Fixed-Payment Database Foundation

Date: 2026-08-19

## Outcome

Phase 3B is committed to the Cash production database. It creates the database foundation for a future School credit-card fixed-payment route without opening that route or changing current immediate-account behavior.

The committed migration body SHA-256 is:

`d1d70888ea6e79d3d1c677a2dbb0efa1ee08cf0cbb722bcea60c17128dba1375`

No migration SQL was added to the repository. The rehearsal and formal transaction used the same temporary migration-body bytes. Existing ignored SQL files were read but not executed, overwritten, or moved.

## Initial Baseline and Bindings

- Git baseline before database work: `main` at `bd2e6e666d7945646af34a1bd1ed6831009f6a31`, equal to `origin/main`, ahead/behind `0/0`, clean worktree.
- Page version remained `20260819-accounting-scope-filter-2`.
- Production owner/user: `8596a708-d99f-4264-8f8c-5b89af9254b6`.
- Physical funding channel: `邮局卡` (`53af0c53-03d3-477a-944e-a9bdfbe441fc`), the sole active JPY channel with that structured identity.
- Household statement template: `西武卡消费` (`1e2cb848-7d9f-4a68-ba9d-9adc7d434b7f`), JPY expense, active, `payment_group = 邮局卡`, `accounting_scope = household`.
- Protected August item: `f43feb39-e5c8-4843-b3be-b6afc8b9392f`, `119,699 JPY`, unchanged.
- Protected August `邮局卡` expense group: `340,134 JPY`, rounded once to `341,000 JPY`, unchanged.
- External requests: 50 total; 42 approved with 42 transaction mappings, 6 pending, and 2 rejected.
- Protected classroom-rent chain remains request `ea5a7ce2-1b7a-44f3-8db7-22bb73c963bc` -> JPY transaction `01e910b8-bf54-486c-a13a-597ca9dbf684`, `202,991 JPY`, account `日元现金`. No correction was performed.

The repository has no project `AGENTS.md`. README and the current-status, module-status, system-map, and external-immutability documents were read. The live ignored-SQL list contains 27 SQL files rather than the 24 stated in the phase request; only directly related history was consulted, and production catalog definitions were authoritative.

## Schema

### `home_card_instruments`

Stores the card tool independently from its physical funding channel:

- user/name/currency identity
- cutoff day and inclusive/exclusive rule
- funding day
- funding payment-channel FK
- household statement-template FK
- active and School-route feature flags
- optimistic version and timestamps

Database validation requires the funding channel and household template to belong to the same user and currency. The template must be an active household expense template and its payment group must match the channel name. Card name is unique per user/currency, and one active household statement template cannot be bound to multiple active card instruments.

Production contains exactly one row:

- ID: `9b27347e-2dce-4caf-bac0-67f053ef6c3b`
- name/currency: `西武卡` / `JPY`
- cutoff: day 10, inclusive
- funding: day 25 through `邮局卡`
- household template: `西武卡消费`
- active: true
- School fixed route enabled: false

The card tool is active master data; “disabled configuration” means its School fixed-payment route flag is off.

### `home_card_statement_cycles`

Stores at most one row per user/card/target fixed month. The target month is a first-of-month `date`. Pending rows may have a null statement total; confirmed rows require a non-null amount greater than or equal to zero plus confirmer/time metadata.

The table intentionally has no School subtotal field. A browser cannot authoritatively store School subtotal or household remainder. Any linked household remainder item must belong to the same user/currency/month, be a household expense, and use the card's bound household template.

Production row count after commit: 0.

### `home_external_fixed_payment_projections`

Stores the immutable identity for one School expense projected to one School fixed month item:

- external request/source/reference/event/idempotency identities
- explicit School expense ID
- card, physical funding channel, and funding account
- business, charge, suggested, target, and funding dates
- separate original and settlement amount/currency fields
- fixed month item, projection/funding status, future funding transaction identity
- correction and month-override metadata
- timestamps and optimistic version

Phase 3 enforces same-currency exact settlement: original currency equals settlement currency, original amount equals settlement amount, and settlement amount status is `confirmed`. The fixed item must be a same-user/same-currency School expense in the target month and use the bound payment-group name.

Active external request, source/reference/event, and School-expense identities are unique. Fixed item, idempotency key, and non-null funding-transaction identities are unique. Ordinary UPDATE cannot change external identity, amount, currency, card, month, schedule, or fixed-item columns; a future narrow writer may update validated status/correction fields only with an advancing version. DELETE is rejected.

Production row count after commit: 0.

`funding_transaction_id` is deliberately a UUID without a direct ledger FK because the future route is currency-aware while current JPY and CNY transactions live in separate tables. Currency-specific existence and ownership validation belongs to the future narrow funding writer; Phase 3B creates no funding row.

## External Request Route Foundation

`home_external_transaction_requests` now carries:

- `payment_route`
- `card_instrument_id`
- `charge_date`
- `suggested_fixed_month`
- `target_fixed_month`
- `fixed_month_override_reason`
- `funding_account_id`
- `fixed_projection_id`
- `projection_status`

All 50 historical rows were explicitly backfilled to:

- `payment_route = immediate_account`
- `projection_status = not_applicable`
- all card/fixed-route fields null

The default remains `immediate_account`, so the unchanged legacy create writer safely creates the current route when it omits the new columns. Existing create/approve/reject/read function definitions, signatures, owners, security modes, settings, and ACLs were not changed.

The fixed route requires a School expense, enabled same-user/same-currency card, active School-eligible funding account, charge date, database-derived suggested month, target month, and exact route lifecycle. The current production card has its route disabled, so a fixed-credit-card request fails closed.

## Schedule Helper

`home_calculate_card_fixed_schedule(uuid,date)` is a postgres-owned, security-invoker, pure read helper with `search_path = pg_catalog, public`. Only postgres has direct EXECUTE.

For an inclusive day-10 cutoff:

- day 9 -> current fixed month
- day 10 -> current fixed month
- day 11 -> next fixed month
- `2026-08-13` -> `2026-09-01`, funding `2026-09-25`
- December rolls into January correctly
- a funding day beyond month end is clamped to the final valid date
- null/invalid inputs and unknown cards fail closed

`home_get_card_route_catalog(uuid)` is a second postgres-only security-invoker reader for operational binding inspection.

## RLS, ACL, and Trigger Boundary

All three new tables are owned by postgres and have RLS enabled. PUBLIC, anon, authenticated, and service_role have no direct SELECT/INSERT/UPDATE/DELETE. No policies or client business writers were created.

Five enabled triggers enforce card, cycle, request-route, projection, and projection-immutability contracts. Their trigger functions are postgres-owned SECURITY DEFINER functions with fixed `search_path = pg_catalog, public`; only postgres retains EXECUTE. The two pure helpers are SECURITY INVOKER for least privilege.

The existing CNY/JPY external immutable triggers remain enabled and unchanged.

## ROLLBACK Rehearsal

The final production rehearsal ran inside one transaction and ended with explicit ROLLBACK. It covered:

- exact production binding and baseline gates
- schema, constraint, unique-index, FK, RLS, ACL, owner, trigger, and function metadata
- historical 50-row immediate-route backfill
- active card master with disabled School route
- cutoff before/on/after, `2026-08-13`, cross-year, and month-end clamping
- unknown card, null/invalid date, wrong currency/channel/template, duplicate card name/template binding
- pending/confirmed/invalid/duplicate statement cycles
- invalid immediate/fixed route combinations and disabled production route
- one full 2099 fixed request -> School fixed item -> projection lifecycle
- duplicate projection, immutable amount update, allowed versioned funding-status update, and delete rejection
- unchanged legacy request writer defaulting to `immediate_account`
- actual anon/authenticated/service_role INSERT denial with SQLSTATE `42501`
- original table, reader, RPC, immutable-trigger, amount, status, and balance fingerprints
- SAVEPOINT fixture cleanup followed by outer ROLLBACK

Earlier rehearsal attempts stopped on test-harness assertions or deliberately stricter guards and disconnected before commit. A fresh connection after each relevant stop confirmed zero residual state. The final rehearsal completed successfully, and a new connection confirmed the three tables and route columns were absent before formal migration.

## Formal Commit and Independent Postcheck

The formal transaction used the unchanged migration-body hash and inserted no test fixture. All commit gates passed before COMMIT.

Independent read-only postcheck confirmed:

- 50 immediate-account requests; fixed route 0
- 42 approved requests with 42 mappings; 6 pending; 2 rejected
- one `西武卡` master with School route disabled
- statement cycles 0; external fixed projections 0
- School fixed items 0
- fixture residue 0
- exact protected classroom-rent chain unchanged
- `西武卡消费 = 119,699 JPY` unchanged
- `邮局卡 = 340,134 / rounded 341,000 JPY` unchanged
- all pre-existing account, payment-channel, fixed-template/item, JPY/CNY transaction, advance, and request business fingerprints unchanged
- fixed JPY/CNY, JPY/CNY account-page, and annual-summary reader fingerprints unchanged
- all 46 pre-existing home function definitions, signatures, owners, settings, and ACLs unchanged
- Phase 2 accounting-scope invariants unchanged
- both external immutable triggers still enabled

## Deferred Work

Phase 3B does not enable a School route, create a School fixed item, enter a card statement, calculate a household remainder, fund a payment group, create a compensation transaction, modify School V2, or correct the current classroom-rent data.

No group-funding/allocation table was created. A projection already provides per-School-expense allocation identity and future funding transaction identity. Phase 3E should add only a lightweight group funding header if the final writer/rounding/idempotency contract cannot be expressed safely without it.

Phase 3C should start with the request-entry and feature-flag contract. It must not infer authorization from this foundation or silently activate `fixed_credit_card`.
