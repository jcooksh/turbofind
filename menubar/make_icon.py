"""Render AppIcon.icns from the TurboFind logo (white mark on a dark squircle).

Composites assets/logo-white.png onto a rounded-square dark tile, then builds
the .iconset and runs iconutil. macOS only (uses sips + iconutil).

    python make_icon.py        # -> AppIcon.icns  (+ icon_1024.png)
"""
import shutil
import subprocess
from pathlib import Path

from PIL import Image

SZ = 1024
HERE = Path(__file__).parent
LOGO = HERE.parent / "assets" / "logo-white.png"


def render_png() -> Path:
    img = Image.new("RGBA", (SZ, SZ), (0, 0, 0, 0))
    # dark rounded-square background (drawn via a mask for clean corners)
    bg = Image.new("RGBA", (SZ, SZ), (15, 17, 21, 255))
    mask = Image.new("L", (SZ, SZ), 0)
    from PIL import ImageDraw
    ImageDraw.Draw(mask).rounded_rectangle([0, 0, SZ - 1, SZ - 1], radius=225, fill=255)
    img.paste(bg, (0, 0), mask)

    # logo centred at ~62% of the canvas width
    logo = Image.open(LOGO).convert("RGBA")
    target_w = int(SZ * 0.62)
    scale = target_w / logo.width
    logo = logo.resize((target_w, int(logo.height * scale)), Image.LANCZOS)
    pos = ((SZ - logo.width) // 2, (SZ - logo.height) // 2)
    img.paste(logo, pos, logo)

    out = HERE / "icon_1024.png"
    img.save(out)
    return out


def build_icns(src: Path) -> None:
    iconset = HERE / "AppIcon.iconset"
    if iconset.exists():
        shutil.rmtree(iconset)
    iconset.mkdir()
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
