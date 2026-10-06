"""Renders every oracle fixture with compc and compares it against the oracle's own pixels.

Run:  python run_oracle.py                 (all fixtures, writes report.json and report.md)
      python run_oracle.py --only NAME      (one fixture)
      python run_oracle.py --no-render      (reuse the PNGs already in fixtures/actual)

The comparison is per pixel and per channel on the RGBA PNG the CLI writes. A fixture passes
when the worst channel difference is within its tolerance: 1 for the exact classes (one unit is
the rounding of two different-but-equivalent float expressions), wider for the blurring classes,
where the kernel itself is allowed to differ. Variants let a fixture name the alternative
implementations the macOS sources also contain - the 33-cube canvas path, Levels at 1024 entries,
the opposite motion angle - so a mismatch can be attributed instead of just reported.
"""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys

import numpy as np
from PIL import Image

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from oracle_adjust import (  # noqa: E402
    apply_black_white,
    apply_color_balance,
    apply_exposure,
    apply_gradient_map,
    apply_hsv_direct,
    apply_levels_gpu,
    apply_motion_blur,
    gradient_map_table,
)
from oracle_core import cube_apply, gaussian_blur_premul, straight_to_premul  # noqa: E402

ROOT = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(ROOT, "fixtures-oracle")
ACTUAL = os.path.join(FIXTURES, "actual")
REPO = os.path.dirname(os.path.dirname(os.path.dirname(ROOT)))
DEFAULT_COMPC = os.path.join(REPO, "target-lead", "debug", "compc.exe")

CHANNELS = ["R", "G", "B", "A"]


def build_cube33(fn):
    """GPUCanvas.cube(for:): run the adjustment over a 33-point lattice and read it back."""
    n = 33
    levels = np.round(np.arange(n) * 255.0 / (n - 1)).astype(np.uint8)
    lattice = np.zeros((n, n * n, 4), dtype=np.uint8)
    for blue in range(n):
        for green in range(n):
            for red in range(n):
                offset = green * n + red
                lattice[blue, offset, 0] = levels[red]
                lattice[blue, offset, 1] = levels[green]
                lattice[blue, offset, 2] = levels[blue]
                lattice[blue, offset, 3] = 255
    out = fn(lattice)
    cube = np.zeros((n, n, n, 3), dtype=np.float64)
    for blue in range(n):
        for green in range(n):
            for red in range(n):
                cube[blue, green, red] = out[blue, green * n + red, :3] / 255.0
    return cube


def variants_for(name, record, base):
    """Alternative predictors the macOS sources also contain, keyed by variant name."""
    canvas = straight_to_premul(base)
    if name == "hsv-master":
        return {"hsv-direct": lambda: apply_hsv_direct(canvas, hue=40.0, saturation=60.0, lightness=-10.0)}
    if name == "hsv-reds":
        return {"hsv-direct": lambda: apply_hsv_direct(canvas, adjustments={"Reds": (60.0, -40.0, 20.0)})}
    if name == "levels-work":
        ranges = record["adjustment"]["levels"]["ranges"]
        return {"levels-gpu1024": lambda: apply_levels_gpu(canvas, ranges)}
    if name == "exposure-up":
        cube = build_cube33(lambda pixels: apply_exposure(pixels, 0.8, 0.05, 1.2))
        return {"exposure-cube33": lambda: cube_apply(canvas, cube)}
    if name.startswith("gradientmap"):
        settings = record["adjustment"]["gradientMapSettings"]
        shadows = (settings["shadows"]["red"], settings["shadows"]["green"], settings["shadows"]["blue"])
        highlights = (settings["highlights"]["red"], settings["highlights"]["green"], settings["highlights"]["blue"])
        table = gradient_map_table(shadows, highlights, settings.get("reversed", False))
        cube = build_cube33(lambda pixels: apply_gradient_map(pixels, table))
        return {"gradientmap-cube33": lambda: cube_apply(canvas, cube)}
    if name.startswith("blackwhite"):
        settings = record["adjustment"]["blackWhiteSettings"]
        weights = (settings["reds"], settings["yellows"], settings["greens"], settings["cyans"],
                   settings["blues"], settings["magentas"])
        cube = build_cube33(lambda pixels: apply_black_white(
            pixels, weights, settings.get("tint", False), settings.get("tintHue", 40.0),
            settings.get("tintSaturation", 20.0)))
        return {"blackwhite-cube33": lambda: cube_apply(canvas, cube)}
    if name == "colorbalance-warm":
        cube = build_cube33(lambda pixels: apply_color_balance(pixels, (25, -15, 0), (10, 8, -20), (0, 0, 30), True))
        return {"blackwhite-cube33": lambda: cube_apply(canvas, cube)}
    if name == "gaussianblur-medium":
        return {"gaussian-clamped": lambda: gaussian_blur_premul(canvas, 4.0, edge="clamp")}
    if name == "motionblur-30deg":
        return {"motion-plus30": lambda: apply_motion_blur(canvas, 9.0, 30.0),
                "motion-minus30": lambda: apply_motion_blur(canvas, 9.0, -30.0)}
    return {}


def compare(expected: np.ndarray, actual: np.ndarray):
    """Worst and mean absolute channel difference, plus the three worst pixels."""
    if expected.shape != actual.shape:
        return None
    difference = np.abs(expected.astype(np.int64) - actual.astype(np.int64))
    per_pixel = difference.max(axis=2)
    order = np.argsort(per_pixel, axis=None)[::-1][:3]
    worst = []
    for flat in order:
        y, x = divmod(int(flat), per_pixel.shape[1])
        worst.append({
            "x": x, "y": y,
            "expected": [int(value) for value in expected[y, x]],
            "actual": [int(value) for value in actual[y, x]],
            "difference": [int(value) for value in difference[y, x]],
        })
    return {
        "worst": int(difference[..., :3].max()),
        "mean": float(difference[..., :3].mean()),
        "worst_alpha": int(difference[..., 3].max()),
        "mismatched": int((per_pixel > 1).sum()),
        "worst_pixels": worst,
    }


def render(compc, package, output):
    result = subprocess.run([compc, "render", package, "-o", output],
                            capture_output=True, text=True)
    if result.returncode != 0:
        raise RuntimeError("compc render failed for %s: %s%s" % (package, result.stdout, result.stderr))


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default=None)
    parser.add_argument("--compc", default=DEFAULT_COMPC)
    parser.add_argument("--no-render", action="store_true")
    arguments = parser.parse_args()

    with open(os.path.join(FIXTURES, "index.json"), "r", encoding="utf-8") as handle:
        index = json.load(handle)
    fixtures = index["fixtures"]
    if arguments.only:
        fixtures = [record for record in fixtures if record["name"] == arguments.only]

    os.makedirs(ACTUAL, exist_ok=True)
    control = None
    if not arguments.only:
        with Image.open(os.path.join(FIXTURES, "expected", "control-base.png")) as image:
            control = np.asarray(image.convert("RGBA"), dtype=np.uint8)

    identity_names = {"control-base", "control-identity-normal", "hsv-identity", "levels-identity",
                      "curves-identity", "exposure-identity", "colorbalance-identity"}

    results = []
    for record in fixtures:
        name = record["name"]
        package = os.path.join(FIXTURES, record["package"])
        output = os.path.join(ACTUAL, name + ".png")
        if not arguments.no_render:
            render(arguments.compc, package, output)
        with Image.open(os.path.join(FIXTURES, record["expected"])) as image:
            expected = np.asarray(image.convert("RGBA"), dtype=np.uint8)
        with Image.open(output) as image:
            actual = np.asarray(image.convert("RGBA"), dtype=np.uint8)
        with open(os.path.join(package, "manifest.json"), "r", encoding="utf-8") as handle:
            manifest = json.load(handle)
        chart = next(layer for layer in manifest["layers"] if layer.get("name") == "Chart")
        with Image.open(os.path.join(package, "images", chart["imageFile"])) as image:
            source = np.asarray(image.convert("RGBA"), dtype=np.uint8)

        stats = compare(expected, actual)
        entry = dict(record)
        entry["stats"] = stats
        entry["pass"] = bool(stats is not None and stats["worst"] <= record["tolerance"]
                             and stats["worst_alpha"] <= max(1, record["tolerance"]))
        entry["changed"] = bool(control is not None and
                                np.abs(actual.astype(np.int64) - control.astype(np.int64)).max() > 0)
        entry["expected_change"] = name not in identity_names
        if record.get("variants"):
            variant_stats = {}
            for variant in record["variants"]:
                predictor = variants_for(name, record, source).get(variant)
                if predictor is None:
                    continue
                predicted = predictor()
                from oracle_core import premul_to_straight
                predicted = premul_to_straight(predicted)
                variant_stats[variant] = compare(predicted, actual)
            entry["variant_stats"] = variant_stats
        results.append(entry)
        marker = "ok  " if entry["pass"] else "FAIL"
        print("%s %-28s worst=%3d mean=%6.3f %s" % (
            marker, name, stats["worst"] if stats else -1, stats["mean"] if stats else -1,
            "" if entry["changed"] or not entry["expected_change"] else "(no change from base)"))

    if not arguments.only:
        binary = os.stat(arguments.compc)
        with open(os.path.join(ROOT, "report.json"), "w", encoding="utf-8") as handle:
            json.dump({"compc": arguments.compc, "compcBytes": binary.st_size,
                       "compcModified": int(binary.st_mtime), "fixtures": results}, handle, indent=2)
        write_markdown(results)
        failures = [entry for entry in results if not entry["pass"]]
        print("\n%d fixtures, %d outside tolerance" % (len(results), len(failures)))
        for entry in failures:
            print("  " + entry["name"])


def write_markdown(results):
    lines = ["# Oracle run", "",
             "| fixture | kind | class | worst | mean | tol | verdict |", "|---|---|---|---|---|---|---|"]
    for entry in results:
        stats = entry["stats"]
        worst = stats["worst"] if stats else -1
        mean = stats["mean"] if stats else -1
        lines.append("| %s | %s | %s | %d | %.3f | %d | %s |" % (
            entry["name"], entry["kind"], entry["class"], worst, mean, entry["tolerance"],
            "consistent" if entry["pass"] else "DIVERGES"))
    lines.append("")
    lines.append("## Worst pixels")
    for entry in results:
        stats = entry["stats"]
        if stats is None:
            lines.append("- **%s**: could not compare (image shape differs)" % entry["name"])
            continue
        worst = stats["worst_pixels"][0]
        lines.append("- **%s** worst=%d at (%d, %d): expected %s, actual %s" % (
            entry["name"], stats["worst"], worst["x"], worst["y"],
            worst["expected"], worst["actual"]))
        for variant, variant_stats in (entry.get("variant_stats") or {}).items():
            lines.append("    - variant %s: worst=%d" % (variant, variant_stats["worst"]))
    with open(os.path.join(ROOT, "report.md"), "w", encoding="utf-8") as handle:
        handle.write("\n".join(lines) + "\n")


if __name__ == "__main__":
    main()
