"""Tests for agora.py against a scratch klepsydra folder and fake sessions.
Run: python3 -I fleet/test_agora.py"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
NOW = 1_793_300_000
SID = "11111111-2222-4333-8444-555555555555"


class Agora(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(tempfile.mkdtemp())
        self.k = self.tmp / "k"
        (self.k / "fleet").mkdir(parents=True)
        (self.k / "cast.json").write_text(
            json.dumps(
                {
                    "characters": {
                        "am_michael": {"name": "Hephaestus"},
                        "af_nova": {"name": "Metis"},
                        "bf_emma": {"name": "Mneme"},
                    }
                }
            )
        )
        self.live(fleet_name="techne-evals", voice=None)
        (self.k / "picks.json").write_text(
            json.dumps({"agent:techne-evals": "af_nova"})
        )

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def live(self, sid=SID, pane="%4", ended=None, **fields):
        s = {
            "session_id": sid,
            "tmux": {"socket": "/tmp/tmux-1000/klepsydra", "pane": pane},
            "ended": ended,
            "where": {"repo": "techne"},
        } | fields
        (self.k / "fleet" / f"{sid}.json").write_text(json.dumps(s))

    def run_agora(
        self,
        *args,
        now=NOW,
        pane="%4",
        socket="/tmp/tmux-1000/klepsydra",
        gitleaks="none",
    ):
        env = os.environ | {
            "KLEPSYDRA_DIR": str(self.k),
            "FLEET_STATE": str(self.tmp / "state"),
            "FLEET_NOW": str(now),
            "TMUX": f"{socket},1,0",
            "TMUX_PANE": pane,
            "FLEET_GITLEAKS": gitleaks,
        }
        r = subprocess.run(
            [sys.executable, "-I", str(HERE / "agora.py"), *args],
            capture_output=True,
            text=True,
            env=env,
        )
        return r.returncode, r.stdout.strip()

    def posts(self):
        path = self.k / "agora" / "posts.jsonl"
        return (
            [json.loads(x) for x in path.read_text().splitlines()]
            if path.exists()
            else []
        )

    def test_a_post_is_signed_with_the_agents_character_repo_and_time(self):
        rc, out = self.run_agora(
            "post",
            "--kind",
            "gripe",
            "--link",
            "https://github.com/ajbarea/klepsydra/issues/187",
            "lock",
            "waits",
            "again",
        )
        self.assertEqual((rc, out), (0, "Posted as Metis."))
        (p,) = self.posts()
        self.assertEqual(
            {
                k: p[k]
                for k in (
                    "at",
                    "who",
                    "character",
                    "name",
                    "repo",
                    "kind",
                    "text",
                    "link",
                )
            },
            {
                "at": NOW,
                "who": "techne-evals",
                "character": "af_nova",
                "name": "Metis",
                "repo": "techne",
                "kind": "gripe",
                "text": "lock waits again",
                "link": "https://github.com/ajbarea/klepsydra/issues/187",
            },
        )
        rc, out = self.run_agora("list")
        self.assertIn("Metis (techne) [gripe] lock waits again", out)

    def test_the_orchestrator_signs_as_heph_and_an_own_voice_signs_as_itself(self):
        self.live(orchestrator=True, voice="bf_emma")
        self.assertEqual(self.run_agora("post", "a win")[1], "Posted as Hephaestus.")
        self.live(
            sid="22222222-2222-4333-8444-555555555555", pane="%5", voice="bf_emma"
        )
        self.assertEqual(self.run_agora("post", "x", pane="%5")[1], "Posted as Mneme.")

    def test_one_post_an_hour_per_agent(self):
        self.assertEqual(self.run_agora("post", "first")[0], 0)
        rc, out = self.run_agora("post", "second", now=NOW + 1800)
        self.assertEqual(rc, 4)
        self.assertIn("post again in 31 min", out)
        self.assertEqual(self.run_agora("post", "third", now=NOW + 3600)[0], 0)
        self.assertEqual([p["text"] for p in self.posts()], ["first", "third"])

    def test_a_secret_shaped_post_is_refused_and_not_written(self):
        token = "ghp_" + "A1b2C3d4E5f6G7h8I9j0K1l2M3n4O5p6Q7r8"
        rc, out = self.run_agora("post", f"my token is {token}")
        self.assertEqual(rc, 3)
        self.assertIn("looks like it holds a secret", out)
        self.assertEqual(self.posts(), [])
        self.assertNotIn(token, (self.tmp / "state" / "log" / "agora.log").read_text())

    def test_gitleaks_is_asked_when_installed(self):
        fake = self.tmp / "gitleaks"
        fake.write_text("#!/usr/bin/env bash\ngrep -q LEAKY && exit 1\nexit 0\n")
        fake.chmod(0o755)
        self.assertEqual(self.run_agora("post", "LEAKY text", gitleaks=str(fake))[0], 3)
        self.assertEqual(self.run_agora("post", "clean text", gitleaks=str(fake))[0], 0)

    def test_only_from_a_live_fleet_session_and_within_the_limits(self):
        self.assertEqual(
            self.run_agora("post", "x", pane="%9")[0], 2, "no session in this pane"
        )
        self.assertEqual(
            self.run_agora("post", "x", socket="/tmp/tmux-1000/default")[0],
            2,
            "another tmux server",
        )
        self.assertEqual(self.run_agora("post", "y" * 281)[0], 2, "over 280 characters")
        self.assertEqual(
            self.run_agora("post", "x", "--link", "https://evil.example/x")[0], 2
        )
        self.live(ended={"at": 1})
        self.assertEqual(self.run_agora("post", "x")[0], 2, "an ended session")
        self.assertEqual(self.posts(), [])

    def test_a_full_file_moves_to_the_archive(self):
        (self.k / "agora").mkdir()
        big = json.dumps({"at": 1, "who": "old", "text": "z" * 200}) + "\n"
        (self.k / "agora" / "posts.jsonl").write_text(big * 1400)
        self.assertEqual(self.run_agora("post", "fresh")[0], 0)
        self.assertEqual([p["text"] for p in self.posts()], ["fresh"])
        self.assertEqual(
            len(list((self.k / "agora" / "archive").glob("posts-*.jsonl"))), 1
        )

    def test_control_characters_are_flattened(self):
        self.run_agora("post", "two\nlines\x1b[31m")
        self.assertEqual(self.posts()[0]["text"], "two lines [31m")


if __name__ == "__main__":
    unittest.main()
