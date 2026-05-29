export const els = {};

const elementIds = [
  "authGate",
  "appShell",
  "syncStatus",
  "appVersion",
  "appMessage",
  "monthPicker",
  "generateMonthBtn",
  "refreshBtn",
  "fixedIncomeTotal",
  "fixedExpenseTotal",
  "fixedBalanceTotal",
  "fixedUnpaidTotal",
  "paymentGroupSummary",
  "templateFormTitle",
  "templateForm",
  "templateSubmitBtn",
  "templateCancelBtn",
  "incomeItemRows",
  "expenseItemRows",
  "templateRows",
  "stoppedTemplateTitle",
  "toggleStoppedTemplatesBtn",
  "stoppedTemplateRows",
  "accountForm",
  "accountRows",
  "jpyBalanceRows",
  "jpyTransactionForm",
  "jpyAccountSelect",
  "jpyTransferAccountSelect",
  "jpyTransactionRows",
  "authForm",
  "authState",
  "passwordSignInBtn",
  "passwordSignUpBtn",
  "signOutBtn",
  "actionMessage",
];

export function bindElements() {
  elementIds.forEach((id) => {
    els[id] = document.getElementById(id);
  });
}
