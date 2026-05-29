import { bindElements } from "./js/elements.js?v=20260530-responsive-3";
import { bindEvents } from "./js/events.js?v=20260530-responsive-3";
import { bindJpyEvents } from "./js/jpy.js?v=20260530-responsive-3";
import { render } from "./js/render.js?v=20260530-responsive-3";
import { initSupabaseClient, loadAppData, refreshSession, setCloudChangeHandler } from "./js/supabase.js?v=20260530-responsive-3";
import { processAuthHash, setActionMessage, setInitialDates } from "./js/ui.js?v=20260530-responsive-3";

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  bindJpyEvents();
  setCloudChangeHandler(render);
  setInitialDates();
  render();
  try {
    await initSupabaseClient();
    await refreshSession();
    processAuthHash();
    await loadAppData();
  } catch (error) {
    setActionMessage(`启动失败：${error.message}`, "error");
  }
  render();
});
