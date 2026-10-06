# Third-party notices

The Windows port is offered under the repository's MIT license. Its Rust dependencies are listed
in `Cargo.lock`; consult each dependency's license metadata and source distribution for its terms.

Additional components used by optional or runtime features:

- **U-2-Netp model weights**: Apache-2.0. The model is downloaded separately and is not committed.
- **LibRaw 0.21.4**: `LGPL-2.1 OR CDDL-1.0`, when built with the optional `libraw` feature. See
  `crates/comp-raw/NOTES-libraw.md` and `tools/libraw/README.md` for source checksums and distribution
  considerations.
- **libjpeg-turbo 3.1.2**: BSD-3-Clause/IJG, used by the optional LibRaw build. See
  `tools/libraw/README.md`.
- **Windows HEIF/AVIF codecs**: supplied by the user's Windows Imaging Component extensions; the
  port does not bundle them.

This index is informational. Redistributors should include the notices and license texts required
by the components and exact distribution configuration they ship.
