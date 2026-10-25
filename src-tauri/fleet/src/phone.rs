//! The phone wall: a read-only HTTP server for the card wall, so a phone on
//! the tailnet can watch the fleet through Tailscale Serve. It listens on the
//! loopback interface only, Serve being the one way in from outside, answers
//! only GET and HEAD, and answers only requests named for loopback or for a
//! tailnet `*.ts.net` name, so a web page cannot reach it through DNS
//! rebinding. Nothing it serves writes anything.

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
    HeaderValue, ALLOW, CACHE_CONTROL, CONNECTION, CONTENT_LENGTH, CONTENT_SECURITY_POLICY,
    CONTENT_TYPE, HOST, LOCATION, ORIGIN, REFERRER_POLICY, X_CONTENT_TYPE_OPTIONS,
};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use serde_json::{Map, Value};
use tokio::sync::{mpsc, oneshot, watch, OwnedSemaphorePermit, Semaphore};

use crate::receiver::{backoff, bind, our_host, Log};

/// Where Tailscale Serve proxies to (`tailscale serve --bg 8318`): loopback
/// only. 8318 is unassigned at IANA, below Windows' dynamic port range
/// (49152 and up), and clear of the OTLP pair 4317/4318 and the usual dev
/// server ports.
pub const ADDR: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 8318);

/// How long a connection may take over a request's head, how many
/// connections are served at once, how many of them may hold an event
/// stream, and how often a quiet stream sends a comment so no proxy between
/// here and the phone closes it.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub header: Duration,
    pub connections: usize,
    pub streams: usize,
    pub heartbeat: Duration,
}

pub const LIMITS: Limits = Limits {
    header: Duration::from_secs(10),
    connections: 32,
    streams: 8,
    heartbeat: Duration::from_secs(15),
};

/// The app's bundled frontend: the bytes at a path such as `fleet/wall.js`.
pub type Assets = Arc<dyn Fn(&str) -> Option<Vec<u8>> + Send + Sync>;

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
const SESSION_FIELDS: [&str; 21] = [
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
/// folder, the IPC shim it imports, the install files and the icons. The
/// gauge, the tests and the dev snapshots are not among them.
pub fn asset_type(path: &str) -> Option<&'static str> {
    let root = matches!(
        path,
        "wall.html" | "ipc.js" | "manifest.webmanifest" | "sw.js"
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
        "js" => "text/javascript; charset=utf-8",
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
    snapshots: watch::Receiver<Option<Bytes>>,
    streams: Arc<Semaphore>,
    heartbeat: Duration,
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

/// The running server. Dropping it, or `stop`, closes the port and every
/// connection before it returns.
pub struct Server {
    addr: SocketAddr,
    snapshots: watch::Sender<Option<Bytes>>,
    stop: Option<oneshot::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
}

impl Server {
    /// Bind `addr` now, so a port in use is reported to the caller, then
    /// serve on a thread of its own until stopped.
    pub fn spawn(addr: SocketAddrV4, assets: Assets, log: Log) -> std::io::Result<Server> {
        Self::spawn_with(addr, LIMITS, assets, log)
    }

    pub fn spawn_with(
        addr: SocketAddrV4,
        limits: Limits,
        assets: Assets,
        log: Log,
    ) -> std::io::Result<Server> {
        let std_listener = bind(addr)?;
        std_listener.set_nonblocking(true)?;
        let bound = std_listener.local_addr()?;
        let runtime = tokio::runtime::Builder::new_current_thread()
            .enable_io()
            .enable_time()
            .build()?;
        let (snapshots, watcher) = watch::channel(None);
        let (stop, stopped) = oneshot::channel::<()>();
        let shared = Arc::new(Shared {
            bound,
            assets,
            snapshots: watcher,
            streams: Arc::new(Semaphore::new(limits.streams)),
            heartbeat: limits.heartbeat,
        });
        let thread = std::thread::Builder::new()
            .name("phone-wall".into())
            .spawn(move || {
                runtime.block_on(async move {
                    tokio::spawn(accept(std_listener, limits, shared, log));
                    // Stopped, or the Server dropped without a word.
                    let _ = stopped.await;
                });
                // The runtime drops here, and with it the listener and every
                // connection still open.
            })?;
        Ok(Server {
            addr: bound,
            snapshots,
            stop: Some(stop),
            thread: Some(thread),
        })
    }

    pub fn addr(&self) -> SocketAddr {
        self.addr
    }

    /// Hand every phone the fleet's newest snapshot, cut to what it shows.
    pub fn publish(&self, snapshot: &Value) {
        if let Ok(json) = serde_json::to_vec(&phone_view(snapshot)) {
            self.snapshots.send_replace(Some(Bytes::from(json)));
        }
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

async fn accept(
    std_listener: std::net::TcpListener,
    limits: Limits,
    shared: Arc<Shared>,
    log: Log,
) {
    let listener = match tokio::net::TcpListener::from_std(std_listener) {
        Ok(l) => l,
        Err(e) => return log(format!("phone: server stopped: {e}")),
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
                    log(format!("phone: accept failed: {e}"));
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
                "/fleet/cast.json",
                Some(Route::Asset("fleet/cast.json".into())),
            ),
            (
                "/fleet/faces/kourai/hermes-96.webp",
                Some(Route::Asset("fleet/faces/kourai/hermes-96.webp".into())),
            ),
            (
                "/fleet/fonts/cinzel-latin-wght-normal.woff2",
                Some(Route::Asset(
                    "fleet/fonts/cinzel-latin-wght-normal.woff2".into(),
                )),
            ),
            ("/ipc.js", Some(Route::Asset("ipc.js".into()))),
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
            "/gauge.js",
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
                "turn_at": 4, "asked_after_turn": true
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
    };

    fn serve(limits: Limits) -> Probe {
        let asked = Arc::new(Mutex::new(Vec::new()));
        let seen = asked.clone();
        // As the app builds it: Tauri's resolver held to the bundle's keys.
        let exact = exact_assets(BUNDLE.iter().map(|(k, _)| format!("/{k}")), tauri_get);
        let assets: Assets = Arc::new(move |p: &str| {
            seen.lock().unwrap().push(p.to_string());
            exact(p)
        });
        let log: Log = Arc::new(|_| {});
        let server = Server::spawn_with(
            SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0),
            limits,
            assets,
            log,
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
        let again = Server::spawn(taken, Arc::new(tauri_get), Arc::new(|_| {}));
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
}
