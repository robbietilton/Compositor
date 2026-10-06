//! Just enough of the ISO base media file format to read a HEIF or AVIF file's metadata.
//!
//! The pictures themselves are decoded by the system codec; what is read here are the parts the
//! Windows Imaging Component does not expose: the Exif item that carries the resolution, and the
//! item reference that says a picture has an auxiliary alpha image.
//!
//! Only the boxes along those two paths are parsed. A malformed file yields None rather than an
//! error, because a missing resolution is not a reason to refuse a picture that still decodes.
use crate::metadata::read_tiff_resolution;

/// Where one item's bytes live.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
struct ItemLocation {
    offset: u64,
    length: u64,
}

/// The resolution a HEIF or AVIF file declares in its Exif item, in pixels per inch.
pub fn read_heif_resolution(bytes: &[u8]) -> Option<f64> {
    let exif = exif_item(bytes)?;
    // The Exif item starts with four big-endian bytes giving the offset of the TIFF header, and the
    // header itself is an ordinary TIFF block. Writers disagree about what the offset counts from,
    // so both readings are tried and the TIFF magic decides: the offset past the four-byte field
    // first, which is what libheif and the specification mean, then the raw offset.
    let declared = u32::from_be_bytes(exif.get(0..4)?.try_into().ok()?) as usize;
    for base in [4usize.saturating_add(declared), declared] {
        let Some(tiff) = exif.get(base..) else { continue };
        if let Some(value) = read_tiff_resolution(tiff) {
            if value.is_finite() && (1.0..=9600.0).contains(&value) {
                return Some(value);
            }
        }
    }
    None
}

/// True when the file says its picture has an auxiliary alpha image.
///
/// The system decoder ignores those images today, so a caller can tell the user that transparency
/// was dropped rather than leaving it a mystery.
pub fn has_auxiliary_alpha(bytes: &[u8]) -> bool {
    let Some(meta) = find_meta(bytes) else { return false };
    // An auxl item reference is what ties an alpha item to its picture, so its presence means the
    // file carries more than the color picture.
    box_payloads(meta, b"iref").iter().any(|iref| {
        let body = iref.get(4..).unwrap_or(&[]);
        let mut cursor = 0usize;
        while cursor + 8 <= body.len() {
            let size = match body[cursor..cursor + 4].try_into() {
                Ok(value) => u32::from_be_bytes(value) as usize,
                Err(_) => break,
            };
            let kind = &body[cursor + 4..cursor + 8];
            if size < 8 || cursor + size > body.len() {
                break;
            }
            if kind == b"auxl" {
                return true;
            }
            cursor += size;
        }
        false
    })
}

/// The bytes of the file's Exif item, from the item and location tables.
fn exif_item(bytes: &[u8]) -> Option<Vec<u8>> {
    let meta = find_meta(bytes)?;
    let exif_id = item_infos(meta).into_iter().find(|(_, kind, _)| kind == b"Exif").map(|(id, _, _)| id)?;
    let spot = item_locations(meta).into_iter().find(|(id, _)| *id == exif_id).map(|(_, spot)| spot)?;
    let start = usize::try_from(spot.offset).ok()?;
    let end = start.checked_add(usize::try_from(spot.length).ok()?)?;
    Some(bytes.get(start..end)?.to_vec())
}

/// The payload of the meta box, which holds the item tables.
///
/// meta is a full box, so four bytes of version and flags come before its children.
fn find_meta(bytes: &[u8]) -> Option<&[u8]> {
    let mut cursor = 0usize;
    while cursor + 8 <= bytes.len() {
        let size = u32::from_be_bytes(bytes[cursor..cursor + 4].try_into().ok()?) as usize;
        let kind = &bytes[cursor + 4..cursor + 8];
        let (header, size) = if size == 1 {
            // A 64-bit size follows the type.
            if cursor + 16 > bytes.len() {
                return None;
            }
            let large = u64::from_be_bytes(bytes[cursor + 8..cursor + 16].try_into().ok()?);
            (16usize, usize::try_from(large).ok()?)
        } else if size == 0 {
            // A zero size means the box runs to the end of the file.
            (8usize, bytes.len() - cursor)
        } else {
            (8usize, size)
        };
        if size < header || cursor + size > bytes.len() {
            return None;
        }
        if kind == b"meta" {
            return bytes.get(cursor + header + 4..cursor + size);
        }
        cursor += size;
    }
    None
}

/// The payloads of every box of one type directly inside a container.
fn box_payloads<'a>(container: &'a [u8], wanted: &[u8; 4]) -> Vec<&'a [u8]> {
    let mut found = Vec::new();
    let mut cursor = 0usize;
    while cursor + 8 <= container.len() {
        let size = match container[cursor..cursor + 4].try_into() {
            Ok(value) => u32::from_be_bytes(value) as usize,
            Err(_) => break,
        };
        if size < 8 || cursor + size > container.len() {
            break;
        }
        if &container[cursor + 4..cursor + 8] == wanted {
            found.push(&container[cursor + 8..cursor + size]);
        }
        cursor += size;
    }
    found
}

/// The item table: every item's id, its four-character type and its name.
fn item_infos(meta: &[u8]) -> Vec<(u32, [u8; 4], Vec<u8>)> {
    let mut items = Vec::new();
    for payload in box_payloads(meta, b"iinf") {
        let Some(version) = payload.first().copied() else { continue };
        let mut cursor = 4usize;
        let count = if version == 0 {
            let value = read_u16(payload, cursor);
            cursor += 2;
            value.map(u32::from)
        } else {
            let value = read_u32(payload, cursor);
            cursor += 4;
            value
        };
        for _ in 0..count.unwrap_or(0) {
            let Some(size) = read_u32(payload, cursor) else { break };
            if size < 8 || cursor + size as usize > payload.len() {
                break;
            }
            let entry = &payload[cursor + 8..cursor + size as usize];
            let Some(entry_version) = entry.first().copied() else { break };
            // The item id is sixteen bits through version 2 and thirty-two bits from version 3, but
            // libheif writes a thirty-two bit id under version 2, so the four bytes after the
            // protection index are read and the layout that yields a printable four-character type
            // wins. Nothing else in the entry can be mistaken for one.
            let candidates: [(usize, bool); 2] = [(8, false), (10, true)];
            let mut parsed = false;
            for (type_at, wide_id) in candidates {
                let Some(kind): Option<[u8; 4]> =
                    entry.get(type_at..type_at + 4).and_then(|slice| slice.try_into().ok())
                else {
                    continue;
                };
                if !kind.iter().all(|byte| byte.is_ascii_graphic()) {
                    continue;
                }
                let id = if wide_id {
                    read_u32(entry, 4)
                } else if entry_version >= 3 {
                    read_u32(entry, 4)
                } else {
                    read_u16(entry, 4).map(u32::from)
                };
                if let Some(id) = id {
                    items.push((id, kind, entry.get(type_at + 4..).unwrap_or(&[]).to_vec()));
                    parsed = true;
                }
                break;
            }
            if !parsed && entry_version < 2 {
                // Before version 2 an item has no type, only a name.
                if let Some(id) = read_u16(entry, 4).map(u32::from) {
                    items.push((id, *b"    ", entry.get(8..).unwrap_or(&[]).to_vec()));
                }
            }
            cursor += size as usize;
        }
    }
    items
}

/// Where each item's bytes live, from the location table.
fn item_locations(meta: &[u8]) -> Vec<(u32, ItemLocation)> {
    let mut locations = Vec::new();
    for payload in box_payloads(meta, b"iloc") {
        let Some(version) = payload.first().copied() else { continue };
        let Some(sizes) = payload.get(4).copied() else { continue };
        let offset_size = (sizes >> 4) as usize;
        let length_size = (sizes & 0x0f) as usize;
        let Some(base_sizes) = payload.get(5).copied() else { continue };
        let base_offset_size = (base_sizes >> 4) as usize;
        let index_size = if version == 1 || version == 2 { (base_sizes & 0x0f) as usize } else { 0 };
        let mut cursor = 6usize;
        let count = if version < 2 {
            let value = read_u16(payload, cursor);
            cursor += 2;
            value.map(u32::from)
        } else {
            let value = read_u32(payload, cursor);
            cursor += 4;
            value
        };
        for _ in 0..count.unwrap_or(0) {
            let id = if version < 2 {
                let value = read_u16(payload, cursor);
                cursor += 2;
                value.map(u32::from)
            } else {
                let value = read_u32(payload, cursor);
                cursor += 4;
                value
            };
            if version == 1 || version == 2 {
                cursor += 2; // reserved and construction method
            }
            cursor += 2; // data reference index
            let Some(base_offset) = read_sized(payload, &mut cursor, base_offset_size) else { break };
            let Some(extent_count) = read_u16(payload, cursor) else { break };
            cursor += 2;
            let mut spot = ItemLocation { offset: base_offset, length: 0 };
            for index in 0..extent_count {
                if index_size > 0 && read_sized(payload, &mut cursor, index_size).is_none() {
                    break;
                }
                let Some(offset) = read_sized(payload, &mut cursor, offset_size) else { break };
                let Some(length) = read_sized(payload, &mut cursor, length_size) else { break };
                if index == 0 {
                    // Only the first extent is used: an Exif item of a still picture has one.
                    spot = ItemLocation { offset: base_offset + offset, length };
                }
            }
            if let Some(id) = id {
                locations.push((id, spot));
            }
        }
    }
    locations
}

fn read_u16(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes(bytes.get(at..at + 2)?.try_into().ok()?))
}

fn read_u32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes(bytes.get(at..at + 4)?.try_into().ok()?))
}

/// Reads a big-endian integer of up to eight bytes and moves the cursor past it.
fn read_sized(bytes: &[u8], cursor: &mut usize, size: usize) -> Option<u64> {
    if size > 8 {
        return None;
    }
    let slice = bytes.get(*cursor..*cursor + size)?;
    *cursor += size;
    let mut value = 0u64;
    for byte in slice {
        value = (value << 8) | u64::from(*byte);
    }
    Some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// One box: a four-character type and its payload.
    fn boxed(kind: &[u8; 4], payload: &[u8]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(&((payload.len() + 8) as u32).to_be_bytes());
        out.extend_from_slice(kind);
        out.extend_from_slice(payload);
        out
    }

    /// An infe box (version 3, with the 32-bit item id that version defines) for one item.
    fn infe(id: u32, kind: &[u8; 4]) -> Vec<u8> {
        let mut payload = vec![3, 0, 0, 0];
        payload.extend_from_slice(&id.to_be_bytes());
        payload.extend_from_slice(&0u16.to_be_bytes());
        payload.extend_from_slice(kind);
        payload.extend_from_slice(b"name\0");
        boxed(b"infe", &payload)
    }

    /// A minimized HEIF file: ftyp, a meta box with both item tables, then the item bodies.
    ///
    /// The locations are patched after the bodies are appended, exactly as a real writer lays the
    /// file out, so the parser walks the same shape a real file has.
    fn heif_with(exif: Option<&[u8]>, auxiliary_alpha: bool) -> Vec<u8> {
        let mut items = Vec::new();
        let mut locations: Vec<(u32, u32, u32)> = Vec::new();
        let mut body = Vec::new();
        let mut next_id = 1u32;

        if let Some(exif) = exif {
            items.push(infe(next_id, b"Exif"));
            locations.push((next_id, 0, exif.len() as u32));
            body.extend_from_slice(exif);
            next_id += 1;
        }
        let picture_id = next_id;
        items.push(infe(picture_id, b"hvc1"));
        locations.push((picture_id, body.len() as u32, 4));
        body.extend_from_slice(&[0, 0, 0, 0]);
        if auxiliary_alpha {
            next_id += 1;
            items.push(infe(next_id, b"hvc1"));
            locations.push((next_id, body.len() as u32, 4));
            body.extend_from_slice(&[0, 0, 0, 0]);
        }

        let mut iinf = vec![0, 0, 0, 0];
        iinf.extend_from_slice(&(items.len() as u16).to_be_bytes());
        for item in &items {
            iinf.extend_from_slice(item);
        }
        let mut iloc = vec![0, 0, 0, 0, 0x44, 0x00];
        iloc.extend_from_slice(&(locations.len() as u16).to_be_bytes());
        for (id, offset, length) in &locations {
            iloc.extend_from_slice(&(*id as u16).to_be_bytes());
            iloc.extend_from_slice(&0u16.to_be_bytes()); // data reference index
            iloc.extend_from_slice(&1u16.to_be_bytes()); // one extent
            iloc.extend_from_slice(&offset.to_be_bytes());
            iloc.extend_from_slice(&length.to_be_bytes());
        }
        let mut meta = vec![0, 0, 0, 0];
        meta.extend_from_slice(&boxed(b"iinf", &iinf));
        meta.extend_from_slice(&boxed(b"iloc", &iloc));
        if auxiliary_alpha {
            let mut reference = Vec::new();
            reference.extend_from_slice(&(picture_id as u16).to_be_bytes());
            reference.extend_from_slice(&((picture_id + 1) as u16).to_be_bytes());
            let mut iref = vec![0, 0, 0, 0];
            iref.extend_from_slice(&boxed(b"auxl", &reference));
            meta.extend_from_slice(&boxed(b"iref", &iref));
        }

        let mut file = boxed(b"ftyp", b"heic\x00\x00\x00\x00mif1heic");
        file.extend_from_slice(&boxed(b"meta", &meta));
        let base = file.len() as u32;
        file.extend_from_slice(&body);
        patch_locations(&mut file, base);
        file
    }

    /// Adds the item bodies' base offset to every entry, the way a real location table points.
    fn patch_locations(file: &mut [u8], base: u32) {
        let start = file.windows(4).position(|window| window == b"iloc").expect("an iloc box");
        let payload = start + 4 + 6;
        let count = u16::from_be_bytes([file[payload], file[payload + 1]]) as usize;
        let mut cursor = payload + 2;
        for _ in 0..count {
            cursor += 6; // id, data reference index and extent count
            let offset = u32::from_be_bytes(file[cursor..cursor + 4].try_into().unwrap());
            file[cursor..cursor + 4].copy_from_slice(&(base + offset).to_be_bytes());
            cursor += 8; // the offset and the length
        }
    }

    /// An Exif payload: the TIFF header offset, then a TIFF block declaring a resolution.
    fn exif_with_dpi(dpi: u32) -> Vec<u8> {
        let mut tiff = Vec::new();
        tiff.extend_from_slice(b"II\x2a\x00");
        tiff.extend_from_slice(&8u32.to_le_bytes());
        tiff.extend_from_slice(&3u16.to_le_bytes());
        tiff.extend_from_slice(&0x011Au16.to_le_bytes());
        tiff.extend_from_slice(&5u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        // The rationals follow the directory: eight bytes of header, two of entry count, three
        // twelve-byte entries and the four-byte next-directory offset.
        tiff.extend_from_slice(&50u32.to_le_bytes());
        tiff.extend_from_slice(&0x011Bu16.to_le_bytes());
        tiff.extend_from_slice(&5u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&58u32.to_le_bytes());
        tiff.extend_from_slice(&0x0128u16.to_le_bytes());
        tiff.extend_from_slice(&3u16.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&2u32.to_le_bytes());
        tiff.extend_from_slice(&0u32.to_le_bytes());
        tiff.extend_from_slice(&dpi.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        tiff.extend_from_slice(&dpi.to_le_bytes());
        tiff.extend_from_slice(&1u32.to_le_bytes());
        let mut payload = Vec::new();
        payload.extend_from_slice(&0u32.to_be_bytes());
        payload.extend_from_slice(&tiff);
        payload
    }




    #[test]
    fn a_libheif_file_with_a_resolution_is_read_the_same_way() {
        // libheif writes the item table with a 32-bit id under version 2 and puts the Exif block in
        // an item of its own; this is the real file the DPI test in heic.rs imports.
        let path = std::path::PathBuf::from(env!("CARGO_MANIFEST_DIR"))
            .join("tests")
            .join("fixtures")
            .join("heic_dpi.heic");
        if !path.exists() {
            return;
        }
        let bytes = std::fs::read(&path).unwrap();
        assert_eq!(read_heif_resolution(&bytes), Some(300.0));
    }

    #[test]
    fn a_heif_resolution_is_read_from_its_exif_item() {
        assert_eq!(read_heif_resolution(&heif_with(Some(&exif_with_dpi(300)), false)), Some(300.0));
        assert_eq!(read_heif_resolution(&heif_with(Some(&exif_with_dpi(72)), false)), Some(72.0));
    }

    #[test]
    fn a_file_without_an_exif_item_has_no_resolution() {
        assert_eq!(read_heif_resolution(&heif_with(None, false)), None);
        assert_eq!(read_heif_resolution(b"not a heif file"), None);
        assert_eq!(read_heif_resolution(&[]), None);
    }

    #[test]
    fn a_resolution_outside_the_format_limits_is_ignored() {
        assert_eq!(read_heif_resolution(&heif_with(Some(&exif_with_dpi(0)), false)), None);
        assert_eq!(read_heif_resolution(&heif_with(Some(&exif_with_dpi(20_000)), false)), None);
    }


    #[test]
    fn an_auxiliary_alpha_reference_is_found() {
        assert!(!has_auxiliary_alpha(&heif_with(None, false)));
        assert!(has_auxiliary_alpha(&heif_with(None, true)));
        assert!(!has_auxiliary_alpha(b"not a heif file"));
    }
}
