"""The six layer effects, transcribed from LayerEffectsRenderer.

The macOS export path (compositor_mac/Compositor/Document/LayerEffects.swift) builds a padded
surface the size of the layer plus LayerEffectsRenderer.margin, lays the effects down in this
order, and hands the result back with the inset the caller grows the transform by:

  1 drop shadow          shape moved by the light offset, softened
  2 outer glow           shape softened all round, less the shape
  3 stroke (outside)     dilated shape less the shape
  4 the layer's pixels   source-over, so effects under transparent pixels survive
  5 color overlay        flat color through the shape
  6 inner glow           shape less the shape softened inward
  7 inner shadow         shape less the moved, softened shape
  8 stroke (inside)      shape less the eroded shape

The soften step is CIGaussianBlur(sigma: blur / 2) with clampedToExtent, and every coverage
passes through an 8-bit gray context (GuidedMatte.levels/image), so values quantize to bytes.
Blurred coverage is therefore where a different blur kernel shows up; the unblurred effects
(stroke, color overlay) are formula-exact and are the strong checks.
"""

from __future__ import annotations

import math

import numpy as np

from oracle_core import (
    fill_over_premul,
    gaussian_blur_plane,
    morph_extreme,
    round_half_up,
)

KINDS = ["stroke", "shadow", "colorOverlay", "innerShadow", "outerGlow", "innerGlow"]


def _enabled(effects, kind):
    entry = effects.get(kind)
    if entry is None:
        return None
    if entry.get("enabled", True) is False:
        return None
    return entry


def visible(effects):
    return {kind: value for kind in KINDS if (value := _enabled(effects, kind)) is not None}


def margin(effects) -> int:
    """LayerEffectsRenderer.margin: what the effects reach beyond the layer's own pixels."""
    shown = visible(effects)
    reach = 0.0
    stroke = shown.get("stroke")
    if stroke is not None and not stroke.get("inside", False):
        reach = max(reach, float(stroke.get("size", 4.0)))
    shadow = shown.get("shadow")
    if shadow is not None:
        reach = max(reach, float(shadow.get("distance", 20.0)) + float(shadow.get("blur", 20.0)) * 3.0)
    glow = shown.get("outerGlow")
    if glow is not None:
        reach = max(reach, float(glow.get("size", 20.0)) * 3.0)
    return int(math.ceil(reach)) + 2


def shadow_offset(effect):
    """ShadowEffect.offset: the shadow falls away from the light; layer pixels count y downward."""
    radians = math.radians(float(effect.get("angle", 90.0)))
    distance = float(effect.get("distance", 20.0))
    return (-math.cos(radians) * distance, math.sin(radians) * distance)


def _shape_coverage(image: np.ndarray, placed, size, blur: float) -> np.ndarray:
    """LayerEffectsRenderer.coverage: the shape's alpha in a bigger canvas, optionally softened.
    Returns the 8-bit gray levels as floats 0-1, the way GuidedMatte.levels reads them."""
    width, height = size
    # The fixtures keep every effect offset on whole pixels, so there is no resampling question:
    # a fractional offset would make Core Graphics filter the shape and blur the comparison.
    x0, y0, image_width, image_height = (int(round(placed[0])), int(round(placed[1])),
                                         int(placed[2]), int(placed[3]))
    plane = np.zeros((height, width), dtype=np.float64)
    x_start = max(0, x0)
    y_start = max(0, y0)
    x_stop = min(width, x0 + image_width)
    y_stop = min(height, y0 + image_height)
    if x_stop > x_start and y_stop > y_start:
        source = image[y_start - y0:y_stop - y0, x_start - x0:x_stop - x0, 3].astype(np.float64)
        plane[y_start:y_stop, x_start:x_stop] = source
    if blur > 0:
        # clampedToExtent() plus a Gaussian of sigma = blur / 2, then cropped back to the surface.
        plane = gaussian_blur_plane(plane, blur / 2.0, edge="clamp")
    return np.clip(round_half_up(plane), 0, 255) / 255.0


def _levels(image_levels: np.ndarray) -> np.ndarray:
    """GuidedMatte.levels: an 8-bit gray image read back as 0-1 floats."""
    return np.clip(round_half_up(image_levels * 255.0), 0, 255) / 255.0


def _to_levels(levels: np.ndarray) -> np.ndarray:
    """GuidedMatte.image: 0-1 levels quantized into an 8-bit gray image."""
    return np.clip(round_half_up(np.clip(levels, 0.0, 1.0) * 255.0), 0, 255) / 255.0


def _stroke_ring(shape: np.ndarray, stroke) -> np.ndarray:
    """LayerEffectsRenderer.strokeCoverage: a square reach, not a round one."""
    reach = max(1, int(round(float(stroke.get("size", 4.0)))))
    inside = bool(stroke.get("inside", False))
    moved = morph_extreme(shape, reach, smallest=inside)
    ring = np.maximum(0.0, shape - moved) if inside else np.maximum(0.0, moved - shape)
    return _to_levels(ring)


def render_effects(image: np.ndarray, effects: dict):
    """`image` is straight-alpha uint8 RGBA. Returns (premultiplied RGBA canvas, inset)."""
    shown_effects = visible(effects)
    inset = margin(effects)
    height, width = image.shape[:2]
    full_height, full_width = height + inset * 2, width + inset * 2
    placed = (inset, inset, width, height)
    shape = _shape_coverage(image, placed, (full_width, full_height), 0.0)
    canvas = np.zeros((full_height, full_width, 4), dtype=np.uint8)
    full = (0, 0, full_width, full_height)

    shadow = shown_effects.get("shadow")
    if shadow is not None and float(shadow.get("opacity", 0.5)) > 0:
        dx, dy = shadow_offset(shadow)
        coverage = _shape_coverage(image, (placed[0] + dx, placed[1] + dy, width, height),
                                   (full_width, full_height), float(shadow.get("blur", 20.0)))
        canvas = fill_over_premul(canvas, _color(shadow), coverage, float(shadow.get("opacity", 0.5)))

    glow = shown_effects.get("outerGlow")
    if glow is not None and float(glow.get("opacity", 0.75)) > 0:
        soft = _levels(_shape_coverage(image, placed, (full_width, full_height), float(glow.get("size", 20.0))))
        levels = np.maximum(0.0, soft * (1.0 - shape))
        canvas = fill_over_premul(canvas, _color(glow), _to_levels(levels), float(glow.get("opacity", 0.75)))

    stroke = shown_effects.get("stroke")
    if stroke is not None and float(stroke.get("size", 4.0)) > 0 and float(stroke.get("opacity", 1.0)) > 0:
        if not stroke.get("inside", False):
            canvas = fill_over_premul(canvas, _color(stroke), _stroke_ring(shape, stroke),
                                      float(stroke.get("opacity", 1.0)))

    canvas = _draw_layer(canvas, image, placed)

    overlay = shown_effects.get("colorOverlay")
    if overlay is not None and float(overlay.get("opacity", 1.0)) > 0:
        canvas = fill_over_premul(canvas, _color(overlay), shape, float(overlay.get("opacity", 1.0)))

    inner_glow = shown_effects.get("innerGlow")
    if inner_glow is not None and float(inner_glow.get("opacity", 0.75)) > 0:
        softened = _levels(_shape_coverage(image, placed, (full_width, full_height),
                                           float(inner_glow.get("size", 10.0))))
        inside = np.maximum(0.0, shape * (1.0 - softened))
        canvas = fill_over_premul(canvas, _color(inner_glow), _to_levels(inside),
                                  float(inner_glow.get("opacity", 0.75)))

    inner_shadow = shown_effects.get("innerShadow")
    if inner_shadow is not None and float(inner_shadow.get("opacity", 0.5)) > 0:
        dx, dy = shadow_offset(inner_shadow)
        moved = _levels(_shape_coverage(image, (placed[0] + dx, placed[1] + dy, width, height),
                                        (full_width, full_height), float(inner_shadow.get("blur", 10.0))))
        inside = np.maximum(0.0, shape * (1.0 - moved))
        canvas = fill_over_premul(canvas, _color(inner_shadow), _to_levels(inside),
                                  float(inner_shadow.get("opacity", 0.5)))

    if stroke is not None and float(stroke.get("size", 4.0)) > 0 and float(stroke.get("opacity", 1.0)) > 0:
        if stroke.get("inside", False):
            canvas = fill_over_premul(canvas, _color(stroke), _stroke_ring(shape, stroke),
                                      float(stroke.get("opacity", 1.0)))
    _ = full
    return canvas, inset


def _color(effect):
    return (float(effect.get("red", 0.0)) * 255.0,
            float(effect.get("green", 0.0)) * 255.0,
            float(effect.get("blue", 0.0)) * 255.0)


def _draw_layer(canvas: np.ndarray, image: np.ndarray, placed) -> np.ndarray:
    """The layer's own pixels drawn source-over, so nothing under transparent pixels is erased."""
    x0, y0, width, height = placed
    premultiplied = _premultiply(image)
    target = canvas.astype(np.float64)
    patch = premultiplied.astype(np.float64)
    inverse = 1.0 - patch[..., 3:4] / 255.0
    region = target[y0:y0 + height, x0:x0 + width, :]
    region[..., :3] = patch[..., :3] + region[..., :3] * inverse
    region[..., 3:4] = patch[..., 3:4] + region[..., 3:4] * inverse
    return np.clip(round_half_up(target), 0, 255).astype(np.uint8)


def _premultiply(image: np.ndarray) -> np.ndarray:
    straight = image.astype(np.float64)
    alpha = straight[..., 3:4]
    out = np.empty_like(straight)
    out[..., :3] = round_half_up(straight[..., :3] * alpha / 255.0)
    out[..., 3] = alpha[..., 0]
    return np.clip(out, 0, 255).astype(np.uint8)


def composite_over(backdrop_straight: np.ndarray, layer_premultiplied: np.ndarray, origin) -> np.ndarray:
    """A premultiplied RGBA patch composited over a straight-alpha backdrop, source-over."""
    height, width = backdrop_straight.shape[:2]
    backdrop = backdrop_straight.astype(np.float64)
    premultiplied = backdrop.copy()
    premultiplied[..., :3] = backdrop[..., :3] * (backdrop[..., 3:4] / 255.0)
    x0, y0 = origin
    patch_height, patch_width = layer_premultiplied.shape[:2]
    x_start, y_start = max(0, x0), max(0, y0)
    x_stop, y_stop = min(width, x0 + patch_width), min(height, y0 + patch_height)
    if x_stop > x_start and y_stop > y_start:
        patch = layer_premultiplied[y_start - y0:y_stop - y0, x_start - x0:x_stop - x0].astype(np.float64)
        region = premultiplied[y_start:y_stop, x_start:x_stop, :]
        inverse = 1.0 - patch[..., 3:4] / 255.0
        region[..., :3] = patch[..., :3] + region[..., :3] * inverse
        region[..., 3:4] = patch[..., 3:4] + region[..., 3:4] * inverse
    alpha = premultiplied[..., 3:4] / 255.0
    straight = np.zeros_like(premultiplied)
    solid = alpha > 0
    straight[..., :3] = np.where(solid, premultiplied[..., :3] / np.maximum(alpha, 1e-9), 0.0)
    straight[..., 3] = premultiplied[..., 3]
    return np.clip(round_half_up(straight), 0, 255).astype(np.uint8)
