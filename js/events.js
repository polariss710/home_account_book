import { els } from "#elements";
import { appState, findFixedTemplate, findJpyAccount, getFixedTemplateTermStatus } from "#state";
import { render } from "#render";
import { setActionMessage, switchView } from "#ui";
import {
  createTemplate,
  generateFixedMonth,
  isCloudReady,
  loadAppData,
  loadExternalTransactionRequests,
  loadFixedMonthPage,
  loadYearSummary,
  passwordAuth,
  saveAccount,
  savePaymentChannel,
  sendMagicLink,
  signOut,
  syncFixedMonthItems,
  updateAccount,
  updatePaymentChannel,
  updateTemplate,
} from "#supabase";
import { formData, toNumber } from "#utils";

export function bindEvents() {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.addEventListener("click", async () => {
      switchView(button.dataset.view);
      if (button.dataset.view === "annual" && isCloudReady()) {
        await loadYearSummary(appState.activeYear);
      }
      if (button.dataset.view === "externalRequests" && isCloudReady()) {
        await loadExternalTransactionRequests();
      }
      render();
    });
  });

  els.templateForm.elements.fixed_type.addEventListener("change", updateFixedTypeControls);
  els.templatePaymentGroupSelect.addEventListener("change", applySelectedPaymentChannelDueDay);
  updateFixedTypeControls();

  els.monthPicker.addEventListener("change", async () => {
    appState.activeMonth = els.monthPicker.value;
    await loadAppData();
    render();
  });

  els.refreshBtn.addEventListener("click", async () => {
    await loadCurrentViewData();
    render();
  });

  els.generateMonthBtn.addEventListener("click", async () => {
    if (!requireCloudReady("请先登录后再生成本月固定项。")) return;
    const result = await generateFixedMonth();
    if (!result) return;
    await loadFixedMonthPage();
    const insertedCount = Number(result.inserted_count || 0);
    setActionMessage(generationMessage(result), insertedCount > 0 || result.all_generated ? "success" : "error");
    render();
  });

  els.syncMonthBtn.addEventListener("click", async () => {
    if (!requireCloudReady("请先登录后再同步本月固定项。")) return;
    const confirmed = window.confirm("同步后，本月固定项的名称、金额、支付渠道、期限、期数会按当前模板更新；状态和备注会保留。继续同步？");
    if (!confirmed) return;
    const result = await syncFixedMonthItems();
    if (!result) return;
    await loadFixedMonthPage();
    setActionMessage(`本月固定项已同步 ${Number(result.updated_count || 0)} 条。`, "success");
    render();
  });

  els.templateForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再保存模板。")) return;
    const form = event.currentTarget;
    const data = formData(form);
    const existingTemplate = findFixedTemplate(appState.editingTemplateId);
    const templateId = appState.editingTemplateId;
    const isShortTerm = data.fixed_type === "short_term";
    const record = {
      direction: data.direction,
      name: data.name.trim(),
      fixed_type: data.fixed_type,
      default_amount: toNumber(data.default_amount),
      payment_group: data.payment_group.trim() || null,
      due_day: data.due_day ? Number(data.due_day) : null,
      start_month: isShortTerm ? data.start_month || appState.activeMonth : null,
      total_terms: isShortTerm && data.total_terms ? Number(data.total_terms) : null,
      sort_order: existingTemplate?.sort_order ?? (appState.page?.templates || []).length,
    };
    const ok = templateId
      ? await updateTemplate(templateId, record)
      : await createTemplate({
          ...record,
          id: crypto.randomUUID(),
          is_active: true,
          created_at: new Date().toISOString(),
        });
    if (!ok) return;
    await loadFixedMonthPage();
    resetTemplateForm();
    render();
  });

  els.templateCancelBtn.addEventListener("click", () => {
    resetTemplateForm();
  });

  els.accountForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再保存账户。")) return;
    const form = event.currentTarget;
    const data = formData(form);
    const accountId = appState.editingAccountId;
    const existingAccount = findJpyAccount(accountId);
    const record = {
      name: data.name.trim(),
      account_type: data.account_type,
      opening_balance: toNumber(data.opening_balance),
      sort_order: existingAccount?.sort_order ?? (appState.jpyPage?.accounts || []).length,
    };
    const ok = accountId
      ? await updateAccount(accountId, record)
      : await saveAccount({
          ...record,
          id: crypto.randomUUID(),
          is_active: true,
          created_at: new Date().toISOString(),
        });
    if (!ok) return;
    await loadAppData();
    resetAccountForm();
    render();
  });

  els.accountCancelBtn.addEventListener("click", () => {
    resetAccountForm();
  });

  els.paymentChannelForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再保存日元固定收支账户。")) return;
    const form = event.currentTarget;
    const data = formData(form);
    const channelId = appState.editingPaymentChannelId;
    const record = {
      name: data.name.trim(),
      default_due_day: data.default_due_day ? Number(data.default_due_day) : null,
    };
    const ok = channelId
      ? await updatePaymentChannel(channelId, record)
      : await savePaymentChannel({
          ...record,
          sort_order: (appState.page?.payment_channels || []).length,
          id: crypto.randomUUID(),
          is_active: true,
          created_at: new Date().toISOString(),
        });
    if (!ok) return;
    await loadFixedMonthPage();
    resetPaymentChannelForm();
    render();
  });

  els.paymentChannelCancelBtn.addEventListener("click", () => {
    resetPaymentChannelForm();
  });

  els.authForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    const data = formData(event.currentTarget);
    await sendMagicLink(data.email.trim());
  });

  els.passwordSignInBtn.addEventListener("click", async () => {
    await runPasswordAuth("signIn");
  });

  els.passwordSignUpBtn.addEventListener("click", async () => {
    await runPasswordAuth("signUp");
  });

  els.signOutBtn.addEventListener("click", async () => {
    await signOut();
    render();
  });
}

async function loadCurrentViewData() {
  if (appState.activeView === "annual") {
    await loadYearSummary(appState.activeYear);
    return;
  }
  if (appState.activeView === "externalRequests") {
    await loadExternalTransactionRequests();
    return;
  }
  await loadAppData();
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

function generationMessage(result) {
  const insertedCount = Number(result.inserted_count || 0);
  const eligibleCount = Number(result.eligible_count || 0);
  const expiredCount = (appState.page?.templates || []).filter(
    (template) => getFixedTemplateTermStatus(template, appState.activeMonth).kind === "expired",
  ).length;
  const expiredHint = expiredCount > 0 ? ` 另有 ${expiredCount} 个短期模板已到期，不会生成本月固定项，可检查后停止生成。` : "";
  if (insertedCount > 0) return `本月固定项已生成 ${insertedCount} 条。${expiredHint}`;
  if (eligibleCount === 0) {
    return expiredCount > 0
      ? `当前没有可生成的固定模板。有 ${expiredCount} 个短期模板已到期，不会生成本月固定项，可检查后停止生成。`
      : "当前没有可生成的固定模板，请先新增模板。";
  }
  if (result.all_generated) return `当前还在使用的固定项已经生成完毕，无需重复生成。${expiredHint}`;
  return `没有新增固定项，请刷新后重试；若仍出现，请检查恢复生成的模板状态。${expiredHint}`;
}

function resetAccountForm() {
  appState.editingAccountId = null;
  els.accountForm.reset();
  els.accountSubmitBtn.textContent = "添加";
  els.accountCancelBtn.hidden = true;
}

function resetTemplateForm() {
  appState.editingTemplateId = null;
  els.templateForm.reset();
  els.templateFormTitle.textContent = "新增固定模板";
  els.templateSubmitBtn.textContent = "保存模板";
  els.templateCancelBtn.hidden = true;
  updateFixedTypeControls();
}

function resetPaymentChannelForm() {
  appState.editingPaymentChannelId = null;
  els.paymentChannelForm.reset();
  els.paymentChannelSubmitBtn.textContent = "添加";
  els.paymentChannelCancelBtn.hidden = true;
}

function updateFixedTypeControls() {
  const isShortTerm = els.templateForm.elements.fixed_type.value === "short_term";
  els.templateForm.elements.start_month.disabled = !isShortTerm;
  els.templateForm.elements.total_terms.disabled = !isShortTerm;
  if (!isShortTerm) {
    els.templateForm.elements.start_month.value = "";
    els.templateForm.elements.total_terms.value = "";
  }
}

function applySelectedPaymentChannelDueDay() {
  const dueDay = els.templatePaymentGroupSelect.selectedOptions[0]?.dataset.defaultDueDay || "";
  els.templateForm.elements.due_day.value = dueDay;
}
