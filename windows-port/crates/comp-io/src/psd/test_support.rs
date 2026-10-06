//! A minimal Photoshop writer for the tests.
//!
//! Writing the bytes is the only way to exercise ZIP channels, PSB lengths, CMYK headers, damaged
//! lengths and merged images without checking binary fixtures into the tree.
use std::io::Write;

use flate2::write::ZlibEncoder;
use flate2::Compression;

/// The mask settings a fixture writes.
#[derive(Clone, Copy, Debug)]
pub(crate) struct MaskSpec {
    pub rect: (i32, i32, i32, i32),
    pub default_value: u8,
    pub flags: u8,
}

/// One layer record, its channels and its additional layer information.
#[derive(Clone, Debug)]
pub(crate) struct LayerSpec {
    pub name: String,
    /// top, left, bottom, right
    pub rect: (i32, i32, i32, i32),
    /// Channel id, plane bytes, compression method.
    pub planes: Vec<(i16, Vec<u8>, u16)>,
    /// Channel id, compression word, and bytes written as they are, for damaged-file tests.
    pub verbatim: Vec<(i16, u16, Vec<u8>)>,
    pub opacity: u8,
    pub fill: u8,
    pub blend: [u8; 4],
    pub flags: u8,
    pub clipping: bool,
    pub section: Option<u32>,
    pub mask: Option<MaskSpec>,
    pub extras: Vec<([u8; 4], Vec<u8>)>,
}

impl LayerSpec {
    pub(crate) fn new(name: &str, rect: (i32, i32, i32, i32)) -> Self {
        LayerSpec {
            name: name.to_string(),
            rect,
            planes: Vec::new(),
            verbatim: Vec::new(),
            opacity: 255,
            fill: 255,
            blend: *b"norm",
            flags: 0,
            clipping: false,
            section: None,
            mask: None,
            extras: Vec::new(),
        }
    }

    /// The layer's size in pixels.
    pub(crate) fn size(&self) -> (usize, usize) {
        (
            (self.rect.3 - self.rect.1).max(0) as usize,
            (self.rect.2 - self.rect.0).max(0) as usize,
        )
    }

    pub(crate) fn plane(mut self, id: i16, plane: Vec<u8>, compression: u16) -> Self {
        self.planes.push((id, plane, compression));
        self
    }

    /// Adds the transparency, red, green and blue planes Photoshop writes for a layer.
    pub(crate) fn rgba(mut self, pixels: &[[u8; 4]], compression: u16) -> Self {
        let mut alpha = Vec::with_capacity(pixels.len());
        let mut red = Vec::with_capacity(pixels.len());
        let mut green = Vec::with_capacity(pixels.len());
        let mut blue = Vec::with_capacity(pixels.len());
        for pixel in pixels {
            red.push(pixel[0]);
            green.push(pixel[1]);
            blue.push(pixel[2]);
            alpha.push(pixel[3]);
        }
        self.planes.push((-1, alpha, compression));
        self.planes.push((0, red, compression));
        self.planes.push((1, green, compression));
        self.planes.push((2, blue, compression));
        self
    }

    pub(crate) fn gray_plane(mut self, plane: Vec<u8>, compression: u16) -> Self {
        self.planes.push((-2, plane, compression));
        self
    }

    /// Writes channel bytes with no encoding, so a test can hand the reader something the
    /// fixture writer would never produce, such as an unknown compression method.
    pub(crate) fn verbatim_channel(mut self, id: i16, compression: u16, data: Vec<u8>) -> Self {
        self.verbatim.push((id, compression, data));
        self
    }

    pub(crate) fn extra(mut self, key: &[u8; 4], payload: Vec<u8>) -> Self {
        self.extras.push((*key, payload));
        self
    }

    pub(crate) fn unicode_name(self, name: &str) -> Self {
        self.extra(b"luni", luni(name))
    }

    pub(crate) fn section(mut self, section: u32) -> Self {
        self.section = Some(section);
        self.extra(b"lsct", section.to_be_bytes().to_vec())
    }

    pub(crate) fn opacity(mut self, value: u8) -> Self {
        self.opacity = value;
        self
    }

    pub(crate) fn fill_opacity(mut self, value: u8) -> Self {
        self.fill = value;
        self.extra(b"iOpa", vec![value])
    }

    pub(crate) fn blend(mut self, key: &[u8; 4]) -> Self {
        self.blend = *key;
        self
    }

    pub(crate) fn hidden(mut self) -> Self {
        self.flags |= 2;
        self
    }

    pub(crate) fn clipping(mut self) -> Self {
        self.clipping = true;
        self
    }

    pub(crate) fn mask(mut self, mask: MaskSpec) -> Self {
        self.mask = Some(mask);
        self
    }
}

/// A whole file to write.
#[derive(Clone, Debug)]
pub(crate) struct PsdSpec {
    pub version: u16,
    pub depth: u16,
    pub color_mode: u16,
    /// width, height
    pub canvas: (u32, u32),
    pub resolution: Option<f64>,
    pub layers: Vec<LayerSpec>,
    /// The merged image planes and their compression, or raw black when None.
    pub merged: Option<(Vec<Vec<u8>>, u16)>,
}

impl PsdSpec {
    pub(crate) fn new(canvas: (u32, u32)) -> Self {
        PsdSpec { version: 1, depth: 8, color_mode: 3, canvas, resolution: None, layers: Vec::new(), merged: None }
    }

    pub(crate) fn layer(mut self, layer: LayerSpec) -> Self {
        self.layers.push(layer);
        self
    }

    pub(crate) fn version(mut self, version: u16) -> Self {
        self.version = version;
        self
    }

    pub(crate) fn depth(mut self, depth: u16) -> Self {
        self.depth = depth;
        self
    }

    pub(crate) fn color_mode(mut self, color_mode: u16) -> Self {
        self.color_mode = color_mode;
        self
    }

    pub(crate) fn resolution(mut self, resolution: f64) -> Self {
        self.resolution = Some(resolution);
        self
    }

    pub(crate) fn merged(mut self, planes: Vec<Vec<u8>>, compression: u16) -> Self {
        self.merged = Some((planes, compression));
        self
    }
}

/// A one-layer file with RGBA pixels, the fixture most reader tests start from.
pub(crate) fn single_layer(
    name: &str,
    width: u32,
    height: u32,
    pixels: &[[u8; 4]],
    compression: u16,
) -> Vec<u8> {
    let rect = (0, 0, height as i32, width as i32);
    build(&PsdSpec::new((width, height)).layer(LayerSpec::new(name, rect).rgba(pixels, compression)))
}

/// A 'luni' block: a UTF-16 big-endian layer name.
pub(crate) fn luni(name: &str) -> Vec<u8> {
    let units: Vec<u16> = name.encode_utf16().collect();
    let mut out = (units.len() as u32).to_be_bytes().to_vec();
    for unit in units {
        out.extend_from_slice(&unit.to_be_bytes());
    }
    out
}

/// PackBits with the row count table Photoshop puts in front, for one channel.
pub(crate) fn rle_plane(plane: &[u8], width: usize, height: usize) -> Vec<u8> {
    let (counts, rows) = pack_rows(plane, width, height);
    let mut out = Vec::with_capacity(counts.len() * 2 + rows.len());
    for count in counts {
        out.extend_from_slice(&(count as u16).to_be_bytes());
    }
    out.extend_from_slice(&rows);
    out
}

/// A zlib stream of a channel, optionally delta-encoded as compression 3 stores it.
pub(crate) fn zip_plane(plane: &[u8], width: usize, prediction: bool) -> Vec<u8> {
    let mut data = plane.to_vec();
    if prediction {
        for row in data.chunks_exact_mut(width) {
            for index in (1..width).rev() {
                row[index] = row[index].wrapping_sub(row[index - 1]);
            }
        }
    }
    let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
    encoder.write_all(&data).unwrap();
    encoder.finish().unwrap()
}

/// The whole file.
pub(crate) fn build(spec: &PsdSpec) -> Vec<u8> {
    let mut out = Vec::new();
    out.extend_from_slice(b"8BPS");
    out.extend_from_slice(&spec.version.to_be_bytes());
    out.extend_from_slice(&[0u8; 6]);
    let channels: u16 = spec.merged.as_ref().map(|(planes, _)| planes.len() as u16).unwrap_or(3).max(3);
    out.extend_from_slice(&channels.to_be_bytes());
    out.extend_from_slice(&spec.canvas.1.to_be_bytes());
    out.extend_from_slice(&spec.canvas.0.to_be_bytes());
    out.extend_from_slice(&spec.depth.to_be_bytes());
    out.extend_from_slice(&spec.color_mode.to_be_bytes());
    // Color mode data: empty for RGB and CMYK.
    out.extend_from_slice(&0u32.to_be_bytes());
    // Image resources: the resolution record when the fixture asks for one.
    let resources = spec.resolution.map(resolution_resource).unwrap_or_default();
    out.extend_from_slice(&(resources.len() as u32).to_be_bytes());
    out.extend_from_slice(&resources);
    // Layer and mask information.
    if spec.layers.is_empty() {
        out.extend_from_slice(&0u32.to_be_bytes());
    } else {
        let mut section = Vec::new();
        let info = layer_info(spec);
        if spec.version == 2 {
            section.extend_from_slice(&(info.len() as u64).to_be_bytes());
        } else {
            section.extend_from_slice(&(info.len() as u32).to_be_bytes());
        }
        section.extend_from_slice(&info);
        // The global layer mask section is empty in these fixtures.
        section.extend_from_slice(&0u32.to_be_bytes());
        if spec.version == 2 {
            out.extend_from_slice(&(section.len() as u64).to_be_bytes());
        } else {
            out.extend_from_slice(&(section.len() as u32).to_be_bytes());
        }
        out.extend_from_slice(&section);
    }
    // Image data: the merged composite.
    match &spec.merged {
        Some((planes, compression)) => {
            out.extend_from_slice(&compression.to_be_bytes());
            if *compression == 1 {
                let height = spec.canvas.1 as usize;
                let width = spec.canvas.0 as usize;
                let mut counts = Vec::new();
                let mut rows = Vec::new();
                for plane in planes {
                    let (plane_counts, plane_rows) = pack_rows(plane, width, height);
                    counts.extend(plane_counts);
                    rows.extend(plane_rows);
                }
                for count in counts {
                    if spec.version == 2 {
                        out.extend_from_slice(&(count as u32).to_be_bytes());
                    } else {
                        out.extend_from_slice(&(count as u16).to_be_bytes());
                    }
                }
                out.extend_from_slice(&rows);
            } else {
                for plane in planes {
                    out.extend_from_slice(plane);
                }
            }
        }
        None => {
            // A raw black composite, so a file with layers is still well formed.
            out.extend_from_slice(&0u16.to_be_bytes());
            out.extend_from_slice(&vec![0u8; spec.canvas.0 as usize * spec.canvas.1 as usize * 3]);
        }
    }
    out
}

fn layer_info(spec: &PsdSpec) -> Vec<u8> {
    let large = spec.version == 2;
    let mut records = Vec::new();
    records.extend_from_slice(&(spec.layers.len() as i16).to_be_bytes());
    for layer in &spec.layers {
        records.extend_from_slice(&layer_record(layer, large));
    }
    for layer in &spec.layers {
        let (width, height) = layer.size();
        for (_, plane, compression) in &layer.planes {
            records.extend_from_slice(&compression.to_be_bytes());
            records.extend_from_slice(&encode_plane(plane, width, height, *compression, large));
        }
        for (_, compression, data) in &layer.verbatim {
            records.extend_from_slice(&compression.to_be_bytes());
            records.extend_from_slice(data);
        }
    }
    records
}

fn layer_record(layer: &LayerSpec, large: bool) -> Vec<u8> {
    let (width, height) = layer.size();
    let mut out = Vec::new();
    out.extend_from_slice(&layer.rect.0.to_be_bytes());
    out.extend_from_slice(&layer.rect.1.to_be_bytes());
    out.extend_from_slice(&layer.rect.2.to_be_bytes());
    out.extend_from_slice(&layer.rect.3.to_be_bytes());
    // Channel lengths are 32-bit in both formats; only the PackBits row counts follow the
    // version, so the encoded size has to be computed with the same flag the writer uses.
    out.extend_from_slice(&((layer.planes.len() + layer.verbatim.len()) as u16).to_be_bytes());
    for (id, plane, compression) in &layer.planes {
        out.extend_from_slice(&id.to_be_bytes());
        let length = (encode_plane(plane, width, height, *compression, large).len() + 2) as u64;
        // PSB layer records store channel lengths as 64-bit values.
        if large {
            out.extend_from_slice(&length.to_be_bytes());
        } else {
            out.extend_from_slice(&(length as u32).to_be_bytes());
        }
    }
    for (id, _, data) in &layer.verbatim {
        out.extend_from_slice(&id.to_be_bytes());
        let length = (data.len() + 2) as u64;
        if large {
            out.extend_from_slice(&length.to_be_bytes());
        } else {
            out.extend_from_slice(&(length as u32).to_be_bytes());
        }
    }
    out.extend_from_slice(b"8BIM");
    out.extend_from_slice(&layer.blend);
    out.push(layer.opacity);
    out.push(u8::from(layer.clipping));
    out.push(layer.flags);
    out.push(0);

    let mut extra = Vec::new();
    match &layer.mask {
        Some(mask) => {
            extra.extend_from_slice(&20u32.to_be_bytes());
            extra.extend_from_slice(&mask.rect.0.to_be_bytes());
            extra.extend_from_slice(&mask.rect.1.to_be_bytes());
            extra.extend_from_slice(&mask.rect.2.to_be_bytes());
            extra.extend_from_slice(&mask.rect.3.to_be_bytes());
            extra.push(mask.default_value);
            extra.push(mask.flags);
            // Photoshop writes four more bytes than the fields above describe.
            extra.extend_from_slice(&[0, 0]);
        }
        None => extra.extend_from_slice(&0u32.to_be_bytes()),
    }
    // Blending ranges: empty.
    extra.extend_from_slice(&0u32.to_be_bytes());
    let name = layer.name.as_bytes();
    extra.push(name.len() as u8);
    extra.extend_from_slice(name);
    let padding = (4 - ((name.len() + 1) % 4)) % 4;
    extra.extend(std::iter::repeat_n(0u8, padding));
    for (key, payload) in &layer.extras {
        extra.extend_from_slice(b"8BIM");
        extra.extend_from_slice(key);
        extra.extend_from_slice(&(payload.len() as u32).to_be_bytes());
        extra.extend_from_slice(payload);
        if payload.len() % 2 == 1 {
            extra.push(0);
        }
    }
    out.extend_from_slice(&(extra.len() as u32).to_be_bytes());
    out.extend_from_slice(&extra);
    out
}

/// The resolution record (ID 1005): 16.16 fixed point pixels per inch for both axes.
fn resolution_resource(resolution: f64) -> Vec<u8> {
    let fixed = (resolution * 65536.0).round() as u32;
    let mut payload = Vec::with_capacity(16);
    payload.extend_from_slice(&fixed.to_be_bytes());
    payload.extend_from_slice(&1u16.to_be_bytes()); // pixels per inch
    payload.extend_from_slice(&1u16.to_be_bytes()); // width unit: inches
    payload.extend_from_slice(&fixed.to_be_bytes());
    payload.extend_from_slice(&1u16.to_be_bytes());
    payload.extend_from_slice(&1u16.to_be_bytes());
    let mut out = Vec::new();
    out.extend_from_slice(b"8BIM");
    out.extend_from_slice(&1005u16.to_be_bytes());
    out.push(0); // empty pascal name
    out.push(0); // its pad byte
    out.extend_from_slice(&(payload.len() as u32).to_be_bytes());
    out.extend_from_slice(&payload);
    out
}

/// A channel plane in the compression the fixture asks for.
fn encode_plane(plane: &[u8], width: usize, height: usize, compression: u16, large: bool) -> Vec<u8> {
    match compression {
        0 => plane.to_vec(),
        1 => {
            if !large {
                return rle_plane(plane, width, height);
            }
            let (counts, rows) = pack_rows(plane, width, height);
            let mut out = Vec::with_capacity(counts.len() * 4 + rows.len());
            for count in counts {
                out.extend_from_slice(&(count as u32).to_be_bytes());
            }
            out.extend_from_slice(&rows);
            out
        }
        2 => zip_plane(plane, width, false),
        3 => zip_plane(plane, width, true),
        other => panic!("the fixture writer does not know compression {other}"),
    }
}

/// PackBits rows as literal runs of at most four bytes, plus their byte counts.
fn pack_rows(plane: &[u8], width: usize, height: usize) -> (Vec<usize>, Vec<u8>) {
    let mut counts = Vec::with_capacity(height);
    let mut rows = Vec::new();
    for y in 0..height {
        let row = &plane[y * width..(y + 1) * width];
        let mut packed = Vec::new();
        let mut index = 0;
        while index < row.len() {
            let chunk = (row.len() - index).min(4);
            packed.push((chunk - 1) as u8);
            packed.extend_from_slice(&row[index..index + chunk]);
            index += chunk;
        }
        counts.push(packed.len());
        rows.extend_from_slice(&packed);
    }
    (counts, rows)
}
