# comp-core notes

Open work and limits that a reader should know about. The format layer (store.rs, digest.rs,
png_io.rs) and its tests were hardened in this pass; everything below is either a deliberate
deviation from the macOS app, an environment limitation, or work left for another pass.

## Package replacement

- A save stages a complete sibling package and swaps it in. Windows cannot rename a directory over
  another one, so the swap is a move-aside followed by a rename, and the staged copy is always
  removed when either step fails.
- The swap is serialized by a process-wide mutex. This is an in-process guarantee only: two
  processes saving the same package (a second app instance, a script, a sync client) can still
  interleave their renames. The macOS app covers that window with NSFileCoordinator. Closing it on
  Windows needs a named mutex or a lock file in the package's parent directory, which is out of
  scope for this pass.
- Residual backups: a directory named .<name>.comp.backup-<uuid> means a save was interrupted
  between the two renames, or that restoring the previous package failed because another writer had
  already claimed the path. That directory holds the previous package, complete. Recovery: if
  <name>.comp is missing, move the newest backup back to <name>.comp; never delete a backup that is
  the only copy. The error a failed restore returns names the backup path. Staging directories are
  never left behind, so anything named .<name>.comp.staging-<uuid> can be deleted.
- A save refuses a layer whose image_file or mask_file outlives its pixels (Error::MissingAsset).
  Writing that manifest would produce a package that cannot be read back; the macOS app refuses the
  same save with ProjectError.missingImage.

## Digest

- The digest follows the macOS ProjectDigest: the manifest's bytes, then each regular file in
  images/ by name and byte length, sorted by name. Directories, links and other non-regular entries
  are skipped. The manifest is hashed as bytes and never parsed, so a package caught half written
  still has a digest, one that matches nothing, and a watcher waits for the next change instead of
  failing.
- Documented boundary: an asset rewritten with exactly the same byte length is invisible unless the
  manifest changes too. docs/writing-comp-files.md tells writers to touch the manifest in that case.
  A manifest over the 4 MiB limit is an error rather than a digest.

## PNG assets

- Layer images accept every 8-bit color type; palette and sub-byte files are expanded. Masks must be
  single-channel: RGB, RGBA, gray+alpha and palette files are rejected, exactly as the macOS
  LayerMask.isValid rejects them. Deliberate deviation: a 1, 2 or 4 bit grayscale mask is expanded
  and accepted, where the macOS app requires 8 bits per component and refuses the file. Being more
  forgiving on read cannot make a package that macOS wrote unreadable here.
- The header is measured before any pixels are allocated. An asset that claims a surface beyond 200
  megapixels, or a document whose images or masks exceed the 100 megapixel budgets, is refused
  without a buffer being allocated, so a decompression bomb cannot exhaust memory.
- A PNG with an animation control chunk holding more than one frame is refused: one asset is one
  frame, and the macOS loader requires ImageIO to report a single frame. Interlaced PNGs decode.
- The png crate's default 64 MiB budget would refuse legal surfaces of about 4200x4100 RGBA, so the
  decoder budget is derived from the header instead (about 1 MiB budget for a 1 MiB budget).
  Regenerate nothing: this is internal.

## Environment limits on testing

- Read-only directories: the sandbox used for this pass grants the test user a group with Modify and
  ignores a deny entry for the user itself, so a save into a directory that truly refuses writes
  cannot be built as a test. What is tested instead: a destination whose parent cannot be created
  (Error::Io, nothing replaced), a swap that fails after the old package moved aside (rollback), and
  a staged write that fails (cleanup). A read-only package directory surfaces as Error::Io too.
- Symlinks need administrator rights or developer mode on this machine, so the symlink case of
  assets that resolve outside the package is covered with a directory junction (no privilege
  needed), and the symlink itself is tried and skipped when the system refuses to create one.

## Golden fixtures

- fixtures/ holds three packages written by fixtures/make_fixtures.py with Pillow: RGBA layers, a
  palette layer with a transparency table, grayscale masks, a 1x1 mask, a folder with its own
  opacity and mask, a clipping mask, layer effects, text runs, a shape layer, guides, adjustment
  layers and an unlinked mask. expected/ holds the raw pixels the generator read back from the PNGs
  it wrote, so tests/fixtures.rs compares two independent PNG decoders, not this crate with itself.
- Regenerate with: python fixtures/make_fixtures.py (Pillow and Python come from the workspace
  runtime). The ids are derived from fixed integers, so regenerating rewrites identical bytes.

## Format version coverage

- Versions 1, 3, 5, 7, 8, 9 and 11 packages are written by hand in the integration tests and read
  back; every save writes version 11, which is what the macOS ProjectManifest.current does.
- The document pixel budgets come from limits.rs (100 million image pixels, 100 million mask pixels)
  rather than from the macOS DocumentLimits.documentPixelBudget, which scales with physical memory.
  The constants here are the ones docs/project-format.md states.
## Error granularity (the second generation)

A caller used to have to read the sentence to tell one failure from another: `Invalid` covered
"not a package", "the path is not there" and "the metadata is damaged"; `MissingAsset` covered
"not in the package" and "cannot be decoded"; `Encode` carried no context at all; `Message` and
`Decode` were flat strings; and a manifest error never said which field it was about.

The fine-grained kinds are `NotAProject`, `DamagedPackage`, `DamagedManifest { field, detail, line,
column }`, `IllegalPath { path, detail }`, `DamagedAsset { name, detail }`, `EncodeFailed { asset,
detail }` and `Failed { stage, detail }`. `Error::source()` answers `ErrorSource` (package, manifest,
asset, pixel, media, io, other) for both generations; `field()`, `asset()`, `path()`, `line()`,
`column()`, `detail()` and `is_coarse()` answer for both as well. Named constructors
(`Error::manifest(field, detail)` and friends) keep call sites readable.

Two things are deliberately unchanged:

- **The coarse variants stay.** `Invalid`, `MissingAsset(String)`, `Encode`, `Decode(String)`,
  `Message(String)`, `UnsupportedVersion(u32)`, `TooLarge(String)`, `Json`, `Io` and `BufferSize`
  are public API that other crates and their tests still name, so they keep their names, their
  payloads and their exact sentences. The producers in this crate have moved to the fine kinds -
  `Error::Encode` and `Error::Invalid` are no longer constructed anywhere in comp-core - but a
  consumer sees no removed variant and no changed shape.
- **The acceptance rule stays.** Only the *description* changed: the same packages load and the
  same packages are refused. `crates/comp-core/tests/error_parity.rs` is the regression test. It
  walks one table of 17 hostile shapes twice: `the_rejection_set_is_unchanged` asks only whether
  the load failed, so it answers the same before and after the refinement, and
  `a_refusal_says_what_is_wrong` pins the new description of each - which field, which asset,
  which path, which stage. Fields under `layers[i].*` name the layer by its index in the
  manifest, which is the path a reader can act on.

Where each refusal comes from now:

| Shape on disk | Kind | Carries |
|---|---|---|
| no `manifest.json`, not JSON, another format id | `NotAProject` | detail |
| JSON that parses a header but not a document | `DamagedManifest` | line, column |
| a field the format does not allow (transform, name, imageFile, maskFile, opacity, ...) | `DamagedManifest` | field |
| a version this build does not read | `UnsupportedVersion` | the version |
| canvas, layer or surface past a budget | `TooLarge` | the limit |
| an asset the manifest names that is not there | `MissingAsset` | the file name |
| an asset that is there and cannot be decoded, or is the wrong surface | `DamagedAsset` | file name, reason |
| a path that is missing, is a file, or leaves the package | `IllegalPath` | path, reason |
| an image the encoder refused | `EncodeFailed` | asset name when the writer knew it, reason |

`Error::line()` and `Error::column()` also answer for the legacy `Json` variant, so a caller that
still matches on it can report a position.

### Wiring left for the GUI

comp-gui's `LoadProblem::from_core` matches every `Error` variant and currently ends in a wildcard
that reports anything new as `Other` (added so this refinement could land without touching the
shell). Mapping the new kinds to the categories it already has is a pure lookup:

| comp-core | comp-gui |
|---|---|
| `NotAProject { detail }` | `CorruptPackage { detail }` |
| `DamagedPackage { detail }` | `CorruptPackage { detail }` |
| `DamagedManifest { field, detail, .. }` | `DamagedManifest { detail }`, with `field` appended when present |
| `MissingAsset(name)` | `MissingAsset { name }` (no string sniffing needed) |
| `DamagedAsset { name, detail }` | `DamagedAsset { name, detail }` (no string sniffing needed) |
| `IllegalPath { path, detail }` | `IllegalPath { path, detail }` |
| `EncodeFailed { asset, detail }` | `Other { detail }`, or a new export category |
| `Failed { stage, detail }` | `Other { detail }`, or a category chosen from `stage` |

With that, `classify_asset` (which guesses damage from the wording) and the sentence sniffing in
`from_message` can be deleted for these cases. `Error::is_coarse()` marks the remaining coarse
kinds, so the shell can tell which answers still need the old path.

### Not done here

- comp-io keeps its own `IoError` (unreadable, unsupported format, unsupported depth, too large,
  invalid). It is already structured, so nothing was changed there; only `comp-cli` prints the new
  fields (a second `compc:` line with stage, field, asset, path and position).
- `Error::Json` still answers `Error::source() == Manifest`: the only JSON this crate parses is a
  manifest. A caller that parses something else with that variant should use `Error::failed`.
- The CLI still builds its own argument errors (a bad hex colour, a missing layer image) out of
  `Invalid` and `Message`. They never reach the GUI's load path, so they were left alone.
### Asset names through the accessors (task-56)

`Error::asset()` answers for every kind that is about one image, and always with the file's own
name rather than the path a producer happened to hold:

- `DamagedAsset { name }` and `EncodeFailed { asset }` return what they were given, and answer
  `None` for a name that is empty or only whitespace (a name that names nothing).
- `MissingAsset(payload)` - the coarse variant, still raised by `read_file` and `package_digest` -
  has its name read out of the payload: the tail after the last `": "` when a producer wrapped a
  sentence around it (safe, because a Windows file name cannot contain a colon), then the last
  component after a `\` or `/`. `images\A1B2.png`, `E:\Docs\Doc.comp\images\A1B2.png` and a bare
  `A1B2.png` all answer `A1B2.png`. Prose with neither a colon nor a separator comes back
  unchanged: a name is never invented, so a caller sees what it saw before the accessor existed.
- `None` from `asset()` means the producer did not know which image it was, not that the failure is
  unrelated to one: `Error::source()` is still `Asset`. That is the case `png_io` raises, because an
  encoder handed a buffer with no pixels has no file name to report; its callers add theirs
  (`store` names the layer's asset, `compc` names the file it was writing).

Nothing about the payloads or the sentences changed: `MissingAsset` still displays its payload
verbatim, which is why the accessor reads the payload instead of the producers rewriting it.
`crates/comp-core/tests/error_parity.rs` asserts that a missing asset found by `load` comes back
with a bare `.png` name and not a path, and `tests/package_safety.rs` asserts the exact name for a
package whose asset was removed.

One legacy edge, left as it was: `package_digest` raises `MissingAsset` for a file that disappears
between listing and reading, including `manifest.json` itself. That path is only reachable in a race
(`load` reads the manifest first and answers `NotAProject` when it is absent), so it was not changed.
