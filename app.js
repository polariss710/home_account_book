import { bindElements } from "#elements";
import { bindCnyEvents } from "#cny";
import { bindEvents } from "#events";
import { bindFixedTransferEvents } from "#fixed-transfer";
import { bindJpyEvents } from "#jpy";
import { render } from "#render";
import { initSupabaseClient, loadAppData, refreshSession, setCloudChangeHandler } from "#supabase";
import { processAuthHash, setActionMessage, setInitialDates } from "#ui";

document.addEventListener("DOMContentLoaded", async () => {
  bindElements();
  bindEvents();
  bindFixedTransferEvents(render);
  bindJpyEvents();
  bindCnyEvents();
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
