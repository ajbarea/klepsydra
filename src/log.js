// The front end's one logger. warn and error go to the console and, inside
// the app, to its log file through tauri-plugin-log's `log` command, so one
// file holds both sides. debug lines appear only while localStorage's
// "klepsydra.debug" is "1". The phone wall has no app, so its lines stay in
// its console.

/** tauri-plugin-log's LogLevel numbers. */
export const LEVELS = { debug: 2, warn: 4, error: 5 };
/** The longest message sent to the log file; the rest is cut. */
export const MAX_CHARS = 2000;
export const DEBUG_KEY = "klepsydra.debug";
/** Repeats remembered per logger; past this many the memory starts over. */
export const REPEAT_KEYS = 200;

/** An error, rejection value or anything else, as one line of text. */
export function describe(err) {
  if (err instanceof Error) return `${err.name}: ${err.message}`;
  if (typeof err === "string") return err;
  try {
    return JSON.stringify(err) ?? String(err);
  } catch {
    return String(err);
  }
}

/**
 * `describe`, with an Error's stack when it has one, for the log file. V8
 * (WebView2) starts a stack with `Name: message`; JavaScriptCore (WebKitGTK)
 * gives only `fn@url:line:col` frames, so those follow the one-line form.
 */
export function detail(err) {
  const one = describe(err);
  const stack = err instanceof Error && typeof err.stack === "string" ? err.stack.trim() : "";
  if (!stack) return one;
  return stack.startsWith(one) ? stack : `${one}\n${stack}`;
}

/** Whether the `n`th sighting of a repeat is logged: the first, then the 10th, 100th, 1000th... */
export const loggedRepeat = (n) => n === 1 || (n >= 10 && /^10*$/.test(String(n)));

function debugFlag(win) {
  try {
    return win?.localStorage?.getItem(DEBUG_KEY) === "1";
  } catch {
    return false;
  }
}

/**
 * A logger for the module at `where` (a path under src/, such as
 * "fleet/wall.js"), which becomes the log line's target `webview::<where>`.
 * `env` replaces the window, console and debug flag, for tests.
 */
export function createLog(where, env = {}) {
  const win = () => env.window ?? globalThis.window;
  const out = () => env.console ?? globalThis.console;
  const debugOn = () => env.debug ?? debugFlag(win());
  const seen = new Map();

  function send(level, message, fields) {
    const invoke = win()?.__TAURI__?.core?.invoke;
    if (typeof invoke !== "function") return;
    const keyValues = fields ? Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, String(v)])) : undefined;
    const args = { level: LEVELS[level], message: message.slice(0, MAX_CHARS), location: where, keyValues };
    try {
      // A log that cannot be written must not disturb the page, nor log again.
      Promise.resolve(invoke("plugin:log|log", args)).catch(() => {});
    } catch {
      // as above
    }
  }

  function line(level, text, err, fields) {
    // Logging never stops the page: a value that cannot be described (a
    // throwing getter, a prototype-less object) drops the line, not the caller.
    try {
      const shown = `klepsydra: ${err === undefined ? text : `${text}: ${describe(err)}`}`;
      if (level === "debug") {
        out().debug(shown);
      } else if (level === "warn") {
        out().warn(shown, ...(err === undefined ? [] : [err]));
      } else {
        out().error(shown, ...(err === undefined ? [] : [err]));
      }
      send(level, err === undefined ? text : `${text}: ${detail(err)}`, fields);
    } catch {
      // as above
    }
  }

  const idOf = (key, err) => {
    try {
      return `${key}\u0000${describe(err)}`;
    } catch {
      return `${key}\u0000`;
    }
  };

  /** `line` for the first sighting of `key` with this cause, then at the 10th, 100th... with the count. */
  function repeat(level, key, text, err, fields) {
    const id = idOf(key, err);
    if (!seen.has(id) && seen.size >= REPEAT_KEYS) seen.clear();
    const n = (seen.get(id) ?? 0) + 1;
    seen.set(id, n);
    if (loggedRepeat(n)) line(level, n === 1 ? text : `${text} (${n} times so far)`, err, fields);
  }

  /** Forget `key`'s repeats: its call worked, so the next failure starts a new episode and is logged. */
  function ok(key) {
    for (const id of seen.keys()) if (id.startsWith(`${key}\u0000`)) seen.delete(id);
  }

  return {
    /** Detail for one problem; dropped unless the debug flag is on. */
    debug: (text, fields) => debugOn() && line("debug", text, undefined, fields),
    /** Unexpected, but the page goes on as before. */
    warn: (text, err, fields) => line("warn", text, err, fields),
    /** One piece of work failed; the page goes on. */
    error: (text, err, fields) => line("error", text, err, fields),
    // The repeat calls are for a failure that can recur on every poll or
    // render. `key` names the call site, and repeats count per key and cause,
    // so neither may embed a changing value (a size, a count, a time); the
    // text may, since only the first and the 10th, 100th... are logged. Call
    // `ok(key)` where that call succeeds, so a failure after a recovery is
    // logged again rather than counted into the old episode.
    /** `warn` for a failure that can recur: logged once per `key` and cause, then at the 10th, 100th... */
    warnRepeat: (key, text, err, fields) => repeat("warn", key, text, err, fields),
    /** `error`, logged as `warnRepeat` is. */
    errorRepeat: (key, text, err, fields) => repeat("error", key, text, err, fields),
    /** `key`'s call worked: its next failure is logged as a new one. */
    ok,
  };
}
