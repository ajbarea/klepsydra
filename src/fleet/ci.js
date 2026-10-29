// The CI watch on the wall: a button in the bar that says whether any fleet
// repo's CI is red, and a popover listing each red run. The view comes from
// the app (ci_subscribe) or, on the phone, with each snapshot. Free of the DOM
// so it can be unit tested; wall.js draws what this returns.

/** What the bar button and its popover show for CI watch VIEW (ci.rs `view`); hidden without one. */
export function ciView(view) {
  if (!view || typeof view !== "object") return { hidden: true, label: "", tone: "", title: "", rows: [], note: "" };
  const red = Array.isArray(view.red) ? view.red : [];
  const repos = Number(view.repos) || 0;
  const later = Number(view.dependabot) || 0;
  const unread = Number(view.unread) || 0;
  const rows = red.map((r) => ({
    head: [r.repo, r.workflow, r.pr ? `PR #${r.pr}` : r.branch].filter(Boolean).join(" · "),
    step: [r.failing?.job, r.failing?.step].filter(Boolean).join(" › "),
    cause: r.triage?.state === "done" ? [r.triage.cause, r.triage.location && `(${r.triage.location})`].filter(Boolean).join(" ") : triageNote(r.triage?.state),
    url: typeof r.url === "string" && r.url.startsWith("https://github.com/") ? r.url : null,
  }));
  const extras = [later && `${later} Dependabot ${later === 1 ? "run" : "runs"} for the morning`, unread && `${unread} ${unread === 1 ? "repo" : "repos"} not read`].filter(Boolean);
  if (view.stale) {
    return { hidden: false, label: "CI ?", tone: "stale", title: "The CI watch has not reported for 15 minutes", rows, note: "The CI watch has stopped reporting; its last reading is below." };
  }
  if (rows.length) {
    return { hidden: false, label: `CI ${rows.length} red`, tone: "red", title: `${rows.length} red CI ${rows.length === 1 ? "run" : "runs"} across ${repos} repos`, rows, note: extras.join("; ") };
  }
  return { hidden: false, label: "CI ok", tone: "ok", title: `CI green across ${repos} repos`, rows, note: extras.join("; ") || `Green across ${repos} repos.` };
}

function triageNote(state) {
  if (state === "unavailable") return "Not triaged: ci-audit's report mode is not installed.";
  if (state === "failed") return "Triage failed; open the run.";
  return "Triage pending.";
}
