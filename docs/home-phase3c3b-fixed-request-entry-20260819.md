# Home/Cash Phase 3C3-B fixed request entry

Status date: 2026-08-19
Result: production deployed; entry foundation closed by card flag and School Gate.

## Baseline and scope

- Repository baseline: `main` at `3880722c6b3da48a3012a17622429b9ded58e9d8`, equal to `origin/main`, clean before work.
- Production baseline: 50 external requests, 35 JPY transactions, 75 CNY transactions, 2 fixed advances, 0 fixed requests, 0 projections, 0 cycles, 0 School fixed items.
- The sole card is `西武卡` (`9b27347e-2dce-4caf-bac0-67f053ef6c3b`), active, route disabled, version 1.
- No UI, ordinary fixed settlement/advance, 202,991 JPY classroom-rent fact, projection/item creation, statement, allocation, correction or Phase 3D behavior was changed.

## Deployed database contract

- Fixed requests require null `account_id` and `funding_account_id`; immediate requests retain non-null account behavior.
- Projection `funding_account_id` is nullable only in `unfunded`; funded/reversed states require account, transaction and timestamp. `supersedes_projection_id` is new-replacement → old-corrected, and only `projected` occupies active unique indexes.
- Referenced card currency/cutoff/inclusive/funding-day/channel/template facts are immutable. Route and active flags remain versioned. Only active card display names are unique.
- `home_get_school_fixed_card_schedule(uuid,date)` is service-only and database-authoritative for dates/months.
- `home_create_external_fixed_transaction_request(...)` verifies card ownership/currency/active/route, recomputes the schedule, requires initial target=suggested, stores structured funding-date/fingerprint evidence, and creates only a pending request.
- Exact event/idempotency replay returns the same request even after a later Gate close. Changed card/date/month/funding/amount/currency/reference evidence returns a stable identity conflict.
- Generic approve returns `HOME_FIXED_REQUEST_APPROVAL_REQUIRES_FIXED_WRITER` before any write. Rejection creates no transaction/projection/item/cycle.

## Verification

- Exact migration SHA-256: `a75aeb981e5b570851cebf28d4f22f327591a90823965e257e4287ad6dee4b06`.
- Production ROLLBACK covered day 9/10/11, 2026-08-13 → 2026-09-01/09-25, cross-year, month-end clamp, Gate/card closed, exact replay, all structured conflicts, null-account contract, initial override rejection, generic approve fail-close, card freeze, rejection and balance/downstream zero writes.
- Isolated local PostgreSQL two-session request creation produced one pending request and no projection.
- Formal postcheck: fixed request/projection/cycle/School item all 0; card route false/version 1; request fingerprint `7885061cf09eee37b62e39670286cc4e`; account fingerprint `af7a367cfc163b1a5f4a053887ceb8ce`.
- The 202,991 JPY transaction remains `01e910b8-bf54-486c-a13a-597ca9dbf684`, expense, account `b06f29c4-67cd-4d55-b39c-7cff0eab99a1`, dated 2026-08-13.

## Current hard stop

The database entry exists, but no production caller can create a fixed request because the School fixed Gate is blocked and the card route flag is false. Approval, projection, item, statement, funding, allocation and correction remain future separately authorized phases.
