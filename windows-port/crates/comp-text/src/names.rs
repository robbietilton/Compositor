//! A minimal SFNT `name`-table reader.
//!
//! `fontdue` exposes one name per face (name ID 4, the full name), but mapping the macOS face
//! names a `.comp` file stores onto the faces a Windows machine actually has needs all of
//! them: family, subfamily, full and PostScript. Reading the table here keeps that mapping free of a
//! second font dependency, and of the C toolchain one would drag in.

use std::collections::BTreeMap;

/// Name IDs the index uses, from the OpenType `name` table specification.
const ID_FAMILY: u16 = 1;
const ID_SUBFAMILY: u16 = 2;
const ID_FULL: u16 = 4;
const ID_POST_SCRIPT: u16 = 6;
const ID_TYPOGRAPHIC_FAMILY: u16 = 16;
const ID_TYPOGRAPHIC_SUBFAMILY: u16 = 17;

/// The names one face answers to. Absent records stay empty rather than guessing.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct FontNames {
    pub family: Option<String>,
    pub subfamily: Option<String>,
    pub full_name: Option<String>,
    pub post_script: Option<String>,
    pub typographic_family: Option<String>,
    pub typographic_subfamily: Option<String>,
}

impl FontNames {
    /// The family to show a user: the typographic family when the face has one, since that is the
    /// name that groups every weight ("Segoe UI", not "Segoe UI Semibold").
    pub fn display_family(&self) -> Option<&str> {
        self.typographic_family.as_deref().or(self.family.as_deref())
    }

    /// Every distinct name this face can be asked for, most specific last.
    ///
    /// The typographic family groups every weight of a design — "Arial" is the typographic family of
    /// "Arial Narrow" — so it answers for a face only when that face has no style of its own.
    /// Otherwise the narrow face would take over the name "Arial" for the whole font set.
    pub fn keys(&self) -> Vec<String> {
        let mut keys = Vec::new();
        for name in [&self.family, &self.full_name, &self.post_script].into_iter().flatten() {
            push_key(&mut keys, name);
        }
        if let (Some(family), Some(subfamily)) = (self.family.as_deref(), self.subfamily.as_deref()) {
            push_key(&mut keys, &format!("{family}{subfamily}"));
        }
        let typographic_subfamily = self.typographic_subfamily.as_deref().unwrap_or("");
        if let Some(family) = self.typographic_family.as_deref() {
            if typographic_subfamily.is_empty() {
                push_key(&mut keys, family);
            } else {
                push_key(&mut keys, &format!("{family}{typographic_subfamily}"));
                if normalize(typographic_subfamily) == "regular" {
                    push_key(&mut keys, family);
                }
            }
        }
        keys
    }
}

/// Reads the face names at `collection_index` out of a TTF/OTF/TTC byte string.
pub fn parse(data: &[u8], collection_index: u32) -> Option<FontNames> {
    let face = face_offset(data, collection_index)?;
    let num_tables = read_u16(data, face + 4)? as usize;
    let records = face.checked_add(12)?;
    let mut name_table = None;
    for index in 0..num_tables {
        let record = records.checked_add(index.checked_mul(16)?)?;
        let Some(tag) = data.get(record..record + 4) else { continue };
        if tag == b"name" {
            let offset = read_u32(data, record + 8)? as usize;
            let length = read_u32(data, record + 12)? as usize;
            name_table = Some((offset, length));
            break;
        }
    }
    let (offset, length) = name_table?;
    let table = data.get(offset..offset.checked_add(length)?)?;
    parse_name_table(table)
}

/// How many faces a byte string holds: one, or the count in a TrueType collection header.
pub fn face_count(data: &[u8]) -> u32 {
    if data.len() >= 12 && &data[0..4] == b"ttcf" {
        read_u32(data, 8).unwrap_or(1)
    } else {
        1
    }
}

/// The offset of one face's table directory inside a single font or a collection.
fn face_offset(data: &[u8], collection_index: u32) -> Option<usize> {
    if data.len() < 12 {
        return None;
    }
    if &data[0..4] == b"ttcf" {
        let count = read_u32(data, 8)?;
        if collection_index >= count {
            return None;
        }
        let entry = 12usize.checked_add(collection_index as usize * 4)?;
        Some(read_u32(data, entry)? as usize)
    } else if collection_index == 0 {
        Some(0)
    } else {
        None
    }
}

fn parse_name_table(table: &[u8]) -> Option<FontNames> {
    let count = read_u16(table, 2)? as usize;
    let string_offset = read_u16(table, 4)? as usize;
    // The best-scoring record per name ID: a Windows English record beats a Mac one, and the first
    // record of equal score wins so a font's own ordering decides ties.
    let mut best: BTreeMap<u16, (u8, String)> = BTreeMap::new();
    for index in 0..count {
        let record = 6usize.checked_add(index.checked_mul(12)?)?;
        let Some(platform) = read_u16(table, record) else { continue };
        let Some(encoding) = read_u16(table, record + 2) else { continue };
        let Some(language) = read_u16(table, record + 4) else { continue };
        let Some(name_id) = read_u16(table, record + 6) else { continue };
        let Some(length) = read_u16(table, record + 8) else { continue };
        let Some(offset) = read_u16(table, record + 10) else { continue };
        let start = string_offset.checked_add(offset as usize);
        let end = start.and_then(|start| start.checked_add(length as usize));
        let (Some(start), Some(end)) = (start, end) else { continue };
        let Some(bytes) = table.get(start..end) else { continue };
        let Some(text) = decode(platform, encoding, bytes) else { continue };
        let text = text.trim().to_string();
        if text.is_empty() {
            continue;
        }
        let score = score(platform, encoding, language);
        match best.get(&name_id) {
            Some((existing, _)) if *existing >= score => {}
            _ => {
                best.insert(name_id, (score, text));
            }
        }
    }
    if best.is_empty() {
        return None;
    }
    let take = |id: u16| best.get(&id).map(|(_, text)| text.clone());
    Some(FontNames {
        family: take(ID_FAMILY),
        subfamily: take(ID_SUBFAMILY).or_else(|| take(ID_TYPOGRAPHIC_SUBFAMILY)),
        full_name: take(ID_FULL),
        post_script: take(ID_POST_SCRIPT),
        typographic_family: take(ID_TYPOGRAPHIC_FAMILY),
        typographic_subfamily: take(ID_TYPOGRAPHIC_SUBFAMILY),
    })
}

/// Ranks a name record: ASCII-only Mac names lose to Unicode Windows ones.
fn score(platform: u16, encoding: u16, language: u16) -> u8 {
    match platform {
        3 if language == 0x0409 && (encoding == 1 || encoding == 10) => 4,
        3 => 3,
        0 => 2,
        1 if language == 0 => 1,
        _ => 0,
    }
}

fn decode(platform: u16, _encoding: u16, bytes: &[u8]) -> Option<String> {
    match platform {
        0 | 3 => {
            let units: Vec<u16> = bytes.chunks_exact(2).map(|pair| u16::from_be_bytes([pair[0], pair[1]])).collect();
            Some(String::from_utf16_lossy(&units))
        }
        // Mac and ISO records are single-byte; face names are ASCII in practice, so a Latin-1 read
        // is exact for them.
        _ => Some(bytes.iter().map(|byte| *byte as char).collect()),
    }
}

fn read_u16(data: &[u8], offset: usize) -> Option<u16> {
    let bytes = data.get(offset..offset + 2)?;
    Some(u16::from_be_bytes([bytes[0], bytes[1]]))
}

fn read_u32(data: &[u8], offset: usize) -> Option<u32> {
    let bytes = data.get(offset..offset + 4)?;
    Some(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
}

fn push_key(keys: &mut Vec<String>, name: &str) {
    let key = normalize(name);
    if !key.is_empty() && !keys.contains(&key) {
        keys.push(key);
    }
}

/// A lookup key for a face name: case-folded, with every space, hyphen and dot removed, so
/// "Helvetica-Bold", "Helvetica Bold" and "helveticabold" are one name.
pub fn normalize(name: &str) -> String {
    name.chars().filter(|c| c.is_alphanumeric()).flat_map(|c| c.to_lowercase()).collect()
}

/// The style words a face name may carry, longest first so "semibold" is not read as "bold".
const BOLD_WORDS: [&str; 6] = ["extrabold", "ultrabold", "semibold", "demibold", "black", "bold"];
const HEAVY_WORDS: [&str; 2] = ["heavy", "extrabold"];
const ITALIC_WORDS: [&str; 2] = ["italic", "oblique"];

/// The weight and slant a face name asks for.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub struct StyleHints {
    pub bold: bool,
    pub italic: bool,
}

/// Reads the weight and slant out of an already normalized name.
pub fn style_hints(key: &str) -> StyleHints {
    StyleHints {
        bold: BOLD_WORDS.iter().any(|word| key.contains(word)) || HEAVY_WORDS.iter().any(|w| key.contains(w)),
        italic: ITALIC_WORDS.iter().any(|word| key.contains(word)),
    }
}

/// The same name without its style words: "arialboldoblique" becomes "arial".
pub fn strip_style_words(key: &str) -> String {
    let mut stripped = key.to_string();
    for word in BOLD_WORDS.iter().chain(HEAVY_WORDS.iter()).chain(ITALIC_WORDS.iter()) {
        stripped = stripped.replace(word, "");
    }
    // "regular", "medium" and "book" carry no weight of their own but do hide the family.
    for word in ["regular", "medium", "book", "normal"] {
        stripped = stripped.replace(word, "");
    }
    stripped
}

#[cfg(test)]
mod tests {
    use super::*;

    /// Builds a one-face SFNT byte string with a `name` table holding `records`.
    fn synthetic_font(records: &[(u16, u16, u16, u16, &str)]) -> Vec<u8> {
        synthetic_font_at(records, 0)
    }

    /// The same, for a face placed at `base` inside a collection: table offsets in a face's
    /// directory are absolute file offsets, so an embedded face has to account for where it sits.
    fn synthetic_font_at(records: &[(u16, u16, u16, u16, &str)], base: usize) -> Vec<u8> {
        let mut name = Vec::new();
        name.extend_from_slice(&0u16.to_be_bytes()); // format 0
        name.extend_from_slice(&(records.len() as u16).to_be_bytes());
        name.extend_from_slice(&(6u16 + records.len() as u16 * 12).to_be_bytes()); // string offset
        let mut strings = Vec::new();
        for (platform, encoding, language, name_id, text) in records {
            let utf16: Vec<u8> =
                text.encode_utf16().flat_map(|unit| unit.to_be_bytes()).collect();
            name.extend_from_slice(&platform.to_be_bytes());
            name.extend_from_slice(&encoding.to_be_bytes());
            name.extend_from_slice(&language.to_be_bytes());
            name.extend_from_slice(&name_id.to_be_bytes());
            name.extend_from_slice(&(utf16.len() as u16).to_be_bytes());
            name.extend_from_slice(&(strings.len() as u16).to_be_bytes());
            strings.extend_from_slice(&utf16);
        }
        name.extend_from_slice(&strings);

        let header_end = 12 + 16;
        let mut font = Vec::new();
        font.extend_from_slice(&0x0001_0000u32.to_be_bytes());
        font.extend_from_slice(&1u16.to_be_bytes()); // numTables
        font.extend_from_slice(&0u16.to_be_bytes());
        font.extend_from_slice(&0u16.to_be_bytes());
        font.extend_from_slice(&0u16.to_be_bytes());
        font.extend_from_slice(b"name");
        font.extend_from_slice(&0u32.to_be_bytes());
        font.extend_from_slice(&((base + header_end) as u32).to_be_bytes());
        font.extend_from_slice(&(name.len() as u32).to_be_bytes());
        font.extend_from_slice(&name);
        font
    }

    fn windows_record(name_id: u16, text: &str) -> (u16, u16, u16, u16, &str) {
        (3, 1, 0x0409, name_id, text)
    }

    #[test]
    fn reads_every_name_id() {
        let font = synthetic_font(&[
            windows_record(ID_FAMILY, "Segoe UI"),
            windows_record(ID_SUBFAMILY, "Semibold"),
            windows_record(ID_FULL, "Segoe UI Semibold"),
            windows_record(ID_POST_SCRIPT, "SegoeUI-Semibold"),
            windows_record(ID_TYPOGRAPHIC_FAMILY, "Segoe UI"),
        ]);
        let names = parse(&font, 0).unwrap();
        assert_eq!(names.family.as_deref(), Some("Segoe UI"));
        assert_eq!(names.subfamily.as_deref(), Some("Semibold"));
        assert_eq!(names.full_name.as_deref(), Some("Segoe UI Semibold"));
        assert_eq!(names.post_script.as_deref(), Some("SegoeUI-Semibold"));
        assert_eq!(names.display_family(), Some("Segoe UI"));
    }

    #[test]
    fn windows_records_beat_mac_records() {
        let font = synthetic_font(&[
            (1, 0, 0, ID_FAMILY, "Old Mac"),
            (3, 1, 0x0409, ID_FAMILY, "Windows Win"),
        ]);
        assert_eq!(parse(&font, 0).unwrap().family.as_deref(), Some("Windows Win"));
    }

    #[test]
    fn malformed_input_is_rejected_without_panicking() {
        assert!(parse(&[], 0).is_none());
        assert!(parse(&[0, 1, 0, 0], 0).is_none());
        let mut truncated = synthetic_font(&[windows_record(ID_FAMILY, "Arial")]);
        truncated.truncate(truncated.len() - 4);
        // A record whose string runs past the table is dropped, leaving nothing to report.
        assert!(parse(&truncated, 0).is_none());
        assert!(parse(&synthetic_font(&[windows_record(ID_FAMILY, "Arial")]), 3).is_none());
    }

    #[test]
    fn collection_offsets_select_a_face() {
        let base = 12 + 8;
        let face = synthetic_font_at(&[windows_record(ID_FAMILY, "Face")], base);
        let mut collection = Vec::new();
        collection.extend_from_slice(b"ttcf");
        collection.extend_from_slice(&0x0001_0000u32.to_be_bytes());
        collection.extend_from_slice(&2u32.to_be_bytes());
        collection.extend_from_slice(&(base as u32).to_be_bytes());
        collection.extend_from_slice(&((base + face.len()) as u32).to_be_bytes());
        collection.extend_from_slice(&face);
        collection.extend_from_slice(&face);
        assert_eq!(face_count(&collection), 2);
        assert_eq!(parse(&collection, 0).unwrap().family.as_deref(), Some("Face"));
        assert!(parse(&collection, 2).is_none());
        assert_eq!(face_count(&face), 1);
    }

    #[test]
    fn keys_cover_family_style_and_script_names() {
        let names = FontNames {
            family: Some("Arial".into()),
            subfamily: Some("Bold".into()),
            full_name: Some("Arial Bold".into()),
            post_script: Some("Arial-BoldMT".into()),
            ..FontNames::default()
        };
        let keys = names.keys();
        assert!(keys.contains(&"arial".to_string()), "{keys:?}");
        assert!(keys.contains(&"arialbold".to_string()), "{keys:?}");
        assert!(keys.contains(&"arialboldmt".to_string()), "{keys:?}");
        assert!(!keys.contains(&"".to_string()));
    }

    #[test]
    fn a_narrow_face_does_not_take_over_its_typographic_family() {
        // Arial Narrow really is typographic family "Arial" with subfamily "Narrow"; if it answered
        // to "Arial", every Helvetica request would land on the narrow face.
        let names = FontNames {
            family: Some("Arial Narrow".into()),
            subfamily: Some("Regular".into()),
            full_name: Some("Arial Narrow".into()),
            post_script: Some("ArialNarrow".into()),
            typographic_family: Some("Arial".into()),
            typographic_subfamily: Some("Narrow".into()),
        };
        let keys = names.keys();
        assert!(!keys.contains(&"arial".to_string()), "{keys:?}");
        assert!(keys.contains(&"arialnarrow".to_string()), "{keys:?}");
        assert!(keys.contains(&"arialnarrowregular".to_string()), "{keys:?}");
    }

    #[test]
    fn a_plain_typographic_family_is_a_key() {
        let names = FontNames {
            family: Some("Arial".into()),
            subfamily: Some("Regular".into()),
            full_name: Some("Arial".into()),
            post_script: Some("ArialMT".into()),
            typographic_family: Some("Arial".into()),
            typographic_subfamily: Some("Regular".into()),
        };
        let keys = names.keys();
        assert!(keys.contains(&"arial".to_string()), "{keys:?}");
        assert!(keys.contains(&"arialmt".to_string()), "{keys:?}");
    }

    #[test]
    fn normalization_folds_punctuation_and_case() {
        assert_eq!(normalize("Helvetica-Bold"), "helveticabold");
        assert_eq!(normalize("Times New Roman"), "timesnewroman");
        assert_eq!(normalize("Arial.Bold MT"), "arialboldmt");
        assert_eq!(normalize("微软雅黑"), "微软雅黑");
        assert_eq!(normalize("---"), "");
    }

    #[test]
    fn style_hints_read_weight_and_slant() {
        assert_eq!(style_hints("arialbold"), StyleHints { bold: true, italic: false });
        assert_eq!(style_hints("arialboldoblique"), StyleHints { bold: true, italic: true });
        assert_eq!(style_hints("segoeuisemibold"), StyleHints { bold: true, italic: false });
        assert_eq!(style_hints("timesitalic"), StyleHints { bold: false, italic: true });
        assert_eq!(style_hints("arial"), StyleHints::default());
        assert_eq!(strip_style_words("arialboldoblique"), "arial");
        assert_eq!(strip_style_words("segoeuisemibold"), "segoeui");
        assert_eq!(strip_style_words("helveticaregular"), "helvetica");
    }
}
