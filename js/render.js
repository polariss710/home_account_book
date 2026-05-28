import { els } from "./elements.js?v=20260528-db-rpc-1";
import { appState, saveLocal } from "./state.js?v=20260528-db-rpc-1";
import { renderSyncStatus } from "./ui.js?v=20260528-db-rpc-1";
import { emptyRow, escapeHtml, money } from "./utils.js?v=20260528-db-rpc-1";
import { loadMonthPageData, persist, removeCloud } from "./supabase.js?v=20260528-db-rpc-1";

export function render() {
  saveLocal();
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
      const id = button.dataset.delete;
      appState.data.transactions = appState.data.transactions.filter((item) => item.id !== id);
      await removeCloud("transactions", id);
      await loadMonthPageData();
      render();
    });
  });

  els.transactionRows.querySelectorAll("[data-toggle-status]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.toggleStatus;
      const tx = appState.data.transactions.find((item) => item.id === id);
      if (!tx) return;
      tx.status = tx.status === "paid" ? "unpaid" : "paid";
      await persist("transactions", tx);
      await loadMonthPageData();
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
      const id = button.dataset.deleteAccount;
      appState.data.accounts = appState.data.accounts.filter((item) => item.id !== id);
      await removeCloud("accounts", id);
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
      const id = button.dataset.deleteCategory;
      appState.data.categories = appState.data.categories.filter((item) => item.id !== id);
      await removeCloud("categories", id);
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

function labelAccountKind(kind) {
  return {
    cash: "现金",
    wallet: "钱包",
    bank: "银行",
    credit: "信用卡",
  }[kind] || kind;
}
