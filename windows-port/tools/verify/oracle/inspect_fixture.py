r"""One fixture under the microscope, or the synthetic probes that isolate an effect finding.

    python inspect_fixture.py adjust-levels-rgb        # render, compare, print evidence
    python inspect_fixture.py fx-outer-glow-wide
    python inspect_fixture.py --probe-effects          # the margin, rounding and direction probes

compare.py answers "do they agree"; this answers "where exactly do they differ", which is what a
fix needs. Every probe writes its packages and PNGs to the system temp directory.
"""
from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import packages as P
import upstream as U

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
COMPC = os.environ.get("COMPC", r"E:\Compositor-main\compositor_win\target-lead\debug\compc.exe")


def load(path: str) -> np.ndarray:
    with Image.open(path) as image:
        return np.array(image.convert("RGBA")).astype(np.int64)


def render(compc: str, package: str, target: str) -> np.ndarray:
    subprocess.run([compc, "render", package, "-o", target], check=True, capture_output=True)
    return load(target)


def runs(values, predicate):
    """Runs of consecutive indices a predicate holds for."""
    found, start = [], None
    for index, value in enumerate(values):
        if predicate(value) and start is None:
            start = index
        elif not predicate(value) and start is not None:
            found.append((start, index - 1))
            start = None
    if start is not None:
        found.append((start, len(values) - 1))
    return found


def show(image, label, backdrop):
    """A coarse map: S shape white, R ring black, . backdrop, o anything else."""
    print(f"   {label}")
    for y in range(0, image.shape[0], 2):
        row = ""
        for x in range(0, image.shape[1], 2):
            pixel = image[y, x]
            if (pixel[:3] == 255).all() and pixel[3] == 255:
                row += "S"
            elif (pixel[:3] == 0).all() and pixel[3] == 255:
                row += "R"
            elif np.array_equal(pixel, backdrop[y, x]):
                row += "."
            else:
                row += "o"
        print("     " + row)


def inspect(compc: str, name: str) -> int:
    with open(os.path.join(FIXTURES, "index.json"), "r", encoding="utf-8") as handle:
        entries = {entry["name"]: entry for entry in json.load(handle)["fixtures"]}
    if name not in entries:
        print(f"unknown fixture {name!r}; try one of: {', '.join(sorted(entries)[:8])} ...", file=sys.stderr)
        return 2
    entry = entries[name]
    work = tempfile.mkdtemp(prefix="comp-oracle-inspect-")
    actual = render(compc, os.path.join(HERE, entry["package"]), os.path.join(work, name + ".png"))
    expected = load(os.path.join(FIXTURES, entry["expected"]))
    source = load(os.path.join(FIXTURES, "inputs", entry["input"] + ".png"))
    delta = np.abs(actual - expected)
    print(f"{name}: {entry['notes']}")
    print(f"  class {entry['class']}, kind {entry['kind']}, worst {int(delta.max())}, "
          f"mean {delta.mean():.4f}, pixels over 1: {int((delta.max(axis=-1) > 1).sum())} of {delta[..., 0].size}")
    if entry.get("settings"):
        print(f"  settings {json.dumps(entry['settings'])[:300]}")
    if entry.get("effects"):
        print(f"  effects {json.dumps(entry['effects'])[:300]}")
        print(f"  upstream margin {U.effect_margin(entry['effects'])}")
    flat = np.argsort(delta.max(axis=-1), axis=None)[::-1][:5]
    for index in flat:
        y, x = divmod(int(index), delta.shape[1])
        print(f"  ({x:2d},{y:2d}) input {source[y, x].tolist()} expected {expected[y, x].tolist()} "
              f"actual {actual[y, x].tolist()}")
    backdrop = source if entry["class"] != "effect" else load(os.path.join(FIXTURES, "inputs", "backdrop.png"))
    show(expected, "expected (S = white, R = black, . = input)", backdrop)
    show(actual, "actual", backdrop)
    if entry["class"] == "effect":
        print("  measured coverage, actual versus expected (non-backdrop pixels):")
        for label, image in (("actual", actual), ("expected", expected)):
            mask = (np.abs(image - backdrop).max(axis=-1) > 0)
            if mask.any():
                ys, xs = np.where(mask)
                print(f"    {label}: x {xs.min()}..{xs.max()} y {ys.min()}..{ys.max()} pixels {int(mask.sum())}")
    print(f"  rendered PNG kept at {os.path.join(work, name + '.png')}")
    return 0


def probe_effects(compc: str) -> int:
    """Three probes that separate the effect findings compare.py reports."""
    work = tempfile.mkdtemp(prefix="comp-oracle-probe-")
    backdrop = load(os.path.join(FIXTURES, "inputs", "backdrop.png"))
    shape = P.shape_image()
    P.save_png(shape, os.path.join(work, "shape.png"))
    shape_array = P.load_png(os.path.join(work, "shape.png"))

    def package(name, effects):
        path = os.path.join(work, name + ".comp")
        P.write_package(path, [
            {"name": "Backdrop", "image": Image.fromarray(backdrop.astype(np.uint8), mode="RGBA")},
            {"name": "Shape", "image": shape, "effects": effects, "transform": P.full_transform()},
        ])
        return render(compc, path, os.path.join(work, name + ".png"))

    plain = package("probe-plain", {})

    print("Probe 1: does the effect surface's margin move the layer?")
    print("  A color overlay with a forced margin: upstream keeps the shape where it is.")
    for distance in (0.0, 4.0, 20.0, 60.0):
        effects = {"colorOverlay": {"opacity": 1.0, "red": 1.0, "green": 0.0, "blue": 1.0},
                   "shadow": {"distance": distance, "blur": 0.0, "opacity": 0.0}}
        actual = package(f"probe-overlay-{int(distance)}", effects)
        magenta = lambda pixel: (pixel[:3] == np.array([255, 0, 255])).all()
        print(f"    margin {U.effect_margin(effects):3d}: overlay columns on row 24 "
              f"{runs(actual[24], magenta)} (upstream 10..53, hole 26..37 on rows 20..27)")

    print("Probe 2: where does a drop shadow at angle 120 land?")
    print("  macOS offset (-cos120, sin120) * distance = right and down.")
    actual = package("probe-shadow", {"shadow": {"angle": 120.0, "distance": 8.0, "blur": 0.0,
                                                 "opacity": 1.0}})
    darkened = (actual[..., :3].sum(-1) + 30 < plain[..., :3].sum(-1))
    ys, xs = np.where(darkened)
    if len(xs):
        print(f"    darkened x {xs.min()}..{xs.max()} y {ys.min()}..{ys.max()}: "
              f"left of the shape {int((xs < 10).sum())}, right {int((xs > 53).sum())}, "
              f"above {int((ys < 8).sum())}, below {int((ys > 39).sum())}")

    print("Probe 3: a fractional effect offset at the smallest possible margin.")
    print("  Inner shadow, angle 45, distance 6: the macOS offset is (-4.243, +4.243).")
    actual = package("probe-inner", {"innerShadow": {"angle": 45.0, "distance": 6.0, "blur": 0.0,
                                                     "opacity": 1.0}})
    actual_mask = (actual[..., :3].sum(-1) + 30 < plain[..., :3].sum(-1))
    alpha = shape_array[..., 3].astype(float) / 255.0
    for dx, dy in [(-4, 4), (-5, 4), (-5, 5)]:
        shape_levels = U.coverage_levels(alpha, (0, 0), (64, 48), 0.0)
        moved = U.coverage_levels(alpha, (dx, dy), (64, 48), 0.0)
        candidate = np.clip(shape_levels * (1.0 - moved), 0.0, 1.0) > 0.5
        print(f"    offset ({dx},{dy}): only actual {int((actual_mask & ~candidate).sum())}, "
              f"only oracle {int((candidate & ~actual_mask).sum())}")
    print(f"  probes kept in {work}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description="Inspect one fixture or run the effect probes")
    parser.add_argument("fixture", nargs="?", help="fixture name from fixtures/index.json")
    parser.add_argument("--compc", default=COMPC)
    parser.add_argument("--probe-effects", action="store_true")
    args = parser.parse_args()
    if not os.path.exists(args.compc if False else args.compс):
        pass
    if not os.path.exists(args.compc):
        print(f"compc not found at {args.compc}", file=sys.stderr)
        return 2
    if args.probe_effects:
        return probe_effects(args.compc)
    if not args.fixture:
        parser.error("give a fixture name or --probe-effects")
    return inspect(args.compc, args.fixture)


if __name__ == "__main__":
    sys.exit(main())
