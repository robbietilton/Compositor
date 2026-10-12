# Language packs

Compositor keeps English in the application and downloads every other language from this directory through GitHub's
raw-file endpoint. A downloaded pack is verified with the SHA-256 value in `manifest.json`, then stored under
`Application Support/Compositor/Languages` so it remains available offline.

The **Help → Language** menu contains packs that have been downloaded and verified successfully, plus valid local packs.
For an offline installation, copy `<language-code>.json` into
`~/Library/Application Support/Compositor/Languages`; a manifest is optional for manually installed files. Compositor
checks the file name, language code, revision, size, contents, and formatting placeholders before offering it. If no
local or downloadable language is available, the menu remains visible with English as its only option.

Each pack is JSON with a schema version, BCP 47 language code, revision, and `strings` dictionary. To publish a change:

1. Update the translation source in `Compositor/Localizable.xcstrings`.
2. Export that language to `<language-code>.json` and increment its revision.
3. Calculate the file's SHA-256 and update its entry in `manifest.json`.
4. Commit and push both files to `main` together.

New languages need only a pack and a manifest entry. The application downloads the manifest at launch, so adding one
does not require a new Compositor release. Missing translations fall back to the English key.

## Translate a new language

`translation-template.json` is a machine-readable, publishable language-pack template containing every current English
string. Copy it to `<language-code>.json`, set `language` to the target's BCP 47 code, and translate only the values in
`strings`. Keep every key and formatting token such as `%@`, `%lld`, and `%%` unchanged. English values may be left in
place while a translation is incomplete; alternatively, omit those entries to use Compositor's English fallback.

`language-pack.schema.json` describes the runtime format for editors and automated tooling. Before opening a pull
request, set `revision` to 1 (or increment it for an existing language), add the pack to `manifest.json`, and record the
exact file checksum with `shasum -a 256 <language-code>.json`.
