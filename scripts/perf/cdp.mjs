// Reads render cost from a klepsydra test copy's WebView2 over the Chrome
// DevTools Protocol. Runs under Windows Node (22+, for the global WebSocket),
// against a copy started with
// WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS=--remote-debugging-port=<port>.
//
//   node cdp.mjs <port> targets
//   node cdp.mjs <port> idle <page> <seconds>       renderer main-thread time over a quiet span
//   node cdp.mjs <port> cold <page> <cards>         reload; ms until <cards> cards are drawn
//   node cdp.mjs <port> update <page> <session-file> main-thread work after that file changes
//   node cdp.mjs <port> openwall gauge              open the card wall through the app's own command
//   node cdp.mjs <port> eval <page> <expression>    (PowerShell 5.1 strips double quotes from it)
//
// <page> is "wall" for the card wall, anything else for the gauge.
// Each command prints one JSON line.

const [port, cmd, page, arg] = process.argv.slice(2);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
/** One JSON line on stdout: this command's result. */
const print = (v) => process.stdout.write(`${JSON.stringify(v)}\n`);

async function connect(part) {
  const list = await (await fetch(`http://127.0.0.1:${port}/json`)).json();
  if (cmd === "targets") return list;
  const wall = (x) => x.url.includes("wall.html");
  const t = list.find((x) => x.type === "page" && (part === "wall" ? wall(x) : !wall(x)));
  if (!t) throw new Error(`no ${part} page: ${list.map((x) => x.url).join(", ")}`);
  const ws = new WebSocket(t.webSocketDebuggerUrl);
  await new Promise((ok, bad) => { ws.onopen = ok; ws.onerror = bad; });
  let id = 0;
  const waiting = new Map();
  ws.onmessage = (m) => {
    const msg = JSON.parse(m.data);
    if (msg.id && waiting.has(msg.id)) {
      const { ok, bad } = waiting.get(msg.id);
      waiting.delete(msg.id);
      msg.error ? bad(new Error(JSON.stringify(msg.error))) : ok(msg.result);
    }
  };
  const send = (method, params = {}) => new Promise((ok, bad) => {
    waiting.set(++id, { ok, bad });
    ws.send(JSON.stringify({ id, method, params }));
  });
  return { send, close: () => ws.close() };
}

async function metrics(c) {
  const { metrics } = await c.send("Performance.getMetrics");
  return Object.fromEntries(metrics.map((m) => [m.name, m.value]));
}

const KEYS = ["TaskDuration", "ScriptDuration", "LayoutDuration", "RecalcStyleDuration", "LayoutCount", "RecalcStyleCount"];
const delta = (a, b) => Object.fromEntries(KEYS.map((k) => [k, +(b[k] - a[k]).toFixed(4)]));
async function evalIn(c, expression) {
  const r = await c.send("Runtime.evaluate", { expression, returnByValue: true, awaitPromise: true });
  if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
  return r.result.value;
}

async function main() {
  const c = await connect(page);
  if (cmd === "targets") return print(c.map((t) => ({ type: t.type, url: t.url })));
  await c.send("Performance.enable", { timeDomain: "threadTicks" });
  if (cmd === "idle") {
    const a = await metrics(c);
    await sleep(Number(arg) * 1000);
    const b = await metrics(c);
    print({ page, seconds: Number(arg), ...delta(a, b), JSHeapUsedMB: +(b.JSHeapUsedSize / 2 ** 20).toFixed(2), Nodes: b.Nodes });
  } else if (cmd === "cold") {
    const want = Number(arg);
    // Navigation start to N cards in the DOM, read only from the new document
    // (a poll that reached the old page would report its age).
    const origin = await evalIn(c, "performance.timeOrigin");
    await c.send("Page.enable");
    await c.send("Page.reload", { ignoreCache: false });
    const t0 = Date.now();
    let at = null;
    while (Date.now() - t0 < 20_000) {
      await sleep(10);
      try {
        at = await evalIn(c, `performance.timeOrigin !== ${origin} && document.querySelectorAll("#wall article.card").length >= ${want} ? performance.now() : null`);
      } catch { at = null; }
      if (at !== null) break;
    }
    await sleep(2000); // arrivals settle before the heap is read
    const b = await metrics(c);
    print({ page, cards: want, msToCards: at === null ? null : +at.toFixed(1), JSHeapUsedMB: +(b.JSHeapUsedSize / 2 ** 20).toFixed(2), Nodes: b.Nodes });
  } else if (cmd === "update") {
    // Rewrites one session file the way the hook does (temp file, then a
    // rename over it) with a new reply; the reader's watcher sees it within
    // its 75 ms coalesce, so 3 s holds the whole update. A quiet 3 s just
    // before is the baseline to subtract.
    const fs = await import("node:fs");
    const q0 = await metrics(c);
    await sleep(3000);
    const q1 = await metrics(c);
    const body = JSON.parse(fs.readFileSync(arg, "utf8"));
    const now = Math.floor(Date.now() / 1000);
    const mark = `Measured ${Date.now()}`;
    body.reply = { text: `${mark}: the wall redraws this card.`, at: now };
    body.state = "working"; body.state_at = now; body.written_at = now;
    const t0 = Date.now();
    fs.writeFileSync(arg + ".tmp", JSON.stringify(body));
    fs.renameSync(arg + ".tmp", arg);
    // The reading counts only once the card shows the new reply.
    let shown = null;
    while (Date.now() - t0 < 3000) {
      if (await evalIn(c, `document.getElementById("wall").textContent.includes(${JSON.stringify(mark)})`)) { shown = Date.now() - t0; break; }
      await sleep(10);
    }
    await sleep(Math.max(0, 3000 - (Date.now() - t0)));
    const b = await metrics(c);
    print({ page, msToShown: shown, quiet: delta(q0, q1), update: delta(q1, b) });
  } else if (cmd === "openwall") {
    print(await evalIn(c, `window.__TAURI_INTERNALS__.invoke("open_wall", { focus: "" }).then(() => "opened")`));
  } else if (cmd === "eval") {
    print(await evalIn(c, arg));
  }
  c.close();
}

main().catch((e) => { console.error(String(e)); process.exit(1); });
