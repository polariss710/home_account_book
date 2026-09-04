import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import {
  canRequestFixedMonthItemDelete,
  fixedMonthItemDeleteErrorMessage,
  fixedMonthItemDeleteLockLabel,
} from "../js/utils.js";

let assertionCount = 0;
function check(condition, message) {
  assert.ok(condition, message);
  assertionCount += 1;
}

// accounting_scope 是 reader 明确构造的权威字段（见 docs/current-status.md
// 2026-08-19 Phase 2B1 条目），reader 记录必然带有它，因此 fixture 也必须带。
const unpaid = { status: "unpaid", accounting_scope: "household" };
check(canRequestFixedMonthItemDelete(unpaid), "ordinary unpaid item keeps delete entry");
check(!canRequestFixedMonthItemDelete({ status: "paid", accounting_scope: "household" }), "paid item hides delete entry");
check(!canRequestFixedMonthItemDelete({ status: "settled", accounting_scope: "household" }), "settled item hides delete entry");
check(!canRequestFixedMonthItemDelete({ ...unpaid, advance_id: "advance" }), "advanced item hides delete entry");
check(!canRequestFixedMonthItemDelete({ ...unpaid, linked_jpy_transaction_id: "jpy" }), "JPY-linked item hides delete entry");
check(!canRequestFixedMonthItemDelete({ ...unpaid, linked_cny_transaction_id: "cny" }), "CNY-linked item hides delete entry");
check(canRequestFixedMonthItemDelete({ ...unpaid, projection_id: "not-reader-authoritative" }), "frontend does not guess downstream projection eligibility");

// School 来源的固定项不提供删除入口。
//
// 判据是 accounting_scope 而非 projection —— 上一条断言仍然成立：前端不猜测
// 下游 projection 资格，只依据 reader 权威给出的归属。数据库侧仍以 projection
// 为准（HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN），两者范围不完全重合，
// 前端因此比数据库更严，这是安全方向。
check(!canRequestFixedMonthItemDelete({ ...unpaid, accounting_scope: "school" }), "School item hides delete entry");
check(!canRequestFixedMonthItemDelete({ status: "paid", accounting_scope: "school" }), "paid School item hides delete entry");
// 归属缺失或非法时同样不给入口：accountingScopeKind() 会把这类记录判为 invalid
check(!canRequestFixedMonthItemDelete({ status: "unpaid" }), "item without accounting_scope hides delete entry");
check(!canRequestFixedMonthItemDelete({ ...unpaid, accounting_scope: "unexpected" }), "item with invalid accounting_scope hides delete entry");

check(fixedMonthItemDeleteLockLabel({ status: "paid", accounting_scope: "household" }) === "仅未支付可删除", "paid lock label");
check(fixedMonthItemDeleteLockLabel({ ...unpaid, advance_id: "advance" }) === "垫付锁定", "advance lock label");
check(fixedMonthItemDeleteLockLabel({ ...unpaid, linked_jpy_transaction_id: "jpy" }) === "流水已关联", "linked lock label");
check(fixedMonthItemDeleteLockLabel({ ...unpaid, accounting_scope: "school" }) === "School 项不可删除", "School lock label");
// 已付的 School 项显示 School 而非「仅未支付可删除」——后者会暗示改成未付就能删
check(fixedMonthItemDeleteLockLabel({ status: "paid", accounting_scope: "school" }) === "School 项不可删除", "paid School item keeps School label");
check(fixedMonthItemDeleteLockLabel({ status: "unpaid" }) === "归属异常", "missing scope lock label");

const expectedCodes = [
  "HOME_FIXED_ITEM_ALREADY_ABSENT",
  "HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED",
  "HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN",
  "HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN",
  "HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN",
  "HOME_FUNDED_FIXED_ITEM_DELETE_FORBIDDEN",
  "HOME_ADVANCE_FIXED_ITEM_DELETE_FORBIDDEN",
  "HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN",
  "HOME_CORRECTION_FIXED_ITEM_DELETE_FORBIDDEN",
];
for (const code of expectedCodes) {
  const message = fixedMonthItemDeleteErrorMessage({ code, message: "permission denied for table internal" });
  check(!message.includes("permission denied") && !message.includes("table internal"), `${code} maps to product copy`);
}

const unknownJpy = fixedMonthItemDeleteErrorMessage({ message: "permission denied for table home_external_fixed_payment_projections" }, "JPY");
const unknownCny = fixedMonthItemDeleteErrorMessage({ message: "permission denied for table home_card_statement_cycles" }, "CNY");
check(unknownJpy === "固定项删除失败，请刷新后重试。", "unknown JPY SQL error is hidden");
check(unknownCny === "人民币固定项删除失败，请刷新后重试。", "unknown CNY SQL error is hidden");

const [supabaseSource, renderSource, cnySource, indexSource, configSource] = await Promise.all([
  readFile(new URL("../js/supabase.js", import.meta.url), "utf8"),
  readFile(new URL("../js/render.js", import.meta.url), "utf8"),
  readFile(new URL("../js/cny.js", import.meta.url), "utf8"),
  readFile(new URL("../index.html", import.meta.url), "utf8"),
  readFile(new URL("../js/config.js", import.meta.url), "utf8"),
]);

const jpyDeleteSource = supabaseSource.slice(
  supabaseSource.indexOf("export async function deleteMonthItem"),
  supabaseSource.indexOf("export async function deleteJpyTransaction"),
);
const cnyDeleteSource = supabaseSource.slice(
  supabaseSource.indexOf("export async function deleteCnyFixedItem"),
  supabaseSource.indexOf("export async function deactivateAccount"),
);
check(jpyDeleteSource.includes("fixedMonthItemDeleteErrorMessage") && !jpyDeleteSource.includes("error.message"), "JPY RPC hides raw SQL errors");
check(cnyDeleteSource.includes("fixedMonthItemDeleteErrorMessage") && !cnyDeleteSource.includes("error.message"), "CNY RPC hides raw SQL errors");
check(renderSource.includes("canRequestFixedMonthItemDelete(item)"), "JPY row uses known-state delete eligibility");
check(cnySource.includes("canRequestFixedMonthItemDelete(item)"), "CNY row uses known-state delete eligibility");
check(!renderSource.includes("删除会同步删除对应流水"), "JPY confirmation no longer promises linked deletion");
check(!cnySource.includes("删除可能同步清理对应流水"), "CNY confirmation no longer promises linked deletion");
check(renderSource.includes("关联流水不会被同步删除"), "JPY confirmation states linked rows remain");
check(cnySource.includes("关联流水不会被同步删除"), "CNY confirmation states linked rows remain");
// 三条断言并存，防的是两种不同的失误。
//
// 前两条防「忘记 bump」：改了 JS 却没更新版本号，浏览器继续用缓存里的旧模块。
// 这个保护只能由测试提供——.github/workflows/pages.yml 里只有 checkout、上传与
// Pages 部署，没有任何版本前移检查，所以「发布流程会覆盖」这个想法不成立。
// 代价是每次 bump 都要同步改这里的 expectedVersion，那是有意的：它就是 bump 的
// 检查点。
//
// 第三条防「只改一处」：importmap 与 APP_VERSION 不一致时，模块缓存会部分失效、
// 部分不失效，页面上新旧代码混跑，症状难以复现。
//
// 2026-09-03 曾一度把前两条替换成纯一致性检查，被审核驳回——理由即上面那条对
// pages.yml 的实际核查。
const expectedVersion = "20260904-projection-bulk-skip-1";
const indexVersion = indexSource.match(/\?v=(\d{8}-[a-z0-9-]+)/)?.[1];
const configVersion = configSource.match(/APP_VERSION\s*=\s*"(\d{8}-[a-z0-9-]+)"/)?.[1];
check(indexVersion === expectedVersion, "index asset version advanced");
check(configVersion === expectedVersion, "runtime version advanced");
check(indexVersion === configVersion, "index and runtime versions stay aligned");
check(!supabaseSource.includes("home_fixed_month_item_delete_authorizations"), "frontend never touches the authorization table");
check(!supabaseSource.includes("fixed_month_item_delete_actor"), "frontend never sets delete actor context");
check(!supabaseSource.includes("fixed_month_item_delete_writer"), "frontend never sets delete writer context");

console.log(`PHASEB_DELETE_FRONTEND_MOCK_PASS ${assertionCount}/${assertionCount}`);
