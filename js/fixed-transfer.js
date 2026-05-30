import { els } from "#elements";
import { appState } from "#state";
import { createFixedTransfer, isCloudReady, loadAppData } from "#supabase";
import { setActionMessage } from "#ui";
import { escapeHtml, formData, money } from "#utils";

export function bindFixedTransferEvents(afterSave) {
  els.fixedTransferForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!isCloudReady()) {
      setActionMessage("请先登录后再保存固定资金调拨。", "error");
      return;
    }

    const form = event.currentTarget;
    const data = formData(form);
    const status = appState.page?.fixed_settlement_status;
    const transactionType = status?.transaction_type;
    if (!data.account_id) {
      setActionMessage("请先选择日元账户。", "error");
      return;
    }
    if (!transactionType) {
      setActionMessage("当前固定收支已平衡，不需要调拨。", "error");
      return;
    }

    const result = await createFixedTransfer({
      transaction_type: transactionType,
      account_id: data.account_id,
      transacted_at: data.transacted_at,
      note: data.note.trim(),
    });
    if (!result) return;

    await loadAppData();
    resetFixedTransferForm();
    setActionMessage(result.message || "固定资金调拨已保存，日元账户余额已更新。", "success");
    afterSave();
  });
}

export function renderFixedTransferForm() {
  renderFixedTransferAccountOptions();
  renderFixedTransferStatus();
  setFixedTransferDate();
}

function renderFixedTransferStatus() {
  const status = appState.page?.fixed_settlement_status;
  if (!status) {
    els.fixedTransferForm.elements.transaction_type.disabled = true;
    els.fixedTransferStatus.className = "settlement-status";
    els.fixedTransferStatus.textContent = "请执行最新 SQL 后使用固定调拨";
    els.fixedTransferSubmitBtn.disabled = true;
    return;
  }

  const state = status.state || "balanced";
  const amount = Number(status.transfer_amount || 0);
  const typeSelect = els.fixedTransferForm.elements.transaction_type;

  typeSelect.disabled = true;
  if (state === "deficit") typeSelect.value = "fixed_out";
  if (state === "surplus") typeSelect.value = "fixed_in";

  els.fixedTransferStatus.className = `settlement-status ${state}`;
  els.fixedTransferStatus.innerHTML = `
    <span>${labelSettlementState(state)}</span>
    <strong>${money(amount)}</strong>
  `;
  els.fixedTransferSubmitBtn.textContent = labelSubmitButton(state);
  els.fixedTransferSubmitBtn.disabled = state === "balanced" || amount <= 0;
}

function renderFixedTransferAccountOptions() {
  const accounts = appState.jpyPage?.accounts || [];
  const currentValue = els.fixedTransferAccountSelect.value;
  els.fixedTransferAccountSelect.innerHTML = accounts.length
    ? accounts.map((account) => `<option value="${account.id}">${escapeHtml(account.name)}</option>`).join("")
    : `<option value="">请先新增日元账户</option>`;
  if (accounts.some((account) => account.id === currentValue)) {
    els.fixedTransferAccountSelect.value = currentValue;
  }
}

function resetFixedTransferForm() {
  els.fixedTransferForm.reset();
  setFixedTransferDate();
  renderFixedTransferAccountOptions();
  renderFixedTransferStatus();
}

function setFixedTransferDate() {
  if (els.fixedTransferForm.elements.transacted_at.value) return;
  els.fixedTransferForm.elements.transacted_at.value = `${appState.activeMonth}-01`;
}

function labelSettlementState(state) {
  const labels = {
    deficit: "结算赤字",
    surplus: "结算盈余",
    balanced: "结算已平衡",
  };
  return labels[state] || "固定收支状态";
}

function labelSubmitButton(state) {
  const labels = {
    deficit: "补充赤字",
    surplus: "转入盈余",
    balanced: "当前已平衡",
  };
  return labels[state] || "保存调拨";
}
