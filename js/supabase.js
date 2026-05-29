import { appState } from "./state.js?v=20260530-responsive-4";
import { getRedirectUrl } from "./utils.js?v=20260530-responsive-4";
import { getConfig, setActionMessage } from "./ui.js?v=20260530-responsive-4";

let onCloudChange = () => {};
let pageLoadPromise = null;

export function setCloudChangeHandler(handler) {
  onCloudChange = handler;
}

export async function initSupabaseClient() {
  const config = getConfig();
  if (!window.supabase) {
    setActionMessage("Supabase SDK 加载失败，请刷新页面或检查网络。", "error");
    return;
  }
  appState.supabaseClient = window.supabase.createClient(config.url, config.anonKey);
  appState.supabaseClient.auth.onAuthStateChange((_event, session) => {
    appState.currentUser = session?.user || null;
    onCloudChange();
    if (isCloudReady()) queuePageLoad();
  });
}

export async function refreshSession() {
  if (!appState.supabaseClient) return;
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
  if (!appState.supabaseClient) return;
  const { error } = await appState.supabaseClient.auth.signInWithOtp({
    email,
    options: { emailRedirectTo: getRedirectUrl() },
  });
  if (error) {
    setActionMessage(`登录链接发送失败：${error.message}`, "error");
    return;
  }
  setActionMessage("登录链接已发送，请打开邮箱完成登录。", "success");
}

export async function signOut() {
  if (!appState.supabaseClient) return;
  await appState.supabaseClient.auth.signOut();
  appState.currentUser = null;
}

export async function passwordAuth(mode, email, password) {
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
    queuePageLoad();
    return;
  }
  setActionMessage("注册成功，请按邮箱确认后再登录。", "success");
}

export function queuePageLoad() {
  if (!isCloudReady()) return Promise.resolve();
  if (!pageLoadPromise) {
    pageLoadPromise = loadAppData()
      .catch((error) => {
        setActionMessage(`数据读取失败：${error.message}`, "error");
      })
      .finally(() => {
        pageLoadPromise = null;
        onCloudChange();
      });
  }
  return pageLoadPromise;
}

export async function loadAppData() {
  await Promise.all([loadFixedMonthPage(), loadJpyAccountPage()]);
}

export async function loadFixedMonthPage() {
  if (!isCloudReady()) return;
  const { data, error } = await appState.supabaseClient.rpc("home_get_fixed_month_page", {
    p_month_key: appState.activeMonth,
    p_currency: "JPY",
  });
  if (error) {
    setActionMessage(`固定收支读取失败：${error.message}`, "error");
    appState.page = null;
    return;
  }
  appState.page = data;
}

export async function loadJpyAccountPage() {
  if (!isCloudReady()) return;
  const { data, error } = await appState.supabaseClient.rpc("home_get_jpy_account_page", {
    p_month_key: appState.activeMonth,
  });
  if (error) {
    setActionMessage(`日元账户读取失败：${error.message}`, "error");
    appState.jpyPage = null;
    return;
  }
  appState.jpyPage = data;
}

export async function generateFixedMonth() {
  const { data, error } = await appState.supabaseClient.rpc("home_generate_fixed_month", {
    p_month_key: appState.activeMonth,
    p_currency: "JPY",
  });
  if (error) {
    setActionMessage(`生成本月固定项失败：${error.message}`, "error");
    return null;
  }
  if (!data) {
    setActionMessage("生成结果为空，请先执行最新的 supabase-schema.sql。", "error");
    return null;
  }
  return data;
}

export async function saveAccount(record) {
  return upsert("home_accounts", withUser({ ...record, currency: "JPY" }));
}

export async function createTemplate(record) {
  return upsert("home_fixed_templates", withUser({ ...record, currency: "JPY" }));
}

export async function updateTemplate(id, patch) {
  return updateById("home_fixed_templates", id, patch);
}

export async function saveMonthItem(record) {
  return upsert("home_fixed_month_items", withUser(record));
}

export async function saveJpyTransaction(record) {
  const allowedRecord = {
    id: record.id,
    transaction_type: record.transaction_type,
    account_id: record.account_id,
    transfer_account_id: record.transfer_account_id,
    currency: "JPY",
    transacted_at: record.transacted_at,
    amount: record.amount,
    description: record.description,
    note: record.note,
    created_at: record.created_at,
  };
  return upsert("home_jpy_transactions", withUser(allowedRecord));
}

export async function deactivateTemplate(id) {
  return updateById("home_fixed_templates", id, { is_active: false });
}

export async function reactivateTemplate(id) {
  return updateById("home_fixed_templates", id, { is_active: true });
}

export async function deleteMonthItem(id) {
  return deleteById("home_fixed_month_items", id);
}

export async function deleteJpyTransaction(id) {
  return deleteById("home_jpy_transactions", id);
}

async function upsert(table, record) {
  if (!isCloudReady()) return false;
  const { error } = await appState.supabaseClient.from(table).upsert(record);
  if (error) {
    setActionMessage(`Supabase 保存失败：${error.message}`, "error");
    return false;
  }
  return true;
}

async function updateById(table, id, patch) {
  if (!isCloudReady()) return false;
  const { data, error } = await appState.supabaseClient
    .from(table)
    .update(patch)
    .eq("id", id)
    .eq("user_id", appState.currentUser.id)
    .select("id")
    .maybeSingle();
  if (error) {
    setActionMessage(`Supabase 更新失败：${error.message}`, "error");
    return false;
  }
  if (!data) {
    setActionMessage("Supabase 更新失败：没有找到可更新的数据。", "error");
    return false;
  }
  return true;
}

async function deleteById(table, id) {
  if (!isCloudReady()) return false;
  const { error } = await appState.supabaseClient.from(table).delete().eq("id", id).eq("user_id", appState.currentUser.id);
  if (error) {
    setActionMessage(`Supabase 删除失败：${error.message}`, "error");
    return false;
  }
  return true;
}

function withUser(record) {
  return { ...record, user_id: appState.currentUser.id };
}
