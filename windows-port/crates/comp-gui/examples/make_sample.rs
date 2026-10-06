//! Writes a small sample package, so the editor has something to open without the fixtures.
//!
//! Run with: cargo run -p comp-gui --example make_sample [output.comp]

use std::path::PathBuf;

use comp_core::bitmap::Bitmap8;
use comp_core::blend::BlendMode;
use comp_core::document::Document;
use comp_core::layer::Layer;

const WIDTH: u32 = 640;
const HEIGHT: u32 = 400;

fn main() -> Result<(), String> {
    let target = std::env::args()
        .nth(1)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("crates/comp-gui/samples/sample.comp"));

    let mut document = Document::new(WIDTH, HEIGHT);
    document.add_layer(Layer::with_image("Sky", sky()), None);
    let mut sun = Layer::with_image("Sun", sun());
    // Screen keeps the sky gradient visible through the disc, the way the demo fixture does it.
    sun.blend = BlendMode::Screen;
    sun.opacity = 0.9;
    document.add_layer(sun, None);
    document.add_layer(Layer::with_image("Hills", hills()), None);

    comp_core::store::save(&document, &target).map_err(|error| error.to_string())?;
    println!(
        "wrote {} ({}x{}, {} layers)",
        target.display(),
        WIDTH,
        HEIGHT,
        document.layers.len()
    );
    Ok(())
}

/// A vertical two-color ramp.
fn sky() -> Bitmap8 {
    let top = [38, 66, 148];
    let bottom = [178, 205, 236];
    let mut bitmap = Bitmap8::new(WIDTH, HEIGHT);
    for y in 0..HEIGHT {
        let t = y as f32 / (HEIGHT - 1) as f32;
        let color = [
            mix(top[0], bottom[0], t),
            mix(top[1], bottom[1], t),
            mix(top[2], bottom[2], t),
            255,
        ];
        for x in 0..WIDTH {
            bitmap.set(x, y, color);
        }
    }
    bitmap
}

/// An antialiased disc.
fn sun() -> Bitmap8 {
    let (center_x, center_y, radius) = (480.0f32, 110.0f32, 62.0f32);
    let mut bitmap = Bitmap8::new(WIDTH, HEIGHT);
    let inner = radius - 1.0;
    for y in 0..HEIGHT {
        for x in 0..WIDTH {
            let dx = x as f32 + 0.5 - center_x;
            let dy = y as f32 + 0.5 - center_y;
            let distance = (dx * dx + dy * dy).sqrt();
            if distance <= inner {
                bitmap.set(x, y, [255, 244, 214, 255]);
            } else if distance < radius {
                let cover = (radius - distance).clamp(0.0, 1.0);
                bitmap.set(x, y, [255, 244, 214, (cover * 255.0).round() as u8]);
            }
        }
    }
    bitmap
}

/// Two ridges filled towards the bottom edge.
fn hills() -> Bitmap8 {
    let peaks = [(150.0f32, 150.0f32), (430.0f32, 250.0f32)];
    let mut bitmap = Bitmap8::new(WIDTH, HEIGHT);
    for x in 0..WIDTH {
        let position = x as f32 + 0.5;
        let ridge = peaks
            .iter()
            .map(|(center, height)| (height - (position - center).abs() * 0.85).max(0.0))
            .fold(0.0f32, f32::max);
        let top = HEIGHT as f32 - ridge;
        for y in 0..HEIGHT {
            let depth = y as f32 + 0.5 - top;
            if depth >= 0.0 {
                // Darken with depth so the silhouette reads as two overlapping hills.
                let shade = (1.0 - (depth / 260.0)).clamp(0.35, 1.0);
                bitmap.set(
                    x,
                    y,
                    [
                        (36.0 * shade) as u8 + 8,
                        (74.0 * shade) as u8 + 10,
                        (54.0 * shade) as u8 + 8,
                        255,
                    ],
                );
            }
        }
    }
    bitmap
}

fn mix(from: u8, to: u8, t: f32) -> u8 {
    (from as f32 + (to as f32 - from as f32) * t).round().clamp(0.0, 255.0) as u8
}
