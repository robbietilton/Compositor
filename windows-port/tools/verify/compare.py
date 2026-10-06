"""Compares a rendered PNG with the reference PNG for a fixture.

Run:  python compare.py <expected.png> <actual.png> [tolerance]
Exits 1 when any channel differs by more than the tolerance (default 1 level).
"""

from __future__ import annotations

import sys

import numpy as np
from PIL import Image


def compare(expected_path, actual_path, tolerance=1):
    with Image.open(expected_path) as handle:
        expected = np.asarray(handle.convert("RGBA"), dtype=np.int16)
    with Image.open(actual_path) as handle:
        actual = np.asarray(handle.convert("RGBA"), dtype=np.int16)
    if expected.shape != actual.shape:
        return {
            "ok": False,
            "reason": f"size mismatch: expected {expected.shape}, got {actual.shape}",
        }
    diff = np.abs(expected - actual)
    worst = int(diff.max())
    mismatched = int((diff.max(axis=-1) > tolerance).sum())
    return {
        "ok": worst <= tolerance,
        "worst": worst,
        "mean": float(diff.mean()),
        "mismatched_pixels": mismatched,
        "total_pixels": int(expected.shape[0] * expected.shape[1]),
        "tolerance": tolerance,
    }


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    tolerance = int(argv[3]) if len(argv) > 3 else 1
    result = compare(argv[1], argv[2], tolerance)
    print(result)
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
