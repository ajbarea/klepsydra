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
                        "bf_alice": {"name": "Athena"},
                    }
                }
            )
        )
        (self.tmp / "state").mkdir()
        self.bin = self.tmp / "bin"
        self.bin.mkdir()
        tmux = self.bin / "tmux"
        tmux.write_text(
            '#!/usr/bin/env bash\nif [[ $FAKE_TMUX_PID == parent ]]; then echo "$PPID"; else echo "$FAKE_TMUX_PID"; fi\n'
        )
        tmux.chmod(0o755)
        self.live(voice=None)
        self.register("%4", "techne-evals", SID)
        (self.k / "picks.json").write_text(json.dumps({SID: "af_nova"}))

    def tearDown(self):
        shutil.rmtree(self.tmp, ignore_errors=True)

    def register(self, pane, name, sid):
        rows = self.tmp / "state" / "panes.tsv"
        old = rows.read_text() if rows.exists() else ""
        kept = "".join(r + "\n" for r in old.splitlines() if r.split("\t")[1] != name)
        rows.write_text(kept + f"{pane}\t{name}\t/b/task-{name}.src\t{sid}\t/w\t\n")

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
        tmux_pid="parent",
    ):
        env = os.environ | {
            "KLEPSYDRA_DIR": str(self.k),
            "FLEET_STATE": str(self.tmp / "state"),
            "FLEET_NOW": str(now),
            "TMUX": f"{socket},1,0",
            "TMUX_PANE": pane,
            "FLEET_GITLEAKS": gitleaks,
            # A fake tmux on PATH names the pane's process: agora.py itself
            # (its parent), or pid 1, a pane the poster does not run in.
            "PATH": f"{self.bin}:{os.environ['PATH']}",
            "FAKE_TMUX_PID": tmux_pid,
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
        (self.tmp / "state" / "orchestrator.session").write_text(SID + "\n")
        self.live(voice="bf_emma")
        self.assertEqual(self.run_agora("post", "a win")[1], "Posted as Hephaestus.")
        self.assertEqual(self.posts()[0]["who"], "heph")
        (self.tmp / "state" / "orchestrator.session").unlink()
        self.live(
            sid="22222222-2222-4333-8444-555555555555", pane="%5", voice="bf_emma"
        )
        self.register("%5", "sphragis", "22222222-2222-4333-8444-555555555555")
        self.assertEqual(self.run_agora("post", "x", pane="%5")[1], "Posted as Mneme.")

    def test_an_orchestrator_wearing_athena_signs_as_athena_and_no_worker_does(self):
        (self.tmp / "state" / "orchestrator.session").write_text(SID + "\n")
        self.live(voice="am_puck", orchestrator_face="bf_alice")
        self.assertEqual(self.run_agora("post", "a win")[1], "Posted as Athena.")
        (self.tmp / "state" / "orchestrator.session").unlink()
        self.live(voice="bf_alice")
        self.assertEqual(
            self.run_agora("post", "x", now=NOW + 3601)[1], "Posted as Metis."
        )

    def test_a_relaunched_agent_is_still_held_to_one_post_an_hour(self):
        self.assertEqual(self.run_agora("post", "first")[0], 0)
        (self.k / "fleet" / f"{SID}.json").unlink()
        new = "33333333-2222-4333-8444-555555555555"
        self.live(sid=new, pane="%9")
        self.register("%9", "techne-evals", new)
        self.assertEqual(self.run_agora("post", "again", pane="%9", now=NOW + 60)[0], 4)

    def test_a_post_from_outside_the_pane_it_names_is_refused(self):
        self.assertEqual(self.run_agora("post", "spoofed", tmux_pid="1")[0], 2)
        self.assertEqual(self.posts(), [])

    def test_a_scan_with_no_verdict_refuses_and_says_why_in_the_log(self):
        fake = self.tmp / "gitleaks"
        fake.write_text("#!/usr/bin/env bash\necho 'unknown flag' >&2\nexit 126\n")
        fake.chmod(0o755)
        self.assertEqual(self.run_agora("post", "fine text", gitleaks=str(fake))[0], 3)
        log = (self.tmp / "state" / "log" / "agora.log").read_text()
        self.assertIn('"rc": 126', log)
        self.assertNotIn("fine text", log)

    def test_a_session_the_registry_does_not_name_cannot_post(self):
        other = "44444444-2222-4333-8444-555555555555"
        self.live(sid=other, pane="%6")
        self.assertEqual(self.run_agora("post", "who am i", pane="%6")[0], 2)
        self.assertEqual(self.posts(), [])

    def test_a_new_heph_in_his_pane_posts_as_heph_before_he_is_recorded(self):
        (self.tmp / "state" / "orchestrator.session").write_text("old-session\n")
        (self.tmp / "state" / "orchestrator.pane").write_text("%0\n")
        new = "55555555-2222-4333-8444-555555555555"
        self.live(sid=new, pane="%0")
        self.assertEqual(
            self.run_agora("post", "back", pane="%0")[1], "Posted as Hephaestus."
        )

    def test_a_stale_registry_row_for_this_pane_names_no_one(self):
        self.register("%4", "techne-evals", "66666666-2222-4333-8444-555555555555")
        self.assertEqual(self.run_agora("post", "who")[0], 2)
        (self.tmp / "state" / "orchestrator.pane").write_text("%4\n")
        self.assertEqual(self.run_agora("post", "who")[0], 2, "nor makes it Heph")
        self.assertEqual(self.posts(), [])

    def test_a_worker_resumed_in_hephs_pane_is_not_heph(self):
        self.register("%5", "techne-evals", SID)
        self.live(pane="%0")
        (self.tmp / "state" / "orchestrator.pane").write_text("%0\n")
        self.assertEqual(self.run_agora("post", "x", pane="%0")[0], 2)
        self.assertEqual(self.posts(), [])

    def test_two_live_sessions_in_one_pane_name_no_one(self):
        other = "77777777-2222-4333-8444-555555555555"
        self.live(sid=other)
        self.register("%4", "sphragis", other)
        self.assertEqual(self.run_agora("post", "x")[0], 2)

    def test_a_worker_with_hephs_voice_is_not_signed_as_heph(self):
        self.live(voice="am_michael")
        self.assertEqual(self.run_agora("post", "x")[1], "Posted as Metis.")

    def test_a_registered_session_in_the_orchestrators_pane_is_not_heph(self):
        (self.tmp / "state" / "orchestrator.pane").write_text("%4\n")
        self.assertEqual(self.run_agora("post", "x")[1], "Posted as Metis.")
        self.assertEqual(self.posts()[0]["who"], "techne-evals")

    def test_an_agent_name_that_is_not_a_plain_name_cannot_post(self):
        (self.tmp / "state" / "panes.tsv").write_text(f"%4\t../evil\t/b\t{SID}\t/w\t\n")
        self.assertEqual(self.run_agora("post", "x")[0], 2)

    def test_a_session_with_no_id_is_never_heph(self):
        (self.k / "fleet" / f"{SID}.json").unlink()
        (self.k / "fleet" / "x.json").write_text(
            json.dumps({"tmux": {"pane": "%7"}, "ended": None})
        )
        (self.tmp / "state" / "orchestrator.session").write_text("\n")
        self.assertEqual(self.run_agora("post", "x", pane="%7")[0], 2)

    def test_a_cast_or_picks_file_of_the_wrong_shape_signs_with_the_name(self):
        (self.k / "picks.json").write_text(json.dumps([SID]))
        for i, cast in enumerate(
            ([], {"characters": ["am_michael"]}, {"characters": "x"})
        ):
            (self.k / "cast.json").write_text(json.dumps(cast))
            self.assertEqual(
                self.run_agora("post", "x", now=NOW + i * 3600)[1],
                "Posted as techne-evals.",
                cast,
            )

    def test_a_character_entry_of_the_wrong_shape_signs_with_the_name(self):
        (self.k / "cast.json").write_text(
            json.dumps({"characters": {"af_nova": "Metis"}})
        )
        self.assertEqual(self.run_agora("post", "x")[1], "Posted as techne-evals.")

    def test_a_malformed_line_is_skipped_and_controls_are_stripped(self):
        (self.k / "agora").mkdir()
        (self.k / "agora" / "posts.jsonl").write_text(
            '{"at":"yesterday","who":"x","text":"t"}\n[1]\n'
        )
        self.assertEqual(self.run_agora("list")[0], 0)
        self.assertEqual(
            self.run_agora(
                "post", "abc\u202edef\u2028x\x9by \U0001f468\u200d\U0001f469"
            )[0],
            0,
        )
        self.assertEqual(
            self.posts()[-1]["text"], "abc def x y \U0001f468\u200d\U0001f469"
        )
        (self.k / "agora" / "posts.jsonl").write_text(
            json.dumps({"at": NOW + 10**8, "who": "techne-evals", "text": "t"}) + "\n"
        )
        self.assertEqual(
            self.run_agora("post", "a clock step holds nobody back", now=NOW + 9000)[0],
            0,
        )

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

    def test_current_openai_key_shapes_are_refused(self):
        for key in ("sk-proj-" + "Ab1_" * 12, "sk-svcacct-" + "Zx9-" * 12):
            self.assertEqual(self.run_agora("post", f"key {key}")[0], 3, key)
        self.assertEqual(self.posts(), [])

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
        pr = "https://github.com/ajbarea/klepsydra/pull/192"
        for around in (
            f"javascript:x//{pr}",
            f"{pr}#x",
            f" {pr}",
            "https://github.com/\u00f3wner/r/pull/1",
            "https://github.com/o/r/issues/\u0661\u0662",
        ):
            self.assertEqual(
                self.run_agora("post", "x", "--link", around)[0], 2, around
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

    def test_the_archive_keeps_the_last_hours_posts_for_the_limit(self):
        (self.k / "agora").mkdir()
        old = json.dumps({"at": 1, "who": "old", "text": "z" * 200}) + "\n"
        mine = json.dumps({"at": NOW - 60, "who": "sphragis", "text": "recent"}) + "\n"
        ahead = json.dumps({"at": NOW + 600, "who": "x", "text": "dated ahead"}) + "\n"
        (self.k / "agora" / "posts.jsonl").write_text(old * 1400 + mine + ahead)
        self.assertEqual(self.run_agora("post", "fresh")[0], 0)
        self.assertEqual([p["text"] for p in self.posts()], ["recent", "fresh"])
        (kept,) = (self.k / "agora" / "archive").glob("posts-*.jsonl")
        archived = kept.read_text()
        self.assertNotIn("recent", archived, "each post in one file only")
        self.assertIn("dated ahead", archived)
        self.assertEqual(archived.count("\n"), 1401)

    def test_two_archives_in_one_second_are_both_kept(self):
        (self.k / "agora" / "archive").mkdir(parents=True)
        (self.k / "agora" / "archive" / f"posts-{int(NOW)}.jsonl").write_text(
            "earlier\n"
        )
        big = json.dumps({"at": 1, "who": "old", "text": "z" * 200}) + "\n"
        (self.k / "agora" / "posts.jsonl").write_text(big * 1400)
        self.assertEqual(self.run_agora("post", "fresh")[0], 0)
        archive = self.k / "agora" / "archive"
        self.assertEqual(len(list(archive.glob("posts-*.jsonl"))), 2)
        self.assertEqual(
            (archive / f"posts-{int(NOW)}.jsonl").read_text(),
            "earlier\n",
            "the earlier archive is not overwritten",
        )
        self.assertIn("zzz", (archive / f"posts-{int(NOW)}-1.jsonl").read_text())

    def test_a_full_file_of_the_last_hours_posts_writes_no_empty_archive(self):
        (self.k / "agora").mkdir()
        recent = json.dumps({"at": NOW - 60, "who": "a", "text": "z" * 200}) + "\n"
        (self.k / "agora" / "posts.jsonl").write_text(recent * 1400)
        self.assertEqual(self.run_agora("post", "fresh")[0], 0)
        self.assertEqual(list((self.k / "agora").glob("archive/*")), [])

    def test_a_line_dated_past_any_clock_is_no_post(self):
        (self.k / "agora").mkdir()
        far = json.dumps({"at": 10**20, "who": "x", "text": "far"}) + "\n"
        true = json.dumps({"at": True, "who": "x", "text": "bool"}) + "\n"
        zero = json.dumps({"at": 0, "who": "x", "text": "zero"}) + "\n"
        neg = json.dumps({"at": -5, "who": "x", "text": "negative"}) + "\n"
        (self.k / "agora" / "posts.jsonl").write_text(far + true + zero + neg)
        code, out = self.run_agora("list")[:2]
        self.assertEqual(code, 0)
        self.assertNotIn("far", out)
        self.assertNotIn("bool", out, "a JSON true is no time")
        self.assertNotIn("zero", out)
        self.assertNotIn("negative", out)

    def test_control_characters_are_flattened(self):
        self.run_agora("post", "two\nlines\x1b[31m")
        self.assertEqual(self.posts()[0]["text"], "two lines [31m")


if __name__ == "__main__":
    unittest.main()
