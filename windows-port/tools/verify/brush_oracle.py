"""Recomputes a compc stroke from the brush model, without the Rust engine.

This is the judge for the brush semantics, which until now were only ever compared with themselves
(an incremental stroke against a batch one). Everything here is written from the model rather than
from the Rust source: the path is flattened, each chord deposits optical density along the tip, the
profile and coverage tables are recomputed, and the pixels are composited with source-over. Where
the model says a value is a 32-bit float (the engine keeps the stroke's own buffers in f32), this
uses numpy float32 too, so the two agree to within a level rather than to within a rewrite.

The model, in the order the engine applies it (see crates/comp-brush/NOTES.md):

1. The path is the control points as given (compc stroke paints with smoothing 0, which is the
   identity: no pointer string).
2. Each consecutive pair becomes one centripetal Catmull-Rom piece, flattened until the polyline
   stays within CHORD_TOLERANCE (0.5 px) of the curve, or ten levels of bisection, whichever
   comes first. Each chord of that polyline is a deposition segment.
3. A segment deposits into the stroke's buffer, one pixel at a time, at pixel centres
   (x + 0.5, y + 0.5):
   - Soft tip (hardness < 1): the density is integrated along the segment with a midpoint rule of
     1..4 taps, the tap count growing with the length, and divided by the deposition spacing. A
     tap's density is read from a 1024-entry table over squared distance, linearly interpolated.
     Samples outside the tip read zero, which is what clips the integral.
   - Hard tip (hardness >= 1): the antialiased silhouette at the nearest point of the segment,
     clamped over the segment's ends, kept with max().
   - A zero-length segment (a click) deposits one tip profile.
4. Coverage: soft tips are 1 - exp(-density) through a 4096-entry table over 0..20; hard tips are
   the strongest silhouette, clamped to 0..1.
5. Paint: alpha = coverage * opacity, then source-over with straight alpha. The engine has a fast
   path for opaque paint over an opaque pixel, which is the same arithmetic with the alpha that
   falls out of the general formula equal to 1, so this mirrors both.

Usage:
  python brush_oracle.py --output out.png --width 256 --height 192 --brush 40 --hardness 0.6 ...
The flags are the ones compc stroke takes, so a check can pass the same list to both.
"""

from __future__ import annotations

import argparse
import math

import numpy as np
from PIL import Image

MAX_DENSITY = 20.0
EDGE_ANTIALIAS = 1.0
FALLOFF_K = 2.5
MIN_SPACING_PIXELS = 0.25
CHORD_TOLERANCE = 0.5
PROFILE_ENTRIES = 1024
COVERAGE_ENTRIES = 4096
COVERAGE_SCALE = COVERAGE_ENTRIES / MAX_DENSITY
MAX_SUBDIVISION_DEPTH = 10


def spacing_fraction(hardness: float) -> float:
    return 0.015 if hardness >= 1.0 else 0.025


def spacing_pixels(size: float, hardness: float, spacing: float) -> float:
    fraction = spacing if spacing > 0.0 else spacing_fraction(hardness)
    fraction = min(max(fraction, 0.001), 1.0)
    return max(size * fraction, MIN_SPACING_PIXELS)


def tip_reach(size: float) -> float:
    return size / 2.0 + EDGE_ANTIALIAS


def tip_weight(size: float, hardness: float, distance):
    """Coverage of one dab at a distance: 1 inside the hardness radius, 0 at the rim."""
    radius = size / 2.0
    distance = np.asarray(distance, dtype=np.float64)
    if hardness >= 1.0:
        return np.clip((radius - distance) / EDGE_ANTIALIAS + 0.5, 0.0, 1.0)
    t = np.clip((distance / radius - hardness) / (1.0 - hardness), 0.0, 1.0)
    return (np.exp(-FALLOFF_K * t * t) - math.exp(-FALLOFF_K)) / (1.0 - math.exp(-FALLOFF_K))


def profile_lut(size: float, hardness: float):
    """The soft tip's optical density over squared distance, as the engine's table holds it."""
    reach = tip_reach(size)
    index = np.arange(PROFILE_ENTRIES + 1, dtype=np.float64)
    distance = np.sqrt(reach * reach * index / PROFILE_ENTRIES)
    weight = tip_weight(size, hardness, distance)
    density = -np.log(np.maximum(1.0 - weight, 0.001))
    return density.astype(np.float32), reach * reach / PROFILE_ENTRIES


def lut_density(table: np.ndarray, step: float, distance_squared: np.ndarray) -> np.ndarray:
    """Linear interpolation over squared distance, in float32, zero past the tip's reach."""
    index = distance_squared / step
    base = index.astype(np.int64)
    out = np.zeros(distance_squared.shape, dtype=np.float32)
    inside = base < len(table) - 1
    if not inside.any():
        return out
    low_index = base[inside]
    low = table[low_index]
    weight = (index[inside] - low_index.astype(np.float64)).astype(np.float32)
    out[inside] = (low + (table[low_index + 1] - low) * weight).astype(np.float32)
    return out


def knot(t: float, a, b) -> float:
    return t + max(math.hypot(b[0] - a[0], b[1] - a[1]), 0.0001)


def mix(a, b, ta: float, tb: float, t: float):
    wa = (tb - t) / (tb - ta)
    wb = (t - ta) / (tb - ta)
    return (a[0] * wa + b[0] * wb, a[1] * wa + b[1] * wb)


def subdivide(start, end, before, after, tolerance: float, out: list) -> None:
    """Appends the flattened spline from start (already in out) to end."""
    t0 = 0.0
    t1 = knot(t0, before, start)
    t2 = knot(t1, start, end)
    t3 = knot(t2, end, after)

    def point(u: float):
        if u <= 0.0:
            return start
        if u >= 1.0:
            return end
        t = t1 + (t2 - t1) * u
        a = mix(before, start, t0, t1, t)
        b = mix(start, end, t1, t2, t)
        c = mix(end, after, t2, t3, t)
        return mix(mix(a, b, t0, t2, t), mix(b, c, t1, t3, t), t1, t2, t)

    def error(pixel, from_point, to_point) -> float:
        dx = to_point[0] - from_point[0]
        dy = to_point[1] - from_point[1]
        length_squared = dx * dx + dy * dy
        if length_squared > 0.0:
            t = min(max(((pixel[0] - from_point[0]) * dx + (pixel[1] - from_point[1]) * dy) / length_squared, 0.0), 1.0)
        else:
            t = 0.0
        ex = pixel[0] - from_point[0] - t * dx
        ey = pixel[1] - from_point[1] - t * dy
        return math.hypot(ex, ey)

    def step(from_point, to_point, lo: float, hi: float, depth: int) -> None:
        mid = (lo + hi) / 2.0
        middle = point(mid)
        deviation = max(
            error(middle, from_point, to_point),
            error(point((lo + mid) / 2.0), from_point, to_point),
            error(point((mid + hi) / 2.0), from_point, to_point),
        )
        if deviation <= tolerance or depth >= MAX_SUBDIVISION_DEPTH:
            out.append(to_point)
            return
        step(from_point, middle, lo, mid, depth + 1)
        step(middle, to_point, mid, hi, depth + 1)

    step(start, end, 0.0, 1.0, 0)


def stroke_segments(points):
    """The whole path as deposition segments: every pair of samples flattened into chords."""
    if not points:
        return []
    if len(points) == 1:
        return [(points[0], points[0])]
    segments = []
    for index in range(len(points) - 1):
        start = points[index]
        end = points[index + 1]
        before = points[max(index - 1, 0)]
        after = points[min(index + 2, len(points) - 1)]
        polyline = [start]
        subdivide(start, end, before, after, CHORD_TOLERANCE, polyline)
        for left, right in zip(polyline, polyline[1:]):
            segments.append((left, right))
    return segments


def deposit_soft(values: np.ndarray, table, step: float, size: float, hardness: float, flow: float,
                 spacing: float, segment) -> None:
    (ax, ay), (bx, by) = segment
    abx, aby = bx - ax, by - ay
    length = math.hypot(abx, aby)
    height, width = values.shape
    reach = tip_reach(size)
    reach_squared = reach * reach
    radius = max(size / 2.0, 1e-6)

    min_x = max(math.ceil(min(ax, bx) - reach - 0.5), 0)
    min_y = max(math.ceil(min(ay, by) - reach - 0.5), 0)
    max_x = min(math.floor(max(ax, bx) + reach - 0.5) + 1, width)
    max_y = min(math.floor(max(ay, by) + reach - 0.5) + 1, height)
    if max_x <= min_x or max_y <= min_y:
        return
    xs = np.arange(min_x, max_x, dtype=np.float64)[None, :] + 0.5
    ys = np.arange(min_y, max_y, dtype=np.float64)[:, None] + 0.5
    dx = xs - ax
    dy = ys - ay

    if length <= 1e-12:
        distance_squared = dx * dx + dy * dy
        contribution = lut_density(table, step, distance_squared) * np.float32(flow)
        near = distance_squared <= reach_squared
        block = values[min_y:max_y, min_x:max_x]
        block[near] += contribution[near]
        return

    # The quadrature samples the segment at most a quarter of the tip's radius apart: a straight
    # line is one chord however long it is, and too few samples would step over the pixels the tip
    # swept. Samples outside the tip read zero, so summing all of them is the sum of those in range.
    sample_step = max(0.25 * radius, 1e-6)
    samples = max(math.ceil(length / sample_step), 1)
    sample_spacing = length / samples
    scale = np.float32(flow) * np.float32(sample_spacing / spacing)
    ux, uy = abx / length, aby / length
    along = dx * ux + dy * uy
    perpendicular_squared = dx * dx + dy * dy - along * along
    total = np.zeros(perpendicular_squared.shape, dtype=np.float32)
    for sample in range(samples):
        offset = (sample + 0.5) * sample_spacing - along
        total += lut_density(table, step, perpendicular_squared + offset * offset)
    near = perpendicular_squared <= reach_squared
    block = values[min_y:max_y, min_x:max_x]
    block[near] += (total * scale)[near]


def deposit_hard(values: np.ndarray, size: float, hardness: float, flow: float, segment) -> None:
    (ax, ay), (bx, by) = segment
    abx, aby = bx - ax, by - ay
    length = math.hypot(abx, aby)
    height, width = values.shape
    reach = tip_reach(size)
    reach_squared = reach * reach

    min_x = max(math.ceil(min(ax, bx) - reach - 0.5), 0)
    min_y = max(math.ceil(min(ay, by) - reach - 0.5), 0)
    max_x = min(math.floor(max(ax, bx) + reach - 0.5) + 1, width)
    max_y = min(math.floor(max(ay, by) + reach - 0.5) + 1, height)
    if max_x <= min_x or max_y <= min_y:
        return
    xs = np.arange(min_x, max_x, dtype=np.float64)[None, :] + 0.5
    ys = np.arange(min_y, max_y, dtype=np.float64)[:, None] + 0.5
    dx = xs - ax
    dy = ys - ay

    if length <= 1e-12:
        along = np.zeros_like(dx)
    else:
        ux, uy = abx / length, aby / length
        along = np.clip(dx * ux + dy * uy, 0.0, length)
        dx = dx - along * ux
        dy = dy - along * uy
    distance_squared = dx * dx + dy * dy
    weight = tip_weight(size, hardness, np.sqrt(np.maximum(distance_squared, 0.0)))
    painted = (np.float32(flow) * weight.astype(np.float32)).astype(np.float32)
    near = distance_squared <= reach_squared
    block = values[min_y:max_y, min_x:max_x]
    block[near] = np.maximum(block[near], painted[near])


def coverage_from_density(committed: np.ndarray) -> np.ndarray:
    """1 - exp(-density) through the same table the engine reads, in float64."""
    table = (1.0 - np.exp(-(np.arange(COVERAGE_ENTRIES + 1) / COVERAGE_SCALE))).astype(np.float32)
    density = committed.astype(np.float64)
    index = density * COVERAGE_SCALE
    base = index.astype(np.int64)
    out = np.zeros(density.shape, dtype=np.float64)
    inside = (density > 0.0) & (base < COVERAGE_ENTRIES)
    saturated = density > 0.0
    saturated &= base >= COVERAGE_ENTRIES
    out[saturated] = float(table[COVERAGE_ENTRIES])
    low_index = base[inside]
    low = table[low_index].astype(np.float64)
    high = table[low_index + 1].astype(np.float64)
    out[inside] = low + (high - low) * (index[inside] - low_index.astype(np.float64))
    return out


def composite(base: np.ndarray, color, alpha: np.ndarray, erase: bool) -> np.ndarray:
    """One pixel of paint through coverage, straight alpha."""
    source = np.broadcast_to(np.array(color, dtype=np.float64), (base.shape[0], 4))
    out = base.astype(np.float64).copy()
    painted = alpha > 0.0
    if erase:
        remaining = base[:, 3] / 255.0 * (1.0 - alpha)
        out[:, 3] = np.round(np.clip(remaining * 255.0, 0.0, 255.0))
        return out[painted] if False else np.where(painted[:, None], out, base.astype(np.float64)).astype(np.uint8)
    sa = source[:, 3] / 255.0 * alpha
    da = base[:, 3] / 255.0
    out_a = sa + da * (1.0 - sa)
    opaque = painted & (source[:, 3] == 255.0) & (base[:, 3] == 255.0)
    general = painted & ~opaque
    if opaque.any():
        keep = 1.0 - alpha[opaque]
        for channel in range(3):
            out[opaque, channel] = np.round(
                np.clip(source[opaque, channel] * alpha[opaque] + base[opaque, channel] * keep, 0.0, 255.0)
            )
        out[opaque, 3] = 255.0
    if general.any():
        a = out_a[general]
        for channel in range(3):
            value = (source[general, channel] * sa[general] + base[general, channel] * da[general] * (1.0 - sa[general])) / a
            out[general, channel] = np.round(np.clip(value, 0.0, 255.0))
        out[general, 3] = np.round(np.clip(a * 255.0, 0.0, 255.0))
    result = base.astype(np.uint8).copy()
    result[painted] = out[painted].astype(np.uint8)
    return result


def parse_hex(text: str):
    digits = text.strip().lstrip("#")
    if len(digits) == 6:
        digits += "ff"
    if len(digits) != 8:
        raise SystemExit(f"{text} is not a hex colour")
    return [int(digits[index:index + 2], 16) for index in (0, 2, 4, 6)]


def parse_point(text: str):
    x, y = text.split(",")
    return (float(x), float(y))


def build_path(args):
    """The same points compc stroke builds, from the same flags."""
    from_point = parse_point(args.from_point)
    if args.samples == 0:
        raise SystemExit("--samples must be at least 1")
    if args.samples == 1:
        return [from_point]
    last = args.samples - 1
    if args.path == "line":
        to_point = parse_point(args.to_point)
        return [
            (
                from_point[0] + (to_point[0] - from_point[0]) * (index / last),
                from_point[1] + (to_point[1] - from_point[1]) * (index / last),
            )
            for index in range(args.samples)
        ]
    if args.path == "arc":
        center = parse_point(args.center)
        if args.radius <= 0.0:
            raise SystemExit("--radius must be above zero")
        points = []
        for index in range(args.samples):
            radians = math.radians(args.start_deg + args.sweep_deg * (index / last))
            points.append((center[0] + args.radius * math.cos(radians), center[1] + args.radius * math.sin(radians)))
        return points
    raise SystemExit(f"{args.path} is not a path: use line or arc")


def paint(args) -> np.ndarray:
    size = args.brush
    hardness = args.hardness
    soft = hardness < 1.0
    background = parse_hex(args.background)
    color = parse_hex(args.color)
    canvas = np.zeros((args.height, args.width, 4), dtype=np.uint8)
    canvas[:, :] = background
    points = build_path(args)
    segments = stroke_segments(points)
    values = np.zeros((args.height, args.width), dtype=np.float32)
    spacing = spacing_pixels(size, hardness, args.spacing)
    table, step = profile_lut(size, hardness)
    for segment in segments:
        if soft:
            deposit_soft(values, table, step, size, hardness, args.flow, spacing, segment)
        else:
            deposit_hard(values, size, hardness, args.flow, segment)
    coverage = coverage_from_density(values) if soft else np.clip(values.astype(np.float64), 0.0, 1.0)
    alpha = (coverage * args.opacity).ravel()
    flat = canvas.reshape(-1, 4)
    painted = composite(flat, color, alpha, False)
    return painted.reshape(args.height, args.width, 4)


def main(argv=None) -> int:
    parser = argparse.ArgumentParser(description="Recompute a compc stroke from the model")
    parser.add_argument("--output", required=True)
    parser.add_argument("--width", type=int, default=256)
    parser.add_argument("--height", type=int, default=192)
    parser.add_argument("--brush", type=float, required=True)
    parser.add_argument("--hardness", type=float, default=1.0)
    parser.add_argument("--flow", type=float, default=1.0)
    parser.add_argument("--opacity", type=float, default=1.0)
    parser.add_argument("--spacing", type=float, default=0.0)
    parser.add_argument("--color", default="000000ff")
    parser.add_argument("--background", default="ffffffff")
    parser.add_argument("--path", default="line")
    parser.add_argument("--samples", type=int, default=2)
    parser.add_argument("--from", dest="from_point", default="40,96")
    parser.add_argument("--to", dest="to_point", default="216,96")
    parser.add_argument("--center", default="128,96")
    parser.add_argument("--radius", type=float, default=64.0)
    parser.add_argument("--start-deg", dest="start_deg", type=float, default=0.0)
    parser.add_argument("--sweep-deg", dest="sweep_deg", type=float, default=180.0)
    args = parser.parse_args(argv)
    painted = paint(args)
    Image.fromarray(painted, "RGBA").save(args.output)
    print(f"oracle: {args.width}x{args.height}, {len(stroke_segments(build_path(args)))} segments -> {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
