import CoreGraphics
import Foundation
import ImageIO
import Testing
import UIKit
@testable import Compositor

/// Opening a project in a tab on iPad.
@MainActor struct PadOpeningTests {
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

    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory.appending(path: "PadOpeningTests \(UUID().uuidString) \(name)")
    }

    /// A project of two layers, saved where a tab can open it.
    private func savedProject() throws -> URL {
        let session = EditorSession()
        session.createDocument(width: 300, height: 200)
        for seed in 0..<2 {
            let image = try pattern(300 - seed * 50, 200 - seed * 25, seed: seed)
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Layer"))
        }
        let url = temporaryURL("Project.comp")
        try ProjectStore.package(for: try #require(session.projectSnapshot())).write(to: url, options: [], originalContentsURL: nil)
        return url
    }

    /// A PNG to bring in.
    private func savedImage() throws -> URL {
        let url = temporaryURL("Image.png")
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try pattern(120, 80, seed: 3), nil)
        #expect(CGImageDestinationFinalize(destination))
        return url
    }

    /// Images brought into a tab while a project opens in it wait for the project and land in it, as on the Mac.
    @Test func anImageBroughtInWhileAProjectOpensLandsInIt() async throws {
        let url = try savedProject(), image = try savedImage()
        defer { for file in [url, image] { try? FileManager.default.removeItem(at: file) } }
        let tab = EditorTab()
        let opening = tab.open(url)
        await tab.session.importImages([image])
        _ = try await opening.value
        #expect(tab.session.document?.layers.count == 3)
        #expect(tab.session.projectURL == url && tab.document?.fileURL == url)
        await tab.close()
    }

    /// The tab's editor is busy from the moment a project starts opening until it's in, as the Mac's is.
    @Test func openingKeepsTheProjectBusyUntilItIsIn() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = EditorTab()
        let opening = tab.open(url)
        #expect(tab.session.isProjectBusy && !tab.session.canStartProjectOperation)
        _ = try await opening.value
        #expect(!tab.session.isProjectBusy && tab.session.document != nil)
        await tab.close()
    }

    /// Closing a tab while its project opens stops the open and lets go of the file, with no error to show.
    @Test func closingATabWhileItOpensClosesItsFile() async throws {
        let url = try savedProject()
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = EditorTab()
        let opening = tab.open(url)
        await tab.close()
        await #expect(throws: CancellationError.self) { try await opening.value }
        #expect(tab.session.document == nil && tab.document == nil && !tab.session.isProjectBusy)
        #expect(!NSFileCoordinator.filePresenters.contains { $0.presentedItemURL?.standardizedFileURL == url.standardizedFileURL })
    }

    /// Waits up to a few seconds for `condition`, as the window's own tasks finish.
    private func eventually(_ condition: () -> Bool) async throws {
        for _ in 0..<250 where !condition() { try await Task.sleep(for: .milliseconds(20)) }
    }

    /// Images opened with a project that turns out not to open land in the tab it was given, which stays.
    @Test func imagesBroughtInWhileAProjectFailsToOpenKeepTheirTab() async throws {
        let broken = temporaryURL("Broken.comp"), image = try savedImage()
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        defer { for file in [broken, image] { try? FileManager.default.removeItem(at: file) } }
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        // A canvas in front, so the project gets a tab of its own.
        try #require(window.activeTab).session.createNewProject(width: 64, height: 48)
        window.open([broken, image])
        #expect(window.tabs.count == 2)
        let tab = try #require(window.tabs.last)
        try await eventually { tab.document != nil }
        #expect(window.tabs.contains { $0 === tab })
        #expect(tab.session.document?.layers.count == 1)
        let file = tab.document?.fileURL
        for tab in window.tabs { await tab.close() }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// A photo from Photos, handed over a second after it's asked for, as one downloaded from iCloud is.
    private func slowPhoto() throws -> NSItemProvider {
        let data = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(data, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, try pattern(80, 60, seed: 4), nil)
        #expect(CGImageDestinationFinalize(destination))
        let png = data as Data
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: "public.png", visibility: .all) { completion in
            DispatchQueue.global().asyncAfter(deadline: .now() + 1) { completion(png, nil) }
            return nil
        }
        provider.suggestedName = "PadOpeningTests \(UUID().uuidString)"
        return provider
    }

    /// Photos picked into a tab whose project then fails to open land in it, even when the open fails while they're
    /// still being handed over.
    @Test func photosPickedWhileAProjectFailsToOpenKeepTheirTab() async throws {
        let broken = temporaryURL("Broken.comp")
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: broken) }
        let window = EditorWindowController()
        window.loadViewIfNeeded()
        try #require(window.activeTab).session.createNewProject(width: 64, height: 48)
        window.open([broken])
        let tab = try #require(window.tabs.last)
        await window.receive([try slowPhoto()])
        try await eventually { tab.document != nil }
        #expect(window.tabs.contains { $0 === tab })
        #expect(tab.session.document?.layers.count == 1)
        let file = tab.document?.fileURL
        for tab in window.tabs { await tab.close() }
        if let file { try? FileManager.default.removeItem(at: file) }
    }

    /// A tab closed while the file for what was brought into it is being written closes that file again.
    @Test func aTabClosedWhileItsNewFileIsWrittenClosesIt() async throws {
        let tab = EditorTab()
        tab.session.createNewProject(width: 64, height: 48)
        let creating = Task { try await tab.createDocument(named: "PadOpeningTests \(UUID().uuidString)") }
        // The file is being written once this goes on.
        await Task.yield()
        await tab.close()
        try await creating.value
        #expect(tab.document == nil)
        let written = CompositorDocument.projectsFolder
        let files = try FileManager.default.contentsOfDirectory(at: written, includingPropertiesForKeys: nil)
        #expect(!NSFileCoordinator.filePresenters.contains { presenter in files.contains { $0.standardizedFileURL == presenter.presentedItemURL?.standardizedFileURL && $0.lastPathComponent.hasPrefix("PadOpeningTests") } })
        for file in files where file.lastPathComponent.hasPrefix("PadOpeningTests") { try? FileManager.default.removeItem(at: file) }
    }

    /// Images waiting on a tab closed while its project opens get no file of their own.
    @Test func imagesWaitingOnATabClosedWhileItOpensGetNoFile() async throws {
        let url = try savedProject(), image = try savedImage()
        defer { for file in [url, image] { try? FileManager.default.removeItem(at: file) } }
        let tab = EditorTab()
        let opening = tab.open(url)
        let importing = Task {
            await tab.session.importImages([image])
            try await tab.createDocument(named: "PadOpeningTests \(UUID().uuidString)")
        }
        await tab.close()
        _ = await opening.result
        try await importing.value
        #expect(tab.document == nil)
        if let file = tab.document?.fileURL {
            await tab.document?.closeDocument()
            try? FileManager.default.removeItem(at: file)
        }
    }

    /// A project that can't be opened doesn't leave the tab busy.
    @Test func aFailedOpenIsNotLeftBusy() async throws {
        let url = temporaryURL("Empty.comp")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: url) }
        let tab = EditorTab()
        let opening = tab.open(url)
        await #expect(throws: (any Error).self) { try await opening.value }
        #expect(!tab.session.isProjectBusy && tab.session.document == nil)
    }
}
