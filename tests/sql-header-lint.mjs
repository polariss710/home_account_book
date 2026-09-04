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
// ---------------------------------------------------------------------------
// 判据（第三版。前两版都是被自己的误报或漏检推翻的）
// ---------------------------------------------------------------------------
//
//   有 \set / begin; 标记的文件 → **严格**：标记之前每个非空行都必须以 -- 开头
//   没有该标记的老文件         → **启发式**：不以 -- 开头却含中日韩字符的行可疑
//
// 为什么这么分：
//
//   第一版对所有文件用严格规则，被 supabase-update-20260529-fixed-10.sql 误报。
//   那种老文件没有事务包裹、第一行直接是 drop function，于是「标记之前」等于整个
//   文件，正常 SQL 全被判成裸行。
//
//   第二版改成纯启发式（含中文 + 不含引号），躲开了误报，却**漏检**——
//   审核 2026-09-05 用本仓库的真实例子打穿：
//   supabase-update-20260904-card-household-template-optional.sql 第 28 行
//     direction='expense'、accounting_scope='household'、payment_group 等于还款渠道名
//   是中文散文，但含 'expense' 的引号，被「跳过含引号的行」放走。
//   纯 ASCII 的注释行（`-- see also foo.sql`）掉前缀同样漏检。
//
//   第三版的要点：**新格式文件根本不需要启发式。** 它的头部边界是确定的，
//   直接严格要求即可，ASCII 与含引号的散文一并覆盖。启发式退化成只给没有边界
//   标记的老文件兜底——那里仍会漏检含引号的中文散文，但那些文件不再新增编辑。
//
// 块注释 /* */ 在头部区是合法写法，单独放行。

import assert from "node:assert/strict";
import { readdir, readFile } from "node:fs/promises";

let assertionCount = 0;
function check(condition, message) {
  assert.ok(condition, message);
  assertionCount += 1;
}

// 不以 -- 开头却含中日韩字符 —— 只用于老文件兜底。
const CJK = /[一-鿿　-〿＀-￯]/;

function findHeaderEnd(lines) {
  for (let i = 0; i < lines.length; i += 1) {
    const trimmed = lines[i].trim();
    if (trimmed.startsWith("\\set") || trimmed === "begin;") return i;
  }
  return -1;
}

function bareLinesStrict(lines, headerEnd) {
  const bare = [];
  let inBlockComment = false;
  for (let i = 0; i < headerEnd; i += 1) {
    const trimmed = lines[i].trim();
    if (inBlockComment) {
      if (trimmed.includes("*/")) inBlockComment = false;
      continue;
    }
    if (!trimmed || trimmed.startsWith("--")) continue;
    if (trimmed.startsWith("/*")) {
      if (!trimmed.includes("*/")) inBlockComment = true;
      continue;
    }
    bare.push(`${i + 1}: ${lines[i].slice(0, 60)}`);
  }
  return bare;
}

function bareLinesHeuristic(lines) {
  const bare = [];
  for (let i = 0; i < lines.length; i += 1) {
    const trimmed = lines[i].trim();
    if (!trimmed || trimmed.startsWith("--")) continue;
    if (!CJK.test(trimmed)) continue;
    // 老文件没有确定的头部边界，必须容忍中文字符串字面量与美元引用块。
    // 代价就是含引号的中文散文会漏检——这个缺口只存在于老格式文件。
    if (trimmed.includes("'") || trimmed.includes('"') || trimmed.includes("$$")) continue;
    bare.push(`${i + 1}: ${lines[i].slice(0, 60)}`);
  }
  return bare;
}

const files = (await readdir(".")).filter(
  (name) => name.startsWith("supabase-update-") && name.endsWith(".sql"),
).sort();

check(files.length > 0, "至少能找到一个迁移文件");

let strictCount = 0;
for (const name of files) {
  const lines = (await readFile(name, "utf8")).split("\n");
  const headerEnd = findHeaderEnd(lines);
  const strict = headerEnd > 0;
  if (strict) strictCount += 1;

  const bare = strict ? bareLinesStrict(lines, headerEnd) : bareLinesHeuristic(lines);

  check(
    bare.length === 0,
    `${name} 头部区有未加 -- 的裸行（${strict ? "严格" : "启发式"}判据），`
      + `部署时会是语法错误：\n    ${bare.join("\n    ")}`,
  );
}

console.log(
  `SQL_HEADER_LINT_PASS ${assertionCount}/${assertionCount}`
    + `（${files.length} 个迁移文件，其中 ${strictCount} 个走严格判据）`,
);
