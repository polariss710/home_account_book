# System Map

Status date: 2026-06-13

## Core Tables

- `home_accounts`: account master data for JPY/CNY accounts.
- `home_payment_channels`: fixed item payment channel grouping, not a balance ledger.
- `home_jpy_transactions`: JPY ledger movements.
- `home_cny_transactions`: CNY ledger movements.
- `home_fixed_templates`: recurring fixed item templates.
- `home_fixed_month_items`: generated monthly fixed items.

## Core RPCs

- `home_get_jpy_account_page(text)`: reads JPY accounts, balances, and month transactions.
- `home_update_jpy_transaction(...)`: updates ordinary JPY transactions.
- `home_delete_jpy_transaction(uuid)`: deletes ordinary JPY transactions.
- `home_create_external_jpy_transaction(...)`: creates idempotent external-source JPY transactions for aozora school Phase 1 linkage.

## External JPY RPC Boundary

`home_create_external_jpy_transaction(...)` only writes `home_jpy_transactions`.

It does not write:

- `home_cny_transactions`
- `home_fixed_month_items`
- `home_fixed_templates`
- `home_payment_channels`
- any school table

It requires an active JPY `home_accounts` row and a positive amount.

## Balance Rule

Balances remain read-time calculations from `opening_balance` plus transaction movements. The external JPY RPC only inserts a normal JPY `income` or `expense` row with external metadata; it does not store a cached account balance.

## Cross-Project Boundary

Cash System now has the DB/RPC primitive needed by the school project. The school project owns mapping/outbox state and the manual Phase 1 sync executor. Cash System receives idempotent RPC calls and stores external JPY rows with `created_by_external = true`.

Verified Phase 1 E2E test:

- Cash account: `94000000-0000-4000-8000-000000150501`
- Cash JPY transaction: `fbd3e5df-14be-4b3b-9a0b-319f4416968b`
- school payment request reference: `94000000-0000-4000-8000-000000150101`

Remaining out of scope: CNY linkage, reversal sync, automatic background retry, Cash UI changes for external rows, and cross-DB strong transactions.
