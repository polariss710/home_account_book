// 迁移文件头部区的注释完整性。
//
// 本项目的迁移文件都有一大段头部说明（为什么改、语义声明、回滚步骤），全部用
// `--` 行注释。反复编辑那段文字时，很容易漏掉某一行的 `--` 前缀——那一行就会
// 被当成可执行 SQL，文件在部署时直接语法错误。
//
// 2026-09-05 真发生过一次：修正一段措辞时漏了前缀，文件从那一刻起就是不可执行的，
// 而肉眼完全看不出来（周围全是中文，缺个 -- 不显眼），也没有任何检查会碰它——
// 本机没有离线的 PostgreSQL 解析器，`psql -f` 又需要连库。
//
// 所以退而求其次：**头部区（第一条 \set 或 begin; 之前）的每一行，
// 要么是空行，要么必须以 -- 开头。** 这不能替代真正的语法检查，
// 但恰好覆盖了那个反复编辑、最容易出错的区域。

import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";

let assertionCount = 0;
function check(condition, message) {
  assert.ok(condition, message);
  assertionCount += 1;
}

const files = (await readdir(".")).filter(
  (name) => name.startsWith("supabase-update-") && name.endsWith(".sql"),
).sort();

check(files.length > 0, "至少能找到一个迁移文件");

for (const name of files) {
  const lines = (await readFile(name, "utf8")).split("\n");

  // 判据不是「在头部区」，而是「这一行像散文」。
  //
  // 初稿按 SQL 关键字划头部区，连着误报两次：一个老文件第一行就是 drop function，
  // 另一个用了 lock table 而我的关键字表里没有。**追关键字是无底洞。**
  //
  // 换个角度：本项目的说明文字是中文，SQL 是 ASCII。所以
  // 「不以 -- 开头、却含中日韩字符」的行，几乎必然是掉了前缀的注释。
  //
  // 唯一的合法例外是**中文字符串字面量**（错误信息里有中文），它们必然带引号，
  // 所以再排除含引号的行。这两条合起来误报率极低，而且不依赖任何关键字表。
  const CJK = /[\u4e00-\u9fff\u3000-\u303f\uff00-\uffef]/;
  const bare = [];
  for (let i = 0; i < lines.length; i += 1) {
    const trimmed = lines[i].trim();
    if (!trimmed || trimmed.startsWith("--")) continue;
    if (!CJK.test(trimmed)) continue;
    if (trimmed.includes("'") || trimmed.includes('"')) continue;
    bare.push(`${i + 1}: ${lines[i].slice(0, 60)}`);
  }

  check(
    bare.length === 0,
    `${name} 头部区有未加 -- 的裸行，部署时会是语法错误：\n    ${bare.join("\n    ")}`,
  );
}

console.log(`SQL_HEADER_LINT_PASS ${assertionCount}/${assertionCount}（${files.length} 个迁移文件）`);
