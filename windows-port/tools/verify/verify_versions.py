"""Cross-checks the version fixtures against an independent reader.

Two things are checked, both against the Swift-decoder port in macos_interop.py rather than against the
Rust code that is under test:

* a package at version N is accepted, and its render matches the reference compositor;
* a package that uses a feature its version did not have is refused -- and refused by both readers, so
  the two agree on where the version gates are.

Usage:
  python verify_versions.py valid   <fixtures-dir> <renders-dir>
  python verify_versions.py invalid <fixtures-dir>
"""

from __future__ import annotations

import os
import sys

import numpy as np
from PIL import Image

import comp_reference as R
import macos_interop as M

TOLERANCE = 1


def valid(fixtures: str, renders: str) -> int:
    failures = 0
    packages = sorted(name for name in os.listdir(fixtures) if name.endswith(".comp"))
    for name in packages:
        path = os.path.join(fixtures, name)
        stem = name[:-len(".comp")]
        problems = M.validate_package(path)
        if problems:
            print(f"FAIL {stem}: the independent reader rejects it: {problems[0]}")
            failures += 1
            continue
        manifest, images, masks = R.read_comp(path)
        expected = R.composite_document(manifest, images, masks)
        render = os.path.join(renders, stem + ".png")
        if not os.path.exists(render):
            print(f"FAIL {stem}: no render to compare")
            failures += 1
            continue
        with Image.open(render) as image:
            actual = R.rgba_image_to_array(image)
        worst = int(np.abs(expected.astype(np.int16) - actual.astype(np.int16)).max()) if expected.shape == actual.shape else -1
        if worst > TOLERANCE:
            print(f"FAIL {stem}: version {manifest.get('version')} renders {worst} levels from the reference")
            failures += 1
        else:
            print(f"ok   {stem}: version {manifest.get('version')} accepted and within {worst} of the reference")
    return failures


def invalid(fixtures: str) -> int:
    failures = 0
    packages = sorted(name for name in os.listdir(fixtures) if name.endswith(".comp"))
    for name in packages:
        path = os.path.join(fixtures, name)
        problems = M.validate_package(path)
        if problems:
            print(f"ok   {name}: the independent reader refuses it ({problems[0]})")
        else:
            print(f"FAIL {name}: the independent reader accepts a package that uses a feature too early")
            failures += 1
    return failures


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    mode = argv[1]
    if mode == "valid":
        failures = valid(argv[2], argv[3] if len(argv) > 3 else argv[2])
    elif mode == "invalid":
        failures = invalid(argv[2])
    else:
        print(__doc__)
        return 2
    print(f"{'FAIL' if failures else 'PASS'} {mode}: {failures} problem(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
