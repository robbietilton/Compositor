"""Checks PSD import against PSD files this repository did not write.

Each case is built by psd_oracle.py (a from-scratch PSD writer), imported by the CLI, rendered, and
compared with the composite the generator computed itself. Both the bytes and the expectation come from
the second implementation, so agreeing means the importer understood the format rather than agreeing
with itself.

Usage: python verify_psd.py --cli <compc> [--work <dir>]
"""

from __future__ import annotations

import argparse
import os
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

import psd_oracle as P

TOLERANCE = 2


def solid(width, height, rgba):
    array = np.zeros((height, width, 4))
    array[..., 0], array[..., 1], array[..., 2], array[..., 3] = rgba
    return array


def pattern(width, height, seed):
    rng = np.random.default_rng(seed)
    array = np.zeros((height, width, 4))
    array[..., :3] = rng.random((height, width, 3))
    array[..., 3] = 1.0
    return array


def cases():
    """(name, width, height, layers, kwargs) -- every one exercises a different part of the format."""
    backdrop = lambda: P.Layer("Backdrop", 0, 0, solid(32, 24, (0.1, 0.2, 0.6, 1.0)))
    top = lambda **kw: P.Layer("Top", 6, 5, pattern(12, 10, 7), **kw)
    return [
        ("rle-two-layers", 32, 24, [backdrop(), top(opacity=200)], {"compression": 1}),
        ("raw-two-layers", 32, 24, [backdrop(), top(opacity=255)], {"compression": 0}),
        ("multiply-half-opacity", 32, 24, [backdrop(), top(blend="Multiply", opacity=128)], {"compression": 1}),
        ("screen-blend", 32, 24, [backdrop(), top(blend="Screen", opacity=255)], {"compression": 1}),
        ("hidden-layer", 32, 24, [backdrop(), top(opacity=255, visible=False)], {"compression": 1}),
        ("layer-mask", 32, 24, [backdrop(), P.Layer("Masked", 4, 4, pattern(20, 16, 3), mask=np.where(
            np.arange(20)[None, :] < 10, 255, 0).repeat(16, axis=0).astype(np.uint8))], {"compression": 1}),
        ("late-layer-order", 32, 24, [top(opacity=255), backdrop()], {"compression": 1}),
    ]


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--work")
    args = parser.parse_args(argv)

    work = args.work or tempfile.mkdtemp(prefix="comppsd-")
    os.makedirs(work, exist_ok=True)
    failures = 0
    compared = 0
    refused = 0
    try:
        for name, width, height, layers, kwargs in cases():
            psd = os.path.join(work, name + ".psd")
            package = os.path.join(work, name + ".comp")
            render = os.path.join(work, name + ".png")
            expected = P.write_psd(psd, width, height, layers, **kwargs)
            if os.path.exists(package):
                shutil.rmtree(package)
            result = subprocess.run([args.cli, "psd", psd, package], capture_output=True, text=True)
            if result.returncode != 0:
                print(f"FAIL {name}: the importer refused a file this repository just wrote: "
                      f"{(result.stderr or result.stdout).strip()[:160]}")
                failures += 1
                continue
            result = subprocess.run([args.cli, "render", package, "-o", render], capture_output=True, text=True)
            if result.returncode != 0:
                print(f"FAIL {name}: the imported package does not render: "
                      f"{(result.stderr or result.stdout).strip()[:160]}")
                failures += 1
                continue
            with Image.open(render) as image:
                actual = np.asarray(image.convert("RGBA"), dtype=np.float64) / 255.0
            want = expected
            if want.shape != actual.shape:
                print(f"FAIL {name}: imported {actual.shape}, expected {want.shape}")
                failures += 1
                continue
            # Compare where either side has ink; fully transparent pixels carry no colour.
            mask = (want[..., 3] > 0.004) | (actual[..., 3] > 0.004)
            if not mask.any():
                print(f"ok   {name}: both sides empty")
                compared += 1
                continue
            diff = np.abs(want - actual) * 255.0
            worst = int(diff[mask].max())
            alpha_worst = int((np.abs(want[..., 3] - actual[..., 3]) * 255.0).max())
            compared += 1
            if worst > TOLERANCE or alpha_worst > TOLERANCE:
                worst_flat = np.unravel_index(np.argmax((diff.max(axis=-1)) * mask), mask.shape)
                print(f"FAIL {name}: worst {worst} levels (alpha {alpha_worst}) at {worst_flat}; "
                      f"expected {np.round(want[worst_flat] * 255)} got {np.round(actual[worst_flat] * 255)}")
                failures += 1
            else:
                print(f"ok   {name}: worst {worst} levels, alpha {alpha_worst}")
    finally:
        if not args.work:
            shutil.rmtree(work, ignore_errors=True)

    print(f"{compared} PSD files imported and compared, {refused} refused, {failures} wrong")
    if failures:
        print("FAIL")
        return 1
    print("PASS every generated PSD imported to the expected pixels")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
