"""Independent oracle for the Camera Raw kernels, written from the C source.

This script exists to pin the Rust port in `comp-raw` to numbers that were produced by a separate
implementation of compositor_mac/Compositor/Rendering/AdjustPixels.c. It is not part of the crate
build; run it with the bundled Python and copy the values it prints into the test in
`src/light.rs` / `tests/pipeline.rs` when the port changes.

    python tools/oracle.py
"""
import math

# --- shared primitives, from AdjustPixels.c -------------------------------------------------


def clamp(value):
    if value < 0.0:
        return 0.0
    if value > 1.0:
        return 1.0
    return value


def srgb_to_linear(encoded):
    if encoded <= 0.04045:
        return encoded / 12.92
    return ((encoded + 0.055) / 1.055) ** 2.4


def linear_to_srgb(linear):
    if linear <= 0.0:
        return 0.0
    if linear >= 1.0:
        return 1.0
    if linear <= 0.0031308:
        return linear * 12.92
    return 1.055 * (linear ** (1.0 / 2.4)) - 0.055


def rec709(r, g, b):
    return 0.2126 * r + 0.7152 * g + 0.0722 * b


def scale_luminance(rgb, target):
    target = clamp(target)
    y = rec709(*rgb)
    if abs(target - y) < 1e-8:
        return rgb
    if y < 1e-8:
        return [target, target, target] if target > y else rgb
    factor = target / y
    return [clamp(channel * factor) for channel in rgb]


def tone_highlights(y, amount):
    t = clamp((y - 0.5) / 0.5)
    weight = t * t
    if amount >= 0.0:
        return clamp(y + amount * weight * (1.0 - y))
    return clamp(y + amount * weight * (y - 0.5))


def tone_shadows(y, amount):
    t = clamp((0.5 - y) / 0.5)
    weight = t * t
    if amount >= 0.0:
        return clamp(y + amount * weight * (0.5 - y))
    return clamp(y + amount * weight * y)


def tone_whites(y, amount):
    if y <= 0.75:
        return y
    return clamp(0.75 + (y - 0.75) * (1.0 + amount))


def tone_blacks(y, amount):
    if y >= 0.25:
        return y
    return clamp(0.25 + (y - 0.25) * (1.0 - amount))


def vibrance_and_saturation(rgb, vibrance, saturation):
    r, g, b = rgb
    lum = rec709(r, g, b)
    maxc, minc = max(r, g, b), min(r, g, b)
    chroma = maxc - minc
    sat = 0.0 if maxc <= 1e-8 else chroma / maxc
    hue = 0.0
    if chroma > 1e-8:
        if r >= g and r >= b:
            hue = 60.0 * math.fmod((g - b) / chroma, 6.0)
        elif g >= r and g >= b:
            hue = 60.0 * ((b - r) / chroma + 2.0)
        else:
            hue = 60.0 * ((r - g) / chroma + 4.0)
        if hue < 0.0:
            hue += 360.0
    skin = 0.0
    if 10.0 <= hue <= 50.0:
        skin = (hue - 10.0) / 20.0 if hue <= 30.0 else (50.0 - hue) / 20.0
        skin *= clamp((sat - 0.15) / 0.35)
    amount = vibrance * (1.0 - sat)
    if vibrance > 0.0:
        amount *= 1.0 - 0.7 * skin
    factor = 1.0 + amount
    out = [clamp(lum + (channel - lum) * factor) for channel in (r, g, b)]
    lum = rec709(*out)
    factor = 1.0 + saturation
    return [clamp(lum + (channel - lum) * factor) for channel in out]


def rgb_to_hsl(r, g, b):
    maxc, minc = max(r, g, b), min(r, g, b)
    l = (maxc + minc) * 0.5
    d = maxc - minc
    if d < 1e-6:
        return 0.0, 0.0, l
    s = d / (1.0 - abs(2.0 * l - 1.0))
    if maxc == r:
        h = math.fmod((g - b) / d, 6.0)
    elif maxc == g:
        h = (b - r) / d + 2.0
    else:
        h = (r - g) / d + 4.0
    h /= 6.0
    if h < 0.0:
        h += 1.0
    return h, s, l


def hue_to_rgb(p, q, t):
    if t < 0.0:
        t += 1.0
    if t > 1.0:
        t -= 1.0
    if t < 1.0 / 6.0:
        return p + (q - p) * 6.0 * t
    if t < 0.5:
        return q
    if t < 2.0 / 3.0:
        return p + (q - p) * (2.0 / 3.0 - t) * 6.0
    return p


def hsl_to_rgb(h, s, l):
    if s <= 1e-6:
        return [l, l, l]
    q = l * (1.0 + s) if l < 0.5 else l + s - l * s
    p = 2.0 * l - q
    return [hue_to_rgb(p, q, h + 1.0 / 3.0), hue_to_rgb(p, q, h), hue_to_rgb(p, q, h - 1.0 / 3.0)]


def circular_distance(a, b):
    d = abs(a - b)
    return 1.0 - d if d > 0.5 else d


# --- curve, from CameraRawColor.swift + Curves.swift ----------------------------------------


def curve_value(points, x):
    if len(points) < 2:
        return x
    index = 0
    for i, point in enumerate(points):
        if point[0] <= x:
            index = i
    index = min(len(points) - 2, max(0, index))
    d = [(points[i + 1][1] - points[i][1]) / (points[i + 1][0] - points[i][0]) for i in range(len(points) - 1)]

    def slope(j):
        if j == 0:
            return d[0]
        if j == len(points) - 1:
            return d[-1]
        if d[j - 1] * d[j] <= 0.0:
            return 0.0
        return 2.0 / (1.0 / d[j - 1] + 1.0 / d[j])

    h = points[index + 1][0] - points[index][0]
    t = min(1.0, max(0.0, (x - points[index][0]) / h))
    y = ((2 * t ** 3 - 3 * t ** 2 + 1) * points[index][1]
         + (t ** 3 - 2 * t ** 2 + t) * h * slope(index)
         + (-2 * t ** 3 + 3 * t ** 2) * points[index + 1][1]
         + (t ** 3 - t ** 2) * h * slope(index + 1))
    return min(1.0, max(0.0, y))


def bend(tone, lower, low, upper, high):
    strength = 1.66
    if tone < lower and lower > 0.0:
        return lower * (tone / lower) ** (2.0 ** (-low / 100.0 * strength))
    if tone > upper and upper < 1.0:
        rest = 1.0 - upper
        return 1.0 - rest * ((1.0 - tone) / rest) ** (2.0 ** (high / 100.0 * strength))
    return tone


def parametric(tone, shadows, darks, lights, highlights, shadow_split=25.0, dark_split=50.0, light_split=75.0):
    if shadows == 0.0 and darks == 0.0 and lights == 0.0 and highlights == 0.0:
        return tone
    anchors = []
    for index in range(33):
        x = index / 32.0
        inner = bend(x, shadow_split / 100.0, shadows, light_split / 100.0, highlights)
        anchors.append((x, bend(inner, dark_split / 100.0, darks, dark_split / 100.0, lights)))
    return curve_value(anchors, tone)


MEDIUM = [(0.0, 0.0), (0.25, 0.18), (0.75, 0.82), (1.0, 1.0)]
LINEAR = [(0.0, 0.0), (1.0, 1.0)]


def lut_at(lut, value):
    scaled = clamp(value) * 255.0
    low = int(scaled)
    high = low + 1 if low < 255 else 255
    t = scaled - low
    return lut[low] + (lut[high] - lut[low]) * t


# --- kernels --------------------------------------------------------------------------------


def light_color(pixel, exposure=0.0, contrast=0.0, highlights=0.0, shadows=0.0, whites=0.0, blacks=0.0,
                vibrance=0.0, saturation=0.0, gains=(1.0, 1.0, 1.0), clipping=0):
    light = 2.0 ** exposure
    contrast_scale = 1.0 + contrast / 100.0
    color = [clamp(srgb_to_linear(pixel[i] / 255.0) * gains[i] * light) for i in range(3)]
    color = [clamp(0.5 + (linear_to_srgb(channel) - 0.5) * contrast_scale) for channel in color]
    for amount, tone in ((highlights / 100.0, tone_highlights), (shadows / 100.0, tone_shadows),
                         (whites / 100.0, tone_whites), (blacks / 100.0, tone_blacks)):
        color = scale_luminance(color, tone(rec709(*color), amount))
    color = vibrance_and_saturation(color, vibrance / 100.0, saturation / 100.0)
    if clipping == 1:
        clipped = [channel >= 254.5 / 255.0 for channel in color]
        if any(clipped):
            color = [1.0 if flag else 0.0 for flag in clipped]
    elif clipping == 2:
        clipped = [channel <= 0.5 / 255.0 for channel in color]
        if any(clipped):
            color = [0.0 if flag else 1.0 for flag in clipped]
    return [int(min(255.0, max(0.0, round(channel * 255.0)))) for channel in color]


MIXER_CENTERS = [0.0, 30 / 360, 60 / 360, 120 / 360, 180 / 360, 240 / 360, 270 / 360, 300 / 360]


def curve_color(pixel, curve_rgb=LINEAR, refine=0.0, mixer_hue=None, mixer_sat=None, mixer_lum=None,
                wheels=None, blending=0.5, balance=0.0):
    mixer_hue = mixer_hue or [0.0] * 8
    mixer_sat = mixer_sat or [0.0] * 8
    mixer_lum = mixer_lum or [0.0] * 8
    wheels = wheels or [(0.0, 0.0, 0.0)] * 4
    tone = [curve_value(curve_rgb, parametric(i / 255.0, 0, 0, 0, 0)) for i in range(256)]
    r, g, b = pixel[0] / 255.0, pixel[1] / 255.0, pixel[2] / 255.0
    r, g, b = lut_at(tone, r), lut_at(tone, g), lut_at(tone, b)
    if refine > 0.0:
        lum = rec709(r, g, b)
        factor = 1.0 + refine
        r, g, b = (clamp(lum + (channel - lum) * factor) for channel in (r, g, b))
    elif refine < 0.0:
        flat = scale_luminance([pixel[0] / 255.0, pixel[1] / 255.0, pixel[2] / 255.0],
                               lut_at(tone, rec709(pixel[0] / 255.0, pixel[1] / 255.0, pixel[2] / 255.0)))
        k = -refine
        r, g, b = (channel + (flat[i] - channel) * k for i, channel in enumerate((r, g, b)))
    h, s, l = rgb_to_hsl(r, g, b)
    hue_delta = sat_delta = lum_delta = weight_sum = 0.0
    for family in range(8):
        distance = circular_distance(h, MIXER_CENTERS[family])
        weight = 1.0 - distance / (40.0 / 360.0)
        if weight <= 0.0:
            continue
        hue_delta += mixer_hue[family] / 100.0 * weight * (30.0 / 360.0)
        sat_delta += mixer_sat[family] / 100.0 * weight
        lum_delta += mixer_lum[family] / 100.0 * weight * 0.25
        weight_sum += weight
    if weight_sum > 1.0:
        hue_delta /= weight_sum
        sat_delta /= weight_sum
        lum_delta /= weight_sum
    h += hue_delta
    if h < 0.0:
        h += 1.0
    if h >= 1.0:
        h -= 1.0
    s = clamp(s * (1.0 + sat_delta))
    l = clamp(l + lum_delta)
    r, g, b = hsl_to_rgb(h, s, l)
    split = 0.5 - balance * 0.2
    reach = 0.12 + blending * 0.38
    lum = rec709(r, g, b)
    shadow = clamp((split + reach - lum) / max(0.05, reach * 2))
    highlight = clamp((lum - (split - reach)) / max(0.05, reach * 2))
    mid = clamp(1.0 - abs(lum - split) / (0.35 + reach))
    total = shadow + mid + highlight
    if total > 1e-4:
        shadow, mid, highlight = shadow / total, mid / total, highlight / total
    for wheel, weight in enumerate((shadow, mid, highlight, 1.0)):
        wh, ws, wl = wheels[wheel]
        if weight <= 0.0 or (ws <= 0.0 and wl == 0.0):
            continue
        cr, cg, cb = hsl_to_rgb(wh, 1.0, 0.5)
        r = clamp(r + (cr - 0.5) * ws * weight * 0.85)
        g = clamp(g + (cg - 0.5) * ws * weight * 0.85)
        b = clamp(b + (cb - 0.5) * ws * weight * 0.85)
        if wl != 0.0:
            r, g, b = scale_luminance([r, g, b], clamp(rec709(r, g, b) + wl * 0.25 * weight))
    return [int(min(255.0, max(0.0, round(channel * 255.0)))) for channel in (r, g, b)]


def main():
    print("# Case A: gray 128, +1 stop")
    print("A =", light_color((128, 128, 128), exposure=1.0))
    print("# Case B: gray 128, contrast 50, saturation 40")
    print("B =", light_color((128, 128, 128), contrast=50.0, saturation=40.0))
    print("# Case C: (200, 60, 60), vibrance 60, saturation -20")
    print("C =", light_color((200, 60, 60), vibrance=60.0, saturation=-20.0))
    print("# Case D: (60, 90, 200), temperature 60, tint -40, exposure -0.5, contrast 25")
    gains = (1.0 + 0.35 * 0.6 + 0.15 * -0.4, 1.0 - 0.30 * -0.4, 1.0 - 0.35 * 0.6 + 0.15 * -0.4)
    print("D =", light_color((60, 90, 200), exposure=-0.5, contrast=25.0, gains=gains))
    print("# Case E: (48, 128, 230), highlights -60, shadows 70, whites 50, blacks -40")
    print("E =", light_color((48, 128, 230), highlights=-60.0, shadows=70.0, whites=50.0, blacks=-40.0))
    print("# Case F: curve Medium Contrast (point curve only) on 64, 128, 192")
    print("F =", [curve_color((value, value, value), curve_rgb=MEDIUM) for value in (64, 128, 192)])
    print("# Case G: (200, 60, 60) with Reds hue +40, saturation +30")
    print("G =", curve_color((200, 60, 60), mixer_hue=[40, 0, 0, 0, 0, 0, 0, 0], mixer_sat=[30, 0, 0, 0, 0, 0, 0, 0]))
    print("# Case H: (128, 128, 128) with the global wheel at hue 240, saturation 100")
    print("H =", curve_color((128, 128, 128), wheels=[(0, 0, 0), (0, 0, 0), (0, 0, 0), (240.0 / 360.0, 1.0, 0.0)]))
    print("# Case I: (40, 40, 40) with the shadow wheel at hue 30, saturation 100, luminance -50")
    print("I =", curve_color((40, 40, 40), wheels=[(30.0 / 360.0, 1.0, -0.5), (0, 0, 0), (0, 0, 0), (0, 0, 0)]))
    print("# Case J: refine saturation +80 on (180, 120, 90)")
    print("J =", curve_color((180, 120, 90), refine=0.8))
    print("# Case K: bright 230 with highlights -60, then whites 50 (the white point is 0.75)")
    print("K =", light_color((230, 230, 230), highlights=-60.0, whites=50.0))
    print("# Case L: dark 13 with blacks -100 (the black point is 0.25)")
    print("L =", light_color((13, 13, 13), blacks=-100.0))
    print("# Case M: dark 13 with shadows 60 and blacks -100, in that order")
    print("M =", light_color((13, 13, 13), shadows=60.0, blacks=-100.0))
    print("# Case N: (200, 60, 60) vibrance 100 at the skin-tone edge of the hue range")
    print("N =", light_color((200, 60, 60), vibrance=100.0))
    print("# Case O: gray 128 saturation -100 (a neutral pixel cannot lose color)")
    print("O =", light_color((128, 128, 128), saturation=-100.0))
    print("# Case P: clipping view, highlights, on (255, 128, 128)")
    print("P =", light_color((255, 128, 128), clipping=1))
    print("# Case Q: clipping view, shadows, on (0, 40, 200)")
    print("Q =", light_color((0, 40, 200), clipping=2))


if __name__ == "__main__":
    main()
