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

/** `describe`, with an Error's stack when it has one, for the log file. */
export function detail(err) {
  const stack = err instanceof Error && typeof err.stack === "string" ? err.stack : "";
  return stack.includes(err?.message ?? "") && stack.includes("\n") ? stack : describe(err);
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
    const shown = `klepsydra: ${err === undefined ? text : `${text}: ${describe(err)}`}`;
    if (level === "debug") {
      out().debug(shown);
    } else if (level === "warn") {
      out().warn(shown, ...(err === undefined ? [] : [err]));
    } else {
      out().error(shown, ...(err === undefined ? [] : [err]));
    }
    send(level, err === undefined ? text : `${text}: ${detail(err)}`, fields);
  }

  /** `line` for the first sighting of `key` with this cause, then at the 10th, 100th... with the count. */
  function repeat(level, key, text, err, fields) {
    const id = `${key}\u0000${describe(err)}`;
    if (!seen.has(id) && seen.size >= REPEAT_KEYS) seen.clear();
    const n = (seen.get(id) ?? 0) + 1;
    seen.set(id, n);
    if (loggedRepeat(n)) line(level, n === 1 ? text : `${text} (${n} times so far)`, err, fields);
  }

  return {
    /** Detail for one problem; dropped unless the debug flag is on. */
    debug: (text, fields) => debugOn() && line("debug", text, undefined, fields),
    /** Unexpected, but the page goes on as before. */
    warn: (text, err, fields) => line("warn", text, err, fields),
    /** One piece of work failed; the page goes on. */
    error: (text, err, fields) => line("error", text, err, fields),
    /** `warn` for a failure that can recur on every poll or render: logged once per `key` and cause, then at the 10th, 100th... */
    warnRepeat: (key, text, err, fields) => repeat("warn", key, text, err, fields),
    /** `error`, logged as `warnRepeat` is. */
    errorRepeat: (key, text, err, fields) => repeat("error", key, text, err, fields),
  };
}
