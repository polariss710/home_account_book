# Home Phase 3E Card Statement Confirm and Reopen

Status date: 2026-08-19

## Outcome

Phase 3E deployed the Home database contract for credit-card statement preview, confirmation, explicit reopen and reconfirm. It remains operationally closed: there is no page entry, the School fixed Gate is blocked, the card route flag is false, and production contains no fixed request, projection, cycle, revision or School fixed item. No real statement confirm/reopen was invoked.

The exact formally deployed migration SHA-256 was `bb7baba4a1b11d18bcb052eef47a62f5f8f12fe57d19ccbb9ef08c88abcb17c5`.

## Database Authority

The browser will eventually provide only card, target month, complete statement total, expected cycle version and operation identity. PostgreSQL computes:

`household remainder = statement total - School subtotal`

School subtotal is the sum of an ordered DB manifest containing only fully consistent approved fixed request → active projected/unfunded projection → unpaid School JPY fixed-item chains for the same user/card/month. The manifest records request, projection, item, School expense, event, amount, currency, card and target month. Its SHA-256 is generated from canonical ordered JSON; zero School items use `[]`, whose production fingerprint is `4f53cda18c2baa0c0354bb5f9a3ecbe5ed12ab4d8e11ba873c2f11161202b945`.

Any approved-request/projection count mismatch, identity mismatch, amount/currency mismatch, funded/corrected/reversed fact or invalid School item fails the whole calculation. Pending requests are excluded rather than silently included.

## Preview and Household Item

`home_preview_card_statement(uuid,date,numeric)` is authenticated-only and read-only. It does not create a cycle, generate a month, update an item or advance a version. It returns the computed values, current cycle state/version, exact item identity, blockers and `can_confirm`.

The only eligible household item is the unique row identified by card-bound `household_statement_template_id + user + target month`. It must be household, JPY, expense, unpaid, unlinked, unadvanced and use the bound payment channel. Name/note matching is never used. A missing item returns `HOME_CARD_STATEMENT_HOUSEHOLD_ITEM_MISSING`; confirm leaves no pending cycle. Production has the unique August item `f43feb39-e5c8-4843-b3be-b6afc8b9392f` at 119,699 JPY and no September item, so the read-only September postcheck correctly returned the generation blocker.

The existing table contract already permits amount zero, so statement total equal to School subtotal stores a zero household remainder without weakening ordinary item constraints.

## Cycle and Append-Only Revision

`home_card_statement_cycles` now uses pending version 0 before first confirmation. A confirmed snapshot contains statement total, School subtotal, household remainder, manifest fingerprint, household item, actor/time and the current confirm revision. Reopen advances one version and clears current confirmed financial fields while retaining the controlled household-item identity and latest operation audit.

`home_card_statement_cycle_revisions` stores one immutable row per cycle version with action `confirm`, `reopen` or `reconfirm`, all amounts, full manifest/fingerprint, item before/after amount, actor, DB time, reason, operation key and payload fingerprint. It is postgres-owned, RLS enabled, has no client DML grants, rejects direct INSERT outside the owner core and rejects every UPDATE/DELETE.

## Confirm, Reopen and Idempotency

`home_confirm_card_statement(...)` and `home_reopen_card_statement(...)` are postgres-owned `SECURITY DEFINER`, fixed to `search_path=pg_catalog, public`, and executable only by authenticated. Their cores and evidence helpers are postgres-only.

First confirm changes pending 0→confirmed 1. Reopen requires a nonempty reason, restores the exact latest confirm `item before` amount and changes confirmed 1→pending 2. Reconfirm is a normal fresh calculation and changes pending 2→confirmed 3. Every real transition increases version exactly once.

Exact operation replay returns its original revision without changing item/version. Reusing the operation key with another payload conflicts. A confirmed cycle rejects a new confirm key with `HOME_CARD_STATEMENT_REOPEN_REQUIRED`. Reopen refuses an item state change, group advance/funding or any School manifest/funding/correction drift.

## Shared Lock and Late Requests

Confirm/reopen lock the card, call Phase 3D `home_lock_card_fixed_month(uuid,date)`, then lock the cycle/item. They do not acquire request/projection row locks. Fixed approval keeps request→card→advisory order, so there is no inverse wait edge:

- approval first: statement sees the approved projection in its manifest;
- statement first: approval sees confirmed cycle and returns `HOME_FIXED_APPROVAL_STATEMENT_CONFIRMED`.

New fixed request creation now locks card/month and checks the confirmed cycle before insert. A genuinely new late request returns `HOME_CARD_STATEMENT_REOPEN_REQUIRED`; exact pre-existing request identity replay remains recoverable. A pending request created before confirm is excluded, and its later approval is rejected until reopen.

## Item Protection

The existing fixed-item final-defense trigger now also protects every cycle-linked household item, including reopened pending cycles. Direct UPDATE/DELETE and ordinary single-status, bulk-status, delete, template/month sync and advance writers fail before changing it. Only statement confirm/reopen can change amount; future Phase 3F must add its own narrow status/funding contract. Projection-linked School-item protection is unchanged.

## Verification

- Exact migration body plus full production fixture matrix completed inside one transaction and ROLLBACK.
- Preview zero-write, missing/duplicate/invalid household item, zero/nonzero subtotal, zero remainder, total-below-subtotal, optimistic version, operation conflict, confirm/reopen/reconfirm, late create/approve, direct DML, generic writer, ACL/RLS and ordinary-item regression passed.
- Forced failures after household item update, revision insert and cycle update each left no cycle/revision/item change.
- Isolated clone with independent PostgreSQL sessions passed confirm/confirm, confirm→reopen, approve→confirm and confirm→new-request races with 10-second lock and 20-second statement timeouts; no deadlock or timeout occurred.
- One earlier rehearsal exposed that a blocked missing-item confirm left a version-0 pending cycle. The core was corrected to validate before creating the initial cycle, and both the full ROLLBACK and concurrency matrices were rerun successfully with the final bytes.

Formal postcheck: 50 requests, 0 fixed requests, 0 projections, 0 cycles, 0 revisions, 0 School fixed items, 70 fixed items, 35 JPY transactions, 75 CNY transactions and 2 advances. Request/account/fixed-item/template fingerprints remain `7885061cf09eee37b62e39670286cc4e`, `af7a367cfc163b1a5f4a053887ceb8ce`, `bc0341743e7c76e269c17d7d80036ec1`, and `274a5e00b8bd44ad9704fdc362b0d3fa`. Existing fixed/year reader definitions and the 202,991 JPY classroom-rent chain are unchanged.

## Deferred Boundary

Phase 3E creates no transaction, balance, payment-group rounding, advance allocation or funding fact. It does not modify `home_get_year_summary`, accounting-scope statistics, pages, School database or Edge. Phase 3F may separately introduce the 25-day group funding/allocation writer, but must reuse cycle revision evidence, shared card/month locking and cycle-linked item protection.

The task expected 27 ignored SQL files, while the live repository had 32 before Phase 3E. The two new Phase 3E SQL artifacts are also ignored, so 34 are now present. No pre-existing ignored SQL was deleted, overwritten, moved or force-added.
