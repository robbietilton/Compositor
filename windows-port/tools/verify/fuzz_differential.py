"""Generates random documents and compares the engine against the independent compositor.

The forty fixtures are curated: a person chose each one to cover a rule. This goes the other way and
composes random documents out of the features the reference models -- blend modes, opacity, transforms,
masks, clipping chains, folders, visibility -- so combinations nobody thought to write down get tried.
A mismatch is either a bug in the engine or a hole in the reference, and both are worth knowing about.

Rotations are restricted to quarter turns: the reference has no analytic edge coverage for an arbitrary
angle (documented in PARITY.md), so a rotated layer's antialiased edge would report a difference that is
the reference's fault, not the engine's.

Usage:
  python fuzz_differential.py --cli <compc> --count 40 [--seed 1234] [--keep]
"""

from __future__ import annotations

import argparse
import os
import random
import shutil
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image

import comp_reference as R
import macos_interop as M

HERE = os.path.dirname(os.path.abspath(__file__))
FAILURES = os.path.join(HERE, "fuzz-failures")

BLEND_MODES = [
    "Normal", "Multiply", "Screen", "Overlay", "Darken", "Lighten", "Color Burn", "Color Dodge",
    "Linear Burn", "Linear Dodge (Add)", "Soft Light", "Hard Light", "Vivid Light", "Linear Light",
    "Pin Light", "Hard Mix", "Difference", "Exclusion", "Subtract", "Divide",
    "Hue", "Saturation", "Color", "Luminosity",
]
SAMPLING = ["Nearest", "Smooth", "High quality"]
ROTATIONS = [0.0, 90.0, 180.0, 270.0]


def numpy_from(rng):
    """The Python generator drives the choices; NumPy needs its own, seeded from the same stream."""
    return np.random.default_rng(rng.randrange(1 << 30))


def noise_image(width, height, rng):
    source = numpy_from(rng)
    array = np.zeros((height, width, 4))
    array[..., :3] = source.random((height, width, 3))
    array[..., 3] = source.choice([0.0, 0.35, 0.7, 1.0], size=(height, width), p=[0.1, 0.2, 0.3, 0.4])
    return R.array_to_rgba_image(array)


def gradient_mask(width, height, rng):
    source = numpy_from(rng)
    if rng.random() < 0.5:
        ramp = np.linspace(0.0, 1.0, width)[None, :]
        array = np.broadcast_to(ramp, (height, width))
    else:
        array = source.integers(0, 2, size=(height, width)).astype(float)
    return Image.fromarray((array * 255).astype(np.uint8), mode="L")


def random_transform(width, height, image, rng):
    """A transform the reference models exactly: quarter turns, simple scales, canvas-sized or smaller."""
    mode = rng.choice(["canvas", "canvas", "moved", "scaled", "turned", "shrunk"])
    if mode == "canvas":
        return {"origin": [0.0, 0.0], "size": [float(width), float(height)], "rotation": 0.0,
                "flipX": False, "flipY": False, "sampling": rng.choice(SAMPLING)}
    scale = {"moved": 1.0, "scaled": rng.choice([0.5, 2.0]), "turned": 1.0,
             "shrunk": rng.choice([0.75, 1.0])}[mode]
    size = [image.width * scale, image.height * scale]
    origin = [rng.uniform(-8.0, width * 0.5), rng.uniform(-8.0, height * 0.5)]
    rotation = rng.choice(ROTATIONS) if mode != "turned" else rng.choice([90.0, 180.0, 270.0])
    return {"origin": origin, "size": size, "rotation": rotation,
            "flipX": rng.random() < 0.3, "flipY": rng.random() < 0.3, "sampling": rng.choice(SAMPLING)}


def random_document(rng):
    width = rng.choice([32, 48, 64])
    height = rng.choice([24, 32, 48])
    layers = []
    count = rng.randint(2, 5)
    folder_id = None
    if rng.random() < 0.4:
        folder_id = R.new_uuid()
        layers.append({
            "id": folder_id, "name": "Group", "isGroup": True,
            "opacity": rng.choice([1.0, 0.5, 0.8]), "visible": rng.random() < 0.9,
            "transform": {"origin": [0.0, 0.0], "size": [float(width), float(height)], "rotation": 0.0,
                          "flipX": False, "flipY": False, "sampling": "High quality"},
            "mask": gradient_mask(width, height, rng) if rng.random() < 0.3 else None,
        })
    for index in range(count):
        image = noise_image(max(4, int(width * rng.choice([0.4, 1.0]))),
                            max(4, int(height * rng.choice([0.4, 1.0]))), rng)
        layer = {
            # An explicit id, because a clipping link has to name the layer it clips onto.
            "id": R.new_uuid(),
            "name": f"Layer {index}",
            "image": image,
            "opacity": rng.choice([1.0, 1.0, 0.75, 0.5, 0.25]),
            "blendMode": rng.choice(BLEND_MODES),
            "visible": rng.random() < 0.85,
            "transform": random_transform(width, height, image, rng),
        }
        if folder_id and rng.random() < 0.5:
            layer["parentID"] = folder_id
        if rng.random() < 0.35:
            layer["mask"] = gradient_mask(image.width, image.height, rng)
        if rng.random() < 0.25 and layers:
            # Clip onto an earlier layer, as long as it is not the folder record.
            candidates = [entry for entry in layers if not entry.get("isGroup")]
            if candidates:
                layer["maskSourceID"] = rng.choice(candidates)["id"]
        layers.append(layer)
    return width, height, layers


def main(argv=None):
    parser = argparse.ArgumentParser()
    parser.add_argument("--cli", required=True)
    parser.add_argument("--count", type=int, default=40)
    parser.add_argument("--seed", type=int, default=None)
    parser.add_argument("--tolerance", type=int, default=1)
    parser.add_argument("--keep", action="store_true", help="keep every package, not just the failures")
    parser.add_argument("--roundtrip", action="store_true",
                        help="also save each document through the editor's writer and compare")
    args = parser.parse_args(argv)

    seed = args.seed if args.seed is not None else random.randrange(1 << 30)
    rng = random.Random(seed)
    work = tempfile.mkdtemp(prefix="compfuzz-")
    if os.path.exists(FAILURES) and not args.keep:
        shutil.rmtree(FAILURES, ignore_errors=True)
    os.makedirs(FAILURES, exist_ok=True)
    failures = 0
    try:
        for index in range(args.count):
            document_seed = rng.randrange(1 << 30)
            local = random.Random(document_seed)
            width, height, layers = random_document(local)
            package = os.path.join(work, f"doc{index:03d}.comp")
            manifest = R.write_comp(package, width, height, layers)
            render = os.path.join(work, f"doc{index:03d}.png")
            result = subprocess.run([args.cli, "render", package, "-o", render],
                                    capture_output=True, text=True)
            if result.returncode != 0:
                print(f"FAIL doc{index:03d} seed={document_seed}: the engine refused to render it: "
                      f"{(result.stderr or result.stdout).strip()[:160]}")
                failures += 1
                shutil.copytree(package, os.path.join(FAILURES, f"doc{index:03d}"))
                continue
            images, masks = {}, {}
            for record in manifest["layers"]:
                if record.get("imageFile"):
                    with Image.open(os.path.join(package, "images", record["imageFile"])) as image:
                        images[record["id"]] = R.rgba_image_to_array(image)
                if record.get("maskFile"):
                    with Image.open(os.path.join(package, "images", record["maskFile"])) as mask:
                        masks[record["id"]] = R.gray_mask_to_array(mask)
            expected = R.composite_document(manifest, images, masks)
            with Image.open(render) as image:
                actual = R.rgba_image_to_array(image)
            if expected.shape != actual.shape:
                worst = -1
            else:
                worst = int(np.abs(expected.astype(np.int16) - actual.astype(np.int16)).max())
            if worst > args.tolerance:
                print(f"FAIL doc{index:03d} seed={document_seed}: worst {worst} "
                      f"(modes {sorted({entry.get('blendMode', 'Normal') for entry in layers})})")
                failures += 1
                shutil.copytree(package, os.path.join(FAILURES, f"doc{index:03d}"))
                continue

            if args.roundtrip:
                # Saving and reopening must not change a single pixel, and the result must still be a
                # package the macOS-side reader would accept. This is where a writer that drops a mask,
                # lowercases a UUID or loses an unknown field shows up.
                saved = os.path.join(work, f"doc{index:03d}-resaved.comp")
                result = subprocess.run([args.cli, "resave", package, saved], capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"FAIL doc{index:03d} seed={document_seed}: resaving failed: "
                          f"{(result.stderr or result.stdout).strip()[:160]}")
                    failures += 1
                    shutil.copytree(package, os.path.join(FAILURES, f"doc{index:03d}"))
                    continue
                problems = M.validate_package(saved)
                if problems:
                    print(f"FAIL doc{index:03d} seed={document_seed}: the resaved package would not load "
                          f"on macOS: {problems[0]}")
                    failures += 1
                    shutil.copytree(package, os.path.join(FAILURES, f"doc{index:03d}"))
                    continue
                resaved_render = os.path.join(work, f"doc{index:03d}-resaved.png")
                result = subprocess.run([args.cli, "render", saved, "-o", resaved_render],
                                        capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"FAIL doc{index:03d} seed={document_seed}: the resaved package does not render")
                    failures += 1
                    shutil.copytree(package, os.path.join(FAILURES, f"doc{index:03d}"))
                    continue
                with Image.open(resaved_render) as image:
                    again = R.rgba_image_to_array(image)
                drift = -1 if again.shape != actual.shape else int(np.abs(again.astype(np.int16) - actual.astype(np.int16)).max())
                if drift != 0:
                    print(f"FAIL doc{index:03d} seed={document_seed}: saving changed {drift} levels "
                          f"of the render")
                    failures += 1
                    shutil.copytree(package, os.path.join(FAILURES, f"doc{index:03d}"))
    finally:
        shutil.rmtree(work, ignore_errors=True)

    if failures:
        print(f"FAIL {failures} of {args.count} random documents disagreed (seed {seed}); "
              f"packages kept in {FAILURES}")
        return 1
    print(f"PASS {args.count} random documents agreed with the reference (seed {seed})")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
