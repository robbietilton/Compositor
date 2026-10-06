"""Builds the oracle's fixtures: .comp packages plus the PNG the oracle says each must render to.

Run:  python make_fixtures.py            (writes fixtures/ and fixtures/index.json)
      python make_fixtures.py --only NAME  (one fixture, for debugging)

Every adjustment kind gets an identity (or minimum) case and a representative case; the six
layer effects get a no-blur case and a blurred case. The base image is a chart: a red/green
gradient crossed by a blue diagonal, eight saturated blocks, and black/white probes, so
boundaries and hue families are all present in one 64x48 canvas.
"""

from __future__ import annotations

import argparse
import json
import os
import sys

import numpy as np

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from oracle_adjust import (  # noqa: E402
    apply_add_noise,
    apply_black_white,
    apply_color_balance,
    apply_curves,
    apply_exposure,
    apply_gaussian_blur,
    apply_gradient_map,
    apply_grain,
    apply_hsv,
    apply_hsv_direct,
    apply_invert,
    apply_levels,
    apply_levels_gpu,
    apply_motion_blur,
    gradient_map_table,
)
from oracle_comp import new_uuid, write_package  # noqa: E402
from oracle_core import premul_to_straight, straight_to_premul  # noqa: E402
from oracle_effects import composite_over, render_effects  # noqa: E402

WIDTH, HEIGHT = 64, 48
ROOT = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(ROOT, "fixtures-oracle")
EXPECTED = os.path.join(FIXTURES, "expected")

IDENTITY_LEVELS = {
    "channel": "RGB",
    "ranges": [{"black": 0, "gamma": 1, "white": 255, "outputBlack": 0, "outputWhite": 255}
               for _ in range(4)],
}
IDENTITY_CURVES = {
    "channel": "RGB",
    "channels": [[{"x": 0, "y": 0}, {"x": 255, "y": 255}] for _ in range(4)],
}


def base_chart() -> np.ndarray:
    """A 64x48 opaque chart with gradients, saturated blocks and boundary probes."""
    height, width = HEIGHT, WIDTH
    xs = np.arange(width, dtype=np.int64)
    ys = np.arange(height, dtype=np.int64)
    chart = np.zeros((height, width, 3), dtype=np.int64)
    chart[..., 0] = xs * 4
    chart[..., 1] = (ys * 5)[:, None]
    chart[..., 2] = ((xs[None, :] + 3 * ys[:, None]) % 64) * 4
    palette = [(255, 0, 0), (255, 255, 0), (0, 255, 0), (0, 255, 255),
               (0, 0, 255), (255, 0, 255), (255, 255, 255), (128, 128, 128)]
    for index, color in enumerate(palette):
        chart[0:8, index * 4:(index + 1) * 4] = color
    chart[height - 1, width - 1] = (255, 255, 255)
    chart[height - 1, 0] = (0, 0, 0)
    chart[0, width - 1] = (255, 255, 255)
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[..., :3] = np.clip(chart, 0, 255)
    rgba[..., 3] = 255
    return rgba


def alpha_chart() -> np.ndarray:
    """The chart with a horizontal alpha ramp: 0 at the left edge, 255 at the right."""
    rgba = base_chart()
    ramp = np.round(np.arange(WIDTH, dtype=np.float64) * 255.0 / (WIDTH - 1)).astype(np.uint8)
    rgba[..., 3] = ramp[None, :]
    return rgba


def shape_layer() -> np.ndarray:
    """A 16x12 white opaque block with a bite out of one corner: asymmetric in both axes, so a
    flipped or shifted effect shows up, and white so any coverage interpretation is the same."""
    height, width = 12, 16
    rgba = np.zeros((height, width, 4), dtype=np.uint8)
    rgba[..., :3] = 255
    rgba[:, :, 3] = 255
    rgba[0:4, 0:6] = 0
    return rgba


def clip8(value) -> int:
    return int(min(255, max(0, round(value))))


def adjustment(kind, **fields):
    record = {
        "kind": kind,
        "hue": 0.0,
        "saturation": 0.0,
        "lightness": 0.0,
        "colorize": False,
        "levels": IDENTITY_LEVELS,
        "curves": IDENTITY_CURVES,
    }
    record.update(fields)
    return record


def level_range(black=0, gamma=1, white=255, output_black=0, output_white=255):
    return {"black": black, "gamma": gamma, "white": white,
            "outputBlack": output_black, "outputWhite": output_white}


def fixture_specs():
    """Every fixture: name, the adjustment/effects record, and the oracle that predicts its pixels."""
    specs = []

    def add_adjustment(name, adjustment_record, predict, note, klass="exact", tolerance=1,
                       variants=None):
        specs.append({
            "name": name,
            "group": "adjustment",
            "kind": adjustment_record["kind"],
            "adjustment": adjustment_record,
            "predict": predict,
            "note": note,
            "class": klass,
            "tolerance": tolerance,
            "variants": variants or [],
        })

    # ---- Hue/Saturation -------------------------------------------------------------------
    add_adjustment("hsv-identity", adjustment("Hue/Saturation"),
                   lambda base: apply_hsv(straight_to_premul(base)),
                   "identity: no range adjustment, so the layer must not change a pixel")
    add_adjustment("hsv-master", adjustment("Hue/Saturation", hue=40.0, saturation=60.0, lightness=-10.0),
                   lambda base: apply_hsv(straight_to_premul(base), hue=40.0, saturation=60.0, lightness=-10.0),
                   "master range: +40 degrees, +60 saturation, -10 lightness",
                   variants=["hsv-direct"])
    add_adjustment("hsv-reds", adjustment("Hue/Saturation", hsvSettings={
        "range": "Reds", "colorize": False, "invertRange": False,
        "adjustments": {"Reds": {"hue": 60.0, "saturation": -40.0, "lightness": 20.0}},
        "bands": {"Reds": {"falloffStart": 315.0, "rangeStart": 345.0, "rangeEnd": 15.0, "falloffEnd": 45.0}},
    }), lambda base: apply_hsv(straight_to_premul(base), adjustments={"Reds": (60.0, -40.0, 20.0)}),
        "targeted Reds range through hsvSettings; schema probe for the optional settings block",
        variants=["hsv-direct"])

    # ---- Levels ---------------------------------------------------------------------------
    add_adjustment("levels-identity", adjustment("Levels", levels=IDENTITY_LEVELS),
                   lambda base: base.copy(),
                   "identity ranges: the macOS filter returns the image untouched")
    levels_work = {"channel": "RGB", "ranges": [
        level_range(20, 1.4, 230, 10, 245),
        level_range(5, 0.8, 250),
        level_range(0, 1.0, 255),
        level_range(0, 1.15, 240, 0, 250),
    ]}
    add_adjustment("levels-work", adjustment("Levels", levels=levels_work),
                   lambda base: apply_levels(straight_to_premul(base), levels_work["ranges"]),
                   "composite range 20/1.4/230 with per-channel ranges on top",
                   variants=["levels-gpu1024"])
    add_adjustment("levels-clip", adjustment("Levels", levels={"channel": "RGB", "ranges": [
        level_range(0, 1.0, 255, 200, 255),
        level_range(0, 1.0, 255, 100, 200),
        level_range(0, 1.0, 255),
        level_range(0, 1.0, 255),
    ]}), lambda base: apply_levels(straight_to_premul(base), [
        level_range(0, 1.0, 255, 200, 255),
        level_range(0, 1.0, 255, 100, 200),
        level_range(0, 1.0, 255),
        level_range(0, 1.0, 255),
    ]), "output ranges only: compresses the tonal range without moving the black point")

    # ---- Curves ---------------------------------------------------------------------------
    add_adjustment("curves-identity", adjustment("Curves", curves=IDENTITY_CURVES),
                   lambda base: base.copy(), "two-point curves are the identity")
    curves_work = {"channel": "RGB", "channels": [
        [{"x": 0, "y": 0}, {"x": 64, "y": 84}, {"x": 160, "y": 188}, {"x": 255, "y": 255}],
        [{"x": 0, "y": 12}, {"x": 128, "y": 140}, {"x": 255, "y": 248}],
        [{"x": 0, "y": 0}, {"x": 100, "y": 78}, {"x": 255, "y": 255}],
        [{"x": 0, "y": 0}, {"x": 255, "y": 255}],
    ]}
    add_adjustment("curves-s", adjustment("Curves", curves=curves_work),
                   lambda base: apply_curves(straight_to_premul(base), curves_work["channels"]),
                   "contrast S-curve on RGB plus separate red and green curves")

    # ---- Exposure -------------------------------------------------------------------------
    add_adjustment("exposure-identity", adjustment("Exposure", exposureSettings={
        "exposure": 0.0, "offset": 0.0, "gamma": 1.0}),
        lambda base: base.copy(), "zero stops, no offset, gamma 1: the table is the identity")
    add_adjustment("exposure-up", adjustment("Exposure", exposureSettings={
        "exposure": 0.8, "offset": 0.05, "gamma": 1.2}),
        lambda base: apply_exposure(straight_to_premul(base), 0.8, 0.05, 1.2),
        "0.8 stops of linear light, +0.05 offset, gamma 1.2",
        variants=["exposure-cube33"])

    # ---- Gradient Map ---------------------------------------------------------------------
    add_adjustment("gradientmap-default", adjustment("Gradient Map", gradientMapSettings={
        "shadows": {"red": 0.0, "green": 0.0, "blue": 0.0},
        "highlights": {"red": 1.0, "green": 1.0, "blue": 1.0}, "reversed": False}),
        lambda base: apply_gradient_map(straight_to_premul(base), gradient_map_table((0, 0, 0), (1, 1, 1))),
        "default black-to-white ramp: luminance picks the gray",
        variants=["gradientmap-cube33"])
    add_adjustment("gradientmap-duotone", adjustment("Gradient Map", gradientMapSettings={
        "shadows": {"red": 0.12, "green": 0.04, "blue": 0.35},
        "highlights": {"red": 1.0, "green": 0.82, "blue": 0.35}, "reversed": True}),
        lambda base: apply_gradient_map(straight_to_premul(base),
                                        gradient_map_table((0.12, 0.04, 0.35), (1.0, 0.82, 0.35), reversed_ends=True)),
        "duotone with reversed ends",
        variants=["gradientmap-cube33"])

    add_adjustment("gradientmap-reversed-bw", adjustment("Gradient Map", gradientMapSettings={
        "shadows": {"red": 0.0, "green": 0.0, "blue": 0.0},
        "highlights": {"red": 1.0, "green": 1.0, "blue": 1.0}, "reversed": True}),
        lambda base: apply_gradient_map(straight_to_premul(base),
                                        gradient_map_table((0, 0, 0), (1, 1, 1), reversed_ends=True)),
        "the same black-to-white ramp with reversed ends: probes whether the flag is read",
        variants=["gradientmap-cube33"])
    add_adjustment("gradientmap-warm-end", adjustment("Gradient Map", gradientMapSettings={
        "shadows": {"red": 0.0, "green": 0.0, "blue": 0.0},
        "highlights": {"red": 1.0, "green": 0.5, "blue": 0.0}, "reversed": False}),
        lambda base: apply_gradient_map(straight_to_premul(base),
                                        gradient_map_table((0, 0, 0), (1.0, 0.5, 0.0))),
        "black to orange: probes whether the highlight color is read at all",
        variants=["gradientmap-cube33"])

    # ---- Grain ----------------------------------------------------------------------------
    add_adjustment("grain-default", adjustment("Grain", grainSettings={
        "amount": 25.0, "size": 1.5, "roughness": 50.0, "seed": 12345}),
        lambda base: apply_grain(straight_to_premul(base), 25.0, 1.5, 50.0, 12345),
        "default grain at seed 12345")
    add_adjustment("grain-coarse", adjustment("Grain", grainSettings={
        "amount": 70.0, "size": 6.0, "roughness": 0.0, "seed": 777}),
        lambda base: apply_grain(straight_to_premul(base), 70.0, 6.0, 0.0, 777),
        "strong, coarse, smooth grain: roughness 0 leaves the broad lattice alone")

    # ---- Add Noise ------------------------------------------------------------------------
    add_adjustment("addnoise-uniform", adjustment("Add Noise", noiseAmount=30.0,
                                                  noiseGaussian=False, noiseMonochromatic=False,
                                                  noiseSeed=4242),
                   lambda base: apply_add_noise(straight_to_premul(base), 30.0, False, False, 4242),
                   "uniform independent noise on each channel")
    add_adjustment("addnoise-gaussian-mono", adjustment("Add Noise", noiseAmount=20.0,
                                                        noiseGaussian=True, noiseMonochromatic=True,
                                                        noiseSeed=99),
                   lambda base: apply_add_noise(straight_to_premul(base), 20.0, True, True, 99),
                   "Gaussian noise, one value for all three channels")

    # ---- Gaussian Blur --------------------------------------------------------------------
    add_adjustment("gaussianblur-min", adjustment("Gaussian Blur", blurRadius=0.1),
                   lambda base: apply_gaussian_blur(straight_to_premul(base), 0.1),
                   "minimum radius: sigma 0.1, effectively the identity",
                   klass="kernel", tolerance=1)
    add_adjustment("gaussianblur-medium", adjustment("Gaussian Blur", blurRadius=4.0),
                   lambda base: apply_gaussian_blur(straight_to_premul(base), 4.0),
                   "sigma 4 at 1:1; Core Image blurs past the edges into transparent black",
                   klass="kernel", tolerance=6,
                   variants=["gaussian-clamped"])

    # ---- Motion Blur ----------------------------------------------------------------------
    add_adjustment("motionblur-min", adjustment("Motion Blur", motionAngle=0.0, motionDistance=1.0),
                   lambda base: apply_motion_blur(straight_to_premul(base), 1.0, 0.0),
                   "one pixel of streak: effectively the identity",
                   klass="kernel", tolerance=1)
    add_adjustment("motionblur-30deg", adjustment("Motion Blur", motionAngle=30.0, motionDistance=9.0),
                   lambda base: apply_motion_blur(straight_to_premul(base), 9.0, 30.0),
                   "9-pixel streak at +30 degrees; the sign of the angle is checked against both",
                   klass="kernel", tolerance=32,
                   variants=["motion-plus30", "motion-minus30"])

    # ---- Invert ---------------------------------------------------------------------------
    add_adjustment("invert-chart", adjustment("Invert"),
                   lambda base: apply_invert(straight_to_premul(base)),
                   "every color becomes alpha minus color, alpha 255 everywhere")
    add_adjustment("invert-alpha", adjustment("Invert"),
                   lambda base: apply_invert(straight_to_premul(base)),
                   "invert on a canvas with partial alpha: the premultiplied path",
                   klass="alpha", tolerance=2)
    specs[-1]["base"] = "alpha"

    # ---- Black & White --------------------------------------------------------------------
    add_adjustment("blackwhite-default", adjustment("Black & White", blackWhiteSettings={
        "reds": 40.0, "yellows": 60.0, "greens": 40.0, "cyans": 60.0, "blues": 20.0,
        "magentas": 80.0, "tint": False, "tintHue": 40.0, "tintSaturation": 20.0}),
        lambda base: apply_black_white(straight_to_premul(base)),
        "Photoshop's default family weights", variants=["blackwhite-cube33"])
    add_adjustment("blackwhite-tinted", adjustment("Black & White", blackWhiteSettings={
        "reds": 80.0, "yellows": 10.0, "greens": 90.0, "cyans": 20.0, "blues": 0.0,
        "magentas": 60.0, "tint": True, "tintHue": 40.0, "tintSaturation": 60.0}),
        lambda base: apply_black_white(straight_to_premul(base), (80, 10, 90, 20, 0, 60), True, 40.0, 60.0),
        "sepia tint at hue 40, saturation 60, with strong reds and greens",
        variants=["blackwhite-cube33"])

    # ---- Color Balance --------------------------------------------------------------------
    add_adjustment("colorbalance-identity", adjustment("Color Balance", colorBalanceSettings={
        "shadowCyanRed": 0.0, "shadowMagentaGreen": 0.0, "shadowYellowBlue": 0.0,
        "midCyanRed": 0.0, "midMagentaGreen": 0.0, "midYellowBlue": 0.0,
        "highlightCyanRed": 0.0, "highlightMagentaGreen": 0.0, "highlightYellowBlue": 0.0,
        "preserveLuminosity": True}),
        lambda base: base.copy(), "all three wheels at zero: the macOS filter returns the image")
    balance_work = {"shadowCyanRed": 25.0, "shadowMagentaGreen": -15.0, "shadowYellowBlue": 0.0,
                    "midCyanRed": 10.0, "midMagentaGreen": 8.0, "midYellowBlue": -20.0,
                    "highlightCyanRed": 0.0, "highlightMagentaGreen": 0.0, "highlightYellowBlue": 30.0,
                    "preserveLuminosity": True}
    add_adjustment("colorbalance-warm", adjustment("Color Balance", colorBalanceSettings=balance_work),
                   lambda base: apply_color_balance(straight_to_premul(base), (25, -15, 0), (10, 8, -20), (0, 0, 30), True),
                   "warm shadows and midtones, cooler highlights, luminosity preserved",
                   variants=["blackwhite-cube33"])
    balance_flat = dict(balance_work, preserveLuminosity=False)
    add_adjustment("colorbalance-noluminosity", adjustment("Color Balance", colorBalanceSettings=balance_flat),
                   lambda base: apply_color_balance(straight_to_premul(base), (25, -15, 0), (10, 8, -20), (0, 0, 30), False),
                   "the same shift without preserve luminosity, so brightness moves too")

    # ---- Controls -------------------------------------------------------------------------
    specs.append({"name": "control-base", "group": "control", "kind": "none",
                  "predict": lambda base: base.copy(), "variants": [],
                  "note": "the chart with no adjustment layer: proves the base renders exactly",
                  "class": "exact", "tolerance": 0})
    specs.append({"name": "control-identity-normal", "group": "control", "kind": "Levels",
                  "adjustment": adjustment("Levels", levels=IDENTITY_LEVELS),
                  "predict": lambda base: base.copy(), "variants": [],
                  "note": "an identity adjustment layer above the chart must leave it alone",
                  "class": "exact", "tolerance": 0})

    # ---- Layer effects --------------------------------------------------------------------
    def add_effect(name, effects, note, klass, tolerance, variants=None):
        specs.append({"name": name, "group": "effect", "kind": "effects",
                      "effects": effects, "predict": None, "note": note,
                      "class": klass, "tolerance": tolerance, "variants": variants or []})

    add_effect("effect-coloroverlay", {"colorOverlay": {"red": 0.9, "green": 0.2, "blue": 0.1, "opacity": 0.6}},
               "flat color through the shape at 60%: no blur anywhere, so formula-exact", "exact", 1)
    add_effect("effect-stroke-outside", {"stroke": {"size": 3.0, "red": 0.0, "green": 0.35, "blue": 0.9,
                                                    "opacity": 0.8, "inside": False}},
               "outside stroke, 3 pixels of square dilation: formula-exact", "exact", 1)
    add_effect("effect-stroke-inside", {"stroke": {"size": 3.0, "red": 1.0, "green": 0.6, "blue": 0.0,
                                                   "opacity": 1.0, "inside": True}},
               "inside stroke, 3 pixels of square erosion: formula-exact", "exact", 1)
    add_effect("effect-shadow-hard", {"shadow": {"angle": 90.0, "distance": 6.0, "blur": 0.0,
                                                 "red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.7}},
               "drop shadow straight down 6 pixels with no blur: only the offset and the fill", "exact", 1)
    add_effect("effect-shadow-ang180", {"shadow": {"angle": 180.0, "distance": 5.0, "blur": 0.0,
                                                   "red": 0.2, "green": 0.1, "blue": 0.0, "opacity": 0.5}},
               "shadow at 180 degrees moves right with no blur: the horizontal offset and its sign",
               "exact", 1)
    add_effect("effect-shadow-blur", {"shadow": {"angle": 90.0, "distance": 4.0, "blur": 6.0,
                                                 "red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.6}},
               "blurred drop shadow: sigma 3, so a different kernel shows as a soft difference",
               "kernel", 40)
    add_effect("effect-outerglow", {"outerGlow": {"size": 6.0, "red": 1.0, "green": 0.9, "blue": 0.2,
                                                  "opacity": 0.8}},
               "outer glow, sigma 3 all round minus the shape", "kernel", 40)
    add_effect("effect-innerglow", {"innerGlow": {"size": 5.0, "red": 0.2, "green": 0.8, "blue": 1.0,
                                                  "opacity": 0.9}},
               "inner glow: the shape less its own softening, all inside the shape", "kernel", 40)
    add_effect("effect-innershadow", {"innerShadow": {"angle": 90.0, "distance": 4.0, "blur": 4.0,
                                                      "red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.7}},
               "inner shadow in from the top edge, sigma 2", "kernel", 40)
    add_effect("effect-stack", {"shadow": {"angle": 90.0, "distance": 4.0, "blur": 4.0,
                                           "red": 0.0, "green": 0.0, "blue": 0.0, "opacity": 0.6},
                                "colorOverlay": {"red": 0.1, "green": 0.1, "blue": 0.6, "opacity": 0.5},
                                "stroke": {"size": 2.0, "red": 1.0, "green": 1.0, "blue": 0.0,
                                           "opacity": 1.0, "inside": False}},
               "shadow, overlay and outside stroke together: checks the stacking order",
               "kernel", 40)
    return specs


SHAPE_ORIGIN = (24, 18)


def build(spec, base):
    """Writes one package and returns the record written to index.json."""
    name = spec["name"]
    package = os.path.join(FIXTURES, name + ".comp")
    expected = None

    if spec["group"] == "effect":
        layer = shape_layer()
        canvas, inset = render_effects(layer, spec["effects"])
        document = composite_over(base, canvas, (SHAPE_ORIGIN[0] - inset, SHAPE_ORIGIN[1] - inset))
        layers = [
            {"name": "Chart", "rgba": base},
            {"name": "Shape", "rgba": layer, "effects": spec["effects"], "transform": {
                "origin": [float(SHAPE_ORIGIN[0]), float(SHAPE_ORIGIN[1])],
                "size": [float(layer.shape[1]), float(layer.shape[0])],
                "rotation": 0.0, "flipX": False, "flipY": False, "sampling": "Nearest"}},
        ]
        expected = document
        extra = {"inset": inset, "origin": list(SHAPE_ORIGIN)}
    elif spec["group"] == "control" and "adjustment" not in spec:
        layers = [{"name": "Chart", "rgba": base}]
        expected = base.copy()
        extra = {}
    else:
        canvas = straight_to_premul(base)
        result = spec["predict"](base)
        expected = premul_to_straight(result) if result.shape == base.shape else result
        record_layers = [{"name": "Chart", "rgba": base}]
        if "adjustment" in spec:
            record_layers.append({"name": spec["kind"], "adjustment": spec["adjustment"]})
        layers = record_layers
        extra = {}

    if expected is None:
        expected = spec["predict"](base)
    write_package(package, WIDTH, HEIGHT, layers)
    expected_path = os.path.join(EXPECTED, name + ".png")
    from PIL import Image
    Image.fromarray(expected.astype("uint8"), mode="RGBA").save(expected_path)

    digest = {"name": name, "group": spec["group"], "kind": spec["kind"], "base": spec.get("base", "chart"),
              "variants": spec.get("variants", []),
              "class": spec["class"], "tolerance": spec["tolerance"], "note": spec["note"],
              "package": name + ".comp", "expected": "expected/" + name + ".png"}
    digest.update(extra)
    if "adjustment" in spec:
        digest["adjustment"] = spec["adjustment"]
    if "effects" in spec:
        digest["effects"] = spec["effects"]
    return digest


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--only", default=None)
    arguments = parser.parse_args()

    os.makedirs(EXPECTED, exist_ok=True)
    specs = fixture_specs()
    if arguments.only:
        specs = [spec for spec in specs if spec["name"] == arguments.only]
        if not specs:
            raise SystemExit("no fixture named " + arguments.only)

    index = []
    for spec in specs:
        record = build(spec, alpha_chart() if spec.get("base") == "alpha" else base_chart())
        index.append(record)
        print("built " + record["name"])

    if not arguments.only:
        with open(os.path.join(FIXTURES, "index.json"), "w", encoding="utf-8") as handle:
            json.dump({"canvas": [WIDTH, HEIGHT], "fixtures": index}, handle, indent=2)
        print("wrote %d fixtures" % len(index))


if __name__ == "__main__":
    main()
