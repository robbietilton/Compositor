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
        /// What the edit carried on, such as a color picker: its next edit joins this entry (see `end`).
        weak var group: AnyObject?
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
    /// What the edit Undo would take back, or Redo make again, carried on (see `end`).
    var undoGroup: AnyObject? { past.last?.group }
    var redoGroup: AnyObject? { future.last?.group }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    func markSaved() { savedRevision = revision }
    /// The document as it stands, for a save that captures it now and finishes later.
    var currentRevision: UUID { revision }
    /// A save of `saved` finished. Edits made while it was writing leave the document modified; undoing back to it doesn't.
    func markSaved(_ saved: UUID) { savedRevision = saved }
    /// The document as it was before the edit still open, if one is: the last finished edit's, at `currentRevision`.
    var beforeOpenEdit: Snapshot? { depth > 0 ? pending : nil }
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

    /// `coalescing`: what the edit carries on, such as the color picker it came from. When the last entry carries on the
    /// same and the history hasn't moved since (the document's revision is still that entry's), this edit joins it
    /// rather than adding another, so a picking undoes in one step without holding one open. An edit made in between
    /// that still stands, or the picking's own entry undone, starts a new entry; once the edit in between is undone, or
    /// the picking's entry redone, the picking's next edit joins its entry again. An entry joined back to where it began
    /// goes, as an edit that changes nothing adds none.
    func end(document: CanvasDocument?, selection: UUID?, coalescing group: AnyObject? = nil) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        var start = (name: pendingName, before: before)
        if let group, let last = past.last, last.group === group, last.after.revision == before.revision {
            past.removeLast()
            start = (last.name, last.before)
        }
        future.removeAll()
        if start.before.document == document {
            revision = start.before.revision
        } else {
            revision = UUID()
            past.append(Entry(name: start.name, before: start.before,
                after: Snapshot(document: document, activeLayerID: selection, revision: revision), group: group))
        }
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

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int {
        var seen = Set<ObjectIdentifier>()
        for layer in current?.layers ?? [] {
            for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                seen.insert(ObjectIdentifier(asset.image))
                seen.insert(ObjectIdentifier(asset.thumbnail))
            }
        }
        var bytes = 0
        for entry in past + future {
            for snapshot in [entry.before, entry.after] {
                for layer in snapshot.document?.layers ?? [] {
                    for asset in [layer.asset, layer.mask?.asset].compactMap({ $0 }) {
                        for image in [asset.image, asset.thumbnail] where seen.insert(ObjectIdentifier(image)).inserted {
                            bytes += image.bytesPerRow * image.height
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
