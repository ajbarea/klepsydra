"""Draw the phone wall's Home Screen icons from the klepsydra mark.

`uv run -q --no-project --with pillow python -I scripts/make-phone-icons.py`
writes src/phone/icon-192.png, icon-512.png and apple-touch-icon.png (180 px):
the mark of src-tauri/icons/512x512.png on the wall's background, opaque
(iOS fills a transparent icon with black) and inside the maskable safe zone
(the centre circle of 80% diameter).
"""

from pathlib import Path

from PIL import Image

ROOT = Path(__file__).resolve().parent.parent
MARK = ROOT / "src-tauri/icons/512x512.png"
OUT = ROOT / "src/phone"
WALL_BG = (0x11, 0x15, 0x1B, 255)  # wall.css --wall-bg
SIZES = {"icon-192.png": 192, "icon-512.png": 512, "apple-touch-icon.png": 180}
SAFE = 0.72  # the mark's width as a share of the icon; its corners stay inside the 80% circle


def main() -> None:
    mark = Image.open(MARK).convert("RGBA")
    mark = mark.crop(mark.getbbox())
    OUT.mkdir(exist_ok=True)
    for name, size in SIZES.items():
        icon = Image.new("RGBA", (size, size), WALL_BG)
        w = round(size * SAFE)
        h = round(mark.height * w / mark.width)
        scaled = mark.resize((w, h), Image.LANCZOS)
        icon.alpha_composite(scaled, ((size - w) // 2, (size - h) // 2))
        icon.convert("RGB").save(OUT / name, optimize=True)
        print(f"{name}: {size}x{size}")


if __name__ == "__main__":
    main()
