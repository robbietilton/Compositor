//! Colour arithmetic and the recent-colour list behind the shared panel.
//!
//! One place picks a colour so the brush, the text tool and the effect dialogs cannot drift apart.
//! The conversions here are the parts worth testing; the panel itself is egui widgets on top.

/// A colour as the editor stores it: straight RGBA bytes.
pub type Color = [u8; 4];

/// How many colours the recent list keeps.
pub const MAX_RECENT: usize = 12;

/// A colour split into hue (degrees) and saturation and value (0 to 1).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Hsv {
    pub hue: f64,
    pub saturation: f64,
    pub value: f64,
}

/// The hue, saturation and value of an RGB colour.
pub fn to_hsv(color: Color) -> Hsv {
    let red = color[0] as f64 / 255.0;
    let green = color[1] as f64 / 255.0;
    let blue = color[2] as f64 / 255.0;
    let max = red.max(green).max(blue);
    let min = red.min(green).min(blue);
    let span = max - min;
    let hue = if span <= f64::EPSILON {
        0.0
    } else if max == red {
        60.0 * (((green - blue) / span) % 6.0)
    } else if max == green {
        60.0 * ((blue - red) / span + 2.0)
    } else {
        60.0 * ((red - green) / span + 4.0)
    };
    Hsv {
        hue: if hue < 0.0 { hue + 360.0 } else { hue },
        saturation: if max <= f64::EPSILON { 0.0 } else { span / max },
        value: max,
    }
}

/// The RGB colour of a hue, saturation and value, keeping an alpha byte.
pub fn from_hsv(hsv: Hsv, alpha: u8) -> Color {
    let hue = hsv.hue.rem_euclid(360.0);
    let saturation = hsv.saturation.clamp(0.0, 1.0);
    let value = hsv.value.clamp(0.0, 1.0);
    let chroma = value * saturation;
    let second = chroma * (1.0 - ((hue / 60.0) % 2.0 - 1.0).abs());
    let offset = value - chroma;
    let (red, green, blue) = match (hue / 60.0) as u32 {
        0 => (chroma, second, 0.0),
        1 => (second, chroma, 0.0),
        2 => (0.0, chroma, second),
        3 => (0.0, second, chroma),
        4 => (second, 0.0, chroma),
        _ => (chroma, 0.0, second),
    };
    let byte = |channel: f64| ((channel + offset) * 255.0).round().clamp(0.0, 255.0) as u8;
    [byte(red), byte(green), byte(blue), alpha]
}

/// The colour as #RRGGBB, which is what the hex field shows.
pub fn to_hex(color: Color) -> String {
    format!("#{:02X}{:02X}{:02X}", color[0], color[1], color[2])
}

/// The colour a hex string names, with or without the hash and with three, six or eight digits.
pub fn parse_hex(text: &str) -> Option<Color> {
    let digits: String = text.trim().trim_start_matches('#').chars().filter(|c| !c.is_whitespace()).collect();
    let byte = |pair: &str| u8::from_str_radix(pair, 16).ok();
    match digits.len() {
        3 => {
            let mut channels = [0u8; 4];
            for (index, character) in digits.chars().enumerate() {
                let value = character.to_digit(16)? as u8;
                channels[index] = value * 17;
            }
            channels[3] = 255;
            Some(channels)
        }
        6 | 8 => {
            let mut channels = [0u8; 4];
            channels[3] = 255;
            for index in 0..digits.len() / 2 {
                channels[index] = byte(&digits[index * 2..index * 2 + 2])?;
            }
            Some(channels)
        }
        _ => None,
    }
}

/// Puts a colour at the front of the recent list, without duplicates and with the oldest dropped.
pub fn push_recent(recent: &mut Vec<Color>, color: Color) {
    recent.retain(|existing| *existing != color);
    recent.insert(0, color);
    recent.truncate(MAX_RECENT);
}

/// The colours the panel offers before the user has picked any.
pub fn presets() -> Vec<Color> {
    vec![
        [0, 0, 0, 255],
        [255, 255, 255, 255],
        [255, 0, 0, 255],
        [255, 128, 0, 255],
        [255, 255, 0, 255],
        [0, 200, 0, 255],
        [0, 200, 200, 255],
        [0, 120, 255, 255],
        [128, 0, 255, 255],
        [255, 0, 200, 255],
        [128, 128, 128, 255],
        [64, 48, 32, 255],
    ]
}

#[cfg(test)]
mod tests {
    use super::*;

    fn close(left: Color, right: Color, tolerance: i32) -> bool {
        (0..4).all(|index| (left[index] as i32 - right[index] as i32).abs() <= tolerance)
    }

    #[test]
    fn hsv_and_rgb_round_trip() {
        for color in [
            [255u8, 0, 0, 255],
            [0, 255, 0, 255],
            [0, 0, 255, 255],
            [255, 255, 0, 255],
            [12, 200, 90, 255],
            [200, 30, 140, 64],
        ] {
            let hsv = to_hsv(color);
            let back = from_hsv(hsv, color[3]);
            assert!(close(back, color, 1), "{color:?} became {back:?} through {hsv:?}");
            assert_eq!(back[3], color[3], "the alpha rides through");
        }
    }

    #[test]
    fn the_hue_of_the_primaries_is_where_it_belongs() {
        assert_eq!(to_hsv([255, 0, 0, 255]).hue, 0.0);
        assert_eq!(to_hsv([255, 255, 0, 255]).hue, 60.0);
        assert_eq!(to_hsv([0, 255, 0, 255]).hue, 120.0);
        assert_eq!(to_hsv([0, 255, 255, 255]).hue, 180.0);
        assert_eq!(to_hsv([0, 0, 255, 255]).hue, 240.0);
        assert_eq!(to_hsv([255, 0, 255, 255]).hue, 300.0);
    }

    #[test]
    fn greys_have_no_hue_and_no_saturation() {
        let grey = to_hsv([128, 128, 128, 255]);
        assert_eq!(grey.hue, 0.0);
        assert_eq!(grey.saturation, 0.0);
        assert!((grey.value - 128.0 / 255.0).abs() < 1e-9);
        let black = to_hsv([0, 0, 0, 255]);
        assert_eq!(black.value, 0.0);
        assert_eq!(black.saturation, 0.0, "a division by a black value cannot be a NaN");
        assert!((from_hsv(black, 255)[0] as i32) == 0);
    }

    #[test]
    fn a_hue_outside_the_circle_wraps_around() {
        let wrapped = from_hsv(Hsv { hue: 370.0, saturation: 1.0, value: 1.0 }, 255);
        let same = from_hsv(Hsv { hue: 10.0, saturation: 1.0, value: 1.0 }, 255);
        assert_eq!(wrapped, same);
        let negative = from_hsv(Hsv { hue: -10.0, saturation: 1.0, value: 1.0 }, 255);
        let positive = from_hsv(Hsv { hue: 350.0, saturation: 1.0, value: 1.0 }, 255);
        assert_eq!(negative, positive);
    }

    #[test]
    fn saturation_and_value_clamp() {
        let wild = from_hsv(Hsv { hue: 0.0, saturation: 5.0, value: 5.0 }, 255);
        assert_eq!(wild, [255, 0, 0, 255], "over-saturated red is still red");
        let flat = from_hsv(Hsv { hue: 200.0, saturation: -1.0, value: 1.0 }, 128);
        assert_eq!(flat, [255, 255, 255, 128], "no saturation at full value is white");
    }

    #[test]
    fn hex_round_trips_and_accepts_the_usual_shapes() {
        let color = [18, 52, 86, 255];
        assert_eq!(to_hex(color), "#123456");
        assert_eq!(parse_hex("#123456"), Some(color));
        assert_eq!(parse_hex("123456"), Some(color));
        assert_eq!(parse_hex("  #123456  "), Some(color));
        assert_eq!(parse_hex("#fff"), Some([255, 255, 255, 255]));
        assert_eq!(parse_hex("#0f0"), Some([0, 255, 0, 255]));
        assert_eq!(parse_hex("#12345678"), Some([18, 52, 86, 120]));
        assert_eq!(parse_hex("#12345"), None, "five digits is not a colour");
        assert_eq!(parse_hex("#zzzzzz"), None);
        assert_eq!(parse_hex(""), None);
    }

    #[test]
    fn the_recent_list_keeps_the_newest_and_drops_the_oldest() {
        let mut recent = Vec::new();
        assert!(recent.is_empty());
        push_recent(&mut recent, [1, 2, 3, 255]);
        push_recent(&mut recent, [4, 5, 6, 255]);
        assert_eq!(recent[0], [4, 5, 6, 255], "the newest colour is first");
        push_recent(&mut recent, [1, 2, 3, 255]);
        assert_eq!(recent, vec![[1, 2, 3, 255], [4, 5, 6, 255]], "picking a colour again moves it up");
        for index in 0..20u8 {
            push_recent(&mut recent, [index, index, index, 255]);
        }
        assert_eq!(recent.len(), MAX_RECENT);
        assert_eq!(recent[0], [19, 19, 19, 255]);
        assert!(!recent.contains(&[4, 5, 6, 255]), "the oldest fell off the end");
    }

    #[test]
    fn the_presets_are_opaque_and_distinct() {
        let presets = presets();
        assert!(presets.len() >= 12);
        for preset in &presets {
            assert_eq!(preset[3], 255, "a preset without alpha would pick up whatever was there");
        }
        let mut sorted = presets.clone();
        sorted.sort_unstable();
        sorted.dedup();
        assert_eq!(sorted.len(), presets.len(), "no preset is listed twice");
    }
}
