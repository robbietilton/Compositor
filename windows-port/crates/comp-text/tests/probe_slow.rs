//! Temporary probe: which random document is slow.

use comp_core::text::{SizeD, TextAlignment, TextStyle};
use comp_text::{layout_text, FontLibrary};
use std::time::Instant;

struct Rng(u64);
impl Rng {
    fn next(&mut self) -> u64 {
        self.0 = self.0.wrapping_add(0x9E37_79B9_7F4A_7C15);
        let mut z = self.0;
        z = (z ^ (z >> 30)).wrapping_mul(0xBF58_476D_1CE4_E5B9);
        z = (z ^ (z >> 27)).wrapping_mul(0x94D0_49BB_1331_11EB);
        z ^ (z >> 31)
    }
    fn below(&mut self, bound: usize) -> usize {
        if bound == 0 { 0 } else { (self.next() % bound as u64) as usize }
    }
    fn between(&mut self, low: f64, high: f64) -> f64 {
        let unit = (self.next() >> 11) as f64 / (1u64 << 53) as f64;
        low + unit * (high - low)
    }
}

const PIECES: &[&str] = &[
    "今天天气很好", "文字排版", "中文", "混排", "字", "the quick brown fox", "example", "spaces", "a",
    "3.14", "https://example.com/path", "。", "，", "、", "「引用」", "（括号）", "!?,.;:",
    "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}\u{200D}\u{1F466}", "\u{1F44D}\u{1F3FD}",
    "\u{1F1EF}\u{1F1F5}", "\u{2764}\u{FE0F}", "e\u{0301}", "\u{0915}\u{094D}\u{0915}",
    "\u{0E01}\u{0E49}", "\u{05D0}\u{05D1}\u{05D2}", "\u{05D3}\u{05D4}", "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxx",
    "\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}\u{4E2D}",
    "\n", "\r\n",
];

#[test]
fn probe_slow_cases() {
    let mut worst = 0.0f64;
    for round in 0..200usize {
        let mut rng = Rng(0x5EED_0001u64.wrapping_add(round as u64 * 0x9E37_79B9));
        let mut text = String::new();
        for paragraph in 0..1 + rng.below(3) {
            if paragraph > 0 {
                text.push('\n');
            }
            for _ in 0..1 + rng.below(14) {
                text.push_str(PIECES[rng.below(PIECES.len())]);
            }
        }
        let box_size = match rng.below(5) {
            0 => None,
            1 => Some((1.0 + rng.between(0.0, 40.0), 400.0)),
            2 => Some((40.0 + rng.between(0.0, 120.0), 600.0)),
            3 => Some((120.0 + rng.between(0.0, 400.0), 900.0)),
            _ => Some((1500.0 + rng.between(0.0, 1500.0), 900.0)),
        };
        let style = TextStyle {
            content: text.clone(),
            font_name: "Arial".into(),
            font_size: rng.between(8.0, 48.0),
            tracking: if rng.below(3) == 0 { rng.between(0.0, 4.0) } else { 0.0 },
            leading: 0.0,
            alignment: TextAlignment::Left,
            box_size: box_size.map(|(width, height)| SizeD::new(width, height)),
            ..TextStyle::default()
        };
        let mut library = FontLibrary::from_faces(Vec::new(), Vec::new());
        let started = Instant::now();
        let layout = layout_text(&style, &mut library);
        let millis = started.elapsed().as_secs_f64() * 1e3;
        if millis > worst {
            worst = millis;
            println!("round {round}: {millis:.1} ms, {} chars, {} lines, box {box_size:?}, size {:.1}", text.chars().count(), layout.lines.len(), style.font_size);
        }
    }
    println!("worst {worst:.1} ms");
}
