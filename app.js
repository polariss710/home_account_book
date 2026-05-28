import { bindElements } from "./js/elements.js?v=20260529-form-1";
import { bindEvents } from "./js/events.js?v=20260529-form-1";
import { render } from "./js/render.js?v=20260529-form-1";
import { initSupabaseClient, loadCloudData, refreshSession, setCloudChangeHandler } from "./js/supabase.js?v=20260529-form-1";
import { processAuthHash, setActionMessage, setInitialDates } from "./js/ui.js?v=20260529-form-1";

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
  } catch (error) {
    setActionMessage(`启动失败：${error.message}`, "error");
  }
  render();
});
