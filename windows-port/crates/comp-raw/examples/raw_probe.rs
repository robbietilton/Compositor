//! Prints what rawloader sees in a camera raw file: dimensions, CFA, levels, white balance and the
//! camera-to-XYZ matrix. Useful when a format decodes oddly; the pipeline itself lives in
//! `comp_raw::decode_raw_file`.
//!
//!     cargo run -p comp-raw --example raw_probe -- <file>...

fn main() {
    for path in std::env::args().skip(1) {
        println!("=== {path}");
        match rawloader::decode_file(&path) {
            Ok(image) => {
                println!("  camera: {} / {} ({})", image.clean_make, image.clean_model, image.make);
                println!("  size: {}x{} cpp={} cfa={} crops={:?}", image.width, image.height, image.cpp,
                    image.cfa.name, image.crops);
                println!("  wb: {:?}", image.wb_coeffs);
                println!("  black: {:?} white: {:?}", image.blacklevels, image.whitelevels);
                println!("  xyz_to_cam: {:?}", image.xyz_to_cam);
                println!("  cam_to_xyz: {:?}", image.cam_to_xyz());
                println!("  orientation: {:?}", image.orientation);
                match &image.data {
                    rawloader::RawImageData::Integer(data) => {
                        let min = data.iter().min().copied().unwrap_or(0);
                        let max = data.iter().max().copied().unwrap_or(0);
                        println!("  integer data: {} samples, min={} max={}", data.len(), min, max);
                    }
                    rawloader::RawImageData::Float(data) => {
                        let min = data.iter().cloned().fold(f32::INFINITY, f32::min);
                        let max = data.iter().cloned().fold(f32::NEG_INFINITY, f32::max);
                        println!("  float data: {} samples, min={} max={}", data.len(), min, max);
                    }
                }
            }
            Err(error) => println!("  rawloader error: {error}"),
        }
    }
}
