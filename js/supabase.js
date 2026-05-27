import { appState, saveLocal } from "./state.js";
import { mergeById, mergeMonths, getRedirectUrl } from "./utils.js";
import { getConfig, setActionMessage } from "./ui.js";

let onCloudChange = () => {};

export function setCloudChangeHandler(handler) {
  onCloudChange = handler;
}

export async function initSupabaseClient() {
  const config = getConfig();
  if (!config?.url || !config?.anonKey) {
    appState.supabaseClient = null;
    appState.currentUser = null;
    return;
  }
  if (!window.supabase) {
    await loadSupabaseSdk();
  }
  if (!window.supabase) {
    appState.supabaseClient = null;
    appState.currentUser = null;
    setActionMessage("Supabase SDK 加载失败，请刷新页面或检查网络。", "error");
    return;
  }
  appState.supabaseClient = window.supabase.createClient(config.url, config.anonKey);
  appState.supabaseClient.auth.onAuthStateChange(async (_event, session) => {
    appState.currentUser = session?.user || null;
    if (appState.currentUser) {
      await syncAllToCloud({ silent: true });
      await loadCloudData();
    }
    onCloudChange();
  });
}

export async function refreshSession() {
  if (!appState.supabaseClient) {
    appState.currentUser = null;
    return;
  }
  const { data, error } = await appState.supabaseClient.auth.getSession();
  if (error) {
    appState.currentUser = null;
    return;
  }
  appState.currentUser = data.session?.user || null;
}

export function isCloudReady() {
  return Boolean(appState.supabaseClient && appState.currentUser);
}

export async function sendMagicLink(email) {
  if (!appState.supabaseClient) {
    alert("请先配置 Supabase。");
    return;
  }
  const { error } = await appState.supabaseClient.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: getRedirectUrl() },
  });
  if (error) {
    alert(`登录链接发送失败：${error.message}`);
    return;
  }
  alert("登录链接已发送，请打开邮箱完成登录。");
}

export async function signOut() {
  if (!appState.supabaseClient) return;
  await appState.supabaseClient.auth.signOut();
  appState.currentUser = null;
}

export async function passwordAuth(mode, email, password) {
  if (!appState.supabaseClient) {
    setActionMessage("请先配置 Supabase。", "error");
    return;
  }
  if (!email || !password) {
    setActionMessage("请输入 Email 和密码。", "error");
    return;
  }
  const payload = { email, password };
  const { data, error } =
    mode === "signUp"
      ? await appState.supabaseClient.auth.signUp({
          ...payload,
          options: { emailRedirectTo: getRedirectUrl() },
        })
      : await appState.supabaseClient.auth.signInWithPassword(payload);

  if (error) {
    setActionMessage(`${mode === "signUp" ? "注册" : "登录"}失败：${error.message}`, "error");
    return;
  }
  appState.currentUser = data.session?.user || data.user || null;
  if (appState.currentUser) {
    await syncAllToCloud({ silent: true });
    await loadCloudData();
    setActionMessage(`${mode === "signUp" ? "注册" : "登录"}成功。`, "success");
    onCloudChange();
    return;
  }
  setActionMessage("注册成功，请按邮箱确认后再登录。", "success");
}

export async function loadCloudData() {
  if (!isCloudReady()) return;
  const [accounts, categories, transactions, months] = await Promise.all([
    selectCloud("home_accounts"),
    selectCloud("home_categories"),
    selectCloud("home_transactions"),
    selectCloud("home_months"),
  ]);
  if (accounts && categories && transactions && months) {
    appState.data.accounts = mergeById(appState.data.accounts, accounts);
    appState.data.categories = mergeById(appState.data.categories, categories);
    appState.data.transactions = mergeById(appState.data.transactions, transactions);
    appState.data.months = mergeMonths(appState.data.months, months);
    saveLocal();
  }
}

export async function persist(kind, record) {
  saveLocal();
  if (!isCloudReady()) return;
  const table = `home_${kind}`;
  const { error } = await appState.supabaseClient.from(table).upsert(withUser(record));
  if (error) alert(`Supabase 保存失败：${error.message}`);
}

export async function persistMonth(record) {
  saveLocal();
  if (!isCloudReady()) return;
  const { error } = await appState.supabaseClient
    .from("home_months")
    .upsert(withUser(record), { onConflict: "user_id,month_key" });
  if (error) alert(`Supabase 保存失败：${error.message}`);
}

export async function removeCloud(kind, id) {
  saveLocal();
  if (!isCloudReady()) return;
  const { error } = await appState.supabaseClient.from(`home_${kind}`).delete().eq("id", id).eq("user_id", appState.currentUser.id);
  if (error) alert(`Supabase 删除失败：${error.message}`);
}

export async function syncAllToCloud({ silent = false } = {}) {
  if (!isCloudReady()) return;
  const operations = [
    ["home_accounts", appState.data.accounts.map(withUser), undefined],
    ["home_categories", appState.data.categories.map(withUser), undefined],
    ["home_transactions", appState.data.transactions.map(withUser), undefined],
    ["home_months", Object.values(appState.data.months).map(withUser), "user_id,month_key"],
  ].filter(([, rows]) => rows.length);

  if (!operations.length) {
    if (!silent) setActionMessage("当前没有本地数据可同步。可以先点“初始化示例”。", "error");
    return;
  }

  for (const [table, rows, onConflict] of operations) {
    const options = onConflict ? { onConflict } : undefined;
    const { error } = await appState.supabaseClient.from(table).upsert(rows, options);
    if (error) {
      if (!silent) setActionMessage(`Supabase 同步失败：${error.message}`, "error");
      else alert(`Supabase 同步失败：${error.message}`);
      return;
    }
  }
  if (!silent) setActionMessage("同步完成。", "success");
}

async function selectCloud(table) {
  const { data, error } = await appState.supabaseClient.from(table).select("*").order("created_at", { ascending: true });
  if (error) {
    alert(`Supabase 读取失败：${error.message}`);
    return null;
  }
  return data || [];
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

function withUser(record) {
  return { ...record, user_id: appState.currentUser.id };
}
