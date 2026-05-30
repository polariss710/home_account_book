import { appState } from "#state";
import { getRedirectUrl } from "#utils";
import { getConfig, setActionMessage } from "#ui";

let onCloudChange = () => {};
let pageLoadPromise = null;

function handleRpcResult(data, fallbackMessage) {
  if (data?.ok === false) {
    setActionMessage(data.message || fallbackMessage, "error");
    return null;
  }
  return data;
}

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

function queuePageLoad() {
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
  await Promise.all([loadFixedMonthPage(), loadJpyAccountPage(), loadCnyAccountPage(), loadCnyFixedPage()]);
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

async function loadJpyAccountPage() {
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

async function loadCnyAccountPage() {
  if (!isCloudReady()) return;
  const { data, error } = await appState.supabaseClient.rpc("home_get_cny_account_page", {
    p_month_key: appState.activeMonth,
  });
  if (error) {
    setActionMessage(`人民币账户读取失败：${error.message}`, "error");
    appState.cnyPage = null;
    return;
  }
  appState.cnyPage = data;
}

async function loadCnyFixedPage() {
  if (!isCloudReady()) return;
  const { data, error } = await appState.supabaseClient.rpc("home_get_fixed_month_page", {
    p_month_key: appState.activeMonth,
    p_currency: "CNY",
  });
  if (error) {
    setActionMessage(`人民币固定收支读取失败：${error.message}`, "error");
    appState.cnyFixedPage = null;
    return;
  }
  appState.cnyFixedPage = data;
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

export async function syncFixedMonthItems() {
  const { data, error } = await appState.supabaseClient.rpc("home_sync_fixed_month_items", {
    p_month_key: appState.activeMonth,
    p_currency: "JPY",
  });
  if (error) {
    setActionMessage(`同步本月固定项失败：${error.message}`, "error");
    return null;
  }
  return data;
}

export async function generateCnyFixedMonth() {
  const { data, error } = await appState.supabaseClient.rpc("home_generate_fixed_month", {
    p_month_key: appState.activeMonth,
    p_currency: "CNY",
  });
  if (error) {
    setActionMessage(`生成人民币固定项失败：${error.message}`, "error");
    return null;
  }
  return data;
}

export async function createFixedTransfer(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_create_fixed_transfer", {
    p_month_key: appState.activeMonth,
    p_currency: "JPY",
    p_transaction_type: record.transaction_type,
    p_account_id: record.account_id,
    p_transacted_at: record.transacted_at,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`固定资金调拨失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "固定资金调拨失败。");
}

export async function createCnyToJpyFx(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_create_cny_to_jpy_fx", {
    p_cny_account_id: record.account_id,
    p_jpy_account_id: record.jpy_account_id,
    p_transacted_at: record.transacted_at,
    p_cny_amount: record.amount,
    p_jpy_amount: record.jpy_amount,
    p_description: record.description,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`购汇联动保存失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "购汇联动保存失败。");
}

export async function updateCnyToJpyFx(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_cny_to_jpy_fx", {
    p_cny_transaction_id: record.id,
    p_cny_account_id: record.account_id,
    p_jpy_account_id: record.jpy_account_id,
    p_transacted_at: record.transacted_at,
    p_cny_amount: record.amount,
    p_jpy_amount: record.jpy_amount,
    p_description: record.description,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`购汇联动更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "购汇联动更新失败。");
}

export async function createJpyToCnyFx(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_create_jpy_to_cny_fx", {
    p_jpy_account_id: record.account_id,
    p_cny_account_id: record.cny_account_id,
    p_transacted_at: record.transacted_at,
    p_jpy_amount: record.amount,
    p_cny_amount: record.cny_amount,
    p_description: record.description,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`换汇联动保存失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "换汇联动保存失败。");
}

export async function updateJpyToCnyFx(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_jpy_to_cny_fx", {
    p_jpy_transaction_id: record.id,
    p_jpy_account_id: record.account_id,
    p_cny_account_id: record.cny_account_id,
    p_transacted_at: record.transacted_at,
    p_jpy_amount: record.amount,
    p_cny_amount: record.cny_amount,
    p_description: record.description,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`换汇联动更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "换汇联动更新失败。");
}

export async function saveAccount(record) {
  return upsert("home_accounts", withUser({ ...record, currency: "JPY" }));
}

export async function saveCnyAccount(record) {
  return upsert("home_accounts", withUser({ ...record, currency: "CNY" }));
}

export async function updateAccount(id, patch) {
  return updateById("home_accounts", id, patch);
}

export async function createTemplate(record) {
  return upsert("home_fixed_templates", withUser({ ...record, currency: "JPY" }));
}

export async function createCnyTemplate(record) {
  return upsert("home_fixed_templates", withUser({ ...record, currency: "CNY" }));
}

export async function updateTemplate(id, patch) {
  return updateById("home_fixed_templates", id, patch);
}

export async function savePaymentChannel(record) {
  return upsert("home_payment_channels", withUser({ ...record, currency: "JPY" }));
}

export async function updatePaymentChannel(id, patch) {
  return updateById("home_payment_channels", id, patch);
}

export async function saveMonthItem(record) {
  return upsert("home_fixed_month_items", withUser(record));
}

export async function updateMonthItemStatus(id, status) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_fixed_month_item_status", {
    p_item_id: id,
    p_status: status,
  });
  if (error) {
    setActionMessage(`固定项状态更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "固定项状态更新失败。");
}

export async function updateMonthItemsStatus(direction, status) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_fixed_month_items_status", {
    p_month_key: appState.activeMonth,
    p_currency: "JPY",
    p_direction: direction,
    p_status: status,
  });
  if (error) {
    setActionMessage(`固定项状态更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "固定项状态更新失败。");
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

export async function saveCnyTransaction(record) {
  const allowedRecord = {
    id: record.id,
    transaction_type: record.transaction_type,
    account_id: record.account_id,
    transfer_account_id: record.transfer_account_id,
    currency: "CNY",
    transacted_at: record.transacted_at,
    amount: record.amount,
    description: record.description,
    note: record.note,
    created_at: record.created_at,
  };
  return upsert("home_cny_transactions", withUser(allowedRecord));
}

export async function updateJpyTransaction(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_jpy_transaction", {
    p_transaction_id: record.id,
    p_account_id: record.account_id,
    p_transfer_account_id: record.transfer_account_id,
    p_transacted_at: record.transacted_at,
    p_amount: record.amount,
    p_description: record.description,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`日元流水更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "日元流水更新失败。");
}

export async function updateCnyTransaction(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_cny_transaction", {
    p_transaction_id: record.id,
    p_account_id: record.account_id,
    p_transfer_account_id: record.transfer_account_id,
    p_transacted_at: record.transacted_at,
    p_amount: record.amount,
    p_description: record.description,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`人民币流水更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "人民币流水更新失败。");
}

export async function updateCnyFixedItem(record) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_cny_fixed_item", {
    p_item_id: record.id,
    p_amount: record.amount,
    p_account_id: record.account_id,
    p_note: record.note,
  });
  if (error) {
    setActionMessage(`人民币固定项更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "人民币固定项更新失败。");
}

export async function updateCnyFixedItemStatus(id, status) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_cny_fixed_item_status", {
    p_item_id: id,
    p_status: status,
  });
  if (error) {
    setActionMessage(`人民币固定项状态更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "人民币固定项状态更新失败。");
}

export async function updateCnyFixedItemsStatus(direction, status) {
  const { data, error } = await appState.supabaseClient.rpc("home_update_cny_fixed_items_status", {
    p_month_key: appState.activeMonth,
    p_direction: direction,
    p_status: status,
  });
  if (error) {
    setActionMessage(`人民币固定项批量状态更新失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "人民币固定项批量状态更新失败。");
}

export async function deactivateTemplate(id) {
  return updateById("home_fixed_templates", id, { is_active: false });
}

export async function reactivateTemplate(id) {
  return updateById("home_fixed_templates", id, { is_active: true });
}

export async function deactivatePaymentChannel(id) {
  return updateById("home_payment_channels", id, { is_active: false });
}

export async function deleteMonthItem(id) {
  const { data, error } = await appState.supabaseClient.rpc("home_delete_fixed_month_item", {
    p_item_id: id,
  });
  if (error) {
    setActionMessage(`固定项删除失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "固定项删除失败。");
}

export async function deleteJpyTransaction(id) {
  const { data, error } = await appState.supabaseClient.rpc("home_delete_jpy_transaction", {
    p_transaction_id: id,
  });
  if (error) {
    setActionMessage(`日元流水删除失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "日元流水删除失败。");
}

export async function deleteCnyTransaction(id) {
  const { data, error } = await appState.supabaseClient.rpc("home_delete_cny_transaction", {
    p_transaction_id: id,
  });
  if (error) {
    setActionMessage(`人民币流水删除失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "人民币流水删除失败。");
}

export async function deleteCnyToJpyFx(id) {
  const { data, error } = await appState.supabaseClient.rpc("home_delete_cny_to_jpy_fx", {
    p_cny_transaction_id: id,
  });
  if (error) {
    setActionMessage(`购汇联动删除失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "购汇联动删除失败。");
}

export async function deleteJpyToCnyFx(id) {
  const { data, error } = await appState.supabaseClient.rpc("home_delete_jpy_to_cny_fx", {
    p_jpy_transaction_id: id,
  });
  if (error) {
    setActionMessage(`换汇联动删除失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "换汇联动删除失败。");
}

export async function deleteCnyFixedItem(id) {
  const { data, error } = await appState.supabaseClient.rpc("home_delete_cny_fixed_item", {
    p_item_id: id,
  });
  if (error) {
    setActionMessage(`人民币固定项删除失败：${error.message}`, "error");
    return null;
  }
  return handleRpcResult(data, "人民币固定项删除失败。");
}

export async function deleteAccount(id) {
  return deleteById("home_accounts", id);
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
