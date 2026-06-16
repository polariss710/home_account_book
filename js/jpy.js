import { els } from "#elements";
import { appState } from "#state";
import {
  createJpyToCnyFx,
  deleteJpyToCnyFx,
  loadAppData,
  deleteJpyTransaction,
  isCloudReady,
  saveJpyTransaction,
  updateJpyToCnyFx,
  updateJpyTransaction,
} from "#supabase";
import { setActionMessage } from "#ui";
import { emptyRow, escapeHtml, formData, money, toNumber } from "#utils";

export function bindJpyEvents() {
  els.jpyTransactionForm.elements.transaction_type.addEventListener("change", updateTransferAccountControl);
  els.jpyTransactionCancelBtn.addEventListener("click", resetJpyTransactionForm);
  els.jpyTransactionForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!isCloudReady()) {
      setActionMessage("请先登录后再保存日元流水。", "error");
      return;
    }
    const form = event.currentTarget;
    const data = formData(form);
    const existingTransaction = findJpyTransaction(appState.editingJpyTransactionId);
    const transactionType = existingTransaction?.transaction_type || data.transaction_type;
    const transferAccountId = transactionType === "transfer" ? data.transfer_account_id : null;
    const isFixedTransfer = transactionType === "fixed_in" || transactionType === "fixed_out";
    if (!appState.editingJpyTransactionId && isFixedTransfer) {
      setActionMessage("固定调拨请在日元固定收支页面生成。", "error");
      return;
    }
    if (transactionType === "transfer" && (!transferAccountId || transferAccountId === data.account_id)) {
      setActionMessage("账户间转账需要选择不同的转入账户。", "error");
      return;
    }
    if (transactionType === "fx_out" && (!data.cny_account_id || toNumber(data.cny_amount) <= 0)) {
      setActionMessage("换汇转出需要选择人民币入账账户，并填写实际到账人民币金额。", "error");
      return;
    }
    const record = {
      id: appState.editingJpyTransactionId || crypto.randomUUID(),
      transaction_type: transactionType,
      account_id: data.account_id,
      transfer_account_id: transferAccountId,
      cny_account_id: transactionType === "fx_out" ? data.cny_account_id : null,
      transacted_at: data.transacted_at,
      amount: toNumber(data.amount),
      cny_amount: transactionType === "fx_out" ? toNumber(data.cny_amount) : null,
      description: data.description.trim(),
      note: data.note.trim(),
      created_at: existingTransaction?.created_at || new Date().toISOString(),
    };
    const result =
      transactionType === "fx_out"
        ? appState.editingJpyTransactionId
          ? await updateJpyToCnyFx(record)
          : await createJpyToCnyFx(record)
        : appState.editingJpyTransactionId
          ? await updateJpyTransaction(record)
          : await saveJpyTransaction(record);
    if (!result) return;
    resetJpyTransactionForm();
    await refreshAfterJpyMutation(result.message || "日元流水已保存。", result.reset_expense_status ? "error" : "success");
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
            <div class="balance-card">
              <div class="balance-card-main">
                <strong>${escapeHtml(account.name)}</strong>
                <span>${labelAccountType(account.account_type)} · 期初 ${money(account.opening_balance || 0)}</span>
              </div>
              <div class="balance-current">
                <span>当前余额</span>
                <strong>${money(account.current_balance || 0)}</strong>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无日元账户</div>`;
}

function renderJpyAccountOptions() {
  const accounts = appState.jpyPage?.accounts || [];
  const cnyAccounts = appState.cnyPage?.accounts || [];
  const options = accounts.map((account) => `<option value="${account.id}">${escapeHtml(account.name)}</option>`).join("");
  const cnyOptions = cnyAccounts.map((account) => `<option value="${account.id}">${escapeHtml(account.name)}</option>`).join("");
  els.jpyAccountSelect.innerHTML = options || `<option value="">请先新增账户</option>`;
  els.jpyTransferAccountSelect.innerHTML = `<option value="">不使用</option>${options}`;
  els.jpyFxCnyAccountSelect.innerHTML = cnyOptions || `<option value="">请先新增人民币账户</option>`;
  updateTransferAccountControl();
}

function updateTransferAccountControl() {
  const transactionType = els.jpyTransactionForm.elements.transaction_type.value;
  const isTransfer = transactionType === "transfer";
  const isFxOut = transactionType === "fx_out";
  els.jpyTransferAccountSelect.disabled = !isTransfer;
  els.jpyTransferAccountSelect.required = isTransfer;
  if (!isTransfer) els.jpyTransferAccountSelect.value = "";
  els.jpyTransferAccountSelect.parentElement.hidden = isFxOut;
  els.jpyFxCnyAccountSelect.disabled = !isFxOut;
  els.jpyFxCnyAccountSelect.required = isFxOut;
  els.jpyFxCnyAccountSelect.parentElement.hidden = !isFxOut;
  els.jpyFxCnyAmountInput.disabled = !isFxOut;
  els.jpyFxCnyAmountInput.required = isFxOut;
  els.jpyFxCnyAmountInput.parentElement.hidden = !isFxOut;
  if (!isFxOut) {
    els.jpyFxCnyAccountSelect.value = "";
    els.jpyFxCnyAmountInput.value = "";
  }
}

function renderJpyTransactions() {
  const transactions = appState.jpyPage?.transactions || [];
  els.jpyTransactionRows.innerHTML = transactions.length ? transactions.map(transactionRow).join("") : emptyRow(8);
  bindTransactionControls();
}

function transactionRow(item) {
  const fixedTransfer = isFixedTransfer(item);
  const fxLinked = Boolean(item.linked_cny_transaction_id);
  const schoolSynced = Boolean(item.created_by_external);
  const sourceFx = fxLinked && item.transaction_type === "fx_out";
  const generatedFx = fxLinked && item.transaction_type === "fx_in";
  const locked = fixedTransfer || generatedFx || sourceFx;
  const targetAccountName = sourceFx || generatedFx ? item.linked_cny_account_name : item.transfer_account_name;
  const amountCell = locked
    ? money(item.amount || 0)
    : `<input class="table-input amount-input" data-jpy-amount="${item.id}" type="number" step="1" value="${Number(item.amount || 0)}" />`;
  const descriptionCell = locked
    ? escapeHtml(item.description || "")
    : `<input class="table-input" data-jpy-description="${item.id}" value="${escapeHtml(item.description || "")}" />`;
  const noteCell = locked
    ? escapeHtml(item.note || "")
    : `<input class="table-input" data-jpy-note="${item.id}" value="${escapeHtml(item.note || "")}" />`;
  const controls = generatedFx
    ? `<span class="badge settled">购汇生成</span>`
    : `
      <div class="button-row">
        ${
          fixedTransfer
            ? ""
            : sourceFx
              ? `<button class="ghost-button compact-button" data-edit-jpy="${item.id}" type="button">编辑</button>`
            : `
              <button class="ghost-button compact-button" data-edit-jpy="${item.id}" type="button">编辑</button>
              <button class="ghost-button compact-button" data-copy-jpy="${item.id}" type="button">复制</button>
            `
        }
        <button class="danger-button compact-button" data-delete-jpy="${item.id}" type="button">删除</button>
      </div>
    `;
  const sourceBadge = schoolSynced ? `<span class="badge settled" title="School 收支确认请求同步生成">School同步生成</span>` : "";
  return `
    <tr>
      <td>${escapeHtml(item.transacted_at)}</td>
      <td>${labelTransactionType(item.transaction_type)}</td>
      <td>${escapeHtml(item.account_name || "-")}</td>
      <td>${escapeHtml(targetAccountName || "-")}</td>
      <td>${amountCell}</td>
      <td>${descriptionCell}</td>
      <td>${noteCell}</td>
      <td>${sourceBadge}${controls}</td>
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
      const transaction = findJpyTransaction(button.dataset.deleteJpy);
      if (!confirmDeleteJpyTransaction(transaction)) return;
      const result = transaction?.transaction_type === "fx_out"
        ? await deleteJpyToCnyFx(button.dataset.deleteJpy)
        : await deleteJpyTransaction(button.dataset.deleteJpy);
      if (!result) return;
      await refreshAfterJpyMutation(result.message || "日元流水已删除。", result.reset_expense_status ? "error" : "success");
    });
  });
  document.querySelectorAll("[data-edit-jpy]").forEach((button) => {
    button.addEventListener("click", () => {
      const transaction = findJpyTransaction(button.dataset.editJpy);
      if (!transaction) return;
      setJpyTransactionForm(transaction, "edit");
    });
  });
  document.querySelectorAll("[data-copy-jpy]").forEach((button) => {
    button.addEventListener("click", () => {
      const transaction = findJpyTransaction(button.dataset.copyJpy);
      if (!transaction) return;
      setJpyTransactionForm({ ...transaction, description: `${transaction.description} 复制` }, "copy");
    });
  });
}

async function saveTransactionPatch(id, patch) {
  const transaction = (appState.jpyPage?.transactions || []).find((item) => item.id === id);
  if (!transaction) return;
  const result = await updateJpyTransaction({ ...transaction, ...patch });
  if (!result) return;
  await refreshAfterJpyMutation(result.message || "日元流水已更新。", result.reset_expense_status ? "error" : "success");
}

function setJpyTransactionForm(transaction, mode) {
  const form = els.jpyTransactionForm;
  appState.editingJpyTransactionId = mode === "edit" ? transaction.id : null;
  form.elements.transacted_at.value = transaction.transacted_at || `${appState.activeMonth}-01`;
  form.elements.transaction_type.value = transaction.transaction_type || "expense";
  form.elements.account_id.value = transaction.account_id || "";
  form.elements.transfer_account_id.value = transaction.transfer_account_id || "";
  form.elements.cny_account_id.value = transaction.linked_cny_account_id || "";
  form.elements.amount.value = transaction.amount ?? "";
  form.elements.cny_amount.value = transaction.linked_cny_amount ?? "";
  form.elements.description.value = transaction.description || "";
  form.elements.note.value = transaction.note || "";
  form.elements.transaction_type.disabled = mode === "edit";
  els.jpyTransactionFormTitle.textContent = mode === "edit" ? "编辑日元零散流水" : "复制日元零散流水";
  els.jpyTransactionSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新流水";
  els.jpyTransactionCancelBtn.hidden = false;
  updateTransferAccountControl();
  form.elements.amount.focus();
}

function resetJpyTransactionForm() {
  appState.editingJpyTransactionId = null;
  els.jpyTransactionForm.elements.transaction_type.disabled = false;
  els.jpyTransactionForm.reset();
  els.jpyTransactionFormTitle.textContent = "日元零散流水登录";
  els.jpyTransactionSubmitBtn.textContent = "保存流水";
  els.jpyTransactionCancelBtn.hidden = true;
  setJpyTransactionDate();
  updateTransferAccountControl();
}

function findJpyTransaction(id) {
  if (!id) return null;
  return (appState.jpyPage?.transactions || []).find((item) => item.id === id) || null;
}

function isFixedTransfer(transaction) {
  const type = typeof transaction === "string" ? transaction : transaction?.transaction_type;
  return type === "fixed_in" || type === "fixed_out";
}

function confirmDeleteJpyTransaction(transaction) {
  if (!transaction) {
    return window.confirm("确定删除这条日元支出记录吗？此操作无法撤销。");
  }

  const linkedMessages = [];
  if (isFixedTransfer(transaction)) {
    linkedMessages.push("这笔固定调拨会同步删除固定收支中的对应记录，并可能让已付固定支出恢复为未付。");
  }
  if (transaction.transaction_type === "fx_out") {
    linkedMessages.push("这笔换汇转出会同步删除关联的人民币入金流水。");
  }

  const linkedText = linkedMessages.length ? `\n\n${linkedMessages.join("\n")}` : "";
  const deletePrompt = transaction.transaction_type === "expense"
    ? "确定删除这条日元支出记录吗？此操作无法撤销。"
    : "确认删除这笔日元流水？";
  const confirmed = window.confirm(`${deletePrompt}\n\n${deleteTransactionSummary(transaction, "JPY")}${linkedText}`);
  if (!confirmed) {
    return false;
  }

  if (!isSchoolSyncedTransaction(transaction)) {
    return true;
  }

  return window.confirm("这条流水由 School 收入/支出记录同步生成。删除后可能导致 School 与 Cash 状态不一致。请再次确认：我理解这可能造成 School/Cash 状态不一致，仍要删除。");
}

async function refreshAfterJpyMutation(message, type) {
  await loadAppData();
  setActionMessage(message, type);
  const { render } = await import("#render");
  render();
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

function deleteTransactionSummary(transaction, currency) {
  return [
    "准备删除这笔 Cash 流水：",
    `日期：${transaction.transacted_at || "-"}`,
    `金额：${formatDeleteAmount(transaction.amount, currency)}`,
    `币种：${currency}`,
    `账户：${deleteTransactionAccountLabel(transaction)}`,
    `类型：${labelTransactionType(transaction.transaction_type)}`,
    `备注：${deleteTransactionMemo(transaction)}`,
  ].join("\n");
}

function deleteTransactionAccountLabel(transaction) {
  const fromAccount = transaction.account_name || "-";
  const targetAccount = transaction.linked_cny_account_name || transaction.transfer_account_name || "";
  return targetAccount ? `${fromAccount} -> ${targetAccount}` : fromAccount;
}

function deleteTransactionMemo(transaction) {
  return [transaction.description, transaction.note].filter(Boolean).join(" / ") || "-";
}

function formatDeleteAmount(amount, currency) {
  return currency === "CNY" ? `${amount} CNY` : `${money(amount)} JPY`;
}

function isSchoolSyncedTransaction(transaction) {
  return Boolean(
    transaction?.created_by_external ||
    transaction?.external_source_id ||
    transaction?.external_reference_type ||
    transaction?.external_reference_id
  );
}
