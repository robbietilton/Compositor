"""Shows exactly where a render diverges from the reference, pixel by pixel.

Run:  python diagnose.py <fixture-name> [count]
Example: python diagnose.py blend-hue 12
"""

from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

import comp_reference as R

HERE = os.path.dirname(os.path.abspath(__file__))
CLI = os.path.join(HERE, "..", "..", "target-lead", "debug", "compc.exe")


def lum(rgb):
    return 0.3 * rgb[..., 0] + 0.59 * rgb[..., 1] + 0.11 * rgb[..., 2]


def sat(rgb):
    return rgb.max(axis=-1) - rgb.min(axis=-1)


def main(argv):
    if len(argv) < 2:
        print(__doc__)
        return 2
    name = argv[1]
    count = int(argv[2]) if len(argv) > 2 else 10
    package = os.path.join(HERE, "fixtures", f"{name}.comp")
    expected_path = os.path.join(HERE, "fixtures", "expected", f"{name}.png")
    if not os.path.exists(package):
        print(f"no such fixture: {package}")
        return 2

    with tempfile.TemporaryDirectory() as work:
        actual_path = os.path.join(work, "actual.png")
        process = subprocess.run([os.path.abspath(CLI), "render", package, "-o", actual_path],
                                 capture_output=True, text=True)
        if process.returncode != 0:
            print("render failed:", process.stderr)
            return 1
        manifest, images, masks = R.read_comp(package)
        expected = np.asarray(Image.open(expected_path).convert("RGBA"), dtype=np.int16)
        actual = np.asarray(Image.open(actual_path).convert("RGBA"), dtype=np.int16)

    diff = np.abs(expected - actual).max(axis=-1)
    print(f"fixture {name}: worst {diff.max()}, mean {np.abs(expected - actual).mean():.4f}, "
          f"pixels over 1: {(diff > 1).sum()}/{diff.size}")

    flat_backdrop = images[manifest["layers"][0]["id"]][0, 0, :3] if images else None
    order = np.stack(np.unravel_index(np.argsort(-diff, axis=None), diff.shape), axis=-1)[:count]
    for y, x in order:
        row = {
            "x": int(x),
            "y": int(y),
            "backdrop": [round(float(images[manifest["layers"][0]["id"]][y, x, c]) * 255) for c in range(3)],
            "source": [round(float(images[manifest["layers"][1]["id"]][y, x, c]) * 255) for c in range(3)],
            "expected": expected[y, x].tolist(),
            "actual": actual[y, x].tolist(),
            "diff": int(diff[y, x]),
        }
        print(json.dumps(row))

    # The defining invariant of the non-separable modes: Hue keeps the backdrop's luminosity and the
    # source's saturation; Saturation keeps the backdrop's luminosity and the source's saturation.
    if name in {"blend-hue", "blend-saturation", "blend-luminosity", "blend-color"}:
        for label, data in (("expected", expected), ("actual", actual)):
            rgb = data[..., :3].astype(np.float64) / 255.0
            backdrop = images[manifest["layers"][0]["id"]][..., :3]
            source = images[manifest["layers"][1]["id"]][..., :3]
            print(f"{label}: max |lum(result)-lum(backdrop)| = {np.abs(lum(rgb) - lum(backdrop)).max():.5f}"
                  f", max |sat(result)-sat(source)| = {np.abs(sat(rgb) - sat(source)).max():.5f}"
                  f", max |sat(result)-sat(backdrop)| = {np.abs(sat(rgb) - sat(backdrop)).max():.5f}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
