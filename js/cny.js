import { els } from "#elements";
import { appState, findCnyAccount, findCnyTemplate } from "#state";
import {
  createCnyTemplate,
  deactivateTemplate,
  deleteAccount,
  deleteCnyTransaction,
  deleteMonthItem,
  generateCnyFixedMonth,
  isCloudReady,
  loadAppData,
  saveCnyAccount,
  saveCnyTransaction,
  saveMonthItem,
  updateAccount,
  updateCnyTransaction,
  updateMonthItemStatus,
  updateTemplate,
} from "#supabase";
import { setActionMessage } from "#ui";
import { emptyRow, escapeHtml, formData, moneyCny, toNumber } from "#utils";

export function bindCnyEvents() {
  els.cnyTransactionForm.elements.transaction_type.addEventListener("change", updateTransferAccountControl);
  els.cnyTransactionCancelBtn.addEventListener("click", resetTransactionForm);
  els.cnyTransactionForm.addEventListener("submit", saveTransaction);
  els.cnyFilterForm.addEventListener("submit", applyFilters);
  els.cnyFilterForm.elements.reset_filter.addEventListener("click", resetFilters);
  els.cnyFixedTemplateForm.addEventListener("submit", saveFixedTemplate);
  els.cnyFixedTemplateCancelBtn.addEventListener("click", resetFixedTemplateForm);
  els.generateCnyFixedMonthBtn.addEventListener("click", generateFixedItems);
  els.cnyAccountForm.addEventListener("submit", saveAccount);
  els.cnyAccountCancelBtn.addEventListener("click", resetAccountForm);
}

export function renderCnyPage() {
  renderBalances();
  renderAccountOptions();
  renderFilterControls();
  renderFixedItems();
  renderFixedTemplates();
  renderTransactions();
  renderAccounts();
  setTransactionDate();
  updateTransferAccountControl();
}

async function saveTransaction(event) {
  event.preventDefault();
  if (!isCloudReady()) {
    setActionMessage("请先登录后再保存人民币流水。", "error");
    return;
  }

  const form = event.currentTarget;
  const data = formData(form);
  const existingTransaction = findTransaction(appState.editingCnyTransactionId);
  const transactionType = existingTransaction?.transaction_type || data.transaction_type;
  const transferAccountId = transactionType === "transfer" ? data.transfer_account_id : null;
  if (transactionType === "transfer" && (!transferAccountId || transferAccountId === data.account_id)) {
    setActionMessage("账户间转账需要选择不同的转入账户。", "error");
    return;
  }

  const record = {
    id: appState.editingCnyTransactionId || crypto.randomUUID(),
    transaction_type: transactionType,
    account_id: data.account_id,
    transfer_account_id: transferAccountId,
    transacted_at: data.transacted_at,
    amount: toNumber(data.amount),
    description: data.description.trim(),
    note: data.note.trim(),
    created_at: existingTransaction?.created_at || new Date().toISOString(),
  };
  const result = appState.editingCnyTransactionId ? await updateCnyTransaction(record) : await saveCnyTransaction(record);
  if (!result) return;
  resetTransactionForm();
  await refreshAfterMutation(result.message || "人民币流水已保存。", "success");
}

async function saveAccount(event) {
  event.preventDefault();
  if (!isCloudReady()) {
    setActionMessage("请先登录后再保存人民币账户。", "error");
    return;
  }

  const form = event.currentTarget;
  const data = formData(form);
  const accountId = appState.editingCnyAccountId;
  const existingAccount = findCnyAccount(accountId);
  const record = {
    name: data.name.trim(),
    account_type: data.account_type,
    opening_balance: toNumber(data.opening_balance),
    sort_order: existingAccount?.sort_order ?? (appState.cnyPage?.accounts || []).length,
  };
  const ok = accountId
    ? await updateAccount(accountId, record)
    : await saveCnyAccount({
        ...record,
        id: crypto.randomUUID(),
        is_active: true,
        created_at: new Date().toISOString(),
      });
  if (!ok) return;
  resetAccountForm();
  await refreshAfterMutation("人民币账户已保存。", "success");
}

async function saveFixedTemplate(event) {
  event.preventDefault();
  if (!isCloudReady()) {
    setActionMessage("请先登录后再保存人民币固定项。", "error");
    return;
  }

  const form = event.currentTarget;
  const data = formData(form);
  const templateId = appState.editingCnyTemplateId;
  const existingTemplate = findCnyTemplate(templateId);
  const record = {
    direction: data.direction,
    name: data.name.trim(),
    fixed_type: "long_term",
    default_amount: toNumber(data.default_amount),
    payment_group: null,
    due_day: data.due_day ? Number(data.due_day) : null,
    start_month: null,
    total_terms: null,
    sort_order: existingTemplate?.sort_order ?? (appState.cnyFixedPage?.templates || []).length,
  };
  const ok = templateId
    ? await updateTemplate(templateId, record)
    : await createCnyTemplate({
        ...record,
        id: crypto.randomUUID(),
        is_active: true,
        created_at: new Date().toISOString(),
      });
  if (!ok) return;
  resetFixedTemplateForm();
  await refreshAfterMutation("人民币固定项已保存。", "success");
}

async function generateFixedItems() {
  if (!isCloudReady()) {
    setActionMessage("请先登录后再生成人民币固定项。", "error");
    return;
  }
  const result = await generateCnyFixedMonth();
  if (!result) return;
  await refreshAfterMutation(cnyGenerationMessage(result), Number(result.inserted_count || 0) > 0 || result.all_generated ? "success" : "error");
}

function renderBalances() {
  const accounts = appState.cnyPage?.accounts || [];
  els.cnyBalanceRows.innerHTML = accounts.length
    ? accounts
        .map(
          (account) => `
            <div class="balance-card">
              <div class="balance-card-main">
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountType(account.account_type)} · 期初 ${moneyCny(account.opening_balance || 0)}</span>
              </div>
              <div class="balance-current">
                <span>当前余额</span>
                <strong>${moneyCny(account.current_balance || 0)}</strong>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无人民币账户</div>`;
}

function renderAccountOptions() {
  const accounts = appState.cnyPage?.accounts || [];
  const options = accounts.map((account) => `<option value="${account.id}">${escapeHtml(account.name)}</option>`).join("");
  els.cnyAccountSelect.innerHTML = options || `<option value="">请先新增账户</option>`;
  els.cnyTransferAccountSelect.innerHTML = `<option value="">不使用</option>${options}`;
  els.cnyFilterAccountSelect.innerHTML = `<option value="">全部账户</option>${options}`;
  updateTransferAccountControl();
}

function renderFilterControls() {
  const filters = appState.cnyFilters;
  els.cnyFilterForm.elements.date_from.value = filters.dateFrom || "";
  els.cnyFilterForm.elements.date_to.value = filters.dateTo || "";
  els.cnyFilterForm.elements.transaction_type.value = filters.transactionType || "";
  els.cnyFilterAccountSelect.value = filters.accountId || "";
}

function renderFixedItems() {
  const incomeItems = appState.cnyFixedPage?.income_items || [];
  const expenseItems = appState.cnyFixedPage?.expense_items || [];
  els.cnyFixedIncomeRows.innerHTML = incomeItems.length ? incomeItems.map(fixedItemRow).join("") : emptyRow(6);
  els.cnyFixedExpenseRows.innerHTML = expenseItems.length ? expenseItems.map(fixedItemRow).join("") : emptyRow(6);
  bindFixedItemControls();
}

function fixedItemRow(item) {
  return `
    <tr>
      <td>${escapeHtml(item.name)}</td>
      <td><input class="table-input amount-input" data-cny-fixed-amount="${item.id}" type="number" step="0.01" value="${Number(item.amount || 0)}" /></td>
      <td>${escapeHtml(item.due_date || "-")}</td>
      <td>${fixedStatusSelect(item)}</td>
      <td><input class="table-input" data-cny-fixed-note="${item.id}" value="${escapeHtml(item.note || "")}" /></td>
      <td><button class="danger-button compact-button" data-delete-cny-fixed="${item.id}" type="button">删除</button></td>
    </tr>
  `;
}

function fixedStatusSelect(item) {
  return `
    <select class="table-input" data-cny-fixed-status="${item.id}">
      <option value="unpaid"${item.status === "unpaid" ? " selected" : ""}>未付</option>
      <option value="paid"${item.status === "paid" ? " selected" : ""}>已付</option>
      <option value="settled"${item.status === "settled" ? " selected" : ""}>已结清</option>
    </select>
  `;
}

function bindFixedItemControls() {
  document.querySelectorAll("[data-cny-fixed-amount]").forEach((input) => {
    input.addEventListener("change", () => saveFixedItemPatch(input.dataset.cnyFixedAmount, { amount: Number(input.value || 0) }));
  });
  document.querySelectorAll("[data-cny-fixed-status]").forEach((select) => {
    select.addEventListener("change", () => saveFixedItemStatus(select.dataset.cnyFixedStatus, select.value));
  });
  document.querySelectorAll("[data-cny-fixed-note]").forEach((input) => {
    input.addEventListener("change", () => saveFixedItemPatch(input.dataset.cnyFixedNote, { note: input.value.trim() }));
  });
  document.querySelectorAll("[data-delete-cny-fixed]").forEach((button) => {
    button.addEventListener("click", async () => {
      const result = await deleteMonthItem(button.dataset.deleteCnyFixed);
      if (!result) return;
      await refreshAfterMutation(result.message || "人民币固定项已删除。", "success");
    });
  });
}

async function saveFixedItemPatch(id, patch) {
  const item = findFixedItem(id);
  if (!item) return;
  const ok = await saveMonthItem({ ...item, ...patch });
  if (!ok) return;
  await refreshAfterMutation("人民币固定项已更新。", "success");
}

async function saveFixedItemStatus(id, status) {
  const result = await updateMonthItemStatus(id, status);
  if (!result) return;
  await refreshAfterMutation(result.message || "人民币固定项状态已更新。", "success");
}

function renderFixedTemplates() {
  const templates = appState.cnyFixedPage?.templates || [];
  els.cnyFixedTemplateRows.innerHTML = templates.length
    ? templates.map(fixedTemplateRow).join("")
    : `<div class="empty-state">暂无人民币固定模板</div>`;
  bindFixedTemplateControls();
}

function fixedTemplateRow(template) {
  return `
    <div class="settings-item">
      <div>
        <strong>${escapeHtml(template.name)}</strong>
        <span>${labelDirection(template.direction)} · ${moneyCny(template.default_amount || 0)} · 支付日 ${template.due_day || "-"}</span>
      </div>
      <div class="button-row">
        <button class="ghost-button compact-button" data-edit-cny-template="${template.id}" type="button">编辑</button>
        <button class="ghost-button compact-button" data-copy-cny-template="${template.id}" type="button">复制</button>
        <button class="danger-button compact-button" data-disable-cny-template="${template.id}" type="button">停用</button>
      </div>
    </div>
  `;
}

function bindFixedTemplateControls() {
  document.querySelectorAll("[data-edit-cny-template]").forEach((button) => {
    button.addEventListener("click", () => {
      const template = findCnyTemplate(button.dataset.editCnyTemplate);
      if (!template) return;
      setFixedTemplateForm(template, "edit");
    });
  });
  document.querySelectorAll("[data-copy-cny-template]").forEach((button) => {
    button.addEventListener("click", () => {
      const template = findCnyTemplate(button.dataset.copyCnyTemplate);
      if (!template) return;
      setFixedTemplateForm({ ...template, name: `${template.name} 复制` }, "copy");
    });
  });
  document.querySelectorAll("[data-disable-cny-template]").forEach((button) => {
    button.addEventListener("click", async () => {
      const template = findCnyTemplate(button.dataset.disableCnyTemplate);
      if (!template) return;
      const confirmed = window.confirm(`停用「${template.name}」？历史月份记录会保留。`);
      if (!confirmed) return;
      const ok = await deactivateTemplate(template.id);
      if (!ok) return;
      await refreshAfterMutation("人民币固定模板已停用。", "success");
    });
  });
}

function updateTransferAccountControl() {
  const isTransfer = els.cnyTransactionForm.elements.transaction_type.value === "transfer";
  els.cnyTransferAccountSelect.disabled = !isTransfer;
  els.cnyTransferAccountSelect.required = isTransfer;
  if (!isTransfer) els.cnyTransferAccountSelect.value = "";
}

function renderTransactions() {
  const transactions = filteredTransactions();
  els.cnyTransactionRows.innerHTML = transactions.length ? transactions.map(transactionRow).join("") : emptyRow(8);
  bindTransactionControls();
}

function filteredTransactions() {
  const filters = appState.cnyFilters;
  return (appState.cnyPage?.transactions || []).filter((transaction) => {
    if (filters.dateFrom && transaction.transacted_at < filters.dateFrom) return false;
    if (filters.dateTo && transaction.transacted_at > filters.dateTo) return false;
    if (filters.transactionType && transaction.transaction_type !== filters.transactionType) return false;
    if (filters.accountId && transaction.account_id !== filters.accountId && transaction.transfer_account_id !== filters.accountId) return false;
    return true;
  });
}

function transactionRow(item) {
  return `
    <tr>
      <td>${escapeHtml(item.transacted_at)}</td>
      <td>${labelTransactionType(item.transaction_type)}</td>
      <td>${escapeHtml(item.account_name || "-")}</td>
      <td>${escapeHtml(item.transfer_account_name || "-")}</td>
      <td><input class="table-input amount-input" data-cny-amount="${item.id}" type="number" step="0.01" value="${Number(item.amount || 0)}" /></td>
      <td><input class="table-input" data-cny-description="${item.id}" value="${escapeHtml(item.description || "")}" /></td>
      <td><input class="table-input" data-cny-note="${item.id}" value="${escapeHtml(item.note || "")}" /></td>
      <td>
        <div class="button-row">
          <button class="ghost-button compact-button" data-edit-cny="${item.id}" type="button">编辑</button>
          <button class="ghost-button compact-button" data-copy-cny="${item.id}" type="button">复制</button>
          <button class="danger-button compact-button" data-delete-cny="${item.id}" type="button">删除</button>
        </div>
      </td>
    </tr>
  `;
}

function bindTransactionControls() {
  document.querySelectorAll("[data-cny-amount]").forEach((input) => {
    input.addEventListener("change", () => saveTransactionPatch(input.dataset.cnyAmount, { amount: Number(input.value || 0) }));
  });
  document.querySelectorAll("[data-cny-description]").forEach((input) => {
    input.addEventListener("change", () => saveTransactionPatch(input.dataset.cnyDescription, { description: input.value.trim() }));
  });
  document.querySelectorAll("[data-cny-note]").forEach((input) => {
    input.addEventListener("change", () => saveTransactionPatch(input.dataset.cnyNote, { note: input.value.trim() }));
  });
  document.querySelectorAll("[data-edit-cny]").forEach((button) => {
    button.addEventListener("click", () => {
      const transaction = findTransaction(button.dataset.editCny);
      if (!transaction) return;
      setTransactionForm(transaction, "edit");
    });
  });
  document.querySelectorAll("[data-copy-cny]").forEach((button) => {
    button.addEventListener("click", () => {
      const transaction = findTransaction(button.dataset.copyCny);
      if (!transaction) return;
      setTransactionForm({ ...transaction, description: `${transaction.description} 复制` }, "copy");
    });
  });
  document.querySelectorAll("[data-delete-cny]").forEach((button) => {
    button.addEventListener("click", async () => {
      const result = await deleteCnyTransaction(button.dataset.deleteCny);
      if (!result) return;
      await refreshAfterMutation(result.message || "人民币流水已删除。", "success");
    });
  });
}

function applyFilters(event) {
  event.preventDefault();
  const data = formData(event.currentTarget);
  appState.cnyFilters = {
    dateFrom: data.date_from,
    dateTo: data.date_to,
    transactionType: data.transaction_type,
    accountId: data.account_id,
  };
  renderTransactions();
}

function resetFilters() {
  appState.cnyFilters = {
    dateFrom: "",
    dateTo: "",
    transactionType: "",
    accountId: "",
  };
  els.cnyFilterForm.reset();
  renderTransactions();
}

async function saveTransactionPatch(id, patch) {
  const transaction = findTransaction(id);
  if (!transaction) return;
  const result = await updateCnyTransaction({ ...transaction, ...patch });
  if (!result) return;
  await refreshAfterMutation(result.message || "人民币流水已更新。", "success");
}

function renderAccounts() {
  const accounts = appState.cnyPage?.accounts || [];
  els.cnyAccountRows.innerHTML = accounts.length
    ? accounts
        .map(
          (account) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountType(account.account_type)} · 期初 ${moneyCny(account.opening_balance || 0)}</span>
              </div>
              <div class="button-row">
                <button class="ghost-button compact-button" data-edit-cny-account="${account.id}" type="button">编辑</button>
                <button class="ghost-button compact-button" data-copy-cny-account="${account.id}" type="button">复制</button>
                <button class="danger-button compact-button" data-delete-cny-account="${account.id}" type="button">删除</button>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无人民币账户</div>`;

  document.querySelectorAll("[data-edit-cny-account]").forEach((button) => {
    button.addEventListener("click", () => {
      const account = findCnyAccount(button.dataset.editCnyAccount);
      if (!account) return;
      setAccountForm(account, "edit");
    });
  });
  document.querySelectorAll("[data-copy-cny-account]").forEach((button) => {
    button.addEventListener("click", () => {
      const account = findCnyAccount(button.dataset.copyCnyAccount);
      if (!account) return;
      setAccountForm({ ...account, name: `${account.name} 复制` }, "copy");
    });
  });
  document.querySelectorAll("[data-delete-cny-account]").forEach((button) => {
    button.addEventListener("click", async () => {
      const account = findCnyAccount(button.dataset.deleteCnyAccount);
      if (!account) return;
      const confirmed = window.confirm(`删除「${account.name}」？该账户关联的人民币流水也会被删除，余额会重新计算。`);
      if (!confirmed) return;
      const ok = await deleteAccount(account.id);
      if (!ok) return;
      await refreshAfterMutation("人民币账户已删除。", "success");
    });
  });
}

function setTransactionForm(transaction, mode) {
  const form = els.cnyTransactionForm;
  appState.editingCnyTransactionId = mode === "edit" ? transaction.id : null;
  form.elements.transacted_at.value = transaction.transacted_at || `${appState.activeMonth}-01`;
  form.elements.transaction_type.value = transaction.transaction_type || "expense";
  form.elements.account_id.value = transaction.account_id || "";
  form.elements.transfer_account_id.value = transaction.transfer_account_id || "";
  form.elements.amount.value = transaction.amount ?? "";
  form.elements.description.value = transaction.description || "";
  form.elements.note.value = transaction.note || "";
  form.elements.transaction_type.disabled = mode === "edit";
  els.cnyTransactionFormTitle.textContent = mode === "edit" ? "编辑人民币流水" : "复制人民币流水";
  els.cnyTransactionSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新流水";
  els.cnyTransactionCancelBtn.hidden = false;
  updateTransferAccountControl();
  form.elements.amount.focus();
}

function resetTransactionForm() {
  appState.editingCnyTransactionId = null;
  els.cnyTransactionForm.elements.transaction_type.disabled = false;
  els.cnyTransactionForm.reset();
  els.cnyTransactionFormTitle.textContent = "人民币流水登录";
  els.cnyTransactionSubmitBtn.textContent = "保存流水";
  els.cnyTransactionCancelBtn.hidden = true;
  setTransactionDate();
  updateTransferAccountControl();
}

function setFixedTemplateForm(template, mode) {
  const form = els.cnyFixedTemplateForm;
  appState.editingCnyTemplateId = mode === "edit" ? template.id : null;
  form.elements.name.value = template.name || "";
  form.elements.direction.value = template.direction || "expense";
  form.elements.default_amount.value = template.default_amount ?? "";
  form.elements.due_day.value = template.due_day || "";
  els.cnyFixedTemplateTitle.textContent = mode === "edit" ? "编辑人民币固定项" : "复制人民币固定项";
  els.cnyFixedTemplateSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新固定项";
  els.cnyFixedTemplateCancelBtn.hidden = false;
  form.elements.name.focus();
  setActionMessage(mode === "edit" ? "正在编辑人民币固定项。" : "已复制到人民币固定项表单。", "success");
}

function resetFixedTemplateForm() {
  appState.editingCnyTemplateId = null;
  els.cnyFixedTemplateForm.reset();
  els.cnyFixedTemplateTitle.textContent = "人民币固定收支设置";
  els.cnyFixedTemplateSubmitBtn.textContent = "保存固定项";
  els.cnyFixedTemplateCancelBtn.hidden = true;
}

function setAccountForm(account, mode) {
  const form = els.cnyAccountForm;
  appState.editingCnyAccountId = mode === "edit" ? account.id : null;
  form.elements.name.value = account.name || "";
  form.elements.account_type.value = account.account_type || "wallet";
  form.elements.opening_balance.value = account.opening_balance ?? "";
  els.cnyAccountSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新账户";
  els.cnyAccountCancelBtn.hidden = false;
  form.elements.name.focus();
  setActionMessage(mode === "edit" ? "正在编辑人民币账户。" : "已复制到人民币账户表单，保存后会成为新账户。", "success");
}

function resetAccountForm() {
  appState.editingCnyAccountId = null;
  els.cnyAccountForm.reset();
  els.cnyAccountSubmitBtn.textContent = "添加";
  els.cnyAccountCancelBtn.hidden = true;
}

function findTransaction(id) {
  if (!id) return null;
  return (appState.cnyPage?.transactions || []).find((item) => item.id === id) || null;
}

function findFixedItem(id) {
  if (!id) return null;
  const items = [...(appState.cnyFixedPage?.income_items || []), ...(appState.cnyFixedPage?.expense_items || [])];
  return items.find((item) => item.id === id) || null;
}

async function refreshAfterMutation(message, type) {
  await loadAppData();
  setActionMessage(message, type);
  const { render } = await import("#render");
  render();
}

function setTransactionDate() {
  if (els.cnyTransactionForm.elements.transacted_at.value) return;
  els.cnyTransactionForm.elements.transacted_at.value = `${appState.activeMonth}-01`;
}

function labelAccountType(type) {
  const labels = {
    cash: "现金",
    bank: "银行卡",
    wallet: "电子钱包",
    pass_through: "过账账户",
    investment: "投资账户",
  };
  return labels[type] || type;
}

function labelTransactionType(type) {
  const labels = {
    income: "收入",
    expense: "支出",
    transfer: "账户间转账",
    fx_in: "换汇入金",
    fx_out: "购汇转出",
  };
  return labels[type] || type;
}

function labelDirection(direction) {
  return direction === "income" ? "收入" : "支出";
}

function cnyGenerationMessage(result) {
  const insertedCount = Number(result.inserted_count || 0);
  const eligibleCount = Number(result.eligible_count || 0);
  if (insertedCount > 0) return `人民币固定项已生成 ${insertedCount} 条。`;
  if (eligibleCount === 0) return "当前没有可生成的人民币固定模板。";
  if (result.all_generated) return "人民币固定项已经生成完毕，无需重复生成。";
  return "没有新增人民币固定项，请刷新后重试。";
}
