//! A command-line check of the importers and exporters, for the Python verification pass.
//!
//!     cargo run -p comp-io --example io_check -- import <file>
//!     cargo run -p comp-io --example io_check -- export-png <source> <target> <dpi>
//!     cargo run -p comp-io --example io_check -- export-jpeg <source> <target> <quality> <dpi>
//!     cargo run -p comp-io --example io_check -- psd <file>
//!
//! Every fact is printed as one key=value line, so a script can compare the result with what
//! Pillow reads or writes without parsing Rust types.

use std::process::ExitCode;

use comp_core::bitmap::Bitmap8;
use comp_io::{self as io, ImportOptions};

fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().skip(1).collect();
    let outcome = match args.first().map(String::as_str) {
        Some("import") => import(&args),
        Some("export-png") => export_png(&args),
        Some("export-jpeg") => export_jpeg(&args),
        Some("psd") => psd(&args),
        _ => Err("usage: io_check import|export-png|export-jpeg|psd ...".to_string()),
    };
    match outcome {
        Ok(()) => ExitCode::SUCCESS,
        Err(message) => {
            println!("error={message}");
            ExitCode::FAILURE
        }
    }
}

fn argument(args: &[String], index: usize) -> Result<&str, String> {
    args.get(index).map(String::as_str).ok_or_else(|| format!("missing argument {index}"))
}

fn import(args: &[String]) -> Result<(), String> {
    let path = argument(args, 1)?;
    let raster = io::import_raster(path, &ImportOptions::default()).map_err(|error| error.to_string())?;
    println!("format={}", raster.format.as_str());
    println!("width={}", raster.image.width());
    println!("height={}", raster.image.height());
    println!("resolution={}", raster.resolution.unwrap_or(0.0));
    println!("name={}", raster.name);
    println!("checksum={}", checksum(&raster.image));
    Ok(())
}

fn export_png(args: &[String]) -> Result<(), String> {
    let source = argument(args, 1)?;
    let target = argument(args, 2)?;
    let dpi: f64 = argument(args, 3)?.parse().map_err(|_| "the dpi is not a number".to_string())?;
    let image = io::import_image(source).map_err(|error| error.to_string())?;
    io::export_png(&image, target, dpi).map_err(|error| error.to_string())?;
    println!("wrote={target}");
    println!("checksum={}", checksum(&image));
    Ok(())
}

fn export_jpeg(args: &[String]) -> Result<(), String> {
    let source = argument(args, 1)?;
    let target = argument(args, 2)?;
    let quality: u8 = argument(args, 3)?.parse().map_err(|_| "the quality is not a number".to_string())?;
    let dpi: f64 = argument(args, 4)?.parse().map_err(|_| "the dpi is not a number".to_string())?;
    let image = io::import_image(source).map_err(|error| error.to_string())?;
    io::export_jpeg(&image, target, quality, dpi).map_err(|error| error.to_string())?;
    println!("wrote={target}");
    println!("quality={quality}");
    Ok(())
}

fn psd(args: &[String]) -> Result<(), String> {
    let path = argument(args, 1)?;
    let bytes = std::fs::read(path).map_err(|error| error.to_string())?;
    let imported = io::read_psd_with_report(&bytes).map_err(|error| error.to_string())?;
    println!("width={}", imported.document.width);
    println!("height={}", imported.document.height);
    println!("resolution={}", imported.document.resolution);
    println!("layers={}", imported.document.layers.len());
    for layer in &imported.document.layers {
        let image = layer.image.as_ref();
        println!(
            "layer={}|visible={}|opacity={}|blend={}|group={}|x={}|y={}|w={}|h={}|checksum={}|parent={}",
            layer.name,
            layer.visible,
            layer.opacity,
            layer.blend.as_str(),
            layer.is_group,
            layer.transform.origin.x,
            layer.transform.origin.y,
            layer.transform.size.width,
            layer.transform.size.height,
            image.map(|bitmap| checksum(bitmap)).unwrap_or(0),
            layer.parent.map(|id| id.to_string()).unwrap_or_default(),
        );
    }
    println!("conversions={}", imported.conversions.len());
    for conversion in &imported.conversions {
        println!("conversion={conversion}");
    }
    Ok(())
}

/// FNV-1a over the straight RGBA bytes, the same value the Python check computes.
fn checksum(image: &Bitmap8) -> u64 {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in image.pixels() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    hash
}
