# Language packs

Compositor keeps English in the application and downloads every other language from this directory through GitHub's
raw-file endpoint. A downloaded pack is verified with the SHA-256 value in `manifest.json`, then stored under
`Application Support/Compositor/Languages` so it remains available offline.

Each pack is JSON with a schema version, BCP 47 language code, revision, and `strings` dictionary. To publish a change:

1. Update the translation source in `Compositor/Localizable.xcstrings`.
2. Export that language to `<language-code>.json` and increment its revision.
3. Calculate the file's SHA-256 and update its entry in `manifest.json`.
4. Commit and push both files to `main` together.

New languages need only a pack and a manifest entry. The application downloads the manifest at launch, so adding one
does not require a new Compositor release. Missing translations fall back to the English key.
