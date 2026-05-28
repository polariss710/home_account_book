import { PUBLIC_APP_URL } from "./config.js?v=20260528-cloud-1";

export function formData(form) {
  return Object.fromEntries(new FormData(form).entries());
}

export function monthKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

export function todayString() {
  return new Date().toISOString().slice(0, 10);
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

export function nameById(list, id) {
  return list.find((item) => item.id === id)?.name || "-";
}

export function emptyRow(colspan) {
  return `<tr><td colspan="${colspan}" class="empty-state">暂无数据</td></tr>`;
}

export function sortByDate(a, b) {
  return a.date.localeCompare(b.date);
}

export function sortByDateDesc(a, b) {
  return b.date.localeCompare(a.date);
}

export function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

export function mergeById(currentRows, incomingRows) {
  const map = new Map();
  [...incomingRows, ...currentRows].forEach((row) => {
    map.set(row.id, row);
  });
  return [...map.values()].sort((a, b) => (a.created_at || "").localeCompare(b.created_at || ""));
}

export function mergeMonths(currentMonths, incomingMonths) {
  return { ...Object.fromEntries(incomingMonths.map((item) => [item.month_key, item])), ...currentMonths };
}

export function getRedirectUrl() {
  if (window.location.protocol === "file:") return PUBLIC_APP_URL;
  return `${window.location.origin}${window.location.pathname}`;
}
