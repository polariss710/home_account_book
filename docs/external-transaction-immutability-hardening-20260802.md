# Cash External Transaction Immutability Hardening

Date: 2026-08-02

## Outcome

CNY and JPY external transactions are immutable across UI, ordinary RPC, RLS,
table ACL, and database trigger layers. Ordinary manual Cash transaction CRUD
remains available. The complete 30-item acceptance matrix passed and all write
fixtures were rolled back.

## Database Cutover

Executed against `CASH_SUPABASE_DB_URL`:

- `supabase-update-20260802-external-transaction-immutability.sql`

Installed or replaced:

- `home_guard_external_transaction_immutable()` owned by `postgres`, security
  definer, fixed `search_path = pg_catalog, public`;
- enabled CNY/JPY `BEFORE UPDATE OR DELETE` triggers;
- four minimum authenticated RLS policies per transaction table;
- ordinary CNY/JPY update/delete RPC fail-closed guards, row locks, fixed search
  path, and execute ACL limited to authenticated/service role plus owner;
- removal of anon/PUBLIC transaction write and ordinary RPC execute privileges.

No account, request, CNY transaction, or JPY transaction row was changed by the
cutover.

## Test Matrix

- Backend items 1–24: PASS 24/24.
- UI items 25–28: PASS. The browser contract additionally separated canonical
  external-source detection from `created_by_external` display text.
- Item 29: fixture transaction rolled back.
- Item 30: fixture residue 0.

Rollback fixtures used only the `f3f10000-*` namespace, including fixture
accounts `f3f10000-0000-4000-8000-00000000c001` and
`f3f10000-0000-4000-8000-00000000c002`. No real transaction was used for a
write test.

## UI Contract

Version: `20260802-external-transaction-immutable-1`.

- Canonical external rows show `School同步生成` and no edit/copy/delete action.
- Amount, description, and note render as read-only text.
- Defense-in-depth handlers refuse externally sourced edit/delete attempts.
- Ordinary manual CNY/JPY rows retain edit/copy/delete controls.
- CNY uses two decimals: `1120.50` renders as `1,120.50 CNY`.
- JPY continues to use zero decimals.

## Protected Real Baseline

| Object | Postdeploy evidence |
|---|---|
| Cash accounts | `7 / 89b057e2cdeb7324ef73f73e252174f1` |
| Cash requests | `35 / 4a7319eb294222cb5057ecfe262a885f` |
| CNY transactions | `64 / 8e5f62d1e256228b956ca7155bed65db` |
| JPY transactions | `31 / 95ab7cf8a8d167e9b052d3fc6b64614b` |
| 袁振轩 transaction | `2feb333c-6228-4f57-a1fa-c8aa3d40616c` |
| 袁振轩 row MD5 | `7c94d3e343e26713a54e779e1d3b53da` |
| 余额宝 balance | `111041.82 CNY` |
| 余额宝 expenses | `37 / 124069.05 CNY` |

The older balance checkpoint was `111441.82 CNY`. The `400.00 CNY` decrease
was explicitly confirmed by the business owner as a legitimate ordinary Cash
expense. Codex did not modify, delete, roll back, reinterpret, or use that
operation for testing. The refreshed 64-row CNY fingerprint above is the
predeploy and postdeploy baseline.

## Writes and Residue

- Persistent Cash database write: security DDL/RLS/ACL/RPC deployment only.
- Persistent business-row writes by hardening: 0.
- Rollback-only fixture writes: yes, fixed `f3f10000-*` whitelist.
- Fixture residue: 0.
- Real business transaction delta caused by hardening: 0.
