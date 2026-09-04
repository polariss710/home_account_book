import { els } from "#elements";
import { renderAnnualPage } from "#annual";
import { renderCnyPage } from "#cny";
import { renderExternalRequestsPage } from "#external-requests";
import { renderFixedTransferForm } from "#fixed-transfer";
import { renderJpyPage } from "#jpy";
import { appState, findFixedTemplate, findJpyAccount, getFixedTemplateTermStatus } from "#state";
import { renderShell, setActionMessage } from "#ui";
import { canRequestFixedMonthItemDelete, emptyRow, escapeHtml, fixedMonthItemDeleteLockLabel, money } from "#utils";
import {
  deactivatePaymentChannel,
  deactivateAccount,
  deactivateTemplate,
  createFixedAdvancePayment,
  deleteMonthItem,
  loadAppData,
  loadFixedMonthPage,
  reactivateTemplate,
  saveMonthItem,
  settleFixedAdvanceRepayment,
  applySkippedProjectionItems,
  updateMonthItemsStatus,
  updateMonthItemStatus,
} from "#supabase";

export function render() {
  renderShell();
  renderDashboard();
  renderAnnualPage();
  renderMonthItems();
  renderTemplates();
  renderAccounts();
  renderTemplatePaymentGroupOptions();
  renderFixedTransferForm();
  renderExternalRequestsPage();
  renderPaymentChannels();
  renderJpyPage();
  renderCnyPage();
}

function renderDashboard() {
  const metrics = appState.page?.metrics || {};
  renderMetric(els.plannedIncomeTotal, metrics.planned_income ?? metrics.income);
  renderMetric(els.plannedExpenseTotal, metrics.planned_expense ?? metrics.expense);
  renderMetric(els.plannedBalanceTotal, metrics.planned_balance ?? metrics.balance, true);
  renderMetric(els.actualIncomeTotal, metrics.actual_income);
  renderMetric(els.actualExpenseTotal, metrics.actual_expense);
  renderMetric(els.actualBalanceTotal, metrics.actual_balance, true);
  renderPendingSummary(metrics);

  const groups = appState.page?.expense_groups || [];
  els.paymentGroupSummary.innerHTML = groups.length
    ? groups
        .map(
          (group) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(group.payment_group || "未分组")}</strong>
                <span>未付金额</span>
              </div>
              <strong>${money(group.unpaid ?? group.total ?? 0)}</strong>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无支付渠道数据</div>`;
}

function renderMetric(element, value, markNegative = false) {
  const number = Number(value || 0);
  element.textContent = money(number);
  element.classList.toggle("negative", markNegative && number < 0);
}

function renderPendingSummary(metrics) {
  const items = [
    { label: "未收固定收入", value: metrics.unreceived_income },
    { label: "未付固定支出", value: metrics.unpaid_expense },
  ];
  els.pendingSummary.innerHTML = items
    .map(
      (item) => `
        <div class="settings-item">
          <div>
            <strong>${item.label}</strong>
            <span>当前账期仍未完成的固定项目金额</span>
          </div>
          <strong>${money(item.value || 0)}</strong>
        </div>
      `,
    )
    .join("");
}

function renderMonthItems() {
  const selectedScope = appState.fixedAccountingScope;
  document.getElementById("fixedScopeFilter").value = selectedScope;
  const incomeItems = (appState.page?.income_items || []).filter((item) => matchesAccountingScope(item, selectedScope, "JPY fixed income"));
  const expenseSections = (appState.page?.expense_sections || [])
    .map((section) => ({
      ...section,
      items: (section.items || []).filter((item) => matchesAccountingScope(item, selectedScope, "JPY fixed expense")),
    }))
    .filter((section) => section.items.length > 0);
  const expenseItems = (appState.page?.expense_items || []).filter((item) => matchesAccountingScope(item, selectedScope, "JPY fixed expense"));
  els.incomeItemRows.innerHTML = incomeItems.length ? incomeItems.map(incomeItemRow).join("") : scopeEmptyRow(8, selectedScope);
  els.expenseItemRows.innerHTML = renderExpenseRows(expenseSections, expenseItems);
  bindMonthItemControls();
}

function renderExpenseRows(sections, items) {
  if (sections.length) return sections.map(expenseSectionRows).join("");
  if (items.length) return items.map(expenseItemRow).join("");
  return scopeEmptyRow(9, appState.fixedAccountingScope);
}

function incomeItemRow(item) {
  return `
    <tr class="${fixedStatusRowClass(item)}">
      <td>${escapeHtml(item.name)}</td>
      <td>${monthItemAmountCell(item)}</td>
      <td>${escapeHtml(item.due_date || "-")}</td>
      <td>${monthItemStatusCell(item)}</td>
      <td>${termLabel(item)}</td>
      <td>${monthItemNoteCell(item)}</td>
      <td>${accountingScopeBadge(item, "JPY fixed income")}</td>
      <td>${monthItemDeleteCell(item)}</td>
    </tr>
  `;
}

function expenseItemRow(item) {
  return `
    <tr class="${fixedStatusRowClass(item)}">
      <td>${escapeHtml(item.payment_group || "未分组")}</td>
      <td>${escapeHtml(item.name)}</td>
      <td>${monthItemAmountCell(item)}</td>
      <td>${escapeHtml(item.due_date || "-")}</td>
      <td>${monthItemStatusCell(item)}</td>
      <td>${termLabel(item)}</td>
      <td>${monthItemNoteCell(item)}</td>
      <td>${accountingScopeBadge(item, "JPY fixed expense")}</td>
      <td>${monthItemDeleteCell(item)}</td>
    </tr>
  `;
}

function monthItemAmountCell(item) {
  if (item.linked_jpy_transaction_id || item.advance_id) return money(item.amount || 0);
  return `<input class="table-input amount-input" data-item-amount="${item.id}" type="number" step="1" value="${Number(item.amount || 0)}" />`;
}

function monthItemStatusCell(item) {
  if (item.linked_jpy_transaction_id || item.advance_id) return labelStatus("paid");
  return statusSelect(item);
}

function monthItemNoteCell(item) {
  if (item.linked_jpy_transaction_id || item.advance_id) return escapeHtml(item.note || "");
  return `<input class="table-input" data-item-note="${item.id}" value="${escapeHtml(item.note || "")}" />`;
}

function monthItemDeleteCell(item) {
  if (!canRequestFixedMonthItemDelete(item)) {
    return `<span class="badge settled">${fixedMonthItemDeleteLockLabel(item)}</span>`;
  }
  return `<button class="danger-button compact-button" data-delete-item="${item.id}" type="button">删除</button>`;
}

function expenseSectionRows(section) {
  return `
    <tr class="fixed-expense-section">
      <td colspan="9">
        <div class="fixed-expense-section-summary">
          <div>
            <strong>${escapeHtml(section.payment_group || "未分组")}</strong>
            <span>期限 ${escapeHtml(section.first_due_date || "-")}</span>
          </div>
          <div class="fixed-expense-section-side">
            <div class="fixed-expense-section-amounts">
              <span>合计 <strong>${money(section.total || 0)}</strong></span>
              <span>已付 <strong>${money(section.paid || 0)}</strong></span>
              <span>未付 <strong>${money(section.unpaid || 0)}</strong></span>
            </div>
            ${fixedAdvanceControls(section)}
          </div>
        </div>
      </td>
    </tr>
    ${(section.items || []).map(expenseItemRow).join("")}
  `;
}

function fixedAdvanceControls(section) {
  const status = section.advance_status || "";
  if (status === "repaid") {
    return `
      <div class="fixed-advance-controls">
        <span class="badge settled">已补回</span>
        <span>${escapeHtml(section.advance_account_name || "-")} · ${money(section.advance_amount || 0)}</span>
      </div>
    `;
  }

  if (status === "pending") {
    return `
      <div class="fixed-advance-controls" data-advance-controls>
        <span class="badge">待补回</span>
        <span>${escapeHtml(section.advance_account_name || "-")} · ${money(section.advance_amount || 0)}</span>
        <input class="table-input compact-date-input" data-fixed-advance-date type="date" value="${escapeHtml(section.advance_paid_at || `${appState.activeMonth}-01`)}" />
        <button class="primary-button compact-button" data-settle-fixed-advance="${section.advance_id}" type="button">补回垫付</button>
      </div>
    `;
  }

  return `
    <div class="fixed-advance-controls" data-advance-controls>
      <span class="badge">可垫付</span>
      <select class="table-input compact-select" data-fixed-advance-account>
        ${fixedAdvanceAccountOptions()}
      </select>
      <input class="table-input compact-date-input" data-fixed-advance-date type="date" value="${escapeHtml(section.first_due_date || `${appState.activeMonth}-01`)}" />
      <button class="ghost-button compact-button" data-create-fixed-advance="${escapeHtml(encodeURIComponent(section.payment_group || "未分组"))}" type="button">垫付支付</button>
    </div>
  `;
}

function fixedAdvanceAccountOptions() {
  const accounts = appState.jpyPage?.accounts || [];
  return accounts.length
    ? accounts.map((account) => `<option value="${account.id}">${escapeHtml(account.name)}</option>`).join("")
    : `<option value="">请先新增日元账户</option>`;
}

function statusSelect(item) {
  return `
    <select class="table-input" data-item-status="${item.id}">
      <option value="unpaid"${item.status === "unpaid" ? " selected" : ""}>未付</option>
      <option value="paid"${item.status === "paid" ? " selected" : ""}>已付</option>
      <option value="settled"${item.status === "settled" ? " selected" : ""}>已结清</option>
    </select>
  `;
}

function fixedStatusRowClass(item) {
  if (item.status === "paid" || item.status === "settled" || item.linked_jpy_transaction_id) return "status-paid-row";
  return "status-unpaid-row";
}

function labelStatus(status) {
  const labels = {
    unpaid: "未付",
    paid: "已付",
    settled: "已结清",
  };
  return labels[status] || status;
}

function termLabel(item) {
  if (!item.term_no || !item.total_terms) return "-";
  return `${item.term_no}/${item.total_terms}`;
}

function bindMonthItemControls() {
  document.querySelectorAll("[data-item-amount]").forEach((input) => {
    input.addEventListener("change", () => saveItemPatch(input.dataset.itemAmount, { amount: Number(input.value || 0) }));
  });
  document.querySelectorAll("[data-item-status]").forEach((select) => {
    select.addEventListener("change", () => saveItemStatus(select.dataset.itemStatus, select.value));
  });
  document.querySelectorAll("[data-item-note]").forEach((input) => {
    input.addEventListener("change", () => saveItemPatch(input.dataset.itemNote, { note: input.value.trim() }));
  });
  document.querySelectorAll("[data-delete-item]").forEach((button) => {
    button.addEventListener("click", async () => {
      const item = findMonthItem(button.dataset.deleteItem);
      if (!confirmDeleteMonthItem(item)) return;
      const result = await deleteMonthItem(button.dataset.deleteItem);
      if (!result) return;
      await loadAppData();
      setActionMessage(result.message || "固定项已删除。", result.reset_expense_status ? "error" : "success");
      render();
    });
  });
  document.querySelectorAll("[data-create-fixed-advance]").forEach((button) => {
    button.addEventListener("click", async () => {
      const controls = button.closest("[data-advance-controls]");
      const accountId = controls?.querySelector("[data-fixed-advance-account]")?.value || "";
      const transactedAt = controls?.querySelector("[data-fixed-advance-date]")?.value || "";
      if (!accountId || !transactedAt) {
        setActionMessage("请先选择垫付账户和垫付日期。", "error");
        return;
      }
      const result = await createFixedAdvancePayment({
        payment_group: decodeURIComponent(button.dataset.createFixedAdvance || ""),
        account_id: accountId,
        transacted_at: transactedAt,
        note: "",
      });
      if (!result) return;
      await loadAppData();
      setActionMessage(result.message || "固定支出垫付已生成。", "success");
      render();
    });
  });
  document.querySelectorAll("[data-settle-fixed-advance]").forEach((button) => {
    button.addEventListener("click", async () => {
      const controls = button.closest("[data-advance-controls]");
      const repaidAt = controls?.querySelector("[data-fixed-advance-date]")?.value || "";
      if (!repaidAt) {
        setActionMessage("请先选择补回日期。", "error");
        return;
      }
      const result = await settleFixedAdvanceRepayment({
        advance_id: button.dataset.settleFixedAdvance,
        repaid_at: repaidAt,
        note: "",
      });
      if (!result) return;
      await loadAppData();
      setActionMessage(result.message || "固定垫付已补回。", "success");
      render();
    });
  });
  document.querySelectorAll("[data-bulk-item-status]").forEach((button) => {
    button.addEventListener("click", async () => {
      const [direction, status] = button.dataset.bulkItemStatus.split(":");
      // **在第一次 await 之前固定操作范围。** 批量请求往返期间用户可能切换账期，
      // 之后再读 appState.page 拿到的是另一个月的项目，补写会打到错误的月份上。
      const operatingMonth = appState.activeMonth;
      const projectionTargets =
        (direction === "income" ? appState.page?.income_items : appState.page?.expense_items) || [];
      const result = await updateMonthItemsStatus(direction, status);
      if (!result) return;
      // 批量 writer 有意跳过 School projection 项，这里逐条补上，用户仍只点一次。
      // 理由见 supabase.js 里 confirmProjectionItemsStatus 的注释。
      const suffix = await applySkippedProjectionItems(
        result,
        projectionTargets,
        status,
        operatingMonth,
      );
      await loadFixedMonthPage();
      setActionMessage(
        `${result.message || `固定项状态已更新 ${Number(result.updated_count || 0)} 条。`}${suffix}`,
        "success",
      );
      render();
    });
  });
}

async function saveItemPatch(id, patch) {
  const item = findMonthItem(id);
  if (!item) return;
  const ok = await saveMonthItem({ ...item, ...patch });
  if (!ok) return;
  await loadFixedMonthPage();
  render();
}

async function saveItemStatus(id, status) {
  // School projection 项要走专用 writer，把 item 一起传下去让 supabase.js 分岔。
  const result = await updateMonthItemStatus(id, status, findMonthItem(id));
  if (!result) {
    await loadFixedMonthPage();
    render();
    return;
  }
  await loadFixedMonthPage();
  setActionMessage(result.message || "固定项状态已更新。", "success");
  render();
}

function findMonthItem(id) {
  const items = [...(appState.page?.income_items || []), ...(appState.page?.expense_items || [])];
  return items.find((item) => item.id === id);
}

function confirmDeleteMonthItem(item) {
  if (!item) {
    return window.confirm("确定删除这条日元固定支出吗？此操作无法撤销。");
  }

  return window.confirm([
    item.direction === "expense"
      ? "确定删除这条日元固定支出吗？此操作无法撤销。"
      : "准备删除这笔日元固定项：",
    `日期：${item.due_date || "-"}`,
    `金额：${money(item.amount)} JPY`,
    "币种：JPY",
    `账户：${item.account_name || "-"}`,
    `类型：${item.direction === "income" ? "固定收入" : "固定支出"}`,
    `备注：${[item.name, item.note].filter(Boolean).join(" / ") || "-"}`,
    "",
    "只有未支付且没有下游支付事实的普通固定项会被删除；关联流水不会被同步删除。",
    "",
    "确认删除吗？",
  ].join("\n"));
}

function renderTemplates() {
  const selectedScope = appState.fixedAccountingScope;
  const templates = (appState.page?.templates || []).filter((item) => matchesAccountingScope(item, selectedScope, "JPY fixed template"));
  const stoppedTemplates = (appState.page?.stopped_templates || []).filter((item) => matchesAccountingScope(item, selectedScope, "JPY stopped fixed template"));
  els.activeTemplateTitle.textContent = `使用中的固定模板（${templates.length}）`;
  els.templateRows.hidden = !appState.jpyTemplatesExpanded;
  els.toggleActiveTemplatesBtn.textContent = appState.jpyTemplatesExpanded ? "收起" : "展开";
  els.templateRows.innerHTML = appState.jpyTemplatesExpanded
    ? templates.map((item) => templateRow(item, "active")).join("") || scopeEmptyState(selectedScope, "暂无固定模板")
    : "";

  els.stoppedTemplateTitle.textContent = `停止生成的固定模板（${stoppedTemplates.length}）`;
  els.stoppedTemplateRows.hidden = !appState.stoppedTemplatesExpanded;
  els.toggleStoppedTemplatesBtn.textContent = appState.stoppedTemplatesExpanded ? "收起" : "展开";
  els.stoppedTemplateRows.innerHTML = appState.stoppedTemplatesExpanded
    ? stoppedTemplates.map((item) => templateRow(item, "stopped")).join("") || scopeEmptyState(selectedScope, "暂无停止生成的模板")
    : "";

  els.toggleActiveTemplatesBtn.onclick = () => {
    appState.jpyTemplatesExpanded = !appState.jpyTemplatesExpanded;
    renderTemplates();
  };

  els.toggleStoppedTemplatesBtn.onclick = () => {
    appState.stoppedTemplatesExpanded = !appState.stoppedTemplatesExpanded;
    renderTemplates();
  };

  document.querySelectorAll("[data-edit-template]").forEach((button) => {
    button.addEventListener("click", () => {
      const template = findFixedTemplate(button.dataset.editTemplate);
      if (!template) return;
      setTemplateForm(template, "edit");
    });
  });

  document.querySelectorAll("[data-copy-template]").forEach((button) => {
    button.addEventListener("click", () => {
      const template = findFixedTemplate(button.dataset.copyTemplate);
      if (!template) return;
      setTemplateForm({ ...template, name: `${template.name} 复制` }, "copy");
    });
  });

  document.querySelectorAll("[data-disable-template]").forEach((button) => {
    button.addEventListener("click", async () => {
      const template = findFixedTemplate(button.dataset.disableTemplate);
      if (!template) return;
      const confirmed = window.confirm(`停止生成「${template.name}」？历史月份记录会保留，之后月份不再自动生成。`);
      if (!confirmed) return;
      const ok = await deactivateTemplate(button.dataset.disableTemplate);
      if (!ok) return;
      await loadFixedMonthPage();
      setActionMessage("模板已停止生成，历史记录已保留。", "success");
      render();
    });
  });

  document.querySelectorAll("[data-reactivate-template]").forEach((button) => {
    button.addEventListener("click", async () => {
      const template = findFixedTemplate(button.dataset.reactivateTemplate);
      if (!template) return;
      const ok = await reactivateTemplate(template.id);
      if (!ok) return;
      await loadFixedMonthPage();
      setActionMessage("模板已恢复生成，之后月份可继续使用。", "success");
      render();
    });
  });
}

function renderTemplatePaymentGroupOptions(selectedValue = els.templatePaymentGroupSelect.value) {
  const channels = appState.page?.payment_channels || [];
  const hasSelectedValue = selectedValue && channels.some((channel) => channel.name === selectedValue);
  const channelOptions = channels
    .map(
      (channel) =>
        `<option value="${escapeHtml(channel.name)}" data-default-due-day="${channel.default_due_day || ""}">${escapeHtml(channel.name)}</option>`,
    )
    .join("");
  const selectedOption = selectedValue && !hasSelectedValue ? `<option value="${escapeHtml(selectedValue)}">${escapeHtml(selectedValue)}</option>` : "";
  els.templatePaymentGroupSelect.innerHTML = `<option value="">未分组</option>${selectedOption}${channelOptions}`;
  els.templatePaymentGroupSelect.value = selectedValue || "";
}

function renderPaymentChannels() {
  const channels = appState.page?.payment_channels || [];
  els.paymentChannelRows.innerHTML = channels.length
    ? channels
        .map(
          (item) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(item.name)}</strong>
                <span>默认支付日 ${item.default_due_day || "-"}</span>
              </div>
              <div class="button-row">
                <button class="ghost-button compact-button" data-edit-payment-channel="${item.id}" type="button">编辑</button>
                <button class="danger-button compact-button" data-disable-payment-channel="${item.id}" type="button">停用</button>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无日元固定收支账户</div>`;

  document.querySelectorAll("[data-edit-payment-channel]").forEach((button) => {
    button.addEventListener("click", () => {
      const channel = findPaymentChannel(button.dataset.editPaymentChannel);
      if (!channel) return;
      setPaymentChannelForm(channel);
    });
  });

  document.querySelectorAll("[data-disable-payment-channel]").forEach((button) => {
    button.addEventListener("click", async () => {
      const channel = findPaymentChannel(button.dataset.disablePaymentChannel);
      if (!channel) return;
      const confirmed = window.confirm(`停用日元固定收支账户「${channel.name}」？已有模板和历史固定项会保留当前文字。`);
      if (!confirmed) return;
      const ok = await deactivatePaymentChannel(channel.id);
      if (!ok) return;
      await loadFixedMonthPage();
      setActionMessage("日元固定收支账户已停用。", "success");
      render();
    });
  });
}

function templateRow(item, status) {
  const statusLabel = status === "stopped" ? "停止生成" : "使用中";
  const periodLabel = templatePeriodLabel(item);
  const statusAction =
    status === "stopped"
      ? `<button class="primary-button compact-button" data-reactivate-template="${item.id}" type="button">恢复生成</button>`
      : `<button class="danger-button compact-button" data-disable-template="${item.id}" type="button">停止生成</button>`;
  return `
    <div class="settings-item">
      <div>
        <strong>${escapeHtml(item.name)}</strong> ${accountingScopeBadge(item, "JPY fixed template")}
        <span>${statusLabel} · ${labelDirection(item.direction)} · ${labelFixedType(item.fixed_type)} · ${periodLabel} · ${escapeHtml(item.payment_group || "未分组")} · ${money(item.default_amount || 0)}</span>
      </div>
      <div class="button-row">
        <button class="ghost-button compact-button" data-edit-template="${item.id}" type="button">编辑</button>
        <button class="ghost-button compact-button" data-copy-template="${item.id}" type="button">复制</button>
        ${statusAction}
      </div>
    </div>
  `;
}

function templatePeriodLabel(item) {
  return getFixedTemplateTermStatus(item, appState.activeMonth).label;
}

function matchesAccountingScope(item, selectedScope, context) {
  const scope = accountingScopeKind(item, context);
  return selectedScope === "all" || scope === selectedScope;
}

function accountingScopeBadge(item, context) {
  const scope = accountingScopeKind(item, context);
  const labels = {
    household: "家庭",
    school: "School",
    invalid: "归属异常",
  };
  return `<span class="scope-badge scope-${scope}">${labels[scope]}</span>`;
}

function accountingScopeKind(item, context) {
  const scope = item?.accounting_scope;
  if (scope === "household" || scope === "school") return scope;
  console.error("[accounting_scope] Unexpected value in reader record.", {
    context,
    id: item?.id || null,
    accounting_scope: scope,
  });
  return "invalid";
}

function scopeEmptyRow(colspan, selectedScope) {
  if (selectedScope === "all") return emptyRow(colspan);
  return `<tr><td colspan="${colspan}" class="empty-state">当前没有符合该账务归属的记录。</td></tr>`;
}

function scopeEmptyState(selectedScope, defaultMessage) {
  const message = selectedScope === "all" ? defaultMessage : "当前没有符合该账务归属的记录。";
  return `<div class="empty-state">${message}</div>`;
}

function setTemplateForm(template, mode) {
  const form = els.templateForm;
  appState.editingTemplateId = mode === "edit" ? template.id : null;
  renderTemplatePaymentGroupOptions(template.payment_group || "");
  form.elements.name.value = template.name || "";
  form.elements.direction.value = template.direction || "expense";
  form.elements.fixed_type.value = template.fixed_type || "long_term";
  form.elements.default_amount.value = template.default_amount ?? "";
  form.elements.payment_group.value = template.payment_group || "";
  form.elements.due_day.value = template.due_day || "";
  form.elements.start_month.value = template.start_month || "";
  form.elements.total_terms.value = template.total_terms || "";
  els.templateFormTitle.textContent = mode === "edit" ? "编辑固定模板" : "复制固定模板";
  els.templateSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新模板";
  els.templateCancelBtn.hidden = false;
  form.elements.fixed_type.dispatchEvent(new Event("change"));
  form.elements.name.focus();
  setActionMessage(mode === "edit" ? "正在编辑固定模板。" : "已复制到表单，保存后会成为新模板。", "success");
}

function setPaymentChannelForm(channel) {
  const form = els.paymentChannelForm;
  appState.editingPaymentChannelId = channel.id;
  form.elements.name.value = channel.name || "";
  form.elements.default_due_day.value = channel.default_due_day || "";
  els.paymentChannelSubmitBtn.textContent = "保存修改";
  els.paymentChannelCancelBtn.hidden = false;
  form.elements.name.focus();
}

function findPaymentChannel(id) {
  if (!id) return null;
  return (appState.page?.payment_channels || []).find((item) => item.id === id) || null;
}

function renderAccounts() {
  const accounts = appState.jpyPage?.accounts || appState.page?.accounts || [];
  els.accountRows.innerHTML = accounts.length
    ? accounts
        .map(
          (item) => `
            <div class="settings-item">
              <div>
                <strong>${escapeHtml(item.name)}</strong>
                <span>${labelAccountType(item.account_type)} · 期初 ${money(item.opening_balance || 0)}</span>
              </div>
              <div class="button-row">
                <button class="ghost-button compact-button" data-edit-account="${item.id}" type="button">编辑</button>
                <button class="ghost-button compact-button" data-copy-account="${item.id}" type="button">复制</button>
                <button class="danger-button compact-button" data-deactivate-account="${item.id}" type="button">停用</button>
              </div>
            </div>
          `,
        )
        .join("")
    : `<div class="empty-state">暂无日元账户</div>`;

  document.querySelectorAll("[data-edit-account]").forEach((button) => {
    button.addEventListener("click", () => {
      const account = findJpyAccount(button.dataset.editAccount);
      if (!account) return;
      setAccountForm(account, "edit");
    });
  });

  document.querySelectorAll("[data-copy-account]").forEach((button) => {
    button.addEventListener("click", () => {
      const account = findJpyAccount(button.dataset.copyAccount);
      if (!account) return;
      setAccountForm({ ...account, name: `${account.name} 复制` }, "copy");
    });
  });

  document.querySelectorAll("[data-deactivate-account]").forEach((button) => {
    button.addEventListener("click", async () => {
      const account = findJpyAccount(button.dataset.deactivateAccount);
      if (!account) return;
      const confirmed = window.confirm(`停用「${account.name}」？历史日元流水会保留，但新流水不再使用这个账户。`);
      if (!confirmed) return;
      const ok = await deactivateAccount(account.id);
      if (!ok) return;
      await loadAppData();
      setActionMessage("日元账户已停用，历史流水已保留。", "success");
      render();
    });
  });
}

function setAccountForm(account, mode) {
  const form = els.accountForm;
  appState.editingAccountId = mode === "edit" ? account.id : null;
  form.elements.name.value = account.name || "";
  form.elements.account_type.value = account.account_type || "cash";
  form.elements.opening_balance.value = account.opening_balance ?? "";
  els.accountSubmitBtn.textContent = mode === "edit" ? "保存修改" : "保存为新账户";
  els.accountCancelBtn.hidden = false;
  form.elements.name.focus();
  setActionMessage(mode === "edit" ? "正在编辑日元账户。" : "已复制到账户表单，保存后会成为新账户。", "success");
}

function labelDirection(direction) {
  return direction === "income" ? "收入" : "支出";
}

function labelFixedType(type) {
  return type === "short_term" ? "短期固定" : "长期固定";
}

function labelAccountType(type) {
  const labels = {
    cash: "现金",
    bank: "银行卡",
    investment: "投资账户",
  };
  return labels[type] || type;
}
