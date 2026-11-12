import AppKit
import Testing
@testable import Compositor

/// A document begun from an image file goes back out the way it came: Export and Save start with its name and folder,
/// and Export with its format.
@MainActor struct ImageSourceTests {
    @Test func exportStartsWithTheImagesNameAndFormat() {
        let png = URL(fileURLWithPath: "/Users/someone/Pictures/Sky Edit.png")
        #expect(ProjectController.startingFormat(source: png, projectURL: nil) == .png)
        #expect(ProjectController.startingFormat(source: URL(fileURLWithPath: "/a/photo.JPG"), projectURL: nil) == .jpeg)
        #expect(ProjectController.exportName(projectURL: nil, source: png, format: .png) == "Sky Edit.png")
        #expect(ProjectController.exportName(projectURL: nil, source: png, format: .jpeg) == "Sky Edit.jpeg")
        // Once saved as a project, its name leads.
        let project = URL(fileURLWithPath: "/Users/someone/Projects/Poster.comp")
        #expect(ProjectController.exportName(projectURL: project, source: png, format: .png) == "Poster.png")
        #expect(ProjectController.exportName(projectURL: nil, source: nil, format: .png) == "Untitled.png")
    }

    @Test func openingAnImageIntoAnEmptyWindowRemembersIt() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("Icon.png")
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])).write(to: url)

        let session = EditorSession()
        await session.importImages([url])
        #expect(session.document != nil)
        #expect(session.sourceImageURL == url)
        // A second image goes into the document as a layer; the document still came from the first.
        await session.importImages([url])
        #expect(session.sourceImageURL == url)
        session.clearProject()
        #expect(session.sourceImageURL == nil)
    }
}
