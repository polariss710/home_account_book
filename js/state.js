import { monthKey } from "./utils.js?v=20260529-fixed-6";

export const appState = {
  activeMonth: monthKey(new Date()),
  page: null,
  editingTemplateId: null,
  stoppedTemplatesExpanded: false,
  supabaseClient: null,
  currentUser: null,
};
