//! Painting, selection and transform engines.
//!
//! Everything here is pure CPU and UI-free: inputs and outputs are the frozen `comp-core`
//! types (`Bitmap8` for straight-alpha RGBA pixels, `Gray8` for coverage masks, `Document`
//! for the guides and layer bounds snapping reads). The semantics are ported from the macOS
//! app, which stays the specification for behavior: `Document/BrushStroke.swift` for strokes,
//! `Rendering/WandPixels.c` for the wand and Color Range, `Rendering/HealPixels.c` and
//! `Rendering/ContentFill.c` for repair, and `Document/Selection.swift` with
//! `Document/LayerTransform.swift` for selections and alignment.
//!
//! Five engines:
//!
//! - [`brush`]: round tips with soft falloff, a per-stroke opacity cap, erasing, and the
//!   coverage buffer that Clone Stamp and Spot Healing paint through. @StrokeSession@ paints a
//!   stroke one pointer sample at a time with pixels identical to the batch @stroke@.
//! - [`clone`]: Clone Stamp, Spot Healing and content-aware fill.
//! - [`wand`]: Magic Wand, Color Range and mask outlines.
//! - [`subject`]: subject and background extraction without a model (border color model,
//!   center prior, iterated labeling, guided-filter edge refinement).
//! - [`subject_model`]: the same cut-out from a small ONNX salient-object network, run through
//!   tract when a model file is present, with @subject@ as the fallback when it is not.
//! - [`selection`]: rectangle, ellipse and lasso rasterization, feather, expand/contract,
//!   boolean operations, and clipping or cropping pixels by selection.
//! - [`transform`]: affine and perspective resampling plus guide/canvas/edge snapping.

pub mod brush;
pub mod clone;
pub mod selection;
pub mod subject;
pub mod subject_model;
pub mod transform;
pub mod wand;

pub use brush::{
    coverage_mask, dab_bounds, place_dabs, smooth_path, spacing_fraction, spline_path, Brush, BrushEngine,
    StrokeOutcome, StrokeSession, MAX_BRUSH_DIAMETER,
};
pub use clone::{clone_stamp, clone_stamp_clipped, content_fill, spot_heal, CloneState, HealMode};
pub use selection::{stacked_feather, Selection, SelectionOp, MAX_FEATHER};
pub use subject::{refine_edges, remove_background, select_background, select_subject, SubjectOptions};
pub use subject_model::{
    input_tensor, mask_from_map, select_subject_with, SubjectModel, MODEL_SIDE, SUBJECT_MODEL_ENV, SUBJECT_MODEL_FILE,
};
pub use transform::{
    snap_offset, snap_point, snap_value, transform_bitmap, transform_mask, warp_perspective, LayoutGrid, SnapResult,
    SnapTargets,
};
pub use wand::{color_range, magic_wand, reference_color, trace_outline, WandSampleSize, WandSettings};

pub use comp_core as core;
