import CoreGraphics
import Foundation

nonisolated enum GenerativeMode: String, Sendable {
    case fill, remove, expand
    var title: String { self == .fill ? "Generative Fill" : self == .remove ? "Remove" : "Generative Expand" }
}

/// The words sent with the pictures. Kept in one place because they are what gets tuned against the live
/// models: they have no mask input, so where to work and what to leave alone can only be said.
nonisolated enum GenerativePrompt {
    /// - Parameters:
    ///   - target: what is to change, as a part of the picture sent: each edge from 0 to 1.
    static func make(_ mode: GenerativeMode, request: String, target: CGRect, hasHint: Bool, references: Int) -> String {
        let request = request.trimmingCharacters(in: .whitespacesAndNewlines)
        var lines: [String] = []
        switch mode {
        case .fill where request.isEmpty, .remove:
            lines.append("Using the first image, remove what is in the marked area and fill that area with what would naturally be behind it, continuing the surrounding background, textures, lighting and perspective so that no trace of it remains.")
        case .fill:
            lines.append("Using the first image, edit what is already inside the marked area according to this request: \(request)")
            // Seen with a box drawn round a face and the request "clown face": the model treated the box as a frame
            // and put a whole new portrait in it, background and shoulders included.
            lines.append("The marked area is a region of the photograph, not a frame: never place a separate picture, portrait, border or background of its own inside it. If the request changes something that is there, such as a person, a face, clothing or an object, keep that subject where it is, at the same size, pose and outline, and change only what the request asks. If the request adds something new, draw it at a natural scale for the scene and attached to its surroundings. What is inside the area must line up with what is outside it: bodies, objects and the background continue across its edge.")
            lines.append("Match the lighting, perspective, focus, grain and color of the surroundings so the change sits naturally in the scene.")
        case .expand:
            lines.append("The first image is a photograph placed on a larger canvas; the blank area around it has no content yet. Extend the photograph into the blank area, continuing its scene, lighting, perspective, focus and grain seamlessly.\(request.isEmpty ? "" : " In the new area: \(request)")")
        }
        lines.append("The marked area is \(place(target)) of the image.\(hasHint ? " The second image is a mask of the same scene: white marks the area to work in, black marks what must not change." : "")")
        if references > 0 {
            let first = hasHint ? 3 : 2
            let named = references == 1 ? "The image after that is a reference" : "Images \(first) to \(first + references - 1) are references"
            lines.append("\(named) for what to put there: take the subject or material from it, not its background or framing.")
        }
        lines.append("Keep everything outside the marked area exactly as it is: same framing, same position and size of every object, same colors. Return the whole image at the same framing, with no border, text or mask overlay.")
        return lines.joined(separator: "\n")
    }

    /// "the centre", "the upper left", "the left edge"…, with the span in percent for a model that can use it.
    static func place(_ target: CGRect) -> String {
        func percent(_ value: CGFloat) -> Int { Int((min(1, max(0, value)) * 100).rounded()) }
        let span = "from \(percent(target.minX))% to \(percent(target.maxX))% across and \(percent(target.minY))% to \(percent(target.maxY))% down"
        if target.width > 0.85, target.height > 0.85 { return "most (\(span))" }
        let column = target.midX < 0.38 ? "left" : target.midX > 0.62 ? "right" : ""
        let row = target.midY < 0.38 ? "upper" : target.midY > 0.62 ? "lower" : ""
        let name = row.isEmpty && column.isEmpty ? "the centre" : row.isEmpty ? "the \(column) side" : column.isEmpty ? "the \(row) part" : "the \(row) \(column)"
        return "in \(name) (\(span))"
    }
}
