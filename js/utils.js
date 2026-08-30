export function formData(form) {
  return Object.fromEntries(new FormData(form).entries());
}

export function monthKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

export function toNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

export function money(value) {
  return new Intl.NumberFormat("ja-JP", { maximumFractionDigits: 0 }).format(Math.round(toNumber(value)));
}

export function moneyCny(value) {
  return new Intl.NumberFormat("zh-CN", { minimumFractionDigits: 2, maximumFractionDigits: 2 }).format(toNumber(value));
}

export function moneyByCurrency(value, currency) {
  return String(currency || "").toUpperCase() === "CNY" ? moneyCny(value) : money(value);
}

export function isExternalTransaction(transaction) {
  if (!transaction) return false;
  const externalTextFields = [
    "external_source",
    "external_event_type",
    "external_idempotency_key",
    "external_reference_type",
    "external_note",
    "external_payload_hash",
  ];
  return transaction.created_by_external === true ||
    Boolean(transaction.external_source_id) ||
    Boolean(transaction.external_reference_id) ||
    Boolean(transaction.external_created_at) ||
    externalTextFields.some((field) => String(transaction[field] || "").trim() !== "");
}

export function canRequestFixedMonthItemDelete(item) {
  return Boolean(
    item &&
      // School 来源的固定项不提供删除入口。数据库侧
      // home_check_fixed_month_item_delete_eligibility 会以 projection 为判据拒绝
      // （HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN），此处只是不再显示一个
      // 注定失败的按钮。
      //
      // 判据用 accounting_scope 而非 projection，有两个原因：reader 目前不返回
      // projection 字段；以及业务要求本就是「School 产生的不可随意删除」，与
      // scope 语义一致。两者范围不完全重合——前端因此比数据库更严，这是安全方向。
      //
      // 写成「必须明确等于 household」而不是「不等于 school」：accounting_scope
      // 只有 household / school 两个合法值，出现其他值时 accountingScopeKind()
      // 会判为 invalid 并报错，那种记录同样不该给删除入口。
      item.accounting_scope === "household" &&
      item.status === "unpaid" &&
      !item.advance_id &&
      !item.linked_jpy_transaction_id &&
      !item.linked_cny_transaction_id,
  );
}

export function fixedMonthItemDeleteLockLabel(item) {
  if (item?.advance_id) return "垫付锁定";
  if (item?.linked_jpy_transaction_id || item?.linked_cny_transaction_id) return "流水已关联";
  if (item?.accounting_scope === "school") return "School 项不可删除";
  if (item?.accounting_scope !== "household") return "归属异常";
  if (item?.status !== "unpaid") return "仅未支付可删除";
  return "";
}

export function fixedMonthItemDeleteErrorMessage(errorOrResult, currency = "JPY") {
  const raw = [errorOrResult?.code, errorOrResult?.message, typeof errorOrResult === "string" ? errorOrResult : ""]
    .filter(Boolean)
    .join(" ");
  const messages = {
    HOME_FIXED_ITEM_ALREADY_ABSENT: "该固定项已不存在，请刷新页面。",
    HOME_FIXED_ITEM_DELETE_UNAUTHENTICATED: "请先登录后再删除固定项。",
    HOME_FIXED_ITEM_DELETE_STATUS_FORBIDDEN: "仅未支付的普通固定项可以删除。已支付或已结算项目请先撤销支付或使用纠正流程。",
    HOME_PROJECTION_FIXED_ITEM_DELETE_FORBIDDEN: "该固定项来自外部固定支付链路，不能直接删除。",
    HOME_STATEMENT_FIXED_ITEM_DELETE_FORBIDDEN: "该固定项已经进入账单处理流程，不能直接删除。",
    HOME_FUNDED_FIXED_ITEM_DELETE_FORBIDDEN: "该固定项已经进入资金处理流程，不能直接删除。",
    HOME_ADVANCE_FIXED_ITEM_DELETE_FORBIDDEN: "该固定项所在支付分组已经进入垫付流程，不能直接删除。",
    HOME_LINKED_PAYMENT_FIXED_ITEM_DELETE_FORBIDDEN: "该固定项已经关联Cash流水，不能直接删除。",
    HOME_CORRECTION_FIXED_ITEM_DELETE_FORBIDDEN: "该固定项属于纠正或replacement链路，不能直接删除。",
  };
  const code = Object.keys(messages).find((candidate) => raw.includes(candidate));
  if (code) return messages[code];
  return currency === "CNY" ? "人民币固定项删除失败，请刷新后重试。" : "固定项删除失败，请刷新后重试。";
}

export function emptyRow(colspan) {
  return `<tr><td colspan="${colspan}" class="empty-state">暂无数据</td></tr>`;
}

export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function getRedirectUrl() {
  return `${window.location.origin}${window.location.pathname}`;
}
