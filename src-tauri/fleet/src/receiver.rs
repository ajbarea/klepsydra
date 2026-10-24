//! A local OTLP/HTTP JSON receiver: Claude Code posts its metrics and events
//! here and the ledger counts them. It listens on the loopback interface only,
//! and answers only requests addressed to that interface by name, so a web
//! page cannot reach it through DNS rebinding.

use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener};
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{CONNECTION, CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE, HOST, ORIGIN};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};
use socket2::{Domain, Protocol, Socket, Type};
use tokio::sync::Semaphore;

use crate::ledger::{lock, Shared, Tally};
use crate::otel;
use crate::watch::unix_now;

/// Where Claude Code's `OTEL_EXPORTER_OTLP_ENDPOINT` points: the OTLP/HTTP
/// default port, on loopback only.
pub const ADDR: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 4318);
/// The largest request body accepted. Claude Code's biggest export, the
/// startup batch of plugin and hook events, is under 100 KB.
pub const MAX_BODY: usize = 4 * 1024 * 1024;

/// How long a connection may take over each part of a request, and how many
/// connections are served at once; the rest wait to be accepted.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Limits {
    pub header: Duration,
    pub body: Duration,
    pub connections: usize,
}

pub const LIMITS: Limits = Limits {
    header: Duration::from_secs(10),
    body: Duration::from_secs(10),
    connections: 32,
};

/// The accept loop's first and longest pause after an accept error.
const BACKOFF_FIRST: Duration = Duration::from_millis(10);
const BACKOFF_MAX: Duration = Duration::from_secs(1);

/// What became of one request, for the log.
pub type Log = Arc<dyn Fn(String) + Send + Sync>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Signal {
    Metrics,
    Logs,
}

/// The parts of a request that decide whether its body is read.
struct Head<'a> {
    method: &'a Method,
    path: &'a str,
    host: Option<&'a str>,
    origin: bool,
    content_type: Option<&'a str>,
    encoding: Option<&'a str>,
    length: Option<u64>,
}

/// Whether `host` names the receiver at `bound`: its address or `localhost`,
/// with its port. Any other name is a page that rebound its own.
fn our_host(host: Option<&str>, bound: SocketAddr) -> bool {
    let Some(host) = host else {
        return false;
    };
    let port = bound.port();
    host == format!("{}:{port}", bound.ip())
        || host.eq_ignore_ascii_case(&format!("localhost:{port}"))
}

/// The answer to a request, from its line and headers alone; Ok when the
/// body should be read.
fn admit(h: &Head, bound: SocketAddr) -> Result<Signal, StatusCode> {
    // A browser sends Origin on every cross-origin POST; the exporter never does.
    if h.origin || !our_host(h.host, bound) {
        return Err(StatusCode::FORBIDDEN);
    }
    let signal = match h.path {
        "/v1/metrics" => Signal::Metrics,
        "/v1/logs" => Signal::Logs,
        _ => return Err(StatusCode::NOT_FOUND),
    };
    if h.method != Method::POST {
        return Err(StatusCode::METHOD_NOT_ALLOWED);
    }
    let media = h
        .content_type
        .and_then(|c| c.split(';').next())
        .map(|m| m.trim().to_ascii_lowercase());
    if media.as_deref() != Some("application/json") {
        return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }
    if h.encoding
        .is_some_and(|e| !e.trim().eq_ignore_ascii_case("identity"))
    {
        return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }
    if h.length.is_some_and(|n| n > MAX_BODY as u64) {
        return Err(StatusCode::PAYLOAD_TOO_LARGE);
    }
    Ok(signal)
}

/// Count one body into the ledger and save it. Bad JSON is a 400.
fn ingest(signal: Signal, body: &[u8], ledger: &Shared, log: &Log) -> StatusCode {
    let Ok(value) = serde_json::from_slice::<serde_json::Value>(body) else {
        log(format!("otel: dropped a {signal:?} body that is not JSON"));
        return StatusCode::BAD_REQUEST;
    };
    let now = unix_now();
    let mut l = lock(ledger);
    let tally: Tally = match signal {
        Signal::Metrics => l.record_metrics(&otel::metrics(&value), now),
        Signal::Logs => l.record_events(&otel::logs(&value), now),
    };
    if tally.no_session > 0 || tally.future > 0 {
        log(format!(
            "otel: dropped {} points with no session.id, {} dated ahead",
            tally.no_session, tally.future
        ));
    }
    // A seeded baseline is saved too, or a restart counts its total again.
    if tally.counted > 0 || tally.seeded > 0 {
        if let Err(e) = l.save() {
            log(format!("otel: ledger not saved: {e}"));
        }
    }
    StatusCode::OK
}

fn reply(status: StatusCode) -> Response<Full<Bytes>> {
    // An OTLP success is an empty ExportServiceResponse.
    let body = if status == StatusCode::OK { "{}" } else { "" };
    let mut r = Response::new(Full::new(Bytes::from_static(body.as_bytes())));
    *r.status_mut() = status;
    let h = r.headers_mut();
    if status == StatusCode::OK {
        h.insert(CONTENT_TYPE, "application/json".parse().expect("static"));
    }
    // A stalled body would hold the connection while hyper drains it, and a
    // refused caller gets nothing more read from it. Other refusals keep
    // hyper's drain, so the client reads its answer before the close.
    if matches!(status, StatusCode::FORBIDDEN | StatusCode::REQUEST_TIMEOUT) {
        h.insert(CONNECTION, "close".parse().expect("static"));
    }
    r
}

async fn handle(
    req: Request<Incoming>,
    bound: SocketAddr,
    body_timeout: Duration,
    ledger: Shared,
    log: Log,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let header = |name| req.headers().get(name).and_then(|v| v.to_str().ok());
    let head = Head {
        method: req.method(),
        path: req.uri().path(),
        host: header(HOST),
        origin: req.headers().contains_key(ORIGIN),
        content_type: header(CONTENT_TYPE),
        encoding: header(CONTENT_ENCODING),
        length: header(CONTENT_LENGTH).and_then(|v| v.parse().ok()),
    };
    let signal = match admit(&head, bound) {
        Ok(s) => s,
        Err(status) => return Ok(reply(status)),
    };
    // A chunked body has no length up front, so the limit applies as it reads.
    let read = Limited::new(req.into_body(), MAX_BODY).collect();
    let body = match tokio::time::timeout(body_timeout, read).await {
        Err(_) => return Ok(reply(StatusCode::REQUEST_TIMEOUT)),
        Ok(Ok(b)) => b.to_bytes(),
        Ok(Err(e)) if e.is::<http_body_util::LengthLimitError>() => {
            return Ok(reply(StatusCode::PAYLOAD_TOO_LARGE))
        }
        Ok(Err(_)) => return Ok(reply(StatusCode::BAD_REQUEST)),
    };
    Ok(reply(ingest(signal, &body, &ledger, &log)))
}

/// The pause after another accept error in a row.
fn backoff(previous: Duration) -> Duration {
    previous.saturating_mul(2).clamp(BACKOFF_FIRST, BACKOFF_MAX)
}

/// Ask Windows for the port to ourselves: without this, another socket may
/// later bind the same address with SO_REUSEADDR and take our traffic.
#[cfg(windows)]
fn exclusive(s: &Socket) -> std::io::Result<()> {
    use std::os::windows::io::AsRawSocket;
    use windows_sys::Win32::Networking::WinSock::{setsockopt, SOL_SOCKET, SO_EXCLUSIVEADDRUSE};
    let on: i32 = 1;
    // SAFETY: a live socket handle, and a pointer to an i32 of the given length.
    let rc = unsafe {
        setsockopt(
            s.as_raw_socket() as _,
            SOL_SOCKET,
            SO_EXCLUSIVEADDRUSE,
            (&on as *const i32).cast(),
            std::mem::size_of::<i32>() as i32,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error())
    }
}

fn socket() -> std::io::Result<Socket> {
    let s = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP))?;
    #[cfg(windows)]
    exclusive(&s)?;
    // Linux refuses a second listener on a port whatever this says; it only
    // lets a restart bind while the last run's connections sit in TIME_WAIT.
    #[cfg(unix)]
    s.set_reuse_address(true)?;
    Ok(s)
}

/// Bind `s` to every address on `port`, for holding the port only. Windows
/// Firewall asks for an exception the first time an executable listens beyond
/// loopback, so nothing bound here may listen.
#[cfg(any(windows, test))]
fn bind_wildcard(s: &Socket, port: u16) -> std::io::Result<()> {
    s.bind(&SocketAddrV4::new(Ipv4Addr::UNSPECIFIED, port).into())
}

/// Bind `addr` as a listener. An address beyond loopback is refused, as
/// Windows Firewall would ask about it. On Windows a loopback bind succeeds
/// beside another process's wildcard listener on the same port, and
/// connections could then reach either, so an exclusive wildcard bind is tried
/// first and dropped: it fails while anything else holds the port. Linux
/// refuses that bind on its own.
fn bind(addr: SocketAddrV4) -> std::io::Result<TcpListener> {
    if !addr.ip().is_loopback() {
        return Err(std::io::Error::new(
            std::io::ErrorKind::InvalidInput,
            format!("listens on loopback only, not {addr}"),
        ));
    }
    #[cfg(windows)]
    if addr.port() != 0 {
        let probe = socket()?;
        bind_wildcard(&probe, addr.port())?;
    }
    let s = socket()?;
    s.bind(&addr.into())?;
    s.listen(128)?;
    Ok(s.into())
}

/// Bind `addr` now, so a port in use is reported to the caller, then serve
/// on a thread of its own for as long as the process runs. Returns the
/// address actually bound.
pub fn spawn(addr: SocketAddrV4, ledger: Shared, log: Log) -> std::io::Result<SocketAddr> {
    spawn_with(addr, LIMITS, ledger, log)
}

pub fn spawn_with(
    addr: SocketAddrV4,
    limits: Limits,
    ledger: Shared,
    log: Log,
) -> std::io::Result<SocketAddr> {
    let std_listener = bind(addr)?;
    std_listener.set_nonblocking(true)?;
    let bound = std_listener.local_addr()?;
    let runtime = tokio::runtime::Builder::new_current_thread()
        .enable_io()
        .enable_time()
        .build()?;
    std::thread::Builder::new()
        .name("otel-receiver".into())
        .spawn(move || {
            runtime.block_on(async move {
                let listener = match tokio::net::TcpListener::from_std(std_listener) {
                    Ok(l) => l,
                    Err(e) => return log(format!("otel: receiver stopped: {e}")),
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
                                log(format!("otel: accept failed: {e}"));
                            }
                            pause = backoff(pause);
                            tokio::time::sleep(pause).await;
                            continue;
                        }
                    };
                    let (ledger, log) = (ledger.clone(), log.clone());
                    tokio::spawn(async move {
                        let service = service_fn(move |req| {
                            handle(req, bound, limits.body, ledger.clone(), log.clone())
                        });
                        let _ = http1::Builder::new()
                            .timer(TokioTimer::new())
                            .header_read_timeout(limits.header)
                            .serve_connection(TokioIo::new(stream), service)
                            .await;
                        drop(slot);
                    });
                }
            });
        })?;
    Ok(bound)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::ledger::Ledger;
    use crate::otel::tests::fixtures;
    use std::io::{Read, Write};
    use std::net::TcpStream;
    use std::sync::Mutex;

    #[test]
    fn the_receiver_listens_on_loopback_port_4318() {
        assert_eq!(ADDR.ip(), &Ipv4Addr::LOCALHOST);
        assert_eq!(ADDR.port(), 4318);
        assert_eq!(MAX_BODY, 4 * 1024 * 1024);
    }

    fn adm(
        method: &Method,
        path: &str,
        content_type: Option<&str>,
        encoding: Option<&str>,
        length: Option<u64>,
    ) -> Result<Signal, StatusCode> {
        let head = Head {
            method,
            path,
            host: Some("127.0.0.1:4318"),
            origin: false,
            content_type,
            encoding,
            length,
        };
        admit(&head, SocketAddr::V4(ADDR))
    }

    #[test]
    fn only_requests_named_for_the_receiver_without_an_origin_are_admitted() {
        let bound = SocketAddr::V4(ADDR);
        let json = Some("application/json");
        let head = |host, origin| Head {
            method: &Method::POST,
            path: "/v1/logs",
            host,
            origin,
            content_type: json,
            encoding: None,
            length: None,
        };
        for host in ["127.0.0.1:4318", "localhost:4318", "LOCALHOST:4318"] {
            assert_eq!(
                admit(&head(Some(host), false), bound),
                Ok(Signal::Logs),
                "{host}"
            );
        }
        for host in [
            None,
            Some("evil.example:4318"),
            Some("127.0.0.1"),
            Some("localhost"),
            Some("127.0.0.1:4319"),
            Some("127.0.0.1.evil.example:4318"),
            Some("[::1]:4318"),
        ] {
            assert_eq!(
                admit(&head(host, false), bound),
                Err(StatusCode::FORBIDDEN),
                "{host:?}"
            );
        }
        assert_eq!(
            admit(&head(Some("127.0.0.1:4318"), true), bound),
            Err(StatusCode::FORBIDDEN)
        );
    }

    #[test]
    fn the_limits_and_the_backoff_are_as_set() {
        assert_eq!(LIMITS.header, Duration::from_secs(10));
        assert_eq!(LIMITS.body, Duration::from_secs(10));
        assert_eq!(LIMITS.connections, 32);
        let mut d = Duration::ZERO;
        let mut seen = Vec::new();
        for _ in 0..10 {
            d = backoff(d);
            seen.push(d.as_millis());
        }
        assert_eq!(seen, [10, 20, 40, 80, 160, 320, 640, 1000, 1000, 1000]);
    }

    #[test]
    fn requests_are_admitted_by_path_method_type_and_size() {
        let post = Method::POST;
        let json = Some("application/json");
        assert_eq!(
            adm(&post, "/v1/metrics", json, None, Some(10)),
            Ok(Signal::Metrics)
        );
        assert_eq!(
            adm(
                &post,
                "/v1/logs",
                Some("Application/JSON; charset=utf-8"),
                Some("identity"),
                None
            ),
            Ok(Signal::Logs)
        );
        assert_eq!(
            adm(&post, "/v1/traces", json, None, None),
            Err(StatusCode::NOT_FOUND)
        );
        assert_eq!(
            adm(&post, "/", json, None, None),
            Err(StatusCode::NOT_FOUND)
        );
        assert_eq!(
            adm(&Method::GET, "/v1/logs", json, None, None),
            Err(StatusCode::METHOD_NOT_ALLOWED)
        );
        assert_eq!(
            adm(
                &post,
                "/v1/logs",
                Some("application/x-protobuf"),
                None,
                None
            ),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            adm(&post, "/v1/logs", None, None, None),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            adm(&post, "/v1/logs", json, Some("gzip"), None),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            adm(&post, "/v1/logs", json, None, Some(MAX_BODY as u64)),
            Ok(Signal::Logs)
        );
        assert_eq!(
            adm(&post, "/v1/logs", json, None, Some(MAX_BODY as u64 + 1)),
            Err(StatusCode::PAYLOAD_TOO_LARGE)
        );
    }

    struct Server {
        addr: SocketAddr,
        ledger: Shared,
        lines: Arc<Mutex<Vec<String>>>,
    }

    fn server() -> Server {
        server_with(LIMITS)
    }

    const QUICK: Limits = Limits {
        header: Duration::from_millis(300),
        body: Duration::from_millis(300),
        connections: 2,
    };

    fn server_with(limits: Limits) -> Server {
        let ledger: Shared = Arc::new(Mutex::new(Ledger::in_memory(unix_now())));
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink = lines.clone();
        let log: Log = Arc::new(move |l| sink.lock().unwrap().push(l));
        let any_port = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0);
        let addr = spawn_with(any_port, limits, ledger.clone(), log).unwrap();
        Server {
            addr,
            ledger,
            lines,
        }
    }

    /// Send raw request bytes; the status code of the answer. The body goes
    /// from a thread of its own while the answer is read, since the server
    /// may answer, and close, before a large body is all sent.
    fn send(addr: SocketAddr, head: &str, body: &[u8]) -> u16 {
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s.write_all(head.as_bytes()).unwrap();
        let mut w = s.try_clone().unwrap();
        let body = body.to_vec();
        let writer = std::thread::spawn(move || {
            let _ = w.write_all(&body);
        });
        let mut out = String::new();
        let mut buf = [0u8; 512];
        while let Ok(n) = s.read(&mut buf) {
            if n == 0 {
                break;
            }
            out.push_str(&String::from_utf8_lossy(&buf[..n]));
            if out.contains("\r\n\r\n") {
                break;
            }
        }
        let _ = s.shutdown(std::net::Shutdown::Both);
        let _ = writer.join();
        out.split(' ')
            .nth(1)
            .and_then(|c| c.parse().ok())
            .unwrap_or(0)
    }

    fn post(addr: SocketAddr, path: &str, body: &[u8]) -> u16 {
        let head = format!(
            "POST {path} HTTP/1.1\r\nHost: {addr}\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        );
        send(addr, &head, body)
    }

    #[test]
    fn a_spawned_receiver_binds_loopback_only() {
        let s = server();
        assert!(s.addr.ip().is_loopback());
    }

    #[test]
    fn an_address_beyond_loopback_is_refused_before_any_bind() {
        for ip in [Ipv4Addr::new(0, 0, 0, 0), Ipv4Addr::new(10, 0, 0, 1)] {
            let ledger: Shared = Arc::new(Mutex::new(Ledger::in_memory(unix_now())));
            let log: Log = Arc::new(|_| {});
            let err = spawn(SocketAddrV4::new(ip, 0), ledger, log).unwrap_err();
            assert_eq!(err.kind(), std::io::ErrorKind::InvalidInput, "{ip}");
        }
    }

    #[test]
    fn a_taken_port_is_an_error_not_a_panic() {
        let s = server();
        let SocketAddr::V4(taken) = s.addr else {
            unreachable!()
        };
        let log: Log = Arc::new(|_| {});
        let again = spawn(taken, s.ledger.clone(), log);
        assert!(again.is_err());
    }

    #[test]
    fn exports_over_http_reach_the_ledger() {
        let s = server();
        // The recorded session is a few minutes old by now; only its events'
        // and points' shapes matter here, so restamp them to the present.
        let now_ns = (unix_now() as u64 * 1_000_000_000).to_string();
        for (name, v) in fixtures("delta") {
            let text = v.to_string();
            let text = restamp(&text, &now_ns);
            let path = if name.ends_with("metrics.json") {
                "/v1/metrics"
            } else {
                "/v1/logs"
            };
            assert_eq!(post(s.addr, path, text.as_bytes()), 200, "{name}");
        }
        let l = lock(&s.ledger);
        let t = l.session("4ce1be96-f12f-4c66-87eb-4ab36e451dc5").unwrap();
        assert_eq!(t.tokens.output, 706);
        assert_eq!(t.lines_added, 1);
        assert_eq!(t.guardrail_rejects, 1);
    }

    /// Post one cumulative export of 7 input tokens of "s1" to a receiver on
    /// the ledger in `dir`, reopen the ledger as after a crash, and return it
    /// with what a repeat of the export adds there.
    fn post_then_reopen(dir: &crate::scan::tests::Scratch) -> (Tally, Ledger) {
        let utc = || jiff::tz::TimeZone::UTC;
        let (l, _) = Ledger::open(dir.0.clone(), unix_now(), utc());
        let ledger: Shared = Arc::new(Mutex::new(l));
        let log: Log = Arc::new(|_| {});
        let any = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0);
        let addr = spawn_with(any, LIMITS, ledger, log).unwrap();
        let now = unix_now() as u64;
        let ns = |n: u64| (n * 1_000_000_000).to_string();
        let body = serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.token.usage","sum":{"aggregationTemporality":2,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":"s1"}},{"key":"type","value":{"stringValue":"input"}}],"startTimeUnixNano":ns(now - 60),"timeUnixNano":ns(now),"asDouble":7}]}}]}]}]});
        assert_eq!(post(addr, "/v1/metrics", body.to_string().as_bytes()), 200);
        let (mut again, problems) = Ledger::open(dir.0.clone(), unix_now(), utc());
        assert!(problems.is_empty(), "{problems:?}");
        let t = again.record_metrics(&otel::metrics(&body), unix_now());
        (t, again)
    }

    #[test]
    fn a_counted_cumulative_export_is_on_disk_when_it_is_answered() {
        let dir = crate::scan::tests::Scratch::new("receiver-saves");
        let (t, again) = post_then_reopen(&dir);
        // The baseline held: a repeat is a duplicate.
        assert_eq!((t.counted, t.duplicate), (0, 1));
        assert_eq!(again.session("s1").unwrap().tokens.input, 7);
    }

    #[test]
    fn a_seeded_baseline_is_on_disk_when_it_is_answered() {
        let dir = crate::scan::tests::Scratch::new("receiver-seeds");
        let today = crate::ledger::day_name(unix_now(), &jiff::tz::TimeZone::UTC);
        dir.write(
            &format!("{today}.json"),
            r#"{"sessions":{"s1":{"tokens":{"input":3}}}}"#,
        );
        dir.write(crate::ledger::STATE_FILE, "{not json");
        let (t, again) = post_then_reopen(&dir);
        assert_eq!((t.counted, t.duplicate), (0, 1));
        assert_eq!(again.day().sessions["s1"].tokens.input, 3);
    }

    /// Every nanosecond timestamp, and the event.sequence moved by the same
    /// file, set to `now`; keys stay distinct because windows still differ by
    /// start time and events by sequence.
    fn restamp(text: &str, now: &str) -> String {
        let mut v: serde_json::Value = serde_json::from_str(text).unwrap();
        fn walk(v: &mut serde_json::Value, now: &str) {
            match v {
                serde_json::Value::Object(m) => {
                    for (k, x) in m.iter_mut() {
                        if k == "timeUnixNano" || k == "observedTimeUnixNano" {
                            *x = serde_json::Value::String(now.into());
                        } else {
                            walk(x, now);
                        }
                    }
                }
                serde_json::Value::Array(a) => a.iter_mut().for_each(|x| walk(x, now)),
                _ => {}
            }
        }
        walk(&mut v, now);
        v.to_string()
    }

    #[test]
    fn bad_paths_bodies_and_sizes_get_their_status() {
        let s = server();
        assert_eq!(post(s.addr, "/v1/traces", b"{}"), 404);
        assert_eq!(post(s.addr, "/v1/metrics", b"{half"), 400);
        assert_eq!(post(s.addr, "/v1/metrics", b"\xff\xfe"), 400);
        assert_eq!(post(s.addr, "/v1/metrics", b"{}"), 200);
        assert_eq!(post(s.addr, "/v1/logs", b"[1,2,3]"), 200);
        let big = vec![b' '; MAX_BODY + 1];
        assert_eq!(post(s.addr, "/v1/logs", &big), 413);
        // A chunked body has no length up front and is cut off as it reads.
        let head = format!("POST /v1/logs HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n", s.addr);
        let mut chunked = Vec::new();
        for _ in 0..5 {
            chunked.extend_from_slice(format!("{:x}\r\n", 1024 * 1024).as_bytes());
            chunked.extend(std::iter::repeat_n(b' ', 1024 * 1024));
            chunked.extend_from_slice(b"\r\n");
        }
        chunked.extend_from_slice(b"0\r\n\r\n");
        assert_eq!(send(s.addr, &head, &chunked), 413);
        // Garbage instead of HTTP closes the connection; the server lives on.
        let mut g = TcpStream::connect(s.addr).unwrap();
        let _ = g.write_all(b"\x00\x01garbage\r\n\r\n");
        drop(g);
        assert_eq!(post(s.addr, "/v1/metrics", b"{}"), 200);
        assert!(s
            .lines
            .lock()
            .unwrap()
            .iter()
            .any(|l| l.contains("not JSON")));
    }

    /// A POST of `body` with these header lines (no Content-Length).
    fn post_with(addr: SocketAddr, headers: &[(&str, &str)], body: &[u8]) -> u16 {
        let mut head = String::from("POST /v1/metrics HTTP/1.1\r\n");
        for (k, v) in headers {
            head.push_str(&format!("{k}: {v}\r\n"));
        }
        head.push_str(&format!(
            "Content-Length: {}\r\nConnection: close\r\n\r\n",
            body.len()
        ));
        send(addr, &head, body)
    }

    fn fake_session(id: &str) -> Vec<u8> {
        let ns = (unix_now() as u64 * 1_000_000_000).to_string();
        serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"claude_code.commit.count","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"session.id","value":{"stringValue":id}}],"timeUnixNano":ns,"asDouble":1}]}}]}]}]}).to_string().into_bytes()
    }

    #[test]
    fn a_rebound_host_or_any_origin_is_refused() {
        let s = server();
        let json = ("Content-Type", "application/json");
        let host = s.addr.to_string();
        let evil = format!("evil.example:{}", s.addr.port());
        let body = fake_session("rebound");
        assert_eq!(post_with(s.addr, &[json, ("Host", &evil)], &body), 403);
        assert_eq!(
            post_with(
                s.addr,
                &[
                    json,
                    ("Host", "evil.example"),
                    ("Origin", "http://evil.example")
                ],
                &body
            ),
            403
        );
        assert_eq!(
            post_with(
                s.addr,
                &[json, ("Host", &host), ("Origin", "http://evil.example")],
                &body
            ),
            403
        );
        assert_eq!(post_with(s.addr, &[json], &body), 403, "no Host at all");
        assert!(lock(&s.ledger).session("rebound").is_none());
        let local = format!("localhost:{}", s.addr.port());
        assert_eq!(post_with(s.addr, &[json, ("Host", &local)], &body), 200);
    }

    #[test]
    fn the_recorded_live_request_headers_are_accepted() {
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests/fixtures/otel/request-headers.json");
        let rec: serde_json::Value =
            serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
        let s = server();
        let host = s.addr.to_string();
        let headers: Vec<(String, String)> = rec["headers"]
            .as_array()
            .unwrap()
            .iter()
            .map(|h| {
                (
                    h[0].as_str().unwrap().to_string(),
                    h[1].as_str().unwrap().to_string(),
                )
            })
            .filter(|(k, _)| {
                !k.eq_ignore_ascii_case("content-length") && !k.eq_ignore_ascii_case("connection")
            })
            .map(|(k, v)| {
                if k.eq_ignore_ascii_case("host") {
                    (k, host.clone())
                } else {
                    (k, v)
                }
            })
            .collect();
        assert!(headers
            .iter()
            .all(|(k, _)| !k.eq_ignore_ascii_case("origin")));
        let refs: Vec<(&str, &str)> = headers
            .iter()
            .map(|(k, v)| (k.as_str(), v.as_str()))
            .collect();
        assert_eq!(post_with(s.addr, &refs, &fake_session("live")), 200);
        assert!(lock(&s.ledger).session("live").is_some());
    }

    #[test]
    fn a_socket_holding_the_wildcard_port_is_a_clash() {
        let other = Socket::new(Domain::IPV4, Type::STREAM, Some(Protocol::TCP)).unwrap();
        bind_wildcard(&other, 0).unwrap();
        let port = other.local_addr().unwrap().as_socket_ipv4().unwrap().port();
        let ledger: Shared = Arc::new(Mutex::new(Ledger::in_memory(unix_now())));
        let log: Log = Arc::new(|_| {});
        let ours = spawn(SocketAddrV4::new(Ipv4Addr::LOCALHOST, port), ledger, log);
        assert!(
            ours.is_err(),
            "bound beside a socket holding the wildcard port"
        );
    }

    #[test]
    fn a_stalled_body_is_closed_within_the_timeout() {
        let s = server_with(QUICK);
        let mut c = TcpStream::connect(s.addr).unwrap();
        c.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let head = format!(
            "POST /v1/metrics HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: 100\r\n\r\n{{\"resource",
            s.addr
        );
        c.write_all(head.as_bytes()).unwrap();
        let started = std::time::Instant::now();
        let mut out = String::new();
        let mut buf = [0u8; 256];
        while let Ok(n) = c.read(&mut buf) {
            if n == 0 {
                break;
            }
            out.push_str(&String::from_utf8_lossy(&buf[..n]));
        }
        assert!(out.starts_with("HTTP/1.1 408"), "{out:?}");
        assert!(
            started.elapsed() < Duration::from_secs(2),
            "{:?}",
            started.elapsed()
        );
    }

    /// Whether the server closes `c` within `within`.
    fn closes(c: &mut TcpStream, within: Duration) -> bool {
        c.set_read_timeout(Some(within)).unwrap();
        let mut buf = [0u8; 64];
        loop {
            match c.read(&mut buf) {
                Ok(0) => return true,
                Ok(_) => continue,
                Err(e) => {
                    return matches!(
                        e.kind(),
                        std::io::ErrorKind::ConnectionReset | std::io::ErrorKind::ConnectionAborted
                    )
                }
            }
        }
    }

    #[test]
    fn a_silent_connection_is_closed_within_the_header_timeout() {
        let s = server_with(QUICK);
        let mut c = TcpStream::connect(s.addr).unwrap();
        c.write_all(b"POST /v1/me").unwrap();
        assert!(closes(&mut c, Duration::from_secs(3)));
        let mut idle = TcpStream::connect(s.addr).unwrap();
        assert!(closes(&mut idle, Duration::from_secs(3)));
    }

    #[test]
    fn connections_past_the_cap_wait_their_turn() {
        let s = server_with(Limits {
            header: Duration::from_secs(30),
            ..QUICK
        });
        // Two connections that say nothing hold both slots.
        let _a = TcpStream::connect(s.addr).unwrap();
        let _b = TcpStream::connect(s.addr).unwrap();
        std::thread::sleep(Duration::from_millis(200));
        let mut c = TcpStream::connect(s.addr).unwrap();
        c.set_read_timeout(Some(Duration::from_millis(500)))
            .unwrap();
        let head = format!(
            "POST /v1/metrics HTTP/1.1\r\nHost: {}\r\nContent-Type: application/json\r\nContent-Length: 2\r\nConnection: close\r\n\r\n{{}}",
            s.addr
        );
        c.write_all(head.as_bytes()).unwrap();
        let mut buf = [0u8; 64];
        assert!(c.read(&mut buf).is_err(), "served past the cap");
        drop(_a);
        c.set_read_timeout(Some(Duration::from_secs(5))).unwrap();
        let n = c.read(&mut buf).unwrap();
        assert!(String::from_utf8_lossy(&buf[..n]).starts_with("HTTP/1.1 200"));
    }
}
