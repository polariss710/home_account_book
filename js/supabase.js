import { appState } from "./state.js?v=20260528-cloud-5";
import { mergeById, mergeMonths, getRedirectUrl } from "./utils.js?v=20260528-cloud-5";
import { getConfig, setActionMessage } from "./ui.js?v=20260528-cloud-5";

let onCloudChange = () => {};
let cloudLoadPromise = null;

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
    appState.supabaseClient = null;
    appState.currentUser = null;
    setActionMessage("Supabase SDK 加载失败，请刷新页面或检查网络。", "error");
    return;
  }
  appState.supabaseClient = window.supabase.createClient(config.url, config.anonKey);
  appState.supabaseClient.auth.onAuthStateChange(async (_event, session) => {
    appState.currentUser = session?.user || null;
    onCloudChange();
    if (appState.currentUser) {
      queueCloudDataLoad();
    }
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
    setActionMessage(`${mode === "signUp" ? "注册" : "登录"}成功。`, "success");
    onCloudChange();
    queueCloudDataLoad();
    return;
  }
  setActionMessage("注册成功，请按邮箱确认后再登录。", "success");
}

export function queueCloudDataLoad() {
  if (!isCloudReady()) return Promise.resolve();
  if (!cloudLoadPromise) {
    cloudLoadPromise = loadCloudData()
      .catch((error) => {
        setActionMessage(`数据读取失败：${error.message}`, "error");
      })
      .finally(() => {
        cloudLoadPromise = null;
        onCloudChange();
      });
  }
  return cloudLoadPromise;
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
  }
  await loadMonthPageData();
}

export async function loadMonthPageData() {
  if (!isCloudReady()) {
    appState.data.monthPage = null;
    return;
  }
  const { data, error } = await appState.supabaseClient.rpc("home_get_month_page", {
    p_month_key: appState.activeMonth,
  });
  if (error) {
    setActionMessage(`月度数据读取失败：${error.message}`, "error");
    appState.data.monthPage = null;
    return;
  }
  appState.data.monthPage = data;
}

export async function persist(kind, record) {
  if (!isCloudReady()) return;
  const table = `home_${kind}`;
  const { error } = await appState.supabaseClient.from(table).upsert(withUser(record));
  if (error) alert(`Supabase 保存失败：${error.message}`);
}

export async function persistMonth(record) {
  if (!isCloudReady()) return;
  const { error } = await appState.supabaseClient
    .from("home_months")
    .upsert(withUser(record), { onConflict: "user_id,month_key" });
  if (error) alert(`Supabase 保存失败：${error.message}`);
}

export async function removeCloud(kind, id) {
  if (!isCloudReady()) return;
  const { error } = await appState.supabaseClient.from(`home_${kind}`).delete().eq("id", id).eq("user_id", appState.currentUser.id);
  if (error) alert(`Supabase 删除失败：${error.message}`);
}

async function selectCloud(table) {
  const { data, error } = await appState.supabaseClient.from(table).select("*").order("created_at", { ascending: true });
  if (error) {
    alert(`Supabase 读取失败：${error.message}`);
    return null;
  }
  return data || [];
}

function withUser(record) {
  return { ...record, user_id: appState.currentUser.id };
}
