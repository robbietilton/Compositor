//! Timed composition benchmarks, ignored by default so a normal test run stays quick.
//!
//! Run them with:
//! `cargo test -p comp-render --release -- --ignored --nocapture`
//!
//! The numbers they print are the ones recorded in this crate's `NOTES.md`. They are not pass/fail
//! gates: the assertions only catch a pathological slowdown, because a machine's load changes the time
//! by more than the code does.

use std::time::Instant;

use comp_core::geom::{PointF, Sampling, SizeF, Transform};
use comp_core::{Bitmap8, BlendMode, Document, Layer};

use crate::composite::flatten_document;

/// A layer filling the canvas with a deterministic pattern, so two runs measure the same work.
fn pattern_layer(name: &str, width: u32, height: u32, seed: u32) -> Layer {
    let mut pixels = vec![0u8; width as usize * height as usize * 4];
    for (index, texel) in pixels.chunks_exact_mut(4).enumerate() {
        let x = (index % width as usize) as u32;
        let y = (index / width as usize) as u32;
        texel[0] = ((x.wrapping_mul(7).wrapping_add(seed)) % 256) as u8;
        texel[1] = ((y.wrapping_mul(5).wrapping_add(seed * 3)) % 256) as u8;
        texel[2] = ((x ^ y).wrapping_add(seed * 11) % 256) as u8;
        texel[3] = 255;
    }
    let bitmap = Bitmap8::from_raw(width, height, pixels).expect("pattern fills the canvas");
    let mut layer = Layer::with_image(name, bitmap);
    layer.image_file = None;
    layer
}

/// A layer covering half the canvas in a blend mode, so a composite has something to blend.
fn blended_layer(name: &str, width: u32, height: u32, mode: BlendMode, seed: u32) -> Layer {
    let mut layer = pattern_layer(name, width, height, seed);
    layer.blend = mode;
    layer.transform = Transform {
        origin: PointF::new(0.0, 0.0),
        size: SizeF::new(width as f64 / 2.0, height as f64),
        rotation: 0.0,
        flip_x: false,
        flip_y: false,
        sampling: Sampling::HighQuality,
    };
    layer
}

fn time(label: &str, document: &Document) -> f64 {
    let started = Instant::now();
    let out = flatten_document(document);
    let elapsed = started.elapsed().as_secs_f64();
    let pixels = out.pixel_count() as f64;
    println!(
        "{label}: {:.3} s ({:.1} Mpixel/s, {}x{})",
        elapsed,
        pixels / elapsed / 1.0e6,
        out.width(),
        out.height()
    );
    assert!(out.width() == document.width && out.height() == document.height);
    assert!(elapsed < 120.0, "{label} took {elapsed:.1} s, which is pathological");
    elapsed
}

#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_single_layer_4000x4000() {
    let mut document = Document::new(4000, 4000);
    document.add_layer(pattern_layer("Base", 4000, 4000, 1), None);
    time("4000x4000, one layer", &document);
}

#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_ten_layers_4000x4000() {
    let mut document = Document::new(4000, 4000);
    document.add_layer(pattern_layer("Base", 4000, 4000, 1), None);
    let modes = [
        BlendMode::Multiply,
        BlendMode::Screen,
        BlendMode::Overlay,
        BlendMode::SoftLight,
        BlendMode::ColorDodge,
        BlendMode::Difference,
        BlendMode::HardLight,
        BlendMode::Exclusion,
        BlendMode::Color,
    ];
    for (index, mode) in modes.iter().enumerate() {
        document.add_layer(blended_layer(&format!("Layer {}", index + 2), 4000, 4000, *mode, index as u32 + 2), None);
    }
    time("4000x4000, ten layers (nine blend modes)", &document);
}

#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_single_layer_512x512_stays_fast() {
    // A quick shape check that the same path scales down, useful when comparing machines.
    let mut document = Document::new(512, 512);
    document.add_layer(pattern_layer("Base", 512, 512, 1), None);
    time("512x512, one layer", &document);
}
/// The GPU's worst channel difference from the CPU for each of the 24 modes, over opaque and
/// semi-transparent inputs: the evidence behind the numbers in NOTES.md.
#[test]
#[ignore = "report; run with --ignored --nocapture"]
fn report_gpu_mode_fidelity() {
    let Some(backend) = crate::gpu::backend() else {
        println!("no GPU backend: {:?}", crate::gpu::unavailability());
        return;
    };
    println!("GPU: {}", backend.describe());
    let backdrop = pattern_bitmap(64, 64, 1);
    let source = pattern_bitmap(64, 64, 2);
    let opaque_backdrop = opaque(&backdrop);
    let opaque_source = opaque(&source);
    println!("{:<22} {:>8} {:>8}", "mode", "opaque", "alpha");
    for mode in comp_core::BlendMode::ALL {
        let worst_opaque = worst_against_cpu(backend, &opaque_backdrop, &opaque_source, mode, 1.0);
        let worst_alpha = worst_against_cpu(backend, &backdrop, &source, mode, 0.6);
        println!("{:<22} {:>8} {:>8}", mode.as_str(), worst_opaque, worst_alpha);
    }
}

/// The CPU's own answer for the same inputs, as the pipeline would produce it.
fn cpu_composite(backdrop: &Bitmap8, source: &Bitmap8, mode: comp_core::BlendMode, opacity: f64) -> Bitmap8 {
    let mut under = crate::pixel::Surface::from_bitmap(backdrop);
    let mut over = crate::pixel::Surface::from_bitmap(source);
    over.scale_alpha(opacity as f32);
    crate::blend::composite_surface(&mut under, &over, mode);
    under.to_bitmap()
}

fn worst_against_cpu(
    backend: &crate::gpu::GpuBackend,
    backdrop: &Bitmap8,
    source: &Bitmap8,
    mode: comp_core::BlendMode,
    opacity: f64,
) -> i32 {
    let cpu = cpu_composite(backdrop, source, mode, opacity);
    let Some(gpu) = backend.composite(backdrop, source, mode, opacity) else {
        return -1;
    };
    cpu.pixels()
        .iter()
        .zip(gpu.pixels().iter())
        .map(|(a, b)| (*a as i32 - *b as i32).abs())
        .max()
        .unwrap_or(0)
}

fn opaque(bitmap: &Bitmap8) -> Bitmap8 {
    let mut copy = bitmap.clone();
    for texel in copy.pixels_mut().chunks_exact_mut(4) {
        texel[3] = 255;
    }
    copy
}

/// A varied image: ramps in every channel with a spread of alphas.
fn pattern_bitmap(width: u32, height: u32, seed: u32) -> Bitmap8 {
    let mut bitmap = Bitmap8::new(width, height);
    for y in 0..height {
        for x in 0..width {
            bitmap.set(
                x,
                y,
                [
                    ((x * 37 + seed * 11) % 256) as u8,
                    ((y * 53 + seed * 7) % 256) as u8,
                    (((x ^ y) * 29 + seed * 3) % 256) as u8,
                    (((x + y + seed) % 4) * 85) as u8,
                ],
            );
        }
    }
    bitmap
}

/// What a composite costs on the GPU against the CPU at export size.
///
/// The GPU figure is the whole round trip: two uploads, the dispatch and the readback. That is the
/// number a caller pays, and on a 4000 x 4000 canvas most of it is the 192 MB of traffic.
#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_gpu_against_cpu_4000x4000() {
    use std::time::Instant;
    let opacity = 0.75;
    let mode = comp_core::BlendMode::Multiply;
    println!("Multiply at 0.75, straight-alpha in and out:");
    println!("{:<10} {:>11} {:>11} {:>8} {:>8}", "canvas", "CPU (s)", "GPU (s)", "speedup", "worst");
    let mut sizes = vec![(16u32, 16u32), (64, 64), (256, 256), (1024, 1024), (4000, 4000)];
    if let Ok(side) = std::env::var("GPU_BENCH_SIDE") {
        if let Ok(side) = side.parse::<u32>() {
            sizes = vec![(side, side)];
        }
    }
    for (width, height) in sizes {
        let backdrop = pattern_bitmap(width, height, 1);
        let source = pattern_bitmap(width, height, 2);

        // Two runs, keeping the second: the first fills the caches and faults the pages in.
        let _ = cpu_composite(&backdrop, &source, mode, opacity);
        let started = Instant::now();
        let cpu = cpu_composite(&backdrop, &source, mode, opacity);
        let cpu_seconds = started.elapsed().as_secs_f64();

        let Some(backend) = crate::gpu::backend() else {
            println!("{:<10} {:>11.6} {:>11} {:>8} {:>8}", format!("{width}x{height}"), cpu_seconds, "unavailable", "-", "-");
            continue;
        };
        // One warm-up composite, so shader compilation and buffer allocation are not measured.
        let _ = backend.composite(&backdrop, &source, mode, opacity);
        let started = Instant::now();
        let gpu = match backend.composite(&backdrop, &source, mode, opacity) {
            Some(gpu) => gpu,
            None => {
                println!("{:<10} {:>11.6}  fell back: {:?}", format!("{width}x{height}"), cpu_seconds, backend.last_error());
                continue;
            }
        };
        let gpu_seconds = started.elapsed().as_secs_f64();
        let worst = cpu
            .pixels()
            .iter()
            .zip(gpu.pixels().iter())
            .map(|(a, b)| (*a as i32 - *b as i32).abs())
            .max()
            .unwrap_or(0);
        println!(
            "{:<10} {:>11.6} {:>11.6} {:>7.1}x {:>8}",
            format!("{width}x{height}"),
            cpu_seconds,
            gpu_seconds,
            cpu_seconds / gpu_seconds,
            worst
        );
        assert!(worst <= 2, "the GPU must agree with the CPU");
    }
    println!("The GPU figure is the whole round trip: two uploads, the dispatch and the readback.");
    println!("A small canvas pays that traffic for very little arithmetic, which is why the CPU wins there.");
}
/// The rectangle the editor would redraw between two pointer samples, rendered the old way and the new.
///
/// The old way is what the editor did before regions existed: build a copy of the document with every
/// transform shifted into the rectangle, drop the layers that do not reach it, and composite that copy
/// whole. The new way is `flatten_region`, which renders the rectangle and nothing else.
#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_region_composite() {
    println!("{:<38} {:>10} {:>12} {:>9}", "case", "old (ms)", "region (ms)", "speedup");
    for (side, bounds) in [
        (2000u32, (700i64, 640i64, 390u32, 400u32)),
        (4000, (1600, 1200, 800, 820)),
        (4000, (1600, 1200, 800, 800)),
    ] {
        for (layers, opacity, blend) in [
            (1usize, 1.0, BlendMode::Normal),
            (1, 0.8, BlendMode::Multiply),
            (4, 0.8, BlendMode::Multiply),
            (10, 0.8, BlendMode::Multiply),
        ] {
            let document = bench_document(side, layers, opacity, blend);
            let label = format!(
                "{side}x{side}, {layers} layer(s) at {:.0}% {blend:?}, {}x{}",
                opacity * 100.0,
                bounds.2,
                bounds.3
            );
            let old = median(15, || {
                let cropped = cropped_document(&document, bounds);
                std::hint::black_box(crate::flatten_document(&cropped));
            });
            let region = median(15, || {
                std::hint::black_box(crate::flatten_region(&document, bounds));
            });
            println!(
                "{label:<38} {:>10.3} {:>12.3} {:>8.1}x",
                old.as_secs_f64() * 1000.0,
                region.as_secs_f64() * 1000.0,
                old.as_secs_f64() / region.as_secs_f64()
            );
        }
    }
    println!();
    println!("Old is what the editor did before regions: build a copy of the document with the transforms");
    println!("shifted into the rectangle and composite that copy whole. Region is flatten_region. Both share");
    println!("the same compositor, so the difference is the work each one asks of it.");
}

fn median(runs: usize, mut body: impl FnMut()) -> std::time::Duration {
    let mut times: Vec<std::time::Duration> = (0..runs)
        .map(|_| {
            let started = std::time::Instant::now();
            body();
            started.elapsed()
        })
        .collect();
    times.sort();
    times[times.len() / 2]
}

/// A canvas with `layers` full-canvas raster layers, which is what an export of a painting looks like.
fn bench_document(side: u32, layers: usize, opacity: f64, blend: BlendMode) -> Document {
    let mut document = Document::new(side, side);
    for index in 0..layers {
        let mut bitmap = Bitmap8::new(side, side);
        // A cheap pattern: the point is the compositor's cost, not the pixels' values.
        for (position, texel) in bitmap.pixels_mut().chunks_exact_mut(4).enumerate() {
            let value = ((position / side as usize + index * 7) % 256) as u8;
            texel.copy_from_slice(&[value, value.wrapping_add(30), value.wrapping_add(60), 255]);
        }
        let mut layer = Layer::with_image(format!("Layer {index}"), bitmap);
        layer.image_file = None;
        layer.blend = blend;
        layer.opacity = opacity;
        document.add_layer(layer, None);
    }
    document
}

/// The document shifted into a rectangle, the way the editor used to render a dirty one.
fn cropped_document(document: &Document, bounds: (i64, i64, u32, u32)) -> Document {
    let (x, y, width, height) = bounds;
    let mut cropped = Document::new(width.max(1), height.max(1));
    cropped.version = document.version;
    for layer in &document.layers {
        let mut copy = layer.clone();
        copy.transform.origin = comp_core::PointF::new(
            layer.transform.origin.x - x as f64,
            layer.transform.origin.y - y as f64,
        );
        if let Some(placement) = layer.mask_placement {
            copy.mask_placement = Some(comp_core::geom::Transform {
                origin: comp_core::PointF::new(placement.origin.x - x as f64, placement.origin.y - y as f64),
                ..placement
            });
        }
        cropped.layers.push(copy);
    }
    cropped
}

/// Where a whole 4000x4000 render's time goes: the case the GUI's benchmark calls out at about 1.07 s
/// for twenty layers. Each stage is timed on its own, so an optimisation has a number to move.
#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_whole_canvas_stages() {
    let side = 4000u32;
    let document = bench_document(side, 20, 1.0, BlendMode::Normal);
    let layer = &document.layers[1];
    let image = layer.image.as_ref().unwrap();
    let transform = layer.transform;
    println!("twenty layers on a {side}x{side} canvas, {} MiB apiece", (side as usize * side as usize * 4) / (1024 * 1024));

    let show = |label: &str, mut times: Vec<f64>| {
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!(
            "  {label:<30} min {:7.2} ms  median {:7.2} ms",
            times[0] * 1000.0,
            times[times.len() / 2] * 1000.0
        );
    };
    let timed = |mut body: Box<dyn FnMut() + '_>| -> Vec<f64> {
        (0..7)
            .map(|_| {
                let started = std::time::Instant::now();
                body();
                started.elapsed().as_secs_f64()
            })
            .collect()
    };

    show(
        "whole document",
        timed(Box::new(|| {
            std::hint::black_box(crate::flatten_document(&document));
        })),
    );
    show(
        "canvas allocation",
        timed(Box::new(|| {
            std::hint::black_box(crate::pixel::Surface::new(side, side));
        })),
    );
    show(
        "one placement (Normal)",
        timed(Box::new({
            let mut canvas = crate::pixel::Surface::new(side, side);
            move || {
                crate::place::paint_bitmap_box(&mut canvas, image, &transform, comp_core::BlendMode::Normal, 1.0);
            }
        })),
    );
    show(
        "one placement (Multiply)",
        timed(Box::new({
            let mut canvas = crate::pixel::Surface::new(side, side);
            move || {
                crate::place::paint_bitmap_box(&mut canvas, image, &transform, comp_core::BlendMode::Multiply, 1.0);
            }
        })),
    );
    show(
        "one mask over a canvas",
        timed(Box::new({
            let mut canvas = crate::pixel::Surface::new(side, side);
            let plane = crate::pixel::Plane::new(side, side);
            move || {
                canvas.mask_by_plane(&plane);
            }
        })),
    );
    show(
        "one opacity scale",
        timed(Box::new({
            let mut canvas = crate::pixel::Surface::new(side, side);
            move || {
                canvas.scale_alpha(0.5);
            }
        })),
    );
    show(
        "the write back",
        timed(Box::new({
            let canvas = crate::pixel::Surface::new(side, side);
            move || {
                std::hint::black_box(canvas.to_bitmap());
            }
        })),
    );
    show(
        "eight canvas copies (floor)",
        timed(Box::new(|| {
            let bytes = side as usize * side as usize * 4;
            let source = vec![7u8; bytes];
            let mut last = vec![0u8; bytes];
            for _ in 0..8 {
                last.copy_from_slice(&source);
            }
            std::hint::black_box(&last);
        })),
    );
}

/// Where a region render's time goes, against the memory it has to move.
#[test]
#[ignore = "timed benchmark; run with --ignored --nocapture"]
fn benchmark_region_stages() {
    let side = 4000u32;
    let region = (1600i64, 1200i64, 800u32, 800u32);
    let document = bench_document(side, 1, 0.8, BlendMode::Multiply);
    let layer = &document.layers[0];
    let image = layer.image.as_ref().unwrap();
    let transform = layer.transform;
    println!("one opaque layer on a {side}x{side} canvas, {}x{} region", region.2, region.3);

    let show = |label: &str, mut times: Vec<f64>| {
        times.sort_by(|a, b| a.partial_cmp(b).unwrap());
        println!(
            "  {label:<28} min {:6.2} ms  median {:6.2} ms",
            times[0] * 1000.0,
            times[times.len() / 2] * 1000.0
        );
    };
    let timed = |mut body: Box<dyn FnMut() + '_>| -> Vec<f64> {
        (0..21)
            .map(|_| {
                let started = std::time::Instant::now();
                body();
                started.elapsed().as_secs_f64()
            })
            .collect()
    };

    show(
        "whole region render",
        timed(Box::new(|| {
            std::hint::black_box(crate::flatten_region(&document, region));
        })),
    );
    show(
        "canvas allocation",
        timed(Box::new(|| {
            std::hint::black_box(crate::pixel::Surface::new(region.2, region.3));
        })),
    );
    show(
        "paint placement",
        timed(Box::new({
            let mut canvas = crate::pixel::Surface::new(region.2, region.3);
            let mut local = transform;
            local.origin.x -= region.0 as f64;
            local.origin.y -= region.1 as f64;
            move || {
                crate::place::paint_bitmap_box(&mut canvas, image, &local, comp_core::BlendMode::Normal, 1.0);
            }
        })),
    );
    show(
        "crop and unpremultiply",
        timed(Box::new({
            let canvas = crate::pixel::Surface::new(region.2, region.3);
            move || {
                std::hint::black_box(canvas.to_bitmap());
            }
        })),
    );
    show(
        "three 2.5 MB copies (floor)",
        timed(Box::new(|| {
            let bytes = region.2 as usize * region.3 as usize * 4;
            let source = vec![7u8; bytes];
            let mut first = vec![0u8; bytes];
            let mut second = vec![0u8; bytes];
            first.copy_from_slice(&source);
            second.copy_from_slice(&source);
            std::hint::black_box(&second);
        })),
    );
}