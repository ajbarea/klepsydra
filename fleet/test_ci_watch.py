"""Tests for ci_watch.py with a fake GitHub. Run: python3 -I fleet/test_ci_watch.py"""

import http.server
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
import urllib.parse
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp())
os.environ |= {
    "FLEET_STATE": str(TMP / "state"),
    "KLEPSYDRA_DIR": str(TMP / "k"),
    "FLEET_QUEUE": str(TMP / "q.md"),
}
(TMP / "k").mkdir()
sys.path.insert(0, str(HERE))
import ci_watch  # noqa: E402


def run(
    i,
    workflow=1,
    branch="main",
    sha="m",
    conclusion="failure",
    at="2026-10-28T10:00:00Z",
    actor="ajbarea",
):
    return {
        "id": i,
        "name": f"wf{workflow}",
        "workflow_id": workflow,
        "head_branch": branch,
        "head_sha": sha,
        "status": "completed",
        "conclusion": conclusion,
        "created_at": at,
        "updated_at": at,
        "html_url": f"https://github.com/o/r/actions/runs/{i}",
        "actor": {"login": actor},
        "head_repository": {"full_name": "o/r"},
    }


def pr(n, sha, login="ajbarea"):
    return {"number": n, "head": {"sha": sha}, "user": {"login": login}}


class Fake:
    """GitHub's raw answers, filtered by the query as the API would."""

    def __init__(
        self, runs, pulls=(), jobs=None, broken=(), full_name=None, workflows=(1, 2, 3)
    ):
        self.runs, self.pulls = list(runs), list(pulls)
        self.full_name, self.workflows = full_name, workflows
        self.jobs = jobs or {
            "jobs": [
                {
                    "name": "test",
                    "conclusion": "failure",
                    "steps": [{"name": "pytest", "conclusion": "failure"}],
                }
            ]
        }
        self.broken = broken
        self.calls = []

    def get(self, path, keep=None):
        self.calls.append(path)
        for b in self.broken:
            if b in path:
                raise ci_watch.urllib.error.HTTPError(
                    path, 403, "rate limited", {}, None
                )
        url = urllib.parse.urlparse(path)
        q = dict(urllib.parse.parse_qsl(url.query))
        if url.path.endswith("/jobs"):
            body = self.jobs
        elif url.path.endswith("/pulls"):
            body = self.pulls
        elif url.path.endswith("/actions/workflows"):
            body = {"workflows": [{"id": w, "state": "active"} for w in self.workflows]}
        elif url.path.endswith("/actions/runs"):
            rs = [
                r
                for r in self.runs
                if q.get("branch") in (None, r["head_branch"])
                and q.get("head_sha") in (None, r["head_sha"])
            ]
            body = {"workflow_runs": rs}
        else:
            body = {
                "default_branch": "main",
                "full_name": self.full_name or url.path.removeprefix("/repos/"),
            }
        return keep(body) if keep else body


class Counts(unittest.TestCase):
    def ids(self, gh):
        return sorted(r["id"] for r in ci_watch.runs_that_count("o", "r", gh)[0])

    def test_a_later_green_run_clears_a_red_one(self):
        self.assertEqual(
            self.ids(
                Fake([run(1), run(2, conclusion="success", at="2026-10-28T11:00:00Z")])
            ),
            [2],
        )

    def test_a_cancelled_skipped_or_neutral_run_decides_nothing(self):
        for c in ("cancelled", "skipped", "neutral"):
            self.assertEqual(
                self.ids(
                    Fake([run(1), run(2, conclusion=c, at="2026-10-28T11:00:00Z")])
                ),
                [1],
                c,
            )

    def test_only_the_default_branch_and_open_pr_heads_count(self):
        gh = Fake(
            [
                run(1, branch="feature", sha="f"),
                run(2, branch="pr-branch", sha="p"),
                run(3, workflow=2),
            ],
            pulls=[pr(7, "p")],
        )
        self.assertEqual(
            self.ids(gh), [2, 3], "a branch with no open PR is not watched"
        )

    def test_each_branch_and_head_is_asked_for_so_nothing_pages_out(self):
        gh = Fake([run(1)], pulls=[pr(7, "p"), pr(8, "q")])
        ci_watch.runs_that_count("o", "r", gh)
        self.assertIn(
            "/repos/o/r/actions/runs?branch=main&status=completed&per_page=100",
            gh.calls,
        )
        self.assertIn("/repos/o/r/actions/runs?head_sha=p&per_page=50", gh.calls)
        self.assertIn("/repos/o/r/actions/runs?head_sha=q&per_page=50", gh.calls)

    def test_a_fork_pr_branch_named_main_is_not_the_default_branch(self):
        fork = run(4, sha="x") | {"head_repository": {"full_name": "someone/r"}}
        self.assertEqual(self.ids(Fake([fork])), [])


class Poll(unittest.TestCase):
    def setUp(self):
        (TMP / "q.md").write_text(
            "# Queue\n\n## Needs you\n- earlier ask\n\n## Running now\n"
        )
        self.triaged = []

        def triage(user, repo, run_id):
            self.triaged.append(run_id)
            return {
                "state": "done",
                "verdict": "failure",
                "cause": "test_x fails",
                "location": "a.py:3",
                "summary": "s",
                "report": "r.md",
            }

        self.patch = mock.patch.object(ci_watch, "triage", triage)
        self.patch.start()

    def tearDown(self):
        self.patch.stop()

    def test_a_new_red_run_is_triaged_once_saved_at_once_and_queued_once(self):
        known, saves = {}, []
        gh = Fake([run(5), run(6, workflow=2, conclusion="timed_out")])
        first = ci_watch.poll(
            "o", ["r"], gh, known, lambda: saves.append(sorted(known))
        )
        second = ci_watch.poll("o", ["r"], gh, known)
        self.assertEqual(
            sorted(self.triaged), [5, 6], "each red run triaged once across passes"
        )
        self.assertEqual(
            len(saves[0]), 1, "known is saved right after the first triage"
        )
        self.assertEqual(second["red"], first["red"])
        self.assertEqual(first["red"][0]["failing"], {"job": "test", "step": "pytest"})
        q = (TMP / "q.md").read_text()
        self.assertEqual(q.count("<!-- ci:r:5 -->"), 1)
        self.assertIn(
            "- 🔴 **CI r**: wf1 failed on main: test_x fails (a.py:3). https://github.com/o/r/actions/runs/5",
            q,
        )
        self.assertLess(q.index("ci:r:5"), q.index("## Running now"), "under Needs you")

    def test_a_cause_cannot_write_a_heading_into_the_queue_file(self):
        def nasty(user, repo, run_id):
            return {
                "state": "done",
                "verdict": "failure",
                "cause": "boom\n## Done\n- [x] fake",
                "location": None,
                "summary": "s",
                "report": "r.md",
            }

        with mock.patch.object(ci_watch, "triage", nasty):
            ci_watch.poll("o", ["r"], Fake([run(9)]), {})
        q = (TMP / "q.md").read_text()
        self.assertEqual(
            [ln for ln in q.splitlines() if ln.startswith("#")],
            ["# Queue", "## Needs you", "## Running now"],
        )
        self.assertEqual(
            len([ln for ln in q.splitlines() if "ci:r:9" in ln]), 1, "one line"
        )

    def test_without_a_needs_you_heading_the_line_waits_and_comes_later(self):
        (TMP / "q.md").write_text("# Queue\n")
        known = {}
        ci_watch.poll("o", ["r"], Fake([run(5)]), known)
        self.assertEqual(known["r:5"]["queued"], False)
        (TMP / "q.md").write_text("# Queue\n\n## Needs you\n")
        ci_watch.poll("o", ["r"], Fake([run(5)]), known)
        self.assertEqual(
            (known["r:5"]["queued"], self.triaged),
            (True, [5]),
            "queued on a later pass, triaged once",
        )

    def test_dependabots_reds_wait_for_the_morning(self):
        for pulls, actor in (
            ([pr(9, "d", "dependabot[bot]")], "ajbarea"),
            ([pr(9, "d")], "dependabot[bot]"),
        ):
            got = ci_watch.poll(
                "o",
                ["r"],
                Fake([run(8, branch="dep/uv", sha="d", actor=actor)], pulls=pulls),
                {},
            )
            self.assertEqual(
                (got["red"], [d["run_id"] for d in got["dependabot"]], self.triaged),
                ([], [8], []),
                actor,
            )

    def test_any_error_in_one_repo_skips_it_for_the_pass(self):
        for where in ("/jobs", "/actions/runs", "/pulls"):
            got = ci_watch.poll("o", ["r"], Fake([run(7)], broken=(where,)), {})
            self.assertEqual([e["repo"] for e in got["errors"]], ["r"], where)
            self.assertIn("HTTPError", got["errors"][0]["error"])
        self.assertEqual(
            [r["run_id"] for r in ci_watch.poll("o", ["r"], Fake([run(5)]), {})["red"]],
            [5],
        )

    def test_a_timeout_reading_github_is_one_repos_error_not_the_watchs_end(self):
        class Slow(Fake):
            def get(self, path, keep=None):
                raise TimeoutError("read timed out")

        got = ci_watch.poll("o", ["x"], Slow([]), {})
        self.assertEqual([e["repo"] for e in got["errors"]], ["x"])


class Poll2(unittest.TestCase):
    """Queue errors, runs that page out, forks and the sweep."""

    setUp = Poll.setUp
    tearDown = Poll.tearDown

    def test_a_queue_file_that_cannot_be_changed_does_not_hide_the_red_run(self):
        known = {}
        with mock.patch.object(
            ci_watch, "add_queue_line", side_effect=PermissionError("read-only")
        ):
            got = ci_watch.poll("o", ["r"], Fake([run(5)]), known)
        self.assertEqual(
            ([r["run_id"] for r in got["red"]], got["errors"], known["r:5"]["queued"]),
            ([5], [], False),
        )
        self.assertEqual(
            list(TMP.glob(".q.md.*.tmp")), [], "no temp file left beside the queue"
        )

    def test_a_red_run_that_paged_out_stays_red_until_a_green_run_of_its_workflow(self):
        known = {}
        ci_watch.poll("o", ["r"], Fake([run(5, workflow=3)]), known)
        later = ci_watch.poll(
            "o", ["r"], Fake([run(6, workflow=1, conclusion="success")]), known
        )
        self.assertEqual(
            [r["run_id"] for r in later["red"]],
            [5],
            "weekly workflow 3 paged out: still red",
        )
        green = ci_watch.poll(
            "o",
            ["r"],
            Fake([run(7, workflow=3, conclusion="success", at="2026-10-29T00:00:00Z")]),
            known,
        )
        self.assertEqual(green["red"], [], "a green run of workflow 3 clears it")

    def test_a_forks_pr_is_shown_but_never_triaged_or_queued(self):
        fork = run(8, branch="patch-1", sha="f") | {
            "head_repository": {"full_name": "someone/r"}
        }
        got = ci_watch.poll("o", ["r"], Fake([fork], pulls=[pr(4, "f", "someone")]), {})
        self.assertEqual(
            ([r["triage"]["state"] for r in got["red"]], self.triaged),
            (["skipped"], []),
        )
        self.assertNotIn("ci:r:8", (TMP / "q.md").read_text())

    def test_the_sweep_reads_default_branch_runs_once_and_no_pr_run(self):
        runs = [
            run(10, conclusion="success"),
            run(11, workflow=2, branch="pr", sha="p", conclusion="success"),
        ]
        swept = set()
        with mock.patch.object(
            ci_watch,
            "triage",
            lambda u, r, i: (
                self.triaged.append(i),
                {"state": "done", "verdict": "clean"},
            )[1],
        ):
            ci_watch.sweep("o", ["r"], Fake(runs, pulls=[pr(4, "p")]), swept)
            ci_watch.sweep("o", ["r"], Fake(runs, pulls=[pr(4, "p")]), swept)
        self.assertEqual(
            self.triaged, [10], "the PR's run is not swept, and run 10 only once"
        )


class Held(unittest.TestCase):
    """A red run held after it paged out, and what lets it go."""

    setUp = Poll.setUp
    tearDown = Poll.tearDown

    def test_a_pr_closed_while_red_lets_its_red_go(self):
        known = {}
        ci_watch.poll(
            "o", ["r"], Fake([run(5, branch="b", sha="p")], pulls=[pr(4, "p")]), known
        )
        got = ci_watch.poll("o", ["r"], Fake([run(6, conclusion="success")]), known)
        self.assertEqual(got["red"], [], "PR 4 is no longer open")

    def test_a_deleted_or_renamed_workflow_lets_its_red_go(self):
        known = {}
        ci_watch.poll("o", ["r"], Fake([run(5, workflow=3)]), known)
        got = ci_watch.poll(
            "o", ["r"], Fake([run(6, conclusion="success")], workflows=(1, 2)), known
        )
        self.assertEqual(got["red"], [])

    def test_a_newer_red_in_the_same_place_replaces_the_older_one(self):
        known = {}
        ci_watch.poll("o", ["r"], Fake([run(5, workflow=3)]), known)
        ci_watch.poll(
            "o", ["r"], Fake([run(7, workflow=3, at="2026-10-29T00:00:00Z")]), known
        )
        got = ci_watch.poll(
            "o", ["r"], Fake([run(9, workflow=1, conclusion="success")]), known
        )
        self.assertEqual(
            [r["run_id"] for r in got["red"]], [7], "only the newer red, once"
        )

    def test_a_transferred_repo_or_another_case_is_not_a_fork(self):
        moved = run(5) | {"head_repository": {"full_name": "LDQIS/ldqis"}}
        got = ci_watch.poll("aj", ["ldqis"], Fake([moved], full_name="ldqis/ldqis"), {})
        self.assertEqual(
            [(r["run_id"], r["triage"]["state"]) for r in got["red"]], [(5, "done")]
        )

    def test_a_held_red_a_month_old_goes(self):
        known = {}
        ci_watch.poll("o", ["r"], Fake([run(5, workflow=3)]), known)
        known["r:5"]["seen"] = int(time.time()) - 31 * 86400
        got = ci_watch.poll("o", ["r"], Fake([run(6, conclusion="success")]), known)
        self.assertEqual(got["red"], [])

    def test_entries_from_before_seen_existed_count_as_seen_at_load(self):
        state = Path(os.environ["FLEET_STATE"]) / "ci"
        state.mkdir(parents=True, exist_ok=True)
        (state / "known.json").write_text(
            '{"r:1": {"failing": {}, "triage": {}, "queued": true}}'
        )
        seen = {}
        with (
            mock.patch.object(
                ci_watch,
                "poll",
                side_effect=lambda u, r, gh, known, save: (
                    seen.update(known) or {"red": [], "dependabot": [], "errors": []}
                ),
            ),
            mock.patch.object(
                ci_watch.subprocess, "run", return_value=mock.Mock(stdout="t0ken")
            ),
            mock.patch.object(ci_watch, "sisters", return_value=("o", ["r"])),
        ):
            ci_watch.main(["ci_watch.py", "--once"])
        self.assertGreater(seen["r:1"]["seen"], time.time() - 60)

    def test_a_queue_file_that_will_not_decode_hides_no_red(self):
        (TMP / "q.md").write_bytes(b"\xff\xfe## Needs you\n")
        got = ci_watch.poll("o", ["r"], Fake([run(5)]), {})
        self.assertEqual(([r["run_id"] for r in got["red"]], got["errors"]), ([5], []))


class Triage(unittest.TestCase):
    def test_a_report_that_hangs_or_writes_nothing_is_a_failed_triage(self):
        script = TMP / "report.sh"
        script.write_text("#!/bin/bash\nexit 0\n")
        with mock.patch.dict(os.environ, {"TECHNE_CI_REPORT": str(script)}):
            self.assertEqual(
                ci_watch.triage("o", "r", 1)["state"], "failed", "no report.json"
            )
            with mock.patch.object(
                ci_watch.subprocess,
                "run",
                side_effect=subprocess.TimeoutExpired("bash", 900),
            ):
                got = ci_watch.triage("o", "r", 2)
        self.assertEqual(got["state"], "failed")
        self.assertIsInstance(got["why"], str)


class Prune(unittest.TestCase):
    def test_only_old_folders_report_sh_made_go_and_no_link_is_followed(self):
        folder = TMP / "prune"
        outside = TMP / "outside"
        outside.mkdir(parents=True)
        (outside / "keep.txt").write_text("not ours")
        old = time.time() - 30 * 86400
        made = folder / "r-1"
        (made / "run").mkdir(parents=True)
        (made / "run" / ".ci-report-run").write_text("")
        (made / "report.json").write_text("{}")
        (made / "run" / "link").symlink_to(outside)
        foreign = folder / "notes-2"
        foreign.mkdir()
        (foreign / "x").write_text("y")
        linked = folder / "r-3"
        linked.symlink_to(outside)
        fresh = folder / "r-4"
        (fresh / "run").mkdir(parents=True)
        (fresh / "run" / ".ci-report-run").write_text("")
        for d in (made, foreign):
            os.utime(d, (old, old))
        ci_watch.prune_reports(folder, time.time())
        self.assertFalse(made.exists(), "an old marked folder goes")
        self.assertEqual(
            (outside / "keep.txt").read_text(),
            "not ours",
            "its link was removed, not followed",
        )
        self.assertTrue(foreign.exists() and linked.is_symlink() and fresh.exists())


class Conditional(unittest.TestCase):
    """The real client against a local server: an ETag answer, then a free 304."""

    def test_an_unchanged_answer_is_a_304_and_reuses_the_kept_cut(self):
        seen = []

        class H(http.server.BaseHTTPRequestHandler):
            def do_GET(self):
                seen.append(
                    (
                        self.headers.get("If-None-Match"),
                        self.headers.get("Authorization"),
                    )
                )
                if self.headers.get("If-None-Match") == '"v1"':
                    self.send_response(304)
                    self.end_headers()
                    return
                body = b'{"default_branch": "main", "big": "' + b"x" * 1000 + b'"}'
                self.send_response(200)
                self.send_header("ETag", '"v1"')
                self.send_header("X-Poll-Interval", "300")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def log_message(self, *a):
                pass

        server = http.server.HTTPServer(("127.0.0.1", 0), H)
        threading.Thread(target=server.serve_forever, daemon=True).start()

        def keep(b):
            return {"default_branch": b["default_branch"]}

        with mock.patch.object(
            ci_watch, "API", f"http://127.0.0.1:{server.server_port}"
        ):
            gh = ci_watch.GitHub("t0ken", TMP / "etags.json")
            a = gh.get("/repos/o/r", keep=keep)
            b = gh.get("/repos/o/r", keep=keep)
        server.shutdown()
        server.server_close()
        self.assertEqual((a, b), ({"default_branch": "main"},) * 2)
        self.assertEqual(seen, [(None, "Bearer t0ken"), ('"v1"', "Bearer t0ken")])
        self.assertEqual(gh.poll_s, 300, "x-poll-interval is honoured")
        gh.save()
        kept = (TMP / "etags.json").read_text()
        self.assertNotIn("t0ken", kept, "the token is never written")
        self.assertNotIn("xxxx", kept, "only the cut is kept, not the whole body")


class Sisters(unittest.TestCase):
    def test_only_active_sisters_are_watched(self):
        p = TMP / "t.toml"
        p.write_text(
            'github_user = "aj"\n[[sisters]]\nname = "a"\nstatus = "active"\n'
            '[[sisters]]\nname = "b"\nstatus = "backburner"\n'
        )
        self.assertEqual(ci_watch.sisters(p), ("aj", ["a"]))


if __name__ == "__main__":
    unittest.main(verbosity=1)
