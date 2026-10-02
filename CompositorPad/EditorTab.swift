import UIKit

/// One project in a window's tab strip, as on the Mac: its editor, its canvas and, once it has a file, its document.
/// A tab without a document shows the New Canvas form, as a new tab does on the Mac.
@MainActor final class EditorTab {
    let id = UUID()
    let session = EditorSession()
    private(set) var document: CompositorDocument?
    private(set) lazy var canvas = PadCanvasView(session: session)
    /// Undo and Redo for the menu bar, the keyboard and the system's gestures, which ask the responder chain.
    private(set) lazy var undoManager = SessionUndoManager(session: session)

    /// The project being opened into the tab, while it loads.
    private(set) var openingURL: URL?

    /// The file's name without its extension, or Untitled.
    var title: String { (session.projectURL ?? openingURL)?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    /// Nothing in it yet and nothing on its way: the New Canvas form, which an opened project can take over.
    var isEmpty: Bool { document == nil && session.document == nil && openingURL == nil }
    /// The project the tab holds or is opening.
    var url: URL? { session.projectURL ?? openingURL }

    /// Opens the project at `url` in this tab. The tab is taken from the call on, while the package is read, so
    /// projects opened together (as a window's are when it comes back) each get a tab of their own.
    func open(_ url: URL) -> Task<Void, any Error> {
        openingURL = url
        return Task {
            defer { openingURL = nil }
            let opening = Timing.begin("Open project")
            let document = CompositorDocument(fileURL: url, session: session)
            try await document.openDocument()
            self.document = document
            Timing.end(opening, session.document.map { "\($0.width)×\($0.height), \(Timing.counted($0.layers.count, "layer"))" } ?? "")
            // The tab in front shows it on the canvas's next frame; a tab behind, once it's brought forward.
            if canvas.window != nil {
                let drawing = Timing.begin("First frame")
                canvas.afterNextFrame { Timing.end(drawing) }
            }
        }
    }

    /// Gives what the editor holds (a new canvas, or images brought into an empty tab) a file of its own. The file is
    /// where the project starts from then, as an opened project's is: undo doesn't go back past it to no canvas at all.
    func createDocument(named name: String) async throws {
        guard document == nil, session.document != nil else { return }
        session.history.reset()
        document = try await CompositorDocument.create(at: CompositorDocument.unusedURL(named: name), with: session)
    }

    /// Saves and closes the file; the tab is done with.
    func close() async {
        await document?.closeDocument()
        document = nil
    }
}

/// UndoManager's face on the editor's own history, for the parts of UIKit that undo through the responder chain.
final class SessionUndoManager: UndoManager {
    private let session: EditorSession

    init(session: EditorSession) {
        self.session = session
        super.init()
    }

    override var canUndo: Bool { session.canUndo }
    override var canRedo: Bool { session.canRedo }
    override var undoActionName: String { session.history.undoName }
    override var redoActionName: String { session.history.redoName }
    override func undo() { session.undo() }
    override func redo() { session.redo() }
}
