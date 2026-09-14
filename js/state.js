import { monthKey } from "#utils";

export const appState = {
  activeMonth: monthKey(new Date()),
  // 已加载的固定收支页各自属于哪个月。activeMonth 会先于加载完成而改变，
  // 批量操作靠这两个字段判断手上的列表是否属于当前账期（审核 P1）。
  pageMonth: null,
  cnyFixedPageMonth: null,
  activeYear: new Date().getFullYear(),
  activeView: "dashboard",
  page: null,
  jpyPage: null,
  cnyPage: null,
  cnyFixedPage: null,
  externalRequests: [],
  // 跨月可见的待补回垫付。固定月页面只读当前账期，换月就看不到上个月的垫付，
  // 所以这份单独全量加载，不按月过滤。
  pendingFixedAdvances: [],
  externalRequestStatusFilter: "pending",
  yearSummary: null,
  editingJpyTransactionId: null,
  // 日元零散新增的草稿 id：稳定到保存成功为止。
  // 这样「写入成功但响应丢失」之后的重试会落在同一条记录上，
  // 由唯一键冲突 + 内容核验收敛，而不是插出第二条。
  jpyDraftId: null,
  // 结果未知的那次提交。独立于表单存在——取消、切换编辑/复制都不清除它，
  // 且后续请求的明确失败也不能抹掉（前一次可能已经成功了）。
  jpyPendingSubmission: null,
  editingCnyTransactionId: null,
  editingAccountId: null,
  editingCnyAccountId: null,
  editingCnyTemplateId: null,
  fixedAccountingScope: "all",
  jpyAccountingScope: "all",
  cnyAccountingScope: "all",
  jpyFilters: {
    dateFrom: "",
    dateTo: "",
    transactionType: "",
    accountId: "",
  },
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
