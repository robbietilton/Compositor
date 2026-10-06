"""The twelve adjustment kinds, transcribed from the macOS pixel kernels.

Sources, in the order the code below follows them:
  * AdjustPixels.c      - gradient map, grain, black & white, color balance, box blur helpers
  * LevelsPixels.c      - levels_apply (table lookup), cube_apply (trilinear color cube)
  * NoisePixels.c       - add noise, uniform and Gaussian
  * Levels.swift        - LevelRange/LevelsSettings.apply, the RGB range last
  * Curves.swift        - shape-preserving cubic Hermite through the points, per channel then RGB
  * ImageAdjustments.swift - Exposure's table, Gradient Map's table, Grain/Color Balance settings
  * HueSaturation.swift - HSL round trip, band weights, the 33-cube the canvas uses
  * PixelInvert.swift   - premultiplied invert (alpha - color)
  * GPUCanvas.swift     - which kinds the canvas runs through a 33-cube, Levels at 1024 entries
"""

from __future__ import annotations

import math

import numpy as np

from oracle_core import (
    build_cube,
    cube_apply,
    gaussian_blur_premul,
    lut_apply,
    motion_streak,
    round_half_up,
    unpremul_rgb255,
    write_premul,
)

MASK32 = 0xFFFFFFFF
TWO_PI = 6.2831853


def _clamp(value, low, high):
    return np.minimum(high, np.maximum(low, value))


# ---------------------------------------------------------------------------------------------
# Hue/Saturation
# ---------------------------------------------------------------------------------------------

BANDS = {
    "Master": (0.0, 0.0, 360.0, 360.0),
    "Reds": (315.0, 345.0, 15.0, 45.0),
    "Yellows": (15.0, 45.0, 75.0, 105.0),
    "Greens": (75.0, 105.0, 135.0, 165.0),
    "Cyans": (135.0, 165.0, 195.0, 225.0),
    "Blues": (195.0, 225.0, 255.0, 285.0),
    "Magentas": (255.0, 285.0, 315.0, 345.0),
}


def _forward(start: float, end: float) -> float:
    """HueBand.forward: degrees from `start` forward to `end`, always 0-360."""
    delta = math.fmod(end - start, 360.0)
    return delta + 360.0 if delta < 0 else delta


def band_weight(band, hue: float) -> float:
    falloff_start, range_start, range_end, falloff_end = band
    span = _forward(falloff_start, falloff_end)
    if span <= 0:
        return 1.0
    position = _forward(falloff_start, hue)
    if position > span:
        return 0.0
    ramp_in = _forward(falloff_start, range_start)
    plateau_end = _forward(falloff_start, range_end)
    if position < ramp_in:
        return position / ramp_in if ramp_in > 0 else 1.0
    if position <= plateau_end:
        return 1.0
    ramp_out = span - plateau_end
    return (span - position) / ramp_out if ramp_out > 0 else 1.0


def hsv_response(adjustments, bands=None, invert_range=False, range_name="Master") -> np.ndarray:
    """HueSaturationFilter.hueResponse: one (shift, saturation, lightness) triple per degree."""
    table = np.zeros((361, 3), dtype=np.float64)
    for color_range, adjustment in adjustments.items():
        if all(abs(value) < 1e-12 for value in adjustment):
            continue
        band = (bands or BANDS)[color_range]
        for degree in range(361):
            weight = 1.0 if color_range == "Master" else band_weight(band, float(degree))
            if invert_range and color_range == range_name:
                weight = 1.0 - weight
            if weight <= 0:
                continue
            table[degree, 0] += adjustment[0] * weight
            table[degree, 1] += adjustment[1] * weight
            table[degree, 2] += adjustment[2] * weight
    return table


def _to_hsl(red, green, blue):
    high = np.maximum(red, np.maximum(green, blue))
    low = np.minimum(red, np.minimum(green, blue))
    lightness = (high + low) * 0.5
    delta = high - low
    hue = np.zeros_like(red)
    saturation = np.zeros_like(red)
    chromatic = delta > 0
    with np.errstate(divide="ignore", invalid="ignore"):
        saturation = np.where(chromatic, delta / (1.0 - np.abs(2.0 * lightness - 1.0)), 0.0)
        hue = np.where(high == red, (green - blue) / np.where(chromatic, delta, 1.0),
                       np.where(high == green, (blue - red) / np.where(chromatic, delta, 1.0) + 2.0,
                                (red - green) / np.where(chromatic, delta, 1.0) + 4.0))
    hue = np.where(chromatic, hue * 60.0, 0.0)
    hue = np.where(hue < 0, hue + 360.0, hue)
    return hue, np.minimum(1.0, saturation), lightness


def _to_rgb(hue, saturation, lightness):
    chroma = (1.0 - np.abs(2.0 * lightness - 1.0)) * saturation
    sector = hue / 60.0
    second = chroma * (1.0 - np.abs(np.fmod(sector, 2.0) - 1.0))
    base = lightness - chroma / 2.0
    index = sector.astype(np.int64)
    red = np.select([index == 0, index == 1, index == 2, index == 3, index == 4],
                    [chroma, second, np.zeros_like(chroma), np.zeros_like(chroma), second], default=chroma)
    green = np.select([index == 0, index == 1, index == 2, index == 3, index == 4],
                      [second, chroma, chroma, second, np.zeros_like(chroma)], default=np.zeros_like(chroma))
    blue = np.select([index == 0, index == 1, index == 2, index == 3, index == 4],
                     [np.zeros_like(chroma), np.zeros_like(chroma), second, chroma, chroma], default=second)
    solid = saturation > 0
    red = np.where(solid, _clamp(red + base, 0.0, 1.0), lightness)
    green = np.where(solid, _clamp(green + base, 0.0, 1.0), lightness)
    blue = np.where(solid, _clamp(blue + base, 0.0, 1.0), lightness)
    return red, green, blue


def _adjusted_saturation(saturation, amount):
    """Photoshop's saturation: multiplicative below zero, divisor above it."""
    amount = _clamp(np.asarray(amount, dtype=np.float64) / 100.0, -1.0, 1.0)
    with np.errstate(divide="ignore", invalid="ignore"):
        raised = np.where(amount >= 1.0, np.where(saturation > 0, 1.0, 0.0),
                          np.minimum(1.0, saturation / np.where(amount >= 1.0, 1.0, 1.0 - amount)))
    lowered = np.maximum(0.0, saturation * (1.0 + amount))
    return np.where(amount > 0, raised, lowered)


def hsv_adjust(rgb, hue=0.0, saturation=0.0, lightness=0.0, colorize=False,
               range_name="Master", adjustments=None, bands=None, invert_range=False):
    """HueSaturationFilter.adjust on float RGB in 0-1."""
    if adjustments is None:
        adjustments = {range_name: (float(hue), float(saturation), float(lightness))}
    out_hue, out_saturation, out_lightness = _to_hsl(rgb[..., 0], rgb[..., 1], rgb[..., 2])
    if colorize:
        out_hue = np.full_like(out_hue, math.fmod(float(hue), 360.0))
        out_saturation = np.full_like(out_saturation, float(_clamp(saturation / 100.0, 0.0, 1.0)))
        lightness_amount = np.full_like(out_lightness, float(lightness) / 100.0)
    else:
        table = hsv_response(adjustments, bands, invert_range, range_name)
        index = np.clip(np.floor(out_hue + 0.5), 0, 360).astype(np.int64)
        sampled = table[index]
        lightness_amount = sampled[..., 2] / 100.0
        out_hue = np.mod(out_hue + sampled[..., 0], 360.0)
        out_saturation = _adjusted_saturation(out_saturation, sampled[..., 1])
    amount = _clamp(lightness_amount, -1.0, 1.0)
    out_lightness = np.where(amount >= 0, out_lightness + (1.0 - out_lightness) * amount,
                             out_lightness * (1.0 + amount))
    return _to_rgb(out_hue, out_saturation, _clamp(out_lightness, 0.0, 1.0))


def apply_hsv(pixels, **settings):
    """Hue/Saturation runs through the 33-cube on macOS, so the cube is the primary oracle."""
    cube = build_cube(33, lambda lattice: np.stack(
        hsv_adjust(lattice, **settings), axis=-1))
    return cube_apply(pixels, cube)


def apply_hsv_direct(pixels, **settings):
    result = pixels.copy()
    active = pixels[..., 3] > 0
    rgb = unpremul_rgb255(pixels) / 255.0
    adjusted = np.stack(hsv_adjust(rgb, **settings), axis=-1) * 255.0
    write_premul(result, np.where(active[..., None], adjusted, 0.0), pixels[..., 3].astype(np.float64))
    return result


# ---------------------------------------------------------------------------------------------
# Levels, Curves, Exposure: 256-entry tables through levels_apply
# ---------------------------------------------------------------------------------------------


def _range_tuple(level_range):
    """Accept either the manifest's object or a plain tuple, so fixtures read as the file does."""
    if isinstance(level_range, dict):
        return (level_range.get("black", 0.0), level_range.get("gamma", 1.0), level_range.get("white", 255.0),
                level_range.get("outputBlack", 0.0), level_range.get("outputWhite", 255.0))
    return tuple(level_range)


def _point_pair(point):
    return (point["x"], point["y"]) if isinstance(point, dict) else (point[0], point[1])


def _normalized_range(level_range):
    black, gamma, white, output_black, output_white = _range_tuple(level_range)
    black = min(254.0, max(0.0, black))
    white = min(255.0, max(black + 1.0, white))
    gamma = min(9.99, max(0.1, gamma))
    output_black = min(255.0, max(0.0, output_black))
    output_white = min(255.0, max(0.0, output_white))
    return black, gamma, white, output_black, output_white


def level_range_apply(value, level_range):
    black, gamma, white, output_black, output_white = _normalized_range(level_range)
    scaled = np.clip((np.asarray(value) * 255.0 - black) / (white - black), 0.0, 1.0)
    return (output_black + np.power(scaled, 1.0 / gamma) * (output_white - output_black)) / 255.0


def levels_tables(ranges):
    """LevelsSettings.apply: the composite RGB range runs after the channel's own range."""
    composite = ranges[0]
    tables = []
    for index in (1, 2, 3):
        values = np.arange(256, dtype=np.float64) / 255.0
        tables.append(level_range_apply(level_range_apply(values, ranges[index]), composite))
    return np.stack(tables)


def apply_levels(pixels, ranges):
    return lut_apply(pixels, levels_tables(ranges))


def apply_levels_gpu(pixels, ranges, size=1024):
    """GPUCanvas's Levels path: a 1024-entry CIColorCurves over the whole 0-1 domain."""
    step = float(size - 1)
    values = np.arange(size, dtype=np.float64) / step
    composite = ranges[0]
    curve = np.stack([level_range_apply(level_range_apply(values, ranges[index]), composite)
                      for index in (1, 2, 3)])
    result = pixels.copy()
    active = pixels[..., 3] > 0
    rgb = np.zeros(pixels.shape[:2] + (3,), dtype=np.float64)
    rgb[active] = unpremul_rgb255(pixels)[active] / 255.0
    position = rgb * step
    lo = np.clip(position.astype(np.int64), 0, size - 2)
    fraction = position - lo
    out = np.zeros_like(rgb)
    for channel in range(3):
        value = curve[channel][lo[..., channel]]
        value = value + (curve[channel][lo[..., channel] + 1] - value) * fraction[..., channel]
        out[..., channel] = value * 255.0
    write_premul(result, np.where(active[..., None], out, 0.0), pixels[..., 3].astype(np.float64))
    return result


def curve_value(points, x, channel):
    """CurvesSettings.value: shape-preserving cubic Hermite, clamped to 0-255."""
    xs = np.array([_point_pair(point)[0] for point in points], dtype=np.float64)
    ys = np.array([_point_pair(point)[1] for point in points], dtype=np.float64)
    difference = np.diff(ys) / np.diff(xs)
    count = len(points)
    slopes = np.empty(count, dtype=np.float64)
    for index in range(count):
        if index == 0:
            slopes[index] = difference[0]
        elif index == count - 1:
            slopes[index] = difference[-1]
        elif difference[index - 1] * difference[index] <= 0:
            slopes[index] = 0.0
        else:
            slopes[index] = 2.0 / (1.0 / difference[index - 1] + 1.0 / difference[index])
    last = np.max(np.nonzero(xs <= x)) if np.any(xs <= x) else 0
    index = min(count - 2, max(0, int(last)))
    span = xs[index + 1] - xs[index]
    t = min(1.0, max(0.0, (x - xs[index]) / span))
    y = ((2 * t ** 3 - 3 * t ** 2 + 1) * ys[index]
         + (t ** 3 - 2 * t ** 2 + t) * span * slopes[index]
         + (-2 * t ** 3 + 3 * t ** 2) * ys[index + 1]
         + (t ** 3 - t ** 2) * span * slopes[index + 1])
    return min(255.0, max(0.0, float(y)))


def curve_tables(channels):
    """Curves.apply: channel 1-3 first, then the RGB curve over their result."""
    tables = []
    for index in (1, 2, 3):
        tables.append(np.array([curve_value(channels[0], curve_value(channels[index], float(value), index), 0)
                                for value in range(256)], dtype=np.float64) / 255.0)
    return np.stack(tables)


def apply_curves(pixels, channels):
    return lut_apply(pixels, curve_tables(channels))


def exposure_table(exposure=0.0, offset=0.0, gamma=1.0):
    """ExposureSettings.table: decode to linear light, scale, offset, gamma, encode back."""
    scale = math.pow(2.0, exposure)
    table = np.empty(256, dtype=np.float64)
    for index in range(256):
        encoded = index / 255.0
        linear = encoded / 12.92 if encoded <= 0.04045 else math.pow((encoded + 0.055) / 1.055, 2.4)
        linear = math.pow(max(0.0, linear * scale + offset), 1.0 / gamma)
        output = linear * 12.92 if linear <= 0.0031308 else 1.055 * math.pow(linear, 1.0 / 2.4) - 0.055
        table[index] = min(1.0, max(0.0, output))
    return table


def apply_exposure(pixels, exposure=0.0, offset=0.0, gamma=1.0):
    table = exposure_table(exposure, offset, gamma)
    return lut_apply(pixels, np.stack([table, table, table]))


# ---------------------------------------------------------------------------------------------
# Gradient Map, Black & White, Color Balance, Grain, Add Noise, Invert: AdjustPixels.c/NoisePixels.c
# ---------------------------------------------------------------------------------------------


def gradient_map_table(shadows, highlights, reversed_ends=False):
    """GradientMapSettings.apply: a 256 x 3 byte table from the dark end to the light one."""
    dark, light = (highlights, shadows) if reversed_ends else (shadows, highlights)
    table = np.empty((256, 3), dtype=np.uint8)
    for index in range(256):
        t = index / 255.0
        for channel in range(3):
            value = dark[channel] + (light[channel] - dark[channel]) * t
            table[index, channel] = int(min(255.0, max(0.0, round_half_up(value * 255.0))))
    return table


def apply_gradient_map(pixels, table):
    """adjust_gradient_map: luminance picks the row; color is re-premultiplied by the alpha."""
    result = pixels.copy()
    alpha = pixels[..., 3].astype(np.int64)
    active = alpha > 0
    rgb = pixels[..., :3].astype(np.int64).copy()
    partial = active & (alpha < 255)
    for channel in range(3):
        rgb[..., channel] = np.where(partial, (rgb[..., channel] * 255 + alpha // 2) // np.maximum(alpha, 1),
                                     rgb[..., channel])
    rgb = np.minimum(rgb, 255)
    level = (2126 * rgb[..., 0] + 7152 * rgb[..., 1] + 722 * rgb[..., 2] + 5000) // 10000
    level = np.minimum(level, 255)
    color = table[level]
    for channel in range(3):
        value = (color[..., channel].astype(np.int64) * alpha + 127) // 255
        result[..., channel] = np.where(active, value, result[..., channel]).astype(np.uint8)
    return result


def apply_black_white(pixels, weights=(40.0, 60.0, 40.0, 60.0, 20.0, 80.0), tint=False,
                      tint_hue=40.0, tint_saturation=20.0):
    """adjust_black_white: each color is gray plus a secondary plus a primary, each weighted."""
    result = pixels.copy()
    alpha = pixels[..., 3].astype(np.float64)
    active = alpha > 0
    safe = np.maximum(alpha, 1.0)
    channels = []
    for channel in range(3):
        value = np.minimum(255.0, pixels[..., channel].astype(np.float64) * 255.0 / safe) / 255.0
        channels.append(value)
    red, green, blue = channels
    maximum = np.maximum(red, np.maximum(green, blue))
    minimum = np.minimum(red, np.minimum(green, blue))
    middle = red + green + blue - maximum - minimum
    primary = np.where(maximum == red, 0, np.where(maximum == green, 2, 4))
    secondary = np.where(maximum == red, np.where(green >= blue, 1, 5),
                         np.where(maximum == green, np.where(red >= blue, 1, 3),
                                  np.where(green >= red, 3, 5)))
    weight = np.array([weights[0], weights[1], weights[2], weights[3], weights[4], weights[5]]) / 100.0
    gray = minimum + (middle - minimum) * weight[secondary] + (maximum - middle) * weight[primary]
    gray = np.minimum(1.0, np.maximum(0.0, gray))
    out_red, out_green, out_blue = gray.copy(), gray.copy(), gray.copy()
    saturation = float(tint_saturation) / 100.0
    if tint and saturation > 0:
        chroma = (1.0 - np.abs(2.0 * gray - 1.0)) * saturation
        hue_prime = math.fmod(float(tint_hue), 360.0) / 60.0
        second = chroma * (1.0 - np.abs(math.fmod(hue_prime, 2.0) - 1.0))
        if hue_prime < 1:
            first, middle_c, last = chroma, second, np.zeros_like(chroma)
        elif hue_prime < 2:
            first, middle_c, last = second, chroma, np.zeros_like(chroma)
        elif hue_prime < 3:
            first, middle_c, last = np.zeros_like(chroma), chroma, second
        elif hue_prime < 4:
            first, middle_c, last = np.zeros_like(chroma), second, chroma
        elif hue_prime < 5:
            first, middle_c, last = second, np.zeros_like(chroma), chroma
        else:
            first, middle_c, last = chroma, np.zeros_like(chroma), second
        base = gray - chroma / 2.0
        out_red = np.minimum(1.0, np.maximum(0.0, first + base))
        out_green = np.minimum(1.0, np.maximum(0.0, middle_c + base))
        out_blue = np.minimum(1.0, np.maximum(0.0, last + base))
    for channel, value in enumerate((out_red, out_green, out_blue)):
        updated = np.minimum(alpha, np.maximum(0.0, round_half_up(value * alpha)))
        result[..., channel] = np.where(active, updated, result[..., channel]).astype(np.uint8)
    return result


def tonal_weights(value):
    """adjust_color_balance's three overlapping tonal curves."""
    a, b, scale = 0.25, 0.333, 0.7
    shadow = np.clip((value - b) / -a + 0.5, 0.0, 1.0)
    highlight = np.clip((value + b - 1.0) / a + 0.5, 0.0, 1.0)
    mid_one = np.clip((value - b) / a + 0.5, 0.0, 1.0)
    mid_two = np.clip((value + b - 1.0) / -a + 0.5, 0.0, 1.0)
    return shadow * scale, mid_one * mid_two * scale, highlight * scale


def apply_color_balance(pixels, shadows=(0.0, 0.0, 0.0), midtones=(0.0, 0.0, 0.0),
                        highlights=(0.0, 0.0, 0.0), preserve_luminosity=True):
    """adjust_color_balance: a per-tonal-range shift, with brightness put back afterwards."""
    result = pixels.copy()
    alpha = pixels[..., 3].astype(np.float64)
    active = alpha > 0
    safe = np.maximum(alpha, 1.0)
    color = [np.minimum(255.0, pixels[..., channel].astype(np.float64) * 255.0 / safe) / 255.0
             for channel in range(3)]
    before = 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2]
    shift = [np.array(shadows) / 100.0, np.array(midtones) / 100.0, np.array(highlights) / 100.0]
    for channel in range(3):
        shadow, mid, highlight = tonal_weights(color[channel])
        color[channel] = np.clip(color[channel] + shift[0][channel] * shadow
                                 + shift[1][channel] * mid + shift[2][channel] * highlight, 0.0, 1.0)
    if preserve_luminosity:
        after = 0.299 * color[0] + 0.587 * color[1] + 0.114 * color[2]
        ratio = np.where(after > 0.0001, before / np.maximum(after, 1e-12), 0.0)
        for channel in range(3):
            color[channel] = np.where(after > 0.0001,
                                      np.clip(color[channel] * ratio, 0.0, 1.0), color[channel])
    for channel in range(3):
        updated = np.minimum(alpha, np.maximum(0.0, round_half_up(color[channel] * alpha)))
        result[..., channel] = np.where(active, updated, result[..., channel]).astype(np.uint8)
    return result


def mix32(x):
    x = int(x) & MASK32
    x ^= x >> 16
    x = (x * 0x7FEB352D) & MASK32
    x ^= x >> 15
    x = (x * 0x846CA68B) & MASK32
    x ^= x >> 16
    return x


def _lattice(ix, iy, seed):
    h = mix32(((int(ix) & MASK32) * 0x9E3779B1) ^ mix32(((int(iy) & MASK32) * 0x85EBCA77) ^ seed))
    return (h & 0xFFFF) / 65535.0 + (h >> 16) / 65535.0 - 1.0


def _grain_field(u, v, scale, seed):
    cell_x = math.floor(u / scale)
    cell_y = math.floor(v / scale)
    tx = u / scale - cell_x
    ty = v / scale - cell_y
    tx = tx * tx * (3.0 - 2.0 * tx)
    ty = ty * ty * (3.0 - 2.0 * ty)
    n00 = _lattice(cell_x, cell_y, seed)
    n10 = _lattice(cell_x + 1, cell_y, seed)
    n01 = _lattice(cell_x, cell_y + 1, seed)
    n11 = _lattice(cell_x + 1, cell_y + 1, seed)
    top = n00 + (n10 - n00) * tx
    bottom = n01 + (n11 - n01) * tx
    return (top + (bottom - top) * ty) * 1.6


def apply_grain(pixels, amount=25.0, size=1.5, roughness=50.0, seed=0,
                origin=(0.0, 0.0), units_per_pixel=1.0):
    """adjust_grain: the same brightness change on all three channels, strongest in the midtones."""
    result = pixels.copy()
    if amount <= 0 or units_per_pixel <= 0:
        return result
    if size <= 0:
        size = 1.0
    strength = (1.0 if amount > 100 else amount / 100.0) * 0.35 * 255.0
    rough = 0.0 if roughness < 0 else (1.0 if roughness > 100 else roughness / 100.0)
    fine_seed = mix32(seed ^ 0xA511E9B3)
    detail_size = max(0.5, size * 0.35)
    height, width = pixels.shape[:2]
    for y in range(height):
        v = origin[1] + (y + 0.5) * units_per_pixel
        for x in range(width):
            alpha = int(pixels[y, x, 3])
            if alpha == 0:
                continue
            u = origin[0] + (x + 0.5) * units_per_pixel
            smooth = _grain_field(u, v, size, seed)
            fine = _grain_field(u, v, detail_size, fine_seed)
            noise = smooth + (fine - smooth) * rough
            unpremultiply = 1.0 if alpha == 255 else 255.0 / alpha
            red = pixels[y, x, 0] * unpremultiply
            green = pixels[y, x, 1] * unpremultiply
            blue = pixels[y, x, 2] * unpremultiply
            level = (0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0
            level = min(1.0, level)
            delta = noise * strength * (0.4 + 2.4 * level * (1.0 - level))
            coverage = alpha / 255.0
            for channel, value in enumerate((red, green, blue)):
                clamped = min(255.0, max(0.0, value + delta))
                result[y, x, channel] = int(clamped * coverage + 0.5)
    return result


def _noise_hash(x):
    x = int(x) & MASK32
    x ^= x >> 16
    x = (x * 0x7FEB352D) & MASK32
    x ^= x >> 15
    x = (x * 0x846CA68B) & MASK32
    x ^= x >> 16
    return x


def _noise_unit(key):
    return (_noise_hash(key) >> 8) * (1.0 / 16777216.0)


def apply_add_noise(pixels, amount=10.0, gaussian=False, monochromatic=False, seed=0, origin=(0, 0)):
    """noise_add_at: uniform or Box-Muller Gaussian noise on the unpremultiplied color."""
    result = pixels.copy()
    spread = amount / 100.0 * 127.5
    height, width = pixels.shape[:2]
    for y in range(height):
        for x in range(width):
            alpha = int(pixels[y, x, 3])
            if alpha == 0:
                continue
            px = (int(origin[0]) + x) & MASK32
            py = (int(origin[1]) + y) & MASK32
            base = _noise_hash(seed ^ _noise_hash((px * 0x9E3779B9) & MASK32
                                                  ^ _noise_hash((py * 0x85EBCA6B) & MASK32)))
            for channel in range(3):
                key = base if monochromatic else (base + channel * 0x9E3779B9) & MASK32
                if gaussian:
                    u1 = _noise_unit(key)
                    u2 = _noise_unit(key ^ 0x68E31DA4)
                    noise = math.sqrt(-2.0 * math.log(1.0 - u1)) * math.cos(TWO_PI * u2) * spread * (2.0 / 3.0)
                else:
                    noise = (_noise_unit(key) * 2.0 - 1.0) * spread
                value = pixels[y, x, channel] * 255.0 / alpha + noise
                value = 0.0 if value < 0 else (255.0 if value > 255 else value)
                result[y, x, channel] = int(math.floor(value * alpha / 255.0 + 0.5))
    return result


def apply_invert(pixels):
    """PixelInvert: every color becomes alpha - color, so transparency is kept."""
    result = pixels.copy()
    alpha = pixels[..., 3].astype(np.int64)
    for channel in range(3):
        result[..., channel] = np.maximum(0, alpha - pixels[..., channel].astype(np.int64)).astype(np.uint8)
    return result


# ---------------------------------------------------------------------------------------------
# Gaussian and Motion Blur
# ---------------------------------------------------------------------------------------------


def apply_gaussian_blur(pixels, radius, edge="zero"):
    """The adjustment layer's blur: CIGaussianBlur(sigma: radius) at 1:1."""
    return gaussian_blur_premul(pixels, float(radius), edge)


def apply_motion_blur(pixels, distance, angle_deg, edge="zero"):
    """The adjustment layer's streak, modelled as an even smear of `distance` pixels."""
    return motion_streak(pixels, float(distance), float(angle_deg), edge)
