import { els } from "./elements.js";
import { appState } from "./state.js";
import { seedDefaults } from "./seed.js";
import { render } from "./render.js";
import { renderSyncStatus, setActionMessage, switchView } from "./ui.js";
import {
  initSupabaseClient,
  isCloudReady,
  loadCloudData,
  passwordAuth,
  persist,
  persistMonth,
  sendMagicLink,
  signOut,
  syncAllToCloud,
  refreshSession,
} from "./supabase.js";
import { emptyToNull, formData, todayString, toNumber } from "./utils.js";
import { CONFIG_KEY } from "./config.js";

export function bindEvents() {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  document.querySelectorAll(".segment").forEach((button) => {
    button.addEventListener("click", () => {
      appState.transactionFilter = button.dataset.filter;
      document.querySelectorAll(".segment").forEach((item) => item.classList.remove("is-active"));
      button.classList.add("is-active");
      render();
    });
  });

  els.monthPicker.addEventListener("change", () => {
    appState.activeMonth = els.monthPicker.value;
    render();
  });

  els.transactionForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = formData(event.currentTarget);
    const record = {
      id: crypto.randomUUID(),
      date: data.date,
      type: data.type,
      amount: toNumber(data.amount),
      category_id: emptyToNull(data.category_id),
      source_account_id: emptyToNull(data.source_account_id),
      target_account_id: emptyToNull(data.target_account_id),
      status: data.status,
      description: data.description.trim(),
      created_at: new Date().toISOString(),
    };
    appState.data.transactions.push(record);
    await persist("transactions", record);
    event.currentTarget.reset();
    event.currentTarget.elements.date.value = todayString();
    render();
  });

  els.accountForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = formData(event.currentTarget);
    const record = {
      id: crypto.randomUUID(),
      name: data.name.trim(),
      kind: data.kind,
      opening_balance: toNumber(data.opening_balance),
      currency: "JPY",
      sort_order: appState.data.accounts.length,
      created_at: new Date().toISOString(),
    };
    appState.data.accounts.push(record);
    await persist("accounts", record);
    event.currentTarget.reset();
    render();
  });

  els.categoryForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = formData(event.currentTarget);
    const record = {
      id: crypto.randomUUID(),
      name: data.name.trim(),
      kind: data.kind,
      sort_order: appState.data.categories.length,
      created_at: new Date().toISOString(),
    };
    appState.data.categories.push(record);
    await persist("categories", record);
    event.currentTarget.reset();
    render();
  });

  els.supabaseForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = formData(event.currentTarget);
    localStorage.setItem(CONFIG_KEY, JSON.stringify({ url: data.url.trim(), anonKey: data.anonKey.trim() }));
    await initSupabaseClient();
    await refreshSession();
    await syncAllToCloud();
    await loadCloudData();
    render();
  });

  els.clearCloudBtn.addEventListener("click", () => {
    localStorage.removeItem(CONFIG_KEY);
    appState.supabaseClient = null;
    renderSyncStatus();
  });

  els.authForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = formData(event.currentTarget);
    await sendMagicLink(data.email.trim());
  });

  els.signOutBtn.addEventListener("click", async () => {
    await signOut();
    render();
  });

  els.passwordSignInBtn.addEventListener("click", async () => {
    await runPasswordAuth("signIn");
  });

  els.passwordSignUpBtn.addEventListener("click", async () => {
    await runPasswordAuth("signUp");
  });

  els.syncLocalBtn.addEventListener("click", async () => {
    if (!isCloudReady()) {
      setActionMessage("请先登录后再同步。", "error");
      return;
    }
    await syncAllToCloud();
    await loadCloudData();
    setActionMessage("本地数据已同步到 Supabase。", "success");
    render();
  });

  els.seedBtn.addEventListener("click", async () => {
    seedDefaults(appState.data);
    await syncAllToCloud();
    render();
  });

  els.exportBtn.addEventListener("click", () => {
    const blob = new Blob([JSON.stringify(appState.data, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `home-book-${appState.activeMonth}.json`;
    a.click();
    URL.revokeObjectURL(url);
  });

  els.settleMonthBtn.addEventListener("click", async () => {
    const current = appState.data.months[appState.activeMonth] || { month_key: appState.activeMonth, status: "open" };
    current.status = current.status === "locked" ? "open" : "locked";
    appState.data.months[appState.activeMonth] = current;
    await persistMonth(current);
    render();
  });
}

async function runPasswordAuth(mode) {
  const email = els.authForm.elements.email.value.trim();
  const password = els.authForm.elements.password.value;
  await passwordAuth(mode, email, password);
}
