"""The perf fixture writes only what it owns and puts no time in the future.

    python3 -I scripts/perf/test_fixture.py
"""

import json
import pathlib
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
import fixture  # beside this file

failed = 0


def check(ok, what, got=None):
    global failed
    print(("ok " if ok else "FAIL ") + what + ("" if ok else f": {got}"))
    failed += not ok


NOW = 1_800_000_000
with tempfile.TemporaryDirectory() as tmp:
    fleet = fixture.write(10, tmp, now=NOW)
    files = sorted(fleet.glob("*.json"))
    bodies = [json.loads(f.read_text()) for f in files]
    check(len(files) == 10, "writes N session files", len(files))
    check(all(f.stem == b["session_id"] for f, b in zip(files, bodies, strict=True)), "each file is named by its session_id")
    times = [b["state_at"] for b in bodies] + [b[k]["at"] for b in bodies for k in ("prompt", "reply", "where") if k in b]
    check(max(times) <= NOW, "no time is in the future", max(times) - NOW)

    fixture.write(3, tmp, now=NOW)
    check(len(list(fleet.glob("*.json"))) == 3, "a rerun replaces its own files", len(list(fleet.glob("*.json"))))

    stranger = fleet / "16647344-cedf-4667-b1ce-d9a8095bbc79.json"
    stranger.write_text("{}")
    try:
        fixture.write(3, tmp, now=NOW)
        refused = False
    except SystemExit:
        refused = True
    check(refused and stranger.exists() and len(list(fleet.glob("*.json"))) == 4,
          "a folder holding a session it did not write is refused and left as it was")

print(f"{failed} failed")
sys.exit(1 if failed else 0)
