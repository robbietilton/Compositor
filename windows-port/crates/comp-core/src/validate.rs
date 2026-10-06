//! Format validation, following `ProjectStore.validate` in the macOS app.
//!
//! A document that fails any check must never replace the live document.
use std::collections::{HashMap, HashSet};

use uuid::Uuid;

use crate::document::SUPPORTED_VERSIONS;
use crate::error::{Error, Result};
use crate::limits;
use crate::manifest::{LayerRecord, Manifest, COLOR_SPACE, FORMAT_ID};

/// Every check \`load\` and \`save\` run before touching pixels.
///
/// A refusal names the field it is about, in the manifest's own spelling
/// (`layers[2].transform`, `guides[0].position`), so a caller can point at the thing rather than at
/// the file. The set of manifests that pass is exactly what it was before the names were added.
pub fn validate_manifest(manifest: &Manifest) -> Result<()> {
    if manifest.format != FORMAT_ID {
        return Err(Error::manifest(
            "format",
            format!("this build reads {FORMAT_ID}, not {}", manifest.format),
        ));
    }
    if !SUPPORTED_VERSIONS.contains(&manifest.version) {
        return Err(Error::UnsupportedVersion(manifest.version));
    }
    if manifest.color_space != COLOR_SPACE {
        return Err(Error::manifest(
            "colorSpace",
            format!("this build works in {COLOR_SPACE}, not {}", manifest.color_space),
        ));
    }
    if let Some(resolution) = manifest.resolution {
        if !resolution.is_finite() || !(1.0..=9600.0).contains(&resolution) {
            return Err(Error::manifest("resolution", format!("{resolution} is not between 1 and 9600")));
        }
    }
    let side_ok = (1..=limits::MAX_SIDE).contains(&manifest.width)
        && (1..=limits::MAX_SIDE).contains(&manifest.height);
    if !side_ok || manifest.layers.len() > limits::MAX_LAYERS {
        return Err(Error::TooLarge(format!(
            "canvas {}x{} with {} layers",
            manifest.width,
            manifest.height,
            manifest.layers.len()
        )));
    }

    let version = manifest.version;
    for (index, layer) in manifest.layers.iter().enumerate() {
        validate_layer(layer, version, index)?;
    }
    validate_hierarchy(&manifest.layers)?;
    validate_live_mask_graph(&manifest.layers)?;

    for (index, layer) in manifest.layers.iter().enumerate() {
        if version < 5 && layer.mask_source_id.is_some() {
            return Err(Error::manifest(
                format!("layers[{index}].maskSourceID"),
                "live masks arrived in format version 5",
            ));
        }
        if version == 1 && (layer.parent_id.is_some() || layer.is_group == Some(true)) {
            return Err(Error::manifest(
                format!("layers[{index}].parentID"),
                "folders arrived in format version 2",
            ));
        }
    }

    let mut ids = HashSet::new();
    for (index, layer) in manifest.layers.iter().enumerate() {
        if !ids.insert(layer.id) {
            return Err(Error::manifest(format!("layers[{index}].id"), "two layers share this id"));
        }
        if !layer.transform.is_valid() {
            return Err(Error::manifest(
                format!("layers[{index}].transform"),
                "a transform must be finite and carry a size above zero",
            ));
        }
        if layer.name.trim().is_empty() || layer.name.len() > 16_384 {
            return Err(Error::manifest(
                format!("layers[{index}].name"),
                "a layer name must be there and no longer than 16384 bytes",
            ));
        }
        if let Some(file) = &layer.image_file {
            if *file != format!("{}.png", layer.id.to_string().to_uppercase()) {
                return Err(Error::manifest(
                    format!("layers[{index}].imageFile"),
                    format!("an asset is named after its layer, so this must be {}.png", layer.id.to_string().to_uppercase()),
                ));
            }
        }
    }
    if let Some(active) = manifest.active_layer_id {
        if !ids.contains(&active) {
            return Err(Error::manifest(
                "activeLayerID",
                format!("{active} is not one of the document's layers"),
            ));
        }
    }
    validate_guides(manifest)
}

fn validate_layer(layer: &LayerRecord, version: u32, index: usize) -> Result<()> {
    let is_group = layer.is_group.unwrap_or(false);
    let field = |name: &str| format!("layers[{index}].{name}");

    if let Some(text) = &layer.text {
        // Per-letter colors arrived in version 10, per-letter faces in version 11.
        let runs_ok = (text.color_runs.is_none() || version >= 10) && (text.font_runs.is_none() || version >= 11);
        let refusal = if !text.is_valid() {
            Some("the text model is not valid")
        } else if !runs_ok {
            Some("per-letter runs need format version 10, per-letter faces version 11")
        } else if layer.image_file.is_none() {
            Some("a text layer carries the pixels it rendered")
        } else if is_group {
            Some("a folder cannot hold text")
        } else if layer.adjustment.is_some() {
            Some("a layer cannot be text and an adjustment at once")
        } else {
            None
        };
        if let Some(reason) = refusal {
            return Err(Error::manifest(field("text"), reason));
        }
    }

    if let Some(adjustment) = &layer.adjustment {
        let refusal = if version < 7 {
            Some("adjustment layers arrived in format version 7")
        } else if is_group {
            Some("a folder cannot be an adjustment")
        } else if layer.image_file.is_some() {
            Some("an adjustment has no pixels of its own")
        } else if !adjustment.is_valid() {
            Some("the adjustment's parameters are not valid")
        } else if adjustment.kind.samples_neighbors() && version < 9 {
            Some("this adjustment samples its neighbours, which needs format version 9")
        } else {
            None
        };
        if let Some(reason) = refusal {
            return Err(Error::manifest(field("adjustment"), reason));
        }
    }

    // Layer masks arrived in version 4, folder masks in version 6.
    if let Some(mask_file) = &layer.mask_file {
        let minimum = if is_group { 6 } else { 4 };
        let expected = format!("{}.mask.png", layer.id.to_string().to_uppercase());
        let refusal = if version < minimum {
            Some(format!("a mask on this layer arrived in format version {minimum}"))
        } else if *mask_file != expected {
            Some(format!("a mask is named after its layer, so this must be {expected}"))
        } else {
            None
        };
        if let Some(reason) = refusal {
            return Err(Error::manifest(field("maskFile"), reason));
        }
    }
    if layer.mask_enabled.is_some() && layer.mask_file.is_none() {
        return Err(Error::manifest(field("maskEnabled"), "there is no mask for this to enable"));
    }
    if let Some(placement) = layer.mask_placement {
        let refusal = if layer.mask_file.is_none() {
            Some("there is no mask to place")
        } else if !placement.is_valid() {
            Some("a mask placement must be finite")
        } else {
            None
        };
        if let Some(reason) = refusal {
            return Err(Error::manifest(field("maskPlacement"), reason));
        }
    }

    let opacity = layer.opacity.unwrap_or(1.0);
    let blend = layer.blend_mode.unwrap_or_default();
    if !opacity.is_finite() || !(0.0..=1.0).contains(&opacity) {
        return Err(Error::manifest(field("opacity"), format!("{opacity} is not between 0 and 1")));
    }
    if version < 3 && opacity != 1.0 {
        return Err(Error::manifest(field("opacity"), "layer opacity arrived in format version 3"));
    }
    if version < 3 && blend != crate::blend::BlendMode::Normal {
        return Err(Error::manifest(field("blendMode"), "blend modes arrived in format version 3"));
    }
    // Folders took an opacity of their own in version 8; their blend mode stays pass-through.
    if is_group {
        if blend != crate::blend::BlendMode::Normal {
            return Err(Error::manifest(field("blendMode"), "a folder passes its children through unchanged"));
        }
        if version < 8 && opacity != 1.0 {
            return Err(Error::manifest(field("opacity"), "folder opacity arrived in format version 8"));
        }
    }
    if let Some(effects) = &layer.effects {
        if !effects.is_valid() {
            return Err(Error::manifest(field("effects"), "a layer effect's parameters are not valid"));
        }
    }
    if let Some(shape) = &layer.shape {
        if !shape.is_valid() {
            return Err(Error::manifest(field("shape"), "a shape's geometry is not valid"));
        }
    }
    Ok(())
}

/// Groups own contiguous subtrees; cycles, dangling parents, image-bearing groups and nesting
/// deeper than 64 levels are rejected.
pub fn validate_hierarchy(layers: &[LayerRecord]) -> Result<()> {
    let index: HashMap<Uuid, usize> = layers.iter().enumerate().map(|(i, l)| (l.id, i)).collect();
    if index.len() != layers.len() {
        return Err(Error::manifest("layers", "two layers share an id"));
    }
    for (position, layer) in layers.iter().enumerate() {
        let parent_field = format!("layers[{position}].parentID");
        let Some(parent_id) = layer.parent_id else {
            continue;
        };
        let Some(&parent_index) = index.get(&parent_id) else {
            return Err(Error::manifest(parent_field, format!("{parent_id} is not one of the document's layers")));
        };
        let parent = &layers[parent_index];
        if parent.is_group != Some(true) {
            return Err(Error::manifest(parent_field, "a layer can only be parented to a folder"));
        }
        if positions_overlap(position, parent_index, layers, &index) {
            return Err(Error::manifest(parent_field, "a folder cannot contain itself"));
        }
        // A group's subtree must stay contiguous and follow the group.
        if parent_index >= position {
            return Err(Error::manifest(parent_field, "a folder comes after the layers it holds"));
        }
    }
    for (position, layer) in layers.iter().enumerate() {
        if layer.is_group == Some(true) && layer.image_file.is_some() {
            return Err(Error::manifest(format!("layers[{position}].isGroup"), "a folder carries no pixels"));
        }
        // Group ancestors permit room for leaf nodes at the deepest level.
        let mut depth = 0usize;
        let mut cursor = layer.parent_id;
        let mut seen = HashSet::new();
        while let Some(parent) = cursor {
            if !seen.insert(parent) {
                return Err(Error::manifest(format!("layers[{position}].parentID"), "the parent chain loops"));
            }
            depth += 1;
            if depth > limits::MAX_GROUP_DEPTH {
                return Err(Error::manifest(
                    format!("layers[{position}].parentID"),
                    format!("folders nest no deeper than {} levels", limits::MAX_GROUP_DEPTH),
                ));
            }
            let Some(&parent_index) = index.get(&parent) else {
                return Err(Error::manifest(
                    format!("layers[{position}].parentID"),
                    format!("{parent} is not one of the document's layers"),
                ));
            };
            cursor = layers[parent_index].parent_id;
        }
    }
    Ok(())
}

/// True when `parent_index` lies inside `position`'s own subtree, which would make a cycle.
fn positions_overlap(position: usize, parent_index: usize, layers: &[LayerRecord], index: &HashMap<Uuid, usize>) -> bool {
    let mut cursor = Some(layers[parent_index].id);
    let mut guard = 0;
    while let Some(id) = cursor {
        if index.get(&id).copied() == Some(position) {
            return true;
        }
        guard += 1;
        if guard > limits::MAX_GROUP_DEPTH + 1 {
            return true;
        }
        cursor = index.get(&id).and_then(|i| layers[*i].parent_id);
    }
    false
}

/// Live masks (clipping masks) must point at a non-group layer, never themselves, and never form a
/// cycle or a chain longer than 256 nodes.
pub fn validate_live_mask_graph(layers: &[LayerRecord]) -> Result<()> {
    let index: HashMap<Uuid, usize> = layers.iter().enumerate().map(|(i, l)| (l.id, i)).collect();
    for (position, layer) in layers.iter().enumerate() {
        let field = format!("layers[{position}].maskSourceID");
        let Some(source) = layer.mask_source_id else { continue };
        if source == layer.id {
            return Err(Error::manifest(field, "a layer cannot be clipped to itself"));
        }
        let Some(&source_index) = index.get(&source) else {
            return Err(Error::manifest(field, format!("{source} is not one of the document's layers")));
        };
        if layers[source_index].is_group == Some(true) {
            return Err(Error::manifest(field, "a folder cannot be a clipping mask"));
        }
        let mut cursor = Some(source);
        let mut length = 0usize;
        let mut seen = HashSet::new();
        while let Some(id) = cursor {
            if !seen.insert(id) {
                return Err(Error::manifest(field, "the clipping chain loops"));
            }
            length += 1;
            if length > limits::MAX_LIVE_MASK_CHAIN {
                return Err(Error::manifest(
                    field,
                    format!("a clipping chain holds at most {} layers", limits::MAX_LIVE_MASK_CHAIN),
                ));
            }
            let Some(&next) = index.get(&id) else {
                return Err(Error::manifest(field, format!("{id} is not one of the document's layers")));
            };
            if layers[next].is_group == Some(true) {
                return Err(Error::manifest(field, format!("the chain reaches the folder {}", layers[next].name)));
            }
            cursor = layers[next].mask_source_id;
        }
    }
    Ok(())
}

fn validate_guides(manifest: &Manifest) -> Result<()> {
    let guides = manifest.guides.clone().unwrap_or_default();
    if manifest.version < 8 {
        if !guides.is_empty() {
            return Err(Error::manifest("guides", "guides arrived in format version 8"));
        }
        return Ok(());
    }
    if guides.len() > limits::MAX_GUIDES {
        return Err(Error::TooLarge(format!("{} guides", guides.len())));
    }
    let mut ids = HashSet::new();
    for (index, guide) in guides.iter().enumerate() {
        if !ids.insert(guide.id) {
            return Err(Error::manifest(format!("guides[{index}].id"), "two guides share this id"));
        }
        if !guide.position.is_finite() || guide.position.abs() > 1_000_000.0 {
            return Err(Error::manifest(
                format!("guides[{index}].position"),
                format!("{} is not a finite position within a million pixels", guide.position),
            ));
        }
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::adjustment::{Adjustment, AdjustmentKind};
    use crate::blend::BlendMode;
    use crate::geom::{PointF, SizeF, Transform};
    use crate::manifest::Manifest;

    fn base_layer(id: Uuid) -> LayerRecord {
        LayerRecord {
            id,
            name: "Layer".to_string(),
            is_visible: true,
            transform: Transform::new(PointF::new(0.0, 0.0), SizeF::new(100.0, 100.0)),
            image_file: Some(format!("{}.png", id.to_string().to_uppercase())),
            parent_id: None,
            is_group: Some(false),
            opacity: Some(1.0),
            blend_mode: Some(BlendMode::Normal),
            mask_file: None,
            mask_enabled: None,
            mask_source_id: None,
            adjustment: None,
            mask_placement: None,
            mask_linked: None,
            shape: None,
            effects: None,
            text: None,
        }
    }

    fn manifest_with(layers: Vec<LayerRecord>, version: u32) -> Manifest {
        Manifest {
            format: FORMAT_ID.to_string(),
            version,
            color_space: COLOR_SPACE.to_string(),
            resolution: Some(72.0),
            document_id: Uuid::new_v4(),
            width: 100,
            height: 100,
            active_layer_id: layers.first().map(|layer| layer.id),
            layers,
            guides: None,
        }
    }

    #[test]
    fn a_minimal_manifest_validates() {
        let id = Uuid::new_v4();
        let manifest = manifest_with(vec![base_layer(id)], 11);
        assert!(validate_manifest(&manifest).is_ok());
    }

    #[test]
    fn wrong_format_or_color_space_is_rejected() {
        let id = Uuid::new_v4();
        let mut manifest = manifest_with(vec![base_layer(id)], 11);
        manifest.format = "com.example.other".to_string();
        match validate_manifest(&manifest) {
            Err(error) => {
                assert_eq!(error.field(), Some("format"), "{error}");
                assert_eq!(error.source(), crate::ErrorSource::Manifest);
            }
            Ok(()) => panic!("another format must be refused"),
        }
        let mut manifest = manifest_with(vec![base_layer(id)], 11);
        manifest.color_space = "Display P3".to_string();
        match validate_manifest(&manifest) {
            Err(error) => assert_eq!(error.field(), Some("colorSpace"), "{error}"),
            Ok(()) => panic!("another color space must be refused"),
        }
    }

    #[test]
    fn unsupported_version_reports_the_version() {
        let id = Uuid::new_v4();
        let manifest = manifest_with(vec![base_layer(id)], 12);
        match validate_manifest(&manifest) {
            Err(Error::UnsupportedVersion(version)) => assert_eq!(version, 12),
            other => panic!("unexpected {other:?}"),
        }
    }

    #[test]
    fn image_file_must_match_the_layer_id() {
        let id = Uuid::new_v4();
        let mut layer = base_layer(id);
        layer.image_file = Some("other.png".to_string());
        let manifest = manifest_with(vec![layer], 11);
        match validate_manifest(&manifest) {
            Err(error) => assert_eq!(error.field(), Some("layers[0].imageFile"), "{error}"),
            Ok(()) => panic!("a misnamed asset must be refused"),
        }
    }

    #[test]
    fn group_hierarchy_rules_hold() {
        let group_id = Uuid::new_v4();
        let mut group = base_layer(group_id);
        group.is_group = Some(true);
        group.image_file = None;
        let mut child = base_layer(Uuid::new_v4());
        child.parent_id = Some(group_id);
        let manifest = manifest_with(vec![group.clone(), child.clone()], 11);
        assert!(validate_manifest(&manifest).is_ok());

        // A group with pixels is rejected.
        let mut bad_group = group.clone();
        bad_group.image_file = Some(format!("{}.png", group_id.to_string().to_uppercase()));
        assert!(validate_manifest(&manifest_with(vec![bad_group, child.clone()], 11)).is_err());

        // A child before its group is rejected.
        assert!(validate_manifest(&manifest_with(vec![child.clone(), group.clone()], 11)).is_err());

        // A dangling parent is rejected.
        let mut orphan = base_layer(Uuid::new_v4());
        orphan.parent_id = Some(Uuid::new_v4());
        assert!(validate_manifest(&manifest_with(vec![orphan], 11)).is_err());
    }

    #[test]
    fn version_one_rejects_groups_and_late_fields() {
        let group_id = Uuid::new_v4();
        let mut group = base_layer(group_id);
        group.is_group = Some(true);
        group.image_file = None;
        assert!(validate_manifest(&manifest_with(vec![group], 1)).is_err());

        let id = Uuid::new_v4();
        let mut layer = base_layer(id);
        layer.opacity = Some(0.5);
        assert!(validate_manifest(&manifest_with(vec![layer], 1)).is_err());
        assert!(validate_manifest(&manifest_with(vec![base_layer(id)], 1)).is_ok());
    }

    #[test]
    fn adjustment_layers_follow_their_version_rules() {
        let id = Uuid::new_v4();
        let mut layer = base_layer(id);
        layer.image_file = None;
        layer.adjustment = Some(Adjustment::new(AdjustmentKind::Levels));
        assert!(validate_manifest(&manifest_with(vec![layer.clone()], 7)).is_ok());
        assert!(validate_manifest(&manifest_with(vec![layer.clone()], 6)).is_err());
        layer.adjustment = Some(Adjustment::new(AdjustmentKind::GaussianBlur));
        assert!(validate_manifest(&manifest_with(vec![layer.clone()], 8)).is_err());
        assert!(validate_manifest(&manifest_with(vec![layer], 9)).is_ok());
    }

    #[test]
    fn mask_names_and_versions_are_checked() {
        let id = Uuid::new_v4();
        let mut layer = base_layer(id);
        layer.mask_file = Some(format!("{}.mask.png", id.to_string().to_uppercase()));
        layer.mask_enabled = Some(true);
        assert!(validate_manifest(&manifest_with(vec![layer.clone()], 4)).is_ok());
        assert!(validate_manifest(&manifest_with(vec![layer.clone()], 3)).is_err());
        layer.mask_file = Some("wrong.mask.png".to_string());
        assert!(validate_manifest(&manifest_with(vec![layer], 4)).is_err());
    }

    #[test]
    fn live_mask_chains_reject_cycles_and_groups() {
        let a = Uuid::new_v4();
        let b = Uuid::new_v4();
        let mut first = base_layer(a);
        first.mask_source_id = Some(b);
        let mut second = base_layer(b);
        second.mask_source_id = Some(a);
        assert!(validate_manifest(&manifest_with(vec![first.clone(), second], 11)).is_err());

        let mut self_link = base_layer(a);
        self_link.mask_source_id = Some(a);
        assert!(validate_manifest(&manifest_with(vec![self_link], 11)).is_err());

        let group_id = Uuid::new_v4();
        let mut group = base_layer(group_id);
        group.is_group = Some(true);
        group.image_file = None;
        let mut clipped = base_layer(Uuid::new_v4());
        clipped.mask_source_id = Some(group_id);
        assert!(validate_manifest(&manifest_with(vec![group, clipped], 11)).is_err());
    }

    #[test]
    fn guides_are_limited_and_version_gated() {
        let id = Uuid::new_v4();
        let mut manifest = manifest_with(vec![base_layer(id)], 7);
        manifest.guides = Some(vec![crate::geom::Guide {
            id: Uuid::new_v4(),
            axis: crate::geom::GuideAxis::Vertical,
            position: 10.0,
        }]);
        assert!(validate_manifest(&manifest).is_err());
        manifest.version = 8;
        assert!(validate_manifest(&manifest).is_ok());
        manifest.guides = Some(vec![crate::geom::Guide {
            id: Uuid::new_v4(),
            axis: crate::geom::GuideAxis::Vertical,
            position: f64::NAN,
        }]);
        assert!(validate_manifest(&manifest).is_err());
    }

    #[test]
    fn too_many_layers_is_a_size_error() {
        let mut layers = Vec::new();
        for _ in 0..limits::MAX_LAYERS + 1 {
            layers.push(base_layer(Uuid::new_v4()));
        }
        assert!(matches!(validate_manifest(&manifest_with(layers, 11)), Err(Error::TooLarge(_))));
    }
}
