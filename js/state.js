import { monthKey } from "./utils.js?v=20260530-responsive-1";

export const appState = {
  activeMonth: monthKey(new Date()),
  page: null,
  jpyPage: null,
  editingJpyTransactionId: null,
  editingTemplateId: null,
  stoppedTemplatesExpanded: false,
  supabaseClient: null,
  currentUser: null,
};

export function findFixedTemplate(id) {
  if (!id) return null;
  const templates = [...(appState.page?.templates || []), ...(appState.page?.stopped_templates || [])];
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
