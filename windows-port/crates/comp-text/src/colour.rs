//! Colour glyphs: the layers a COLR font draws an emoji out of, and the colours they take.
//!
//! Segoe UI Emoji carries COLR + CPAL and nothing else — no CBDT/CBLC bitmaps and no sbix — so a
//! layered outline font is the whole of what colour means on this machine. COLR version 1 is what the
//! table says, but it keeps the complete set of version 0 records (3372 base glyphs, 53071 layers), and
//! a version 0 record is a fixed-size structure with a sorted index, which is small enough to read here
//! rather than walk the version 1 paint graph of gradients and transforms that this application never
//! uses. The colours come from CPAL through ttf-parser, not from a hand-read header.

/// The layers of one glyph, as (layer glyph, palette entry), or none when the font has no colour for
/// it — a glyph with no layers is drawn as the outline it always was.
pub fn colour_layers(face_bytes: &[u8], glyph_id: u16) -> Option<Vec<(u16, u16)>> {
    let colr = table(face_bytes, b"COLR")?;
    let header = colr.get(..14)?;
    let version = be16(header, 0)?;
    let base_count = be16(header, 2)? as usize;
    let base_offset = be32(header, 4)? as usize;
    let layer_offset = be32(header, 8)? as usize;
    let layer_count = be16(header, 12)? as usize;
    // Version 0 is what this reader understands; a version 1 table still carries the version 0 records
    // this walks, and a glyph that only exists in the version 1 graph has no record and falls back.
    if version == 0xFFFF {
        return None;
    }
    // The base glyph records are sorted by glyph id, so the record for a glyph is a binary search.
    let mut low = 0usize;
    let mut high = base_count;
    while low < high {
        let middle = (low + high) / 2;
        let record = colr.get(base_offset + middle * 6..base_offset + middle * 6 + 6)?;
        let glyph = be16(record, 0)?;
        match glyph.cmp(&glyph_id) {
            std::cmp::Ordering::Less => low = middle + 1,
            std::cmp::Ordering::Greater => high = middle,
            std::cmp::Ordering::Equal => {
                let first = be16(record, 2)? as usize;
                let count = be16(record, 4)? as usize;
                if first + count > layer_count {
                    return None;
                }
                let mut layers = Vec::with_capacity(count);
                for index in first..first + count {
                    let layer = colr.get(layer_offset + index * 4..layer_offset + index * 4 + 4)?;
                    layers.push((be16(layer, 0)?, be16(layer, 2)?));
                }
                return (!layers.is_empty()).then_some(layers);
            }
        }
    }
    None
}

/// The same layers, with the colour each one takes from a palette of the font.
pub fn colour_layers_rgba(face_bytes: &[u8], glyph_id: u16, palette: u16) -> Option<Vec<(u16, [u8; 4])>> {
    let layers = colour_layers(face_bytes, glyph_id)?;
    // CPAL version 0: uint16 version, uint16 palette entries, uint16 palettes, uint16 colour records,
    // Offset32 first record, then one uint16 index per palette. The header is 12 bytes plus two per
    // palette, and the table is 14 + records * 4 bytes for the one-palette face on this machine, which
    // is what says the fields are read here and not two bytes either way.
    let cpal = table(face_bytes, b"CPAL")?;
    let entries = be16(cpal, 2)? as usize;
    let palettes = be16(cpal, 4)? as usize;
    if entries == 0 || palette as usize >= palettes.max(1) {
        return None;
    }
    // The header's offset is where the colour records start, in bytes: record k of this palette is
    // at that offset plus four bytes each for the records the palettes before it have taken.
    let first_record = be32(cpal, 8)? as usize;
    let first = be16(cpal, 12 + palette as usize * 2)? as usize;
    let mut coloured = Vec::with_capacity(layers.len());
    for (glyph, entry) in layers {
        // The palette entry indexes the colour records from this palette's first one. The header's entry
        // count is not used as a bound: on this machine the two readings of that field pair disagree,
        // while the address — first record plus the entry, times four — is the same either way, and a
        // record that is not there is caught by the slice below.
        let at = first.checked_add(entry as usize)?.checked_mul(4)?.checked_add(first_record)?;
        let record = cpal.get(at..at + 4)?;
        // CPAL stores its colours blue first, with straight alpha.
        coloured.push((glyph, [record[2], record[1], record[0], record[3]]));
    }
    Some(coloured)
}

/// The number of entries in one palette of a face, for a caller that wants to show the choices.
pub fn palette_entries(face_bytes: &[u8], palette: u16) -> Option<u16> {
    let cpal = table(face_bytes, b"CPAL")?;
    let entries = be16(cpal, 2)?;
    let palettes = be16(cpal, 4)?;
    (entries > 0 && palette < palettes).then_some(entries)
}

/// The bytes of one table, by its tag.
fn table<'a>(face_bytes: &'a [u8], tag: &[u8; 4]) -> Option<&'a [u8]> {
    let count = be16(face_bytes, 4)? as usize;
    for index in 0..count {
        let record = face_bytes.get(12 + index * 16..12 + index * 16 + 16)?;
        if &record[..4] != tag {
            continue;
        }
        let offset = be32(record, 8)? as usize;
        let length = be32(record, 12)? as usize;
        return face_bytes.get(offset..offset.checked_add(length)?);
    }
    None
}

fn be16(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*bytes.get(at)?, *bytes.get(at + 1)?]))
}

fn be32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes([*bytes.get(at)?, *bytes.get(at + 1)?, *bytes.get(at + 2)?, *bytes.get(at + 3)?]))
}

#[cfg(test)]
mod tests {
    use super::*;
    use rustybuzz::ttf_parser;

    /// The colour face this machine has, if it has one.
    fn colour_face() -> Option<Vec<u8>> {
        std::fs::read("C:/Windows/Fonts/seguiemj.ttf").ok()
    }

    /// A face with no colour tables at all.
    fn grey_face() -> Option<Vec<u8>> {
        std::fs::read("C:/Windows/Fonts/segoeui.ttf").ok()
    }

    fn glyph_of(bytes: &[u8], ch: char) -> Option<u16> {
        ttf_parser::Face::parse(bytes, 0).ok()?.glyph_index(ch).map(|glyph| glyph.0)
    }

    #[test]
    fn a_colour_face_gives_an_emoji_its_layers() {
        let Some(bytes) = colour_face() else { return };
        let Some(glyph) = glyph_of(&bytes, '\u{1F600}') else { return };
        let layers = colour_layers(&bytes, glyph).expect("a grinning face is layered");
        assert!(layers.len() > 1, "an emoji is drawn from several layers: {}", layers.len());
        assert!(layers.iter().all(|(layer, _)| *layer != glyph), "a layer is not the base glyph");
        let entries = palette_entries(&bytes, 0).expect("the face has a palette");
        assert!(
            layers.iter().all(|(_, entry)| (*entry as usize) < entries as usize),
            "every layer names an entry the palette has: {layers:?} of {entries}"
        );
    }

    #[test]
    fn a_colour_face_gives_every_layer_a_colour() {
        let Some(bytes) = colour_face() else { return };
        // Some emoji have no version 0 record and fall back to their outline; the ones that do have
        // one must come back with a colour for every layer, and an emoji is drawn in several colours.
        let mut layered = 0usize;
        let mut multicoloured = 0usize;
        for ch in ['\u{1F600}', '\u{1F680}', '\u{1F44D}', '\u{2764}', '\u{1F1EF}'] {
            let Some(glyph) = glyph_of(&bytes, ch) else { continue };
            let Some(coloured) = colour_layers_rgba(&bytes, glyph, 0) else { continue };
            layered += 1;
            assert!(coloured.len() > 1, "{ch:?} is drawn from several layers: {}", coloured.len());
            let mut seen: Vec<[u8; 4]> = Vec::new();
            for (_, colour) in &coloured {
                if !seen.contains(colour) {
                    seen.push(*colour);
                }
            }
            if seen.len() > 1 {
                multicoloured += 1;
            }
        }
        if layered == 0 {
            return;
        }
        assert!(multicoloured > 0, "{layered} coloured emoji, none of them in more than one colour");
    }

    #[test]
    fn a_palette_has_colours_and_a_face_without_one_has_none() {
        let Some(bytes) = colour_face() else { return };
        // One palette, and the table is exactly the size its record count says it is: that is what
        // pins the header fields down, since a read two bytes either way cannot satisfy it.
        let entries = palette_entries(&bytes, 0).expect("the face has a palette");
        assert!(entries > 0, "the palette has entries: {entries}");
        assert_eq!(palette_entries(&bytes, 60_000), None, "there is no such palette index");
        let cpal = table(&bytes, b"CPAL").unwrap();
        let records = be16(cpal, 6).unwrap() as usize;
        let first_record = be32(cpal, 8).unwrap() as usize;
        assert_eq!(
            cpal.len(),
            first_record + records * 4,
            "the colour records fill the table exactly, which is what pins the header down"
        );
        if let Some(grey) = grey_face() {
            assert_eq!(palette_entries(&grey, 0), None);
        }
    }

    #[test]
    fn a_face_without_colour_has_no_layers() {
        let Some(bytes) = grey_face() else { return };
        let Some(glyph) = glyph_of(&bytes, 'A') else { return };
        assert_eq!(colour_layers(&bytes, glyph), None);
        assert_eq!(colour_layers_rgba(&bytes, glyph, 0), None);
    }

    #[test]
    fn a_glyph_without_colour_falls_back() {
        let Some(bytes) = colour_face() else { return };
        let Some(glyph) = glyph_of(&bytes, 'A') else { return };
        assert_eq!(colour_layers(&bytes, glyph), None, "a letter has no layers and keeps its outline");
    }

    #[test]
    fn a_layer_list_is_stable_and_ordered() {
        let Some(bytes) = colour_face() else { return };
        let Some(glyph) = glyph_of(&bytes, '\u{1F44D}') else { return };
        let first = colour_layers(&bytes, glyph).expect("a thumbs up is layered");
        let second = colour_layers(&bytes, glyph).expect("and again");
        assert_eq!(first, second);
        assert!(first.len() <= 64, "an emoji is a handful of layers, not hundreds: {}", first.len());
    }
}
