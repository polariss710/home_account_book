import { DEFAULT_SUPABASE_ANON_KEY, DEFAULT_SUPABASE_URL } from "./config.js?v=20260528-cloud-4";
import { els } from "./elements.js?v=20260528-cloud-4";
import { appState } from "./state.js?v=20260528-cloud-4";
import { todayString } from "./utils.js?v=20260528-cloud-4";

export function setInitialDates() {
  els.monthPicker.value = appState.activeMonth;
  els.transactionForm.elements.date.value = todayString();
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
  renderAuthGate();
  const month = appState.data.months[appState.activeMonth];
  const lockText = month?.status === "locked" ? "已净结" : "未净结";
  const modeText = isLoggedIn()
    ? `已登录 · ${appState.currentUser.email}`
    : appState.supabaseClient
      ? "Supabase 未登录"
      : "Supabase 未配置";
  els.syncStatus.textContent = `${modeText} · ${lockText}`;
  els.settleMonthBtn.textContent = month?.status === "locked" ? "取消净结" : "标记净结";
  if (els.authState) {
    els.authState.className = `badge ${appState.currentUser ? "paid" : "unpaid"}`;
    els.authState.textContent = appState.currentUser ? "已登录" : "未登录";
  }
}

function renderAuthGate() {
  const loggedIn = isLoggedIn();
  els.authGate.hidden = loggedIn;
  els.appShell.hidden = !loggedIn;
}

function isLoggedIn() {
  return Boolean(appState.supabaseClient && appState.currentUser);
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

export function getConfig() {
  return {
    url: DEFAULT_SUPABASE_URL,
    anonKey: DEFAULT_SUPABASE_ANON_KEY,
  };
}
