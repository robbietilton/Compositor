//! HEIC and HEIF import through the Windows Imaging Component.
//!
//! There is no pure-Rust HEIF decoder, and macOS reads these files through ImageIO, which is a
//! system framework. The closest equivalent here is the system codec: the HEIF Image Extension from
//! the Microsoft Store registers a WIC decoder (and an encoder), so this module drives that instead
//! of bundling a decoder. Nothing is redistributed, and a machine without the extension gets an
//! error that says what to install rather than a mystery.
#[cfg(windows)]
mod platform {
    use std::ptr;

    use comp_core::bitmap::Bitmap8;
    use windows::core::{w, Interface};
    use windows::Win32::Foundation::RPC_E_CHANGED_MODE;
    use windows::Win32::Graphics::Imaging::{
        IWICBitmapSource, IWICImagingFactory, IWICPalette, CLSID_WICImagingFactory,
        GUID_WICPixelFormat32bppRGBA, WICBitmapDitherTypeNone, WICBitmapPaletteTypeCustom,
        WICBitmapTransformFlipHorizontal, WICBitmapTransformFlipVertical, WICBitmapTransformOptions,
        WICBitmapTransformRotate0, WICBitmapTransformRotate180, WICBitmapTransformRotate270,
        WICBitmapTransformRotate90, WICDecodeMetadataCacheOnDemand,
    };
    use windows::Win32::System::Com::{
        CoCreateInstance, CoInitializeEx, CoUninitialize, IStream, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
    };
    use windows::Win32::System::Com::StructuredStorage::PROPVARIANT;
    use windows::Win32::System::Variant::VT_UI2;

    use crate::codec::{check_limits, ImportOptions};
    use crate::error::{IoError, IoResult};

    /// WINCODEC_ERR_COMPONENTNOTFOUND: no registered decoder claims this file, which on a machine
    /// without the HEIF Image Extension is what a HEIC file gets.
    const WINCODEC_ERR_COMPONENTNOTFOUND: i32 = 0x8898_2F50u32 as i32;

    /// The apartment COM needs for this call, given back when the import ends.
    ///
    /// A host that already initialized COM in another mode keeps its own apartment: the call still
    /// works, and balancing it with CoUninitialize would tear down someone else's state.
    struct Apartment {
        owned: bool,
    }

    impl Apartment {
        fn enter() -> IoResult<Apartment> {
            let result = unsafe { CoInitializeEx(None, COINIT_MULTITHREADED) };
            if result.is_ok() {
                return Ok(Apartment { owned: true });
            }
            if result == RPC_E_CHANGED_MODE {
                return Ok(Apartment { owned: false });
            }
            Err(IoError::Unreadable(format!(
                "COM could not be initialized for the HEIF decoder: {}",
                windows::core::Error::from(result)
            )))
        }
    }

    impl Drop for Apartment {
        fn drop(&mut self) {
            if self.owned {
                unsafe { CoUninitialize() };
            }
        }
    }

    /// Decodes a HEIC or HEIF file into straight RGBA pixels, and reports whether the file's EXIF
    /// orientation was applied to them.
    pub fn decode_heic(bytes: &[u8], options: &ImportOptions) -> IoResult<(Bitmap8, bool)> {
        if bytes.is_empty() {
            return Err(IoError::Unreadable("the file is empty".into()));
        }
        let _apartment = Apartment::enter()?;
        unsafe {
            let factory: IWICImagingFactory =
                CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).map_err(|error| {
                    IoError::Unreadable(format!("the Windows Imaging Component is unavailable: {error}"))
                })?;
            let stream = factory
                .CreateStream()
                .map_err(|error| IoError::Unreadable(format!("a WIC stream could not be created: {error}")))?;
            stream.InitializeFromMemory(bytes).map_err(|error| {
                IoError::Unreadable(format!("the file could not be handed to WIC: {error}"))
            })?;
            let istream: IStream = stream.cast().map_err(|error| {
                IoError::Unreadable(format!("the WIC stream is not readable: {error}"))
            })?;
            let decoder = factory
                .CreateDecoderFromStream(&istream, ptr::null(), WICDecodeMetadataCacheOnDemand)
                .map_err(decoder_error)?;
            if decoder.GetFrameCount().unwrap_or(0) == 0 {
                return Err(IoError::Unreadable("the HEIF file holds no picture".into()));
            }
            let frame = decoder.GetFrame(0).map_err(|error| {
                IoError::Unreadable(format!("the first picture in the HEIF file is unreadable: {error}"))
            })?;
            let (mut width, mut height) = (0u32, 0u32);
            frame.GetSize(&mut width, &mut height).map_err(|error| {
                IoError::Unreadable(format!("the HEIF picture has no size: {error}"))
            })?;
            if width == 0 || height == 0 {
                return Err(IoError::Unreadable(format!("the HEIF picture is {width}x{height}")));
            }
            // The size is known before any pixel buffer is allocated, so an oversized file costs
            // nothing but its header read.
            check_limits(width, height, options.remaining_pixels)?;

            let source: IWICBitmapSource = frame.cast().map_err(|error| {
                IoError::Unreadable(format!("the HEIF picture cannot be read: {error}"))
            })?;
            let orientation = if options.apply_orientation { orientation_of(&frame) } else { None };
            let source = rotate_to_display(&factory, &source, orientation)?;
            let orientation_applied = !matches!(orientation, None | Some(1));

            let converter = factory.CreateFormatConverter().map_err(|error| {
                IoError::Unreadable(format!("a WIC pixel converter could not be created: {error}"))
            })?;
            converter
                .Initialize(
                    &source,
                    &GUID_WICPixelFormat32bppRGBA,
                    WICBitmapDitherTypeNone,
                    None::<&IWICPalette>,
                    0.0,
                    WICBitmapPaletteTypeCustom,
                )
                .map_err(|error| {
                    IoError::Unreadable(format!("the HEIF picture could not be converted to RGBA: {error}"))
                })?;
            let stride = width * 4;
            let mut pixels = vec![0u8; stride as usize * height as usize];
            converter.CopyPixels(ptr::null(), stride, &mut pixels).map_err(|error| {
                IoError::Unreadable(format!("the HEIF picture could not be copied out: {error}"))
            })?;
            Ok((Bitmap8::from_raw(width, height, pixels)?, orientation_applied))
        }
    }

    /// The WIC transform an EXIF orientation tag asks for.
    ///
    /// WIC has no name for a transpose, so the two odd tags are spelled as the flip and quarter
    /// turn that compose into one: 5 is a quarter turn with a vertical flip, 7 the same turn with a
    /// horizontal one. The table is checked against the reference implementation in the image crate
    /// by a test, because the order WIC applies the two parts in is not documented.
    pub fn transform_for_orientation(orientation: Option<u16>) -> WICBitmapTransformOptions {
        match orientation {
            Some(2) => WICBitmapTransformFlipHorizontal,
            Some(3) => WICBitmapTransformRotate180,
            Some(4) => WICBitmapTransformOptions(
                WICBitmapTransformFlipHorizontal.0 | WICBitmapTransformRotate180.0,
            ),
            Some(5) => WICBitmapTransformOptions(
                WICBitmapTransformRotate90.0 | WICBitmapTransformFlipVertical.0,
            ),
            Some(6) => WICBitmapTransformRotate90,
            Some(7) => WICBitmapTransformOptions(
                WICBitmapTransformRotate90.0 | WICBitmapTransformFlipHorizontal.0,
            ),
            Some(8) => WICBitmapTransformRotate270,
            _ => WICBitmapTransformRotate0,
        }
    }

    /// Turns a decoder failure into something a user can act on.
    pub fn decoder_error(error: windows::core::Error) -> IoError {
        if error.code().0 == WINCODEC_ERR_COMPONENTNOTFOUND {
            return IoError::UnsupportedFormat(
                "no HEIF decoder is installed; install HEIF Image Extensions from the Microsoft Store \
                 (winget install --source msstore 9PMMSR1CGPWG) to open HEIC files"
                    .into(),
            );
        }
        IoError::Unreadable(format!("the Windows HEIF decoder refused the file: {error}"))
    }

    /// The EXIF orientation the file carries, as the frame's metadata reports it.
    fn orientation_of(frame: &windows::Win32::Graphics::Imaging::IWICBitmapFrameDecode) -> Option<u16> {
        unsafe {
            let reader = frame.GetMetadataQueryReader().ok()?;
            let mut value = PROPVARIANT::default();
            reader.GetMetadataByName(w!("/app1/ifd/{ushort=274}"), &mut value).ok()?;
            let raw = &value.Anonymous.Anonymous;
            if raw.vt != VT_UI2 {
                return None;
            }
            Some(raw.Anonymous.uiVal)
        }
    }

    /// Applies the EXIF orientation the way ImageIO does, through WIC's own flip rotator.
    ///
    /// Transpose and transverse (5 and 7) are left as stored: WIC's flip and rotate cannot be
    /// ordered the way those two need, and a wrong quarter turn is worse than none.
    fn rotate_to_display(
        factory: &IWICImagingFactory,
        source: &IWICBitmapSource,
        orientation: Option<u16>,
    ) -> IoResult<IWICBitmapSource> {
        let transform = transform_for_orientation(orientation);
        if transform == WICBitmapTransformRotate0 {
            return Ok(source.clone());
        }
        unsafe {
            let rotator = factory.CreateBitmapFlipRotator().map_err(|error| {
                IoError::Unreadable(format!("a WIC rotator could not be created: {error}"))
            })?;
            rotator.Initialize(source, transform).map_err(|error| {
                IoError::Unreadable(format!("the HEIF picture could not be rotated: {error}"))
            })?;
            rotator.cast().map_err(|error| {
                IoError::Unreadable(format!("the rotated HEIF picture cannot be read: {error}"))
            })
        }
    }
}

#[cfg(all(test, windows))]
mod tests {
    use std::fs;
    use std::path::PathBuf;

    use windows::core::Interface;

    use super::platform::{decode_heic, decoder_error, transform_for_orientation};
    use crate::codec::{decode_raster, import_document, ImportOptions};
    use crate::error::IoError;
    use crate::format::RasterFormat;
    use windows::Win32::Graphics::Imaging::{
        WICBitmapTransformFlipHorizontal, WICBitmapTransformFlipVertical, WICBitmapTransformOptions,
        WICBitmapTransformRotate0, WICBitmapTransformRotate180, WICBitmapTransformRotate270,
        WICBitmapTransformRotate90,
    };

    /// WINCODEC_ERR_COMPONENTNOTFOUND, what a machine without the HEIF extension returns.
    const COMPONENT_NOT_FOUND: i32 = 0x8898_2F50u32 as i32;

    fn fixture(name: &str) -> PathBuf {
        PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("tests").join("fixtures").join(name)
    }

    fn bytes(name: &str) -> Vec<u8> {
        fs::read(fixture(name)).unwrap_or_else(|error| panic!("{name}: {error}; run tests/make_codec_fixtures.py"))
    }

    /// The raw RGBA libheif produced for a fixture, one byte per channel.
    fn expected(name: &str) -> Vec<u8> {
        let stem = name.rsplit_once('.').map(|(stem, _)| stem).unwrap_or(name);
        fs::read(fixture(&format!("{stem}.rgba"))).expect("the expected pixels")
    }

    /// A tiny picture whose four quadrants differ, so a transform is identifiable.
    fn quadrant_pixels(width: u32, height: u32) -> Vec<u8> {
        let mut pixels = Vec::new();
        for y in 0..height {
            for x in 0..width {
                let color = match (x < width / 2, y < height / 2) {
                    (true, true) => [255, 0, 0, 255],
                    (false, true) => [0, 255, 0, 255],
                    (true, false) => [0, 0, 255, 255],
                    (false, false) => [255, 255, 0, 255],
                };
                pixels.extend_from_slice(&color);
            }
        }
        pixels
    }

    /// Runs pixels through WIC's flip rotator, the transform the importer uses.
    fn wic_transform(
        pixels: &[u8],
        width: u32,
        height: u32,
        transform: windows::Win32::Graphics::Imaging::WICBitmapTransformOptions,
    ) -> (Vec<u8>, u32, u32) {
        use windows::Win32::Graphics::Imaging::{
            CLSID_WICImagingFactory, IWICBitmapSource, IWICImagingFactory, GUID_WICPixelFormat32bppRGBA,
            WICBitmapPaletteTypeCustom, WICBitmapDitherTypeNone, GUID_WICPixelFormat32bppPRGBA,
        };
        use windows::Win32::System::Com::{
            CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED,
        };
        unsafe {
            let _ = CoInitializeEx(None, COINIT_MULTITHREADED);
            let factory: IWICImagingFactory = CoCreateInstance(&CLSID_WICImagingFactory, None, CLSCTX_INPROC_SERVER).unwrap();
            let bitmap = factory
                .CreateBitmapFromMemory(width, height, &GUID_WICPixelFormat32bppRGBA, width * 4, pixels)
                .unwrap();
            let source: IWICBitmapSource = bitmap.cast().unwrap();
            let rotator = factory.CreateBitmapFlipRotator().unwrap();
            rotator.Initialize(&source, transform).unwrap();
            let rotated = factory.CreateFormatConverter().unwrap();
            rotated
                .Initialize(
                    &rotator.cast::<IWICBitmapSource>().unwrap(),
                    &GUID_WICPixelFormat32bppRGBA,
                    WICBitmapDitherTypeNone,
                    None::<&windows::Win32::Graphics::Imaging::IWICPalette>,
                    0.0,
                    WICBitmapPaletteTypeCustom,
                )
                .unwrap();
            let (mut out_width, mut out_height) = (0u32, 0u32);
            rotated.GetSize(&mut out_width, &mut out_height).unwrap();
            let _ = GUID_WICPixelFormat32bppPRGBA;
            let mut out = vec![0u8; out_width as usize * out_height as usize * 4];
            rotated.CopyPixels(std::ptr::null(), out_width * 4, &mut out).unwrap();
            (out, out_width, out_height)
        }
    }

    #[test]
    fn the_orientation_table_matches_the_exif_semantics() {
        use image::metadata::Orientation;
        // Every tag, with the meaning the EXIF specification gives it. WIC has no transpose, so
        // the table composes one; this pins the composition against the reference implementation
        // in the image crate, which is what the macOS exporter would agree with.
        for (tag, orientation) in [
            (1u16, Orientation::NoTransforms),
            (2, Orientation::FlipHorizontal),
            (3, Orientation::Rotate180),
            (4, Orientation::FlipVertical),
            (5, Orientation::Rotate90FlipH),
            (6, Orientation::Rotate90),
            (7, Orientation::Rotate270FlipH),
            (8, Orientation::Rotate270),
        ] {
            let (width, height) = (4u32, 2u32);
            let pixels = quadrant_pixels(width, height);
            let (turned, out_width, out_height) =
                wic_transform(&pixels, width, height, transform_for_orientation(Some(tag)));
            let mut expected =
                image::DynamicImage::ImageRgba8(image::RgbaImage::from_raw(width, height, pixels).unwrap());
            expected.apply_orientation(orientation);
            let expected = expected.to_rgba8();
            assert_eq!(
                (out_width, out_height),
                (expected.width(), expected.height()),
                "tag {tag} has the wrong shape"
            );
            assert_eq!(turned.as_slice(), expected.as_raw().as_slice(), "tag {tag} is the wrong transform");
        }
    }

    #[test]
    fn a_grayscale_picture_decodes_exactly_like_libheif() {
        // Grayscale has no chroma, so no color matrix or upsampling can differ: this checks the
        // geometry, the stride and the pixel order against an unrelated decoder exactly.
        let raster = decode_raster(&bytes("heic_gray.heic"), &ImportOptions::default()).unwrap();
        assert_eq!(raster.format, RasterFormat::Heic);
        assert_eq!(raster.image.width(), 24);
        assert_eq!(raster.image.height(), 18);
        assert_eq!(raster.image.pixels(), expected("heic_gray.heic").as_slice());
    }

    #[test]
    fn a_grayscale_avif_decodes_exactly_like_libheif() {
        // The same check as the HEIC one, for the AV1 codec: no chroma means no decoder freedom.
        let raster = decode_raster(&bytes("avif_gray.avif"), &ImportOptions::default()).unwrap();
        assert_eq!(raster.format, RasterFormat::Avif);
        assert_eq!(raster.image.width(), 24);
        assert_eq!(raster.image.height(), 18);
        assert_eq!(raster.image.pixels(), expected("avif_gray.avif").as_slice());
    }

    #[test]
    fn an_avif_becomes_a_document_of_its_own_format() {
        let document = import_document(fixture("avif_soft.avif")).unwrap();
        assert_eq!((document.width, document.height), (24, 18));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].name, "avif_soft");
        let raster = decode_raster(&bytes("avif_soft.avif"), &ImportOptions::default()).unwrap();
        assert_eq!(raster.format, RasterFormat::Avif);
        assert_eq!(raster.format.as_str(), "AVIF");
        assert!(raster.image.pixels().chunks_exact(4).all(|pixel| pixel[3] == 255));
    }

    #[test]
    fn a_color_picture_imports_with_its_geometry_and_alpha() {
        let raster = decode_raster(&bytes("heic_soft.heic"), &ImportOptions::default()).unwrap();
        assert_eq!((raster.image.width(), raster.image.height()), (24, 18));
        assert!(raster.image.pixels().chunks_exact(4).all(|pixel| pixel[3] == 255));
        // The picture itself is compared with libheif's decode in tests/codec_reference.rs; here the
        // import is checked to be a plain opaque RGBA raster.
        assert!(raster.image.pixels().chunks_exact(4).any(|pixel| pixel[0] > 100));
    }

    #[test]
    fn an_odd_sized_picture_imports_whole() {
        let raster = decode_raster(&bytes("heic_odd.heic"), &ImportOptions::default()).unwrap();
        assert_eq!((raster.image.width(), raster.image.height()), (23, 17));
    }

    #[test]
    fn a_heic_becomes_a_document_the_size_of_the_picture() {
        let document = import_document(fixture("heic_soft.heic")).unwrap();
        assert_eq!((document.width, document.height), (24, 18));
        assert_eq!(document.layers.len(), 1);
        assert_eq!(document.layers[0].image.as_ref().unwrap().width(), 24);
        assert_eq!(document.layers[0].name, "heic_soft");
        // A HEIF file's DPI is not read yet, so the document keeps the default.
        assert_eq!(document.resolution, 72.0);
    }

    #[test]
    fn a_file_that_declares_a_resolution_sets_the_document_dpi() {
        // The Exif item carries 300 dpi; the Windows metadata reader does not expose it, so the
        // container reader in isobmff.rs finds it and the import keeps it.
        let document = import_document(fixture("heic_dpi.heic")).unwrap();
        assert_eq!(document.resolution, 300.0);
        assert_eq!((document.width, document.height), (24, 18));
        // A file without the item keeps the default.
        let plain = import_document(fixture("heic_soft.heic")).unwrap();
        assert_eq!(plain.resolution, 72.0);
    }

    #[test]
    fn an_auxiliary_alpha_image_is_not_applied_yet() {
        // The file libheif wrote carries its transparency in an auxiliary image, and the system
        // decoder reports 24bppBGR for it: the alpha never reaches this code. The test pins the
        // behavior so a decoder that starts exposing it is noticed.
        let raster = decode_raster(&bytes("heic_alpha.heic"), &ImportOptions::default()).unwrap();
        assert!(
            raster.image.pixels().chunks_exact(4).all(|pixel| pixel[3] == 255),
            "the system HEIF decoder now exposes alpha; the import should use it"
        );
        // The container reader is what tells a caller the file had transparency at all.
        assert!(crate::has_auxiliary_alpha(&bytes("heic_alpha.heic")));
        assert!(!crate::has_auxiliary_alpha(&bytes("heic_soft.heic")));
    }

    #[test]
    fn a_picture_below_the_decoders_minimum_is_reported() {
        match decode_heic(&bytes("heic_too_small.heic"), &ImportOptions::default()) {
            Err(IoError::Unreadable(message)) => {
                assert!(message.contains("HEIF"), "the message should name the decoder: {message}");
            }
            other => panic!("a 2x2 HEIC should be refused: {other:?}"),
        }
    }

    #[test]
    fn a_truncated_file_is_refused() {
        let mut truncated = bytes("heic_soft.heic");
        truncated.truncate(truncated.len() / 2);
        assert!(matches!(decode_heic(&truncated, &ImportOptions::default()), Err(IoError::Unreadable(_))));
    }

    #[test]
    fn a_file_that_only_looks_like_heic_is_refused() {
        // A real ftyp box with an HEVC brand, followed by nothing that is a picture.
        let mut fake = vec![0u8, 0, 0, 24];
        fake.extend_from_slice(b"ftypheic");
        fake.extend_from_slice(&[0, 0, 0, 0]);
        fake.extend_from_slice(b"mif1heic");
        fake.extend_from_slice(&[0xAB; 256]);
        let error = decode_heic(&fake, &ImportOptions::default()).unwrap_err();
        assert!(matches!(error, IoError::Unreadable(_)), "{error:?}");
        // The signature is what routes it here in the first place.
        assert_eq!(RasterFormat::from_bytes(&fake), Some(RasterFormat::Heic));
    }

    #[test]
    fn an_empty_file_is_refused() {
        match decode_heic(&[], &ImportOptions::default()) {
            Err(IoError::Unreadable(message)) => assert!(message.contains("empty"), "{message}"),
            other => panic!("an empty file should be refused: {other:?}"),
        }
    }

    #[test]
    fn a_missing_codec_says_what_to_install() {
        let error = decoder_error(windows::core::Error::from(windows::core::HRESULT(COMPONENT_NOT_FOUND)));
        match error {
            IoError::UnsupportedFormat(message) => {
                assert!(message.contains("HEIF Image Extensions"), "{message}");
                assert!(message.contains("winget"), "{message}");
            }
            other => panic!("a missing codec should be an unsupported format: {other:?}"),
        }
        // Any other failure stays a read error rather than sending the user to the Store.
        let other = decoder_error(windows::core::Error::from(windows::core::HRESULT(0x8007_0057u32 as i32)));
        assert!(matches!(other, IoError::Unreadable(_)), "{other:?}");
    }

    #[test]
    fn the_exif_orientation_table_is_right() {
        assert_eq!(transform_for_orientation(None), WICBitmapTransformRotate0);
        assert_eq!(transform_for_orientation(Some(1)), WICBitmapTransformRotate0);
        assert_eq!(transform_for_orientation(Some(2)), WICBitmapTransformFlipHorizontal);
        assert_eq!(transform_for_orientation(Some(3)), WICBitmapTransformRotate180);
        assert_eq!(transform_for_orientation(Some(6)), WICBitmapTransformRotate90);
        assert_eq!(transform_for_orientation(Some(8)), WICBitmapTransformRotate270);
        // Transpose and transverse are a quarter turn plus a flip, in the order WIC applies them.
        assert_eq!(
            transform_for_orientation(Some(5)),
            WICBitmapTransformOptions(WICBitmapTransformRotate90.0 | WICBitmapTransformFlipVertical.0)
        );
        assert_eq!(
            transform_for_orientation(Some(7)),
            WICBitmapTransformOptions(WICBitmapTransformRotate90.0 | WICBitmapTransformFlipHorizontal.0)
        );
        // An unknown tag changes nothing.
        assert_eq!(transform_for_orientation(Some(99)), WICBitmapTransformRotate0);
    }

    #[test]
    fn the_limits_are_checked_before_the_pixels_are_read() {
        let options = ImportOptions { remaining_pixels: 10, ..ImportOptions::default() };
        match decode_raster(&bytes("heic_soft.heic"), &options) {
            Err(IoError::TooLarge(message)) => assert!(message.contains("10"), "{message}"),
            other => panic!("a picture over the budget should be refused: {other:?}"),
        }
    }
}

#[cfg(windows)]
pub use platform::decode_heic;

/// HEIC import needs the system codec, which only exists on Windows.
#[cfg(not(windows))]
pub fn decode_heic(
    _bytes: &[u8],
    _options: &crate::codec::ImportOptions,
) -> crate::error::IoResult<(comp_core::bitmap::Bitmap8, bool)> {
    Err(crate::error::IoError::UnsupportedFormat(
        "HEIC import uses the Windows Imaging Component, which this build does not have".into(),
    ))
}
