import { bindElements } from "./js/elements.js";
import { bindEvents } from "./js/events.js";
import { render } from "./js/render.js";
import { initSupabaseClient, loadCloudData, loadMonthPageData, refreshSession, setCloudChangeHandler, syncAllToCloud } from "./js/supabase.js";
import { processAuthHash, setInitialDates, warnIfFileMode } from "./js/ui.js";

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  setCloudChangeHandler(render);
  setInitialDates();
  await initSupabaseClient();
  warnIfFileMode();
  await refreshSession();
  processAuthHash();
  await syncAllToCloud({ silent: true });
  await loadCloudData();
  await loadMonthPageData();
  render();
});
