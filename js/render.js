import { els } from "./elements.js?v=20260529-fixed-1";
import { appState } from "./state.js?v=20260529-fixed-1";
import { renderShell } from "./ui.js?v=20260529-fixed-1";
import { emptyRow, escapeHtml, money } from "./utils.js?v=20260529-fixed-1";
import { deleteMonthItem, loadFixedMonthPage, saveMonthItem, deactivateTemplate } from "./supabase.js?v=20260529-fixed-1";

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
              <button class="danger-button" data-disable-template="${item.id}" type="button">停用</button>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无固定模板</div>`;

  els.templateRows.querySelectorAll("[data-disable-template]").forEach((button) => {
    button.addEventListener("click", async () => {
      const ok = await deactivateTemplate(button.dataset.disableTemplate);
      if (!ok) return;
      await loadFixedMonthPage();
      render();
    });
  });
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
