export const els = {};

const elementIds = [
  "syncStatus",
  "monthPicker",
  "settleMonthBtn",
  "exportBtn",
  "seedBtn",
  "accountBalances",
  "pendingRows",
  "transactionForm",
  "transactionRows",
  "accountForm",
  "accountRows",
  "categoryForm",
  "categoryRows",
  "authForm",
  "authState",
  "passwordSignInBtn",
  "passwordSignUpBtn",
  "signOutBtn",
  "actionMessage",
  "supabaseForm",
  "monthIncome",
  "monthExpense",
  "monthUnpaid",
  "monthBalance",
];

export function bindElements() {
  elementIds.forEach((id) => {
    els[id] = document.getElementById(id);
  });
}
