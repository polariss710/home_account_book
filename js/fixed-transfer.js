import { els } from "#elements";
import { appState } from "#state";
import { isCloudReady, loadAppData, saveJpyTransaction } from "#supabase";
import { setActionMessage } from "#ui";
import { escapeHtml, formData, toNumber } from "#utils";

export function bindFixedTransferEvents(afterSave) {
  els.fixedTransferForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (!isCloudReady()) {
      setActionMessage("请先登录后再保存固定资金调拨。", "error");
      return;
    }

    const form = event.currentTarget;
    const data = formData(form);
    if (!data.account_id) {
      setActionMessage("请先选择日元账户。", "error");
      return;
    }

    const record = {
      id: crypto.randomUUID(),
      transaction_type: data.transaction_type,
      account_id: data.account_id,
      transfer_account_id: null,
      transacted_at: data.transacted_at,
      amount: toNumber(data.amount),
      description: fixedTransferDescription(data.transaction_type),
      note: data.note.trim(),
      created_at: new Date().toISOString(),
    };
    const ok = await saveJpyTransaction(record);
    if (!ok) return;

    await loadAppData();
    resetFixedTransferForm();
    setActionMessage("固定资金调拨已保存，日元账户余额已更新。", "success");
    afterSave();
  });
}

export function renderFixedTransferForm() {
  renderFixedTransferAccountOptions();
  setFixedTransferDate();
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
}

function setFixedTransferDate() {
  if (els.fixedTransferForm.elements.transacted_at.value) return;
  els.fixedTransferForm.elements.transacted_at.value = `${appState.activeMonth}-01`;
}

function fixedTransferDescription(type) {
  return type === "fixed_in" ? "固定盈余转入" : "固定赤字补充";
}
