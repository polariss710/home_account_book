import { APP_VERSION, DEFAULT_SUPABASE_ANON_KEY, DEFAULT_SUPABASE_URL } from "./config.js?v=20260529-fixed-10";
import { els } from "./elements.js?v=20260529-fixed-10";
import { appState } from "./state.js?v=20260529-fixed-10";

export function setInitialDates() {
  els.monthPicker.value = appState.activeMonth;
}

export function switchView(viewId) {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.view === viewId);
  });
  document.querySelectorAll(".view").forEach((view) => {
    view.classList.toggle("is-active", view.id === viewId);
  });
}

export function renderShell() {
  const loggedIn = Boolean(appState.supabaseClient && appState.currentUser);
  els.authGate.hidden = loggedIn;
  els.appShell.hidden = !loggedIn;
  els.syncStatus.textContent = loggedIn ? `已登录 · ${appState.currentUser.email}` : "Supabase 未登录";
  els.appVersion.textContent = `版本 ${APP_VERSION}`;
  if (els.authState) {
    els.authState.className = `badge ${loggedIn ? "paid" : "unpaid"}`;
    els.authState.textContent = loggedIn ? "已登录" : "未登录";
  }
}

export function setActionMessage(message, type = "") {
  [els.actionMessage, els.appMessage].forEach((messageEl) => {
    if (!messageEl) return;
    messageEl.textContent = message;
    messageEl.className = `${messageEl.id === "appMessage" ? "app-message" : "form-message"} ${type}`;
  });
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
