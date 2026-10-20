//! A local OTLP/HTTP JSON receiver: Claude Code posts its metrics and events
//! here and the ledger counts them. It listens on the loopback interface only.

use std::convert::Infallible;
use std::net::{Ipv4Addr, SocketAddr, SocketAddrV4, TcpListener};
use std::sync::Arc;
use std::time::Duration;

use http_body_util::{BodyExt, Full, Limited};
use hyper::body::{Bytes, Incoming};
use hyper::header::{CONTENT_ENCODING, CONTENT_LENGTH, CONTENT_TYPE};
use hyper::server::conn::http1;
use hyper::service::service_fn;
use hyper::{Method, Request, Response, StatusCode};
use hyper_util::rt::{TokioIo, TokioTimer};

use crate::ledger::{lock, Shared, Tally};
use crate::otel;
use crate::watch::unix_now;

/// Where Claude Code's `OTEL_EXPORTER_OTLP_ENDPOINT` points: the OTLP/HTTP
/// default port, on loopback only.
pub const ADDR: SocketAddrV4 = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 4318);
/// The largest request body accepted. Claude Code's biggest export, the
/// startup batch of plugin and hook events, is under 100 KB.
pub const MAX_BODY: usize = 4 * 1024 * 1024;
/// How long a connection may take to send its request headers.
const HEADER_TIMEOUT: Duration = Duration::from_secs(10);

/// What became of one request, for the log.
pub type Log = Arc<dyn Fn(String) + Send + Sync>;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Signal {
    Metrics,
    Logs,
}

/// The answer to a request, from its line and headers alone; Ok when the
/// body should be read.
fn admit(
    method: &Method,
    path: &str,
    content_type: Option<&str>,
    encoding: Option<&str>,
    length: Option<u64>,
) -> Result<Signal, StatusCode> {
    let signal = match path {
        "/v1/metrics" => Signal::Metrics,
        "/v1/logs" => Signal::Logs,
        _ => return Err(StatusCode::NOT_FOUND),
    };
    if method != Method::POST {
        return Err(StatusCode::METHOD_NOT_ALLOWED);
    }
    let media = content_type
        .and_then(|c| c.split(';').next())
        .map(|m| m.trim().to_ascii_lowercase());
    if media.as_deref() != Some("application/json") {
        return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }
    if encoding.is_some_and(|e| !e.trim().eq_ignore_ascii_case("identity")) {
        return Err(StatusCode::UNSUPPORTED_MEDIA_TYPE);
    }
    if length.is_some_and(|n| n > MAX_BODY as u64) {
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
    if tally.counted > 0 {
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
    if status == StatusCode::OK {
        r.headers_mut()
            .insert(CONTENT_TYPE, "application/json".parse().expect("static"));
    }
    r
}

async fn handle(
    req: Request<Incoming>,
    ledger: Shared,
    log: Log,
) -> Result<Response<Full<Bytes>>, Infallible> {
    let header = |name| req.headers().get(name).and_then(|v| v.to_str().ok());
    let length = header(CONTENT_LENGTH).and_then(|v| v.parse().ok());
    let signal = match admit(
        req.method(),
        req.uri().path(),
        header(CONTENT_TYPE),
        header(CONTENT_ENCODING),
        length,
    ) {
        Ok(s) => s,
        Err(status) => return Ok(reply(status)),
    };
    // A chunked body has no length up front, so the limit applies as it reads.
    let body = match Limited::new(req.into_body(), MAX_BODY).collect().await {
        Ok(b) => b.to_bytes(),
        Err(e) if e.is::<http_body_util::LengthLimitError>() => {
            return Ok(reply(StatusCode::PAYLOAD_TOO_LARGE))
        }
        Err(_) => return Ok(reply(StatusCode::BAD_REQUEST)),
    };
    Ok(reply(ingest(signal, &body, &ledger, &log)))
}

/// Bind `addr` now, so a port in use is reported to the caller, then serve
/// on a thread of its own for as long as the process runs. Returns the
/// address actually bound.
pub fn spawn(addr: SocketAddrV4, ledger: Shared, log: Log) -> std::io::Result<SocketAddr> {
    let std_listener = TcpListener::bind(addr)?;
    std_listener.set_nonblocking(true)?;
    let local = std_listener.local_addr()?;
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
                loop {
                    let Ok((stream, _)) = listener.accept().await else {
                        continue;
                    };
                    let (ledger, log) = (ledger.clone(), log.clone());
                    tokio::spawn(async move {
                        let service =
                            service_fn(move |req| handle(req, ledger.clone(), log.clone()));
                        let _ = http1::Builder::new()
                            .timer(TokioTimer::new())
                            .header_read_timeout(HEADER_TIMEOUT)
                            .serve_connection(TokioIo::new(stream), service)
                            .await;
                    });
                }
            });
        })?;
    Ok(local)
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

    #[test]
    fn requests_are_admitted_by_path_method_type_and_size() {
        let post = Method::POST;
        let json = Some("application/json");
        assert_eq!(
            admit(&post, "/v1/metrics", json, None, Some(10)),
            Ok(Signal::Metrics)
        );
        assert_eq!(
            admit(
                &post,
                "/v1/logs",
                Some("Application/JSON; charset=utf-8"),
                Some("identity"),
                None
            ),
            Ok(Signal::Logs)
        );
        assert_eq!(
            admit(&post, "/v1/traces", json, None, None),
            Err(StatusCode::NOT_FOUND)
        );
        assert_eq!(
            admit(&post, "/", json, None, None),
            Err(StatusCode::NOT_FOUND)
        );
        assert_eq!(
            admit(&Method::GET, "/v1/logs", json, None, None),
            Err(StatusCode::METHOD_NOT_ALLOWED)
        );
        assert_eq!(
            admit(
                &post,
                "/v1/logs",
                Some("application/x-protobuf"),
                None,
                None
            ),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            admit(&post, "/v1/logs", None, None, None),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            admit(&post, "/v1/logs", json, Some("gzip"), None),
            Err(StatusCode::UNSUPPORTED_MEDIA_TYPE)
        );
        assert_eq!(
            admit(&post, "/v1/logs", json, None, Some(MAX_BODY as u64)),
            Ok(Signal::Logs)
        );
        assert_eq!(
            admit(&post, "/v1/logs", json, None, Some(MAX_BODY as u64 + 1)),
            Err(StatusCode::PAYLOAD_TOO_LARGE)
        );
    }

    struct Server {
        addr: SocketAddr,
        ledger: Shared,
        lines: Arc<Mutex<Vec<String>>>,
    }

    fn server() -> Server {
        let ledger: Shared = Arc::new(Mutex::new(Ledger::in_memory(unix_now())));
        let lines = Arc::new(Mutex::new(Vec::new()));
        let sink = lines.clone();
        let log: Log = Arc::new(move |l| sink.lock().unwrap().push(l));
        let any_port = SocketAddrV4::new(Ipv4Addr::LOCALHOST, 0);
        let addr = spawn(any_port, ledger.clone(), log).unwrap();
        Server {
            addr,
            ledger,
            lines,
        }
    }

    /// Send raw request bytes; the status code of the answer.
    fn send(addr: SocketAddr, head: &str, body: &[u8]) -> u16 {
        let mut s = TcpStream::connect(addr).unwrap();
        s.set_read_timeout(Some(Duration::from_secs(10))).unwrap();
        s.write_all(head.as_bytes()).unwrap();
        // The server may answer and close before a large body is all sent.
        let _ = s.write_all(body);
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
        out.split(' ')
            .nth(1)
            .and_then(|c| c.parse().ok())
            .unwrap_or(0)
    }

    fn post(addr: SocketAddr, path: &str, body: &[u8]) -> u16 {
        let head = format!(
            "POST {path} HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nContent-Length: {}\r\nConnection: close\r\n\r\n",
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
        let head = "POST /v1/logs HTTP/1.1\r\nHost: x\r\nContent-Type: application/json\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n";
        let mut chunked = Vec::new();
        for _ in 0..5 {
            chunked.extend_from_slice(format!("{:x}\r\n", 1024 * 1024).as_bytes());
            chunked.extend(std::iter::repeat_n(b' ', 1024 * 1024));
            chunked.extend_from_slice(b"\r\n");
        }
        chunked.extend_from_slice(b"0\r\n\r\n");
        assert_eq!(send(s.addr, head, &chunked), 413);
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
}
