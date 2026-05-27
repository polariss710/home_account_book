import { PUBLIC_APP_URL, CONFIG_KEY, DEFAULT_SUPABASE_ANON_KEY, DEFAULT_SUPABASE_URL } from "./config.js";
import { els } from "./elements.js";
import { appState } from "./state.js";
import { todayString } from "./utils.js";
import { isCloudReady } from "./supabase.js";

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
  try {
    return (
      JSON.parse(localStorage.getItem(CONFIG_KEY) || "null") || {
        url: DEFAULT_SUPABASE_URL,
        anonKey: DEFAULT_SUPABASE_ANON_KEY,
      }
    );
  } catch {
    return {
      url: DEFAULT_SUPABASE_URL,
      anonKey: DEFAULT_SUPABASE_ANON_KEY,
    };
  }
}
