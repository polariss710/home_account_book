# Codex Project Rules — Home / Cash

本文件为家庭账本（Home / Cash）项目的默认守则，2026-08-24 首次建立。
规则改编自 School V2 的 `AGENTS.md`，已按本项目实际结构调整：本项目是纯静态
前端 + Supabase，无 Edge Functions，数据访问集中在单一模块而非 `pages/` 与
`api/` 目录分层。未经核实的 School 侧规则不适用于此。

- Default to Chinese for progress updates and final reports.
- Keep prompts, plans, and outputs concise. Prefer high-signal summaries over long history.
- Start each work turn by checking `git status --short`.
- P0 highest-priority rule: frontend JavaScript must not decide, derive, round, or otherwise compute business facts that will be saved or passed as write RPC parameters. This includes monetary amounts, balances, carryovers, exchange-derived amounts, advance/settlement totals, card statement amounts, and other persisted business-result fields. Such values must come from DB/RPC authoritative results or from explicit user input. Frontend may format display values and may show non-persisted previews only when the saved value is still computed and validated by DB/RPC.
- Data-access boundary: `js/supabase.js` is the only module allowed to call Supabase `.rpc()` or to read/write tables via `.from(...)`. UI, render, state, and event modules must go through the functions it exports. As of 2026-08-24 all 32 `.rpc()` calls and both direct table writes are inside that file; keep it that way.
- This repository uses `CASH_SUPABASE_DB_URL`. Never use `SUPABASE_DB_URL`. Cross-DB verification against School may use `SCHOOL_SUPABASE_DB_URL` for read-only queries only; never write to the School DB from this project. If available, run `load_both_db >/dev/null` first. Never print, save, or commit any DB URL or secret.
- Each turn report must state whether files were changed, executed SQL files and called RPCs if any, whether the database was written, whether writes were limited to test whitelist data, test record ids when relevant, whether commit/push happened, commit hashes when relevant, the current git status, and whether the workflow completed or stopped.

## Privilege And Function Security Boundary

这一节由 2026-08-24 的生产缺陷催生，优先级等同 P0。

- Every new table must have an explicit privilege decision recorded at creation time: which roles get which grants, and whether RLS is enabled. A table created with no `GRANT` and no RLS statement is not "secure by default" — it is an unfinished object, and any later code path that touches it as a non-owner role will fail at runtime.
- Before adding any `select`, `insert`, `update`, or `delete` on a table inside a `security invoker` function, verify that the invoking role actually holds that privilege. Check with `has_table_privilege('authenticated', '<table>', '<privilege>')` against production, not by reading repository SQL.
- If a `security invoker` function must consult a table the caller cannot access, do not grant the caller access to the whole table and do not convert the entire function to `security definer`. Extract the specific predicate into a narrowly scoped `security definer` helper that returns only the boolean or minimal value needed, pin its `search_path`, set its owner explicitly, and grant `execute` only to the roles that need it.
- Guard checks fail closed in the wrong way when they cannot read their own inputs. A permission error surfaces as an opaque `42501` instead of the intended business message, and it blocks every record rather than only the guarded ones. Treat "guard cannot read the table it guards" as a P0 defect.
- Changing a function's `security invoker` / `security definer` attribute, its owner, or any table/function grant is a permission-boundary change. It requires explicit business-owner approval under the gate below.

## Full Autopilot

- Write-operation features default to full autopilot.
- The initial task prompt is the phase-level authorization for the requested feature after the Schema And Business Model Expansion Gate below passes. Do not stop at ordinary phase transitions for user confirmation. Continue through the standard workflow until completion unless a hard stop condition is hit.
- Do not ask for confirmation only because the next step is schema execution, RPC execution, rollback test, whitelisted commit test, frontend implementation, checkpoint commit, `docs/current-status.md` update, or push, when required checks have passed and the action is inside the requested feature scope.
- If rollback or commit test candidates do not match the test data whitelist, Codex may create narrowly scoped test data with explicit markers such as `codex-test`, `home-test`, `sandbox`, or the current phase id.
- Stop immediately and report when any hard stop condition occurs: an unapproved business-model expansion or a missing/incomplete/vague/unmatched expansion approval, a missing `CASH_SUPABASE_DB_URL`, unavailable `psql`, static check failure, rollback/commit test failure, abnormal git status, uncertain test-data ownership that cannot be solved by creating safe test data, need for non-whitelisted real business data, frontend JS computing persisted business-result values, a privilege or function-security-attribute change without approval, broad refactor, non-target module changes, `delete`, `truncate`, `drop`, destructive cleanup, broad historical-data modification, historical data repair, broad backfill, secrets exposure, production irreversible action, or a request/documentation conflict that cannot be safely interpreted.

## Schema And Business Model Expansion Gate

- This gate overrides phase-level authorization, full autopilot, and general wording in a task. Phrases such as "modify necessary schema", "make required DB changes", "implement the complete feature", "full autopilot", or "use the best approach" do not authorize business-model expansion.
- Explicit business-owner approval is required for each specific business-model expansion before Codex drafts business code or SQL, creates a migration, executes DDL, or changes schema. Approval of the business goal alone does not approve objects or semantics inferred by Codex.
- An approval is valid only when it identifies the exact object, the exact new or changed semantics, and the intended authority/mutability/permission behavior. Silence, lack of objection, an implementation proposal, an already-created unapproved object, previous accidental deployment, or blanket wording is not approval.
- Business-model expansion includes any new business table; business column; enum or status value; date, month, attribution, identity, source, snapshot, version, writable-fact, or authoritative-source concept; any change to an existing field's business meaning, mutability, ownership, writer, reader precedence, or locking rule; **and any change to table grants, RLS policies, function ownership, or function `security definer` / `security invoker` attributes**. Adding dual writes, fallback, `COALESCE`, or NULL-based branching to decide a business fact, and destructive schema changes such as drop, rename, type change, or semantic repurposing are also expansions.
- Every business fact must have exactly one declared authoritative source. Two writable fields must not express the same fact; different readers must not select different authorities; frontend code must not recreate a DB-authoritative fact.
- Indexes, foreign keys, check or unique constraints, triggers, comments, test fixtures, rollback tests, and postdeploy checks may proceed under normal phase-level autopilot only when they enforce an already approved model and introduce no business fact, authority, or permission boundary beyond it.
- If implementation discovers an unapproved expansion, stop immediately before drafting or changing business code/SQL. Preserve read-only findings, explain why the existing model is insufficient, provide the exact proposed object and impact contract, and wait for explicit approval.

## Schema And RPC Execution Workflow

- Before running schema or RPC SQL, check `git status --short` and the latest commit.
- Execute SQL files with `psql "$CASH_SUPABASE_DB_URL" -v ON_ERROR_STOP=1 -f <file>`.
- Never print, save, or commit any DB URL or secret.
- Treat live production as the sole authority for current deployment and runtime state. Verify it with read-only evidence such as `pg_get_functiondef`, definition hashes, `has_table_privilege`, `pg_policies`, catalog metadata, or exact postdeploy queries.
- SQL headers, `docs/current-status.md`, and other documents record historical actions and intent only. Never use an unverified document statement by itself to claim that an object is currently deployed, absent, enabled, granted, or matches the repository. `supabase-update-20260822-correction-p.sql` is a live counterexample: its header still claimed `NOT DEPLOYED` long after production execution.
- Repository SQL files are not the production function body. Some objects in this project family are deployed by patching live definitions. Always confirm against `pg_get_functiondef` before reasoning about a function's contents.
- After schema execution, run read-only verification for columns, nullable flags, FK/constraints, indexes, comments, grants, and unchanged historical data.
- After RPC execution, smoke test function existence, run rollback tests, then run a commit test only against whitelisted test data.

## Default Guardrails

- For non-write-operation tasks, keep the requested scope narrow and do not edit unrelated modules.
- Do not use real business data for automatic rollback or commit tests.
- Do not run `delete`, `truncate`, `drop`, historical data repair, broad backfill, or cleanup automatically.
- Do not skip static review, rollback test, commit test, or the `docs/current-status.md` update for a write-operation feature.
- Frontend deploys to GitHub Pages from this repository. Any change to a versioned asset must carry a forward cache-buster update; do not reuse a previous phase's cache key.

## Known Gaps (2026-08-24)

以下为建立本文件时已知、尚未处理的问题，不构成对现状的背书：

- `home_external_fixed_payment_projections` 建表时未做任何权限授予，也未启用 RLS，导致四个 `security invoker` writer 在读取它时报 `42501`。这是本文件「Privilege And Function Security Boundary」一节的直接来源。
- 本项目尚未做过 P0 计算边界的全量符合性审计。已核实的范围是：`js/supabase.js` 中传给写 RPC 的金额参数均为 `record.*` 原样透传，唯一的计算参数是 `p_year: Number(year)`（年份类型转换，非业务金额）。渲染层的数值处理未逐条核查。
- `supabase-update-20260822-correction-p.sql` 的文件头仍写着 `Phase B local draft only. NOT DEPLOYED.`，而该文件已于 2026-08-22 部署；同文件的 `home_correction_p_evidence_fingerprint_v1` 仍为 `p_amount::text`，而生产已由 0823 补丁改为 `trim_scale(p_amount)::text`，按原样重跑会覆盖回旧定义。School 侧的同类问题已于 2026-08-24 修复，本项目尚未同步。
