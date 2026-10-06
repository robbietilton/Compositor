//! Errors shared by the format layer and the pixel pipeline.
//!
//! Two generations of kinds live here. The first six coarse variants (`Invalid`, `MissingAsset`,
//! `Encode`, `Decode`, `Message`, `TooLarge`) each covered several different failures, so a caller
//! could only tell them apart by reading the sentence; they stay because other crates and their
//! tests still name them, and because every one of them is still produced somewhere.
//!
//! The fine-grained kinds below say exactly what went wrong: which stage, which document field,
//! which asset, which path. Producers in this crate prefer them; `Error::source`, `Error::field`,
//! `Error::asset` and `Error::path` answer for both generations, so a caller never has to match on
//! the wording. Nothing about *which* packages are accepted changed with them - only how a refusal
//! is described.
use thiserror::Error;

pub type Result<T> = std::result::Result<T, Error>;

/// The stage of the format layer a failure came from.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ErrorSource {
    /// Reading or writing the package itself: its layout, its entries, its digest.
    Package,
    /// `manifest.json`: parsing it or checking what it describes.
    Manifest,
    /// One PNG asset: missing, undecodable, or not the surface its layer needs.
    Asset,
    /// The pixels themselves: a buffer that does not match its declared size.
    Pixel,
    /// Another image format on its way in or out (JPEG, TIFF, PSD and friends).
    Media,
    /// The operating system refused the read or the write.
    Io,
    /// Anything else; the detail carries the wording.
    Other,
}

impl ErrorSource {
    /// A stable, lower-case name for logs and tests.
    pub fn as_str(self) -> &'static str {
        match self {
            ErrorSource::Package => "package",
            ErrorSource::Manifest => "manifest",
            ErrorSource::Asset => "asset",
            ErrorSource::Pixel => "pixel",
            ErrorSource::Media => "media",
            ErrorSource::Io => "io",
            ErrorSource::Other => "other",
        }
    }
}

#[derive(Debug, Error)]
pub enum Error {
    /// The path is neither a package nor readable as one. Kept for callers that only need to know
    /// "this will not open"; new code says which of the three it was.
    #[error("this is not a valid Compositor project, or its metadata is damaged")]
    Invalid,
    #[error("this project uses format version {0}; this build supports versions 1-11")]
    UnsupportedVersion(u32),
    /// An asset the manifest names is not in the package. Damage has its own variant now.
    #[error("an image inside the project is missing or damaged: {0}")]
    MissingAsset(String),
    #[error("this project exceeds a supported limit: {0}")]
    TooLarge(String),
    /// An image could not be written. Kept for callers that do not know which one.
    #[error("an image could not be saved")]
    Encode,
    /// An image could not be decoded. Damage to a named asset has its own variant now.
    #[error("an image could not be read: {0}")]
    Decode(String),
    /// A failure with no structure beyond its sentence.
    #[error("{0}")]
    Message(String),
    #[error(transparent)]
    Json(#[from] serde_json::Error),
    #[error(transparent)]
    Io(#[from] std::io::Error),
    #[error("pixel buffer size {got} does not match {expected} for {width}x{height}")]
    BufferSize { got: usize, expected: usize, width: u32, height: u32 },

    /// The path is not a Compositor package at all: a plain file, an empty folder, a folder whose
    /// manifest is missing, or a manifest that is not one of ours.
    #[error("this is not a Compositor project: {detail}")]
    NotAProject { detail: String },
    /// The package is there but nothing in it can be read - what a half-written package looks like.
    #[error("the project could not be read: {detail}")]
    DamagedPackage { detail: String },
    /// `manifest.json` does not describe a project this build can build. `field` names the place at
    /// fault in the document ("layers[2].transform.size") when the check knows one, and the line and
    /// column point into the file when it came from the parser.
    #[error("{}", damaged_manifest_message(field, detail, line, column))]
    DamagedManifest { field: Option<String>, detail: String, line: Option<usize>, column: Option<usize> },
    /// A path that cannot be used: missing, not a directory, refused by the system, or a link that
    /// leaves the package.
    #[error("{path} could not be used: {detail}")]
    IllegalPath { path: String, detail: String },
    /// An asset is in the package and cannot be turned into pixels: truncated, not a PNG, the wrong
    /// surface for its layer, or a size that disagrees with its own header.
    #[error("the image {name} could not be read: {detail}")]
    DamagedAsset { name: String, detail: String },
    /// An image could not be written; `asset` names it when the writer knew which one.
    #[error("{}", encode_failed_message(asset, detail))]
    EncodeFailed { asset: Option<String>, detail: String },
    /// A failure that is neither about the package nor about an image, with the stage it came
    /// from. The field is @stage@ rather than @source@ because thiserror reserves that name for the
    /// error's cause; @Error::source()@ is the accessor and answers for both generations.
    #[error("{detail}")]
    Failed { stage: ErrorSource, detail: String },
}

impl Error {
    /// The message the macOS app would show for the same failure.
    pub fn user_message(&self) -> String {
        self.to_string()
    }

    /// Which stage of the format layer produced this failure.
    pub fn source(&self) -> ErrorSource {
        match self {
            Error::Invalid | Error::NotAProject { .. } | Error::DamagedPackage { .. } => ErrorSource::Package,
            Error::UnsupportedVersion(_) | Error::DamagedManifest { .. } => ErrorSource::Manifest,
            Error::MissingAsset(_) | Error::DamagedAsset { .. } | Error::Encode | Error::EncodeFailed { .. } => {
                ErrorSource::Asset
            }
            Error::Decode(_) => ErrorSource::Media,
            // The only JSON this crate parses is a manifest; a caller that parses something else
            // with this variant should use Error::failed instead.
            Error::Json(_) => ErrorSource::Manifest,
            Error::TooLarge(_) => ErrorSource::Manifest,
            Error::IllegalPath { .. } | Error::Io(_) => ErrorSource::Io,
            Error::BufferSize { .. } => ErrorSource::Pixel,
            Error::Message(_) | Error::Failed { .. } => ErrorSource::Other,
        }
    }

    /// The document field at fault, when the check knew one. The path is a manifest path:
    /// `layers[2].transform.size`, `width`, `guides[0].position`.
    pub fn field(&self) -> Option<&str> {
        match self {
            Error::DamagedManifest { field, .. } => field.as_deref(),
            _ => None,
        }
    }

    /// The asset (image or mask file name) at fault, when the failure is about one.
    ///
    /// Answers for both generations, and always with the file's own name rather than with the path a
    /// producer happened to have in hand: @MissingAsset@ carries whatever was written when it was
    /// raised, which may be a bare name, a package-relative path (@images\A1B2.png@) or a path from
    /// the file system. A caller that shows the name to a person, or looks the file up in the
    /// package, wants @A1B2.png@, so that is what this returns.
    ///
    /// @None@ means the producer did not know which image it was - an encoder asked to write a
    /// buffer with no pixels, say - not that the failure is unrelated to an image: @Error::source()@
    /// remains the answer for the stage.
    pub fn asset(&self) -> Option<&str> {
        match self {
            Error::DamagedAsset { name, .. } => Some(name.as_str()).filter(|name| !name.trim().is_empty()),
            Error::EncodeFailed { asset, .. } => asset.as_deref().filter(|name| !name.trim().is_empty()),
            Error::MissingAsset(payload) => Some(asset_name_in(payload)),
            _ => None,
        }
    }

    /// The filesystem path at fault, when the failure is about one.
    pub fn path(&self) -> Option<&str> {
        match self {
            Error::IllegalPath { path, .. } => Some(path),
            _ => None,
        }
    }

    /// The line of `manifest.json` a parse failure stopped on.
    pub fn line(&self) -> Option<usize> {
        match self {
            Error::DamagedManifest { line, .. } => *line,
            Error::Json(error) => Some(error.line()),
            _ => None,
        }
    }

    /// The column of `manifest.json` a parse failure stopped on.
    pub fn column(&self) -> Option<usize> {
        match self {
            Error::DamagedManifest { column, .. } => *column,
            Error::Json(error) => Some(error.column()),
            _ => None,
        }
    }

    /// The detail alone, without the surrounding sentence: what the fine-grained kinds carry, and
    /// the whole message for the coarse ones. A caller that knows more than the layer below (which
    /// file it was writing, for instance) can fold this into its own sentence.
    pub fn detail(&self) -> String {
        match self {
            Error::NotAProject { detail }
            | Error::DamagedPackage { detail }
            | Error::DamagedManifest { detail, .. }
            | Error::IllegalPath { detail, .. }
            | Error::DamagedAsset { detail, .. }
            | Error::EncodeFailed { detail, .. }
            | Error::Failed { detail, .. } => detail.clone(),
            Error::MissingAsset(detail)
            | Error::TooLarge(detail)
            | Error::Decode(detail)
            | Error::Message(detail) => detail.clone(),
            Error::UnsupportedVersion(version) => {
                format!("this project uses format version {version}; this build supports versions 1-11")
            }
            Error::Invalid => "this is not a valid Compositor project, or its metadata is damaged".to_string(),
            Error::Encode => "an image could not be saved".to_string(),
            other => other.to_string(),
        }
    }

    /// True for the coarse kinds, which say "something is wrong" without saying what. A caller that
    /// wants a precise message can use this to decide whether to look closer.
    pub fn is_coarse(&self) -> bool {
        matches!(
            self,
            Error::Invalid
                | Error::MissingAsset(_)
                | Error::Encode
                | Error::Decode(_)
                | Error::Message(_)
                | Error::UnsupportedVersion(_)
                | Error::TooLarge(_)
        )
    }

    /// The path is not a project at all.
    pub fn not_a_project(detail: impl Into<String>) -> Self {
        Error::NotAProject { detail: detail.into() }
    }

    /// The package exists but cannot be read.
    pub fn damaged_package(detail: impl Into<String>) -> Self {
        Error::DamagedPackage { detail: detail.into() }
    }

    /// The metadata is wrong at a known field.
    pub fn manifest(field: impl Into<String>, detail: impl Into<String>) -> Self {
        Error::DamagedManifest { field: Some(field.into()), detail: detail.into(), line: None, column: None }
    }

    /// The metadata does not parse, with where the parser stopped. The field is unknown then: the
    /// text never became a document.
    pub fn manifest_json(error: &serde_json::Error) -> Self {
        Error::DamagedManifest {
            field: None,
            detail: error.to_string(),
            line: Some(error.line()),
            column: Some(error.column()),
        }
    }

    /// A path that cannot be used, named as the caller was given it.
    pub fn illegal_path(path: impl Into<String>, detail: impl Into<String>) -> Self {
        Error::IllegalPath { path: path.into(), detail: detail.into() }
    }

    /// An asset that is present but cannot become pixels.
    pub fn damaged_asset(name: impl Into<String>, detail: impl Into<String>) -> Self {
        Error::DamagedAsset { name: name.into(), detail: detail.into() }
    }

    /// An asset that could not be written.
    pub fn encode_failed(asset: Option<&str>, detail: impl Into<String>) -> Self {
        Error::EncodeFailed { asset: asset.map(str::to_string), detail: detail.into() }
    }

    /// A failure from a named stage with no other structure.
    pub fn failed(stage: ErrorSource, detail: impl Into<String>) -> Self {
        Error::Failed { stage, detail: detail.into() }
    }
}

/// The asset name inside a payload a producer wrote.
///
/// Producers write the file the way they had it: `A1B2.png`, `images\A1B2.png`, or a full path. The
/// last path component is the name. A producer that wrapped a sentence around it - the coarse
/// variants still do - is handled too: the tail after the last `": "` wins, which is safe because a
/// Windows file name cannot contain a colon. Prose that has neither a colon nor a separator comes
/// back as it is, which is exactly what a caller had before this existed; a name is never invented.
fn asset_name_in(payload: &str) -> &str {
    let trimmed = payload.trim();
    let tail = match trimmed.rsplit_once(": ") {
        Some((_, tail)) => tail.trim(),
        None => trimmed,
    };
    let name = tail.rsplit(['\\', '/']).next().unwrap_or(tail).trim();
    if name.is_empty() {
        trimmed
    } else {
        name
    }
}

/// The sentence for a damaged manifest: the field and the position are each added only when known.
fn damaged_manifest_message(
    field: &Option<String>,
    detail: &str,
    line: &Option<usize>,
    column: &Option<usize>,
) -> String {
    let mut message = String::from("the project's metadata is damaged");
    if let Some(field) = field {
        message.push_str(" at ");
        message.push_str(field);
    }
    match (line, column) {
        (Some(line), Some(column)) => message.push_str(&format!(" (line {line}, column {column})")),
        (Some(line), None) => message.push_str(&format!(" (line {line})")),
        _ => {}
    }
    message.push_str(": ");
    message.push_str(detail);
    message
}

/// The sentence for an image that could not be written.
fn encode_failed_message(asset: &Option<String>, detail: &str) -> String {
    match asset {
        Some(name) => format!("the image {name} could not be saved: {detail}"),
        None => format!("an image could not be saved: {detail}"),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn json_failure() -> serde_json::Error {
        serde_json::from_str::<Vec<i32>>("{\"format\": 3}").expect_err("not a list")
    }

    #[test]
    fn a_path_that_is_not_a_project_says_so() {
        let error = Error::not_a_project("it holds no manifest.json");
        assert!(matches!(error, Error::NotAProject { .. }));
        assert_eq!(error.source(), ErrorSource::Package);
        assert!(error.to_string().contains("not a Compositor project"), "{error}");
        assert!(error.to_string().contains("manifest.json"), "{error}");
    }

    #[test]
    fn a_damaged_package_is_its_own_kind() {
        let error = Error::damaged_package("the digest does not match");
        assert!(matches!(error, Error::DamagedPackage { .. }));
        assert_eq!(error.source(), ErrorSource::Package);
        assert!(error.to_string().contains("digest"), "{error}");
    }

    #[test]
    fn a_damaged_manifest_names_the_field() {
        let error = Error::manifest("layers[2].transform.size", "a size must be above zero");
        assert_eq!(error.field(), Some("layers[2].transform.size"));
        assert_eq!(error.source(), ErrorSource::Manifest);
        assert_eq!(error.detail(), "a size must be above zero");
        let message = error.to_string();
        assert!(message.contains("layers[2].transform.size"), "{message}");
        assert!(message.contains("above zero"), "{message}");
    }

    #[test]
    fn a_manifest_that_does_not_parse_carries_the_line() {
        let error = Error::manifest_json(&json_failure());
        assert!(matches!(error, Error::DamagedManifest { .. }));
        assert!(error.field().is_none(), "the text never became a document to walk");
        assert!(error.line().is_some() && error.column().is_some(), "{error}");
        assert_eq!(error.source(), ErrorSource::Manifest);
    }

    #[test]
    fn an_illegal_path_names_the_path() {
        let error = Error::illegal_path("D:\\gone\\Doc.comp", "the system cannot find the path");
        assert_eq!(error.path(), Some("D:\\gone\\Doc.comp"));
        assert_eq!(error.source(), ErrorSource::Io);
        let message = error.to_string();
        assert!(message.contains("Doc.comp") && message.contains("cannot find"), "{message}");
    }

    #[test]
    fn a_damaged_asset_names_the_asset() {
        let error = Error::damaged_asset("A1B2.png", "the deflate stream ends early");
        assert_eq!(error.asset(), Some("A1B2.png"));
        assert_eq!(error.source(), ErrorSource::Asset);
        let message = error.to_string();
        assert!(message.contains("A1B2.png") && message.contains("deflate"), "{message}");
    }

    #[test]
    fn an_encode_failure_names_the_image_when_it_can() {
        let named = Error::encode_failed(Some("A1B2.png"), "the encoder refused it");
        assert_eq!(named.asset(), Some("A1B2.png"));
        assert!(named.to_string().contains("A1B2.png"), "{named}");
        let anonymous = Error::encode_failed(None, "the encoder refused it");
        assert_eq!(anonymous.asset(), None);
        assert!(anonymous.to_string().starts_with("an image could not be saved"), "{anonymous}");
    }

    #[test]
    fn a_failure_carries_its_stage() {
        let error = Error::failed(ErrorSource::Media, "the PSD uses a layer kind this build does not read");
        assert!(matches!(error, Error::Failed { stage: ErrorSource::Media, .. }));
        assert_eq!(error.source(), ErrorSource::Other);
        assert_eq!(error.detail(), "the PSD uses a layer kind this build does not read");
    }

    #[test]
    fn every_kind_reports_the_stage_it_came_from() {
        let cases: Vec<(Error, ErrorSource)> = vec![
            (Error::Invalid, ErrorSource::Package),
            (Error::not_a_project("x"), ErrorSource::Package),
            (Error::damaged_package("x"), ErrorSource::Package),
            (Error::UnsupportedVersion(99), ErrorSource::Manifest),
            (Error::manifest("width", "x"), ErrorSource::Manifest),
            (Error::TooLarge("canvas".into()), ErrorSource::Manifest),
            (Error::MissingAsset("x".into()), ErrorSource::Asset),
            (Error::damaged_asset("x", "y"), ErrorSource::Asset),
            (Error::Encode, ErrorSource::Asset),
            (Error::encode_failed(None, "y"), ErrorSource::Asset),
            (Error::Decode("x".into()), ErrorSource::Media),
            (Error::manifest_json(&json_failure()), ErrorSource::Manifest),
            (Error::Json(json_failure()), ErrorSource::Manifest),
            (Error::illegal_path("x", "y"), ErrorSource::Io),
            (Error::Io(std::io::Error::new(std::io::ErrorKind::NotFound, "gone")), ErrorSource::Io),
            (Error::BufferSize { got: 3, expected: 4, width: 1, height: 1 }, ErrorSource::Pixel),
            (Error::Message("x".into()), ErrorSource::Other),
            (Error::failed(ErrorSource::Other, "x"), ErrorSource::Other),
        ];
        for (error, expected) in cases {
            assert_eq!(error.source(), expected, "{error:?}");
        }
    }

    #[test]
    fn the_coarse_kinds_still_say_what_they_always_said() {
        let cases = [
            (Error::Invalid, "this is not a valid Compositor project, or its metadata is damaged"),
            (Error::UnsupportedVersion(7), "this project uses format version 7; this build supports versions 1-11"),
            (Error::MissingAsset("x".into()), "an image inside the project is missing or damaged: x"),
            (Error::TooLarge("y".into()), "this project exceeds a supported limit: y"),
            (Error::Encode, "an image could not be saved"),
            (Error::Decode("z".into()), "an image could not be read: z"),
            (Error::Message("plain".into()), "plain"),
        ];
        for (error, expected) in cases {
            assert_eq!(error.user_message(), expected);
        }
    }

    #[test]
    fn the_fine_kinds_are_not_coarse_and_the_coarse_ones_are() {
        assert!(Error::Invalid.is_coarse());
        assert!(Error::MissingAsset("x".into()).is_coarse());
        assert!(Error::Encode.is_coarse());
        assert!(Error::Decode("x".into()).is_coarse());
        assert!(Error::Message("x".into()).is_coarse());
        assert!(!Error::not_a_project("x").is_coarse());
        assert!(!Error::damaged_asset("x", "y").is_coarse());
        assert!(!Error::manifest("width", "x").is_coarse());
        assert!(!Error::illegal_path("x", "y").is_coarse());
        assert!(!Error::encode_failed(None, "x").is_coarse());
        assert!(!Error::failed(ErrorSource::Other, "x").is_coarse());
    }

    #[test]
    fn detail_is_the_payload_without_the_sentence() {
        assert_eq!(Error::damaged_asset("a.png", "truncated").detail(), "truncated");
        assert_eq!(Error::manifest("width", "zero").detail(), "zero");
        assert_eq!(Error::illegal_path("p", "missing").detail(), "missing");
        assert_eq!(Error::MissingAsset("a.png".into()).detail(), "a.png");
        assert!(Error::UnsupportedVersion(3).detail().contains("version 3"));
        // The coarse kinds answer with their whole sentence, so a caller can still fold them in.
        assert_eq!(Error::Encode.detail(), "an image could not be saved");
    }

    #[test]
    fn the_accessors_answer_none_when_the_failure_is_about_nothing_named() {
        assert_eq!(Error::Invalid.field(), None);
        assert_eq!(Error::Invalid.asset(), None);
        assert_eq!(Error::Invalid.path(), None);
        assert_eq!(Error::Invalid.line(), None);
        assert_eq!(Error::damaged_asset("a.png", "x").field(), None);
        assert_eq!(Error::manifest("width", "x").asset(), None);
        assert_eq!(Error::illegal_path("p", "x").field(), None);
    }

    #[test]
    fn the_constructors_build_what_they_say() {
        assert!(matches!(Error::not_a_project("d"), Error::NotAProject { .. }));
        assert!(matches!(Error::damaged_package("d"), Error::DamagedPackage { .. }));
        assert!(matches!(
            Error::manifest("f", "d"),
            Error::DamagedManifest { field: Some(_), line: None, column: None, .. }
        ));
        assert!(matches!(Error::illegal_path("p", "d"), Error::IllegalPath { .. }));
        assert!(matches!(Error::damaged_asset("a", "d"), Error::DamagedAsset { .. }));
        assert!(matches!(Error::encode_failed(Some("a"), "d"), Error::EncodeFailed { asset: Some(_), .. }));
        assert!(matches!(Error::failed(ErrorSource::Media, "d"), Error::Failed { stage: ErrorSource::Media, .. }));
    }


    #[test]
    fn the_asset_name_is_extracted_from_a_path() {
        // A package-relative path, a full path, and either separator: all three are the same file.
        let relative = Error::MissingAsset("images\\A1B2.png".to_string());
        assert_eq!(relative.asset(), Some("A1B2.png"));
        let absolute = Error::MissingAsset("E:\\Docs\\Doc.comp\\images\\A1B2.png".to_string());
        assert_eq!(absolute.asset(), Some("A1B2.png"));
        let forward = Error::MissingAsset("Doc.comp/images/A1B2.png".to_string());
        assert_eq!(forward.asset(), Some("A1B2.png"));
        let padded = Error::MissingAsset("  images\\A1B2.png  ".to_string());
        assert_eq!(padded.asset(), Some("A1B2.png"));
    }

    #[test]
    fn the_asset_name_is_extracted_from_a_sentence() {
        // What a caller sees if a producer wrapped the name in the message it would display.
        let wrapped = Error::MissingAsset("an image inside the project is missing or damaged: A1B2.png".to_string());
        assert_eq!(wrapped.asset(), Some("A1B2.png"));
        // Prose with no colon is a payload this accessor cannot take apart, so it comes back as it
        // is: the caller sees exactly what it saw before the accessor existed, never a made-up name.
        let prose = Error::MissingAsset("an image is missing".to_string());
        assert_eq!(prose.asset(), Some("an image is missing"));
    }

    #[test]
    fn a_payload_that_is_already_a_name_comes_back_unchanged() {
        assert_eq!(Error::MissingAsset("A1B2.png".to_string()).asset(), Some("A1B2.png"));
        assert_eq!(Error::MissingAsset("A1B2.mask.png".to_string()).asset(), Some("A1B2.mask.png"));
    }

    #[test]
    fn a_missing_asset_is_an_asset_stage_failure() {
        let error = Error::MissingAsset("images\\A1B2.png".to_string());
        assert_eq!(error.source(), ErrorSource::Asset);
        assert!(error.is_coarse(), "the coarse variant keeps its kind");
        assert_eq!(error.asset(), Some("A1B2.png"));
        assert_eq!(error.field(), None);
        assert_eq!(error.path(), None);
    }

    #[test]
    fn an_asset_failure_with_no_name_says_so() {
        let encoder = Error::encode_failed(None, "an image with no pixels cannot be saved");
        assert_eq!(encoder.source(), ErrorSource::Asset);
        assert_eq!(encoder.asset(), None, "the encoder did not know which image it was");
        // A name that is only whitespace is no name at all.
        let blank = Error::encode_failed(Some("   "), "refused");
        assert_eq!(blank.asset(), None);
        let empty = Error::damaged_asset("", "truncated");
        assert_eq!(empty.asset(), None);
        let named = Error::damaged_asset("A1B2.png", "truncated");
        assert_eq!(named.asset(), Some("A1B2.png"));
    }

    #[test]
    fn the_missing_asset_sentence_did_not_change() {
        // The Display of the coarse variant is public API: the accessor reads the payload, it does
        // not rewrite it.
        for payload in ["A1B2.png", "images\\A1B2.png", "E:\\Docs\\images\\A1B2.png"] {
            let error = Error::MissingAsset(payload.to_string());
            assert_eq!(
                error.to_string(),
                format!("an image inside the project is missing or damaged: {payload}")
            );
            assert_eq!(error.detail(), payload);
        }
    }

    #[test]
    fn the_asset_of_a_named_failure_is_the_name_it_was_given() {
        assert_eq!(Error::damaged_asset("A1B2.png", "truncated").asset(), Some("A1B2.png"));
        assert_eq!(Error::encode_failed(Some("A1B2.png"), "refused").asset(), Some("A1B2.png"));
        // A name given as a path is not trimmed by these variants: they were told the name.
        assert_eq!(Error::damaged_asset("images\\A1B2.png", "truncated").asset(), Some("images\\A1B2.png"));
        // Nothing named: no asset, whichever stage it came from.
        assert_eq!(Error::Invalid.asset(), None);
        assert_eq!(Error::not_a_project("x").asset(), None);
        assert_eq!(Error::failed(ErrorSource::Asset, "the mask could not be applied").asset(), None);
    }

    #[test]
    fn error_source_names_itself_for_logs() {
        let names = [
            (ErrorSource::Package, "package"),
            (ErrorSource::Manifest, "manifest"),
            (ErrorSource::Asset, "asset"),
            (ErrorSource::Pixel, "pixel"),
            (ErrorSource::Media, "media"),
            (ErrorSource::Io, "io"),
            (ErrorSource::Other, "other"),
        ];
        for (source, name) in names {
            assert_eq!(source.as_str(), name);
        }
    }
}

