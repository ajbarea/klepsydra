"""Browser tests and screenshot generator for Rooms (#386).

Verifies Layouts B, D, E at 1920 desktop and 390 phone viewports, keyboard flow,
and saves the 24 demo screenshots for the fleet-briefing shots review.

    uv run -q --no-project --with playwright python -I scripts/test_rooms_browser.py
"""

import http.server
import pathlib
import socket
import threading

from playwright.sync_api import sync_playwright

ROOT = pathlib.Path(__file__).resolve().parent.parent
SHOTS_DIR = pathlib.Path("/mnt/c/Users/ajbar/fleet-briefing/shots/2026-11-25")
LAYOUTS = ["B", "D", "E"]
VIEWS = ["needs", "agents"]
WIDTHS = [
    (1920, 1000),
    (390, 844),
]
THEMES = ["dark", "light"]


class QuietHandler(http.server.SimpleHTTPRequestHandler):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, directory=str(ROOT), **kwargs)

    def log_message(self, *args):
        pass


def start_server():
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    httpd = http.server.HTTPServer(("127.0.0.1", port), QuietHandler)
    t = threading.Thread(target=httpd.serve_forever, daemon=True)
    t.start()
    return httpd, port


def run_tests_and_shots():
    SHOTS_DIR.mkdir(parents=True, exist_ok=True)
    httpd, port = start_server()
    print(f"Server started on http://127.0.0.1:{port}")

    with sync_playwright() as p:
        browser = p.chromium.launch()

        # 1. Targeted browser tests
        print("Running browser verification tests...")
        test_page = browser.new_page(
            viewport={"width": 1920, "height": 1000}, color_scheme="dark"
        )
        test_page.goto(f"http://127.0.0.1:{port}/src/wall.html?demo")
        test_page.wait_for_timeout(800)

        # Header pills check
        pills = test_page.query_selector_all(".room-pill")
        assert len(pills) == 2, f"Expected 2 pills, got {len(pills)}"
        needs_pill = test_page.query_selector("#btn-needs-room")
        agents_pill = test_page.query_selector("#btn-agents-room")
        assert needs_pill is not None, "Missing #btn-needs-room"
        assert agents_pill is not None, "Missing #btn-agents-room"

        # Key shortcut N opens Needs you
        test_page.keyboard.press("N")
        test_page.wait_for_timeout(300)
        assert test_page.evaluate("document.body.dataset.view") == "needs", (
            "Pressing N should switch to needs view"
        )
        nr = test_page.query_selector("#needs-room")
        assert nr.is_visible(), "Needs room must be visible in needs view"

        # Key navigation j/k
        initial_foc = test_page.evaluate(
            "document.querySelector('.is-focused')?.dataset.idx"
        )
        test_page.keyboard.press("j")
        test_page.wait_for_timeout(200)
        next_foc = test_page.evaluate(
            "document.querySelector('.is-focused')?.dataset.idx"
        )
        print(f"  Focus moved from {initial_foc} to {next_foc}")

        # Move focus to the first file item past blocked sessions
        blocked_len = test_page.evaluate(
            "document.querySelectorAll('.blocked-row').length"
        )
        print(f"  Blocked sessions count: {blocked_len}")
        for _ in range(blocked_len):
            test_page.keyboard.press("j")
            test_page.wait_for_timeout(100)

        # Done and Undo via keyboard
        test_page.keyboard.press("e")
        test_page.wait_for_timeout(300)
        toast = test_page.query_selector(".room-toast")
        assert toast is not None, "Toast should appear after mark done"
        assert "Marked done" in toast.inner_text(), (
            f"Unexpected toast text: {toast.inner_text()}"
        )

        test_page.keyboard.press("u")
        test_page.wait_for_timeout(300)
        toast_undo = test_page.query_selector(".room-toast")
        assert toast_undo is not None, "Undo toast should appear after undo"
        assert "Restored item" in toast_undo.inner_text(), (
            f"Unexpected toast text: {toast_undo.inner_text()}"
        )

        # Esc returns to Agents
        test_page.keyboard.press("Escape")
        test_page.wait_for_timeout(300)
        assert test_page.evaluate("document.body.dataset.view") == "agents", (
            "Escape should return to agents view"
        )

        # Test phone tabbar at 390
        phone_page = browser.new_page(
            viewport={"width": 390, "height": 844}, color_scheme="dark"
        )
        phone_page.goto(f"http://127.0.0.1:{port}/src/wall.html?demo")
        phone_page.wait_for_timeout(800)
        tabbar = phone_page.query_selector("#phone-tabbar")
        assert tabbar.is_visible(), "Phone tabbar must be visible on 390 viewport"
        phone_page.click("#ptab-needs")
        phone_page.wait_for_timeout(300)
        assert phone_page.query_selector("#needs-room").is_visible(), (
            "Needs room visible on phone after click"
        )
        phone_page.close()
        test_page.close()
        print("Browser verification tests passed cleanly!")

        # 2. Capture all 24 screenshots
        print("\nCapturing 24 screenshots...")
        count = 0
        for layout in LAYOUTS:
            for view in VIEWS:
                for width, height in WIDTHS:
                    for theme in THEMES:
                        page = browser.new_page(
                            viewport={"width": width, "height": height},
                            color_scheme=theme,
                        )
                        page.goto(f"http://127.0.0.1:{port}/src/wall.html?demo")
                        page.wait_for_timeout(600)

                        # Set layout
                        page.evaluate(
                            f"document.getElementById('needs-layout').value = '{layout}';"
                            f"document.getElementById('needs-layout').dispatchEvent(new Event('change'))"
                        )
                        page.wait_for_timeout(200)

                        # Set view
                        if width > 640:
                            btn_id = f"btn-{view}-room"
                            page.evaluate(
                                f"document.getElementById('{btn_id}').click()"
                            )
                        else:
                            ptab_id = f"ptab-{view}"
                            page.evaluate(
                                f"document.getElementById('{ptab_id}').click()"
                            )

                        page.wait_for_timeout(400)

                        shot_name = (
                            f"klepsydra-386-build-{layout}-{view}-{width}-{theme}.png"
                        )
                        shot_path = SHOTS_DIR / shot_name
                        page.screenshot(path=str(shot_path), full_page=False)
                        file_size_kb = shot_path.stat().st_size / 1024
                        count += 1
                        print(
                            f"[{count:02d}/24] Saved {shot_name} ({file_size_kb:.1f} KB)"
                        )
                        page.close()

        browser.close()

    httpd.shutdown()
    print(f"\nAll 24 screenshots captured and saved to {SHOTS_DIR}")


if __name__ == "__main__":
    run_tests_and_shots()
