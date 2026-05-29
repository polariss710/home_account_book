import { els } from "./elements.js?v=20260529-fixed-8";
import { appState, findFixedTemplate } from "./state.js?v=20260529-fixed-8";
import { render } from "./render.js?v=20260529-fixed-8";
import { setActionMessage, switchView } from "./ui.js?v=20260529-fixed-8";
import {
  generateFixedMonth,
  isCloudReady,
  loadFixedMonthPage,
  passwordAuth,
  saveAccount,
  saveTemplate,
  sendMagicLink,
  signOut,
} from "./supabase.js?v=20260529-fixed-8";
import { emptyToNull, formData, toNumber } from "./utils.js?v=20260529-fixed-8";

export function bindEvents() {
  document.querySelectorAll(".nav-button").forEach((button) => {
    button.addEventListener("click", () => switchView(button.dataset.view));
  });

  els.monthPicker.addEventListener("change", async () => {
    appState.activeMonth = els.monthPicker.value;
    await loadFixedMonthPage();
    render();
  });

  els.refreshBtn.addEventListener("click", async () => {
    await loadFixedMonthPage();
    render();
  });

  els.generateMonthBtn.addEventListener("click", async () => {
    if (!requireCloudReady("请先登录后再生成本月固定项。")) return;
    const result = await generateFixedMonth();
    if (!result) return;
    await loadFixedMonthPage();
    const insertedCount = Number(result.inserted_count || 0);
    const eligibleCount = Number(result.eligible_count || 0);
    const existingCount = Number(result.existing_count || 0);
    if (insertedCount > 0) {
      setActionMessage(`本月固定项已生成 ${insertedCount} 条。`, "success");
    } else if (eligibleCount === 0) {
      setActionMessage("当前没有可生成的固定模板，请先新增模板。", "error");
    } else if (existingCount >= eligibleCount) {
      setActionMessage("当前还在使用的固定项已经生成完毕，无需重复生成。", "success");
    } else {
      setActionMessage("没有新增固定项，请检查模板是否已生成或已到期。", "error");
    }
    render();
  });

  els.templateForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!requireCloudReady("请先登录后再新增模板。")) return;
    const form = event.currentTarget;
    const data = formData(form);
    const existingTemplate = findFixedTemplate(appState.editingTemplateId);
    const record = {
      id: appState.editingTemplateId || crypto.randomUUID(),
      direction: data.direction,
      name: data.name.trim(),
      fixed_type: data.fixed_type,
      default_amount: toNumber(data.default_amount),
      payment_group: data.payment_group.trim() || null,
      due_day: data.due_day ? Number(data.due_day) : null,
      start_month: data.fixed_type === "short_term" ? data.start_month || appState.activeMonth : emptyToNull(data.start_month),
      total_terms: data.total_terms ? Number(data.total_terms) : null,
      is_active: true,
      sort_order: existingTemplate?.sort_order ?? (appState.page?.templates || []).length,
      created_at: existingTemplate?.created_at || new Date().toISOString(),
    };
    const ok = await saveTemplate(record);
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
    await loadFixedMonthPage();
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

function resetTemplateForm() {
  appState.editingTemplateId = null;
  els.templateForm.reset();
  els.templateFormTitle.textContent = "新增固定模板";
  els.templateSubmitBtn.textContent = "保存模板";
  els.templateCancelBtn.hidden = true;
}
