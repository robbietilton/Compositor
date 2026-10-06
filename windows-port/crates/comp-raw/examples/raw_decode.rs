//! Decodes a camera raw file through the library and prints what came out, the way the CLI does.
//! Handy when a format needs investigating; `raw_probe` shows what rawloader alone sees.
//!
//!     cargo run -p comp-raw --example raw_decode -- <file>...

use comp_core::Bitmap8;

fn main() {
    println!(
        "supplementary decoder: {}",
        if comp_raw::libraw_available() {
            format!("LibRaw {}", comp_raw::libraw_version())
        } else {
            "not built in (enable --features libraw)".to_string()
        }
    );
    let mut failed = false;
    for path in std::env::args().skip(1) {
        println!("=== {path}");
        let path_ref = std::path::Path::new(&path);
        match comp_raw::decode_raw_file(path_ref) {
            Ok(decoded) => {
                match decoded.metadata() {
                    Some(metadata) => {
                        println!(
                            "  {} {} ({}x{}, CFA {}, {} channel(s), black {:?}, white {:?}, white balance {:?} \
from {:?}, matrix from {:?})",
                            metadata.clean_make,
                            metadata.clean_model,
                            metadata.width,
                            metadata.height,
                            if metadata.cfa.is_empty() { "none" } else { metadata.cfa.as_str() },
                            metadata.channels,
                            metadata.black_levels,
                            metadata.white_levels,
                            metadata.white_balance,
                            metadata.white_balance_source,
                            metadata.matrix_source,
                        );
                        println!(
                            "  decoded by {:?}{}{}",
                            metadata.engine,
                            if metadata.decoder.is_empty() {
                                String::new()
                            } else {
                                format!(" ({})", metadata.decoder)
                            },
                            match &metadata.fallback_reason {
                                Some(reason) => format!(" after the pure-Rust decoder said: {reason}"),
                                None => String::new(),
                            }
                        );
                    }
                    None => println!("  read by the DNG/TIFF container reader (no sensor metadata)"),
                }
                let (mean, deviation) = statistics(&decoded.image);
                println!("  developed {}x{}: mean {mean:.1}, deviation {deviation:.1}",
                    decoded.image.width(), decoded.image.height());
            }
            Err(error) => {
                failed = true;
                println!("  {error}");
            }
        }
    }
    if failed {
        std::process::exit(1);
    }
}

fn statistics(image: &Bitmap8) -> (f64, f64) {
    let mut sum = 0.0;
    let mut square = 0.0;
    let mut count = 0.0;
    for pixel in image.pixels().chunks_exact(4) {
        for channel in 0..3 {
            let value = pixel[channel] as f64;
            sum += value;
            square += value * value;
            count += 1.0;
        }
    }
    let mean = sum / count;
    (mean, (square / count - mean * mean).max(0.0).sqrt())
}
