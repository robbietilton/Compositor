//! A probe, not a feature: how much of seguiemj's version 1 paint graph a renderer would have to
//! understand to draw its emoji. It counts, it does not draw.

use rustybuzz::ttf_parser::colr::{ClipBox, CompositeMode, Paint, Painter, Table};
use rustybuzz::ttf_parser::{cpal, GlyphId, RgbaColor, Transform};

/// What one glyph's paint graph needs, and how deep it nests.
#[derive(Default, Debug)]
struct Needs {
    outlines: usize,
    solids: usize,
    gradients: usize,
    transforms: usize,
    clips: usize,
    layers: usize,
    depth: usize,
    max_depth: usize,
}

impl Needs {
    fn enter(&mut self) {
        self.depth += 1;
        self.max_depth = self.max_depth.max(self.depth);
    }

    fn leave(&mut self) {
        self.depth = self.depth.saturating_sub(1);
    }
}

impl<'a> Painter<'a> for Needs {
    fn outline_glyph(&mut self, _glyph: GlyphId) {
        self.outlines += 1;
    }
    fn paint(&mut self, paint: Paint<'a>) {
        match paint {
            Paint::Solid(_) => self.solids += 1,
            _ => self.gradients += 1,
        }
    }
    fn push_clip(&mut self) {
        self.clips += 1;
        self.enter();
    }
    fn push_clip_box(&mut self, _clipbox: ClipBox) {
        self.clips += 1;
        self.enter();
    }
    fn pop_clip(&mut self) {
        self.leave();
    }
    fn push_layer(&mut self, _mode: CompositeMode) {
        self.layers += 1;
        self.enter();
    }
    fn pop_layer(&mut self) {
        self.leave();
    }
    fn push_transform(&mut self, _transform: Transform) {
        self.transforms += 1;
        self.enter();
    }
    fn pop_transform(&mut self) {
        self.leave();
    }
}

fn table<'a>(bytes: &'a [u8], tag: &[u8; 4]) -> Option<&'a [u8]> {
    let count = u16::from_be_bytes([*bytes.get(4)?, *bytes.get(5)?]) as usize;
    for index in 0..count {
        let record = bytes.get(12 + index * 16..12 + index * 16 + 16)?;
        if &record[..4] != tag {
            continue;
        }
        let offset = u32::from_be_bytes([record[8], record[9], record[10], record[11]]) as usize;
        let length = u32::from_be_bytes([record[12], record[13], record[14], record[15]]) as usize;
        return bytes.get(offset..offset.checked_add(length)?);
    }
    None
}

#[test]
fn probe_v1_paint_graph_coverage() {
    let Ok(bytes) = std::fs::read("C:/Windows/Fonts/seguiemj.ttf") else {
        println!("no colour face on this machine");
        return;
    };
    let (Some(colr_slice), Some(cpal_slice)) = (table(&bytes, b"COLR"), table(&bytes, b"CPAL")) else {
        println!("no COLR or no CPAL table");
        return;
    };
    let Some(palettes) = cpal::Table::parse(cpal_slice) else {
        println!("CPAL did not parse");
        return;
    };
    let Some(colr) = Table::parse(palettes, colr_slice) else {
        println!("COLR did not parse");
        return;
    };
    println!("COLR parsed, version {}", if colr.is_simple() { "simple" } else { "not simple" });

    let mut painted = 0usize;
    let mut simple = 0usize;
    let mut needs_gradient = 0usize;
    let mut needs_transform = 0usize;
    let mut both = 0usize;
    let mut max_depth = 0usize;
    let mut outlines = 0usize;
    let mut solids = 0usize;
    let mut gradients = 0usize;
    let mut attempted = 0usize;
    for id in 0..6000u16 {
        if painted >= 200 {
            break;
        }
        attempted += 1;
        let mut needs = Needs::default();
        let foreground = RgbaColor { red: 0, green: 0, blue: 0, alpha: 255 };
        if colr.paint(GlyphId(id), 0, &mut needs, &[], foreground).is_none()
            || needs.outlines + needs.solids + needs.gradients == 0
        {
            continue;
        }
        painted += 1;
        outlines += needs.outlines;
        solids += needs.solids;
        gradients += needs.gradients;
        max_depth = max_depth.max(needs.max_depth);
        match (needs.gradients > 0, needs.transforms > 0) {
            (false, false) => simple += 1,
            (true, true) => both += 1,
            (true, false) => needs_gradient += 1,
            (false, true) => needs_transform += 1,
        }
    }
    println!("sampled {painted} painted glyphs out of {attempted} ids tried");
    println!("  only outlines, solids, clips and layers: {simple}");
    println!("  needs a gradient: {needs_gradient}, needs a transform: {needs_transform}, needs both: {both}");
    println!("  totals: {outlines} outlines, {solids} solids, {gradients} gradients, deepest nesting {max_depth}");
    if painted > 0 {
        let percent = simple as f64 * 100.0 / painted as f64;
        println!(
            "  coverage with solids and outlines alone: {percent:.1}% ({})",
            if percent >= 70.0 { "worth implementing" } else { "not worth it on this face" }
        );
    }
}
