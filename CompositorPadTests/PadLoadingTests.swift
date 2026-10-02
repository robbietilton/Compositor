import CoreGraphics
import Foundation
import Testing
import UIKit
@testable import Compositor

/// The Loading card a tab shows while its project opens on iPad.
@MainActor struct PadLoadingTests {
    private typealias Line = LoadingProgress.Line

    private func pattern(_ width: Int, _ height: Int, seed: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        let data = context.data!.assumingMemoryBound(to: UInt8.self)
        for y in 0..<height { for x in 0..<width {
            let i = y * context.bytesPerRow + x * 4
            data[i] = UInt8(x * 255 / width); data[i + 1] = UInt8(y * 255 / height)
            data[i + 2] = UInt8((x / 16 + y / 16 + seed) % 2 == 0 ? 200 : 60); data[i + 3] = 255
        } }
        return context.makeImage()!
    }

    /// A project of two layers, or `layers`, saved where a tab can open it, or over the one at `url`.
    private func savedProject(layers: Int = 2, at url: URL? = nil) throws -> URL {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        for seed in 0..<layers {
            let image = try pattern(300 - seed * 50, 200 - seed * 25, seed: seed)
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        }
        let url = url ?? FileManager.default.temporaryDirectory.appending(path: "PadLoadingTests \(UUID().uuidString) Project.comp")
        try? FileManager.default.removeItem(at: url)
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// Waits up to a few seconds for `condition`, as the open's and the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// A window on the app's screen, which a canvas draws in.
    private func window() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.lazy.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 1024, height: 768)
        return window
    }

    private func running(_ text: String) -> Line { Line(text: text, isDone: false) }
    private func done(_ text: String) -> Line { Line(text: text, isDone: true) }

    // MARK: What the lines say

    /// Each step has a line once it's reached: the one under way counts as it goes, the ones done say what they did, and
    /// counts said late or out of order don't move a line back.
    @Test func theCardSaysWhatEachStepHasDone() {
        var counts = LoadingProgress.Counts()
        func lines(made: Int? = nil, drawing: Bool = false) -> [Line] { LoadingProgress.lines(counts, made: made, drawing: drawing) }
        #expect(lines() == [running("Waiting to read the file…")])
        counts.record(.manifest(width: 300, height: 200, layers: 8, files: 10))
        counts.record(.layers(done: 3))
        #expect(lines() == [running("Loading 3/8 layers…")])
        counts.record(.layers(done: 8))
        counts.record(.thumbnails(done: 4))
        counts.record(.layers(done: 5))
        counts.record(.thumbnails(done: 2))
        #expect(lines() == [done("8/8 layers loaded."), running("Making 4/10 thumbnails…")])
        counts.record(.thumbnails(done: 10))
        counts.record(.waiting)
        #expect(lines() == [done("8/8 layers loaded."), done("10/10 thumbnails made."), running("Waiting for another project to open…")])
        counts.record(.making(total: 8))
        counts.record(.made(done: 3))
        #expect(lines().last == running("Decompressing 3/8 images for the canvas…"))
        counts.record(.made(done: 8))
        // One of them couldn't be made.
        #expect(lines(made: 7).last == done("7/8 images decompressed for the canvas."))
        #expect(lines(made: 7, drawing: true) == [done("8/8 layers loaded."), done("10/10 thumbnails made."),
                                                  done("7/8 images decompressed for the canvas."), running("Drawing the canvas…")])
        // A second manifest, as a read of a changed package says, changes nothing.
        counts.record(.manifest(width: 10, height: 10, layers: 1, files: 1))
        #expect(counts.layers == 8 && counts.files == 10 && counts.width == 300)
    }

    /// One of a kind is said without a count, which would sit at 0/1 until it's done.
    @Test func oneOfAKindIsSaidWithoutACount() {
        var counts = LoadingProgress.Counts()
        func lines(made: Int? = nil) -> [Line] { LoadingProgress.lines(counts, made: made, drawing: false) }
        counts.record(.manifest(width: 300, height: 200, layers: 1, files: 1))
        #expect(lines() == [running("Loading the layer…")])
        counts.record(.layers(done: 1))
        #expect(lines() == [done("1/1 layer loaded."), running("Making the thumbnail…")])
        counts.record(.thumbnails(done: 1))
        counts.record(.making(total: 1))
        #expect(lines() == [done("1/1 layer loaded."), done("1/1 thumbnail made."), running("Decompressing the image for the canvas…")])
        #expect(lines(made: 1).last == done("1/1 image decompressed for the canvas."))
    }

    /// Large counts are grouped as the locale groups them.
    @Test func largeCountsAreGrouped() {
        var counts = LoadingProgress.Counts()
        counts.record(.manifest(width: 300, height: 200, layers: 10_000, files: 10_000))
        counts.record(.layers(done: 1204))
        let expected = "Loading \(1204.formatted())/\(10_000.formatted()) layers…"
        #expect(expected.contains("1") && LoadingProgress.lines(counts, made: nil, drawing: false) == [running(expected)])
    }

    /// A step with nothing to do has no line: no files means no thumbnails, no layers no layers line, and a wait that
    /// turned out to have nothing to make goes.
    @Test func stepsWithNothingToDoHaveNoLine() {
        var counts = LoadingProgress.Counts()
        counts.record(.manifest(width: 300, height: 200, layers: 2, files: 0))
        counts.record(.layers(done: 2))
        #expect(LoadingProgress.lines(counts, made: nil, drawing: false) == [done("2/2 layers loaded.")])
        #expect(LoadingProgress.lines(counts, made: nil, drawing: true) == [done("2/2 layers loaded."), running("Drawing the canvas…")])
        var empty = LoadingProgress.Counts()
        empty.record(.manifest(width: 300, height: 200, layers: 0, files: 0))
        #expect(LoadingProgress.lines(empty, made: nil, drawing: false) == [])
        empty.record(.waiting)
        #expect(LoadingProgress.lines(empty, made: nil, drawing: false) == [running("Waiting for another project to open…")])
        #expect(LoadingProgress.lines(empty, made: 0, drawing: false) == [])
    }

    // MARK: How it goes

    /// The card names the project, says its size once the manifest is read, ends once, and hears nothing afterwards.
    @Test func theCardEndsOnceAndHearsNothingAfterwards() {
        let progress = LoadingProgress(name: "Photos")
        #expect(progress.title == "Loading “Photos”…" && progress.caption == nil && progress.isShowing)
        progress.read(.manifest(width: 3840, height: 2160, layers: 8, files: 8))
        progress.drawing()
        #expect(progress.caption == "3840 × 2160 px · 8 layers")
        progress.shown()
        progress.stopped()
        #expect(!progress.isShowing && progress.ending == .shown)
        progress.read(.layers(done: 8))
        progress.prepared(8)
        #expect(progress.counts.layersDone == 0 && progress.made == nil)
    }

    /// Counts said from many threads at once all reach the card, the last of them included.
    @Test func countsFromManyThreadsAllReachTheCard() async throws {
        let progress = LoadingProgress(name: "Photos")
        progress.read(.manifest(width: 300, height: 200, layers: 0, files: 0))
        progress.preparing(.making(total: 20_000))
        await Task.detached {
            DispatchQueue.concurrentPerform(iterations: 4) { lane in
                for done in stride(from: lane + 1, through: 20_000, by: 4) { progress.preparing(.made(done: done)) }
            }
        }.value
        let all = "Decompressing \(20_000.formatted())/\(20_000.formatted()) images for the canvas…"
        try await eventually { progress.lines.last?.text == all }
        #expect(progress.lines.last == running(all))
    }

    /// A tab in front says each step of its open, then the card goes with the project's first frame.
    @Test func aTabInFrontSaysEachStepAndEndsWithItsFirstFrame() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let window = try window()
        let tab = EditorTab()
        tab.canvas.frame = window.bounds
        window.addSubview(tab.canvas)
        let opening = tab.open(url)
        let loading = try #require(tab.loading)
        #expect(loading.name == tab.title && loading.isShowing && loading.lines == [running("Waiting to read the file…")])
        _ = try await opening.value
        #expect(loading.caption == "300 × 200 px · 2 layers")
        #expect(loading.lines == [done("2/2 layers loaded."), done("2/2 thumbnails made."),
                                  done("2/2 images decompressed for the canvas."), running("Drawing the canvas…")])
        // The display link may have drawn it already.
        if loading.isShowing { tab.canvas.render() }
        #expect(loading.ending == .shown)
        tab.canvas.removeFromSuperview()
        await tab.close()
        withExtendedLifetime(window) {}
    }

    /// A tab behind makes no textures as it opens, and keeps its card until it's brought forward and draws.
    @Test func aTabBehindKeepsItsCardUntilItsFirstFrame() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = EditorTab()
        _ = try await tab.open(url).value
        let loading = try #require(tab.loading)
        #expect(loading.lines == [done("2/2 layers loaded."), done("2/2 thumbnails made."), running("Drawing the canvas…")])
        #expect(loading.isShowing)
        let window = try window()
        tab.canvas.frame = window.bounds
        window.addSubview(tab.canvas)
        tab.canvas.layoutIfNeeded()
        if loading.isShowing { tab.canvas.render() }
        #expect(loading.ending == .shown)
        tab.canvas.removeFromSuperview()
        await tab.close()
        withExtendedLifetime(window) {}
    }

    /// A project that can't be opened ends its card, and so does closing the tab while it opens.
    @Test func aFailedOrStoppedOpenEndsItsCard() async throws {
        let broken = FileManager.default.temporaryDirectory.appending(path: "PadLoadingTests \(UUID().uuidString) Broken.comp")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        let url = try savedProject()
        defer { for file in [broken, url] { try? FileManager.default.removeItem(at: file) } }
        let failing = EditorTab()
        _ = await failing.open(broken).result
        #expect(failing.loading?.ending == .stopped)
        let closed = EditorTab()
        let opening = closed.open(url)
        await closed.close()
        _ = await opening.result
        #expect(closed.loading?.ending == .stopped)
    }

    /// Only the open's own read is reported: one after it, as another app changing the package brings, says nothing.
    @Test func aReadAfterTheOpenReportsNothing() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let said = Said<ProjectStore.ReadProgress>()
        let document = CompositorDocument(fileURL: url, session: EditorSession(), reading: said.add)
        try await document.openDocument { _ in
            _ = try? savedProject(layers: 3, at: url)
            #expect(await document.revert(toContentsOf: url))
            return nil
        }
        #expect(document.session.document?.layers.count == 3)
        #expect(said.events.first == .manifest(width: 300, height: 200, layers: 2, files: 2) && said.events.count == 5)
        await document.closeDocument()
    }

    /// The window shows the Loading card of the tab in front, in place of New canvas, and swaps it as tabs are
    /// switched; it goes with the project's first frame, or when the project can't be opened.
    @Test func theWindowShowsTheLoadingCardOfTheTabInFront() async throws {
        let url = try savedProject()
        let broken = FileManager.default.temporaryDirectory.appending(path: "PadLoadingTests \(UUID().uuidString) Broken.comp")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        defer { for file in [url, broken] { try? FileManager.default.removeItem(at: file) } }
        let window = try window()
        let controller = EditorWindowController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.view.layoutIfNeeded()
        let card = try #require(controller.view.subviews.lazy.compactMap { $0 as? LoadingView }.first)
        let newCanvas = try #require(controller.view.subviews.lazy.compactMap { $0 as? NewCanvasView }.first)
        func update() {
            controller.updatePropertiesIfNeeded()
            card.updatePropertiesIfNeeded()
        }

        controller.open([url])
        let opening = try #require(controller.activeTab)
        update()
        #expect(!card.isHidden && newCanvas.isHidden && card.progress?.title == "Loading “\(opening.title)”…")
        // The canvas's handles and outlines wait for its picture.
        #expect(opening.canvas.overlayView.isHidden)
        // To VoiceOver, the title is a heading, and the line under way changes often.
        let shownLabels = labels(in: card).filter(shows)
        #expect(shownLabels.first { $0.text == card.progress?.title }?.accessibilityTraits.contains(.header) == true)
        #expect(shownLabels.first { $0.text == "Waiting to read the file…" }?.accessibilityTraits.contains(.updatesFrequently) == true)
        #expect(card.subviews.first?.accessibilityElements?.count == shownLabels.count)
        controller.newCanvasTab(nil)
        update()
        #expect(card.isHidden && !newCanvas.isHidden)
        controller.select(opening.id)
        update()
        #expect(!card.isHidden && newCanvas.isHidden)
        try await eventually { opening.loading?.isDrawing == true || opening.loading?.isShowing == false }
        // The project is in, its first frame on its way: the handles and outlines wait for the picture, as the card does.
        if opening.loading?.isShowing == true {
            update()
            #expect(!card.isHidden && opening.canvas.overlayView.isHidden)
            opening.canvas.render()
        }
        update()
        #expect(card.isHidden && opening.loading?.ending == .shown && !opening.canvas.overlayView.isHidden)

        // A project that can't be opened, in a tab of its own: its card goes, and so does the tab.
        controller.open([broken])
        let failing = try #require(controller.activeTab)
        update()
        #expect(!card.isHidden)
        try await eventually { failing.loading?.isShowing == false }
        update()
        #expect(card.isHidden && failing.loading?.ending == .stopped)
        for tab in controller.tabs { await tab.close() }
        withExtendedLifetime(window) {}
    }

    /// Whether `view` shows: neither it nor anything it's in is hidden.
    private func shows(_ view: UIView) -> Bool {
        var current: UIView? = view
        while let shown = current {
            if shown.isHidden { return false }
            current = shown.superview
        }
        return true
    }

    private func labels(in view: UIView) -> [UILabel] {
        view.subviews.flatMap { ($0 as? UILabel).map { [$0] } ?? [] + labels(in: $0) }
    }

    /// A tab whose project is opening isn't called empty: the status bar doesn't say it's ready for a canvas, nor the
    /// Layers panel that there are none and to make one.
    @Test func anOpeningTabDoesntCallItselfEmpty() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let window = try window()
        let controller = EditorWindowController()
        window.rootViewController = controller
        controller.loadViewIfNeeded()
        controller.view.frame = window.bounds
        controller.open([url])
        controller.updatePropertiesIfNeeded()
        for view in controller.view.subviews where view is StatusBarView || view is LayersPanelView { view.updatePropertiesIfNeeded() }
        let shown = labels(in: controller.view).filter(shows).compactMap(\.text)
        #expect(!shown.contains("Ready when you are"))
        #expect(!shown.contains("No layers yet") && !shown.contains("Create a canvas or import an image."))
        for tab in controller.tabs { await tab.close() }
        withExtendedLifetime(window) {}
    }

    /// An open that fails says so in the turn its tab stops opening, the card ended and the tab empty; one stopped by
    /// closing the tab says nothing.
    @Test func aFailedOpenIsSaidAsTheTabStopsOpening() async throws {
        let broken = FileManager.default.temporaryDirectory.appending(path: "PadLoadingTests \(UUID().uuidString) Broken.comp")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        let url = try savedProject()
        defer { for file in [broken, url] { try? FileManager.default.removeItem(at: file) } }
        let failing = EditorTab()
        var seen: (empty: Bool, ending: LoadingProgress.Ending?)?
        _ = await failing.open(broken) { _ in seen = (failing.isEmpty, failing.loading?.ending) }.result
        #expect(seen?.empty == true && seen?.ending == .stopped)
        let closed = EditorTab()
        var told = false
        let opening = closed.open(url) { _ in told = true }
        await closed.close()
        _ = await opening.result
        #expect(!told)
    }
}
