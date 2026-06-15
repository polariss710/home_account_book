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
import { emptyRow, escapeHtml, money } from "#utils";

let renderPage = () => {};

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
  els.externalRequestRows.innerHTML = requests.length ? requests.map(requestRow).join("") : emptyRow(9);
  bindRequestActions();
}

function requestRow(request) {
  return `
    <tr>
      <td>${statusBadge(request.status)}</td>
      <td>${escapeHtml(sourceLabel(request.external_source))}</td>
      <td>${escapeHtml(requestTypeLabel(request.request_type))}</td>
      <td>${escapeHtml(transactionTypeLabel(request.transaction_type))}</td>
      <td>${money(request.amount || 0)} ${escapeHtml(request.currency || "JPY")}</td>
      <td>${escapeHtml(request.account_name || request.account_id || "-")}</td>
      <td>${escapeHtml(formatDateTime(request.requested_at))}</td>
      <td>
        <div class="compact-stack">
          <strong>${escapeHtml(referenceLabel(request.external_reference_type))}</strong>
          <span>${escapeHtml(request.external_reference_id || "-")}</span>
          <span>event ${escapeHtml(request.external_event_id || "-")}</span>
          ${renderPayloadDetails(request)}
          ${request.created_transaction_id ? `<span>transaction ${escapeHtml(request.created_transaction_id)}</span>` : ""}
          ${request.rejected_reason ? `<span>拒绝理由：${escapeHtml(request.rejected_reason)}</span>` : ""}
        </div>
      </td>
      <td>${requestActions(request)}</td>
    </tr>
  `;
}

function renderPayloadDetails(request) {
  const payload = request.payload_snapshot || {};
  if (request.request_type === "teacher_wage_payment_confirm" && payload.school_amount_jpy) {
    const parts = [
      `School成本 ${money(payload.school_amount_jpy)} JPY`,
      payload.payment_exchange_rate ? `汇率 ${payload.payment_exchange_rate}` : "",
      payload.payment_amount && payload.payment_currency
        ? `实付 ${money(payload.payment_amount)} ${payload.payment_currency}`
        : "",
    ].filter(Boolean);

    return parts.map((part) => `<span>${escapeHtml(part)}</span>`).join("");
  }

  if (request.request_type === "part_time_work_income_received") {
    const parts = [
      payload.workplace_name && payload.year_month ? `${payload.workplace_name} ${payload.year_month}` : "",
      payload.original_amount_jpy ? `JPY工资 ${money(payload.original_amount_jpy)} JPY` : "",
      payload.actual_received_amount && payload.actual_received_currency
        ? `实际到账 ${money(payload.actual_received_amount)} ${payload.actual_received_currency}`
        : "",
      payload.exchange_rate_cny_per_jpy ? `汇率 ${payload.exchange_rate_cny_per_jpy}` : "",
      payload.note || "",
    ].filter(Boolean);

    return parts.map((part) => `<span>${escapeHtml(part)}</span>`).join("");
  }

  return "";
}

function requestActions(request) {
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
      const confirmed = window.confirm(`确认这笔外部请求并生成 Cash ${transactionTypeLabel(request.transaction_type)}流水？`);
      if (!confirmed) return;
      const result = await approveExternalTransactionRequest(request.id);
      if (!result) return;
      const schoolSync = await syncCashRequestResultToSchool(request.id, "approved");
      if (!schoolSync?.ok) {
        await refreshAfterRequestMutation(
          `Cash 已处理，但回写 School 失败，请稍后重试：${schoolSync?.message || "未知错误"}`,
          "error",
        );
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
      const result = await rejectExternalTransactionRequest(request.id, reason.trim());
      if (!result) return;
      const schoolSync = await syncCashRequestResultToSchool(request.id, "rejected");
      if (!schoolSync?.ok) {
        await refreshAfterRequestMutation(
          `Cash 已处理，但回写 School 失败，请稍后重试：${schoolSync?.message || "未知错误"}`,
          "error",
        );
        return;
      }
      await refreshAfterRequestMutation("已拒绝并回写私塾系统。");
    });
  });
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
    rejected: "已拒绝",
  };
  const classes = {
    pending: "unpaid",
    approved: "paid",
    rejected: "settled",
  };
  return `<span class="badge ${classes[status] || "unpaid"}">${labels[status] || escapeHtml(status || "-")}</span>`;
}

function sourceLabel(source) {
  return source === "aozora_school" ? "青空私塾" : source || "-";
}

function requestTypeLabel(type) {
  const labels = {
    teacher_wage_payment_confirm: "老师工资支付",
    teacher_wage_payment_reverse: "老师工资撤销",
    tuition_income_received: "个人学费收入",
    part_time_work_income_received: "外部塾打工收入",
  };
  return labels[type] || type || "-";
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
    school_payment_requests: "School payment request",
    school_income_records: "School income record",
    school_part_time_work_income_requests: "School part-time income request",
  };
  return labels[type] || type || "-";
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
