r"""An independent port of the filter kernels that have exact C implementations upstream.

Lens distortion is ported from compositor_mac/Compositor/Rendering/LensPixels.c line for line: the same
radial scale, the same pixel-centre arithmetic, the same bilinear taps and the same rounding. A filter
whose upstream implementation is a Core Image filter cannot be checked this way — those are documented
as approximations instead.

Run:  python oracle_filters.py <in.png> <out.png> --kind lens --k 0.25
"""

from __future__ import annotations

import math
import sys

import numpy as np
from PIL import Image


def lens_distort(pixels: np.ndarray, k: float) -> np.ndarray:
    """Ports `lens_distort`: sample each destination pixel from a radially scaled source position."""
    height, width = pixels.shape[:2]
    cx, cy = width * 0.5, height * 0.5
    half_diagonal_squared = cx * cx + cy * cy
    source = pixels.astype(np.float64)
    out = np.zeros_like(source)

    for y in range(height):
        dy = y + 0.5 - cy
        for x in range(width):
            dx = x + 0.5 - cx
            scale = 1.0 - k * (dx * dx + dy * dy) / half_diagonal_squared
            # Source position in pixel-centre coordinates.
            sx = cx + dx * scale - 0.5
            sy = cy + dy * scale - 0.5
            fx0 = math.floor(sx)
            fy0 = math.floor(sy)
            fx = sx - fx0
            fy = sy - fy0
            x0 = int(fx0)
            y0 = int(fy0)
            sums = [0.0, 0.0, 0.0, 0.0]
            for j in (0, 1):
                row = y0 + j
                if row < 0 or row >= height:
                    continue
                wy = fy if j else 1.0 - fy
                if wy == 0.0:
                    continue
                for i in (0, 1):
                    column = x0 + i
                    if column < 0 or column >= width:
                        continue
                    weight = wy * (fx if i else 1.0 - fx)
                    if weight == 0.0:
                        continue
                    for c in range(4):
                        sums[c] += weight * source[row, column, c]
            for c in range(4):
                out[y, x, c] = round(sums[c])

    # The kernel weights every channel the same way, so its raw output is *premultiplied*: where a
    # destination pixel pulls from outside the image the color is scaled by the coverage it found.
    # macOS hands it a premultiplied bitmap context and draws the result straight back; a straight-alpha
    # PNG needs the color divided by that coverage again, which is what the editor's Bitmap8 holds.
    alpha = out[..., 3:4]
    straight = np.where(alpha > 0, out[..., :3] * 255.0 / np.maximum(alpha, 1e-9), 0.0)
    out[..., :3] = np.clip(straight, 0.0, 255.0).round()
    return out


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    source_path, target_path = argv[1], argv[2]
    k = 0.0
    if "--k" in argv:
        k = float(argv[argv.index("--k") + 1])
    with Image.open(source_path) as handle:
        pixels = np.asarray(handle.convert("RGBA"), dtype=np.uint8)
    result = lens_distort(pixels, k)
    Image.fromarray(np.clip(result, 0, 255).astype(np.uint8), mode="RGBA").save(target_path)
    print(f"lens distortion k={k}: {source_path} -> {target_path}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
