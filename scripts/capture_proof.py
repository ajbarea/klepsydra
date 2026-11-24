#!/usr/bin/env python3
"""Capture 1920-wide wall screenshot showing the browser chip."""

import http.server
import json
import os
import pathlib
import socketserver
import sys
import threading
import time

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
PORT = 8945
PROOF_IMG = ROOT / "docs" / "proof-533-chip.png"

class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def log_message(self, *args):
        pass

def main():
    PROOF_IMG.parent.mkdir(parents=True, exist_ok=True)

    server = socketserver.TCPServer(("127.0.0.1", PORT), QuietHandler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    print(f"Server started on http://127.0.0.1:{PORT}")

    # Read live session file from klepsydra app data dir
    session_file = pathlib.Path(f"/mnt/c/Users/{os.environ.get('USER', 'ajbar')}/AppData/Local/dev.ajsoftworks.klepsydra/fleet/70e18ff7-bca0-4141-a5fc-f7c8c1e8de76.json")
    if session_file.exists():
        session_data = json.loads(session_file.read_text())
    else:
        session_data = {
            "v": 1,
            "session_id": "70e18ff7-bca0-4141-a5fc-f7c8c1e8de76",
            "name": "agy-533",
            "state": "working",
            "browser": "agy-533",
            "where": {"repo": "klepsydra", "worktree": "agy-533", "branch": "feat/browser-in-use-533"},
        }

    # Ensure browser field is present
    session_data["browser"] = "agy-533"

    # Also load sample demo cards so the wall looks full and realistic at 1920
    demo_file = ROOT / "scripts" / "fixtures" / "fleet-demo.json"
    demo_sessions = []
    if demo_file.exists():
        demo_sessions = json.loads(demo_file.read_text()).get("sessions", [])[:7]

    snapshot = {
        "at": int(time.time()),
        "sessions": [session_data] + demo_sessions,
        "speaking": None,
    }

    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(viewport={"width": 1920, "height": 1000})

        page.route("**/dev-fleet.json", lambda route: route.fulfill(
            status=200,
            content_type="application/json",
            body=json.dumps(snapshot),
        ))

        page.goto(f"http://127.0.0.1:{PORT}/src/wall.html")
        page.wait_for_selector(".browser-chip:not([hidden])", timeout=5000)

        chip_text = page.inner_text(".browser-chip")
        chip_title = page.get_attribute(".browser-chip", "title")
        print(f"Browser chip text: {chip_text!r}, title: {chip_title!r}")

        # Take full 1920x1000 screenshot
        page.screenshot(path=str(PROOF_IMG))
        print(f"Saved 1920-wide screenshot to {PROOF_IMG} (size: {PROOF_IMG.stat().st_size} bytes)")

        browser.close()

    server.shutdown()
    return 0

if __name__ == "__main__":
    sys.exit(main())
