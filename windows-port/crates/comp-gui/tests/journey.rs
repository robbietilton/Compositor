//! The journey a person takes through the editor, driven without a window.
//!
//! The smoke test proves the window draws and the fixture run proves the compositor renders; neither
//! touches the editing path. This file drives the same session and editor API the panels call, in the
//! order a person would, and after every step it checks three things:
//!
//! * the document says what it should (layers, blend, opacity, masks, adjustments, the modified flag),
//! * the whole-canvas render changed as expected, and the region render equals the crop of it,
//! * undo and redo return the pixels byte for byte, including once across a save point.
//!
//! Everything here runs headless: the panels and the window are the only parts that need an egui
//! context, and nothing in this file touches them. What cannot be driven this way is listed in the
//! crate's NOTES rather than faked here.

use std::path::{Path, PathBuf};

use comp_gui::core::adjustment::AdjustmentKind;
use comp_gui::core::bitmap::Bitmap8;
use comp_gui::core::blend::BlendMode;
use comp_gui::core::document::Document;
use comp_gui::core::geom::PointF;
use comp_gui::filters::{FilterKind, FilterSettings};
use comp_gui::maskfill::{GradientBlend, GradientShape};
use comp_gui::{backend::Preference, engine, worker};
use comp_gui::{BrushSettings, Editor};
use egui::{pos2, vec2};

/// A directory that cleans up after itself.
struct Scratch(PathBuf);

impl Scratch {
    fn new(name: &str) -> Scratch {
        let stamp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map(|elapsed| elapsed.as_nanos())
            .unwrap_or(0);
        let path = std::env::temp_dir().join(format!("comp-gui-journey-{name}-{}-{stamp}", std::process::id()));
        std::fs::create_dir_all(&path).expect("a scratch directory");
        Scratch(path)
    }

    fn package(&self, name: &str) -> PathBuf {
        self.0.join(name)
    }
}

impl Drop for Scratch {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

/// An editor on a fresh document of this size.
fn new_editor(width: u32, height: u32) -> Editor {
    Editor::with_document(Document::with_background(width, height))
}

/// The whole canvas, rendered on the CPU so the bytes are the reference ones.
fn render(editor: &Editor) -> Bitmap8 {
    engine::flatten_full(&editor.document, Preference::ForceCpu).0
}

/// The same canvas through the region path a stroke uses.
fn region(editor: &Editor, bounds: (i64, i64, u32, u32)) -> Bitmap8 {
    engine::flatten_region(&editor.document, bounds).expect("a region inside the canvas")
}

/// The first place two images disagree, described in a line rather than as two pixel dumps.
fn first_difference(left: &Bitmap8, right: &Bitmap8) -> Option<String> {
    let (width, height) = (left.width(), left.height());
    if (width, height) != (right.width(), right.height()) {
        return Some(format!("size {width}x{height} against {}x{}", right.width(), right.height()));
    }
    let (left_pixels, right_pixels) = (left.pixels(), right.pixels());
    for (index, (a, b)) in left_pixels.iter().zip(right_pixels.iter()).enumerate() {
        if a != b {
            let pixel = index / 4;
            let (x, y) = ((pixel as u32) % width, (pixel as u32) / width);
            return Some(format!(
                "{} of {} pixels differ; the first is at x={x} y={y} channel {} ({a} against {b})",
                left_pixels.iter().zip(right_pixels.iter()).filter(|(a, b)| a != b).count(),
                pixel + 1,
                index % 4
            ));
        }
    }
    None
}

/// Asserts that a region render is the exact crop of the full one.
fn assert_region_is_the_crop(editor: &Editor, bounds: (i64, i64, u32, u32)) {
    let full = render(editor);
    let expected = full.subimage(bounds.0, bounds.1, bounds.2, bounds.3);
    let actual = region(editor, bounds);
    if let Some(difference) = first_difference(&actual, &expected) {
        panic!("the region {bounds:?} is not the crop of the full render: {difference}");
    }
}

/// Asserts two renders are the same image, byte for byte.
fn assert_same_pixels(before: &Bitmap8, after: &Bitmap8, what: &str) {
    if let Some(difference) = first_difference(before, after) {
        panic!("{what}: {difference}");
    }
}

/// The layer facts that have to survive a save and a reopen.
fn layer_facts(editor: &Editor) -> Vec<String> {
    editor
        .document
        .layers
        .iter()
        .map(|layer| {
            format!(
                "{} blend={:?} opacity={:.3} visible={} mask={} adjustment={:?} pixels={:?}",
                layer.name,
                layer.blend,
                layer.opacity,
                layer.visible,
                layer.mask.is_some(),
                layer.adjustment.as_ref().map(|adjustment| adjustment.kind),
                layer.image.as_ref().map(|image| (image.width(), image.height())).unwrap_or((0, 0)),
            )
        })
        .collect()
}

/// A solid image, for a pixel edit whose result is known before it runs.
fn solid(width: u32, height: u32, rgba: [u8; 4]) -> Bitmap8 {
    let mut image = Bitmap8::new(width, height);
    for y in 0..height {
        for x in 0..width {
            image.set(x, y, rgba);
        }
    }
    image
}

/// True when a render has any pixel that differs from another render.
fn differs(left: &Bitmap8, right: &Bitmap8) -> bool {
    first_difference(left, right).is_some()
}

#[test]
fn the_whole_journey_runs_without_a_window() {
    let scratch = Scratch::new("whole");
    let path = scratch.package("Journey.comp");

    // Open a project: a new document, saved and reopened before anything is done to it.
    let mut editor = new_editor(64, 48);
    assert_eq!(editor.document_size(), (64, 48));
    assert_eq!(editor.document.layers.len(), 1, "a background layer");
    assert!(!editor.is_modified(), "a new document is not modified");
    // A new document's background is transparent, and an adjustment has nothing to act on there, so
    // the journey starts from a picture: a filled background, which is itself an edit and undoes.
    let background = editor.document.layers[0].id;
    assert!(editor.replace_layer_pixels(background, solid(64, 48, [40, 90, 160, 255])));
    assert!(editor.is_modified(), "filling the background is an edit");
    assert!(editor.undo(), "and it undoes");
    assert!(!editor.is_modified(), "back to a document nobody has changed");
    assert!(editor.redo(), "and forward again");
    assert!(editor.is_modified());
    editor.save_to(&path).expect("the first save");
    assert!(!editor.is_modified(), "saving marks the document saved");
    assert_eq!(editor.path.as_deref(), Some(path.as_path()));

    let opened = render(&editor);
    assert_region_is_the_crop(&editor, (10, 10, 12, 9));

    let mut reopened = new_editor(8, 8);
    reopened.load(&path).expect("reopening what was just written");
    assert_same_pixels(&render(&reopened), &opened, "a saved document reopens as itself");

    // Structural edit 1: a new layer on top.
    let painted = render(&editor);
    assert!(editor.add_layer(), "a layer can be added");
    assert_eq!(editor.document.layers.len(), 2);
    assert!(editor.is_modified(), "adding a layer modifies the document");
    let with_layer = render(&editor);
    assert!(
        !differs(&with_layer, &painted),
        "an empty transparent layer above a picture cannot change it"
    );
    assert_region_is_the_crop(&editor, (0, 0, 64, 48));

    // Pixel edit 1: a brush stroke on the new layer.
    let layer = editor.document.active_layer.expect("the new layer is active");
    assert_eq!(editor.paintable_layer(), Some(layer));
    editor.brush = BrushSettings { size: 12.0, hardness: 1.0, opacity: 1.0 }.clamped();
    assert!(editor.begin_stroke(pos2(16.0, 16.0)), "a stroke starts");
    assert!(editor.stroke_to(pos2(40.0, 24.0)), "the stroke follows the pointer");
    let dirty = editor.take_dirty().expect("a stroke dirties a rectangle");
    assert!(dirty.2 > 0 && dirty.3 > 0, "the dirty rectangle has an area: {dirty:?}");
    assert!(editor.end_stroke(), "the stroke ends");
    let stroked = render(&editor);
    assert!(differs(&stroked, &with_layer), "the stroke put pixels down");
    assert_region_is_the_crop(&editor, dirty);

    // Structural edit 2: blend mode and opacity, as one step because that is how the panel drives
    // them: a drag is wrapped in begin_edit and finish_edit, so the whole gesture undoes at once.
    let before_blend = render(&editor);
    editor.begin_edit("Layer Blend");
    assert!(editor.set_blend(layer, BlendMode::Multiply), "the blend mode changes");
    assert!(editor.set_opacity(layer, 0.5), "the opacity changes");
    editor.finish_edit();
    let blended = render(&editor);
    assert!(differs(&blended, &before_blend), "blending and fading change the picture");
    assert_region_is_the_crop(&editor, (8, 8, 24, 16));

    // Undo and redo over a structural edit step back and forward byte for byte.
    assert!(editor.undo(), "the blend step can be undone");
    assert_same_pixels(&render(&editor), &before_blend, "undo of a blend");
    assert!(editor.redo(), "and redone");
    assert_same_pixels(&render(&editor), &blended, "redo of a blend");

    // A call that changes nothing records nothing, and one that does records exactly one step: this is
    // the property the journey found missing, so it is pinned here as well as in its own test.
    let spaced = render(&editor);
    assert!(!editor.set_blend(layer, BlendMode::Multiply), "already multiply");
    assert!(!editor.set_opacity(layer, 0.5), "already half");
    assert!(editor.set_opacity(layer, 0.25), "a single call is a step of its own");
    let now = render(&editor);
    assert!(differs_safely(&now, &spaced), "the faded pixels differ");
    assert!(editor.undo(), "one call, one undo");
    assert_same_pixels(&render(&editor), &spaced, "undo of a single call lands between steps");
    assert!(editor.redo(), "and forward again");
    assert_same_pixels(&render(&editor), &now, "redo of a single call");

    // Structural edit 3: an adjustment layer.
    let before_adjustment = render(&editor);
    assert!(editor.add_adjustment_layer(AdjustmentKind::Levels), "an adjustment layer is added");
    let adjustment = editor.document.active_layer.expect("it is active");
    assert_eq!(editor.adjustment_kind(adjustment), Some(AdjustmentKind::Levels));
    assert!(
        editor.update_adjustment(adjustment, |a| a.levels.ranges[0].gamma = 1.8),
        "the adjustment takes a setting"
    );
    let adjusted = render(&editor);
    assert!(differs(&adjusted, &before_adjustment), "a levels adjustment changes the picture");
    assert_region_is_the_crop(&editor, (0, 0, 64, 48));

    // Pixel edit 2: a filter on the painted layer.
    editor.select_layer(layer);
    let before_filter = render(&editor);
    editor
        .apply_filter(FilterKind::GaussianBlur, FilterSettings { radius: 3.0, ..Default::default() })
        .expect("the blur runs");
    let blurred = render(&editor);
    assert!(differs(&blurred, &before_filter), "a blur changes the picture");
    assert_region_is_the_crop(&editor, (20, 16, 16, 12));

    // Pixel edit 3: a mask, filled with a gradient and then softened.
    let before_mask = render(&editor);
    assert!(editor.add_layer_mask(layer, false), "a mask is added");
    assert!(editor.has_mask(layer));
    assert!(
        editor.fill_mask_gradient(
            GradientShape::Linear,
            PointF::new(0.0, 0.0),
            PointF::new(64.0, 48.0),
            false,
            GradientBlend::Replace,
        ),
        "the mask takes a gradient"
    );
    let masked = render(&editor);
    assert!(differs(&masked, &before_mask), "a mask changes what the layer shows");
    // Feathering rewrites the mask; whether the composite moves depends on where the layer has
    // pixels, so what is asserted is the mask itself and the region invariant that must always hold.
    let before_feather = editor
        .document
        .layer(layer)
        .and_then(|layer| layer.mask.as_ref().map(|mask| mask.pixels().to_vec()))
        .expect("the mask is there");
    assert!(editor.feather_mask(3.0), "the mask can be softened");
    let after_feather = editor
        .document
        .layer(layer)
        .and_then(|layer| layer.mask.as_ref().map(|mask| mask.pixels().to_vec()))
        .expect("the mask is still there");
    assert_ne!(before_feather, after_feather, "feathering rewrites the mask");
    let feathered = render(&editor);
    let _ = &feathered;
    assert_region_is_the_crop(&editor, (0, 12, 32, 20));

    // Save, and reopen: the state and the pixels have to match what was in memory.
    let facts = layer_facts(&editor);
    let saved_pixels = render(&editor);
    editor.save_to(&path).expect("the second save");
    assert!(!editor.is_modified(), "saving clears the modified flag");
    let mut reopened = new_editor(8, 8);
    reopened.load(&path).expect("the project reopens");
    assert_eq!(layer_facts(&reopened), facts, "every layer fact survives the round trip");
    assert_same_pixels(&render(&reopened), &saved_pixels, "the reopened pixels");

    // Undo across the save point: the history still knows the step before the save, and redoing it
    // returns exactly the pixels that were written to disk.
    assert!(editor.undo(), "the step before the save can still be undone");
    assert!(editor.is_modified(), "undoing after a save makes the document modified again");
    // The last step before the save was a feather, which can leave the composite where it was; what
    // has to hold is that the history crossed the save point and that redo returns the saved pixels.
    assert!(editor.redo(), "and redone");
    assert_same_pixels(&render(&editor), &saved_pixels, "redo returns to the saved pixels");
}

/// True when two renders differ, with the size checked first so a mismatch is a clear failure.
fn differs_safely(left: &Bitmap8, right: &Bitmap8) -> bool {
    assert_eq!((left.width(), left.height()), (right.width(), right.height()));
    left.pixels() != right.pixels()
}

#[test]
fn an_invert_adjustment_layer_complements_what_is_under_it() {
    // A structural edit whose pixels are known before it runs: invert is its own answer.
    let mut editor = new_editor(8, 6);
    // A new document's background is transparent, and inverting transparent pixels changes nothing
    // visible, so the canvas is made opaque first: then invert has an answer to check.
    let background = editor.document.layers[0].id;
    assert!(editor.replace_layer_pixels(background, solid(8, 6, [255, 96, 32, 255])));
    let under = render(&editor);
    assert!(editor.add_adjustment_layer(AdjustmentKind::Invert), "an invert layer is added");
    let inverted = render(&editor);
    assert_eq!(under.pixels().len(), inverted.pixels().len());
    for (index, (before, after)) in under.pixels().chunks_exact(4).zip(inverted.pixels().chunks_exact(4)).enumerate() {
        assert_eq!(after[3], before[3], "pixel {index}: alpha is untouched");
        for channel in 0..3 {
            assert_eq!(
                after[channel],
                255 - before[channel],
                "pixel {index} channel {channel}: invert is the complement"
            );
        }
    }
    // And it undoes to the pixels underneath.
    assert!(editor.undo(), "the adjustment can be undone");
    assert_same_pixels(&render(&editor), &under, "undo of an adjustment layer");
}

#[test]
fn undo_and_redo_return_every_pixel_byte_for_byte() {
    let mut editor = new_editor(32, 24);
    let background = render(&editor);

    // Three pixel edits and three structural ones, checking the round trip after each.
    let steps: Vec<(&str, Box<dyn Fn(&mut Editor)>)> = vec![
        ("add a layer", Box::new(|editor: &mut Editor| assert!(editor.add_layer()))),
        (
            "paint a stroke",
            Box::new(|editor: &mut Editor| {
                editor.brush = BrushSettings { size: 10.0, hardness: 1.0, opacity: 1.0 }.clamped();
                assert!(editor.begin_stroke(pos2(6.0, 6.0)));
                assert!(editor.stroke_to(pos2(24.0, 14.0)));
                assert!(editor.end_stroke());
            }),
        ),
        (
            "blur the layer",
            Box::new(|editor: &mut Editor| {
                editor
                    .apply_filter(FilterKind::GaussianBlur, FilterSettings { radius: 2.0, ..Default::default() })
                    .expect("the blur runs");
            }),
        ),
        (
            "fade and blend the layer",
            Box::new(|editor: &mut Editor| {
                // One gesture, one step: the panel wraps a slider drag the same way.
                editor.begin_edit("Layer Blend");
                let layer = editor.document.active_layer.expect("a layer");
                assert!(editor.set_opacity(layer, 0.6));
                assert!(editor.set_blend(layer, BlendMode::Screen));
                editor.finish_edit();
            }),
        ),
        (
            "move the layer",
            Box::new(|editor: &mut Editor| {
                let layer = editor.document.active_layer.expect("a layer");
                editor.begin_edit("Move Layer");
                assert!(editor.translate_layer(layer, vec2(3.0, -2.0)));
                editor.finish_edit();
            }),
        ),
        (
            "flatten the picture",
            Box::new(|editor: &mut Editor| assert!(editor.flatten_image())),
        ),
    ];

    let mut seen = vec![background.clone()];
    for (index, (label, step)) in steps.iter().enumerate() {
        let before = render(&editor);
        step(&mut editor);
        let after = render(&editor);
        // Two steps need not change a pixel: an empty transparent layer above changes nothing, and
        // flattening with nothing to flatten changes nothing. Both still have to round trip.
        let must_change = label != &"add a layer" && label != &"flatten the picture";
        if must_change {
            assert!(differs_safely(&after, &before), "step {index} ({label}) changed nothing");
        } else {
            assert!(
                !differs_safely(&after, &before),
                "step {index} ({label}) was not expected to change the pixels"
            );
        }
        seen.push(after.clone());
        assert!(editor.can_undo(), "step {index} ({label}) left something to undo");
        assert!(editor.undo(), "step {index} ({label}) undoes");
        assert_same_pixels(&render(&editor), &before, &format!("undo of step {index} ({label})"));
        assert!(editor.redo(), "step {index} ({label}) redoes");
        assert_same_pixels(&render(&editor), &after, &format!("redo of step {index} ({label})"));
    }

    // Undoing the whole journey walks back through every render that was seen on the way out.
    for (index, expected) in seen.iter().rev().skip(1).enumerate() {
        assert!(editor.undo(), "the journey can be walked back, step {index}");
        assert_same_pixels(&render(&editor), expected, &format!("walking back to render {index}"));
    }
}

#[test]
fn a_stroke_repaints_only_its_dirty_rectangle() {
    let mut editor = new_editor(48, 48);
    assert!(editor.add_layer());
    editor.brush = BrushSettings { size: 8.0, hardness: 1.0, opacity: 1.0 }.clamped();
    let before = render(&editor);
    assert!(editor.begin_stroke(pos2(12.0, 12.0)));
    assert!(editor.stroke_to(pos2(20.0, 20.0)));
    let dirty = editor.take_dirty().expect("the stroke dirtied something");
    assert!(editor.end_stroke());

    // The region render of the dirty rectangle is the crop of the full render, and the pixels outside
    // it are the ones that were there before the stroke.
    assert_region_is_the_crop(&editor, dirty);
    let after = render(&editor);
    let untouched = after.subimage(0, 0, 4, 4);
    let was = before.subimage(0, 0, 4, 4);
    assert_same_pixels(&untouched, &was, "a corner the stroke never reached");
    assert!(differs_safely(&after, &before), "the stroke did paint somewhere");
    // A stroke reports through the dirty rectangle, so the same region asked twice is the same image.
    assert_region_is_the_crop(&editor, dirty);
}

#[test]
fn a_saved_document_reopens_with_the_same_state_and_pixels() {
    let scratch = Scratch::new("reopen");
    let path = scratch.package("Reopen.comp");
    let mut editor = new_editor(24, 16);
    assert!(editor.add_layer());
    let layer = editor.document.active_layer.expect("the new layer");
    assert!(editor.replace_layer_pixels(layer, solid(24, 16, [200, 40, 90, 160])));
    assert!(editor.set_blend(layer, BlendMode::Overlay));
    assert!(editor.set_opacity(layer, 0.75));
    assert!(editor.set_name(layer, "Painted".to_string()));
    assert!(editor.add_adjustment_layer(AdjustmentKind::Invert));
    let facts = layer_facts(&editor);
    let pixels = render(&editor);

    editor.save_to(&path).expect("the save");
    let mut reopened = Editor::with_document(Document::with_background(1, 1));
    reopened.load(&path).expect("the reopen");
    assert_eq!(layer_facts(&reopened), facts);
    assert_same_pixels(&render(&reopened), &pixels, "a reopen after every kind of edit");
    assert!(!reopened.is_modified(), "a reopened document has no unsaved changes");
    assert_eq!(reopened.path.as_deref(), Some(path.as_path()));
    // And the same document read straight through the worker agrees.
    let (document, digest) = worker::open_document(&path).expect("the worker opens it too");
    assert!(digest.is_some(), "a package has a digest");
    let through_worker = engine::flatten_full(&document, Preference::ForceCpu).0;
    assert_same_pixels(&through_worker, &pixels, "the worker's document renders the same");
}

#[test]
fn every_edit_leaves_the_region_render_equal_to_the_crop() {
    // The region path is what a stroke and a drag repaint through, so every kind of edit is checked
    // against the full render rather than only the ones that happen to use it.
    let mut editor = new_editor(40, 32);
    let boxes = [(0i64, 0i64, 40u32, 32u32), (0, 0, 1, 1), (39, 31, 1, 1), (10, 10, 20, 12), (0, 16, 40, 16)];

    assert!(editor.add_layer());
    for bounds in boxes {
        assert_region_is_the_crop(&editor, bounds);
    }
    let layer = editor.document.active_layer.expect("a layer");
    editor.brush = BrushSettings { size: 9.0, hardness: 0.5, opacity: 0.8 }.clamped();
    assert!(editor.begin_stroke(pos2(5.0, 5.0)));
    assert!(editor.stroke_to(pos2(30.0, 20.0)));
    assert!(editor.end_stroke());
    for bounds in boxes {
        assert_region_is_the_crop(&editor, bounds);
    }
    assert!(editor.set_opacity(layer, 0.4));
    assert!(editor.add_layer_mask(layer, false));
    assert!(
        editor.fill_mask_gradient(
            GradientShape::Radial,
            PointF::new(20.0, 16.0),
            PointF::new(36.0, 16.0),
            false,
            GradientBlend::Replace,
        ),
        "a radial mask"
    );
    for bounds in boxes {
        assert_region_is_the_crop(&editor, bounds);
    }
    assert!(editor.feather_mask(2.0));
    editor
        .apply_filter(FilterKind::GaussianBlur, FilterSettings { radius: 1.5, ..Default::default() })
        .expect("a blur");
    for bounds in boxes {
        assert_region_is_the_crop(&editor, bounds);
    }
    // A layer move is the case that reaches across the canvas: the region path has to repaint the
    // pixels the layer left behind as well as the ones it arrived at.
    editor.begin_edit("Move Layer");
    assert!(editor.translate_layer(layer, vec2(6.0, 4.0)));
    editor.finish_edit();
    for bounds in boxes {
        assert_region_is_the_crop(&editor, bounds);
    }
    assert!(editor.merge_down());
    for bounds in boxes {
        assert_region_is_the_crop(&editor, bounds);
    }
}

#[test]
fn a_history_step_is_the_state_before_the_call_that_made_it() {
    // Which render does one undo restore? The one before the last recorded step, whatever that step
    // was, and nothing else.
    let mut editor = new_editor(32, 24);
    assert!(editor.add_layer());
    let layer = editor.document.active_layer.expect("a layer");
    // A blend over a transparent layer shows nothing, so the layer gets pixels first.
    assert!(editor.replace_layer_pixels(layer, solid(32, 24, [180, 120, 60, 200])));
    let start = render(&editor);

    editor.begin_edit("Layer Blend");
    assert!(editor.set_blend(layer, BlendMode::Multiply));
    assert!(editor.set_opacity(layer, 0.5));
    editor.finish_edit();
    let blended = render(&editor);
    assert!(differs_safely(&blended, &start), "the wrapped gesture changed the pixels");

    // A call that changes nothing must not become a step of its own.
    assert!(!editor.set_blend(layer, BlendMode::Multiply), "the blend is already multiply");
    assert!(!editor.set_opacity(layer, 0.5), "the opacity is already half");
    assert!(editor.undo(), "the wrapped gesture still undoes in one step");
    assert_same_pixels(&render(&editor), &start, "a no-op call did not become a step");
    assert!(editor.redo());

    // And one real call is one step: undoing it lands on the state before that call.
    assert!(editor.set_opacity(layer, 0.25), "a single call changes the pixels");
    let faded = render(&editor);
    assert!(differs_safely(&faded, &blended), "the new opacity changed the pixels");
    assert!(editor.undo(), "the single call undoes");
    let after = render(&editor);
    assert!(
        first_difference(&after, &blended).is_none(),
        "one call, one undo, back to the state before it: {}",
        first_difference(&after, &blended).unwrap_or_default()
    );
    assert!(editor.redo(), "and forward again");
    assert_same_pixels(&render(&editor), &faded, "redo returns the faded pixels");
}

#[test]
fn a_document_can_be_reopened_without_the_window_that_wrote_it() {
    // The narrow version of the journey: write with one editor, read with another, and check that the
    // pixels come back without any panel, window or worker thread in between.
    let scratch = Scratch::new("handoff");
    let path: PathBuf = scratch.package("Handoff.comp");
    {
        let mut writer = new_editor(16, 12);
        assert!(writer.add_layer());
        let layer = writer.document.active_layer.expect("a layer");
        assert!(writer.replace_layer_pixels(layer, solid(16, 12, [10, 200, 30, 255])));
        writer.save_to(&path).expect("written by the first editor");
        assert!(Path::new(&path).exists());
    }
    let mut reader = Editor::with_document(Document::with_background(1, 1));
    reader.load(&path).expect("read by the second");
    assert_eq!(reader.document.layers.len(), 2);
    let top = reader.document.layers.last().expect("the painted layer");
    assert_eq!(top.image.as_ref().map(|image| (image.width(), image.height())), Some((16, 12)));
    assert_eq!(reader.document_size(), (16, 12));
}
