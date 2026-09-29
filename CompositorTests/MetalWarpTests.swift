import AppKit
import Testing
@testable import Compositor

/// Smudge and Liquify on the GPU against the same strokes on the CPU.
@MainActor struct MetalWarpTests {
    private func photo() throws -> CGImage {
        let context = try BrushRaster.context(width: 300, height: 200, mask: false)
        let data = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        for y in 0..<200 { for x in 0..<300 {
            let i = y * context.bytesPerRow + x * 4
            let a: Int = x < 250 ? 255 : 128
            data[i] = UInt8((x * 255 / 300) * a / 255); data[i + 1] = UInt8((y * 255 / 200) * a / 255)
            data[i + 2] = UInt8(((x / 12 + y / 12) % 2 == 0 ? 220 : 40) * a / 255); data[i + 3] = UInt8(a)
        } }
        return try #require(context.makeImage())
    }

    private func bytes(_ image: CGImage) throws -> [UInt8] {
        let context = try BrushRaster.copy(image)
        return Array(UnsafeBufferPointer(start: try #require(context.data).assumingMemoryBound(to: UInt8.self),
                                         count: context.bytesPerRow * context.height))
    }

    @Test(arguments: [BlurToolMode.smudge, .liquify])
    func matchesTheCPU(mode: BlurToolMode) throws {
        guard GPUCanvasRenderer.shared != nil else { return }
        let image = try photo()
        let layer = ImageLayer(asset: ImportedImage(image: image, thumbnail: image, name: "Photo"), origin: CGPoint(x: 20, y: 10))
        var settings = BrushSettings()
        settings.diameter = 50
        settings.hardness = 0.3
        settings.opacity = 0.7
        func run(gpu: Bool) throws -> CGImage {
            let stroke = try WarpStroke(layer: layer, image: image, transform: layer.transform, canvas: CGSize(width: 340, height: 240),
                                        mode: mode, settings: settings, useGPU: gpu)
            #expect((stroke.gpu != nil) == gpu)
            for step in 0...40 { stroke.append(CGPoint(x: 30 + Double(step) * 6, y: 60 + 40 * sin(Double(step) / 6))) }
            return try #require(stroke.image)
        }
        let cpu = try bytes(try run(gpu: false)), gpu = try bytes(try run(gpu: true))
        #expect(cpu.count == gpu.count)
        var largest = 0, over = 0
        for (a, b) in zip(cpu, gpu) {
            let difference = abs(Int(a) - Int(b))
            largest = max(largest, difference)
            if difference > 2 { over += 1 }
        }
        // A level here and there: the GPU's square roots round a hair differently.
        #expect(Double(over) / Double(cpu.count) < 0.001 && largest <= 8, "\(mode.rawValue): largest \(largest), \(over) values over 2")
    }
}
