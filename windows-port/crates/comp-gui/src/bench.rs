//! The editor's own timings, measured in release.
//!
//! These are not correctness tests: they are the numbers behind NOTES.md's performance section, so
//! they are ignored by default and run with
//! cargo test --release -p comp-gui --lib bench -- --ignored --nocapture
//!
//! What is measured here is the editor's share of a frame — laying the layer panel out, packing
//! thumbnails, walking the grid, turning a composite into the image egui uploads, and re-laying a
//! text layer out while typing. The compositor is measured too, but only so the editor's slice has
//! something to sit beside.

use std::sync::Arc;
use std::time::{Duration, Instant};

use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::document::Document;
use comp_core::geom::PointF;
use comp_core::layer::Layer;
use comp_core::text::TextStyle;
use uuid::Uuid;

/// Runs a closure enough times to mean something and answers the average, in milliseconds.
fn average(label: &str, runs: usize, mut body: impl FnMut()) -> f64 {
    // One warm-up pass, so page faults and lazily built caches are not counted.
    body();
    let started = Instant::now();
    for _ in 0..runs {
        body();
    }
    let each = started.elapsed().as_secs_f64() * 1000.0 / runs as f64;
    eprintln!("bench: {label}: {each:.2} ms over {runs} runs");
    each
}

/// A canvas of this size with this many layers, each carrying its own pixels.
fn big_document(size: u32, layers: usize) -> Document {
    let mut document = Document::new(size, size);
    for index in 0..layers {
        let step = (size / 8).max(1);
        let mut pixels = Bitmap8::new(size, size);
        // A band per layer, so the layers really differ and the compositor cannot shortcut.
        for y in 0..size {
            for x in 0..size {
                let value = ((x / step + y / step + index as u32) % 8) as u8 * 32;
                pixels.set(x, y, [value, value.wrapping_add(index as u8), 128, 200]);
            }
        }
        let mut layer = Layer::with_image(format!("Layer {index}"), pixels);
        layer.transform.origin = PointF::new((index % 4) as f64 * 8.0, (index / 4) as f64 * 8.0);
        document.add_layer(layer, None);
    }
    document
}

/// A document with this many small layers, which is what the panel has to draw.
fn many_layers(count: usize) -> Document {
    let mut document = Document::new(256, 256);
    for index in 0..count {
        let mut pixels = Bitmap8::new(64, 64);
        for y in 0..64 {
            for x in 0..64 {
                pixels.set(x, y, [(x * 4) as u8, (y * 4) as u8, index as u8, 255]);
            }
        }
        let mut layer = Layer::with_image(format!("Layer {index}"), pixels);
        layer.transform.origin = PointF::new((index % 8) as f64 * 20.0, (index / 8) as f64 * 20.0);
        // A mask on every third layer, so the panel has mask thumbnails to pack too.
        if index % 3 == 0 {
            layer.mask = Some(Arc::new(Gray8::filled(64, 64, (index % 255) as u8)));
        }
        document.add_layer(layer, None);
    }
    document
}

/// A text layer with a paragraph of this many characters.
fn text_document(characters: usize) -> (Document, Uuid) {
    let sentence = "The quick brown fox jumps over the lazy dog. ";
    let mut content = String::new();
    while content.chars().count() < characters {
        content.push_str(sentence);
    }
    let mut document = Document::new(1024, 1024);
    let mut layer = Layer::raster("Text", 1024, 1024);
    layer.text = Some(TextStyle { content, font_size: 24.0, ..TextStyle::default() });
    let id = document.add_layer(layer, None);
    (document, id)
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_full_repaint() {
    let document = big_document(4000, 20);
    let (bitmap, backend) = crate::engine::flatten_full(&document, crate::backend::Preference::ForceCpu);
    eprintln!("bench: full repaint used {backend:?} and produced {}x{}", bitmap.width(), bitmap.height());
    average("4000x4000, 20 layers: full repaint (CPU)", 3, || {
        let _ = crate::engine::flatten_full(&document, crate::backend::Preference::ForceCpu);
    });
    average("4000x4000, 20 layers: full repaint (preferred backend)", 3, || {
        let _ = crate::engine::flatten_full(&document, crate::backend::Preference::PreferGpu);
    });
    average("4000x4000: one 256x256 region repaint", 20, || {
        let _ = crate::engine::flatten_region(&document, (1000, 1000, 256, 256));
    });
    // The composite is taken once, so this measures the conversion the upload does and not the
    // compositor underneath it.
    let composite = crate::engine::flatten_document(&document);
    average("4000x4000: the whole composite as the image egui uploads", 5, || {
        let _ = egui::ColorImage::from_rgba_unmultiplied(
            [composite.width() as usize, composite.height() as usize],
            composite.pixels(),
        );
    });
    let region = composite.subimage(1000, 1000, 256, 256);
    average("4000x4000: a 256x256 rectangle as an upload image", 50, || {
        let _ = egui::ColorImage::from_rgba_unmultiplied(
            [region.width() as usize, region.height() as usize],
            region.pixels(),
        );
    });
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_undo_repaint() {
    let mut editor = crate::session::Editor::with_document(big_document(4000, 20));
    // One edit, so there is a step to undo and redo.
    let id = editor.document.layers.last().map(|layer| layer.id).expect("a layer");
    editor.begin_edit("Move Layer");
    editor.translate_layer(id, egui::Vec2::new(4.0, 4.0));
    editor.finish_edit();
    average("4000x4000, 20 layers: undo + redo (history swap)", 3, || {
        let _ = editor.undo();
        let _ = editor.redo();
    });
    average("4000x4000, 20 layers: layer order change + repaint", 3, || {
        editor.move_active_layer(1);
        let _ = crate::engine::flatten_full(&editor.document, crate::backend::Preference::ForceCpu);
    });
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_layer_panel() {
    let document = many_layers(100);
    let collapsed = std::collections::HashSet::new();
    average("100 layers: panel rows per frame", 50, || {
        let rows = crate::panel::layer_rows(&document, &collapsed);
        assert_eq!(rows.len(), 100);
    });
    average("100 layers: thumbnail keys + stale list per frame", 50, || {
        let _ = crate::thumbs::stale_layers(
            &document.layers,
            1,
            &std::collections::HashMap::new(),
            crate::thumbs::PER_FRAME,
        );
    });
    average("100 layers: 2 thumbnails as the budget allows", 20, || {
        for layer in document.layers.iter().take(2) {
            let _ = crate::thumbs::thumbnail_for(layer);
        }
    });
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_view_and_grid() {
    let grid = crate::guides::GridSettings { visible: true, spacing: 64, subdivisions: 4 };
    average("5000x5000: grid lines for both axes", 50, || {
        let _ = grid.lines(5000.0);
    });
    let mut view = crate::view::CanvasView::default();
    let viewport = egui::Rect::from_min_size(egui::Pos2::ZERO, egui::Vec2::new(1440.0, 900.0));
    view.refresh(viewport, 5000.0, 5000.0);
    average("5000x5000: a pan/zoom frame of view arithmetic", 200, || {
        view.pan_by(egui::Vec2::new(1.0, 0.5));
        let _ = view.doc_to_screen(egui::Pos2::new(2500.0, 2500.0));
        let _ = view.screen_to_doc(egui::pos2(700.0, 450.0));
        let _ = view.doc_rect_on_screen(5000.0, 5000.0);
    });
    average("5000x5000: a frame of guide and snap targets", 50, || {
        let _ = crate::guides::targets(
            comp_core::geom::GuideAxis::Vertical,
            (5000.0, 5000.0),
            &[],
            &grid,
            &crate::guides::SnapSettings::default(),
            &[1200.0, 2400.0, 3600.0],
        );
    });
}

/// One egui frame with a layer panel in it, drawn headless.
///
/// The rows are the widgets the real panel draws — a visibility box, a drag source, a thumbnail, a
/// name label and a small note — so the number is the cost of the panel rather than of the model
/// underneath it. Virtualized draws only the rows the viewport can show, which is what
/// ScrollArea::show_rows does.
fn panel_frame(document: &Document, virtualized: bool) -> f64 {
    let context = egui::Context::default();
    let mut frame = 0usize;
    let draw = |context: &egui::Context, frame: &mut usize| {
        let input = egui::RawInput { screen_rect: Some(egui::Rect::from_min_size(egui::Pos2::ZERO, egui::vec2(1440.0, 900.0))), ..Default::default() };
        // egui 0.36 frames run as begin_pass/end_pass, which is what a headless frame needs.
        context.begin_pass(input);
        {
            // An area the size of the window stands in for the panel: 0.36 shows panels inside a Ui,
            // and an Area is the container that still takes a Context.
            egui::Area::new(egui::Id::new("panel-bench"))
                .fixed_pos(egui::Pos2::ZERO)
                .show(context, |ui| {
                    ui.set_min_size(egui::vec2(1440.0, 900.0));
                let rows = crate::panel::layer_rows(document, &std::collections::HashSet::new());
                let scroll = egui::ScrollArea::vertical();
                if virtualized {
                    // The panel's own row height, which is what makes the off-screen rows skippable.
                    scroll.show_rows(ui, 26.0, rows.len(), |ui, range| {
                        for row in &rows[range] {
                            row_widgets(ui, document, row);
                        }
                    });
                } else {
                    scroll.show(ui, |ui| {
                        for row in &rows {
                            row_widgets(ui, document, row);
                        }
                    });
                }
                });
        }
        let _ = context.end_pass();
        *frame += 1;
    };
    // A few frames first: egui builds its fonts and its layout caches on the first one.
    for _ in 0..3 {
        draw(&context, &mut frame);
    }
    let started = Instant::now();
    for _ in 0..10 {
        draw(&context, &mut frame);
    }
    let each = started.elapsed().as_secs_f64() * 1000.0 / 10.0;
    each
}

/// The widgets one layer row draws, mirroring the panel's own.
fn row_widgets(ui: &mut egui::Ui, document: &Document, row: &crate::panel::LayerRow) {
    let Some(layer) = document.layers.get(row.index) else { return };
    ui.horizontal(|ui| {
        let mut visible = layer.visible;
        let _ = ui.checkbox(&mut visible, "");
        ui.add_space(row.depth as f32 * 12.0);
        if let Some(thumb) = crate::thumbs::thumbnail_for(layer) {
            let size = egui::vec2(thumb.width() as f32, thumb.height() as f32);
            let (rect, _) = ui.allocate_exact_size(egui::vec2(size.x + 4.0, size.y), egui::Sense::hover());
            let _ = rect;
        }
        let _ = ui.selectable_label(false, &layer.name);
        let _ = ui.label(egui::RichText::new("50%").weak().small());
    });
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_panel_frame() {
    let document = many_layers(100);
    let all = panel_frame(&document, false);
    eprintln!("bench: 100 layers: one panel frame, every row drawn: {all:.2} ms");
    let virtualized = panel_frame(&document, true);
    eprintln!("bench: 100 layers: one panel frame, visible rows only: {virtualized:.2} ms");
    let small = many_layers(20);
    let all_small = panel_frame(&small, false);
    eprintln!("bench: 20 layers: one panel frame, every row drawn: {all_small:.2} ms");
    let huge = many_layers(400);
    let all_huge = panel_frame(&huge, false);
    eprintln!("bench: 400 layers: one panel frame, every row drawn: {all_huge:.2} ms");
    let virtualized_huge = panel_frame(&huge, true);
    eprintln!("bench: 400 layers: one panel frame, visible rows only: {virtualized_huge:.2} ms");
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_typing() {
    let (document, id) = text_document(400);
    let mut library = comp_text::FontLibrary::from_faces(Vec::new(), Vec::new());
    let style = document.layer(id).and_then(|layer| layer.text.clone()).expect("a text layer");
    average("typing: relayout a 400 character paragraph", 20, || {
        let _ = comp_text::layout_text(&style, &mut library);
    });
    let mut editor = crate::session::Editor::with_document(document);
    editor.select_layer(id);
    average("typing: relayout and rasterize (one keystroke)", 20, || {
        let mut draft = editor.text_style(id).expect("a style");
        draft.content.push('x');
        editor.set_text_style(id, draft);
        let _ = editor.commit_text(id, &mut library);
        // Put it back, so every run measures the same edit.
        if let Some(mut style) = editor.text_style(id) {
            style.content.pop();
            editor.set_text_style(id, style);
        }
    });
}

#[test]
#[ignore = "a benchmark: run with --ignored --nocapture in release"]
fn bench_stroke_region() {
    // A stroke's own frame: the dirty rectangle of a big canvas, which is what keeps painting cheap.
    let document = big_document(4000, 20);
    let mut total = Duration::ZERO;
    let runs = 30;
    for _ in 0..runs {
        let started = Instant::now();
        let bounds = crate::engine::union_bounds(Some((1000, 1000, 64, 64)), (1100, 1050, 64, 64));
        let _ = bounds.and_then(|bounds| crate::engine::flatten_region(&document, bounds));
        total += started.elapsed();
    }
    eprintln!(
        "bench: 4000x4000: a stroke frame (union + region): {:.2} ms",
        total.as_secs_f64() * 1000.0 / runs as f64
    );
}
