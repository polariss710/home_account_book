import { bindElements } from "./js/elements.js?v=20260529-fixed-6";
import { bindEvents } from "./js/events.js?v=20260529-fixed-6";
import { render } from "./js/render.js?v=20260529-fixed-6";
import { initSupabaseClient, loadFixedMonthPage, refreshSession, setCloudChangeHandler } from "./js/supabase.js?v=20260529-fixed-6";
import { processAuthHash, setActionMessage, setInitialDates } from "./js/ui.js?v=20260529-fixed-6";

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
    await loadFixedMonthPage();
  } catch (error) {
    setActionMessage(`启动失败：${error.message}`, "error");
  }
  render();
});
