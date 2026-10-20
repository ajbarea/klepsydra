"""Cut the fifteen kourai portraits to the fleet's faces, as 96 px and 192 px
WebP, with a LICENSES.json entry for each file. Ten come from the head of the
kourai-khryseai 640 px neutral portraits; five (chronos, argos, hermes, elpis, hesychia)
come from this repo's assets/portraits/<name>.jpg.

Usage: uv run --no-project --with pillow==13.0.0 python -I scripts/cut-portraits.py <kourai-khryseai> <faces dir>
"""

import json
import sys
from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
KOURAI = ("aidos", "aletheia", "cupid", "dokimasia", "hephaestus", "kallos", "metis", "mneme", "puck", "techne")
NEW = ("argos", "chronos", "elpis", "hermes", "hesychia")
NAMES = tuple(sorted(KOURAI + NEW))
# (left, top, right, bottom) of the head in the source portrait. Hephaestus
# stands right of centre at his anvil. The five new boxes are in the 1024 px
# JPEGs, framed like Hephaestus: head and beard in the upper middle, one
# shoulder entering the circle. Hermes's hat wings clip; his face and brim stay.
HEAD = (
    {name: (180, 20, 460, 300) for name in KOURAI}
    | {"hephaestus": (250, 20, 530, 300)}
    | {"chronos": (330, 20, 970, 660), "argos": (200, 20, 700, 520), "hermes": (330, 30, 850, 550), "elpis": (300, 20, 780, 500), "hesychia": (250, 40, 810, 600)}
)
SIZES = (96, 192)
SOURCE = (
    "kourai-khryseai assets/avatars/vn/{name}_neutral.png "
    "(https://github.com/ajbarea/kourai-khryseai), head cropped and scaled to {size} px"
)
LICENSE = "MIT (kourai-khryseai LICENSE, Copyright (c) 2026 AJ Barea)"
NEW_SOURCE = (
    "AJ Barea, generated from the briefs in docs/characters/portrait-briefs.md "
    "(assets/portraits/{name}.jpg), head cropped and scaled to {size} px"
)
NEW_LICENSE = "MIT (Copyright (c) 2026 AJ Barea)"


def main(kourai: Path, faces: Path) -> None:
    licenses_path = faces / "LICENSES.json"
    licenses = json.loads(licenses_path.read_text())
    (faces / "kourai").mkdir(parents=True, exist_ok=True)
    for name in NAMES:
        new = name in NEW
        path = ROOT / "assets" / "portraits" / f"{name}.jpg" if new else kourai / "assets" / "avatars" / "vn" / f"{name}_neutral.png"
        portrait = Image.open(path).convert("RGB")
        expected = (1024, 1024) if new else (640, 640)
        if portrait.size != expected:
            raise SystemExit(f"{name}: expected {expected}, got {portrait.size}")
        head = portrait.crop(HEAD[name])
        for size in SIZES:
            file = f"kourai/{name}-{size}.webp"
            head.resize((size, size), Image.Resampling.LANCZOS).save(faces / file, "WEBP", quality=82, method=6)
            licenses[file] = (
                {"source": NEW_SOURCE.format(name=name, size=size), "license": NEW_LICENSE}
                if new
                else {"source": SOURCE.format(name=name, size=size), "license": LICENSE}
            )
    licenses_path.write_text(json.dumps(dict(sorted(licenses.items())), indent=2) + "\n")
    print(f"cut {len(NAMES)} portraits at {', '.join(map(str, SIZES))} px")


if __name__ == "__main__":
    if len(sys.argv) != 3:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]), Path(sys.argv[2]))
