"""Builds one package per format version, plus packages that use a feature too early.

The format has eleven versions and each one added something: opacity and blend modes in 3, layer masks
in 4, clipping links in 5, folder masks in 6, adjustment layers in 7, folder opacity in 8, adjustments
that read their neighbours in 9, per-letter colours in 10 and per-letter faces in 11. An editor that
claims to read v1..v11 has to accept every one of those packages and must refuse a package that uses a
feature its version did not have -- which is what the macOS validator does and what comp-core ports.

Run:  python make_version_fixtures.py
"""

from __future__ import annotations

import os

import numpy as np
from PIL import Image

import comp_reference as R

HERE = os.path.dirname(os.path.abspath(__file__))
VALID = os.path.join(HERE, "fixtures-versions")
INVALID = os.path.join(VALID, "invalid")
WIDTH, HEIGHT = 64, 48


def backdrop():
    xs = np.linspace(0.0, 1.0, WIDTH)[None, :]
    ys = np.linspace(0.0, 1.0, HEIGHT)[:, None]
    array = np.zeros((HEIGHT, WIDTH, 4))
    array[..., 0] = np.broadcast_to(xs, (HEIGHT, WIDTH))
    array[..., 1] = np.broadcast_to(ys, (HEIGHT, WIDTH))
    array[..., 2] = 0.4
    array[..., 3] = 1.0
    return R.array_to_rgba_image(array)


def overlay(value=0.8):
    array = np.zeros((HEIGHT, WIDTH, 4))
    array[HEIGHT // 4: HEIGHT * 3 // 4, WIDTH // 4: WIDTH * 3 // 4, :3] = value
    array[HEIGHT // 4: HEIGHT * 3 // 4, WIDTH // 4: WIDTH * 3 // 4, 3] = 1.0
    return R.array_to_rgba_image(array)


def half_mask():
    array = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
    array[:, : WIDTH // 2] = 255
    return Image.fromarray(array, mode="L")


def levels():
    return {
        "channel": "RGB",
        "ranges": [{"black": 0.0, "gamma": 1.0, "white": 255.0, "outputBlack": 0.0, "outputWhite": 255.0}] * 4,
    }


def curves():
    return {"channel": "RGB", "channels": [[{"x": 0.0, "y": 0.0}, {"x": 255.0, "y": 255.0}]] * 4}


def adjustment(kind, **extra):
    body = {
        "kind": kind, "hue": 0.0, "saturation": 0.0, "lightness": 0.0, "colorize": False,
        "levels": levels(), "curves": curves(),
    }
    body.update(extra)
    return body


def text_layer(**extra):
    layer = {
        "name": "Title",
        "image": overlay(0.9),
        "text": {
            "content": "Hi",
            "fontName": "Arial",
            "fontSize": 18.0,
            "red": 1.0, "green": 1.0, "blue": 1.0,
            "alignment": "Left",
            "tracking": 0.0,
            "leading": 1.2,
        },
    }
    layer["text"].update(extra)
    return layer


def canvas_transform():
    """A layer without pixels -- a folder or an adjustment -- still carries the canvas rectangle."""
    return {"origin": [0.0, 0.0], "size": [float(WIDTH), float(HEIGHT)], "rotation": 0.0,
            "flipX": False, "flipY": False, "sampling": "High quality"}


def packages():
    """Returns (version, layers, note) for each version, using exactly what that version allows."""
    base = [{"name": "Backdrop", "image": backdrop()}, {"name": "Overlay", "image": overlay()}]
    group = {"id": R.new_uuid(), "name": "Group", "isGroup": True, "transform": canvas_transform()}
    child = {"name": "Inside", "image": overlay(0.5), "parentID": group["id"]}
    adjustment_layer = lambda kind, **extra: {  # noqa: E731 - a fixture helper, not production code
        "name": kind, "adjustment": adjustment(kind, **extra), "transform": canvas_transform(),
    }
    return [
        (1, base, "two plain layers, unit opacity, Normal blend"),
        (2, [{"name": "Backdrop", "image": backdrop()}] + base[1:], "nothing new was added in 2"),
        (3, [base[0], {**base[1], "opacity": 0.6, "blendMode": "Multiply"}], "opacity and blend mode"),
        (4, [base[0], {**base[1], "mask": half_mask()}], "a layer mask"),
        (5, [base[0], {**base[1], "id": group["id"]},
             {"name": "Clipped", "image": overlay(0.3), "maskSourceID": group["id"]}],
         "a clipping link"),
        (6, [base[0], {**group, "mask": half_mask()}, child], "a folder mask"),
        (7, [base[0], adjustment_layer("Invert")], "a pointwise adjustment layer"),
        (8, [base[0], {**group, "opacity": 0.5}, child], "folder opacity"),
        (9, [base[0], adjustment_layer("Gaussian Blur", blurRadius=6.0)],
         "an adjustment that reads its neighbours"),
        (10, [base[0], text_layer(colorRuns=[{"location": 0, "length": 1, "red": 1.0, "green": 0.0, "blue": 0.0},
                                              {"location": 1, "length": 1, "red": 0.0, "green": 0.0, "blue": 1.0}])],
         "per-letter colours"),
        (11, [base[0], text_layer(fontRuns=[{"location": 0, "length": 1, "fontName": "Arial"},
                                             {"location": 1, "length": 1, "fontName": "Times New Roman"}])],
         "per-letter faces"),
    ]


def write_valid():
    os.makedirs(VALID, exist_ok=True)
    written = []
    for version, layers, note in packages():
        path = os.path.join(VALID, f"v{version}.comp")
        R.write_comp(path, WIDTH, HEIGHT, layers, version=version)
        written.append((version, note))
    return written


def write_invalid():
    """One feature used one version too early, per feature the format ever added."""
    os.makedirs(INVALID, exist_ok=True)
    cases = [
        (1, "opacity", [{"name": "Backdrop", "image": backdrop()},
                        {"name": "Overlay", "image": overlay(), "opacity": 0.5}], "opacity arrived in 3"),
        (2, "blend", [{"name": "Backdrop", "image": backdrop()},
                      {"name": "Overlay", "image": overlay(), "blendMode": "Multiply"}], "blend modes arrived in 3"),
        (3, "mask", [{"name": "Backdrop", "image": backdrop()},
                     {"name": "Overlay", "image": overlay(), "mask": half_mask()}], "layer masks arrived in 4"),
        (4, "clip", None, "clipping links arrived in 5"),
        (5, "folder-mask", None, "folder masks arrived in 6"),
        (6, "adjustment", [{"name": "Backdrop", "image": backdrop()},
                           {"name": "Invert", "adjustment": adjustment("Invert")}], "adjustment layers arrived in 7"),
        (7, "folder-opacity", None, "folder opacity arrived in 8"),
        (8, "blur", [{"name": "Backdrop", "image": backdrop()},
                     {"name": "Blur", "adjustment": adjustment("Gaussian Blur", blurRadius=4.0)}],
         "neighbour-reading adjustments arrived in 9"),
        (9, "color-runs", [{"name": "Backdrop", "image": backdrop()},
                           text_layer(colorRuns=[{"location": 0, "length": 1, "red": 1.0, "green": 0.0, "blue": 0.0}])],
         "per-letter colours arrived in 10"),
        (10, "font-runs", [{"name": "Backdrop", "image": backdrop()},
                           text_layer(fontRuns=[{"location": 0, "length": 1, "fontName": "Arial"}])],
         "per-letter faces arrived in 11"),
    ]
    written = []
    for version, feature, layers, note in cases:
        if layers is None:
            # Reuse the legitimate package for that version and add the feature it cannot carry.
            source = os.path.join(VALID, f"v{version}.comp")
            manifest, images, masks = R.read_comp(source)
            layers = []
            for record in manifest["layers"]:
                entry = {"id": record["id"], "name": record["name"], "isGroup": record.get("isGroup", False),
                         "opacity": record.get("opacity", 1.0), "blendMode": record.get("blendMode", "Normal")}
                # read_comp hands back arrays keyed by layer id; write_comp wants images.
                if record.get("imageFile"):
                    entry["image"] = R.array_to_rgba_image(images[record["id"]])
                if record.get("maskFile"):
                    mask_array = np.asarray(masks[record["id"]])
                    if mask_array.ndim == 3:
                        mask_array = mask_array[..., 0]
                    entry["mask"] = Image.fromarray(mask_array.astype(np.uint8), mode="L")
                if record.get("parentID"):
                    entry["parentID"] = record["parentID"]
                layers.append(entry)
            if feature == "clip":
                layers.append({"name": "Clipped", "image": overlay(0.3), "maskSourceID": layers[-1]["id"]})
            elif feature == "folder-mask":
                layers.append({"name": "Group", "isGroup": True, "mask": half_mask()})
            elif feature == "folder-opacity":
                layers.append({"name": "Group", "isGroup": True, "opacity": 0.5})
        path = os.path.join(INVALID, f"v{version}-{feature}.comp")
        R.write_comp(path, WIDTH, HEIGHT, layers, version=version)
        written.append((version, feature, note))
    return written


def main():
    valid = write_valid()
    invalid = write_invalid()
    print(f"wrote {len(valid)} version packages and {len(invalid)} too-early packages to {VALID}")
    for version, note in valid:
        print(f"  v{version}: {note}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
