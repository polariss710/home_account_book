import { bindElements } from "./js/elements.js?v=20260528-cloud-1";
import { bindEvents } from "./js/events.js?v=20260528-cloud-1";
import { render } from "./js/render.js?v=20260528-cloud-1";
import { initSupabaseClient, loadCloudData, loadMonthPageData, refreshSession, setCloudChangeHandler } from "./js/supabase.js?v=20260528-cloud-1";
import { processAuthHash, setInitialDates, warnIfFileMode } from "./js/ui.js?v=20260528-cloud-1";

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  setCloudChangeHandler(render);
  setInitialDates();
  await initSupabaseClient();
  warnIfFileMode();
  await refreshSession();
  processAuthHash();
  await loadCloudData();
  await loadMonthPageData();
  render();
});
