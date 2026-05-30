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
  "plannedIncomeTotal",
  "plannedExpenseTotal",
  "plannedBalanceTotal",
  "actualIncomeTotal",
  "actualExpenseTotal",
  "actualBalanceTotal",
  "pendingSummary",
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
  "jpyTransactionFormTitle",
  "jpyTransactionForm",
  "jpyTransactionSubmitBtn",
  "jpyTransactionCancelBtn",
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
