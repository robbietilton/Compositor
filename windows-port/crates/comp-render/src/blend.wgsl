// The 24 blend modes and the W3C source-over composite, on straight-alpha RGBA8.
//
// This mirrors comp-render's CPU path exactly: the same blend functions, the same alpha algebra, the same
// rounding. The buffers hold straight RGBA8 (one u32 per pixel, little-endian, so the bytes are R, G, B, A),
// the mode is the index into BlendMode::ALL, and the output is straight RGBA8 again - so a caller cannot
// tell a GPU composite from a CPU one beyond a level of rounding.

// WGSL keeps a list of reserved words - `shared`, `vec`, `mat` and friends - that a variable may not
// be called; naga rejects the whole shader over one, so names here are deliberately plain.
const EPSILON: f32 = 1e-12;

struct Params {
    count: u32,
    mode: u32,
    opacity: f32,
    // How many workgroups the dispatch put on the x axis. A canvas can need more workgroups than one
    // dimension allows (65535 of them), so the dispatch spreads over two and each invocation works out
    // which pixel it owns from this.
    groups_x: u32,
    // How many coverage planes follow one another in the coverage buffer, and how many words each of them
    // takes. A layer's coverage is its own mask, then its clipping coverage, then its folders' masks, in
    // the order the CPU multiplies them in.
    coverage_planes: u32,
    plane_words: u32,
    // The layer's own image, which is what the source buffer holds when the layer is placed by a transform
    // rather than filling the canvas.
    source_width: u32,
    source_height: u32,
    canvas_width: u32,
    // 0 nearest, 1 bilinear, 2 bicubic - the filter the CPU's sampling_filter picks for this placement.
    // Named tap_filter because @@filter@@ is one of WGSL's reserved words.
    tap_filter: u32,
    // 1 when the source has to be sampled through the inverse transform, 0 when it fills the canvas.
    placement: u32,
    // 1 when the transform turns nothing, which selects the axis-aligned coverage.
    axis_aligned: u32,
    // The destination box the placement covers, in canvas pixels; nothing outside it is drawn.
    box_x: i32,
    box_y: i32,
    box_width: u32,
    box_height: u32,
    // The inverse of the pixel-to-document affine, column major as Affine holds it.
    inv_a: f32,
    inv_b: f32,
    inv_c: f32,
    inv_d: f32,
    inv_tx: f32,
    inv_ty: f32,
    // The affine itself, for the coverage of a scaled or flipped layer.
    aff_a: f32,
    aff_d: f32,
    aff_tx: f32,
    aff_ty: f32,
    // The scale a reduced layer's sample coordinates take, 1 / 2^level.
    coord_scale: f32,
    // The size of the image the source buffer actually holds, which is the layer's own size only when it
    // was not reduced. The coverage still measures against the layer's full size below.
    sample_width: u32,
    sample_height: u32,
    // The canvas is as tall as its pixel count divided by its width; the blur passes need it to walk
    // columns.
    canvas_height: u32,
};

@group(0) @binding(0) var<uniform> params: Params;
@group(0) @binding(1) var<storage, read> backdrop: array<u32>;
@group(0) @binding(2) var<storage, read> source: array<u32>;
@group(0) @binding(3) var<storage, read_write> output: array<u32>;
@group(0) @binding(4) var<storage, read> coverage: array<u32>;

/// One byte of a packed texel.
fn channel(texel: u32, shift: u32) -> f32 {
    return f32((texel >> shift) & 0xFFu);
}

fn pack(red: u32, green: u32, blue: u32, alpha: u32) -> u32 {
    return red | (green << 8u) | (blue << 16u) | (alpha << 24u);
}

/// The CPU's round_u8: round half up, clamped to a byte.
fn round_u8(value: f32) -> u32 {
    return u32(clamp(floor(value + 0.5), 0.0, 255.0));
}

/// Rust's f32::round, which is half away from zero, where WGSL's round is half to even. Every place the CPU
/// calls .round() has to use this instead: the two differ exactly on a half, and a half is where a bead
/// picks a different column, a pattern slot picks a different pattern, or a written byte lands a level away.
fn round_away(value: f32) -> f32 {
    return select(floor(value + 0.5), ceil(value - 0.5), value < 0.0);
}

// ---------------------------------------------------------------------------------------------
// The separable modes, one channel at a time.
// ---------------------------------------------------------------------------------------------

fn color_burn(cb: f32, cs: f32) -> f32 {
    if (cs <= 0.0) {
        return 0.0;
    }
    return 1.0 - min(1.0, (1.0 - cb) / max(cs, EPSILON));
}

fn color_dodge(cb: f32, cs: f32) -> f32 {
    if (cs >= 1.0) {
        return 1.0;
    }
    return min(cb / max(1.0 - cs, EPSILON), 1.0);
}

/// The Photoshop cubic, not Core Image's curve.
fn soft_light(cb: f32, cs: f32) -> f32 {
    if (cs <= 0.5) {
        return cb - (1.0 - 2.0 * cs) * cb * (1.0 - cb);
    }
    var d = sqrt(max(cb, 0.0));
    if (cb <= 0.25) {
        d = ((16.0 * cb - 12.0) * cb + 4.0) * cb;
    }
    return cb + (2.0 * cs - 1.0) * (d - cb);
}

fn hard_light(cb: f32, cs: f32) -> f32 {
    if (cs <= 0.5) {
        return (2.0 * cs) * cb;
    }
    let doubled = 2.0 * cs - 1.0;
    return doubled + cb - doubled * cb;
}

fn vivid_light(cb: f32, cs: f32) -> f32 {
    if (cs <= 0.5) {
        return color_burn(cb, 2.0 * cs);
    }
    return color_dodge(cb, 2.0 * cs - 1.0);
}

fn blend_channel(mode: u32, cb: f32, cs: f32) -> f32 {
    var value = cs;
    switch mode {
        // Normal
        case 0u: { value = cs; }
        // Darken
        case 1u: { value = min(cb, cs); }
        // Multiply
        case 2u: { value = cb * cs; }
        case 3u: { value = color_burn(cb, cs); }
        // Linear Burn
        case 4u: { value = cb + cs - 1.0; }
        // Lighten
        case 5u: { value = max(cb, cs); }
        // Screen
        case 6u: { value = cb + cs - cb * cs; }
        case 7u: { value = color_dodge(cb, cs); }
        // Linear Dodge (Add)
        case 8u: { value = cb + cs; }
        // Overlay is Hard Light with the arguments swapped.
        case 9u: { value = hard_light(cs, cb); }
        case 10u: { value = soft_light(cb, cs); }
        case 11u: { value = hard_light(cb, cs); }
        case 12u: { value = vivid_light(cb, cs); }
        // Linear Light
        case 13u: { value = cb + 2.0 * cs - 1.0; }
        // Pin Light
        case 14u: {
            if (cs <= 0.5) {
                value = min(cb, 2.0 * cs);
            } else {
                value = max(cb, 2.0 * cs - 1.0);
            }
        }
        // Hard Mix is Vivid Light posterized.
        case 15u: {
            if (vivid_light(cb, cs) < 0.5) {
                value = 0.0;
            } else {
                value = 1.0;
            }
        }
        // Difference
        case 16u: { value = abs(cb - cs); }
        // Exclusion
        case 17u: { value = cb + cs - 2.0 * cb * cs; }
        // Subtract
        case 18u: { value = cb - cs; }
        // Divide
        case 19u: {
            if (cs <= 0.0) {
                value = 1.0;
            } else {
                value = min(cb / max(cs, EPSILON), 1.0);
            }
        }
        default: { value = cs; }
    }
    return clamp(value, 0.0, 1.0);
}

// ---------------------------------------------------------------------------------------------
// The component modes: PDF SetLum, ClipColor, SetSat.
// ---------------------------------------------------------------------------------------------

fn lum(color: vec3<f32>) -> f32 {
    return 0.3 * color.r + 0.59 * color.g + 0.11 * color.b;
}

fn clip_color(input: vec3<f32>) -> vec3<f32> {
    var color = input;
    let l = lum(color);
    let n = min(color.r, min(color.g, color.b));
    let x = max(color.r, max(color.g, color.b));
    // The expressions keep the CPU's order - `(c - l) * l / d` rather than `(c - l) * (l / d)` - because a
    // component mode can amplify a last-bit difference into a whole level.
    if (n < 0.0) {
        let d = max(l - n, EPSILON);
        color = vec3<f32>(
            l + (color.r - l) * l / d,
            l + (color.g - l) * l / d,
            l + (color.b - l) * l / d,
        );
    }
    // The second correction reads the *original* l and x, as the CPU one does.
    if (x > 1.0) {
        let d = max(x - l, EPSILON);
        color = vec3<f32>(
            l + (color.r - l) * (1.0 - l) / d,
            l + (color.g - l) * (1.0 - l) / d,
            l + (color.b - l) * (1.0 - l) / d,
        );
    }
    return clamp(color, vec3<f32>(0.0), vec3<f32>(1.0));
}

fn set_lum(color: vec3<f32>, l: f32) -> vec3<f32> {
    let d = l - lum(color);
    return clip_color(color + vec3<f32>(d));
}

fn sat(color: vec3<f32>) -> f32 {
    return max(color.r, max(color.g, color.b)) - min(color.r, min(color.g, color.b));
}

/// The channels ranked rather than compared against the middle value: recovering the middle as
/// r + g + b - min - max and testing it for equality loses to a rounding error, which silently zeroes a
/// channel. The CPU side had exactly that bug once.
fn set_sat(color: vec3<f32>, s: f32) -> vec3<f32> {
    let minimum = min(color.r, min(color.g, color.b));
    let maximum = max(color.r, max(color.g, color.b));
    let span = maximum - minimum;
    if (span <= 0.0) {
        return vec3<f32>(0.0);
    }
    let middle = color.r + color.g + color.b - minimum - maximum;
    let scale = s / span;
    let rank = vec3<f32>(
        select(0.0, 1.0, color.g < color.r) + select(0.0, 1.0, color.b < color.r),
        select(0.0, 1.0, color.r < color.g) + select(0.0, 1.0, color.b < color.g),
        select(0.0, 1.0, color.r < color.b) + select(0.0, 1.0, color.g < color.b),
    );
    let lowest = vec3<f32>(0.0);
    let middle_share = vec3<f32>((middle - minimum) * scale);
    let highest = vec3<f32>((maximum - minimum) * scale);
    return select(select(lowest, middle_share, rank >= vec3<f32>(1.0)), highest, rank >= vec3<f32>(2.0));
}

fn blend_colors(mode: u32, cb: vec3<f32>, cs: vec3<f32>) -> vec3<f32> {
    switch mode {
        // Hue
        case 20u: { return set_lum(set_sat(cs, sat(cb)), lum(cb)); }
        // Saturation
        case 21u: { return set_lum(set_sat(cb, sat(cs)), lum(cb)); }
        // Color
        case 22u: { return set_lum(cs, lum(cb)); }
        // Luminosity
        case 23u: { return set_lum(cb, lum(cs)); }
        default: {
            return vec3<f32>(
                blend_channel(mode, cb.r, cs.r),
                blend_channel(mode, cb.g, cs.g),
                blend_channel(mode, cb.b, cs.b),
            );
        }
    }
}

// ---------------------------------------------------------------------------------------------
// The composite.
// ---------------------------------------------------------------------------------------------

/// The CPU's premultiply: the byte a premultiplied surface stores for a straight byte and an alpha.
fn premultiply(byte: u32, alpha: u32) -> u32 {
    return (byte * alpha + 127u) / 255u;
}

/// The CPU's unpremultiply: straight bytes back out of a premultiplied byte and its alpha.
fn unpremultiply(premultiplied: u32, alpha: u32) -> u32 {
    if (alpha == 0u) {
        return 0u;
    }
    if (alpha == 255u) {
        return min(premultiplied, 255u);
    }
    return min((premultiplied * 255u + alpha / 2u) / alpha, 255u);
}

/// One channel of a packed texel, as a byte.
fn byte_at(texel: u32, shift: u32) -> u32 {
    return (texel >> shift) & 0xFFu;
}

/// The straight color the CPU's blend function sees for a pixel: the surface holds round(C * a), and the
/// kernel divides by the alpha again. Reproducing that round trip is what makes this shader a drop-in for
/// the CPU step rather than a more accurate answer that moves pixels when the backend changes.
fn straight_from_stored(stored: u32, alpha: u32) -> f32 {
    if (alpha == 0u) {
        return 0.0;
    }
    // The CPU writes this as `stored as f32 / 255.0 / (alpha as f32 / 255.0)`, and the order matters:
    // a dodging mode divides by one minus this color, so a last-bit disagreement becomes a whole level.
    // Mirroring the expression keeps the two implementations on the same side of every rounding.
    return f32(stored) / 255.0 / (f32(alpha) / 255.0);
}

/// The backdrop as the CPU's composite reads it: straight colors recovered from its premultiplied bytes.
fn backdrop_colors(under: u32, alpha_byte: u32) -> vec3<f32> {
    return vec3<f32>(
        straight_from_stored(premultiply(byte_at(under, 0u), alpha_byte), alpha_byte),
        straight_from_stored(premultiply(byte_at(under, 8u), alpha_byte), alpha_byte),
        straight_from_stored(premultiply(byte_at(under, 16u), alpha_byte), alpha_byte),
    );
}

/// One byte of a packed coverage plane: four pixels to a word.
fn coverage_at(index: u32, plane: u32) -> u32 {
    let word = coverage[plane * params.plane_words + index / 4u];
    return (word >> ((index % 4u) * 8u)) & 0xFFu;
}

// ---------------------------------------------------------------------------------------------
// Placement: sampling the layer's own image through the inverse transform, as place.rs does it.
// ---------------------------------------------------------------------------------------------

fn source_texel(x: i32, y: i32) -> u32 {
    let xi = clamp(x, 0, i32(params.sample_width) - 1);
    let yi = clamp(y, 0, i32(params.sample_height) - 1);
    return source[yi * i32(params.sample_width) + xi];
}

/// A tap of the layer's image, premultiplied, which is what the CPU's placements sample: they read a
/// surface, whose bytes are already premultiplied.
fn source_tap(x: i32, y: i32) -> vec4<f32> {
    let packed = source_texel(x, y);
    let alpha = byte_at(packed, 24u);
    return vec4<f32>(
        f32(premultiply(byte_at(packed, 0u), alpha)),
        f32(premultiply(byte_at(packed, 8u), alpha)),
        f32(premultiply(byte_at(packed, 16u), alpha)),
        f32(alpha),
    );
}

/// Catmull-Rom weights for the four taps around a fraction, as pixel.rs writes them.
fn cubic_weights(t: f32) -> vec4<f32> {
    let t2 = t * t;
    let t3 = t2 * t;
    return vec4<f32>(
        -0.5 * t3 + t2 - 0.5 * t,
        1.5 * t3 - 2.5 * t2 + 1.0,
        -1.5 * t3 + 2.0 * t2 + 0.5 * t,
        0.5 * t3 - 0.5 * t2,
    );
}

fn sample_bilinear(x: f32, y: f32) -> vec4<f32> {
    let fx = x - 0.5;
    let fy = y - 0.5;
    let x0 = floor(fx);
    let y0 = floor(fy);
    let wx = fx - x0;
    let wy = fy - y0;
    let xi = i32(x0);
    let yi = i32(y0);
    var out = vec4<f32>(0.0);
    for (var j = 0; j < 2; j = j + 1) {
        let weight_y = select(1.0 - wy, wy, j == 1);
        for (var i = 0; i < 2; i = i + 1) {
            let weight = select(1.0 - wx, wx, i == 1) * weight_y;
            if (weight == 0.0) {
                continue;
            }
            out = out + source_tap(xi + i, yi + j) * weight;
        }
    }
    return out;
}

fn sample_bicubic(x: f32, y: f32) -> vec4<f32> {
    let fx = x - 0.5;
    let fy = y - 0.5;
    let x0 = floor(fx);
    let y0 = floor(fy);
    let tx = fx - x0;
    let ty = fy - y0;
    let xi = i32(x0);
    let yi = i32(y0);
    let wx = cubic_weights(tx);
    let wy = cubic_weights(ty);
    var out = vec4<f32>(0.0);
    for (var j = 0; j < 4; j = j + 1) {
        let weight_y = wy[j];
        if (weight_y == 0.0) {
            continue;
        }
        for (var i = 0; i < 4; i = i + 1) {
            let weight = wx[i] * weight_y;
            if (weight == 0.0) {
                continue;
            }
            out = out + source_tap(xi + i - 1, yi + j - 1) * weight;
        }
    }
    return out;
}

/// One texel at a fractional pixel-corner coordinate, clamped at the edges: SampledSurface::sample.
fn sample_source(x: f32, y: f32) -> vec4<f32> {
    if (params.tap_filter == 0u) {
        return source_tap(i32(floor(x)), i32(floor(y)));
    }
    if (params.tap_filter == 1u) {
        return sample_bilinear(x, y);
    }
    return sample_bicubic(x, y);
}

/// The product of the two axes' overlaps: exact for a transform that does not turn.
fn axis_coverage(x: i32, y: i32) -> f32 {
    let end_x = params.aff_tx + params.aff_a * f32(params.source_width);
    let end_y = params.aff_ty + params.aff_d * f32(params.source_height);
    let left = min(params.aff_tx, end_x);
    let right = max(params.aff_tx, end_x);
    let top = min(params.aff_ty, end_y);
    let bottom = max(params.aff_ty, end_y);
    let px = f32(x);
    let py = f32(y);
    let cx = clamp(min(px + 1.0, right) - max(px, left), 0.0, 1.0);
    let cy = clamp(min(py + 1.0, bottom) - max(py, top), 0.0, 1.0);
    return cx * cy;
}

/// A convex polygon being clipped: four corners of a destination pixel, growing to at most eight points as
/// the four borders of the source rectangle cut it.
struct Polygon {
    points: array<vec2<f32>, 8>,
    count: u32,
}

struct Hit {
    inside: bool,
    point: vec2<f32>,
}

fn intersect_edge(start: vec2<f32>, end: vec2<f32>, a: f32, b: f32, c: f32) -> Hit {
    let d0 = a * start.x + b * start.y - c;
    let d1 = a * end.x + b * end.y - c;
    let denominator = d0 - d1;
    if (abs(denominator) < 1e-12) {
        return Hit(false, vec2<f32>(0.0));
    }
    let t = clamp(d0 / denominator, 0.0, 1.0);
    return Hit(true, vec2<f32>(start.x + (end.x - start.x) * t, start.y + (end.y - start.y) * t));
}

/// Sutherland-Hodgman against one line, the CPU's clip_to_box step for step.
fn clip_edge(polygon: Polygon, a: f32, b: f32, c: f32) -> Polygon {
    var out: Polygon;
    out.count = 0u;
    if (polygon.count == 0u) {
        return out;
    }
    for (var i = 0u; i < polygon.count; i = i + 1u) {
        let current = polygon.points[i];
        let previous = polygon.points[(i + polygon.count - 1u) % polygon.count];
        let current_inside = a * current.x + b * current.y - c >= 0.0;
        let previous_inside = a * previous.x + b * previous.y - c >= 0.0;
        if (current_inside) {
            if (!previous_inside) {
                let hit = intersect_edge(previous, current, a, b, c);
                if (hit.inside && out.count < 8u) {
                    out.points[out.count] = hit.point;
                    out.count = out.count + 1u;
                }
            }
            if (out.count < 8u) {
                out.points[out.count] = current;
                out.count = out.count + 1u;
            }
        } else if (previous_inside) {
            let hit = intersect_edge(previous, current, a, b, c);
            if (hit.inside && out.count < 8u) {
                out.points[out.count] = hit.point;
                out.count = out.count + 1u;
            }
        }
    }
    return out;
}

/// Coverage when the layer is turned: the destination pixel's quad clipped against the source rectangle,
/// over the area a source pixel covers. This is what softens a rotated edge over one pixel.
fn rotated_coverage(x: i32, y: i32) -> f32 {
    var polygon: Polygon;
    polygon.count = 4u;
    polygon.points[0] = inverse_point(f32(x), f32(y));
    polygon.points[1] = inverse_point(f32(x) + 1.0, f32(y));
    polygon.points[2] = inverse_point(f32(x) + 1.0, f32(y) + 1.0);
    polygon.points[3] = inverse_point(f32(x), f32(y) + 1.0);
    let width = f32(params.source_width);
    let height = f32(params.source_height);
    polygon = clip_edge(polygon, 1.0, 0.0, 0.0);
    polygon = clip_edge(polygon, -1.0, 0.0, -width);
    polygon = clip_edge(polygon, 0.0, 1.0, 0.0);
    polygon = clip_edge(polygon, 0.0, -1.0, -height);
    if (polygon.count < 3u) {
        return 0.0;
    }
    var area = 0.0;
    for (var i = 0u; i < polygon.count; i = i + 1u) {
        let a = polygon.points[i];
        let b = polygon.points[(i + 1u) % polygon.count];
        area = area + a.x * b.y - b.x * a.y;
    }
    let unit = max(abs(params.inv_a * params.inv_d - params.inv_b * params.inv_c), 1e-12);
    return clamp(abs(area / 2.0) / unit, 0.0, 1.0);
}

/// A canvas point in the layer's own pixel corners, through the inverse transform.
fn inverse_point(x: f32, y: f32) -> vec2<f32> {
    return vec2<f32>(
        params.inv_a * x + params.inv_c * y + params.inv_tx,
        params.inv_b * x + params.inv_d * y + params.inv_ty,
    );
}

/// The layer's pixels at one canvas pixel, premultiplied: what place_surface leaves in its scratch.
fn placed_texel(index: u32, x: i32, y: i32) -> vec4<u32> {
    if (params.placement == 0u) {
        let packed = source[index];
        let alpha = byte_at(packed, 24u);
        return vec4<u32>(
            premultiply(byte_at(packed, 0u), alpha),
            premultiply(byte_at(packed, 8u), alpha),
            premultiply(byte_at(packed, 16u), alpha),
            alpha,
        );
    }
    if (x < params.box_x || x >= params.box_x + i32(params.box_width)
        || y < params.box_y || y >= params.box_y + i32(params.box_height)) {
        return vec4<u32>(0u, 0u, 0u, 0u);
    }
    let coverage = select(rotated_coverage(x, y), axis_coverage(x, y), params.axis_aligned == 1u);
    if (coverage <= 0.0) {
        return vec4<u32>(0u, 0u, 0u, 0u);
    }
    // A reduced layer is sampled at its own scale, exactly as the CPU's placements multiply the coordinate.
    let point = inverse_point(f32(x) + 0.5, f32(y) + 0.5) * params.coord_scale;
    let sample = sample_source(point.x, point.y);
    return vec4<u32>(
        round_u8(sample.r * coverage),
        round_u8(sample.g * coverage),
        round_u8(sample.b * coverage),
        round_u8(sample.a * coverage),
    );
}

/// The source as the CPU's pipeline hands it to the blend: premultiplied on the way into its surface, then
/// through each coverage plane - its own mask, its clipping coverage, its folders' masks - and then scaled
/// by the opacity.
///
/// The order and the arithmetic are Surface::mask_by_plane and Surface::scale_alpha, step for step: each
/// plane scales the alpha with (a * m + 127) / 255 and carries the premultiplied colors with it by the same
/// ratio, and the opacity does the same once more. This is what lets a masked or clipped layer composite on
/// the GPU and still land on the CPU's own answer.
fn source_premultiplied(placed: vec4<u32>, index: u32) -> vec4<u32> {
    var texel = placed;
    for (var plane = 0u; plane < params.coverage_planes; plane = plane + 1u) {
        let value = coverage_at(index, plane);
        if (value == 255u) {
            continue;
        }
        if (value == 0u || texel.a == 0u) {
            texel = vec4<u32>(0u, 0u, 0u, 0u);
            continue;
        }
        let scaled = (texel.a * value + 127u) / 255u;
        let ratio = f32(scaled) / f32(texel.a);
        texel = vec4<u32>(
            round_u8(f32(texel.r) * ratio),
            round_u8(f32(texel.g) * ratio),
            round_u8(f32(texel.b) * ratio),
            scaled,
        );
    }
    // Surface::scale_alpha: at one or above it does nothing at all, and an alpha that rounds to itself
    // leaves the colors alone too.
    if (texel.a != 0u && params.opacity < 1.0) {
        let scaled = round_u8(f32(texel.a) * params.opacity);
        if (scaled == 0u) {
            return vec4<u32>(0u, 0u, 0u, 0u);
        }
        if (scaled != texel.a) {
            let ratio = f32(scaled) / f32(texel.a);
            texel = vec4<u32>(
                round_u8(f32(texel.r) * ratio),
                round_u8(f32(texel.g) * ratio),
                round_u8(f32(texel.b) * ratio),
                scaled,
            );
        }
    }
    return texel;
}

/// The backdrop as the CPU's bitmap round trip would hand it back with nothing composited over it.
fn untouched(under: u32, alpha_byte: u32) -> u32 {
    if (alpha_byte == 0u) {
        return 0u;
    }
    return pack(
        unpremultiply(premultiply(byte_at(under, 0u), alpha_byte), alpha_byte),
        unpremultiply(premultiply(byte_at(under, 8u), alpha_byte), alpha_byte),
        unpremultiply(premultiply(byte_at(under, 16u), alpha_byte), alpha_byte),
        alpha_byte,
    );
}

@compute @workgroup_size(64)
fn composite(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let under = backdrop[index];
    let backdrop_alpha_byte = byte_at(under, 24u);
    // The layer's pixels at this canvas pixel - placed by the transform when it has one - and then through
    // every coverage plane, and scaled by the layer's opacity.
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let placed = placed_texel(index, x, y);
    let source_texel = source_premultiplied(placed, index);
    let alpha_byte = source_texel.a;
    if (alpha_byte == 0u) {
        // Nothing to composite: the backdrop comes back as the CPU's bitmap round trip would hand it over.
        output[index] = untouched(under, backdrop_alpha_byte);
        return;
    }
    let source_alpha = f32(alpha_byte) / 255.0;
    let alpha_b = f32(backdrop_alpha_byte) / 255.0;
    let inv_s = 1.0 - source_alpha;
    let inv_b = 1.0 - alpha_b;

    let cs = vec3<f32>(
        straight_from_stored(source_texel.r, alpha_byte),
        straight_from_stored(source_texel.g, alpha_byte),
        straight_from_stored(source_texel.b, alpha_byte),
    );
    let cb = backdrop_colors(under, backdrop_alpha_byte);

    let blended = blend_colors(params.mode, cb, cs);
    let alpha_out = source_alpha + alpha_b * inv_s;
    if (alpha_out <= 0.0) {
        output[index] = 0u;
        return;
    }
    var premultiplied = vec3<f32>(0.0);
    for (var c = 0u; c < 3u; c = c + 1u) {
        premultiplied[c] = source_alpha * inv_b * cs[c] + source_alpha * alpha_b * blended[c] + inv_s * alpha_b * cb[c];
    }
    // Quantize to the bytes a premultiplied surface holds, then unpremultiply - the CPU's exact two steps.
    let output_alpha = round_u8(alpha_out * 255.0);
    output[index] = pack(
        unpremultiply(round_u8(premultiplied.r * 255.0), output_alpha),
        unpremultiply(round_u8(premultiplied.g * 255.0), output_alpha),
        unpremultiply(round_u8(premultiplied.b * 255.0), output_alpha),
        output_alpha,
    );
}
// ---------------------------------------------------------------------------------------------
// Adjustment layers: the per-pixel kernels of adjustment.rs, run as a pass over the canvas.
//
// The program buffer holds one adjustment: a kind, an apply flag (the CPU skips a kernel whose settings
// are the identity, so the shader does too rather than round-tripping pixels through a no-op), sixteen
// scalars, eight integers for the seeds, and then the tables - which the CPU builds with its own code, so
// a lookup cannot drift from the one the CPU runs.
// ---------------------------------------------------------------------------------------------

@group(0) @binding(5) var<storage, read> program: array<u32>;

/// The CPU's composite_texel_mode: premultiplied bytes in, premultiplied bytes out, in a blend mode.
fn composite_texel_mode(mode: u32, under: u32, over: u32) -> vec4<u32> {
    let alpha_s = f32(byte_at(over, 24u)) / 255.0;
    var out = vec4<u32>(byte_at(under, 0u), byte_at(under, 8u), byte_at(under, 16u), byte_at(under, 24u));
    if (alpha_s <= 0.0) {
        return out;
    }
    let alpha_b = f32(byte_at(under, 24u)) / 255.0;
    let inv_s = 1.0 - alpha_s;
    let inv_b = 1.0 - alpha_b;
    var cs = vec3<f32>(0.0);
    var cb = vec3<f32>(0.0);
    for (var channel = 0u; channel < 3u; channel = channel + 1u) {
        cs[channel] = f32(byte_at(over, channel * 8u)) / 255.0 / alpha_s;
        if (alpha_b > 0.0) {
            cb[channel] = f32(byte_at(under, channel * 8u)) / 255.0 / alpha_b;
        }
    }
    let blended = blend_colors(mode, cb, cs);
    let alpha_out = alpha_s + alpha_b * inv_s;
    if (alpha_out <= 0.0) {
        return vec4<u32>(0u, 0u, 0u, 0u);
    }
    for (var channel = 0u; channel < 3u; channel = channel + 1u) {
        let co = alpha_s * inv_b * cs[channel] + alpha_s * alpha_b * blended[channel] + inv_s * alpha_b * cb[channel];
        out[channel] = round_u8(co * 255.0);
    }
    out.a = round_u8(alpha_out * 255.0);
    return out;
}

/// A straight texel as the premultiplied texel a surface would hold for it.
fn premultiplied_texel(straight: u32) -> vec4<u32> {
    let alpha = byte_at(straight, 24u);
    return vec4<u32>(
        premultiply(byte_at(straight, 0u), alpha),
        premultiply(byte_at(straight, 8u), alpha),
        premultiply(byte_at(straight, 16u), alpha),
        alpha,
    );
}

@group(0) @binding(6) var<storage, read> canvas: array<u32>;
@group(0) @binding(7) var<storage, read> beneath: array<u32>;
@group(0) @binding(8) var<storage, read_write> scratch: array<f32>;

const PROGRAM_SCALARS: u32 = 2u;
const PROGRAM_INTEGERS: u32 = 18u;
const PROGRAM_TABLE: u32 = 32u;

fn scalar(index: u32) -> f32 {
    return bitcast<f32>(program[PROGRAM_SCALARS + index]);
}

fn integer(index: u32) -> u32 {
    return program[PROGRAM_INTEGERS + index];
}

fn table(index: u32) -> f32 {
    return bitcast<f32>(program[PROGRAM_TABLE + index]);
}

/// An adjustment never touches the alpha: every kernel here keeps texel.a and works on the premultiplied
/// colors, exactly as the CPU's kernels do.
fn adjust_kernel(texel: vec4<u32>, x: u32, y: u32) -> vec4<u32> {
    if (program[1] == 0u) {
        return texel;
    }
    let kind = program[0];
    if (kind == 0u) {
        return adjust_invert(texel);
    }
    if (kind == 1u) {
        return adjust_lookup(texel);
    }
    if (kind == 2u) {
        return adjust_gradient_map(texel);
    }
    if (kind == 3u) {
        return adjust_black_white(texel);
    }
    if (kind == 4u) {
        return adjust_color_balance(texel);
    }
    if (kind == 5u) {
        return adjust_hue_saturation(texel);
    }
    if (kind == 6u) {
        return adjust_grain(texel, x, y);
    }
    return adjust_add_noise(texel, x, y);
}

/// Each premultiplied channel becomes alpha minus itself, so transparency is kept.
fn adjust_invert(texel: vec4<u32>) -> vec4<u32> {
    return vec4<u32>(
        texel.a - min(texel.r, texel.a),
        texel.a - min(texel.g, texel.a),
        texel.a - min(texel.b, texel.a),
        texel.a,
    );
}

/// The lookup Levels, Curves and Exposure run: unpremultiply, interpolate between the two neighbouring
/// table entries, re-premultiply.
fn adjust_lookup(texel: vec4<u32>) -> vec4<u32> {
    let alpha = f32(texel.a);
    if (alpha <= 0.0) {
        return texel;
    }
    var out = texel;
    let channels = array<u32, 3>(texel.r, texel.g, texel.b);
    for (var channel = 0u; channel < 3u; channel = channel + 1u) {
        let x = min(f32(channels[channel]) * 255.0 / alpha, 255.0);
        let lo = u32(x);
        let hi = select(lo + 1u, 255u, lo >= 255u);
        let low = table(channel * 256u + lo);
        let high = table(channel * 256u + hi);
        let result = low + (high - low) * (x - f32(lo));
        out[channel] = min(round_u8(result * alpha), texel.a);
    }
    return out;
}
/// The integer straightening the gradient map's C kernel does.
fn straight_channel(value: u32, alpha: u32) -> u32 {
    if (alpha == 255u) {
        return value;
    }
    return min((value * 255u + alpha / 2u) / alpha, 255u);
}

/// Rec. 601 luma of the straightened color picks a table entry, which is premultiplied again.
fn adjust_gradient_map(texel: vec4<u32>) -> vec4<u32> {
    let alpha = texel.a;
    if (alpha == 0u) {
        return texel;
    }
    let red = straight_channel(texel.r, alpha);
    let green = straight_channel(texel.g, alpha);
    let blue = straight_channel(texel.b, alpha);
    let level = min((2126u * red + 7152u * green + 722u * blue + 5000u) / 10000u, 255u);
    return vec4<u32>(
        ((u32(program[PROGRAM_INTEGERS + 8u + 0u]) >> 0u) & 0u) + premultiply_table(level, 0u, alpha),
        premultiply_table(level, 1u, alpha),
        premultiply_table(level, 2u, alpha),
        alpha,
    );
}

/// One byte of the gradient map's 256 x 3 table, packed four to a word.
fn premultiply_table(level: u32, channel: u32, alpha: u32) -> u32 {
    let index = level * 3u + channel;
    let word = program[PROGRAM_TABLE + index / 4u];
    let value = (word >> ((index % 4u) * 8u)) & 0xFFu;
    return (value * alpha + 127u) / 255u;
}

/// Photoshop's black and white mix: the darkest channel of gray, plus the middle channel's share of the
/// secondary, plus the brightest channel's share of the primary.
fn adjust_black_white(texel: vec4<u32>) -> vec4<u32> {
    let alpha = f32(texel.a);
    if (alpha <= 0.0) {
        return texel;
    }
    let red = min(f32(texel.r) * 255.0 / alpha, 255.0) / 255.0;
    let green = min(f32(texel.g) * 255.0 / alpha, 255.0) / 255.0;
    let blue = min(f32(texel.b) * 255.0 / alpha, 255.0) / 255.0;
    let maximum = max(max(red, green), blue);
    let minimum = min(min(red, green), blue);
    let middle = red + green + blue - maximum - minimum;
    var primary = 4u;
    var secondary = 5u;
    if (maximum == red) {
        primary = 0u;
        secondary = select(5u, 1u, green >= blue);
    } else if (maximum == green) {
        primary = 2u;
        secondary = select(3u, 1u, red >= blue);
    } else {
        primary = 4u;
        secondary = select(5u, 3u, green >= red);
    }
    var gray = minimum + (middle - minimum) * scalar(secondary) + (maximum - middle) * scalar(primary);
    gray = clamp(gray, 0.0, 1.0);
    var red_out = gray;
    var green_out = gray;
    var blue_out = gray;
    let tint = scalar(6u);
    let tint_saturation = scalar(8u);
    if (tint > 0.0 && tint_saturation > 0.0) {
        let chroma = (1.0 - abs(2.0 * gray - 1.0)) * tint_saturation;
        let hue = (scalar(7u) - floor(scalar(7u) / 360.0) * 360.0) / 60.0;
        let second = chroma * (1.0 - abs((hue - floor(hue / 2.0) * 2.0) - 1.0));
        var base_color = vec3<f32>(chroma, second, 0.0);
        if (hue >= 1.0 && hue < 2.0) {
            base_color = vec3<f32>(second, chroma, 0.0);
        } else if (hue >= 2.0 && hue < 3.0) {
            base_color = vec3<f32>(0.0, chroma, second);
        } else if (hue >= 3.0 && hue < 4.0) {
            base_color = vec3<f32>(0.0, second, chroma);
        } else if (hue >= 4.0 && hue < 5.0) {
            base_color = vec3<f32>(second, 0.0, chroma);
        } else if (hue >= 5.0) {
            base_color = vec3<f32>(chroma, 0.0, second);
        }
        let base = gray - chroma / 2.0;
        red_out = base_color.r + base;
        green_out = base_color.g + base;
        blue_out = base_color.b + base;
    }
    return vec4<u32>(
        min(round_u8(clamp(red_out, 0.0, 1.0) * alpha), texel.a),
        min(round_u8(clamp(green_out, 0.0, 1.0) * alpha), texel.a),
        min(round_u8(clamp(blue_out, 0.0, 1.0) * alpha), texel.a),
        texel.a,
    );
}
/// How much a tone belongs to the shadows, midtones and highlights: three overlapping curves that sum to
/// about one across the range.
fn tonal_weights(value: f32) -> vec3<f32> {
    let a = 0.25;
    let b = 0.333;
    let scale = 0.7;
    let shadow = clamp((value - b) / -a + 0.5, 0.0, 1.0) * scale;
    let highlight = clamp((value + b - 1.0) / a + 0.5, 0.0, 1.0) * scale;
    let mid_one = clamp((value - b) / a + 0.5, 0.0, 1.0);
    let mid_two = clamp((value + b - 1.0) / -a + 0.5, 0.0, 1.0);
    return vec3<f32>(shadow, mid_one * mid_two * scale, highlight);
}

fn adjust_color_balance(texel: vec4<u32>) -> vec4<u32> {
    let alpha = f32(texel.a);
    if (alpha <= 0.0) {
        return texel;
    }
    var color = vec3<f32>(
        min(f32(texel.r) * 255.0 / alpha, 255.0) / 255.0,
        min(f32(texel.g) * 255.0 / alpha, 255.0) / 255.0,
        min(f32(texel.b) * 255.0 / alpha, 255.0) / 255.0,
    );
    let before = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
    for (var channel = 0u; channel < 3u; channel = channel + 1u) {
        let weights = tonal_weights(color[channel]);
        color[channel] = clamp(
            color[channel]
                + scalar(channel) * weights.x
                + scalar(3u + channel) * weights.y
                + scalar(6u + channel) * weights.z,
            0.0,
            1.0,
        );
    }
    if (scalar(9u) > 0.0) {
        let after = 0.299 * color.r + 0.587 * color.g + 0.114 * color.b;
        if (after > 0.0001) {
            color = clamp(color * (before / after), vec3<f32>(0.0), vec3<f32>(1.0));
        }
    }
    return vec4<u32>(
        min(round_u8(color.r * alpha), texel.a),
        min(round_u8(color.g * alpha), texel.a),
        min(round_u8(color.b * alpha), texel.a),
        texel.a,
    );
}

/// RGB to HSL, the conversion the CPU's kernel is written in - the same branches, in the same order.
fn to_hsl(red: f32, green: f32, blue: f32) -> vec3<f32> {
    let high = max(max(red, green), blue);
    let low = min(min(red, green), blue);
    let lightness = (high + low) / 2.0;
    let delta = high - low;
    if (delta <= 0.0) {
        return vec3<f32>(0.0, 0.0, lightness);
    }
    let saturation = delta / (1.0 - abs(2.0 * lightness - 1.0));
    var hue = (red - green) / delta + 4.0;
    if (high == red) {
        hue = (green - blue) / delta;
    } else if (high == green) {
        hue = (blue - red) / delta + 2.0;
    }
    hue = hue * 60.0;
    if (hue < 0.0) {
        hue = hue + 360.0;
    }
    return vec3<f32>(hue, min(saturation, 1.0), lightness);
}

fn to_rgb(hue: f32, saturation: f32, lightness: f32) -> vec3<f32> {
    if (saturation <= 0.0) {
        return vec3<f32>(lightness, lightness, lightness);
    }
    let chroma = (1.0 - abs(2.0 * lightness - 1.0)) * saturation;
    let sector = i32(hue / 60.0);
    let wrapped = (hue / 60.0) - floor((hue / 60.0) / 2.0) * 2.0;
    let second = chroma * (1.0 - abs(wrapped - 1.0));
    let base = lightness - chroma / 2.0;
    // Sector zero is its own arm: leaving it to the default below would take the last arm's channel order
    // and swap green with blue.
    var color = vec3<f32>(chroma, second, 0.0);
    if (sector == 1) {
        color = vec3<f32>(second, chroma, 0.0);
    } else if (sector == 2) {
        color = vec3<f32>(0.0, chroma, second);
    } else if (sector == 3) {
        color = vec3<f32>(0.0, second, chroma);
    } else if (sector == 4) {
        color = vec3<f32>(second, 0.0, chroma);
    } else if (sector != 0) {
        color = vec3<f32>(chroma, 0.0, second);
    }
    return clamp(vec3<f32>(color.r + base, color.g + base, color.b + base), vec3<f32>(0.0), vec3<f32>(1.0));
}

/// Photoshop's Saturation slider: below zero scales toward gray, above zero divides by what is left.
fn adjusted_saturation(saturation: f32, amount: f32) -> f32 {
    let a = clamp(amount / 100.0, -1.0, 1.0);
    if (a <= 0.0) {
        return max(saturation * (1.0 + a), 0.0);
    }
    if (a >= 1.0) {
        return select(0.0, 1.0, saturation > 0.0);
    }
    return min(saturation / (1.0 - a), 1.0);
}

fn adjust_hue_saturation(texel: vec4<u32>) -> vec4<u32> {
    let alpha = f32(texel.a);
    if (alpha <= 0.0) {
        return texel;
    }
    let scale = 255.0 / alpha;
    let red = f32(texel.r) * scale / 255.0;
    let green = f32(texel.g) * scale / 255.0;
    let blue = f32(texel.b) * scale / 255.0;
    var hsl = to_hsl(red, green, blue);
    var lightness_amount = 0.0;
    if (scalar(0u) > 0.0) {
        hsl.x = scalar(1u);
        hsl.y = scalar(2u);
        lightness_amount = scalar(3u);
    } else {
        // The CPU reads the band response with hue.round(), half away from zero.
    let index = u32(clamp(round_away(hsl.x), 0.0, 360.0));
        lightness_amount = table(index * 3u + 2u) / 100.0;
        hsl.x = hsl.x + table(index * 3u + 0u);
        hsl.x = hsl.x - floor(hsl.x / 360.0) * 360.0;
        // The response's saturation is already a percentage, and adjusted_saturation divides by 100 itself.
        hsl.y = adjusted_saturation(hsl.y, table(index * 3u + 1u));
    }
    let amount = clamp(lightness_amount, -1.0, 1.0);
    hsl.z = select(hsl.z * (1.0 + amount), hsl.z + (1.0 - hsl.z) * amount, amount >= 0.0);
    let out = to_rgb(hsl.x, hsl.y, clamp(hsl.z, 0.0, 1.0));
    return vec4<u32>(
        round_u8(out.r * alpha),
        round_u8(out.g * alpha),
        round_u8(out.b * alpha),
        texel.a,
    );
}
/// A well-mixed 32-bit hash, so neighbouring pixels get unrelated values.
fn mix32(value: u32) -> u32 {
    var x = value;
    x = x ^ (x >> 16u);
    x = x * 0x7feb352du;
    x = x ^ (x >> 15u);
    x = x * 0x846ca68bu;
    x = x ^ (x >> 16u);
    return x;
}

/// A value in -1 to 1 for an integer lattice point: two uniform halves summed give a triangular spread,
/// closer to film grain than flat noise.
fn lattice(ix: i32, iy: i32, seed: u32) -> f32 {
    let h = mix32(u32(ix) * 0x9E3779B1u ^ mix32(u32(iy) * 0x85EBCA77u ^ seed));
    return f32(h & 0xFFFFu) / 65535.0 + f32(h >> 16u) / 65535.0 - 1.0;
}

/// Smooth seeded noise whose features follow `scale` document pixels.
fn grain_field(u: f32, v: f32, scale: f32, seed: u32) -> f32 {
    let cell_x = floor(u / scale);
    let cell_y = floor(v / scale);
    var tx = u / scale - cell_x;
    var ty = v / scale - cell_y;
    tx = tx * tx * (3.0 - 2.0 * tx);
    ty = ty * ty * (3.0 - 2.0 * ty);
    let ix = i32(cell_x);
    let iy = i32(cell_y);
    let n00 = lattice(ix, iy, seed);
    let n10 = lattice(ix + 1, iy, seed);
    let n01 = lattice(ix, iy + 1, seed);
    let n11 = lattice(ix + 1, iy + 1, seed);
    let top = n00 + (n10 - n00) * tx;
    let bottom = n01 + (n11 - n01) * tx;
    return (top + (bottom - top) * ty) * 1.6;
}

fn adjust_grain(texel: vec4<u32>, x: u32, y: u32) -> vec4<u32> {
    let alpha = texel.a;
    if (alpha == 0u) {
        return texel;
    }
    let u = scalar(4u) + f32(x) + 0.5;
    let v = scalar(5u) + f32(y) + 0.5;
    // Named coarse rather than smooth: that one is a WGSL reserved word.
    let coarse = grain_field(u, v, scalar(2u), integer(0u));
    let fine = grain_field(u, v, scalar(3u), integer(1u));
    let noise = coarse + (fine - coarse) * scalar(1u);
    let unpremultiply = select(255.0 / f32(alpha), 1.0, alpha == 255u);
    let red = f32(texel.r) * unpremultiply;
    let green = f32(texel.g) * unpremultiply;
    let blue = f32(texel.b) * unpremultiply;
    let level = min((0.2126 * red + 0.7152 * green + 0.0722 * blue) / 255.0, 1.0);
    let delta = noise * scalar(0u) * (0.4 + 2.4 * level * (1.0 - level));
    let coverage = f32(alpha) / 255.0;
    return vec4<u32>(
        round_u8(clamp(red + delta, 0.0, 255.0) * coverage),
        round_u8(clamp(green + delta, 0.0, 255.0) * coverage),
        round_u8(clamp(blue + delta, 0.0, 255.0) * coverage),
        alpha,
    );
}

/// Uniform in [0, 1).
fn noise_unit(key: u32) -> f32 {
    return f32(mix32(key) >> 8u) * (1.0 / 16777216.0);
}

fn adjust_add_noise(texel: vec4<u32>, x: u32, y: u32) -> vec4<u32> {
    let alpha = texel.a;
    if (alpha == 0u) {
        return texel;
    }
    let px = u32(i32(scalar(3u)) + i32(x));
    let py = u32(i32(scalar(4u)) + i32(y));
    let base = mix32(integer(0u) ^ mix32(px * 0x9e3779b9u ^ mix32(py * 0x85ebca6bu)));
    let alpha_scale = f32(alpha);
    var out = texel;
    let channels = array<u32, 3>(texel.r, texel.g, texel.b);
    let monochromatic = scalar(2u) > 0.0;
    let gaussian = scalar(1u) > 0.0;
    for (var channel = 0u; channel < 3u; channel = channel + 1u) {
        let key = select(base + channel * 0x9e3779b9u, base, monochromatic);
        var value = (noise_unit(key) * 2.0 - 1.0) * scalar(0u);
        if (gaussian) {
            let u1 = noise_unit(key);
            let u2 = noise_unit(key ^ 0x68e31da4u);
            value = sqrt(-2.0 * log(1.0 - u1)) * cos(6.283185307179586 * u2) * scalar(0u) * (2.0 / 3.0);
        }
        let scaled = f32(channels[channel]) * 255.0 / alpha_scale + value;
        out[channel] = round_u8(clamp(scaled, 0.0, 255.0) * alpha_scale / 255.0);
    }
    return out;
}

/// One adjustment layer's pass over the canvas, in the CPU's order: the kernel, then - when the layer has
/// a blend mode - the adjusted colors blended with what was under them at full coverage and shown only
/// where the canvas had coverage, then the layer's coverage (its mask, its folders' masks and its opacity)
/// mixed back in.
@compute @workgroup_size(64)
fn adjust(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = index % params.canvas_width;
    let y = index / params.canvas_width;
    // The kernels work on a premultiplied surface, which is what the CPU applies them to; the canvas
    // travelling between passes is straight alpha, so it is premultiplied here and straightened again at
    // the end - the same two steps Surface::from_bitmap and to_bitmap take.
    let straight = canvas[index];
    let straight_below = beneath[index];
    let under = premultiplied_texel(straight);
    let below = premultiplied_texel(straight_below);
    var texel = adjust_kernel(under, x, y);
    if (params.mode != 0u) {
        // The blend runs at full coverage, and the result comes back through the below alpha afterwards,
        // so a soft edge is not thickened.
        let changed = pack(texel.r, texel.g, texel.b, 255u);
        let opaque_below = pack(below.r, below.g, below.b, 255u);
        let blended = composite_texel_mode(params.mode - 1u, opaque_below, changed);
        texel = vec4<u32>(
            (blended.r * below.a + 127u) / 255u,
            (blended.g * below.a + 127u) / 255u,
            (blended.b * below.a + 127u) / 255u,
            (blended.a * below.a + 127u) / 255u,
        );
    }
    // The coverage plane mixes the adjusted pixel with what was under the layer.
    if (params.coverage_planes > 0u) {
        let mix = coverage_at(index, 0u);
        if (mix < 255u) {
            texel = vec4<u32>(
                (texel.r * mix + below.r * (255u - mix) + 127u) / 255u,
                (texel.g * mix + below.g * (255u - mix) + 127u) / 255u,
                (texel.b * mix + below.b * (255u - mix) + 127u) / 255u,
                (texel.a * mix + below.a * (255u - mix) + 127u) / 255u,
            );
        }
    }
    output[index] = pack(
        unpremultiply(texel.r, texel.a),
        unpremultiply(texel.g, texel.a),
        unpremultiply(texel.b, texel.a),
        texel.a,
    );
}
// ---------------------------------------------------------------------------------------------
// The two blur adjustments: their own entry points, because a blur reads its neighbours and cannot be a
// per-pixel kernel. The canvas is premultiplied first, blurred, and finished with the same blend and
// coverage steps every other adjustment layer uses.
// ---------------------------------------------------------------------------------------------

/// The canvas as a premultiplied surface would hold it, which is what the CPU's blurs read.
@compute @workgroup_size(64)
fn prepare(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let texel = premultiplied_texel(canvas[index]);
    output[index] = pack(texel.r, texel.g, texel.b, texel.a);
}

/// One separable pass of the CPU's Gaussian: rows when the direction is zero, columns otherwise. Taps
/// outside the canvas are skipped, as the CPU skips them, so the blur spreads into transparency.
@compute @workgroup_size(64)
fn blur(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let taps = i32(scalar(0u));
    var out = vec4<f32>(0.0);
    for (var tap = 0; tap <= taps * 2; tap = tap + 1) {
        let offset = tap - taps;
        var sx = x;
        var sy = y;
        if (params.placement == 0u) {
            sx = x + offset;
        } else {
            sy = y + offset;
        }
        if (sx < 0 || sy < 0 || sx >= i32(params.canvas_width) || sy >= i32(params.canvas_height)) {
            continue;
        }
        let packed = canvas[sy * i32(params.canvas_width) + sx];
        let weight = table(u32(tap));
        out = out + vec4<f32>(
            f32(byte_at(packed, 0u)) * weight,
            f32(byte_at(packed, 8u)) * weight,
            f32(byte_at(packed, 16u)) * weight,
            f32(byte_at(packed, 24u)) * weight,
        );
    }
    output[index] = pack(round_u8(out.r), round_u8(out.g), round_u8(out.b), round_u8(out.a));
}

/// The CPU's motion blur: an even streak of one sample per pixel along the angle, each sample bilinear
/// with everything outside the canvas transparent, then averaged.
@compute @workgroup_size(64)
fn motion(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = f32(index % params.canvas_width) + 0.5;
    let y = f32(index / params.canvas_width) + 0.5;
    let steps = i32(scalar(0u));
    let half = f32(steps - 1) / 2.0;
    var out = vec4<f32>(0.0);
    for (var step = 0; step < steps; step = step + 1) {
        let t = f32(step) - half;
        out = out + sample_transparent(x + scalar(1u) * t, y + scalar(2u) * t);
    }
    let count = f32(steps);
    output[index] = pack(
        round_u8(out.r / count),
        round_u8(out.g / count),
        round_u8(out.b / count),
        round_u8(out.a / count),
    );
}

/// One texel of a premultiplied surface at a fractional corner coordinate, transparent outside: the CPU's
/// sample_transparent, which its blurs read through.
fn sample_transparent(x: f32, y: f32) -> vec4<f32> {
    let fx = x - 0.5;
    let fy = y - 0.5;
    let x0 = floor(fx);
    let y0 = floor(fy);
    let wx = fx - x0;
    let wy = fy - y0;
    var out = vec4<f32>(0.0);
    for (var dy = 0; dy < 2; dy = dy + 1) {
        let weight_y = select(1.0 - wy, wy, dy == 1);
        for (var dx = 0; dx < 2; dx = dx + 1) {
            let sx = i32(x0) + dx;
            let sy = i32(y0) + dy;
            if (sx < 0 || sy < 0 || sx >= i32(params.canvas_width) || sy >= i32(params.canvas_height)) {
                continue;
            }
            let packed = canvas[sy * i32(params.canvas_width) + sx];
            let weight = select(1.0 - wx, wx, dx == 1) * weight_y;
            out = out + vec4<f32>(
                f32(byte_at(packed, 0u)) * weight,
                f32(byte_at(packed, 8u)) * weight,
                f32(byte_at(packed, 16u)) * weight,
                f32(byte_at(packed, 24u)) * weight,
            );
        }
    }
    return out;
}

/// The tail every adjustment layer ends with: the blend mode against what was under the layer at full
/// coverage, shown only where the canvas had coverage, and then the layer's coverage mixed in. Both inputs
/// are premultiplied, which is how the blurs leave them.
@compute @workgroup_size(64)
fn finish(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let under = canvas[index];
    let below = beneath[index];
    var texel = vec4<u32>(byte_at(under, 0u), byte_at(under, 8u), byte_at(under, 16u), byte_at(under, 24u));
    let below_texel = vec4<u32>(byte_at(below, 0u), byte_at(below, 8u), byte_at(below, 16u), byte_at(below, 24u));
    if (params.mode != 0u) {
        let changed = pack(texel.r, texel.g, texel.b, 255u);
        let opaque_below = pack(below_texel.r, below_texel.g, below_texel.b, 255u);
        let blended = composite_texel_mode(params.mode - 1u, opaque_below, changed);
        texel = vec4<u32>(
            (blended.r * below_texel.a + 127u) / 255u,
            (blended.g * below_texel.a + 127u) / 255u,
            (blended.b * below_texel.a + 127u) / 255u,
            (blended.a * below_texel.a + 127u) / 255u,
        );
    }
    if (params.coverage_planes > 0u) {
        let mix = coverage_at(index, 0u);
        if (mix < 255u) {
            texel = vec4<u32>(
                (texel.r * mix + below_texel.r * (255u - mix) + 127u) / 255u,
                (texel.g * mix + below_texel.g * (255u - mix) + 127u) / 255u,
                (texel.b * mix + below_texel.b * (255u - mix) + 127u) / 255u,
                (texel.a * mix + below_texel.a * (255u - mix) + 127u) / 255u,
            );
        }
    }
    output[index] = pack(
        unpremultiply(texel.r, texel.a),
        unpremultiply(texel.g, texel.a),
        unpremultiply(texel.b, texel.a),
        texel.a,
    );
}

// ---------------------------------------------------------------------------------------------
// Layer effects. They work in the layer's own pixel grid on a canvas grown by the effects' margin,
// in the CPU's order: what sits behind the layer is painted first, then the layer's own pixels over
// it, then what sits on top. Every pass mirrors effects.rs.
//
// A coverage plane travels in the red channel of a four channel buffer, so one layout serves the
// canvas and the planes both; the horizontal half of a Gaussian keeps its values as f32 in a buffer
// of its own, because the CPU's effects blur rounds only once, after both axes.
// ---------------------------------------------------------------------------------------------

fn plane_of(packed: u32) -> f32 {
    return f32(byte_at(packed, 0u));
}

fn pack_plane(value: f32) -> u32 {
    let byte = round_u8(value);
    return byte | (byte << 8u) | (byte << 16u) | (byte << 24u);
}

/// The mask the layer carries, in the layer's own grid, one byte per pixel.
fn mask_at(layer_index: u32) -> u32 {
    let word = coverage[layer_index / 4u];
    return (word >> ((layer_index % 4u) * 8u)) & 0xFFu;
}

/// The grown canvas: the layer's pixels at the inset, premultiplied and masked the way Surface::from_bitmap
/// and mask_by_plane leave them, with the shape - their coverage - written out as a plane.
@compute @workgroup_size(64)
fn fx_prepare(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let inset = i32(params.box_x);
    let layer_width = i32(params.sample_width);
    let layer_height = i32(params.sample_height);
    let sx = x - inset;
    let sy = y - inset;
    var texel = vec4<u32>(0u, 0u, 0u, 0u);
    if (sx >= 0 && sy >= 0 && sx < layer_width && sy < layer_height) {
        let packed = canvas[sy * layer_width + sx];
        let alpha = byte_at(packed, 24u);
        texel = vec4<u32>(
            premultiply(byte_at(packed, 0u), alpha),
            premultiply(byte_at(packed, 8u), alpha),
            premultiply(byte_at(packed, 16u), alpha),
            alpha,
        );
        if (params.coverage_planes > 0u) {
            // Surface::mask_by_plane: the alpha is scaled by the mask and the colors follow its ratio.
            let value = mask_at(u32(sy) * u32(layer_width) + u32(sx));
            if (value == 0u) {
                texel = vec4<u32>(0u, 0u, 0u, 0u);
            } else if (value < 255u && texel.a > 0u) {
                let scaled = (texel.a * value + 127u) / 255u;
                let ratio = f32(scaled) / f32(texel.a);
                texel = vec4<u32>(
                    round_u8(f32(texel.r) * ratio),
                    round_u8(f32(texel.g) * ratio),
                    round_u8(f32(texel.b) * ratio),
                    scaled,
                );
            }
        }
    }
    output[index] = pack(texel.r, texel.g, texel.b, texel.a);
}

/// The shape moved by its offset, landing on whole pixels: what falls outside is nothing.
@compute @workgroup_size(64)
fn fx_shift(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width) - i32(scalar(0u));
    let y = i32(index / params.canvas_width) - i32(scalar(1u));
    if (x < 0 || y < 0 || x >= i32(params.canvas_width) || y >= i32(params.canvas_height)) {
        output[index] = pack_plane(0.0);
        return;
    }
    output[index] = pack_plane(plane_of(canvas[y * i32(params.canvas_width) + x]));
}

/// The horizontal half of the CPU's effects blur: the border is carried outwards, and the values stay
/// unrounded in the scratch buffer so the vertical half is the only place that rounds.
@compute @workgroup_size(64)
fn fx_blur_h(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let taps = i32(scalar(0u));
    var value = 0.0;
    for (var tap = 0; tap <= taps * 2; tap = tap + 1) {
        let sx = clamp(x + tap - taps, 0, i32(params.canvas_width) - 1);
        value = value + plane_of(canvas[y * i32(params.canvas_width) + sx]) * table(u32(tap));
    }
    // The half-finished values leave as f32, so the vertical half is the only place that rounds.
    output[index] = bitcast<u32>(value);
}

/// The vertical half: the same kernel down the columns, rounded to a byte once.
@compute @workgroup_size(64)
fn fx_blur_v(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let taps = i32(scalar(0u));
    var value = 0.0;
    for (var tap = 0; tap <= taps * 2; tap = tap + 1) {
        let sy = clamp(y + tap - taps, 0, i32(params.canvas_height) - 1);
        value = value + scratch[sy * i32(params.canvas_width) + x] * table(u32(tap));
        // The scratch is the horizontal half's own values in f32, exactly as the CPU's blur holds them.
    }
    output[index] = pack_plane(value);
}

/// One sweep of the morphological filter the stroke's ring is measured from: the largest or smallest
/// value within the reach, along rows or columns. An eroding filter has nothing to hold beyond the
/// edge; a dilating one holds the edge value.
@compute @workgroup_size(64)
fn fx_extreme(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let reach = i32(scalar(0u));
    let smallest = scalar(1u) > 0.0;
    let horizontal = params.placement == 0u;
    let count = select(params.canvas_height, params.canvas_width, horizontal);
    let center = select(y, x, horizontal);
    var value = 0.0;
    for (var offset = -reach; offset <= reach; offset = offset + 1) {
        let at = center + offset;
        if (smallest && (at < 0 || at >= i32(count))) {
            continue;
        }
        let clamped = clamp(at, 0, i32(count) - 1);
        let sx = select(x, clamped, horizontal);
        let sy = select(clamped, y, horizontal);
        let sample = plane_of(canvas[sy * i32(params.canvas_width) + sx]);
        if (offset == -reach) {
            value = sample;
        } else if (smallest) {
            value = min(value, sample);
        } else {
            value = max(value, sample);
        }
    }
    output[index] = pack_plane(value);
}

/// The plane algebra: the coverage an effect paints through. The soft plane is in the canvas buffer and
/// the shape in the one beneath it.
@compute @workgroup_size(64)
fn fx_combine(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let soft = plane_of(canvas[index]);
    let shape = plane_of(beneath[index]);
    let mode = params.tap_filter;
    var value = 0.0;
    if (mode == 0u) {
        // An outer glow: the softened shape, minus the shape itself.
        value = soft * (1.0 - shape / 255.0);
    } else if (mode == 1u) {
        // Inside, uncovered by the softened copy.
        value = shape * (1.0 - soft / 255.0);
    } else if (mode == 2u) {
        value = max(soft - shape, 0.0);
    } else {
        value = max(shape - soft, 0.0);
    }
    output[index] = pack_plane(value);
}

/// Paints a solid color through a coverage, source over, at the effect's opacity. The arithmetic stays in
/// floats until the write, as the original's fill does.
@compute @workgroup_size(64)
fn fx_fill(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let source_alpha = clamp(plane_of(beneath[index]) / 255.0 * scalar(3u), 0.0, 1.0);
    var texel = vec4<u32>(byte_at(packed, 0u), byte_at(packed, 8u), byte_at(packed, 16u), byte_at(packed, 24u));
    if (source_alpha > 0.0) {
        let inverse = 1.0 - source_alpha;
        texel = vec4<u32>(
            round_u8(scalar(0u) * 255.0 * source_alpha + f32(texel.r) * inverse),
            round_u8(scalar(1u) * 255.0 * source_alpha + f32(texel.g) * inverse),
            round_u8(scalar(2u) * 255.0 * source_alpha + f32(texel.b) * inverse),
            round_u8(source_alpha * 255.0 + f32(texel.a) * inverse),
        );
    }
    output[index] = pack(texel.r, texel.g, texel.b, texel.a);
}

/// The layer's own pixels over the effects it casts, source over: what lets an effect behind the layer
/// show through the layer's transparent pixels.
@compute @workgroup_size(64)
fn fx_over(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    // Both buffers are grown canvases: the effects in one, and the layer's own placed pixels - premultiplied
    // and masked, as place_surface leaves them - in the other.
    let under = canvas[index];
    let layer = beneath[index];
    // The CPU composites them with its own texel function, not a plain source over: the backdrop's alpha
    // takes part.
    let composed = composite_texel_mode(0u, under, layer);
    output[index] = pack(composed.r, composed.g, composed.b, composed.a);
}

/// The canvas's own coverage as a plane: the shape every effect measures from, taken once and kept
/// while the fills paint colors over the canvas.
@compute @workgroup_size(64)
fn fx_shape(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    output[index] = pack_plane(f32(byte_at(canvas[index], 24u)));
}

/// The effects canvas as straight alpha, which is what the placement machinery samples.
@compute @workgroup_size(64)
fn fx_straighten(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let alpha = byte_at(packed, 24u);
    output[index] = pack(
        unpremultiply(byte_at(packed, 0u), alpha),
        unpremultiply(byte_at(packed, 8u), alpha),
        unpremultiply(byte_at(packed, 16u), alpha),
        alpha,
    );
}
// ---------------------------------------------------------------------------------------------
// The filter kernels: adjust_colored_vignette and the lens correction, per pixel, on the
// premultiplied surface the CPU's filters work in. Their formulas are the CPU's own.
// ---------------------------------------------------------------------------------------------

/// vignette_mask_at: the vignette's strength at a point of the frame, zero at its middle.
fn vignette_mask_at(px: f32, py: f32, width: f32, height: f32, midpoint: f32, roundness: f32, feather: f32) -> f32 {
    let nx = px / width * 2.0 - 1.0;
    let ny = py / height * 2.0 - 1.0;
    let square = max(abs(nx), abs(ny));
    let circle = sqrt(nx * nx + ny * ny) / 1.4142135623730951;
    let shape = (1.0 - roundness / 100.0) * 0.5;
    let distance = circle + (square - circle) * shape;
    let start = (midpoint / 100.0) * 0.85;
    var soft = feather / 100.0;
    if (soft < 0.05) {
        soft = 0.05;
    }
    let t = clamp((distance - start) / soft, 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// write_premultiplied: min(alpha, max(0, round(value * alpha))).
fn write_premultiplied(value: f32, alpha: f32) -> u32 {
    // The CPU's write_premultiplied rounds half away from zero.
    return u32(clamp(round_away(value * alpha), 0.0, alpha));
}

/// adjust_colored_vignette: the edges take the chosen color at the settings' strength, with bright pixels
/// protected by Highlights when the vignette darkens them.
@compute @workgroup_size(64)
fn fx_vignette(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let packed = canvas[index];
    var texel = vec4<u32>(byte_at(packed, 0u), byte_at(packed, 8u), byte_at(packed, 16u), byte_at(packed, 24u));
    let fills_clear = scalar(7u) > 0.5;
    if (texel.a == 0u && !fills_clear) {
        output[index] = packed;
        return;
    }
    // The mask arrives ready: the CPU builds it in f64, because its ramp is steep enough that an f32
    // evaluation of the same formula lands three levels away where the feather is small.
    let mask = scratch[index];
    if (mask <= 0.0) {
        output[index] = packed;
        return;
    }
    let alpha = f32(texel.a) / 255.0;
    var straight = vec3<f32>(0.0);
    var bright = 0.0;
    if (texel.a != 0u) {
        straight = vec3<f32>(
            min(f32(texel.r) / f32(texel.a), 1.0),
            min(f32(texel.g) / f32(texel.a), 1.0),
            min(f32(texel.b) / f32(texel.a), 1.0),
        );
        let luminance = 0.2126 * straight.r + 0.7152 * straight.g + 0.0722 * straight.b;
        bright = clamp((luminance - 0.45) / 0.55, 0.0, 1.0);
    }
    let strength = scalar(2u);
    let color = vec3<f32>(scalar(12u), scalar(13u), scalar(14u));
    let effect = strength * mask * (1.0 - scalar(6u) / 100.0 * bright);
    if (!fills_clear) {
        // Only the pixels that are there change color; their coverage stays as it was.
        output[index] = pack(
            write_premultiplied(straight.r + (color.r - straight.r) * effect, f32(texel.a)),
            write_premultiplied(straight.g + (color.g - straight.g) * effect, f32(texel.a)),
            write_premultiplied(straight.b + (color.b - straight.b) * effect, f32(texel.a)),
            texel.a,
        );
        return;
    }
    // The color painted over the pixel at effect: an opaque pixel moves toward it, a clear one takes it on.
    let out = alpha + effect * (1.0 - alpha);
    if (out <= 0.0) {
        output[index] = packed;
        return;
    }
    let alpha_out = min(out * 255.0, 255.0);
    let alpha_byte = round_u8(alpha_out);
    let value = (color * effect + straight * alpha * (1.0 - effect)) / out;
    output[index] = pack(
        write_premultiplied(value.r, alpha_out),
        write_premultiplied(value.g, alpha_out),
        write_premultiplied(value.b, alpha_out),
        alpha_byte,
    );
}

/// lens_correction: each pixel reads the source at a radially scaled position, bilinear, with everything
/// outside the frame left transparent.
@compute @workgroup_size(64)
fn fx_lens(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let width = f32(params.canvas_width);
    let height = f32(params.canvas_height);
    let x = f32(index % params.canvas_width);
    let y = f32(index / params.canvas_width);
    let cx = width * 0.5;
    let cy = height * 0.5;
    let half_diagonal = cx * cx + cy * cy;
    let dx = x + 0.5 - cx;
    let dy = y + 0.5 - cy;
    let scale = 1.0 - scalar(0u) * (dx * dx + dy * dy) / half_diagonal;
    let sx = cx + dx * scale - 0.5;
    let sy = cy + dy * scale - 0.5;
    let fx = floor(sx);
    let fy = floor(sy);
    let wx = sx - fx;
    let wy = sy - fy;
    var sums = vec4<f32>(0.0);
    for (var j = 0; j < 2; j = j + 1) {
        let sample_y = i32(fy) + j;
        if (sample_y < 0 || sample_y >= i32(params.canvas_height)) {
            continue;
        }
        let weight_y = select(1.0 - wy, wy, j == 1);
        if (weight_y == 0.0) {
            continue;
        }
        for (var i = 0; i < 2; i = i + 1) {
            let sample_x = i32(fx) + i;
            if (sample_x < 0 || sample_x >= i32(params.canvas_width)) {
                continue;
            }
            let weight = weight_y * select(1.0 - wx, wx, i == 1);
            if (weight == 0.0) {
                continue;
            }
            let packed = canvas[sample_y * i32(params.canvas_width) + sample_x];
            sums = sums + vec4<f32>(
                f32(byte_at(packed, 0u)) * weight,
                f32(byte_at(packed, 8u)) * weight,
                f32(byte_at(packed, 16u)) * weight,
                f32(byte_at(packed, 24u)) * weight,
            );
        }
    }
    output[index] = pack(round_u8(sums.r), round_u8(sums.g), round_u8(sums.b), round_u8(sums.a));
}
// ---------------------------------------------------------------------------------------------
// Bloom and tonal contrast. Both blur through adjustment::gaussian_blur - the same kernel the blur
// adjustment uses, transparent past the edges and rounded between the axes - which is the pass above.
// ---------------------------------------------------------------------------------------------

/// The highlights a bloom spreads: the bright parts of a pixel, weighted by how far past the knee their
/// luminance is.
@compute @workgroup_size(64)
fn fx_bloom_highlights(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    if (byte_at(packed, 24u) == 0u) {
        output[index] = packed;
        return;
    }
    let alpha = f32(byte_at(packed, 24u));
    let straight = vec3<f32>(
        f32(byte_at(packed, 0u)) / alpha,
        f32(byte_at(packed, 8u)) / alpha,
        f32(byte_at(packed, 16u)) / alpha,
    );
    let luminance = 0.2126 * straight.r + 0.7152 * straight.g + 0.0722 * straight.b;
    let knee = scalar(0u);
    let weight = clamp((luminance - knee) / (1.0 - knee), 0.0, 1.0);
    output[index] = pack(
        round_u8(f32(byte_at(packed, 0u)) * weight),
        round_u8(f32(byte_at(packed, 8u)) * weight),
        round_u8(f32(byte_at(packed, 16u)) * weight),
        byte_at(packed, 24u),
    );
}

/// The blurred highlights added back, never past the pixel's own coverage.
@compute @workgroup_size(64)
fn fx_bloom_add(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let glow = beneath[index];
    let alpha = f32(byte_at(packed, 24u));
    let intensity = scalar(0u);
    output[index] = pack(
        round_u8(min(f32(byte_at(packed, 0u)) + f32(byte_at(glow, 0u)) * intensity, alpha)),
        round_u8(min(f32(byte_at(packed, 8u)) + f32(byte_at(glow, 8u)) * intensity, alpha)),
        round_u8(min(f32(byte_at(packed, 16u)) + f32(byte_at(glow, 16u)) * intensity, alpha)),
        byte_at(packed, 24u),
    );
}

/// tonal_smooth: an S-curve between two tones.
fn tonal_smooth(low: f32, high: f32, value: f32) -> f32 {
    let t = clamp((value - low) / (high - low), 0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
}

/// adjust_tonal_contrast: local detail, taken from a blurred copy, is added back with a weight that
/// depends on how dark the local tone is.
@compute @workgroup_size(64)
fn fx_tonal(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let base = beneath[index];
    if (byte_at(packed, 24u) == 0u || byte_at(base, 24u) == 0u) {
        output[index] = packed;
        return;
    }
    let alpha = f32(byte_at(packed, 24u));
    let base_alpha = f32(byte_at(base, 24u));
    var straight = vec3<f32>(0.0);
    var base_straight = vec3<f32>(0.0);
    for (var channel = 0u; channel < 3u; channel = channel + 1u) {
        let shift = channel * 8u;
        straight[channel] = min(f32(byte_at(packed, shift)) / alpha, 1.0);
        base_straight[channel] = min(f32(byte_at(base, shift)) / base_alpha, 1.0);
    }
    let luminance = 0.2126 * straight.r + 0.7152 * straight.g + 0.0722 * straight.b;
    let base_luminance = 0.2126 * base_straight.r + 0.7152 * base_straight.g + 0.0722 * base_straight.b;
    let shadow_weight = 1.0 - tonal_smooth(0.15, 0.5, base_luminance);
    let highlight_weight = tonal_smooth(0.5, 0.85, base_luminance);
    let midtone_weight = 1.0 - shadow_weight - highlight_weight;
    let weight = (scalar(1u) * shadow_weight + scalar(2u) * midtone_weight + scalar(3u) * highlight_weight) / 100.0;
    let detail = luminance - base_luminance;
    // tanh is not in WGSL's core; this is the same function written from its exponential.
    let doubled = 2.0 * (detail * 6.0);
    let tanh_detail = clamp((exp(doubled) - 1.0) / (exp(doubled) + 1.0), -1.0, 1.0);
    let delta = 0.18 * tanh_detail * weight * scalar(0u) * (4.0 * luminance * (1.0 - luminance));
    output[index] = pack(
        write_premultiplied(straight.r + delta, alpha),
        write_premultiplied(straight.g + delta, alpha),
        write_premultiplied(straight.b + delta, alpha),
        byte_at(packed, 24u),
    );
}
// ---------------------------------------------------------------------------------------------
// The dither's ordered styles. adjust_tone, the threshold matrix and the quantization are the CPU's
// own, per pixel; the styles whose marks are halftone geometry or glyphs, and the ones that diffuse
// their error into their neighbours, are not here.
// ---------------------------------------------------------------------------------------------

/// adjust_tone: density darkens (positive) or lightens as a gamma, then contrast pivots on mid gray.
fn dither_tone(value: f32, gamma: f32, contrast: f32) -> f32 {
    let toned = pow(clamp(value, 0.0, 1.0), gamma);
    return clamp((toned - 0.5) * contrast + 0.5, 0.0, 1.0);
}

/// The ordered matrix a pixel's threshold comes from: Bayer 2 x 2, 4 x 4, or the 8 x 8 the smaller
/// screens are the corners of.
fn dither_threshold(style: u32, x: i32, y: i32) -> f32 {
    if (style == 0u) {
        let matrix = array<u32, 4>(0u, 2u, 3u, 1u);
        return (f32(matrix[(y & 1) * 2 + (x & 1)]) + 0.5) / 4.0;
    }
    if (style == 1u) {
        let matrix = array<u32, 16>(0u, 8u, 2u, 10u, 12u, 4u, 14u, 6u, 3u, 11u, 1u, 9u, 15u, 7u, 13u, 5u);
        return (f32(matrix[(y & 3) * 4 + (x & 3)]) + 0.5) / 16.0;
    }
    let bayer = array<u32, 64>(
        0u, 32u, 8u, 40u, 2u, 34u, 10u, 42u, 48u, 16u, 56u, 24u, 50u, 18u, 58u, 26u,
        12u, 44u, 4u, 36u, 14u, 46u, 6u, 38u, 60u, 28u, 52u, 20u, 62u, 30u, 54u, 22u,
        3u, 35u, 11u, 43u, 1u, 33u, 9u, 41u, 51u, 19u, 59u, 27u, 49u, 17u, 57u, 25u,
        15u, 47u, 7u, 39u, 13u, 45u, 5u, 37u, 63u, 31u, 55u, 23u, 61u, 29u, 53u, 21u,
    );
    return (f32(bayer[(y & 7) * 8 + (x & 7)]) + 0.5) / 64.0;
}

/// A quantized tone through its threshold, the way the ordered screens do it.
fn dither_ordered(value: f32, threshold: f32, levels: f32) -> f32 {
    let steps = levels - 1.0;
    let quantized = floor(clamp(value, 0.0, 1.0) * steps + threshold);
    return min(quantized, steps) / steps;
}

/// dither_write: the tone painted back through the pixel's own coverage.
fn dither_write(red: f32, green: f32, blue: f32, alpha: f32) -> vec3<u32> {
    return vec3<u32>(
        round_u8(clamp(red, 0.0, 1.0) * alpha * 255.0),
        round_u8(clamp(green, 0.0, 1.0) * alpha * 255.0),
        round_u8(clamp(blue, 0.0, 1.0) * alpha * 255.0),
    );
}

/// One ordered dither: Bayer 2, 4 or 8, with either the tone's own colors or one plane of them.
@compute @workgroup_size(64)
fn fx_dither_ordered(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let alpha_byte = byte_at(packed, 24u);
    if (alpha_byte == 0u) {
        output[index] = packed;
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let alpha = f32(alpha_byte) / 255.0;
    let scale = 1.0 / f32(alpha_byte);
    let red = f32(byte_at(packed, 0u)) * scale;
    let green = f32(byte_at(packed, 8u)) * scale;
    let blue = f32(byte_at(packed, 16u)) * scale;
    let gamma = scalar(0u);
    let contrast = scalar(1u);
    let levels = scalar(2u);
    // The screen's size travels in the pass's mode word, which is the field at 36.
    let threshold = dither_threshold(params.tap_filter, x, y);
    // The tone's own colors quantize each channel; one plane quantizes the luminance and paints the
    // dark to light ramp through it.
    if (params.placement == 1u) {
        let toned = dither_ordered(dither_tone(red, gamma, contrast), threshold, levels);
        let toned_g = dither_ordered(dither_tone(green, gamma, contrast), threshold, levels);
        let toned_b = dither_ordered(dither_tone(blue, gamma, contrast), threshold, levels);
        let out = dither_write(toned, toned_g, toned_b, alpha);
        output[index] = pack(out.r, out.g, out.b, alpha_byte);
        return;
    }
    let luminance = 0.2126 * red + 0.7152 * green + 0.0722 * blue;
    let value = dither_ordered(dither_tone(luminance, gamma, contrast), threshold, levels);
    let dark = vec3<f32>(scalar(3u), scalar(4u), scalar(5u));
    let light = vec3<f32>(scalar(6u), scalar(7u), scalar(8u));
    let out = dither_write(
        dark.r + (light.r - dark.r) * value,
        dark.g + (light.g - dark.g) * value,
        dark.b + (light.b - dark.b) * value,
        alpha,
    );
    output[index] = pack(out.r, out.g, out.b, alpha_byte);
}
/// How much of a halftone cell a point must be covered by before it is marked, for each screen shape.
/// The shapes grow from the cell's middle as coverage rises.
fn dither_spot(style: u32, u: f32, v: f32) -> f32 {
    let au = abs(u);
    let av = abs(v);
    if (style == 1u) {
        // Dots: a disc of the cell's area.
        return 3.141592653589793 * (u * u + v * v);
    }
    if (style == 2u) {
        // Lines: horizontal bands.
        return av * 2.0;
    }
    // Diamonds: a square turned forty five degrees.
    return au + av;
}

/// The marks a dither draws: the old Mac fill patterns, and the dot, line and diamond screens. One pixel
/// per invocation, from the tone plane the threshold styles also use.
@compute @workgroup_size(64)
fn fx_dither_marks(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let alpha_byte = byte_at(packed, 24u);
    if (alpha_byte == 0u) {
        output[index] = packed;
        return;
    }
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let alpha = f32(alpha_byte) / 255.0;
    let scale = 1.0 / f32(alpha_byte);
    let red = f32(byte_at(packed, 0u)) * scale;
    let green = f32(byte_at(packed, 8u)) * scale;
    let blue = f32(byte_at(packed, 16u)) * scale;
    let toned = dither_tone(0.2126 * red + 0.7152 * green + 0.0722 * blue, scalar(0u), scalar(1u));
    let light_on_dark = scalar(9u) > 0.5;
    let value = select(1.0 - toned, toned, light_on_dark);
    let style = params.tap_filter;
    var amount = 0.0;
    if (style == 0u) {
        // The pattern whose density is closest to the tone, then its bit for this pixel.
        // The CPU picks the pattern with (coverage * 16).round(), half away from zero.
        let slot = min(u32(round_away(value * 16.0)), 16u);
        // The bit is read as a mask rather than as a shift: the two say the same thing, and a mask keeps
        // the row, the width and the sign in one type.
        let row = dither_pattern(slot, y & 7);
        let bit = u32(7 - (x & 7));
        amount = select(0.0, 1.0, (row & (1u << bit)) != 0u);
    } else {
        let cell = max(scalar(10u), 2.0);
        let radians = scalar(11u);
        let fx = f32(x) + 0.5;
        let fy = f32(y) + 0.5;
        var u = (fx * cos(radians) + fy * sin(radians)) / cell;
        var v = (-fx * sin(radians) + fy * cos(radians)) / cell;
        u = u - floor(u) - 0.5;
        v = v - floor(v) - 0.5;
        amount = select(0.0, 1.0, value > dither_spot(style, u, v));
    }
    // A probe build can ask the pass to report its own intermediates instead of the pixel: the tone in the
    // red channel, the pattern slot in the green, and the mark in the blue.
    if (scalar(12u) > 0.5) {
        // Which branch the pass read, the tone it worked from, and the mark it ended with.
        output[index] = pack(style, round_u8(value * 255.0), round_u8(amount * 255.0), 255u);
        return;
    }
    // The marks paint between the two ramp ends, or between the tone's own color and paper.
    // The two ramp ends come from the dark and light the ordered screens read too, turned over when the
    // screen is light on dark.
    let dark = vec3<f32>(scalar(3u), scalar(4u), scalar(5u));
    let light = vec3<f32>(scalar(6u), scalar(7u), scalar(8u));
    let ink = select(dark, light, light_on_dark);
    let paper = select(light, dark, light_on_dark);
    var ramped = vec3<f32>(0.0);
    if (params.placement == 1u) {
        let plain = select(vec3<f32>(1.0), vec3<f32>(0.0), light_on_dark);
        ramped = plain + (vec3<f32>(red, green, blue) - plain) * amount;
    } else {
        ramped = paper + (ink - paper) * amount;
    }
    let out = dither_write(ramped.r, ramped.g, ramped.b, alpha);
    output[index] = pack(out.r, out.g, out.b, alpha_byte);
}

/// One row of one of the seventeen 8 x 8 fill patterns, as its byte.
fn dither_pattern(slot: u32, row: i32) -> u32 {
    // The table is the CPU's own, one row per entry, seventeen patterns of eight rows.
    let rows = array<u32, 136>(
        0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u, 0x00u,
        0x80u, 0x00u, 0x00u, 0x00u, 0x08u, 0x00u, 0x00u, 0x00u,
        0x88u, 0x00u, 0x22u, 0x00u, 0x88u, 0x00u, 0x22u, 0x00u,
        0x80u, 0x40u, 0x20u, 0x10u, 0x08u, 0x04u, 0x02u, 0x01u,
        0x88u, 0x22u, 0x88u, 0x22u, 0x88u, 0x22u, 0x88u, 0x22u,
        0x00u, 0xFFu, 0x00u, 0x00u, 0x00u, 0xFFu, 0x00u, 0x00u,
        0x11u, 0x22u, 0x44u, 0x88u, 0x11u, 0x22u, 0x44u, 0x88u,
        0xAAu, 0x00u, 0xAAu, 0x00u, 0xAAu, 0x00u, 0xAAu, 0x00u,
        0x88u, 0x55u, 0x22u, 0x55u, 0x88u, 0x55u, 0x22u, 0x55u,
        0xFFu, 0x80u, 0x80u, 0x80u, 0xFFu, 0x08u, 0x08u, 0x08u,
        0xAAu, 0x55u, 0xAAu, 0x55u, 0xAAu, 0x55u, 0xAAu, 0x55u,
        0x81u, 0x42u, 0x24u, 0x18u, 0x18u, 0x24u, 0x42u, 0x81u,
        0x77u, 0xAAu, 0xDDu, 0xAAu, 0x77u, 0xAAu, 0xDDu, 0xAAu,
        0xEEu, 0xDDu, 0xBBu, 0x77u, 0xEEu, 0xDDu, 0xBBu, 0x77u,
        0x77u, 0xFFu, 0xDDu, 0xFFu, 0x77u, 0xFFu, 0xDDu, 0xFFu,
        0x7Fu, 0xFFu, 0xFFu, 0xFFu, 0xF7u, 0xFFu, 0xFFu, 0xFFu,
        0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu, 0xFFu,
    );
    return rows[slot * 8u + u32(row)];
}
/// DITHER_SCANLINES: each line of the screen scans the picture, its tone the average of the rows it
/// covers, and the beam is drawn a little brighter than the picture to make up for the dark screen
/// between the lines. Every pixel works out its own line's average, so no pass of its own is needed.
@compute @workgroup_size(64)
fn fx_scanlines(@builtin(global_invocation_id) invocation: vec3<u32>) {
    let index = invocation.x + invocation.y * params.groups_x * 64u;
    if (index >= params.count) {
        return;
    }
    let packed = canvas[index];
    let alpha_byte = byte_at(packed, 24u);
    if (alpha_byte == 0u) {
        output[index] = packed;
        return;
    }
    let width = i32(params.canvas_width);
    let height = i32(params.canvas_height);
    let x = i32(index % params.canvas_width);
    let y = i32(index / params.canvas_width);
    let alpha = f32(alpha_byte);
    let scale = 1.0 / alpha;
    let red = f32(byte_at(packed, 0u)) * scale;
    let green = f32(byte_at(packed, 8u)) * scale;
    let blue = f32(byte_at(packed, 16u)) * scale;
    let gamma = scalar(0u);
    let contrast = scalar(1u);
    let original = params.placement == 1u;
    let spacing = max(scalar(9u), 2.0);
    let middle = spacing / 2.0;
    let dots = scalar(10u);
    let line = y / i32(spacing);
    let top = line * i32(spacing);
    let bottom = min(top + i32(spacing), height);
    // The wobble: a slow wave down the screen with a quicker one over it.
    let wave = sin(f32(line) * 0.45) * 0.7 + sin(f32(line) * 1.7 + 1.3) * 0.3;
    let shift = i32(round_away(scalar(11u) * wave));
    // Where this pixel's bead reads from: the line is broken into beads, one every spacing.
    let along = ((f32(x) + 0.5) % spacing) - middle;
    let centered = i32(round_away(f32(x) - along * dots));
    let at = clamp(centered, 0, width - 1);
    // The line's own average down the column the bead reads from, recomputed here.
    var tone = vec3<f32>(0.0);
    var used = 0;
    let sx = at - shift;
    if (sx >= 0 && sx < width) {
        for (var yy = top; yy < bottom; yy = yy + 1) {
            let sample = canvas[yy * width + sx];
            if (byte_at(sample, 24u) == 0u) {
                continue;
            }
            let sample_scale = 1.0 / f32(byte_at(sample, 24u));
            let sample_red = f32(byte_at(sample, 0u)) * sample_scale;
            let sample_green = f32(byte_at(sample, 8u)) * sample_scale;
            let sample_blue = f32(byte_at(sample, 16u)) * sample_scale;
            if (original) {
                tone = tone + vec3<f32>(
                    dither_tone(sample_red, gamma, contrast),
                    dither_tone(sample_green, gamma, contrast),
                    dither_tone(sample_blue, gamma, contrast),
                );
            } else {
                let luminance = 0.2126 * sample_red + 0.7152 * sample_green + 0.0722 * sample_blue;
                tone = tone + vec3<f32>(dither_tone(luminance, gamma, contrast));
            }
            used = used + 1;
        }
    }
    if (used > 0) {
        tone = tone / f32(used);
    }
    let screen = vec3<f32>(scalar(3u), scalar(4u), scalar(5u));
    let phosphor = vec3<f32>(scalar(6u), scalar(7u), scalar(8u));
    var value = 0.0;
    var lit = vec3<f32>(0.0);
    if (original) {
        lit = tone;
        value = 0.2126 * tone.r + 0.7152 * tone.g + 0.0722 * tone.b;
    } else {
        value = tone.r;
        lit = screen + (phosphor - screen) * value;
    }
    lit = lit * 1.35;
    let beam = middle * (0.2 + 0.5 * sqrt(clamp(value, 0.0, 1.0)));
    let across = along * dots;
    let offset = abs(f32(y - top) + 0.5 - middle);
    let distance = sqrt(offset * offset + across * across);
    let cover = clamp(beam - distance + 0.5, 0.0, 1.0);
    let base = select(screen, vec3<f32>(0.0), original);
    // dither_write takes the pixel's coverage as a fraction, which is what the CPU hands it: the raw byte
    // would scale the result by another 255.
    let coverage = alpha / 255.0;
    let out = dither_write(
        base.r + (lit.r - base.r) * cover,
        base.g + (lit.g - base.g) * cover,
        base.b + (lit.b - base.b) * cover,
        coverage,
    );
    // A probe build reports the bytes this pass is about to write, premultiplied: if these are right, what
    // goes wrong is the straightening after them.
    if (scalar(12u) > 0.5) {
        // The tone the line average gave, the cover that came of it, and the column it read.
        output[index] = pack(round_u8(value * 255.0), round_u8(cover * 255.0), u32(clamp(sx, 0, width)), 255u);
        return;
    }
    output[index] = pack(out.r, out.g, out.b, alpha_byte);
}
