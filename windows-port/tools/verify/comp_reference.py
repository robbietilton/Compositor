"""An independent reference implementation of Compositor's compositing model.

The Windows port is checked against this, not against itself: the formulas here come from the
W3C/PDF compositing specification (the ones Photoshop follows), and the package writer follows
docs/project-format.md. Blend math runs in sRGB, the same space the macOS app blends in
(see compositor_mac/Compositor/Rendering/SeparableBlend.swift).

Values are float arrays in [0, 1] with shape (H, W, 3) for color and (H, W) or (H, W, 1) for alpha.
"""

from __future__ import annotations

import json
import os
import shutil
import uuid

import numpy as np
from PIL import Image

EPS = 1e-12


# --------------------------------------------------------------------------------------------
# Separable blend modes, from the W3C compositing spec.
# --------------------------------------------------------------------------------------------


def _clip(x):
    return np.clip(x, 0.0, 1.0)


def blend_normal(cb, cs):
    return cs


def blend_darken(cb, cs):
    return np.minimum(cb, cs)


def blend_multiply(cb, cs):
    return cb * cs


def blend_color_burn(cb, cs):
    out = np.where(cs <= 0.0, 0.0, 1.0 - np.minimum(1.0, (1.0 - cb) / np.maximum(cs, EPS)))
    return _clip(out)


def blend_linear_burn(cb, cs):
    return _clip(cb + cs - 1.0)


def blend_lighten(cb, cs):
    return np.maximum(cb, cs)


def blend_screen(cb, cs):
    return cb + cs - cb * cs


def blend_color_dodge(cb, cs):
    out = np.where(cs >= 1.0, 1.0, np.minimum(1.0, cb / np.maximum(1.0 - cs, EPS)))
    return _clip(out)


def blend_linear_dodge(cb, cs):
    return _clip(cb + cs)


def blend_overlay(cb, cs):
    return blend_hard_light(cs, cb)


def blend_soft_light(cb, cs):
    d = np.where(cb <= 0.25, ((16.0 * cb - 12.0) * cb + 4.0) * cb, np.sqrt(np.maximum(cb, 0.0)))
    return np.where(cs <= 0.5, cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb), cb + (2.0 * cs - 1.0) * (d - cb))


def blend_hard_light(cb, cs):
    return np.where(cs <= 0.5, blend_multiply(2.0 * cs, cb), blend_screen(2.0 * cs - 1.0, cb))


def blend_vivid_light(cb, cs):
    return np.where(cs <= 0.5, blend_color_burn(cb, 2.0 * cs), blend_color_dodge(cb, 2.0 * cs - 1.0))


def blend_linear_light(cb, cs):
    return _clip(cb + 2.0 * cs - 1.0)


def blend_pin_light(cb, cs):
    return np.where(cs <= 0.5, np.minimum(cb, 2.0 * cs), np.maximum(cb, 2.0 * cs - 1.0))


def blend_hard_mix(cb, cs):
    return np.where(blend_vivid_light(cb, cs) < 0.5, 0.0, 1.0)


def blend_difference(cb, cs):
    return np.abs(cb - cs)


def blend_exclusion(cb, cs):
    return cb + cs - 2.0 * cb * cs


def blend_subtract(cb, cs):
    return _clip(cb - cs)


def blend_divide(cb, cs):
    # Photoshop divides by the source and treats a black source as white.
    return np.where(cs <= 0.0, 1.0, _clip(cb / np.maximum(cs, EPS)))


# --------------------------------------------------------------------------------------------
# Non-separable modes, from the PDF blend specification.
# --------------------------------------------------------------------------------------------


def _lum(c):
    return 0.3 * c[..., 0] + 0.59 * c[..., 1] + 0.11 * c[..., 2]


def _clip_color(c):
    l = _lum(c)[..., None]
    n = np.min(c, axis=-1)[..., None]
    x = np.max(c, axis=-1)[..., None]
    c = np.where(n < 0.0, l + (c - l) * l / np.maximum(l - n, EPS), c)
    c = np.where(x > 1.0, l + (c - l) * (1.0 - l) / np.maximum(x - l, EPS), c)
    return _clip(c)


def _set_lum(c, l):
    d = l - _lum(c)
    return _clip_color(c + d[..., None])


def _sat(c):
    return np.max(c, axis=-1) - np.min(c, axis=-1)


def _set_sat(c, s):
    """Reorders the channel magnitudes so the result has the saturation of `s`."""
    cmin = np.min(c, axis=-1, keepdims=True)
    cmax = np.max(c, axis=-1, keepdims=True)
    cmid = np.sum(c, axis=-1, keepdims=True) - cmin - cmax
    span = cmax - cmin
    scale = np.where(span > EPS, s[..., None] / np.maximum(span, EPS), 0.0)
    out = np.where(
        np.isclose(c, cmax),
        (cmax - cmin) * scale,
        np.where(np.isclose(c, cmid), (cmid - cmin) * scale, 0.0),
    )
    return np.where(span > EPS, out, np.zeros_like(c))


def blend_hue(cb, cs):
    return _set_lum(_set_sat(cs, _sat(cb)), _lum(cb))


def blend_saturation(cb, cs):
    return _set_lum(_set_sat(cb, _sat(cs)), _lum(cb))


def blend_color(cb, cs):
    return _set_lum(cs, _lum(cb))


def blend_luminosity(cb, cs):
    return _set_lum(cb, _lum(cs))


SEPARABLE = {
    "Normal": blend_normal,
    "Darken": blend_darken,
    "Multiply": blend_multiply,
    "Color Burn": blend_color_burn,
    "Linear Burn": blend_linear_burn,
    "Lighten": blend_lighten,
    "Screen": blend_screen,
    "Color Dodge": blend_color_dodge,
    "Linear Dodge (Add)": blend_linear_dodge,
    "Overlay": blend_overlay,
    "Soft Light": blend_soft_light,
    "Hard Light": blend_hard_light,
    "Vivid Light": blend_vivid_light,
    "Linear Light": blend_linear_light,
    "Pin Light": blend_pin_light,
    "Hard Mix": blend_hard_mix,
    "Difference": blend_difference,
    "Exclusion": blend_exclusion,
    "Subtract": blend_subtract,
    "Divide": blend_divide,
}

NON_SEPARABLE = {
    "Hue": blend_hue,
    "Saturation": blend_saturation,
    "Color": blend_color,
    "Luminosity": blend_luminosity,
}

ALL_MODES = list(SEPARABLE) + list(NON_SEPARABLE)


def blend(mode: str, cb, cs):
    """Blends source over backdrop, both float arrays in [0, 1]."""
    if mode in SEPARABLE:
        return _clip(SEPARABLE[mode](cb, cs))
    if mode in NON_SEPARABLE:
        return _clip(NON_SEPARABLE[mode](cb, cs))
    raise ValueError(f"unknown blend mode {mode!r}")


# --------------------------------------------------------------------------------------------
# Compositing: W3C source-over with a blend function.
# --------------------------------------------------------------------------------------------


def composite(backdrop_rgba, source_rgba, mode="Normal", opacity=1.0):
    """Composites straight-alpha RGBA arrays; returns a new straight-alpha RGBA array."""
    cb = backdrop_rgba[..., :3].astype(np.float64)
    ab = backdrop_rgba[..., 3:4].astype(np.float64)
    cs = source_rgba[..., :3].astype(np.float64)
    alpha_s = source_rgba[..., 3:4].astype(np.float64) * float(opacity)

    blended = blend(mode, cb, cs)
    ao = alpha_s + ab * (1.0 - alpha_s)
    premultiplied = (
        alpha_s * (1.0 - ab) * cs
        + alpha_s * ab * blended
        + (1.0 - alpha_s) * ab * cb
    )
    color = np.where(ao > EPS, premultiplied / np.maximum(ao, EPS), 0.0)
    out = np.concatenate([_clip(color), _clip(ao)], axis=-1)
    return out


def place_nearest(image, origin, size, rotation=0.0, flip_x=False, flip_y=False,
                  width=None, height=None):
    """Places a layer image in document space the way the format describes it.

    Mirrors the macOS record: the image is stretched to `size`, rotated clockwise about the box
    center, flipped inside the box, then moved to `origin`. Only Nearest sampling is modelled here;
    filtered sampling has no single correct kernel to compare against.
    """
    src_h, src_w = image.shape[:2]
    width = width or int(round(origin[0] + size[0]))
    height = height or int(round(origin[1] + size[1]))
    out = np.zeros((height, width, 4))

    # Local box coordinates (0..size) to document coordinates.
    cx, cy = size[0] / 2.0, size[1] / 2.0
    theta = np.deg2rad(rotation)
    cos_t, sin_t = np.cos(theta), np.sin(theta)

    ys, xs = np.mgrid[0:height, 0:width]
    px = xs + 0.5 - origin[0]
    py = ys + 0.5 - origin[1]
    # Undo the rotation about the box center; clockwise on screen means y grows downward.
    lx = cos_t * (px - cx) + sin_t * (py - cy) + cx
    ly = -sin_t * (px - cx) + cos_t * (py - cy) + cy
    # Undo the flips.
    if flip_x:
        lx = size[0] - lx
    if flip_y:
        ly = size[1] - ly
    inside = (lx >= 0) & (lx < size[0]) & (ly >= 0) & (ly < size[1])
    sx = np.clip((lx / size[0] * src_w).astype(np.int64), 0, src_w - 1)
    sy = np.clip((ly / size[1] * src_h).astype(np.int64), 0, src_h - 1)
    sampled = image[sy, sx]
    out[inside] = sampled[inside]
    return out


def effective_opacity(record, by_id) -> float:
    """A layer's opacity times every enclosing folder's, as LayerGroups.swift defines it."""
    opacity = float(record.get("opacity", 1.0))
    parent = record.get("parentID")
    depth = 0
    while parent is not None and depth < 64:
        node = by_id.get(parent)
        if node is None:
            break
        opacity *= float(node.get("opacity", 1.0))
        parent = node.get("parentID")
        depth += 1
    return opacity


def group_mask_factor(record, by_id, masks, shape):
    """The product of every enclosing folder's enabled mask."""
    factor = np.ones(shape)
    parent = record.get("parentID")
    depth = 0
    while parent is not None and depth < 64:
        node = by_id.get(parent)
        if node is None:
            break
        mask = layer_mask_in_document(node, masks, shape)
        if mask is not None:
            factor = factor * mask
        parent = node.get("parentID")
        depth += 1
    return factor


def placed_layer(record, images, shape):
    """A layer's pixels in document space, or None when it has no image."""
    image = images.get(record["id"])
    if image is None:
        return None
    transform = record.get("transform")
    if transform is None:
        return image if image.shape[:2] == shape else None
    origin = transform["origin"]
    size = transform["size"]
    if (origin == [0.0, 0.0] and size == [float(image.shape[1]), float(image.shape[0])]
            and float(transform.get("rotation", 0.0)) == 0.0
            and not transform.get("flipX") and not transform.get("flipY")):
        return image
    return place_nearest(
        image,
        origin=origin,
        size=size,
        rotation=float(transform.get("rotation", 0.0)),
        flip_x=bool(transform.get("flipX")),
        flip_y=bool(transform.get("flipY")),
        width=shape[1],
        height=shape[0],
    )


def layer_mask_in_document(record, masks, shape, enabled_only=True):
    """A layer's or folder's mask placed in document space, or None.

    A mask's extent matches its layer's local rectangle, so the layer transform places it too
    (docs/project-format.md, version 4). An unlinked mask keeps its own placement instead.
    """
    mask = masks.get(record["id"])
    if mask is None or (enabled_only and not record.get("maskEnabled", True)):
        return None
    plane = mask[..., 0]
    transform = record.get("transform") or {}
    if record.get("maskLinked") is False and record.get("maskPlacement"):
        transform = record["maskPlacement"]
    origin = transform.get("origin")
    size = transform.get("size")
    if origin is None or size is None:
        return plane if plane.shape == shape else None
    height, width = shape
    if (origin == [0.0, 0.0]
            and size == [float(width), float(height)]
            and float(transform.get("rotation", 0.0)) == 0.0
            and not transform.get("flipX") and not transform.get("flipY")
            and plane.shape == shape):
        return plane
    rgba = np.dstack([plane, plane, plane, np.ones_like(plane)])
    placed = place_nearest(
        rgba,
        origin=origin,
        size=size,
        rotation=float(transform.get("rotation", 0.0)),
        flip_x=bool(transform.get("flipX")),
        flip_y=bool(transform.get("flipY")),
        width=width,
        height=height,
    )
    return placed[..., 0]


def clip_coverage(record, by_id, images, masks, shape, seen=None):
    """A layer's coverage as a clipping-mask base: pixels, transform, opacity, raster mask and any
    upstream live mask. Visibility and RGB do not contribute (docs/project-format.md, version 5).

    Folder masks are deliberately left out: a clipped layer and its base normally share the same
    folders, so those masks are already applied to the clipped layer.
    """
    seen = seen or set()
    if record["id"] in seen or len(seen) > 256:
        return np.ones(shape)
    seen = seen | {record["id"]}
    pixels = placed_layer(record, images, shape)
    coverage = pixels[..., 3] if pixels is not None else np.ones(shape)
    mask = layer_mask_in_document(record, masks, shape)
    if mask is not None:
        coverage = coverage * mask
    # LiveLayerMask.swift draws the source into the coverage with its effective opacity: the layer's
    # own value times every enclosing folder's.
    coverage = coverage * effective_opacity(record, by_id)
    source = record.get("maskSourceID")
    if source and source in by_id:
        coverage = coverage * clip_coverage(by_id[source], by_id, images, masks, shape, seen)
    return coverage


def composite_document(manifest, images, masks):
    """Composites a whole package: bottom to top, folders pass-through, folder opacity multiplied
    into each child, folder masks multiplying every descendant, clipping masks limiting a layer's
    alpha by its base's coverage.
    """
    width, height = manifest["width"], manifest["height"]
    by_id = {record["id"]: record for record in manifest["layers"]}
    hidden = _hidden_ids(manifest, by_id)
    result = np.zeros((height, width, 4))

    for record in manifest["layers"]:
        if record.get("isGroup") or record["id"] in hidden:
            continue
        pixels = placed_layer(record, images, (height, width))
        if pixels is None:
            continue
        source = pixels.copy()
        factor = group_mask_factor(record, by_id, masks, (height, width))
        mask = layer_mask_in_document(record, masks, (height, width))
        if mask is not None:
            factor = factor * mask
        source_id = record.get("maskSourceID")
        if source_id and source_id in by_id:
            factor = factor * clip_coverage(by_id[source_id], by_id, images, masks, (height, width))
        source[..., 3] = np.clip(source[..., 3] * factor, 0.0, 1.0)
        result = composite(result, source, record.get("blendMode", "Normal"),
                           float(record.get("opacity", 1.0)) * _ancestor_opacity(record, by_id))
    return result


def _ancestor_opacity(record, by_id):
    opacity = 1.0
    parent = record.get("parentID")
    depth = 0
    while parent is not None and depth < 64:
        node = by_id.get(parent)
        if node is None:
            break
        opacity *= float(node.get("opacity", 1.0))
        parent = node.get("parentID")
        depth += 1
    return opacity


def _hidden_ids(manifest, by_id):
    """Every layer that does not show: hidden itself, or inside a hidden folder."""
    hidden = set()
    for record in manifest["layers"]:
        if not record.get("isVisible", True):
            hidden.add(record["id"])
            continue
        parent = record.get("parentID")
        depth = 0
        while parent is not None and depth < 64:
            node = by_id.get(parent)
            if node is None or not node.get("isVisible", True):
                hidden.add(record["id"])
                break
            parent = node.get("parentID")
            depth += 1
    return hidden


def rgba_image_to_array(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("RGBA"), dtype=np.float64) / 255.0


def array_to_rgba_image(array: np.ndarray) -> Image.Image:
    data = np.clip(np.rint(array * 255.0), 0, 255).astype(np.uint8)
    return Image.fromarray(data, mode="RGBA")


def gray_mask_to_array(image: Image.Image) -> np.ndarray:
    return np.asarray(image.convert("L"), dtype=np.float64)[..., None] / 255.0


# --------------------------------------------------------------------------------------------
# Package writing, following docs/project-format.md.
# ---------------------------------------------------------------------------------------------


def new_uuid() -> str:
    return str(uuid.uuid4()).upper()


def write_comp(path, width, height, layers, resolution=72, version=11, document_id=None):
    """Writes a .comp package.

    Each layer is a dict: id, name, image (PIL RGBA image, optional), mask (PIL L image, optional),
    opacity, blendMode, isGroup, children (nested groups are written flat, as the format stores them),
    adjustment (raw dict, optional), visible.
    """
    if os.path.exists(path):
        shutil.rmtree(path)
    os.makedirs(os.path.join(path, "images"))

    records = []
    for layer in layers:
        records.append(_write_layer(path, layer))

    manifest = {
        "format": "com.compositor.project",
        "version": version,
        "colorSpace": "sRGB",
        "documentID": document_id or new_uuid(),
        "width": width,
        "height": height,
        "resolution": resolution,
        "activeLayerID": records[-1]["id"] if records else None,
        "layers": records,
    }
    with open(os.path.join(path, "manifest.json"), "w", encoding="utf-8") as handle:
        json.dump(manifest, handle, indent=2, sort_keys=True)
    return manifest


def _write_layer(package, layer):
    layer_id = layer.get("id") or new_uuid()
    record = {
        "id": layer_id,
        "name": layer.get("name", "Layer"),
        "isVisible": layer.get("visible", True),
        "isGroup": layer.get("isGroup", False),
        "opacity": layer.get("opacity", 1.0),
        "blendMode": layer.get("blendMode", "Normal"),
        "transform": layer.get("transform") or {
            "origin": [0.0, 0.0],
            "size": [float(layer["image"].width), float(layer["image"].height)] if layer.get("image") else [0.0, 0.0],
            "rotation": 0.0,
            "flipX": False,
            "flipY": False,
            "sampling": "High quality",
        },
    }
    if layer.get("parentID"):
        record["parentID"] = layer["parentID"]
    image = layer.get("image")
    if image is not None:
        name = f"{layer_id}.png"
        image.convert("RGBA").save(os.path.join(package, "images", name))
        record["imageFile"] = name
    mask = layer.get("mask")
    if mask is not None:
        name = f"{layer_id}.mask.png"
        mask.convert("L").save(os.path.join(package, "images", name))
        record["maskFile"] = name
        record["maskEnabled"] = layer.get("maskEnabled", True)
    if layer.get("adjustment") is not None:
        record["adjustment"] = layer["adjustment"]
    if layer.get("maskSourceID"):
        record["maskSourceID"] = layer["maskSourceID"]
    # Metadata the caller supplies verbatim: the writer must not silently drop a feature, or a fixture
    # testing that feature passes for the wrong reason.
    for key in ("effects", "text", "shape", "maskPlacement", "maskLinked"):
        if layer.get(key) is not None:
            record[key] = layer[key]
    return record


def read_comp(path):
    """Reads a package back into (manifest, {layer id: RGBA array}, {layer id: L array})."""
    with open(os.path.join(path, "manifest.json"), "r", encoding="utf-8") as handle:
        manifest = json.load(handle)
    images, masks = {}, {}
    for record in manifest["layers"]:
        if record.get("imageFile"):
            with Image.open(os.path.join(path, "images", record["imageFile"])) as image:
                images[record["id"]] = rgba_image_to_array(image)
        if record.get("maskFile"):
            with Image.open(os.path.join(path, "images", record["maskFile"])) as mask:
                masks[record["id"]] = gray_mask_to_array(mask)
    return manifest, images, masks
