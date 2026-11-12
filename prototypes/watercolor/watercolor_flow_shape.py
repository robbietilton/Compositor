#!/usr/bin/env python3
"""Deterministic post-stroke wash transport over a generated brush silhouette."""

from __future__ import annotations

from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont

from watercolor_settled import noise_field, paper


ROOT = Path(__file__).resolve().parent
SHAPE = ROOT / "references" / "generated_base_shape.png"
OUTPUT = ROOT / "settled_flow_shape.png"
SEED = 12027


def font(size: int, bold: bool = False) -> ImageFont.FreeTypeFont | ImageFont.ImageFont:
    name = "Arial Bold.ttf" if bold else "Arial.ttf"
    try:
        return ImageFont.truetype(f"/System/Library/Fonts/Supplemental/{name}", size)
    except OSError:
        return ImageFont.load_default(size=size)


def distance_field(mask: np.ndarray, limit: int = 90) -> np.ndarray:
    """Chamfer-like distance from each pixel to the mask boundary."""
    inside = Image.fromarray(np.uint8(mask * 255), "L")
    current = inside
    depth = np.zeros(mask.shape, dtype=np.float32)
    for step in range(1, limit + 1):
        eroded = current.filter(ImageFilter.MinFilter(3))
        removed = np.asarray(current, dtype=np.uint8) > np.asarray(eroded, dtype=np.uint8)
        depth[removed & (depth == 0)] = step
        current = eroded
    remaining = np.asarray(current, dtype=np.uint8) > 0
    depth[remaining] = limit + 1
    return depth


def normalize(x: np.ndarray, y: np.ndarray) -> tuple[np.ndarray, np.ndarray]:
    length = np.sqrt(x * x + y * y)
    return x / np.maximum(length, 1e-5), y / np.maximum(length, 1e-5)


def sample_bilinear(field: np.ndarray, x: np.ndarray, y: np.ndarray) -> np.ndarray:
    height, width = field.shape
    x = np.clip(x, 0, width - 1.001)
    y = np.clip(y, 0, height - 1.001)
    x0, y0 = x.astype(np.int32), y.astype(np.int32)
    x1, y1 = np.minimum(x0 + 1, width - 1), np.minimum(y0 + 1, height - 1)
    fx, fy = x - x0, y - y0
    return ((field[y0, x0] * (1 - fx) + field[y0, x1] * fx) * (1 - fy)
            + (field[y1, x0] * (1 - fx) + field[y1, x1] * fx) * fy)


def advect(field: np.ndarray, vx: np.ndarray, vy: np.ndarray, step: float) -> np.ndarray:
    """Semi-Lagrangian backward sampling for one settled transport substep."""
    height, width = field.shape
    yy, xx = np.mgrid[:height, :width].astype(np.float32)
    return sample_bilinear(field, xx - vx * step, yy - vy * step)


def static_pigment(mask: np.ndarray, paper_grain: np.ndarray, seed: int) -> np.ndarray:
    """Layered but stationary pigment control, using the same source silhouette."""
    rng = np.random.default_rng(seed)
    pigment = mask.astype(np.float32) * (0.56 + (paper_grain - 0.5) * 0.22)
    for cell, weight in ((42, 0.10), (16, 0.065), (6, 0.025)):
        pigment *= np.clip(1 + noise_field(mask.shape[1], mask.shape[0], rng, cell) * weight, 0.82, 1.18)
    return np.clip(pigment, 0, 0.76)


def flow_pigment(mask: np.ndarray, paper_grain: np.ndarray, seed: int) -> tuple[np.ndarray, np.ndarray, np.ndarray]:
    """Transport a suspended pigment field through a paper-sensitive wash, then fix it."""
    height, width = mask.shape
    solid = mask > 0.5
    dist_inside = distance_field(solid)
    dist_outside = distance_field(~solid)
    signed = dist_inside - dist_outside
    grad_y, grad_x = np.gradient(signed)
    outward_x, outward_y = normalize(-grad_x, -grad_y)

    # A smooth paper potential adds coherent curl to the boundary-driven flow.
    rng = np.random.default_rng(seed)
    potential = noise_field(width, height, rng, 48) * 0.72 + noise_field(width, height, rng, 19) * 0.28
    pot_y, pot_x = np.gradient(potential)
    curl_x, curl_y = normalize(pot_y, -pot_x)
    flow_x, flow_y = normalize(outward_x * 0.78 + curl_x * 0.22,
                               outward_y * 0.78 + curl_y * 0.22 + 0.12)

    # Water is broader and more mobile than the pigment it carries.
    water_image = Image.fromarray(np.uint8(mask * 255), "L").filter(ImageFilter.GaussianBlur(10))
    water = np.asarray(water_image, dtype=np.float32) / 255
    suspended = mask.astype(np.float32) * (0.68 + (paper_grain - 0.5) * 0.16)
    fixed = np.zeros_like(suspended)
    speed = np.clip(0.48 + water * 0.66 + (paper_grain - 0.5) * 0.12, 0, 1.25)
    vx, vy = flow_x * speed, flow_y * speed

    # Offscreen settling is intentionally brief. Repeated steps yield coherent
    # movement without exposing an animation or simulating a full fluid solver.
    for _ in range(9):
        water = advect(water, vx * 1.18, vy * 1.18, 1)
        water = np.asarray(Image.fromarray(np.uint8(np.clip(water, 0, 1) * 255), "L")
                          .filter(ImageFilter.GaussianBlur(0.65)), dtype=np.float32) / 255
        suspended = advect(suspended, vx, vy, 1)
        fixation = np.clip((0.028 + (paper_grain - 0.5) * 0.012) * (0.6 + water), 0.014, 0.052)
        fixed += suspended * fixation
        suspended *= 1 - fixation

    pigment = np.clip(fixed + suspended, 0, 0.86)
    # Drying concentrates pigment along the edge. A broad seeded field changes
    # inward reach; fine noise only perturbs it, so it reads as branches, not speckle.
    broad = noise_field(width, height, rng, 54)
    medium = noise_field(width, height, rng, 21)
    fine = noise_field(width, height, rng, 7)
    reach_noise = np.clip(0.5 + broad * 3.0 + medium * 1.25 + fine * 0.24, 0, 1)
    reach = 3.5 + 31.0 * np.power(reach_noise, 2.35)
    distance = np.maximum(0, dist_inside - 1)
    branch_taper = np.clip((reach - distance) / 5.5, 0, 1)
    branch_taper = branch_taper * branch_taper * (3 - 2 * branch_taper)
    inward_falloff = np.exp(-distance / (3.2 + reach * 0.33))
    continuous_rim = 0.30 * np.exp(-distance / 2.6)
    inward_spikes = branch_taper * inward_falloff * (0.30 + 0.70 * reach_noise)
    edge_pool = np.clip(continuous_rim + inward_spikes * 0.72, 0, 1) * mask
    edge_pool *= np.clip(0.70 + broad * 0.58 + medium * 0.23 + fine * 0.08, 0.28, 1.12)
    pigment = np.clip(pigment + edge_pool * water * 0.24, 0, 0.92)
    return pigment, water, edge_pool


def render(canvas: Image.Image, mask: np.ndarray, grain: np.ndarray,
           pigment: np.ndarray, water: np.ndarray, edge: np.ndarray) -> Image.Image:
    # Cool blue watercolor over warm paper; the separate pale wash carries
    # beyond the generated mask while the pigment remains concentrated inside.
    color = np.array([31, 91, 128], dtype=np.float32)
    pale = color * 0.42 + np.array([255, 255, 249], dtype=np.float32) * 0.58
    texture = np.clip(0.90 + (grain - 0.5) * 0.44, 0.68, 1.12)
    wash_alpha = np.clip(water * (0.18 + 0.18 * (1 - mask)), 0, 0.34)
    pigment_alpha = np.clip(pigment * texture * 0.78, 0, 0.72)
    edge_darkening = np.clip(edge * 0.52, 0, 0.58)

    base = np.asarray(canvas.convert("RGB"), dtype=np.float32)
    wash_rgb = base * (1 - wash_alpha[..., None]) + pale * wash_alpha[..., None]
    pigment_rgb = wash_rgb * (1 - pigment_alpha[..., None]) + color * pigment_alpha[..., None]
    pigment_rgb *= (1 - edge_darkening[..., None] * 0.72)
    output = Image.fromarray(np.uint8(np.clip(pigment_rgb, 0, 255)), "RGB")
    return output


def make_mask(size: tuple[int, int]) -> np.ndarray:
    source = Image.open(SHAPE).convert("RGB")
    red, green, blue = np.asarray(source).transpose(2, 0, 1)
    raw = np.uint8((red > 210) & (green < 70) & (blue < 70)) * 255
    image = Image.fromarray(raw, "L").resize(size, Image.Resampling.LANCZOS)
    # Preserve the generated silhouette but soften its hard pixel boundary slightly.
    image = image.filter(ImageFilter.GaussianBlur(0.55))
    return np.asarray(image, dtype=np.float32) / 255


def main() -> None:
    panel_size = (700, 710)
    sheet = Image.new("RGB", (2200, 870), (244, 243, 238))
    draw = ImageDraw.Draw(sheet)
    draw.text((28, 18), "SETTLED WATERCOLOR · GENERATED SILHOUETTE + PAPER-SENSITIVE FLOW",
              font=font(24, True), fill=(34, 47, 56))
    draw.text((28, 51), "Same generated mask in each panel · blue pigment, pale wash, one deterministic settling pass",
              font=font(15), fill=(93, 103, 109))

    paper_image, _ = paper(*panel_size, seed=SEED)
    paper_rgb = paper_image.convert("RGB")
    grain = paper(*panel_size, seed=SEED)[1]
    mask = make_mask(panel_size)
    base = static_pigment(mask, grain, SEED)
    flowed, water, edge = flow_pigment(mask, grain, SEED)

    panels = [("Generated base shape", None),
              ("Layered pigment · no transport", (base, np.zeros_like(base), np.zeros_like(base))),
              ("Paper-sensitive flow + settling", (flowed, water, edge))]
    for index, (title, fields) in enumerate(panels):
        x = 20 + index * 730
        draw.rounded_rectangle((x, 83, x + 710, 850), radius=18,
                               fill=(252, 251, 247), outline=(219, 218, 211), width=2)
        draw.text((x + 20, 98), title, font=font(19, True), fill=(34, 47, 56))
        if fields is None:
            red = np.zeros((*mask.shape, 3), dtype=np.uint8)
            red[..., 0] = 255
            red[..., 1] = 5
            red[..., 2] = 8
            rendered = Image.fromarray(np.uint8(np.clip(mask[..., None] * red, 0, 255)), "RGB")
            background = np.asarray(paper_rgb, dtype=np.float32)
            shape = np.asarray(rendered, dtype=np.float32)
            alpha = mask[..., None]
            rendered = Image.fromarray(np.uint8(shape * alpha + background * (1 - alpha)), "RGB")
        else:
            rendered = render(paper_rgb, mask, grain, *fields)
        sheet.paste(rendered, (x + 5, 130))

    sheet.save(OUTPUT)
    # Small runnable regression check: deterministic replay and a bounded wash halo.
    check_again, check_water, check_edge = flow_pigment(mask, grain, SEED)
    assert np.array_equal(flowed, check_again)
    assert np.isfinite(flowed).all() and np.isfinite(check_water).all() and np.isfinite(check_edge).all()
    assert flowed.max() <= 0.92 and check_water.min() >= 0
    outside = mask < 0.01
    assert check_water[outside].max() > 0.01 and check_again[outside].max() > 0.01
    print(f"saved {OUTPUT}; shape coverage={mask.mean():.3f}; pigment range={flowed.min():.3f}..{flowed.max():.3f}; wash max={water.max():.3f}; outside wash={water[outside].max():.3f}")


if __name__ == "__main__":
    main()
