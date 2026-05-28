import { STORE_KEY } from "./config.js?v=20260528-db-rpc-1";
import { monthKey } from "./utils.js?v=20260528-db-rpc-1";

const defaultData = {
  accounts: [],
  categories: [],
  transactions: [],
  months: {},
  monthPage: null,
};

export const appState = {
  data: loadLocal(),
  activeMonth: monthKey(new Date()),
  transactionFilter: "all",
  supabaseClient: null,
  currentUser: null,
};

export function loadLocal() {
  try {
    return { ...defaultData, ...JSON.parse(localStorage.getItem(STORE_KEY) || "{}") };
  } catch {
    return structuredClone(defaultData);
  }
}

export function saveLocal() {
  localStorage.setItem(STORE_KEY, JSON.stringify(appState.data));
}
