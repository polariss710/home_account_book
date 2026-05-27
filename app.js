const STORE_KEY = "home_book_mvp_v1";
const CONFIG_KEY = "home_book_supabase_v1";
const DEFAULT_SUPABASE_URL = "https://ahtgiwdzocerkonrjmdo.supabase.co";
const DEFAULT_SUPABASE_ANON_KEY = "sb_publishable_HTCFg_w3vmdNqfG2ZE46-A_6KXpxAnz";
const PUBLIC_APP_URL = "https://polariss710.github.io/home_account_book/";

const defaultData = {
  accounts: [],
  categories: [],
  transactions: [],
  months: {},
};

let state = loadLocal();
let activeMonth = monthKey(new Date());
let transactionFilter = "all";
let supabaseClient = null;
let currentUser = null;

const els = {};

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  setInitialDates();
  await initSupabaseClient();
  warnIfFileMode();
  await refreshSession();
  processAuthHash();
  await syncAllToCloud({ silent: true });
  await loadCloudData();
  render();
});

function bindElements() {
  [
    "syncStatus",
    "monthPicker",
    "settleMonthBtn",
    "exportBtn",
    "seedBtn",
    "accountBalances",
    "pendingRows",
    "transactionForm",
    "transactionRows",
    "accountForm",
    "accountRows",
    "categoryForm",
    "categoryRows",
    "authForm",
    "authState",
    "passwordSignInBtn",
    "passwordSignUpBtn",
    "signOutBtn",
    "syncLocalBtn",
    "actionMessage",
    "supabaseForm",
    "clearCloudBtn",
    "monthIncome",
    "monthExpense",
    "monthUnpaid",
    "monthBalance",
  ].forEach((id) => {
    els[id] = document.getElementById(id);
  });
}

function bindEvents() {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  document.querySelectorAll(".segment").forEach((button) => {
    button.addEventListener("click", () => {
      transactionFilter = button.dataset.filter;
      document.querySelectorAll(".segment").forEach((item) => item.classList.remove("is-active"));
      button.classList.add("is-active");
      renderTransactions();
    });
  });

  els.monthPicker.addEventListener("change", () => {
    activeMonth = els.monthPicker.value;
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
    state.transactions.push(record);
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
      sort_order: state.accounts.length,
      created_at: new Date().toISOString(),
    };
    state.accounts.push(record);
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
      sort_order: state.categories.length,
      created_at: new Date().toISOString(),
    };
    state.categories.push(record);
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
    supabaseClient = null;
    renderSyncStatus();
  });

  els.authForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!supabaseClient) {
      alert("请先配置 Supabase。");
      return;
    }
    const data = formData(event.currentTarget);
    const redirectTo = getRedirectUrl();
    const { error } = await supabaseClient.auth.signInWithOtp({
      email: data.email.trim(),
      options: { emailRedirectTo: redirectTo },
    });
    if (error) {
      alert(`登录链接发送失败：${error.message}`);
      return;
    }
    alert("登录链接已发送，请打开邮箱完成登录。");
  });

  els.signOutBtn.addEventListener("click", async () => {
    if (!supabaseClient) return;
    await supabaseClient.auth.signOut();
    currentUser = null;
    render();
  });

  els.passwordSignInBtn.addEventListener("click", async () => {
    await passwordAuth("signIn");
  });

  els.passwordSignUpBtn.addEventListener("click", async () => {
    await passwordAuth("signUp");
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
    seedDefaults();
    await syncAllToCloud();
    render();
  });

  els.exportBtn.addEventListener("click", () => {
    const blob = new Blob([JSON.stringify(state, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = `home-book-${activeMonth}.json`;
    a.click();
    URL.revokeObjectURL(url);
  });

  els.settleMonthBtn.addEventListener("click", async () => {
    const current = state.months[activeMonth] || { month_key: activeMonth, status: "open" };
    current.status = current.status === "locked" ? "open" : "locked";
    state.months[activeMonth] = current;
    await persistMonth(current);
    render();
  });
}

function setInitialDates() {
  els.monthPicker.value = activeMonth;
  els.transactionForm.elements.date.value = todayString();
  const config = getConfig();
  if (config) {
    els.supabaseForm.elements.url.value = config.url || "";
    els.supabaseForm.elements.anonKey.value = config.anonKey || "";
  }
}

function switchView(viewId) {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.classList.toggle("is-active", button.dataset.view === viewId);
  });
  document.querySelectorAll(".view").forEach((view) => {
    view.classList.toggle("is-active", view.id === viewId);
  });
}

function render() {
  saveLocal();
  renderSyncStatus();
  renderSelectOptions();
  renderDashboard();
  renderTransactions();
  renderAccounts();
  renderCategories();
}

function renderSyncStatus() {
  const month = state.months[activeMonth];
  const lockText = month?.status === "locked" ? "已净结" : "未净结";
  const modeText = isCloudReady() ? `已登录 · ${currentUser.email}` : supabaseClient ? "Supabase 未登录" : "本地模式";
  els.syncStatus.textContent = `${modeText} · ${lockText}`;
  els.settleMonthBtn.textContent = month?.status === "locked" ? "取消净结" : "标记净结";
  if (els.authState) {
    els.authState.className = `badge ${currentUser ? "paid" : "unpaid"}`;
    els.authState.textContent = currentUser ? "已登录" : "未登录";
  }
}

function renderSelectOptions() {
  const accountOptions = `<option value="">-</option>${state.accounts
    .map((item) => `<option value="${item.id}">${escapeHtml(item.name)}</option>`)
    .join("")}`;
  const categoryOptions = `<option value="">-</option>${state.categories
    .map((item) => `<option value="${item.id}">${escapeHtml(item.name)}</option>`)
    .join("")}`;

  els.transactionForm.elements.source_account_id.innerHTML = accountOptions;
  els.transactionForm.elements.target_account_id.innerHTML = accountOptions;
  els.transactionForm.elements.category_id.innerHTML = categoryOptions;
}

function renderDashboard() {
  const txs = monthTransactions(activeMonth);
  const paid = txs.filter((item) => item.status === "paid");
  const income = sum(paid.filter((item) => item.type === "income").map((item) => item.amount));
  const expense = sum(paid.filter((item) => item.type === "expense").map((item) => item.amount));
  const unpaid = sum(txs.filter((item) => item.status === "unpaid").map((item) => item.amount));
  const balances = calculateBalances(endOfMonth(activeMonth));
  const totalBalance = sum(Object.values(balances));

  els.monthIncome.textContent = money(income);
  els.monthExpense.textContent = money(expense);
  els.monthUnpaid.textContent = money(unpaid);
  els.monthBalance.textContent = money(totalBalance);

  els.accountBalances.innerHTML = state.accounts.length
    ? state.accounts
        .map(
          (account) => `
            <div class="balance-item">
              <div>
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountKind(account.kind)}</span>
              </div>
              <strong>${money(balances[account.id] || 0)}</strong>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无账户</div>`;

  const pending = txs.filter((item) => item.status === "unpaid").sort(sortByDate);
  els.pendingRows.innerHTML = pending.length ? pending.map(pendingRow).join("") : emptyRow(5);
}

function renderTransactions() {
  let txs = monthTransactions(activeMonth).sort(sortByDateDesc);
  if (transactionFilter !== "all") {
    txs = txs.filter((item) => item.status === transactionFilter);
  }
  els.transactionRows.innerHTML = txs.length ? txs.map(transactionRow).join("") : emptyRow(8);

  els.transactionRows.querySelectorAll("[data-delete]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.delete;
      state.transactions = state.transactions.filter((item) => item.id !== id);
      await removeCloud("transactions", id);
      render();
    });
  });

  els.transactionRows.querySelectorAll("[data-toggle-status]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.toggleStatus;
      const tx = state.transactions.find((item) => item.id === id);
      tx.status = tx.status === "paid" ? "unpaid" : "paid";
      await persist("transactions", tx);
      render();
    });
  });
}

function renderAccounts() {
  els.accountRows.innerHTML = state.accounts.length
    ? state.accounts
        .map(
          (item) => `
          <div class="settings-item">
            <div>
              <strong>${escapeHtml(item.name)}</strong>
              <span>${labelAccountKind(item.kind)} · 期初 ${money(item.opening_balance)}</span>
            </div>
            <button class="danger-button" type="button" data-delete-account="${item.id}">删除</button>
          </div>
        `,
        )
        .join("")
    : `<div class="empty-state">暂无账户</div>`;

  els.accountRows.querySelectorAll("[data-delete-account]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.deleteAccount;
      state.accounts = state.accounts.filter((item) => item.id !== id);
      await removeCloud("accounts", id);
      render();
    });
  });
}

function renderCategories() {
  els.categoryRows.innerHTML = state.categories.length
    ? state.categories
        .map(
          (item) => `
          <div class="settings-item">
            <div>
              <strong>${escapeHtml(item.name)}</strong>
              <span>${labelType(item.kind)}</span>
            </div>
            <button class="danger-button" type="button" data-delete-category="${item.id}">删除</button>
          </div>
        `,
        )
        .join("")
    : `<div class="empty-state">暂无分类</div>`;

  els.categoryRows.querySelectorAll("[data-delete-category]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.deleteCategory;
      state.categories = state.categories.filter((item) => item.id !== id);
      await removeCloud("categories", id);
      render();
    });
  });
}

function pendingRow(item) {
  return `
    <tr>
      <td>${item.date}</td>
      <td>${escapeHtml(item.description || "-")}</td>
      <td>${escapeHtml(nameById(state.categories, item.category_id))}</td>
      <td class="amount">${money(item.amount)}</td>
      <td>${statusBadge(item.status)}</td>
    </tr>
  `;
}

function transactionRow(item) {
  return `
    <tr>
      <td>${item.date}</td>
      <td>${labelType(item.type)}</td>
      <td>${escapeHtml(item.description || "-")}</td>
      <td>${escapeHtml(nameById(state.categories, item.category_id))}</td>
      <td>${escapeHtml(accountPair(item))}</td>
      <td class="amount">${money(item.amount)}</td>
      <td><button class="plain-button" type="button" data-toggle-status="${item.id}">${statusBadge(item.status)}</button></td>
      <td><button class="danger-button" type="button" data-delete="${item.id}">删除</button></td>
    </tr>
  `;
}

function statusBadge(status) {
  return `<span class="badge ${status}">${status === "paid" ? "已付" : "未付"}</span>`;
}

function calculateBalances(endDate) {
  const balances = Object.fromEntries(state.accounts.map((account) => [account.id, toNumber(account.opening_balance)]));
  state.transactions
    .filter((tx) => tx.status === "paid" && tx.date <= endDate)
    .forEach((tx) => {
      const amount = toNumber(tx.amount);
      if (tx.type === "income" && tx.target_account_id) balances[tx.target_account_id] += amount;
      if (tx.type === "expense" && tx.source_account_id) balances[tx.source_account_id] -= amount;
      if (tx.type === "transfer") {
        if (tx.source_account_id) balances[tx.source_account_id] -= amount;
        if (tx.target_account_id) balances[tx.target_account_id] += amount;
      }
      if (tx.type === "adjustment" && tx.target_account_id) balances[tx.target_account_id] += amount;
    });
  return balances;
}

function seedDefaults() {
  if (!state.accounts.length) {
    state.accounts = [
      accountSeed("现金", "cash", 0, 0),
      accountSeed("支付宝余额", "wallet", 0, 1),
      accountSeed("余利宝", "wallet", 0, 2),
      accountSeed("余额宝", "wallet", 0, 3),
      accountSeed("信用卡", "credit", 0, 4),
    ];
  }
  if (!state.categories.length) {
    state.categories = [
      categorySeed("工资", "income", 0),
      categorySeed("生活费", "expense", 1),
      categorySeed("房贷", "expense", 2),
      categorySeed("社保", "expense", 3),
      categorySeed("购物", "expense", 4),
      categorySeed("余额调整", "adjustment", 5),
      categorySeed("账户转账", "transfer", 6),
    ];
  }
}

function accountSeed(name, kind, openingBalance, sortOrder) {
  return {
    id: crypto.randomUUID(),
    name,
    kind,
    opening_balance: openingBalance,
    currency: "JPY",
    sort_order: sortOrder,
    created_at: new Date().toISOString(),
  };
}

function categorySeed(name, kind, sortOrder) {
  return {
    id: crypto.randomUUID(),
    name,
    kind,
    sort_order: sortOrder,
    created_at: new Date().toISOString(),
  };
}

function monthTransactions(key) {
  return state.transactions.filter((item) => item.date?.startsWith(key));
}

function loadLocal() {
  try {
    return { ...defaultData, ...JSON.parse(localStorage.getItem(STORE_KEY) || "{}") };
  } catch {
    return structuredClone(defaultData);
  }
}

function saveLocal() {
  localStorage.setItem(STORE_KEY, JSON.stringify(state));
}

async function initSupabaseClient() {
  const config = getConfig();
  if (!config?.url || !config?.anonKey) {
    supabaseClient = null;
    currentUser = null;
    return;
  }
  if (!window.supabase) {
    await loadSupabaseSdk();
  }
  if (!window.supabase) {
    supabaseClient = null;
    currentUser = null;
    setActionMessage("Supabase SDK 加载失败，请刷新页面或检查网络。", "error");
    return;
  }
  supabaseClient = window.supabase.createClient(config.url, config.anonKey);
  supabaseClient.auth.onAuthStateChange(async (_event, session) => {
    currentUser = session?.user || null;
    if (currentUser) {
      await syncAllToCloud({ silent: true });
      await loadCloudData();
    }
    render();
  });
}

async function loadSupabaseSdk() {
  const sources = [
    "https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2",
    "https://unpkg.com/@supabase/supabase-js@2",
  ];
  for (const src of sources) {
    try {
      await loadScript(src);
      if (window.supabase) return;
    } catch {
      // Try the next CDN.
    }
  }
}

function loadScript(src) {
  return new Promise((resolve, reject) => {
    const script = document.createElement("script");
    script.src = src;
    script.async = true;
    script.onload = resolve;
    script.onerror = reject;
    document.head.appendChild(script);
  });
}

function getConfig() {
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

async function loadCloudData() {
  if (!isCloudReady()) return;
  const [accounts, categories, transactions, months] = await Promise.all([
    selectCloud("home_accounts"),
    selectCloud("home_categories"),
    selectCloud("home_transactions"),
    selectCloud("home_months"),
  ]);
  if (accounts && categories && transactions && months) {
    state.accounts = mergeById(state.accounts, accounts);
    state.categories = mergeById(state.categories, categories);
    state.transactions = mergeById(state.transactions, transactions);
    state.months = mergeMonths(state.months, months);
    saveLocal();
  }
}

async function selectCloud(table) {
  const { data, error } = await supabaseClient.from(table).select("*").order("created_at", { ascending: true });
  if (error) {
    alert(`Supabase 读取失败：${error.message}`);
    return null;
  }
  return data || [];
}

async function persist(kind, record) {
  saveLocal();
  if (!isCloudReady()) return;
  const table = `home_${kind}`;
  const { error } = await supabaseClient.from(table).upsert(withUser(record));
  if (error) alert(`Supabase 保存失败：${error.message}`);
}

async function persistMonth(record) {
  saveLocal();
  if (!isCloudReady()) return;
  const { error } = await supabaseClient.from("home_months").upsert(withUser(record), { onConflict: "user_id,month_key" });
  if (error) alert(`Supabase 保存失败：${error.message}`);
}

async function removeCloud(kind, id) {
  saveLocal();
  if (!isCloudReady()) return;
  const { error } = await supabaseClient.from(`home_${kind}`).delete().eq("id", id).eq("user_id", currentUser.id);
  if (error) alert(`Supabase 删除失败：${error.message}`);
}

async function syncAllToCloud({ silent = false } = {}) {
  if (!isCloudReady()) return;
  const operations = [
    ["home_accounts", state.accounts.map(withUser), undefined],
    ["home_categories", state.categories.map(withUser), undefined],
    ["home_transactions", state.transactions.map(withUser), undefined],
    ["home_months", Object.values(state.months).map(withUser), "user_id,month_key"],
  ].filter(([, rows]) => rows.length);

  if (!operations.length) {
    if (!silent) setActionMessage("当前没有本地数据可同步。可以先点“初始化示例”。", "error");
    return;
  }

  for (const [table, rows, onConflict] of operations) {
    const options = onConflict ? { onConflict } : undefined;
    const { error } = await supabaseClient.from(table).upsert(rows, options);
    if (error) {
      if (!silent) setActionMessage(`Supabase 同步失败：${error.message}`, "error");
      else alert(`Supabase 同步失败：${error.message}`);
      return;
    }
  }
  if (!silent) setActionMessage("同步完成。", "success");
}

async function refreshSession() {
  if (!supabaseClient) {
    currentUser = null;
    return;
  }
  const { data, error } = await supabaseClient.auth.getSession();
  if (error) {
    currentUser = null;
    return;
  }
  currentUser = data.session?.user || null;
}

function isCloudReady() {
  return Boolean(supabaseClient && currentUser);
}

async function passwordAuth(mode) {
  if (!supabaseClient) {
    setActionMessage("请先配置 Supabase。", "error");
    return;
  }
  const email = els.authForm.elements.email.value.trim();
  const password = els.authForm.elements.password.value;
  if (!email || !password) {
    setActionMessage("请输入 Email 和密码。", "error");
    return;
  }
  const payload = { email, password };
  const { data, error } =
    mode === "signUp"
      ? await supabaseClient.auth.signUp({
          ...payload,
          options: { emailRedirectTo: getRedirectUrl() },
        })
      : await supabaseClient.auth.signInWithPassword(payload);

  if (error) {
    setActionMessage(`${mode === "signUp" ? "注册" : "登录"}失败：${error.message}`, "error");
    return;
  }
  currentUser = data.session?.user || data.user || null;
  if (currentUser) {
    await syncAllToCloud({ silent: true });
    await loadCloudData();
    setActionMessage(`${mode === "signUp" ? "注册" : "登录"}成功。`, "success");
    render();
    return;
  }
  setActionMessage("注册成功，请按邮箱确认后再登录。", "success");
}

function withUser(record) {
  return { ...record, user_id: currentUser.id };
}

function mergeById(localRows, cloudRows) {
  const map = new Map();
  [...cloudRows, ...localRows].forEach((row) => {
    map.set(row.id, row);
  });
  return [...map.values()].sort((a, b) => (a.created_at || "").localeCompare(b.created_at || ""));
}

function mergeMonths(localMonths, cloudMonths) {
  const merged = { ...Object.fromEntries(cloudMonths.map((item) => [item.month_key, item])), ...localMonths };
  return merged;
}

function setActionMessage(message, type = "") {
  if (!els.actionMessage) return;
  els.actionMessage.textContent = message;
  els.actionMessage.className = `form-message ${type}`;
}

function processAuthHash() {
  const hash = new URLSearchParams(window.location.hash.replace(/^#/, ""));
  const errorDescription = hash.get("error_description");
  if (errorDescription) {
    setActionMessage(`登录链接无效或已过期，请重新发送登录链接。`, "error");
    window.history.replaceState({}, document.title, `${window.location.origin}${window.location.pathname}`);
  }
}

function getRedirectUrl() {
  if (window.location.protocol === "file:") return PUBLIC_APP_URL;
  return `${window.location.origin}${window.location.pathname}`;
}

function warnIfFileMode() {
  if (window.location.protocol !== "file:") return;
  setActionMessage(`当前是本地文件模式，登录请使用线上地址：${PUBLIC_APP_URL}`, "error");
}

function formData(form) {
  return Object.fromEntries(new FormData(form).entries());
}

function monthKey(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}`;
}

function todayString() {
  return new Date().toISOString().slice(0, 10);
}

function endOfMonth(key) {
  const [year, month] = key.split("-").map(Number);
  return new Date(year, month, 0).toISOString().slice(0, 10);
}

function toNumber(value) {
  const number = Number(value);
  return Number.isFinite(number) ? number : 0;
}

function sum(values) {
  return values.reduce((total, value) => total + toNumber(value), 0);
}

function money(value) {
  return new Intl.NumberFormat("ja-JP", { maximumFractionDigits: 0 }).format(Math.round(toNumber(value)));
}

function emptyToNull(value) {
  return value === "" ? null : value;
}

function nameById(list, id) {
  return list.find((item) => item.id === id)?.name || "-";
}

function accountPair(tx) {
  if (tx.type === "income") return nameById(state.accounts, tx.target_account_id);
  if (tx.type === "expense") return nameById(state.accounts, tx.source_account_id);
  if (tx.type === "transfer") return `${nameById(state.accounts, tx.source_account_id)} -> ${nameById(state.accounts, tx.target_account_id)}`;
  return nameById(state.accounts, tx.target_account_id);
}

function labelType(type) {
  return {
    income: "收入",
    expense: "支出",
    transfer: "转账",
    adjustment: "调整",
  }[type] || type;
}

function labelAccountKind(kind) {
  return {
    cash: "现金",
    wallet: "钱包",
    bank: "银行",
    credit: "信用卡",
  }[kind] || kind;
}

function emptyRow(colspan) {
  return `<tr><td colspan="${colspan}" class="empty-state">暂无数据</td></tr>`;
}

function sortByDate(a, b) {
  return a.date.localeCompare(b.date);
}

function sortByDateDesc(a, b) {
  return b.date.localeCompare(a.date);
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
