// Gauge strip mockups (#421, #438). One renderer per variant, three layouts
// each (NVIDIA's linear, double and stacked), fed by readings.js.
// window.STRIP.page(variant) fills <main id="sheet">.

(() => {
  const S = window.SNAP;
  const ICON = window.ICON;

  const pctOf = (w) => `${Math.round(w.pct)}%`;
  const spoken = (a) => {
    if (a.placeholder) return `${a.name}: no reading yet`;
    const L = window.lead(a);
    const parts = (a.windows || []).filter((w) => !(L.out && w.key === "five_hour")).map((w) => `${w.label} ${pctOf(w)}${w.pct >= 100 && w.at ? `, out until ${w.at}` : w.at ? `, resets ${w.at}` : ""}`);
    return `${a.name}${L.out ? `, out until ${L.w.at}` : ""}: ${parts.join("; ")}`;
  };
  const isRoute = (a, opt) => opt.route !== false && a.route;
  const ageState = (a) => (a.ageMin >= window.staleAt ? "stale" : a.ageMin >= 30 ? "aged" : "");
  // A chip names its age only once the reading is stale; the stacked layout and the hover always do.
  const ageTag = (a, always) => ((always ? window.ageText(a.ageMin) : ageState(a) === "stale") ? `<span class="age">${window.ageText(a.ageMin)}</span>` : "");

  /* ── Variant A: Readout. Text first, NVIDIA HUD grammar: icon, bold value,
        plain reset, tiny pips for the other windows, | between accounts. ── */
  const pip = (w, lead) =>
    `<span class="pip b-${window.band(w.pct)}${w.pct >= 100 ? " full" : ""}${lead ? " lead" : ""}" style="--p:${Math.min(100, w.pct)}" title="${w.label} ${pctOf(w)}"></span>`;
  const pipsA = (a, L) => `<span class="pips" aria-hidden="true">${[L.w, ...L.rest].map((w, i) => pip(w, i === 0)).join("")}</span>`;

  const itemA = (a, opt = {}) => {
    const cls = ["ra", ageState(a), isRoute(a, opt) ? "route" : ""].filter(Boolean).join(" ");
    if (a.placeholder)
      return `<div class="ra ph" role="group" aria-label="${spoken(a)}">${window.iconHTML(a)}<b class="val">–</b><span class="when">no reading yet</span></div>`;
    const L = window.lead(a);
    const val = L.out ? `<b class="val">out</b><span class="when">until ${L.w.at}</span>` : `<b class="val">${pctOf(L.w)}</b><span class="when">${L.w.in || "–"}</span>`;
    const rt = isRoute(a, opt) ? `<span class="rt">route</span>` : "";
    return `<div class="${cls}${L.out ? " out" : ""}" role="group" aria-label="${spoken(a)}">${window.iconHTML(a)}${val}${pipsA(a, L)}${ageTag(a)}${rt}</div>`;
  };

  const rowA = (a, opt = {}) => {
    if (a.placeholder)
      return `<div class="sa-row ph" role="group" aria-label="${spoken(a)}">${window.iconHTML(a)}<span class="nm">${a.name}</span><span class="cell wide">no reading yet</span></div>`;
    const L = window.lead(a);
    const cell = (w) => {
      if (!w) return `<span class="cell"></span>`;
      if (L.out && w.key === "five_hour") return `<span class="cell hidden-win">session hidden</span>`;
      const gone = w.pct >= 100;
      return `<span class="cell${w.group ? " grp" : ""}"><span class="k">${w.group ? w.label.toLowerCase() : w.key === "five_hour" ? "session" : "week"}</span><b>${gone ? "out" : pctOf(w)}</b><span class="t">${gone ? `until ${w.at}` : w.in || "–"}</span>${pip(w, false)}</span>`;
    };
    const ws = a.windows;
    const cls = ["sa-row", ageState(a), isRoute(a, opt) ? "route" : "", L.out ? "out" : ""].filter(Boolean).join(" ");
    return `<div class="${cls}" role="group" aria-label="${spoken(a)}">${window.iconHTML(a)}<span class="nm">${a.name}${ageTag(a, true)}${isRoute(a, opt) ? `<span class="rt">route · ${a.route.says}</span>` : ""}</span>${cell(ws.find((w) => w.key === "five_hour"))}${cell(ws.find((w) => w.key === "seven_day"))}${cell(ws.find((w) => w.group))}</div>`;
  };

  /* ── Variant B: Dial. The account logo sits inside a ring for its tightest
        window; other windows are hairline bars; faces dock to their account. ── */
  const ring = (a, w, size, out) => {
    const r = 10.5, c = 2 * Math.PI * r, p = w ? Math.min(100, w.pct) : 0;
    const b = w ? window.band(w.pct) : "low";
    return `<span class="ring b-${b}${out ? " full" : ""}" style="--sz:${size}px" aria-hidden="true"><svg viewBox="0 0 24 24"><circle class="tr" cx="12" cy="12" r="${r}"/>${p > 0 ? `<circle class="fl" cx="12" cy="12" r="${r}" stroke-dasharray="${(c * p) / 100} ${c}"/>` : ""}</svg>${window.iconHTML(a)}</span>`;
  };
  const barsB = (a, L) =>
    `<span class="hbars" aria-hidden="true">${[L.w, ...L.rest].map((w) => `<span class="hb b-${window.band(w.pct)}${w.pct >= 100 ? " full" : ""}" style="--p:${Math.min(100, w.pct)}" title="${w.label} ${pctOf(w)}"></span>`).join("")}</span>`;
  const faces = (a) => (a.faces ? `<span class="faces">${a.faces.map(window.FACE).join("")}</span>` : "");

  const itemB = (a, opt = {}) => {
    if (a.placeholder)
      return `<div class="rb ph" role="group" aria-label="${spoken(a)}">${ring(a, null, opt.ring || 28)}<span class="txt"><span class="l1"><b class="val">–</b></span><span class="l2">no reading yet</span></span></div>`;
    const L = window.lead(a);
    const cls = ["rb", ageState(a), isRoute(a, opt) ? "route" : "", L.out ? "out" : ""].filter(Boolean).join(" ");
    const l1 = L.out ? `<b class="val">out</b><span class="when">until ${L.w.at}</span>` : `<b class="val">${pctOf(L.w)}</b><span class="when">${L.w.in || "–"}</span>`;
    const l2 = `${barsB(a, L)}${ageTag(a)}${isRoute(a, opt) ? `<span class="rt">route</span>` : ""}`;
    return `<div class="${cls}" role="group" aria-label="${spoken(a)}">${ring(a, L.w, opt.ring || 28, L.out)}<span class="txt"><span class="l1">${l1}</span><span class="l2">${l2}</span></span>${opt.faces === false ? "" : faces(a)}</div>`;
  };

  const rowB = (a, opt = {}) => {
    if (a.placeholder)
      return `<div class="sb-row ph" role="group" aria-label="${spoken(a)}">${ring(a, null, 36)}<span class="body"><span class="nm">${a.name}</span><span class="line"><span class="lbl">No reading yet</span></span></span></div>`;
    const L = window.lead(a);
    const line = (w) => {
      if (L.out && w.key === "five_hour") return "";
      const gone = w.pct >= 100;
      const lbl = w.label;
      return `<span class="line${w.group ? " grp" : ""}"><span class="lbl">${lbl}</span><span class="track"><span class="fill b-${window.band(w.pct)}" style="--p:${Math.min(100, w.pct)}"></span></span><b>${gone ? "out" : pctOf(w)}</b><span class="t">${gone ? `until ${w.at}` : w.in ? `in ${w.in}` : "–"}</span></span>`;
    };
    const cls = ["sb-row", ageState(a), isRoute(a, opt) ? "route" : "", L.out ? "out" : ""].filter(Boolean).join(" ");
    return `<div class="${cls}" role="group" aria-label="${spoken(a)}">${ring(a, L.w, 36, L.out)}<span class="body"><span class="nm">${a.name}${ageTag(a, true)}${isRoute(a, opt) ? `<span class="rt">route · ${a.route.says}</span>` : ""}${faces(a)}</span>${[L.w, ...L.rest].sort((x, y) => (a.windows.indexOf(x) - a.windows.indexOf(y))).map(line).join("")}</span></div>`;
  };

  /* ── Layout wrappers ── */
  const grip = `<span class="grip" aria-hidden="true">${ICON.grip}</span>`;
  const strip = (v, layout, accts, opt = {}) => {
    const op = opt.op ?? 100;
    // The halo threshold follows the panel: at 50% a dark panel over a light desktop
    // drops body text to 3.3:1, while a light panel at 50% keeps its dark ink crisp.
    const light = document.documentElement.dataset.theme === "light";
    const haloAt = light ? 50 : 60;
    const halo = op < haloAt ? " halo" : op < 70 ? " thin" : "";
    const item = v === "a" ? itemA : itemB;
    const row = v === "a" ? rowA : rowB;
    const body =
      layout === "stacked" ? accts.map((a) => row(a, opt)).join("") : accts.map((a) => item(a, opt)).join("") + (opt.sys ? (v === "a" ? sysA(opt.sys) : sysB(opt.sys)) : "");
    return `<div class="panel strip v${v} ${layout}${halo}" data-op="${op}" style="--op:${op}" role="group" aria-label="Usage, ${layout} layout">${layout === "stacked" ? "" : grip}<div class="items">${body}</div></div>`;
  };


  /* ── System chip (#421, AJ 11-18): optional, off by default. WSL RAM, CPU,
        GPU load with VRAM; a tap toggles % and GB. Same grammar per variant. ── */
  const Y = window.SYS;
  const sysSpoken = `System: WSL memory ${Y.ram.used.toFixed(1)} of ${Y.ram.total.toFixed(1)} GB, ${Y.ram.pct}%; CPU ${Y.cpu.pct}%; GPU ${Y.gpu.pct}%, VRAM ${Y.vram.used.toFixed(1)} of ${Y.vram.total.toFixed(1)} GB`;
  const metrics = (mode) => [
    { k: "ram", pct: Y.ram.pct, v: mode === "gb" ? `${Y.ram.used.toFixed(1)}` : `${Y.ram.pct}%`, of: mode === "gb" ? `/${Y.ram.total.toFixed(1)} GB` : "" },
    { k: "cpu", pct: Y.cpu.pct, v: `${Y.cpu.pct}%`, of: "" },
    { k: "gpu", pct: Y.gpu.pct, v: `${Y.gpu.pct}%`, of: "" },
    { k: "vram", pct: Y.vram.pct, v: mode === "gb" ? `${Y.vram.used.toFixed(1)}` : `${Y.vram.pct}%`, of: mode === "gb" ? `/${Y.vram.total.toFixed(1)} GB` : "" },
  ];
  const sysA = (mode = "pct") =>
    `<div class="ra sys" role="button" tabindex="0" aria-label="${sysSpoken}. Activate to show ${mode === "gb" ? "percent" : "gigabytes"}."><span class="ico">${ICON.chip}</span>${metrics(mode)
      .map((m) => `<span class="sm"><span class="k">${m.k}</span><b class="val">${m.v}</b>${m.of ? `<span class="of">${m.of}</span>` : ""}${pip({ pct: m.pct, label: m.k }, false)}</span>`)
      .join("")}</div>`;
  const sysB = (mode = "pct") => {
    const [ram, ...rest] = metrics(mode);
    return `<div class="rb sys" role="button" tabindex="0" aria-label="${sysSpoken}. Activate to show ${mode === "gb" ? "percent" : "gigabytes"}.">${ring({ icon: "chip" }, { pct: ram.pct }, 28)}<span class="txt"><span class="l1"><b class="val">${ram.v}</b><span class="when">${ram.of ? `of ${ram.of.slice(1)} ` : ""}ram</span></span><span class="l2">${rest
      .map((m) => `<span class="sk">${m.k} <b>${m.v}</b>${m.of}</span>`)
      .join("")}</span></span></div>`;
  };
  const sysDetail = () => {
    const row = (label, pct, text) =>
      `<tr><th scope="row">${label}</th><td><span class="track"><span class="fill b-${window.band(pct)}" style="--p:${pct}"></span></span></td><td class="n">${pct}%</td><td>${text}</td></tr>`;
    return `<div class="detail panel" data-op="100" style="--op:100" role="tooltip"><div class="dh"><span class="ico">${ICON.chip}</span><b>System</b><span class="age">${Y.takenAt}</span></div><table>${row("WSL memory", Y.ram.pct, `${Y.ram.used.toFixed(1)} of ${Y.ram.total.toFixed(1)} GB · ${(Y.ram.total - Y.ram.used).toFixed(1)} GB free`)}${row("Fleet slice", Y.fleet.pct, `${Y.fleet.used.toFixed(1)} of its ${Y.fleet.cap.toFixed(1)} GB cap`)}${row("CPU", Y.cpu.pct, `${Y.cpu.cores} cores`)}${row("GPU", Y.gpu.pct, Y.gpu.name)}${row("VRAM", Y.vram.pct, `${Y.vram.used.toFixed(1)} of ${Y.vram.total.toFixed(1)} GB`)}<tr class="note"><td colspan="4">Sampled once a second while on screen. Tap the chip to switch % and GB.</td></tr></table></div>`;
  };

  const detail = (a) => {
    const rows = a.windows
      .map((w) => {
        const gone = w.pct >= 100;
        return `<tr class="${w.group ? "grp" : ""}"><th scope="row">${w.label}</th><td><span class="track"><span class="fill b-${window.band(w.pct)}" style="--p:${Math.min(100, w.pct)}"></span></span></td><td class="n">${pctOf(w)}</td><td>${gone ? `out until ${w.at}` : `resets ${w.at}`}</td></tr>${w.note ? `<tr class="note"><td colspan="4">${w.note}</td></tr>` : ""}`;
      })
      .join("");
    return `<div class="detail panel" data-op="100" style="--op:100" role="tooltip"><div class="dh">${window.iconHTML(a)}<b>${a.name}</b><span class="age">read ${a.ageMin} min ago</span>${a.route ? `<span class="rt">route · ${a.route.says} session</span>` : ""}</div><table>${rows}</table></div>`;
  };

  const wpFor = () => (document.documentElement.dataset.theme === "light" ? "wp-light" : "wp-dark");
  const wpName = { "wp-dark": "dark desktop", "wp-light": "light desktop", "wp-busy": "busy wallpaper" };
  const tile = (wp, inner, extra = "") => `<div class="wp ${wp} ${extra}"><span class="wp-name">${wpName[wp]}</span>${inner}</div>`;

  const COPY = {
    a: {
      name: "Strip A: Readout",
      linear: "Linear: one row, 47 px tall, fits a 48 px taskbar",
      trade:
        "Text first, like NVIDIA's HUD: logo, bold value, reset, a pip per window. It needs no background, so it still reads at 0% opacity. A pip is a smaller cue than today's ring.",
    },
    b: {
      name: "Strip B: Dial",
      linear: "Linear: one row, 56 px tall, so it overhangs a 48 px taskbar",
      trade:
        "Today's ring, now one per account with the logo inside it, a hairline bar per window, and each account's agents docked beside it. Strongest at a glance, but it needs a panel or a heavy halo.",
    },
  };

  window.STRIP = {
    page(v) {
      const A = S.accounts;
      const me = document.getElementById("sheet");
      const wp = wpFor();
      const c = COPY[v];
      me.innerHTML = `
<header><h1>${c.name}</h1><p class="trade">${c.trade}</p><p class="stamp">Readings: ${S.takenAt}</p></header>

<h2>Three layouts, one switch</h2>
<p>NVIDIA's HUD offers the same three. Linear replaces Compact, stacked replaces Comfortable, and double is new, for a screen corner.</p>
<div class="layouts">
  <figure class="ly-linear">${tile(wp, strip(v, "linear", A), "measure")}<figcaption class="cap">${c.linear}</figcaption></figure>
  <figure>${tile(wp, strip(v, "double", A))}<figcaption class="cap">Double: two rows, for a corner</figcaption></figure>
  <figure>${tile(wp, strip(v, "stacked", A))}<figcaption class="cap">Stacked: one account per line, every window shown</figcaption></figure>
</div>

<h2>Background opacity: 100, 50 and 0%</h2>
<p>Below 60% (dark theme) or 50% (light theme) the text switches to light ink with a dark halo; between that and 70%, faint text turns full ink. A dark panel at 50% over a light desktop would otherwise leave body text near 3:1.</p>
<div class="opgrid">
  ${["wp-dark", "wp-light", "wp-busy"].map((w) => [100, 50, 0].map((op) => `<figure>${tile(w, strip(v, "double", A, { op }))}<figcaption class="cap">${op}% · ${wpName[w]}</figcaption></figure>`).join("")).join("")}
</div>
<figure class="wide">${tile("wp-busy", strip(v, "linear", A, { op: 0 }))}<figcaption class="cap">Linear at 0% over the busy wallpaper, the hardest case</figcaption></figure>

<h2>States</h2>
<p>Real readings except where a caption names an earlier one. Colour is never the only cue: each state also has a word or a shape.</p>
<div class="states">
  <figure>${tile(wp, strip(v, "linear", [S.states.ritOut], { route: false }))}<figcaption class="cap"><b>Out until reset.</b> RIT at 3:48 AM today: week 100%, so the session is hidden.</figcaption></figure>
  <figure>${tile(wp, strip(v, "linear", [S.states.agyStale], { route: false }))}<figcaption class="cap"><b>Old reading.</b> agy on 11-17, 10 h old. It dims and shows its age instead of turning red.</figcaption></figure>
  <figure>${tile(wp, strip(v, "linear", [A[1]]))}<figcaption class="cap"><b>No reading yet.</b> Copilot until its readings land (#323).</figcaption></figure>
  <figure>${tile(wp, strip(v, "linear", [A[0]]))}<figcaption class="cap"><b>One route.</b> agy Gemini, by the free-first order (#411). The spent claude/gpt pool stays a full pip and never leads the chip.</figcaption></figure>
</div>
<figure class="hover">${tile(wp, `<div class="hover-demo">${strip(v, "linear", A)}${detail(A[0])}</div>`)}<figcaption class="cap">Hover or tap a chip: every window, with its reset and the age of its reading.</figcaption></figure>

<h2>System chip (optional, off by default)</h2>
<p>Switched on in Settings, one chip joins the end of the strip: WSL memory, CPU, and GPU load paired with VRAM. A tap switches percent and GB. Real numbers from ${Y.takenAt}. No FPS.</p>
<figure class="wide">${tile(wp, strip(v, "linear", A, { sys: "pct" }))}<figcaption class="cap">Linear with the System chip on</figcaption></figure>
<div class="layouts" style="margin-top:18px">
  <figure>${tile(wp, `<div class="panel strip v${v} linear" data-op="100" style="--op:100"><div class="items">${v === "a" ? sysA("pct") : sysB("pct")}</div></div>`)}<figcaption class="cap">Percent (default)</figcaption></figure>
  <figure>${tile(wp, `<div class="panel strip v${v} linear" data-op="100" style="--op:100"><div class="items">${v === "a" ? sysA("gb") : sysB("gb")}</div></div>`)}<figcaption class="cap">GB, after a tap</figcaption></figure>
</div>
<figure class="hover">${tile(wp, `<div class="hover-demo">${strip(v, "linear", A, { sys: "pct" })}<div class="sys-detail-wrap">${sysDetail()}</div></div>`)}<figcaption class="cap">Hover the System chip: the fleet slice's own cap (the limit the fleet hits first) beside WSL's total.</figcaption></figure>

`;
    },
  };
})();
