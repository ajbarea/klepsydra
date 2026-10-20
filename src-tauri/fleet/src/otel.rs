//! Claude Code's OTLP/HTTP JSON exports, read into the points and events the
//! ledger counts. Unknown fields are ignored; a part that does not have the
//! expected shape is skipped, never a panic.

use std::collections::BTreeMap;

use serde_json::Value;

/// How a sum's data points relate to each other.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Temporality {
    /// Each point is the change over its own window (Claude Code's default).
    Delta,
    /// Each point is the running total since its start time.
    Cumulative,
}

/// One data point of a sum metric.
#[derive(Clone, Debug, PartialEq)]
pub struct Point {
    pub metric: String,
    pub temporality: Temporality,
    /// The series: resource, scope, metric and attribute set.
    pub series: u64,
    /// The series plus the point's window: what a retried export repeats.
    pub key: u64,
    pub start_ns: u64,
    pub end_ns: u64,
    pub value: f64,
    pub attrs: BTreeMap<String, String>,
}

/// One log record, named by its `event.name`.
#[derive(Clone, Debug, PartialEq)]
pub struct Event {
    pub name: String,
    /// Resource, scope, name, session, sequence and time: what a retried
    /// export repeats.
    pub key: u64,
    pub time_ns: u64,
    pub attrs: BTreeMap<String, String>,
}

/// 64-bit FNV-1a, which unlike std's hasher is fixed forever, so a key saved
/// to disk still matches after the app is rebuilt.
#[derive(Clone, Copy)]
struct Fnv(u64);

impl Fnv {
    fn new() -> Self {
        Fnv(0xcbf2_9ce4_8422_2325)
    }
    fn bytes(mut self, b: &[u8]) -> Self {
        for &x in b {
            self.0 ^= u64::from(x);
            self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        }
        // A separator, so ("ab", "c") and ("a", "bc") differ.
        self.0 ^= 0xff;
        self.0 = self.0.wrapping_mul(0x0000_0100_0000_01b3);
        self
    }
    fn str(self, s: &str) -> Self {
        self.bytes(s.as_bytes())
    }
    fn num(self, n: u64) -> Self {
        self.bytes(&n.to_le_bytes())
    }
}

/// An OTLP AnyValue as text: strings as they are, numbers and booleans
/// printed. Arrays and maps carry nothing the ledger reads.
fn any_value(v: &Value) -> Option<String> {
    let (kind, inner) = v.as_object()?.iter().next()?;
    match kind.as_str() {
        "stringValue" => inner.as_str().map(str::to_string),
        "boolValue" => inner.as_bool().map(|b| b.to_string()),
        "intValue" | "doubleValue" => match inner {
            Value::String(s) => Some(s.clone()),
            Value::Number(n) => Some(n.to_string()),
            _ => None,
        },
        _ => None,
    }
}

/// Longest attribute value kept, in characters; longer ones are cut, and
/// longer keys dropped.
pub const MAX_ATTR_CHARS: usize = 256;

/// A KeyValue list as a sorted map of the values that are text or numbers.
fn attributes(v: Option<&Value>) -> BTreeMap<String, String> {
    let mut out = BTreeMap::new();
    for kv in v.and_then(Value::as_array).into_iter().flatten() {
        let key = kv
            .get("key")
            .and_then(Value::as_str)
            .filter(|k| k.chars().count() <= MAX_ATTR_CHARS);
        let value = kv.get("value").and_then(any_value);
        if let (Some(k), Some(mut v)) = (key, value) {
            if let Some((cut, _)) = v.char_indices().nth(MAX_ATTR_CHARS) {
                v.truncate(cut);
            }
            out.insert(k.to_string(), v);
        }
    }
    out
}

fn hash_attrs(h: Fnv, attrs: &BTreeMap<String, String>) -> Fnv {
    attrs.iter().fold(h, |h, (k, v)| h.str(k).str(v))
}

/// A resource and scope as one hash, the part of every key they share.
fn origin(resource: Option<&Value>, scope: Option<&Value>) -> Fnv {
    let res = attributes(resource.and_then(|r| r.get("attributes")));
    let field = |k: &str| scope.and_then(|s| s.get(k)).and_then(Value::as_str);
    hash_attrs(Fnv::new(), &res)
        .str(field("name").unwrap_or(""))
        .str(field("version").unwrap_or(""))
}

/// A 64-bit integer that OTLP JSON writes as a string, or as a number.
fn uint(v: Option<&Value>) -> Option<u64> {
    match v? {
        Value::String(s) => s.parse().ok(),
        Value::Number(n) => n.as_u64(),
        _ => None,
    }
}

fn number(v: Option<&Value>) -> Option<f64> {
    match v? {
        Value::String(s) => s.parse().ok(),
        Value::Number(n) => n.as_f64(),
        _ => None,
    }
}

fn temporality(v: Option<&Value>) -> Option<Temporality> {
    match v? {
        Value::Number(n) => match n.as_u64()? {
            1 => Some(Temporality::Delta),
            2 => Some(Temporality::Cumulative),
            _ => None,
        },
        Value::String(s) => match s.as_str() {
            "AGGREGATION_TEMPORALITY_DELTA" => Some(Temporality::Delta),
            "AGGREGATION_TEMPORALITY_CUMULATIVE" => Some(Temporality::Cumulative),
            _ => None,
        },
        _ => None,
    }
}

fn list<'a>(v: &'a Value, key: &str) -> impl Iterator<Item = &'a Value> {
    v.get(key).and_then(Value::as_array).into_iter().flatten()
}

/// Every sum data point in an ExportMetricsServiceRequest. Gauges and
/// histograms are skipped: every Claude Code metric is a sum.
pub fn metrics(body: &Value) -> Vec<Point> {
    let mut out = Vec::new();
    for rm in list(body, "resourceMetrics") {
        for sm in list(rm, "scopeMetrics") {
            let from = origin(rm.get("resource"), sm.get("scope"));
            for m in list(sm, "metrics") {
                let (Some(name), Some(sum)) = (m.get("name").and_then(Value::as_str), m.get("sum"))
                else {
                    continue;
                };
                let Some(temporality) = temporality(sum.get("aggregationTemporality")) else {
                    continue;
                };
                for dp in list(sum, "dataPoints") {
                    let attrs = attributes(dp.get("attributes"));
                    let value = number(dp.get("asDouble")).or_else(|| number(dp.get("asInt")));
                    let (Some(end_ns), Some(value)) = (uint(dp.get("timeUnixNano")), value) else {
                        continue;
                    };
                    let start_ns = uint(dp.get("startTimeUnixNano")).unwrap_or(0);
                    let series = hash_attrs(from.str(name), &attrs);
                    out.push(Point {
                        metric: name.to_string(),
                        temporality,
                        series: series.0,
                        key: series.num(start_ns).num(end_ns).0,
                        start_ns,
                        end_ns,
                        value,
                        attrs,
                    });
                }
            }
        }
    }
    out
}

/// Every named log record in an ExportLogsServiceRequest.
pub fn logs(body: &Value) -> Vec<Event> {
    let mut out = Vec::new();
    for rl in list(body, "resourceLogs") {
        for sl in list(rl, "scopeLogs") {
            let from = origin(rl.get("resource"), sl.get("scope"));
            for lr in list(sl, "logRecords") {
                let attrs = attributes(lr.get("attributes"));
                let body_name = lr
                    .get("body")
                    .and_then(any_value)
                    .map(|b| b.trim_start_matches("claude_code.").to_string());
                let Some(name) = attrs.get("event.name").cloned().or(body_name) else {
                    continue;
                };
                let time_ns = uint(lr.get("timeUnixNano"))
                    .filter(|&t| t > 0)
                    .or_else(|| uint(lr.get("observedTimeUnixNano")))
                    .unwrap_or(0);
                let get = |k: &str| attrs.get(k).map_or("", String::as_str);
                let key = from
                    .str(&name)
                    .str(get("session.id"))
                    .str(get("event.sequence"))
                    .num(time_ns)
                    .0;
                out.push(Event {
                    name,
                    key,
                    time_ns,
                    attrs,
                });
            }
        }
    }
    out
}

#[cfg(test)]
pub(crate) mod tests {
    use super::*;
    use std::path::PathBuf;

    /// The recorded exports of one live session, in arrival order.
    pub fn fixtures(dir: &str) -> Vec<(String, Value)> {
        let root = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/otel");
        let mut files: Vec<PathBuf> = std::fs::read_dir(root.join(dir))
            .unwrap()
            .map(|e| e.unwrap().path())
            .collect();
        files.sort();
        files
            .into_iter()
            .map(|p| {
                let name = p.file_name().unwrap().to_string_lossy().into_owned();
                let v = serde_json::from_str(&std::fs::read_to_string(&p).unwrap()).unwrap();
                (name, v)
            })
            .collect()
    }

    fn all_points(dir: &str) -> Vec<Point> {
        fixtures(dir)
            .iter()
            .filter(|(n, _)| n.ends_with("metrics.json"))
            .flat_map(|(_, v)| metrics(v))
            .collect()
    }

    fn all_events(dir: &str) -> Vec<Event> {
        fixtures(dir)
            .iter()
            .filter(|(n, _)| n.ends_with("logs.json"))
            .flat_map(|(_, v)| logs(v))
            .collect()
    }

    #[test]
    fn the_recorded_metrics_parse_with_their_names_and_temporality() {
        let points = all_points("delta");
        let names: std::collections::BTreeSet<&str> =
            points.iter().map(|p| p.metric.as_str()).collect();
        assert_eq!(
            names.into_iter().collect::<Vec<_>>(),
            [
                "claude_code.active_time.total",
                "claude_code.code_edit_tool.decision",
                "claude_code.cost.usage",
                "claude_code.lines_of_code.count",
                "claude_code.session.count",
                "claude_code.token.usage",
            ]
        );
        assert!(points.iter().all(|p| p.temporality == Temporality::Delta));
        assert!(points
            .iter()
            .all(|p| p.attrs["session.id"] == "4ce1be96-f12f-4c66-87eb-4ab36e451dc5"));
        let out: f64 = points
            .iter()
            .filter(|p| p.metric == "claude_code.token.usage" && p.attrs["type"] == "output")
            .map(|p| p.value)
            .sum();
        assert_eq!(out, 269.0 + 306.0 + 131.0);
    }

    #[test]
    fn the_recorded_cumulative_export_reads_as_cumulative() {
        let points = all_points("cumulative");
        assert!(!points.is_empty());
        assert!(points
            .iter()
            .all(|p| p.temporality == Temporality::Cumulative));
    }

    #[test]
    fn the_recorded_events_parse_with_their_names() {
        let events = all_events("delta");
        let decisions: Vec<(&str, &str, &str)> = events
            .iter()
            .filter(|e| e.name == "tool_decision")
            .map(|e| {
                (
                    e.attrs["decision"].as_str(),
                    e.attrs["source"].as_str(),
                    e.attrs["tool_name"].as_str(),
                )
            })
            .collect();
        assert_eq!(
            decisions,
            [
                ("accept", "config", "Bash"),
                ("accept", "config", "Edit"),
                ("reject", "config", "Bash"),
            ]
        );
        let results: Vec<&str> = events
            .iter()
            .filter(|e| e.name == "tool_result")
            .map(|e| e.attrs["success"].as_str())
            .collect();
        assert_eq!(results, ["true", "true"]);
        // Content stays redacted at the source.
        let prompt = events.iter().find(|e| e.name == "user_prompt").unwrap();
        assert_eq!(prompt.attrs["prompt"], "<REDACTED>");
        // event.sequence is an intValue written as a JSON number.
        assert!(events
            .iter()
            .all(|e| e.attrs.contains_key("event.sequence")));
    }

    #[test]
    fn the_fixtures_carry_no_account_identity() {
        for (name, v) in fixtures("delta").into_iter().chain(fixtures("cumulative")) {
            let text = v.to_string();
            assert!(text.contains("user@example.invalid"), "{name}");
            assert!(!text.contains("user_01"), "{name}");
        }
    }

    #[test]
    fn keys_differ_by_window_and_series_by_attributes() {
        let body = |start: &str, end: &str, kind: &str| serde_json::json!({"resourceMetrics":[{"resource":{"attributes":[]},"scopeMetrics":[{"scope":{"name":"s"},"metrics":[{"name":"m","sum":{"aggregationTemporality":1,"dataPoints":[{"attributes":[{"key":"type","value":{"stringValue":kind}}],"startTimeUnixNano":start,"timeUnixNano":end,"asDouble":1}]}}]}]}]});
        let a = &metrics(&body("1", "2", "x"))[0];
        let b = &metrics(&body("2", "3", "x"))[0];
        let c = &metrics(&body("1", "2", "y"))[0];
        assert_eq!(a.series, b.series);
        assert_ne!(a.key, b.key);
        assert_ne!(a.series, c.series);
        assert_eq!(a.key, metrics(&body("1", "2", "x"))[0].key);
    }

    #[test]
    fn malformed_shapes_are_skipped_without_a_panic() {
        for text in [
            "null",
            "[]",
            "{}",
            r#"{"resourceMetrics":7}"#,
            r#"{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"m"}]}]}]}"#,
            r#"{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"m","sum":{"aggregationTemporality":9,"dataPoints":[{}]}}]}]}]}"#,
            r#"{"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"m","sum":{"aggregationTemporality":1,"dataPoints":[{"timeUnixNano":"x","asDouble":"y"},{"attributes":[{"key":5},{"value":{}}]}]}}]}]}]}"#,
            r#"{"resourceLogs":[{"scopeLogs":[{"logRecords":[{},{"attributes":"no"},{"body":{"kvlistValue":{}}}]}]}]}"#,
        ] {
            let v: Value = serde_json::from_str(text).unwrap();
            assert!(metrics(&v).is_empty(), "{text}");
            assert!(logs(&v).is_empty(), "{text}");
        }
    }

    #[test]
    fn int_and_string_encodings_both_read() {
        let v = serde_json::json!({"resourceMetrics":[{"scopeMetrics":[{"metrics":[{"name":"m","sum":{"aggregationTemporality":"AGGREGATION_TEMPORALITY_CUMULATIVE","dataPoints":[{"timeUnixNano":5,"asInt":"42"}]}}]}]}]});
        let p = &metrics(&v)[0];
        assert_eq!(p.temporality, Temporality::Cumulative);
        assert_eq!((p.end_ns, p.value), (5, 42.0));
    }

    #[test]
    fn long_attribute_values_are_cut_to_the_cap() {
        let long = "é".repeat(1000);
        let v = serde_json::json!({"resourceLogs":[{"scopeLogs":[{"logRecords":[{"timeUnixNano":"1","attributes":[{"key":"event.name","value":{"stringValue":"tool_result"}},{"key":"tool_name","value":{"stringValue":long}}]}]}]}]});
        let e = &logs(&v)[0];
        assert_eq!(e.attrs["tool_name"].chars().count(), 256);
    }
}
