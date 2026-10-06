//! A bounds-checked big-endian cursor over the file bytes.
//!
//! Photoshop stores every number big-endian and every section length in bytes, so a damaged file
//! must never be able to make a read index past the buffer.
use crate::error::{IoError, IoResult};

pub(crate) struct Cursor<'a> {
    data: &'a [u8],
    offset: usize,
}

impl<'a> Cursor<'a> {
    pub(crate) fn new(data: &'a [u8]) -> Self {
        Cursor { data, offset: 0 }
    }

    pub(crate) fn offset(&self) -> usize {
        self.offset
    }

    pub(crate) fn remaining(&self) -> usize {
        self.data.len().saturating_sub(self.offset)
    }

    /// Moves to an absolute offset, which must be inside the file.
    pub(crate) fn seek(&mut self, offset: usize) -> IoResult<()> {
        if offset > self.data.len() {
            return Err(self.truncated("a section length"));
        }
        self.offset = offset;
        Ok(())
    }

    pub(crate) fn skip(&mut self, count: usize) -> IoResult<()> {
        self.need(count, "a skipped field")?;
        self.offset += count;
        Ok(())
    }

    pub(crate) fn u8(&mut self) -> IoResult<u8> {
        self.need(1, "a byte")?;
        let value = self.data[self.offset];
        self.offset += 1;
        Ok(value)
    }

    pub(crate) fn u16(&mut self) -> IoResult<u16> {
        let bytes = self.bytes(2, "a 16-bit number")?;
        Ok(u16::from_be_bytes([bytes[0], bytes[1]]))
    }

    pub(crate) fn i16(&mut self) -> IoResult<i16> {
        Ok(self.u16()? as i16)
    }

    pub(crate) fn u32(&mut self) -> IoResult<u32> {
        let bytes = self.bytes(4, "a 32-bit number")?;
        Ok(u32::from_be_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]))
    }

    pub(crate) fn i32(&mut self) -> IoResult<i32> {
        Ok(self.u32()? as i32)
    }

    pub(crate) fn u64(&mut self) -> IoResult<u64> {
        let bytes = self.bytes(8, "a 64-bit number")?;
        let mut value = [0u8; 8];
        value.copy_from_slice(bytes);
        Ok(u64::from_be_bytes(value))
    }

    pub(crate) fn bytes(&mut self, count: usize, what: &'static str) -> IoResult<&'a [u8]> {
        self.need(count, what)?;
        let slice = &self.data[self.offset..self.offset + count];
        self.offset += count;
        Ok(slice)
    }

    /// Everything from the cursor to the end of the file.
    pub(crate) fn rest(&self) -> &'a [u8] {
        &self.data[self.offset.min(self.data.len())..]
    }

    /// A section length that has to fit in an address.
    pub(crate) fn length(&mut self, is_psb: bool, what: &'static str) -> IoResult<usize> {
        let value = if is_psb { self.u64()? } else { u64::from(self.u32()?) };
        usize::try_from(value)
            .map_err(|_| IoError::TooLarge(format!("{what} is {value} bytes, which this build cannot address")))
    }

    fn need(&self, count: usize, what: &'static str) -> IoResult<()> {
        if count > self.remaining() {
            return Err(self.truncated(what));
        }
        Ok(())
    }

    fn truncated(&self, what: &str) -> IoError {
        IoError::Truncated(format!("{what} runs past the end of the file at byte {}", self.offset))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_big_endian_values() {
        let data = [0x12, 0x34, 0x56, 0x78, 0x9A, 0xBC, 0xDE, 0xF0, 0x11];
        let mut cursor = Cursor::new(&data);
        assert_eq!(cursor.u16().unwrap(), 0x1234);
        assert_eq!(cursor.u16().unwrap(), 0x5678);
        assert_eq!(cursor.u32().unwrap(), 0x9ABC_DEF0);
        assert_eq!(cursor.u8().unwrap(), 0x11);
        assert_eq!(cursor.remaining(), 0);
    }

    #[test]
    fn signed_values_are_the_same_bits() {
        let data = [0xFF, 0xFF, 0xFF, 0xFE];
        let mut cursor = Cursor::new(&data);
        assert_eq!(cursor.i16().unwrap(), -1);
        assert_eq!(cursor.i16().unwrap(), -2);
    }

    #[test]
    fn reads_past_the_end_are_truncated_errors() {
        let mut cursor = Cursor::new(&[1, 2, 3]);
        assert!(matches!(cursor.u32(), Err(IoError::Truncated(_))));
        assert!(matches!(cursor.seek(4), Err(IoError::Truncated(_))));
        assert!(matches!(cursor.skip(4), Err(IoError::Truncated(_))));
        assert_eq!(cursor.rest(), &[1, 2, 3]);
    }
}
