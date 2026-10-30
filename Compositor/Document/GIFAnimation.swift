import Foundation
import ImageIO
import CoreGraphics

/// Encoded frames and small previews are immutable and shared by layers, history and background saves.
nonisolated final class GIFSource: @unchecked Sendable {
    static let byteLimit = 512 * 1024 * 1024
    static let totalByteLimit = DocumentLimits.documentPixelBudget * 4
    static let totalThumbnailPixelBudget = GIFTimelineLimits.thumbnailPixelBudget

    let data: Data
    let frames: [GIFTimelineFrame]
    let width: Int
    let height: Int

    init(data: Data, frames: [GIFTimelineFrame], width: Int, height: Int) {
        self.data = data
        self.frames = frames
        self.width = width
        self.height = height
    }

    var thumbnailPixels: Int { frames.reduce(0) { $0 + $1.thumbnail.width * $1.thumbnail.height } }

    /// One reader kept open for every frame read. A GIF frame is often only the part that changed, so a new reader
    /// rebuilds it from the first frame on each read (tens of milliseconds, too slow to play), while this one carries
    /// on from the frame it read last.
    private var reader: CGImageSource?
    private let readerLock = NSLock()

    func withReader<T>(_ body: (CGImageSource) throws -> T) throws -> T {
        try readerLock.withLock {
            if reader == nil { reader = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) }
            guard let reader else { throw ImageImportError.unreadable }
            return try body(reader)
        }
    }
}

/// Image Size's rasterization, applied lazily to every frame, including rotation and uneven scaling.
nonisolated struct GIFFrameGeometry: Equatable, Codable, Sendable {
    let width: Int
    let height: Int
    let a: Double
    let b: Double
    let c: Double
    let d: Double
    let tx: Double
    let ty: Double
    var sampling: LayerSampling = .high

    init(width: Int, height: Int, unitTransform: CGAffineTransform, sampling: LayerSampling = .high) {
        self.width = width
        self.height = height
        a = unitTransform.a; b = unitTransform.b; c = unitTransform.c; d = unitTransform.d
        tx = unitTransform.tx; ty = unitTransform.ty
        self.sampling = sampling
    }

    private enum CodingKeys: String, CodingKey { case width, height, a, b, c, d, tx, ty, sampling }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        width = try values.decode(Int.self, forKey: .width)
        height = try values.decode(Int.self, forKey: .height)
        a = try values.decode(Double.self, forKey: .a); b = try values.decode(Double.self, forKey: .b)
        c = try values.decode(Double.self, forKey: .c); d = try values.decode(Double.self, forKey: .d)
        tx = try values.decode(Double.self, forKey: .tx); ty = try values.decode(Double.self, forKey: .ty)
        sampling = try values.decodeIfPresent(LayerSampling.self, forKey: .sampling) ?? .high
    }

    var unitTransform: CGAffineTransform { CGAffineTransform(a: a, b: b, c: c, d: d, tx: tx, ty: ty) }
    var isValid: Bool {
        (1...DocumentLimits.maxSide).contains(width) && (1...DocumentLimits.maxSide).contains(height)
            && width * height <= DocumentLimits.maxSurfacePixels
            && [a, b, c, d, tx, ty].allSatisfy { $0.isFinite && abs($0) <= 1_000_000 }
            && abs(a * d - b * c) > 1e-15
    }
}

/// A stable editable frame identity, distinct from its composed frame in the immutable GIF.
nonisolated struct GIFFrameReference: Equatable, Codable, Sendable {
    let index: Int
    let sourceIndex: Int
}

nonisolated struct GIFAnimation: Equatable, Sendable {
    let source: GIFSource
    /// The frame restored on opening. Navigation and playback stay in the editor's runtime state.
    var selectedFrameIndex = 0
    var geometry: GIFFrameGeometry? = nil
    /// Only edited frames retain full-size pixels; unedited frames still decode from the immutable source.
    var framePixels: [Int: ImportedImage] = [:]
    /// Removed original frames. Inserted identities are removed directly from frameOrder.
    var deletedFrameIndices: Set<Int> = []
    /// Nil uses the surviving source sequence. Insertions and moves retain an explicit order.
    var frameOrder: [GIFFrameReference]? = nil
    var timing = GIFFrameTiming()

    var frameReferences: [GIFFrameReference] {
        frameOrder ?? source.frames.filter { !deletedFrameIndices.contains($0.index) }
            .map { GIFFrameReference(index: $0.index, sourceIndex: $0.index) }
    }

    var sourceFrames: [GIFTimelineFrame] {
        frameReferences.compactMap { reference in
            guard source.frames.indices.contains(reference.sourceIndex) else { return nil }
            let frame = source.frames[reference.sourceIndex]
            return GIFTimelineFrame(index: reference.index, thumbnail: frame.thumbnail, duration: frame.duration)
        }
    }

    var frames: [GIFTimelineFrame] {
        sourceFrames.map { GIFTimelineFrame(index: $0.index, thumbnail: $0.thumbnail, duration: timing.delay(for: $0)) }
    }

    func sourceFrameIndex(for index: Int) -> Int? {
        if let frameOrder { return frameOrder.first(where: { $0.index == index })?.sourceIndex }
        return source.frames.indices.contains(index) && !deletedFrameIndices.contains(index) ? index : nil
    }

    func containsFrame(_ index: Int) -> Bool {
        sourceFrameIndex(for: index) != nil
    }

    var hasValidFrameOrder: Bool {
        guard let frameOrder else { return true }
        guard !frameOrder.isEmpty, frameOrder.count <= GIFTimelineLimits.maxFrames else { return false }
        var indices = Set<Int>()
        for frame in frameOrder {
            guard (0..<GIFTimelineLimits.frameIdentityLimit).contains(frame.index),
                  indices.insert(frame.index).inserted, source.frames.indices.contains(frame.sourceIndex),
                  frame.index >= source.frames.count || (frame.index == frame.sourceIndex
                    && !deletedFrameIndices.contains(frame.index)) else { return false }
        }
        return Set(frameOrder.filter { $0.index < source.frames.count }.map(\.index))
            == Set(source.frames.indices).subtracting(deletedFrameIndices)
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.source === rhs.source && lhs.selectedFrameIndex == rhs.selectedFrameIndex && lhs.geometry == rhs.geometry
            && lhs.deletedFrameIndices == rhs.deletedFrameIndices && lhs.frameOrder == rhs.frameOrder && lhs.timing == rhs.timing
            && lhs.framePixels.count == rhs.framePixels.count
            && lhs.framePixels.allSatisfy { rhs.framePixels[$0.key]?.image === $0.value.image }
    }

    func resizing(from old: LayerTransform, to new: LayerTransform, scaleX: CGFloat, scaleY: CGFloat) -> GIFAnimation {
        let map = (geometry?.unitTransform ?? .identity)
            .concatenating(old.unitToDocument)
            .concatenating(CGAffineTransform(scaleX: scaleX, y: scaleY))
            .concatenating(new.unitToDocument.inverted())
        var resized = self
        resized.geometry = GIFFrameGeometry(width: Int(new.size.width), height: Int(new.size.height),
                                           unitTransform: map, sampling: new.sampling)
        return resized
    }
}
