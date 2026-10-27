"""Rasterize the Professions and DiceBear faces into src/fleet/faces.

Reads the SVGs and manifest.json that scripts/render-themes.mjs drew, renders
each in headless Chromium at 96 and 192 px and at 512 px for the portrait
dialog and the empty wall, saves them as WebP beside the kourai portraits,
and writes each file's LICENSES.json entry. Run through
scripts/render-themes.sh.

Usage: python -I scripts/render-themes.py <svg dir> <faces dir>
"""

import io
import json
import sys
from pathlib import Path

from PIL import Image
from playwright.sync_api import sync_playwright

SIZES = {"96": 96, "192": 192, "full": 512}
THEMES = ("professions", "dicebear")


def main(svgs: Path, faces: Path) -> None:
    manifest = json.loads((svgs / "manifest.json").read_text())
    licenses_path = faces / "LICENSES.json"
    licenses = json.loads(licenses_path.read_text())
    # A theme's folder is rewritten whole, so a face renamed in its theme file leaves no orphan.
    for theme in THEMES:
        for old in (faces / theme).glob("*.webp"):
            old.unlink()
        licenses = {k: v for k, v in licenses.items() if not k.startswith(f"{theme}/")}
    with sync_playwright() as p:
        browser = p.chromium.launch()
        page = browser.new_page(device_scale_factor=1)
        for svg_file, entry in manifest.items():
            if not svg_file.endswith(".svg"):
                # A licence text, shipped as it is.
                (faces / svg_file).parent.mkdir(parents=True, exist_ok=True)
                (faces / svg_file).write_bytes((svgs / svg_file).read_bytes())
                licenses[svg_file] = entry
                continue
            theme, name = svg_file.removesuffix(".svg").split("/")
            if theme not in THEMES:
                raise SystemExit(f"{svg_file}: not a theme this script renders")
            markup = (svgs / svg_file).read_text()
            (faces / theme).mkdir(parents=True, exist_ok=True)
            for suffix, px in SIZES.items():
                page.set_viewport_size({"width": px, "height": px})
                page.set_content(
                    "<!doctype html><style>html,body{margin:0;background:transparent}"
                    f"svg{{display:block;width:{px}px;height:{px}px}}</style>{markup}"
                )
                png = page.locator("svg").screenshot(omit_background=True)
                file = f"{theme}/{name}-{suffix}.webp"
                Image.open(io.BytesIO(png)).save(
                    faces / file, "WEBP", quality=90, alpha_quality=100, method=6
                )
                licenses[file] = {
                    "source": f"{entry['source']}, {px} px",
                    "license": entry["license"],
                }
        browser.close()
    licenses_path.write_text(json.dumps(dict(sorted(licenses.items())), indent=2) + "\n")
    print(f"rendered {sum(f.endswith('.svg') for f in manifest)} faces at {', '.join(str(v) for v in SIZES.values())} px")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit("usage: render-themes.py <svg dir> <faces dir>")
    main(Path(sys.argv[1]), Path(sys.argv[2]))
