import Foundation
import CoreGraphics
import Observation

/// Value snapshots share immutable CGImages; no pixel copies for layer edits.
@Observable
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let revision: UUID
    }
    private struct Entry {
        let name: String
        let before: Snapshot
        let after: Snapshot
        let images: [ObjectIdentifier: Int]
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    private var pendingName = "Edit"
    private var depth = 0
    /// Images held by history entries, reference-counted by identity. Without this index, every small edit walked
    /// every layer in every undo state to enforce the byte limit — quadratic work that became visible as the history
    /// and layer count grew. The live document is still excluded when `retainedBytes` is asked for.
    private var historyImages: [ObjectIdentifier: (references: Int, bytes: Int)] = [:]
    let entryLimit: Int
    let retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last?.name ?? "" }
    var redoName: String { future.last?.name ?? "" }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    func markSaved() { savedRevision = revision }
    /// The document as it stands, for a save that captures it now and finishes later.
    var currentRevision: UUID { revision }
    /// A save of `saved` finished. Edits made while it was writing leave the document modified; undoing back to it doesn't.
    func markSaved(_ saved: UUID) { savedRevision = saved }
    func reset() {
        past.removeAll()
        future.removeAll()
        pending = nil
        depth = 0
        historyImages.removeAll()
        revision = UUID()
        savedRevision = revision
    }

    func begin(_ name: String, document: CanvasDocument?, selection: UUID?) {
        if depth == 0 {
            pending = Snapshot(document: document, activeLayerID: selection, revision: revision)
            pendingName = name
        }
        depth += 1
    }

    func end(document: CanvasDocument?, selection: UUID?) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        revision = UUID()
        let after = Snapshot(document: document, activeLayerID: selection, revision: revision)
        let entry = Entry(name: pendingName, before: before, after: after,
                          images: Self.imageSizes(in: [before, after]))
        past.append(entry)
        register(entry)
        for discarded in future { unregister(discarded) }
        future.removeAll()
        trim(current: document)
    }

    func undo() -> Snapshot? {
        guard canUndo, let entry = past.popLast() else { return nil }
        future.append(entry)
        revision = entry.before.revision
        trim(current: entry.before.document)
        return entry.before
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.popLast() else { return nil }
        past.append(entry)
        revision = entry.after.revision
        trim(current: entry.after.document)
        return entry.after
    }

    /// Every image an asset holds: a 16-bit layer's 16-bit pixels too, twice the size of its 8-bit copy.
    private static func images(of asset: ImportedImage) -> [CGImage] {
        [asset.image, asset.thumbnail] + (asset.deep.map { [$0] } ?? [])
    }

    /// Each image only once per snapshot: a thumbnail or deep image may deliberately be the same object as another
    /// representation, and an entry owns two snapshots that often share most of their pixels.
    private static func imageSizes(in snapshot: Snapshot) -> [ObjectIdentifier: Int] {
        var result: [ObjectIdentifier: Int] = [:]
        for layer in snapshot.document?.layers ?? [] {
            for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                for image in images(of: asset) {
                    result[ObjectIdentifier(image)] = image.bytesPerRow * image.height
                }
            }
        }
        return result
    }

    private static func imageSizes(in snapshots: [Snapshot]) -> [ObjectIdentifier: Int] {
        snapshots.reduce(into: [:]) { result, snapshot in
            for (id, bytes) in imageSizes(in: snapshot) { result[id] = bytes }
        }
    }

    private func register(_ entry: Entry) {
        for (id, bytes) in entry.images {
            let old = historyImages[id]
            historyImages[id] = (references: (old?.references ?? 0) + 1, bytes: bytes)
        }
    }

    private func unregister(_ entry: Entry) {
        for id in entry.images.keys {
            guard let old = historyImages[id] else { continue }
            if old.references <= 1 { historyImages.removeValue(forKey: id) }
            else { historyImages[id] = (references: old.references - 1, bytes: old.bytes) }
        }
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int {
        var seen = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] {
            for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                for image in Self.images(of: asset) { seen.insert(ObjectIdentifier(image)) }
            }
        }
        return historyImages.reduce(0) { seen.contains($1.key) ? $0 : $0 + $1.value.bytes }
    }

    private func trim(current: CanvasDocument?) {
        while past.count + future.count > entryLimit || retainedBytes(current: current) > retainedByteLimit {
            if !past.isEmpty { unregister(past.removeFirst()) }
            else if !future.isEmpty { unregister(future.removeFirst()) }
            else { break }
        }
    }
}
