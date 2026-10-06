//! The compositing and pixel pipeline: blend modes, adjustment layers, layer effects, transforms.
//!
//! Owned by the render task; every function here works on `comp-core` types only. The engine is a CPU
//! compositor that follows the macOS original pixel for pixel: premultiplied 8-bit surfaces, sRGB blend
//! math, and the same order of operations (see `NOTES.md` for the places it deliberately differs). A
//! wgpu backend can composite the 24 blend modes instead, and is checked against the CPU in the tests.

pub mod adjustment;
pub mod blend;
pub mod composite;
pub mod effects;
pub mod filters;
pub mod gpu;
pub mod pixel;
pub mod place;

#[cfg(test)]
mod bench;

pub use comp_core as core;
pub use composite::{flatten_document, flatten_layer, flatten_region, layer_bounds, Region};
pub use filters::{apply_filter, apply_filter_surface, blur_margin, FilterError, FilterKind, FilterSettings};
pub use gpu::{
    available as gpu_available, composite_gpu, describe as describe_gpu, flatten_document_gpu,
    flatten_document_preferring_gpu, gpu_accepts, GpuBackend,
};
pub use pixel::{Filter, Plane, Surface};
