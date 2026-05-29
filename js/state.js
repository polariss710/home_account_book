import { monthKey } from "./utils.js?v=20260529-fixed-10";

export const appState = {
  activeMonth: monthKey(new Date()),
  page: null,
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
