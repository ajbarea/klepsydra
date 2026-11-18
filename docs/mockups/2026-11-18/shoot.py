"""Screenshot every mockup page at 1920x1080 and 390 wide, in both themes.

Run: uv run --with playwright python shoot.py OUT_DIR [page ...]
Writes OUT_DIR/design-<page>-<width>-<theme>.png (full page) and prints the
linear strip's measured width at 1920 and 1366 for the gauge pages.
"""

import sys
from pathlib import Path

from playwright.sync_api import sync_playwright

HERE = Path(__file__).resolve().parent
PAGES = [
    "gauge-a",
    "gauge-b",
    "new-session-a",
    "new-session-b",
    "settings-a",
    "settings-b",
    "wall-cards",
]
SIZES = [(1920, 1080), (390, 844)]
THEMES = ["dark", "light"]


def main() -> None:
    out = Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    pages = sys.argv[2:] or PAGES
    with sync_playwright() as p:
        browser = p.chromium.launch()
        try:
            for name in pages:
                url = (HERE / f"{name}.html").as_uri()
                for theme in THEMES:
                    for w, h in SIZES:
                        ctx = browser.new_context(
                            viewport={"width": w, "height": h},
                            color_scheme=theme,
                            device_scale_factor=1,
                            reduced_motion="reduce",
                        )
                        page = ctx.new_page()
                        errors: list[str] = []
                        page.on("pageerror", lambda e: errors.append(str(e)))
                        page.on(
                            "console",
                            lambda m: (
                                errors.append(m.text) if m.type == "error" else None
                            ),
                        )
                        page.goto(f"{url}?theme={theme}")
                        page.wait_for_load_state("networkidle")
                        page.evaluate("document.fonts.ready")
                        overflow = page.evaluate(
                            "document.documentElement.scrollWidth - innerWidth"
                        )
                        # Clipped content: an element past the right edge, other than inside a scroller.
                        clipped = page.evaluate(
                            """[...document.querySelectorAll('main *')].filter(e => {
                                 const r = e.getBoundingClientRect();
                                 return r.width && r.right > innerWidth + 1 && !e.closest('.rail');
                               }).slice(0, 4).map(e => e.getAttribute('class') || e.tagName)"""
                        )
                        path = out / f"design-{name}-{w}-{theme}.png"
                        page.screenshot(path=str(path), full_page=True)
                        print(
                            f"{path.name}: overflow={overflow}px clipped={clipped or 'none'} errors={errors or 'none'}"
                        )
                        if name.startswith("gauge") and theme == "dark" and w == 1920:
                            for vw in (1920, 1366):
                                page.set_viewport_size({"width": vw, "height": 1080})
                                sw = page.evaluate(
                                    "Math.round(document.querySelector('.measure .strip').getBoundingClientRect().width)"
                                )
                                print(f"  {name} linear strip width at {vw}: {sw}px")
                        ctx.close()
        finally:
            browser.close()


if __name__ == "__main__":
    main()
