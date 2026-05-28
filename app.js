import { bindElements } from "./js/elements.js?v=20260528-cloud-4";
import { bindEvents } from "./js/events.js?v=20260528-cloud-4";
import { render } from "./js/render.js?v=20260528-cloud-4";
import { initSupabaseClient, loadCloudData, loadMonthPageData, refreshSession, setCloudChangeHandler } from "./js/supabase.js?v=20260528-cloud-4";
import { processAuthHash, setActionMessage, setInitialDates } from "./js/ui.js?v=20260528-cloud-4";

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  setCloudChangeHandler(render);
  setInitialDates();
  render();
  try {
    await initSupabaseClient();
    await refreshSession();
    processAuthHash();
    await loadCloudData();
    await loadMonthPageData();
  } catch (error) {
    setActionMessage(`启动失败：${error.message}`, "error");
  }
  render();
});
