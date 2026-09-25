import AppKit
import Metal

/// Layer effects on the GPU: the outline's reach and the shadow's blur are the two heavy passes, and both are
/// separable, so each runs as a row pass and a column pass over the same pixels. Falls back to the CPU renderer
/// when Metal isn't available (see `LayerEffectsRenderer`). Export renders on a worker, so it holds only Metal objects,
/// which are safe to use from any thread.
nonisolated final class MetalLayerEffects: Sendable {
    static let shared: MetalLayerEffects? = try? MetalLayerEffects()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let alpha: MTLComputePipelineState
    private let spreadRows: MTLComputePipelineState
    private let spreadColumns: MTLComputePipelineState
    private let ring: MTLComputePipelineState
    private let shift: MTLComputePipelineState
    private let blurRows: MTLComputePipelineState
    private let blurColumns: MTLComputePipelineState
    private let inside: MTLComputePipelineState
    private let compose: MTLComputePipelineState

    private struct Spread { var width: UInt32; var height: UInt32; var reach: UInt32; var smallest: UInt32 }
    private struct Shift { var width: UInt32; var height: UInt32; var dx: Float; var dy: Float }
    private struct Blur { var width: UInt32; var height: UInt32; var sigma: Float; var radius: UInt32 }
    private struct Compose {
        var width: UInt32; var height: UInt32
        var strokeColor: SIMD4<Float>   // rgb, opacity
        var shadowColor: SIMD4<Float>
        var overlayColor: SIMD4<Float>
        var innerColor: SIMD4<Float>
        var glowColor: SIMD4<Float>
        var innerGlowColor: SIMD4<Float>
        var flags: SIMD4<UInt32>        // has stroke, stroke inside, has shadow, has inner shadow
        var more: SIMD4<UInt32>         // has color overlay, has outer glow, has inner glow, unused…
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ExportError.render }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        func pipeline(_ name: String) throws -> MTLComputePipelineState {
            guard let function = library.makeFunction(name: name) else { throw ExportError.render }
            return try device.makeComputePipelineState(function: function)
        }
        self.device = device
        self.queue = queue
        alpha = try pipeline("effects_alpha")
        spreadRows = try pipeline("effects_spread_rows")
        spreadColumns = try pipeline("effects_spread_columns")
        ring = try pipeline("effects_ring")
        shift = try pipeline("effects_shift")
        blurRows = try pipeline("effects_blur_rows")
        blurColumns = try pipeline("effects_blur_columns")
        inside = try pipeline("effects_inside")
        compose = try pipeline("effects_compose")
    }

    /// `pixels` — a layer's pixels as they are shown, with room around them for the effects — with its stroke and
    /// drop shadow composited around them. The result is the same size.
    func render(_ pixels: CGImage, effects: LayerEffects) throws -> CGImage {
        let width = pixels.width, height = pixels.height
        let count = width * height
        guard count > 0, count <= 80_000_000 else { throw ExportError.tooLarge }
        // The pixels as bytes the GPU can read, premultiplied as everything else here is.
        let source = try BrushRaster.context(width: width, height: height, mask: false)
        // Through BrushRaster, which turns the image the right way up for this context's top-left coordinates.
        BrushRaster.draw(pixels, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: source)
        guard let bytes = source.data else { throw ExportError.render }
        let stride = MemoryLayout<Float>.stride
        guard let input = device.makeBuffer(bytes: bytes, length: count * 4, options: .storageModeShared),
              let output = device.makeBuffer(length: count * 4, options: .storageModeShared),
              let first = device.makeBuffer(length: count * stride, options: .storageModeShared),
              let second = device.makeBuffer(length: count * stride, options: .storageModeShared),
              let third = device.makeBuffer(length: count * stride, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        let grid = MTLSize(width: width, height: height, depth: 1)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        func run(_ state: MTLComputePipelineState, _ buffers: [(MTLBuffer, Int)], _ uniforms: UnsafeRawPointer, _ length: Int) {
            encoder.setComputePipelineState(state)
            for (buffer, index) in buffers { encoder.setBuffer(buffer, offset: 0, index: index) }
            encoder.setBytes(uniforms, length: length, index: 9)
            encoder.dispatchThreads(grid, threadsPerThreadgroup: group)
            // Each pass reads what the one before it wrote. Without this they can run at the same time, and a pass
            // reads half-written pixels — which showed up as effects that only appeared once the stroke ended.
            encoder.memoryBarrier(scope: .buffers)
        }
        // first: the shape's own coverage.
        var size = Spread(width: UInt32(width), height: UInt32(height), reach: 0, smallest: 0)
        run(alpha, [(input, 0), (first, 1)], &size, MemoryLayout<Spread>.stride)

        let stroke = effects.stroke.flatMap { $0.isEnabled && $0.size > 0 && $0.opacity > 0 ? $0 : nil }
        if let stroke {
            // second: the shape reached out (or pulled in) by the stroke's size; third: the ring between them.
            var spread = Spread(width: UInt32(width), height: UInt32(height),
                                reach: UInt32(max(1, Int(stroke.size.rounded()))), smallest: stroke.inside ? 1 : 0)
            run(spreadRows, [(first, 0), (third, 1)], &spread, MemoryLayout<Spread>.stride)
            run(spreadColumns, [(third, 0), (second, 1)], &spread, MemoryLayout<Spread>.stride)
            run(ring, [(first, 0), (second, 1), (third, 2)], &spread, MemoryLayout<Spread>.stride)
        }
        let shadow = effects.shadow.flatMap { $0.isEnabled && $0.opacity > 0 ? $0 : nil }
        if let shadow {
            // second: the shape moved and softened.
            var moved = Shift(width: UInt32(width), height: UInt32(height),
                              dx: Float(shadow.offset.width), dy: Float(shadow.offset.height))
            run(shift, [(first, 0), (second, 1)], &moved, MemoryLayout<Shift>.stride)
            let sigma = Float(shadow.blur / 2)
            if sigma > 0.01 {
                var blur = Blur(width: UInt32(width), height: UInt32(height), sigma: sigma,
                                radius: UInt32(max(1, Int((sigma * 3).rounded()))))
                // The ring is already in `third`, so the blur borrows the coverage buffer for its row pass.
                guard let scratch = device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
                run(blurRows, [(second, 0), (scratch, 1)], &blur, MemoryLayout<Blur>.stride)
                run(blurColumns, [(scratch, 0), (second, 1)], &blur, MemoryLayout<Blur>.stride)
            }
        }
        let overlay = effects.colorOverlay.flatMap { $0.isEnabled && $0.opacity > 0 ? $0 : nil }
        let innerShadow = effects.innerShadow.flatMap { $0.isEnabled && $0.opacity > 0 ? $0 : nil }
        var innerBuffer: MTLBuffer?
        if let innerShadow {
            // What lies outside the layer, moved and softened, kept to the layer's own shape.
            guard let moved = device.makeBuffer(length: count * stride, options: .storageModeShared),
                  let softened = device.makeBuffer(length: count * stride, options: .storageModeShared),
                  let result = device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
            var shift = Shift(width: UInt32(width), height: UInt32(height),
                              dx: Float(innerShadow.offset.width), dy: Float(innerShadow.offset.height))
            run(self.shift, [(first, 0), (moved, 1)], &shift, MemoryLayout<Shift>.stride)
            let sigma = Float(innerShadow.blur / 2)
            if sigma > 0.01 {
                var blur = Blur(width: UInt32(width), height: UInt32(height), sigma: sigma,
                                radius: UInt32(max(1, Int((sigma * 3).rounded()))))
                run(blurRows, [(moved, 0), (softened, 1)], &blur, MemoryLayout<Blur>.stride)
                run(blurColumns, [(softened, 0), (moved, 1)], &blur, MemoryLayout<Blur>.stride)
            }
            var size = Spread(width: UInt32(width), height: UInt32(height), reach: 0, smallest: 0)
            run(self.inside, [(first, 0), (moved, 1), (result, 2)], &size, MemoryLayout<Spread>.stride)
            innerBuffer = result
        }
        guard let inner = innerBuffer ?? device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
        let glow = effects.outerGlow.flatMap { $0.isEnabled && $0.size > 0 && $0.opacity > 0 ? $0 : nil }
        var glowBuffer: MTLBuffer?
        if let glow {
            guard let blurredGlow = device.makeBuffer(length: count * stride, options: .storageModeShared),
                  let scratch = device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
            let sigma = Float(glow.size / 2)
            if sigma > 0.01 {
                var blur = Blur(width: UInt32(width), height: UInt32(height), sigma: sigma,
                                radius: UInt32(max(1, Int((sigma * 3).rounded()))))
                run(blurRows, [(first, 0), (scratch, 1)], &blur, MemoryLayout<Blur>.stride)
                run(blurColumns, [(scratch, 0), (blurredGlow, 1)], &blur, MemoryLayout<Blur>.stride)
            } else {
                var zeroShift = Shift(width: UInt32(width), height: UInt32(height), dx: 0, dy: 0)
                run(shift, [(first, 0), (blurredGlow, 1)], &zeroShift, MemoryLayout<Shift>.stride)
            }
            glowBuffer = blurredGlow
        }
        guard let glowOutput = glowBuffer ?? device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
        let innerGlow = effects.innerGlow.flatMap { $0.isEnabled && $0.size > 0 && $0.opacity > 0 ? $0 : nil }
        var innerGlowBuffer: MTLBuffer?
        if let innerGlow {
            guard let blurredGlow = device.makeBuffer(length: count * stride, options: .storageModeShared),
                  let scratch = device.makeBuffer(length: count * stride, options: .storageModeShared),
                  let result = device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
            let sigma = Float(innerGlow.size / 2)
            if sigma > 0.01 {
                var blur = Blur(width: UInt32(width), height: UInt32(height), sigma: sigma,
                                radius: UInt32(max(1, Int((sigma * 3).rounded()))))
                run(blurRows, [(first, 0), (scratch, 1)], &blur, MemoryLayout<Blur>.stride)
                run(blurColumns, [(scratch, 0), (blurredGlow, 1)], &blur, MemoryLayout<Blur>.stride)
            } else {
                var zeroShift = Shift(width: UInt32(width), height: UInt32(height), dx: 0, dy: 0)
                run(shift, [(first, 0), (blurredGlow, 1)], &zeroShift, MemoryLayout<Shift>.stride)
            }
            var size = Spread(width: UInt32(width), height: UInt32(height), reach: 0, smallest: 0)
            run(inside, [(first, 0), (blurredGlow, 1), (result, 2)], &size, MemoryLayout<Spread>.stride)
            innerGlowBuffer = result
        }
        guard let innerGlowOutput = innerGlowBuffer ?? device.makeBuffer(length: count * stride, options: .storageModeShared) else { throw ExportError.render }
        var settings = Compose(width: UInt32(width), height: UInt32(height),
            strokeColor: SIMD4(Float(stroke?.color.red ?? 0), Float(stroke?.color.green ?? 0),
                               Float(stroke?.color.blue ?? 0), Float(stroke?.opacity ?? 0)),
            shadowColor: SIMD4(Float(shadow?.color.red ?? 0), Float(shadow?.color.green ?? 0),
                               Float(shadow?.color.blue ?? 0), Float(shadow?.opacity ?? 0)),
            overlayColor: SIMD4(Float(overlay?.color.red ?? 0), Float(overlay?.color.green ?? 0),
                                Float(overlay?.color.blue ?? 0), Float(overlay?.opacity ?? 0)),
            innerColor: SIMD4(Float(innerShadow?.color.red ?? 0), Float(innerShadow?.color.green ?? 0),
                              Float(innerShadow?.color.blue ?? 0), Float(innerShadow?.opacity ?? 0)),
            glowColor: SIMD4(Float(glow?.color.red ?? 0), Float(glow?.color.green ?? 0),
                             Float(glow?.color.blue ?? 0), Float(glow?.opacity ?? 0)),
            innerGlowColor: SIMD4(Float(innerGlow?.color.red ?? 0), Float(innerGlow?.color.green ?? 0),
                                  Float(innerGlow?.color.blue ?? 0), Float(innerGlow?.opacity ?? 0)),
            flags: SIMD4(stroke != nil ? 1 : 0, stroke?.inside == true ? 1 : 0, shadow != nil ? 1 : 0,
                         innerShadow != nil ? 1 : 0),
            more: SIMD4(overlay != nil ? 1 : 0, glow != nil ? 1 : 0, innerGlow != nil ? 1 : 0, 0))
        run(compose, [(input, 0), (third, 1), (second, 2), (output, 3), (inner, 4), (first, 5), (glowOutput, 6), (innerGlowOutput, 7)], &settings, MemoryLayout<Compose>.stride)
        encoder.endEncoding()
        command.commit()
        command.waitUntilCompleted()
        guard command.error == nil else { throw ExportError.render }
        // Taken out of the result buffer, which is freed as soon as this returns: an image left pointing at it
        // would draw whatever the buffer was reused for.
        let data = Data(bytes: output.contents(), count: count * 4)
        guard let provider = CGDataProvider(data: data as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
        else { throw ExportError.render }
        return image
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Spread { uint width; uint height; uint reach; uint smallest; };
    struct Shift { uint width; uint height; float dx; float dy; };
    struct Blur { uint width; uint height; float sigma; uint radius; };
    struct Compose { uint width; uint height; float4 strokeColor; float4 shadowColor; float4 overlayColor;
                     float4 innerColor; float4 glowColor; float4 innerGlowColor; uint4 flags; uint4 more; };

    kernel void effects_alpha(device const uchar4* pixels [[buffer(0)]],
                              device float* coverage [[buffer(1)]],
                              constant Spread& size [[buffer(9)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.width || gid.y >= size.height) { return; }
        uint index = gid.y * size.width + gid.x;
        coverage[index] = float(pixels[index].w) / 255.0;
    }

    // The largest (or smallest) value within reach along a row; past the edge there is nothing.
    kernel void effects_spread_rows(device const float* source [[buffer(0)]],
                                    device float* result [[buffer(1)]],
                                    constant Spread& size [[buffer(9)]],
                                    uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.width || gid.y >= size.height) { return; }
        int reach = int(size.reach);
        int x = int(gid.x);
        float best = size.smallest == 1 ? 1.0 : 0.0;
        for (int offset = -reach; offset <= reach; ++offset) {
            int sample = x + offset;
            float value = (sample < 0 || sample >= int(size.width)) ? 0.0 : source[gid.y * size.width + uint(sample)];
            best = size.smallest == 1 ? min(best, value) : max(best, value);
        }
        result[gid.y * size.width + gid.x] = best;
    }

    kernel void effects_spread_columns(device const float* source [[buffer(0)]],
                                       device float* result [[buffer(1)]],
                                       constant Spread& size [[buffer(9)]],
                                       uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.width || gid.y >= size.height) { return; }
        int reach = int(size.reach);
        int y = int(gid.y);
        float best = size.smallest == 1 ? 1.0 : 0.0;
        for (int offset = -reach; offset <= reach; ++offset) {
            int sample = y + offset;
            float value = (sample < 0 || sample >= int(size.height)) ? 0.0 : source[uint(sample) * size.width + gid.x];
            best = size.smallest == 1 ? min(best, value) : max(best, value);
        }
        result[y * size.width + gid.x] = best;
    }

    // What the stroke covers: the difference between the shape and the reached-out (or pulled-in) shape.
    kernel void effects_ring(device const float* shape [[buffer(0)]],
                             device const float* moved [[buffer(1)]],
                             device float* result [[buffer(2)]],
                             constant Spread& size [[buffer(9)]],
                             uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.width || gid.y >= size.height) { return; }
        uint index = gid.y * size.width + gid.x;
        result[index] = clamp(size.smallest == 1 ? shape[index] - moved[index] : moved[index] - shape[index], 0.0, 1.0);
    }

    kernel void effects_shift(device const float* source [[buffer(0)]],
                              device float* result [[buffer(1)]],
                              constant Shift& shift [[buffer(9)]],
                              uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= shift.width || gid.y >= shift.height) { return; }
        float sx = float(gid.x) - shift.dx;
        float sy = float(gid.y) - shift.dy;
        float value = 0.0;
        if (sx >= 0.0 && sy >= 0.0 && sx <= float(shift.width - 1) && sy <= float(shift.height - 1)) {
            // Between pixels, so the shadow moves smoothly rather than in whole steps.
            uint x0 = uint(floor(sx)), y0 = uint(floor(sy));
            uint x1 = min(x0 + 1, shift.width - 1), y1 = min(y0 + 1, shift.height - 1);
            float fx = sx - float(x0), fy = sy - float(y0);
            float top = mix(source[y0 * shift.width + x0], source[y0 * shift.width + x1], fx);
            float bottom = mix(source[y1 * shift.width + x0], source[y1 * shift.width + x1], fx);
            value = mix(top, bottom, fy);
        }
        result[gid.y * shift.width + gid.x] = value;
    }

    kernel void effects_blur_rows(device const float* source [[buffer(0)]],
                                  device float* result [[buffer(1)]],
                                  constant Blur& blur [[buffer(9)]],
                                  uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= blur.width || gid.y >= blur.height) { return; }
        int radius = int(blur.radius);
        float total = 0.0, weightSum = 0.0;
        for (int offset = -radius; offset <= radius; ++offset) {
            float weight = exp(-float(offset * offset) / (2.0 * blur.sigma * blur.sigma));
            int sample = clamp(int(gid.x) + offset, 0, int(blur.width) - 1);
            total += weight * source[gid.y * blur.width + uint(sample)];
            weightSum += weight;
        }
        result[gid.y * blur.width + gid.x] = total / weightSum;
    }

    kernel void effects_blur_columns(device const float* source [[buffer(0)]],
                                     device float* result [[buffer(1)]],
                                     constant Blur& blur [[buffer(9)]],
                                     uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= blur.width || gid.y >= blur.height) { return; }
        int radius = int(blur.radius);
        float total = 0.0, weightSum = 0.0;
        for (int offset = -radius; offset <= radius; ++offset) {
            float weight = exp(-float(offset * offset) / (2.0 * blur.sigma * blur.sigma));
            int sample = clamp(int(gid.y) + offset, 0, int(blur.height) - 1);
            total += weight * source[uint(sample) * blur.width + gid.x];
            weightSum += weight;
        }
        result[gid.y * blur.width + gid.x] = total / weightSum;
    }

    // An inner shadow's coverage: what is outside the layer, softened, kept to the layer's own shape.
    kernel void effects_inside(device const float* shape [[buffer(0)]],
                               device const float* moved [[buffer(1)]],
                               device float* result [[buffer(2)]],
                               constant Spread& size [[buffer(9)]],
                               uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= size.width || gid.y >= size.height) { return; }
        uint index = gid.y * size.width + gid.x;
        result[index] = clamp(shape[index] * (1.0 - moved[index]), 0.0, 1.0);
    }

    // Shadow behind, outer glow over it, outside stroke over that, the layer's pixels over that, then a color overlay,
    // an inner glow, an inner shadow and an inside stroke on top.
    kernel void effects_compose(device const uchar4* pixels [[buffer(0)]],
                                device const float* ring [[buffer(1)]],
                                device const float* shadow [[buffer(2)]],
                                device uchar4* result [[buffer(3)]],
                                device const float* inner [[buffer(4)]],
                                device const float* shape [[buffer(5)]],
                                device const float* glow [[buffer(6)]],
                                device const float* innerGlow [[buffer(7)]],
                                constant Compose& settings [[buffer(9)]],
                                uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= settings.width || gid.y >= settings.height) { return; }
        uint index = gid.y * settings.width + gid.x;
        float3 color = float3(0.0);
        float alpha = 0.0;
        if (settings.flags.z == 1) {
            float coverage = clamp(shadow[index] * settings.shadowColor.w, 0.0, 1.0);
            color = settings.shadowColor.xyz * coverage;
            alpha = coverage;
        }
        if (settings.more.y == 1) {
            float glowCoverage = clamp(glow[index] * (1.0 - shape[index]) * settings.glowColor.w, 0.0, 1.0);
            color = settings.glowColor.xyz * glowCoverage + color * (1.0 - glowCoverage);
            alpha = glowCoverage + alpha * (1.0 - glowCoverage);
        }
        float strokeCoverage = settings.flags.x == 1 ? clamp(ring[index] * settings.strokeColor.w, 0.0, 1.0) : 0.0;
        if (settings.flags.x == 1 && settings.flags.y == 0) {
            color = settings.strokeColor.xyz * strokeCoverage + color * (1.0 - strokeCoverage);
            alpha = strokeCoverage + alpha * (1.0 - strokeCoverage);
        }
        float4 source = float4(pixels[index]) / 255.0;
        color = source.xyz + color * (1.0 - source.w);
        alpha = source.w + alpha * (1.0 - source.w);
        if (settings.more.x == 1) {
            float coverage = clamp(shape[index] * settings.overlayColor.w, 0.0, 1.0);
            color = settings.overlayColor.xyz * coverage + color * (1.0 - coverage);
            alpha = coverage + alpha * (1.0 - coverage);
        }
        if (settings.more.z == 1) {
            float coverage = clamp(innerGlow[index] * settings.innerGlowColor.w, 0.0, 1.0);
            color = settings.innerGlowColor.xyz * coverage + color * (1.0 - coverage);
            alpha = coverage + alpha * (1.0 - coverage);
        }
        if (settings.flags.w == 1) {
            float coverage = clamp(inner[index] * settings.innerColor.w, 0.0, 1.0);
            color = settings.innerColor.xyz * coverage + color * (1.0 - coverage);
            alpha = coverage + alpha * (1.0 - coverage);
        }
        if (settings.flags.x == 1 && settings.flags.y == 1) {
            color = settings.strokeColor.xyz * strokeCoverage + color * (1.0 - strokeCoverage);
            alpha = strokeCoverage + alpha * (1.0 - strokeCoverage);
        }
        result[index] = uchar4(uchar(clamp(color.x, 0.0, 1.0) * 255.0 + 0.5),
                               uchar(clamp(color.y, 0.0, 1.0) * 255.0 + 0.5),
                               uchar(clamp(color.z, 0.0, 1.0) * 255.0 + 0.5),
                               uchar(clamp(alpha, 0.0, 1.0) * 255.0 + 0.5));
    }
    """
}
