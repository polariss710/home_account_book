// School projection 固定项的状态写入路由。
//
// 背景：projection 项被 home_fixed_month_items_projection_guard 冻结——除 status
// 外整行不许改，且改 status 必须挂着 phase3f_projection_status_write=on。那个标记
// 只有 home_confirm_projection_fixed_item_status 会设。
//
// Phase 3F 把这扇窄门建好了，但前端一直没接上去，导致生产里那条
// 「教室费用 / 2026-08 / 202,991 JPY」从界面点不动（2026-09-04 用户实测）。
//
// 这个测试锁住三件最容易被改回去的事：
//
//   1. 单条状态更新按 accounting_scope 分岔到专用 writer
//   2. 批量 writer **跳过** projection 项而不是整批失败，并报出跳过条数
//   3. 前端在批量之后把跳过的那些逐条补上，且「DB 说跳过了但列表里没有」
//      这种不一致不被静默吞掉
//
// 第 2 条尤其要钉住方向：修法**不是**让批量去写 projection 项。那样等于放宽
// GUC 守卫的边界，而守卫存在的理由是让这类写入显式且窄。

import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";

let assertionCount = 0;
function check(condition, message) {
  assert.ok(condition, message);
  assertionCount += 1;
}

const supabaseSource = await readFile("js/supabase.js", "utf8");
const renderSource = await readFile("js/render.js", "utf8");
const cnySource = await readFile("js/cny.js", "utf8");
const bulkSql = await readFile(
  "supabase-update-20260904-bulk-status-skip-projection.sql",
  "utf8",
);

// --- 1. 单条分岔 ------------------------------------------------------------
check(
  /function isSchoolProjectionItem\(item\)[\s\S]*?accounting_scope === "school"/.test(supabaseSource),
  "单条分岔按 accounting_scope 判定",
);
for (const fn of ["updateMonthItemStatus", "updateCnyFixedItemStatus"]) {
  const body = supabaseSource.slice(supabaseSource.indexOf(`export async function ${fn}(`));
  check(
    /isSchoolProjectionItem\(item\)\s*\n?\s*\?\s*"home_confirm_projection_fixed_item_status"/.test(
      body.slice(0, 600),
    ),
    `${fn} 对 School 项改用专用 writer`,
  );
}
// 日元与人民币都要改。只改一边，等工行卡上线又是同一个坑。
check(
  supabaseSource.split("home_confirm_projection_fixed_item_status").length - 1 >= 3,
  "专用 writer 在单条日元、单条人民币、批量补写三处都被引用",
);

// --- 2. 批量是「跳过」而不是「代写」-----------------------------------------
check(
  !/HOME_PROJECTION_FIXED_ITEM_BULK_STATUS_FORBIDDEN/.test(
    bulkSql.slice(bulkSql.indexOf("create or replace function")),
  ),
  "整批拒绝已从函数体中移除",
);
check(
  /and not public\.home_fixed_item_has_external_projection\(i\.id\)/.test(bulkSql),
  "日元批量的 UPDATE 排除 projection 项",
);
check(
  /if public\.home_fixed_item_has_external_projection\(v_item\.id\) then[\s\S]{0,120}continue;/.test(bulkSql),
  "人民币批量循环跳过 projection 项而不是中止",
);
check(
  (bulkSql.match(/skipped_projection_count/g) || []).length >= 3,
  "两个批量 writer 都报出跳过条数",
);
// 修法的方向：批量路径**不得**自己去写 projection 项。
//
// 只能在**可执行区间**里查，不能对整个文件查 —— 文件头的注释里正当地解释了
// 「为什么不走放宽 GUC 那条路」，对全文匹配会把那段散文判成违规。
// 本测试初稿就栽在这上面，而今天早些时候 School 侧的 exchange_rate 断言
// 也是同一个错。**断言源码文本时必须先划定可执行区间。**
const executable = bulkSql.slice(
  bulkSql.indexOf("create or replace function"),
  bulkSql.indexOf("\ncommit;"),
);
check(
  !/phase3f_projection_status_write/.test(executable),
  "批量 writer 不碰那个 GUC —— 放宽守卫边界不是本方案",
);
// 缩小判定范围 ≠ 取消判定
check(
  /存在未选择有效账户的人民币固定项/.test(bulkSql),
  "人民币账户预检仍在，只是排除了 projection 项",
);
check(
  /HOME_CARD_STATEMENT_ITEM_BULK_STATUS_FORBIDDEN/.test(bulkSql),
  "statement 关联项仍整批拒绝 —— 那是另一类对象，不适用跳过",
);
// 人民币那个基线没有固定 search_path，本轮不该顺手加上（安全加固不混进功能修复）
const cnyFnStart = bulkSql.indexOf("create or replace function public.home_update_cny_fixed_items_status");
const cnyFnHead = bulkSql.slice(cnyFnStart, cnyFnStart + 400);
check(
  !/set search_path/i.test(cnyFnHead),
  "人民币批量保持 proconfig 为 null，与基线一致",
);

// --- 3. 前端补写与不一致告警 ------------------------------------------------
check(
  /export async function applySkippedProjectionItems\(batchResult, items, status\)/.test(supabaseSource),
  "存在批量后补写的共用入口",
);
check(
  /请刷新后单独处理/.test(supabaseSource),
  "DB 报了跳过但列表里没有 School 项时要出声，不能静默当成已处理完",
);
for (const [name, source] of [["render.js", renderSource], ["cny.js", cnySource]]) {
  check(
    /applySkippedProjectionItems\(\s*\n?\s*result,/.test(source),
    `${name} 的一键按钮在批量之后补写 School 项`,
  );
}

console.log(`PROJECTION_STATUS_ROUTING_PASS ${assertionCount}/${assertionCount}`);
