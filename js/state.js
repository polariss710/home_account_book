import { monthKey } from "./utils.js?v=20260529-fixed-4";

export const appState = {
  activeMonth: monthKey(new Date()),
  page: null,
  editingTemplateId: null,
  supabaseClient: null,
  currentUser: null,
};
