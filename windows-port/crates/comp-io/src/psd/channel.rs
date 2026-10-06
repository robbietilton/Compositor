//! Photoshop channel decoding: raw, PackBits (RLE) and ZIP.
//!
//! A layer channel is a compression word followed by the channel's bytes. Photoshop writes raw
//! (0), PackBits (1), and on larger files ZIP with and without prediction (2 and 3); anything
//! else is refused by name rather than guessed at.
use std::io::Read;

use flate2::read::ZlibDecoder;

use crate::error::{IoError, IoResult};

/// The part of a channel a decode keeps, in channel coordinates.
///
/// Photoshop stores a layer's full bounds even when a memory budget forced the import to keep
/// only the canvas intersection, so decoding skips the rows and columns that fall outside.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) struct ChannelCrop {
    pub x: usize,
    pub y: usize,
    pub width: usize,
    pub height: usize,
}

impl ChannelCrop {
    fn full(width: usize, height: usize) -> Self {
        ChannelCrop { x: 0, y: 0, width, height }
    }

    fn is_full(&self, width: usize, height: usize) -> bool {
        self.x == 0 && self.y == 0 && self.width == width && self.height == height
    }
}

/// Decodes one layer channel, keeping only the cropped part when one is given.
pub(crate) fn decode(
    compression: u16,
    width: usize,
    height: usize,
    data: &[u8],
    large_document: bool,
    crop: Option<ChannelCrop>,
) -> IoResult<Vec<u8>> {
    if width == 0 || height == 0 {
        return Ok(Vec::new());
    }
    let crop = crop.unwrap_or_else(|| ChannelCrop::full(width, height));
    if crop.width == 0 || crop.height == 0 {
        return Ok(Vec::new());
    }
    if crop.x + crop.width > width || crop.y + crop.height > height {
        return Err(IoError::Truncated(format!(
            "a channel crop {}x{} at ({}, {}) does not fit the {width}x{height} channel",
            crop.width, crop.height, crop.x, crop.y
        )));
    }
    match compression {
        0 => raw(width, height, data, crop),
        1 => pack_bits(width, height, data, large_document, crop),
        2 | 3 => {
            let plane = zip(compression, width, height, data)?;
            Ok(crop_plane(&plane, width, crop))
        }
        other => Err(IoError::UnsupportedCompression(other)),
    }
}

/// Raw channel bytes, copied row by row so an oversized layer never has to be materialized.
fn raw(width: usize, height: usize, data: &[u8], crop: ChannelCrop) -> IoResult<Vec<u8>> {
    if data.len() < width * height {
        return Err(IoError::Truncated(format!(
            "a raw channel holds {} bytes; {width}x{height} needs {}",
            data.len(),
            width * height
        )));
    }
    let mut plane = vec![0u8; crop.width * crop.height];
    for row in 0..crop.height {
        let source = (crop.y + row) * width + crop.x;
        let target = row * crop.width;
        plane[target..target + crop.width].copy_from_slice(&data[source..source + crop.width]);
    }
    Ok(plane)
}

/// PackBits, with the row byte counts Photoshop puts in front of the packed rows.
fn pack_bits(
    width: usize,
    height: usize,
    data: &[u8],
    large_document: bool,
    crop: ChannelCrop,
) -> IoResult<Vec<u8>> {
    let mut offset = 0usize;
    let mut counts = Vec::with_capacity(height);
    for _ in 0..height {
        let count = read_count(data, &mut offset, large_document)?;
        counts.push(count);
    }
    let mut plane = vec![0u8; crop.width * crop.height];
    let mut row = vec![0u8; width];
    for (y, count) in counts.iter().enumerate() {
        let end = offset
            .checked_add(*count)
            .ok_or_else(|| IoError::Truncated("a PackBits row length".into()))?;
        if end > data.len() {
            return Err(IoError::Truncated(format!(
                "a PackBits row ends at {end}, past the {} bytes of channel data",
                data.len()
            )));
        }
        if y >= crop.y && y < crop.y + crop.height {
            pack_bits_row(&data[offset..end], width, &mut row)?;
            let target = (y - crop.y) * crop.width;
            plane[target..target + crop.width].copy_from_slice(&row[crop.x..crop.x + crop.width]);
        }
        offset = end;
    }
    Ok(plane)
}

/// PackBits rows whose byte counts are already known, as the merged image section stores them.
pub(crate) fn pack_bits_rows(
    width: usize,
    height: usize,
    data: &[u8],
    counts: &[usize],
) -> IoResult<(Vec<u8>, usize)> {
    if width == 0 || height == 0 {
        return Ok((Vec::new(), 0));
    }
    if counts.len() < height {
        return Err(IoError::Truncated(format!(
            "a PackBits row count table holds {} entries; {height} rows need one each",
            counts.len()
        )));
    }
    let mut plane = vec![0u8; width * height];
    let mut offset = 0usize;
    for y in 0..height {
        let end = offset
            .checked_add(counts[y])
            .ok_or_else(|| IoError::Truncated("a PackBits row length".into()))?;
        if end > data.len() {
            return Err(IoError::Truncated(format!(
                "a PackBits row ends at {end}, past the {} bytes of channel data",
                data.len()
            )));
        }
        pack_bits_row(&data[offset..end], width, &mut plane[y * width..(y + 1) * width])?;
        offset = end;
    }
    Ok((plane, offset))
}

/// One PackBits row: a signed count, then either literals or one repeated byte.
fn pack_bits_row(row: &[u8], width: usize, out: &mut [u8]) -> IoResult<()> {
    let mut offset = 0usize;
    let mut written = 0usize;
    while written < width {
        if offset >= row.len() {
            return Err(IoError::Truncated(format!(
                "a PackBits row wrote {written} of {width} pixels"
            )));
        }
        let control = row[offset] as i8;
        offset += 1;
        if control >= 0 {
            let count = control as usize + 1;
            if written + count > width || offset + count > row.len() {
                return Err(IoError::Truncated("a PackBits literal run".into()));
            }
            out[written..written + count].copy_from_slice(&row[offset..offset + count]);
            offset += count;
            written += count;
        } else if control != -128 {
            // -128 is a no-op that Photoshop emits as padding.
            let count = (1 - i32::from(control)) as usize;
            if written + count > width || offset >= row.len() {
                return Err(IoError::Truncated("a PackBits repeat run".into()));
            }
            let value = row[offset];
            offset += 1;
            out[written..written + count].fill(value);
            written += count;
        }
    }
    Ok(())
}

/// The ZIP compression modes, with the per-row delta filter of mode 3 undone after inflating.
fn zip(compression: u16, width: usize, height: usize, data: &[u8]) -> IoResult<Vec<u8>> {
    let expected = width * height;
    let decoder = ZlibDecoder::new(data);
    // Reading one byte past the expected length is enough to know the stream was too long; the
    // cap also stops a hostile stream from inflating into memory it has no right to.
    let mut limited = decoder.take(expected as u64 + 1);
    let mut plane = Vec::with_capacity(expected.min(1 << 24));
    limited
        .read_to_end(&mut plane)
        .map_err(|error| IoError::Truncated(format!("a ZIP-compressed channel: {error}")))?;
    if plane.len() < expected {
        return Err(IoError::Truncated(format!(
            "a ZIP-compressed channel inflated to {} bytes; {width}x{height} needs {expected}",
            plane.len()
        )));
    }
    plane.truncate(expected);
    if compression == 3 {
        for row in plane.chunks_exact_mut(width) {
            for index in 1..width {
                row[index] = row[index].wrapping_add(row[index - 1]);
            }
        }
    }
    Ok(plane)
}

fn crop_plane(plane: &[u8], width: usize, crop: ChannelCrop) -> Vec<u8> {
    if crop.is_full(width, plane.len() / width.max(1)) {
        return plane.to_vec();
    }
    let mut out = vec![0u8; crop.width * crop.height];
    for row in 0..crop.height {
        let source = (crop.y + row) * width + crop.x;
        let target = row * crop.width;
        out[target..target + crop.width].copy_from_slice(&plane[source..source + crop.width]);
    }
    out
}

fn read_count(data: &[u8], offset: &mut usize, large_document: bool) -> IoResult<usize> {
    let width = if large_document { 4 } else { 2 };
    if *offset + width > data.len() {
        return Err(IoError::Truncated("a PackBits row count table".into()));
    }
    let count = if large_document {
        let bytes = &data[*offset..*offset + 4];
        u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]) as usize
    } else {
        u16::from_be_bytes([data[*offset], data[*offset + 1]]) as usize
    };
    *offset += width;
    Ok(count)
}

#[cfg(test)]
mod tests {
    use super::*;
    use flate2::write::ZlibEncoder;
    use flate2::Compression;
    use std::io::Write;

    /// A plane with a recognizable value per pixel.
    fn plane(width: usize, height: usize) -> Vec<u8> {
        (0..width * height).map(|index| (index % 251) as u8).collect()
    }

    /// PackBits rows with a literal run and a repeat run, plus the count table.
    fn pack_bits_stream(plane: &[u8], width: usize, height: usize, large: bool) -> Vec<u8> {
        let mut counts = Vec::new();
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
        let mut out = Vec::new();
        for count in counts {
            if large {
                out.extend_from_slice(&(count as u32).to_be_bytes());
            } else {
                out.extend_from_slice(&(count as u16).to_be_bytes());
            }
        }
        out.extend_from_slice(&rows);
        out
    }

    fn deflate(data: &[u8]) -> Vec<u8> {
        let mut encoder = ZlibEncoder::new(Vec::new(), Compression::default());
        encoder.write_all(data).unwrap();
        encoder.finish().unwrap()
    }

    #[test]
    fn raw_planes_decode_and_crop() {
        let source = plane(4, 3);
        assert_eq!(decode(0, 4, 3, &source, false, None).unwrap(), source);
        let crop = ChannelCrop { x: 1, y: 1, width: 2, height: 2 };
        assert_eq!(decode(0, 4, 3, &source, false, Some(crop)).unwrap(), vec![5, 6, 9, 10]);
    }

    #[test]
    fn raw_planes_that_are_too_short_are_refused() {
        assert!(matches!(decode(0, 4, 4, &[0; 15], false, None), Err(IoError::Truncated(_))));
    }

    #[test]
    fn pack_bits_round_trips_with_and_without_a_crop() {
        let source = plane(6, 4);
        let stream = pack_bits_stream(&source, 6, 4, false);
        assert_eq!(decode(1, 6, 4, &stream, false, None).unwrap(), source);
        let crop = ChannelCrop { x: 2, y: 1, width: 3, height: 2 };
        let cropped = decode(1, 6, 4, &stream, false, Some(crop)).unwrap();
        assert_eq!(cropped, vec![8, 9, 10, 14, 15, 16]);
    }

    #[test]
    fn pack_bits_handles_repeat_runs_and_the_no_op_control() {
        // Row: 0x80 is a no-op, then three 7s as a repeat run, then two literals.
        let row = [0x80u8, 0xFE, 0x07, 0x01, 0xAA, 0xBB];
        let mut stream = (row.len() as u16).to_be_bytes().to_vec();
        stream.extend_from_slice(&row);
        let decoded = decode(1, 5, 1, &stream, false, None).unwrap();
        assert_eq!(decoded, vec![7, 7, 7, 0xAA, 0xBB]);
    }

    #[test]
    fn psb_row_counts_are_four_bytes() {
        let source = plane(3, 2);
        let stream = pack_bits_stream(&source, 3, 2, true);
        assert_eq!(decode(1, 3, 2, &stream, true, None).unwrap(), source);
        // The same stream read as a PSD count table would be nonsense, not a panic.
        assert!(decode(1, 3, 2, &stream, false, None).is_err());
    }

    #[test]
    fn truncated_pack_bits_rows_are_refused() {
        let source = plane(6, 2);
        let mut stream = pack_bits_stream(&source, 6, 2, false);
        stream.truncate(stream.len() - 3);
        assert!(matches!(decode(1, 6, 2, &stream, false, None), Err(IoError::Truncated(_))));
        // A count table that promises more bytes than the file holds.
        let mut lying = vec![0u8, 200, 0, 200];
        lying.extend_from_slice(&[0u8; 4]);
        assert!(matches!(decode(1, 2, 2, &lying, false, None), Err(IoError::Truncated(_))));
    }

    #[test]
    fn zip_channels_decode_with_and_without_prediction() {
        let source = plane(5, 3);
        let stream = deflate(&source);
        assert_eq!(decode(2, 5, 3, &stream, false, None).unwrap(), source);

        // Prediction stores the delta between neighboring pixels, so the encoder subtracts.
        let mut deltas = source.clone();
        for row in deltas.chunks_exact_mut(5) {
            for index in (1..5).rev() {
                row[index] = row[index].wrapping_sub(row[index - 1]);
            }
        }
        let predicted = deflate(&deltas);
        assert_eq!(decode(3, 5, 3, &predicted, false, None).unwrap(), source);

        let crop = ChannelCrop { x: 1, y: 1, width: 2, height: 1 };
        assert_eq!(decode(2, 5, 3, &stream, false, Some(crop)).unwrap(), vec![6, 7]);
    }

    #[test]
    fn zip_channels_that_inflate_to_too_little_are_refused() {
        let stream = deflate(&[1, 2, 3]);
        assert!(matches!(decode(2, 4, 4, &stream, false, None), Err(IoError::Truncated(_))));
    }

    #[test]
    fn unknown_compression_and_crops_outside_the_channel_are_refused() {
        assert!(matches!(decode(7, 4, 4, &[0; 16], false, None), Err(IoError::UnsupportedCompression(7))));
        let crop = ChannelCrop { x: 3, y: 3, width: 4, height: 4 };
        assert!(matches!(decode(1, 4, 4, &[], false, Some(crop)), Err(IoError::Truncated(_))));
        // A crop with no pixels decodes to nothing, which is not an error.
        let empty = ChannelCrop { x: 2, y: 2, width: 0, height: 0 };
        assert_eq!(decode(1, 4, 4, &[], false, Some(empty)).unwrap(), Vec::<u8>::new());
    }

    #[test]
    fn merged_image_rows_decode_from_a_shared_count_table() {
        let source = plane(4, 2);
        let stream = pack_bits_stream(&source, 4, 2, false);
        let counts = vec![
            u16::from_be_bytes([stream[0], stream[1]]) as usize,
            u16::from_be_bytes([stream[2], stream[3]]) as usize,
        ];
        let (decoded, used) = pack_bits_rows(4, 2, &stream[4..], &counts).unwrap();
        assert_eq!(decoded, source);
        assert_eq!(used, stream.len() - 4);
        assert!(pack_bits_rows(4, 4, &stream[4..], &counts).is_err());
    }
}
