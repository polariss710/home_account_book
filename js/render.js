import { els } from "./elements.js";
import { appState, monthTransactions, saveLocal } from "./state.js";
import { renderSyncStatus } from "./ui.js";
import {
  emptyRow,
  endOfMonth,
  escapeHtml,
  money,
  nameById,
  sortByDate,
  sortByDateDesc,
  sum,
  toNumber,
} from "./utils.js";
import { persist, removeCloud } from "./supabase.js";

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
  const txs = monthTransactions(appState.activeMonth);
  const paid = txs.filter((item) => item.status === "paid");
  const income = sum(paid.filter((item) => item.type === "income").map((item) => item.amount));
  const expense = sum(paid.filter((item) => item.type === "expense").map((item) => item.amount));
  const unpaid = sum(txs.filter((item) => item.status === "unpaid").map((item) => item.amount));
  const balances = calculateBalances(endOfMonth(appState.activeMonth));
  const totalBalance = sum(Object.values(balances));

  els.monthIncome.textContent = money(income);
  els.monthExpense.textContent = money(expense);
  els.monthUnpaid.textContent = money(unpaid);
  els.monthBalance.textContent = money(totalBalance);

  els.accountBalances.innerHTML = appState.data.accounts.length
    ? appState.data.accounts
        .map(
          (account) => `
            <div class="balance-item">
              <div>
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountKind(account.kind)}</span>
              </div>
              <strong>${money(balances[account.id] || 0)}</strong>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无账户</div>`;

  const pending = txs.filter((item) => item.status === "unpaid").sort(sortByDate);
  els.pendingRows.innerHTML = pending.length ? pending.map(pendingRow).join("") : emptyRow(5);
}

function renderTransactions() {
  let txs = monthTransactions(appState.activeMonth).sort(sortByDateDesc);
  if (appState.transactionFilter !== "all") {
    txs = txs.filter((item) => item.status === appState.transactionFilter);
  }
  els.transactionRows.innerHTML = txs.length ? txs.map(transactionRow).join("") : emptyRow(8);

  els.transactionRows.querySelectorAll("[data-delete]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.delete;
      appState.data.transactions = appState.data.transactions.filter((item) => item.id !== id);
      await removeCloud("transactions", id);
      render();
    });
  });

  els.transactionRows.querySelectorAll("[data-toggle-status]").forEach((button) => {
    button.addEventListener("click", async () => {
      const id = button.dataset.toggleStatus;
      const tx = appState.data.transactions.find((item) => item.id === id);
      tx.status = tx.status === "paid" ? "unpaid" : "paid";
      await persist("transactions", tx);
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
      <td>${escapeHtml(nameById(appState.data.categories, item.category_id))}</td>
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
      <td>${escapeHtml(nameById(appState.data.categories, item.category_id))}</td>
      <td>${escapeHtml(accountPair(item))}</td>
      <td class="amount">${money(item.amount)}</td>
      <td><button class="plain-button" type="button" data-toggle-status="${item.id}">${statusBadge(item.status)}</button></td>
      <td><button class="danger-button" type="button" data-delete="${item.id}">删除</button></td>
    </tr>
  `;
}

function statusBadge(status) {
  return `<span class="badge ${status}">${status === "paid" ? "已付" : "未付"}</span>`;
}

function calculateBalances(endDate) {
  const balances = Object.fromEntries(appState.data.accounts.map((account) => [account.id, toNumber(account.opening_balance)]));
  appState.data.transactions
    .filter((tx) => tx.status === "paid" && tx.date <= endDate)
    .forEach((tx) => {
      const amount = toNumber(tx.amount);
      if (tx.type === "income" && tx.target_account_id) balances[tx.target_account_id] += amount;
      if (tx.type === "expense" && tx.source_account_id) balances[tx.source_account_id] -= amount;
      if (tx.type === "transfer") {
        if (tx.source_account_id) balances[tx.source_account_id] -= amount;
        if (tx.target_account_id) balances[tx.target_account_id] += amount;
      }
      if (tx.type === "adjustment" && tx.target_account_id) balances[tx.target_account_id] += amount;
    });
  return balances;
}

function accountPair(tx) {
  if (tx.type === "income") return nameById(appState.data.accounts, tx.target_account_id);
  if (tx.type === "expense") return nameById(appState.data.accounts, tx.source_account_id);
  if (tx.type === "transfer") {
    return `${nameById(appState.data.accounts, tx.source_account_id)} -> ${nameById(appState.data.accounts, tx.target_account_id)}`;
  }
  return nameById(appState.data.accounts, tx.target_account_id);
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
