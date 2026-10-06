"""A minimal .comp writer/reader for the oracle's own fixtures.

The schema follows compositor_mac/docs/project-format.md (version 11) and the shape
`compc sample` writes, so these packages are ordinary Compositor documents: one opaque base
layer, then the adjustment or effects layer under test.
"""

from __future__ import annotations

import json
import os
import shutil
import uuid

import numpy as np
from PIL import Image


def new_uuid() -> str:
    return str(uuid.uuid4()).upper()


def write_package(path, width, height, layers):
    """`layers` is a list of dicts: id, name, rgba (uint8 HxWx4, optional), adjustment, effects,
    transform, opacity, blendMode, visible."""
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(os.path.join(path, "images"))
    records = []
    for layer in layers:
        records.append(_write_layer(path, layer, width, height))
    manifest = {
        "format": "com.compositor.project",
        "version": 11,
        "colorSpace": "sRGB",
        "documentID": new_uuid(),
        "width": width,
        "height": height,
        "resolution": 72,
        "activeLayerID": records[0]["id"] if records else None,
        "layers": records,
    }
    with open(os.path.join(path, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2)
    return manifest


def _write_layer(package, layer, width, height):
    layer_id = layer.get("id") or new_uuid()
    record = {
        "id": layer_id,
        "name": layer.get("name", "Layer"),
        "isVisible": layer.get("visible", True),
        "isGroup": False,
        "opacity": layer.get("opacity", 1.0),
        "blendMode": layer.get("blendMode", "Normal"),
        "transform": {
            "origin": [0.0, 0.0],
            "size": [float(width), float(height)],
            "rotation": 0.0,
            "flipX": False,
            "flipY": False,
            "sampling": "Nearest",
        },
    }
    rgba = layer.get("rgba")
    if rgba is not None:
        name = layer_id + ".png"
        Image.fromarray(np.asarray(rgba, dtype=np.uint8), mode="RGBA").save(os.path.join(package, "images", name))
        record["imageFile"] = name
    if layer.get("adjustment") is not None:
        record["adjustment"] = layer["adjustment"]
    if layer.get("effects") is not None:
        record["effects"] = layer["effects"]
    if layer.get("transform"):
        record["transform"] = layer["transform"]
    return record


def read_package(path):
    with open(os.path.join(path, "manifest.json"), "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    images = {}
    for record in manifest["layers"]:
        if record.get("imageFile"):
            with Image.open(os.path.join(path, "images", record["imageFile"])) as image:
                images[record["id"]] = np.asarray(image.convert("RGBA"), dtype=np.uint8)
    return manifest, images
