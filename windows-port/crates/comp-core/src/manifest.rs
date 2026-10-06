//! The `manifest.json` data transfer objects and their conversion to the document model.
//!
//! Field names and spellings must match the macOS record exactly: `documentID`, `activeLayerID`,
//! `parentID`, `maskSourceID`, `imageFile`, `maskFile`, `maskEnabled`, `blendMode`, `isGroup`,
//! `isVisible`, `maskPlacement`, `maskLinked`.
use serde::{Deserialize, Serialize};
use uuid::Uuid;

use crate::adjustment::Adjustment;
use crate::blend::BlendMode;
use crate::document::{Document, CURRENT_VERSION};
use crate::effects::LayerEffects;
use crate::error::{Error, Result};
use crate::geom::{Guide, Transform};
use crate::layer::Layer;
use crate::shape::ShapeStyle;
use crate::text::TextStyle;

/// The package's format identifier.
pub const FORMAT_ID: &str = "com.compositor.project";
/// The only working space the format allows.
pub const COLOR_SPACE: &str = "sRGB";

/// The first two fields a loader reads before decoding the rest.
#[derive(Clone, Debug, Deserialize, Serialize)]
pub struct ManifestHeader {
    pub format: String,
    pub version: u32,
}

/// One layer record, as stored.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LayerRecord {
    #[serde(with = "crate::uuid_text")]
    pub id: Uuid,
    pub name: String,
    #[serde(rename = "isVisible")]
    pub is_visible: bool,
    pub transform: Transform,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub image_file: Option<String>,
    #[serde(
        rename = "parentID",
        default,
        with = "crate::uuid_text::optional",
        skip_serializing_if = "Option::is_none"
    )]
    pub parent_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub is_group: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub opacity: Option<f64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub blend_mode: Option<BlendMode>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mask_file: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mask_enabled: Option<bool>,
    #[serde(
        rename = "maskSourceID",
        default,
        with = "crate::uuid_text::optional",
        skip_serializing_if = "Option::is_none"
    )]
    pub mask_source_id: Option<Uuid>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub adjustment: Option<Adjustment>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mask_placement: Option<Transform>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub mask_linked: Option<bool>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub shape: Option<ShapeStyle>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub effects: Option<LayerEffects>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub text: Option<TextStyle>,
}

/// The whole manifest.
#[derive(Clone, Debug, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Manifest {
    pub format: String,
    pub version: u32,
    pub color_space: String,
    /// Pixels per inch; older version-1 projects omit it and mean 72.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub resolution: Option<f64>,
    #[serde(rename = "documentID", with = "crate::uuid_text")]
    pub document_id: Uuid,
    pub width: u32,
    pub height: u32,
    #[serde(
        rename = "activeLayerID",
        default,
        with = "crate::uuid_text::optional",
        skip_serializing_if = "Option::is_none"
    )]
    pub active_layer_id: Option<Uuid>,
    pub layers: Vec<LayerRecord>,
    /// Alignment guides; missing on versions 1-7.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub guides: Option<Vec<Guide>>,
}

impl Manifest {
    /// Builds the record a save writes for a document.
    pub fn from_document(document: &Document) -> Manifest {
        let layers = document
            .layers
            .iter()
            .map(|layer| LayerRecord {
                id: layer.id,
                name: layer.name.clone(),
                is_visible: layer.visible,
                transform: layer.transform,
                // Names always follow the layer id, whatever the in-memory document says.
                image_file: if layer.image.is_some() {
                    Some(layer.expected_image_file())
                } else {
                    layer.image_file.clone()
                },
                parent_id: layer.parent,
                is_group: Some(layer.is_group),
                opacity: Some(layer.opacity),
                blend_mode: Some(layer.blend),
                mask_file: if layer.mask.is_some() {
                    Some(layer.expected_mask_file())
                } else {
                    layer.mask_file.clone()
                },
                mask_enabled: if layer.mask.is_some() || layer.mask_file.is_some() {
                    Some(layer.mask_enabled)
                } else {
                    None
                },
                mask_source_id: layer.mask_source,
                adjustment: layer.adjustment.clone(),
                mask_placement: layer.mask_placement,
                mask_linked: if layer.mask_file.is_some() { Some(layer.mask_linked) } else { None },
                shape: layer.shape,
                effects: layer.effects,
                text: layer.text.clone(),
            })
            .collect();
        Manifest {
            format: FORMAT_ID.to_string(),
            version: CURRENT_VERSION,
            color_space: COLOR_SPACE.to_string(),
            resolution: Some(document.resolution),
            document_id: document.id,
            width: document.width,
            height: document.height,
            active_layer_id: document.active_layer,
            layers,
            guides: if document.guides.is_empty() { None } else { Some(document.guides.clone()) },
        }
    }

    /// Turns the record into a document without pixels; a loader attaches them by layer id.
    pub fn into_document(self) -> Document {
        let layers = self
            .layers
            .into_iter()
            .map(|record| Layer {
                id: record.id,
                name: record.name,
                visible: record.is_visible,
                parent: record.parent_id,
                is_group: record.is_group.unwrap_or(false),
                opacity: record.opacity.unwrap_or(1.0),
                blend: record.blend_mode.unwrap_or_default(),
                transform: record.transform,
                image: None,
                image_file: record.image_file,
                mask: None,
                mask_file: record.mask_file,
                mask_enabled: record.mask_enabled.unwrap_or(true),
                mask_source: record.mask_source_id,
                mask_placement: record.mask_placement,
                mask_linked: record.mask_linked.unwrap_or(true),
                adjustment: record.adjustment,
                effects: record.effects,
                text: record.text,
                shape: record.shape,
            })
            .collect();
        Document {
            id: self.document_id,
            width: self.width,
            height: self.height,
            resolution: self.resolution.unwrap_or(72.0),
            active_layer: self.active_layer_id,
            layers,
            guides: self.guides.unwrap_or_default(),
            version: self.version,
        }
    }

    /// Pretty JSON with sorted keys, the way the macOS app writes it.
    pub fn to_json(&self) -> Result<String> {
        // serde_json's value maps are sorted, matching JSONEncoder's .sortedKeys.
        let value = serde_json::to_value(self)?;
        Ok(serde_json::to_string_pretty(&value)?)
    }

    /// Reads only the format check fields, which a loader validates before anything else.
    ///
    /// Bytes that do not carry those two fields are not a manifest of this format, which is what the
    /// caller needs to know before it can say anything about the rest of the file.
    pub fn parse_header(bytes: &[u8]) -> Result<ManifestHeader> {
        serde_json::from_slice::<ManifestHeader>(bytes)
            .map_err(|_| Error::not_a_project("its manifest does not say which format it is"))
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::bitmap::Bitmap8;
    use crate::document::CURRENT_VERSION;
    use std::sync::Arc;

    fn sample_document() -> Document {
        let mut document = Document::new(1920, 1080);
        let mut layer = Layer::raster("Background", 1920, 1080);
        layer.image = Some(Arc::new(Bitmap8::new(1920, 1080)));
        layer.image_file = Some(layer.expected_image_file());
        document.active_layer = Some(layer.id);
        document.layers.push(layer);
        document
    }

    #[test]
    fn manifest_uses_the_exact_field_spellings() {
        let document = sample_document();
        let manifest = Manifest::from_document(&document);
        let json = manifest.to_json().unwrap();
        for key in ["\"documentID\"", "\"activeLayerID\"", "\"imageFile\"", "\"isVisible\"", "\"isGroup\"", "\"blendMode\"", "\"colorSpace\"", "\"format\""] {
            assert!(json.contains(key), "missing {key} in {json}");
        }
        assert!(json.contains("\"version\": 11"), "{json}");
        assert!(json.contains("\"blendMode\": \"Normal\""), "{json}");
        assert!(json.contains("\"sampling\": \"High quality\""), "{json}");
    }

    #[test]
    fn keys_are_sorted_like_the_mac_writer() {
        let document = sample_document();
        let json = Manifest::from_document(&document).to_json().unwrap();
        let format_at = json.find("\"format\"").unwrap();
        let version_at = json.find("\"version\"").unwrap();
        assert!(format_at < version_at, "object keys should be sorted: {json}");
    }

    #[test]
    fn manifest_roundtrips_through_the_document_model() {
        let document = sample_document();
        let manifest = Manifest::from_document(&document);
        let json = manifest.to_json().unwrap();
        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        let restored = parsed.into_document();
        assert_eq!(restored.id, document.id);
        assert_eq!(restored.width, document.width);
        assert_eq!(restored.height, document.height);
        assert_eq!(restored.resolution, document.resolution);
        assert_eq!(restored.active_layer, document.active_layer);
        assert_eq!(restored.layers.len(), document.layers.len());
        let original = &document.layers[0];
        let copy = &restored.layers[0];
        assert_eq!(copy.id, original.id);
        assert_eq!(copy.name, original.name);
        assert_eq!(copy.image_file, original.image_file);
        assert_eq!(copy.transform, original.transform);
        assert_eq!(copy.blend, original.blend);
        assert_eq!(restored.version, CURRENT_VERSION);
    }

    /// A document carrying every optional feature, so the spelling test below sees every key.
    fn kitchen_sink_document() -> Document {
        use crate::adjustment::{Adjustment, AdjustmentKind};
        use crate::blend::BlendMode;
        use crate::effects::{ColorOverlayEffect, LayerEffects, StrokeEffect};
        use crate::geom::{Guide, GuideAxis};
        use crate::shape::{ShapeKind, ShapeStyle};
        use crate::text::{SizeD, TextColorRun, TextFontRun, TextStyle};

        let mut document = Document::new(64, 48);
        let group = Layer::group("Folder", 64, 48);
        let group_id = group.id;
        document.add_layer(group, None);

        let mut pixel = Layer::raster("Pixels", 64, 48);
        pixel.image = Some(Arc::new(Bitmap8::filled(64, 48, [1, 2, 3, 255])));
        pixel.mask = Some(Arc::new(crate::bitmap::Gray8::filled(64, 48, 255)));
        pixel.mask_file = Some(pixel.expected_mask_file());
        pixel.mask_enabled = true;
        pixel.blend = BlendMode::SoftLight;
        pixel.opacity = 0.6;
        pixel.effects = Some(LayerEffects {
            stroke: Some(StrokeEffect::default()),
            color_overlay: Some(ColorOverlayEffect::default()),
            ..LayerEffects::default()
        });
        pixel.text = Some(TextStyle {
            content: "Hello".to_string(),
            box_size: Some(SizeD::new(40.0, 20.0)),
            color_runs: Some(vec![TextColorRun { location: 0, length: 2, red: 1.0, green: 0.0, blue: 0.0 }]),
            font_runs: Some(vec![TextFontRun {
                location: 2,
                length: 2,
                font_name: "Helvetica-Bold".to_string(),
            }]),
            ..TextStyle::default()
        });
        pixel.shape = Some(ShapeStyle {
            kind: ShapeKind::Rectangle,
            corner_radius: 4.0,
            line_width: Some(2.0),
            start: Some([0.0, 0.0]),
            end: Some([1.0, 1.0]),
            ..ShapeStyle::default()
        });
        document.add_layer(pixel, None);

        let mut adjustment = Layer::adjustment("Levels", Adjustment::new(AdjustmentKind::ColorBalance), 64, 48);
        adjustment.mask_source = Some(document.layers[1].id);
        document.add_layer(adjustment, Some(group_id));
        document.guides.push(Guide { id: Uuid::new_v4(), axis: GuideAxis::Vertical, position: 12.0 });
        document
    }

    fn collect_keys(value: &serde_json::Value, keys: &mut Vec<String>) {
        match value {
            serde_json::Value::Object(map) => {
                for (key, item) in map {
                    keys.push(key.clone());
                    collect_keys(item, keys);
                }
            }
            serde_json::Value::Array(items) => {
                for item in items {
                    collect_keys(item, keys);
                }
            }
            _ => {}
        }
    }

    /// The macOS decoder is the synthesized Codable one: a key it does not expect fails the whole
    /// manifest decode, so a package with a snake_case field would be rejected outright.
    #[test]
    fn no_manifest_key_uses_snake_case() {
        let document = kitchen_sink_document();
        let json = Manifest::from_document(&document).to_json().unwrap();
        let value: serde_json::Value = serde_json::from_str(&json).unwrap();
        let mut keys = Vec::new();
        collect_keys(&value, &mut keys);
        let offenders: Vec<&String> = keys.iter().filter(|key| key.contains('_')).collect();
        assert!(offenders.is_empty(), "snake_case keys in the manifest: {offenders:?}");
        for required in ["fontName", "cornerRadius", "lineWidth", "colorOverlay", "maskSourceID", "documentID"] {
            assert!(json.contains(required), "missing {required} in {json}");
        }
    }

    /// Every optional feature must survive a write and a read.
    #[test]
    fn kitchen_sink_document_roundtrips() {
        let document = kitchen_sink_document();
        let json = Manifest::from_document(&document).to_json().unwrap();
        let parsed: Manifest = serde_json::from_str(&json).unwrap();
        let restored = parsed.into_document();
        assert_eq!(restored.layers.len(), document.layers.len());
        let pixels = restored.layers.iter().find(|layer| layer.name == "Pixels").unwrap();
        assert_eq!(pixels.blend, crate::blend::BlendMode::SoftLight);
        assert!(pixels.mask_file.is_some());
        assert!(pixels.effects.is_some());
        let text = pixels.text.as_ref().unwrap();
        assert_eq!(text.font_runs.as_ref().unwrap()[0].font_name, "Helvetica-Bold");
        assert_eq!(text.box_size.unwrap().width, 40.0);
        let shape = pixels.shape.unwrap();
        assert_eq!(shape.corner_radius, 4.0);
        assert_eq!(shape.line_width, Some(2.0));
        assert_eq!(restored.guides.len(), 1);
    }

    #[test]
    fn older_manifests_default_missing_fields() {
        let json = r#"{
            "format": "com.compositor.project",
            "version": 1,
            "colorSpace": "sRGB",
            "documentID": "0C5E7A91-3B2D-4F6A-8E1C-9D0B7A6F5E4D",
            "width": 4,
            "height": 4,
            "activeLayerID": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F",
            "layers": [{
                "id": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F",
                "name": "Background",
                "imageFile": "6F1D3C2A-0B7E-4E8A-9C4D-2A1B3C4D5E6F.png",
                "isVisible": true,
                "transform": {"origin":[0,0],"size":[4,4],"rotation":0,"flipX":false,"flipY":false,"sampling":"High quality"}
            }]
        }"#;
        let manifest: Manifest = serde_json::from_str(json).unwrap();
        assert_eq!(manifest.resolution, None);
        let document = manifest.into_document();
        assert_eq!(document.resolution, 72.0);
        assert_eq!(document.layers[0].opacity, 1.0);
        assert_eq!(document.layers[0].blend, BlendMode::Normal);
        assert!(!document.layers[0].is_group);
        assert!(document.layers[0].mask_linked);
        assert_eq!(document.version, 1);
    }
}
