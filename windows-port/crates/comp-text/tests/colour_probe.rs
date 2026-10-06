//! Temporary probe: which colour tables the machine's emoji faces carry, read properly.

fn be16(bytes: &[u8], at: usize) -> Option<u16> {
    Some(u16::from_be_bytes([*bytes.get(at)?, *bytes.get(at + 1)?]))
}
fn be32(bytes: &[u8], at: usize) -> Option<u32> {
    Some(u32::from_be_bytes([*bytes.get(at)?, *bytes.get(at + 1)?, *bytes.get(at + 2)?, *bytes.get(at + 3)?]))
}

fn probe(path: &str) {
    let Ok(bytes) = std::fs::read(path) else { return };
    let Some(num_tables) = be16(&bytes, 4) else { return };
    let mut found: Vec<(String, u32, u32)> = Vec::new();
    for index in 0..num_tables as usize {
        let record = 12 + index * 16;
        let Some(tag) = bytes.get(record..record + 4) else { break };
        let tag = String::from_utf8_lossy(tag).to_string();
        let (Some(offset), Some(length)) = (be32(&bytes, record + 8), be32(&bytes, record + 12)) else { break };
        if matches!(tag.as_str(), "COLR" | "CPAL" | "CBDT" | "CBLC" | "sbix" | "SVG ") {
            found.push((tag, offset, length));
        }
    }
    print!("{}: {} tables, colour tables {:?}", path.rsplit('\\').next().unwrap_or(path), num_tables, found.iter().map(|(tag, _, _)| tag.as_str()).collect::<Vec<_>>());
    for (tag, offset, length) in &found {
        let offset = *offset as usize;
        if tag == "COLR" {
            let version = be16(&bytes, offset).unwrap_or(0);
            let bases = be16(&bytes, offset + 2).unwrap_or(0);
            let layers = be16(&bytes, offset + 12).unwrap_or(0);
            print!(" [COLR v{version}: {bases} base glyphs, {layers} layer records]");
        }
        if tag == "CPAL" {
            let version = be16(&bytes, offset).unwrap_or(0);
            let entries = be16(&bytes, offset + 4).unwrap_or(0);
            let palettes = be16(&bytes, offset + 6).unwrap_or(0);
            print!(" [CPAL v{version}: {entries} entries, {palettes} palettes, {length} bytes]");
        }
    }
    println!();
}

#[test]
fn probe_colour_tables() {
    for path in [
        "C:\\Windows\\Fonts\\seguiemj.ttf",
        "C:\\Windows\\Fonts\\segoeui.ttf",
        "C:\\Windows\\Fonts\\seguisym.ttf",
        "C:\\Windows\\Fonts\\msyh.ttc",
    ] {
        probe(path);
    }
}
