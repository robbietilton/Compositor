//! Reading Photoshop files: the header, image resources, layer records and channel data.
//!
//! This follows Adobe's Photoshop File Formats Specification the way the macOS PSDReader does:
//! the header and color mode, image resources (for the resolution), the layer and mask
//! information, and the merged image of a file that has no layer records. The Swift source is the
//! behavior reference, not the shape: records become comp-core layers in the builder.

use std::collections::HashMap;

use uuid::Uuid;

use comp_core::adjustment::{
    Adjustment, AdjustmentKind, Channel as AdjustmentChannel, CurvePoint, CurvesSettings, LevelRange,
    LevelsSettings,
};
use comp_core::bitmap::{Bitmap8, Gray8};
use comp_core::blend::BlendMode;
use comp_core::document::Document;
use comp_core::limits;

use crate::error::{IoError, IoResult};
use crate::psd::builder;
use crate::psd::channel::{self, ChannelCrop};
use crate::psd::cursor::Cursor;
use crate::psd::types::{
    PsdColorMode, PsdConversion, PsdHeader, PsdImport, PsdLayerKind, PsdMask, PsdReadOptions, PsdRecord,
    PSD_MAGIC,
};

/// The channel IDs that carry pixels Compositor can use: transparency, red, green, blue, mask.
const UNPACKED_CHANNEL_IDS: [i16; 5] = [-1, 0, 1, 2, -2];

/// The additional layer info keys that make a layer an adjustment layer.
const ADJUSTMENT_KEYS: [&[u8; 4]; 16] = [
    b"levl", b"curv", b"hue2", b"hue ", b"expA", b"grdm", b"brit", b"blnc", b"nvrt", b"thrs", b"post", b"mixr",
    b"selc", b"blwh", b"phfl", b"vibA",
];

/// Keys PSB files store with 64-bit lengths.
const PSB_LARGE_KEYS: [&[u8; 4]; 13] = [
    b"LMsk", b"Lr16", b"Lr32", b"Layr", b"Mt16", b"Mt32", b"Mtrn", b"Alph", b"FMsk", b"lnk2", b"FEid", b"FXid",
    b"PxSD",
];

/// Reads a Photoshop file into a document. Conversion notes are dropped here; call
/// read_psd_with_report when they matter.
pub fn read_psd(bytes: &[u8]) -> IoResult<Document> {
    Ok(read_psd_with_options(bytes, &PsdReadOptions::default())?.document)
}

/// Reads a Photoshop file and keeps the conversion report.
pub fn read_psd_with_report(bytes: &[u8]) -> IoResult<PsdImport> {
    read_psd_with_options(bytes, &PsdReadOptions::default())
}

/// Reads a Photoshop file with explicit limits, and a strict mode that refuses approximations.
pub fn read_psd_with_options(bytes: &[u8], options: &PsdReadOptions) -> IoResult<PsdImport> {
    let (header, resolution, records, conversions) = parse(bytes, options)?;
    builder::build(header, resolution, records, conversions, options)
}

/// Everything before the layers become a document.
fn parse(
    bytes: &[u8],
    options: &PsdReadOptions,
) -> IoResult<(PsdHeader, f64, Vec<PsdRecord>, Vec<PsdConversion>)> {
    let mut cursor = Cursor::new(bytes);
    if cursor.bytes(4, "the file signature")? != PSD_MAGIC {
        return Err(IoError::Unreadable("the file does not start with 8BPS".into()));
    }
    let version = cursor.u16()?;
    if version != 1 && version != 2 {
        return Err(IoError::UnsupportedVersion(version));
    }
    let is_psb = version == 2;
    // Six reserved bytes, then the channel count, canvas, depth and color mode.
    cursor.skip(6)?;
    let channels = cursor.u16()?;
    let height = cursor.u32()?;
    let width = cursor.u32()?;
    let depth = cursor.u16()?;
    let color_mode = PsdColorMode::from_raw(cursor.u16()?);
    if width == 0 || height == 0 || !limits::surface_fits(width, height) {
        return Err(IoError::TooLarge(format!(
            "the canvas is {width}x{height}; the format allows {} pixels per side and {} in one surface",
            limits::MAX_SIDE,
            limits::MAX_SURFACE_PIXELS
        )));
    }
    if depth != 8 {
        return Err(IoError::UnsupportedDepth(format!("{depth} bits per channel")));
    }
    if color_mode != PsdColorMode::Rgb {
        return Err(IoError::UnsupportedColorMode(format!(
            "{} at {depth} bits per channel",
            color_mode.name()
        )));
    }
    let header = PsdHeader { version, channels, width, height, depth, color_mode };

    // Only the layer and mask section grows to 64-bit lengths in a PSB; these two stay 32-bit.
    let color_mode_length = cursor.length(false, "the color mode data section")?;
    cursor.skip(color_mode_length)?;
    let resources_length = cursor.length(false, "the image resources section")?;
    let resources_end = cursor.offset() + resources_length;
    let resolution = read_resources(&mut cursor, resources_end)?;
    cursor.seek(resources_end)?;

    let layer_section = cursor.length(is_psb, "the layer and mask section")?;
    let layer_section_end = cursor.offset() + layer_section;
    let mut conversions = Vec::new();
    if layer_section < 4 {
        // Photoshop writes no layer records when the file is only a background, so the merged
        // image is all there is. macOS reads it through ImageIO for the same reason.
        let image = decode_merged(&mut cursor, &header)?;
        let mut record = PsdRecord::new(Uuid::new_v4(), "Background".to_string());
        record.bounds = (0.0, 0.0, f64::from(width), f64::from(height));
        record.image = Some(image);
        conversions.push(PsdConversion::new(
            "Background",
            "The file has no layer records, so its merged image was imported as one layer.",
        ));
        return Ok((header, resolution, vec![record], conversions));
    }

    let layer_info_length = cursor.length(is_psb, "the layer info section")?;
    let layer_info_start = cursor.offset();
    let layer_info_end = layer_info_start + layer_info_length;
    if layer_info_end > bytes.len() {
        return Err(IoError::Truncated(format!(
            "the layer info section ends at {layer_info_end}, past the {} bytes of the file",
            bytes.len()
        )));
    }
    let raw_count = cursor.i16()?;
    let count = raw_count.unsigned_abs() as usize;
    if count > limits::MAX_LAYERS {
        return Err(IoError::TooLarge(format!(
            "the file holds {count} layers; a document holds at most {}",
            limits::MAX_LAYERS
        )));
    }
    let mut raw = Vec::with_capacity(count.min(1024));
    for _ in 0..count {
        raw.push(read_record(&mut cursor, is_psb)?);
    }
    if !fits_budget(&raw, options.remaining_pixels) {
        for layer in &mut raw {
            crop_to_canvas(layer, width, height);
        }
        if !fits_budget(&raw, options.remaining_pixels) {
            return Err(IoError::TooLarge(
                "the layer pixels exceed the document budget even after cropping to the canvas".into(),
            ));
        }
    }
    let mut used_pixels = 0u64;
    for layer in &mut raw {
        decode_channels(
            &mut cursor,
            layer,
            options.remaining_pixels.saturating_sub(used_pixels),
            is_psb,
            &mut conversions,
        )?;
        if let Some(image) = &layer.image {
            used_pixels += image.pixel_count() as u64;
        }
    }
    // The global mask section and the merged image follow the layer records; neither is needed
    // once the layers are decoded.
    cursor.seek(layer_section_end)?;
    let remaining = options.remaining_pixels.saturating_sub(used_pixels);
    let records = assemble(raw, (width, height), remaining)?;
    Ok((header, resolution, records, conversions))
}

/// Reads the image resources for Photoshop's resolution record (ID 1005).
fn read_resources(cursor: &mut Cursor, resources_end: usize) -> IoResult<f64> {
    let mut resolution = 72.0;
    while cursor.offset() + 12 <= resources_end {
        if cursor.bytes(4, "an image resource signature")? != b"8BIM" {
            break;
        }
        let id = cursor.u16()?;
        let name_length = cursor.u8()? as usize;
        cursor.skip(name_length)?;
        if (name_length + 1) % 2 == 1 {
            cursor.skip(1)?;
        }
        let length = cursor.length(false, "an image resource")?;
        let data_start = cursor.offset();
        if id == 1005 && length >= 4 {
            // ResolutionInfo: 16.16 fixed point pixels per inch, both axes then both units.
            let value = f64::from(cursor.u32()?) / 65536.0;
            if value.is_finite() && value >= 1.0 {
                resolution = value.clamp(1.0, 9600.0);
            }
        }
        cursor.seek(data_start + length)?;
        if length % 2 == 1 {
            cursor.skip(1)?;
        }
    }
    Ok(resolution)
}

/// A layer record as the file stores it, before its channels are decoded.
struct RawLayer {
    name: String,
    top: i32,
    left: i32,
    bottom: i32,
    right: i32,
    source_top: i32,
    source_left: i32,
    source_bottom: i32,
    source_right: i32,
    opacity: u8,
    fill: u8,
    clipping: bool,
    hidden: bool,
    blend_key: [u8; 4],
    channels: Vec<(i16, usize)>,
    extra: HashMap<[u8; 4], Vec<u8>>,
    mask: Option<RawMask>,
    section: Option<u32>,
    image: Option<Bitmap8>,
    mask_image: Option<Gray8>,
    image_crop: Option<ChannelCrop>,
    mask_crop: Option<ChannelCrop>,
    cropped: bool,
}

struct RawMask {
    top: i32,
    left: i32,
    bottom: i32,
    right: i32,
    source_top: i32,
    source_left: i32,
    source_bottom: i32,
    source_right: i32,
    default_value: u8,
    disabled: bool,
    from_render: bool,
}

impl RawLayer {
    fn has_extra(&self, keys: &[&[u8; 4]]) -> bool {
        keys.iter().any(|key| self.extra.contains_key(*key))
    }
}

fn read_record(cursor: &mut Cursor, is_psb: bool) -> IoResult<RawLayer> {
    let top = cursor.i32()?;
    let left = cursor.i32()?;
    let bottom = cursor.i32()?;
    let right = cursor.i32()?;
    let channel_count = cursor.u16()? as usize;
    if channel_count > 56 {
        return Err(IoError::TooLarge(format!("a layer holds {channel_count} channels; at most 56 are read")));
    }
    let mut channels = Vec::with_capacity(channel_count);
    for _ in 0..channel_count {
        let id = cursor.i16()?;
        let length = cursor.length(is_psb, "a layer channel")?;
        channels.push((id, length));
    }
    if cursor.bytes(4, "a layer blend signature")? != b"8BIM" {
        return Err(IoError::Truncated("a layer record is missing its 8BIM blend signature".into()));
    }
    let mut blend_key = [0u8; 4];
    blend_key.copy_from_slice(cursor.bytes(4, "a blend mode key")?);
    let opacity = cursor.u8()?;
    let clipping = cursor.u8()? != 0;
    let flags = cursor.u8()?;
    let hidden = flags & 2 != 0;
    cursor.skip(1)?;
    let extra_length = cursor.length(false, "a layer extra data block")?;
    let extra_end = cursor.offset() + extra_length;

    let mask_length = cursor.length(false, "a layer mask block")?;
    let mask_end = cursor.offset() + mask_length;
    let mut mask = None;
    if mask_length >= 20 {
        let mask_top = cursor.i32()?;
        let mask_left = cursor.i32()?;
        let mask_bottom = cursor.i32()?;
        let mask_right = cursor.i32()?;
        let default_value = cursor.u8()?;
        let mask_flags = cursor.u8()?;
        mask = Some(RawMask {
            top: mask_top,
            left: mask_left,
            bottom: mask_bottom,
            right: mask_right,
            source_top: mask_top,
            source_left: mask_left,
            source_bottom: mask_bottom,
            source_right: mask_right,
            default_value,
            disabled: mask_flags & 2 != 0,
            // Bit 0 says whether the mask is linked to the layer. It is not stored here because
            // the mask is baked onto the layer's own grid, which is the linked placement.
            from_render: mask_flags & 8 != 0,
        });
    }
    cursor.seek(mask_end)?;
    let ranges = cursor.length(false, "a layer blending ranges block")?;
    cursor.skip(ranges)?;
    let name_length = cursor.u8()? as usize;
    let name_bytes = cursor.bytes(name_length, "a layer name")?;
    let mut name = mac_roman(name_bytes);
    let padding = (4 - ((name_length + 1) % 4)) % 4;
    cursor.skip(padding)?;

    let mut extra: HashMap<[u8; 4], Vec<u8>> = HashMap::new();
    while cursor.offset() + 12 <= extra_end {
        let signature = cursor.bytes(4, "an additional layer info signature")?;
        if signature != b"8BIM" && signature != b"8B64" {
            break;
        }
        let mut key = [0u8; 4];
        key.copy_from_slice(cursor.bytes(4, "an additional layer info key")?);
        let large = signature == b"8B64" || (is_psb && PSB_LARGE_KEYS.contains(&&key));
        let length = cursor.length(large, "additional layer info")?;
        let payload = cursor.bytes(length, "additional layer info")?.to_vec();
        if length % 2 == 1 {
            cursor.skip(1)?;
        }
        if key == *b"luni" {
            if let Some(unicode) = unicode_name(&payload) {
                name = unicode;
            }
        }
        extra.insert(key, payload);
    }
    cursor.seek(extra_end)?;

    let fill = extra.get(b"iOpa").and_then(|payload| payload.first().copied()).unwrap_or(255);
    let section = extra
        .get(b"lsct")
        .or_else(|| extra.get(b"lsdk"))
        .filter(|payload| payload.len() >= 4)
        .map(|payload| u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]));

    Ok(RawLayer {
        name,
        top,
        left,
        bottom,
        right,
        source_top: top,
        source_left: left,
        source_bottom: bottom,
        source_right: right,
        opacity,
        fill,
        clipping,
        hidden,
        blend_key,
        channels,
        extra,
        mask,
        section,
        image: None,
        mask_image: None,
        image_crop: None,
        mask_crop: None,
        cropped: false,
    })
}

/// The Unicode layer name from a 'luni' block: a count, then UTF-16 big-endian units.
fn unicode_name(payload: &[u8]) -> Option<String> {
    if payload.len() < 4 {
        return None;
    }
    let count = u32::from_be_bytes([payload[0], payload[1], payload[2], payload[3]]) as usize;
    if count == 0 || payload.len() < 4 + count * 2 {
        return None;
    }
    let mut units = Vec::with_capacity(count);
    for index in 0..count {
        let high = payload[4 + index * 2];
        let low = payload[5 + index * 2];
        units.push(u16::from_be_bytes([high, low]));
    }
    Some(String::from_utf16_lossy(&units).trim_matches(char::from(0)).to_string())
}

/// Photoshop stores a layer name as MacRoman when it has no 'luni' block.
fn mac_roman(bytes: &[u8]) -> String {
    bytes
        .iter()
        .map(|&byte| {
            if byte < 0x80 {
                byte as char
            } else {
                MAC_ROMAN_UPPER.chars().nth((byte - 0x80) as usize).unwrap_or('?')
            }
        })
        .collect()
}

/// MacRoman code points 0x80 through 0xFF, the only ones that differ from Latin-1.
const MAC_ROMAN_UPPER: &str = "\
ÄÅÇÉÑÖÜáàâäãåçéèêëíìîïñóòôöõúùûü\
†°¢£§•¶ß®©™´¨≠ÆØ∞±≤≥¥µ∂∑∏π∫ªºΩæø\
¿¡¬√ƒ≈∆«»…\u{A0}ÀÃÕŒœ–—“”‘’÷◊ÿŸ⁄€‹›ﬁﬂ‡·‚„‰\
ÂÊÁËÈÍÎÏÌÓÔ\u{F8FF}ÒÚÛÙıˆ˜¯˘˙˚¸˝˛ˇ";

/// Whether every layer's pixels fit the budget, as PSDReader.fitsBudget checks.
fn fits_budget(layers: &[RawLayer], remaining_pixels: u64) -> bool {
    let mut used = 0u64;
    for layer in layers {
        let width = (layer.right - layer.left).max(0) as u64;
        let height = (layer.bottom - layer.top).max(0) as u64;
        if width > 0 && height > 0 {
            if !fits(width, height, remaining_pixels.saturating_sub(used)) {
                return false;
            }
            used += width * height;
        }
        if let Some(mask) = &layer.mask {
            let mask_width = (mask.right - mask.left).max(0) as u64;
            let mask_height = (mask.bottom - mask.top).max(0) as u64;
            if mask_width > 0
                && mask_height > 0
                && !fits(mask_width, mask_height, remaining_pixels.saturating_sub(used))
            {
                return false;
            }
        }
    }
    true
}

fn fits(width: u64, height: u64, budget: u64) -> bool {
    width <= u64::from(limits::MAX_SIDE) && height <= u64::from(limits::MAX_SIDE) && width * height <= budget
}

/// Crops a layer's bounds and mask bounds to the canvas, as PSDReader.cropToCanvas does.
fn crop_to_canvas(layer: &mut RawLayer, canvas_width: u32, canvas_height: u32) {
    let crop = crop_rect(layer.left, layer.top, layer.right, layer.bottom, canvas_width, canvas_height);
    if crop.x != 0
        || crop.y != 0
        || crop.width != (layer.right - layer.left).max(0) as usize
        || crop.height != (layer.bottom - layer.top).max(0) as usize
    {
        layer.left += crop.x as i32;
        layer.top += crop.y as i32;
        layer.right = layer.left + crop.width as i32;
        layer.bottom = layer.top + crop.height as i32;
        layer.image_crop = Some(crop);
        layer.cropped = true;
    }
    let Some(mask) = layer.mask.as_mut() else { return };
    let crop = crop_rect(mask.left, mask.top, mask.right, mask.bottom, canvas_width, canvas_height);
    if crop.x != 0
        || crop.y != 0
        || crop.width != (mask.right - mask.left).max(0) as usize
        || crop.height != (mask.bottom - mask.top).max(0) as usize
    {
        mask.left += crop.x as i32;
        mask.top += crop.y as i32;
        mask.right = mask.left + crop.width as i32;
        mask.bottom = mask.top + crop.height as i32;
        layer.mask_crop = Some(crop);
        layer.cropped = true;
    }
}

fn crop_rect(left: i32, top: i32, right: i32, bottom: i32, canvas_width: u32, canvas_height: u32) -> ChannelCrop {
    let canvas_width = canvas_width as i32;
    let canvas_height = canvas_height as i32;
    let cropped_left = left.clamp(0, canvas_width);
    let cropped_top = top.clamp(0, canvas_height);
    let cropped_right = right.clamp(cropped_left, canvas_width);
    let cropped_bottom = bottom.clamp(cropped_top, canvas_height);
    ChannelCrop {
        x: (cropped_left - left).max(0) as usize,
        y: (cropped_top - top).max(0) as usize,
        width: (cropped_right - cropped_left).max(0) as usize,
        height: (cropped_bottom - cropped_top).max(0) as usize,
    }
}

/// Decodes the channels Photoshop stored for one layer, in file order.
fn decode_channels(
    cursor: &mut Cursor,
    layer: &mut RawLayer,
    remaining_pixels: u64,
    is_psb: bool,
    conversions: &mut Vec<PsdConversion>,
) -> IoResult<()> {
    let width = (layer.right - layer.left).max(0) as usize;
    let height = (layer.bottom - layer.top).max(0) as usize;
    let mask_width = layer.mask.as_ref().map(|mask| (mask.right - mask.left).max(0) as usize).unwrap_or(0);
    let mask_height = layer.mask.as_ref().map(|mask| (mask.bottom - mask.top).max(0) as usize).unwrap_or(0);
    if (width > 0 && height > 0 && !fits(width as u64, height as u64, remaining_pixels))
        || (mask_width > 0 && mask_height > 0 && !fits(mask_width as u64, mask_height as u64, remaining_pixels))
    {
        return Err(IoError::TooLarge(format!(
            "layer \"{}\" is {width}x{height} with a {mask_width}x{mask_height} mask, past the budget",
            layer.name
        )));
    }
    let source_width = (layer.source_right - layer.source_left).max(0) as usize;
    let source_height = (layer.source_bottom - layer.source_top).max(0) as usize;
    let source_mask_width =
        layer.mask.as_ref().map(|mask| (mask.source_right - mask.source_left).max(0) as usize).unwrap_or(0);
    let source_mask_height =
        layer.mask.as_ref().map(|mask| (mask.source_bottom - mask.source_top).max(0) as usize).unwrap_or(0);

    let mut planes: HashMap<i16, Vec<u8>> = HashMap::new();
    for (id, length) in layer.channels.clone() {
        let start = cursor.offset();
        let mut plane = None;
        let mut outcome: IoResult<()> = Ok(());
        if UNPACKED_CHANNEL_IDS.contains(&id) && length >= 2 {
            outcome = (|| -> IoResult<()> {
                let compression = cursor.u16()?;
                let payload = cursor.bytes(length - 2, "channel data")?;
                let is_mask = id == -2;
                let (source_w, source_h, target_w, target_h, crop) = if is_mask {
                    (source_mask_width, source_mask_height, mask_width, mask_height, layer.mask_crop)
                } else {
                    (source_width, source_height, width, height, layer.image_crop)
                };
                if target_w > 0 && target_h > 0 {
                    let crop = crop.unwrap_or(ChannelCrop { x: 0, y: 0, width: source_w, height: source_h });
                    plane = Some(channel::decode(compression, source_w, source_h, payload, is_psb, Some(crop))?);
                }
                Ok(())
            })();
        } else if !UNPACKED_CHANNEL_IDS.contains(&id) {
            conversions.push(PsdConversion::new(
                layer.name.clone(),
                format!(
                    "Channel {id} was skipped: only transparency, red, green, blue and the user mask are imported."
                ),
            ));
        }
        cursor.seek(start + length)?;
        outcome?;
        if let Some(plane) = plane {
            planes.insert(id, plane);
        }
    }

    // A mask with no pixels of its own keeps Photoshop's default value everywhere, which the
    // builder fills in from the mask record.
    if let Some(gray) = planes.get(&-2) {
        if mask_width > 0 && mask_height > 0 && gray.len() >= mask_width * mask_height {
            layer.mask_image = Some(Gray8::from_raw(mask_width as u32, mask_height as u32, gray.clone())?);
        }
    }
    if width == 0 || height == 0 {
        return Ok(());
    }
    let count = width * height;
    let red = planes.remove(&0);
    let green = planes.remove(&1);
    let blue = planes.remove(&2);
    let alpha = planes.remove(&-1);
    for plane in [&red, &green, &blue, &alpha].into_iter().flatten() {
        if plane.len() < count {
            return Err(IoError::Truncated(format!(
                "layer \"{}\" has a {}-byte channel; {width}x{height} needs {count}",
                layer.name,
                plane.len()
            )));
        }
    }
    // Straight RGBA: Photoshop's channels are straight, and premultiplying here would bake the
    // alpha into the color the compositor expects to premultiply itself.
    let mut pixels = vec![0u8; count * 4];
    for index in 0..count {
        pixels[index * 4] = red.as_ref().map_or(0, |plane| plane[index]);
        pixels[index * 4 + 1] = green.as_ref().map_or(0, |plane| plane[index]);
        pixels[index * 4 + 2] = blue.as_ref().map_or(0, |plane| plane[index]);
        pixels[index * 4 + 3] = alpha.as_ref().map_or(255, |plane| plane[index]);
    }
    layer.image = Some(Bitmap8::from_raw(width as u32, height as u32, pixels)?);
    Ok(())
}

/// Turns the decoded layers into records, resolving folders, clipping links and adjustments.
fn assemble(raw: Vec<RawLayer>, canvas: (u32, u32), remaining_pixels: u64) -> IoResult<Vec<PsdRecord>> {
    let mut result: Vec<PsdRecord> = Vec::with_capacity(raw.len());
    let mut groups: Vec<Uuid> = Vec::new();
    let mut group_starts: HashMap<Uuid, usize> = HashMap::new();
    let mut remaining = remaining_pixels;

    for layer in raw {
        // Photoshop writes a folder bottom to top: a bounding divider, the children, then the
        // folder record. The divider opens a group; the folder record closes it.
        if layer.section == Some(3) {
            let id = Uuid::new_v4();
            group_starts.insert(id, result.len());
            groups.push(id);
            continue;
        }
        let is_group = matches!(layer.section, Some(1) | Some(2));
        let id = if is_group { groups.pop().unwrap_or_else(Uuid::new_v4) } else { Uuid::new_v4() };
        let name = if layer.name.is_empty() { "Layer".to_string() } else { layer.name.clone() };
        let mut record = PsdRecord::new(id, name);
        record.parent = groups.last().copied();
        record.is_group = is_group;
        record.visible = !layer.hidden;
        record.clipping = layer.clipping;
        record.kind = layer_kind(&layer, is_group);
        let has_effects =
            record.kind == PsdLayerKind::Effects || layer.has_extra(&[b"lfx2", b"lrFX", b"lmfx"]);
        let opacity = f64::from(layer.opacity) / 255.0;
        // A layer whose effects already carry the fill opacity must not have it applied twice.
        record.opacity = if has_effects && layer.fill != 255 {
            opacity
        } else {
            opacity * f64::from(layer.fill) / 255.0
        }
        .clamp(0.0, 1.0);
        record.bounds = if is_group {
            (0.0, 0.0, f64::from(canvas.0), f64::from(canvas.1))
        } else {
            (
                f64::from(layer.left),
                f64::from(layer.top),
                f64::from((layer.right - layer.left).max(0)),
                f64::from((layer.bottom - layer.top).max(0)),
            )
        };
        record.image = if is_group { None } else { layer.image };
        record.blend_key = blend_key_string(&layer.blend_key);
        // Folders are pass-through in Compositor, so only a non-normal key is worth reporting.
        record.blend = if is_group { None } else { blend_mode(&layer.blend_key) };
        record.cropped = layer.cropped;
        if let Some(mask) = &layer.mask {
            let width = (mask.right - mask.left).max(0);
            let height = (mask.bottom - mask.top).max(0);
            let usable = !mask.from_render && width > 0 && height > 0;
            if usable {
                record.mask = layer.mask_image.clone().map(|pixels| PsdMask {
                    pixels,
                    x: f64::from(mask.left),
                    y: f64::from(mask.top),
                    width: f64::from(width),
                    height: f64::from(height),
                    default_value: mask.default_value,
                });
            }
            record.mask_enabled = !mask.disabled;
            record.mask_skipped = usable && record.mask.is_none();
        }
        if !is_group {
            record.adjustment = parse_adjustment(&layer.extra);
        }
        if record.adjustment.is_some() {
            record.kind = PsdLayerKind::Adjustment;
        }
        if let Some(image) = &record.image {
            let pixels = image.pixel_count() as u64;
            if pixels > remaining {
                return Err(IoError::TooLarge(format!(
                    "layer \"{}\" needs {pixels} more pixels than the document budget allows",
                    record.name
                )));
            }
            remaining -= pixels;
        }
        if is_group {
            // The folder record has to sit in front of its own subtree for the document model,
            // which keeps a group and its descendants contiguous.
            let start = group_starts
                .remove(&id)
                .or_else(|| result.iter().position(|other| other.parent == Some(id)))
                .unwrap_or(result.len())
                .min(result.len());
            result.insert(start, record);
        } else {
            result.push(record);
        }
    }
    if !groups.is_empty() {
        return Err(IoError::Truncated("a folder divider has no matching folder record".into()));
    }
    Ok(result)
}

/// What the additional layer info says this layer is, matching PSDReader.kind.
fn layer_kind(layer: &RawLayer, is_group: bool) -> PsdLayerKind {
    if is_group {
        return PsdLayerKind::Group;
    }
    if layer.has_extra(&[b"TySh", b"tySh", b"txt2"]) {
        return PsdLayerKind::Text;
    }
    if layer.has_extra(&[b"vmsk", b"vsms", b"vogk"]) {
        return PsdLayerKind::Vector;
    }
    if layer.has_extra(&[b"SoLd", b"SoLE"]) {
        return PsdLayerKind::SmartObject;
    }
    if layer.has_extra(&[b"lfx2", b"lrFX", b"lmfx"]) {
        return PsdLayerKind::Effects;
    }
    if ADJUSTMENT_KEYS.iter().any(|key| layer.extra.contains_key(*key)) {
        return PsdLayerKind::Adjustment;
    }
    PsdLayerKind::Raster
}

/// Photoshop's four-character blend key as text, for the conversion report.
fn blend_key_string(key: &[u8; 4]) -> String {
    let text: String =
        key.iter().map(|&byte| if byte.is_ascii_graphic() { byte as char } else { ' ' }).collect();
    text.trim().to_string()
}

/// Photoshop blend keys to Compositor blend modes, matching LayerBlendMode.fromPSD.
///
/// Dissolve, Darker Color and Lighter Color are deliberately absent: Compositor has no
/// equivalent, so they fall through to Normal and say so in the conversion report.
fn blend_mode(key: &[u8; 4]) -> Option<BlendMode> {
    match key {
        b"norm" => Some(BlendMode::Normal),
        b"mul " => Some(BlendMode::Multiply),
        b"scrn" => Some(BlendMode::Screen),
        b"over" => Some(BlendMode::Overlay),
        b"sLit" => Some(BlendMode::SoftLight),
        b"dark" => Some(BlendMode::Darken),
        b"lite" => Some(BlendMode::Lighten),
        b"diff" => Some(BlendMode::Difference),
        b"div " => Some(BlendMode::ColorDodge),
        b"idiv" => Some(BlendMode::ColorBurn),
        b"hue " => Some(BlendMode::Hue),
        b"sat " => Some(BlendMode::Saturation),
        b"colr" => Some(BlendMode::Color),
        b"lum " => Some(BlendMode::Luminosity),
        b"lbrn" => Some(BlendMode::LinearBurn),
        b"lddg" => Some(BlendMode::LinearDodge),
        b"hLit" => Some(BlendMode::HardLight),
        b"vLit" => Some(BlendMode::VividLight),
        b"lLit" => Some(BlendMode::LinearLight),
        b"pLit" => Some(BlendMode::PinLight),
        b"hMix" => Some(BlendMode::HardMix),
        b"smud" => Some(BlendMode::Exclusion),
        b"fsub" => Some(BlendMode::Subtract),
        b"fdiv" => Some(BlendMode::Divide),
        _ => None,
    }
}

/// Levels and Curves adjustment layers, the two kinds Compositor's record stores directly.
///
/// Photoshop's other adjustment blocks are reported and the layer is skipped, which is what macOS
/// does when its own parser does not recognize one.
fn parse_adjustment(extra: &HashMap<[u8; 4], Vec<u8>>) -> Option<Adjustment> {
    if let Some(payload) = extra.get(b"levl") {
        return levels(payload);
    }
    if let Some(payload) = extra.get(b"curv") {
        return curves(payload);
    }
    None
}

/// Photoshop's 'levl': input black and white, output black and white and gamma in hundredths,
/// for RGB and then red, green and blue.
fn levels(data: &[u8]) -> Option<Adjustment> {
    if data.len() < 292 {
        return None;
    }
    let mut settings = LevelsSettings { channel: AdjustmentChannel::RGB, ..LevelsSettings::default() };
    for channel in 0..4 {
        let base = 2 + channel * 10;
        let input_black = f64::from(u16_at(data, base)?);
        let input_white = f64::from(u16_at(data, base + 2)?);
        let output_black = f64::from(u16_at(data, base + 4)?);
        let output_white = f64::from(u16_at(data, base + 6)?);
        let gamma = f64::from(u16_at(data, base + 8)?) / 100.0;
        settings.ranges[channel] =
            normalize_levels(LevelRange { black: input_black, gamma, white: input_white, output_black, output_white });
    }
    Some(Adjustment {
        kind: AdjustmentKind::Levels,
        levels: settings,
        ..Adjustment::new(AdjustmentKind::Levels)
    })
}

/// The same clamps LevelRange.normalized applies, so a stored record always passes validation.
fn normalize_levels(range: LevelRange) -> LevelRange {
    fn clamp(value: f64, low: f64, high: f64, fallback: f64) -> f64 {
        if value.is_finite() {
            value.clamp(low, high)
        } else {
            fallback
        }
    }
    let black = clamp(range.black, 0.0, 254.0, 0.0);
    LevelRange {
        black,
        white: clamp(range.white, black + 1.0, 255.0, 255.0),
        gamma: clamp(range.gamma, 0.1, 9.99, 1.0),
        output_black: clamp(range.output_black, 0.0, 255.0, 0.0),
        output_white: clamp(range.output_white, 0.0, 255.0, 255.0),
    }
}

/// Photoshop's 'curv': a version, then a point list per channel, each point stored as the output
/// value followed by the input value.
fn curves(data: &[u8]) -> Option<Adjustment> {
    if data.len() < 5 {
        return None;
    }
    let mut offset = 0usize;
    if data[0] == 0 {
        offset += 1;
    }
    let version = u16_at(data, offset)?;
    offset += 2;
    if version != 1 && version != 4 {
        return None;
    }
    let count = u16_at(data, offset)? as usize;
    offset += 2;
    let mut settings = CurvesSettings::default();
    let mut found = false;
    for channel in 0..count.min(4) {
        let points = u16_at(data, offset)? as usize;
        offset += 2;
        let mut curve = Vec::with_capacity(points);
        for _ in 0..points {
            let output = f64::from(u16_at(data, offset)?);
            let input = f64::from(u16_at(data, offset + 2)?);
            offset += 4;
            curve.push(CurvePoint { x: input.clamp(0.0, 255.0), y: output.clamp(0.0, 255.0) });
        }
        if curve.len() >= 2 {
            curve.sort_by(|a, b| a.x.partial_cmp(&b.x).unwrap_or(std::cmp::Ordering::Equal));
            if curve.first().map(|point| point.x) != Some(0.0) {
                let y = curve[0].y;
                curve.insert(0, CurvePoint { x: 0.0, y });
            }
            if curve.last().map(|point| point.x) != Some(255.0) {
                let y = curve[curve.len() - 1].y;
                curve.push(CurvePoint { x: 255.0, y });
            }
            settings.channels[channel] = curve;
            found = true;
        }
    }
    if !found {
        return None;
    }
    Some(Adjustment {
        kind: AdjustmentKind::Curves,
        curves: settings,
        ..Adjustment::new(AdjustmentKind::Curves)
    })
}

fn u16_at(data: &[u8], offset: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*data.get(offset)?, *data.get(offset + 1)?]))
}

/// The merged image of a file with no layer records: the whole canvas, channel by channel.
fn decode_merged(cursor: &mut Cursor, header: &PsdHeader) -> IoResult<Bitmap8> {
    let width = header.width as usize;
    let height = header.height as usize;
    let count = usize::from(header.channels.clamp(1, 4));
    let plane_length = width * height;
    let compression = cursor.u16()?;
    let planes: Vec<Vec<u8>> = match compression {
        0 => {
            let mut planes = Vec::with_capacity(count);
            for _ in 0..count {
                planes.push(cursor.bytes(plane_length, "the merged image")?.to_vec());
            }
            planes
        }
        1 => {
            // The merged section stores one count table for every channel's rows, then the
            // packed rows in channel order, which is not how a layer channel is stored.
            let large = header.is_psb();
            let mut counts = Vec::with_capacity(count * height);
            for _ in 0..count * height {
                counts.push(if large { cursor.u32()? as usize } else { cursor.u16()? as usize });
            }
            let data = cursor.rest();
            let mut planes = Vec::with_capacity(count);
            let mut offset = 0usize;
            for channel in 0..count {
                let (plane, used) = channel::pack_bits_rows(
                    width,
                    height,
                    &data[offset..],
                    &counts[channel * height..(channel + 1) * height],
                )?;
                offset += used;
                planes.push(plane);
            }
            planes
        }
        other => return Err(IoError::UnsupportedCompression(other)),
    };
    let mut pixels = vec![0u8; plane_length * 4];
    for index in 0..plane_length {
        pixels[index * 4] = planes.first().map_or(0, |plane| plane[index]);
        pixels[index * 4 + 1] = planes.get(1).map_or(0, |plane| plane[index]);
        pixels[index * 4 + 2] = planes.get(2).map_or(0, |plane| plane[index]);
        pixels[index * 4 + 3] = planes.get(3).map_or(255, |plane| plane[index]);
    }
    Ok(Bitmap8::from_raw(header.width, header.height, pixels)?)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::psd::test_support::{self as fixture, LayerSpec, MaskSpec, PsdSpec};
    use comp_core::adjustment::AdjustmentKind;
    use comp_core::geom::PointF;

    /// A four-pixel image with every kind of channel value.
    fn pixels() -> Vec<[u8; 4]> {
        vec![[255, 0, 0, 255], [0, 255, 0, 255], [0, 0, 255, 255], [255, 255, 255, 128]]
    }

    fn flat() -> Vec<u8> {
        pixels().iter().flatten().copied().collect()
    }

    fn layer(name: &str) -> LayerSpec {
        LayerSpec::new(name, (0, 0, 2, 2))
    }

    fn full() -> Vec<u8> {
        fixture::single_layer("Art", 2, 2, &pixels(), 0)
    }

    #[test]
    fn a_minimal_file_parses_into_one_layer() {
        let document = read_psd(&full()).unwrap();
        assert_eq!((document.width, document.height), (2, 2));
        assert_eq!(document.layers.len(), 1);
        let parsed = &document.layers[0];
        assert_eq!(parsed.name, "Art");
        assert!(parsed.visible);
        assert_eq!(parsed.opacity, 1.0);
        assert_eq!(parsed.blend, BlendMode::Normal);
        assert_eq!(parsed.transform.origin, PointF::new(0.0, 0.0));
        assert_eq!(parsed.transform.size.width, 2.0);
        assert_eq!(parsed.image.as_ref().unwrap().pixels(), flat().as_slice());
        assert_eq!(document.active_layer, Some(parsed.id));
    }

    #[test]
    fn raw_rle_zip_and_predicted_zip_channels_all_decode() {
        for compression in [0u16, 1, 2, 3] {
            let bytes =
                fixture::build(&PsdSpec::new((2, 2)).layer(layer("Art").rgba(&pixels(), compression)));
            let document = read_psd(&bytes)
                .unwrap_or_else(|error| panic!("compression {compression} failed: {error}"));
            assert_eq!(
                document.layers[0].image.as_ref().unwrap().pixels(),
                flat().as_slice(),
                "compression {compression}"
            );
        }
    }

    #[test]
    fn alpha_survives_a_translucent_layer_without_premultiplying() {
        let document = read_psd(&full()).unwrap();
        let image = document.layers[0].image.as_ref().unwrap();
        assert_eq!(image.get(1, 1), [255, 255, 255, 128]);
    }

    #[test]
    fn psb_files_use_four_byte_row_counts() {
        let bytes =
            fixture::build(&PsdSpec::new((2, 2)).version(2).layer(layer("Art").rgba(&pixels(), 1)));
        let document = read_psd(&bytes).unwrap();
        assert_eq!(document.layers[0].image.as_ref().unwrap().pixels(), flat().as_slice());
    }

    #[test]
    fn folders_keep_their_subtree_contiguous() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(layer("Bottom").rgba(&pixels(), 0))
                .layer(LayerSpec::new("Divider", (0, 0, 0, 0)).section(3))
                .layer(layer("Inner").rgba(&pixels(), 0))
                .layer(LayerSpec::new("Folder", (0, 0, 2, 2)).section(1)),
        );
        let document = read_psd(&bytes).unwrap();
        let names: Vec<&str> = document.layers.iter().map(|entry| entry.name.as_str()).collect();
        assert_eq!(names, vec!["Bottom", "Folder", "Inner"]);
        let folder = &document.layers[1];
        let inner = &document.layers[2];
        assert!(folder.is_group);
        assert_eq!(inner.parent, Some(folder.id));
        assert_eq!(document.layers[0].parent, None);
        assert_eq!(document.subtree_indices(folder.id), vec![1, 2]);
        assert!(document.renderable_ids().contains(&inner.id));
    }

    #[test]
    fn nested_folders_keep_every_level_contiguous() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(LayerSpec::new("D1", (0, 0, 0, 0)).section(3))
                .layer(LayerSpec::new("D2", (0, 0, 0, 0)).section(3))
                .layer(layer("Leaf").rgba(&pixels(), 0))
                .layer(LayerSpec::new("Inner", (0, 0, 2, 2)).section(2))
                .layer(layer("Outer child").rgba(&pixels(), 0))
                .layer(LayerSpec::new("Outer", (0, 0, 2, 2)).section(1)),
        );
        let document = read_psd(&bytes).unwrap();
        let names: Vec<&str> = document.layers.iter().map(|entry| entry.name.as_str()).collect();
        assert_eq!(names, vec!["Outer", "Inner", "Leaf", "Outer child"]);
        let outer = &document.layers[0];
        let inner = &document.layers[1];
        assert!(outer.is_group && inner.is_group);
        assert_eq!(inner.parent, Some(outer.id));
        assert_eq!(document.layers[2].parent, Some(inner.id));
        assert_eq!(document.layers[3].parent, Some(outer.id));
        assert_eq!(document.subtree_indices(outer.id), vec![0, 1, 2, 3]);
        assert_eq!(document.subtree_indices(inner.id), vec![1, 2]);
        assert_eq!(document.depth(document.layers[2].id), 2);
        // The top root layer is the active one, as macOS's insertPhotoshop selects.
        assert_eq!(document.active_layer, Some(outer.id));
    }

    #[test]
    fn opacity_multiplies_fill_opacity_and_hidden_layers_stay_out() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(layer("Half").rgba(&pixels(), 0).opacity(128).fill_opacity(64))
                .layer(layer("Hidden").rgba(&pixels(), 0).hidden()),
        );
        let document = read_psd(&bytes).unwrap();
        let expected = (128.0 / 255.0) * (64.0 / 255.0);
        assert!((document.layers[0].opacity - expected).abs() < 1e-9, "{}", document.layers[0].opacity);
        assert!(!document.layers[1].visible);
        assert!(!document.renderable_ids().contains(&document.layers[1].id));
    }

    #[test]
    fn blend_keys_map_to_compositor_modes_and_unknown_ones_are_reported() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(layer("Multiply").rgba(&pixels(), 0).blend(b"mul "))
                .layer(layer("Dissolve").rgba(&pixels(), 0).blend(b"diss")),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert_eq!(import.document.layers[0].blend, BlendMode::Multiply);
        assert_eq!(import.document.layers[1].blend, BlendMode::Normal);
        assert!(import
            .conversions
            .iter()
            .any(|conversion| conversion.layer_name == "Dissolve" && conversion.message.contains("diss")));
    }

    #[test]
    fn masks_land_on_the_layer_grid_with_the_files_default_outside_the_patch() {
        // A mask channel holds only the mask rectangle, which is 2x2 here.
        let mask_plane = vec![200u8; 4];
        let bytes = fixture::build(
            &PsdSpec::new((4, 4))
                .layer(
                    LayerSpec::new("Masked", (0, 0, 4, 4))
                        .rgba(&[[10, 20, 30, 255]; 16], 0)
                        .gray_plane(mask_plane, 0)
                        .mask(MaskSpec { rect: (1, 1, 3, 3), default_value: 255, flags: 0 }),
                )
                .layer(
                    layer("Off")
                        .rgba(&pixels(), 0)
                        .gray_plane(vec![255u8; 4], 0)
                        .mask(MaskSpec { rect: (0, 0, 2, 2), default_value: 255, flags: 2 }),
                ),
        );
        let document = read_psd(&bytes).unwrap();
        let mask = document.layers[0].mask.as_ref().unwrap();
        assert_eq!((mask.width(), mask.height()), (4, 4));
        assert_eq!(mask.get(0, 0), 255);
        assert_eq!(mask.get(2, 2), 200);
        assert!(document.layers[0].mask_enabled);
        assert!(document.layers[0].mask_linked, "the mask is baked onto the layer grid");
        assert!(!document.layers[1].mask_enabled, "bit 2 of the mask flags disables it");
    }

    #[test]
    fn clipping_layers_point_at_the_layer_below_them() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(layer("Base").rgba(&pixels(), 0))
                .layer(layer("Clipped").rgba(&pixels(), 0).clipping()),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert_eq!(import.document.layers[1].mask_source, Some(import.document.layers[0].id));
        assert!(import.conversions.is_empty(), "{:?}", import.conversions);
    }

    #[test]
    fn clipping_onto_an_unsupported_base_is_reported() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(LayerSpec::new("Divider", (0, 0, 0, 0)).section(3))
                .layer(layer("Inner").rgba(&pixels(), 0))
                .layer(LayerSpec::new("Folder", (0, 0, 2, 2)).section(1))
                .layer(layer("Clipped").rgba(&pixels(), 0).clipping()),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert!(import.document.layers.last().unwrap().mask_source.is_none());
        assert!(import.conversions.iter().any(|conversion| conversion.message.contains("clipping")));
    }

    #[test]
    fn folder_blend_modes_are_reported_as_pass_through() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(LayerSpec::new("D", (0, 0, 0, 0)).section(3))
                .layer(layer("Inner").rgba(&pixels(), 0))
                .layer(LayerSpec::new("Folder", (0, 0, 2, 2)).section(1).blend(b"mul ")),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        let folder = import.document.layers.iter().find(|entry| entry.is_group).unwrap();
        assert_eq!(folder.blend, BlendMode::Normal);
        assert!(import.conversions.iter().any(|conversion| conversion.message.contains("Folder blend mode")));
    }

    #[test]
    fn unsupported_colors_depths_and_versions_are_refused() {
        let cmyk = fixture::build(&PsdSpec::new((2, 2)).color_mode(4));
        assert!(matches!(read_psd(&cmyk), Err(IoError::UnsupportedColorMode(_))));
        let deep = fixture::build(&PsdSpec::new((2, 2)).depth(16));
        assert!(matches!(read_psd(&deep), Err(IoError::UnsupportedDepth(_))));
        let future = fixture::build(&PsdSpec::new((2, 2)).version(3));
        assert!(matches!(read_psd(&future), Err(IoError::UnsupportedVersion(3))));
        assert!(matches!(read_psd(b"not a photoshop file"), Err(IoError::Unreadable(_))));
    }

    #[test]
    fn damaged_files_are_refused() {
        let bytes = full();
        let cut = &bytes[..bytes.len() / 2];
        assert!(matches!(
            read_psd(cut),
            Err(IoError::Truncated(_)) | Err(IoError::Unreadable(_))
        ));
        assert!(matches!(read_psd(&[]), Err(IoError::Truncated(_))));
        assert!(matches!(read_psd(b"8BPS"), Err(IoError::Truncated(_))));
    }

    #[test]
    fn unknown_channel_compression_is_refused_by_number() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2)).layer(layer("Odd").verbatim_channel(0, 7, vec![0u8; 8])),
        );
        assert!(matches!(read_psd(&bytes), Err(IoError::UnsupportedCompression(7))));
    }

    #[test]
    fn spot_channels_are_reported_instead_of_dropped() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2)).layer(layer("Spotty").rgba(&pixels(), 0).plane(3, vec![9u8; 4], 0)),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert!(import.conversions.iter().any(|conversion| conversion.message.contains("Channel 3")));
    }

    #[test]
    fn text_layers_fall_back_to_their_pixels_with_a_note() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2)).layer(layer("Headline").rgba(&pixels(), 0).extra(b"TySh", vec![0u8; 8])),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert!(import.document.layers[0].image.is_some());
        assert!(import
            .conversions
            .iter()
            .any(|conversion| conversion.message.contains("text layer was imported as pixels")));
    }

    #[test]
    fn the_resolution_comes_from_the_image_resource() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2)).resolution(300.0).layer(layer("Art").rgba(&pixels(), 0)),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert!((import.resolution - 300.0).abs() < 0.01, "{}", import.resolution);
        assert_eq!(import.document.resolution, import.resolution);
        assert_eq!(import.header.width, 2);
        assert!(!import.header.is_psb());
        assert_eq!(import.report(), "");
    }

    #[test]
    fn a_file_without_layer_records_imports_its_merged_image() {
        let planes = vec![vec![255u8; 4], vec![0u8; 4], vec![10u8; 4]];
        let bytes = fixture::build(&PsdSpec::new((2, 2)).merged(planes, 0));
        let import = read_psd_with_report(&bytes).unwrap();
        assert_eq!(import.document.layers.len(), 1);
        let parsed = &import.document.layers[0];
        assert_eq!(parsed.name, "Background");
        assert_eq!(parsed.image.as_ref().unwrap().get(0, 0), [255, 0, 10, 255]);
        assert!(import.conversions.iter().any(|conversion| conversion.message.contains("no layer records")));
    }

    #[test]
    fn a_merged_image_can_be_pack_bits_compressed() {
        let planes = vec![vec![1u8; 4], vec![2u8; 4], vec![3u8; 4]];
        let bytes = fixture::build(&PsdSpec::new((2, 2)).merged(planes, 1));
        let document = read_psd(&bytes).unwrap();
        assert_eq!(document.layers[0].image.as_ref().unwrap().get(1, 1), [1, 2, 3, 255]);
    }

    #[test]
    fn levels_and_curves_layers_import_as_adjustment_records() {
        let mut levels = vec![0u8; 292];
        levels[1] = 1; // version 1
        for channel in 0..4 {
            let base = 2 + channel * 10;
            levels[base + 2..base + 4].copy_from_slice(&255u16.to_be_bytes());
            levels[base + 6..base + 8].copy_from_slice(&255u16.to_be_bytes());
            levels[base + 8..base + 10].copy_from_slice(&100u16.to_be_bytes());
        }
        let mut curves = vec![0u8];
        curves.extend_from_slice(&1u16.to_be_bytes());
        curves.extend_from_slice(&1u16.to_be_bytes());
        curves.extend_from_slice(&2u16.to_be_bytes());
        curves.extend_from_slice(&0u16.to_be_bytes());
        curves.extend_from_slice(&0u16.to_be_bytes());
        curves.extend_from_slice(&128u16.to_be_bytes());
        curves.extend_from_slice(&255u16.to_be_bytes());
        let bytes = fixture::build(
            &PsdSpec::new((2, 2))
                .layer(LayerSpec::new("Levels", (0, 0, 2, 2)).extra(b"levl", levels))
                .layer(LayerSpec::new("Curves", (0, 0, 2, 2)).extra(b"curv", curves)),
        );
        let document = read_psd(&bytes).unwrap();
        let adjustment = document.layers[0].adjustment.as_ref().unwrap();
        assert_eq!(adjustment.kind, AdjustmentKind::Levels);
        assert!(adjustment.is_valid());
        assert_eq!(adjustment.levels.ranges[0].white, 255.0);
        let adjustment = document.layers[1].adjustment.as_ref().unwrap();
        assert_eq!(adjustment.kind, AdjustmentKind::Curves);
        assert_eq!(adjustment.curves.channels[0].last().unwrap().y, 128.0);
        assert_eq!(document.layers[0].kind(), comp_core::layer::LayerKind::Adjustment);
    }

    #[test]
    fn an_unsupported_adjustment_is_reported_and_skipped() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2)).layer(LayerSpec::new("Brightness", (0, 0, 2, 2)).extra(b"brit", vec![0u8; 8])),
        );
        let import = read_psd_with_report(&bytes).unwrap();
        assert!(import.document.layers.is_empty());
        assert!(import
            .conversions
            .iter()
            .any(|conversion| conversion.message.contains("adjustment type is not supported")));
    }

    #[test]
    fn a_unicode_name_block_wins_over_the_pascal_name() {
        let bytes = fixture::build(
            &PsdSpec::new((2, 2)).layer(layer("Fallback").rgba(&pixels(), 0).unicode_name("Café ☕")),
        );
        let document = read_psd(&bytes).unwrap();
        assert_eq!(document.layers[0].name, "Café ☕");
    }

    #[test]
    fn the_mac_roman_table_covers_the_upper_half() {
        assert_eq!(MAC_ROMAN_UPPER.chars().count(), 128);
        assert_eq!(mac_roman(b"Caf\x8E"), "Café");
        assert_eq!(mac_roman(&[0xA5]), "\u{2022}");
        assert_eq!(mac_roman(&[0xD5]), "\u{2019}");
        assert_eq!(mac_roman(&[0xF0]), "\u{F8FF}");
    }

    #[test]
    fn the_signature_check_matches_only_photoshop_files() {
        assert!(crate::psd::matches(&full()));
        assert!(!crate::psd::matches(b"\x89PNG\r\n\x1a\n"));
        assert!(!crate::psd::matches(b""));
    }
}

