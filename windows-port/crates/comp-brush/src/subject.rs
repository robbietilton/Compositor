//! Subject and background extraction without a model.
//!
//! The macOS app asks Vision for a foreground instance mask
//! (`VNGenerateForegroundInstanceMaskRequest`, see `Document/SubjectRemoval.swift`). Windows has no
//! equivalent and this build ships no model, so this module is a **classical, deterministic
//! substitute**: a border color model, a center prior, an iterated binary segmentation, a guided
//! filter on the image's own edges and a morphology pass. It is honest about what it is - see the
//! "quality against Vision" section in `NOTES.md` - and it is built to be testable: no randomness,
//! no hash-map ordering, every loop in raster order, so the same pixels always give the same matte.
//!
//! Pipeline, in order:
//!
//! 1. **Border color model.** The outer band of the image (and every transparent pixel) is taken as
//!    certain background, and its colors are histogrammed. The same is done for the center of the
//!    image minus anything that already looks like background, as the first subject model. This is
//!    the trimap seeding step of GrabCut (Rother, Kolmogorov & Blake, 2004), with quantized color
//!    histograms instead of Gaussian mixtures: histograms are exactly reproducible, which matters
//!    more here than the extra accuracy a GMM would buy.
//! 2. **Data terms and the center prior.** Every pixel costs `-ln P(color | subject)` to call it a
//!    subject and `-ln P(color | background)` to call it background. A smooth radial prior pulls the
//!    center toward subject and the edges toward background, which is what keeps a uniform image and
//!    a subject that shares its color with the background from collapsing.
//! 3. **Iterated refinement.** The two models are re-estimated from the current labeling and the
//!    labeling is re-solved by iterated conditional modes (Besag, 1986) on the binary field
//!    `sum D(l_p) + sum lambda w_pq [l_p != l_q]`, with the contrast-sensitive weights of GrabCut's
//!    smoothness term. ICM is the cheap, deterministic cousin of the graph cut GrabCut uses; on the
//!    energy above it reaches a local minimum.
//! 4. **Cleanup.** Connected components smaller than a fraction of the largest are dropped and small
//!    enclosed holes are filled, so specks and pinholes do not survive into the matte.
//! 5. **Edge refinement.** A guided filter (He, Sun & Tang, 2010) with the image's luminance as the
//!    guide, ported from the app's own `Document/GuidedMatte.swift`, pulls the matte onto the image's
//!    real edges. This is the same "Refine Edges" the macOS panel offers.

use comp_core::{Bitmap8, Error, Gray8, Result};

/// Square of the guided filter's regularization. Small, so fine strands in the guide still count;
/// the same 1e-4 `GuidedMatte.refine` uses.
const EDGE_EPSILON: f32 = 1e-4;
/// Largest data cost before clamping. `ln(1e-6)`, so an impossible color is expensive but finite.
const MAX_DATA_COST: f64 = 13.8;

/// Settings for the classical extractor. Every value is clamped to the documented range, so no
/// combination can panic or divide by zero; the defaults are tuned for ordinary photographs.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct SubjectOptions {
    /// Share of the shorter side taken as certain background, 0.01-0.25. Bigger is safer on busy
    /// edges and worse when the subject runs off the frame.
    pub border_fraction: f64,
    /// Histogram bins per channel, 2-32. More bins separate close colors and need more pixels.
    pub color_bins: u32,
    /// Weight of the center prior, 0-4. 0 ignores it; the default keeps a same-colored subject.
    pub center_prior: f64,
    /// Refinement sweeps, 0-12. Each one re-estimates both color models.
    pub iterations: u32,
    /// Smoothness weight, 0-8: how strongly a label boundary is penalized.
    pub smoothing: f64,
    /// Components (and holes) smaller than this share of the largest are dropped, 0-1.
    pub min_component_fraction: f64,
    /// Guided-filter radius in pixels for the final edge pass, 0-64. 0 keeps a hard matte.
    pub edge_radius: f64,
}

impl Default for SubjectOptions {
    fn default() -> Self {
        SubjectOptions {
            border_fraction: 0.08,
            color_bins: 8,
            center_prior: 1.2,
            iterations: 4,
            smoothing: 1.0,
            min_component_fraction: 0.02,
            edge_radius: 1.5,
        }
    }
}

impl SubjectOptions {
    /// The same settings with every value inside its documented range, so a caller can pass
    /// anything without a panic.
    pub fn clamped(&self) -> SubjectOptions {
        SubjectOptions {
            border_fraction: finite_or(self.border_fraction, 0.08).clamp(0.01, 0.25),
            color_bins: self.color_bins.clamp(2, 32),
            center_prior: finite_or(self.center_prior, 0.0).clamp(0.0, 4.0),
            iterations: self.iterations.min(12),
            smoothing: finite_or(self.smoothing, 0.0).clamp(0.0, 8.0),
            min_component_fraction: finite_or(self.min_component_fraction, 0.0).clamp(0.0, 1.0),
            edge_radius: finite_or(self.edge_radius, 0.0).clamp(0.0, 64.0),
        }
    }
}

fn finite_or(value: f64, fallback: f64) -> f64 {
    if value.is_finite() {
        value
    } else {
        fallback
    }
}

/// White where the image is subject, black where it is background, at the image's resolution.
///
/// Deterministic by construction: there is no random sampling anywhere in the pipeline, so two
/// identical images always give identical bytes. That is a stronger promise than a fixed seed.
pub fn select_subject(image: &Bitmap8, options: &SubjectOptions) -> Gray8 {
    let width = image.width();
    let height = image.height();
    let matte = Gray8::new(width, height);
    if width == 0 || height == 0 {
        return matte;
    }
    let options = options.clamped();
    let (w, h) = (width as usize, height as usize);
    let count = w * h;
    let band = border_band(width, height, options.border_fraction);
    let center = center_field(width, height);
    let mut forced_background = vec![false; count];
    let mut opaque = vec![false; count];
    for y in 0..h {
        for x in 0..w {
            let index = y * w + x;
            let inside_band = (x as i64) < band
                || (y as i64) < band
                || (x as i64) >= width as i64 - band
                || (y as i64) >= height as i64 - band;
            let pixel = image.get(x as u32, y as u32);
            opaque[index] = pixel[3] >= 128;
            forced_background[index] = inside_band || !opaque[index];
        }
    }
    if forced_background.iter().all(|forced| *forced) {
        // Every pixel is border or transparent: there is no interior to call a subject.
        return matte;
    }

    // 1. Seed the two color models: the border band is background, and the middle is the first
    //    guess at the subject, minus whatever already looks like the background.
    let mut background_model = ColorModel::build(image, options.color_bins, &forced_background);
    let mut subject_seed: Vec<bool> = (0..count)
        .map(|index| opaque[index] && !forced_background[index] && center[index] >= 0.5)
        .collect();
    if !subject_seed.iter().any(|selected| *selected) {
        // No center pixels (a tiny image): fall back to every interior pixel.
        subject_seed = (0..count).map(|index| opaque[index] && !forced_background[index]).collect();
    }
    let mut subject_model = ColorModel::build(image, options.color_bins, &subject_seed);

    // 2. First labeling from the data terms and the center prior.
    let mut labels = vec![false; count];
    let mut costs =
        data_costs(image, &subject_model, &background_model, &center, &forced_background, options.center_prior);
    for index in 0..count {
        if !forced_background[index] {
            labels[index] = costs.0[index] <= costs.1[index];
        }
    }

    // 3. Iterate: re-estimate both models from the current labeling, then re-solve.
    let beta = contrast_beta(image);
    for _ in 0..options.iterations {
        let subject_selected: Vec<bool> = (0..count).map(|index| labels[index] && opaque[index]).collect();
        let background_selected: Vec<bool> =
            (0..count).map(|index| (!labels[index] && opaque[index]) || forced_background[index]).collect();
        let next_subject = ColorModel::build(image, options.color_bins, &subject_selected);
        let next_background = ColorModel::build(image, options.color_bins, &background_selected);
        if next_subject.is_empty() || next_background.is_empty() {
            break;
        }
        subject_model = next_subject;
        background_model = next_background;
        costs = data_costs(image, &subject_model, &background_model, &center, &forced_background, options.center_prior);
        if !refine_labels(image, &mut labels, &costs, &forced_background, options.smoothing, beta) {
            break;
        }
    }

    // 4. Cleanup: drop specks, fill pinholes.
    keep_components(&mut labels, w, h, options.min_component_fraction);
    fill_holes(&mut labels, w, h, options.min_component_fraction);
    let hard = matte_from_labels(&labels, w, h);

    // 5. Pull the matte onto the image's own edges, then put the certain background back: the
    //    guided filter reads a window, so near the frame it can lift a little subject back into
    //    the band the trimap ruled out. Those pixels are background by construction.
    let mut refined = if options.edge_radius >= 0.5 {
        refine_edges(image, &hard, options.edge_radius).unwrap_or(hard)
    } else {
        hard
    };
    for (index, forced) in forced_background.iter().enumerate() {
        if *forced {
            refined.pixels_mut()[index] = 0;
        }
    }
    refined
}

/// Everything that is not the subject: the exact complement of `select_subject`.
pub fn select_background(image: &Bitmap8, options: &SubjectOptions) -> Gray8 {
    let mut mask = select_subject(image, options);
    for value in mask.pixels_mut() {
        *value = 255 - *value;
    }
    mask
}

/// The image with its alpha multiplied by the matte: what "remove background" hands back.
///
/// The straight color is left alone, so a later edit can still recover the pixels the matte hid.
pub fn remove_background(image: &Bitmap8, matte: &Gray8) -> Result<Bitmap8> {
    if image.width() != matte.width() || image.height() != matte.height() {
        return Err(Error::BufferSize {
            got: matte.byte_len(),
            expected: image.pixel_count(),
            width: image.width(),
            height: image.height(),
        });
    }
    let mut out = image.clone();
    let width = image.width() as usize;
    for y in 0..image.height() as usize {
        let coverage = matte.row(y as u32);
        let row = out.row_mut(y as u32);
        for x in 0..width {
            let alpha = row[x * 4 + 3] as u32;
            row[x * 4 + 3] = ((alpha * coverage[x] as u32 + 127) / 255) as u8;
        }
    }
    Ok(out)
}

/// Pulls a matte onto the image's own edges with a guided filter, `radius` pixels wide. This is
/// the app's "Refine Edges": a radius below half a pixel returns the matte unchanged, and the cost
/// does not grow with the radius, because every mean is two running-sum passes.
pub fn refine_edges(image: &Bitmap8, matte: &Gray8, radius: f64) -> Result<Gray8> {
    if image.width() != matte.width() || image.height() != matte.height() {
        return Err(Error::BufferSize {
            got: matte.byte_len(),
            expected: image.pixel_count(),
            width: image.width(),
            height: image.height(),
        });
    }
    // A window wider than an eighth of the shorter side would average a small subject into a flat
    // gray, so the effective radius stops there however large the request is.
    let widest = (image.width().min(image.height()) / 8).max(1) as usize;
    let steps = (finite_or(radius, 0.0).clamp(0.0, 64.0).round() as usize).min(widest);
    if steps == 0 || image.is_empty() {
        return Ok(matte.clone());
    }
    let (w, h) = (image.width() as usize, image.height() as usize);
    let guide = luma(image);
    let mask: Vec<f32> = matte.pixels().iter().map(|value| *value as f32 / 255.0).collect();
    let filtered = guided_filter(&mask, &guide, w, h, steps, EDGE_EPSILON);
    let mut out = Gray8::new(image.width(), image.height());
    for (index, value) in filtered.iter().enumerate() {
        out.pixels_mut()[index] = (value * 255.0).round().clamp(0.0, 255.0) as u8;
    }
    Ok(out)
}

/// The width of the certain-background band, at least one pixel and never the whole image.
fn border_band(width: u32, height: u32, fraction: f64) -> i64 {
    let shorter = width.min(height) as f64;
    let band = (shorter * fraction).round().max(1.0);
    band.min((shorter / 2.0).floor().max(1.0)) as i64
}

/// A smooth elliptical prior: 1 at the center, fading to about 0.1 at the corners.
fn center_field(width: u32, height: u32) -> Vec<f32> {
    let (w, h) = (width as f64, height as f64);
    let mut field = vec![0f32; (width * height) as usize];
    for y in 0..height as usize {
        let ny = ((y as f64 + 0.5) - h / 2.0) / (h / 2.0).max(1.0);
        for x in 0..width as usize {
            let nx = ((x as f64 + 0.5) - w / 2.0) / (w / 2.0).max(1.0);
            field[y * width as usize + x] = (-2.2 * (nx * nx + ny * ny)).exp() as f32;
        }
    }
    field
}

/// Quantized color histogram of one region, with Laplace smoothing: an unseen color stays
/// possible, just unlikely.
struct ColorModel {
    bins: u32,
    counts: Vec<u32>,
    total: u64,
    occupied: u64,
}

impl ColorModel {
    fn build(image: &Bitmap8, bins: u32, selected: &[bool]) -> ColorModel {
        let bins = bins.clamp(2, 32);
        let mut counts = vec![0u32; (bins * bins * bins) as usize];
        let mut total = 0u64;
        for (index, pixel) in image.pixels().chunks_exact(4).enumerate() {
            if !selected.get(index).copied().unwrap_or(false) || pixel[3] < 128 {
                continue;
            }
            counts[Self::cell(pixel, bins)] += 1;
            total += 1;
        }
        let occupied = counts.iter().filter(|count| **count > 0).count() as u64;
        ColorModel { bins, counts, total, occupied }
    }

    fn is_empty(&self) -> bool {
        self.total == 0
    }

    fn cell(pixel: &[u8], bins: u32) -> usize {
        let bin = |channel: u8| ((channel as usize * bins as usize) / 256).min(bins as usize - 1);
        (bin(pixel[0]) * bins as usize + bin(pixel[1])) * bins as usize + bin(pixel[2])
    }

    fn probability(&self, pixel: [u8; 4]) -> f64 {
        if self.total == 0 {
            return 1.0 / self.counts.len() as f64;
        }
        let count = self.counts[Self::cell(&pixel, self.bins)] as f64;
        // Half a count of smoothing, spread over the colors this region actually uses.
        let denominator = self.total as f64 + 0.5 * self.occupied.max(1) as f64;
        (count + 0.5) / denominator
    }

    fn cost(&self, pixel: [u8; 4]) -> f64 {
        -self.probability(pixel).max(1e-6).ln()
    }
}

/// Data costs `(-ln P(color | subject), -ln P(color | background))` with the center prior folded in.
fn data_costs(
    image: &Bitmap8,
    subject: &ColorModel,
    background: &ColorModel,
    center: &[f32],
    forced_background: &[bool],
    center_prior: f64,
) -> (Vec<f64>, Vec<f64>) {
    let count = center.len();
    let mut subject_cost = vec![0f64; count];
    let mut background_cost = vec![0f64; count];
    for index in 0..count {
        let pixel: [u8; 4] = image.pixels()[index * 4..index * 4 + 4].try_into().expect("four channels");
        let prior = center[index] as f64;
        let subject_bias = center_prior * (1.0 - prior);
        let background_bias = center_prior * prior;
        subject_cost[index] = (subject.cost(pixel) + subject_bias).min(MAX_DATA_COST);
        background_cost[index] = (background.cost(pixel) + background_bias).min(MAX_DATA_COST);
        if forced_background[index] {
            // Certain background: no labeling can be cheaper here.
            subject_cost[index] = f64::MAX;
        }
    }
    (subject_cost, background_cost)
}

/// One pass of iterated conditional modes over the binary field: flip a pixel when that lowers
/// `D(l_p) + sum lambda w_pq [l_p != l_q]`. Raster order, no randomness, so the result is a
/// deterministic local minimum. Returns whether anything moved.
fn refine_labels(
    image: &Bitmap8,
    labels: &mut [bool],
    costs: &(Vec<f64>, Vec<f64>),
    forced_background: &[bool],
    smoothing: f64,
    beta: f64,
) -> bool {
    let (w, h) = (image.width() as i64, image.height() as i64);
    if w <= 0 || h <= 0 {
        return false;
    }
    let mut moved = false;
    for y in 0..h {
        for x in 0..w {
            let index = (y * w + x) as usize;
            if forced_background[index] {
                continue;
            }
            let current = labels[index];
            let mut cost_current = if current { costs.0[index] } else { costs.1[index] };
            let mut cost_flipped = if current { costs.1[index] } else { costs.0[index] };
            let neighbors = [
                (-1i64, 0i64, false),
                (1, 0, false),
                (0, -1, false),
                (0, 1, false),
                (-1, -1, true),
                (1, -1, true),
                (-1, 1, true),
                (1, 1, true),
            ];
            for (dx, dy, diagonal) in neighbors {
                let nx = x + dx;
                let ny = y + dy;
                if nx < 0 || ny < 0 || nx >= w || ny >= h {
                    continue;
                }
                let neighbor = (ny * w + nx) as usize;
                let weight = smoothing * edge_weight(image, index, neighbor, beta) * if diagonal { 0.7071 } else { 1.0 };
                if labels[neighbor] != current {
                    cost_current += weight;
                } else {
                    cost_flipped += weight;
                }
            }
            if cost_flipped < cost_current - 1e-9 {
                labels[index] = !current;
                moved = true;
            }
        }
    }
    moved
}

/// Contrast-sensitive edge weight: `exp(-beta * |I_p - I_q|^2)`, so a flip is cheap only where the
/// image itself has an edge. This is GrabCut's smoothness term.
fn edge_weight(image: &Bitmap8, a: usize, b: usize, beta: f64) -> f64 {
    let pixels = image.pixels();
    let mut sum = 0.0;
    for channel in 0..3 {
        let difference = pixels[a * 4 + channel] as f64 - pixels[b * 4 + channel] as f64;
        sum += difference * difference;
    }
    (-beta * sum / 3.0).exp()
}

/// `beta` from the image's own mean neighbour contrast, as GrabCut estimates it: a busy image
/// needs a smaller `beta` for the same penalty.
fn contrast_beta(image: &Bitmap8) -> f64 {
    let (w, h) = (image.width() as usize, image.height() as usize);
    if w < 2 || h < 2 {
        return 1.0 / (2.0 * 30.0 * 30.0);
    }
    let mut total = 0.0;
    let mut count = 0.0;
    let pixels = image.pixels();
    for y in (0..h).step_by(2) {
        for x in (0..w - 1).step_by(2) {
            let a = y * w + x;
            let b = a + 1;
            for channel in 0..3 {
                let difference = pixels[a * 4 + channel] as f64 - pixels[b * 4 + channel] as f64;
                total += difference * difference / 3.0;
            }
            count += 1.0;
        }
    }
    for y in (0..h - 1).step_by(2) {
        for x in (0..w).step_by(2) {
            let a = y * w + x;
            let b = a + w;
            for channel in 0..3 {
                let difference = pixels[a * 4 + channel] as f64 - pixels[b * 4 + channel] as f64;
                total += difference * difference / 3.0;
            }
            count += 1.0;
        }
    }
    let mean = if count > 0.0 { total / count } else { 0.0 };
    if mean <= 1.0 {
        1.0 / (2.0 * 30.0 * 30.0)
    } else {
        1.0 / (2.0 * mean)
    }
}

/// Drops subject components smaller than `min_fraction` of the largest, and spares everything when
/// the fraction is 0. 8-connected, in raster order, so the outcome never depends on visit order.
fn keep_components(labels: &mut [bool], width: usize, height: usize, min_fraction: f64) {
    let (ids, sizes) = label_components(labels, width, height, true);
    let largest = sizes.iter().copied().max().unwrap_or(0);
    if largest == 0 {
        return;
    }
    let threshold = min_fraction * largest as f64;
    for (index, id) in ids.iter().enumerate() {
        if *id == 0 {
            continue;
        }
        if (sizes[*id as usize] as f64) < threshold {
            labels[index] = false;
        }
    }
}

/// Fills background pockets that are closed off from the image border and smaller than
/// `min_fraction` of the subject, which removes pinholes without filling a deliberate hole.
fn fill_holes(labels: &mut [bool], width: usize, height: usize, min_fraction: f64) {
    let background: Vec<bool> = labels.iter().map(|label| !*label).collect();
    let (ids, sizes) = label_components(&background, width, height, false);
    let subject_size = labels.iter().filter(|label| **label).count();
    if subject_size == 0 {
        return;
    }
    let threshold = (min_fraction * subject_size as f64).max(1.0);
    // A background component touching the border is the outside, never a hole.
    let mut touches_border = vec![false; sizes.len()];
    for x in 0..width {
        for y in [0, height - 1] {
            touches_border[ids[y * width + x] as usize] = true;
        }
    }
    for y in 0..height {
        for x in [0, width - 1] {
            touches_border[ids[y * width + x] as usize] = true;
        }
    }
    for (index, id) in ids.iter().enumerate() {
        if *id == 0 || touches_border[*id as usize] {
            continue;
        }
        if (sizes[*id as usize] as f64) <= threshold {
            labels[index] = true;
        }
    }
}

/// Connected components of the true pixels (8-connected) or the false ones (4-connected, which is
/// what "enclosed" means for a hole). Returns a per-pixel id (0 = not part of any component) and
/// the sizes indexed by id.
fn label_components(labels: &[bool], width: usize, height: usize, eight_connected: bool) -> (Vec<u32>, Vec<usize>) {
    let mut ids = vec![0u32; labels.len()];
    let mut sizes = vec![0usize];
    let mut stack: Vec<usize> = Vec::new();
    let mut next_id = 1u32;
    for start in 0..labels.len() {
        if !labels[start] || ids[start] != 0 {
            continue;
        }
        let id = next_id;
        next_id += 1;
        let mut size = 0usize;
        ids[start] = id;
        stack.push(start);
        while let Some(index) = stack.pop() {
            size += 1;
            let x = (index % width) as i64;
            let y = (index / width) as i64;
            let neighbors = [
                (-1i64, 0i64),
                (1, 0),
                (0, -1),
                (0, 1),
                (-1, -1),
                (1, -1),
                (-1, 1),
                (1, 1),
            ];
            for (dx, dy) in neighbors {
                if !eight_connected && dx != 0 && dy != 0 {
                    continue;
                }
                let nx = x + dx;
                let ny = y + dy;
                if nx < 0 || ny < 0 || nx >= width as i64 || ny >= height as i64 {
                    continue;
                }
                let neighbor = ny as usize * width + nx as usize;
                if labels[neighbor] && ids[neighbor] == 0 {
                    ids[neighbor] = id;
                    stack.push(neighbor);
                }
            }
        }
        sizes.push(size);
    }
    (ids, sizes)
}

/// The labels as a hard matte.
fn matte_from_labels(labels: &[bool], width: usize, height: usize) -> Gray8 {
    let mut bytes = vec![0u8; width * height];
    for (index, label) in labels.iter().enumerate() {
        if *label {
            bytes[index] = 255;
        }
    }
    Gray8::from_raw(width as u32, height as u32, bytes).expect("labels match the matte size")
}

/// The image's luminance as 0-1, transparent pixels counting as black. Rec. 709 weights, the same
/// the app's gray conversion approximates.
fn luma(image: &Bitmap8) -> Vec<f32> {
    let mut guide = vec![0f32; image.pixel_count()];
    for (index, pixel) in image.pixels().chunks_exact(4).enumerate() {
        let alpha = pixel[3] as f32 / 255.0;
        let value = 0.2126 * pixel[0] as f32 + 0.7152 * pixel[1] as f32 + 0.0722 * pixel[2] as f32;
        guide[index] = value / 255.0 * alpha;
    }
    guide
}

/// Mean over a (2r+1) x (2r+1) square as two running-sum passes, with the edges extended.
/// Ported from `GuidedMatte.box`: the cost does not grow with the radius, and a constant field
/// stays exactly constant, which is what keeps the filter energy-preserving at the border.
fn box_blur(source: &[f32], width: usize, height: usize, radius: usize) -> Vec<f32> {
    let span = (radius * 2 + 1) as f32;
    let mut pass = vec![0f32; source.len()];
    for y in 0..height {
        let row = y * width;
        let mut sum = 0.0;
        for offset in -(radius as i64)..=(radius as i64) {
            sum += source[row + clamp_index(offset, width)];
        }
        for x in 0..width {
            pass[row + x] = sum / span;
            sum -= source[row + clamp_index(x as i64 - radius as i64, width)];
            sum += source[row + clamp_index(x as i64 + radius as i64 + 1, width)];
        }
    }
    let mut result = vec![0f32; source.len()];
    for x in 0..width {
        let mut sum = 0.0;
        for offset in -(radius as i64)..=(radius as i64) {
            sum += pass[clamp_index(offset, height) * width + x];
        }
        for y in 0..height {
            result[y * width + x] = sum / span;
            sum -= pass[clamp_index(y as i64 - radius as i64, height) * width + x];
            sum += pass[clamp_index(y as i64 + radius as i64 + 1, height) * width + x];
        }
    }
    result
}

fn clamp_index(value: i64, length: usize) -> usize {
    value.clamp(0, length as i64 - 1) as usize
}

/// Guided filter (He, Sun & Tang 2010): `mask` filtered with `guide` as its edge reference, both
/// 0-1 and the same size. A port of the app's `GuidedMatte.filter`, epsilon included, so "Refine
/// Edges" behaves as it does on macOS.
fn guided_filter(mask: &[f32], guide: &[f32], width: usize, height: usize, radius: usize, epsilon: f32) -> Vec<f32> {
    let count = width * height;
    if count == 0 || mask.len() != count || guide.len() != count {
        return mask.to_vec();
    }
    let mean_guide = box_blur(guide, width, height, radius);
    let mean_mask = box_blur(mask, width, height, radius);
    let mut squares = vec![0f32; count];
    let mut products = vec![0f32; count];
    for index in 0..count {
        squares[index] = guide[index] * guide[index];
        products[index] = guide[index] * mask[index];
    }
    let mean_squares = box_blur(&squares, width, height, radius);
    let mean_products = box_blur(&products, width, height, radius);
    let mut slope = vec![0f32; count];
    let mut offset = vec![0f32; count];
    for index in 0..count {
        let variance = mean_squares[index] - mean_guide[index] * mean_guide[index];
        let covariance = mean_products[index] - mean_guide[index] * mean_mask[index];
        slope[index] = covariance / (variance + epsilon);
        offset[index] = mean_mask[index] - slope[index] * mean_guide[index];
    }
    let mean_slope = box_blur(&slope, width, height, radius);
    let mean_offset = box_blur(&offset, width, height, radius);
    let mut result = vec![0f32; count];
    for index in 0..count {
        result[index] = (mean_slope[index] * guide[index] + mean_offset[index]).clamp(0.0, 1.0);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::*;

    /// A square image with a filled disc of `subject` on a flat `background`.
    fn disc_on_flat(size: u32, background: [u8; 4], subject: [u8; 4], radius: f64) -> Bitmap8 {
        let mut image = Bitmap8::filled(size, size, background);
        let center = size as f64 / 2.0;
        for y in 0..size {
            for x in 0..size {
                let dx = x as f64 + 0.5 - center;
                let dy = y as f64 + 0.5 - center;
                if dx * dx + dy * dy <= radius * radius {
                    image.set(x, y, subject);
                }
            }
        }
        image
    }

    /// A disc whose edge fades between subject and background over `softness` pixels, the way a
    /// real photograph's edge is antialiased.
    fn soft_disc(size: u32, background: [u8; 4], subject: [u8; 4], radius: f64, softness: f64) -> Bitmap8 {
        let mut image = Bitmap8::filled(size, size, background);
        let center = size as f64 / 2.0;
        for y in 0..size {
            for x in 0..size {
                let dx = x as f64 + 0.5 - center;
                let dy = y as f64 + 0.5 - center;
                let distance = (dx * dx + dy * dy).sqrt();
                let coverage = ((radius - distance) / softness + 0.5).clamp(0.0, 1.0);
                let mut pixel = [0u8; 4];
                for channel in 0..4 {
                    pixel[channel] = (background[channel] as f64 * (1.0 - coverage)
                        + subject[channel] as f64 * coverage)
                        .round()
                        .clamp(0.0, 255.0) as u8;
                }
                image.set(x, y, pixel);
            }
        }
        image
    }

    /// The mean matte value over the central disc of `fraction` of the subject's radius, 0-1.
    fn subject_coverage(matte: &Gray8, radius: f64, fraction: f64) -> f64 {
        let size = matte.width() as f64;
        let center = size / 2.0;
        let limit = radius * fraction;
        let mut total = 0.0;
        let mut count = 0.0;
        for y in 0..matte.height() {
            for x in 0..matte.width() {
                let dx = x as f64 + 0.5 - center;
                let dy = y as f64 + 0.5 - center;
                if dx * dx + dy * dy <= limit * limit {
                    total += matte.get(x, y) as f64 / 255.0;
                    count += 1.0;
                }
            }
        }
        if count == 0.0 {
            0.0
        } else {
            total / count
        }
    }

    /// The mean matte value outside a disc of `radius`, 0-1: how much background leaked in.
    fn background_leakage(matte: &Gray8, radius: f64) -> f64 {
        let size = matte.width() as f64;
        let center = size / 2.0;
        let mut total = 0.0;
        let mut count = 0.0;
        for y in 0..matte.height() {
            for x in 0..matte.width() {
                let dx = x as f64 + 0.5 - center;
                let dy = y as f64 + 0.5 - center;
                if dx * dx + dy * dy > radius * radius {
                    total += matte.get(x, y) as f64 / 255.0;
                    count += 1.0;
                }
            }
        }
        if count == 0.0 {
            0.0
        } else {
            total / count
        }
    }

    fn rect_coverage(matte: &Gray8, x0: u32, y0: u32, width: u32, height: u32) -> f64 {
        let mut total = 0.0;
        let mut count = 0.0;
        for y in y0..(y0 + height).min(matte.height()) {
            for x in x0..(x0 + width).min(matte.width()) {
                total += matte.get(x, y) as f64 / 255.0;
                count += 1.0;
            }
        }
        if count == 0.0 {
            0.0
        } else {
            total / count
        }
    }

    #[test]
    fn a_disc_on_a_flat_background_is_selected() {
        let image = disc_on_flat(96, [240, 240, 240, 255], [200, 40, 40, 255], 28.0);
        let matte = select_subject(&image, &SubjectOptions::default());
        let inside = subject_coverage(&matte, 28.0, 0.7);
        let outside = background_leakage(&matte, 34.0);
        assert!(inside >= 0.90, "subject coverage {inside:.3}");
        assert!(outside <= 0.10, "background leakage {outside:.3}");
        assert_eq!(matte.get(48, 48), 255, "the middle is subject");
        assert_eq!(matte.get(2, 2), 0, "the border band is background");
    }

    #[test]
    fn the_background_selection_is_the_exact_complement() {
        let image = disc_on_flat(64, [240, 240, 240, 255], [30, 90, 180, 255], 18.0);
        let subject = select_subject(&image, &SubjectOptions::default());
        let background = select_background(&image, &SubjectOptions::default());
        for (index, value) in subject.pixels().iter().enumerate() {
            assert_eq!(background.pixels()[index], 255 - *value);
        }
        assert!(subject_coverage(&background, 18.0, 0.7) < 0.1);
    }

    #[test]
    fn a_two_tone_background_is_handled() {
        let mut image = disc_on_flat(96, [245, 245, 245, 255], [30, 160, 90, 255], 26.0);
        for y in 0..96 {
            for x in 48..96 {
                if image.get(x, y) == [245, 245, 245, 255] {
                    image.set(x, y, [200, 220, 250, 255]);
                }
            }
        }
        let matte = select_subject(&image, &SubjectOptions::default());
        assert!(subject_coverage(&matte, 26.0, 0.7) >= 0.90, "coverage {:.3}", subject_coverage(&matte, 26.0, 0.7));
        assert!(background_leakage(&matte, 32.0) <= 0.10, "leakage {:.3}", background_leakage(&matte, 32.0));
    }

    #[test]
    fn a_gradient_background_is_handled() {
        // White on the left fading to mid gray on the right, with a saturated subject in front.
        let mut image = Bitmap8::new(96, 96);
        for y in 0..96 {
            for x in 0..96 {
                let level = 245 - (x as f64 * 105.0 / 95.0) as u8;
                image.set(x, y, [level, level, level, 255]);
            }
        }
        let center = 48.0;
        for y in 0..96 {
            for x in 0..96 {
                let dx = x as f64 + 0.5 - center;
                let dy = y as f64 + 0.5 - center;
                if dx * dx + dy * dy <= 26.0 * 26.0 {
                    image.set(x, y, [230, 120, 20, 255]);
                }
            }
        }
        let matte = select_subject(&image, &SubjectOptions::default());
        assert!(subject_coverage(&matte, 26.0, 0.7) >= 0.85, "coverage {:.3}", subject_coverage(&matte, 26.0, 0.7));
        assert!(background_leakage(&matte, 34.0) <= 0.15, "leakage {:.3}", background_leakage(&matte, 34.0));
    }

    #[test]
    fn a_same_colored_subject_survives_only_because_of_the_center_prior() {
        // One flat color everywhere: no color evidence at all, so only the prior can decide.
        let image = Bitmap8::filled(64, 64, [128, 128, 128, 255]);
        let matte = select_subject(&image, &SubjectOptions::default());
        assert_eq!(matte.get(32, 32), 255, "the center prior claims the middle");
        assert_eq!(matte.get(12, 12), 0, "outside the prior the background wins");
        assert_eq!(matte.get(3, 3), 0, "the border band is always background");

        let without_prior = select_subject(&image, &SubjectOptions { center_prior: 0.0, ..SubjectOptions::default() });
        assert_eq!(without_prior.get(12, 12), 255, "with no prior nothing pushes the label back");
        assert_eq!(without_prior.get(2, 2), 0, "the border band is still background");
    }

    #[test]
    fn a_uniform_image_has_no_subject_once_the_prior_is_off() {
        let image = Bitmap8::filled(48, 48, [90, 90, 90, 255]);
        let with_prior = select_subject(&image, &SubjectOptions::default());
        let without_prior = select_subject(&image, &SubjectOptions { center_prior: 0.0, ..SubjectOptions::default() });
        // One flat color gives the color models nothing to separate, so the center prior is the
        // only thing saying "middle". Without it the region is the whole interior of the frame.
        let wide = rect_coverage(&without_prior, 0, 0, 48, 48);
        let narrow = rect_coverage(&with_prior, 0, 0, 48, 48);
        assert!(wide > 0.6, "the interior is claimed wholesale: {wide:.3}");
        assert!(narrow < wide * 0.8, "the prior confines the claim: {narrow:.3} vs {wide:.3}");
        assert_eq!(without_prior.get(24, 24), 255, "the middle survives");
        assert_eq!(without_prior.get(2, 2), 0, "the certain background is still background");
        // A straight boundary is already at a local minimum of the smoothness energy - flipping one
        // of its pixels would lengthen it - so more sweeps change nothing.
        let more = select_subject(&image, &SubjectOptions { center_prior: 0.0, iterations: 12, ..SubjectOptions::default() });
        assert_eq!(more, without_prior);
    }

    #[test]
    fn a_disc_on_a_speckled_background_is_still_selected() {
        let mut image = disc_on_flat(96, [240, 240, 240, 255], [200, 40, 40, 255], 26.0);
        // Deterministic noise, so the test does not need a random source.
        let mut state = 0x1234_5678u32;
        for y in 0..96 {
            for x in 0..96 {
                state = state.wrapping_mul(1_664_525).wrapping_add(1_013_904_223);
                if image.get(x, y) != [200, 40, 40, 255] {
                    let jitter = ((state >> 24) as i32 % 25) - 12;
                    let level = (240 + jitter).clamp(0, 255) as u8;
                    image.set(x, y, [level, level, level, 255]);
                }
            }
        }
        let matte = select_subject(&image, &SubjectOptions::default());
        assert!(subject_coverage(&matte, 26.0, 0.6) >= 0.85, "coverage {:.3}", subject_coverage(&matte, 26.0, 0.6));
    }

    #[test]
    fn tiny_images_are_safe_and_empty_ones_return_an_empty_matte() {
        for size in 1..=3u32 {
            let image = Bitmap8::filled(size, size, [10, 20, 30, 255]);
            let matte = select_subject(&image, &SubjectOptions::default());
            assert_eq!((matte.width(), matte.height()), (size, size));
            assert!(matte.pixels().iter().all(|value| *value == 0), "size {size} has no interior");
        }
        assert!(select_subject(&Bitmap8::new(0, 0), &SubjectOptions::default()).is_empty());
        assert!(select_subject(&Bitmap8::new(8, 0), &SubjectOptions::default()).is_empty());
    }

    #[test]
    fn the_extraction_is_deterministic() {
        let image = disc_on_flat(64, [240, 240, 240, 255], [200, 40, 40, 255], 18.0);
        let first = select_subject(&image, &SubjectOptions::default());
        let second = select_subject(&image, &SubjectOptions::default());
        assert_eq!(first, second);
        let copy = image.clone();
        assert_eq!(first, select_subject(&copy, &SubjectOptions::default()));
        // And the edge pass is deterministic on its own.
        let refined = refine_edges(&image, &first, 2.0).expect("edges");
        assert_eq!(refined, refine_edges(&image, &first, 2.0).expect("edges"));
    }

    #[test]
    fn options_outside_their_ranges_are_clamped_not_fatal() {
        let image = disc_on_flat(32, [240, 240, 240, 255], [10, 10, 200, 255], 9.0);
        let wild = SubjectOptions {
            border_fraction: 5.0,
            color_bins: 0,
            center_prior: -3.0,
            iterations: 1000,
            smoothing: f64::NAN,
            min_component_fraction: 12.0,
            edge_radius: 1.0e9,
        };
        let clamped = wild.clamped();
        assert_eq!(clamped.border_fraction, 0.25);
        assert_eq!(clamped.color_bins, 2);
        assert_eq!(clamped.center_prior, 0.0);
        assert_eq!(clamped.iterations, 12);
        assert_eq!(clamped.smoothing, 0.0);
        assert_eq!(clamped.min_component_fraction, 1.0);
        assert_eq!(clamped.edge_radius, 64.0);
        let matte = select_subject(&image, &wild);
        assert_eq!((matte.width(), matte.height()), (32, 32));
        // Asking for a 64 px edge refinement on a 32 px image legitimately smooths the whole matte,
        // so the claim is not "some pixel is 255": it is that the subject is still lighter than the
        // background and that the run is repeatable.
        let subject = rect_coverage(&matte, 10, 10, 12, 12);
        let background = rect_coverage(&matte, 0, 0, 6, 6);
        assert!(subject > 0.3, "the subject survives the clamping: {subject:.3}");
        assert!(subject > background, "subject {subject:.3} vs background {background:.3}");
        assert_eq!(matte, select_subject(&image, &wild));
    }

    #[test]
    fn a_matte_without_edge_refinement_is_binary() {
        let image = disc_on_flat(64, [240, 240, 240, 255], [200, 40, 40, 255], 18.0);
        let options = SubjectOptions { edge_radius: 0.0, ..SubjectOptions::default() };
        let matte = select_subject(&image, &options);
        assert!(matte.pixels().iter().all(|value| *value == 0 || *value == 255));
        // The guided filter only softens an edge the image actually has: a hard-edged disc stays
        // hard, and an antialiased one gains the soft pixels along it.
        let hard_guide = select_subject(&image, &SubjectOptions::default());
        assert!(hard_guide.pixels().iter().all(|value| *value == 0 || *value == 255));
        let soft = soft_disc(64, [240, 240, 240, 255], [200, 40, 40, 255], 18.0, 2.0);
        let refined = select_subject(&soft, &SubjectOptions::default());
        let middle = refined.pixels().iter().filter(|value| **value != 0 && **value != 255).count();
        assert!(middle > 0, "an antialiased edge is recovered as partial coverage");
        assert_eq!(refined.get(32, 32), 255);
    }

    #[test]
    fn small_components_are_dropped() {
        // A large disc and a small same-colored speck far away from it.
        let mut image = disc_on_flat(96, [245, 245, 245, 255], [200, 40, 40, 255], 24.0);
        for y in 12..16 {
            for x in 12..16 {
                image.set(x, y, [200, 40, 40, 255]);
            }
        }
        let keep_all = select_subject(&image, &SubjectOptions { min_component_fraction: 0.0, ..SubjectOptions::default() });
        let keep_big = select_subject(&image, &SubjectOptions { min_component_fraction: 0.2, ..SubjectOptions::default() });
        assert!(rect_coverage(&keep_all, 12, 12, 4, 4) > 0.5, "the speck is kept when nothing is dropped");
        assert_eq!(rect_coverage(&keep_big, 12, 4, 4, 20), 0.0, "the speck is dropped by size");
        assert!(subject_coverage(&keep_big, 24.0, 0.7) >= 0.9, "the disc survives");
    }

    #[test]
    fn transparent_pixels_are_always_background() {
        let mut image = disc_on_flat(64, [240, 240, 240, 255], [200, 40, 40, 255], 18.0);
        for y in 0..20 {
            for x in 0..20 {
                image.set(x, y, [200, 40, 40, 0]);
            }
        }
        let matte = select_subject(&image, &SubjectOptions::default());
        assert_eq!(rect_coverage(&matte, 0, 0, 20, 20), 0.0, "a transparent corner is background");
        assert_eq!(matte.get(32, 32), 255, "the disc is still found");
    }

    #[test]
    fn a_subject_running_off_the_frame_loses_its_border_pixels_only() {
        // A disc large enough to cross the frame: the certain-background band wins at the edge.
        let image = disc_on_flat(64, [240, 240, 240, 255], [200, 40, 40, 255], 40.0);
        let matte = select_subject(&image, &SubjectOptions::default());
        assert_eq!(matte.get(1, 32), 0, "the border band is background");
        assert_eq!(matte.get(32, 32), 255, "the interior is still the subject");
        // A disc that reaches every edge shares its color with the whole border band, so the color
        // models cannot separate it: the center prior is all that is left, and it keeps the middle
        // of the frame rather than the disc's true outline. That limitation is documented.
        assert!(rect_coverage(&matte, 20, 20, 24, 24) > 0.9, "the prior's core is subject");
        assert_eq!(rect_coverage(&matte, 0, 0, 8, 8), 0.0, "the band stays background");
    }

    #[test]
    fn remove_background_multiplies_the_alpha_by_the_matte() {
        let image = Bitmap8::filled(8, 8, [10, 20, 30, 255]);
        let mut matte = Gray8::new(8, 8);
        matte.set(2, 2, 255);
        matte.set(3, 3, 128);
        let cut = remove_background(&image, &matte).expect("cutout");
        assert_eq!(cut.get(2, 2), [10, 20, 30, 255]);
        assert_eq!(cut.get(3, 3)[3], 128);
        assert_eq!(cut.get(0, 0)[3], 0);
        // Straight alpha: the color of a hidden pixel is kept for a later edit.
        assert_eq!(&cut.get(0, 0)[0..3], &[10, 20, 30]);
        assert_eq!(&cut.get(3, 3)[0..3], &[10, 20, 30]);
    }

    #[test]
    fn remove_background_scales_an_existing_alpha() {
        let image = Bitmap8::filled(4, 4, [1, 2, 3, 200]);
        let mut matte = Gray8::new(4, 4);
        matte.set(0, 0, 128);
        let cut = remove_background(&image, &matte).expect("cutout");
        assert_eq!(cut.get(0, 0)[3], ((200 * 128) as f32 / 255.0).round() as u8);
        assert_eq!(cut.get(1, 0)[3], 0);
        // A fully opaque matte leaves the alpha alone.
        let untouched = remove_background(&image, &Gray8::filled(4, 4, 255)).expect("cutout");
        assert_eq!(untouched, image);
    }

    #[test]
    fn remove_background_needs_a_matte_of_the_same_size() {
        let image = Bitmap8::new(8, 8);
        assert!(remove_background(&image, &Gray8::new(4, 4)).is_err());
        assert!(remove_background(&Bitmap8::new(0, 0), &Gray8::new(1, 1)).is_err());
    }

    #[test]
    fn refine_edges_without_a_radius_is_the_identity() {
        let image = disc_on_flat(32, [240, 240, 240, 255], [10, 10, 200, 255], 10.0);
        let mut matte = Gray8::new(32, 32);
        matte.set(10, 10, 200);
        matte.set(20, 20, 128);
        assert_eq!(refine_edges(&image, &matte, 0.0).expect("refine"), matte);
        assert_eq!(refine_edges(&image, &matte, 0.2).expect("refine"), matte);
        assert_eq!(refine_edges(&image, &matte, f64::NAN).expect("refine"), matte);
        assert_eq!(refine_edges(&image, &matte, -3.0).expect("refine"), matte);
    }

    #[test]
    fn refine_edges_leaves_a_constant_matte_constant() {
        // A flat matte has nothing for the guide to move: the filter is its own box mean.
        let image = soft_disc(32, [240, 240, 240, 255], [40, 60, 200, 255], 12.0, 3.0);
        for level in [0u8, 90, 200, 255] {
            let matte = Gray8::filled(32, 32, level);
            let refined = refine_edges(&image, &matte, 3.0).expect("refine");
            assert!(refined.pixels().iter().all(|value| (*value as i32 - level as i32).abs() <= 1), "level {level}");
        }
        assert!(refine_edges(&image, &Gray8::filled(32, 32, 0), 3.0).expect("refine").is_uniform());
        assert_eq!(refine_edges(&image, &Gray8::filled(32, 32, 255), 3.0).expect("refine").get(5, 5), 255);
    }

    #[test]
    fn refine_edges_pulls_the_matte_onto_the_guide_edge() {
        // A hard vertical edge at x = 32 in the image, and a soft matte transition centred at 29.
        let mut image = Bitmap8::new(64, 16);
        for y in 0..16 {
            for x in 0..64 {
                let level = if x < 32 { 0 } else { 255 };
                image.set(x, y, [level, level, level, 255]);
            }
        }
        let mut matte = Gray8::new(64, 16);
        for y in 0..16 {
            for x in 0..64 {
                let value = if x <= 26 {
                    255
                } else if x >= 34 {
                    0
                } else {
                    (255 * (34 - x) / 8) as u8
                };
                matte.set(x, y, value);
            }
        }
        let crossing = |mask: &Gray8| -> f64 {
            for x in 0..64 {
                if mask.get(x, 8) < 128 {
                    return x as f64;
                }
            }
            64.0
        };
        let before = crossing(&matte);
        let refined = refine_edges(&image, &matte, 3.0).expect("refine");
        let after = crossing(&refined);
        assert!((before - 29.0).abs() < 2.0, "the input transition is where it was built: {before}");
        assert!(
            (after - 32.0).abs() < (before - 32.0).abs(),
            "the refined edge sits on the guide's edge: after {after}, before {before}"
        );
        // The ramp stays monotone and keeps its plateau, so the guide did not invert anything.
        let row: Vec<u8> = (0..64).map(|x| refined.get(x, 8)).collect();
        assert!(row.windows(2).all(|pair| pair[0] >= pair[1]), "monotone across the edge: {row:?}");
        assert_eq!(row[10], 255, "far from the edge the matte is untouched");
        assert_eq!(row[50], 0);
    }

    #[test]
    fn refine_edges_is_monotone_in_the_matte() {
        let image = soft_disc(48, [240, 240, 240, 255], [40, 60, 200, 255], 15.0, 3.0);
        let mut weak = Gray8::new(48, 48);
        let mut strong = Gray8::new(48, 48);
        let center = 24.0;
        for y in 0..48 {
            for x in 0..48 {
                let dx = x as f64 + 0.5 - center;
                let dy = y as f64 + 0.5 - center;
                if dx * dx + dy * dy <= 14.0 * 14.0 {
                    weak.set(x, y, 128);
                    strong.set(x, y, 255);
                }
            }
        }
        let refined_weak = refine_edges(&image, &weak, 2.0).expect("refine");
        let refined_strong = refine_edges(&image, &strong, 2.0).expect("refine");
        for (index, value) in refined_weak.pixels().iter().enumerate() {
            assert!(refined_strong.pixels()[index] >= *value, "monotone at index {index}");
        }
        // The filter is linear in the matte, so twice the input is twice the output (up to rounding).
        for (index, value) in refined_weak.pixels().iter().enumerate() {
            let doubled = (*value as i32 * 2).min(255);
            assert!((refined_strong.pixels()[index] as i32 - doubled).abs() <= 2, "linear at index {index}");
        }
    }

    #[test]
    fn refine_edges_needs_a_matte_of_the_same_size() {
        let image = Bitmap8::new(8, 8);
        assert!(refine_edges(&image, &Gray8::new(4, 4), 2.0).is_err());
        assert!(refine_edges(&image, &Gray8::new(8, 8), 2.0).is_ok());
        assert!(refine_edges(&Bitmap8::new(0, 0), &Gray8::new(0, 0), 2.0).is_ok());
    }

    #[test]
    fn refine_edges_caps_an_absurd_radius() {
        // A window wider than the image would flatten the matte into a single gray; the clamp keeps
        // the middle of a subject at full coverage.
        let image = Bitmap8::filled(32, 32, [40, 90, 200, 255]);
        let mut matte = Gray8::new(32, 32);
        for y in 8..24 {
            for x in 8..24 {
                matte.set(x, y, 255);
            }
        }
        let refined = refine_edges(&image, &matte, 1.0e9).expect("refine");
        assert!(refined.get(16, 16) > 200, "the core survives, got {}", refined.get(16, 16));
        assert_eq!(refined.get(0, 0), 0);
    }

    #[test]
    fn an_end_to_end_cutout_keeps_the_subject_and_drops_the_background() {
        let image = disc_on_flat(80, [245, 245, 245, 255], [190, 45, 60, 255], 22.0);
        let matte = select_subject(&image, &SubjectOptions::default());
        let cut = remove_background(&image, &matte).expect("cutout");
        assert_eq!(cut.get(40, 40), [190, 45, 60, 255], "the subject keeps its pixels");
        assert_eq!(cut.get(2, 2), [245, 245, 245, 0], "the background is transparent");
        assert_eq!(cut.get(40, 40)[3], 255);
        assert_eq!(cut.get(2, 2)[3], 0);
        // The cutout and the matte agree everywhere, which is what the alpha promise means.
        for y in 0..80 {
            for x in 0..80 {
                assert_eq!(cut.get(x, y)[3], matte.get(x, y));
            }
        }
    }
}
