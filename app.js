import { bindElements } from "./js/elements.js?v=20260528-cloud-2";
import { bindEvents } from "./js/events.js?v=20260528-cloud-2";
import { render } from "./js/render.js?v=20260528-cloud-2";
import { initSupabaseClient, loadCloudData, loadMonthPageData, refreshSession, setCloudChangeHandler } from "./js/supabase.js?v=20260528-cloud-2";
import { processAuthHash, setInitialDates } from "./js/ui.js?v=20260528-cloud-2";

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  setCloudChangeHandler(render);
  setInitialDates();
  await initSupabaseClient();
  await refreshSession();
  processAuthHash();
  await loadCloudData();
  await loadMonthPageData();
  render();
});
