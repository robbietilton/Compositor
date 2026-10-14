import SwiftUI
import UniformTypeIdentifiers

/// Resolve in pasteboard order; the importer validates contents rather than trusting extensions.
@MainActor
enum ImageFileDrop {
    static func importProviders(_ providers: [NSItemProvider], into session: EditorSession, at point: CGPoint?, projects: ProjectController? = nil, workspace: ProjectWorkspace? = nil, destination: UUID? = nil) async {
        let (urls, unreadable) = await ItemProviderFiles.urls(from: providers)
        if let workspace { await workspace.receive(urls, into: destination, at: point) }
        else if let projects { await projects.receive(urls, at: point) }
        else { await session.importImages(urls, at: point) }
        if unreadable, !providers.isEmpty {
            let message = "Some dropped items couldn’t be read. Drag JPEG, PNG, HEIC, HEIF, TIFF, WebP, or Photoshop (PSD) files from Finder."
            session.importError = [session.importError, message].compactMap { $0 }.joined(separator: "\n\n")
        }
    }
}
