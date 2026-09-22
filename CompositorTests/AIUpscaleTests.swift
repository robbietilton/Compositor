import AppKit
import CryptoKit
import Testing
@testable import Compositor

/// CPU checks always run; the GPU cases opt in with COMPOSITOR_AI_MODEL_PATH pointing at the official checkpoint.
@MainActor
@Suite(.serialized)
struct AIUpscaleTests {
    nonisolated private static var modelPath: String? { ProcessInfo.processInfo.environment["COMPOSITOR_AI_MODEL_PATH"] }

    @Test func dimensionsRejectInvalidFactorsAndOverflowBeforeAllocation() throws {
        let size = try ESRGANUpscaler.outputSize(width: 1536, height: 1024, factor: 4)
        #expect(size.width == 6144 && size.height == 4096)
        for values in [(0, 4, 2), (-1, 4, 2), (Int.max, 1, 4), (1, Int.max, 2),
                       (1, 1, 0), (1, 1, -2), (1, 1, 3), (1, 1, Int.max), (5001, 5000, 2)] {
            #expect(throws: ESRGANError.self) {
                try ESRGANUpscaler.outputSize(width: values.0, height: values.1, factor: values.2)
            }
        }
    }

    @Test func cachedModelMustMatchSizeAndDigest() throws {
        let bytes = Data([1, 2, 3, 4])
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        let model = AIModel(name: "Test", file: "test", url: url, size: bytes.count,
            sha256: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), credit: "Test")
        try bytes.write(to: url)
        #expect(try model.verifiedData(at: url) == bytes)
        try Data([4, 3, 2, 1]).write(to: url)
        #expect(throws: AIModelError.self) { try model.verifiedData(at: url) }
        try Data([1, 2, 3]).write(to: url)
        #expect(throws: AIModelError.self) { try model.verifiedData(at: url) }
    }

    @Test func tensorParserChecksShapesOffsetsAndArchiveBounds() throws {
        let valid = archive(pickle: tensor(shape: [1], strides: [1]))
        let parsed = try TorchCheckpoint(data: valid)
        #expect(parsed.tensors["weight"]?.shape == [1])
        #expect(parsed.tensors["weight"]?.values == [1])
        for pickle in [tensor(shape: [], strides: []), tensor(shape: [1, 1], strides: [1]),
                       tensor(shape: [-1], strides: [1]), tensor(shape: [2], strides: [1]),
                       tensor(shape: [1], strides: [1], offset: -1),
                       tensor(shape: [1], strides: [1], offset: Int32.max),
                       tensor(shape: [Int32.max, Int32.max, Int32.max], strides: [1, 1, 1])] {
            #expect(throws: ESRGANError.self) { try TorchCheckpoint(data: archive(pickle: pickle)) }
        }
        for count in [0, 1, 21, valid.count - 1] {
            #expect(throws: ESRGANError.self) { try TorchCheckpoint(data: Data(valid.prefix(count))) }
        }
        var badName = valid
        let central = findSignature(0x02014b50, in: badName)
        put(65_535, bytes: 2, into: &badName, at: central + 28)
        #expect(throws: ESRGANError.self) { try TorchCheckpoint(data: badName) }
        var badOffset = valid
        put(UInt32.max, bytes: 4, into: &badOffset, at: central + 42)
        #expect(throws: ESRGANError.self) { try TorchCheckpoint(data: badOffset) }
        var badLocal = valid
        badLocal[0] = 0
        #expect(throws: ESRGANError.self) { try TorchCheckpoint(data: badLocal) }
        #expect(throws: ESRGANError.self) {
            try TorchCheckpoint(data: archive(pickle: tensor(shape: [1], strides: [1]), duplicate: true))
        }
    }

    @Test func damagedCheckpointMetadataNeverTraps() throws {
        let original = archive(pickle: tensor(shape: [1], strides: [1]))
        // Exercise bounds of ZIP, pickle stack, integer, storage and tensor metadata without executing any pickle callable.
        var seed: UInt64 = 0x51a7
        for _ in 0..<2000 {
            var mutated = original
            for _ in 0..<3 {
                seed = seed &* 6364136223846793005 &+ 1
                let index = Int(seed % UInt64(mutated.count))
                seed = seed &* 6364136223846793005 &+ 1
                mutated[index] = UInt8(truncatingIfNeeded: seed >> 32)
            }
            _ = try? TorchCheckpoint(data: mutated)
        }
    }

    @Test func enlargerRebuildsOnlyVisibleImageLayers() throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        context.setFillColor(CGColor(gray: 0.5, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Visible"))
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Hidden"))
        let hidden = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == hidden })
        session.document?.layers[index].isVisible = false
        #expect(session.aiUpscaleTargets.map(\.name) == ["Visible"])
        #expect(session.canAIUpscale)
    }

    @Test func darkroomApplyHandsItsEnlargerFactorOn() async throws {
        let session = EditorSession()
        session.createDocument(width: 40, height: 30)
        let context = try BrushRaster.context(width: 40, height: 30, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.3, green: 0.5, blue: 0.7, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 40, height: 30))
        let image = try #require(context.makeImage())
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Render"))
        var requested: [Int] = []
        let previous = EditorSession.enlargeAfterDarkroom
        EditorSession.enlargeAfterDarkroom = { target, factor in if target === session { requested.append(factor) } }
        defer { EditorSession.enlargeAfterDarkroom = previous }
        session.beginFilter(.renderFinish)
        session.filterEdit?.enlargeFactor = 4
        await session.applyDarkroom()
        #expect(session.filterEdit == nil && requested == [4])
        #expect(session.activeLayer?.name.hasSuffix("· Tonal Contrast") == true)
        // Without the step, Apply doesn't ask for Enlarger.
        session.beginFilter(.renderFinish)
        await session.applyDarkroom()
        #expect(requested == [4])
    }

    @Test func cancelledBeforeModelLoadKeepsDocumentAndUndo() async throws {
        let session = try session()
        let before = session.document, undo = session.history.undoCount
        let token = UpscaleCancellation()
        token.cancel()
        await #expect(throws: CancellationError.self) {
            try await session.aiUpscale(factor: 2, model: URL(fileURLWithPath: "/missing-model"),
                cancellation: token, progress: { _, _ in Issue.record("Cancelled run reported progress") })
        }
        #expect(session.document == before)
        #expect(session.history.undoCount == undo)
    }

    @Test(.enabled(if: modelPath != nil))
    func gpuDimensionsTransparencyProgressAndTileCancellation() throws {
        let engine = try AIUpscaleEngine.shared.upscaler(for: URL(fileURLWithPath: try #require(Self.modelPath)))
        let source = try image(width: 225, height: 13)
        for factor in [2, 4] {
            var shares: [Double] = []
            let output = try engine.upscale(source, factor: factor, progress: { shares.append($0) }, cancelled: { false })
            #expect(output.width == source.width * factor && output.height == source.height * factor)
            #expect(shares == [0.5, 1])
            let actual = try rgba(output)
            let reference = try BrushRaster.context(width: output.width, height: output.height, mask: false)
            reference.interpolationQuality = .high
            reference.translateBy(x: 0, y: CGFloat(output.height)); reference.scaleBy(x: 1, y: -1)
            reference.draw(source, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
            let a = try #require(actual.data).assumingMemoryBound(to: UInt8.self)
            let b = try #require(reference.data).assumingMemoryBound(to: UInt8.self)
            var equalAlpha = true, premultiplied = true
            for y in 0..<output.height { for x in 0..<output.width {
                let i = y * actual.bytesPerRow + x * 4, j = y * reference.bytesPerRow + x * 4
                equalAlpha = equalAlpha && a[i + 3] == b[j + 3]
                for c in 0..<3 { premultiplied = premultiplied && a[i + c] <= a[i + 3] }
            } }
            #expect(equalAlpha)
            #expect(premultiplied)
        }
        var completed = 0
        #expect(throws: CancellationError.self) {
            try engine.upscale(source, factor: 2, progress: { _ in completed += 1 }, cancelled: { completed > 0 })
        }
        #expect(completed == 1)
        #expect(throws: CancellationError.self) {
            try engine.upscale(source, factor: 2, progress: { _ in Issue.record("Cancelled run emitted progress") }, cancelled: { true })
        }
    }

    @Test(.enabled(if: modelPath != nil))
    func gpuSessionCancellationAtFinalResizeDoesNotApplyOrAddUndo() async throws {
        let session = try session()
        let before = session.document, undo = session.history.undoCount
        let token = UpscaleCancellation()
        await #expect(throws: CancellationError.self) {
            try await session.aiUpscale(factor: 2, model: URL(fileURLWithPath: try #require(Self.modelPath)),
                cancellation: token, progress: { _, label in
                    if label == "Enlarging the canvas…" { token.cancel() }
                })
        }
        #expect(session.document == before)
        #expect(session.history.undoCount == undo)
    }

    @Test(.enabled(if: modelPath != nil))
    func gpuSessionCommitKeepsMetadataScalesEffectsAndUndoesOnce() async throws {
        let session = try session()
        let original = try #require(session.document)
        let id = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == id })
        session.document?.layers[index].opacity = 0.6
        session.document?.layers[index].effects = LayerEffects(stroke: StrokeEffect(size: 2))
        let before = session.document, undo = session.history.undoCount
        try await session.aiUpscale(factor: 2, model: URL(fileURLWithPath: try #require(Self.modelPath)),
                                    cancellation: UpscaleCancellation(), progress: { _, _ in })
        #expect(session.document?.width == original.width * 2)
        #expect(session.document?.height == original.height * 2)
        #expect(session.activeLayerID == id)
        #expect(session.activeLayer?.opacity == 0.6)
        #expect(session.activeLayer?.effects?.stroke?.size == 4)
        #expect(session.history.undoCount == undo + 1)
        session.undo()
        #expect(session.document == before)
        #expect(session.history.undoCount == undo)
    }

    private func session() throws -> EditorSession {
        let session = EditorSession()
        let image = try image(width: 11, height: 7)
        session.createDocument(width: image.width, height: image.height)
        session.insert(ImportedImage(image: image, thumbnail: image, name: "AI test"))
        return session
    }

    private func image(width: Int, height: Int) throws -> CGImage {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.setFillColor(CGColor(srgbRed: 0.35, green: 0.5, blue: 0.7, alpha: 0.7))
        context.fill(CGRect(x: 1, y: 1, width: width - 2, height: height / 2))
        return try #require(context.makeImage())
    }
    private func rgba(_ image: CGImage) throws -> CGContext {
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: false, context: context)
        return context
    }

    // The tiny fixtures use the same protocol-2 tensor structure as the official PyTorch checkpoint.
    private func tensor(shape: [Int32], strides: [Int32], offset: Int32 = 0) -> Data {
        var p = Data([0x80, 2, 0x7d])
        func string(_ s: String) { p.append(0x58); append(UInt32(s.utf8.count), bytes: 4, to: &p); p.append(contentsOf: s.utf8) }
        func global(_ module: String, _ name: String) { p.append(0x63); p.append(contentsOf: "\(module)\n\(name)\n".utf8) }
        func integer(_ n: Int32) { p.append(0x4a); append(UInt32(bitPattern: n), bytes: 4, to: &p) }
        func tuple(_ values: [Int32]) { p.append(0x28); values.forEach(integer); p.append(0x74) }
        string("params_ema"); p.append(0x7d); string("weight")
        global("torch._utils", "_rebuild_tensor_v2"); p.append(0x28)
        p.append(0x28); string("storage"); global("torch", "FloatStorage"); string("0"); string("cpu"); integer(1)
        p.append(contentsOf: [0x74, 0x51]); integer(offset); tuple(shape); tuple(strides)
        p.append(contentsOf: [0x74, 0x52, 0x73, 0x73, 0x2e])
        return p
    }
    private func archive(pickle: Data, duplicate: Bool = false) -> Data {
        var data = Data(), directory = Data()
        var entries = [("archive/data.pkl", pickle), ("archive/data/0", Data([0, 0, 128, 63]))]
        if duplicate { entries.append(entries[1]) }
        for (name, body) in entries {
            let offset = data.count, n = UInt32(name.utf8.count), length = UInt32(body.count)
            append(0x04034b50, bytes: 4, to: &data); append(20, bytes: 2, to: &data)
            data.append(Data(repeating: 0, count: 12)); append(length, bytes: 4, to: &data); append(length, bytes: 4, to: &data)
            append(n, bytes: 2, to: &data); append(0, bytes: 2, to: &data)
            data.append(contentsOf: name.utf8); data.append(body)
            append(0x02014b50, bytes: 4, to: &directory); append(20, bytes: 2, to: &directory); append(20, bytes: 2, to: &directory)
            directory.append(Data(repeating: 0, count: 12)); append(length, bytes: 4, to: &directory); append(length, bytes: 4, to: &directory)
            append(n, bytes: 2, to: &directory); directory.append(Data(repeating: 0, count: 12))
            append(UInt32(offset), bytes: 4, to: &directory); directory.append(contentsOf: name.utf8)
        }
        let offset = data.count
        data.append(directory); append(0x06054b50, bytes: 4, to: &data)
        append(0, bytes: 4, to: &data); append(UInt32(entries.count), bytes: 2, to: &data); append(UInt32(entries.count), bytes: 2, to: &data)
        append(UInt32(directory.count), bytes: 4, to: &data); append(UInt32(offset), bytes: 4, to: &data); append(0, bytes: 2, to: &data)
        return data
    }
    private func append(_ value: UInt32, bytes: Int, to data: inout Data) {
        for i in 0..<bytes { data.append(UInt8(truncatingIfNeeded: value >> (8 * i))) }
    }
    private func put(_ value: UInt32, bytes: Int, into data: inout Data, at offset: Int) {
        for i in 0..<bytes { data[offset + i] = UInt8(truncatingIfNeeded: value >> (8 * i)) }
    }
    private func findSignature(_ value: UInt32, in data: Data) -> Int {
        var signature = Data(); append(value, bytes: 4, to: &signature)
        return data.range(of: signature)!.lowerBound
    }
}
