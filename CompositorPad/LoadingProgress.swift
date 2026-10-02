import Foundation
import Observation
import Synchronization

/// A project opening in a tab, step by step as the open takes the steps, for the window's Loading card. Each open makes
/// one; it ends once the project's first frame is on screen, or when the open fails or stops.
@Observable final class LoadingProgress {
    enum Ending { case shown, stopped }

    /// A line of the card: a step under way, its count updating as it goes, or a step done.
    struct Line: Equatable {
        let text: String
        let isDone: Bool
    }

    /// What the reading and the texture lanes have said so far. Totals are taken once and counts only go up, so lanes
    /// saying theirs out of order can't move a line back.
    nonisolated struct Counts: Equatable, Sendable {
        var width = 0, height = 0
        /// The project's layers, once the manifest is read, and how many image and mask files they have.
        var layers: Int?
        var files = 0
        var layersDone = 0, thumbnailsDone = 0
        /// The textures waited for another window's to be made first.
        var waiting = false
        /// The textures about to be made, once the lanes are about to start.
        var textures: Int?
        var texturesTried = 0

        mutating func record(_ event: ProjectStore.ReadProgress) {
            switch event {
            case let .manifest(width, height, layers, files):
                guard self.layers == nil else { return }
                (self.width, self.height, self.layers, self.files) = (width, height, layers, files)
            case .layers(let done): layersDone = max(layersDone, done)
            case .thumbnails(let done): thumbnailsDone = max(thumbnailsDone, done)
            }
        }

        mutating func record(_ event: GPUCanvasRenderer.PrepareProgress) {
            switch event {
            case .waiting: waiting = true
            case .making(let total): if textures == nil { textures = total }
            case .made(let done): texturesTried = max(texturesTried, done)
            }
        }
    }

    /// The latest counts the threads have said, and whether a hop to the main queue is on its way to take them in: at
    /// most one is, however fast they say them.
    nonisolated final class Reports: Sendable {
        private let counts = Mutex(Counts())
        private let pending = Atomic(false)

        /// Records `change`; true when the caller should send a hop, none being on its way.
        func record(_ change: (inout Counts) -> Void) -> Bool {
            counts.withLock { change(&$0) }
            return !pending.exchange(true, ordering: .acquiringAndReleasing)
        }

        /// The latest counts. The flag is cleared first, so what's said after this sends a hop of its own and nothing is
        /// lost.
        func take() -> Counts {
            _ = pending.exchange(false, ordering: .acquiringAndReleasing)
            return counts.withLock { $0 }
        }
    }

    let name: String
    private(set) var counts = Counts()
    /// How many images the preparation made, once it's done.
    private(set) var made: Int?
    private(set) var isDrawing = false
    private(set) var ending: Ending?
    nonisolated private let reports = Reports()

    init(name: String) {
        self.name = name
    }

    var isShowing: Bool { ending == nil }
    var title: String { "Loading “\(name)”…" }
    /// The canvas's size and layers, once the manifest is read.
    var caption: String? {
        counts.layers.map { "\(counts.width) × \(counts.height) px · \($0.formatted()) \(Self.noun($0, "layer"))" }
    }
    var lines: [Line] { Self.lines(counts, made: made, drawing: isDrawing) }

    /// Said by `ProjectStore.readPackage`, on UIDocument's queue and the reading lanes.
    nonisolated func read(_ event: ProjectStore.ReadProgress) {
        if reports.record({ $0.record(event) }) { hop() }
    }

    /// Said by `GPUCanvasRenderer.prepare`, on the main actor and the texture lanes.
    nonisolated func preparing(_ event: GPUCanvasRenderer.PrepareProgress) {
        if reports.record({ $0.record(event) }) { hop() }
    }

    nonisolated private func hop() {
        DispatchQueue.main.async { [weak self] in MainActor.assumeIsolated { self?.takeReports() } }
    }

    private func takeReports() {
        let latest = reports.take()
        guard ending == nil, latest != counts else { return }
        counts = latest
    }

    /// The preparation is done, having made `count` images.
    func prepared(_ count: Int) {
        takeReports()
        guard ending == nil else { return }
        made = count
    }

    /// The project is in the editor, and its first frame is on its way.
    func drawing() {
        takeReports()
        guard ending == nil else { return }
        isDrawing = true
    }

    /// The project's first frame is on screen.
    func shown() {
        if ending == nil { ending = .shown }
    }

    /// The open failed or stopped.
    func stopped() {
        if ending == nil { ending = .stopped }
    }

    /// The card's lines for what's been said: a line for each step reached, the one under way counting, the ones done
    /// saying what they did.
    static func lines(_ counts: Counts, made: Int?, drawing: Bool) -> [Line] {
        guard let layers = counts.layers else { return [Line(text: "Waiting to read the file…", isDone: false)] }
        let making = counts.textures != nil || counts.waiting || made != nil || drawing
        let thumbnailing = counts.layersDone >= layers || counts.thumbnailsDone > 0 || making
        var lines: [Line] = []
        if layers > 0 {
            lines.append(thumbnailing ? done(layers, of: layers, "layer", "loaded")
                : running("Loading", counts.layersDone, of: layers, "layer", the: "Loading the layer…"))
        }
        if counts.files > 0, thumbnailing {
            lines.append(counts.thumbnailsDone >= counts.files || making ? done(counts.files, of: counts.files, "thumbnail", "made")
                : running("Making", counts.thumbnailsDone, of: counts.files, "thumbnail", the: "Making the thumbnail…"))
        }
        if let total = counts.textures, total > 0 {
            let tried = min(counts.texturesTried, total)
            lines.append(made != nil || drawing ? done(made ?? tried, of: total, "image", "decompressed for the canvas")
                : running("Decompressing", tried, of: total, "image", "for the canvas",
                          the: "Decompressing the image for the canvas…"))
        } else if counts.waiting, made == nil, !drawing {
            lines.append(Line(text: "Waiting for another project to open…", isDone: false))
        }
        if drawing { lines.append(Line(text: "Drawing the canvas…", isDone: false)) }
        return lines
    }

    /// "Loading 3/8 layers…"; for one, `the`, as "0/1" would sit there until it's done.
    private static func running(_ verb: String, _ done: Int, of total: Int, _ noun: String, _ rest: String? = nil,
                                the single: String) -> Line {
        guard total > 1 else { return Line(text: single, isDone: false) }
        let words = [verb, "\(min(done, total).formatted())/\(total.formatted())", Self.noun(total, noun), rest].compactMap { $0 }
        return Line(text: words.joined(separator: " ") + "…", isDone: false)
    }

    /// "8/8 layers loaded."
    private static func done(_ done: Int, of total: Int, _ noun: String, _ what: String) -> Line {
        Line(text: "\(done.formatted())/\(total.formatted()) \(Self.noun(total, noun)) \(what).", isDone: true)
    }

    private static func noun(_ count: Int, _ noun: String) -> String { count == 1 ? noun : noun + "s" }
}
