//! Which subject extractor answers, and how that is said.
//!
//! Two extractors exist in comp-brush: a small ONNX salient-object network (U-2-Netp, Apache-2.0)
//! run through tract when its file is present, and a classical colour-statistics extractor that
//! always works. Which one ran decides how much a result can be trusted, so it is named in the
//! status bar before a run and in a message after one: a silent fall back to the classical
//! extractor must never look like a model answered.
//!
//! This module is the wording and the choice, kept apart from the pixels so it can be tested
//! without a model file or an image.

use std::path::PathBuf;
use std::time::Duration;

use comp_brush::{SUBJECT_MODEL_ENV, SUBJECT_MODEL_FILE};
use comp_core::bitmap::Gray8;

/// The model's name, as its own project calls it.
pub const MODEL_NAME: &str = "u2netp";
/// The model's licence, which is why this one was chosen.
pub const MODEL_LICENCE: &str = "Apache-2.0";

/// The backend a run will use, and what is known about it.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Backend {
    /// The network answered. The description is what comp-brush reports about the file it loaded.
    Model { path: PathBuf, description: String },
    /// The classical extractor answered, because no model file could be found.
    Classical,
}

/// Decides the backend from what comp-brush found: the path and description of a loaded model, or
/// nothing when there is no model file.
pub fn classify(found: Option<(PathBuf, String)>) -> Backend {
    match found {
        Some((path, description)) => Backend::Model { path, description },
        None => Backend::Classical,
    }
}

/// The line the status bar shows for the backend that would answer now.
pub fn status_line(backend: &Backend) -> String {
    match backend {
        Backend::Model { path, .. } => format!(
            "Subject: model {MODEL_NAME} ({MODEL_LICENCE}) at {}",
            path.display()
        ),
        Backend::Classical => "Subject: classical algorithm (no model found)".to_string(),
    }
}

/// Where to put a model file so the model answers instead, in the order comp-brush looks.
pub fn hint(backend: &Backend) -> Option<String> {
    if matches!(backend, Backend::Model { .. }) {
        return None;
    }
    Some(format!(
        "Put {SUBJECT_MODEL_FILE} ({MODEL_LICENCE}) where this build looks for it, in this order:\n\
         1. the file named by {SUBJECT_MODEL_ENV}\n\
         2. models\\{SUBJECT_MODEL_FILE} beside the editor's executable\n\
         3. models\\{SUBJECT_MODEL_FILE} beside the comp-brush crate in a checkout\n\
         Without it the classical extractor runs, which is a supported configuration."
    ))
}

/// What a finished run reports: who answered and how long it took.
pub fn outcome_line(backend: &Backend, elapsed: Duration, coverage: f64) -> String {
    let who = match backend {
        Backend::Model { .. } => format!("model {MODEL_NAME}"),
        Backend::Classical => "classical algorithm".to_string(),
    };
    format!(
        "Subject: {who} answered in {} (the matte covers {:.0}% of the layer)",
        format_elapsed(elapsed),
        coverage * 100.0
    )
}

/// A short label for a log line or the smoke test's evidence.
pub fn short_label(backend: &Backend) -> &'static str {
    match backend {
        Backend::Model { .. } => "model u2netp",
        Backend::Classical => "classical (no model)",
    }
}

/// What the status bar says while a run is still going.
pub fn running_line(backend: &Backend) -> String {
    match backend {
        Backend::Model { .. } => format!("Subject: model {MODEL_NAME} is working (the classical result is on screen)"),
        Backend::Classical => "Subject: the classical extractor is working".to_string(),
    }
}

/// What a run reports when the model was there but could not be used.
pub fn failure_line(reason: &str) -> String {
    format!("Subject: the model could not be used ({reason}); the classical algorithm answered instead")
}

/// The share of a matte that is more subject than background, which is what a message can report.
pub fn coverage(matte: &Gray8) -> f64 {
    let pixels = matte.pixels();
    if pixels.is_empty() {
        return 0.0;
    }
    let subject = pixels.iter().filter(|value| **value > 127).count();
    subject as f64 / pixels.len() as f64
}

/// A duration as a person reads it: milliseconds below a second, seconds above.
pub fn format_elapsed(elapsed: Duration) -> String {
    let millis = elapsed.as_secs_f64() * 1000.0;
    if millis < 1000.0 {
        format!("{:.0} ms", millis.round())
    } else {
        format!("{:.2} s", millis / 1000.0)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn model() -> Backend {
        classify(Some((
            PathBuf::from("C:/app/models/u2netp.onnx"),
            "u2netp.onnx: input input.1 [1, 3, 320x320], 7 outputs".to_string(),
        )))
    }

    #[test]
    fn the_backend_is_the_model_when_a_file_was_found_and_the_classical_one_when_not() {
        assert!(matches!(model(), Backend::Model { .. }));
        assert_eq!(classify(None), Backend::Classical);
        // The description travels with the choice, so a status line can be more specific later.
        match model() {
            Backend::Model { description, .. } => assert!(description.contains("320x320"), "{description}"),
            other => panic!("expected the model, got {other:?}"),
        }
    }

    #[test]
    fn the_model_line_names_the_model_its_licence_and_the_file_it_loaded() {
        let line = status_line(&model());
        assert!(line.contains(MODEL_NAME), "{line}");
        assert!(line.contains(MODEL_LICENCE), "{line}");
        assert!(line.contains("u2netp.onnx"), "{line}");
        assert!(line.contains("C:/app/models"), "{line}");
    }

    #[test]
    fn the_classical_line_says_no_model_was_found() {
        let line = status_line(&Backend::Classical);
        assert!(line.contains("classical"), "{line}");
        assert!(line.contains("no model found"), "{line}");
        assert!(!line.contains(MODEL_NAME), "a missing model must not be named as if it were used: {line}");
    }

    #[test]
    fn the_hint_lists_the_three_places_in_the_order_they_are_searched() {
        let advice = hint(&Backend::Classical).expect("a classical backend has advice");
        let env = advice.find(SUBJECT_MODEL_ENV).expect("the environment variable is named");
        let beside_exe = advice.find("beside the editor's executable").expect("the executable is named");
        let beside_crate = advice.find("beside the comp-brush crate").expect("the crate is named");
        assert!(env < beside_exe && beside_exe < beside_crate, "the order is wrong: {advice}");
        assert!(advice.contains(SUBJECT_MODEL_FILE), "{advice}");
        assert!(advice.contains(MODEL_LICENCE), "the licence is worth stating: {advice}");
        assert_eq!(hint(&model()), None, "there is nothing to advise when the model is there");
    }

    #[test]
    fn a_finished_run_says_who_answered_and_how_long_it_took() {
        let by_model = outcome_line(&model(), Duration::from_millis(412), 0.38);
        assert!(by_model.contains("model u2netp"), "{by_model}");
        assert!(by_model.contains("412 ms"), "{by_model}");
        assert!(by_model.contains("38%"), "{by_model}");

        let by_classical = outcome_line(&Backend::Classical, Duration::from_millis(61), 0.38);
        assert!(by_classical.contains("classical algorithm"), "{by_classical}");
        assert!(by_classical.contains("61 ms"), "{by_classical}");
        assert!(!by_classical.contains(MODEL_NAME), "a fall back must not look like a model: {by_classical}");
    }

    #[test]
    fn a_duration_reads_as_milliseconds_below_a_second_and_as_seconds_above() {
        assert_eq!(format_elapsed(Duration::from_millis(0)), "0 ms");
        assert_eq!(format_elapsed(Duration::from_millis(412)), "412 ms");
        assert_eq!(format_elapsed(Duration::from_millis(999)), "999 ms");
        assert_eq!(format_elapsed(Duration::from_millis(1000)), "1.00 s");
        assert_eq!(format_elapsed(Duration::from_millis(1240)), "1.24 s");
        assert_eq!(format_elapsed(Duration::from_millis(65_000)), "65.00 s");
        // Below a millisecond it does not become a fraction of one.
        assert_eq!(format_elapsed(Duration::from_micros(400)), "0 ms");
    }

    #[test]
    fn coverage_is_the_share_of_the_matte_that_is_subject() {
        let mut matte = Gray8::new(10, 10);
        assert_eq!(coverage(&matte), 0.0, "an empty matte covers nothing");
        for value in matte.pixels_mut().iter_mut().take(25) {
            *value = 255;
        }
        assert!((coverage(&matte) - 0.25).abs() < 1e-9, "{}", coverage(&matte));
        // A value of exactly half counts as background: the matte counts anything above the half point.
        matte.pixels_mut()[25] = 127;
        assert!((coverage(&matte) - 0.25).abs() < 1e-9);
        let empty = Gray8::new(0, 0);
        assert_eq!(coverage(&empty), 0.0, "a matte with no pixels cannot divide by zero");
    }

    #[test]
    fn a_run_in_flight_says_who_is_working_and_what_is_on_screen() {
        let working = running_line(&model());
        assert!(working.contains(MODEL_NAME), "{working}");
        assert!(working.contains("classical result is on screen"), "{working}");
        let classical = running_line(&Backend::Classical);
        assert!(classical.contains("classical extractor is working"), "{classical}");
        // The smoke test's evidence line says which extractor this build would use.
        assert_eq!(short_label(&model()), "model u2netp");
        assert_eq!(short_label(&Backend::Classical), "classical (no model)");
    }

    #[test]
    fn a_model_that_could_not_be_used_says_the_classical_one_answered_instead() {
        let line = failure_line("the file is not an ONNX model this build can read");
        assert!(line.contains("could not be used"), "{line}");
        assert!(line.contains("not an ONNX model"), "{line}");
        assert!(line.contains("classical algorithm answered instead"), "{line}");
    }
}
