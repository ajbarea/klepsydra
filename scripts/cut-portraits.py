"""Cut the ten kourai-khryseai portraits to the fleet's faces: the head of each
640 px neutral portrait, as 96 px and 192 px WebP, with a LICENSES.json entry
for each file.

Usage: uv run --no-project --with pillow==13.0.0 python -I scripts/cut-portraits.py <kourai-khryseai> <faces dir>
"""

import json
import sys
from pathlib import Path

from PIL import Image

NAMES = ("aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne")
# (left, top, right, bottom) of the head in the 640 px portrait. Hephaestus
# stands right of centre at his anvil.
HEAD = {name: (180, 20, 460, 300) for name in NAMES} | {"hephaestus": (250, 20, 530, 300)}
SIZES = (96, 192)
SOURCE = (
    "kourai-khryseai assets/avatars/vn/{name}_neutral.png "
    "(https://github.com/ajbarea/kourai-khryseai), head cropped and scaled to {size} px"
)
LICENSE = "MIT (kourai-khryseai LICENSE, Copyright (c) 2026 AJ Barea)"


def main(kourai: Path, faces: Path) -> None:
    licenses_path = faces / "LICENSES.json"
    licenses = json.loads(licenses_path.read_text())
    (faces / "kourai").mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        portrait = Image.open(kourai / "assets" / "avatars" / "vn" / f"{name}_neutral.png").convert("RGB")
        if portrait.size != (640, 640):
            raise SystemExit(f"{name}: expected 640x640, got {portrait.size}")
        head = portrait.crop(HEAD[name])
        for size in SIZES:
            file = f"kourai/{name}-{size}.webp"
            head.resize((size, size), Image.Resampling.LANCZOS).save(faces / file, "WEBP", quality=82, method=6)
            licenses[file] = {"source": SOURCE.format(name=name, size=size), "license": LICENSE}
    licenses_path.write_text(json.dumps(dict(sorted(licenses.items())), indent=2) + "\n")
    print(f"cut {len(NAMES)} portraits at {', '.join(map(str, SIZES))} px")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
