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
    /// The open under way, which closing the tab stops.
    private var opening: Task<Int, any Error>?
    /// Images on their way in, waiting for the project to open or being read: the tab isn't empty while there are any.
    var incoming = 0
    /// Closed: nothing that lands in it afterwards gets a file.
    private(set) var isClosed = false
    /// The open under way or last made, step by step, for the window's Loading card.
    private(set) var loading: LoadingProgress?

    /// The file's name without its extension, or Untitled.
    var title: String { (session.projectURL ?? openingURL)?.deletingPathExtension().lastPathComponent ?? "Untitled" }
    /// Nothing in it yet and nothing on its way: the New Canvas form, which an opened project can take over.
    var isEmpty: Bool { document == nil && session.document == nil && openingURL == nil && incoming == 0 }
    /// The project the tab holds or is opening.
    var url: URL? { session.projectURL ?? openingURL }

    /// Opens the project at `url` in this tab. The tab is taken from the call on, while the package is read, so
    /// projects opened together (as a window's are when it comes back) each get a tab of their own. Its editor is busy
    /// until the project is in, as the Mac's is: images brought in meanwhile wait, and land in the project. The task's
    /// value is how many textures the canvas was handed as it opened. `failed` is told why it couldn't open, in the same
    /// turn of the main actor as the tab stops opening, so the window takes care of the tab before anything shows it
    /// empty; an open stopped by closing the tab isn't a failure.
    func open(_ url: URL, failed: @escaping (any Error) -> Void = { _ in }) -> Task<Int, any Error> {
        openingURL = url
        session.isProjectBusy = true
        let loading = LoadingProgress(name: title)
        self.loading = loading
        let opening = Task {
            var failure: (any Error)?
            defer {
                openingURL = nil
                session.isProjectBusy = false
                // Failed or stopped before the project went in.
                if !loading.isDrawing { loading.stopped() }
                if let failure, !(failure is CancellationError) { failed(failure) }
            }
            let opening = Timing.begin("Open project")
            let document = CompositorDocument(fileURL: url, session: session, reading: { loading.read($0) })
            let handed: Int
            do {
                handed = try await document.openDocument { snapshot in
                    // The tab in front shows the project on its next frame: the textures it draws from are made first,
                    // away from the main thread. A tab behind makes them as it's brought forward, as before, and so
                    // does one whose window isn't on screen, which draws no frame to take them.
                    guard isShown, let renderer = GPUCanvasRenderer.shared else { return nil }
                    let prepared = await renderer.prepare(CanvasDocument(project: snapshot).canvasSources,
                                                          progress: { loading.preparing($0) })
                    loading.prepared(prepared.count)
                    // Sent behind meanwhile: nothing is kept for it.
                    return isShown ? prepared : nil
                }
            } catch {
                failure = error
                throw error
            }
            self.document = document
            Timing.end(opening, session.document.map {
                "\($0.width)×\($0.height), \(Timing.counted($0.layers.count, "layer")), \(Timing.counted(handed, "texture")) ready"
            } ?? "")
            // The tab in front shows it on the canvas's next frame; a tab behind, once it's brought forward.
            if canvas.window != nil {
                let drawing = Timing.begin("First frame")
                canvas.afterNextFrame { Timing.end(drawing) }
            }
            // The card goes with the frame that shows the project; a tab behind keeps it until it's brought forward.
            if GPUCanvasRenderer.shared != nil {
                loading.drawing()
                canvas.whenNextFrameShows { loading.shown() }
            }
            return handed
        }
        self.opening = opening
        return opening
    }

    /// Gives what the editor holds (a new canvas, or images brought into an empty tab) a file of its own. The file is
    /// where the project starts from then, as an opened project's is: undo doesn't go back past it to no canvas at all.
    func createDocument(named name: String) async throws {
        guard !isClosed, document == nil, session.document != nil else { return }
        session.history.reset()
        let created = try await CompositorDocument.create(at: CompositorDocument.unusedURL(named: name), with: session)
        // Closed while the file was written: it's closed again.
        guard !isClosed else {
            await created.closeDocument()
            return
        }
        document = created
    }

    /// The tab's canvas is in a window on screen, where its next frame will draw.
    private var isShown: Bool {
        guard let scene = canvas.window?.windowScene else { return false }
        return scene.activationState == .foregroundActive || scene.activationState == .foregroundInactive
    }

    /// Saves and closes the file; the tab is done with. What's in progress is kept as the Mac's Quit keeps it: text
    /// being typed goes in as Done would put it, a stroke as lifting the finger would, edits on the canvas are applied
    /// and a transform kept, and an open editor is cancelled, so nothing goes in that wasn't OK'd. A project still
    /// opening stops, and its file is closed.
    func close() async {
        isClosed = true
        loading?.stopped()
        opening?.cancel()
        _ = await opening?.result
        // An edit already OK'd finishes first.
        await session.waitForProjectAccess()
        _ = session.finishText()
        session.finishBrushImmediately()
        await session.settlePendingEdits()
        session.commitTransform()
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
