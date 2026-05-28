import { els } from "./elements.js?v=20260529-form-1";
import { appState } from "./state.js?v=20260529-form-1";
import { renderSyncStatus, setActionMessage } from "./ui.js?v=20260529-form-1";
import { emptyRow, escapeHtml, money } from "./utils.js?v=20260529-form-1";
import { isCloudReady, loadCloudData, persist, removeCloud } from "./supabase.js?v=20260529-form-1";

export function render() {
  renderSyncStatus();
  renderSelectOptions();
  renderDashboard();
  renderTransactions();
  renderAccounts();
  renderCategories();
}

function renderSelectOptions() {
  const accountOptions = `<option value="">-</option>${appState.data.accounts
    .map((item) => `<option value="${item.id}">${escapeHtml(item.name)}</option>`)
    .join("")}`;
  const categoryOptions = `<option value="">-</option>${appState.data.categories
    .map((item) => `<option value="${item.id}">${escapeHtml(item.name)}</option>`)
    .join("")}`;

  els.transactionForm.elements.source_account_id.innerHTML = accountOptions;
  els.transactionForm.elements.target_account_id.innerHTML = accountOptions;
  els.transactionForm.elements.category_id.innerHTML = categoryOptions;
}

function renderDashboard() {
  const page = appState.data.monthPage;
  const metrics = page?.metrics || {};

  els.monthIncome.textContent = money(metrics.income || 0);
  els.monthExpense.textContent = money(metrics.expense || 0);
  els.monthUnpaid.textContent = money(metrics.unpaid || 0);
  els.monthBalance.textContent = money(metrics.balance || 0);

  els.accountBalances.innerHTML = page?.balances?.length
    ? page.balances
        .map(
          (account) => `
            <div class="balance-item">
              <div>
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountKind(account.kind)}</span>
              </div>
              <strong>${money(account.balance || 0)}</strong>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无账户</div>`;

  els.pendingRows.innerHTML = page?.pending?.length ? page.pending.map(pendingRow).join("") : emptyRow(5);
}

function renderTransactions() {
  const page = appState.data.monthPage;
  let txs = page?.transactions || [];
  if (appState.transactionFilter !== "all") {
    txs = txs.filter((item) => item.status === appState.transactionFilter);
  }
  els.transactionRows.innerHTML = txs.length ? txs.map(transactionRow).join("") : emptyRow(8);

  els.transactionRows.querySelectorAll("[data-delete]").forEach((button) => {
    button.addEventListener("click", async () => {
      if (!requireCloudReady("请先登录后再删除流水。")) return;
      const id = button.dataset.delete;
      const ok = await removeCloud("transactions", id);
      if (!ok) return;
      await loadCloudData();
      render();
    });
  });

  els.transactionRows.querySelectorAll("[data-toggle-status]").forEach((button) => {
    button.addEventListener("click", async () => {
      if (!requireCloudReady("请先登录后再修改状态。")) return;
      const id = button.dataset.toggleStatus;
      const tx = appState.data.transactions.find((item) => item.id === id);
      if (!tx) return;
      const updated = { ...tx, status: tx.status === "paid" ? "unpaid" : "paid" };
      const ok = await persist("transactions", updated);
      if (!ok) return;
      await loadCloudData();
      render();
    });
  });
}

function renderAccounts() {
  els.accountRows.innerHTML = appState.data.accounts.length
    ? appState.data.accounts
        .map(
          (item) => `
          <div class="settings-item">
            <div>
              <strong>${escapeHtml(item.name)}</strong>
              <span>${labelAccountKind(item.kind)} · 期初 ${money(item.opening_balance)}</span>
            </div>
            <button class="danger-button" type="button" data-delete-account="${item.id}">删除</button>
          </div>
        `,
        )
        .join("")
    : `<div class="empty-state">暂无账户</div>`;

  els.accountRows.querySelectorAll("[data-delete-account]").forEach((button) => {
    button.addEventListener("click", async () => {
      if (!requireCloudReady("请先登录后再删除账户。")) return;
      const id = button.dataset.deleteAccount;
      const ok = await removeCloud("accounts", id);
      if (!ok) return;
      await loadCloudData();
      render();
    });
  });
}

function renderCategories() {
  els.categoryRows.innerHTML = appState.data.categories.length
    ? appState.data.categories
        .map(
          (item) => `
          <div class="settings-item">
            <div>
              <strong>${escapeHtml(item.name)}</strong>
              <span>${labelType(item.kind)}</span>
            </div>
            <button class="danger-button" type="button" data-delete-category="${item.id}">删除</button>
          </div>
        `,
        )
        .join("")
    : `<div class="empty-state">暂无分类</div>`;

  els.categoryRows.querySelectorAll("[data-delete-category]").forEach((button) => {
    button.addEventListener("click", async () => {
      if (!requireCloudReady("请先登录后再删除分类。")) return;
      const id = button.dataset.deleteCategory;
      const ok = await removeCloud("categories", id);
      if (!ok) return;
      await loadCloudData();
      render();
    });
  });
}

function pendingRow(item) {
  return `
    <tr>
      <td>${item.date}</td>
      <td>${escapeHtml(item.description || "-")}</td>
      <td>${escapeHtml(item.category_name || "-")}</td>
      <td class="amount">${money(item.amount)}</td>
      <td>${statusBadge(item.status)}</td>
    </tr>
  `;
}

function transactionRow(item) {
  return `
    <tr>
      <td>${item.date}</td>
      <td>${labelType(item.type)}</td>
      <td>${escapeHtml(item.description || "-")}</td>
      <td>${escapeHtml(item.category_name || "-")}</td>
      <td>${escapeHtml(item.account_label || "-")}</td>
      <td class="amount">${money(item.amount)}</td>
      <td><button class="plain-button" type="button" data-toggle-status="${item.id}">${statusBadge(item.status)}</button></td>
      <td><button class="danger-button" type="button" data-delete="${item.id}">删除</button></td>
    </tr>
  `;
}

function statusBadge(status) {
  return `<span class="badge ${status}">${status === "paid" ? "已付" : "未付"}</span>`;
}

function labelType(type) {
  return {
    income: "收入",
    expense: "支出",
    transfer: "转账",
    adjustment: "调整",
  }[type] || type;
}

function requireCloudReady(message) {
  if (isCloudReady()) return true;
  setActionMessage(message, "error");
  return false;
}

function labelAccountKind(kind) {
  return {
    cash: "现金",
    wallet: "钱包",
    bank: "银行",
    credit: "信用卡",
  }[kind] || kind;
}
