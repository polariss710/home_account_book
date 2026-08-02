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
