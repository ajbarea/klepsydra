"""Tests for ci_watch.py with a fake GitHub. Run: python3 -I fleet/test_ci_watch.py"""

import http.server
import os
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from unittest import mock

HERE = Path(__file__).resolve().parent
TMP = Path(tempfile.mkdtemp())
os.environ |= {
    "FLEET_STATE": str(TMP / "state"),
    "KLEPSYDRA_DIR": str(TMP / "k"),
    "FLEET_QUEUE": str(TMP / "q.md"),
}
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
    }


class Fake:
    """GitHub's answers by path."""

    def __init__(self, runs, pulls=(), jobs=None):
        self.answers = {
            "/repos/o/r": {"default_branch": "main"},
            "/repos/o/r/pulls?state=open&per_page=50": list(pulls),
            "/repos/o/r/actions/runs?per_page=50": {"workflow_runs": runs},
        }
        self.jobs = jobs or {
            "jobs": [
                {
                    "name": "test",
                    "conclusion": "failure",
                    "steps": [{"name": "pytest", "conclusion": "failure"}],
                }
            ]
        }
        self.calls = []

    def get(self, path):
        self.calls.append(path)
        if "/jobs" in path:
            return self.jobs
        return self.answers[path]


def pr(n, sha, login="ajbarea"):
    return {"number": n, "head": {"sha": sha}, "user": {"login": login}}


class Counts(unittest.TestCase):
    def test_the_newest_completed_run_per_workflow_and_branch_decides(self):
        gh = Fake(
            [
                run(1, at="2026-10-28T10:00:00Z"),
                run(2, conclusion="success", at="2026-10-28T11:00:00Z"),
            ]
        )
        runs, default = ci_watch.runs_that_count("o", "r", gh)
        self.assertEqual(default, "main")
        self.assertEqual(
            [r["id"] for r in runs], [2], "a later green run clears the red"
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
        runs, _ = ci_watch.runs_that_count("o", "r", gh)
        self.assertEqual(
            sorted(r["id"] for r in runs),
            [2, 3],
            "a branch with no open PR is not watched",
        )

    def test_a_run_still_going_is_not_judged(self):
        r = run(1) | {"status": "in_progress", "conclusion": None}
        self.assertEqual(ci_watch.runs_that_count("o", "r", Fake([r]))[0], [])


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

    def test_a_new_red_run_is_triaged_once_and_queued_once(self):
        known = {}
        gh = Fake([run(5), run(6, workflow=2, conclusion="timed_out")])
        first = ci_watch.poll("o", ["r"], gh, known)
        second = ci_watch.poll("o", ["r"], gh, known)
        self.assertEqual(
            sorted(self.triaged), [5, 6], "each red run triaged once across passes"
        )
        self.assertEqual(len(first["red"]), 2)
        self.assertEqual(second["red"], first["red"])
        self.assertEqual(first["red"][0]["failing"], {"job": "test", "step": "pytest"})
        q = (TMP / "q.md").read_text()
        self.assertEqual(q.count("<!-- ci:r:5 -->"), 1)
        self.assertIn(
            "- 🔴 **CI r**: wf1 failed on main: test_x fails (a.py:3). https://github.com/o/r/actions/runs/5",
            q,
        )
        self.assertLess(q.index("ci:r:5"), q.index("## Running now"), "under Needs you")

    def test_dependabots_reds_wait_for_the_morning(self):
        gh = Fake(
            [run(8, branch="dependabot/uv", sha="d", actor="dependabot[bot]")],
            pulls=[pr(9, "d", "dependabot[bot]")],
        )
        got = ci_watch.poll("o", ["r"], gh, {})
        self.assertEqual(
            (got["red"], [d["run_id"] for d in got["dependabot"]], self.triaged),
            ([], [8], []),
        )
        self.assertNotIn("ci:r:8", (TMP / "q.md").read_text())

    def test_a_repo_that_cannot_be_read_is_reported_and_the_rest_go_on(self):
        gh = Fake([run(5)])
        with mock.patch.object(
            ci_watch,
            "runs_that_count",
            side_effect=[
                ci_watch.urllib.error.URLError("down"),
                ci_watch.runs_that_count("o", "r", gh),
            ],
        ):
            got = ci_watch.poll("o", ["x", "r"], gh, {})
        self.assertEqual([e["repo"] for e in got["errors"]], ["x"])
        self.assertEqual([r["run_id"] for r in got["red"]], [5])


class Conditional(unittest.TestCase):
    """The real client against a local server: an ETag answer, then a free 304."""

    def test_an_unchanged_answer_is_a_304_and_reuses_the_body(self):
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
                body = b'{"default_branch": "main"}'
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
        with mock.patch.object(
            ci_watch, "API", f"http://127.0.0.1:{server.server_port}"
        ):
            gh = ci_watch.GitHub("t0ken", TMP / "etags.json")
            a = gh.get("/repos/o/r")
            b = gh.get("/repos/o/r")
        server.shutdown()
        server.server_close()
        self.assertEqual((a, b), ({"default_branch": "main"},) * 2)
        self.assertEqual(seen, [(None, "Bearer t0ken"), ('"v1"', "Bearer t0ken")])
        self.assertEqual(gh.poll_s, 300, "x-poll-interval is honoured")
        gh.save()
        self.assertNotIn(
            "t0ken", (TMP / "etags.json").read_text(), "the token is never written"
        )


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
