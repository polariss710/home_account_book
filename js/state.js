import { monthKey } from "./utils.js?v=20260529-fixed-2";

export const appState = {
  activeMonth: monthKey(new Date()),
  page: null,
  supabaseClient: null,
  currentUser: null,
};
