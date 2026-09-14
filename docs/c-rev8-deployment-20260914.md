# C rev8 数据库部署执行报告

日期：2026-09-14。执行：Codex。授权：C rev8 部署授权、基线差异裁定及最终 helper ACL 裁定。

## 结果

数据库定义已部署；正式定义提交于 11:56:46 UTC（20:56:46 JST），reader 提交于 11:57:31 UTC。
前端 `45600709d77b68da28408bf89752d14cf07b7f3f` 未推送。本轮没有提交业务或测试数据。

## 步骤与证据

1. 重新读取生产基线，18 个原目标函数/触发器函数与前轮导出一致；追加读取配对删除入口等依赖。
   保留已裁定的事实：`home_confirm_projection_fixed_item_status` 是 postgres-owned DEFINER。
2. 前轮历史检查 ①、②全部子项、③、④a、④b、④c、⑤、⑥ 全部为 0，沿用业务负责人通过裁定。
3. 记录三个指纹，范围为用户 `8596a708-d99f-4264-8f8c-5b89af9254b6` 的所有月份。
4. 先在完整 `BEGIN ... ROLLBACK` 中创建定义并跑合成用户测试；测试通过且 ROLLBACK 明确完成。
   再核对原函数基线已恢复、三个指纹一致、合成用户残留 0。随后在单一事务中提交正式定义。
5. 正式部署后，以相同合成用户重新执行独立 `BEGIN ... ROLLBACK` 验收，C01–C30 全部通过。
6. 提交 pending reader 与指定 ACL。以 authenticated 读取，reader 集合与本人 pending 源记录集合一致：1 / 1。
7. 重新读取生产定义和目录：16 个目标函数正文与执行稿完全一致；既有函数 OID、签名、owner、
   prosecdef、provolatile、proconfig、proacl 均未改变。三张业务表及账户表结构、RLS policy 未变。
   三个原固定项触发器定义/OID/启用状态未变；新 AFTER guard 为 O。既有流水触发器未变。

逐项元数据、查询和执行输出见 `c-rev8-deployment-evidence-20260914.json`。
正文比对使用 Python 提取执行稿和生产 `pg_get_functiondef` 的 `$function$` 正文后作字符串全等比较，
结果 16/16 true；没有将迁移文件 MD5 与生产定义 MD5 混比。

## 实现范围

- 两个 helper：INVOKER、VOLATILE、postgres owner、固定 search_path；ACL 仅 postgres/authenticated。
  auth.uid 为空及 p_user_id 不匹配分别拒绝 AUTH_REQUIRED / ACTOR_MISMATCH。
  每张查询表显式按 p_user_id 过滤。
- 固定项 SELECT policy 还包含既有业务可见性 helper：隐藏未完成纠正的 replacement 项。
  新盈余 helper 显式复用该条件，避免 DEFINER 上下文绕过这层既有业务过滤。查询时隐藏项数量 0。
- 新 AFTER UPDATE/DELETE guard 按 OLD/NEW 的用户、月份、币种与已收收入贡献判定。
  不取月份锁；不同 key 或 DELETE 仅在 OLD 贡献 > 0 时检查。新增支出不受此规则拒绝。
- settlement 新字段、付款判据、调拨方向/金额、跨月补回门槛及金额 RPC 已落地。
  原 settlement 字段保留。月份锁位于外层入口，原删除 core 未改。
- 除主函数，还给收入来源相关 status/bulk/projection/sync/delete 入口加同命名空间的月份锁。
  `home_delete_fixed_transfer_pair_item` 生产 ACL 允许直接调用，因此它也在进入 core 前取得锁；
  经外层 delete_jpy 到达同一 key 时是同事务重入，不在 core 中获取锁。不改变该入口安全属性。
- 普通金额 RPC 保留关联流水、垫付及数据库 projection/statement 保护。
- 新 reader 返回本人所有月份 pending advance。没有新增表、业务列、状态值或固定项来源。

## 验证范围

合成用户：`cd091400-0000-4000-8000-000000000001`、`cd091400-0000-4000-8000-000000000002`。
账户：`cd091400-0000-4000-8000-000000000003`。记录标记 `codex-test`，账期 2098 年；
所有相关记录均在回滚事务中生成，测试流水 ID 由数据库生成，未提交。

已验证：

- 无垫付 707000 / -1117000；垫付397000后 310000 / -720000；工资到账与补充310000后归零。
- 盈余不足拒绝补回；旧方向拒绝；付款判据与赤字重置；补回成功后缺口不凭空重现；重复补回拒绝。
- authenticated 直接减少收入触发拒绝，数据保持原值，证明 guard 读到本语句的新值。
- authenticated → 既有 DEFINER 配对删除 → INVOKER guard 路径拒绝；流水未删除。
  第二个测试用户同月有9999999收入，仍不能使第一用户通过，证明未混入其他用户数据。
- 参数身份伪造拒绝；已消费后新增支出允许；负盈余月份移动 unpaid 收入允许；支出金额 RPC 可用。
- 批量收入撤销拒绝且整批原子；110500 展示盈余 / 110000 转出，留下500且不跨月结转。
- 跨月补回后原月份 settlement 全文未变，原 month_key / paid_at 不变。
- pending reader 结果集合与源集合一致。

尚未验证：

- 需要提交的争抢场景（两笔补回、补回与转出、同一垫付跨目标月竞争）。未用回滚测试冒充。
- 双会话锁等待及全部入口组合的死锁实测；当前锁顺序结论来自静态调用链核对。
- 完整前端交互与发布；本轮无前端推送授权。

接受 F8 下直写路径与 RPC 的并发残留风险；本轮未收回直写权限，也未声称实现全部串行化。

## 指纹与写入判定

表达式：`md5(coalesce(string_agg(to_jsonb(t)::text, '' order by id), ''))`。
使用整行 JSONB，包含 NULL、归属、日期、关联等全部列；顺序按唯一 id。
空集合序列化为空字符串，MD5 为 `d41d8cd98f00b204e9800998ecf8427e`，不与 NULL 或空字段混同。

| 集合 | 行数 | 部署前及部署后 MD5 |
|---|---:|---|
| 本人全部固定项 | 92 | e0e2e195321ddbf9f7604ba262709c5e |
| 本人全部垫付 | 3 | 6f81f2f45cc2865a4ebb5379facb72b0 |
| 本人 fixed_in/out、fixed_advance_in/out 流水 | 10 | d72e45b2d2882bb0d52e0c7ede09cbf1 |

结合执行记录：两次测试都有明确 ROLLBACK；两次 COMMIT 仅包含定义/新对象 ACL，没有业务 DML；
合成用户残留为0。因此本执行器未提交业务或测试数据，且上述真实业务集合前后没有观测到变化。
指纹不证明窗口中其他会话从未写入；本轮没有外部会话逐笔执行审计，不将它作为无条件历史断言。

## 已保留的限制

`home_create_fixed_transfer` 原有“同月同方向调拨项已存在则拒绝”的规则未变。
因此本轮没有开放同月多次补充/转出；新增支出可以使缺口重新为正，但既有调拨项可能继续限制再次调拨。
不通过删除垫付、虚假补回或改真实余额规避该限制。

## SQL 归档

- `supabase-update-20260914-c-rev8-body.sql`：定义正文（由事务 wrapper 调用）。
- `supabase-test-20260914-c-rev8-body.sql`：合成用户验收正文，禁止脱离回滚 wrapper 执行。
- `supabase-test-20260914-c-rev8-preflight.sql`：基线断言、定义与验收全部回滚。
- `supabase-update-20260914-c-rev8-deploy.sql`：基线断言后只提交定义。
- `supabase-test-20260914-c-rev8-postdeploy.sql`：部署后的独立回滚验收。
- `supabase-update-20260914-c-rev8-reader.sql`：reader 与指定 ACL。

本轮不重放 School 回写，不连接 School，不推送。完成本地归档提交后停止，前端发布由负责人另行裁决。
