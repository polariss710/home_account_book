import { PUBLIC_APP_URL, CONFIG_KEY, DEFAULT_SUPABASE_ANON_KEY, DEFAULT_SUPABASE_URL, LOCAL_MODE_KEY } from "./config.js?v=20260528-config-1";
import { els } from "./elements.js?v=20260528-config-1";
import { appState } from "./state.js?v=20260528-config-1";
import { todayString } from "./utils.js?v=20260528-config-1";
import { isCloudReady } from "./supabase.js?v=20260528-config-1";

export function setInitialDates() {
  els.monthPicker.value = appState.activeMonth;
  els.transactionForm.elements.date.value = todayString();
  const config = getConfig();
  if (config) {
    els.supabaseForm.elements.url.value = config.url || "";
    els.supabaseForm.elements.anonKey.value = config.anonKey || "";
  }
}

export function switchView(viewId) {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.view === viewId);
  });
  document.querySelectorAll(".view").forEach((view) => {
    view.classList.toggle("is-active", view.id === viewId);
  });
}

export function renderSyncStatus() {
  const month = appState.data.months[appState.activeMonth];
  const lockText = month?.status === "locked" ? "已净结" : "未净结";
  const modeText = isCloudReady()
    ? `已登录 · ${appState.currentUser.email}`
    : appState.supabaseClient
      ? "Supabase 未登录"
      : "本地模式";
  els.syncStatus.textContent = `${modeText} · ${lockText}`;
  els.settleMonthBtn.textContent = month?.status === "locked" ? "取消净结" : "标记净结";
  if (els.authState) {
    els.authState.className = `badge ${appState.currentUser ? "paid" : "unpaid"}`;
    els.authState.textContent = appState.currentUser ? "已登录" : "未登录";
  }
}

export function setActionMessage(message, type = "") {
  if (!els.actionMessage) return;
  els.actionMessage.textContent = message;
  els.actionMessage.className = `form-message ${type}`;
}

export function processAuthHash() {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const errorDescription = hash.get("error_description");
  if (errorDescription) {
    setActionMessage("登录链接无效或已过期，请重新发送登录链接。", "error");
    window.history.replaceState({}, document.title, `${window.location.origin}${window.location.pathname}`);
  }
}

export function warnIfFileMode() {
  if (window.location.protocol !== "file:") return;
  setActionMessage(`当前是本地文件模式，登录请使用线上地址：${PUBLIC_APP_URL}`, "error");
}

export function getConfig() {
  if (localStorage.getItem(LOCAL_MODE_KEY) === "true") return null;
  try {
    const saved = JSON.parse(localStorage.getItem(CONFIG_KEY) || "null") || {};
    return normalizeConfig(saved);
  } catch {
    return normalizeConfig({});
  }
}

function normalizeConfig(config) {
  return {
    url: config.url?.trim() || DEFAULT_SUPABASE_URL,
    anonKey: config.anonKey?.trim() || DEFAULT_SUPABASE_ANON_KEY,
  };
}
