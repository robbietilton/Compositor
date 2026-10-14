# Notes for AI agents

Compositor is a macOS image editor for compositing and photo work, written in Swift (SwiftUI and AppKit, with some C for pixel work).

## Designing or editing a Compositor project

If you've been asked to make or change an image in a `.comp` project, you don't need the app's source code. Read [docs/writing-comp-files.md](docs/writing-comp-files.md): it covers the file format, the rules that make a project load, and how to write it safely while it's open, so the person can watch the canvas update as you work.

## Working on the app itself

- Build: open `Compositor.xcodeproj` and run the **Compositor** scheme, or `xcodebuild -project Compositor.xcodeproj -scheme Compositor -destination 'platform=macOS' build`.
- Tests: the `CompositorTests` target (`xcodebuild ... test -only-testing:CompositorTests`). CI runs these on every push.
- Match the surrounding code: its naming, its comment style and density.
- American spelling in code, comments and UI ("color", not "colour").
- The project file format is described in [docs/project-format.md](docs/project-format.md). A change to what's saved means a format version bump there and in `ProjectManifest.current`.

## iPadOS

`CompositorPad` is an iPad app on the same editor. It builds Document/, IO/ and Rendering/ from `Compositor/`, under the touch interface in `CompositorPad/`.

- Build: `xcodebuild -project Compositor.xcodeproj -scheme CompositorPad -destination 'generic/platform=iOS Simulator' build`.
- Tests: the `CompositorPadTests` target, on an iPad simulator (`xcodebuild ... -scheme CompositorPad -destination 'platform=iOS Simulator,name=<an iPad>' test`). CI runs these too.
- Everything in `Compositor/` builds for both, except the Mac's own interface, listed in `MAC_ONLY_SOURCES` in `CompositorPad/CompositorPad.xcconfig`. A new file that is the Mac's interface goes on that list.
- In Document/, IO/ and Rendering/, import the frameworks a file uses rather than AppKit. The beep, the general pasteboard and drawing text go through `Compositor/Platform/Platform.swift`, which has each platform's version.
- `CompositorPad/` is grouped by the part of the window a file makes: `Window/` (the window, its tabs and what's around the canvas), `Canvas/`, `Panels/` (tools, options and layers), `Dialogs/` and `IO/` (the project's files). `CompositorPadTests/` follows the same folders. File names stay unique across folders, as Swift requires.
