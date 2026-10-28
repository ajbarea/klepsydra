"""Write N demo sessions as fleet session files, for the performance run.

The sessions come from scripts/fixtures/fleet-demo.json (the wall's ?demo
sample, so nothing private), skipping ended ones, with ids made UUID-shaped
as the reader requires and every time moved by the one shift that puts the
demo's `at` at now, so no time lands in the future.

    python3 -I scripts/perf/fixture.py N DIR       writes DIR/fleet/<id>.json

A DIR/fleet that holds any other session file is refused, so pointing this
at the app's real data folder deletes nothing.
"""

import json
import pathlib
import sys
import time
import uuid

DEMO = pathlib.Path(__file__).resolve().parent.parent / "fixtures/fleet-demo.json"


def demo_id(session_id):
    return str(uuid.uuid5(uuid.NAMESPACE_URL, "klepsydra-perf/" + session_id))


def session(s, shift, now):
    def at(t):
        return t + shift if isinstance(t, int) else t

    sid = demo_id(s["session_id"])
    out = {
        "v": 1,
        "session_id": sid,
        "name": s.get("name"),
        "launch_dir": s.get("launch_dir"),
        "started_at": at(s["status_at"]) - 3600,
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


def write(n, root, now=None):
    demo = json.loads(DEMO.read_text())
    live = [s for s in demo["sessions"] if s["status"] != "ended"]
    if n > len(live):
        raise SystemExit(f"the demo has {len(live)} live sessions; asked for {n}")
    ours = {demo_id(s["session_id"]) for s in demo["sessions"]}
    fleet = pathlib.Path(root) / "fleet"
    fleet.mkdir(parents=True, exist_ok=True)
    others = sorted(p.name for p in fleet.glob("*.json") if p.stem not in ours)
    if others:
        raise SystemExit(f"{fleet} holds sessions this script did not write ({others[0]} and {len(others) - 1} more); refusing to touch it")
    for old in fleet.glob("*.json"):
        old.unlink()
    now = int(time.time()) if now is None else now
    shift = now - demo["at"]
    for s in live[:n]:
        sid, body = session(s, shift, now)
        (fleet / f"{sid}.json").write_text(json.dumps(body))
    return fleet


if __name__ == "__main__":
    print(f"{sys.argv[1]} sessions in {write(int(sys.argv[1]), sys.argv[2])}")
