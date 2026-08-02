import { els } from "#elements";
import { appState } from "#state";
import { setActionMessage } from "#ui";
import {
  approveExternalTransactionRequest,
  isCloudReady,
  loadAppData,
  loadExternalTransactionRequests,
  rejectExternalTransactionRequest,
  syncCashRequestResultToSchool,
} from "#supabase";
import { emptyRow, escapeHtml, money, moneyByCurrency } from "#utils";

let renderPage = () => {};
let teacherWageGroupContainer = null;
let isTeacherWageGroupActionRunning = false;

export function bindExternalRequestEvents(renderCallback) {
  renderPage = renderCallback;
  els.externalRequestStatusFilter.addEventListener("change", async () => {
    appState.externalRequestStatusFilter = els.externalRequestStatusFilter.value;
    if (!isCloudReady()) return;
    await loadExternalTransactionRequests();
    renderPage();
  });
}

export function renderExternalRequestsPage() {
  if (!els.externalRequestRows) return;
  els.externalRequestStatusFilter.value = appState.externalRequestStatusFilter;
  const requests = appState.externalRequests || [];
  renderTeacherWageGroups(requests);
  els.externalRequestRows.innerHTML = requests.length ? requests.map(requestRow).join("") : emptyRow(9);
  bindTeacherWageGroupActions();
  bindRequestActions();
}

function requestRow(request) {
  return `
    <tr>
      <td>${statusBadge(request.status)}</td>
      <td>${escapeHtml(sourceLabel(request.external_source))}</td>
      <td>${escapeHtml(requestTypeLabel(request))}</td>
      <td>${escapeHtml(transactionTypeLabel(request.transaction_type))}</td>
      <td>${moneyByCurrency(request.amount || 0, request.currency || "JPY")} ${escapeHtml(request.currency || "JPY")}</td>
      <td>${escapeHtml(request.account_name || request.account_id || "-")}</td>
      <td>${escapeHtml(formatDateTime(request.requested_at))}</td>
      <td>
        <div class="compact-stack">
          ${renderReferenceSummary(request)}
          ${renderPayloadDetails(request)}
          ${renderTechnicalDetails(request)}
          ${request.rejected_reason ? `<span>拒绝理由：${escapeHtml(request.rejected_reason)}</span>` : ""}
        </div>
      </td>
      <td>${requestActions(request)}</td>
    </tr>
  `;
}

function renderReferenceSummary(request) {
  const payload = request.payload_snapshot || {};
  if (isLegacyRequest(request)) {
    const legacyTitle = legacySummaryTitle(request, payload);
    const details = [
      legacyTitle,
      payload.original_amount_jpy ? `JPY工资总额 ${money(payload.original_amount_jpy)}` : "",
      payload.actual_received_amount && payload.actual_received_currency
        ? `实际到账 ${moneyByCurrency(payload.actual_received_amount, payload.actual_received_currency)} ${payload.actual_received_currency}`
        : "",
      payload.school_amount_jpy ? `School成本 ${money(payload.school_amount_jpy)} JPY` : "",
      payload.payment_amount && payload.payment_currency
        ? `实际支付 ${moneyByCurrency(payload.payment_amount, payload.payment_currency)} ${payload.payment_currency}`
        : "",
    ].filter(Boolean).join(" / ");

    return `
      <strong>旧链路 / Legacy</strong>
      <span>仅保留历史查看，不能新建</span>
      ${details ? `<span>${escapeHtml(details)}</span>` : ""}
    `;
  }

  if (isIncomeRequest(request)) {
    const incomePerson = firstValue(payload.student_name, payload.student_display_name, payload.payer_name, payload.source_label);
    const description = firstValue(request.description, payload.description);
    const title = incomeCategoryLabel(payload.income_category);
    const details = [
      incomePerson ? `学生：${incomePerson}` : "",
      !incomePerson && description ? `摘要：${description}` : "",
      firstValue(payload.settlement_month, payload.business_month, payload.year_month)
        ? `业务归属月：${firstValue(payload.settlement_month, payload.business_month, payload.year_month)}`
        : "",
      firstValue(payload.income_date, payload.received_date)
        ? `收款日期：${firstValue(payload.income_date, payload.received_date)}`
        : "",
      originalAmountLabel(payload),
      actualIncomeAmountLabel(payload),
      incomeExchangeRateLabel(payload),
      payload.note || "",
    ].filter(Boolean);

    return `
      <strong>${escapeHtml(title)}</strong>
      ${details.map((part) => `<span>${escapeHtml(part)}</span>`).join("")}
    `;
  }

  if (isExpenseRequest(request)) {
    const title = [
      payload.expense_category_label || payload.expense_category || "支出确认",
      payload.payee_name_snapshot,
      payload.year_month,
    ].filter(Boolean).join(" / ");
    const details = [
      payload.original_amount && payload.original_currency
        ? `原始金额 ${moneyByCurrency(payload.original_amount, payload.original_currency)} ${payload.original_currency}`
        : "",
      payload.actual_payment_amount && payload.actual_payment_currency
        ? `实际支付 ${moneyByCurrency(payload.actual_payment_amount, payload.actual_payment_currency)} ${payload.actual_payment_currency}`
        : "",
    ].filter(Boolean).join(" / ");
    const meta = [
      payload.year_month ? `业务归属月 ${payload.year_month}` : "",
      payload.expense_date || payload.paid_date ? `支付日期 ${payload.expense_date || payload.paid_date}` : "",
      payload.note || "",
    ].filter(Boolean);

    return `
      <strong>${escapeHtml(title)}</strong>
      ${details ? `<span>${escapeHtml(details)}</span>` : ""}
      ${meta.map((part) => `<span>${escapeHtml(part)}</span>`).join("")}
    `;
  }

  return `
    <strong>${escapeHtml(referenceLabel(request.external_reference_type))}</strong>
  `;
}

function renderPayloadDetails(request) {
  const payload = request.payload_snapshot || {};
  if (isLegacyRequest(request)) {
    const parts = [
      payload.payment_exchange_rate ? `汇率 ${payload.payment_exchange_rate}` : "",
      payload.exchange_rate_cny_per_jpy ? `汇率 ${payload.exchange_rate_cny_per_jpy}` : "",
      payload.note || "",
    ].filter(Boolean);

    return parts.map((part) => `<span>${escapeHtml(part)}</span>`).join("");
  }

  if (request.request_type === "expense_paid") {
    const parts = [
      payload.description || "",
      payload.note || "",
    ].filter(Boolean);

    return parts.map((part) => `<span>${escapeHtml(part)}</span>`).join("");
  }

  return "";
}

function requestActions(request) {
  if (isLegacyRequest(request)) {
    return `<span class="badge settled">仅历史查看</span>`;
  }

  if (request.status !== "pending") {
    return request.created_transaction_id
      ? `<span class="badge settled">已生成流水</span>`
      : `<span class="badge unpaid">无需操作</span>`;
  }
  return `
    <div class="button-row">
      <button class="primary-button compact-button" data-approve-external-request="${request.id}" type="button">确认</button>
      <button class="danger-button compact-button" data-reject-external-request="${request.id}" type="button">拒绝</button>
    </div>
  `;
}

function bindRequestActions() {
  document.querySelectorAll("[data-approve-external-request]").forEach((button) => {
    button.addEventListener("click", async () => {
      const request = findRequest(button.dataset.approveExternalRequest);
      if (!request) return;
      const confirmed = window.confirm(`确认这笔 School 收支确认请求并生成 Cash ${transactionTypeLabel(request.transaction_type)}流水？`);
      if (!confirmed) return;
      const result = await approveRequestAndSync(request);
      if (!result.ok) {
        await refreshAfterRequestMutation(result.message, "error");
        return;
      }
      await refreshAfterRequestMutation("已确认并回写私塾系统。");
    });
  });

  document.querySelectorAll("[data-reject-external-request]").forEach((button) => {
    button.addEventListener("click", async () => {
      const request = findRequest(button.dataset.rejectExternalRequest);
      if (!request) return;
      const reason = window.prompt("请输入拒绝理由。", "");
      if (reason === null) return;
      const result = await rejectRequestAndSync(request, reason.trim());
      if (!result.ok) {
        await refreshAfterRequestMutation(result.message, "error");
        return;
      }
      await refreshAfterRequestMutation("已拒绝并回写私塾系统。");
    });
  });
}

function renderTeacherWageGroups(requests) {
  const container = ensureTeacherWageGroupContainer();
  if (!container) return;

  const groups = teacherWageRequestGroups(requests);
  container.innerHTML = `
    <div class="teacher-wage-group-heading">
      <div>
        <h3>老师工资合计待处理</h3>
        <p>请先按合计金额完成实际转账，再点击一键确认。系统会逐条确认本组 Cash 请求。</p>
      </div>
      <span class="badge unpaid">辅助分组</span>
    </div>
    ${
      groups.length
        ? groups.map(teacherWageGroupCard).join("")
        : '<div class="empty-state teacher-wage-group-empty">暂无可合并显示的老师工资请求。</div>'
    }
  `;
}

function ensureTeacherWageGroupContainer() {
  if (teacherWageGroupContainer?.isConnected) return teacherWageGroupContainer;
  const panel = els.externalRequestRows?.closest(".panel");
  if (!panel) return null;
  teacherWageGroupContainer = panel.querySelector(".teacher-wage-group-area");
  if (!teacherWageGroupContainer) {
    teacherWageGroupContainer = document.createElement("section");
    teacherWageGroupContainer.className = "teacher-wage-group-area";
    const tableWrap = panel.querySelector(".table-wrap");
    panel.insertBefore(teacherWageGroupContainer, tableWrap);
  }
  return teacherWageGroupContainer;
}

function teacherWageRequestGroups(requests) {
  const groupsByKey = new Map();
  for (const request of requests) {
    const item = teacherWageGroupItem(request);
    if (!item) continue;
    const group = groupsByKey.get(item.groupKey) || {
      key: item.groupKey,
      teacherName: item.teacherName,
      teacherId: item.teacherId,
      wageMonth: item.wageMonth,
      currency: item.currency,
      amount: 0,
      requests: [],
    };
    group.amount += item.amount;
    group.requests.push(item);
    groupsByKey.set(item.groupKey, group);
  }

  return Array.from(groupsByKey.values()).sort((left, right) => (
    left.wageMonth.localeCompare(right.wageMonth) ||
    left.teacherName.localeCompare(right.teacherName, "zh-Hans") ||
    left.currency.localeCompare(right.currency)
  ));
}

function teacherWageGroupItem(request) {
  if (!isPendingTeacherWageExpenseRequest(request)) return null;
  const payload = request.payload_snapshot || {};
  const teacherName = firstValue(payload.teacher_name, payload.teacher_display_name, payload.payee_name_snapshot);
  const teacherId = firstValue(payload.teacher_id);
  const wageMonth = firstValue(payload.wage_month, payload.settlement_month, payload.year_month, payload.business_month);
  const currency = String(firstValue(request.currency, payload.actual_payment_currency, payload.payment_currency, payload.original_currency)).toUpperCase();
  const amount = Number(firstValue(request.amount, payload.actual_payment_amount, payload.payment_amount, payload.original_amount));

  if (!teacherName || !wageMonth || !currency || !Number.isFinite(amount)) {
    return null;
  }

  const teacherKey = teacherId || teacherName;
  return {
    request,
    groupKey: `${teacherKey}::${wageMonth}::${currency}`,
    teacherName,
    teacherId,
    wageMonth,
    currency,
    amount,
    businessName: firstValue(payload.business_name, payload.business_entity_name, payload.business_entity_label),
    expenseId: firstValue(payload.expense_record_id, request.external_reference_id),
    note: firstValue(payload.note, request.note, payload.description, request.description),
  };
}

function isPendingTeacherWageExpenseRequest(request) {
  const payload = request.payload_snapshot || {};
  return request.status === "pending" &&
    request.external_source === "aozora_school" &&
    isExpenseRequest(request) &&
    (
      payload.expense_category === "teacher_wage" ||
      payload.source_type === "teacher_wage" ||
      payload.expense_category_label === "老师工资"
    );
}

function teacherWageGroupCard(group) {
  return `
    <article class="teacher-wage-group-card">
      <div class="teacher-wage-group-summary">
        <div class="compact-stack">
          <strong>${escapeHtml(group.teacherName)} / ${escapeHtml(group.wageMonth)} / ${escapeHtml(group.currency)}</strong>
          <span>合计：${escapeHtml(group.currency)} ${moneyByCurrency(group.amount, group.currency)} · 明细：${group.requests.length} 条 · 当前状态：待确认</span>
          ${renderBusinessSummary(group)}
        </div>
        <div class="button-row teacher-wage-group-actions">
          <button class="primary-button compact-button" data-approve-teacher-wage-group="${escapeHtml(group.key)}" type="button">一键确认</button>
          <button class="danger-button compact-button" data-reject-teacher-wage-group="${escapeHtml(group.key)}" type="button">一键拒绝</button>
          <details class="teacher-wage-group-details">
            <summary class="ghost-button compact-button">展开 / 收起明细</summary>
            <div class="teacher-wage-group-detail-list">
              ${group.requests.map(teacherWageGroupDetail).join("")}
            </div>
          </details>
        </div>
      </div>
    </article>
  `;
}

function renderBusinessSummary(group) {
  const parts = group.requests.map((item) => (
    `${item.businessName || "业务归属未提供"}：${item.currency} ${moneyByCurrency(item.amount, item.currency)}`
  ));
  return `<span>${escapeHtml(parts.join(" / "))}</span>`;
}

function teacherWageGroupDetail(item) {
  return `
    <div class="teacher-wage-group-detail">
      <strong>${escapeHtml(item.businessName || "业务归属未提供")}：${escapeHtml(item.currency)} ${moneyByCurrency(item.amount, item.currency)}</strong>
      <span>School expense：${escapeHtml(item.expenseId || "-")}</span>
      <span>Cash request：${escapeHtml(item.request.id || "-")} / ${escapeHtml(item.request.status || "-")}</span>
      ${item.note ? `<span>${escapeHtml(item.note)}</span>` : ""}
    </div>
  `;
}

function bindTeacherWageGroupActions() {
  document.querySelectorAll("[data-approve-teacher-wage-group]").forEach((button) => {
    button.addEventListener("click", async () => {
      if (isTeacherWageGroupActionRunning) return;
      const group = findTeacherWageGroup(button.dataset.approveTeacherWageGroup);
      if (!group) return;
      const confirmed = window.confirm(
        `确认将 ${group.teacherName} ${group.wageMonth} 老师工资 ${group.currency} ${moneyByCurrency(group.amount, group.currency)} 的 ${group.requests.length} 条 Cash 请求全部标记为已确认？\n` +
        "请仅在已经完成实际转账后继续。系统会逐条确认这些 Cash 请求。",
      );
      if (!confirmed) return;
      await runTeacherWageGroupAction(group, "approved");
    });
  });

  document.querySelectorAll("[data-reject-teacher-wage-group]").forEach((button) => {
    button.addEventListener("click", async () => {
      if (isTeacherWageGroupActionRunning) return;
      const group = findTeacherWageGroup(button.dataset.rejectTeacherWageGroup);
      if (!group) return;
      const reason = window.prompt("请输入拒绝理由，将用于本组所有 Cash 请求。", "");
      if (reason === null) return;
      const confirmed = window.confirm(
        `确认将 ${group.teacherName} ${group.wageMonth} 老师工资 ${group.currency} ${moneyByCurrency(group.amount, group.currency)} 的 ${group.requests.length} 条 Cash 请求全部拒绝？\n` +
        "系统会逐条拒绝这些 Cash 请求，并逐条回写 School。",
      );
      if (!confirmed) return;
      await runTeacherWageGroupAction(group, "rejected", reason.trim());
    });
  });
}

function findTeacherWageGroup(key) {
  return teacherWageRequestGroups(appState.externalRequests || []).find((group) => group.key === key) || null;
}

async function runTeacherWageGroupAction(group, action, reason = "") {
  isTeacherWageGroupActionRunning = true;
  setTeacherWageGroupButtonsDisabled(true);
  const failures = [];
  let successCount = 0;

  try {
    for (const item of group.requests) {
      const result = action === "approved"
        ? await approveRequestAndSync(item.request)
        : await rejectRequestAndSync(item.request, reason);
      if (result.ok) {
        successCount += 1;
      } else {
        failures.push({
          requestId: item.request.id,
          expenseId: item.expenseId,
          message: result.message,
        });
      }
    }
  } catch (error) {
    const message = error?.message || "未知错误";
    for (const item of group.requests.slice(successCount + failures.length)) {
      failures.push({
        requestId: item.request.id,
        expenseId: item.expenseId,
        message,
      });
    }
  } finally {
    isTeacherWageGroupActionRunning = false;
    setTeacherWageGroupButtonsDisabled(false);
  }

  await refreshAfterRequestMutation(groupActionMessage(successCount, failures), failures.length ? "error" : "success");
}

function setTeacherWageGroupButtonsDisabled(disabled) {
  document.querySelectorAll("[data-approve-teacher-wage-group], [data-reject-teacher-wage-group]").forEach((button) => {
    button.disabled = disabled;
  });
}

function groupActionMessage(successCount, failures) {
  if (!failures.length) {
    return `老师工资分组处理完成：成功 ${successCount} 条，失败 0 条。`;
  }
  const failureText = failures
    .map((failure) => `${shortId(failure.requestId || failure.expenseId)}：${failure.message}`)
    .join("；");
  return `老师工资分组处理完成：成功 ${successCount} 条，失败 ${failures.length} 条。失败：${failureText}`;
}

async function approveRequestAndSync(request) {
  const result = await approveExternalTransactionRequest(request.id);
  if (!result) {
    return { ok: false, message: "Cash 确认 RPC 未成功。" };
  }
  const schoolSync = await syncCashRequestResultToSchool(request.id, "approved");
  if (!schoolSync?.ok) {
    return {
      ok: false,
      message: `Cash 已处理，但回写 School 失败，请稍后重试：${schoolSync?.message || "未知错误"}`,
    };
  }
  return { ok: true };
}

async function rejectRequestAndSync(request, reason) {
  const result = await rejectExternalTransactionRequest(request.id, reason);
  if (!result) {
    return { ok: false, message: "Cash 拒绝 RPC 未成功。" };
  }
  const schoolSync = await syncCashRequestResultToSchool(request.id, "rejected");
  if (!schoolSync?.ok) {
    return {
      ok: false,
      message: `Cash 已处理，但回写 School 失败，请稍后重试：${schoolSync?.message || "未知错误"}`,
    };
  }
  return { ok: true };
}

async function refreshAfterRequestMutation(message, type = "success") {
  await Promise.all([loadExternalTransactionRequests(), loadAppData()]);
  setActionMessage(message, type);
  renderPage();
}

function findRequest(id) {
  return (appState.externalRequests || []).find((request) => request.id === id) || null;
}

function statusBadge(status) {
  const labels = {
    pending: "待确认",
    approved: "已确认",
    rejected: "已驳回",
    cancelled: "已取消",
    void: "已作废",
  };
  const classes = {
    pending: "unpaid",
    approved: "paid",
    rejected: "settled",
    cancelled: "settled",
    void: "settled",
  };
  return `<span class="badge ${classes[status] || "unpaid"}">${labels[status] || escapeHtml(status || "-")}</span>`;
}

function sourceLabel(source) {
  return source === "aozora_school" ? "青空私塾" : source || "-";
}

function requestTypeLabel(request) {
  if (isLegacyRequest(request)) return "旧链路记录";
  if (isIncomeRequest(request)) return "收入确认";
  if (isExpenseRequest(request)) return "支出确认";
  return request.request_type || "-";
}

function transactionTypeLabel(type) {
  const labels = {
    income: "收入",
    expense: "支出",
  };
  return labels[type] || type || "-";
}

function referenceLabel(type) {
  const labels = {
    school_payment_requests: "历史业务请求",
    school_income_records: "School 收入记录",
    school_part_time_work_income_requests: "历史业务请求",
    school_expense_records: "School 支出记录",
  };
  return labels[type] || type || "-";
}

function isIncomeRequest(request) {
  return request.external_reference_type === "school_income_records" &&
    ["income_received", "tuition_income_received"].includes(request.request_type);
}

function isExpenseRequest(request) {
  return request.external_reference_type === "school_expense_records" &&
    request.request_type === "expense_paid";
}

function isLegacyRequest(request) {
  return request.external_reference_type === "school_payment_requests" ||
    request.external_reference_type === "school_part_time_work_income_requests" ||
    [
      "teacher_wage_payment_confirm",
      "teacher_wage_payment_reverse",
      "part_time_work_income_received",
    ].includes(request.request_type);
}

function firstValue(...values) {
  return values.find((value) => value !== null && value !== undefined && value !== "") || "";
}

function shortId(value) {
  const text = String(value || "");
  return text.length > 8 ? text.slice(0, 8) : text || "-";
}

function incomeCategoryLabel(category) {
  const labels = {
    tuition: "学费收入",
    material_fee: "教材费收入",
    registration_fee: "报名费收入",
    other_fee: "其他收入",
    part_time_work: "外部塾打工收入",
  };
  return labels[category] || category || "收入确认";
}

function originalAmountLabel(payload) {
  const amount = firstValue(payload.original_amount, payload.amount);
  const currency = firstValue(payload.original_currency, payload.currency);
  return amount && currency ? `School 原始金额：${currency} ${moneyByCurrency(amount, currency)}` : "";
}

function actualIncomeAmountLabel(payload) {
  const amount = firstValue(payload.actual_received_amount, payload.payment_amount);
  const currency = firstValue(payload.actual_received_currency, payload.payment_currency, payload.currency);
  return amount && currency ? `实际到账：${currency} ${moneyByCurrency(amount, currency)}` : "";
}

function incomeExchangeRateLabel(payload) {
  const rate = firstValue(payload.payment_exchange_rate, payload.exchange_rate, payload.exchange_rate_cny_per_jpy);
  const originalCurrency = firstValue(payload.original_currency, payload.currency);
  const actualCurrency = firstValue(payload.actual_received_currency, payload.payment_currency);
  if (!rate || !originalCurrency || !actualCurrency || originalCurrency === actualCurrency) return "";
  return `参考汇率：1 ${originalCurrency} = ${rate} ${actualCurrency}`;
}

function legacySummaryTitle(request, payload) {
  if (request.request_type === "part_time_work_income_received") {
    return [payload.workplace_name, payload.year_month].filter(Boolean).join(" / ") || "外部塾打工收入";
  }
  if (request.request_type === "teacher_wage_payment_confirm") {
    return "老师工资支付";
  }
  if (request.request_type === "teacher_wage_payment_reverse") {
    return "老师工资撤销";
  }
  return "";
}

function renderTechnicalInfo(request) {
  const parts = [
    `引用：${referenceLabel(request.external_reference_type)} ${request.external_reference_id || "-"}`,
    `技术信息：${request.external_reference_type || "-"} / ${request.request_type || "-"}`,
    `event ${request.external_event_id || "-"}`,
    request.created_transaction_id ? `transaction ${request.created_transaction_id}` : "",
  ].filter(Boolean);
  return parts.map((part) => `<span>${escapeHtml(part)}</span>`).join("");
}

function renderTechnicalDetails(request) {
  const technicalInfo = renderTechnicalInfo(request);
  if (!technicalInfo) return "";
  return `
    <details>
      <summary>系统信息 / 调试信息</summary>
      <div class="compact-stack">
        ${technicalInfo}
      </div>
    </details>
  `;
}

function formatDateTime(value) {
  if (!value) return "-";
  const date = new Date(value);
  if (Number.isNaN(date.getTime())) return value;
  return new Intl.DateTimeFormat("ja-JP", {
    dateStyle: "medium",
    timeStyle: "short",
  }).format(date);
}
