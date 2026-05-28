import { monthKey } from "./utils.js?v=20260528-cloud-1";

const defaultData = {
  accounts: [],
  categories: [],
  transactions: [],
  months: {},
  monthPage: null,
};

export const appState = {
  data: structuredClone(defaultData),
  activeMonth: monthKey(new Date()),
  transactionFilter: "all",
  supabaseClient: null,
  currentUser: null,
};
