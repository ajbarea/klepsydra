//! The phone wall: a read-only HTTP server for the card wall, so a phone on
//! the tailnet can watch the fleet through Tailscale Serve. It listens on the
//! loopback interface only, Serve being the one way in from outside, answers
//! only GET and HEAD, and answers only requests named for loopback or for a
//! tailnet `*.ts.net` name, so a web page cannot reach it through DNS
//! rebinding. Nothing it serves writes anything. Each snapshot carries the
//! fleet and, from a usage source, the statusLine hook's readings for the
//! wall's usage-limit gauges.

use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4};
use std::pin::Pin;
use std::sync::Arc;
use std::task::{Context, Poll};
use std::time::Duration;

use http_body_util::combinators::BoxBody;
use http_body_util::{BodyExt, Empty, Full};
use hyper::body::{Body, Bytes, Frame, Incoming};
use hyper::header::{
    HeaderValue, ACCEPT_RANGES, ALLOW, CACHE_CONTROL, CONNECTION, CONTENT_LENGTH, CONTENT_RANGE,
    CONTENT_SECURITY_POLICY, CONTENT_TYPE, HOST, LOCATION, ORIGIN, RANGE, REFERRER_POLICY,
    X_CONTENT_TYPE_OPTIONS,
};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{Map, Value};
use tokio::sync::{mpsc, oneshot, watch, OwnedSemaphorePermit, Semaphore};

use crate::receiver::{backoff, bind, our_host};

/// Where Tailscale Serve proxies to (`tailscale serve --bg 8318`): loopback
/// only. 8318 is unassigned at IANA, below Windows' dynamic port range
/// (49152 and up), and clear of the OTLP pair 4317/4318 and the usual dev
/// server ports.
pub const ADDR: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8318);

/// How long a connection may take over a request's head, how many
/// connections are served at once, how many of them may hold an event
/// stream, how often a quiet stream sends a comment so no proxy between
/// here and the phone closes it, and how often the usage readings are read.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub header: Duration,
    pub connections: usize,
    pub streams: usize,
    pub heartbeat: Duration,
    pub usage: Duration,
}

pub const LIMITS: Limits = Limits {
    header: Duration::from_secs(10),
    connections: 32,
    streams: 8,
    heartbeat: Duration::from_secs(15),
    // The gauge's POLL_MS (main.js).
    usage: Duration::from_secs(5),
};

/// The app's bundled frontend: the bytes at a path such as `fleet/wall.js`.
pub type Assets = Arc<dyn Fn(&str) -> Option<Vec<u8>> + Send + Sync>;

/// keryx's latest reply clip for a session id (`reply::read`).
pub type Clips = Arc<dyn Fn(&str) -> Option<Vec<u8>> + Send + Sync>;

/// Every usage reading, as `read_usage` gives the gauge (`usage::read`).
pub type Usage = Arc<dyn Fn() -> Vec<Value> + Send + Sync>;

/// `resolve` held to the paths in `known`, the bundle's own (with or
/// without a leading `/`): Tauri's resolver answers a path it lacks with
/// `<path>.html`, `<path>/index.html`, then `index.html`, which would serve
/// the gauge's page as any missing file of the wall.
pub fn exact_assets<K: AsRef<str>>(
    known: impl IntoIterator<Item = K>,
    resolve: impl Fn(&str) -> Option<Vec<u8>> + Send + Sync + 'static,
) -> Assets {
    let known: std::collections::HashSet<String> = known
        .into_iter()
        .map(|k| k.as_ref().trim_start_matches('/').to_string())
        .collect();
    Arc::new(move |path: &str| {
        if known.contains(path) {
            resolve(path)
        } else {
            None
        }
    })
}

/// A session's fields the wall reads, its wrap-up answer and turn among them
/// (shown, never acted on: the phone has no wrap-up buttons). The rest (its
/// tmux pane, Claude process, distro, full launch folder) serve the
/// desktop's actions alone.
const SESSION_FIELDS: [&str; 22] = [
    "session_id",
    "name",
    "voice",
    "status",
    "reason",
    "status_at",
    "active_at",
    "where",
    "touched",
    "prompt",
    "reply",
    "error",
    "updated_at",
    "quiet_since",
    "background",
    "ledger",
    "ledger_partial",
    "remote_url",
    "reply_at",
    "wrapup",
    "turn_at",
    "asked_after_turn",
];

/// The snapshot as the phone gets it: each session cut to `SESSION_FIELDS`,
/// its launch folder to the folder's own name (a card with no name or voice
/// is named by it), the speaking line, and the wall's wrap-up request while
/// one is shown. The receiver's status stays home.
pub fn phone_view(snapshot: &Value) -> Value {
    let sessions: Vec<Value> = snapshot
        .get("sessions")
        .and_then(Value::as_array)
        .map(|all| {
            all.iter()
                .filter_map(Value::as_object)
                .map(|s| {
                    let mut out: Map<String, Value> = SESSION_FIELDS
                        .iter()
                        .filter_map(|k| s.get(*k).map(|v| (k.to_string(), v.clone())))
                        .collect();
                    if let Some(dir) = s.get("launch_dir").and_then(Value::as_str) {
                        let base = dir.trim_end_matches(['/', '\\']);
                        let base = base.rsplit(['/', '\\']).next().unwrap_or("");
                        if !base.is_empty() {
                            out.insert("launch_dir".into(), Value::from(base));
                        }
                    }
                    Value::Object(out)
                })
                .collect()
        })
        .unwrap_or_default();
    let mut out = Map::new();
    out.insert("sessions".into(), Value::Array(sessions));
    out.insert(
        "speaking".into(),
        snapshot.get("speaking").cloned().unwrap_or(Value::Null),
    );
    if let Some(request) = snapshot.get("wrapup").filter(|r| !r.is_null()) {
        out.insert("wrapup".into(), request.clone());
    }
    Value::Object(out)
}

/// What a request asks for.
#[derive(Clone, Debug, PartialEq, Eq)]
enum Route {
    /// A file of the bundled frontend, by its path there.
    Asset(String),
    /// The wall's page by its file name: sent to `/`, the one address where
    /// the page knows it came from this server.
    Home,
    Snapshot,
    Events,
    /// A session's latest spoken reply, by its id.
    Clip(String),
}

/// The parts of a request that decide its answer.
struct Head<'a> {
    method: &'a Method,
    path: &'a str,
    host: Option<&'a str>,
    origin: Option<&'a str>,
    /// Tailscale sets `Tailscale-Funnel-Request` on a request from the open
    /// internet, after deleting any the client sent.
    funnel: bool,
}

/// Whether `host` is a tailnet machine's MagicDNS name, `<machine>.<tailnet>.ts.net`,
/// with or without a port: the Host that Tailscale Serve passes through.
fn tailnet_host(host: &str) -> bool {
    let name = match host.rsplit_once(':') {
        Some((name, port)) => {
            if port.is_empty() || port.len() > 5 || !port.bytes().all(|b| b.is_ascii_digit()) {
                return false;
            }
            name
        }
        None => host,
    };
    let name = name.to_ascii_lowercase();
    let Some(rest) = name.strip_suffix(".ts.net") else {
        return false;
    };
    let labels: Vec<&str> = rest.split('.').collect();
    name.len() <= 253
        && labels.len() >= 2
        && labels.iter().all(|l| {
            !l.is_empty()
                && l.len() <= 63
                && !l.starts_with('-')
                && !l.ends_with('-')
                && l.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-')
        })
}

/// Whether `origin` is the page's own, served as `host` over HTTPS (through
/// Serve) or HTTP (on loopback).
fn same_origin(origin: &str, host: &str) -> bool {
    ["https://", "http://"].iter().any(|scheme| {
        origin
            .strip_prefix(scheme)
            .is_some_and(|rest| rest.eq_ignore_ascii_case(host))
    })
}

/// The frontend files the wall needs, and their types: its page, its
/// folder, the IPC shim, the wheel steps and the gauge's model and rows it
/// shares with the gauge, the vendored markdown-it it imports, the install
/// files and the icons. The gauge's page, the tests and the dev snapshots
/// are not among them.
pub fn asset_type(path: &str) -> Option<&'static str> {
    let root = matches!(
        path,
        "wall.html"
            | "ipc.js"
            | "zoom.js"
            | "gauge.js"
            | "gaugeview.js"
            | "log.js"
            | "manifest.webmanifest"
            | "sw.js"
            | "vendor/markdown-it/markdown-it.esm.min.mjs"
    );
    let folder = path.starts_with("fleet/") || path.starts_with("phone/");
    let clean = !path.is_empty()
        && path.len() <= 200
        && path
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'/'))
        && path
            .split('/')
            .all(|seg| !seg.is_empty() && !seg.starts_with('.'));
    if !(clean && (root || folder)) {
        return None;
    }
    let ext = path.rsplit_once('.').map(|(_, e)| e)?;
    Some(match ext {
        "html" => "text/html; charset=utf-8",
        "js" | "mjs" => "text/javascript; charset=utf-8",
        "css" => "text/css; charset=utf-8",
        "json" => "application/json",
        "webmanifest" => "application/manifest+json",
        "png" => "image/png",
        "webp" => "image/webp",
        "woff2" => "font/woff2",
        _ => return None,
    })
}

fn route(path: &str) -> Option<Route> {
    match path {
        "/" => Some(Route::Asset("wall.html".into())),
        "/wall.html" => Some(Route::Home),
        "/fleet.json" => Some(Route::Snapshot),
        "/events" => Some(Route::Events),
        _ if path.starts_with("/audio/") => {
            let id = &path["/audio/".len()..];
            crate::session::is_session_id(id).then(|| Route::Clip(id.into()))
        }
        _ => {
            let file = path.strip_prefix('/')?;
            asset_type(file).map(|_| Route::Asset(file.into()))
        }
    }
}

/// The answer to a request from its line and headers alone.
fn admit(h: &Head, bound: SocketAddr) -> Result<Route, StatusCode> {
    if h.funnel {
        return Err(StatusCode::FORBIDDEN);
    }
    let host = match h.host {
        Some(host) if our_host(Some(host), bound) || tailnet_host(host) => host,
        _ => return Err(StatusCode::FORBIDDEN),
    };
    if h.origin.is_some_and(|o| !same_origin(o, host)) {
        return Err(StatusCode::FORBIDDEN);
    }
    if h.method != Method::GET && h.method != Method::HEAD {
        return Err(StatusCode::METHOD_NOT_ALLOWED);
    }
    route(h.path).ok_or(StatusCode::NOT_FOUND)
}

type Reply = Response<BoxBody<Bytes, Infallible>>;

/// The page may load only its own files and talk only to its own origin.
const CSP: &str = "default-src 'self'; img-src 'self' data:; style-src 'self' 'unsafe-inline'; connect-src 'self'; manifest-src 'self'; worker-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'";

fn answer(
    status: StatusCode,
    kind: Option<&str>,
    cache: &'static str,
    body: Option<Bytes>,
    head: bool,
) -> Reply {
    let len = body.as_ref().map_or(0, Bytes::len);
    let body = match body {
        Some(b) if !head => Full::new(b).boxed(),
        _ => Empty::new().boxed(),
    };
    let mut r = Response::new(body);
    *r.status_mut() = status;
    let h = r.headers_mut();
    if let Some(kind) = kind.and_then(|k| HeaderValue::from_str(k).ok()) {
        h.insert(CONTENT_TYPE, kind);
        h.insert(CONTENT_LENGTH, HeaderValue::from(len));
    }
    h.insert(CACHE_CONTROL, HeaderValue::from_static(cache));
    h.insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
    h.insert(REFERRER_POLICY, HeaderValue::from_static("no-referrer"));
    h.insert(CONTENT_SECURITY_POLICY, HeaderValue::from_static(CSP));
    match status {
        StatusCode::METHOD_NOT_ALLOWED => {
            h.insert(ALLOW, HeaderValue::from_static("GET, HEAD"));
        }
        // A refused caller gets nothing more read from it.
        StatusCode::FORBIDDEN => {
            h.insert(CONNECTION, HeaderValue::from_static("close"));
        }
        _ => {}
    }
    r
}

fn refuse(status: StatusCode) -> Reply {
    answer(status, None, "no-store", None, false)
}

/// One snapshot as a server-sent event. Compact JSON holds no newline, so it
/// is one `data:` line.
fn event(json: &Bytes) -> Bytes {
    let mut out = Vec::with_capacity(json.len() + 8);
    out.extend_from_slice(b"data: ");
    out.extend_from_slice(json);
    out.extend_from_slice(b"\n\n");
    Bytes::from(out)
}

const HEARTBEAT: &[u8] = b": keepalive\n\n";
/// How long the browser waits before it reconnects a dropped stream.
const RETRY: &[u8] = b"retry: 3000\n\n";

/// An event stream's body: what its feeder task sends, while it holds one
/// of the stream slots.
struct Stream {
    rx: mpsc::Receiver<Bytes>,
    _slot: OwnedSemaphorePermit,
}

impl Body for Stream {
    type Data = Bytes;
    type Error = Infallible;

    fn poll_frame(
        mut self: Pin<&mut Self>,
        cx: &mut Context<'_>,
    ) -> Poll<Option<Result<Frame<Bytes>, Infallible>>> {
        self.rx.poll_recv(cx).map(|b| b.map(|b| Ok(Frame::data(b))))
    }
}

/// Feed one stream: the latest snapshot at once, then each new one, and a
/// comment whenever `heartbeat` passes without one. Ends when the phone
/// goes, which drops the body and so the channel.
async fn feed(
    mut snapshots: watch::Receiver<Option<Bytes>>,
    tx: mpsc::Sender<Bytes>,
    heartbeat: Duration,
) {
    if tx.send(Bytes::from_static(RETRY)).await.is_err() {
        return;
    }
    let first = snapshots.borrow_and_update().clone();
    if let Some(json) = first {
        if tx.send(event(&json)).await.is_err() {
            return;
        }
    }
    loop {
        let next = match tokio::time::timeout(heartbeat, snapshots.changed()).await {
            Ok(Ok(())) => match snapshots.borrow_and_update().clone() {
                Some(json) => event(&json),
                None => continue,
            },
            Ok(Err(_)) => return,
            Err(_) => Bytes::from_static(HEARTBEAT),
        };
        if tx.send(next).await.is_err() {
            return;
        }
    }
}

/// What every connection shares.
struct Shared {
    bound: SocketAddr,
    assets: Assets,
    clips: Clips,
    snapshots: watch::Receiver<Option<Bytes>>,
    streams: Arc<Semaphore>,
    heartbeat: Duration,
}

/// The parts of the phone's snapshot: the fleet's phone view, the usage
/// readings' once a usage source has been read, the character theme once
/// the app has named one, and the CI watch's view once `ci.json` was read.
#[derive(Default)]
struct Parts {
    fleet: Option<Value>,
    usage: Option<Value>,
    theme: Option<&'static str>,
    ci: Option<Value>,
}

/// The snapshot every phone gets, made from its parts.
struct Feed {
    parts: std::sync::Mutex<Parts>,
    snapshots: watch::Sender<Option<Bytes>>,
}

impl Feed {
    /// Change a part and send the snapshot, if it changed. None goes out
    /// before the fleet's first: usage alone would be an empty wall.
    fn update(&self, change: impl FnOnce(&mut Parts)) {
        let mut parts = self.parts.lock().unwrap_or_else(|e| e.into_inner());
        change(&mut parts);
        let Some(mut view) = parts.fleet.clone() else {
            return;
        };
        if let Some(map) = view.as_object_mut() {
            if let Some(usage) = &parts.usage {
                map.insert("usage".into(), usage.clone());
            }
            if let Some(theme) = parts.theme {
                map.insert("theme".into(), Value::from(theme));
            }
            if let Some(ci) = parts.ci.as_ref().filter(|c| !c.is_null()) {
                map.insert("ci".into(), ci.clone());
            }
        }
        let Ok(json) = serde_json::to_vec(&view) else {
            return;
        };
        let json = Bytes::from(json);
        self.snapshots.send_if_modified(|now| {
            if now.as_ref() == Some(&json) {
                return false;
            }
            *now = Some(json);
            true
        });
    }
}

/// Read the usage source every `every`, off the server's thread, for as long
/// as the server runs.
async fn follow_usage(read: Usage, feed: Arc<Feed>, every: Duration) {
    loop {
        let r = read.clone();
        if let Ok(readings) = tokio::task::spawn_blocking(move || r()).await {
            let view = crate::usage::phone_view(&readings);
            feed.update(|p| p.usage = Some(view));
        }
        tokio::time::sleep(every).await;
    }
}

fn handle(req: &Request<Incoming>, s: &Shared) -> Reply {
    let header = |name| req.headers().get(name).and_then(|v| v.to_str().ok());
    let head = Head {
        method: req.method(),
        path: req.uri().path(),
        host: header(HOST),
        origin: header(ORIGIN),
        funnel: req.headers().contains_key("tailscale-funnel-request"),
    };
    let only_head = req.method() == Method::HEAD;
    let route = match admit(&head, s.bound) {
        Ok(r) => r,
        Err(status) => return refuse(status),
    };
    match route {
        Route::Asset(path) => {
            let kind = asset_type(&path);
            match (s.assets)(&path) {
                Some(bytes) => answer(
                    StatusCode::OK,
                    kind,
                    "no-cache",
                    Some(Bytes::from(bytes)),
                    only_head,
                ),
                None => refuse(StatusCode::NOT_FOUND),
            }
        }
        Route::Home => {
            let mut r = refuse(StatusCode::PERMANENT_REDIRECT);
            r.headers_mut()
                .insert(LOCATION, HeaderValue::from_static("/"));
            r
        }
        Route::Snapshot => match s.snapshots.borrow().clone() {
            Some(json) => answer(
                StatusCode::OK,
                Some("application/json"),
                "no-store",
                Some(json),
                only_head,
            ),
            // No snapshot yet: an empty wall would say no session runs.
            None => refuse(StatusCode::SERVICE_UNAVAILABLE),
        },
        // Only a card the phone shows with a clip: what its wall would offer.
        Route::Clip(id) => match s.snapshots.borrow().clone() {
            Some(json) if offers_clip(&json, &id, req.uri().query()) => match (s.clips)(&id) {
                // Range applies to GET only (RFC 9110 14.2).
                Some(bytes) => clip(
                    Bytes::from(bytes),
                    header(RANGE).filter(|_| !only_head),
                    only_head,
                ),
                None => refuse(StatusCode::NOT_FOUND),
            },
            _ => refuse(StatusCode::NOT_FOUND),
        },
        Route::Events => {
            if only_head {
                return answer(
                    StatusCode::OK,
                    Some("text/event-stream"),
                    "no-store",
                    None,
                    true,
                );
            }
            let Ok(slot) = s.streams.clone().try_acquire_owned() else {
                return refuse(StatusCode::SERVICE_UNAVAILABLE);
            };
            let (tx, rx) = mpsc::channel(2);
            tokio::spawn(feed(s.snapshots.clone(), tx, s.heartbeat));
            let mut r = Response::new(Stream { rx, _slot: slot }.boxed());
            let h = r.headers_mut();
            h.insert(CONTENT_TYPE, HeaderValue::from_static("text/event-stream"));
            h.insert(CACHE_CONTROL, HeaderValue::from_static("no-store"));
            h.insert(X_CONTENT_TYPE_OPTIONS, HeaderValue::from_static("nosniff"));
            h.insert("x-accel-buffering", HeaderValue::from_static("no"));
            r
        }
    }
}

/// The bytes a `Range` header asks of a body `len` long, as an inclusive
/// pair: `None` for the whole body (no header, or one this server does not
/// split, such as several ranges), `Err` for a range outside it. Safari asks
/// for media in ranges and plays nothing from a server that answers 200.
fn byte_range(header: Option<&str>, len: usize) -> Result<Option<(usize, usize)>, ()> {
    // The unit is case-insensitive.
    let Some(spec) = header
        .map(str::trim)
        .filter(|h| h.len() > 6 && h.is_char_boundary(6) && h[..6].eq_ignore_ascii_case("bytes="))
        .map(|h| &h[6..])
    else {
        return Ok(None);
    };
    if spec.contains(',') {
        return Ok(None);
    }
    let (from, to) = spec.split_once('-').ok_or(())?;
    // Digits too many for usize name a position past any body.
    let num = |s: &str| {
        let s = s.trim();
        if s.is_empty() || !s.bytes().all(|b| b.is_ascii_digit()) {
            return Err(());
        }
        Ok(s.parse::<usize>().unwrap_or(usize::MAX))
    };
    let (start, end) = match (from.trim(), to.trim()) {
        ("", "") => return Err(()),
        ("", last) => {
            let n = num(last)?;
            if n == 0 {
                return Err(());
            }
            (len.saturating_sub(n), len.checked_sub(1).ok_or(())?)
        }
        (first, "") => (num(first)?, len.checked_sub(1).ok_or(())?),
        (first, last) => (num(first)?, num(last)?.min(len.saturating_sub(1))),
    };
    if start >= len || start > end {
        return Err(());
    }
    Ok(Some((start, end)))
}

/// A reply clip, whole or the range asked for.
fn clip(bytes: Bytes, range: Option<&str>, head: bool) -> Reply {
    let len = bytes.len();
    let mut r = match byte_range(range, len) {
        Ok(None) => answer(
            StatusCode::OK,
            Some("audio/wav"),
            "no-store",
            Some(bytes),
            head,
        ),
        Ok(Some((start, end))) => {
            let mut r = answer(
                StatusCode::PARTIAL_CONTENT,
                Some("audio/wav"),
                "no-store",
                Some(bytes.slice(start..=end)),
                head,
            );
            if let Ok(v) = HeaderValue::from_str(&format!("bytes {start}-{end}/{len}")) {
                r.headers_mut().insert(CONTENT_RANGE, v);
            }
            r
        }
        Err(()) => {
            let mut r = refuse(StatusCode::RANGE_NOT_SATISFIABLE);
            if let Ok(v) = HeaderValue::from_str(&format!("bytes */{len}")) {
                r.headers_mut().insert(CONTENT_RANGE, v);
            }
            r
        }
    };
    r.headers_mut()
        .insert(ACCEPT_RANGES, HeaderValue::from_static("bytes"));
    r
}

/// Whether the phone's snapshot `json` shows session `id` with a reply clip.
/// With `at=` in `query`, only that clip: Safari fetches a clip in several
/// ranges, and a newer reply must not splice into the one already playing.
fn offers_clip(json: &[u8], id: &str, query: Option<&str>) -> bool {
    let Ok(v) = serde_json::from_slice::<Value>(json) else {
        return false;
    };
    let asked = query.and_then(|q| q.split('&').find_map(|kv| kv.strip_prefix("at=")));
    v.get("sessions")
        .and_then(Value::as_array)
        .is_some_and(|all| {
            all.iter().any(|s| {
                s.get("session_id").and_then(Value::as_str) == Some(id)
                    && s.get("reply_at")
                        .and_then(Value::as_i64)
                        .is_some_and(|at| asked.is_none_or(|a| a.parse::<i64>().ok() == Some(at)))
            })
        })
}

/// The running server. Dropping it, or `stop`, closes the port and every
/// connection before it returns.
pub struct Server {
    addr: SocketAddr,
    feed: Arc<Feed>,
    stop: Option<oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Server {
    /// Bind `addr` now, so a port in use is reported to the caller, then
    /// serve on a thread of its own until stopped. With a `usage` source,
    /// its readings ride on every snapshot.
    pub fn spawn(
        addr: SocketAddrV4,
        assets: Assets,
        clips: Clips,
        usage: Option<Usage>,
    ) -> std::io::Result<Server> {
        Self::spawn_with(addr, LIMITS, assets, clips, usage)
    }

    pub fn spawn_with(
        addr: SocketAddrV4,
        limits: Limits,
        assets: Assets,
        clips: Clips,
        usage: Option<Usage>,
    ) -> std::io::Result<Server> {
        let std_listener = bind(addr)?;
        std_listener.set_nonblocking(true)?;
        let bound = std_listener.local_addr()?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()?;
        let (snapshots, watcher) = watch::channel(None);
        let feed = Arc::new(Feed {
            parts: Default::default(),
            snapshots,
        });
        let (stop, stopped) = oneshot::channel::<()>();
        let shared = Arc::new(Shared {
            bound,
            assets,
            clips,
            snapshots: watcher,
            streams: Arc::new(Semaphore::new(limits.streams)),
            heartbeat: limits.heartbeat,
        });
        let usage = usage.map(|read| (read, feed.clone()));
        let thread = std::thread::Builder::new()
            .name("phone-wall".into())
            .spawn(move || {
                runtime.block_on(async move {
                    tokio::spawn(accept(std_listener, limits, shared));
                    if let Some((read, feed)) = usage {
                        tokio::spawn(follow_usage(read, feed, limits.usage));
                    }
                    // Stopped, or the Server dropped without a word.
                    let _ = stopped.await;
                });
                // The runtime drops here, and with it the listener and every
                // connection still open.
            })?;
        Ok(Server {
            addr: bound,
            feed,
            stop: Some(stop),
            thread: Some(thread),
        })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// Hand every phone the fleet's newest snapshot, cut to what it shows.
    pub fn publish(&self, snapshot: &Value) {
        let view = phone_view(snapshot);
        self.feed.update(|p| p.fleet = Some(view));
    }

    /// Have every phone wear the character theme `id`: a known one, else the
    /// default (`theme::known`), so the phone never asks for a file that is
    /// not there.
    pub fn set_theme(&self, id: &str) {
        let theme = crate::theme::known(Some(id));
        self.feed.update(|p| p.theme = Some(theme));
    }

    /// Show every phone the CI watch's view (`ci::view`); null clears it.
    pub fn set_ci(&self, view: &Value) {
        let view = view.clone();
        self.feed.update(|p| p.ci = Some(view));
    }

    /// Close the port and every connection, and return once they are closed.
    pub fn stop(mut self) {
        self.shutdown();
    }

    fn shutdown(&mut self) {
        if let Some(stop) = self.stop.take() {
            let _ = stop.send(());
        }
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for Server {
    fn drop(&mut self) {
        self.shutdown();
    }
}

async fn accept(std_listener: std::net::TcpListener, limits: Limits, shared: Arc<Shared>) {
    let listener = match tokio::net::TcpListener::from_std(std_listener) {
        Ok(l) => l,
        Err(e) => {
            let at = shared.bound;
            log::error!("phone: wall server on {at} stopped; untick and tick Phone wall to start it again: {e}");
            return;
        }
    };
    let slots = Arc::new(Semaphore::new(limits.connections));
    let mut pause = Duration::ZERO;
    loop {
        let Ok(slot) = slots.clone().acquire_owned().await else {
            return;
        };
        let stream = match listener.accept().await {
            Ok((stream, _)) => {
                pause = Duration::ZERO;
                stream
            }
            Err(e) => {
                if pause.is_zero() {
                    log::warn!("phone: accept on {} failed; retrying: {e}", shared.bound);
                }
                pause = backoff(pause);
                tokio::time::sleep(pause).await;
                continue;
            }
        };
        let shared = shared.clone();
        tokio::spawn(async move {
            let service = service_fn(move |req| {
                let reply = handle(&req, &shared);
                async move { Ok::<_, Infallible>(reply) }
            });
            let _ = http1::Builder::new()
                .timer(TokioTimer::new())
                .header_read_timeout(limits.header)
                .serve_connection(TokioIo::new(stream), service)
                .await;
            drop(slot);
        });
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;
    use std::io::{BufRead, BufReader, Read, Write};
    use std::net::TcpStream;
    use std::sync::Mutex;

    #[test]
    fn the_server_listens_on_loopback_port_8318() {
        assert_eq!(ADDR.ip(), &Ipv4Addr::LOCALHOST);
        assert_eq!(ADDR.port(), 8318);
        assert_ne!(ADDR.port(), crate::receiver::ADDR.port());
        assert_ne!(ADDR.port(), 4317);
        assert_eq!(LIMITS.heartbeat, Duration::from_secs(15));
        assert_eq!(LIMITS.streams, 8);
        assert_eq!(LIMITS.usage, Duration::from_secs(5), "the gauge's poll");
    }

    fn head<'a>(
        method: &'a Method,
        path: &'a str,
        host: Option<&'a str>,
        origin: Option<&'a str>,
    ) -> Head<'a> {
        Head {
            method,
            path,
            host,
            origin,
            funnel: false,
        }
    }

    const BOUND: SocketAddr = SocketAddr::V4(ADDR);

    #[test]
    fn only_loopback_and_tailnet_names_are_admitted() {
        let get = Method::GET;
        for host in [
            "127.0.0.1:8318",
            "localhost:8318",
            "LOCALHOST:8318",
            "desk.tail1234.ts.net",
            "Desk.Tail1234.TS.NET",
            "desk.tail1234.ts.net:443",
            "desk-2.tail-1234.ts.net:8443",
        ] {
            assert_eq!(
                admit(&head(&get, "/fleet.json", Some(host), None), BOUND),
                Ok(Route::Snapshot),
                "{host}"
            );
        }
        for host in [
            None,
            Some(""),
            Some("evil.example:8318"),
            Some("127.0.0.1"),
            Some("localhost"),
            Some("127.0.0.1:8319"),
            Some("[::1]:8318"),
            Some("ts.net"),
            Some("tail1234.ts.net"),
            Some("tail1234.ts.net.evil.example"),
            Some("desk.tail1234.ts.net.evil.example"),
            Some("desk.tail1234.ts.netx"),
            Some("desk..ts.net"),
            Some(".tail1234.ts.net"),
            Some("-desk.tail1234.ts.net"),
            Some("desk.tail1234.ts.net:"),
            Some("desk.tail1234.ts.net:99999x"),
            Some("de_sk.tail1234.ts.net"),
            Some("desk.tail1234.ts.net:443:443"),
        ] {
            assert_eq!(
                admit(&head(&get, "/fleet.json", host, None), BOUND),
                Err(StatusCode::FORBIDDEN),
                "{host:?}"
            );
        }
    }

    #[test]
    fn only_a_same_origin_origin_is_admitted() {
        let get = Method::GET;
        let ts = Some("desk.tail1234.ts.net");
        for origin in [
            "https://desk.tail1234.ts.net",
            "http://desk.tail1234.ts.net",
        ] {
            assert!(
                admit(&head(&get, "/events", ts, Some(origin)), BOUND).is_ok(),
                "{origin}"
            );
        }
        assert!(admit(
            &head(
                &get,
                "/",
                Some("127.0.0.1:8318"),
                Some("http://127.0.0.1:8318")
            ),
            BOUND
        )
        .is_ok());
        for origin in [
            "https://evil.example",
            "null",
            "",
            "https://desk.tail1234.ts.net.evil.example",
            "https://other.tail1234.ts.net",
            "http://localhost:8318",
            "file://",
        ] {
            assert_eq!(
                admit(&head(&get, "/events", ts, Some(origin)), BOUND),
                Err(StatusCode::FORBIDDEN),
                "{origin}"
            );
        }
    }

    #[test]
    fn a_funnelled_request_is_refused() {
        let h = Head {
            funnel: true,
            ..head(&Method::GET, "/", Some("desk.tail1234.ts.net"), None)
        };
        assert_eq!(admit(&h, BOUND), Err(StatusCode::FORBIDDEN));
    }

    #[test]
    fn every_method_but_get_and_head_is_refused_on_every_route() {
        let host = Some("127.0.0.1:8318");
        for path in [
            "/",
            "/fleet.json",
            "/events",
            "/fleet/wall.js",
            "/nowhere",
            "/v1/logs",
        ] {
            for m in [
                "POST", "PUT", "DELETE", "PATCH", "OPTIONS", "TRACE", "PROPFIND",
            ] {
                let method = Method::from_bytes(m.as_bytes()).unwrap();
                assert_eq!(
                    admit(&head(&method, path, host, None), BOUND),
                    Err(StatusCode::METHOD_NOT_ALLOWED),
                    "{m} {path}"
                );
            }
            assert_ne!(
                admit(&head(&Method::HEAD, path, host, None), BOUND),
                Err(StatusCode::METHOD_NOT_ALLOWED)
            );
        }
    }

    #[test]
    fn only_the_walls_files_are_routes() {
        for (path, want) in [
            ("/", Some(Route::Asset("wall.html".into()))),
            ("/wall.html", Some(Route::Home)),
            ("/fleet/wall.js", Some(Route::Asset("fleet/wall.js".into()))),
            (
                "/fleet/themes/kourai.json",
                Some(Route::Asset("fleet/themes/kourai.json".into())),
            ),
            (
                "/fleet/faces/kourai/hermes-96.webp",
                Some(Route::Asset("fleet/faces/kourai/hermes-96.webp".into())),
            ),
            (
                "/fleet/faces/professions/messenger-96.webp",
                Some(Route::Asset(
                    "fleet/faces/professions/messenger-96.webp".into(),
                )),
            ),
            (
                "/fleet/fonts/cinzel-latin-wght-normal.woff2",
                Some(Route::Asset(
                    "fleet/fonts/cinzel-latin-wght-normal.woff2".into(),
                )),
            ),
            ("/ipc.js", Some(Route::Asset("ipc.js".into()))),
            ("/zoom.js", Some(Route::Asset("zoom.js".into()))),
            ("/gauge.js", Some(Route::Asset("gauge.js".into()))),
            ("/gaugeview.js", Some(Route::Asset("gaugeview.js".into()))),
            ("/log.js", Some(Route::Asset("log.js".into()))),
            (
                "/manifest.webmanifest",
                Some(Route::Asset("manifest.webmanifest".into())),
            ),
            ("/sw.js", Some(Route::Asset("sw.js".into()))),
            (
                "/phone/icon-192.png",
                Some(Route::Asset("phone/icon-192.png".into())),
            ),
            ("/fleet.json", Some(Route::Snapshot)),
            ("/events", Some(Route::Events)),
        ] {
            assert_eq!(route(path), want, "{path}");
        }
        for path in [
            "/dev-fleet.json",
            "/dev-fixture.json",
            "/index.html",
            "/main.js",
            "/gauge.test.js",
            "/style.css",
            "/fleet-model.test.js",
            "/fleet/../index.html",
            "/fleet/./wall.js",
            "/fleet//wall.js",
            "/fleet/",
            "/fleet",
            "/fleet/.hidden.js",
            "/fleet/wall.js.map",
            "/fleet/faces/LICENSES.txt",
            "/fleet/%2e%2e/index.html",
            "/phone/../../etc/passwd",
            "//etc/passwd",
            "/C:/Windows/win.ini",
            "/fleet\\wall.js",
            "/ledger.json",
            "/v1/logs",
            "",
        ] {
            assert_eq!(route(path), None, "{path}");
        }
    }

    #[test]
    fn the_phone_view_keeps_only_what_the_wall_shows() {
        let snapshot = json!({
            "sessions": [{
                "session_id": "s1", "name": "n", "launch_dir": "/home/aj/repos/klepsydra/",
                "voice": "v", "status": "working", "reason": null, "status_at": 1, "active_at": 2,
                "where": {"repo": "r", "worktree": null, "branch": "b", "at": 1},
                "touched": [], "prompt": {"text": "p", "at": 1}, "reply": null, "error": null,
                "updated_at": 3, "quiet_since": null,
                "tmux": {"socket": "/tmp/tmux-1000/klepsydra", "pane": "%1"},
                "distro": "Ubuntu", "claude": {"pid": 42, "start": 7},
                "background": {"agents": 1, "shells": 0, "tasks": 0},
                "ledger": {"tokens": {"input": 1}}, "ledger_partial": true,
                "remote_url": "https://claude.ai/code/session_01ABC",
                "wrapup": {"state": "blocked", "reason": "a review is running", "at": 5, "settled_at": 6},
                "turn_at": 4, "asked_after_turn": true, "reply_at": 8
            }, {"session_id": "s2", "launch_dir": "C:\\Users\\aj\\proj", "status": "done"}, "junk"],
            "speaking": {"session_id": "s1", "envelope": [0.5], "started_at": 1.0, "ends_at": 2.0},
            "receiver": {"addr": "127.0.0.1:4318", "listening": true, "error": null}
        });
        let v = phone_view(&snapshot);
        let s = v["sessions"][0].as_object().unwrap();
        let mut keys: Vec<&str> = s.keys().map(String::as_str).collect();
        keys.sort_unstable();
        let mut want: Vec<&str> = SESSION_FIELDS.to_vec();
        want.push("launch_dir");
        want.sort_unstable();
        assert_eq!(keys, want);
        assert_eq!(s["launch_dir"], "klepsydra");
        assert_eq!(v["sessions"][1]["launch_dir"], "proj");
        assert_eq!(
            v["sessions"].as_array().unwrap().len(),
            2,
            "a non-object session is dropped"
        );
        assert_eq!(v["speaking"], snapshot["speaking"]);
        assert_eq!(s["wrapup"], snapshot["sessions"][0]["wrapup"]);
        assert_eq!(s["turn_at"], 4);
        assert_eq!(s["asked_after_turn"], true);
        let top: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        assert_eq!(
            top,
            ["sessions", "speaking"],
            "no wrap-up request, none sent"
        );
        let request = json!({"id": "1", "at": 1, "until": 601, "ids": ["s1"]});
        let mut asked = snapshot.clone();
        asked["wrapup"] = request.clone();
        let v = phone_view(&asked);
        assert_eq!(
            v["wrapup"], request,
            "the wall's wrap-up request reaches the phone"
        );
        let mut top: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
        top.sort_unstable();
        assert_eq!(top, ["sessions", "speaking", "wrapup"]);
        let text = v.to_string();
        for private in ["tmux", "/tmp/tmux", "pid", "Ubuntu", "4318", "/home/aj"] {
            assert!(
                !text.contains(private),
                "{private} reached the phone: {text}"
            );
        }
        assert_eq!(
            phone_view(&json!({})),
            json!({"sessions": [], "speaking": null})
        );
    }

    // --- over the wire ---

    struct Probe {
        server: Server,
        asked: Arc<Mutex<Vec<String>>>,
    }

    /// The one session the stub clip store has a clip for, and the clip.
    const CLIP_ID: &str = "cb9fa591-1514-44d1-a31c-eba4a7cb41ed";
    const CLIP: &[u8] = b"RIFF....WAVEfmt  a clip";

    /// The stub bundle: the wall, one of its files, and the gauge's page.
    const BUNDLE: [(&str, &[u8]); 3] = [
        ("wall.html", b"<!doctype html><title>wall</title>"),
        ("fleet/wall.js", b"export {};"),
        ("index.html", b"<!doctype html><title>gauge</title>"),
    ];

    /// What Tauri 2's asset resolver answers for `path` (tauri
    /// `manager::AppManager::get_asset`): the file, else `<path>.html`, else
    /// `<path>/index.html`, else `index.html`.
    fn tauri_get(path: &str) -> Option<Vec<u8>> {
        let hit = |p: &str| {
            BUNDLE
                .iter()
                .find(|(k, _)| *k == p)
                .map(|(_, b)| b.to_vec())
        };
        hit(path)
            .or_else(|| hit(&format!("{path}.html")))
            .or_else(|| hit(&format!("{path}/index.html")))
            .or_else(|| hit("index.html"))
    }

    #[test]
    fn a_resolver_is_held_to_the_bundles_exact_paths() {
        for known in [
            ["/wall.html", "/fleet/wall.js"],
            ["wall.html", "fleet/wall.js"],
        ] {
            let exact = exact_assets(known, tauri_get);
            assert_eq!(exact("wall.html"), tauri_get("wall.html"));
            assert_eq!(exact("fleet/wall.js"), tauri_get("fleet/wall.js"));
            for missing in ["fleet/missing.js", "fleet/wall", "index.html", "", "fleet"] {
                assert_eq!(exact(missing), None, "{missing}");
            }
        }
    }

    const QUICK: Limits = Limits {
        header: Duration::from_millis(500),
        connections: 8,
        streams: 2,
        heartbeat: Duration::from_millis(300),
        usage: Duration::from_millis(50),
    };

    fn serve(limits: Limits) -> Probe {
        serve_usage(limits, None)
    }

    fn serve_usage(limits: Limits, usage: Option<Usage>) -> Probe {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let seen = asked.clone();
        // As the app builds it: Tauri's resolver held to the bundle's keys.
        let exact = exact_assets(BUNDLE.iter().map(|(k, _)| format!("/{k}")), tauri_get);
        let assets: Assets = Arc::new(move |p: &str| {
            seen.lock().unwrap().push(p.to_string());
            exact(p)
        });
        let clips: Clips = Arc::new(|id: &str| (id == CLIP_ID).then(|| CLIP.to_vec()));
        let server = Server::spawn_with(
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0),
            limits,
            assets,
            clips,
            usage,
        )
        .unwrap();
        Probe { server, asked }
    }

    /// The full answer to `request` (the connection is closed after it).
    fn exchange(addr: SocketAddr, request: &str) -> (u16, String, Vec<u8>) {
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        s.write_all(request.as_bytes()).unwrap();
        let mut out = Vec::new();
        let _ = s.read_to_end(&mut out);
        let split = out
            .windows(4)
            .position(|w| w == b"\r\n\r\n")
            .map_or(out.len(), |i| i + 4);
        let headers = String::from_utf8_lossy(&out[..split]).to_string();
        let code = headers
            .split(' ')
            .nth(1)
            .and_then(|c| c.parse().ok())
            .unwrap_or(0);
        (code, headers, out[split..].to_vec())
    }

    fn get(addr: SocketAddr, method: &str, path: &str, extra: &str) -> (u16, String, Vec<u8>) {
        exchange(
            addr,
            &format!(
                "{method} {path} HTTP/1.1\r\nHost: {addr}\r\n{extra}Connection: close\r\n\r\n"
            ),
        )
    }

    #[test]
    fn a_spawned_server_binds_loopback_only() {
        let p = serve(QUICK);
        assert_eq!(
            p.server.addr().ip(),
            std::net::IpAddr::V4(Ipv4Addr::LOCALHOST)
        );
    }

    #[test]
    fn a_taken_port_is_an_error_not_a_panic() {
        let p = serve(QUICK);
        let SocketAddr::V4(taken) = p.server.addr() else {
            unreachable!()
        };
        let again = Server::spawn(taken, Arc::new(tauri_get), Arc::new(|_| None), None);
        assert!(again.is_err());
    }

    #[test]
    fn writes_are_refused_with_405_and_reach_nothing() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        for method in ["POST", "PUT", "DELETE", "PATCH", "OPTIONS"] {
            for path in ["/", "/fleet.json", "/events", "/fleet/wall.js", "/launch"] {
                let (code, headers, _) = exchange(
                    addr,
                    &format!("{method} {path} HTTP/1.1\r\nHost: {addr}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}"),
                );
                assert_eq!(code, 405, "{method} {path}");
                assert!(
                    headers.to_ascii_lowercase().contains("allow: get, head"),
                    "{headers}"
                );
            }
        }
        assert!(
            p.asked.lock().unwrap().is_empty(),
            "a refused request read a file"
        );
    }

    #[test]
    fn a_rebound_host_a_foreign_origin_or_a_funnel_is_refused() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        let raw = |host: &str, extra: &str| {
            exchange(addr, &format!("GET /fleet/wall.js HTTP/1.1\r\nHost: {host}\r\n{extra}Connection: close\r\n\r\n")).0
        };
        let evil = format!("evil.example:{}", addr.port());
        assert_eq!(raw(&evil, ""), 403);
        assert_eq!(raw("desk.tail1234.ts.net.evil.example", ""), 403);
        assert_eq!(
            raw(&addr.to_string(), "Origin: https://evil.example\r\n"),
            403
        );
        assert_eq!(
            raw("desk.tail1234.ts.net", "Tailscale-Funnel-Request: ?1\r\n"),
            403
        );
        assert_eq!(
            exchange(addr, "GET / HTTP/1.1\r\nConnection: close\r\n\r\n").0,
            403,
            "no Host at all"
        );
        assert!(p.asked.lock().unwrap().is_empty());
        // What Tailscale Serve sends (ipn/ipnlocal/serve.go): the phone's Host,
        // X-Forwarded-*, and the tailnet user.
        let serve_headers = "X-Forwarded-Host: desk.tail1234.ts.net\r\nX-Forwarded-Proto: https\r\nX-Forwarded-For: 100.64.0.2\r\nTailscale-User-Login: aj@example.com\r\n";
        assert_eq!(raw("desk.tail1234.ts.net", serve_headers), 200);
        assert_eq!(
            raw(
                "desk.tail1234.ts.net",
                "Origin: https://desk.tail1234.ts.net\r\n"
            ),
            200
        );
    }

    #[test]
    fn the_wall_and_its_files_are_served_with_their_types() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        let (code, headers, body) = get(addr, "GET", "/", "");
        assert_eq!(code, 200);
        let lower = headers.to_ascii_lowercase();
        assert!(
            lower.contains("content-type: text/html; charset=utf-8"),
            "{headers}"
        );
        assert!(
            lower.contains("x-content-type-options: nosniff"),
            "{headers}"
        );
        assert!(
            lower.contains("content-security-policy: default-src 'self'"),
            "{headers}"
        );
        assert!(lower.contains("frame-ancestors 'none'"), "{headers}");
        assert_eq!(body, tauri_get("wall.html").unwrap());
        let (code, headers, body) = get(addr, "GET", "/fleet/wall.js", "");
        assert_eq!(code, 200);
        assert!(
            headers
                .to_ascii_lowercase()
                .contains("content-type: text/javascript"),
            "{headers}"
        );
        assert_eq!(body, b"export {};");
        let (code, headers, body) = get(addr, "HEAD", "/", "");
        assert_eq!(code, 200);
        assert!(
            headers.to_ascii_lowercase().contains(&format!(
                "content-length: {}",
                tauri_get("wall.html").unwrap().len()
            )),
            "{headers}"
        );
        assert!(body.is_empty(), "HEAD sent a body");
        // Tauri's resolver answers a missing file with index.html: the
        // server sends only what the bundle holds at that exact path.
        assert_eq!(tauri_get("fleet/missing.js"), tauri_get("index.html"));
        for path in [
            "/fleet/missing.js",
            "/fleet/missing.css",
            "/phone/missing.png",
            "/sw.js",
        ] {
            let (code, _, body) = get(addr, "GET", path, "");
            assert_eq!(code, 404, "{path}");
            assert!(body.is_empty(), "{path}: {body:?}");
        }
        // The wall has one address, its root, where the page knows it is served.
        for method in ["GET", "HEAD"] {
            let (code, headers, body) = get(addr, method, "/wall.html", "");
            assert_eq!(code, 308, "{method} /wall.html");
            assert!(
                headers.to_ascii_lowercase().contains("\r\nlocation: /\r\n"),
                "{headers}"
            );
            assert!(body.is_empty());
        }
        let before = p.asked.lock().unwrap().len();
        for path in [
            "/dev-fleet.json",
            "/index.html",
            "/fleet/../main.js",
            "/fleet-model.test.js",
        ] {
            assert_eq!(get(addr, "GET", path, "").0, 404, "{path}");
        }
        assert_eq!(
            p.asked.lock().unwrap().len(),
            before,
            "a refused path reached the bundle"
        );
    }

    fn snapshot(n: u64) -> Value {
        json!({
            "sessions": [{"session_id": "s1", "status": "working", "status_at": n,
                          "tmux": {"socket": "/tmp/x/klepsydra", "pane": "%3"}, "claude": {"pid": 9, "start": 1}}],
            "speaking": null,
            "receiver": {"addr": "127.0.0.1:4318", "listening": true, "error": null}
        })
    }

    #[test]
    fn fleet_json_is_the_latest_phone_view() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        assert_eq!(
            get(addr, "GET", "/fleet.json", "").0,
            503,
            "no snapshot yet"
        );
        p.server.publish(&snapshot(1));
        p.server.publish(&snapshot(2));
        let (code, headers, body) = get(addr, "GET", "/fleet.json", "");
        assert_eq!(code, 200);
        let lower = headers.to_ascii_lowercase();
        assert!(
            lower.contains("content-type: application/json"),
            "{headers}"
        );
        assert!(lower.contains("cache-control: no-store"), "{headers}");
        let v: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v, phone_view(&snapshot(2)));
        assert_eq!(v["sessions"][0]["status_at"], 2);
        assert!(v["sessions"][0].get("tmux").is_none());
        assert!(v.get("receiver").is_none());
    }

    #[test]
    fn a_clip_is_served_only_for_a_card_the_phone_shows_with_one() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        let path = format!("/audio/{CLIP_ID}");
        assert_eq!(get(addr, "GET", &path, "").0, 404, "no snapshot yet");
        let other = "0b6e1c5a-1111-4222-8333-444455556666";
        p.server.publish(&json!({"sessions": [
            {"session_id": CLIP_ID, "status": "done", "status_at": 1},
            {"session_id": other, "status": "done", "status_at": 1, "reply_at": 5},
        ]}));
        assert_eq!(get(addr, "GET", &path, "").0, 404, "its card shows no clip");
        assert_eq!(
            get(addr, "GET", &format!("/audio/{other}"), "").0,
            404,
            "a card with a clip the store does not have"
        );
        p.server.publish(&json!({"sessions": [
            {"session_id": CLIP_ID, "status": "done", "status_at": 1, "reply_at": 5},
        ]}));
        let (code, headers, body) = get(addr, "GET", &path, "");
        let lower = headers.to_ascii_lowercase();
        assert_eq!((code, body.as_slice()), (200, CLIP));
        assert!(lower.contains("content-type: audio/wav"), "{headers}");
        assert!(lower.contains("cache-control: no-store"), "{headers}");
        let (code, _, body) = get(addr, "HEAD", &path, "");
        assert_eq!((code, body.len()), (200, 0));
        assert_eq!(
            get(addr, "POST", &path, "").0,
            405,
            "the wall stays read-only"
        );
        for bad in [
            "/audio/",
            "/audio/../wall.html",
            "/audio/x",
            &format!("/audio/{CLIP_ID}.wav"),
        ] {
            assert_eq!(get(addr, "GET", bad, "").0, 404, "{bad}");
        }
        p.server.publish(&json!({"sessions": []}));
        assert_eq!(
            get(addr, "GET", &path, "").0,
            404,
            "its card has left the wall"
        );
    }

    #[test]
    fn a_clip_is_sent_in_the_ranges_safari_asks_for() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        p.server.publish(&json!({"sessions": [
            {"session_id": CLIP_ID, "status": "done", "status_at": 1, "reply_at": 5},
        ]}));
        let path = format!("/audio/{CLIP_ID}");
        let len = CLIP.len();
        let (code, headers, body) = get(addr, "GET", &path, "Range: bytes=0-1\r\n");
        let lower = headers.to_ascii_lowercase();
        assert_eq!((code, body.as_slice()), (206, &CLIP[0..2]));
        assert!(
            lower.contains(&format!("content-range: bytes 0-1/{len}")),
            "{headers}"
        );
        assert!(lower.contains("accept-ranges: bytes"), "{headers}");
        assert!(lower.contains("content-length: 2"), "{headers}");
        let (code, _, body) = get(addr, "GET", &path, "Range: bytes=4-\r\n");
        assert_eq!((code, body.as_slice()), (206, &CLIP[4..]));
        let (code, _, body) = get(addr, "GET", &path, "Range: bytes=-3\r\n");
        assert_eq!((code, body.as_slice()), (206, &CLIP[len - 3..]));
        let (code, headers, body) = get(addr, "GET", &path, &format!("Range: bytes={len}-\r\n"));
        assert_eq!((code, body.len()), (416, 0));
        assert!(
            headers
                .to_ascii_lowercase()
                .contains(&format!("content-range: bytes */{len}")),
            "{headers}"
        );
        let (code, headers, body) = get(addr, "GET", &path, "");
        assert_eq!((code, body.len()), (200, len));
        assert!(
            headers
                .to_ascii_lowercase()
                .contains("accept-ranges: bytes"),
            "{headers}"
        );
        let (code, headers, _) = get(addr, "HEAD", &path, "Range: bytes=0-1\r\n");
        let whole = format!("content-length: {len}");
        assert!(
            code == 200 && headers.to_ascii_lowercase().contains(&whole),
            "HEAD ignores Range: {headers}"
        );
        assert_eq!(
            get(addr, "GET", &format!("{path}?at=5"), "").0,
            200,
            "the clip the card shows"
        );
        assert_eq!(
            get(addr, "GET", &format!("{path}?at=4"), "Range: bytes=2-\r\n").0,
            404,
            "an older clip's range"
        );
    }

    #[test]
    fn byte_ranges_parse_as_rfc_9110_reads_them() {
        assert_eq!(byte_range(None, 10), Ok(None));
        assert_eq!(byte_range(Some("bytes=0-1"), 10), Ok(Some((0, 1))));
        assert_eq!(byte_range(Some("bytes=2-"), 10), Ok(Some((2, 9))));
        assert_eq!(byte_range(Some("bytes=-4"), 10), Ok(Some((6, 9))));
        assert_eq!(
            byte_range(Some("bytes=-40"), 10),
            Ok(Some((0, 9))),
            "a suffix longer than the body is all of it"
        );
        assert_eq!(
            byte_range(Some("bytes=5-99"), 10),
            Ok(Some((5, 9))),
            "an end past the body stops at it"
        );
        assert_eq!(
            byte_range(Some("bytes=0-1,4-5"), 10),
            Ok(None),
            "several ranges: the whole body"
        );
        assert_eq!(
            byte_range(Some("items=0-1"), 10),
            Ok(None),
            "another unit is ignored"
        );
        for bad in [
            "bytes=10-",
            "bytes=5-2",
            "bytes=-0",
            "bytes=-",
            "bytes=a-b",
            "bytes=1",
            "bytes=+1-2",
            "bytes=99999999999999999999999-",
        ] {
            assert_eq!(byte_range(Some(bad), 10), Err(()), "{bad}");
        }
        assert_eq!(
            byte_range(Some("Bytes=0-0"), 10),
            Ok(Some((0, 0))),
            "the unit in any case"
        );
        assert_eq!(
            byte_range(Some("bytes=3-99999999999999999999999"), 10),
            Ok(Some((3, 9))),
            "a huge end clamps"
        );
        assert_eq!(
            byte_range(Some("bytes=-99999999999999999999999"), 10),
            Ok(Some((0, 9))),
            "a huge suffix is all of it"
        );
        assert_eq!(byte_range(Some("bytes=0-"), 0), Err(()), "nothing to send");
    }

    #[test]
    fn the_phone_gets_each_cards_reply_time() {
        let v = phone_view(&json!({"sessions": [{"session_id": "s1", "reply_at": 7}]}));
        assert_eq!(v["sessions"][0]["reply_at"], 7);
    }

    /// Open `/events` and return a reader positioned after the headers.
    fn open_events(addr: SocketAddr) -> (u16, BufReader<TcpStream>) {
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        s.write_all(
            format!("GET /events HTTP/1.1\r\nHost: {addr}\r\nAccept: text/event-stream\r\n\r\n")
                .as_bytes(),
        )
        .unwrap();
        let mut r = BufReader::new(s);
        let mut status = String::new();
        r.read_line(&mut status).unwrap();
        let code = status
            .split(' ')
            .nth(1)
            .and_then(|c| c.parse().ok())
            .unwrap_or(0);
        let mut type_ok = false;
        loop {
            let mut line = String::new();
            if r.read_line(&mut line).unwrap_or(0) == 0 || line == "\r\n" {
                break;
            }
            type_ok |= line
                .to_ascii_lowercase()
                .starts_with("content-type: text/event-stream");
        }
        assert!(code != 200 || type_ok, "an event stream without its type");
        (code, r)
    }

    /// The next SSE payload line (`data: ...` or a `: comment`), across chunk framing.
    fn next_item(r: &mut BufReader<TcpStream>) -> String {
        loop {
            let mut line = String::new();
            assert!(r.read_line(&mut line).unwrap() > 0, "the stream closed");
            let line = line.trim_end();
            if line.starts_with("data: ") || line.starts_with(": ") {
                return line.to_string();
            }
        }
    }

    fn data(line: &str) -> Value {
        serde_json::from_str(line.strip_prefix("data: ").expect(line)).unwrap()
    }

    #[test]
    fn events_send_the_latest_snapshot_then_each_new_one() {
        let p = serve(Limits {
            heartbeat: Duration::from_secs(30),
            ..QUICK
        });
        let addr = p.server.addr();
        p.server.publish(&snapshot(1));
        let (code, mut r) = open_events(addr);
        assert_eq!(code, 200);
        assert_eq!(data(&next_item(&mut r))["sessions"][0]["status_at"], 1);
        p.server.publish(&snapshot(2));
        let second = data(&next_item(&mut r));
        assert_eq!(second, phone_view(&snapshot(2)));
    }

    #[test]
    fn a_quiet_stream_sends_heartbeats() {
        let p = serve(QUICK);
        let (code, mut r) = open_events(p.server.addr());
        assert_eq!(code, 200);
        assert_eq!(next_item(&mut r), ": keepalive");
        assert_eq!(next_item(&mut r), ": keepalive");
    }

    #[test]
    fn streams_past_the_cap_are_refused_until_one_closes() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        let (a, ra) = open_events(addr);
        let (b, _rb) = open_events(addr);
        assert_eq!((a, b), (200, 200));
        assert_eq!(open_events(addr).0, 503);
        drop(ra);
        // The slot frees once the feeder notices, within a heartbeat or two.
        let started = std::time::Instant::now();
        loop {
            let (code, _r) = open_events(addr);
            if code == 200 {
                break;
            }
            assert!(
                started.elapsed() < Duration::from_secs(5),
                "the slot never came back"
            );
            std::thread::sleep(Duration::from_millis(100));
        }
    }

    #[test]
    fn stopping_closes_the_port_and_open_streams() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        p.server.publish(&snapshot(1));
        let (code, mut r) = open_events(addr);
        assert_eq!(code, 200);
        next_item(&mut r);
        p.server.stop();
        assert!(
            TcpStream::connect(addr).is_err(),
            "still listening after stop"
        );
        let mut rest = Vec::new();
        r.get_mut()
            .set_read_timeout(Some(Duration::from_secs(3)))
            .unwrap();
        match r.read_to_end(&mut rest) {
            Ok(_) => {}
            Err(e) => assert_eq!(
                e.kind(),
                std::io::ErrorKind::ConnectionReset,
                "a stream stayed open after stop"
            ),
        }
    }

    #[test]
    fn dropping_the_server_closes_the_port() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        drop(p);
        assert!(TcpStream::connect(addr).is_err());
    }

    // --- the usage readings ---

    const ACCOUNT: &str = "00000000-0000-4000-8000-00000000abcd";

    fn reading(pct: u32) -> Value {
        json!({
            "account": ACCOUNT, "label": "Personal", "session": "00000000-0000-4000-8000-000000000001",
            "written_at": 1_800_000_000, "observed_at": 1_800_000_000, "api_ms": 5,
            "windows": {"five_hour": {"used_percentage": pct, "resets_at": 1_800_003_600}}
        })
    }

    /// A usage source whose readings the test sets, and how often it was read.
    struct Source {
        readings: Arc<Mutex<Vec<Value>>>,
        reads: Arc<Mutex<usize>>,
        usage: Usage,
    }

    fn source(start: Vec<Value>) -> Source {
        let readings = Arc::new(Mutex::new(start));
        let reads = Arc::new(Mutex::new(0));
        let (r, n) = (readings.clone(), reads.clone());
        let usage: Usage = Arc::new(move || {
            *n.lock().unwrap() += 1;
            r.lock().unwrap().clone()
        });
        Source {
            readings,
            reads,
            usage,
        }
    }

    fn wait_for<T>(what: &str, mut f: impl FnMut() -> Option<T>) -> T {
        let started = std::time::Instant::now();
        loop {
            if let Some(v) = f() {
                return v;
            }
            assert!(started.elapsed() < Duration::from_secs(5), "{what}");
            std::thread::sleep(Duration::from_millis(20));
        }
    }

    #[test]
    fn the_snapshot_carries_the_readings_cut_to_the_gauges_fields() {
        let p = serve_usage(QUICK, Some(source(vec![reading(57)]).usage));
        let addr = p.server.addr();
        p.server.publish(&snapshot(1));
        let v = wait_for("the readings never reached fleet.json", || {
            let (code, _, body) = get(addr, "GET", "/fleet.json", "");
            let v: Value = serde_json::from_slice(&body).ok()?;
            (code == 200 && v.get("usage").is_some()).then_some(v)
        });
        assert_eq!(v["usage"], crate::usage::phone_view(&[reading(57)]));
        let mut fleet = v.clone();
        fleet.as_object_mut().unwrap().remove("usage");
        assert_eq!(
            fleet,
            phone_view(&snapshot(1)),
            "the fleet half is the phone view"
        );
        let text = v.to_string();
        for private in [ACCOUNT, "api_ms", "00000000-0000-4000-8000-000000000001"] {
            assert!(
                !text.contains(private),
                "{private} reached the phone: {text}"
            );
        }
    }

    #[test]
    fn readings_alone_are_no_snapshot() {
        let Source { reads, usage, .. } = source(vec![reading(57)]);
        let p = serve_usage(QUICK, Some(usage));
        wait_for("the source was never read twice", || {
            (*reads.lock().unwrap() >= 2).then_some(())
        });
        assert_eq!(
            get(p.server.addr(), "GET", "/fleet.json", "").0,
            503,
            "an empty wall would say no session runs"
        );
    }

    #[test]
    fn a_changed_reading_reaches_open_streams_and_an_unchanged_one_does_not() {
        let Source {
            readings,
            reads,
            usage,
        } = source(vec![reading(57)]);
        let p = serve_usage(QUICK, Some(usage));
        let addr = p.server.addr();
        p.server.publish(&snapshot(1));
        let (code, mut r) = open_events(addr);
        assert_eq!(code, 200);
        let pct = |v: &Value| v["usage"][0]["windows"]["five_hour"]["used_percentage"].clone();
        let mut first = data(&next_item(&mut r));
        while first.get("usage").is_none() {
            first = data(&next_item(&mut r));
        }
        assert_eq!(pct(&first), 57);
        *readings.lock().unwrap() = vec![reading(58)];
        let item = next_item(&mut r);
        assert_eq!(pct(&data(&item)), 58, "the new reading is the next event");
        // Polled many times over, unchanged, and the fleet republished as it
        // was: nothing new, so only heartbeats.
        let before = *reads.lock().unwrap();
        p.server.publish(&snapshot(1));
        assert_eq!(next_item(&mut r), ": keepalive");
        assert_eq!(next_item(&mut r), ": keepalive");
        assert!(*reads.lock().unwrap() >= before + 3, "the source is polled");
    }

    #[test]
    fn the_theme_rides_on_the_snapshot_and_a_switch_reaches_open_streams() {
        let p = serve(QUICK);
        let addr = p.server.addr();
        p.server.set_theme("professions");
        assert_eq!(
            get(addr, "GET", "/fleet.json", "").0,
            503,
            "a theme alone is no snapshot"
        );
        p.server.publish(&snapshot(1));
        let (_, _, body) = get(addr, "GET", "/fleet.json", "");
        let v: Value = serde_json::from_slice(&body).unwrap();
        assert_eq!(v["theme"], "professions");
        let mut fleet = v.clone();
        fleet.as_object_mut().unwrap().remove("theme");
        assert_eq!(
            fleet,
            phone_view(&snapshot(1)),
            "the theme changes nothing else"
        );
        let (code, mut r) = open_events(addr);
        assert_eq!(code, 200);
        assert_eq!(data(&next_item(&mut r))["theme"], "professions");
        p.server.set_theme("dicebear");
        assert_eq!(
            data(&next_item(&mut r))["theme"],
            "dicebear",
            "a switch is the next event, without a new fleet snapshot"
        );
        p.server.set_theme("dicebear");
        assert_eq!(
            next_item(&mut r),
            ": keepalive",
            "the same theme again is nothing new"
        );
    }

    #[test]
    fn an_unknown_theme_reaches_the_phone_as_kourai() {
        let p = serve(QUICK);
        p.server.publish(&snapshot(1));
        let (_, _, body) = get(p.server.addr(), "GET", "/fleet.json", "");
        let v: Value = serde_json::from_slice(&body).unwrap();
        assert!(
            v.get("theme").is_none(),
            "none named yet: the wall's default"
        );
        for bad in ["../faces", "Professions", "", "lorelei"] {
            p.server.set_theme(bad);
            let (_, _, body) = get(p.server.addr(), "GET", "/fleet.json", "");
            let v: Value = serde_json::from_slice(&body).unwrap();
            assert_eq!(v["theme"], "kourai", "{bad}");
        }
    }

    #[test]
    fn without_a_source_the_snapshot_has_no_usage() {
        let p = serve(QUICK);
        p.server.publish(&snapshot(1));
        std::thread::sleep(Duration::from_millis(150));
        let (_, _, body) = get(p.server.addr(), "GET", "/fleet.json", "");
        let v: Value = serde_json::from_slice(&body).unwrap();
        assert!(v.get("usage").is_none(), "{v}");
    }

    #[test]
    fn an_unknown_window_or_any_extra_field_never_reaches_the_phone() {
        let mut odd = reading(57);
        odd["email"] = json!("someone@example.com");
        odd["organization_id"] = json!("org-0000");
        odd["windows"]["secret_window"] = json!({"used_percentage": 1, "resets_at": 2});
        odd["windows"]["five_hour"]["note"] = json!("private");
        let p = serve_usage(QUICK, Some(source(vec![odd]).usage));
        let addr = p.server.addr();
        p.server.publish(&snapshot(1));
        let (code, mut r) = open_events(addr);
        assert_eq!(code, 200);
        let event = loop {
            let item = next_item(&mut r);
            if item.starts_with("data: ") && data(&item).get("usage").is_some() {
                break item;
            }
        };
        let (_, _, body) = get(addr, "GET", "/fleet.json", "");
        for (what, text) in [
            ("/events", event),
            ("/fleet.json", String::from_utf8(body).unwrap()),
        ] {
            let v: Value = serde_json::from_str(text.trim_start_matches("data: ")).unwrap();
            let usage = &v["usage"][0];
            let mut keys: Vec<&str> = usage
                .as_object()
                .unwrap()
                .keys()
                .map(String::as_str)
                .collect();
            keys.sort_unstable();
            assert_eq!(
                keys,
                ["account", "label", "observed_at", "windows", "written_at"],
                "{what}"
            );
            assert_eq!(
                usage["windows"],
                json!({"five_hour": {"used_percentage": 57, "resets_at": 1_800_003_600}}),
                "{what}"
            );
            // The fleet half names sessions; the readings never do.
            let readings = v["usage"].to_string();
            assert!(!readings.contains("session"), "{what}: {readings}");
            for private in [
                "secret_window",
                "someone@example.com",
                "org-0000",
                "private",
                ACCOUNT,
                "api_ms",
            ] {
                assert!(!text.contains(private), "{private} reached {what}: {text}");
            }
        }
    }
}
