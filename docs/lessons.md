# 教训清单

**每轮开工前先读这份文件。** 这里只记会导致返工或事故的东西，不记一般经验。

写法约定：

- 每条给出**可执行的检查动作**，不是感想。写「动手前查 proacl」，不写「要小心权限」
- 附出处（日期、现象），让后来者能判断是否仍然适用
- 被证伪或不再适用的条目**划掉但不删**，删掉就等于把踩坑的过程也抹了

---

## A. 权限与 ACL

### A1. `revoke from anon` 与 `revoke from public` 互不覆盖

PostgreSQL 语义：

```
revoke ... from anon     只撤「直接授予 anon」的部分，不影响 PUBLIC
revoke ... from public   只撤 PUBLIC，不影响「直接授予 anon」的部分
```

**必须先看 ACL 判断权限来源，再决定撤哪个。**

出处：2026-08-28 School 侧收 anon 权限，第一轮对 23 个函数执行
`revoke ... from anon`，验证显示「已收回」，实际一条都没生效——那些函数的权限
来自 PUBLIC（ACL 中的 `=X/postgres`）。白干一轮。

同一天遇到两种来源：函数是 PUBLIC 授予，表是直接授予 anon。不能一律照抄。

### A2. `has_*_privilege()` 会把继承权限算进去，测不出 revoke 效果

`has_function_privilege('anon', ...)` 在权限来自 PUBLIC 时同样返回 true，
所以它**既证明不了成功也证明不了失败**。

判据要用 `proacl` / `relacl` 直接匹配：

```sql
array_to_string(proacl, ',') ~ '(^|,)=X'      -- 有无 PUBLIC 项
array_to_string(proacl, ',') ~ 'anon='        -- 有无直接授予 anon
```

出处：同 A1。当时用 `has_function_privilege` 做复核，报告「剩余 0」，实际全部还在。

### A3. 新建/重建函数前，先查它**原本**的 proacl，别套模板

Supabase 的 default privileges 会给 postgres 新建的函数自动授予
`anon` / `authenticated` / `service_role` 三个角色。所以重建一个函数时，
若不显式撤销，ACL 会比原来更宽。

撤到什么程度取决于该对象原本的定位：

| 类型 | 目标 ACL |
|---|---|
| 对外 writer | `revoke from public, anon` + `grant to authenticated` |
| 内部 helper | `revoke from public, anon, authenticated, service_role` |

部署后复核 `proacl` 是否与预期**精确相等**，不要只查「有没有 anon」——
三个角色任一残留都是权限边界变化。

出处：2026-09-01 配对删除 Step A 要重建
`home_check_fixed_month_item_delete_eligibility`。该函数 proacl 本来是
`{postgres=X/postgres}`，纯内部 helper，只被两个 SECURITY DEFINER 以 postgres
身份调用。按「对外 writer」的模板重建，会凭空给 authenticated 与 service_role
开出入口。审查在部署前拦下。

注：这条本身是**修正**——2026-08-31 最初写的模板是
`revoke from public, anon; grant to authenticated`，那个假定了所有函数都对外，
是错的。

### A4. RLS 不约束 TRUNCATE

表启用 RLS、policy 写得再严，`TRUNCATE` 照样清空整表。收权限时要单独看
TRUNCATE。

出处：2026-08-30 Home 侧盘点，5 张表对 anon 授予 TRUNCATE
（`home_accounts`、`home_external_transaction_requests`、
`home_fixed_advance_payments`、`home_fixed_templates`、`home_payment_channels`）。
当时未发现匿名调用路径，但权限本身不应保留。**截至本文件建立时仍未处理。**

### A5. 视图不受 RLS 保护

视图权限完全由 grant 决定（除非 `security_invoker`）。盘点时若按
`relkind='r'` 筛选会把视图整批漏掉。

出处：2026-08-27 School 侧盘点漏了 3 个 `school_v_*_summary` 视图，
第二轮才发现它们对 anon 全权限开放。Home 侧 public schema 无视图，暂不适用。

---

## B. 磁盘 SQL 与生产的关系

### B1. 磁盘上的 SQL 文件不等于生产，改之前必须逐对象比对

Home 的 `.gitignore` 含 `*.sql`，磁盘 62 个文件只有 28 个进了 git。
且同一个函数常散落在多个历史文件里（`home_create_fixed_transfer` 有三份，
`home_update_fixed_month_item_status` 有七份）。

**改任何函数前，先从生产 `pg_get_functiondef` 导出实际定义作为基线。**

出处：2026-08-31 建立 Phase 3F 基线时发现
`home_update_fixed_month_item_status` 的 08-19 磁盘版仍在 SECURITY INVOKER
函数体内直接 `exists` 查封闭表，而生产版已改为调用两个 SECURITY DEFINER
helper——那是 08-24 invoker privilege 修复的结果，磁盘上毫无痕迹。若拿磁盘版
当基线修改，会把该修复覆盖回去。

基线文件：`supabase-baseline-20260831-fixed-chain-production.sql`

### B2. 某些对象的建表语句在磁盘上根本不存在

`home_external_fixed_payment_projections` 的 `create table` 语句全项目找不到，
只在 rollback 测试文件里被引用。要它的结构只能查生产
`information_schema.columns` 与 `pg_constraint`。

出处：2026-08-31 设计 Phase 3F 时需要确认 `funding_status` 的取值约束。

---

## C. 复用既有函数前的检查

### C1. 只看签名不够，必须读完业务规则

出处：2026-09-01。`home_delete_fixed_month_item_core` 看起来是「新边界提供的
删除通道」，我读了签名和前 25 行就拿来用了。实际它有 **9 条拒绝规则**，其中
两条正好挡住固定调拨项：

```
HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN         仅允许 unpaid
HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN 拒绝有关联流水的
```

而 `home_create_fixed_transfer` 创建的项**写死 `status='paid'` 且带
`linked_jpy_transaction_id`**——两个函数天然不兼容。补丁写完了才在部署前
被审查拦下。

### C2. 触发器可能重跑同一套检查，改函数不等于改行为

`home_guard_fixed_month_item_delete_contract`（BEFORE DELETE 触发器）第 11 行
会**再次调用** `home_check_fixed_month_item_delete_eligibility`。

所以放宽 core 里的检查毫无用处——DELETE 真正执行时触发器会把它挡回来。
改删除相关逻辑时，**必须同时检查有没有触发器在做同样的事**。

出处：同 C1 的后续。第二版方案（只改 core 加参数）也是错的，读了触发器才发现。

### C3. `home_fixed_month_items` 的删除有三层保护

1. 表级 `revoke delete, truncate from authenticated`（2026-08-21）
2. `home_guard_fixed_month_item_delete_contract` 触发器：重跑 eligibility +
   要求存在 authorization 记录并消费它
3. `home_fixed_month_items_projection_guard` 触发器：projection 项无条件拒绝
   DELETE，UPDATE 需 Phase 3F 的 GUC 例外

任何绕过 `home_delete_fixed_month_item_core` 的删除都会失败——core 会插入一条
authorization 记录，触发器消费它；没有这条记录就抛
`HOME_FIXED_ITEM_DELETE_AUTHORIZATION_REQUIRED`。

**所以「另写一个删除函数」这条路走不通，只能复用 core。**

---

## D. 数据模型的隐含约束

### D1. projection 表禁止跨币种

```sql
home_external_fixed_projections_amount_check
  CHECK (original_amount = settlement_amount)
home_external_fixed_projections_same_currency_check
  CHECK (original_currency = settlement_currency)
```

虽然表里有 `original_*` 和 `settlement_*` 两组字段、`currency_check` 也允许
JPY 和 CNY，但这两条强制它们相等——**设计上假定了原币 = 结算币**。

工行卡（JPY 消费 / CNY 结算）需要先放开这两条约束。这比「批准核心硬编码 JPY」
更根本：那个是函数里一行判断，这个是表级约束。

出处：2026-08-31 设计工行卡阶段二时发现。

### D2. `funding_status = 'funded'` 必须带真实交易

```sql
home_external_fixed_projections_funding_lifecycle_check
  funded 时要求 funding_account_id / funding_transaction_id / funded_at 三者非空
```

而本系统的 JPY 还款动作（把钱存入扣款卡）**不产生任何交易记录**，
所以 `funding_status` 恒为 `unfunded`。这不是异常。

CNY 侧不同：`home_update_cny_fixed_item_status` 标记已付时会经
`home_upsert_cny_fixed_transaction` 自动生成流水，那笔流水可以充当
`funding_transaction_id`。因此工行卡的 projection 有条件真正推进到 funded，
与西武卡不对称。

出处：2026-08-31 Phase 3F 设计。

### D3. `month_key` 是还款月，不是消费月

固定调拨与信用卡固定项的 `month_key` 跟的是**用户实际还款的那个月**，
且恒等于 `due_date` 所在月。

- 西武卡：8/15 消费 → 8/10 已结算故进下期 → 9/18 出账单 → 9/25 存钱
  → `month_key = 2026-09`
- 工行卡：9/15 消费 → 9/28 出账单 → 10/15 还款 → `month_key = 2026-10`

出处：2026-08-31 与业务负责人确认。该规则已稳定运行十年以上。

---

## E. 流程

### E1. 生产改动前先建立基线，且基线要从生产导出

见 B1。基线文件放仓库根目录，命名
`supabase-baseline-<日期>-<范围>-production.sql`，文件头写明导出时间、
与磁盘历史文件的差异、以及仍在版本控制之外的对象。

### E2. 改动后与基线 diff，确认只改了该改的

每次改函数后跑一次逐行 diff，输出「新增 N 行 / 删除 M 行」并逐条列出。
若改动行数超出预期，说明动了不该动的地方。

出处：这个习惯在 2026-08-31 Phase 3F 和配对删除 Step A 都发挥了作用——
Step A 的 diff 显示「新增 8 删除 2，只动了两条检查」，其余七条逐字未改，
这是可以交付审查的证据。

### E3. 验证要能证伪

设计验证步骤时问一句：**如果改动是错的，这个检查会不会失败？**

反例：2026-08-28 用 `has_function_privilege` 验证 revoke 效果，那个检查
无论成功失败都返回同样结果，等于没验。

正例：Phase 3F 部署后验证「GUC=on 时改 amount 应被拒」——如果
`(to_jsonb(new)-'status')` 那个条件写错，这条一定会失败。

### E4. 「该失败的」验证比「该成功的」更重要

前者失败 = 保护被拆坏了，比功能没做成严重得多。

出处：Phase 3F 部署时列了 7 项保护性验证（普通 writer 仍拒绝、DELETE 仍禁止、
GUC=on 改 amount/due_date 仍拒绝等），全部通过才算数。
