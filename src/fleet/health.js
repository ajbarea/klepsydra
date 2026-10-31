// The fleet's health on the wall (#208): a bar button beside CI that says
// whether `fleet doctor` found anything failing, and a popover with each
// check. The view comes from the app (health_subscribe) or, on the phone, with
// each snapshot. Free of the DOM so it can be unit tested; wall.js draws it.

const STATUS = { FAIL: "Failing", warn: "Warning", ok: "OK" };

/** What the bar button and its popover show for health VIEW (health.rs `view`); hidden without one. */
export function healthView(view) {
  const checks = Array.isArray(view?.checks) ? view.checks : null;
  if (!checks) return { hidden: true, label: "", tone: "", title: "", rows: [], note: "" };
  const rows = checks
    .filter((c) => Object.hasOwn(STATUS, c?.status) && typeof c.check === "string" && c.check)
    .map((c) => ({ status: c.status, statusLabel: STATUS[c.status], check: c.check, detail: typeof c.detail === "string" ? c.detail : "" }));
  const failed = rows.filter((r) => r.status === "FAIL").length;
  const warned = rows.filter((r) => r.status === "warn").length;
  const warnings = warned ? `${warned} ${warned === 1 ? "warning" : "warnings"}` : "";
  if (view.stale) {
    return { hidden: false, label: "Fleet ?", tone: "stale", title: "fleet doctor has not run for 15 minutes", rows, note: "The doctor timer has stopped; its last reading is below." };
  }
  if (failed) {
    return { hidden: false, label: `Fleet ${failed} failing`, tone: "red", title: `fleet doctor: ${failed} ${failed === 1 ? "check" : "checks"} failing`, rows, note: warnings };
  }
  return { hidden: false, label: "Fleet ok", tone: warned ? "warn" : "ok", title: warned ? `fleet doctor: ${warnings}` : "fleet doctor: every check ok", rows, note: warnings };
}
