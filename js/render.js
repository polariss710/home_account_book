import { els } from "./elements.js?v=20260529-fixed-4";
import { appState } from "./state.js?v=20260529-fixed-4";
import { renderShell, setActionMessage } from "./ui.js?v=20260529-fixed-4";
import { emptyRow, escapeHtml, money } from "./utils.js?v=20260529-fixed-4";
import { deleteMonthItem, loadFixedMonthPage, saveMonthItem, deactivateTemplate } from "./supabase.js?v=20260529-fixed-4";

export function render() {
  renderShell();
  renderDashboard();
  renderMonthItems();
  renderTemplates();
  renderAccounts();
}

function renderDashboard() {
  const metrics = appState.page?.metrics || {};
  els.fixedIncomeTotal.textContent = money(metrics.income || 0);
  els.fixedExpenseTotal.textContent = money(metrics.expense || 0);
  els.fixedBalanceTotal.textContent = money(metrics.balance || 0);
  els.fixedUnpaidTotal.textContent = money(metrics.unpaid_expense || 0);
  els.fixedBalanceTotal.classList.toggle("negative", Number(metrics.balance || 0) < 0);

  const groups = appState.page?.expense_groups || [];
  els.paymentGroupSummary.innerHTML = groups.length
    ? groups
        .map(
          (group) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(group.payment_group || "未分组")}</strong>
                <span>已付 ${money(group.paid || 0)} / 未付 ${money(group.unpaid || 0)}</span>
              </div>
              <strong>${money(group.total || 0)}</strong>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无支付渠道数据</div>`;
}

function renderMonthItems() {
  const incomeItems = appState.page?.income_items || [];
  const expenseItems = appState.page?.expense_items || [];
  els.incomeItemRows.innerHTML = incomeItems.length ? incomeItems.map(incomeItemRow).join("") : emptyRow(6);
  els.expenseItemRows.innerHTML = expenseItems.length ? expenseItems.map(expenseItemRow).join("") : emptyRow(8);
  bindMonthItemControls();
}

function incomeItemRow(item) {
  return `
    <tr>
      <td>${escapeHtml(item.name)}</td>
      <td><input class="table-input amount-input" data-item-amount="${item.id}" type="number" step="1" value="${Number(item.amount || 0)}" /></td>
      <td>${statusSelect(item)}</td>
      <td>${termLabel(item)}</td>
      <td><input class="table-input" data-item-note="${item.id}" value="${escapeHtml(item.note || "")}" /></td>
      <td><button class="danger-button compact-button" data-delete-item="${item.id}" type="button">删除</button></td>
    </tr>
  `;
}

function expenseItemRow(item) {
  return `
    <tr>
      <td>${escapeHtml(item.payment_group || "未分组")}</td>
      <td>${escapeHtml(item.name)}</td>
      <td><input class="table-input amount-input" data-item-amount="${item.id}" type="number" step="1" value="${Number(item.amount || 0)}" /></td>
      <td>${escapeHtml(item.due_date || "-")}</td>
      <td>${statusSelect(item)}</td>
      <td>${termLabel(item)}</td>
      <td><input class="table-input" data-item-note="${item.id}" value="${escapeHtml(item.note || "")}" /></td>
      <td><button class="danger-button compact-button" data-delete-item="${item.id}" type="button">删除</button></td>
    </tr>
  `;
}

function statusSelect(item) {
  return `
    <select class="table-input" data-item-status="${item.id}">
      <option value="unpaid"${item.status === "unpaid" ? " selected" : ""}>未付</option>
      <option value="paid"${item.status === "paid" ? " selected" : ""}>已付</option>
      <option value="settled"${item.status === "settled" ? " selected" : ""}>已结清</option>
    </select>
  `;
}

function termLabel(item) {
  if (!item.term_no || !item.total_terms) return "-";
  return `${item.term_no}/${item.total_terms}`;
}

function bindMonthItemControls() {
  document.querySelectorAll("[data-item-amount]").forEach((input) => {
    input.addEventListener("change", () => saveItemPatch(input.dataset.itemAmount, { amount: Number(input.value || 0) }));
  });
  document.querySelectorAll("[data-item-status]").forEach((select) => {
    select.addEventListener("change", () => saveItemPatch(select.dataset.itemStatus, { status: select.value }));
  });
  document.querySelectorAll("[data-item-note]").forEach((input) => {
    input.addEventListener("change", () => saveItemPatch(input.dataset.itemNote, { note: input.value.trim() }));
  });
  document.querySelectorAll("[data-delete-item]").forEach((button) => {
    button.addEventListener("click", async () => {
      const ok = await deleteMonthItem(button.dataset.deleteItem);
      if (!ok) return;
      await loadFixedMonthPage();
      render();
    });
  });
}

async function saveItemPatch(id, patch) {
  const item = findMonthItem(id);
  if (!item) return;
  const ok = await saveMonthItem({ ...item, ...patch });
  if (!ok) return;
  await loadFixedMonthPage();
  render();
}

function findMonthItem(id) {
  const items = [...(appState.page?.income_items || []), ...(appState.page?.expense_items || [])];
  return items.find((item) => item.id === id);
}

function renderTemplates() {
  const templates = appState.page?.templates || [];
  els.templateRows.innerHTML = templates.length
    ? templates
        .map(
          (item) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(item.name)}</strong>
                <span>${labelDirection(item.direction)} · ${labelFixedType(item.fixed_type)} · ${escapeHtml(item.payment_group || "未分组")} · ${money(item.default_amount || 0)}</span>
              </div>
              <div class="button-row">
                <button class="ghost-button compact-button" data-edit-template="${item.id}" type="button">编辑</button>
                <button class="ghost-button compact-button" data-copy-template="${item.id}" type="button">复制</button>
                <button class="danger-button compact-button" data-disable-template="${item.id}" type="button">停止生成</button>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无固定模板</div>`;

  els.templateRows.querySelectorAll("[data-edit-template]").forEach((button) => {
    button.addEventListener("click", () => {
      const template = findTemplate(button.dataset.editTemplate);
      if (!template) return;
      setTemplateForm(template, "edit");
    });
  });

  els.templateRows.querySelectorAll("[data-copy-template]").forEach((button) => {
    button.addEventListener("click", () => {
      const template = findTemplate(button.dataset.copyTemplate);
      if (!template) return;
      setTemplateForm({ ...template, name: `${template.name} 复制` }, "copy");
    });
  });

  els.templateRows.querySelectorAll("[data-disable-template]").forEach((button) => {
    button.addEventListener("click", async () => {
      const template = findTemplate(button.dataset.disableTemplate);
      if (!template) return;
      const confirmed = window.confirm(`停止生成「${template.name}」？历史月份记录会保留，之后月份不再自动生成。`);
      if (!confirmed) return;
      const ok = await deactivateTemplate(button.dataset.disableTemplate);
      if (!ok) return;
      await loadFixedMonthPage();
      setActionMessage("模板已停止生成，历史记录已保留。", "success");
      render();
    });
  });
}

function setTemplateForm(template, mode) {
  const form = els.templateForm;
  appState.editingTemplateId = mode === "edit" ? template.id : null;
  form.elements.name.value = template.name || "";
  form.elements.direction.value = template.direction || "expense";
  form.elements.fixed_type.value = template.fixed_type || "long_term";
  form.elements.default_amount.value = Number(template.default_amount || 0);
  form.elements.payment_group.value = template.payment_group || "";
  form.elements.due_day.value = template.due_day || "";
  form.elements.start_month.value = template.start_month || "";
  form.elements.total_terms.value = template.total_terms || "";
  els.templateFormTitle.textContent = mode === "edit" ? "编辑固定模板" : "复制固定模板";
  els.templateSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新模板";
  els.templateCancelBtn.hidden = false;
  form.elements.name.focus();
  setActionMessage(mode === "edit" ? "正在编辑固定模板。" : "已复制到表单，保存后会成为新模板。", "success");
}

function findTemplate(id) {
  return (appState.page?.templates || []).find((item) => item.id === id) || null;
}

function renderAccounts() {
  const accounts = appState.page?.accounts || [];
  els.accountRows.innerHTML = accounts.length
    ? accounts
        .map(
          (item) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(item.name)}</strong>
                <span>${labelAccountType(item.account_type)} · 期初 ${money(item.opening_balance || 0)}</span>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无日元账户</div>`;
}

function labelDirection(direction) {
  return direction === "income" ? "收入" : "支出";
}

function labelFixedType(type) {
  return type === "short_term" ? "短期固定" : "长期固定";
}

function labelAccountType(type) {
  return type === "bank" ? "银行卡" : "现金";
}
