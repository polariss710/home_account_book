import { els } from "./elements.js?v=20260530-jpy-2";
import { appState } from "./state.js?v=20260530-jpy-2";
import { loadAppData, deleteJpyTransaction, isCloudReady, saveJpyTransaction } from "./supabase.js?v=20260530-jpy-2";
import { setActionMessage } from "./ui.js?v=20260530-jpy-2";
import { emptyRow, escapeHtml, formData, money, toNumber } from "./utils.js?v=20260530-jpy-2";

export function bindJpyEvents() {
  els.jpyTransactionForm.elements.transaction_type.addEventListener("change", updateTransferAccountControl);
  els.jpyTransactionForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!isCloudReady()) {
      setActionMessage("请先登录后再保存日元流水。", "error");
      return;
    }
    const form = event.currentTarget;
    const data = formData(form);
    const transactionType = data.transaction_type;
    const transferAccountId = transactionType === "transfer" ? data.transfer_account_id : null;
    if (transactionType === "transfer" && (!transferAccountId || transferAccountId === data.account_id)) {
      setActionMessage("账户间转账需要选择不同的转入账户。", "error");
      return;
    }
    const record = {
      id: crypto.randomUUID(),
      transaction_type: transactionType,
      account_id: data.account_id,
      transfer_account_id: transferAccountId,
      transacted_at: data.transacted_at,
      amount: toNumber(data.amount),
      description: data.description.trim(),
      note: data.note.trim(),
      created_at: new Date().toISOString(),
    };
    const ok = await saveJpyTransaction(record);
    if (!ok) return;
    await loadAppData();
    form.reset();
    setJpyTransactionDate();
    setActionMessage("日元流水已保存。", "success");
    renderJpyPage();
  });
}

export function renderJpyPage() {
  renderJpyBalances();
  renderJpyAccountOptions();
  renderJpyTransactions();
  setJpyTransactionDate();
  updateTransferAccountControl();
}

function renderJpyBalances() {
  const accounts = appState.jpyPage?.accounts || [];
  els.jpyBalanceRows.innerHTML = accounts.length
    ? accounts
        .map(
          (account) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountType(account.account_type)} · 期初 ${money(account.opening_balance || 0)}</span>
              </div>
              <strong>${money(account.current_balance || 0)}</strong>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无日元账户</div>`;
}

function renderJpyAccountOptions() {
  const accounts = appState.jpyPage?.accounts || [];
  const options = accounts.map((account) => `<option value="${account.id}">${escapeHtml(account.name)}</option>`).join("");
  els.jpyAccountSelect.innerHTML = options || `<option value="">请先新增账户</option>`;
  els.jpyTransferAccountSelect.innerHTML = `<option value="">不使用</option>${options}`;
  updateTransferAccountControl();
}

function updateTransferAccountControl() {
  const isTransfer = els.jpyTransactionForm.elements.transaction_type.value === "transfer";
  els.jpyTransferAccountSelect.disabled = !isTransfer;
  els.jpyTransferAccountSelect.required = isTransfer;
  if (!isTransfer) els.jpyTransferAccountSelect.value = "";
}

function renderJpyTransactions() {
  const transactions = appState.jpyPage?.transactions || [];
  els.jpyTransactionRows.innerHTML = transactions.length ? transactions.map(transactionRow).join("") : emptyRow(8);
  bindTransactionControls();
}

function transactionRow(item) {
  return `
    <tr>
      <td>${escapeHtml(item.transacted_at)}</td>
      <td>${labelTransactionType(item.transaction_type)}</td>
      <td>${escapeHtml(item.account_name || "-")}</td>
      <td>${escapeHtml(item.transfer_account_name || "-")}</td>
      <td><input class="table-input amount-input" data-jpy-amount="${item.id}" type="number" step="1" value="${Number(item.amount || 0)}" /></td>
      <td><input class="table-input" data-jpy-description="${item.id}" value="${escapeHtml(item.description || "")}" /></td>
      <td><input class="table-input" data-jpy-note="${item.id}" value="${escapeHtml(item.note || "")}" /></td>
      <td><button class="danger-button compact-button" data-delete-jpy="${item.id}" type="button">删除</button></td>
    </tr>
  `;
}

function bindTransactionControls() {
  document.querySelectorAll("[data-jpy-amount]").forEach((input) => {
    input.addEventListener("change", () => saveTransactionPatch(input.dataset.jpyAmount, { amount: Number(input.value || 0) }));
  });
  document.querySelectorAll("[data-jpy-description]").forEach((input) => {
    input.addEventListener("change", () => saveTransactionPatch(input.dataset.jpyDescription, { description: input.value.trim() }));
  });
  document.querySelectorAll("[data-jpy-note]").forEach((input) => {
    input.addEventListener("change", () => saveTransactionPatch(input.dataset.jpyNote, { note: input.value.trim() }));
  });
  document.querySelectorAll("[data-delete-jpy]").forEach((button) => {
    button.addEventListener("click", async () => {
      const ok = await deleteJpyTransaction(button.dataset.deleteJpy);
      if (!ok) return;
      await loadAppData();
      renderJpyPage();
    });
  });
}

async function saveTransactionPatch(id, patch) {
  const transaction = (appState.jpyPage?.transactions || []).find((item) => item.id === id);
  if (!transaction) return;
  const ok = await saveJpyTransaction({ ...transaction, ...patch });
  if (!ok) return;
  await loadAppData();
  renderJpyPage();
}

function setJpyTransactionDate() {
  if (els.jpyTransactionForm.elements.transacted_at.value) return;
  els.jpyTransactionForm.elements.transacted_at.value = `${appState.activeMonth}-01`;
}

function labelAccountType(type) {
  return type === "bank" ? "银行卡" : "现金";
}

function labelTransactionType(type) {
  const labels = {
    income: "零散收入",
    expense: "零散支出",
    transfer: "账户间转账",
    fx_in: "购汇入金",
    fx_out: "换汇转出",
    fixed_in: "固定盈余转入",
    fixed_out: "固定赤字补充",
  };
  return labels[type] || type;
}
