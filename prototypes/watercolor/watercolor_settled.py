#!/usr/bin/env python3
"""Small deterministic, post-stroke watercolor study; uses only Pillow and NumPy."""

from __future__ import annotations

import math
from pathlib import Path

import numpy as np
from PIL import Image, ImageChops, ImageDraw, ImageFilter, ImageFont


ROOT = Path(__file__).resolve().parent
OUTPUT = ROOT / "settled_stroke_exercises.png"
WIDTH, HEIGHT = 1600, 1000
PANEL_W, PANEL_H, GAP = 372, 790, 20


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    path = "/System/Library/Fonts/Supplemental/Arial Bold.ttf" if bold else "/System/Library/Fonts/Supplemental/Arial.ttf"
    try:
        return ImageFont.truetype(path, size)
    except OSError:
        return ImageFont.load_default(size=size)


def noise_field(width: int, height: int, rng: np.random.Generator, cell: int) -> np.ndarray:
    grid = rng.random((max(2, math.ceil(height / cell)), max(2, math.ceil(width / cell))))
    image = Image.fromarray(np.uint8(grid * 255), "L").resize((width, height), Image.Resampling.BICUBIC)
    values = np.asarray(image, dtype=np.float32) / 255
    return values - values.mean()


def paper(width: int, height: int, seed: int) -> tuple[Image.Image, np.ndarray]:
    rng = np.random.default_rng(seed)
    coarse = noise_field(width, height, rng, 34)
    medium = noise_field(width, height, rng, 9)
    fine = rng.normal(0, 1, (height, width)).astype(np.float32)
    grain = np.clip(0.5 + coarse * 0.8 + medium * 0.42 + fine * 0.035, 0, 1)
    base = 248 - grain * 11
    rgb = np.stack((base + 2, base + 1, base - 3), axis=-1).clip(0, 255).astype(np.uint8)
    return Image.fromarray(rgb, "RGB"), grain


def path_samples(controls: list[tuple[float, float, float]], step: float = 2.25) -> np.ndarray:
    result: list[tuple[float, float, float]] = []
    for index in range(len(controls) - 1):
        p0 = controls[max(0, index - 1)]
        p1 = controls[index]
        p2 = controls[index + 1]
        p3 = controls[min(len(controls) - 1, index + 2)]
        length = math.hypot(p2[0] - p1[0], p2[1] - p1[1])
        count = max(1, math.ceil(length / step))
        for index in range(count):
            t = index / count
            t2, t3 = t * t, t * t * t
            point = [0.5 * ((2 * p1[axis]) + (-p0[axis] + p2[axis]) * t
                    + (2 * p0[axis] - 5 * p1[axis] + 4 * p2[axis] - p3[axis]) * t2
                    + (-p0[axis] + 3 * p1[axis] - 3 * p2[axis] + p3[axis]) * t3) for axis in range(2)]
            eased = t2 * (3 - 2 * t)
            pressure = p1[2] * (1 - eased) + p2[2] * eased
            result.append((point[0], point[1], pressure))
    result.append(controls[-1])
    return np.asarray(result, dtype=np.float32)


def correlated_noise(count: int, rng: np.random.Generator, interval: int) -> np.ndarray:
    anchors = rng.normal(0, 1, max(2, math.ceil(count / interval) + 1))
    x = np.linspace(0, len(anchors) - 1, count)
    return np.interp(x, np.arange(len(anchors)), anchors).astype(np.float32)


def stroke_mask(size: tuple[int, int], controls: list[tuple[float, float, float]], seed: int,
                variation: float = 1.0) -> Image.Image:
    width, height = size
    samples = path_samples(controls)
    points = samples[:, :2]
    radii = np.maximum(1, samples[:, 2] * 0.5)
    tangent = np.empty_like(points)
    tangent[1:-1] = points[2:] - points[:-2]
    tangent[0] = points[1] - points[0]
    tangent[-1] = points[-1] - points[-2]
    tangent /= np.maximum(1e-4, np.linalg.norm(tangent, axis=1, keepdims=True))
    normal = np.stack((-tangent[:, 1], tangent[:, 0]), axis=1)

    rng = np.random.default_rng(seed)
    n = len(points)
    fractal = (correlated_noise(n, rng, 7) * 0.47
               + correlated_noise(n, rng, 23) * 0.34
               + correlated_noise(n, rng, 65) * 0.19)
    sideShift = fractal * variation * np.minimum(5.0, radii * 0.22)
    widthNoise = correlated_noise(n, rng, 17) * variation * 0.065
    center = points + normal * sideShift[:, None]
    variedRadius = radii * np.clip(1 + widthNoise, 0.82, 1.18)
    leftGrain = (correlated_noise(n, rng, 2) * 0.24 + correlated_noise(n, rng, 5) * 0.28
                 + correlated_noise(n, rng, 18) * 0.30 + correlated_noise(n, rng, 48) * 0.18)
    rightGrain = (correlated_noise(n, rng, 2) * 0.24 + correlated_noise(n, rng, 6) * 0.27
                  + correlated_noise(n, rng, 20) * 0.30 + correlated_noise(n, rng, 52) * 0.19)
    leftRadius = np.maximum(0.8, variedRadius + leftGrain * variation * np.minimum(6.0, radii * 0.36))
    rightRadius = np.maximum(0.8, variedRadius + rightGrain * variation * np.minimum(6.0, radii * 0.36))
    left = center + normal * leftRadius[:, None]
    right = center - normal * rightRadius[:, None]
    outline = np.concatenate((left, right[::-1]), axis=0)

    mask = Image.new("L", (width, height), 0)
    draw = ImageDraw.Draw(mask)
    draw.polygon([tuple(p) for p in outline], fill=255)
    # Round caps preserve the dab and lift shapes of a real round brush.
    for p, radius in ((points[0], radii[0]), (points[-1], radii[-1])):
        draw.ellipse((p[0] - radius, p[1] - radius, p[0] + radius, p[1] + radius), fill=255)
    return mask.filter(ImageFilter.GaussianBlur(0.45))


def pooled_edge(mask: Image.Image, grain: np.ndarray, strength: float, seed: int) -> Image.Image:
    solid = mask.point(lambda value: 255 if value > 30 else 0)
    width, height = mask.size
    depth = np.zeros((height, width), dtype=np.float32)
    current = solid
    maximumDepth = 30
    for distance in range(1, maximumDepth + 1):
        eroded = current.filter(ImageFilter.MinFilter(3))
        removed = np.asarray(ImageChops.subtract(current, eroded), dtype=np.uint8)
        depth[(removed > 0) & (depth == 0)] = distance
        current = eroded
    remaining = np.asarray(current, dtype=np.uint8) > 0
    depth[remaining] = maximumDepth + 1

    # A seeded multiscale field controls how far each irregular edge section
    # reaches inward. The distance field keeps the pigment attached to the edge.
    rng = np.random.default_rng(seed)
    broad = noise_field(width, height, rng, 27)
    fine = noise_field(width, height, rng, 8)
    spikeNoise = np.clip(0.5 + broad * 4.5 + fine * 0.85, 0, 1)
    maximumReach = min(20.0, max(4.0, float(depth.max()) * 0.38))
    reach = 2.5 + maximumReach * np.power(spikeNoise, 2.8)

    # Pooling reaches farther inward at selected contour locations, then fades
    # smoothly so the middle remains controlled by the brush's separate wash mix.
    normalized = np.clip((reach - depth) / 5.5, 0, 1)
    taper = normalized * normalized * (3 - 2 * normalized)
    falloff = np.exp(-depth / (2.8 + maximumReach * 0.3))
    interior = np.asarray(solid, dtype=np.float32) / 255
    paperFactor = np.clip(0.66 + (grain - 0.5) * 0.42, 0.42, 0.9)
    boundaryDepth = np.maximum(0, depth - 1)
    continuousRim = 0.54 * np.exp(-boundaryDepth / 2.8)
    inwardSpikes = taper * falloff * (0.35 + 0.55 * np.power(spikeNoise, 1.5))
    pool = np.clip(continuousRim + inwardSpikes * 0.8, 0, 1)
    alpha = np.uint8(np.clip(interior * pool * paperFactor * strength, 0, 1) * 255)
    return Image.fromarray(alpha, "L")


def paint_stroke(canvas: Image.Image, paper_grain: np.ndarray,
                 controls: list[tuple[float, float, float]], color: tuple[int, int, int],
                 seed: int, wetness: float = 0.4, edge_strength: float = 0.7,
                 variations: int = 18) -> Image.Image:
    size = canvas.size
    # The base polygon is deformed once, then deterministic low-opacity variants
    # build a layered silhouette, following the Sighack construction at lower cost.
    accumulated = np.zeros((size[1], size[0]), dtype=np.float32)
    for layer in range(variations):
        layer_seed = seed + layer * 7919
        mask = stroke_mask(size, controls, layer_seed, variation=0.45 + 0.75 * (layer / max(1, variations - 1)))
        m = np.asarray(mask, dtype=np.float32) / 255
        texture = np.clip(0.83 + (paper_grain - 0.5) * 0.42, 0.55, 1.08)
        opacity = 0.062 if layer == 0 else 0.043
        accumulated = 1 - (1 - accumulated) * (1 - m * texture * opacity)

    # The wash is a distinct, softer field underneath the more concentrated pigment.
    pigment_alpha = np.clip(accumulated * (0.79 - 0.34 * wetness), 0, 0.82)
    pigment_mask = Image.fromarray(np.uint8(pigment_alpha * 255), "L")
    raw_shape = stroke_mask(size, controls, seed ^ 0x51A7, variation=0.55)
    wash = raw_shape.filter(ImageFilter.GaussianBlur(1.5 + wetness * 5.0))
    wash_alpha = np.asarray(wash, dtype=np.float32) / 255 * (0.11 + 0.13 * wetness)

    rgba = np.zeros((size[1], size[0], 4), dtype=np.uint8)
    rgba[..., :3] = color
    rgba[..., 3] = np.uint8(np.clip(wash_alpha, 0, 1) * 255)
    canvas.alpha_composite(Image.fromarray(rgba, "RGBA"))

    pigment = Image.new("RGBA", size, (*color, 0))
    pigment.putalpha(pigment_mask)
    canvas.alpha_composite(pigment)

    # This pass only runs after the whole stroke exists. It pools pigment at a
    # roughened paper-contact edge instead of punching holes through the wash.
    edge_alpha = pooled_edge(pigment_mask, paper_grain, edge_strength, seed ^ 0xA77E)
    dark = tuple(round(channel * 0.4) for channel in color)
    rim = Image.new("RGBA", size, (*dark, 0))
    rim.putalpha(edge_alpha)
    canvas.alpha_composite(rim)
    return raw_shape


def rewet(canvas: Image.Image, paper_grain: np.ndarray, controls: list[tuple[float, float, float]], seed: int) -> None:
    # Clear water adds no new pigment: after mouse-up, it reactivates and spreads
    # pigment already below it, with the paper texture modulating the local flow.
    wet_mask = stroke_mask(canvas.size, controls, seed, variation=0.8)
    wet_mask = wet_mask.filter(ImageFilter.GaussianBlur(4.5))
    original = canvas.convert("RGB")
    softened = original.filter(ImageFilter.GaussianBlur(7.0))
    shifted = softened.transform(softened.size, Image.Transform.AFFINE, (1, 0, -4, 0, 1, 3),
                                 resample=Image.Resampling.BILINEAR)
    mixed = Image.blend(softened, shifted, 0.36)
    mixed_array = np.asarray(mixed, dtype=np.float32)
    paper_value = 248 - paper_grain * 11
    paper_array = np.stack((paper_value + 2, paper_value + 1, paper_value - 3), axis=-1)
    dilution = np.clip(0.09 + (paper_grain - 0.5) * 0.16, 0.02, 0.18)[..., None]
    mixed_array = mixed_array * (1 - dilution) + paper_array * dilution
    moved = Image.fromarray(np.uint8(np.clip(mixed_array, 0, 255)), "RGB").convert("RGBA")
    canvas.alpha_composite(Image.composite(moved, canvas, wet_mask))

    # Rewetting breaks the old dry rim; pooling forms again along the new water edge.
    wash_edge = pooled_edge(wet_mask, paper_grain, 0.35, seed ^ 0xB10F)
    blue_rim = Image.new("RGBA", canvas.size, (23, 69, 105, 0))
    blue_rim.putalpha(wash_edge)
    canvas.alpha_composite(blue_rim)


def add_panel(canvas: Image.Image, x: int, title: str, subtitle: str, seed: int) -> tuple[Image.Image, np.ndarray, tuple[int, int]]:
    panel = Image.new("RGBA", (PANEL_W, PANEL_H), (255, 255, 255, 0))
    panel_draw = ImageDraw.Draw(panel)
    panel_draw.rounded_rectangle((0, 0, PANEL_W - 1, PANEL_H - 1), radius=18,
                                 fill=(251, 250, 246, 240), outline=(220, 218, 210, 255), width=2)
    panel_draw.text((22, 20), title, font=font(23, True), fill=(35, 47, 55, 255))
    panel_draw.text((22, 54), subtitle, font=font(14), fill=(96, 105, 108, 255))
    canvas.alpha_composite(panel, (x, 80))
    work, grain = paper(PANEL_W - 30, PANEL_H - 120, seed)
    work = work.convert("RGBA")
    canvas.alpha_composite(work, (x + 15, 174))
    return work, grain, (x + 15, 174)


def main() -> None:
    result, _ = paper(WIDTH, HEIGHT, 183)
    result = result.convert("RGBA")
    draw = ImageDraw.Draw(result)
    draw.text((28, 20), "WATERCOLOR · SETTLED-STROKE PROTOTYPE", font=font(25, True), fill=(38, 49, 56))
    draw.text((28, 53), "Seeded layered shape + paper-sensitive wash + one post-stroke pooling pass",
              font=font(15), fill=(101, 108, 110))

    panels = [
        ("01  Straight line", "continuous edge · light load", 220),
        ("02  Thin → thick → thin", "pressure changes the silhouette", 447),
        ("03  Dab, turn, pull", "round-brush lift and direction", 669),
        ("04  Clear-water rewet", "wash moves pigment already down", 891),
    ]
    locations: list[tuple[Image.Image, np.ndarray, tuple[int, int]]] = []
    for index, (title, subtitle, seed) in enumerate(panels):
        x = 20 + index * (PANEL_W + GAP)
        locations.append(add_panel(result, x, title, subtitle, seed))

    blue = (38, 100, 144)
    ochre = (166, 93, 44)
    panel, grain, (ox, oy) = locations[0]
    paint_stroke(panel, grain, [(42, 285, 13), (300, 285, 13)], blue, 1001, wetness=0.58, edge_strength=0.76)
    ImageDraw.Draw(panel).text((45, 342), "single pass", font=font(15), fill=(90, 98, 99, 220))
    result.alpha_composite(panel, (ox, oy))

    panel, grain, (ox, oy) = locations[1]
    paint_stroke(panel, grain, [(35, 285, 7), (92, 285, 20), (150, 285, 46),
                                (220, 285, 46), (278, 285, 20), (325, 285, 7)],
                 blue, 2002, wetness=0.52, edge_strength=0.76)
    ImageDraw.Draw(panel).text((45, 354), "low pressure     full pressure     lift", font=font(14), fill=(90, 98, 99, 220))
    result.alpha_composite(panel, (ox, oy))

    panel, grain, (ox, oy) = locations[2]
    paint_stroke(panel, grain, [(82, 430, 49), (154, 404, 43), (214, 349, 33), (263, 284, 21), (296, 218, 6)],
                 ochre, 3003, wetness=0.38, edge_strength=0.8)
    ImageDraw.Draw(panel).text((45, 500), "press · turn · release", font=font(15), fill=(90, 98, 99, 220))
    result.alpha_composite(panel, (ox, oy))

    panel, grain, (ox, oy) = locations[3]
    # A broad, layered blue pigment wash with a settled edge.
    paint_stroke(panel, grain, [(32, 310, 87), (336, 310, 87)], blue, 4004, wetness=0.28, edge_strength=0.82)
    rewet(panel, grain, [(75, 374, 24), (196, 366, 31), (316, 348, 18)], 4005)
    ImageDraw.Draw(panel).text((45, 455), "clear water reactivates and dilutes", font=font(14), fill=(90, 98, 99, 220))
    result.alpha_composite(panel, (ox, oy))

    result.convert("RGB").save(OUTPUT, quality=95)
    print(OUTPUT)


if __name__ == "__main__":
    main()
