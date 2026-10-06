"""Builds .comp fixtures and the reference PNGs the Rust engine must reproduce.

Run:  python make_fixtures.py
Output: fixtures/<name>.comp, fixtures/expected/<name>.png, fixtures/index.json
"""

from __future__ import annotations

import json
import os

import numpy as np
from PIL import Image, ImageDraw

import comp_reference as R

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures")
EXPECTED = os.path.join(FIXTURES, "expected")

WIDTH = 64
HEIGHT = 64


def backdrop_array():
    """An opaque backdrop with a horizontal and a vertical ramp plus a color twist."""
    xs = np.linspace(0.0, 1.0, WIDTH)[None, :]
    ys = np.linspace(0.0, 1.0, HEIGHT)[:, None]
    red = np.broadcast_to(xs, (HEIGHT, WIDTH))
    green = np.broadcast_to(ys, (HEIGHT, WIDTH))
    blue = np.broadcast_to(0.35 + 0.3 * np.sin(xs * np.pi), (HEIGHT, WIDTH))
    alpha = np.ones((HEIGHT, WIDTH))
    return np.stack([red, green, blue, alpha], axis=-1)


def source_array():
    """The blend probe: hard color blocks, a gradient, black and white extremes."""
    array = np.zeros((HEIGHT, WIDTH, 4))
    xs = np.linspace(0.0, 1.0, WIDTH)[None, :]
    array[..., 0] = np.broadcast_to(xs, (HEIGHT, WIDTH))
    array[..., 1] = 0.25
    array[..., 2] = 1.0 - np.broadcast_to(xs, (HEIGHT, WIDTH))
    array[..., 3] = 1.0
    # A quarter of the image is pure white, a quarter pure black, so every dodging mode is exercised
    # at its boundary.
    array[0:HEIGHT // 4, 0:WIDTH // 4, 0:3] = 1.0
    array[0:HEIGHT // 4, WIDTH // 4:WIDTH // 2, 0:3] = 0.0
    array[HEIGHT // 4:HEIGHT // 2, 0:WIDTH // 4, 0:3] = 0.5
    return array


def array_to_image(array):
    return R.array_to_rgba_image(array)


def quantize(array):
    """The 8-bit values a PNG will actually hold.

    The reference composite must run on the stored bytes, not on the floats that drew them: an
    0.2% difference in the backdrop is amplified by 1/source in Color Burn and Color Dodge.
    """
    return np.rint(np.clip(array, 0.0, 1.0) * 255.0) / 255.0


def write_fixture(name, width, height, layers, expected, notes, version=11):
    package = os.path.join(FIXTURES, f"{name}.comp")
    manifest = R.write_comp(package, width, height, layers, version=version)
    os.makedirs(EXPECTED, exist_ok=True)
    expected_path = os.path.join(EXPECTED, f"{name}.png")
    R.array_to_rgba_image(expected).save(expected_path)
    return {
        "name": name,
        "package": os.path.relpath(package, HERE).replace("\\", "/"),
        "expected": os.path.relpath(expected_path, HERE).replace("\\", "/"),
        "width": width,
        "height": height,
        "documentID": manifest["documentID"],
        "notes": notes,
    }


def write_document_fixture(name, width, height, layers, notes):
    """Writes a package and derives the expected image from the oracle's document compositor.

    Used for the semantics that are about the stack rather than one blend mode: clipping masks,
    folder masks, flips, visibility and nested folder opacity.
    """
    package = os.path.join(FIXTURES, f"{name}.comp")
    manifest = R.write_comp(package, width, height, layers)
    _, images, masks = R.read_comp(package)
    expected = R.composite_document(manifest, images, masks)
    os.makedirs(EXPECTED, exist_ok=True)
    expected_path = os.path.join(EXPECTED, f"{name}.png")
    R.array_to_rgba_image(expected).save(expected_path)
    return {
        "name": name,
        "package": os.path.relpath(package, HERE).replace("\\", "/"),
        "expected": os.path.relpath(expected_path, HERE).replace("\\", "/"),
        "width": width,
        "height": height,
        "documentID": manifest["documentID"],
        "notes": notes,
    }


def full_transform(width, height):
    return {
        "origin": [0.0, 0.0],
        "size": [float(width), float(height)],
        "rotation": 0.0,
        "flipX": False,
        "flipY": False,
        "sampling": "Nearest",
    }


def main():
    os.makedirs(FIXTURES, exist_ok=True)
    index = []

    backdrop = quantize(backdrop_array())
    source = quantize(source_array())

    # 1. Every blend mode, one package each, backdrop + probe layer.
    for mode in R.ALL_MODES:
        expected = R.composite(backdrop, source, mode, 1.0)
        slug = mode.lower().replace(" ", "-").replace("(", "").replace(")", "").replace("/", "-")
        index.append(write_fixture(
            f"blend-{slug}", WIDTH, HEIGHT,
            [
                {"name": "Backdrop", "image": array_to_image(backdrop)},
                {"name": f"Probe {mode}", "image": array_to_image(source), "blendMode": mode},
            ],
            expected,
            f"blend mode {mode}: opaque probe over an opaque ramp",
        ))

    # 2. Alpha ramp: normal blend with opacity, plus a transparent background.
    alpha_ramp = source.copy()
    alpha_ramp[..., 3] = quantize(np.broadcast_to(np.linspace(0.0, 1.0, WIDTH)[None, :], (HEIGHT, WIDTH)))
    expected = R.composite(backdrop, alpha_ramp, "Normal", 0.75)
    index.append(write_fixture(
        "alpha-ramp", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"name": "Fade", "image": array_to_image(alpha_ramp), "opacity": 0.75},
        ],
        expected,
        "source alpha ramp with layer opacity 0.75",
    ))

    # 3. Layer mask: a gray ramp hides the left half smoothly.
    mask = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
    ramp = np.linspace(0, 255, WIDTH).astype(np.uint8)
    mask[:, :] = ramp[None, :]
    opaque = quantize(np.ones((HEIGHT, WIDTH, 4)))
    opaque[..., 0] = quantize(np.full((HEIGHT, WIDTH), 0.9))
    opaque[..., 1] = quantize(np.full((HEIGHT, WIDTH), 0.1))
    opaque[..., 2] = quantize(np.full((HEIGHT, WIDTH), 0.1))
    expected = R.composite(backdrop, opaque * np.concatenate([np.ones((HEIGHT, WIDTH, 3)), mask[..., None].astype(np.float64) / 255.0], axis=-1))
    index.append(write_fixture(
        "layer-mask", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {
                "name": "Masked",
                "image": array_to_image(opaque),
                "mask": Image.fromarray(mask, mode="L"),
            },
        ],
        expected,
        "layer mask ramp multiplies the layer alpha",
    ))

    # 4. Folder opacity multiplies into its children.
    layer_a = quantize(np.zeros((HEIGHT, WIDTH, 4)))
    layer_a[..., 0] = quantize(np.full((HEIGHT, WIDTH), 0.2))
    layer_a[..., 1] = quantize(np.full((HEIGHT, WIDTH), 0.8))
    layer_a[..., 2] = quantize(np.full((HEIGHT, WIDTH), 0.4))
    layer_a[..., 3] = 1.0
    layer_b = quantize(np.zeros((HEIGHT, WIDTH, 4)))
    layer_b[..., 0] = quantize(np.full((HEIGHT, WIDTH), 0.1))
    layer_b[..., 1] = quantize(np.full((HEIGHT, WIDTH), 0.1))
    layer_b[..., 2] = quantize(np.full((HEIGHT, WIDTH), 0.9))
    layer_b[..., 3] = 1.0
    layer_b[:, : WIDTH // 2, 3] = 0.0
    group_id = R.new_uuid()
    # Draw order: backdrop, then the folder's first child at 0.5, then the second at 0.5. The folder
    # is never composited as a unit, so its opacity lands on each child separately.
    expected = R.composite(R.composite(backdrop, layer_a, "Normal", 0.5), layer_b, "Normal", 0.5)
    index.append(write_fixture(
        "group-opacity", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": group_id, "name": "Folder", "isGroup": True, "opacity": 0.5,
             "transform": {"origin": [0.0, 0.0], "size": [float(WIDTH), float(HEIGHT)],
                           "rotation": 0.0, "flipX": False, "flipY": False, "sampling": "High quality"}},
            {"name": "Warm", "image": array_to_image(layer_a), "parentID": group_id},
            {"name": "Cool", "image": array_to_image(layer_b), "parentID": group_id},
        ],
        expected,
        "folder opacity 0.5 multiplies into both children",
    ))

    # 5. Adjustment layer: Invert over the backdrop.
    expected = R.composite(backdrop, np.concatenate([
        1.0 - backdrop[..., :3], backdrop[..., 3:4]
    ], axis=-1), "Normal", 1.0)
    index.append(write_fixture(
        "adjustment-invert", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {
                "name": "Invert",
                "adjustment": {
                    "kind": "Invert",
                    "hue": 0.0, "saturation": 0.0, "lightness": 0.0, "colorize": False,
                    "levels": {"channel": "RGB", "ranges": [
                        {"black": 0.0, "gamma": 1.0, "white": 255.0, "outputBlack": 0.0, "outputWhite": 255.0}
                    ] * 4},
                    "curves": {"channel": "RGB", "channels": [
                        [{"x": 0.0, "y": 0.0}, {"x": 255.0, "y": 255.0}]
                    ] * 4},
                },
                "transform": {"origin": [0.0, 0.0], "size": [float(WIDTH), float(HEIGHT)],
                              "rotation": 0.0, "flipX": False, "flipY": False, "sampling": "High quality"},
            },
        ],
        expected,
        "Invert adjustment layer affects everything below it",
    ))

    # 6. Placement: a smaller layer placed away from the corner, nearest sampling, no rotation.
    probe = np.zeros((12, 16, 4))
    for y in range(12):
        for x in range(16):
            probe[y, x] = [quantize(np.array(x / 15.0)), quantize(np.array(y / 11.0)), 0.4, 1.0]
    placed = R.place_nearest(probe, origin=[9.0, 6.0], size=[16.0, 12.0], width=WIDTH, height=HEIGHT)
    expected = R.composite(backdrop, placed, "Normal", 1.0)
    index.append(write_fixture(
        "placement-offset", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {
                "name": "Placed",
                "image": array_to_image(probe),
                "transform": {"origin": [9.0, 6.0], "size": [16.0, 12.0], "rotation": 0.0,
                              "flipX": False, "flipY": False, "sampling": "Nearest"},
            },
        ],
        expected,
        "a 16x12 layer placed at 9,6 on a bigger canvas: origin and size, nearest sampling",
    ))

    # 7. Scaling: the same layer stretched to 32x24 with nearest sampling.
    scaled = R.place_nearest(probe, origin=[4.0, 8.0], size=[32.0, 24.0], width=WIDTH, height=HEIGHT)
    expected = R.composite(backdrop, scaled, "Normal", 1.0)
    index.append(write_fixture(
        "placement-scaled", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {
                "name": "Scaled",
                "image": array_to_image(probe),
                "transform": {"origin": [4.0, 8.0], "size": [32.0, 24.0], "rotation": 0.0,
                              "flipX": False, "flipY": False, "sampling": "Nearest"},
            },
        ],
        expected,
        "the same layer stretched to 32x24: the image is scaled to the transform size",
    ))

    # 8. Rotation: a quarter turn, which nearest sampling can reproduce exactly.
    rotated_source = np.zeros((16, 16, 4))
    rotated_source[0:8, 0:8] = quantize(np.array([0.9, 0.2, 0.1, 1.0]))
    rotated_source[8:16, 8:16] = quantize(np.array([0.1, 0.2, 0.9, 1.0]))
    turned = R.place_nearest(rotated_source, origin=[16.0, 16.0], size=[16.0, 16.0],
                             rotation=90.0, width=WIDTH, height=HEIGHT)
    expected = R.composite(backdrop, turned, "Normal", 1.0)
    index.append(write_fixture(
        "placement-rotated", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {
                "name": "Turned",
                "image": array_to_image(rotated_source),
                "transform": {"origin": [16.0, 16.0], "size": [16.0, 16.0], "rotation": 90.0,
                              "flipX": False, "flipY": False, "sampling": "Nearest"},
            },
        ],
        expected,
        "a 16x16 layer rotated 90 degrees clockwise about its center",
    ))

    # 9. A demo document for the editor: sky, sun, hills, haze.
    demo_w, demo_h = 480, 320
    sky = np.zeros((demo_h, demo_w, 4))
    for y in range(demo_h):
        t = y / (demo_h - 1)
        sky[y, :, 0] = quantize(np.array(0.15 + 0.55 * t))
        sky[y, :, 1] = quantize(np.array(0.25 + 0.45 * t))
        sky[y, :, 2] = quantize(np.array(0.55 + 0.30 * t))
        sky[y, :, 3] = 1.0
    sun = Image.new("RGBA", (demo_w, demo_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(sun)
    draw.ellipse([330, 40, 430, 140], fill=(255, 236, 176, 255))
    hills = Image.new("RGBA", (demo_w, demo_h), (0, 0, 0, 0))
    draw = ImageDraw.Draw(hills)
    draw.polygon([(0, 320), (140, 190), (300, 320)], fill=(46, 66, 52, 255))
    draw.polygon([(200, 320), (360, 160), (480, 320)], fill=(32, 50, 40, 255))
    demo_layers = [
        {"name": "Sky", "image": R.array_to_rgba_image(sky)},
        {"name": "Sun", "image": sun, "blendMode": "Screen", "opacity": 0.9},
        {"name": "Hills", "image": hills},
    ]
    demo_expected = R.composite(
        R.composite(sky, R.rgba_image_to_array(sun), "Screen", 0.9),
        R.rgba_image_to_array(hills),
        "Normal",
        1.0,
    )
    index.append(write_fixture(
        "demo", demo_w, demo_h, demo_layers, demo_expected,
        "editor demo document: sky, a screen-blended sun at 0.9 opacity, hills with alpha",
    ))

    # 10. Document-level semantics: clipping masks, folder masks, flips, visibility, nesting.
    disc = np.zeros((HEIGHT, WIDTH, 4))
    ys, xs = np.mgrid[0:HEIGHT, 0:WIDTH]
    inside = ((xs - WIDTH / 2) ** 2 + (ys - HEIGHT / 2) ** 2) < (WIDTH / 2.6) ** 2
    disc[..., 3] = np.where(inside, 1.0, 0.0)
    disc[..., 0] = 0.2
    disc[..., 1] = 0.9
    disc[..., 2] = 0.6
    base_id = R.new_uuid()
    stripes = np.zeros((HEIGHT, WIDTH, 4))
    for y in range(HEIGHT):
        stripes[y, :, 0] = quantize(np.array(1.0 if (y // 4) % 2 == 0 else 0.0))
        stripes[y, :, 1] = quantize(np.array(0.4))
        stripes[y, :, 2] = quantize(np.array(1.0 if (y // 4) % 2 == 0 else 0.2))
        stripes[y, :, 3] = 1.0
    index.append(write_document_fixture(
        "clip-mask", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": base_id, "name": "Base", "image": array_to_image(disc)},
            {"name": "Clipped", "image": array_to_image(stripes), "maskSourceID": base_id},
        ],
        "a layer clipped to the disc below it: the base's coverage limits the stripes",
    ))

    # A base at half opacity: its coverage, not just its pixels, limits the clipped layer
    # (LiveLayerMask.swift draws the base into the coverage with its effective opacity).
    soft_base = np.zeros((HEIGHT, WIDTH, 4))
    soft_base[..., 0] = quantize(np.full((HEIGHT, WIDTH), 0.9))
    soft_base[..., 1] = quantize(np.full((HEIGHT, WIDTH), 0.9))
    soft_base[..., 2] = quantize(np.full((HEIGHT, WIDTH), 0.9))
    soft_base[..., 3] = 1.0
    half_id = R.new_uuid()
    flat_red = quantize(np.zeros((HEIGHT, WIDTH, 4)))
    flat_red[..., 0] = 1.0
    flat_red[..., 1] = quantize(np.full((HEIGHT, WIDTH), 0.1))
    flat_red[..., 2] = quantize(np.full((HEIGHT, WIDTH), 0.1))
    flat_red[..., 3] = 1.0
    index.append(write_document_fixture(
        "clip-base-opacity", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": half_id, "name": "Half Base", "image": array_to_image(soft_base), "opacity": 0.5},
            {"name": "Clipped", "image": array_to_image(flat_red), "maskSourceID": half_id},
        ],
        "a clipped layer inherits the base's opacity, not only its pixels",
    ))

    # A base carrying a raster mask: the mask limits the clipped layer too, not just the base.
    base_mask = np.zeros((HEIGHT, WIDTH), dtype=np.uint8)
    base_mask[:, :] = np.linspace(0, 255, WIDTH).astype(np.uint8)[None, :]
    masked_id = R.new_uuid()
    index.append(write_document_fixture(
        "clip-base-mask", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": masked_id, "name": "Masked Base", "image": array_to_image(soft_base),
             "mask": Image.fromarray(base_mask, mode="L")},
            {"name": "Clipped", "image": array_to_image(flat_red), "maskSourceID": masked_id},
        ],
        "a clipped layer inherits the base's raster mask as well",
    ))

    mid_id = R.new_uuid()
    soft = np.zeros((HEIGHT, WIDTH, 4))
    soft[..., 0] = 1.0
    soft[..., 1] = 0.5
    soft[..., 2] = 0.1
    soft[..., 3] = np.broadcast_to(np.linspace(0.0, 1.0, WIDTH)[None, :], (HEIGHT, WIDTH))
    index.append(write_document_fixture(
        "clip-chain", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": base_id, "name": "Base", "image": array_to_image(disc)},
            {"id": mid_id, "name": "Middle", "image": array_to_image(soft), "maskSourceID": base_id},
            {"name": "Top", "image": array_to_image(stripes), "maskSourceID": mid_id, "opacity": 0.75},
        ],
        "a clipping chain of three layers: each coverage multiplies into the layer above",
    ))

    folder_mask = Image.fromarray(np.linspace(0, 255, WIDTH).astype(np.uint8)[None, :].repeat(HEIGHT, 0), mode="L")
    folder_id = R.new_uuid()
    index.append(write_document_fixture(
        "group-mask", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": folder_id, "name": "Masked Folder", "isGroup": True, "opacity": 1.0,
             "mask": folder_mask, "transform": full_transform(WIDTH, HEIGHT)},
            {"name": "Inside A", "image": array_to_image(layer_a), "parentID": folder_id},
            {"name": "Inside B", "image": array_to_image(layer_b), "parentID": folder_id},
        ],
        "a folder mask multiplies the coverage of every layer inside it",
    ))

    index.append(write_document_fixture(
        "flip-horizontal", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {
                "name": "Mirrored",
                "image": array_to_image(source),
                "transform": {**full_transform(WIDTH, HEIGHT), "flipX": True},
            },
        ],
        "an upright layer drawn with flipX mirrors inside its box",
    ))

    index.append(write_document_fixture(
        "hidden-layer", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"name": "Hidden", "image": array_to_image(source), "visible": False},
            {"name": "Visible", "image": array_to_image(layer_a)},
        ],
        "a hidden layer contributes nothing, the layers around it still composite",
    ))

    outer_id = R.new_uuid()
    inner_id = R.new_uuid()
    index.append(write_document_fixture(
        "nested-groups", WIDTH, HEIGHT,
        [
            {"name": "Backdrop", "image": array_to_image(backdrop)},
            {"id": outer_id, "name": "Outer", "isGroup": True, "opacity": 0.5,
             "transform": full_transform(WIDTH, HEIGHT)},
            {"id": inner_id, "name": "Inner", "isGroup": True, "opacity": 0.5,
             "parentID": outer_id, "transform": full_transform(WIDTH, HEIGHT)},
            {"name": "Leaf", "image": array_to_image(stripes), "parentID": inner_id, "opacity": 0.5},
        ],
        "nested folders at 50% each put the leaf at 12.5%",
    ))

    with open(os.path.join(FIXTURES, "index.json"), "w", encoding="utf-8") as handle:
        json.dump({"fixtures": index}, handle, indent=2)
    print(f"wrote {len(index)} fixtures to {FIXTURES}")


if __name__ == "__main__":
    main()
