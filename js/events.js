import { els } from "./elements.js?v=20260528-cloud-6";
import { appState } from "./state.js?v=20260528-cloud-6";
import { seedDefaults } from "./seed.js?v=20260528-cloud-6";
import { render } from "./render.js?v=20260528-cloud-6";
import { setActionMessage, switchView } from "./ui.js?v=20260528-cloud-6";
import {
  isCloudReady,
  loadCloudData,
  loadMonthPageData,
  passwordAuth,
  persist,
  persistMonth,
  sendMagicLink,
  signOut,
} from "./supabase.js?v=20260528-cloud-6";
import { emptyToNull, formData, todayString, toNumber } from "./utils.js?v=20260528-cloud-6";

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

  els.monthPicker.addEventListener("change", async () => {
    appState.activeMonth = els.monthPicker.value;
    await loadMonthPageData();
    render();
  });

  els.transactionForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再新增流水。")) return;
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
    const ok = await persist("transactions", record);
    if (!ok) return;
    await loadCloudData();
    event.currentTarget.reset();
    event.currentTarget.elements.date.value = todayString();
    render();
  });

  els.accountForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再新增账户。")) return;
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
    const ok = await persist("accounts", record);
    if (!ok) return;
    await loadCloudData();
    event.currentTarget.reset();
    render();
  });

  els.categoryForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再新增分类。")) return;
    const data = formData(event.currentTarget);
    const record = {
      id: crypto.randomUUID(),
      name: data.name.trim(),
      kind: data.kind,
      sort_order: appState.data.categories.length,
      created_at: new Date().toISOString(),
    };
    const ok = await persist("categories", record);
    if (!ok) return;
    await loadCloudData();
    event.currentTarget.reset();
    render();
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

  els.seedBtn.addEventListener("click", async () => {
    if (!requireCloudReady("请先登录后再初始化示例。")) return;
    const seeded = seedDefaults();
    const ok = await upsertSeedData(seeded);
    if (!ok) return;
    await loadCloudData();
    setActionMessage("示例数据已写入 Supabase。", "success");
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
    if (!requireCloudReady("请先登录后再标记净结。")) return;
    const current = appState.data.months[appState.activeMonth] || { month_key: appState.activeMonth, status: "open" };
    current.status = current.status === "locked" ? "open" : "locked";
    const ok = await persistMonth(current);
    if (!ok) return;
    await loadCloudData();
    render();
  });
}

async function runPasswordAuth(mode) {
  const email = els.authForm.elements.email.value.trim();
  const password = els.authForm.elements.password.value;
  setActionMessage(`${mode === "signUp" ? "注册" : "登录"}处理中...`);
  await passwordAuth(mode, email, password);
}

function requireCloudReady(message) {
  if (isCloudReady()) return true;
  setActionMessage(message, "error");
  return false;
}

async function upsertSeedData(seeded) {
  const withUser = (row) => ({ ...row, user_id: appState.currentUser.id });
  const operations = [
    ["home_accounts", seeded.accounts.map(withUser)],
    ["home_categories", seeded.categories.map(withUser)],
  ];
  for (const [table, rows] of operations) {
    if (!rows.length) continue;
    const { error } = await appState.supabaseClient.from(table).upsert(rows);
    if (error) {
      setActionMessage(`初始化示例失败：${error.message}`, "error");
      return false;
    }
  }
  return true;
}
