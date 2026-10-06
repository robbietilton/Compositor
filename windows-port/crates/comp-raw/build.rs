//! Links LibRaw when the `libraw` feature is on.
//!
//! Nothing here runs for a normal build: the default configuration is pure Rust and needs no C or C++
//! toolchain at all. With the feature enabled this finds the static libraries that
//! `tools/libraw/build-libraw.ps1` produced and links them, failing with the command to run when they
//! are missing rather than letting the link fail with an unrelated message.

use std::path::PathBuf;

fn main() {
    println!("cargo:rerun-if-changed=build.rs");
    println!("cargo:rerun-if-env-changed=LIBRAW_ROOT");
    println!("cargo:rerun-if-env-changed=LIBRAW_LIB_DIR");
    println!("cargo:rerun-if-env-changed=LIBRAW_JPEG_LIB_DIR");

    if std::env::var_os("CARGO_FEATURE_LIBRAW").is_none() {
        return;
    }

    let manifest = PathBuf::from(std::env::var("CARGO_MANIFEST_DIR").expect("cargo sets this"));
    let root = std::env::var_os("LIBRAW_ROOT")
        .map(PathBuf::from)
        .unwrap_or_else(|| manifest.join("../../target-raw-pipeline/libraw"));
    // LIBRAW_DLL=1 links the shared library instead of the static one. That is the packaging option
    // whose redistribution obligations are simplest for a closed-source product (see NOTES.md), and it
    // is what the size comparison there was measured with.
    let shared = std::env::var_os("LIBRAW_DLL").is_some_and(|value| value != "0");
    if shared {
        let dir = std::env::var_os("LIBRAW_LIB_DIR")
            .map(PathBuf::from)
            .unwrap_or_else(|| root.join("build/libraw-shared/Release"));
        let library = dir.join("raw.lib");
        if !library.is_file() {
            panic!(
                "LIBRAW_DLL is set but {} is missing. Run tools/libraw/build-libraw.ps1 -Shared, or unset LIBRAW_DLL.",
                library.display()
            );
        }
        println!("cargo:rerun-if-env-changed=LIBRAW_DLL");
        println!("cargo:rerun-if-changed={}", library.display());
        println!("cargo:rustc-link-search=native={}", dir.display());
        println!("cargo:rustc-link-lib=dylib=raw");
        return;
    }

    let libraw_dir = std::env::var_os("LIBRAW_LIB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("build/libraw-static/Release"));
    let jpeg_dir = std::env::var_os("LIBRAW_JPEG_LIB_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| root.join("build/jpeg/Release"));

    let libraw_lib = libraw_dir.join("libraw_r.lib");
    let jpeg_lib = jpeg_dir.join("jpeg-static.lib");
    for path in [&libraw_lib, &jpeg_lib] {
        if !path.is_file() {
            panic!(
                "the libraw feature needs {}, which is missing. Run tools/libraw/fetch-libraw.ps1 then tools/libraw/build-libraw.ps1, or set LIBRAW_ROOT to the directory holding build/.",
                path.display()
            );
        }
    }

    // The libraries are inputs in their own right: rustc bundles a native static library into the
    // rlib, so a rebuilt LibRaw has to invalidate this crate or cargo would link the old objects out
    // of its cache.
    println!("cargo:rerun-if-changed={}", libraw_lib.display());
    println!("cargo:rerun-if-changed={}", jpeg_lib.display());
    println!("cargo:rustc-link-search=native={}", libraw_dir.display());
    println!("cargo:rustc-link-search=native={}", jpeg_dir.display());
    println!("cargo:rustc-link-lib=static=libraw_r");
    println!("cargo:rustc-link-lib=static=jpeg-static");
    // LibRaw is C++, and Rust's MSVC target does not pull in the C++ runtime on its own.
    if std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc") {
        println!("cargo:rustc-link-lib=msvcprt");
    }
}
