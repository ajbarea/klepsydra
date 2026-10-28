"""Write N demo sessions as fleet session files, for the performance run.

The sessions come from scripts/fixtures/fleet-demo.json (the wall's ?demo
sample, so nothing private), skipping ended ones, with ids made UUID-shaped
as the reader requires and every time moved up to now.

    python3 -I scripts/perf/fixture.py N DIR       writes DIR/fleet/<id>.json
"""

import json
import pathlib
import sys
import time
import uuid

DEMO = pathlib.Path(__file__).resolve().parent.parent / "fixtures/fleet-demo.json"


def session(s, now):
    shift = now - s["status_at"]
    at = lambda t: t + shift if isinstance(t, int) else t  # noqa: E731
    sid = str(uuid.uuid5(uuid.NAMESPACE_URL, "klepsydra-perf/" + s["session_id"]))
    out = {
        "v": 1,
        "session_id": sid,
        "name": s.get("name"),
        "launch_dir": s.get("launch_dir"),
        "started_at": at(s.get("status_at")) - 3600,
        "voice": s.get("voice"),
        "state": s["status"],
        "reason": s.get("reason"),
        "state_at": at(s["status_at"]),
        "touched": [{**t, "at": at(t["at"])} for t in s.get("touched", [])],
        "error": s.get("error"),
        "written_at": now,
    }
    if s.get("where"):
        out["where"] = {**s["where"], "at": at(s["where"]["at"])}
    for k in ("prompt", "reply"):
        if s.get(k):
            out[k] = {**s[k], "at": at(s[k]["at"])}
    return sid, out


def main():
    n, root = int(sys.argv[1]), pathlib.Path(sys.argv[2])
    fleet = root / "fleet"
    fleet.mkdir(parents=True, exist_ok=True)
    for old in fleet.glob("*.json"):
        old.unlink()
    live = [s for s in json.loads(DEMO.read_text())["sessions"] if s["status"] != "ended"]
    if n > len(live):
        sys.exit(f"the demo has {len(live)} live sessions; asked for {n}")
    now = int(time.time())
    for s in live[:n]:
        sid, body = session(s, now)
        (fleet / f"{sid}.json").write_text(json.dumps(body))
    print(f"{n} sessions in {fleet}")


if __name__ == "__main__":
    main()
