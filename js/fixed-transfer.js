import { els } from "#elements";
import { appState } from "#state";
import { createFixedTransfer, isCloudReady, loadAppData } from "#supabase";
import { setActionMessage } from "#ui";
import { escapeHtml, formData, money } from "#utils";

// 调拨的重入锁。必须在第一个 await 之前设置——这一笔会改账户余额，
// 双击的代价比多等一下大得多。
let fixedTransferInFlight = false;

export function bindFixedTransferEvents(afterSave) {
  els.fixedTransferForm.addEventListener("submit", async (event) => {
    event.preventDefault();
    if (fixedTransferInFlight) return;
    if (!isCloudReady()) {
      setActionMessage("请先登录后再保存固定资金调拨。", "error");
      return;
    }

    const form = event.currentTarget;
    const data = formData(form);
    const status = appState.page?.fixed_settlement_status;
    // 方向由 DB 给，前端不再从差额自己推。旧字段 transaction_type 是按整月差额
    // 算的，与新口径可能给出相反的方向。
    const transactionType = status?.funding_transaction_type;
    if (!data.account_id) {
      setActionMessage("请先选择日元账户。", "error");
      return;
    }
    if (!transactionType) {
      setActionMessage("当前既不需要补充资金，也没有可转出的盈余。", "error");
      return;
    }

    fixedTransferInFlight = true;
    els.fixedTransferSubmitBtn.disabled = true;
    try {
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
    } finally {
      fixedTransferInFlight = false;
      // 按钮该不该可点由结算状态决定，不能无条件恢复成可点。
      renderFixedTransferStatus();
    }
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
    els.fixedTransferStatus.textContent = "固定收支数据尚未加载完成。";
    els.fixedTransferSubmitBtn.disabled = true;
    return;
  }

  // 全部取自 DB，前端不计算也不推导方向（P0）。
  const type = status.funding_transaction_type || null;
  const fundingState = status.funding_state || "balanced";
  const fundingRequired = Number(status.funding_required || 0);
  const surplus = Number(status.transferable_surplus || 0);
  const advance = Number(status.advance_amount_in_month || 0);
  // 补充不取整；转出向下取整到千元，所以这两个字段不能混用。
  const buttonAmount =
    type === "fixed_out"
      ? Number(status.funding_transfer_amount || 0)
      : Number(status.transferable_transfer_amount || 0);

  const typeSelect = els.fixedTransferForm.elements.transaction_type;
  typeSelect.disabled = true;
  if (type) typeSelect.value = type;

  // 三行分开写，是因为这几个数含义完全不同，挤成一行会被当成同一个量：
  //   整月差额 —— 这个月固定收支的规模，含已付与已垫付，不是要准备的现金
  //   本月已垫付 —— 由实体账户先付掉的部分，池子不必再为它出钱
  //   还需补充 / 可转出 —— 真正要动的钱
  const rows = [
    settlementRow("整月固定收支差额", Number(status.balance || 0)),
  ];
  if (advance > 0) rows.push(settlementRow("本月已垫付", advance));
  if (fundingRequired > 0) {
    rows.push(settlementRow("本月还需补充", fundingRequired));
  } else if (surplus > 0) {
    // 展示原始盈余，按钮上是向下取整后的金额。两个数同屏可见，
    // 否则用户会以为系统吞了那个零头。
    rows.push(settlementRow("可转出盈余", surplus));
  }

  els.fixedTransferStatus.className = `settlement-status ${fundingState}`;
  els.fixedTransferStatus.innerHTML = rows.join("");
  els.fixedTransferSubmitBtn.textContent = labelSubmitButton(type, buttonAmount);
  els.fixedTransferSubmitBtn.disabled = !type || buttonAmount <= 0;
}

function settlementRow(label, amount) {
  return `<div class="settlement-row"><span>${escapeHtml(label)}</span><strong>${money(amount)}</strong></div>`;
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

// 按钮上带金额，让它和状态条里的原始盈余同屏可比——转出时两者会差一个零头。
function labelSubmitButton(type, amount) {
  if (type === "fixed_out") return `补充资金 ${money(amount)}`;
  if (type === "fixed_in") return `转出盈余 ${money(amount)}`;
  return "当前无需调拨";
}
