// The phone wall stays dark in either scheme (#247). A classic script in the
// head, so `.served` is on before the first paint and a light-scheme phone
// never flashes the parchment wall before wall.js loads. The test is feed.js's
// feedKind() === "served" (fleet-phone.test.js checks they agree): not the
// app, not ?demo, and the page served at "/".
(() => {
  const app = Boolean(window.__TAURI_INTERNALS__ ?? window.__TAURI__);
  const served = !app && !new URLSearchParams(location.search).has("demo") && location.pathname === "/";
  document.documentElement.classList.toggle("served", served);
  if (!served) return;
  for (const m of document.querySelectorAll('meta[name="theme-color"]')) {
    if (m.media.includes("light")) m.remove();
    else m.removeAttribute("media");
  }
})();
