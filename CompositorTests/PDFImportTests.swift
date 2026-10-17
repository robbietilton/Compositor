import AppKit
import CoreGraphics
import PDFKit
import UniformTypeIdentifiers
import Testing
@testable import Compositor

@MainActor struct PDFImportTests {
    // The first page has red at its top, blue at its bottom and an unpainted right half.
    func fixture(rotation: Int = 0, crop: CGRect? = nil) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        var box = CGRect(x: 0, y: 0, width: 72, height: 144)
        let context = try #require(CGContext(url as CFURL, mediaBox: &box, nil))
        for _ in 0..<3 {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
            context.fill(CGRect(x: 0, y: 72, width: 36, height: 72))
            context.setFillColor(CGColor(red: 0, green: 0, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: 36, height: 72))
            context.endPDFPage()
        }
        context.closePDF()
        if rotation != 0 || crop != nil {
            let document = try #require(PDFDocument(url: url))
            let page = try #require(document.page(at: 0))
            page.rotation = rotation
            if let crop { page.setBounds(crop, for: .cropBox) }
            #expect(document.write(to: url))
        }
        return url
    }

    @Test func rangesAreValidatedDeduplicatedAndInDocumentOrder() throws {
        #expect(try PDFPageSelection.parse("3, 1–2, 2", count: 3) == [1, 2, 3])
        #expect(try PDFPageSelection.parse("", count: 3) == [1, 2, 3])
        for value in ["0", "4", "2-1", "1,,2", "a", "1-999999999", "-1"] {
            #expect(throws: PDFImportError.invalidPages) { try PDFPageSelection.parse(value, count: 3) }
        }
    }

    @Test func dpiDeterminesRasterSizeAndBudgetIsCheckedBeforeRendering() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = try await PDFImporter.shared.plan(url, options: .init(pages: "1,3", dpi: 150))
        #expect(plan.pages.map(\.number) == [1, 3])
        #expect(plan.pages.map(\.width) == [150, 150])
        #expect(plan.pages.map(\.height) == [300, 300])
        #expect(plan.totalPixels == 90_000)
        await #expect(throws: PDFImportError.tooLarge) {
            try await PDFImporter.shared.plan(url, options: .init(pages: "1,3", dpi: 150), pixelBudget: 89_999)
        }
        for dpi in [0.0, -1, .nan, .infinity, 2401] {
            await #expect(throws: PDFImportError.invalidResolution) {
                try await PDFImporter.shared.plan(url, options: .init(pages: "1", dpi: dpi))
            }
        }
    }

    @Test func renderKeepsTopBottomOrientationAndWhitePaper() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let asset = try await PDFImporter.shared.render(url, page: 1, dpi: 72)
        #expect(asset.image.width == 72 && asset.image.height == 144)
        let bytes = try #require(asset.image.dataProvider?.data) as Data
        let stride = asset.image.bytesPerRow
        #expect(bytes[10 * stride + 10 * 4] > 240) // top: red
        #expect(bytes[130 * stride + 10 * 4 + 2] > 240) // bottom: blue
        #expect(Array(bytes[(10 * stride + 60 * 4)..<(10 * stride + 60 * 4 + 4)]) == [255, 255, 255, 255])
    }

    @Test func cropBoxAndRotationDeterminePageDimensions() async throws {
        let url = try fixture(rotation: 90, crop: CGRect(x: 10, y: 20, width: 40, height: 80))
        defer { try? FileManager.default.removeItem(at: url) }
        let plan = try await PDFImporter.shared.plan(url, options: .init(pages: "1", dpi: 144))
        #expect(plan.pages[0].width == 160 && plan.pages[0].height == 80)
        let asset = try await PDFImporter.shared.render(url, page: 1, dpi: 144)
        #expect(asset.image.width == 160 && asset.image.height == 80)
    }

    @Test func pagesBecomeSeparateEditableTabsAndInvalidImportPreservesThem() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        workspace.current.session.createDocument(width: 10, height: 20)
        let original = workspace.current
        try await workspace.importPDF(url, options: .init(pages: "1,3", dpi: 150))
        #expect(workspace.tabs.count == 3)
        #expect(workspace.tabs[0] === original)
        #expect(original.session.document?.width == 10)
        #expect(workspace.tabs[1].title.hasSuffix("— Page 1"))
        #expect(workspace.tabs[2].title.hasSuffix("— Page 3"))
        let session = workspace.current.session
        #expect(session.document?.resolution == 150)
        #expect(session.document?.layers.count == 1)
        #expect(session.projectURL == nil)
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".comp")
        defer { try? FileManager.default.removeItem(at: saved) }
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: saved)
        let reopened = try await ProjectStore.shared.load(from: saved)
        #expect(reopened.manifest.width == 150 && reopened.manifest.height == 300)
        #expect(reopened.manifest.resolution == 150)
        #expect(reopened.images.count == 1)
        session.addBlankLayer()
        #expect(session.document?.layers.count == 2)
        session.undo()
        #expect(session.document?.layers.count == 1)
        await #expect(throws: PDFImportError.invalidPages) {
            try await workspace.importPDF(url, options: .init(pages: "4", dpi: 150))
        }
        #expect(workspace.tabs.count == 3)
        #expect(workspace.canSwitch)
    }

    @Test func damagedAndLockedPDFsFailWithoutCreatingTabs() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        try Data("not a PDF".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace()
        await #expect(throws: PDFImportError.unreadable) {
            try await workspace.importPDF(url, options: .init(pages: "", dpi: 72))
        }
        #expect(workspace.tabs.count == 1 && workspace.current.session.document == nil)
        let source = try fixture()
        defer { try? FileManager.default.removeItem(at: source) }
        let document = try #require(PDFDocument(url: source))
        #expect(document.write(to: url, withOptions: [.userPasswordOption: "fixture", .ownerPasswordOption: "owner"]))
        await #expect(throws: PDFImportError.locked) {
            try await PDFImporter.shared.plan(url, options: .init(pages: "", dpi: 72))
        }
    }

    @Test func oversizedPagesAreRejectedWithoutAllocation() throws {
        let oversized = [PDFPageInfo(number: 1, size: CGSize(width: 100_000, height: 100_000))]
        #expect(throws: PDFImportError.tooLarge) {
            try PDFImportPlan.make(oversized, options: .init(pages: "1", dpi: 300))
        }
    }

    @Test func mixedPDFThenImagesPreservesTheImageDestination() async throws {
        let pdf = try fixture()
        let png = try ImageImportTests().fixture(.png)
        defer {
            try? FileManager.default.removeItem(at: pdf)
            try? FileManager.default.removeItem(at: png)
        }
        let workspace = ProjectWorkspace(pdfOptions: { _, _, _ in .init(pages: "1", dpi: 72) })
        let destination = workspace.current.id
        let providers = [pdf, png, png].map { NSItemProvider(item: $0 as NSURL, typeIdentifier: UTType.fileURL.identifier) }
        await workspace.receiveProviders(providers, into: destination)
        #expect(workspace.tabs.count == 2)
        let images = try #require(workspace.tabs.first { $0.id == destination })
        #expect(images.session.document?.width == 64)
        #expect(images.session.document?.layers.count == 2)
        #expect(workspace.tabs.contains { $0.title.hasSuffix("— Page 1") })
    }

    @Test func cancelledRenderingDoesNotReturnAnImage() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await PDFImporter.shared.render(url, page: 1, dpi: 72)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    @Test func importUsesOneSnapshotEvenIfTheSourceIsOverwritten() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let original = try Data(contentsOf: url)
        let source = try await PDFImporter.shared.open(url)
        let plan = try await source.plan(options: .init(pages: "1,3", dpi: 72), pixelBudget: 20_736)
        #expect(plan.totalPixels == 20_736)
        // Overwrite the same inode, not just rename it, to exercise lazy file readers.
        try Data("replaced externally".utf8).write(to: url)
        for number in [1, 3] {
            let image = try await source.render(page: number, dpi: 72).image
            #expect(image.width == 72 && image.height == 144)
        }
        #expect(try Data(contentsOf: url) == Data("replaced externally".utf8))
        try original.write(to: url)
        let workspace = ProjectWorkspace()
        try await workspace.importPDF(url, options: .init(pages: "1", dpi: 72))
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func pdfOnlyDropProviderReachesTheImportDialog() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let data = try Data(contentsOf: url)
        let provider = NSItemProvider()
        provider.registerDataRepresentation(forTypeIdentifier: UTType.pdf.identifier, visibility: .all) { completion in
            completion(data, nil)
            return nil
        }
        #expect(ProjectWorkspace.dropTypes.contains { provider.hasItemConformingToTypeIdentifier($0) })
        let workspace = ProjectWorkspace(pdfOptions: { _, _, _ in .init(pages: "2", dpi: 72) })
        await workspace.receiveProviders([provider])
        #expect(workspace.tabs.count == 1)
        #expect(workspace.current.title.hasSuffix("— Page 2"))
        #expect(workspace.current.session.document?.width == 72)
        #expect(workspace.current.session.importError == nil)
    }

    @Test func cancelledImportLeavesExistingTabsUntouched() async throws {
        let url = try fixture()
        defer { try? FileManager.default.removeItem(at: url) }
        let workspace = ProjectWorkspace(pdfOptions: { _, _, _ in
            withUnsafeCurrentTask { $0?.cancel() }
            return .init(pages: "1", dpi: 72)
        })
        let original = workspace.current
        let task = Task { await workspace.receive([url]) }
        await task.value
        #expect(workspace.tabs.count == 1 && workspace.current === original)
        #expect(original.session.document == nil)
        #expect(workspace.canSwitch)
    }

    @Test func oversizedSourceIsRejectedBeforeReadingItsContents() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".pdf")
        #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
        defer { try? FileManager.default.removeItem(at: url) }
        let handle = try FileHandle(forWritingTo: url)
        // Sparse file: tests the real source limit without allocating 256 MiB of fixture data.
        try handle.truncate(atOffset: 256 * 1024 * 1024 + 1)
        try handle.close()
        await #expect(throws: PDFImportError.tooLarge) { try await PDFImporter.shared.open(url) }
    }

    @Test(arguments: [90, 180, 270])
    func rotatedPagePixelsStayInTheExpectedCorners(rotation: Int) async throws {
        let url = try fixture(rotation: rotation)
        defer { try? FileManager.default.removeItem(at: url) }
        let image = try await PDFImporter.shared.render(url, page: 1, dpi: 72).image
        let bytes = try #require(image.dataProvider?.data) as Data
        func color(_ x: Int, _ y: Int) -> [UInt8] {
            let offset = y * image.bytesPerRow + x * 4
            return Array(bytes[offset..<(offset + 3)])
        }
        let red: [UInt8]
        let blue: [UInt8]
        switch rotation {
        case 90: red = color(130, 10); blue = color(10, 10)
        case 180: red = color(60, 130); blue = color(60, 10)
        default: red = color(10, 60); blue = color(130, 60)
        }
        #expect(red[0] > 240 && red[2] < 20)
        #expect(blue[2] > 240 && blue[0] < 20)
    }
}
