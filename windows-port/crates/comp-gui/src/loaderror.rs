//! What went wrong when a project would not open, in terms a user can act on.
//!
//! The format layer reports failures precisely — an unsupported version, a missing asset, a limit —
//! but the editor used to show them all as the same sentence. This module turns both the typed
//! errors from comp-core and the sentences comp-io answers with into one kind, so the canvas can say
//! which file, which field or which limit is at fault.

/// Why a package, an image or a Photoshop file would not open.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum LoadProblem {
    /// The package is a newer format than this build reads.
    UnsupportedVersion { found: u32 },
    /// The manifest is missing, truncated or does not have the shape the format describes.
    DamagedManifest { detail: String },
    /// A package is there but nothing in it parses, which is what a half-written package looks like.
    CorruptPackage { detail: String },
    /// The path is not a Compositor project at all: a plain file, an empty folder, a foreign manifest.
    NotAProject { detail: String },
    /// An image could not be written, with the asset's name when the writer knew it.
    WriteFailed { asset: Option<String>, detail: String },
    /// An asset the manifest names is not in the package.
    MissingAsset { name: String },
    /// An asset is there and cannot be decoded.
    DamagedAsset { name: String, detail: String },
    /// The document, or one of its images, is past a limit this build supports.
    TooLarge { limit: String },
    /// The path is not a package, or not reachable.
    IllegalPath { path: String, detail: String },
    /// A Photoshop file is damaged or uses something this build does not implement.
    DamagedPsd { detail: String },
    /// An image is a kind or a depth the importer cannot take.
    UnsupportedMedia { detail: String },
    /// The operating system refused the read.
    Io { detail: String },
    /// Anything else, with the message the layer below produced.
    Other { detail: String },
}

impl LoadProblem {
    /// The kind of failure, for logging and for tests.
    pub fn category(&self) -> &'static str {
        match self {
            LoadProblem::UnsupportedVersion { .. } => "unsupported version",
            LoadProblem::DamagedManifest { .. } => "damaged manifest",
            LoadProblem::CorruptPackage { .. } => "corrupt package",
            LoadProblem::NotAProject { .. } => "not a project",
            LoadProblem::WriteFailed { .. } => "write failed",
            LoadProblem::MissingAsset { .. } => "missing asset",
            LoadProblem::DamagedAsset { .. } => "damaged asset",
            LoadProblem::TooLarge { .. } => "over a limit",
            LoadProblem::IllegalPath { .. } => "illegal path",
            LoadProblem::DamagedPsd { .. } => "damaged Photoshop file",
            LoadProblem::UnsupportedMedia { .. } => "unsupported image",
            LoadProblem::Io { .. } => "io",
            LoadProblem::Other { .. } => "other",
        }
    }

    /// The specific reason, with a file or field name where the layer below knew one.
    pub fn detail(&self) -> String {
        match self {
            LoadProblem::UnsupportedVersion { found } => {
                let supported = comp_core::document::SUPPORTED_VERSIONS;
                format!(
                    "The project is format version {found}; this build reads versions {} to {}",
                    supported.start(),
                    supported.end()
                )
            }
            LoadProblem::DamagedManifest { detail } => format!("The project's manifest is damaged: {detail}"),
            LoadProblem::CorruptPackage { detail } => format!("Nothing in the project could be read: {detail}"),
            LoadProblem::NotAProject { detail } => format!("That path is not a Compositor project: {detail}"),
            LoadProblem::WriteFailed { asset, detail } => match asset {
                Some(name) => format!("The image {name} could not be written: {detail}"),
                None => format!("An image could not be written: {detail}"),
            },
            LoadProblem::MissingAsset { name } => format!("The image {name} is named by the project but is not in it"),
            LoadProblem::DamagedAsset { name, detail } => format!("The image {name} could not be read: {detail}"),
            LoadProblem::TooLarge { limit } => format!("The project is past a limit this build supports: {limit}"),
            LoadProblem::IllegalPath { path, detail } => format!("{path} could not be used: {detail}"),
            LoadProblem::DamagedPsd { detail } => format!("The Photoshop file could not be read: {detail}"),
            LoadProblem::UnsupportedMedia { detail } => detail.clone(),
            LoadProblem::Io { detail } => format!("The file could not be read: {detail}"),
            LoadProblem::Other { detail } => detail.clone(),
        }
    }

    /// What the user can do about it.
    pub fn hint(&self) -> &'static str {
        match self {
            LoadProblem::UnsupportedVersion { .. } => "Open it with the build that wrote it, or export a flattened copy",
            LoadProblem::DamagedManifest { .. } | LoadProblem::CorruptPackage { .. } => {
                "If it was being written by another program, wait for that to finish and open it again"
            }
            LoadProblem::MissingAsset { .. } => "Restore the images folder from a backup, then open the project again",
            LoadProblem::NotAProject { .. } => "Check that you picked the project folder itself, not a file or a folder beside it",
            LoadProblem::WriteFailed { .. } => "Check that the folder is writable and that the drive has room",
            LoadProblem::DamagedAsset { .. } => "The rest of the project can still be opened if the file is replaced",
            LoadProblem::TooLarge { .. } => "Reduce the canvas or the number of layers before opening it here",
            LoadProblem::IllegalPath { .. } => "Check the path, and that the folder is readable",
            LoadProblem::DamagedPsd { .. } => "Re-export the file from Photoshop, or flatten it to a PNG and import that",
            LoadProblem::UnsupportedMedia { .. } => "Convert it to 8-bit RGB PNG, TIFF or JPEG and import that",
            LoadProblem::Io { .. } => "Check that the file is not open in another program and that the drive is there",
            LoadProblem::Other { .. } => "Nothing else to suggest: the message above is what the reader said",
        }
    }

    /// The one-line sentence the status bar shows.
    pub fn summary(&self) -> String {
        format!("{}: {}", self.category(), self.detail())
    }

    /// Classifies a typed error from the format layer.
    ///
    /// The kind of failure comes from the variant and the place comes from comp-core's accessors, so
    /// nothing here reads a sentence: a field, an asset name, a path and a line and column all arrive
    /// through `field()`, `asset()`, `path()`, `line()` and `column()`. The coarse variants, which
    /// say only that something is wrong, are classified as well as they can be, and a variant added
    /// after this file is written falls through to the sentence classifier rather than failing.
    pub fn from_core(error: &comp_core::Error) -> LoadProblem {
        use comp_core::Error as Core;
        match error {
            Core::UnsupportedVersion(found) => LoadProblem::UnsupportedVersion { found: *found },
            // A path that is not a project is the one failure the user can fix by picking again, so
            // it keeps its own category rather than joining "corrupt package".
            Core::NotAProject { .. } => LoadProblem::NotAProject { detail: error.detail() },
            Core::DamagedPackage { .. } => LoadProblem::CorruptPackage { detail: error.detail() },
            Core::DamagedManifest { .. } => LoadProblem::DamagedManifest { detail: manifest_detail(error) },
            Core::IllegalPath { .. } => LoadProblem::IllegalPath {
                path: error.path().unwrap_or("that path").to_string(),
                detail: error.detail(),
            },
            Core::DamagedAsset { .. } => LoadProblem::DamagedAsset {
                name: error.asset().unwrap_or("an image").to_string(),
                detail: error.detail(),
            },
            Core::EncodeFailed { .. } => LoadProblem::WriteFailed {
                asset: error.asset().map(str::to_string),
                detail: error.detail(),
            },
            Core::Failed { stage, .. } => from_stage(*stage, error.detail()),
            // The coarse generation: the variant says which family, the detail says as much as the
            // producer knew when it was written. The asset accessor answers for this one too, and it
            // answers with the file's own name rather than the path the producer had in hand.
            Core::MissingAsset(_) => LoadProblem::MissingAsset {
                name: error.asset().unwrap_or("an image").to_string(),
            },
            Core::TooLarge(_) => LoadProblem::TooLarge { limit: error.detail() },
            Core::Decode(_) => LoadProblem::UnsupportedMedia { detail: error.detail() },
            Core::Encode => LoadProblem::WriteFailed {
                asset: None,
                detail: "an image could not be saved".to_string(),
            },
            Core::Invalid => LoadProblem::CorruptPackage { detail: error.detail() },
            Core::Json(_) => LoadProblem::DamagedManifest { detail: manifest_detail(error) },
            Core::Io(error) => LoadProblem::Io { detail: error.to_string() },
            Core::BufferSize { .. } | Core::Message(_) => LoadProblem::Other { detail: error.detail() },
            // A kind this build has never seen, added to comp-core after this file was written: the
            // sentence is all that is left, so it is classified the way a reader's message is. Every
            // variant that exists today is matched above, which is why this arm is unreachable now
            // and why it is allowed to be: it exists for the next variant, not for this one.
            #[allow(unreachable_patterns)]
            other => LoadProblem::from_message(&other.to_string()),
        }
    }

    /// Classifies a sentence from an image or package reader.
    ///
    /// The lower layers put names and reasons in their messages, so the classification reads them
    /// rather than flattening everything into one sentence.
    pub fn from_message(message: &str) -> LoadProblem {
        let text = message.trim();
        let lower = text.to_lowercase();
        let has = |needle: &str| lower.contains(needle);
        let after = |marker: &str| {
            text.split_once(marker)
                .map(|(_, rest)| rest.trim().trim_start_matches(':').trim().to_string())
                .unwrap_or_else(|| text.to_string())
        };

        // A Photoshop message comes first: one of them mentions a format version too, and it is
        // still a Photoshop problem rather than a package from the future.
        if has("photoshop") {
            return LoadProblem::DamagedPsd { detail: after(": ") };
        }
        if has("format version") {
            let found = text
                .split("format version ")
                .nth(1)
                .and_then(|rest| rest.split(|c: char| !c.is_ascii_digit()).next())
                .and_then(|digits| digits.parse().ok())
                .unwrap_or(0);
            return LoadProblem::UnsupportedVersion { found };
        }
        if has("missing or damaged") {
            return classify_asset(&after("missing or damaged"));
        }
        if has("exceeds the supported limits") || has("exceeds a supported limit") {
            return LoadProblem::TooLarge { limit: after(": ") };
        }
        // The package's own kinds come before an image's: "the project could not be read" is about
        // the package even though it reads like the sentence a decoder writes.
        if has("not a valid compositor project") || has("the project could not be read") {
            return LoadProblem::CorruptPackage { detail: text.to_string() };
        }
        if has("is not a compositor project") {
            return LoadProblem::NotAProject { detail: after(": ") };
        }
        if has("could not be used") {
            // comp-core writes these as "<path> could not be used: <detail>".
            let path = text.split(" could not be used").next().unwrap_or(text).trim().to_string();
            return LoadProblem::IllegalPath { path, detail: after(": ") };
        }
        if has("could not be written") || has("could not be saved") {
            // "<image name> could not be written: <detail>" names the asset on the way through.
            let name = text.split(" could not be").next().unwrap_or(text).trim().to_string();
            let asset = (!name.is_empty() && !name.contains(' ') || name.contains('.')).then_some(name);
            return LoadProblem::WriteFailed { asset, detail: after(": ") };
        }
        if has("could not be read:") && has(".png") {
            let name = text
                .split(" could not be read")
                .next()
                .unwrap_or(text)
                .trim()
                .trim_start_matches("the image ")
                .to_string();
            return LoadProblem::DamagedAsset { name, detail: after(": ") };
        }
        if has("at layers[") || has("at width") || has("at height") {
            // A manifest field named in the sentence, which is what the finer kind carries.
            let field = text.rsplit(" at ").next().unwrap_or_default().to_string();
            return LoadProblem::DamagedManifest { detail: format!("{text} (at {field})") };
        }
        if has("only 8-bit") || has("choose a jpeg") || has("could not be read") || has("no content remained") {
            return LoadProblem::UnsupportedMedia { detail: text.to_string() };
        }
        if has("os error") || has("no such file") || has("access is denied") || has("cannot find") || has("permission") {
            return LoadProblem::Io { detail: text.to_string() };
        }
        if has("expected value") || has("expected ident") || has("eof while parsing") || has("missing field") {
            return LoadProblem::DamagedManifest { detail: text.to_string() };
        }
        LoadProblem::Other { detail: text.to_string() }
    }
}

/// Where a damaged manifest went wrong, taken from the accessors rather than the sentence.
///
/// A field is the better answer ("layers[2].transform.size"); a line and column are what is left when
/// the text never became a document.
fn manifest_detail(error: &comp_core::Error) -> String {
    let detail = error.detail();
    if let Some(field) = error.field() {
        return format!("{detail} (at {field})");
    }
    match (error.line(), error.column()) {
        (Some(line), Some(column)) => format!("{detail} (line {line}, column {column})"),
        (Some(line), None) => format!("{detail} (line {line})"),
        _ => detail,
    }
}

/// A failure that carries only its stage: the stage still picks the category.
fn from_stage(stage: comp_core::ErrorSource, detail: String) -> LoadProblem {
    match stage {
        comp_core::ErrorSource::Package => LoadProblem::CorruptPackage { detail },
        comp_core::ErrorSource::Manifest => LoadProblem::DamagedManifest { detail },
        comp_core::ErrorSource::Asset => LoadProblem::DamagedAsset { name: "an image".to_string(), detail },
        comp_core::ErrorSource::Media => LoadProblem::UnsupportedMedia { detail },
        comp_core::ErrorSource::Io => LoadProblem::Io { detail },
        comp_core::ErrorSource::Pixel | comp_core::ErrorSource::Other => LoadProblem::Other { detail },
    }
}

/// A message that names an asset: the format layer says missing, a decoder says damaged.
///
/// This is the comp-io path: its errors arrive as sentences the importer wrote, not as these kinds.
fn classify_asset(detail: &str) -> LoadProblem {
    let name = detail.trim().trim_matches('"').to_string();
    let lower = detail.to_lowercase();
    if lower.contains("decode") || lower.contains("damaged") || lower.contains("corrupt") || lower.contains("not a png") {
        return LoadProblem::DamagedAsset { name, detail: detail.to_string() };
    }
    LoadProblem::MissingAsset { name }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_path_that_is_not_a_project_keeps_its_own_category() {
        let problem = LoadProblem::from_core(&comp_core::Error::not_a_project("there is no manifest.json here"));
        assert_eq!(problem.category(), "not a project");
        assert!(problem.detail().contains("no manifest.json"), "{}", problem.detail());
        assert!(problem.hint().contains("project folder"), "{}", problem.hint());
        assert!(problem.summary().contains("no manifest.json"), "{}", problem.summary());
    }

    #[test]
    fn a_damaged_package_is_a_corrupt_package_with_the_readers_reason() {
        let problem = LoadProblem::from_core(&comp_core::Error::damaged_package("the digest does not match"));
        assert_eq!(problem.category(), "corrupt package");
        assert!(problem.detail().contains("digest does not match"), "{}", problem.detail());
        assert!(problem.hint().contains("wait"), "{}", problem.hint());
    }

    #[test]
    fn a_manifest_field_is_named_in_the_reason() {
        // The accessor's field, not a parsed sentence: the reason has to name the place at fault.
        let error = comp_core::Error::manifest("layers[2].transform.size", "is not a size");
        assert_eq!(error.field(), Some("layers[2].transform.size"));
        let problem = LoadProblem::from_core(&error);
        assert_eq!(problem.category(), "damaged manifest");
        assert!(problem.detail().contains("layers[2].transform.size"), "{}", problem.detail());
        assert!(problem.detail().contains("is not a size"), "{}", problem.detail());
        assert!(problem.summary().contains("layers[2].transform.size"), "{}", problem.summary());
    }

    #[test]
    fn a_manifest_that_did_not_parse_reports_the_line_and_column_from_the_accessors() {
        let broken = serde_json::from_str::<serde_json::Value>("{\"layers\": [").unwrap_err();
        let error = comp_core::Error::manifest_json(&broken);
        let (line, column) = (error.line().expect("a line"), error.column().expect("a column"));
        assert_eq!(line, broken.line());
        assert_eq!(column, broken.column());
        let problem = LoadProblem::from_core(&error);
        assert_eq!(problem.category(), "damaged manifest");
        let detail = problem.detail();
        assert!(detail.contains(&format!("line {line}")), "{detail}");
        assert!(detail.contains(&format!("column {column}")), "{detail}");
    }

    #[test]
    fn a_manifest_with_neither_field_nor_position_still_reads_well() {
        let error = comp_core::Error::DamagedManifest {
            field: None,
            detail: "the layer list is not a list".to_string(),
            line: None,
            column: None,
        };
        let problem = LoadProblem::from_core(&error);
        assert_eq!(problem.category(), "damaged manifest");
        assert_eq!(problem.detail(), "The project's manifest is damaged: the layer list is not a list");
        assert!(!problem.hint().is_empty());
    }

    #[test]
    fn a_path_problem_from_the_format_layer_carries_the_path_it_could_not_use() {
        let error = comp_core::Error::illegal_path("Z:/gone/Doc.comp", "the drive is not there");
        assert_eq!(error.path(), Some("Z:/gone/Doc.comp"));
        let problem = LoadProblem::from_core(&error);
        assert_eq!(problem.category(), "illegal path");
        assert!(problem.detail().contains("Z:/gone/Doc.comp"), "{}", problem.detail());
        assert!(problem.detail().contains("drive"), "{}", problem.detail());
        assert!(problem.hint().contains("path"), "{}", problem.hint());
    }

    #[test]
    fn a_damaged_asset_is_named_in_the_reason_and_in_the_summary() {
        let error = comp_core::Error::damaged_asset("layer-4.png", "not a PNG");
        assert_eq!(error.asset(), Some("layer-4.png"));
        let problem = LoadProblem::from_core(&error);
        assert_eq!(problem.category(), "damaged asset");
        assert!(problem.detail().contains("layer-4.png"), "{}", problem.detail());
        assert!(problem.summary().contains("layer-4.png"), "{}", problem.summary());
        assert!(problem.hint().contains("replaced"), "{}", problem.hint());
    }

    #[test]
    fn an_image_that_could_not_be_written_names_the_asset_when_it_knows_it() {
        let named = LoadProblem::from_core(&comp_core::Error::encode_failed(Some("layer-5.png"), "the disk is full"));
        assert_eq!(named.category(), "write failed");
        assert!(named.detail().contains("layer-5.png"), "{}", named.detail());
        assert!(named.detail().contains("full"), "{}", named.detail());

        let anonymous = LoadProblem::from_core(&comp_core::Error::encode_failed(None, "the disk is full"));
        assert_eq!(anonymous.category(), "write failed");
        assert!(anonymous.detail().contains("An image"), "{}", anonymous.detail());
        assert!(!anonymous.hint().is_empty());
    }

    #[test]
    fn a_staged_failure_is_classified_by_its_stage() {
        use comp_core::ErrorSource;
        let cases = [
            (ErrorSource::Package, "corrupt package"),
            (ErrorSource::Manifest, "damaged manifest"),
            (ErrorSource::Asset, "damaged asset"),
            (ErrorSource::Media, "unsupported image"),
            (ErrorSource::Io, "io"),
            (ErrorSource::Pixel, "other"),
            (ErrorSource::Other, "other"),
        ];
        for (stage, expected) in cases {
            assert_eq!(stage.as_str().is_empty(), false);
            let problem = LoadProblem::from_core(&comp_core::Error::failed(stage, "something went wrong"));
            assert_eq!(problem.category(), expected, "{stage:?}");
            assert!(problem.detail().contains("something went wrong"), "{stage:?}: {}", problem.detail());
        }
    }

    #[test]
    fn the_coarse_kinds_still_get_a_category_a_reason_and_advice() {
        let cases = [
            (comp_core::Error::Invalid, "corrupt package"),
            (comp_core::Error::MissingAsset("layer-3.png".to_string()), "missing asset"),
            (comp_core::Error::TooLarge("canvas is 90000x90000".to_string()), "over a limit"),
            (comp_core::Error::Encode, "write failed"),
            (comp_core::Error::Decode("not a PNG".to_string()), "unsupported image"),
            (comp_core::Error::Message("something else".to_string()), "other"),
            (comp_core::Error::UnsupportedVersion(99), "unsupported version"),
            (comp_core::Error::BufferSize { got: 1, expected: 2, width: 3, height: 4 }, "other"),
        ];
        for (error, expected) in cases {
            let problem = LoadProblem::from_core(&error);
            assert_eq!(problem.category(), expected, "{error}");
            assert!(!problem.detail().is_empty(), "{error} has no reason");
            assert!(!problem.hint().is_empty(), "{error} has no advice");
            assert!(problem.summary().starts_with(problem.category()));
            // The coarse ones are exactly the kinds this build cannot say more about.
            assert_eq!(error.is_coarse(), !matches!(error, comp_core::Error::BufferSize { .. }), "{error}");
        }
    }

    #[test]
    fn a_missing_asset_is_named_by_its_file_and_never_by_a_path() {
        // The coarse variant carries whatever the producer had in hand, which can be a package path or
        // a path from disk; the accessor turns all of them into the file's own name.
        let cases = [
            ("layer-3.png", "layer-3.png"),
            ("images/A1B2.png", "A1B2.png"),
            ("images\\A1B2.png", "A1B2.png"),
            ("C:\\work\\Doc.comp\\assets\\mask-1.png", "mask-1.png"),
        ];
        for (payload, expected) in cases {
            let problem = LoadProblem::from_core(&comp_core::Error::MissingAsset(payload.to_string()));
            match &problem {
                LoadProblem::MissingAsset { name } => {
                    assert_eq!(name, expected, "{payload}");
                    assert!(!name.contains('/') && !name.contains('\\'), "{name} is still a path");
                }
                other => panic!("{payload} was classified as {other:?}"),
            }
            assert!(problem.detail().contains(expected), "{}", problem.detail());
            assert!(problem.summary().contains(expected), "{}", problem.summary());
        }

        // The reason is still the reader's, and it is kept beside the name.
        let problem = LoadProblem::from_core(&comp_core::Error::MissingAsset("images/layer-3.png".to_string()));
        assert_eq!(problem.detail(), "The image layer-3.png is named by the project but is not in it");
        assert!(problem.hint().contains("backup"), "{}", problem.hint());
    }

    #[test]
    fn a_kind_this_file_has_never_seen_falls_through_to_the_sentence_classifier() {
        // The wildcard arm is a safety net for a variant comp-core adds after this file is written;
        // it cannot be reached from today's variants, so what is tested is that the fallback it calls
        // still classifies a sentence a future kind would produce.
        let problem = LoadProblem::from_message("the project could not be read: the digest does not match");
        assert_eq!(problem.category(), "corrupt package");
        let problem = LoadProblem::from_message("Z:/gone.comp could not be used: the drive is not there");
        assert_eq!(problem.category(), "illegal path");
    }

    #[test]
    fn every_mapping_answers_with_a_reason_that_names_something() {
        // The audit the task asks for: a reason has to carry the field, the asset, the path or the
        // position it is about, not a restatement of the category.
        let cases: Vec<(comp_core::Error, &str)> = vec![
            (comp_core::Error::manifest("width", "is not a number"), "width"),
            (comp_core::Error::damaged_asset("mask-1.png", "truncated"), "mask-1.png"),
            (comp_core::Error::illegal_path("C:/gone", "not a directory"), "C:/gone"),
            (comp_core::Error::encode_failed(Some("layer-9.png"), "no room"), "layer-9.png"),
            (comp_core::Error::manifest_json(&serde_json::from_str::<serde_json::Value>("{").unwrap_err()), "line 1"),
        ];
        for (error, needle) in cases {
            let problem = LoadProblem::from_core(&error);
            let haystack = format!("{} {} {}", problem.detail(), problem.hint(), problem.summary());
            assert!(haystack.contains(needle), "{error}: {haystack} does not name {needle}");
        }
    }

    #[test]
    fn an_unsupported_version_names_both_versions() {
        let problem = LoadProblem::from_core(&comp_core::Error::UnsupportedVersion(99));
        assert_eq!(problem, LoadProblem::UnsupportedVersion { found: 99 });
        assert_eq!(problem.category(), "unsupported version");
        let detail = problem.detail();
        assert!(detail.contains("99") && detail.contains("1 to"), "{detail}");
        assert!(!problem.hint().is_empty());
    }

    #[test]
    fn a_missing_asset_and_a_damaged_one_are_told_apart_by_their_kinds() {
        // The two are separate variants now, so the classifier reads the kind instead of guessing
        // from the sentence: a missing asset keeps its name, a damaged one carries the reason too.
        let missing = LoadProblem::from_core(&comp_core::Error::MissingAsset("layer-3.png".to_string()));
        assert_eq!(missing, LoadProblem::MissingAsset { name: "layer-3.png".to_string() });
        assert!(missing.detail().contains("layer-3.png"), "the asset is named");
        assert_eq!(missing.category(), "missing asset");

        let damaged = LoadProblem::from_core(&comp_core::Error::damaged_asset("layer-3.png", "bad chunk"));
        assert_eq!(damaged.category(), "damaged asset");
        assert!(damaged.detail().contains("bad chunk"), "{}", damaged.detail());
        assert_ne!(missing.category(), damaged.category());

        // The guess still exists, for the sentences comp-io writes, and lands on the same two kinds.
        let from_sentence = LoadProblem::from_message("an image inside the project is missing or damaged: layer-3.png");
        assert_eq!(from_sentence.category(), "missing asset");
        let from_sentence = LoadProblem::from_message("layer-3.png could not be decoded: bad chunk");
        assert_eq!(from_sentence.category(), "other", "a bare decoder sentence claims no kind");
    }

    #[test]
    fn a_json_error_points_at_the_line_it_stopped_on() {
        let broken = serde_json::from_str::<serde_json::Value>("{\"layers\": [").unwrap_err();
        let (line, column) = (broken.line(), broken.column());
        let problem = LoadProblem::from_core(&comp_core::Error::Json(broken));
        let detail = problem.detail();
        assert!(detail.contains(&format!("line {line}")), "{detail}");
        assert!(detail.contains(&format!("column {column}")), "{detail}");
        assert_eq!(problem.category(), "damaged manifest");
    }

    #[test]
    fn an_unreadable_package_says_so_rather_than_blaming_the_user() {
        let problem = LoadProblem::from_core(&comp_core::Error::Invalid);
        assert_eq!(problem.category(), "corrupt package");
        assert!(problem.hint().contains("wait"), "a half-written package is worth retrying: {}", problem.hint());
    }

    #[test]
    fn a_limit_is_reported_with_the_limit_the_layer_named() {
        let problem = LoadProblem::from_core(&comp_core::Error::TooLarge("canvas is 90000x90000".to_string()));
        assert_eq!(problem.category(), "over a limit");
        assert!(problem.detail().contains("90000"), "{:?}", problem.detail());
    }

    #[test]
    fn the_readers_sentences_are_classified_too() {
        // What a damaged package fuzz produces, and what comp-io answers with.
        let cases = [
            ("this project uses format version 12; this build supports versions 1-11", "unsupported version"),
            ("an image inside the project is missing or damaged: layer-2.png", "missing asset"),
            ("the Photoshop file is damaged or incomplete: truncated layer records", "damaged Photoshop file"),
            ("this Photoshop file uses format version 2, which this build cannot read", "damaged Photoshop file"),
            ("this image exceeds the supported limits: 40000x40000", "over a limit"),
            ("only 8-bit images can be imported; this file is 16-bit", "unsupported image"),
            ("choose a JPEG, PNG, TIFF, BMP, or WebP file: notes.txt", "unsupported image"),
            ("No such file or directory (os error 2)", "io"),
            ("expected value at line 3 column 1", "damaged manifest"),
            ("this is not a valid Compositor project, or its metadata is damaged", "corrupt package"),
        ];
        for (message, expected) in cases {
            let problem = LoadProblem::from_message(message);
            assert_eq!(problem.category(), expected, "{message} was classified as {problem:?}");
            assert!(!problem.detail().is_empty());
            assert!(!problem.hint().is_empty(), "{message} has no advice");
        }
    }

    #[test]
    fn a_reader_message_that_fits_nothing_keeps_its_own_words() {
        let problem = LoadProblem::from_message("the plate reader exploded");
        assert_eq!(problem.category(), "other");
        assert_eq!(problem.detail(), "the plate reader exploded");
    }

    #[test]
    fn the_finer_kinds_comp_core_grew_are_read_through_their_sentences() {
        // comp-core is refining its errors while this is written, so the classifier reads the
        // sentences those kinds produce: they name the field, the asset and the path.
        let cases = [
            ("this is not a Compositor project: no manifest.json in the folder", "not a project"),
            ("the project could not be read: the digest does not match", "corrupt package"),
            ("C:/gone/Doc.comp could not be used: not a directory", "illegal path"),
            ("layer-5.png could not be written: the disk is full", "write failed"),
            ("the image layer-4.png could not be read: not a PNG", "damaged asset"),
        ];
        for (message, expected) in cases {
            let problem = LoadProblem::from_message(message);
            assert_eq!(problem.category(), expected, "{message} was classified as {problem:?}");
            assert!(!problem.hint().is_empty());
        }

        // A named path survives into the classification, which is what a dialog needs to show.
        let path = LoadProblem::from_message("Z:/gone.comp could not be used: the drive is not there");
        match path {
            LoadProblem::IllegalPath { path, detail } => {
                assert_eq!(path, "Z:/gone.comp");
                assert!(detail.contains("drive"), "{detail}");
            }
            other => panic!("expected a path problem, got {other:?}"),
        }
        // And a named manifest field survives too.
        let field = LoadProblem::from_message("the manifest is damaged at layers[2].transform.size: is not a size");
        assert_eq!(field.category(), "damaged manifest");
        assert!(field.detail().contains("layers[2].transform.size"), "{}", field.detail());
    }

    #[test]
    fn every_typed_error_has_a_category_and_a_hint() {
        let errors = [
            comp_core::Error::Invalid,
            comp_core::Error::UnsupportedVersion(40),
            comp_core::Error::MissingAsset("a.png".to_string()),
            comp_core::Error::TooLarge("too many layers".to_string()),
            comp_core::Error::Encode,
            comp_core::Error::Decode("not a png".to_string()),
            comp_core::Error::Message("something else".to_string()),
            comp_core::Error::BufferSize { got: 1, expected: 2, width: 3, height: 4 },
        ];
        for error in errors {
            let problem = LoadProblem::from_core(&error);
            assert!(!problem.category().is_empty());
            assert!(!problem.detail().is_empty(), "{error} has no detail");
            assert!(!problem.hint().is_empty(), "{error} has no advice");
            assert!(problem.summary().starts_with(problem.category()), "{error}");
        }
    }

    #[test]
    fn an_illegal_path_carries_the_path_it_could_not_use() {
        let problem = LoadProblem::IllegalPath {
            path: "Z:\\gone\\Doc.comp".to_string(),
            detail: "the drive is not there".to_string(),
        };
        assert_eq!(problem.category(), "illegal path");
        let detail = problem.detail();
        assert!(detail.contains("Z:\\gone\\Doc.comp") && detail.contains("drive"), "{detail}");
    }

    #[test]
    fn a_version_the_reader_could_not_parse_still_lands_on_the_version_kind() {
        // A fuzzed package whose version field is not a number.
        let problem = LoadProblem::from_message("this project uses format version ; this build supports versions 1-11");
        assert!(matches!(problem, LoadProblem::UnsupportedVersion { .. }), "{problem:?}");
        let problem = LoadProblem::from_message("this project uses format version 7; this build supports versions 1-11");
        assert_eq!(problem, LoadProblem::UnsupportedVersion { found: 7 });
    }
}
