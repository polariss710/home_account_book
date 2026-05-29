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

export function emptyToNull(value) {
  return value === "" ? null : value;
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
