"""Cut a portrait's figure out of its painted backdrop, for the wall's header band.

The ten kourai portraits ship with transparent cut-outs; the newer ones are
painted on a dark backdrop. This runs rembg's `isnet-anime` model (IS-Net
trained on illustrated characters, SkyTNT/anime-segmentation, Apache-2.0)
once on kourai-khryseai's original (assets/avatars/originals/<name>.jpg or
.png, square: 2048 px for most, 1254 px for Athena) scaled to 1024 px, and
writes assets/portraits/<name>-cutout.webp, which is committed, so scripts/cut-portraits.py needs no model. About 3 s and 1.2 GB a
portrait on CPU; BiRefNet cut as cleanly but needed over 3.5 GB.

Usage (rembg 2.0.85 needs pillow below 13): uv run --no-project --with "rembg[cpu]==2.0.85" --with pillow==12.3.0 python -I scripts/cutout-portraits.py <kourai-khryseai> <name>...
"""

import sys
from pathlib import Path

from PIL import Image
from rembg import new_session, remove

ROOT = Path(__file__).resolve().parent.parent
PORTRAITS = ROOT / "assets" / "portraits"


def main(kourai: Path, names: list[str]) -> None:
    session = new_session("isnet-anime")
    for name in names:
        originals = kourai / "assets" / "avatars" / "originals"
        path = next((p for p in (originals / f"{name}.jpg", originals / f"{name}.png") if p.exists()), None)
        if path is None:
            raise SystemExit(f"{name}: no {name}.jpg or {name}.png in {originals}")
        original = Image.open(path).convert("RGB")
        if original.width != original.height or original.width < 1024:
            raise SystemExit(f"{name}: expected a square of at least 1024 px, got {original.size}")
        portrait = original.resize((1024, 1024), Image.Resampling.LANCZOS)
        remove(portrait, session=session).save(PORTRAITS / f"{name}-cutout.webp", "WEBP", quality=90, method=6)
        print(f"cut out {name}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]), sys.argv[2:])
