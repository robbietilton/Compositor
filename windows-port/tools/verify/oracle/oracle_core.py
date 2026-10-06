"""Shared primitives for the adjustment/effect oracle.

Every kernel in this package is transcribed from the macOS sources, never from the Windows
crate: the pixel loops come from compositor_mac/Compositor/Rendering/AdjustPixels.c,
LevelsPixels.c and NoisePixels.c, and the settings, ranges and identity semantics from
compositor_mac/Compositor/Document/{LayerAdjustment,Levels,Curves,ImageAdjustments,
HueSaturation,LayerEffects}.swift. Adjustments and blends run on sRGB-encoded values, as
SeparableBlend.swift states, so nothing here converts to linear light unless the kernel
itself does (Exposure).

Images are uint8 arrays shaped (H, W, 4) holding *premultiplied* RGBA, which is what the C
kernels take. Straight-alpha helpers convert at the package boundary.
"""

from __future__ import annotations

import numpy as np
from PIL import Image

# The C kernels round half away from zero; numpy's rint rounds half to even. Every value
# here is non-negative, so floor(x + 0.5) is the same thing without the tie surprise.
def round_half_up(x: np.ndarray) -> np.ndarray:
    return np.floor(np.asarray(x, dtype=np.float64) + 0.5)


def load_rgba(path) -> np.ndarray:
    """A PNG as straight-alpha uint8 (H, W, 4)."""
    with Image.open(path) as image:
        return np.asarray(image.convert("RGBA"), dtype=np.uint8)


def save_rgba(path, rgba: np.ndarray) -> None:
    Image.fromarray(np.asarray(rgba, dtype=np.uint8), mode="RGBA").save(path)


def straight_to_premul(rgba: np.ndarray) -> np.ndarray:
    """Straight RGBA to premultiplied RGBA the way an 8-bit sRGB buffer stores it."""
    straight = rgba.astype(np.float64)
    alpha = straight[..., 3:4]
    premultiplied = np.empty_like(straight)
    premultiplied[..., :3] = round_half_up(straight[..., :3] * alpha / 255.0)
    premultiplied[..., 3] = alpha[..., 0]
    return np.clip(premultiplied, 0, 255).astype(np.uint8)


def premul_to_straight(rgba: np.ndarray) -> np.ndarray:
    """Premultiplied RGBA to straight RGBA for PNG storage."""
    alpha = rgba[..., 3].astype(np.float64)
    out = np.zeros_like(rgba, dtype=np.float64)
    solid = alpha > 0
    scale = np.where(solid, 255.0 / np.maximum(alpha, 1.0), 0.0)
    for channel in range(3):
        out[..., channel] = np.where(solid, np.minimum(255.0, rgba[..., channel] * scale), 0.0)
    out[..., 3] = alpha
    return np.clip(round_half_up(out), 0, 255).astype(np.uint8)


def unpremul_rgb255(pixels: np.ndarray) -> np.ndarray:
    """The C kernels' fmin(255, p[c] * 255 / alpha), as float 0-255; black where alpha is 0."""
    alpha = pixels[..., 3].astype(np.float64)
    safe = np.maximum(alpha, 1.0)
    rgb = pixels[..., :3].astype(np.float64) * 255.0 / safe[..., None]
    return np.where(alpha[..., None] > 0, np.minimum(255.0, rgb), 0.0)


def write_premul(pixels: np.ndarray, rgb255: np.ndarray, alpha: np.ndarray) -> None:
    """The C kernels' write_premultiplied: min(alpha, max(0, round(value * alpha))) per channel."""
    values = np.clip(rgb255, 0.0, 255.0) * alpha[..., None] / 255.0
    out = np.minimum(alpha[..., None], np.maximum(0.0, round_half_up(values)))
    pixels[..., :3] = out.astype(np.uint8)


# ---------------------------------------------------------------------------------------------
# Lookup tables
# ---------------------------------------------------------------------------------------------


def lut_apply(pixels: np.ndarray, tables: np.ndarray) -> np.ndarray:
    """LevelsPixels.c levels_apply: per channel a 256-entry float table, linearly interpolated
    between the two nearest entries, on the color divided by its alpha and multiplied back."""
    result = pixels.copy()
    active = pixels[..., 3] > 0
    x = np.zeros(pixels.shape[:2] + (3,), dtype=np.float64)
    x[active] = unpremul_rgb255(pixels)[active]
    lo = np.clip(x.astype(np.int64), 0, 255)
    hi = np.minimum(lo + 1, 255)
    for channel in range(3):
        table = tables[channel]
        value = table[lo[..., channel]] + (table[hi[..., channel]] - table[lo[..., channel]]) * (x[..., channel] - lo[..., channel])
        # The table holds fractions of full scale, so the write is round(value * alpha), as in
        # LevelsPixels.c; alpha 255 turns the fraction straight back into a byte.
        result[..., channel] = np.where(
            active,
            np.minimum(pixels[..., 3], np.maximum(0.0, round_half_up(value * pixels[..., 3].astype(np.float64)))),
            pixels[..., channel],
        ).astype(np.uint8)
    return result


# ---------------------------------------------------------------------------------------------
# Color cubes: the macOS canvas runs several adjustments through a 33-cube, so the oracle can
# decide whether a difference is a wrong formula or only the cube's interpolation error.
# ---------------------------------------------------------------------------------------------


def build_cube(dimension: int, fn) -> np.ndarray:
    """`fn` maps an (n, n, n, 3) float RGB lattice to adjusted RGB in 0-1, indexed [blue, green, red]."""
    step = float(dimension - 1)
    axis = np.arange(dimension) / step
    red, green, blue = np.meshgrid(axis, axis, axis, indexing="ij")
    lattice = np.stack([red, green, blue], axis=-1)  # [r, g, b] index order
    lattice = np.transpose(lattice, (2, 1, 0, 3))  # [b, g, r] like the Swift builder
    return np.asarray(fn(lattice), dtype=np.float64)


def cube_apply(pixels: np.ndarray, cube: np.ndarray) -> np.ndarray:
    """LevelsPixels.c cube_apply: trilinear blend between the eight nearest cube entries."""
    n = cube.shape[0]
    scale = (n - 1) / 255.0
    result = pixels.copy()
    active = pixels[..., 3] > 0
    position = np.zeros(pixels.shape[:2] + (3,), dtype=np.float64)
    position[active] = unpremul_rgb255(pixels)[active] * scale
    lo = np.minimum(position.astype(np.int64), n - 2)
    fraction = position - lo
    r0, g0, b0 = lo[..., 0], lo[..., 1], lo[..., 2]
    fr, fg, fb = fraction[..., 0:1], fraction[..., 1:2], fraction[..., 2:3]

    def corner(dr, dg, db):
        return cube[b0 + db, g0 + dg, r0 + dr]

    x00 = corner(0, 0, 0) + (corner(1, 0, 0) - corner(0, 0, 0)) * fr
    x10 = corner(0, 1, 0) + (corner(1, 1, 0) - corner(0, 1, 0)) * fr
    x01 = corner(0, 0, 1) + (corner(1, 0, 1) - corner(0, 0, 1)) * fr
    x11 = corner(0, 1, 1) + (corner(1, 1, 1) - corner(0, 1, 1)) * fr
    y0 = x00 + (x10 - x00) * fg
    y1 = x01 + (x11 - x01) * fg
    value = (y0 + (y1 - y0) * fb) * 255.0
    for channel in range(3):
        result[..., channel] = np.where(
            active,
            np.minimum(pixels[..., 3], np.maximum(0.0, round_half_up(value[..., channel] * pixels[..., 3].astype(np.float64) / 255.0))),
            pixels[..., channel],
        ).astype(np.uint8)
    return result


# ---------------------------------------------------------------------------------------------
# Blur and morphology
# ---------------------------------------------------------------------------------------------


def _gaussian_kernel(sigma: float) -> np.ndarray:
    radius = max(1, int(np.ceil(sigma * 4.0)))
    offsets = np.arange(-radius, radius + 1, dtype=np.float64)
    weights = np.exp(-0.5 * (offsets / sigma) ** 2)
    return weights / weights.sum()


def gaussian_blur_plane(plane: np.ndarray, sigma: float, edge: str = "zero") -> np.ndarray:
    """Separable Gaussian over one float plane. `zero` pads with transparent black, which is what
    CIGaussianBlur does; `clamp` repeats the edge, which is what clampedToExtent() does."""
    if sigma <= 0:
        return plane.copy()
    kernel = _gaussian_kernel(sigma)
    radius = (kernel.size - 1) // 2
    pad = ((radius, radius), (radius, radius))
    padded = np.pad(plane, pad, mode="constant" if edge == "zero" else "edge")
    row = np.apply_along_axis(lambda line: np.convolve(line, kernel, mode="valid"), 1, padded)
    out = np.apply_along_axis(lambda line: np.convolve(line, kernel, mode="valid"), 0, row)
    return out


def gaussian_blur_premul(pixels: np.ndarray, sigma: float, edge: str = "zero") -> np.ndarray:
    """CIGaussianBlur semantics on premultiplied RGBA: every channel including alpha is blurred."""
    work = pixels.astype(np.float64)
    out = np.empty_like(work)
    for channel in range(4):
        out[..., channel] = gaussian_blur_plane(work[..., channel], sigma, edge)
    return np.clip(round_half_up(out), 0, 255).astype(np.uint8)


def motion_streak(pixels: np.ndarray, distance: float, angle_deg: float, edge: str = "zero") -> np.ndarray:
    """An even streak of `distance` along the motion direction on premultiplied RGBA, as
    Photoshop smears. `angle_deg` runs counterclockwise from horizontal on a y-down image, so
    +angle streaks toward up-right: the row offset is -sin(angle) per pixel along the row axis."""
    length = max(1, int(round(distance)))
    radians = np.deg2rad(angle_deg)
    weights = np.zeros((length, length), dtype=np.float64)
    # Sample the segment at `length` points and scatter them into the pixel kernel.
    steps = np.arange(length, dtype=np.float64) / max(1, length - 1) - 0.5
    dx = steps * np.cos(radians) * (distance - 1)
    dy = -steps * np.sin(radians) * (distance - 1)
    for x, y in zip(dx, dy):
        col = int(np.floor(x + 0.5)) + length // 2
        row = int(np.floor(y + 0.5)) + length // 2
        if 0 <= row < length and 0 <= col < length:
            weights[row, col] += 1.0
    if weights.sum() <= 0:
        weights[length // 2, length // 2] = 1.0
    weights /= weights.sum()
    radius = length // 2
    pad = ((radius, radius), (radius, radius))
    mode = "constant" if edge == "zero" else "edge"
    work = pixels.astype(np.float64)
    out = np.empty_like(work)
    for channel in range(4):
        padded = np.pad(work[..., channel], pad, mode=mode)
        accumulated = np.zeros(work.shape[:2], dtype=np.float64)
        for row in range(length):
            for col in range(length):
                weight = weights[row, col]
                if weight == 0.0:
                    continue
                accumulated += weight * padded[row:row + work.shape[0], col:col + work.shape[1]]
        out[..., channel] = accumulated
    return np.clip(round_half_up(out), 0, 255).astype(np.uint8)


def morph_extreme(source: np.ndarray, reach: int, smallest: bool) -> np.ndarray:
    """LayerEffectsRenderer.extreme: a separable square sliding window, truncated at the image
    edge, whose erosion also reports zero outside the window."""
    height, width = source.shape
    radius = max(0, int(reach))
    if radius == 0:
        return source.copy()

    def sweep(lines: int, count: int, line_step: int, element_step: int, data: np.ndarray) -> np.ndarray:
        output = np.zeros_like(data)
        flat = data.reshape(-1)
        target = output.reshape(-1)
        for line in range(lines):
            base = line * line_step
            for center in range(count):
                start = max(0, center - radius)
                stop = min(count - 1, center + radius)
                window = flat[base + np.arange(start, stop + 1) * element_step]
                outside = center < radius or center + radius >= count
                if smallest and outside:
                    target[base + center * element_step] = 0.0
                else:
                    target[base + center * element_step] = window.min() if smallest else window.max()
        return output

    pass_one = sweep(height, width, width, 1, source)
    return sweep(width, height, 1, width, pass_one)


# ---------------------------------------------------------------------------------------------
# Fills that the effect renderer uses to lay a color through coverage
# ---------------------------------------------------------------------------------------------


def fill_over_premul(canvas: np.ndarray, color255, coverage: np.ndarray, opacity: float) -> np.ndarray:
    """LayerEffectsRenderer.fill: source-over of a solid color through grayscale coverage at a
    uniform alpha, on the 8-bit premultiplied surface (so each fill quantizes, as CG does)."""
    out = canvas.astype(np.float64)
    source_alpha = np.clip(coverage.astype(np.float64) * float(opacity), 0.0, 1.0)[..., None]
    color = np.asarray(color255, dtype=np.float64).reshape(1, 1, 3)
    source_premul = color * source_alpha
    out[..., :3] = source_premul + out[..., :3] * (1.0 - source_alpha)
    out[..., 3:4] = source_alpha * 255.0 + out[..., 3:4] * (1.0 - source_alpha)
    return np.clip(round_half_up(out), 0, 255).astype(np.uint8)


def draw_over_premul(canvas: np.ndarray, image: np.ndarray, rect) -> np.ndarray:
    """Source-over of a premultiplied RGBA image into a premultiplied surface at `rect`."""
    out = canvas.astype(np.float64)
    x0, y0, width, height = rect
    patch = image.astype(np.float64)
    target = out[y0:y0 + height, x0:x0 + width, :]
    inverse = 1.0 - patch[..., 3:4] / 255.0
    target[..., :3] = patch[..., :3] + target[..., :3] * inverse
    target[..., 3:4] = patch[..., 3:4] + target[..., 3:4] * inverse
    return np.clip(round_half_up(out), 0, 255).astype(np.uint8)
