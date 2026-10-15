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
    }
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    private var pendingName = "Edit"
    private var depth = 0
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
        past.append(Entry(name: pendingName, before: before,
            after: Snapshot(document: document, activeLayerID: selection, revision: revision)))
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

    private static func assets(of layer: ImageLayer) -> [ImportedImage] {
        [layer.asset, layer.mask?.asset].compactMap { $0 } + layer.gifFrameMasks.values.map(\.asset)
            + Array(layer.gifAnimation?.framePixels.values ?? [:].values)
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int {
        var seen = Set<ObjectIdentifier>()
        var seenSources = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] {
            for asset in Self.assets(of: layer) {
                for image in Self.images(of: asset) { seen.insert(ObjectIdentifier(image)) }
            }
            if let source = layer.gifAnimation?.source {
                seenSources.insert(ObjectIdentifier(source))
                for frame in source.frames { seen.insert(ObjectIdentifier(frame.thumbnail)) }
            }
        }
        var bytes = 0
        for entry in past + future {
            for snapshot in [entry.before, entry.after] {
                for layer in snapshot.document?.layers ?? [] {
                    for asset in Self.assets(of: layer) {
                        for image in Self.images(of: asset) where seen.insert(ObjectIdentifier(image)).inserted {
                            bytes += image.bytesPerRow * image.height
                        }
                    }
                    if let source = layer.gifAnimation?.source {
                        if seenSources.insert(ObjectIdentifier(source)).inserted { bytes += source.data.count }
                        for frame in source.frames where seen.insert(ObjectIdentifier(frame.thumbnail)).inserted {
                            bytes += frame.thumbnail.bytesPerRow * frame.thumbnail.height
                        }
                    }
                }
            }
        }
        return bytes
    }

    private func trim(current: CanvasDocument?) {
        while past.count + future.count > entryLimit || retainedBytes(current: current) > retainedByteLimit {
            if !past.isEmpty { past.removeFirst() }
            else if !future.isEmpty { future.removeFirst() }
            else { break }
        }
    }
}
