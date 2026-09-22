import Foundation
import CoreGraphics

/// Uses the same layered PSD conversion as File > Import, with conversion notes returned to
/// the agent instead of opening a modal confirmation sheet.
@MainActor
enum PhotoshopAutomation {
    static func importData(url: URL, filename: String, point: CGPoint?, workspace: ProjectWorkspace) async throws -> String {
        let session = workspace.current.session
        let used = session.document?.layers.reduce(0) { $0 + ($1.asset.map { $0.image.width * $0.image.height } ?? 0) } ?? 0
        workspace.isManaging = true
        session.isProjectBusy = true
        defer { session.isProjectBusy = false; workspace.isManaging = false }
        let parsed = try await ImageImporter.shared.loadPhotoshop(url, remainingPixels: 100_000_000 - used)
        try Task.checkCancellation()
        let assets = try await ImageImporter.shared.photoshopAssets(parsed)
        try Task.checkCancellation()
        let imported = try PSDDocumentBuilder.makeImport(parsed, assets: assets)
        guard !imported.layers.isEmpty else { throw EditorAutomationError.unavailable("The Photoshop file has no supported layers.") }
        // Insertion is synchronous on the main actor and the workspace remains reserved.
        session.isProjectBusy = false
        try Task.checkCancellation()
        try session.insertPhotoshop(imported, named: URL(fileURLWithPath: filename).deletingPathExtension().lastPathComponent, centeredAt: point)
        let notes = imported.conversions.map { "\($0.layerName): \($0.message)" }
        return "Imported \(filename) with \(imported.layers.count) native layers."
            + (notes.isEmpty ? "" : " Conversion warnings: " + notes.joined(separator: " "))
    }
}
