"""Render AppIcon.icns from the TurboFind logo (white mark on a dark squircle).

Draws the logo polygons directly (same coords as assets/logo-*.svg) with Pillow,
then builds the .iconset and runs iconutil. macOS only (uses sips + iconutil).

    python make_icon.py        # -> AppIcon.icns  (+ icon_1024.png)
"""
import shutil
import subprocess
from pathlib import Path

from PIL import Image, ImageDraw

SZ = 1024
HERE = Path(__file__).parent

# Logo polygons in the 0..64 viewBox (must match assets/logo-*.svg).
POLYS = [
    [(8, 10), (56, 10), (52, 21), (12, 21)],                  # top bar
    [(34, 25), (53, 25), (49, 35), (30, 35)],                 # F arm
    [(27, 10), (45, 10), (29, 32), (40, 32),
     (18, 58), (27, 33), (15, 33)],                           # lightning stem
]


def render_png() -> Path:
    img = Image.new("RGBA", (SZ, SZ), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)
    d.rounded_rectangle([0, 0, SZ - 1, SZ - 1], radius=225, fill=(15, 17, 21, 255))
    scale = 600 / 64
    off = (SZ - 64 * scale) / 2
    for poly in POLYS:
        d.polygon([(off + x * scale, off + y * scale) for (x, y) in poly],
                  fill=(255, 255, 255, 255))
    out = HERE / "icon_1024.png"
    img.save(out)
    return out


def build_icns(src: Path) -> None:
    iconset = HERE / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
    # (size, filename) pairs macOS expects in an .iconset
    specs = [(16, "icon_16x16.png"), (32, "icon_16x16@2x.png"),
             (32, "icon_32x32.png"), (64, "icon_32x32@2x.png"),
             (128, "icon_128x128.png"), (256, "icon_128x128@2x.png"),
             (256, "icon_256x256.png"), (512, "icon_256x256@2x.png"),
             (512, "icon_512x512.png"), (1024, "icon_512x512@2x.png")]
    for size, name in specs:
        subprocess.run(["sips", "-z", str(size), str(size), str(src),
                        "--out", str(iconset / name)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.run(["iconutil", "-c", "icns", str(iconset),
                    "-o", str(HERE / "AppIcon.icns")], check=True)
    shutil.rmtree(iconset)
    print("wrote", HERE / "AppIcon.icns")


if __name__ == "__main__":
    build_icns(render_png())
