//! The application object: the editor session, the background workers and the frame loop.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::{Duration, Instant};

use comp_core::bitmap::Bitmap8;
use comp_core::document::Document;
use comp_core::text::TextStyle;
use egui::{Context, Pos2, Rect};
use uuid::Uuid;

use crate::engine;
use crate::session::Editor;
use crate::ui::layers::LayersUi;
use crate::backend::{Backend, Preference};
use crate::filters::{FilterKind, FilterMenu, FilterSettings};
use crate::watch::{WatchEvent, WatchState};
use crate::worker::IoWorker;
use crate::worker::{IoRequest, IoResult, RenderDone, RenderWorker, WatchWorker};

/// How long to wait between two preview renders while a stroke is in flight.
const PREVIEW_INTERVAL: Duration = Duration::from_millis(40);

/// A cached row thumbnail: the texture and the size it should be drawn at.
pub(crate) struct ThumbEntry {
    pub(crate) texture: egui::TextureHandle,
    pub(crate) size: egui::Vec2,
}

/// An open text editing session: the layer, its draft style and the layout size of that draft.
pub(crate) struct TextEditSession {
    pub(crate) layer: Uuid,
    pub(crate) draft: TextStyle,
    /// The size the draft lays out to, so the canvas frame follows the typing without relayout.
    pub(crate) bounds: (u32, u32),
    /// The draft's layout, which is what the canvas hit tests and draws its caret from.
    pub(crate) layout: Option<comp_text::TextLayout>,
    /// Where the caret sits and what is selected, both in character indices.
    pub(crate) caret: crate::textedit::TextCaret,
    /// True while the draft's pixels are behind its metadata.
    pub(crate) uncommitted: bool,
}

/// An editor for a tab slot that is not carrying anything: swapped in and out, never drawn.
fn placeholder_editor() -> crate::session::Editor {
    crate::session::Editor::with_document(comp_core::Document::new(1, 1))
}

/// Everything one open package owns: its document, its history, its view and what is drawn of it.
///
/// The active project's fields live directly on the app, so the rest of the code keeps talking to
/// them without an index; the others wait here until their tab comes forward.
pub(crate) struct Project {
    pub(crate) editor: crate::session::Editor,
    pub(crate) texture: Option<egui::TextureHandle>,
    pub(crate) flattened: Option<std::sync::Arc<comp_core::Bitmap8>>,
    pub(crate) texture_size: Option<(u32, u32)>,
    pub(crate) filter_linear: bool,
    pub(crate) thumbs: std::collections::HashMap<Uuid, (crate::thumbs::ThumbKey, ThumbEntry)>,
    pub(crate) text_edit: Option<TextEditSession>,
    pub(crate) watch_state: crate::watch::WatchState,
    pub(crate) layers_ui: LayersUi,
    pub(crate) uploaded_epoch: u64,
    pub(crate) render_millis: u64,
    pub(crate) requested_epoch: u64,
}

impl Project {
    pub(crate) fn new(editor: crate::session::Editor) -> Self {
        Project {
            editor,
            texture: None,
            flattened: None,
            texture_size: None,
            filter_linear: false,
            thumbs: std::collections::HashMap::new(),
            text_edit: None,
            watch_state: crate::watch::WatchState::default(),
            layers_ui: LayersUi::default(),
            uploaded_epoch: 0,
            render_millis: 0,
            requested_epoch: 0,
        }
    }

    /// The name the tab shows.
    pub(crate) fn title(&self) -> String {
        crate::tabs::tab_title(self.editor.path.as_deref(), &self.editor.file_name())
    }

    pub(crate) fn modified(&self) -> bool {
        self.editor.is_modified()
    }
}

/// The composing text typeset: what the canvas draws and where the candidate window points.
///
/// Every rectangle is in the composing layout's own pixels, the same space comp-text answered in, so
/// the canvas only has to map them the way it maps the text layer itself.
pub(crate) struct PreeditRender {
    /// The whole composing text.
    pub(crate) bounds: comp_core::RectF,
    /// Each clause and how it is drawn.
    pub(crate) clauses: Vec<(comp_text::PreeditStyle, comp_core::RectF)>,
    /// The caret, where the input method says it is rather than at the end of the string.
    pub(crate) caret: comp_core::RectF,
    /// The box the candidate window should point at, and which way it should open.
    pub(crate) anchor: Option<comp_text::CaretAnchor>,
}

/// How the canvas shows the mask while it is being worked on.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum MaskView {
    /// The composite, as usual.
    Off,
    /// The composite with the mask laid over it in red, the way Quick Mask shows it.
    Red,
    /// The mask plane itself, in gray.
    Gray,
}

impl MaskView {
    pub(crate) fn label(self) -> &'static str {
        match self {
            MaskView::Off => "Off",
            MaskView::Red => "Red",
            MaskView::Gray => "Gray",
        }
    }
}

/// What the canvas is currently dragging.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum CanvasDrag {
    /// Space-drag or middle-drag panning.
    Pan,
    /// A tool gesture, owned by the tool state machine.
    Tool,
    /// Pulling a guide out of a ruler, or moving one.
    Guide,
}

/// The key the window's own state is saved under.
const SESSION_KEY: &str = "compositor-session";

/// The extensions an import can read, as the file dialog offers them.
const IMPORT_EXTENSIONS: [&str; 10] = ["png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp", "psd", "psb", "comp"];

/// The extension of a file an import can read, when it has one.
pub(crate) fn import_extension(path: &std::path::Path) -> Option<String> {
    let extension = path.extension()?.to_string_lossy().to_lowercase();
    IMPORT_EXTENSIONS.contains(&extension.as_str()).then_some(extension)
}

/// The whole GUI state.
pub struct GuiApp {
    pub(crate) editor: Editor,
    pub(crate) render: RenderWorker,
    pub(crate) io: IoWorker,
    /// The composite on the GPU, and the pixels it was made from.
    pub(crate) texture: Option<egui::TextureHandle>,
    pub(crate) flattened: Option<Arc<Bitmap8>>,
    /// The size of the composite the texture holds, so a partial upload knows it fits.
    pub(crate) texture_size: Option<(u32, u32)>,
    pub(crate) uploaded_epoch: u64,
    pub(crate) requested_epoch: u64,
    /// True while the texture uses linear filtering, which tracks the zoom level.
    pub(crate) filter_linear: bool,
    pub(crate) render_millis: u64,
    pub(crate) canvas_rect: Option<Rect>,
    pub(crate) drag: Option<CanvasDrag>,
    pub(crate) last_preview: Option<Instant>,
    pub(crate) layers_ui: LayersUi,
    /// The installed fonts, built the first time text is used because the scan is not free.
    pub(crate) fonts: Option<comp_text::FontLibrary>,
    /// The open text editing session, if any.
    pub(crate) text_edit: Option<TextEditSession>,
    /// The face search box in the text panel.
    pub(crate) font_filter: String,
    /// The channel the Levels and Curves panels edit.
    pub(crate) levels_channel: usize,
    /// The curve control point the pointer is dragging, if any.
    pub(crate) curve_drag: Option<usize>,
    /// Row thumbnails, with the key each was built from.
    pub(crate) thumbs: std::collections::HashMap<Uuid, (crate::thumbs::ThumbKey, ThumbEntry)>,
    /// The package watcher and what it has already told the user.
    pub(crate) watch: WatchWorker,
    pub(crate) watch_state: WatchState,
    /// True while the "changed on disk" prompt is up, and whether the package went missing.
    pub(crate) watch_prompt: Option<bool>,
    /// The filter dialog: which filter, and the settings it would run with.
    pub(crate) filter_dialog: Option<(FilterKind, FilterSettings)>,
    /// The system clipboard, opened on first use.
    pub(crate) clipboard: crate::clipboard::SystemClipboard,
    /// Whether whole-canvas renders and exports prefer the GPU.
    pub(crate) backend_preference: Preference,
    /// The backend the last finished render used, for the status bar.
    pub(crate) last_backend: Option<Backend>,
    /// The backend the last export used, reported once it lands.
    pub(crate) export_backend: Option<Backend>,
    /// The layout grid, and what a drag snaps to.
    pub(crate) grid: crate::guides::GridSettings,
    pub(crate) snap: crate::guides::SnapSettings,
    /// Whether the rulers and the guides are drawn, and whether the grid dialog is open.
    pub(crate) show_rulers: bool,
    pub(crate) show_guides: bool,
    pub(crate) show_grid_dialog: bool,
    /// The guide being dragged, if any.
    pub(crate) guide_drag: Option<crate::ui::guides::GuideDrag>,
    /// Every open project, in tab order. The active one's fields are the ones on this struct; its
    /// slot here is a placeholder until it is swapped out.
    pub(crate) tabs: Vec<Project>,
    pub(crate) active_tab: usize,
    /// The tab whose close is waiting for an answer about unsaved edits.
    pub(crate) closing_tab: Option<usize>,
    /// The tab to close once the save it asked for has landed.
    pub(crate) pending_close: Option<usize>,
    /// The colours this session has used, newest first, shared by every tool.
    pub(crate) recent_colors: Vec<crate::color::Color>,
    /// When the last recovery copy was written, and how many there have been.
    pub(crate) autosave: crate::recovery::AutosaveClock,
    /// The document revision the autosave clock last saw, which is how an edit is noticed.
    pub(crate) autosave_epoch: u64,
    /// Where the recovery copies live.
    pub(crate) recovery_root: PathBuf,
    /// Copies an earlier run left behind, waiting to be offered.
    pub(crate) recovery_offers: Vec<crate::recovery::RecoveryEntry>,
    /// True while autosave is on, which the View menu can switch off.
    pub(crate) autosave_enabled: bool,
    /// The last load failure, shown as a dialog with its reason and its advice.
    pub(crate) load_error: Option<(&'static str, crate::loaderror::LoadProblem)>,
    /// Guides cannot be dragged or deleted while this is set.
    pub(crate) guides_locked: bool,
    /// Guides the user has hidden. The format has no room for this, so it is a view setting.
    pub(crate) hidden_guides: std::collections::HashSet<Uuid>,
    /// The curve control point the readout below the editor is showing.
    pub(crate) curve_selected: Option<usize>,
    /// The shape the gradient tool fills a mask with, and whether it runs the other way.
    pub(crate) gradient_shape: crate::maskfill::GradientShape,
    pub(crate) gradient_invert: bool,
    /// The feather radius the mask panel applies.
    pub(crate) feather_radius: f64,
    /// True while the canvas shows the selected layer's mask instead of the composite.
    pub(crate) show_mask: bool,
    /// True while the colour window is open.
    pub(crate) show_color_panel: bool,
    /// The colour button whose popup is open, and where it hangs from.
    pub(crate) open_color: Option<(String, egui::Rect)>,
    /// The colour that popup is editing.
    pub(crate) open_color_value: [u8; 4],
    /// True on the frame after the popup changed its colour.
    pub(crate) open_color_changed: bool,
    /// Packages the last session had open, waiting to be opened one at a time.
    pub(crate) restore_queue: Vec<PathBuf>,
    /// The tab to bring forward once the restore queue has drained.
    pub(crate) restore_active: Option<usize>,
    /// How the canvas shows the selected layer's mask.
    pub(crate) mask_view: MaskView,
    /// The red overlay the mask view draws over the composite, and the document it was built from.
    pub(crate) mask_texture: Option<egui::TextureHandle>,
    pub(crate) overlay_epoch: u64,
    /// How the gradient tool meets the mask that is already there.
    pub(crate) gradient_blend: crate::maskfill::GradientBlend,
    /// The guide the keyboard and the readout are working on.
    pub(crate) selected_guide: Option<Uuid>,
    /// True while a drag with the text tool is extending the selection.
    pub(crate) text_selecting: bool,
    /// What the input method is composing on the canvas, if anything.
    pub(crate) composition: crate::ime::Composition,
    /// The composing text typeset, with where its clauses, caret and candidate anchor sit.
    pub(crate) preedit_render: Option<PreeditRender>,

    /// Which subject extractor this build would use, and the model once it has been loaded.
    ///
    /// The backend is decided from the file alone when the window opens, so the status bar is right
    /// before anything runs; the model itself is loaded the first time an action needs it, because
    /// loading an ONNX graph is not something to do during startup.
    pub(crate) subject_backend: crate::subject::Backend,
    /// The loaded model, shared with the worker thread that runs it.
    pub(crate) subject_model: Option<std::sync::Arc<comp_brush::SubjectModel>>,
    /// Why the model could not be loaded, when it was there and would not load.
    pub(crate) subject_failure: Option<String>,
    /// What the last subject run reported: who answered, and how long it took.
    pub(crate) last_subject: Option<String>,
    /// The model inference running in the background, with what it will change when it lands.
    pub(crate) subject_job: Option<comp_brush::subject_model::SubjectJob>,
    pub(crate) subject_job_target: Option<(Uuid, bool)>,
    pub(crate) subject_job_started: Option<std::time::Instant>,

    /// The open Camera Raw filter window, if any.
    pub(crate) raw: Option<crate::raw::RawEdit>,
    pub(crate) show_new_dialog: bool,
    pub(crate) new_size: (u32, u32),
    pub(crate) show_about: bool,
    pub(crate) working_dir: Option<PathBuf>,
    pub(crate) window_title: String,
    /// Frames drawn so far, used by the smoke-test exit.
    frames: u64,
    /// When the window opened, so the smoke line can report an average frame.
    opened_at: std::time::Instant,
}

impl GuiApp {
    pub fn new(cc: &eframe::CreationContext<'_>, initial: Option<PathBuf>) -> Self {
        cc.egui_ctx.set_visuals(egui::Visuals::dark());
        // What the last run left behind: the tabs it had open and the switches it was set to.
        let saved = cc
            .storage
            .and_then(|storage| eframe::get_value::<crate::session_state::SessionState>(storage, SESSION_KEY))
            .unwrap_or_else(crate::session_state::SessionState::first_run);
        let plan = crate::session_state::plan_restore(&saved);
        let mut editor = Editor::default();
        if let Some(path) = &initial {
            match editor.load(path) {
                Ok(()) => editor.set_message(format!("Opened {}", path.display())),
                Err(message) => editor.set_error(message),
            }
        }
        let mut app = GuiApp {
            editor,
            render: RenderWorker::new(),
            io: IoWorker::new(),
            texture: None,
            flattened: None,
            texture_size: None,
            uploaded_epoch: 0,
            requested_epoch: 0,
            filter_linear: false,
            render_millis: 0,
            canvas_rect: None,
            drag: None,
            last_preview: None,
            layers_ui: LayersUi::default(),
            fonts: None,
            text_edit: None,
            font_filter: String::new(),
            levels_channel: 0,
            curve_drag: None,
            thumbs: std::collections::HashMap::new(),
            watch: WatchWorker::new(),
            watch_state: WatchState::default(),
            watch_prompt: None,
            filter_dialog: None,
            clipboard: crate::clipboard::SystemClipboard::new(),
            backend_preference: if saved.prefer_gpu { Preference::PreferGpu } else { Preference::ForceCpu },
            last_backend: None,
            // The file is looked for now; the graph is loaded on the first run.
            subject_backend: crate::subject::classify(
                comp_brush::SubjectModel::locate().map(|path| (path, String::new())),
            ),
            subject_model: None,
            subject_failure: None,
            last_subject: None,
            subject_job: None,
            subject_job_target: None,
            subject_job_started: None,
            export_backend: None,
            grid: crate::guides::GridSettings {
                visible: saved.grid_visible,
                spacing: saved.grid_spacing,
                subdivisions: saved.grid_subdivisions,
            }
            .normalized(),
            snap: crate::guides::SnapSettings {
                enabled: saved.snap_enabled,
                guides: saved.snap_guides,
                grid: saved.snap_grid,
                document: saved.snap_document,
                layers: saved.snap_layers,
            },
            show_rulers: saved.show_rulers,
            show_guides: saved.show_guides,
            show_grid_dialog: false,
            guide_drag: None,
            tabs: vec![Project::new(placeholder_editor())],
            active_tab: 0,
            closing_tab: None,
            pending_close: None,
            recent_colors: Vec::new(),
            autosave: crate::recovery::AutosaveClock::default(),
            autosave_epoch: 0,
            recovery_root: crate::worker::recovery_root(),
            recovery_offers: Vec::new(),
            autosave_enabled: true,
            load_error: None,
            guides_locked: false,
            hidden_guides: std::collections::HashSet::new(),
            curve_selected: None,
            gradient_shape: crate::maskfill::GradientShape::Linear,
            gradient_invert: false,
            feather_radius: 12.0,
            show_mask: false,
            show_color_panel: false,
            open_color: None,
            open_color_value: [255, 255, 255, 255],
            open_color_changed: false,
            restore_queue: Vec::new(),
            restore_active: None,
            mask_view: if saved.mask_red_overlay { MaskView::Red } else { MaskView::Off },
            mask_texture: None,
            overlay_epoch: 0,
            gradient_blend: crate::maskfill::GradientBlend::Replace,
            selected_guide: None,
            text_selecting: false,
            composition: crate::ime::Composition::new(),
            preedit_render: None,
            raw: None,
            show_new_dialog: false,
            new_size: (1920, 1080),
            show_about: false,
            working_dir: initial.as_ref().and_then(|path| path.parent().map(PathBuf::from)),
            window_title: String::new(),
            frames: 0,
            opened_at: std::time::Instant::now(),
        };
        // A path on the command line wins: the window opens exactly what was asked for, which also
        // keeps the smoke test's run independent of what the last session left open.
        if initial.is_none() {
            app.scan_recovery();
        if let Some(message) = crate::session_state::restore_message(&plan) {
                app.editor.set_message(message);
            }
            if !plan.open.is_empty() {
                app.restore_queue = plan.open;
                app.restore_active = Some(plan.active);
            }
        }
        app.request_render(true);
        app
    }

    /// Writes a recovery copy when the clock says one is due.
    ///
    /// The decision is a pure function of the clock and a few flags; the write itself goes to the IO
    /// worker, so a large document never stalls a frame.
    fn autosave_tick(&mut self) {
        let now = std::time::Instant::now();
        // A revision the clock has not seen is an edit, and the idle condition counts from the last of
        // them: a copy is written at the first pause rather than in the middle of a burst of strokes.
        if self.editor.epoch != self.autosave_epoch {
            self.autosave_epoch = self.editor.epoch;
            self.autosave.edited(now);
        }
        let modified = self.editor.is_modified();
        let has_content = !self.editor.document.layers.is_empty();
        let busy = self.io.is_busy();
        let decision = self
            .autosave
            .decide(now, modified, has_content, busy, self.autosave_enabled);
        if decision != crate::recovery::Autosave::Write {
            return;
        }
        let entry = crate::recovery::RecoveryEntry {
            id: self.editor.document.id.to_string(),
            original: self.editor.path.clone(),
            written: std::time::SystemTime::now(),
            bytes: self.editor.memory_estimate().document_bytes as u64,
        };
        self.autosave.wrote(now);
        self.io.send(IoRequest::Autosave {
            document: self.editor.document.clone(),
            root: self.recovery_root.clone(),
            entry,
        });
    }

    /// Looks for copies an earlier run left behind. Called once when the window opens.
    pub(crate) fn scan_recovery(&mut self) {
        self.io.send(IoRequest::ScanRecovery { root: self.recovery_root.clone() });
    }

    /// Throws away the recovery copy of the document that is open, because it has just been saved or
    /// the editor is closing with nothing left to lose.
    pub(crate) fn clean_recovery(&mut self, id: &str) {
        let _ = crate::worker::discard_recovery(&self.recovery_root, &[id.to_string()]);
    }

    /// The conflict between a copy and the file it came from, if that file is still there.
    pub(crate) fn entry_conflict(&self, entry: &crate::recovery::RecoveryEntry) -> crate::recovery::Conflict {
        let original = entry
            .original
            .as_deref()
            .and_then(|path| std::fs::metadata(path).ok())
            .and_then(|metadata| metadata.modified().ok());
        crate::recovery::conflict(original, entry.written)
    }

    /// The record the window saves between runs.
    pub(crate) fn session_state(&self) -> crate::session_state::SessionState {
        crate::session_state::SessionState {
            tabs: (0..self.tabs.len()).map(|index| crate::session_state::remember(self.project_path(index).as_deref())).collect(),
            active: self.active_tab,
            prefer_gpu: self.backend_preference == Preference::PreferGpu,
            show_rulers: self.show_rulers,
            show_guides: self.show_guides,
            grid_visible: self.grid.visible,
            grid_spacing: self.grid.spacing,
            grid_subdivisions: self.grid.subdivisions,
            snap_enabled: self.snap.enabled,
            snap_guides: self.snap.guides,
            snap_grid: self.snap.grid,
            snap_document: self.snap.document,
            snap_layers: self.snap.layers,
            mask_red_overlay: self.mask_view != MaskView::Off,
        }
    }

    /// Opens the packages the last session had open, one at a time, and brings the saved tab back.
    fn restore_session(&mut self) {
        if !self.restore_queue.is_empty() {
            if !self.io.is_busy() {
                let path = self.restore_queue.remove(0);
                self.open_path(path);
            }
            return;
        }
        if let Some(index) = self.restore_active.take() {
            if self.io.is_busy() {
                // The last package is still loading; the saved tab comes forward once it lands.
                self.restore_active = Some(index);
                return;
            }
            if self.tabs.len() > 1 {
                self.switch_tab(index.min(self.tabs.len() - 1));
            }
        }
    }

    /// Drains the workers, keeps the texture in step and schedules repaints while work is running.
    fn pump(&mut self, ctx: &Context) {
        while let Some(result) = self.io.poll() {
            self.apply_io_result(result);
        }
        self.restore_session();
        self.autosave_tick();
        self.poll_subject_job(ctx);
        while let Some(done) = self.render.poll() {
            self.upload(ctx, done);
        }
        while let Some(current) = self.watch.poll() {
            match self.watch_state.observe(current) {
                WatchEvent::Changed => {
                    self.watch_prompt = Some(false);
                    self.editor.set_message("The project changed on disk");
                }
                WatchEvent::Unreadable => {
                    self.watch_prompt = Some(true);
                    self.editor.set_error("The project on disk cannot be read any more");
                }
                WatchEvent::Quiet => {}
            }
        }
        if self.watch_state.is_watching() || self.watch_state.pending() {
            ctx.request_repaint_after(Duration::from_millis(500));
        }
        self.sync_filtering(ctx);
        match self.mask_view {
            // The mask plane takes the canvas over entirely.
            MaskView::Gray => {
                self.upload_mask_preview(ctx);
                return;
            }
            // The red overlay is drawn on top of the composite, which keeps rendering as usual.
            MaskView::Red => self.refresh_mask_overlay(ctx),
            MaskView::Off => {
                if self.mask_texture.take().is_some() {
                    ctx.request_repaint();
                }
            }
        }
        // A stroke keeps the picture current with region repaints, so only the edits that change
        // more than pixels ask for the whole canvas here.
        if self.editor.epoch != self.requested_epoch && !self.editor.is_stroking() {
            self.request_render(true);
        }
        if self.io.is_busy() || self.render.is_busy() {
            ctx.request_repaint_after(Duration::from_millis(30));
        }
    }

    fn apply_io_result(&mut self, result: IoResult) {
        match result {
            IoResult::Opened { path, document, digest } => {
                self.editor.adopt(document, digest.clone(), &path);
                self.working_dir = path.parent().map(PathBuf::from);
                self.flattened = None;
                self.editor.set_message(format!("Opened {}", path.display()));
                self.watch_package(path, digest);
                self.request_render(true);
            }
            IoResult::Saved { path } => {
                self.editor.path = Some(path.clone());
                // The document is on disk now, so its recovery copy can go and the clock starts over.
                let id = self.editor.document.id.to_string();
                self.clean_recovery(&id);
                self.autosave.saved();
                // A close that waited for this save can go through now.
                if let Some(index) = self.pending_close.take() {
                    if index == self.active_tab {
                        self.close_tab(index);
                    }
                }
                let digest = comp_core::digest::package_digest(&path).ok();
                self.editor.digest = digest.clone();
                self.editor.history.mark_saved();
                self.editor.set_message(format!("Saved {}", path.display()));
                // Saving makes the file ours again, so the watcher starts from the new digest.
                self.watch_package(path, digest);
            }
            IoResult::Exported { path, width, height, backend } => {
                self.export_backend = Some(backend);
                // The export says which compositor produced it, so a GPU/CPU difference is visible.
                self.editor.set_message(format!(
                    "Exported {width} x {height} to {} ({})",
                    path.display(),
                    backend.label()
                ));
            }
            IoResult::ImportedLayer { path, document, layer } => {
                let name = document.layer(layer).map(|layer| layer.name.clone()).unwrap_or_default();
                if self.editor.replace_document(document, "Import Layer") {
                    self.editor.select_layer(layer);
                    self.editor.set_message(format!("Imported {name} from {}", path.display()));
                    self.request_render(true);
                }
            }
            IoResult::ImportedDocument { path, document } => {
                self.editor.adopt_imported(document);
                self.stop_watching();
                self.flattened = None;
                self.texture_size = None;
                self.working_dir = path.parent().map(PathBuf::from);
                self.editor.set_message(format!("Imported {} as a new document", path.display()));
                self.request_render(true);
            }
            IoResult::Failed { action, problem } => {
                // The status bar gets the one-line reason and the dialog gets the reason and the
                // advice; both come from the classification rather than from one flat sentence.
                self.editor.set_error(format!("{action} failed - {}", problem.summary()));
                self.load_error = Some((action, problem));
            }
            IoResult::Autosaved { id } => {
                self.editor.set_message(format!("Recovery copy written ({id})"));
            }
            IoResult::RecoveryFound { entries } => {
                let (offers, stale) = crate::recovery::split_entries(&entries, std::time::SystemTime::now());
                if !stale.is_empty() {
                    let ids: Vec<String> = stale.iter().map(|entry| entry.id.clone()).collect();
                    self.io.send(IoRequest::DiscardRecovery { root: self.recovery_root.clone(), ids });
                }
                if !offers.is_empty() {
                    self.editor.set_message(format!(
                        "{} unsaved document(s) from the last run can be recovered",
                        offers.len()
                    ));
                }
                self.recovery_offers = offers;
            }
            IoResult::Recovered { id, entry, document } => {
                // A recovered document becomes a tab of its own: it has no save of its own yet, so it
                // stays unsaved, and the path it came from is remembered without being written to.
                let mut editor = crate::session::Editor::with_document(document);
                editor.path = entry.original.clone();
                editor.set_message(format!("Recovered {} (unsaved)", crate::recovery::entry_label(&entry)));
                self.add_tab(editor);
                // The history is the only place that knows a document has unsaved changes, and a
                // recovered one starts out looking saved. Recording its own state as a step marks it
                // unsaved without touching the document; undoing that step is harmless.
                let unchanged = self.editor.document.clone();
                self.editor.history.record(unchanged, "Recovered");
                self.recovery_offers.retain(|offer| offer.id != id);
                self.request_render(true);
            }
            IoResult::RecoveryCleaned { .. } => {}
        }
    }

    /// The prompt about copies an earlier run left behind.
    pub(crate) fn recovery_window(&mut self, ctx: &Context) {
        if self.recovery_offers.is_empty() {
            return;
        }
        let offers = self.recovery_offers.clone();
        let mut recover: Option<String> = None;
        let mut discard: Vec<String> = Vec::new();
        egui::Window::new("Unsaved work from the last run")
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label("These documents had unsaved changes when the editor last ran.");
                for entry in &offers {
                    let conflict = self.entry_conflict(entry);
                    ui.separator();
                    ui.horizontal(|ui| {
                        ui.label(egui::RichText::new(crate::recovery::entry_label(entry)).strong());
                        ui.label(egui::RichText::new(crate::recovery::entry_note(conflict)).weak().small());
                    });
                    if let Some(original) = &entry.original {
                        ui.label(egui::RichText::new(original.display().to_string()).weak().small());
                    }
                    ui.horizontal(|ui| {
                        if ui
                            .button("Recover as a new tab")
                            .on_hover_text("The copy opens unsaved, with the original path remembered")
                            .clicked()
                        {
                            recover = Some(entry.id.clone());
                        }
                        if ui.button("Discard").clicked() {
                            discard.push(entry.id.clone());
                        }
                    });
                }
                ui.separator();
                if ui.button("Discard all").clicked() {
                    discard = offers.iter().map(|entry| entry.id.clone()).collect();
                }
            });
        if let Some(id) = recover {
            if let Some(entry) = self.recovery_offers.iter().find(|entry| entry.id == id).cloned() {
                self.io.send(IoRequest::RecoverDocument { root: self.recovery_root.clone(), id, entry });
            }
        }
        if !discard.is_empty() {
            self.recovery_offers.retain(|entry| !discard.contains(&entry.id));
            self.io.send(IoRequest::DiscardRecovery { root: self.recovery_root.clone(), ids: discard });
        }
    }

    /// The dialog a failed load raises: what went wrong, and what to do about it.
    pub(crate) fn load_error_window(&mut self, ctx: &Context) {
        let Some((action, problem)) = self.load_error.clone() else { return };
        let mut close = false;
        egui::Window::new(format!("{action} failed"))
            .collapsible(false)
            .resizable(false)
            .show(ctx, |ui| {
                ui.label(egui::RichText::new(problem.category()).strong());
                ui.label(problem.detail());
                ui.separator();
                ui.label(egui::RichText::new(problem.hint()).weak());
                if ui.button("Close").clicked() {
                    close = true;
                }
            });
        if close {
            self.load_error = None;
        }
    }

    /// Uploads a finished composite. Filtering follows the zoom: crisp pixels when magnified,
    /// smooth ones when reduced.
    ///
    /// A full pass replaces the texture and the CPU mirror; a region pass patches both, which is
    /// what keeps a stroke from recompositing the canvas on every pointer sample.
    /// Draws the selected layer's mask as the canvas: white keeps the layer, black hides it.
    ///
    /// The plane is uploaded straight to the texture rather than through the render worker, because
    /// what is being previewed is not the composite at all.
    fn upload_mask_preview(&mut self, ctx: &Context) {
        if self.editor.epoch == self.requested_epoch && self.texture.is_some() {
            return;
        }
        let Some(entry) = self
            .editor
            .document
            .active_layer
            .and_then(|id| self.editor.document.layer(id))
        else {
            return;
        };
        let Some(mask) = entry.mask.as_deref() else {
            self.editor.set_error("The selected layer has no mask to show");
            self.show_mask = false;
            return;
        };
        let (width, height) = (mask.width() as usize, mask.height() as usize);
        if width == 0 || height == 0 {
            return;
        }
        let mut pixels = Vec::with_capacity(width * height * 4);
        for value in mask.pixels() {
            pixels.extend_from_slice(&[*value, *value, *value, 255]);
        }
        let image = egui::ColorImage::from_rgba_unmultiplied([width, height], &pixels);
        let options = if self.filter_linear { egui::TextureOptions::LINEAR } else { egui::TextureOptions::NEAREST };
        match &mut self.texture {
            Some(texture) => texture.set(image, options),
            None => self.texture = Some(ctx.load_texture("mask", image, options)),
        }
        self.flattened = None;
        self.texture_size = Some((width as u32, height as u32));
        self.requested_epoch = self.editor.epoch;
        self.uploaded_epoch = self.editor.epoch;
        // The overlay belongs to the previous document once the mask takes the canvas over.
        self.mask_texture = None;
    }

    /// Keeps the red Quick-Mask overlay in step with the mask.
    fn refresh_mask_overlay(&mut self, ctx: &Context) {
        if self.editor.epoch == self.overlay_epoch && self.mask_texture.is_some() {
            return;
        }
        let Some(entry) = self.editor.document.active_layer.and_then(|id| self.editor.document.layer(id)) else {
            self.mask_texture = None;
            return;
        };
        let Some(mask) = entry.mask.as_deref() else {
            self.mask_texture = None;
            return;
        };
        let (width, height) = (mask.width() as usize, mask.height() as usize);
        if width == 0 || height == 0 {
            return;
        }
        // Quick Mask paints what is hidden: red where the mask keeps nothing, nothing where it keeps.
        let mut pixels = Vec::with_capacity(width * height * 4);
        for value in mask.pixels() {
            let hidden = 255 - *value;
            pixels.extend_from_slice(&[230, 40, 40, (hidden as u32 * 160 / 255) as u8]);
        }
        let image = egui::ColorImage::from_rgba_unmultiplied([width, height], &pixels);
        match &mut self.mask_texture {
            Some(texture) => texture.set(image, egui::TextureOptions::NEAREST),
            None => self.mask_texture = Some(ctx.load_texture("mask-overlay", image, egui::TextureOptions::NEAREST)),
        }
        self.overlay_epoch = self.editor.epoch;
    }

    fn upload(&mut self, ctx: &Context, done: RenderDone) {
        let width = done.bitmap.width() as usize;
        let height = done.bitmap.height() as usize;
        if width == 0 || height == 0 {
            return;
        }
        let linear = self.want_linear();
        let options = if linear { egui::TextureOptions::LINEAR } else { egui::TextureOptions::NEAREST };
        let image = egui::ColorImage::from_rgba_unmultiplied([width, height], done.bitmap.pixels());
        let canvas = self.editor.document_size();
        let is_full = done.origin == (0, 0)
            && done.bitmap.width() == canvas.0
            && done.bitmap.height() == canvas.1;
        if is_full {
            match &mut self.texture {
                Some(texture) => texture.set(image, options),
                None => self.texture = Some(ctx.load_texture("composite", image, options)),
            }
            self.texture_size = Some(canvas);
            self.flattened = Some(Arc::new(done.bitmap));
        } else {
            let patched = match (&mut self.flattened, &mut self.texture) {
                (Some(mirror), Some(texture)) if self.texture_size == Some(canvas) => {
                    Arc::make_mut(mirror).blit_region(
                        &done.bitmap,
                        0,
                        0,
                        done.bitmap.width(),
                        done.bitmap.height(),
                        done.origin.0,
                        done.origin.1,
                    );
                    texture.set_partial([done.origin.0.max(0) as usize, done.origin.1.max(0) as usize], image, options);
                    true
                }
                // A region without a canvas-sized texture behind it cannot be patched, so the
                // canvas is asked for in full instead of showing a half-updated picture.
                _ => false,
            };
            if !patched {
                self.request_render(true);
                return;
            }
        }
        self.filter_linear = linear;
        self.render_millis = done.millis;
        self.uploaded_epoch = done.epoch;
        self.last_backend = Some(done.backend);
    }

    /// Re-uploads the cached pixels when the zoom crossed the filtering threshold, which avoids a
    /// full composite just to change how the texture is sampled.
    fn sync_filtering(&mut self, ctx: &Context) {
        let linear = self.want_linear();
        if linear == self.filter_linear {
            return;
        }
        let Some(bitmap) = self.flattened.clone() else { return };
        let (width, height) = (bitmap.width() as usize, bitmap.height() as usize);
        if width == 0 || height == 0 {
            return;
        }
        let image = egui::ColorImage::from_rgba_unmultiplied([width, height], bitmap.pixels());
        let options = if linear { egui::TextureOptions::LINEAR } else { egui::TextureOptions::NEAREST };
        match &mut self.texture {
            Some(texture) => texture.set(image, options),
            None => self.texture = Some(ctx.load_texture("composite", image, options)),
        }
        self.filter_linear = linear;
    }

    fn want_linear(&self) -> bool {
        self.editor.view.zoom < 1.0
    }

    /// Queues a full composite. Preview requests are throttled; a forced request always goes out,
    /// which is what makes the picture exact again when a stroke ends.
    pub(crate) fn request_render(&mut self, force: bool) {
        if !force && !self.preview_due() {
            return;
        }
        self.requested_epoch = self.render.request(&self.editor.document, self.backend_preference);
    }

    /// Queues a repaint of one dirty rectangle, throttled like any other preview.
    pub(crate) fn request_region(&mut self, bounds: engine::Bounds) {
        if !self.preview_due() {
            return;
        }
        self.requested_epoch = self.render.request_region(&self.editor.document, bounds);
    }

    /// True when a preview may be queued now: at most one every preview interval, and only while an
    /// older one is still running.
    fn preview_due(&mut self) -> bool {
        let now = Instant::now();
        if let Some(last) = self.last_preview {
            if now.duration_since(last) < PREVIEW_INTERVAL && self.render.is_busy() {
                return false;
            }
        }
        self.last_preview = Some(now);
        true
    }

    fn sync_title(&mut self, ctx: &Context) {
        let title = self.editor.title();
        if title != self.window_title {
            self.window_title = title.clone();
            ctx.send_viewport_cmd(egui::ViewportCommand::Title(title));
        }
    }

    fn handle_dropped_files(&mut self, ctx: &Context) {
        let dropped: Vec<PathBuf> = ctx.input(|input| {
            input
                .raw
                .dropped_files
                .iter()
                .map(|file| file.path().to_path_buf())
                .collect()
        });
        // A dropped package opens; a dropped image or Photoshop file becomes a document, which is
        // what dragging a file onto an editor means.
        for path in dropped {
            if path.is_dir() && path.join(comp_core::store::MANIFEST_NAME).is_file() {
                self.open_path(path);
            } else if import_extension(&path).is_some() {
                self.import_document_path(path);
            } else {
                self.editor
                    .set_error(format!("{} is neither a .comp package nor an image", path.display()));
            }
        }
    }

    // ---------------------------------------------------------------- commands

    pub(crate) fn zoom_by(&mut self, factor: f32) {
        let anchor = self.canvas_rect.map(|rect| rect.center()).unwrap_or(Pos2::ZERO);
        self.editor.view.zoom_at(factor, anchor);
    }

    pub(crate) fn fit_to_window(&mut self) {
        if let Some(rect) = self.canvas_rect {
            let (width, height) = self.editor.document_size();
            self.editor.view.fit(rect, width as f32, height as f32);
        }
    }

    pub(crate) fn actual_pixels(&mut self) {
        if let Some(rect) = self.canvas_rect {
            let (width, height) = self.editor.document_size();
            self.editor.view.actual_size(rect, width as f32, height as f32);
        }
    }

    pub(crate) fn new_document(&mut self, width: u32, height: u32) {
        self.editor = Editor::with_document(Document::with_background(width, height));
        self.layers_ui = LayersUi::default();
        self.flattened = None;
        self.stop_watching();
        self.editor.set_message(format!("New {width} x {height} document"));
        self.request_render(true);
    }

    // ------------------------------------------------------------- thumbnails

    /// Rebuilds the row thumbnails that are out of date, at most a couple per frame.
    ///
    /// Nothing is rebuilt mid-stroke: the revision changes on every pointer sample, and a thumbnail
    /// is not worth a full-size resample per frame.
    pub(crate) fn refresh_thumbnails(&mut self, ctx: &Context) {
        let document = &self.editor.document;
        let live: Vec<Uuid> = document.layers.iter().map(|layer| layer.id).collect();
        self.thumbs.retain(|id, _| live.contains(id));
        if self.editor.is_stroking() {
            return;
        }
        let cached: std::collections::HashMap<Uuid, crate::thumbs::ThumbKey> =
            self.thumbs.iter().map(|(id, (key, _))| (*id, *key)).collect();
        let stale = crate::thumbs::stale_layers(
            &document.layers,
            self.editor.epoch,
            &cached,
            crate::thumbs::PER_FRAME,
        );
        for id in stale {
            let Some(layer) = self.editor.document.layer(id) else { continue };
            let Some(picture) = crate::thumbs::thumbnail_for(layer) else { continue };
            let key = crate::thumbs::thumb_key(layer, self.editor.epoch);
            let size = egui::Vec2::new(picture.width() as f32, picture.height() as f32);
            let image = egui::ColorImage::from_rgba_unmultiplied(
                [picture.width() as usize, picture.height() as usize],
                picture.pixels(),
            );
            let texture = ctx.load_texture(format!("thumb-{id}"), image, egui::TextureOptions::NEAREST);
            self.thumbs.insert(id, (key, ThumbEntry { texture, size }));
        }
    }

    // -------------------------------------------------------------------- tabs

    /// The name a tab shows, whichever one it is.
    pub(crate) fn project_title(&self, index: usize) -> String {
        if index == self.active_tab {
            crate::tabs::tab_title(self.editor.path.as_deref(), &self.editor.file_name())
        } else {
            self.tabs.get(index).map(Project::title).unwrap_or_default()
        }
    }

    /// True when that tab has unsaved edits.
    pub(crate) fn project_modified(&self, index: usize) -> bool {
        if index == self.active_tab {
            self.editor.is_modified()
        } else {
            self.tabs.get(index).map(Project::modified).unwrap_or(false)
        }
    }

    /// The package a tab is showing, when it has one.
    pub(crate) fn project_path(&self, index: usize) -> Option<std::path::PathBuf> {
        if index == self.active_tab {
            self.editor.path.clone()
        } else {
            self.tabs.get(index).and_then(|project| project.editor.path.clone())
        }
    }

    /// Takes the active project's state off the app, leaving a placeholder in its place.
    fn take_active_project(&mut self) -> Project {
        Project {
            editor: std::mem::replace(&mut self.editor, placeholder_editor()),
            texture: self.texture.take(),
            flattened: self.flattened.take(),
            texture_size: self.texture_size.take(),
            filter_linear: self.filter_linear,
            thumbs: std::mem::take(&mut self.thumbs),
            text_edit: self.text_edit.take(),
            watch_state: std::mem::replace(&mut self.watch_state, crate::watch::WatchState::default()),
            layers_ui: std::mem::take(&mut self.layers_ui),
            uploaded_epoch: self.uploaded_epoch,
            render_millis: self.render_millis,
            requested_epoch: self.requested_epoch,
        }
    }

    /// Puts a project's state on the app as the active one.
    fn put_active_project(&mut self, project: Project) {
        self.editor = project.editor;
        self.texture = project.texture;
        self.flattened = project.flattened;
        self.texture_size = project.texture_size;
        self.filter_linear = project.filter_linear;
        self.thumbs = project.thumbs;
        self.text_edit = project.text_edit;
        self.watch_state = project.watch_state;
        self.layers_ui = project.layers_ui;
        self.uploaded_epoch = project.uploaded_epoch;
        self.render_millis = project.render_millis;
        self.requested_epoch = project.requested_epoch;
    }

    /// Drops what belonged to the tab that was in front: an open text session, a half-dragged
    /// guide, a dialog about the old document.
    fn reset_tab_state(&mut self) {
        self.raw = None;
        self.filter_dialog = None;
        self.text_selecting = false;
        self.drag = None;
        self.guide_drag = None;
        self.closing_tab = None;
        // A composition belongs to the text session that was open, not to the tab coming forward.
        self.preedit_render = None;
        self.texture = None;
        self.flattened = None;
        self.texture_size = None;
        let path = self.editor.path.clone();
        self.watch.watch(path.clone());
        if let Some(path) = path {
            self.watch_state.watch(path, self.editor.digest.clone());
        } else {
            self.watch_state.forget();
        }
    }

    /// Brings a tab forward, swapping the project in with everything it owns.
    pub(crate) fn switch_tab(&mut self, index: usize) {
        if index >= self.tabs.len() || index == self.active_tab {
            return;
        }
        let current = self.take_active_project();
        let next = std::mem::replace(&mut self.tabs[self.active_tab], current);
        self.active_tab = index;
        self.put_active_project(next);
        self.reset_tab_state();
        self.request_render(true);
    }

    /// Opens a document of its own in a new tab and makes it the one in front.
    pub(crate) fn add_tab(&mut self, editor: crate::session::Editor) {
        let current = self.take_active_project();
        self.tabs[self.active_tab] = current;
        self.tabs.push(Project::new(placeholder_editor()));
        self.active_tab = self.tabs.len() - 1;
        self.put_active_project(Project::new(editor));
        self.reset_tab_state();
        self.request_render(true);
    }

    /// Closes a tab, asking first when it has unsaved edits.
    pub(crate) fn close_tab(&mut self, index: usize) {
        if index >= self.tabs.len() {
            return;
        }
        if self.project_modified(index) && self.closing_tab != Some(index) {
            self.closing_tab = Some(index);
            return;
        }
        self.closing_tab = None;
        if self.tabs.len() <= 1 {
            // The last tab closes into a new empty document, so the window is never tab-less.
            let document = comp_core::Document::with_background(1024, 768);
            self.add_tab(crate::session::Editor::with_document(document));
            return;
        }
        let remaining = self.tabs.len() - 1;
        if index == self.active_tab {
            // The active tab's state is on the app; drop it and move the neighbour in.
            let _discarded = self.take_active_project();
            self.tabs.remove(index);
            let next = crate::tabs::active_after_close(index, index, remaining).unwrap_or(0);
            let placeholder = std::mem::replace(&mut self.tabs[next], Project::new(placeholder_editor()));
            self.active_tab = next;
            self.put_active_project(placeholder);
        } else {
            self.tabs.remove(index);
            if index < self.active_tab {
                self.active_tab -= 1;
            }
        }
        self.reset_tab_state();
        self.request_render(true);
    }

    /// True when the first tab is still the blank document the window started with.
    fn only_a_blank_tab(&self) -> bool {
        self.tabs.len() == 1
            && self.editor.path.is_none()
            && !self.editor.is_modified()
            && self.editor.document.layers.len() <= 1
    }

    // ------------------------------------------------------------------ guides

    /// Adjusts a move so the layer's edges land on a guide, the grid, the canvas or another layer.
    ///
    /// Each axis is snapped on its own: the near edge, the centre and the far edge are all offered,
    /// and whichever is closest to a target wins, exactly as a guide drag behaves.
    pub(crate) fn snapped_move(&self, layer: uuid::Uuid, delta: egui::Vec2) -> egui::Vec2 {
        if !self.snap.enabled {
            return delta;
        }
        let Some(entry) = self.editor.document.layer(layer) else { return delta };
        let tolerance = crate::guides::snap_distance(self.editor.view.zoom as f64);
        let (width, height) = self.editor.document_size();
        let document = (width as f64, height as f64);
        let bounds = entry.transform.document_bounds();
        let moved = comp_core::RectF::new(
            bounds.x + delta.x as f64,
            bounds.y + delta.y as f64,
            bounds.width,
            bounds.height,
        );
        let other_edges = self.other_layer_edges(layer);
        let snap_axis = |axis: comp_core::geom::GuideAxis, near: f64, middle: f64, far: f64, edges: &[f64]| {
            let targets = crate::guides::targets(axis, document, self.editor.guides(), &self.grid, &self.snap, edges);
            // The smallest correction any of the three edges needs is the one that moves the layer.
            let mut best: Option<f64> = None;
            for edge in [near, middle, far] {
                let snapped = crate::guides::snap(edge, &targets, tolerance);
                let correction = snapped - edge;
                if correction != 0.0 && best.map(|current: f64| correction.abs() < current.abs()).unwrap_or(true) {
                    best = Some(correction);
                }
            }
            best.unwrap_or(0.0)
        };
        let x = snap_axis(
            comp_core::geom::GuideAxis::Vertical,
            moved.x,
            moved.x + moved.width / 2.0,
            moved.max_x(),
            &other_edges.0,
        );
        let y = snap_axis(
            comp_core::geom::GuideAxis::Horizontal,
            moved.y,
            moved.y + moved.height / 2.0,
            moved.max_y(),
            &other_edges.1,
        );
        egui::Vec2::new(delta.x + x as f32, delta.y + y as f32)
    }

    /// The near, middle and far edges of every other layer, per axis, for a move to snap to.
    fn other_layer_edges(&self, skip: uuid::Uuid) -> (Vec<f64>, Vec<f64>) {
        let mut xs = Vec::new();
        let mut ys = Vec::new();
        for layer in &self.editor.document.layers {
            if layer.id == skip || !layer.visible || layer.opacity <= 0.0 {
                continue;
            }
            let bounds = layer.transform.document_bounds();
            if bounds.width <= 0.0 || bounds.height <= 0.0 {
                continue;
            }
            xs.extend([bounds.x.round(), (bounds.x + bounds.width / 2.0).round(), bounds.max_x().round()]);
            ys.extend([bounds.y.round(), (bounds.y + bounds.height / 2.0).round(), bounds.max_y().round()]);
        }
        (xs, ys)
    }

    // ----------------------------------------------------------------- watch

    /// Starts watching a package from the digest the editor just read or wrote.
    pub(crate) fn watch_package(&mut self, path: PathBuf, digest: Option<String>) {
        self.watch.watch(Some(path.clone()));
        self.watch_state.watch(path, digest);
        self.watch_prompt = None;
    }

    /// Stops watching, for a document that has no package behind it.
    pub(crate) fn stop_watching(&mut self) {
        self.watch.watch(None);
        self.watch_state.forget();
        self.watch_prompt = None;
    }

    /// Reloads the package from disk, which discards whatever the editor holds.
    pub(crate) fn reload_from_disk(&mut self) {
        let Some(path) = self.watch_state.path().cloned() else { return };
        self.watch_prompt = None;
        self.editor.set_message(format!("Reloading {}...", path.display()));
        self.io.send(IoRequest::Open(path));
    }

    /// Closes the prompt and keeps the editor's version, telling the user once.
    pub(crate) fn keep_my_edits(&mut self) {
        self.watch_state.resolve_keeping_edits();
        self.watch_prompt = None;
        self.editor.set_message("Kept the editor's version; the file on disk was not read");
    }

    /// Opens the filter menu entry: a dialog for the ones with settings, straight through for the
    /// rest, and a refusal that names what is missing for the ones the engine cannot run yet.
    pub(crate) fn run_filter(&mut self, kind: FilterKind) {
        if kind == FilterKind::CameraRaw {
            self.begin_raw_panel();
            return;
        }
        if kind.has_parameters() {
            self.filter_dialog = Some((kind, FilterSettings::default()));
            return;
        }
        self.apply_filter(kind, FilterSettings::default());
    }

    /// Runs a filter and reports whatever the editor had to say about it.
    pub(crate) fn apply_filter(&mut self, kind: FilterKind, settings: FilterSettings) {
        if let Err(message) = self.editor.apply_filter(kind, settings) {
            self.editor.set_error(message);
        }
    }

    // ---------------------------------------------------------------- filters

    /// Opens the Camera Raw window on the selected layer, as one undo step for the whole session.
    /// The model, loaded once and cached by comp-brush for every later run.
    ///
    /// Nothing here runs during startup: the status bar only needs to know whether the file is there,
    /// which is a path check, while loading the graph takes long enough to be worth deferring.
    fn subject_model(&mut self) -> Option<std::sync::Arc<comp_brush::SubjectModel>> {
        if self.subject_model.is_none() && self.subject_failure.is_none() {
            match comp_brush::SubjectModel::cached_discovered() {
                Some(model) => {
                    let path = comp_brush::SubjectModel::locate().unwrap_or_default();
                    self.subject_backend = crate::subject::classify(Some((path, model.describe())));
                    self.subject_model = Some(model);
                }
                None => {
                    // Either there is no model file, or there is one that will not load. The two are
                    // different failures and the status bar says which.
                    self.subject_failure = comp_brush::SubjectModel::locate().map(|path| {
                        format!("{} could not be loaded as an ONNX model", path.display())
                    });
                    self.subject_backend = crate::subject::classify(None);
                }
            }
        }
        self.subject_model.clone()
    }

    /// Runs a subject extraction: the classical extractor answers at once, the model replaces it.
    ///
    /// The report is the point of this action. The classical extractor is a supported answer, but a
    /// silent fall back must never look like the model ran, so the status bar is told who answered
    /// when, and the whole run is timed from the click.
    pub(crate) fn run_subject(&mut self, keep_as_mask: bool) {
        let Some(id) = self.editor.paintable_layer() else {
            self.editor.set_error("Select a raster layer to take a subject from");
            return;
        };
        let Some(image) = self.editor.document.layer(id).and_then(|layer| layer.image.clone()) else {
            self.editor.set_error("The layer has no pixels to read");
            return;
        };
        let options = comp_brush::SubjectOptions::default();
        let model = self.subject_model();
        // comp-brush's own shape for this: the classical matte now, the model's matte later.
        let comp_brush::subject_model::SubjectPreview { classical, job } =
            comp_brush::subject_model::SubjectPreview::start(&image, &options, model.clone());

        // The classical extractor answers first: it is fast enough to run on the click, so there is
        // something on screen while the model works.
        let started = std::time::Instant::now();
        let coverage = if keep_as_mask {
            self.editor.apply_subject_matte(id, &classical, "Select Subject")
        } else {
            self.editor.apply_background_cut(id, &image, &classical, "Remove Background")
        };
        let classical = match coverage {
            Ok(coverage) => coverage,
            Err(reason) => {
                self.editor.set_error(format!("Subject: {reason}"));
                return;
            }
        };
        let elapsed = started.elapsed();
        let line = crate::subject::outcome_line(&crate::subject::Backend::Classical, elapsed, classical);
        self.last_subject = Some(line.clone());
        self.editor.set_message(line);
        self.request_render(true);

        // Then the model, in the background. With no model the job would answer with the same
        // classical matte again, so it is not started: the classical answer above is the answer.
        let Some(model) = model else { return };
        self.subject_job = Some(job);
        self.subject_job_target = Some((id, keep_as_mask));
        self.subject_job_started = Some(std::time::Instant::now());
        self.last_subject = Some(crate::subject::running_line(&crate::subject::Backend::Model {
            path: comp_brush::SubjectModel::locate().unwrap_or_default(),
            description: model.describe(),
        }));
    }

    /// Takes the model's answer when it lands, and reports who answered and how long it took.
    pub(crate) fn poll_subject_job(&mut self, ctx: &Context) {
        let Some(job) = self.subject_job.as_mut() else { return };
        let Some(result) = job.poll() else {
            // Still working: keep the frames coming and say so.
            ctx.request_repaint_after(Duration::from_millis(50));
            return;
        };
        let elapsed = self.subject_job_started.map(|started| started.elapsed()).unwrap_or_default();
        let target = self.subject_job_target.take();
        self.subject_job = None;
        self.subject_job_started = None;
        let Some((id, keep_as_mask)) = target else { return };
        match result {
            Ok(matte) => {
                let coverage = if keep_as_mask {
                    self.editor.apply_subject_matte(id, &matte, "Select Subject (model)")
                } else {
                    match self.editor.document.layer(id).and_then(|layer| layer.image.clone()) {
                        Some(image) => self.editor.apply_background_cut(id, &image, &matte, "Remove Background (model)"),
                        None => Err("The layer went away while the model worked".to_string()),
                    }
                };
                match coverage {
                    Ok(coverage) => {
                        let line = crate::subject::outcome_line(&self.subject_backend, elapsed, coverage);
                        self.last_subject = Some(line.clone());
                        self.editor.set_message(line);
                        self.request_render(true);
                    }
                    Err(reason) => self.editor.set_error(format!("Subject: {reason}")),
                }
            }
            Err(error) => {
                // The classical result stays: it is already on screen, and it is a supported answer.
                let line = crate::subject::failure_line(&error.to_string());
                self.last_subject = Some(line.clone());
                self.editor.set_error(line);
            }
        }
    }

    pub(crate) fn run_select_subject(&mut self) {
        self.run_subject(true);
    }

    pub(crate) fn run_remove_background(&mut self) {
        self.run_subject(false);
    }

    pub(crate) fn begin_raw_panel(&mut self) {
        let Some(id) = self.editor.document.active_layer else {
            self.editor.set_error("Select a layer to grade");
            return;
        };
        // The source is cloned out before the editor is borrowed again for the undo step.
        let source = self
            .editor
            .document
            .layer(id)
            .and_then(|layer| layer.image.as_deref())
            .cloned();
        let Some(source) = source else {
            self.editor.set_error("The selected layer has no pixels to grade");
            return;
        };
        self.editor.begin_edit("Camera Raw");
        self.raw = Some(crate::raw::RawEdit::begin(id, source));
    }

    /// Replaces the layer's pixels with the current grade of the pixels the panel opened with.
    pub(crate) fn refresh_raw_preview(&mut self) {
        let Some(edit) = self.raw.as_ref() else { return };
        let layer = edit.layer;
        // Every preview starts from the original pixels, so a slider can be walked back and forth.
        let pixels = if edit.is_identity() { edit.source().clone() } else { edit.preview() };
        if self.editor.replace_layer_pixels(layer, pixels) {
            self.request_render(true);
        }
    }

    /// Closes the Camera Raw window; keeping the grade records it, cancelling puts the pixels back.
    pub(crate) fn close_raw_panel(&mut self, keep: bool) {
        let Some(edit) = self.raw.take() else { return };
        if !keep {
            let layer = edit.layer;
            let source = edit.source().clone();
            self.editor.replace_layer_pixels(layer, source);
            self.request_render(true);
        }
        self.editor.finish_edit();
    }

    // -------------------------------------------------------------------- text

    /// Switches tools, closing a text session first so its pixels are never left behind.
    pub(crate) fn choose_tool(&mut self, tool: crate::tools::Tool) {
        if tool != crate::tools::Tool::Text {
            self.end_text_session();
        }
        self.editor.set_tool(tool);
    }

    /// Runs something with the font library, which lives beside the editor because it is expensive
    /// to build, holds no document state and must not be borrowed at the same time as the editor.
    pub(crate) fn with_fonts<R>(
        &mut self,
        edit: impl FnOnce(&mut comp_text::FontLibrary, &mut Editor) -> R,
    ) -> R {
        let mut library = self.fonts.take().unwrap_or_else(comp_text::FontLibrary::new);
        let result = edit(&mut library, &mut self.editor);
        self.fonts = Some(library);
        result
    }

    /// The default style for a new text layer: the paint color and the library's default face.
    pub(crate) fn default_text_style(&mut self) -> TextStyle {
        let color = self.editor.color;
        let font_name = self
            .with_fonts(|library, _| library.default_name().map(|name| name.to_string()))
            .unwrap_or_else(|| "Helvetica".to_string());
        TextStyle {
            content: "Text".to_string(),
            font_name,
            font_size: 48.0,
            red: color[0] as f64 / 255.0,
            green: color[1] as f64 / 255.0,
            blue: color[2] as f64 / 255.0,
            ..TextStyle::default()
        }
    }

    /// Handles a click with the text tool: select the text layer under the pointer, or start a new
    /// one where the click landed.
    pub(crate) fn text_click(&mut self, at: Pos2) {
        if let Some(id) = self.editor.text_layer_at(at) {
            self.begin_text_session(id);
            return;
        }
        let style = self.default_text_style();
        match self.with_fonts(|library, editor| editor.add_text_layer(at, style, library)) {
            Ok(id) => {
                self.begin_text_session(id);
                self.editor.set_message("Text layer created; edit it in the Text panel");
                self.request_render(true);
            }
            Err(message) => self.editor.set_error(message),
        }
    }

    /// Opens a text session on a layer. The whole session is one undo step.
    pub(crate) fn begin_text_session(&mut self, layer: Uuid) {
        let Some(style) = self.editor.text_style(layer) else { return };
        self.editor.select_layer(layer);
        self.editor.begin_edit("Edit Text");
        self.composition.cancel();
        self.preedit_render = None;
        self.text_edit = Some(TextEditSession {
            layer,
            draft: style,
            bounds: (0, 0),
            layout: None,
            caret: crate::textedit::TextCaret::default(),
            uncommitted: false,
        });
        self.refresh_text_bounds();
    }

    // -------------------------------------------------------------- clipboard

    /// Copies the selected layer's pixels to the clipboard.
    pub(crate) fn copy_layer(&mut self) {
        let clipboard = &mut self.clipboard;
        if let Err(message) = self.editor.copy_layer_to_clipboard(clipboard) {
            self.editor.set_error(message);
        }
    }

    /// Copies the composite to the clipboard, which is what Copy Merged means.
    pub(crate) fn copy_merged(&mut self) {
        let clipboard = &mut self.clipboard;
        if let Err(message) = self.editor.copy_merged_to_clipboard(clipboard) {
            self.editor.set_error(message);
        }
    }

    /// Pastes the clipboard's picture as a new layer.
    pub(crate) fn paste(&mut self) {
        let clipboard = &mut self.clipboard;
        match self.editor.paste_from_clipboard(clipboard) {
            Ok(()) => self.request_render(true),
            Err(message) => self.editor.set_error(message),
        }
    }

    /// The point in the open draft's layout that a document position lands on.
    pub(crate) fn canvas_to_layout(&self, at: egui::Pos2) -> Option<comp_core::PointF> {
        let session = self.text_edit.as_ref()?;
        let layer = self.editor.document.layer(session.layer)?;
        let (layout_width, layout_height) = session.bounds;
        crate::textedit::canvas_to_layout(layer, (layout_width, layout_height), comp_core::PointF::new(at.x as f64, at.y as f64))
    }

    /// The character under a canvas position, for a click or a drag with the text tool.
    ///
    /// The hit test answers a layout position, which can be inside a cluster when the pointer is in
    /// the middle of one; the caret is taken to the nearest cluster boundary before it is used.
    pub(crate) fn text_index_at(&self, at: egui::Pos2) -> Option<usize> {
        let session = self.text_edit.as_ref()?;
        let layout = session.layout.as_ref()?;
        let point = self.canvas_to_layout(at)?;
        let index = comp_text::hit_test(layout, point)?;
        let offset = comp_text::editing::utf16_of_char(layout, index);
        let snapped = comp_text::editing::snap_to_grapheme(&session.draft.content, offset);
        Some(comp_text::editing::char_of_utf16(layout, snapped))
    }

    /// Puts the caret where the pointer is, as a click does.
    pub(crate) fn text_place_caret(&mut self, at: egui::Pos2) -> bool {
        let Some(index) = self.text_index_at(at) else { return false };
        if let Some(session) = self.text_edit.as_mut() {
            session.caret.place(index);
        }
        true
    }

    /// Moves the far end of the selection to the pointer, as a drag does.
    pub(crate) fn text_extend_selection(&mut self, at: egui::Pos2) -> bool {
        let Some(index) = self.text_index_at(at) else { return false };
        if let Some(session) = self.text_edit.as_mut() {
            session.caret.extend(index);
        }
        true
    }

    /// Types into the open draft, replacing whatever is selected, and redraws its pixels.
    pub(crate) fn text_type(&mut self, typed: &str) {
        if typed.is_empty() {
            return;
        }
        let Some(session) = self.text_edit.as_mut() else { return };
        let (start, end) = crate::textedit::insert(&mut session.draft.content, &mut session.caret, typed);
        // The runs have to follow the edit, or a color painted over a word would slide sideways.
        let length = session.draft.content.encode_utf16().count();
        crate::runs::shift_text_runs(&mut session.draft, start, end, typed.encode_utf16().count(), length);
        let draft = session.draft.clone();
        let layer = session.layer;
        self.apply_text_draft(layer, draft);
        self.commit_text_session();
    }

    /// Removes the selection, or the cluster before the caret, and redraws.
    ///
    /// One press is one grapheme cluster, so a family emoji goes whole rather than unit by unit.
    pub(crate) fn text_backspace(&mut self) {
        let Some(range) = self.text_grapheme_removal(false) else { return };
        self.text_delete_utf16(range);
    }

    /// The UTF-16 range a backspace or a forward delete would remove from the open draft.
    fn text_grapheme_removal(&self, forward: bool) -> Option<std::ops::Range<usize>> {
        let session = self.text_edit.as_ref()?;
        let layout = session.layout.as_ref()?;
        crate::textnav::delete_grapheme(layout, &session.draft.content, &session.caret, forward)
    }

    /// Takes typing that no widget claimed while a text layer is open.
    ///
    /// egui sends text events to the focused widget; with the canvas focused they arrive here, which
    /// is what makes typing straight onto the canvas work. IME composition is out of scope.
    pub(crate) fn text_handle_keys(&mut self, ctx: &egui::Context) {
        if self.text_edit.is_none() || ctx.egui_wants_keyboard_input() {
            return;
        }
        // An input method's events come first: while it is composing, the pre-edit belongs on the
        // canvas and only a commit puts characters into the text.
        let ime_events: Vec<egui::Event> = ctx.input_mut(|input| {
            let mut taken = Vec::new();
            input.events.retain(|event| {
                if matches!(event, egui::Event::Ime(_)) {
                    taken.push(event.clone());
                    false
                } else {
                    true
                }
            });
            taken
        });
        for event in ime_events {
            let egui::Event::Ime(ime) = event else { continue };
            match ime {
                egui::ImeEvent::Preedit { text, active_range_chars } => self.text_preedit(text, active_range_chars),
                egui::ImeEvent::Commit(text) => {
                    if let Some(insert) = self.composition.commit(text) {
                        self.preedit_render = None;
                        self.text_type(&insert);
                    }
                }
                egui::ImeEvent::DeleteSurrounding { before_chars, after_chars } => {
                    self.text_delete_surrounding(before_chars, after_chars);
                }
                // Enabled and Disabled are no longer sent by egui; anything else is left alone.
                _ => {}
            }
        }
        // Command and Return finishes the text, which is the macOS shortcut for it; Return on its own
        // stays available for a future multi-line style and does nothing yet.
        let finish = ctx.input_mut(|input| {
            let command = input.modifiers.ctrl || input.modifiers.command;
            command && input.consume_key(egui::Modifiers::COMMAND, egui::Key::Enter)
        });
        if finish {
            self.commit_text_session();
            return;
        }
        // The caret and selection keys come next, through comp-text's boundary rules.
        let deleted = self.text_key_gestures(ctx);
        // Plain typing still goes straight in: an input method that is not composing sends Text.
        let typed = ctx.input_mut(|input| {
            let mut typed = String::new();
            input.events.retain(|event| match event {
                egui::Event::Text(text) => {
                    typed.push_str(text);
                    false
                }
                _ => true,
            });
            typed
        });
        if !typed.is_empty() {
            self.text_type(&typed);
            return;
        }
        if self.composition.is_composing() {
            // While a composition is up, Backspace takes it back before it edits the text.
            if ctx.input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::Backspace)) {
                self.composition.cancel();
                self.preedit_render = None;
            }
            return;
        }
        if deleted {
            // The word or line delete already ran; a plain Backspace would remove another character.
            return;
        }
        let removed = ctx.input_mut(|input| input.consume_key(egui::Modifiers::NONE, egui::Key::Backspace));
        if removed {
            self.text_backspace();
        }
    }

    /// Recomputes the draft's layout so the canvas frame, the caret and the hit tests track it.
    pub(crate) fn refresh_text_bounds(&mut self) {
        let Some(draft) = self.text_edit.as_ref().map(|session| session.draft.clone()) else { return };
        // The layout is what the geometry is asked about, so it is kept rather than the bare size.
        let layout = self.with_fonts(|library, _| comp_text::layout_text(&draft, library));
        let bounds = (layout.width, layout.height);
        let characters = layout.chars.len();
        if let Some(session) = self.text_edit.as_mut() {
            session.bounds = bounds;
            session.layout = Some(layout);
            session.caret.clamp(characters);
        }
    }

    /// Stores a draft style on the layer and remembers that its pixels are behind.
    pub(crate) fn apply_text_draft(&mut self, layer: Uuid, draft: TextStyle) {
        let changed = self.editor.set_text_style(layer, draft.clone());
        if let Some(session) = self.text_edit.as_mut() {
            session.draft = draft;
            if changed {
                session.uncommitted = true;
            }
        }
        self.refresh_text_bounds();
        if changed {
            self.editor.set_message("Text changed; press Draw to update the pixels");
        }
    }

    /// Takes an input-method preedit: the composed characters are shown at the caret, not inserted.
    pub(crate) fn text_preedit(&mut self, text: String, active_range: Option<std::ops::Range<usize>>) {
        if self.text_edit.is_none() {
            self.composition.cancel();
            self.preedit_render = None;
            return;
        }
        if self.composition.set_preedit(text, active_range) == crate::ime::PreeditOutcome::Dismissed {
            self.preedit_render = None;
            return;
        }
        self.refresh_preedit_render();
    }

    /// Typesets the composing text and works out its clauses, its caret and its anchor.
    ///
    /// The pre-edit is laid out on its own in the draft's own face, which is what makes the space it
    /// takes the space it keeps once it is committed.
    fn refresh_preedit_render(&mut self) {
        let Some(preedit) = self.composition.to_preedit() else {
            self.preedit_render = None;
            return;
        };
        let Some(session) = self.text_edit.as_ref() else {
            self.preedit_render = None;
            return;
        };
        let mut temporary = session.draft.clone();
        temporary.content = preedit.text.clone();
        temporary.color_runs = None;
        temporary.font_runs = None;
        let layout = self.with_fonts(|library, _| comp_text::layout_text(&temporary, library));
        let bounds = comp_text::preedit_bounds(&layout);
        let clauses = comp_text::preedit_clause_rects(&layout, &preedit)
            .into_iter()
            .map(|entry| (entry.clause.style, entry.rect))
            .collect();
        let caret = comp_text::caret_rect(&layout, preedit.caret);
        let anchor = comp_text::candidate_anchor(&layout, preedit.caret);
        self.preedit_render = match (bounds, caret) {
            (Some(bounds), Some(caret)) => Some(PreeditRender { bounds, clauses, caret, anchor }),
            _ => None,
        };
    }

    /// Tells the platform where the composing text and its caret are on screen.
    ///
    /// egui hands this to winit, which passes it to the platform's IME, and that is what puts the
    /// candidate list under the caret instead of in the corner of the window.
    pub(crate) fn sync_ime_output(&self, ctx: &Context) {
        let Some(render) = self.preedit_render.as_ref() else { return };
        let Some(session) = self.text_edit.as_ref() else { return };
        let Some(layer) = self.editor.document.layer(session.layer) else { return };
        let size = session.bounds;
        let view = self.editor.view;
        let to_screen = |rect: comp_core::RectF| {
            let rect = crate::textedit::layout_to_canvas(layer, size, rect);
            egui::Rect::from_min_max(
                view.doc_to_screen(egui::Pos2::new(rect.x as f32, rect.y as f32)),
                view.doc_to_screen(egui::Pos2::new(rect.max_x() as f32, rect.max_y() as f32)),
            )
        };
        // The candidate window points at the caret's own box, or the whole pre-edit when the
        // layout could not place a caret.
        let anchor = render.anchor.map(|anchor| to_screen(anchor.rect)).unwrap_or_else(|| to_screen(render.bounds));
        let caret = to_screen(render.caret);
        // Only the canvas composition is written here: when it is over the field is left alone, so
        // a text field in a panel keeps its own anchor.
        ctx.output_mut(|output| {
            output.ime = Some(egui::output::IMEOutput {
                purpose: egui::IMEPurpose::Normal,
                rect: anchor,
                cursor_rect: caret,
                should_interrupt_composition: false,
            });
        });
    }

    /// Applies one of comp-text's editing gestures to the caret of the open draft.
    fn text_apply_gesture(
        &mut self,
        gesture: impl Fn(&comp_text::TextLayout, &str, &mut crate::textedit::TextCaret),
    ) {
        let Some(session) = self.text_edit.as_ref() else { return };
        let Some(layout) = session.layout.as_ref() else { return };
        let mut caret = session.caret;
        gesture(layout, &session.draft.content, &mut caret);
        caret.clamp(layout.chars.len());
        if let Some(session) = self.text_edit.as_mut() {
            session.caret = caret;
        }
    }

    /// A double click on the canvas: the word under the pointer.
    pub(crate) fn text_select_word(&mut self, at: egui::Pos2) {
        let Some(index) = self.text_index_at(at) else { return };
        if let Some(session) = self.text_edit.as_mut() {
            session.caret.place(index);
        }
        self.text_apply_gesture(crate::textnav::select_word);
    }

    /// A triple click on the canvas: the paragraph under the pointer.
    pub(crate) fn text_select_paragraph(&mut self, at: egui::Pos2) {
        let Some(index) = self.text_index_at(at) else { return };
        if let Some(session) = self.text_edit.as_mut() {
            session.caret.place(index);
        }
        self.text_apply_gesture(crate::textnav::select_paragraph);
    }

    /// Removes a UTF-16 range from the draft and redraws it, as one undo step.
    pub(crate) fn text_delete_utf16(&mut self, range: std::ops::Range<usize>) {
        let Some(session) = self.text_edit.as_mut() else { return };
        let (start, end) = (range.start, range.end.max(range.start));
        if start >= end {
            return;
        }
        // Pushed out to cluster boundaries first, so the edit cannot cut one in half.
        let snapped = comp_text::editing::snap_range_to_graphemes(&session.draft.content, start..end);
        let (start, end) = (snapped.start, snapped.end);
        let from = crate::runs::char_index(&session.draft.content, start);
        let to = crate::runs::char_index(&session.draft.content, end);
        if from >= to {
            return;
        }
        let mut next = String::with_capacity(session.draft.content.len());
        next.extend(session.draft.content.chars().take(from));
        next.extend(session.draft.content.chars().skip(to));
        session.draft.content = next;
        session.caret.place(from);
        let length = session.draft.content.encode_utf16().count();
        crate::runs::shift_text_runs(&mut session.draft, start, end, 0, length);
        let draft = session.draft.clone();
        let layer = session.layer;
        self.apply_text_draft(layer, draft);
        self.commit_text_session();
    }

    /// The caret and selection keys, all through comp-text's boundary rules.
    ///
    /// Returns true when Backspace was one of them, so the plain one does not run afterwards.
    fn text_key_gestures(&mut self, ctx: &Context) -> bool {
        use egui::Key;
        let (shift, ctrl) = ctx.input(|input| (input.modifiers.shift, input.modifiers.ctrl || input.modifiers.command));
        let pressed = |key: Key| ctx.input(|input| input.key_pressed(key));
        let mut caret = match self.text_edit.as_ref() {
            Some(session) if session.layout.is_some() => session.caret,
            _ => return false,
        };
        let mut handled = false;
        let mut removal: Option<std::ops::Range<usize>> = None;
        {
            let Some(session) = self.text_edit.as_ref() else { return false };
            let Some(layout) = session.layout.as_ref() else { return false };
            let content = session.draft.content.as_str();

            // Home and End, and their shift versions.
            if pressed(Key::Home) {
                if shift {
                    crate::textnav::extend_line_edge(layout, content, &mut caret, false);
                } else {
                    crate::textnav::move_line_edge(layout, content, &mut caret, false);
                }
                handled = true;
            }
            if pressed(Key::End) {
                if shift {
                    crate::textnav::extend_line_edge(layout, content, &mut caret, true);
                } else {
                    crate::textnav::move_line_edge(layout, content, &mut caret, true);
                }
                handled = true;
            }
            // The arrows: one character, or one word with Ctrl, extending with Shift.
            // One step is one grapheme cluster; with Ctrl it is one word.
            if pressed(Key::ArrowLeft) {
                match (ctrl, shift) {
                    (true, true) => crate::textnav::extend_word(layout, content, &mut caret, false),
                    (true, false) => crate::textnav::move_word(layout, content, &mut caret, false),
                    (false, true) => crate::textnav::extend_grapheme(layout, content, &mut caret, false),
                    (false, false) => crate::textnav::move_grapheme(layout, content, &mut caret, false),
                }
                handled = true;
            }
            if pressed(Key::ArrowRight) {
                match (ctrl, shift) {
                    (true, true) => crate::textnav::extend_word(layout, content, &mut caret, true),
                    (true, false) => crate::textnav::move_word(layout, content, &mut caret, true),
                    (false, true) => crate::textnav::extend_grapheme(layout, content, &mut caret, true),
                    (false, false) => crate::textnav::move_grapheme(layout, content, &mut caret, true),
                }
                handled = true;
            }
            // Up and down keep the column, as far as the line allows.
            if pressed(Key::ArrowUp) {
                if shift {
                    crate::textnav::extend_line(layout, content, &mut caret, false);
                } else {
                    crate::textnav::move_line(layout, content, &mut caret, false);
                }
                handled = true;
            }
            if pressed(Key::ArrowDown) {
                if shift {
                    crate::textnav::extend_line(layout, content, &mut caret, true);
                } else {
                    crate::textnav::move_line(layout, content, &mut caret, true);
                }
                handled = true;
            }
            // Backspace and Delete, by a word with Ctrl and to the line edge with Ctrl+Shift.
            if pressed(Key::Backspace) && ctrl {
                removal = if shift {
                    crate::textnav::delete_to_line_edge(layout, content, &caret, false)
                } else {
                    crate::textnav::delete_word(layout, content, &caret, false)
                };
                handled = true;
            } else if pressed(Key::Delete) && ctrl {
                removal = if shift {
                    crate::textnav::delete_to_line_edge(layout, content, &caret, true)
                } else {
                    crate::textnav::delete_word(layout, content, &caret, true)
                };
                handled = true;
            } else if pressed(Key::Delete) {
                // A plain forward delete takes the selection, or the cluster after the caret.
                removal = crate::textnav::delete_grapheme(layout, content, &caret, true);
                handled = true;
            }
        }
        if handled {
            if let Some(session) = self.text_edit.as_mut() {
                session.caret = caret;
            }
        }
        if let Some(range) = removal {
            self.text_delete_utf16(range);
        }
        handled
    }

    /// Deletes around the caret because the input method asked for it.
    pub(crate) fn text_delete_surrounding(&mut self, before: usize, after: usize) {
        let Some(session) = self.text_edit.as_mut() else { return };
        let removed = crate::textedit::delete_surrounding(&mut session.draft.content, &mut session.caret, before, after);
        let Some((start, end)) = removed else { return };
        let length = session.draft.content.encode_utf16().count();
        crate::runs::shift_text_runs(&mut session.draft, start, end, 0, length);
        let draft = session.draft.clone();
        let layer = session.layer;
        self.apply_text_draft(layer, draft);
        self.commit_text_session();
    }

    /// Rasterizes the draft into the layer's pixels and closes the undo step.
    pub(crate) fn commit_text_session(&mut self) {
        let Some(layer) = self.text_edit.as_ref().map(|session| session.layer) else { return };
        let outcome = self.with_fonts(|library, editor| editor.commit_text(layer, library));
        match outcome {
            Ok((width, height)) => {
                self.report_font_fallbacks();
                if let Some(session) = self.text_edit.as_mut() {
                    session.bounds = (width, height);
                    session.uncommitted = false;
                }
                self.editor.finish_edit();
                self.editor.set_message(format!("Text drawn at {width} x {height}"));
            }
            Err(message) => {
                self.editor.set_error(message);
                self.editor.finish_edit();
            }
        }
        self.request_render(true);
    }

    /// Ends the session, leaving the layer's pixels in step with its metadata.
    pub(crate) fn end_text_session(&mut self) {
        if self.text_edit.is_none() {
            return;
        }
        self.commit_text_session();
        self.text_edit = None;
        self.composition.cancel();
        self.preedit_render = None;
    }

    /// Reports a substituted face, which the user would otherwise only see in the pixels.
    fn report_font_fallbacks(&mut self) {
        let Some(requested) = self.text_edit.as_ref().map(|session| session.draft.font_name.clone()) else { return };
        let used = self.with_fonts(|library, _| {
            let substituted = library
                .fallbacks()
                .iter()
                .find(|fallback| fallback.requested == requested)
                .map(|fallback| fallback.used.clone());
            library.clear_fallbacks();
            substituted
        });
        if let Some(used) = used {
            self.editor.set_message(format!("{requested} is not installed; drew with {used}"));
        }
    }

    /// Opens a package folder; a .comp is a directory on disk, exactly as on macOS.
    pub(crate) fn open_dialog(&mut self) {
        let mut dialog = rfd::FileDialog::new().set_title("Open a .comp package folder");
        if let Some(directory) = &self.working_dir {
            dialog = dialog.set_directory(directory);
        }
        let Some(folder) = dialog.pick_folder() else { return };
        if !folder.join(comp_core::store::MANIFEST_NAME).is_file() {
            self.editor.set_error(format!("{} is not a .comp package", folder.display()));
            return;
        }
        self.open_path(folder);
    }

    /// Reads an image, Photoshop file or package into a document of its own.
    pub(crate) fn import_document_path(&mut self, path: PathBuf) {
        self.working_dir = path.parent().map(PathBuf::from);
        self.editor.set_message(format!("Importing {}...", path.display()));
        self.io.send(IoRequest::ImportDocument { path });
    }

    /// Reads an image or Photoshop file into a new layer of the open document.
    pub(crate) fn import_layer_path(&mut self, path: PathBuf) {
        self.working_dir = path.parent().map(PathBuf::from);
        self.editor.set_message(format!("Importing {} as a layer...", path.display()));
        self.io.send(IoRequest::ImportLayer { document: self.editor.document.clone(), path });
    }

    pub(crate) fn import_dialog(&mut self, as_layer: bool) {
        let mut dialog = rfd::FileDialog::new()
            .set_title(if as_layer { "Import an image as a layer" } else { "Import an image as a document" })
            .add_filter("Images", &["png", "jpg", "jpeg", "tif", "tiff", "bmp", "webp"])
            .add_filter("Photoshop", &["psd", "psb"]);
        if let Some(directory) = &self.working_dir {
            dialog = dialog.set_directory(directory);
        }
        let Some(path) = dialog.pick_file() else { return };
        if as_layer {
            self.import_layer_path(path);
        } else {
            self.import_document_path(path);
        }
    }

    pub(crate) fn open_path(&mut self, path: PathBuf) {
        // A package that is already open comes forward instead of being loaded into a second tab.
        let paths: Vec<Option<PathBuf>> = (0..self.tabs.len()).map(|index| self.project_path(index)).collect();
        if let Some(index) = crate::tabs::find_path(&paths, &path) {
            self.switch_tab(index);
            self.editor.set_message(format!("{} is already open", path.display()));
            return;
        }
        // A window still showing its blank first document opens into that tab rather than beside it.
        if !self.only_a_blank_tab() {
            self.add_tab(crate::session::Editor::with_document(comp_core::Document::new(1, 1)));
        }
        self.working_dir = path.parent().map(PathBuf::from);
        self.editor.set_message(format!("Opening {}...", path.display()));
        self.io.send(IoRequest::Open(path));
    }

    pub(crate) fn save(&mut self) {
        match self.editor.path.clone() {
            Some(path) => self.save_to(path),
            None => self.save_as_dialog(),
        }
    }

    pub(crate) fn save_as_dialog(&mut self) {
        let mut dialog = rfd::FileDialog::new()
            .set_title("Save the project as")
            .add_filter("Compositor project", &["comp"])
            .set_file_name("Untitled.comp");
        if let Some(directory) = &self.working_dir {
            dialog = dialog.set_directory(directory);
        }
        let Some(mut path) = dialog.save_file() else { return };
        if path.extension().map(|extension| extension != "comp").unwrap_or(true) {
            path.set_extension("comp");
        }
        self.working_dir = path.parent().map(PathBuf::from);
        self.save_to(path);
    }

    fn save_to(&mut self, path: PathBuf) {
        // Keep the live document's asset names in step with what the writer will produce.
        self.editor.document.refresh_asset_names();
        self.editor.set_message(format!("Saving {}...", path.display()));
        self.io.send(IoRequest::Save { document: self.editor.document.clone(), path });
    }

    pub(crate) fn export_dialog(&mut self) {
        let stem = self.editor.file_name().trim_end_matches(".comp").to_string();
        let mut dialog = rfd::FileDialog::new()
            .set_title("Export a flattened PNG")
            .add_filter("PNG image", &["png"])
            .set_file_name(format!("{stem}.png"));
        if let Some(directory) = &self.working_dir {
            dialog = dialog.set_directory(directory);
        }
        let Some(mut path) = dialog.save_file() else { return };
        if path.extension().map(|extension| extension != "png").unwrap_or(true) {
            path.set_extension("png");
        }
        self.working_dir = path.parent().map(PathBuf::from);
        self.editor.set_message(format!("Exporting {}...", path.display()));
        self.io.send(IoRequest::Export {
            document: self.editor.document.clone(),
            path,
            preference: self.backend_preference,
        });
    }

    /// The same export, for a JPEG: macOS has a second menu item and a second chord for it.
    pub(crate) fn export_jpeg_dialog(&mut self) {
        let stem = self.editor.file_name().trim_end_matches(".comp").to_string();
        let mut dialog = rfd::FileDialog::new()
            .set_title("Export a flattened JPEG")
            .add_filter("JPEG image", &["jpg", "jpeg"])
            .set_file_name(format!("{stem}.jpg"));
        if let Some(directory) = &self.working_dir {
            dialog = dialog.set_directory(directory);
        }
        let Some(mut path) = dialog.save_file() else { return };
        let extension = path
            .extension()
            .map(|extension| extension.to_string_lossy().to_lowercase())
            .unwrap_or_default();
        if extension != "jpg" && extension != "jpeg" {
            path.set_extension("jpg");
        }
        self.working_dir = path.parent().map(PathBuf::from);
        self.editor.set_message(format!("Exporting {}...", path.display()));
        self.io.send(IoRequest::Export {
            document: self.editor.document.clone(),
            path,
            preference: self.backend_preference,
        });
    }
}

impl eframe::App for GuiApp {
    /// Writes what the next run should come back to: the open packages and the view switches.
    ///
    /// eframe calls this on a timer and once more on the way out, so a crash costs at most the
    /// changes since the last call.
    fn save(&mut self, storage: &mut dyn eframe::Storage) {
        let state = self.session_state();
        eframe::set_value(storage, SESSION_KEY, &state);
        storage.flush();
    }

    fn ui(&mut self, ui: &mut egui::Ui, _frame: &mut eframe::Frame) {
        let ctx = ui.ctx().clone();
        self.frames += 1;
        // The clock for the reported average starts after the first few frames, so font building and
        // the first composite are not counted as if they happened every frame.
        if self.frames == 5 {
            self.opened_at = std::time::Instant::now();
        }
        self.pump(&ctx);
        self.shortcuts(&ctx);
        // Typing that no widget claimed goes to the open text draft on the canvas.
        self.text_handle_keys(&ctx);
        self.sync_title(&ctx);
        self.handle_dropped_files(&ctx);

        egui::Panel::top("menu-bar").show(ui, |ui| self.menu_bar(ui));
        egui::Panel::top("tab-bar").show(ui, |ui| self.tab_bar(ui));
        egui::Panel::top("tool-bar").show(ui, |ui| self.tool_bar(ui));
        egui::Panel::bottom("status-bar").show(ui, |ui| self.status_bar(ui));
        egui::Panel::right("layers-panel")
            .default_size(320.0)
            .min_size(240.0)
            .show(ui, |ui| self.layers_panel(ui));
        egui::CentralPanel::default().show(ui, |ui| self.canvas(ui));

        self.new_document_window(&ctx);
        self.about_window(&ctx);
        self.raw_window(&ctx);
        self.filter_window(&ctx);
        self.watch_window(&ctx);
        self.grid_window(&ctx);
        // Where the candidate window should point, once the canvas has settled for this frame.
        self.sync_ime_output(&ctx);
        self.close_tab_window(&ctx);
        self.color_window(&ctx);
        self.recovery_window(&ctx);
        self.load_error_window(&ctx);
        self.color_popup(&ctx);

        // A smoke test can ask the app to close itself after a few painted frames. It has to keep
        // asking for repaints, because egui otherwise idles as soon as the workers are quiet.
        if let Ok(limit) = std::env::var("COMP_GUI_EXIT_AFTER_FRAMES") {
            if let Ok(limit) = limit.parse::<u64>() {
                if self.frames >= limit {
                    // The line below is the smoke test's evidence that the window drew, the worker
                    // composited and the texture upload landed.
                    let texture = match &self.texture {
                        Some(texture) => format!("{}x{}", texture.size()[0], texture.size()[1]),
                        None => "missing".to_string(),
                    };
                    // The backend is part of the evidence: the smoke run says which compositor drew it.
                    let availability = engine::availability(&self.editor.document);
                    let backend = crate::backend::status_line(
                        self.backend_preference,
                        self.last_backend,
                        &availability,
                    );
                    // The tab count is how a restore shows up in a headless run: opening a package
                    // saves the session, and the next run without one should come back with it open.
                    // The average frame is the number to watch over time: it covers the editor's work
                    // as well as the compositor's, and it says which compositor that was.
                    let steady_frames = self.frames.saturating_sub(5).max(1) as f64;
                    let average_frame = self.opened_at.elapsed().as_secs_f64() * 1000.0 / steady_frames;
                    eprintln!(
                        "comp-gui smoke test: frames={}, frame_avg={:.1} ms, texture={}, uploaded_epoch={}, flatten={} ms, backend={}, subject={}, tabs={}",
                        self.frames,
                        average_frame,
                        texture,
                        self.uploaded_epoch,
                        self.render_millis,
                        backend,
                        crate::subject::short_label(&self.subject_backend),
                        self.tabs.len()
                    );
                    // The session is written on the way out, as eframe does when the window closes.
                    ctx.send_viewport_cmd(egui::ViewportCommand::Close);
                } else {
                    ctx.request_repaint();
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn import_extensions_cover_images_photoshop_and_projects() {
        use std::path::Path;
        assert_eq!(import_extension(Path::new("a/b/Photo.JPG")).as_deref(), Some("jpg"));
        assert_eq!(import_extension(Path::new("art.tiff")).as_deref(), Some("tiff"));
        assert_eq!(import_extension(Path::new("art.psd")).as_deref(), Some("psd"));
        assert_eq!(import_extension(Path::new("Doc.comp")).as_deref(), Some("comp"));
        assert_eq!(import_extension(Path::new("readme.txt")), None);
        assert_eq!(import_extension(Path::new("noextension")), None);
    }

    #[test]
    fn preview_requests_are_throttled_but_forced_ones_are_not() {
        // The throttle only ever delays a preview; this pins the interval constant the canvas and
        // the stroke path rely on.
        assert!(PREVIEW_INTERVAL <= Duration::from_millis(100));
    }
}
