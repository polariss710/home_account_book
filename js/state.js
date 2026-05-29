import { monthKey } from "./utils.js?v=20260529-fixed-3";

export const appState = {
  activeMonth: monthKey(new Date()),
  page: null,
  supabaseClient: null,
  currentUser: null,
};
