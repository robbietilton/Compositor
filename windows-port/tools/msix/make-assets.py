"""Draws the packaged application's image assets.

Run:  python tools/msix/make-assets.py [output directory]
The MSIX manifest names these files, and makeappx refuses a package whose assets are missing or the
wrong size, so they are generated rather than hand-made.
"""

from __future__ import annotations

import os
import sys

from PIL import Image, ImageDraw

SIZES = {
    "Square44x44Logo.png": (44, 44),
    "Square150x150Logo.png": (150, 150),
    "Wide310x150Logo.png": (310, 150),
    "StoreLogo.png": (50, 50),
}

BACKGROUND_TOP = (28, 38, 74)
BACKGROUND_BOTTOM = (86, 108, 176)
MARK = (245, 176, 66)


def draw(size):
    width, height = size
    image = Image.new("RGBA", size, (0, 0, 0, 0))
    draw = ImageDraw.Draw(image)
    for y in range(height):
        t = y / max(1, height - 1)
        draw.line(
            [(0, y), (width, y)],
            fill=(
                round(BACKGROUND_TOP[0] + (BACKGROUND_BOTTOM[0] - BACKGROUND_TOP[0]) * t),
                round(BACKGROUND_TOP[1] + (BACKGROUND_BOTTOM[1] - BACKGROUND_TOP[1]) * t),
                round(BACKGROUND_TOP[2] + (BACKGROUND_BOTTOM[2] - BACKGROUND_TOP[2]) * t),
                255,
            ),
        )
    # A layered mark: one square over another, the compositing idea in miniature.
    unit = min(width, height)
    back = [unit * 0.18, unit * 0.30, unit * 0.52, unit * 0.64]
    front = [unit * 0.34, unit * 0.20, unit * 0.68, unit * 0.54]
    if width > height:  # the wide tile keeps the mark centred
        shift = (width - height) / 2
        back[0] += shift
        back[2] += shift
        front[0] += shift
        front[2] += shift
    draw.rectangle(back, fill=(255, 255, 255, 210))
    draw.rectangle(front, fill=MARK + (255,))
    return image


def main(argv):
    directory = argv[1] if len(argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), "Assets")
    os.makedirs(directory, exist_ok=True)
    for name, size in SIZES.items():
        draw(size).save(os.path.join(directory, name))
        print(f"wrote {os.path.join(directory, name)} {size[0]}x{size[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
