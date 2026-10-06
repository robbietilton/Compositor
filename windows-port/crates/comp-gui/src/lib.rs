//! The Windows editor shell for Compositor.
//!
//! The crate is split so that everything except the panels is pure logic: the view transform, the
//! tool state machine, the editor session, the panel layout and the background workers all run and
//! are tested without a window, and the egui layer only draws them.

pub mod app;
pub mod backend;
pub mod clipboard;
#[cfg(test)]
mod bench;
pub mod color;
pub mod curve;
pub mod engine;
pub mod filters;
pub mod guides;
pub mod ime;
pub mod loaderror;
pub mod maskfill;
pub mod merge;
pub mod multiselect;
pub mod panel;
pub mod parity;
pub mod raw;
pub mod recovery;
pub mod reorder;
pub mod runs;
pub mod session;
pub mod shortcuts;
pub mod subject;
pub mod session_state;
pub mod textedit;
pub mod textnav;
pub mod tabs;
pub mod thumbs;
pub mod tools;
pub mod ui;
pub mod view;
pub mod watch;
pub mod worker;

pub use app::GuiApp;
pub use comp_core as core;
pub use session::{Editor, MemoryEstimate};
pub use tools::{BrushSettings, Tool, ToolEffect, ToolMachine};
pub use view::{CanvasView, FitMode};

use std::path::{Path, PathBuf};

/// Opens the editor window, optionally on a package.
pub fn run(initial: Option<PathBuf>) -> eframe::Result {
    let options = eframe::NativeOptions {
        viewport: egui::ViewportBuilder::default()
            .with_title("Compositor")
            .with_inner_size([1440.0, 900.0])
            .with_min_inner_size([960.0, 600.0]),
        // The window comes back where it was, at the size it was, from the saved state.
        persist_window: true,
        ..Default::default()
    };
    eframe::run_native(
        "compositor",
        options,
        Box::new(move |cc| Ok(Box::new(GuiApp::new(cc, initial)))),
    )
}

/// Flattens a package to a PNG without opening a window.
///
/// This is the headless check for the same compositing and export path the canvas uses.
pub fn flatten_to_png(input: &Path, output: &Path) -> Result<String, String> {
    let (document, _digest) = worker::open_document(input).map_err(|problem| problem.summary())?;
    // The command line stays on the CPU: the verification fixtures compare this path byte for byte.
    let (width, height, _) = worker::export_image(&document, output, crate::backend::Preference::ForceCpu)?;
    Ok(format!(
        "{} -> {} ({}x{})",
        input.display(),
        output.display(),
        width,
        height
    ))
}
