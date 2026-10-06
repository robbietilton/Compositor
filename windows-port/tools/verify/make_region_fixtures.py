"""Builds packages that exercise region rendering where it is hardest.

These are not pixel fixtures: the oracle does not model blur kernels or noise patterns. They exist for
check_regions.ps1, which compares a region render against a cropped full render of the same package —
a comparison that needs no oracle at all, and one that fails loudly if a blurred layer is not given the
pixels just outside the rectangle or if a noise pattern moves with the rectangle.

Run:  python make_region_fixtures.py
"""

from __future__ import annotations

import os

import numpy as np
from PIL import Image

import comp_reference as R

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures-regions")
WIDTH, HEIGHT = 96, 64


def backdrop():
    xs = np.linspace(0.0, 1.0, WIDTH)[None, :]
    ys = np.linspace(0.0, 1.0, HEIGHT)[:, None]
    array = np.zeros((HEIGHT, WIDTH, 4))
    array[..., 0] = np.broadcast_to(xs, (HEIGHT, WIDTH))
    array[..., 1] = np.broadcast_to(ys, (HEIGHT, WIDTH))
    array[..., 2] = 0.6
    array[..., 3] = 1.0
    return R.array_to_rgba_image(array)


def block():
    """A small hard-edged block in the middle, so blur and shadow have an edge to spread."""
    array = np.zeros((HEIGHT, WIDTH, 4))
    array[HEIGHT // 3: HEIGHT * 2 // 3, WIDTH // 3: WIDTH * 2 // 3, :3] = 1.0
    array[HEIGHT // 3: HEIGHT * 2 // 3, WIDTH // 3: WIDTH * 2 // 3, 3] = 1.0
    return R.array_to_rgba_image(array)


def levels_block():
    return {
        "channel": "RGB",
        "ranges": [{"black": 0.0, "gamma": 1.0, "white": 255.0, "outputBlack": 0.0, "outputWhite": 255.0}] * 4,
    }


def curves_block():
    return {"channel": "RGB", "channels": [[{"x": 0.0, "y": 0.0}, {"x": 255.0, "y": 255.0}]] * 4}


def main():
    os.makedirs(FIXTURES, exist_ok=True)
    written = []

    # A blurred adjustment: every pixel of a region needs source pixels from beyond it.
    package = os.path.join(FIXTURES, "region-gaussian-blur.comp")
    R.write_comp(package, WIDTH, HEIGHT, [
        {"name": "Backdrop", "image": backdrop()},
        {"name": "Block", "image": block()},
        {
            "name": "Blur",
            "adjustment": {
                "kind": "Gaussian Blur", "hue": 0.0, "saturation": 0.0, "lightness": 0.0,
                "colorize": False, "levels": levels_block(), "curves": curves_block(),
                "blurRadius": 12.0,
            },
            "transform": {"origin": [0.0, 0.0], "size": [float(WIDTH), float(HEIGHT)],
                          "rotation": 0.0, "flipX": False, "flipY": False, "sampling": "Nearest"},
        },
    ])
    written.append("region-gaussian-blur.comp")

    # Add Noise is anchored in document coordinates: the same pixel must get the same grain whatever
    # rectangle it is rendered in.
    package = os.path.join(FIXTURES, "region-add-noise.comp")
    R.write_comp(package, WIDTH, HEIGHT, [
        {"name": "Backdrop", "image": backdrop()},
        {
            "name": "Noise",
            "adjustment": {
                "kind": "Add Noise", "hue": 0.0, "saturation": 0.0, "lightness": 0.0,
                "colorize": False, "levels": levels_block(), "curves": curves_block(),
                "noiseAmount": 60.0, "noiseGaussian": True, "noiseMonochromatic": False, "noiseSeed": 12345,
            },
            "transform": {"origin": [0.0, 0.0], "size": [float(WIDTH), float(HEIGHT)],
                          "rotation": 0.0, "flipX": False, "flipY": False, "sampling": "Nearest"},
        },
    ])
    written.append("region-add-noise.comp")

    # A layer effect with a blur and an offset: the shadow of a block reaches outside the block.
    package = os.path.join(FIXTURES, "region-layer-shadow.comp")
    R.write_comp(package, WIDTH, HEIGHT, [
        {"name": "Backdrop", "image": backdrop()},
        {
            "name": "Block",
            "image": block(),
            "effects": {
                "shadow": {"angle": 45.0, "distance": 8.0, "blur": 10.0, "red": 0.0, "green": 0.0,
                           "blue": 0.0, "opacity": 0.8},
                "outerGlow": {"size": 12.0, "red": 1.0, "green": 0.4, "blue": 0.2, "opacity": 0.7},
            },
        },
    ])
    written.append("region-layer-shadow.comp")

    # A big blur on a layer whose own pixels only touch part of the canvas.
    package = os.path.join(FIXTURES, "region-small-layer.comp")
    small = np.zeros((16, 24, 4))
    small[:, :, 0] = 0.9
    small[:, :, 3] = 1.0
    R.write_comp(package, WIDTH, HEIGHT, [
        {"name": "Backdrop", "image": backdrop()},
        {
            "name": "Small",
            "image": R.array_to_rgba_image(small),
            "transform": {"origin": [30.0, 18.0], "size": [24.0, 16.0], "rotation": 25.0,
                          "flipX": False, "flipY": False, "sampling": "High quality"},
        },
    ])
    written.append("region-small-layer.comp")

    print(f"wrote {len(written)} region fixtures to {FIXTURES}")
    for name in written:
        print(" ", name)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
