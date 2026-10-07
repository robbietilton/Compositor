import Foundation
import Observation

/// An export making its file, step by step as the exporter takes the steps, for the window's Export card. Each export
/// makes one; it ends once what the export shows, its share sheet or its dialog, is up, or when the export fails or
/// stops.
@Observable final class ExportProgress: CardProgress {
    typealias Line = LoadingProgress.Line

    /// What the export makes, and what shows it once it's made.
    enum Kind: String {
        case png = "PNG", jpeg = "JPEG"

        /// What the export opens once its file is made: the share sheet, or the Export JPEG dialog.
        var opens: String { self == .png ? "the share sheet" : "the dialog" }
    }

    /// What the exporter has said so far, in the order it said it. Counts only go up, so a step said late can't move a
    /// line back.
    nonisolated struct Steps: Equatable, Sendable {
        /// The layers to compose, once composing begins.
        var layers: Int?
        var composed = 0
        var isEncoding = false

        mutating func record(_ event: ImageExporter.Progress) {
            switch event {
            case .composing(let total): if layers == nil { layers = total }
            case .composed(let done): composed = max(composed, done)
            case .encoding: isEncoding = true
            }
        }
    }

    let name: String
    let kind: Kind
    let width: Int, height: Int
    private(set) var steps = Steps()
    /// The file is made, and what shows it is on its way.
    private(set) var isOpening = false
    private(set) var isShowing = true

    init(name: String, kind: Kind, width: Int, height: Int) {
        self.name = name
        self.kind = kind
        self.width = width
        self.height = height
    }

    var title: String { "Exporting “\(name)” as \(kind.rawValue)…" }
    var caption: String? { "\(width) × \(height) px" }
    var lines: [Line] { Self.lines(steps, kind: kind, opening: isOpening) }
    var doneAnnouncement: String? { nil }

    /// Said by `ImageExporter`, on the exporter's thread, in order: each step reaches the card in the order it was said.
    nonisolated func said(_ event: ImageExporter.Progress) {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.record(event) } }
    }

    private func record(_ event: ImageExporter.Progress) {
        guard isShowing else { return }
        var next = steps
        next.record(event)
        if next != steps { steps = next }
    }

    /// The file is made, and what shows it is on its way.
    func opening() {
        if isShowing { isOpening = true }
    }

    /// What shows the file is up, or the export failed or stopped.
    func ended() {
        isShowing = false
    }

    /// The card's lines for what's been said: a line for each step reached, the one under way counting, the ones done
    /// saying what they did.
    static func lines(_ steps: Steps, kind: Kind, opening: Bool) -> [Line] {
        guard steps.layers != nil || opening else { return [Line(text: "Waiting to compose the image…", isDone: false)] }
        var lines: [Line] = []
        if let layers = steps.layers, layers > 0 {
            lines.append(steps.isEncoding || opening || steps.composed >= layers ? LoadingProgress.done(layers, of: layers, "layer", "composed")
                : LoadingProgress.running("Composing", steps.composed, of: layers, "layer", the: "Composing the layer…"))
        }
        if steps.isEncoding || opening {
            lines.append(Line(text: opening ? "\(kind.rawValue) encoded." : "Encoding \(kind.rawValue)…", isDone: opening))
        }
        if opening { lines.append(Line(text: "Opening \(kind.opens)…", isDone: false)) }
        return lines
    }
}
