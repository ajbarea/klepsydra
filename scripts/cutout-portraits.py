"""Cut a portrait's figure out of its painted backdrop, for the wall's header band.

The ten kourai portraits ship with transparent cut-outs; the newer ones are
painted on a dark backdrop. This runs BiRefNet (MIT, rembg's
`birefnet-portrait` model) once on kourai-khryseai's 2048 px original
(assets/avatars/originals/<name>.jpg) scaled to 1024 px, and writes
assets/portraits/<name>-cutout.webp, which is committed, so
scripts/cut-portraits.py needs no model. About ten minutes a portrait on CPU.

Usage: uv run --no-project --with "rembg[cpu]==2.0.85" --with pillow==12.3.0 python -I scripts/cutout-portraits.py <kourai-khryseai> <name>...
"""

import sys
from pathlib import Path

from PIL import Image
from rembg import new_session, remove

ROOT = Path(__file__).resolve().parent.parent
PORTRAITS = ROOT / "assets" / "portraits"


def main(kourai: Path, names: list[str]) -> None:
    session = new_session("birefnet-portrait")
    for name in names:
        original = Image.open(kourai / "assets" / "avatars" / "originals" / f"{name}.jpg").convert("RGB")
        if original.size != (2048, 2048):
            raise SystemExit(f"{name}: expected 2048x2048, got {original.size}")
        portrait = original.resize((1024, 1024), Image.Resampling.LANCZOS)
        remove(portrait, session=session).save(PORTRAITS / f"{name}-cutout.webp", "WEBP", quality=90, method=6)
        print(f"cut out {name}", flush=True)


if __name__ == "__main__":
    if len(sys.argv) < 3:
        raise SystemExit(__doc__)
    main(Path(sys.argv[1]), sys.argv[2:])
