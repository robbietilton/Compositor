//! Format round trips across versions 1 to 11, one feature group at a time.
//!
//! Every test here writes the package by hand, loads it, saves it through the crate and loads the
//! result again: what the format stores must survive both directions, and a save must upgrade an
//! old package to the current version without losing anything the old version could hold.
mod common;

use std::sync::Arc;

use common::*;
use uuid::Uuid;

use comp_core::adjustment::{Adjustment, AdjustmentKind, Channel, ColorBalanceSettings, CurvePoint};
use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::blend::BlendMode;
use comp_core::effects::{ColorOverlayEffect, InnerGlowEffect, InnerShadowEffect, LayerEffects, OuterGlowEffect, ShadowEffect, StrokeEffect};
use comp_core::geom::{GuideAxis, PointF, SizeF, Transform};
use comp_core::layer::Layer;
use comp_core::shape::{ShapeKind, ShapeStyle};
use comp_core::store;
use comp_core::text::{TextAlignment, TextColorRun, TextFontRun, TextStyle};

/// A curves adjustment with a real shape, so an identity default cannot pass for it.
fn curves() -> Adjustment {
    let mut adjustment = Adjustment::new(AdjustmentKind::Curves);
    adjustment.curves.channel = Channel::Red;
    adjustment.curves.channels[1] = vec![
        CurvePoint { x: 0.0, y: 8.0 },
        CurvePoint { x: 120.0, y: 147.0 },
        CurvePoint { x: 255.0, y: 250.0 },
    ];
    adjustment
}

fn text_style() -> TextStyle {
    TextStyle {
        content: "Hello Comp".to_string(),
        font_name: "Helvetica".to_string(),
        font_size: 24.0,
        red: 0.1,
        green: 0.2,
        blue: 0.3,
        alignment: TextAlignment::Center,
        tracking: 1.5,
        leading: 30.0,
        box_size: Some(comp_core::text::SizeD { width: 200.0, height: 80.0 }),
        color_runs: Some(vec![TextColorRun { location: 0, length: 5, red: 1.0, green: 0.0, blue: 0.0 }]),
        font_runs: Some(vec![TextFontRun { location: 6, length: 4, font_name: "Georgia-Bold".to_string() }]),
    }
}

#[test]
fn version_one_packages_roundtrip_and_upgrade_on_save() {
    let tree = TempTree::new("v1");
    let package = tree.package("Old");
    let id = Uuid::new_v4();
    let pixels = noisy(6, 4, 11);
    let mut layer = record(id, "Background", 6.0, 4.0);
    layer.is_visible = false;
    write_package(&package, &manifest(1, 6, 4, vec![layer]), &[(asset_name(id), image_bytes(&pixels))]);

    let document = store::load(&package).unwrap();
    assert_eq!(document.version, 1);
    assert_eq!((document.width, document.height), (6, 4));
    // Fields a version-1 record never stored come back at their defaults.
    assert!(!document.layers[0].visible);
    assert_eq!(document.layers[0].opacity, 1.0);
    assert_eq!(document.layers[0].blend, BlendMode::Normal);
    assert!(!document.layers[0].is_group);
    assert!(document.layers[0].mask.is_none());
    assert_eq!(document.layers[0].image.as_deref(), Some(&pixels));

    // Saving writes the current version, exactly as the macOS app does.
    let upgraded = tree.package("Upgraded");
    store::save(&document, &upgraded).unwrap();
    let reloaded = store::load(&upgraded).unwrap();
    assert_eq!(reloaded.version, 11);
    assert_eq!(reloaded.layers[0].name, "Background");
    assert_eq!(reloaded.layers[0].image.as_deref(), Some(&pixels));
    assert!(!reloaded.layers[0].visible);
}

#[test]
fn version_three_packages_keep_opacity_and_blend() {
    let tree = TempTree::new("v3");
    let package = tree.package("Old");
    let id = Uuid::new_v4();
    let pixels = Bitmap8::filled(4, 4, [40, 50, 60, 255]);
    let mut layer = record(id, "Screen", 4.0, 4.0);
    layer.opacity = Some(0.25);
    layer.blend_mode = Some(BlendMode::Screen);
    write_package(&package, &manifest(3, 4, 4, vec![layer]), &[(asset_name(id), image_bytes(&pixels))]);

    let document = store::load(&package).unwrap();
    assert_eq!(document.version, 3);
    assert_eq!(document.layers[0].opacity, 0.25);
    assert_eq!(document.layers[0].blend, BlendMode::Screen);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layers[0].opacity, 0.25);
    assert_eq!(reloaded.layers[0].blend, BlendMode::Screen);
}

#[test]
fn version_seven_packages_keep_adjustment_layers() {
    let tree = TempTree::new("v7");
    let package = tree.package("Old");
    let base = Uuid::new_v4();
    let grade = Uuid::new_v4();
    let pixels = Bitmap8::filled(8, 8, [200, 100, 50, 255]);
    let mut adjustment = record(grade, "Warm Grade", 8.0, 8.0);
    adjustment.image_file = None;
    adjustment.adjustment = Some(curves());
    let layers = vec![record(base, "Base", 8.0, 8.0), adjustment];
    write_package(&package, &manifest(7, 8, 8, layers), &[(asset_name(base), image_bytes(&pixels))]);

    let document = store::load(&package).unwrap();
    assert_eq!(document.version, 7);
    assert_eq!(document.layers.len(), 2);
    assert!(document.layers[1].image.is_none());
    assert_eq!(document.layers[1].adjustment.as_ref().unwrap().kind, AdjustmentKind::Curves);
    assert_eq!(document.layers[1].adjustment.as_ref().unwrap().curves.channels[1][1].y, 147.0);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layers[1].adjustment, document.layers[1].adjustment);
    assert_eq!(reloaded.layers[0].image.as_deref(), Some(&pixels));
}

#[test]
fn version_nine_packages_keep_neighbor_sampling_adjustments() {
    let tree = TempTree::new("v9");
    let package = tree.package("Old");
    let base = Uuid::new_v4();
    let mut blur = record(Uuid::new_v4(), "Blur", 8.0, 8.0);
    blur.image_file = None;
    blur.adjustment = Some(Adjustment { blur_radius: Some(12.5), ..Adjustment::new(AdjustmentKind::GaussianBlur) });
    let mut motion = record(Uuid::new_v4(), "Motion", 8.0, 8.0);
    motion.image_file = None;
    motion.adjustment = Some(Adjustment {
        motion_angle: Some(-30.0),
        motion_distance: Some(250.0),
        ..Adjustment::new(AdjustmentKind::MotionBlur)
    });
    let mut noise = record(Uuid::new_v4(), "Noise", 8.0, 8.0);
    noise.image_file = None;
    noise.adjustment = Some(Adjustment {
        noise_amount: Some(40.0),
        noise_gaussian: Some(true),
        noise_monochromatic: Some(false),
        noise_seed: Some(12_345),
        ..Adjustment::new(AdjustmentKind::AddNoise)
    });
    let mut balance = record(Uuid::new_v4(), "Balance", 8.0, 8.0);
    balance.image_file = None;
    balance.adjustment = Some(Adjustment {
        color_balance_settings: Some(ColorBalanceSettings {
            mid_cyan_red: 22.0,
            highlight_yellow_blue: -14.0,
            preserve_luminosity: false,
            ..ColorBalanceSettings::default()
        }),
        ..Adjustment::new(AdjustmentKind::ColorBalance)
    });
    let layers = vec![
        record(base, "Base", 8.0, 8.0),
        blur,
        motion,
        noise,
        balance,
    ];
    write_package(&package, &manifest(9, 8, 8, layers), &[(asset_name(base), image_bytes(&Bitmap8::new(8, 8)))]);

    let document = store::load(&package).unwrap();
    let kinds: Vec<_> = document
        .layers
        .iter()
        .filter_map(|layer| layer.adjustment.as_ref().map(|a| a.kind))
        .collect();
    assert_eq!(kinds, vec![AdjustmentKind::GaussianBlur, AdjustmentKind::MotionBlur, AdjustmentKind::AddNoise, AdjustmentKind::ColorBalance]);
    let blur_settings = document.layers[1].adjustment.clone().unwrap();
    assert_eq!(blur_settings.blur_radius, Some(12.5));
    let noise_settings = document.layers[3].adjustment.clone().unwrap();
    assert_eq!(noise_settings.noise_seed, Some(12_345));
    assert_eq!(noise_settings.noise_monochromatic, Some(false));
    let balance_settings = document.layers[4].adjustment.clone().unwrap();
    assert_eq!(balance_settings.color_balance_settings.unwrap().mid_cyan_red, 22.0);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    for (before, after) in document.layers.iter().zip(reloaded.layers.iter()) {
        assert_eq!(before.adjustment, after.adjustment);
    }
}

#[test]
fn groups_and_folder_masks_roundtrip() {
    let tree = TempTree::new("groups");
    let package = tree.package("Folder");
    let folder = Uuid::new_v4();
    let inner = Uuid::new_v4();
    let outer = Uuid::new_v4();
    let folder_mask = ramp(8, 8);
    let mut group = group_record(folder, "Folder", 8.0, 8.0);
    group.opacity = Some(0.5);
    group.mask_file = Some(mask_name(folder));
    group.mask_enabled = Some(true);
    let mut child = record(inner, "Inner", 8.0, 8.0);
    child.parent_id = Some(folder);
    let layers = vec![record(outer, "Outer", 8.0, 8.0), group, child];
    let assets = vec![
        (asset_name(outer), image_bytes(&Bitmap8::filled(8, 8, [1, 1, 1, 255]))),
        (asset_name(inner), image_bytes(&Bitmap8::filled(8, 8, [2, 2, 2, 255]))),
        (mask_name(folder), mask_bytes(&folder_mask)),
    ];
    write_package(&package, &manifest(8, 8, 8, layers), &assets);

    let document = store::load(&package).unwrap();
    let loaded_group = document.layer(folder).unwrap();
    assert!(loaded_group.is_group);
    assert_eq!(loaded_group.opacity, 0.5);
    assert_eq!(loaded_group.mask.as_deref(), Some(&folder_mask));
    assert_eq!(loaded_group.blend, BlendMode::Normal);
    // The group's subtree stays contiguous and its opacity multiplies into the child.
    assert_eq!(document.subtree_indices(folder), vec![1, 2]);
    assert_eq!(document.effective_opacity(inner), 0.5);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert!(reloaded.layer(folder).unwrap().is_group);
    assert_eq!(reloaded.layer(folder).unwrap().mask.as_deref(), Some(&folder_mask));
    assert_eq!(reloaded.layer(inner).unwrap().parent, Some(folder));
    assert_eq!(reloaded.effective_opacity(inner), 0.5);
}

#[test]
fn clipping_masks_roundtrip() {
    let tree = TempTree::new("clipping");
    let package = tree.package("Clip");
    let base = Uuid::new_v4();
    let clipped = Uuid::new_v4();
    let mut link = record(clipped, "Clipped", 8.0, 8.0);
    link.mask_source_id = Some(base);
    let layers = vec![record(base, "Base", 8.0, 8.0), link];
    let assets = vec![
        (asset_name(base), image_bytes(&Bitmap8::filled(8, 8, [9, 9, 9, 255]))),
        (asset_name(clipped), image_bytes(&Bitmap8::filled(8, 8, [3, 3, 3, 255]))),
    ];
    write_package(&package, &manifest(5, 8, 8, layers), &assets);

    let document = store::load(&package).unwrap();
    assert_eq!(document.layer(clipped).unwrap().mask_source, Some(base));
    assert_eq!(document.layer(base).unwrap().mask_source, None);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layer(clipped).unwrap().mask_source, Some(base));
}

#[test]
fn guides_keep_their_ids_axes_and_positions() {
    let tree = TempTree::new("guides");
    let package = tree.package("Guides");
    let id = Uuid::new_v4();
    let horizontal = guide(GuideAxis::Horizontal, 42.5);
    let vertical = guide(GuideAxis::Vertical, -18.0);
    let mut manifest = manifest(8, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    manifest.guides = Some(vec![horizontal.clone(), vertical.clone()]);
    write_package(&package, &manifest, &[(asset_name(id), image_bytes(&Bitmap8::new(8, 8)))]);

    let document = store::load(&package).unwrap();
    assert_eq!(document.guides, vec![horizontal, vertical]);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.guides, document.guides);
}

#[test]
fn layer_effects_roundtrip_including_hidden_ones() {
    let tree = TempTree::new("effects");
    let package = tree.package("Effects");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Decorated", 8.0, 8.0);
    layer.effects = Some(LayerEffects {
        stroke: Some(StrokeEffect { size: 3.0, red: 1.0, green: 1.0, blue: 1.0, opacity: 0.8, inside: true, ..StrokeEffect::default() }),
        shadow: Some(ShadowEffect { angle: 135.0, distance: 4.0, blur: 8.0, opacity: 0.5, ..ShadowEffect::default() }),
        color_overlay: Some(ColorOverlayEffect { red: 0.2, green: 0.4, blue: 0.6, opacity: 0.9, enabled: Some(false), ..ColorOverlayEffect::default() }),
        inner_shadow: Some(InnerShadowEffect { angle: 45.0, distance: 2.0, blur: 3.0, opacity: 0.3, ..InnerShadowEffect::default() }),
        outer_glow: Some(OuterGlowEffect { size: 12.0, red: 1.0, green: 0.5, blue: 0.0, opacity: 0.7, ..OuterGlowEffect::default() }),
        inner_glow: Some(InnerGlowEffect { size: 6.0, red: 0.0, green: 0.5, blue: 1.0, opacity: 0.4, ..InnerGlowEffect::default() }),
    });
    write_package(&package, &manifest(11, 8, 8, vec![layer.clone()]), &[(asset_name(id), image_bytes(&Bitmap8::new(8, 8)))]);

    let document = store::load(&package).unwrap();
    let effects = document.layers[0].effects.clone().unwrap();
    assert_eq!(effects.stroke.unwrap().size, 3.0);
    assert!(effects.stroke.unwrap().inside);
    assert_eq!(effects.shadow.unwrap().distance, 4.0);
    assert_eq!(effects.color_overlay.unwrap().enabled, Some(false));
    assert_eq!(effects.outer_glow.unwrap().size, 12.0);
    assert_eq!(effects.inner_glow.unwrap().opacity, 0.4);

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layers[0].effects, document.layers[0].effects);
    assert_eq!(reloaded.layers[0].effects, layer.effects);
}

#[test]
fn text_layers_keep_their_runs_and_paragraph_box() {
    let tree = TempTree::new("text");
    let package = tree.package("Text");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Title", 64.0, 32.0);
    layer.text = Some(text_style());
    write_package(&package, &manifest(11, 64, 32, vec![layer]), &[(asset_name(id), image_bytes(&Bitmap8::new(64, 32)))]);

    let document = store::load(&package).unwrap();
    let text = document.layers[0].text.clone().unwrap();
    assert_eq!(text.content, "Hello Comp");
    assert_eq!(text.alignment, TextAlignment::Center);
    assert_eq!(text.box_size.unwrap().width, 200.0);
    let colors = text.color_runs.clone().unwrap();
    assert_eq!(colors[0].red, 1.0);
    assert_eq!(colors[0].length, 5);
    let fonts = text.font_runs.clone().unwrap();
    assert_eq!(fonts[0].font_name, "Georgia-Bold");

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layers[0].text, document.layers[0].text);
}

#[test]
fn shape_layers_keep_their_geometry() {
    let tree = TempTree::new("shape");
    let package = tree.package("Shape");
    let id = Uuid::new_v4();
    let mut layer = record(id, "Line", 40.0, 20.0);
    layer.shape = Some(ShapeStyle {
        kind: ShapeKind::Line,
        red: 0.9,
        green: 0.1,
        blue: 0.1,
        corner_radius: 0.0,
        line_width: Some(3.5),
        start: Some([0.1, 0.2]),
        end: Some([0.8, 0.9]),
    });
    write_package(&package, &manifest(11, 40, 20, vec![layer]), &[(asset_name(id), image_bytes(&Bitmap8::new(40, 20)))]);

    let document = store::load(&package).unwrap();
    let shape = document.layers[0].shape.unwrap();
    assert_eq!(shape.kind, ShapeKind::Line);
    assert_eq!(shape.line_width, Some(3.5));
    assert_eq!(shape.end, Some([0.8, 0.9]));

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layers[0].shape, document.layers[0].shape);
}

#[test]
fn unlinked_masks_keep_their_own_placement() {
    let tree = TempTree::new("unlinked");
    let package = tree.package("Loose");
    let id = Uuid::new_v4();
    let placement = Transform::new(PointF::new(12.0, 7.0), SizeF::new(20.0, 20.0));
    let mut layer = record(id, "Loose Mask", 32.0, 32.0);
    layer.mask_file = Some(mask_name(id));
    layer.mask_enabled = Some(true);
    layer.mask_linked = Some(false);
    layer.mask_placement = Some(placement);
    let mask = ramp(20, 20);
    let assets = vec![(asset_name(id), image_bytes(&Bitmap8::new(32, 32))), (mask_name(id), mask_bytes(&mask))];
    write_package(&package, &manifest(11, 32, 32, vec![layer]), &assets);

    let document = store::load(&package).unwrap();
    assert!(!document.layers[0].mask_linked);
    assert_eq!(document.layers[0].mask_placement, Some(placement));
    assert_eq!(document.layers[0].mask.as_deref(), Some(&mask));
    assert_eq!(document.layers[0].effective_mask_transform(), Some(placement));

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert!(!reloaded.layers[0].mask_linked);
    assert_eq!(reloaded.layers[0].mask_placement, Some(placement));
}

#[test]
fn a_one_by_one_mask_survives_a_save() {
    let tree = TempTree::new("tiny-mask");
    let package = tree.package("Tiny");
    let mut document = comp_core::Document::new(24, 24);
    let mut layer = Layer::raster("Painted", 24, 24);
    layer.image = Some(Arc::new(Bitmap8::filled(24, 24, [7, 8, 9, 255])));
    layer.mask = Some(Arc::new(Gray8::filled(1, 1, 0)));
    document.add_layer(layer, None);
    store::save(&document, &package).unwrap();

    let loaded = store::load(&package).unwrap();
    let mask = loaded.layers[0].mask.as_ref().unwrap();
    assert_eq!((mask.width(), mask.height()), (1, 1));
    assert_eq!(mask.get(0, 0), 0);
}

#[test]
fn pixels_and_mask_samples_survive_byte_for_byte() {
    let tree = TempTree::new("pixels");
    let package = tree.package("Noise");
    let mut document = comp_core::Document::new(37, 23);
    let image = noisy(37, 23, 7);
    let mask = ramp(37, 23);
    let mut layer = Layer::raster("Noise", 37, 23);
    layer.image = Some(Arc::new(image.clone()));
    layer.mask = Some(Arc::new(mask.clone()));
    let id = document.add_layer(layer, None);
    store::save(&document, &package).unwrap();

    let loaded = store::load(&package).unwrap();
    let restored = loaded.layer(id).unwrap();
    assert_eq!(restored.image.as_ref().unwrap().pixels(), image.pixels());
    assert_eq!(restored.mask.as_ref().unwrap().pixels(), mask.pixels());

    let again = tree.package("Again");
    store::save(&loaded, &again).unwrap();
    let reloaded = store::load(&again).unwrap();
    assert_eq!(reloaded.layer(id).unwrap().image.as_ref().unwrap().pixels(), image.pixels());
    assert_eq!(reloaded.layer(id).unwrap().mask.as_ref().unwrap().pixels(), mask.pixels());
}

#[test]
fn resolution_survives_and_older_packages_default_to_72() {
    let tree = TempTree::new("resolution");
    let id = Uuid::new_v4();
    let mut with_resolution = manifest(11, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    with_resolution.resolution = Some(300.0);
    let package = tree.package("Print");
    write_package(&package, &with_resolution, &[(asset_name(id), image_bytes(&Bitmap8::new(8, 8)))]);
    assert_eq!(store::load(&package).unwrap().resolution, 300.0);

    let mut without = manifest(1, 8, 8, vec![record(id, "Base", 8.0, 8.0)]);
    without.resolution = None;
    let old = tree.package("Old");
    write_package(&old, &without, &[(asset_name(id), image_bytes(&Bitmap8::new(8, 8)))]);
    assert_eq!(store::load(&old).unwrap().resolution, 72.0);
}

#[test]
fn layer_order_active_layer_and_transforms_survive() {
    let tree = TempTree::new("order");
    let package = tree.package("Stack");
    let bottom = Uuid::new_v4();
    let middle = Uuid::new_v4();
    let top = Uuid::new_v4();
    let mut first = record(bottom, "Bottom", 8.0, 8.0);
    first.transform = Transform::new(PointF::new(-2.0, 3.0), SizeF::new(20.0, 10.0));
    first.transform.rotation = 45.0;
    first.transform.flip_x = true;
    let mut second = record(middle, "Middle", 8.0, 8.0);
    second.is_visible = false;
    let third = record(top, "Top", 8.0, 8.0);
    let mut manifest = manifest(11, 8, 8, vec![first, second, third]);
    manifest.active_layer_id = Some(middle);
    write_package(&package, &manifest, &[
        (asset_name(bottom), image_bytes(&Bitmap8::new(8, 8))),
        (asset_name(middle), image_bytes(&Bitmap8::new(8, 8))),
        (asset_name(top), image_bytes(&Bitmap8::new(8, 8))),
    ]);

    let document = store::load(&package).unwrap();
    assert_eq!(document.layers.iter().map(|layer| layer.id).collect::<Vec<_>>(), vec![bottom, middle, top]);
    assert_eq!(document.active_layer, Some(middle));
    assert!(!document.layers[1].visible);
    assert_eq!(document.layers[0].transform.rotation, 45.0);
    assert!(document.layers[0].transform.flip_x);
    assert_eq!(document.layers[0].transform.size, SizeF::new(20.0, 10.0));
}

#[test]
fn unicode_layer_names_survive() {
    let tree = TempTree::new("unicode");
    let package = tree.package("Names");
    let id = Uuid::new_v4();
    let mut layer = record(id, "背景 фон 🌄", 4.0, 4.0);
    layer.is_visible = true;
    write_package(&package, &manifest(11, 4, 4, vec![layer]), &[(asset_name(id), image_bytes(&Bitmap8::new(4, 4)))]);

    let document = store::load(&package).unwrap();
    assert_eq!(document.layers[0].name, "背景 фон 🌄");

    let again = tree.package("Again");
    store::save(&document, &again).unwrap();
    assert_eq!(store::load(&again).unwrap().layers[0].name, "背景 фон 🌄");
}

#[test]
fn creating_a_package_that_already_exists_is_refused() {
    let tree = TempTree::new("fresh");
    let package = tree.package("Once");
    let mut document = comp_core::Document::new(4, 4);
    document.add_layer(Layer::with_image("Base", Bitmap8::filled(4, 4, [1, 2, 3, 255])), None);
    store::create_fresh(&document, &package).unwrap();
    // The second call is about the path, not about the manifest, and says so.
    match store::create_fresh(&document, &package) {
        Err(error @ comp_core::Error::IllegalPath { .. }) => {
            assert_eq!(error.path(), Some(package.to_string_lossy().as_ref()));
            assert_eq!(error.source(), comp_core::ErrorSource::Io);
        }
        other => panic!("expected the path to be refused, got {other:?}"),
    }
    assert_eq!(store::load(&package).unwrap().layers.len(), 1);
}

#[test]
fn a_future_version_is_reported_with_its_number() {
    let tree = TempTree::new("future");
    let package = tree.package("Future");
    let id = Uuid::new_v4();
    let mut manifest = manifest(12, 4, 4, vec![record(id, "Base", 4.0, 4.0)]);
    manifest.version = 12;
    write_package(&package, &manifest, &[(asset_name(id), image_bytes(&Bitmap8::new(4, 4)))]);
    assert!(matches!(store::load(&package), Err(comp_core::Error::UnsupportedVersion(12))));
}

#[test]
fn a_version_eight_package_cannot_hold_a_blur_adjustment() {
    let tree = TempTree::new("gated");
    let package = tree.package("TooNew");
    let base = Uuid::new_v4();
    let mut blur = record(Uuid::new_v4(), "Blur", 4.0, 4.0);
    blur.image_file = None;
    blur.adjustment = Some(Adjustment { blur_radius: Some(4.0), ..Adjustment::new(AdjustmentKind::GaussianBlur) });
    let layers = vec![record(base, "Base", 4.0, 4.0), blur];
    write_package(&package, &manifest(8, 4, 4, layers), &[(asset_name(base), image_bytes(&Bitmap8::new(4, 4)))]);
    // Still refused, and the field says which layer and which part of it.
    match store::load(&package) {
        Err(comp_core::Error::DamagedManifest { field, detail, .. }) => {
            assert_eq!(field.as_deref(), Some("layers[1].adjustment"));
            assert!(detail.contains("version 9"), "{detail}");
        }
        other => panic!("expected the adjustment to be refused, got {other:?}"),
    }
}
