import { monthKey } from "#utils";

export const appState = {
  activeMonth: monthKey(new Date()),
  activeYear: new Date().getFullYear(),
  activeView: "dashboard",
  page: null,
  jpyPage: null,
  cnyPage: null,
  cnyFixedPage: null,
  yearSummary: null,
  editingJpyTransactionId: null,
  editingCnyTransactionId: null,
  editingAccountId: null,
  editingCnyAccountId: null,
  editingCnyTemplateId: null,
  cnyFilters: {
    dateFrom: "",
    dateTo: "",
    transactionType: "",
    accountId: "",
  },
  editingTemplateId: null,
  editingPaymentChannelId: null,
  jpyTemplatesExpanded: false,
  stoppedTemplatesExpanded: false,
  cnyFixedTemplatesExpanded: false,
  cnyStoppedTemplatesExpanded: false,
  supabaseClient: null,
  currentUser: null,
};

export function findFixedTemplate(id) {
  if (!id) return null;
  const templates = [...(appState.page?.templates || []), ...(appState.page?.stopped_templates || [])];
  return templates.find((item) => item.id === id) || null;
}

export function findJpyAccount(id) {
  if (!id) return null;
  const accounts = [...(appState.jpyPage?.accounts || []), ...(appState.page?.accounts || [])];
  return accounts.find((item) => item.id === id) || null;
}

export function findCnyAccount(id) {
  if (!id) return null;
  return (appState.cnyPage?.accounts || []).find((item) => item.id === id) || null;
}

export function findCnyTemplate(id) {
  if (!id) return null;
  const templates = [...(appState.cnyFixedPage?.templates || []), ...(appState.cnyFixedPage?.stopped_templates || [])];
  return templates.find((item) => item.id === id) || null;
}

export function getFixedTemplateTermStatus(template, monthKey) {
  if (template.fixed_type !== "short_term" || !template.start_month || !template.total_terms) {
    return { kind: "ongoing", label: "持续生成" };
  }
  const termNo = monthDistance(template.start_month, monthKey) + 1;
  if (termNo < 1) return { kind: "not_started", label: `未开始 · ${template.start_month} 起`, termNo };
  if (termNo > Number(template.total_terms)) return { kind: "expired", label: `已到期 · ${termNo}/${template.total_terms}`, termNo };
  return { kind: "active", label: `本期 ${termNo}/${template.total_terms}`, termNo };
}

function monthDistance(fromMonth, toMonth) {
  const [fromYear, fromMonthNumber] = fromMonth.split("-").map(Number);
  const [toYear, toMonthNumber] = toMonth.split("-").map(Number);
  return (toYear - fromYear) * 12 + (toMonthNumber - fromMonthNumber);
}
