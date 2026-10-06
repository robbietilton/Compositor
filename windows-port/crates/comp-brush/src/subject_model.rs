//! The subject model: a small ONNX network that cuts a subject out of a photograph.
//!
//! The classical extractor in @subject.rs@ decides from colour statistics. It is fast, has no model
//! file and no licence to carry, and it cannot know what a person looks like. This module runs a
//! real salient-object network through tract (pure Rust, no C toolchain) and answers with the same
//! thing: a @Gray8@ matte at the image's resolution, white where the subject is.
//!
//! Model: **U-2-Netp**, the lightweight U-2-Net of @xuebinqin/U-2-Net@, Apache-2.0. The file this
//! build looks for is the ONNX export published as @BritishWerewolf/U-2-Netp@ on Hugging Face,
//! 4.36 MB, SHA-256 @309C8469258DDA742793DCE0EBEA8E6DD393174F89934733ECC8B14C76F4DDD8@. It is not
//! committed: it is somebody else's weights, and it is optional. NOTES.md records the source, the
//! licence and how to place it.
//!
//! Where the file is looked for, in order:
//!
//! 1. @COMPOSITOR_SUBJECT_MODEL@, if it names a file. This is what an installed build uses.
//! 2. @models/u2netp.onnx@ next to the running executable, which is how the app ships it.
//! 3. @models/u2netp.onnx@ beside this crate's manifest, which is where a checkout puts it.
//!
//! **Fallback.** No file, an unreadable file, a graph this build cannot run, an image the network
//! refuses: every one of those falls back to the classical extractor, which then answers exactly as
//! it always did. A missing model is a supported configuration, not an error.

use std::path::{Path, PathBuf};

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::{Error, ErrorSource};
use tract_onnx::prelude::*;

use crate::subject::{refine_edges, select_subject, SubjectOptions};

/// The file name a subject model is looked for under.
pub const SUBJECT_MODEL_FILE: &str = "u2netp.onnx";
/// The environment variable that points at a model file directly.
pub const SUBJECT_MODEL_ENV: &str = "COMPOSITOR_SUBJECT_MODEL";
/// The side of the square the network is fed by default: what the published export declares, and
/// therefore the shape the graph's own claim is true for.
pub const MODEL_SIDE: usize = 320;
/// The side a preview uses. U-2-Net is fully convolutional, so a smaller square is a coarser but
/// valid input, and the matte is stretched back to the canvas either way. This is where the
/// release budget is won: see the numbers in NOTES.md.
pub const PREVIEW_SIDE: usize = 256;
/// The statistics U-2-Net was trained with (ImageNet's), applied per channel.
const MEAN: [f32; 3] = [0.485, 0.456, 0.406];
const STD: [f32; 3] = [0.229, 0.224, 0.225];

/// The runnable graph tract hands back, named once so the field has a type. tract's @run@ takes
/// @&Arc<Self>@, so the plan is held behind the arc it wants rather than cloned per call.
type Plan = std::sync::Arc<TypedSimplePlan>;

/// How many threads the network may use when nobody says otherwise.
///
/// tract's executor is process-wide, so this is too: `use_threads` swaps it for every model in the
/// process. The cap keeps a many-core machine from spending more time waking threads than
/// multiplying.
pub fn default_threads() -> usize {
    std::thread::available_parallelism()
        .map(|count| count.get())
        .unwrap_or(1)
        .clamp(1, 16)
}

/// Sets how many threads tract may use, for this process and every model in it.
///
/// One thread is a supported choice, and what the release benchmark compares against; the model
/// answers the same pixels either way, which a test asserts.
pub fn use_threads(threads: usize) {
    let executor = tract_linalg::multithread::Executor::multithread(threads.clamp(1, 64));
    tract_linalg::multithread::set_default_executor(executor);
}

/// How many times a model has been read and optimized in this process. Diagnostics: a caller that
/// caches should see this stop moving.
pub fn load_count() -> u64 {
    LOADS.load(std::sync::atomic::Ordering::Relaxed)
}

static LOADS: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(0);

/// What a model file looked like when it was loaded, so a cache can tell whether it changed.
#[derive(Clone, Debug, PartialEq, Eq)]
struct ModelStamp {
    len: u64,
    modified: Option<std::time::SystemTime>,
}

impl ModelStamp {
    fn read(path: &Path) -> Option<ModelStamp> {
        let metadata = std::fs::metadata(path).ok()?;
        if !metadata.is_file() {
            return None;
        }
        Some(ModelStamp { len: metadata.len(), modified: metadata.modified().ok() })
    }

    /// Whether a stamp still describes the file on disk. A file that is gone is not current.
    fn is_current(&self, path: &Path) -> bool {
        ModelStamp::read(path).map(|now| now == *self).unwrap_or(false)
    }
}

/// The process-wide cache of loaded models, keyed by path and invalidated by the file's size and
/// modification time. One entry is enough: a caller uses one model, and a second path simply
/// replaces the first.
static CACHE: std::sync::Mutex<Option<(PathBuf, usize, ModelStamp, std::sync::Arc<SubjectModel>)>> =
    std::sync::Mutex::new(None);

/// A loaded subject network. Loading is expensive (tens of milliseconds plus a file read), so a
/// caller keeps one and reuses it; every call is then whatever the network costs.
pub struct SubjectModel {
    plan: Plan,
    input: String,
    output: usize,
    outputs: usize,
    side: usize,
}

impl SubjectModel {
    /// Loads a model from a path, ready to run.
    ///
    /// The graph's first input is fixed to a batch of one 320x320 RGB image: the published export
    /// leaves the batch open, and a plan needs concrete shapes.
    pub fn load(path: &Path) -> Result<SubjectModel, Error> {
        SubjectModel::load_at_side(path, MODEL_SIDE)
    }

    /// Loads a model and fixes its input to @side@ x @side@.
    ///
    /// The graph is optimized for one concrete input shape, so a different side is a different
    /// plan and is loaded (and cached) separately. Anything from 128 to 320 is worth trying: the
    /// network is fully convolutional, and a coarser input costs less and cuts less finely.
    pub fn load_at_side(path: &Path, side: usize) -> Result<SubjectModel, Error> {
        // tract does not use more than one thread until an executor says so, and the executor is
        // process-wide, so the first load installs one. @use_threads@ changes it afterwards.
        tract_linalg::multithread::set_default_executor(tract_linalg::multithread::Executor::multithread(
            default_threads(),
        ));
        LOADS.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let mut model = tract_onnx::onnx().model_for_path(path).map_err(|error| {
            Error::failed(
                ErrorSource::Other,
                format!("{} is not an ONNX model this build can read: {error}", path.display()),
            )
        })?;
        // The graph's input nodes, by name, for the log line: tract's outlets name a node and a
        // slot, and the name a reader knows is the node's.
        let input = model
            .inputs
            .iter()
            .filter_map(|outlet| model.nodes.get(outlet.node).map(|node| node.name.clone()))
            .collect::<Vec<String>>()
            .join(", ");
        if input.is_empty() {
            return Err(Error::failed(ErrorSource::Other, format!("{} has no input", path.display())));
        }
        let side = side.clamp(64, 4096);
        let fact = f32::fact([1, 3, side, side]);
        model = model
            .with_input_fact(0, fact.into())
            .map_err(|error| Error::failed(ErrorSource::Other, format!("{} refused the input shape: {error}", path.display())))?;
        // The last output is the fused one in the U-2-Net exports (d0, after the six side outputs);
        // an export with a single output has only that one, and either way it is the one to read.
        let outputs = model.outputs.len();
        let output = outputs.saturating_sub(1);
        let plan = model
            .into_optimized()
            .and_then(|model| model.into_runnable())
            .map_err(|error| {
                Error::failed(
                    ErrorSource::Other,
                    format!("{} could not be turned into a runnable graph: {error}", path.display()),
                )
            })?;
        Ok(SubjectModel { plan, input, output, outputs, side })
    }

    /// The first model file that exists, in the documented order. Pure, so a test can drive it.
    pub fn locate_from(env: Option<&str>, exe_dir: Option<&Path>, crate_dir: &Path) -> Option<PathBuf> {
        if let Some(named) = env {
            if !named.trim().is_empty() {
                let path = PathBuf::from(named);
                if path.is_file() {
                    return Some(path);
                }
            }
        }
        if let Some(directory) = exe_dir {
            let path = directory.join("models").join(SUBJECT_MODEL_FILE);
            if path.is_file() {
                return Some(path);
            }
        }
        let path = crate_dir.join("models").join(SUBJECT_MODEL_FILE);
        if path.is_file() {
            return Some(path);
        }
        None
    }

    /// The model file this build would use, if any.
    pub fn locate() -> Option<PathBuf> {
        let env = std::env::var(SUBJECT_MODEL_ENV).ok();
        let exe_dir = std::env::current_exe().ok().and_then(|exe| exe.parent().map(Path::to_path_buf));
        SubjectModel::locate_from(env.as_deref(), exe_dir.as_deref(), Path::new(env!("CARGO_MANIFEST_DIR")))
    }

    /// Loads the model this build would use, or nil when there is none or it will not load.
    ///
    /// Nothing is printed and nothing fails: a build without a model is supported, and a caller
    /// that wants to tell the user which backend ran can ask @locate@ and @describe@.
    pub fn discover() -> Option<SubjectModel> {
        let path = SubjectModel::locate()?;
        SubjectModel::load(&path).ok()
    }

    /// Loads the model at a path, reusing the one already loaded when the file has not changed.
    ///
    /// Loading means reading a few megabytes, parsing a graph and optimizing it: hundreds of
    /// milliseconds that a slider drag must not pay again. The cache is process-wide and holds one
    /// model; the file's size and modification time decide whether the entry still describes it, so
    /// dropping a new export over the old one is picked up on the next call.
    pub fn cached(path: &Path) -> Result<std::sync::Arc<SubjectModel>, Error> {
        SubjectModel::cached_at_side(path, MODEL_SIDE)
    }

    /// @cached@ with the input side spelled out: a preview asks for @PREVIEW_SIDE@ and gets its own
    /// plan, while a full-quality pass asks for @MODEL_SIDE@.
    pub fn cached_at_side(path: &Path, side: usize) -> Result<std::sync::Arc<SubjectModel>, Error> {
        let side = side.clamp(64, 4096);
        let stamp = ModelStamp::read(path).ok_or_else(|| {
            Error::illegal_path(path.display().to_string(), "there is no subject model file there")
        })?;
        {
            let cache = CACHE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
            if let Some((cached_path, cached_side, cached_stamp, model)) = cache.as_ref() {
                // The same path and side, and a file that still looks the way it did when it was
                // loaded: a rewritten or replaced model is a different model.
                if cached_path == path && *cached_side == side && cached_stamp.is_current(path) {
                    return Ok(model.clone());
                }
            }
        }
        // Loading happens outside the lock: two callers racing here load twice, which is harmless,
        // and neither blocks the other for the length of an optimization pass.
        let model = std::sync::Arc::new(SubjectModel::load_at_side(path, side)?);
        let mut cache = CACHE.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
        *cache = Some((path.to_path_buf(), side, stamp, model.clone()));
        Ok(model)
    }

    /// The model this build would use, cached: nil when there is none or it will not load.
    pub fn cached_discovered() -> Option<std::sync::Arc<SubjectModel>> {
        let path = SubjectModel::locate()?;
        SubjectModel::cached_at_side(&path, PREVIEW_SIDE).ok()
    }

    /// A one-line description for a log or a status bar.
    pub fn describe(&self) -> String {
        format!(
            "{}: input {} [1, 3, {}x{}], {} outputs, reading the last one (d0 in the U-2-Net exports)",
            SUBJECT_MODEL_FILE, self.input, self.side, self.side, self.outputs
        )
    }

    /// The side of the square this model is fed.
    pub fn side(&self) -> usize {
        self.side
    }

    /// Cuts the subject out of an image: a matte at the image's resolution, 0-255.
    pub fn mask(&self, image: &Bitmap8) -> Result<Gray8, Error> {
        if image.width() == 0 || image.height() == 0 {
            return Ok(Gray8::new(image.width(), image.height()));
        }
        let input = input_tensor(image, self.side);
        let tensor = Tensor::from_shape(&[1, 3, self.side, self.side], &input)
            .map_err(|error| Error::failed(ErrorSource::Other, format!("the input tensor is malformed: {error}")))?;
        let outputs = self
            .plan
            .run(tvec!(tensor.into()))
            .map_err(|error| Error::failed(ErrorSource::Other, format!("the subject model did not run: {error}")))?;
        let output = outputs
            .get(self.output)
            .ok_or_else(|| Error::failed(ErrorSource::Other, "the subject model returned no output"))?;
        let tensor = output
            .as_arc_tensor()
            .ok_or_else(|| Error::failed(ErrorSource::Other, "the subject model's output is not a tensor"))?;
        // The output map as f32. tract hands back bytes and a datum type; the model's last layer is
        // a float map, and a tensor of anything else is a model this build will not guess at.
        if tensor.datum_type() != f32::datum_type() {
            return Err(Error::failed(
                ErrorSource::Other,
                format!("the subject model's output is {:?}, not f32", tensor.datum_type()),
            ));
        }
        let values: Vec<f32> = tensor
            .as_bytes()
            .chunks_exact(4)
            .map(|bytes| f32::from_ne_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
            .collect();
        Ok(mask_from_map(&values, image.width(), image.height()))
    }
}

/// The network's input for one image: NCHW, 0-1, centered with the statistics U-2-Net was trained
/// with. The image is squashed to @side@ x @side@; the matte is stretched back afterwards, which is
/// what every published U-2-Net demo does and what keeps the two transforms inverse to each other.
pub fn input_tensor(image: &Bitmap8, side: usize) -> Vec<f32> {
    let side = side.max(1);
    let mut plane = vec![0f32; side * side * 3];
    let (width, height) = (image.width().max(1), image.height().max(1));
    for y in 0..side {
        // Sample at pixel centres, so a one-pixel image maps to its own pixel rather than to a
        // corner it does not have.
        let sy = ((y as f64 + 0.5) * height as f64 / side as f64 - 0.5).max(0.0);
        for x in 0..side {
            let sx = ((x as f64 + 0.5) * width as f64 / side as f64 - 0.5).max(0.0);
            let pixel = bilinear(image, sx, sy);
            for channel in 0..3 {
                let value = pixel[channel] as f32 / 255.0;
                plane[channel * side * side + y * side + x] = (value - MEAN[channel]) / STD[channel];
            }
        }
    }
    plane
}

/// One bilinear sample, clamped at the edges.
fn bilinear(image: &Bitmap8, x: f64, y: f64) -> [u8; 4] {
    let (width, height) = (image.width(), image.height());
    let x0 = x.floor().max(0.0) as i64;
    let y0 = y.floor().max(0.0) as i64;
    let fx = x - x0 as f64;
    let fy = y - y0 as f64;
    let clamp = |value: i64, limit: u32| -> u32 { value.clamp(0, limit.saturating_sub(1) as i64) as u32 };
    let (x0c, x1c) = (clamp(x0, width), clamp(x0 + 1, width));
    let (y0c, y1c) = (clamp(y0, height), clamp(y0 + 1, height));
    let mut out = [0u8; 4];
    for channel in 0..4 {
        let top = image.get(x0c, y0c)[channel] as f64 * (1.0 - fx) + image.get(x1c, y0c)[channel] as f64 * fx;
        let bottom = image.get(x0c, y1c)[channel] as f64 * (1.0 - fx) + image.get(x1c, y1c)[channel] as f64 * fx;
        out[channel] = (top * (1.0 - fy) + bottom * fy).round().clamp(0.0, 255.0) as u8;
    }
    out
}

/// The matte from the network's output map.
///
/// U-2-Net's output is not a probability: it is an unbounded map whose *relative* values are what
/// matters, and every published demo rescales it by its own minimum and maximum before thresholding
/// at a half. A map with no range at all (a constant) is a model that saw nothing to cut out, so it
/// answers with a flat matte rather than dividing by zero.
pub fn mask_from_map(values: &[f32], width: u32, height: u32) -> Gray8 {
    let mut matte = Gray8::new(width, height);
    if values.is_empty() || width == 0 || height == 0 {
        return matte;
    }
    let mut low = f32::INFINITY;
    let mut high = f32::NEG_INFINITY;
    for value in values {
        if value.is_finite() {
            low = low.min(*value);
            high = high.max(*value);
        }
    }
    if !low.is_finite() || !high.is_finite() || high - low <= f32::EPSILON {
        return matte;
    }
    let side = (values.len() as f64).sqrt().round().max(1.0) as usize;
    let span = high - low;
    for y in 0..height {
        let sy = ((y as f64 + 0.5) * side as f64 / height as f64 - 0.5).max(0.0);
        for x in 0..width {
            let sx = ((x as f64 + 0.5) * side as f64 / width as f64 - 0.5).max(0.0);
            let value = bilinear_map(values, side, sx, sy);
            // A sample that is not finite is not a subject: an infinite or NaN cell would otherwise
            // spread NaN across every pixel that interpolates it, and a NaN cast to a byte is 0 in
            // Rust but 255 after some other casts - a matte that is suddenly all white.
            let normalized = if value.is_finite() { ((value - low) / span).clamp(0.0, 1.0) } else { 0.0 };
            matte.set(x, y, (normalized * 255.0).round().clamp(0.0, 255.0) as u8);
        }
    }
    matte
}

/// One bilinear sample of the square output map, clamped at the edges.
fn bilinear_map(values: &[f32], side: usize, x: f64, y: f64) -> f32 {
    let x0 = x.floor().max(0.0) as usize;
    let y0 = y.floor().max(0.0) as usize;
    let fx = (x - x0 as f64) as f32;
    let fy = (y - y0 as f64) as f32;
    let at = |x: usize, y: usize| -> f32 {
        let x = x.min(side.saturating_sub(1));
        let y = y.min(side.saturating_sub(1));
        values.get(y * side + x).copied().unwrap_or(0.0)
    };
    let top = at(x0, y0) * (1.0 - fx) + at(x0 + 1, y0) * fx;
    let bottom = at(x0, y0 + 1) * (1.0 - fx) + at(x0 + 1, y0 + 1) * fx;
    top * (1.0 - fy) + bottom * fy
}

/// A subject cut-out running on its own thread.
///
/// The classical extractor answers in milliseconds; a model takes a good fraction of a second, and
/// a window that blocks for that long while somebody drags a slider feels broken. So the model runs
/// here instead: @SubjectPreview@ hands back the classical matte at once and this job carries the
/// model's answer, which the caller polls whenever its event loop comes round.
///
/// Dropping a job does not stop its thread - Rust has no safe way to interrupt a running closure -
/// but the result is thrown away, and the next job does not wait for it. A caller that starts a job
/// per keystroke therefore leaves the older ones finishing in the background, which is what
/// @generation@ is for: the newest number is the answer to keep.
pub struct SubjectJob {
    generation: u64,
    receiver: Option<std::sync::mpsc::Receiver<Result<Gray8, Error>>>,
}

impl SubjectJob {
    /// Starts a cut-out on a worker thread and returns immediately.
    pub fn start(image: Bitmap8, options: SubjectOptions, model: Option<std::sync::Arc<SubjectModel>>) -> SubjectJob {
        static NEXT: std::sync::atomic::AtomicU64 = std::sync::atomic::AtomicU64::new(1);
        let generation = NEXT.fetch_add(1, std::sync::atomic::Ordering::Relaxed);
        let (sender, receiver) = std::sync::mpsc::channel();
        std::thread::Builder::new()
            .name("subject-model".to_string())
            .spawn(move || {
                let result = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| -> Result<Gray8, Error> {
                    Ok(select_subject_with(&image, &options, model.as_deref()))
                }))
                .unwrap_or_else(|_| Err(Error::failed(ErrorSource::Other, "the subject model panicked")));
                // A receiver that went away means the caller moved on; the answer is dropped.
                let _ = sender.send(result);
            })
            .expect("a worker thread");
        SubjectJob { generation, receiver: Some(receiver) }
    }

    /// Which job this is. A caller keeps the newest generation's answer and ignores the rest.
    pub fn generation(&self) -> u64 {
        self.generation
    }

    /// The answer if it is ready, and nil while the worker is still going.
    pub fn poll(&mut self) -> Option<Result<Gray8, Error>> {
        let receiver = self.receiver.as_ref()?;
        match receiver.try_recv() {
            Ok(result) => {
                self.receiver = None;
                Some(result)
            }
            Err(std::sync::mpsc::TryRecvError::Empty) => None,
            Err(std::sync::mpsc::TryRecvError::Disconnected) => {
                self.receiver = None;
                Some(Err(Error::failed(ErrorSource::Other, "the subject worker stopped without an answer")))
            }
        }
    }

    /// True until the answer has been collected.
    pub fn is_running(&self) -> bool {
        self.receiver.is_some()
    }

    /// Waits for the answer. A blocking call, for a script or a test rather than an event loop.
    pub fn wait(mut self) -> Result<Gray8, Error> {
        let Some(receiver) = self.receiver.take() else {
            return Err(Error::failed(ErrorSource::Other, "the answer was already collected"));
        };
        match receiver.recv() {
            Ok(result) => result,
            Err(_) => Err(Error::failed(ErrorSource::Other, "the subject worker stopped without an answer")),
        }
    }
}

/// What a caller shows while the model works: the classical matte now, the model's when it lands.
///
/// The flow the editor wants: on a slider release, take the classical answer (milliseconds, so the
/// canvas never freezes) and start a job for the model's; when @job.poll()@ returns something, put
/// that on the canvas instead. With no model the job answers with the classical matte again, so a
/// caller can use this shape unconditionally.
pub struct SubjectPreview {
    /// The classical extractor's matte, ready now.
    pub classical: Gray8,
    /// The model's matte, when it arrives.
    pub job: SubjectJob,
}

impl SubjectPreview {
    /// Computes the classical matte and starts the model's, without waiting for it.
    pub fn start(image: &Bitmap8, options: &SubjectOptions, model: Option<std::sync::Arc<SubjectModel>>) -> SubjectPreview {
        let classical = select_subject(image, options);
        let job = SubjectJob::start(image.clone(), options.clone(), model);
        SubjectPreview { classical, job }
    }
}

/// The subject matte, from the model when one is there and the classical extractor when not.
///
/// This is the entry point a caller wants: the answer is always the same shape and the same
/// meaning, and a build with no model behaves exactly as it did before there was one. The model's
/// matte gets the same edge pass the classical one does, so a caller cannot tell the two apart by
/// anything but the pixels.
pub fn select_subject_with(image: &Bitmap8, options: &SubjectOptions, model: Option<&SubjectModel>) -> Gray8 {
    let Some(model) = model else {
        return select_subject(image, options);
    };
    let options = options.clamped();
    let matte = match model.mask(image) {
        Ok(matte) => matte,
        // A model that cannot run is not a reason to fail a cut-out: the classical answer stands.
        Err(_) => return select_subject(image, &options),
    };
    if options.edge_radius > 0.0 {
        refine_edges(image, &matte, options.edge_radius).unwrap_or(matte)
    } else {
        matte
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    /// A temporary directory that removes itself.
    struct TempTree(PathBuf);

    impl TempTree {
        fn new(tag: &str) -> TempTree {
            let path = std::env::temp_dir().join(format!("compsubject-{tag}-{}", uuid::Uuid::new_v4()));
            fs::create_dir_all(&path).expect("a temp directory");
            TempTree(path)
        }

        fn path(&self) -> &Path {
            &self.0
        }
    }

    impl Drop for TempTree {
        fn drop(&mut self) {
            let _ = fs::remove_dir_all(&self.0);
        }
    }

    /// A picture with a bright square in the middle of a dark field, which the network and the
    /// classical extractor both have an opinion about.
    fn framed(width: u32, height: u32, subject: [u8; 4], background: [u8; 4]) -> Bitmap8 {
        let mut image = Bitmap8::filled(width, height, background);
        let (x0, y0, x1, y1) = (width / 4, height / 4, width * 3 / 4, height * 3 / 4);
        for y in y0..y1 {
            for x in x0..x1 {
                image.set(x, y, subject);
            }
        }
        image
    }

    #[test]
    fn the_input_tensor_is_nchw_and_centered() {
        let image = Bitmap8::filled(2, 2, [255, 128, 0, 255]);
        let side = 2;
        let tensor = input_tensor(&image, side);
        assert_eq!(tensor.len(), side * side * 3);
        // Red plane first, then green, then blue; one entry per pixel of the square.
        assert!((tensor[0] - (1.0 - MEAN[0]) / STD[0]).abs() < 1e-5, "{}", tensor[0]);
        assert!((tensor[side * side] - (128.0 / 255.0 - MEAN[1]) / STD[1]).abs() < 1e-5);
        assert!((tensor[2 * side * side] - (0.0 - MEAN[2]) / STD[2]).abs() < 1e-5);
    }

    #[test]
    fn the_input_tensor_resizes_any_image_to_the_models_square() {
        let image = framed(20, 60, [255, 255, 255, 255], [0, 0, 0, 255]);
        let tensor = input_tensor(&image, MODEL_SIDE);
        assert_eq!(tensor.len(), MODEL_SIDE * MODEL_SIDE * 3);
        // The bright square is in the middle, so the centre of the tensor is bright and the corners
        // are dark, whatever the image's aspect ratio was.
        let at = |x: usize, y: usize| tensor[y * MODEL_SIDE + x];
        assert!(at(MODEL_SIDE / 2, MODEL_SIDE / 2) > at(0, 0) + 1.0);
        assert!(at(0, 0) < 0.0, "a black pixel normalizes below zero");
    }

    #[test]
    fn a_flat_map_gives_a_flat_matte() {
        let matte = mask_from_map(&[0.5f32; 64], 8, 4);
        assert_eq!((matte.width(), matte.height()), (8, 4));
        for y in 0..4 {
            for x in 0..8 {
                assert_eq!(matte.get(x, y), 0, "a map with no range cannot be normalized");
            }
        }
    }

    #[test]
    fn an_empty_map_gives_an_empty_matte() {
        assert_eq!(mask_from_map(&[], 4, 4).get(0, 0), 0);
        assert_eq!(mask_from_map(&[1.0, 2.0], 0, 0).width(), 0);
    }

    #[test]
    fn a_non_finite_map_does_not_poison_the_matte() {
        // A model that returns a NaN must not turn the whole matte into NaN, which would read as
        // white everywhere after a cast.
        // A 4x4 map with one bright cell, and a NaN in the far corner.
        let mut map = vec![0f32; 16];
        map[4 + 1] = 1.0;
        map[15] = f32::NAN;
        let matte = mask_from_map(&map, 4, 4);
        assert_eq!(matte.get(0, 0), 0, "the map's finite minimum is black");
        assert_eq!(matte.get(1, 1), 255, "a pixel over the bright cell, away from the NaN, is white");
        assert_eq!(matte.get(3, 3), 0, "a pixel interpolating the NaN is background, not white");
    }

    #[test]
    fn the_matte_normalizes_by_the_maps_own_range() {
        // Four samples from 0 to 1, upsampled to a bigger canvas: the corners keep the ends of the
        // range and the middle sits between them.
        let matte = mask_from_map(&[0.0, 0.0, 0.0, 1.0], 16, 16);
        assert_eq!(matte.get(0, 0), 0, "the map's minimum is black");
        assert_eq!(matte.get(15, 15), 255, "the map's maximum is white");
        let middle = matte.get(8, 8);
        assert!(middle > 0 && middle < 255, "the middle is in between: {middle}");
    }

    #[test]
    fn the_matte_is_interpolated_rather_than_snapped() {
        // One bright sample in a dark map: its neighbours have to carry some of it, or the matte
        // would be blocky at every scale change.
        let mut map = vec![0f32; 16];
        map[5] = 1.0;
        let matte = mask_from_map(&map, 32, 32);
        let mut lit = 0;
        for y in 0..32 {
            for x in 0..32 {
                if matte.get(x, y) > 0 {
                    lit += 1;
                }
            }
        }
        assert!(lit > 4, "one sample should light more than its own pixel: {lit}");
    }

    #[test]
    fn a_model_is_looked_for_in_the_documented_order() {
        let tree = TempTree::new("locate");
        let models = tree.path().join("models");
        fs::create_dir_all(&models).unwrap();
        let beside_the_crate = models.join(SUBJECT_MODEL_FILE);
        fs::write(&beside_the_crate, b"not a model, just a file to find").unwrap();
        let environment = tree.path().join("elsewhere.onnx");
        fs::write(&environment, b"another file").unwrap();

        // The environment variable wins.
        assert_eq!(
            SubjectModel::locate_from(Some(environment.to_str().unwrap()), None, tree.path()),
            Some(environment.clone())
        );
        // Then the executable's own directory.
        let exe_models = tree.path().join("exe\\models");
        fs::create_dir_all(&exe_models).unwrap();
        let beside_the_exe = exe_models.join(SUBJECT_MODEL_FILE);
        fs::write(&beside_the_exe, b"yet another file").unwrap();
        assert_eq!(
            SubjectModel::locate_from(None, Some(&tree.path().join("exe")), tree.path()),
            Some(beside_the_exe.clone())
        );
        // Then the crate's own models directory.
        assert_eq!(SubjectModel::locate_from(None, None, tree.path()), Some(beside_the_crate));
    }

    #[test]
    fn a_model_that_is_not_there_is_not_a_model() {
        let tree = TempTree::new("nomodel");
        assert_eq!(SubjectModel::locate_from(None, None, tree.path()), None);
        // An environment variable naming a file that does not exist is ignored rather than fatal.
        let missing = tree.path().join("gone.onnx");
        assert_eq!(SubjectModel::locate_from(Some(missing.to_str().unwrap()), None, tree.path()), None);
        assert_eq!(SubjectModel::locate_from(Some("   "), None, tree.path()), None);
    }

    #[test]
    fn loading_a_model_that_is_not_there_says_which_path() {
        let tree = TempTree::new("missingload");
        let path = tree.path().join("gone.onnx");
        match SubjectModel::load(&path) {
            Err(error) => assert!(error.to_string().contains("gone.onnx"), "{error}"),
            Ok(_) => panic!("a missing model must not load"),
        }
    }

    #[test]
    fn loading_a_file_that_is_not_a_model_is_an_error_and_not_a_panic() {
        let tree = TempTree::new("garbage");
        let path = tree.path().join("model.onnx");
        fs::write(&path, b"this is not a protobuf, it is a sentence").unwrap();
        match SubjectModel::load(&path) {
            Err(error) => assert!(error.to_string().contains("model.onnx"), "{error}"),
            Ok(_) => panic!("a text file is not a model"),
        }
    }

    #[test]
    fn the_classical_extractor_answers_when_there_is_no_model() {
        // The fallback contract: with no model, this is byte for byte what the extractor always
        // produced, so a build without a model is the build that was there before.
        let image = framed(48, 48, [240, 240, 240, 255], [20, 20, 20, 255]);
        let options = SubjectOptions::default();
        let with_none = select_subject_with(&image, &options, None);
        let classical = select_subject(&image, &options);
        assert_eq!(with_none.width(), classical.width());
        for y in 0..classical.height() {
            for x in 0..classical.width() {
                assert_eq!(with_none.get(x, y), classical.get(x, y), "at {x},{y}");
            }
        }
    }

    #[test]
    fn an_image_with_no_pixels_gets_a_matte_of_no_pixels() {
        let image = Bitmap8::new(0, 0);
        let matte = select_subject_with(&image, &SubjectOptions::default(), None);
        assert_eq!((matte.width(), matte.height()), (0, 0));
    }

    /// The real model, when this checkout has one. Without the file the classical extractor is the
    /// whole story, and the test says so rather than failing.
    #[test]
    fn the_real_model_cuts_a_subject_out() {
        let Some(model) = SubjectModel::discover() else {
            eprintln!(
                "skipping: no subject model at {} (see NOTES.md for the source and where to put it)",
                SubjectModel::locate()
                    .map(|path| path.display().to_string())
                    .unwrap_or_else(|| format!("models/{SUBJECT_MODEL_FILE}"))
            );
            return;
        };
        eprintln!("subject model: {}", model.describe());
        assert_eq!(model.side(), MODEL_SIDE);
        let image = framed(96, 96, [230, 210, 190, 255], [30, 40, 60, 255]);
        let matte = model.mask(&image).expect("the model runs");
        assert_eq!((matte.width(), matte.height()), (96, 96));
        let mut bright = 0;
        let mut dark = 0;
        for y in 0..96 {
            for x in 0..96 {
                let value = matte.get(x, y);
                if value > 127 {
                    bright += 1;
                } else {
                    dark += 1;
                }
            }
        }
        assert!(bright > 0 && dark > 0, "a matte that is all one value says nothing: {bright} bright, {dark} dark");
        // The bright square covers about a quarter of the frame, and a salient-object network
        // should find at least part of it.
        let centre = matte.get(48, 48);
        assert!(centre > 127, "the middle of the subject is background: {centre}");
    }

    /// Coverage and leakage for both backends, on three synthetic frames. This is the measurement
    /// the report quotes; it asserts only that both answer, so it keeps printing when a future
    /// model does better or worse.
    #[test]
    fn the_real_model_against_the_classical_extractor() {
        let Some(model) = SubjectModel::discover() else {
            eprintln!("skipping the comparison: no subject model in this checkout");
            return;
        };
        let options = SubjectOptions::default();
        let cases: [(&str, Bitmap8, u32, u32, u32, u32); 5] = [
            ("a bright square on a dark field", framed(96, 96, [235, 235, 235, 255], [25, 25, 25, 255]), 24, 24, 72, 72),
            ("a warm subject on a cool field", framed(96, 96, [220, 170, 120, 255], [40, 60, 110, 255]), 24, 24, 72, 72),
            ("a disc on a gradient", disc_frame(), 26, 26, 70, 70),
            // The hard ones: a subject the border band is made of, and a subject so close to its
            // background in colour that a colour model has almost nothing to work with. These are
            // the cases a network is for, and the cases the classical extractor is expected to
            // struggle with, so the numbers are printed rather than asserted.
            ("a subject in the corner", corner_frame(), 8, 56, 40, 88),
            ("a subject almost the colour of its background", low_contrast_frame(), 24, 24, 72, 72),
        ];
        for (name, image, x0, y0, x1, y1) in cases {
            let truth = |x: u32, y: u32| x >= x0 && x < x1 && y >= y0 && y < y1;
            let model_matte = select_subject_with(&image, &options, Some(&model));
            let classical = select_subject_with(&image, &options, None);
            let (model_coverage, model_leakage) = coverage_and_leakage(&model_matte, truth);
            let (classical_coverage, classical_leakage) = coverage_and_leakage(&classical, truth);
            // A silent fallback would make this comparison a comparison with itself, so the two
            // answers have to differ somewhere.
            let mut differing = 0;
            for y in 0..image.height() {
                for x in 0..image.width() {
                    if model_matte.get(x, y) != classical.get(x, y) {
                        differing += 1;
                    }
                }
            }
            assert!(differing > 0, "{name}: the model and the classical extractor gave identical mattes");
            eprintln!("  {name}: {differing} pixels differ between the two mattes");
            eprintln!(
                "{name}: model coverage {model_coverage:.3} leakage {model_leakage:.3} | classical coverage {classical_coverage:.3} leakage {classical_leakage:.3}"
            );
            assert!(model_coverage >= 0.0 && model_coverage <= 1.0);
            assert!(classical_coverage >= 0.0 && classical_coverage <= 1.0);
        }
    }

    /// A subject that is not in the middle, which is where the classical extractor's centre prior
    /// is least help.
    fn corner_frame() -> Bitmap8 {
        // The same two colours as the framed case, with the subject in the lower left corner.
        let mut image = Bitmap8::filled(96, 96, [25, 25, 25, 255]);
        for y in 56..88 {
            for x in 8..40 {
                image.set(x, y, [235, 235, 235, 255]);
            }
        }
        image
    }

    /// A subject a few levels away from its background in every channel: a colour model has almost
    /// nothing to separate, a network has the shape.
    fn low_contrast_frame() -> Bitmap8 {
        let mut image = Bitmap8::new(96, 96);
        for y in 0..96 {
            for x in 0..96 {
                let inside = (24..72).contains(&x) && (24..72).contains(&y);
                let base = if inside { 132u8 } else { 120u8 };
                let ripple = ((x * 7 + y * 13) % 5) as u8;
                image.set(x, y, [base + ripple, base + ripple, base + ripple, 255]);
            }
        }
        image
    }

#[test]
    fn a_stamp_is_unchanged_while_the_file_is() {
        let tree = TempTree::new("stamp");
        let path = tree.path().join("model.bin");
        fs::write(&path, b"first contents").unwrap();
        let stamp = ModelStamp::read(&path).expect("a file has a stamp");
        assert!(stamp.is_current(&path));
        assert_eq!(ModelStamp::read(&path).unwrap(), stamp);
    }

    #[test]
    fn a_stamp_notices_a_rewritten_file() {
        let tree = TempTree::new("stampchanged");
        let path = tree.path().join("model.bin");
        fs::write(&path, b"first contents").unwrap();
        let stamp = ModelStamp::read(&path).unwrap();
        // A different length is the easy case; the same length with a newer time is the one a
        // size-only check would miss.
        fs::write(&path, b"second contents!").unwrap();
        assert!(!stamp.is_current(&path), "a longer file is not the one that was stamped");
        let same_length = ModelStamp::read(&path).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&path, b"third contents!!").unwrap();
        assert_eq!(ModelStamp::read(&path).unwrap().len, same_length.len);
        assert!(!same_length.is_current(&path), "a rewritten file is not the one that was stamped");
    }

    #[test]
    fn a_stamp_notices_a_deleted_file() {
        let tree = TempTree::new("stampgone");
        let path = tree.path().join("model.bin");
        fs::write(&path, b"contents").unwrap();
        let stamp = ModelStamp::read(&path).unwrap();
        fs::remove_file(&path).unwrap();
        assert!(!stamp.is_current(&path));
        assert_eq!(ModelStamp::read(&path), None);
    }

    #[test]
    fn the_model_and_its_jobs_cross_threads() {
        // The GUI loads the model on one thread and runs it on another.
        fn send_sync<T: Send + Sync>() {}
        fn send<T: Send>() {}
        send_sync::<SubjectModel>();
        send_sync::<std::sync::Arc<SubjectModel>>();
        send::<SubjectJob>();
        send::<SubjectPreview>();
        send_sync::<SubjectOptions>();
    }

    #[test]
    fn a_job_answers_with_the_classical_matte_when_there_is_no_model() {
        let image = framed(48, 48, [240, 240, 240, 255], [20, 20, 20, 255]);
        let options = SubjectOptions::default();
        let job = SubjectJob::start(image.clone(), options.clone(), None);
        let matte = job.wait().expect("a matte, model or not");
        let classical = select_subject(&image, &options);
        for y in 0..48 {
            for x in 0..48 {
                assert_eq!(matte.get(x, y), classical.get(x, y), "at {x},{y}");
            }
        }
    }

    #[test]
    fn a_job_can_be_polled_until_it_is_ready() {
        let image = framed(32, 32, [200, 200, 200, 255], [10, 10, 10, 255]);
        let mut job = SubjectJob::start(image, SubjectOptions::default(), None);
        assert!(job.is_running(), "a fresh job has not answered yet");
        let deadline = std::time::Instant::now() + std::time::Duration::from_secs(30);
        let matte = loop {
            if let Some(result) = job.poll() {
                break result.expect("a matte");
            }
            assert!(std::time::Instant::now() < deadline, "the job never answered");
            std::thread::sleep(std::time::Duration::from_millis(2));
        };
        assert!(!job.is_running(), "collecting the answer retires the job");
        assert_eq!((matte.width(), matte.height()), (32, 32));
        // Polling is one-shot: the answer is not handed out twice.
        assert!(job.poll().is_none());
    }

    #[test]
    fn a_preview_has_the_classical_matte_before_the_model_answers() {
        let image = framed(48, 48, [230, 230, 230, 255], [30, 30, 30, 255]);
        let options = SubjectOptions::default();
        let preview = SubjectPreview::start(&image, &options, None);
        let classical = select_subject(&image, &options);
        for y in 0..48 {
            for x in 0..48 {
                assert_eq!(preview.classical.get(x, y), classical.get(x, y), "at {x},{y}");
            }
        }
        // The job carries the same answer when there is no model, so a caller can use this shape
        // unconditionally.
        let from_job = preview.job.wait().expect("a matte");
        assert_eq!((from_job.width(), from_job.height()), (48, 48));
    }

    #[test]
    fn jobs_are_numbered_so_a_caller_can_ignore_the_old_ones() {
        let image = framed(16, 16, [255, 255, 255, 255], [0, 0, 0, 255]);
        let first = SubjectJob::start(image.clone(), SubjectOptions::default(), None);
        let second = SubjectJob::start(image, SubjectOptions::default(), None);
        assert!(second.generation() > first.generation());
        // Dropping a job whose answer nobody wants must not block the caller.
        let started = std::time::Instant::now();
        drop(first);
        drop(second);
        assert!(started.elapsed() < std::time::Duration::from_millis(250), "dropping waited for the worker");
    }

    #[test]
    fn starting_a_job_does_not_wait_for_the_work() {
        // A big canvas with a model would take a while; even the classical path is not what start
        // is allowed to spend time on. This asserts the call returns, promptly, on a canvas big
        // enough that the classical extraction alone is not instant.
        let image = framed(512, 512, [240, 240, 240, 255], [16, 16, 16, 255]);
        let started = std::time::Instant::now();
        let job = SubjectJob::start(image, SubjectOptions::default(), None);
        let elapsed = started.elapsed();
        assert!(elapsed < std::time::Duration::from_millis(200), "start took {elapsed:?}");
        assert!(job.wait().is_ok());
    }

    /// The cache, with the real model. Without a model file there is nothing to cache, so the test
    /// says so and stops.
    #[test]
    fn the_cache_loads_a_model_once_and_notices_a_replaced_file() {
        let Some(path) = SubjectModel::locate() else {
            eprintln!("skipping: no subject model in this checkout");
            return;
        };
        let tree = TempTree::new("cache");
        let copy = tree.path().join(SUBJECT_MODEL_FILE);
        fs::copy(&path, &copy).expect("a copy of the model");

        // Identity is the proof: a second call that returns the same Arc did not load anything.
        let first = SubjectModel::cached(&copy).expect("the copy loads");
        let loads_after_first = load_count();
        let second = SubjectModel::cached(&copy).expect("the cache answers");
        assert!(std::sync::Arc::ptr_eq(&first, &second), "the second call reuses the plan");
        assert_eq!(load_count(), loads_after_first, "and loads nothing");

        // A different path is a different model.
        let other = tree.path().join("other.onnx");
        fs::copy(&path, &other).unwrap();
        let third = SubjectModel::cached(&other).expect("the other copy loads");
        assert!(!std::sync::Arc::ptr_eq(&first, &third));

        // Replacing the file invalidates the entry, even when the new file has the same length.
        let bytes = fs::read(&copy).unwrap();
        std::thread::sleep(std::time::Duration::from_millis(20));
        fs::write(&copy, &bytes).unwrap();
        let fourth = SubjectModel::cached(&copy).expect("the replacement loads");
        assert!(!std::sync::Arc::ptr_eq(&first, &fourth), "a rewritten model is a different plan");
        assert_eq!(load_count(), loads_after_first + 2, "one for the other path, one for the rewrite");
    }

    /// Multi-threading must not change the answer. It does change the order of some floating point
    /// sums, so this compares within a couple of levels rather than byte for byte, and prints the
    /// worst difference it saw.
    #[test]
    fn the_answer_does_not_depend_on_the_thread_count() {
        let Some(model) = SubjectModel::discover() else {
            eprintln!("skipping: no subject model in this checkout");
            return;
        };
        let image = framed(128, 128, [225, 205, 185, 255], [35, 45, 65, 255]);
        use_threads(1);
        let single = model.mask(&image).expect("one thread runs");
        use_threads(default_threads());
        let many = model.mask(&image).expect("many threads run");
        let mut worst = 0i32;
        for y in 0..image.height() {
            for x in 0..image.width() {
                worst = worst.max((single.get(x, y) as i32 - many.get(x, y) as i32).abs());
            }
        }
        eprintln!("one thread and {} threads differ by at most {worst} level(s)", default_threads());
        assert!(worst <= 2, "the thread count changed the matte by {worst}");
    }

    /// A job with the real model: the flow the editor uses, measured.
    #[test]
    fn a_job_with_the_real_model_answers_in_the_background() {
        let Some(model) = SubjectModel::cached_discovered() else {
            eprintln!("skipping: no subject model in this checkout");
            return;
        };
        let image = framed(256, 256, [225, 205, 185, 255], [35, 45, 65, 255]);
        let started = std::time::Instant::now();
        let preview = SubjectPreview::start(&image, &SubjectOptions::default(), Some(model));
        let classical_ready = started.elapsed();
        let mut job = preview.job;
        let mut polls = 0;
        let matte = loop {
            if let Some(result) = job.poll() {
                break result.expect("a matte");
            }
            polls += 1;
            assert!(started.elapsed() < std::time::Duration::from_secs(120), "the job never answered");
            std::thread::sleep(std::time::Duration::from_millis(5));
        };
        eprintln!(
            "preview: classical matte in {classical_ready:?}, model matte after {:?} ({polls} polls)",
            started.elapsed()
        );
        assert_eq!((matte.width(), matte.height()), (256, 256));
    }

    /// The release numbers. Run with
    /// @cargo test --release -p comp-brush -- --ignored --nocapture bench_subject_model@.
    #[test]
    #[ignore = "timing benchmark"]
    fn bench_subject_model() {
        let Some(path) = SubjectModel::locate() else {
            eprintln!("no subject model in this checkout: nothing to measure");
            return;
        };
        let image = framed(1024, 768, [225, 205, 185, 255], [35, 45, 65, 255]);
        let options = SubjectOptions::default();

        let threads = default_threads();
        for (side, threads) in [(320usize, 1usize), (320, threads), (288, threads), (256, threads), (224, threads)] {
            use_threads(threads);
            let started = std::time::Instant::now();
            let model = SubjectModel::load_at_side(&path, side).expect("the model loads");
            let loaded = started.elapsed();
            // One warm-up, then five measured runs.
            let _ = model.mask(&image).expect("a matte");
            let mut inference = Vec::new();
            for _ in 0..5 {
                let started = std::time::Instant::now();
                let _ = model.mask(&image).expect("a matte");
                inference.push(started.elapsed().as_secs_f64() * 1000.0);
            }
            inference.sort_by(|a, b| a.partial_cmp(b).unwrap());
            let mut end_to_end = Vec::new();
            for _ in 0..3 {
                let started = std::time::Instant::now();
                let _ = select_subject_with(&image, &options, Some(&model));
                end_to_end.push(started.elapsed().as_secs_f64() * 1000.0);
            }
            end_to_end.sort_by(|a, b| a.partial_cmp(b).unwrap());
            eprintln!(
                "side {side}, {threads} thread(s): load {:.0} ms, inference median {:.0} ms (min {:.0}, max {:.0}), end to end median {:.0} ms",
                loaded.as_secs_f64() * 1000.0,
                inference[inference.len() / 2],
                inference[0],
                inference[inference.len() - 1],
                end_to_end[end_to_end.len() / 2]
            );
        }
        // The threading thresholds decide when an operator is worth splitting across threads.
        // tract's defaults are sized for big graphs; this one is small.
        use_threads(threads);
        tract_linalg::multithread::set_threading_panel_threshold(1);
        tract_linalg::multithread::set_threading_element_threshold(1 << 10);
        let model = SubjectModel::load_at_side(&path, 320).expect("the model loads");
        let _ = model.mask(&image).expect("a matte");
        let mut tuned = Vec::new();
        for _ in 0..5 {
            let started = std::time::Instant::now();
            let _ = model.mask(&image).expect("a matte");
            tuned.push(started.elapsed().as_secs_f64() * 1000.0);
        }
        tuned.sort_by(|a, b| a.partial_cmp(b).unwrap());
        eprintln!("side 320, {threads} threads, low thresholds: inference median {:.0} ms", tuned[tuned.len() / 2]);
        use_threads(1);
        let started = std::time::Instant::now();
        let classical = select_subject(&image, &options);
        eprintln!("classical extractor, for reference: {:.0} ms", started.elapsed().as_secs_f64() * 1000.0);
        assert_eq!((classical.width(), classical.height()), (1024, 768));
        use_threads(default_threads());
    }

    /// A disc of one color on a gradient, with a little noise so the classical extractor has
    /// something to chew on.
    fn disc_frame() -> Bitmap8 {
        let size = 96u32;
        let mut image = Bitmap8::new(size, size);
        let centre = size as f64 / 2.0;
        let radius = size as f64 * 0.28;
        for y in 0..size {
            for x in 0..size {
                let dx = x as f64 - centre;
                let dy = y as f64 - centre;
                let inside = (dx * dx + dy * dy).sqrt() <= radius;
                let shade = ((x + y) % 32) as u8;
                let pixel = if inside {
                    [240, 120, 60, 255]
                } else {
                    [40 + shade, 60 + shade, 90 + shade, 255]
                };
                image.set(x, y, pixel);
            }
        }
        image
    }

    /// Share of the true subject above the half threshold, and share of the true background above
    /// it. Coverage 1 and leakage 0 is a perfect cut-out.
    fn coverage_and_leakage(matte: &Gray8, truth: impl Fn(u32, u32) -> bool) -> (f64, f64) {
        let (mut subject_hits, mut subject_total) = (0u32, 0u32);
        let (mut background_hits, mut background_total) = (0u32, 0u32);
        for y in 0..matte.height() {
            for x in 0..matte.width() {
                let lit = matte.get(x, y) > 127;
                if truth(x, y) {
                    subject_total += 1;
                    if lit {
                        subject_hits += 1;
                    }
                } else {
                    background_total += 1;
                    if lit {
                        background_hits += 1;
                    }
                }
            }
        }
        let coverage = if subject_total == 0 { 0.0 } else { subject_hits as f64 / subject_total as f64 };
        let leakage = if background_total == 0 { 0.0 } else { background_hits as f64 / background_total as f64 };
        (coverage, leakage)
    }
}

