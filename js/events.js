import { els } from "./elements.js?v=20260530-responsive-5";
import { appState, findFixedTemplate, getFixedTemplateTermStatus } from "./state.js?v=20260530-responsive-5";
import { render } from "./render.js?v=20260530-responsive-5";
import { setActionMessage, switchView } from "./ui.js?v=20260530-responsive-5";
import {
  generateFixedMonth,
  isCloudReady,
  loadAppData,
  loadFixedMonthPage,
  passwordAuth,
  saveAccount,
  createTemplate,
  updateTemplate,
  sendMagicLink,
  signOut,
} from "./supabase.js?v=20260530-responsive-5";
import { emptyToNull, formData, toNumber } from "./utils.js?v=20260530-responsive-5";

export function bindEvents() {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  els.monthPicker.addEventListener("change", async () => {
    appState.activeMonth = els.monthPicker.value;
    await loadAppData();
    render();
  });

  els.refreshBtn.addEventListener("click", async () => {
    await loadAppData();
    render();
  });

  els.generateMonthBtn.addEventListener("click", async () => {
    if (!requireCloudReady("请先登录后再生成本月固定项。")) return;
    const result = await generateFixedMonth();
    if (!result) return;
    await loadFixedMonthPage();
    const insertedCount = Number(result.inserted_count || 0);
    const eligibleCount = Number(result.eligible_count || 0);
    setActionMessage(generationMessage(result), insertedCount > 0 || result.all_generated ? "success" : "error");
    render();
  });

  els.templateForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再保存模板。")) return;
    const form = event.currentTarget;
    const data = formData(form);
    const existingTemplate = findFixedTemplate(appState.editingTemplateId);
    const templateId = appState.editingTemplateId;
    const record = {
      direction: data.direction,
      name: data.name.trim(),
      fixed_type: data.fixed_type,
      default_amount: toNumber(data.default_amount),
      payment_group: data.payment_group.trim() || null,
      due_day: data.due_day ? Number(data.due_day) : null,
      start_month: data.fixed_type === "short_term" ? data.start_month || appState.activeMonth : emptyToNull(data.start_month),
      total_terms: data.total_terms ? Number(data.total_terms) : null,
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
    if (!requireCloudReady("请先登录后再新增账户。")) return;
    const form = event.currentTarget;
    const data = formData(form);
    const record = {
      id: crypto.randomUUID(),
      name: data.name.trim(),
      account_type: data.account_type,
      opening_balance: toNumber(data.opening_balance),
      is_active: true,
      sort_order: (appState.page?.accounts || []).length,
      created_at: new Date().toISOString(),
    };
    const ok = await saveAccount(record);
    if (!ok) return;
    await loadAppData();
    form.reset();
    render();
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

function resetTemplateForm() {
  appState.editingTemplateId = null;
  els.templateForm.reset();
  els.templateFormTitle.textContent = "新增固定模板";
  els.templateSubmitBtn.textContent = "保存模板";
  els.templateCancelBtn.hidden = true;
}
