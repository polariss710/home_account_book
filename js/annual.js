import { els } from "#elements";
import { appState } from "#state";
import { isCloudReady, loadYearSummary } from "#supabase";
import { setActionMessage } from "#ui";
import { emptyRow, money, moneyCny } from "#utils";

export function bindAnnualEvents(afterLoad) {
  els.annualYearPicker.addEventListener("change", async () => {
    appState.activeYear = Number(els.annualYearPicker.value);
    if (!isCloudReady()) {
      setActionMessage("请先登录后再读取年度统计。", "error");
      afterLoad();
      return;
    }
    await loadYearSummary(appState.activeYear);
    afterLoad();
  });
}

export function renderAnnualPage() {
  if (els.annualYearPicker.value !== String(appState.activeYear)) {
    els.annualYearPicker.value = appState.activeYear;
  }

  const totals = appState.yearSummary?.totals || {};
  const jpy = totals.jpy || {};
  const cny = totals.cny || {};
  renderAmount(els.annualJpyIncome, jpy.income, money);
  renderAmount(els.annualJpyExpense, jpy.expense, money);
  renderAmount(els.annualJpyBalance, jpy.balance, money, true);
  renderAmount(els.annualCnyIncome, cny.income, moneyCny);
  renderAmount(els.annualCnyExpense, cny.expense, moneyCny);
  renderAmount(els.annualCnyBalance, cny.balance, moneyCny, true);

  const months = appState.yearSummary?.months || [];
  els.annualMonthRows.innerHTML = months.length ? months.map(monthRow).join("") : emptyRow(7);
}

function renderAmount(element, value, formatter, markNegative = false) {
  const number = Number(value || 0);
  element.textContent = formatter(number);
  element.classList.toggle("negative", markNegative && number < 0);
}

function monthRow(month) {
  return `
    <tr>
      <td>${month.month_key}</td>
      <td>${money(month.jpy_income || 0)}</td>
      <td>${money(month.jpy_expense || 0)}</td>
      <td class="${Number(month.jpy_balance || 0) < 0 ? "negative-text" : ""}">${money(month.jpy_balance || 0)}</td>
      <td>${moneyCny(month.cny_income || 0)}</td>
      <td>${moneyCny(month.cny_expense || 0)}</td>
      <td class="${Number(month.cny_balance || 0) < 0 ? "negative-text" : ""}">${moneyCny(month.cny_balance || 0)}</td>
    </tr>
  `;
}
