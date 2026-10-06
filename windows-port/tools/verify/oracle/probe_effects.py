"""Reproducers for the layer-effect divergences: one 16x12 white box per document, each with a
different effect over a dark backdrop, rendered one package at a time so the bounds are
unambiguous. Every effect paints white at full opacity, so the rendered image shows the coverage
the engine used. The no-effect case is the control: the layer's own pixels.

Run:  python probe_effects.py [--compc PATH]
Writes fixtures-oracle/probe-*.comp and probe-*.png, then prints each case's coverage bounds next
to the bounds the layer's pixels have. A rectangle that is wider, narrower or shifted means the
effect surface is not placed where the macOS renderer places it, which grows the layer's transform
by the margin so the padded surface lands one-to-one.
"""

from __future__ import annotations

import argparse
import os
import subprocess
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from oracle_comp import write_package  # noqa: E402

WIDTH, HEIGHT = 128, 48
BOX_WIDTH, BOX_HEIGHT = 16, 12
ORIGINS = [(14, 18), (38, 18), (62, 18), (86, 18), (110, 18)]
ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(os.path.dirname(os.path.dirname(ROOT)))
DEFAULT_COMPC = os.path.join(REPO, "target-lead", "debug", "compc.exe")

CASES = [
    ("control (no effect)", None),
    ("color overlay, margin 2", {"colorOverlay": {"red": 1.0, "green": 1.0, "blue": 1.0, "opacity": 1.0}}),
    ("shadow distance 3, margin 5", {"shadow": {"angle": 90.0, "distance": 3.0, "blur": 0.0,
                                                "red": 1.0, "green": 1.0, "blue": 1.0, "opacity": 1.0}}),
    ("shadow distance 10, margin 12", {"shadow": {"angle": 90.0, "distance": 10.0, "blur": 0.0,
                                                  "red": 1.0, "green": 1.0, "blue": 1.0, "opacity": 1.0}}),
    ("stroke outside size 4, margin 6", {"stroke": {"size": 4.0, "red": 1.0, "green": 1.0, "blue": 1.0,
                                                    "opacity": 1.0, "inside": False}}),
]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--compc", default=DEFAULT_COMPC)
    arguments = parser.parse_args()

    directory = os.path.join(ROOT, "fixtures-oracle")
    os.makedirs(directory, exist_ok=True)

    backdrop = np.zeros((HEIGHT, WIDTH, 4), dtype=np.uint8)
    backdrop[..., :3] = 32
    backdrop[..., 3] = 255

    box = np.zeros((BOX_HEIGHT, BOX_WIDTH, 4), dtype=np.uint8)
    box[..., :3] = 255
    box[..., 3] = 255

    origin = ORIGINS[2]
    print("%-34s %-22s %s" % ("case", "coverage bounds", "layer pixels"))
    for index, (label, effects) in enumerate(CASES):
        layer = {"name": "Box", "rgba": box,
                 "transform": {"origin": [float(origin[0]), float(origin[1])],
                               "size": [float(BOX_WIDTH), float(BOX_HEIGHT)],
                               "rotation": 0.0, "flipX": False, "flipY": False, "sampling": "Nearest"}}
        if effects is not None:
            layer["effects"] = effects
        package = os.path.join(directory, "probe-%d.comp" % index)
        write_package(package, WIDTH, HEIGHT, [{"name": "Chart", "rgba": backdrop}, layer])
        output = os.path.join(directory, "probe-%d.png" % index)
        subprocess.run([arguments.compc, "render", package, "-o", output], check=True)
        with Image.open(output) as image:
            rendered = np.asarray(image.convert("RGBA"), dtype=np.int64)
        bright = rendered[..., 0] > 200
        rows = np.nonzero(bright.any(axis=1))[0]
        columns = np.nonzero(bright.any(axis=0))[0]
        print("%-34s x %3d..%-3d y %3d..%-3d   x %d..%d y %d..%d" % (
            label, columns[0], columns[-1], rows[0], rows[-1],
            origin[0], origin[0] + BOX_WIDTH - 1, origin[1], origin[1] + BOX_HEIGHT - 1))
    print()
    print("The control row shows where the layer's own pixels are. Every other row must contain the")
    print("control row's rectangle (a shadow or stroke extends past it by its own distance or size).")


if __name__ == "__main__":
    main()
