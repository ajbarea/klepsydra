"""Write src/dev-fleet.json (gitignored): the three cards of the #247/#248 shots,
Hephaestus needing you, Cupid working and Mneme done, from the demo fleet."""
import copy, json, pathlib
root = pathlib.Path(__file__).resolve().parents[2]
d = json.loads((root / "scripts/fixtures/fleet-demo.json").read_text())
by = {s["voice"]: s for s in d["sessions"] if s.get("voice")}
cupid = copy.deepcopy(by["af_bella"]) | {"voice": "af_heart", "session_id": "demo-x-af_heart"}
d["sessions"], d["speaking"] = [by["am_michael"], cupid, by["bf_isabella"]], None
(root / "src/dev-fleet.json").write_text(json.dumps(d, indent=1))
