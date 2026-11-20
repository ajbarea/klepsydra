"""Real-browser grid regression: desktop wall cards fit sub-420px windows (#505).

Uses the real wall HTML template and CSS, with cards made from its template.
No network, Tauri bridge, or running app is needed. Install Playwright Chromium
(or set KLEPSYDRA_CHROME to a local Chrome/Chromium binary) before running.
"""

import os
from pathlib import Path

from playwright.sync_api import sync_playwright

ROOT = Path(__file__).resolve().parents[1]
WIDTHS = (360, 375, 390, 420, 449, 450, 480, 600, 945, 1920)


def run(browser):
    """Assert card visibility and unchanged two/four-column layouts in Chromium."""
    html = (ROOT / "src/wall.html").read_text(encoding="utf-8")
    css = (ROOT / "src/fleet/wall.css").read_text(encoding="utf-8")
    badge_css = (ROOT / "src/fleet/badge.css").read_text(encoding="utf-8")
    page = browser.new_page(viewport={"width": 945, "height": 1000})
    try:
        page.set_content(html)
        page.add_style_tag(content=badge_css)
        page.add_style_tag(content=css)
        page.evaluate("""() => {
          const wall = document.querySelector('#wall');
          const tpl = document.querySelector('#card-tpl');
          for (let i = 0; i < 8; i++) {
            const card = tpl.content.firstElementChild.cloneNode(true);
            card.querySelector('.name').textContent = 'Session ' + i;
            card.querySelector('.task').textContent = 'A useful development task';
            card.querySelector('.repo').textContent = 'example/repository';
            card.querySelector('.jump').textContent = 'Open terminal';
            wall.append(card);
          }
        }""")
        for density in ("compact", "comfortable"):
            for width in WIDTHS:
                page.set_viewport_size({"width": width, "height": 1000})
                page.evaluate("""density => {
                    document.querySelector('#wall').dataset.density = density;
                    document.querySelector('.bar').dataset.density = density;
                }""", density)
                result = page.evaluate("""() => {
                    const doc = document.documentElement;
                    const wall = document.querySelector('#wall');
                    const cards = [...wall.querySelectorAll('.card')];
                    const rects = cards.map(c => c.getBoundingClientRect());
                    return {
                      cardCount: cards.length,
                      pageWidth: doc.scrollWidth,
                      viewportWidth: doc.clientWidth,
                      cardWidths: rects.map(r => r.width),
                      firstCardRight: rects[0].right,
                      rightmostCard: Math.max(...rects.map(r => r.right)),
                      columns: getComputedStyle(wall).gridTemplateColumns.split(' ').length,
                    };
                }""")
                ok = (
                    result["cardCount"] == 8
                    and result["pageWidth"] <= result["viewportWidth"]
                    and result["rightmostCard"] <= width + 0.5
                    and result["firstCardRight"] <= width + 0.5
                )
                if width == 945:
                    ok = ok and result["columns"] == 2
                if width == 1920:
                    ok = ok and result["columns"] == 4
                print(("PASS" if ok else "FAIL"), density, width, result, flush=True)
                assert ok, f"Wall overflows at {width}px in {density} density: {result}"
    finally:
        page.close()


def main():
    """Run the width matrix using the repository's browser-test convention."""
    with sync_playwright() as p:
        args = {"headless": True}
        if os.environ.get("KLEPSYDRA_CHROME"):
            args["executable_path"] = os.environ["KLEPSYDRA_CHROME"]
        browser = p.chromium.launch(**args)
        try:
            run(browser)
        finally:
            browser.close()


if __name__ == "__main__":
    main()
