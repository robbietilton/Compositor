//! Background work: package IO and compositing, both off the UI thread.
//!
//! The UI thread only hands over a document clone and polls for results, so opening a large package
//! or flattening a big canvas never stalls a frame. Render jobs coalesce, since only the newest
//! document state is worth drawing.

use std::path::{Path, PathBuf};
use std::sync::mpsc::{self, Receiver, RecvTimeoutError, Sender};
use std::thread;
use std::time::{Duration, Instant};

use comp_core::bitmap::Bitmap8;
use comp_core::document::Document;

use crate::engine::{self, Bounds};

/// Reads a package and its digest, with the failure classified for the user.
pub fn open_document(path: &Path) -> Result<(Document, Option<String>), crate::loaderror::LoadProblem> {
    let loaded = comp_core::store::load_project(path).map_err(|error| classify(&error, path))?;
    Ok((loaded.document, Some(loaded.digest)))
}

/// Classifies a failure from the format layer, keeping the path in the message.
pub fn classify(error: &comp_core::Error, path: &Path) -> crate::loaderror::LoadProblem {
    use crate::loaderror::LoadProblem;
    // The format layer answers a missing package with the same error it uses for a damaged one, so
    // the path is checked first: "there is nothing there" is a different problem from "this is
    // damaged", and only one of them is worth retrying.
    if !path.exists() {
        return LoadProblem::IllegalPath {
            path: path.display().to_string(),
            detail: "there is nothing at that path".to_string(),
        };
    }
    // The kind and the place come from the format layer; the only thing this caller knows better is
    // which path it asked for, so that is added where the error does not carry one itself.
    let problem = LoadProblem::from_core(error);
    match problem {
        LoadProblem::Io { detail } => LoadProblem::IllegalPath {
            path: path.display().to_string(),
            detail,
        },
        // A package failure with no path of its own is about the folder that was opened.
        LoadProblem::CorruptPackage { detail } if error.path().is_none() => LoadProblem::CorruptPackage {
            detail: format!("{} is not a readable Compositor project ({detail})", path.display()),
        },
        other => other,
    }
}

/// Where the recovery copies live for this machine.
pub fn recovery_root() -> PathBuf {
    crate::recovery::recovery_dir(&crate::recovery::data_dir())
}

/// Writes a recovery copy of a document: the package, and a note saying where it came from.
pub fn write_recovery(document: &mut Document, root: &Path, entry: &crate::recovery::RecoveryEntry) -> Result<(), String> {
    let folder = root.join(&entry.id);
    std::fs::create_dir_all(&folder).map_err(|error| error.to_string())?;
    document.refresh_asset_names();
    comp_core::store::save(document, &folder.join("document.comp")).map_err(|error| error.to_string())?;
    let note = serde_json::json!({
        "id": entry.id,
        "original": entry.original.as_ref().map(|path| path.display().to_string()),
        "bytes": entry.bytes,
    });
    std::fs::write(folder.join("recovery.json"), note.to_string()).map_err(|error| error.to_string())
}

/// Every recovery copy in the root, as the notes describe them.
pub fn scan_recovery(root: &Path) -> Vec<crate::recovery::RecoveryEntry> {
    let mut found = Vec::new();
    let Ok(entries) = std::fs::read_dir(root) else { return found };
    for entry in entries.flatten() {
        let folder = entry.path();
        if !folder.is_dir() {
            continue;
        }
        let Ok(note) = std::fs::read_to_string(folder.join("recovery.json")) else { continue };
        let Ok(note) = serde_json::from_str::<serde_json::Value>(&note) else { continue };
        let id = note.get("id").and_then(|value| value.as_str()).unwrap_or_default().to_string();
        if id.is_empty() {
            continue;
        }
        let original = note.get("original").and_then(|value| value.as_str()).map(PathBuf::from);
        // The copy's own timestamp is when it was written; the note is written with it.
        let written = entry
            .metadata()
            .and_then(|metadata| metadata.modified())
            .unwrap_or(std::time::SystemTime::UNIX_EPOCH);
        found.push(crate::recovery::RecoveryEntry { id, original, written, bytes: 0 });
    }
    found.sort_by(|left, right| right.written.cmp(&left.written));
    found
}

/// Reads one recovery copy back.
pub fn read_recovery(root: &Path, id: &str) -> Result<Document, crate::loaderror::LoadProblem> {
    let folder = root.join(id);
    let loaded = comp_core::store::load_project(&folder.join("document.comp"))
        .map_err(|error| classify(&error, &folder.join("document.comp")))?;
    Ok(loaded.document)
}

/// Removes recovery copies and the folders they live in.
pub fn discard_recovery(root: &Path, ids: &[String]) -> usize {
    let mut removed = 0;
    for id in ids {
        let folder = root.join(id);
        if std::fs::remove_dir_all(&folder).is_ok() {
            removed += 1;
        }
    }
    removed
}

/// Refreshes asset names and writes a package.
pub fn save_document(document: &mut Document, path: &Path) -> Result<(), String> {
    document.refresh_asset_names();
    comp_core::store::save(document, path).map_err(|error| format!("{}: {error}", path.display()))
}

/// Flattens the document and writes an image at the document's resolution.
///
/// The format follows the file name: JPEG for .jpg and .jpeg, PNG otherwise. The whole image is
/// composited with the backend the policy picks, and the caller is told which one ran.
pub fn export_image(
    document: &Document,
    path: &Path,
    preference: crate::backend::Preference,
) -> Result<(u32, u32, crate::backend::Backend), String> {
    let (bitmap, backend) = engine::flatten_full(document, preference);
    let jpeg = path
        .extension()
        .map(|extension| {
            let extension = extension.to_string_lossy().to_ascii_lowercase();
            extension == "jpg" || extension == "jpeg"
        })
        .unwrap_or(false);
    let written = if jpeg {
        comp_io::export_jpeg(&bitmap, path, JPEG_QUALITY, document.resolution)
    } else {
        comp_io::export_png(&bitmap, path, document.resolution)
    };
    written.map_err(|error| format!("{}: {error}", path.display()))?;
    Ok((bitmap.width(), bitmap.height(), backend))
}

/// The quality the JPEG export uses; high enough that the flattened canvas keeps its detail.
pub const JPEG_QUALITY: u8 = 92;

/// Reads an image or Photoshop file and places it in a document as a new layer.
///
/// The placement follows the macOS insert: centered on the canvas.
pub fn import_layer(document: &mut Document, path: &Path) -> Result<uuid::Uuid, String> {
    let raster = comp_io::import_raster(path, &comp_io::ImportOptions::default())
        .map_err(|error| format!("{}: {error}", path.display()))?;
    comp_io::place_imported(document, raster, None).map_err(|error| format!("{}: {error}", path.display()))
}

/// A package operation for the IO worker.
pub enum IoRequest {
    Open(PathBuf),
    Save { document: Document, path: PathBuf },
    Export { document: Document, path: PathBuf, preference: crate::backend::Preference },
    /// Reads an image or Photoshop file into a new layer of this document.
    ImportLayer { document: Document, path: PathBuf },
    /// Reads an image, Photoshop file or package into a document of its own.
    ImportDocument { path: PathBuf },
    /// Writes a recovery copy for a document that has unsaved changes.
    Autosave { document: Document, root: PathBuf, entry: crate::recovery::RecoveryEntry },
    /// Looks for recovery copies left by an earlier run.
    ScanRecovery { root: PathBuf },
    /// Reads one recovery copy back into a document.
    RecoverDocument { root: PathBuf, id: String, entry: crate::recovery::RecoveryEntry },
    /// Throws recovery copies away.
    DiscardRecovery { root: PathBuf, ids: Vec<String> },
}

/// What the IO worker finished.
pub enum IoResult {
    Opened { path: PathBuf, document: Document, digest: Option<String> },
    Saved { path: PathBuf },
    Exported { path: PathBuf, width: u32, height: u32, backend: crate::backend::Backend },
    /// The document now carries an imported layer; the id is the layer that was added.
    ImportedLayer { path: PathBuf, document: Document, layer: uuid::Uuid },
    /// An imported file became a document of its own, with no package path yet.
    ImportedDocument { path: PathBuf, document: Document },
    Failed { action: &'static str, problem: crate::loaderror::LoadProblem },
    /// A recovery copy was written.
    Autosaved { id: String },
    /// The recovery copies the last run left behind.
    RecoveryFound { entries: Vec<crate::recovery::RecoveryEntry> },
    /// A recovery copy came back as a document.
    Recovered { id: String, entry: crate::recovery::RecoveryEntry, document: Document },
    /// Recovery copies were cleaned up.
    RecoveryCleaned { removed: usize },
}

/// Runs package IO on one worker thread, in the order the requests arrive.
pub struct IoWorker {
    sender: Sender<IoRequest>,
    receiver: Receiver<IoResult>,
    outstanding: usize,
}

impl IoWorker {
    pub fn new() -> Self {
        let (request_sender, request_receiver) = mpsc::channel::<IoRequest>();
        let (result_sender, result_receiver) = mpsc::channel::<IoResult>();
        thread::Builder::new()
            .name("comp-gui-io".to_string())
            .spawn(move || {
                while let Ok(request) = request_receiver.recv() {
                    let result = match request {
                        IoRequest::Open(path) => match open_document(&path) {
                            Ok((document, digest)) => IoResult::Opened { path, document, digest },
                            Err(problem) => IoResult::Failed { action: "Open", problem },
                        },
                        IoRequest::Save { mut document, path } => match save_document(&mut document, &path) {
                            Ok(()) => IoResult::Saved { path },
                            Err(message) => IoResult::Failed {
                                action: "Save",
                                problem: crate::loaderror::LoadProblem::IllegalPath {
                                    path: path.display().to_string(),
                                    detail: message,
                                },
                            },
                        },
                        IoRequest::Export { document, path, preference } => match export_image(&document, &path, preference) {
                            Ok((width, height, backend)) => IoResult::Exported { path, width, height, backend },
                            Err(message) => IoResult::Failed {
                                action: "Export",
                                problem: crate::loaderror::LoadProblem::IllegalPath {
                                    path: path.display().to_string(),
                                    detail: message,
                                },
                            },
                        },
                        IoRequest::ImportLayer { mut document, path } => match import_layer(&mut document, &path) {
                            Ok(layer) => IoResult::ImportedLayer { path, document, layer },
                            Err(message) => IoResult::Failed {
                                action: "Import",
                                problem: crate::loaderror::LoadProblem::from_message(&message),
                            },
                        },
                        IoRequest::ImportDocument { path } => match comp_io::import_document(&path) {
                            Ok(document) => IoResult::ImportedDocument { path, document },
                            Err(error) => IoResult::Failed {
                                action: "Import",
                                problem: crate::loaderror::LoadProblem::from_message(&format!("{}: {error}", path.display())),
                            },
                        },
                        IoRequest::Autosave { mut document, root, entry } => {
                            let id = entry.id.clone();
                            match write_recovery(&mut document, &root, &entry) {
                                Ok(()) => IoResult::Autosaved { id },
                                Err(message) => IoResult::Failed {
                                    action: "Autosave",
                                    problem: crate::loaderror::LoadProblem::IllegalPath {
                                        path: root.display().to_string(),
                                        detail: message,
                                    },
                                },
                            }
                        }
                        IoRequest::ScanRecovery { root } => IoResult::RecoveryFound { entries: scan_recovery(&root) },
                        IoRequest::RecoverDocument { root, id, entry } => match read_recovery(&root, &id) {
                            Ok(document) => IoResult::Recovered { id, entry, document },
                            Err(problem) => IoResult::Failed { action: "Recover", problem },
                        },
                        IoRequest::DiscardRecovery { root, ids } => {
                            IoResult::RecoveryCleaned { removed: discard_recovery(&root, &ids) }
                        }
                    };
                    if result_sender.send(result).is_err() {
                        break;
                    }
                }
            })
            .expect("the IO worker thread must start");
        IoWorker { sender: request_sender, receiver: result_receiver, outstanding: 0 }
    }

    pub fn send(&mut self, request: IoRequest) {
        self.outstanding += 1;
        if self.sender.send(request).is_err() {
            self.outstanding = self.outstanding.saturating_sub(1);
        }
    }

    pub fn poll(&mut self) -> Option<IoResult> {
        match self.receiver.try_recv() {
            Ok(result) => {
                self.outstanding = self.outstanding.saturating_sub(1);
                Some(result)
            }
            Err(_) => None,
        }
    }

    pub fn is_busy(&self) -> bool {
        self.outstanding > 0
    }
}

impl Default for IoWorker {
    fn default() -> Self {
        IoWorker::new()
    }
}

/// How much of the canvas a render job covers.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum RenderScope {
    /// The whole canvas, which is what a structural edit needs.
    Full,
    /// One dirty rectangle in canvas pixels, which is what a stroke needs.
    Region(Bounds),
}

/// The largest area both scopes cover, so coalescing two queued jobs stays correct.
fn merge_scope(pending: RenderScope, next: RenderScope) -> RenderScope {
    match (pending, next) {
        (RenderScope::Full, _) | (_, RenderScope::Full) => RenderScope::Full,
        (RenderScope::Region(a), RenderScope::Region(b)) => {
            RenderScope::Region(engine::union_bounds(Some(a), b).unwrap_or(a))
        }
    }
}

/// A finished flatten pass.
pub struct RenderDone {
    pub epoch: u64,
    pub bitmap: Bitmap8,
    /// The canvas pixel the bitmap's top-left corner sits at; (0, 0) for a full pass.
    pub origin: (i64, i64),
    pub millis: u64,
    /// Which compositor drew it, so the status bar reports what actually ran.
    pub backend: crate::backend::Backend,
}

/// Flattens documents on a worker thread, always keeping only the newest queued job.
pub struct RenderWorker {
    sender: Sender<(u64, Document, RenderScope, crate::backend::Preference)>,
    receiver: Receiver<RenderDone>,
    epoch: u64,
    outstanding: usize,
}

impl RenderWorker {
    pub fn new() -> Self {
        let (job_sender, job_receiver) = mpsc::channel::<(u64, Document, RenderScope, crate::backend::Preference)>();
        let (done_sender, done_receiver) = mpsc::channel::<RenderDone>();
        thread::Builder::new()
            .name("comp-gui-render".to_string())
            .spawn(move || {
                while let Ok((mut epoch, mut document, mut scope, mut preference)) = job_receiver.recv() {
                    // A newer request supersedes the queued ones, but the areas they covered still
                    // have to be repainted, so the scopes merge instead of replacing each other. The
                    // newer request's preference is the one that counts.
                    while let Ok((newer_epoch, newer_document, newer_scope, newer_preference)) = job_receiver.try_recv() {
                        epoch = newer_epoch;
                        document = newer_document;
                        scope = merge_scope(scope, newer_scope);
                        preference = newer_preference;
                    }
                    let started = Instant::now();
                    // A whole canvas takes the GPU when it can; a dirty rectangle stays on the CPU,
                    // where a few milliseconds of work beats a round trip.
                    let (bitmap, origin, backend) = match scope {
                        RenderScope::Full => {
                            let (bitmap, backend) = engine::flatten_full(&document, preference);
                            (bitmap, (0, 0), backend)
                        }
                        RenderScope::Region(bounds) => {
                            match engine::clamp_bounds(bounds, document.width, document.height)
                                .and_then(|clamped| engine::flatten_region(&document, clamped).map(|bitmap| (clamped, bitmap)))
                            {
                                Some((clamped, bitmap)) => (bitmap, (clamped.0, clamped.1), crate::backend::Backend::Cpu),
                                // The region left the canvas while it was queued.
                                None => (Bitmap8::new(0, 0), (0, 0), crate::backend::Backend::Cpu),
                            }
                        }
                    };
                    let millis = started.elapsed().as_millis() as u64;
                    let done = RenderDone { epoch, bitmap, origin, millis, backend };
                    if done_sender.send(done).is_err() {
                        break;
                    }
                }
            })
            .expect("the render worker thread must start");
        RenderWorker { sender: job_sender, receiver: done_receiver, epoch: 0, outstanding: 0 }
    }

    /// Queues a full-canvas flatten and returns the epoch it was tagged with.
    pub fn request(&mut self, document: &Document, preference: crate::backend::Preference) -> u64 {
        self.request_scope(document, RenderScope::Full, preference)
    }

    /// Queues a flatten of one dirty rectangle, which always runs on the CPU.
    pub fn request_region(&mut self, document: &Document, bounds: Bounds) -> u64 {
        self.request_scope(document, RenderScope::Region(bounds), crate::backend::Preference::PreferGpu)
    }

    fn request_scope(
        &mut self,
        document: &Document,
        scope: RenderScope,
        preference: crate::backend::Preference,
    ) -> u64 {
        self.epoch += 1;
        if self.sender.send((self.epoch, document.clone(), scope, preference)).is_ok() {
            self.outstanding += 1;
        }
        self.epoch
    }

    pub fn poll(&mut self) -> Option<RenderDone> {
        match self.receiver.try_recv() {
            Ok(done) => {
                self.outstanding = self.outstanding.saturating_sub(1);
                Some(done)
            }
            // An empty channel is the normal case; the worker only ever sends finished jobs.
            Err(_) => None,
        }
    }

    pub fn is_busy(&self) -> bool {
        self.outstanding > 0
    }

    pub fn latest_epoch(&self) -> u64 {
        self.epoch
    }
}

impl Default for RenderWorker {
    fn default() -> Self {
        RenderWorker::new()
    }
}

/// How often the watcher reads a package's digest.
pub const WATCH_INTERVAL: Duration = Duration::from_millis(1000);

/// Polls a package's digest on a worker thread so the UI thread never touches the disk.
///
/// It reports the digest it read, including None when the package cannot be read; deciding whether
/// that is news is the caller's state machine.
pub struct WatchWorker {
    target: Sender<Option<PathBuf>>,
    digest: Receiver<Option<String>>,
}

impl WatchWorker {
    pub fn new() -> Self {
        let (target_sender, target_receiver) = mpsc::channel::<Option<PathBuf>>();
        let (digest_sender, digest_receiver) = mpsc::channel::<Option<String>>();
        thread::Builder::new()
            .name("comp-gui-watch".to_string())
            .spawn(move || {
                let mut path: Option<PathBuf> = None;
                loop {
                    // A new target takes effect at once; otherwise a tick goes by between reads.
                    match target_receiver.recv_timeout(WATCH_INTERVAL) {
                        Ok(next) => path = next,
                        Err(RecvTimeoutError::Timeout) => {}
                        Err(RecvTimeoutError::Disconnected) => break,
                    }
                    if let Some(path) = &path {
                        let digest = comp_core::digest::package_digest(path).ok();
                        if digest_sender.send(digest).is_err() {
                            break;
                        }
                    }
                }
            })
            .expect("the watch worker thread must start");
        WatchWorker { target: target_sender, digest: digest_receiver }
    }

    /// Points the watcher at a package, or at nothing.
    pub fn watch(&mut self, path: Option<PathBuf>) {
        let _ = self.target.send(path);
    }

    /// The newest digest read, or None when the thread has not reported since the last poll.
    pub fn poll(&mut self) -> Option<Option<String>> {
        self.digest.try_recv().ok()
    }
}

impl Default for WatchWorker {
    fn default() -> Self {
        WatchWorker::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::time::Duration;

    fn wait_for_render(worker: &mut RenderWorker, epoch: u64) -> RenderDone {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(done) = worker.poll() {
                if done.epoch == epoch {
                    return done;
                }
            }
            assert!(Instant::now() < deadline, "the render worker did not answer epoch {epoch}");
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn wait_for_io(worker: &mut IoWorker) -> IoResult {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            if let Some(result) = worker.poll() {
                return result;
            }
            assert!(Instant::now() < deadline, "the IO worker did not answer");
            thread::sleep(Duration::from_millis(5));
        }
    }

    fn temp_root(tag: &str) -> PathBuf {
        let root = std::env::temp_dir().join(format!("comp-gui-worker-{tag}-{}", uuid::Uuid::new_v4()));
        std::fs::create_dir_all(&root).unwrap();
        root
    }

    #[test]
    fn saving_then_opening_round_trips_through_the_helpers() {
        let root = temp_root("roundtrip");
        let package = root.join("Doc.comp");
        let mut document = comp_core::store::solid_document(12, 6, [3, 4, 5, 255]);
        save_document(&mut document, &package).unwrap();
        let (loaded, digest) = open_document(&package).unwrap();
        assert_eq!(loaded.width, 12);
        assert_eq!(loaded.layers[0].image.as_ref().unwrap().get(2, 2), [3, 4, 5, 255]);
        assert!(digest.is_some());
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn png_export_writes_a_decodable_file() {
        let root = temp_root("export");
        let target = root.join("Flat.png");
        let document = comp_core::store::solid_document(9, 7, [250, 0, 10, 255]);
        let (width, height, _) = export_image(&document, &target, crate::backend::Preference::ForceCpu).unwrap();
        assert_eq!((width, height), (9, 7));
        let bytes = std::fs::read(&target).unwrap();
        let decoded = comp_core::png_io::decode_png(&bytes).unwrap().to_bitmap8().unwrap();
        assert_eq!(decoded.get(4, 3), [250, 0, 10, 255]);
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_render_worker_answers_the_newest_request() {
        let mut worker = RenderWorker::new();
        let red = comp_core::store::solid_document(8, 8, [255, 0, 0, 255]);
        worker.request(&red, crate::backend::Preference::PreferGpu);
        let blue = comp_core::store::solid_document(8, 8, [0, 0, 255, 255]);
        let epoch = worker.request(&blue, crate::backend::Preference::PreferGpu);
        let done = wait_for_render(&mut worker, epoch);
        assert_eq!(done.bitmap.get(1, 1), [0, 0, 255, 255]);
        assert_eq!(done.origin, (0, 0));
        assert!(done.millis < 20_000);
    }

    #[test]
    fn a_region_request_reports_its_origin_and_size() {
        let mut worker = RenderWorker::new();
        let document = comp_core::store::solid_document(64, 48, [12, 34, 56, 255]);
        let epoch = worker.request_region(&document, (16, 8, 20, 10));
        let done = wait_for_render(&mut worker, epoch);
        assert_eq!(done.origin, (16, 8));
        assert_eq!((done.bitmap.width(), done.bitmap.height()), (20, 10));
        assert_eq!(done.bitmap.get(0, 0), [12, 34, 56, 255]);

        // A region that misses the canvas comes back empty instead of failing.
        let epoch = worker.request_region(&document, (200, 200, 8, 8));
        let done = wait_for_render(&mut worker, epoch);
        assert!(done.bitmap.is_empty());
    }

    #[test]
    fn coalescing_keeps_every_queued_area() {
        assert_eq!(merge_scope(RenderScope::Full, RenderScope::Region((0, 0, 4, 4))), RenderScope::Full);
        assert_eq!(merge_scope(RenderScope::Region((0, 0, 4, 4)), RenderScope::Full), RenderScope::Full);
        assert_eq!(
            merge_scope(RenderScope::Region((4, 4, 4, 4)), RenderScope::Region((10, 10, 2, 2))),
            RenderScope::Region((4, 4, 8, 8))
        );
    }

    #[test]
    fn a_png_is_imported_as_a_layer_on_top_of_a_document() {
        let root = temp_root("import-layer");
        let png = root.join("Patch.png");
        let source = comp_core::store::solid_document(6, 4, [200, 30, 40, 255]);
        export_image(&source, &png, crate::backend::Preference::ForceCpu).unwrap();

        let mut document = comp_core::store::solid_document(32, 32, [0, 0, 0, 255]);
        let layers_before = document.layers.len();
        let added = import_layer(&mut document, &png).expect("the PNG should import");
        assert_eq!(document.layers.len(), layers_before + 1);
        assert_eq!(document.active_layer, Some(added));
        let layer = document.layer(added).unwrap();
        assert_eq!(layer.image.as_ref().unwrap().get(1, 1), [200, 30, 40, 255]);
        // Centered on the canvas, as EditorSession.insert does.
        assert_eq!(layer.transform.origin, comp_core::geom::PointF::new(13.0, 14.0));
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_failed_import_reports_the_file() {
        let mut document = comp_core::store::solid_document(8, 8, [1, 2, 3, 255]);
        let missing = std::env::temp_dir().join("comp-gui-no-such-image.png");
        let message = import_layer(&mut document, &missing).expect_err("a missing file must fail");
        assert!(message.contains("comp-gui-no-such-image"), "{message}");
    }

    #[test]
    fn the_watch_worker_reports_a_digest_for_a_package_and_nothing_for_an_absent_one() {
        let root = temp_root("watch");
        let package = root.join("Watched.comp");
        let document = comp_core::store::solid_document(8, 8, [4, 5, 6, 255]);
        save_document(&mut document.clone(), &package).unwrap();

        let mut worker = WatchWorker::new();
        worker.watch(Some(package.clone()));
        let deadline = Instant::now() + Duration::from_secs(10);
        let digest = loop {
            if let Some(digest) = worker.poll() {
                break digest;
            }
            assert!(Instant::now() < deadline, "the watcher never reported");
            thread::sleep(Duration::from_millis(20));
        };
        assert!(digest.is_some(), "a package has a digest");

        // The same digest again: nothing about the file changed.
        let again = loop {
            if let Some(digest) = worker.poll() {
                break digest;
            }
            assert!(Instant::now() < deadline, "the watcher stopped reporting");
            thread::sleep(Duration::from_millis(20));
        };
        assert_eq!(again, digest, "an untouched package keeps its digest");

        // A changed package reports a different digest.
        let mut changed = document.clone();
        changed.layers[0].name = "Renamed".to_string();
        save_document(&mut changed, &package).unwrap();
        let changed_digest = loop {
            if let Some(digest) = worker.poll() {
                break digest;
            }
            assert!(Instant::now() < deadline, "the watcher stopped reporting");
            thread::sleep(Duration::from_millis(20));
        };
        assert_ne!(changed_digest, digest, "a rewritten manifest changes the digest");

        worker.watch(Some(root.join("Gone.comp")));
        let missing = loop {
            if let Some(digest) = worker.poll() {
                break digest;
            }
            assert!(Instant::now() < deadline, "the watcher stopped reporting");
            thread::sleep(Duration::from_millis(20));
        };
        assert!(missing.is_none(), "an absent package has no digest");
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn a_recovery_copy_is_written_scanned_read_and_thrown_away() {
        let root = temp_root("recovery");
        let mut document = comp_core::store::solid_document(8, 8, [1, 2, 3, 255]);
        let entry = crate::recovery::RecoveryEntry {
            id: document.id.to_string(),
            original: Some(root.join("Doc.comp")),
            written: std::time::SystemTime::now(),
            bytes: 64,
        };
        write_recovery(&mut document, &root, &entry).expect("the copy is written");

        let found = scan_recovery(&root);
        assert_eq!(found.len(), 1, "the scan finds the copy it was given");
        assert_eq!(found[0].id, entry.id);
        assert_eq!(found[0].original, entry.original, "the note remembers where it came from");

        let read = read_recovery(&root, &entry.id).expect("the copy reads back");
        assert_eq!((read.width, read.height), (document.width, document.height));
        assert_eq!(read.layers.len(), document.layers.len());

        assert_eq!(discard_recovery(&root, &[entry.id.clone()]), 1);
        assert!(scan_recovery(&root).is_empty(), "a discarded copy is gone");
        assert!(
            matches!(read_recovery(&root, &entry.id), Err(crate::loaderror::LoadProblem::IllegalPath { .. })),
            "reading a copy that has been discarded reports the path, not a damaged package"
        );
        let _ = std::fs::remove_dir_all(root);
    }

    #[test]
    fn the_io_worker_reports_a_missing_package_as_a_failure() {
        let mut worker = IoWorker::new();
        let missing = std::env::temp_dir().join(format!("comp-gui-absent-{}", uuid::Uuid::new_v4()));
        worker.send(IoRequest::Open(missing));
        assert!(worker.is_busy());
        match wait_for_io(&mut worker) {
            IoResult::Failed { action, problem } => {
                assert_eq!(action, "Open");
                // A package that is not there is classified as a path problem, and the path is in it.
                let detail = problem.detail();
                assert!(detail.contains("comp-gui-absent"), "{detail}");
                assert_eq!(problem.category(), "illegal path", "{problem:?}");
            }
            _ => panic!("a missing package must fail"),
        }
        assert!(!worker.is_busy());
    }

    #[test]
    fn the_io_worker_saves_and_exports_in_order() {
        let root = temp_root("queue");
        let package = root.join("Queued.comp");
        let png = root.join("Queued.png");
        let document = comp_core::store::solid_document(10, 10, [1, 2, 3, 255]);
        let mut worker = IoWorker::new();
        worker.send(IoRequest::Save { document: document.clone(), path: package.clone() });
        worker.send(IoRequest::Export {
            document,
            path: png.clone(),
            preference: crate::backend::Preference::ForceCpu,
        });
        assert!(matches!(wait_for_io(&mut worker), IoResult::Saved { .. }));
        assert!(matches!(wait_for_io(&mut worker), IoResult::Exported { .. }));
        assert!(package.join("manifest.json").is_file());
        assert!(png.is_file());
        assert!(!worker.is_busy());
        let _ = std::fs::remove_dir_all(root);
    }
}
