//! The comp-gui binary: the editor window, plus a headless flatten check.
//!
//! Usage:
//!   comp-gui [folder.comp]                  open the editor, optionally on a package
//!   comp-gui --flatten <in.comp> <out.png>  composite a package to a PNG without a window

use std::path::PathBuf;
use std::process::ExitCode;

fn main() -> ExitCode {
    let mut arguments = std::env::args().skip(1);
    let mut initial: Option<PathBuf> = None;
    while let Some(argument) = arguments.next() {
        match argument.as_str() {
            "--flatten" => {
                let input = arguments.next().map(PathBuf::from);
                let output = arguments.next().map(PathBuf::from);
                return match (input, output) {
                    (Some(input), Some(output)) => match comp_gui::flatten_to_png(&input, &output) {
                        Ok(summary) => {
                            println!("{summary}");
                            ExitCode::SUCCESS
                        }
                        Err(message) => {
                            eprintln!("{message}");
                            ExitCode::FAILURE
                        }
                    },
                    _ => {
                        eprintln!("usage: comp-gui --flatten <in.comp> <out.png>");
                        ExitCode::FAILURE
                    }
                };
            }
            "--help" | "-h" => {
                println!("{HELP}");
                return ExitCode::SUCCESS;
            }
            other => initial = Some(PathBuf::from(other)),
        }
    }
    match comp_gui::run(initial) {
        Ok(()) => ExitCode::SUCCESS,
        Err(error) => {
            eprintln!("the editor window failed to start: {error}");
            ExitCode::FAILURE
        }
    }
}

const HELP: &str = "\
comp-gui - the Compositor for Windows editor

  comp-gui [folder.comp]                  open the editor, optionally on a package
  comp-gui --flatten <in.comp> <out.png>  composite a package to a PNG without a window
  comp-gui --help                         show this text

A .comp project is a folder holding manifest.json and images/.
";
