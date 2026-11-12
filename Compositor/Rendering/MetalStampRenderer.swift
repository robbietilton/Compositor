import Foundation
import CoreGraphics
import CryptoKit
import Metal

/// Opt-in tile-local Metal stamp experiment. The production renderer remains the reference path.
final class MetalStampRenderer {
    static let shared: MetalStampRenderer? = MetalStampRenderer()

    struct Dab {
        let u0: Float
        let v0: Float
        let ux: Float
        let uy: Float
        let vx: Float
        let vy: Float
        let flow: Float
        let strength: Float
        let grainOrigin: SIMD4<Float>
        let grainTransform: SIMD4<Float>
        let grainEffects: SIMD4<Float>

        init(u0: Float, v0: Float, ux: Float, uy: Float, vx: Float, vy: Float,
             flow: Float = 1, strength: Float = 1, grain: [Double]? = nil) {
            self.u0 = u0
            self.v0 = v0
            self.ux = ux
            self.uy = uy
            self.vx = vx
            self.vy = vy
            self.flow = flow
            self.strength = strength
            if let grain, grain.count == 12 {
                grainOrigin = SIMD4(Float(grain[0] - floor(grain[0])), Float(grain[1] - floor(grain[1])), Float(grain[2]), Float(grain[3]))
                grainTransform = SIMD4(Float(grain[4]), Float(grain[5]), Float(grain[7]), Float(grain[8]))
                grainEffects = SIMD4(Float(grain[9]), Float(grain[6]), Float(grain[10]), Float(grain[11]))
            } else {
                grainOrigin = .zero
                grainTransform = .zero
                grainEffects = .zero
            }
        }

        var encoded: SIMD4<Float> { SIMD4(u0, v0, ux, vy) }
        var modifiers: SIMD4<Float> { SIMD4(uy, vx, flow, strength) }
        var grainParameters: [Double] {
            [Double(grainOrigin.x), Double(grainOrigin.y), Double(grainOrigin.z), Double(grainOrigin.w),
             Double(grainTransform.x), Double(grainTransform.y), Double(grainEffects.y), Double(grainTransform.z),
             Double(grainTransform.w), Double(grainEffects.x), Double(grainEffects.z), Double(grainEffects.w)]
        }
    }

    struct Result {
        let origin: SIMD2<Int32>
        let width: Int
        let height: Int
        let density: [Float]
        let cap: [Float]
        let edges: [Float]
        let wallMilliseconds: Double
        let executionMilliseconds: Double
        let readbackBytes: Int
    }

    struct TileInput {
        let width: Int
        let height: Int
        let documentOrigin: SIMD2<Int32>
        let density: [Float]
        let cap: [Float]
    }

    private struct Uniforms {
        var dimensions: SIMD4<UInt32>
        var originAndFlow: SIMD4<Float>
        var counts: SIMD4<UInt32>
        var dispatchRect: SIMD4<UInt32>
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var uploadedMasks: [String: MTLBuffer] = [:]
    private var maskOrder: [String] = []
    private let renderLock = NSLock()
    private var densityScratch: MTLBuffer?
    private var capScratch: MTLBuffer?
    private var edgeScratch: MTLBuffer?
    private var dabScratch: MTLBuffer?
    private(set) var scratchBufferAllocationCount = 0
    private var pooledScratchBytes = 0
    private static let maskCacheLimit = 16
    private static let pooledDabBufferLimit = 1 << 20
    var cachedMaskCount: Int { uploadedMasks.count }
    var cachedScratchBytes: Int { pooledScratchBytes }
    var deviceName: String { device.name }

    init?() {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.source, options: nil),
              let function = library.makeFunction(name: "bristlesBatch"),
              let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
        self.device = device
        self.queue = queue
        self.pipeline = pipeline
    }

    /// Accumulates ordered, tile-local mask dabs with the same shape and grain filters as BrushPixels.c.
    /// Wet-tip sampling, burnt-edge accumulation, and glaze modes share this ordered pass;
    /// dual shapes and pigment pickup remain on the CPU path.
    func render(tip: Data?, side: Int, width: Int, height: Int, origin: SIMD2<Int32>, dabs: [Dab],
                filtering: UInt32 = 0, initialDensity: [Float]? = nil, initialCap: [Float]? = nil,
                grain: Data? = nil, grainSide: Int = 0,
                initialEdges: [Float]? = nil, wetEdges: Float = 0, accumulateEdges: Bool = false,
                maximumMode: Bool = false, mode: Int32 = 0, hardness: Float = 1, region: CGRect? = nil) throws -> Result {
        renderLock.lock()
        defer { renderLock.unlock() }
        let wallStart = CFAbsoluteTimeGetCurrent()
        let tileBounds = CGRect(x: 0, y: 0, width: width, height: height)
        let region = region ?? tileBounds
        let dispatchRegion = region.integral.intersection(tileBounds)
        guard (tip == nil ? side == 0 : (1...256).contains(side) && tip?.count == side * side),
              (grain == nil ? grainSide == 0 : (1...256).contains(grainSide) && grain?.count == grainSide * grainSide), hardness.isFinite,
              (0...1).contains(hardness), wetEdges.isFinite, (0...1).contains(wetEdges), !dabs.isEmpty,
              (1...256).contains(width), (1...256).contains(height), (0...2).contains(filtering), (0...4).contains(mode),
              (1...250_000).contains(dabs.count),
              !region.isNull, !region.isEmpty, dispatchRegion == region,
              width.multipliedReportingOverflow(by: height).overflow == false,
              dabs.allSatisfy({ dab in
                  [dab.u0, dab.v0, dab.ux, dab.uy, dab.vx, dab.vy, dab.flow, dab.strength].allSatisfy(\.isFinite)
                      && (0...1).contains(dab.flow) && (0...1).contains(dab.strength)
                      && abs(dab.u0) < 1_000_000 && abs(dab.v0) < 1_000_000
              }) else {
            throw ExportError.render
        }
        let (pixelCount, overflow) = width.multipliedReportingOverflow(by: height)
        guard !overflow, pixelCount <= 65_536,
              initialDensity == nil || initialDensity?.count == pixelCount,
              initialCap == nil || initialCap?.count == pixelCount,
              initialEdges == nil || (accumulateEdges && initialEdges?.count == pixelCount),
              pixelCount > 0 else { throw ExportError.render }
        let packedDabs = dabs.flatMap { [$0.encoded, $0.modifiers, $0.grainOrigin, $0.grainTransform, $0.grainEffects] }
        let byteCount = pixelCount * MemoryLayout<Float>.stride
        let densityBuffer = try scratchBuffer(&densityScratch, byteCount: byteCount)
        if let initialDensity {
            initialDensity.withUnsafeBytes { _ = memcpy(densityBuffer.contents(), $0.baseAddress!, byteCount) }
        } else { memset(densityBuffer.contents(), 0, byteCount) }
        let capBuffer = try scratchBuffer(&capScratch, byteCount: byteCount)
        if let initialCap {
            initialCap.withUnsafeBytes { _ = memcpy(capBuffer.contents(), $0.baseAddress!, byteCount) }
        } else { memset(capBuffer.contents(), 0, byteCount) }
        let edgeBuffer: MTLBuffer?
        if accumulateEdges {
            let buffer = try scratchBuffer(&edgeScratch, byteCount: byteCount)
            if let initialEdges {
                initialEdges.withUnsafeBytes { _ = memcpy(buffer.contents(), $0.baseAddress!, byteCount) }
            } else { memset(buffer.contents(), 0, byteCount) }
            edgeBuffer = buffer
        } else { edgeBuffer = nil }
        let dabBuffer: MTLBuffer?
        let packedDabBytes = packedDabs.count * MemoryLayout<SIMD4<Float>>.stride
        if packedDabBytes <= Self.pooledDabBufferLimit {
            let buffer = try scratchBuffer(&dabScratch, byteCount: packedDabBytes)
            packedDabs.withUnsafeBytes { _ = memcpy(buffer.contents(), $0.baseAddress!, $0.count) }
            dabBuffer = buffer
        } else {
            dabBuffer = packedDabs.withUnsafeBytes { bytes in
                bytes.baseAddress.flatMap { device.makeBuffer(bytes: $0, length: bytes.count, options: .storageModeShared) }
            }
            guard dabBuffer != nil else { throw ExportError.render }
        }
        guard
              let tipBuffer = tip.map(maskBuffer) ?? device.makeBuffer(bytes: [UInt8](repeating: 0, count: 1), length: 1, options: .storageModeShared),
              let grainBuffer = grain.map(maskBuffer) ?? device.makeBuffer(bytes: [UInt8](repeating: 0, count: 1), length: 1, options: .storageModeShared),
              let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else {
            throw ExportError.render
        }
        var uniforms = Uniforms(dimensions: SIMD4(UInt32(width), UInt32(height), UInt32(side), filtering),
                                originAndFlow: SIMD4(Float(origin.x), Float(origin.y), hardness, wetEdges),
                                counts: SIMD4(UInt32(dabs.count), UInt32(maximumMode ? 1 : mode), UInt32(accumulateEdges ? 1 : 0), 0),
                                dispatchRect: SIMD4(UInt32(dispatchRegion.minX), UInt32(dispatchRegion.minY),
                                    UInt32(dispatchRegion.width), UInt32(dispatchRegion.height)))
        encoder.setComputePipelineState(pipeline)
        encoder.setBuffer(densityBuffer, offset: 0, index: 0)
        encoder.setBuffer(tipBuffer, offset: 0, index: 1)
        encoder.setBuffer(dabBuffer, offset: 0, index: 2)
        encoder.setBuffer(capBuffer, offset: 0, index: 5)
        encoder.setBuffer(grainBuffer, offset: 0, index: 6)
        encoder.setBuffer(edgeBuffer, offset: 0, index: 8)
        var grainUniforms = SIMD4(UInt32(grainSide), 0, 0, 0)
        encoder.setBytes(&grainUniforms, length: MemoryLayout<SIMD4<UInt32>>.stride, index: 7)
        encoder.setBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 3)
        encoder.dispatchThreads(MTLSize(width: Int(uniforms.dispatchRect.z), height: Int(uniforms.dispatchRect.w), depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
        let start = CFAbsoluteTimeGetCurrent()
        command.commit()
        command.waitUntilCompleted()
        let executionMilliseconds = (CFAbsoluteTimeGetCurrent() - start) * 1000
        guard command.status == .completed else { throw command.error ?? ExportError.render }
        let values = Array(UnsafeBufferPointer(start: densityBuffer.contents().assumingMemoryBound(to: Float.self), count: pixelCount))
        return Result(origin: origin, width: width, height: height,
                      density: values,
                      cap: Array(UnsafeBufferPointer(start: capBuffer.contents().assumingMemoryBound(to: Float.self), count: pixelCount)),
                      edges: edgeBuffer.map { Array(UnsafeBufferPointer(start: $0.contents().assumingMemoryBound(to: Float.self), count: pixelCount)) } ?? [],
                      wallMilliseconds: (CFAbsoluteTimeGetCurrent() - wallStart) * 1000,
                      executionMilliseconds: executionMilliseconds,
                      readbackBytes: pixelCount * MemoryLayout<Float>.stride * (2 + (accumulateEdges ? 1 : 0)))
    }

    /// The renderer waits for completion before returning, so this private scratch storage is never in flight.
    private func scratchBuffer(_ slot: inout MTLBuffer?, byteCount: Int) throws -> MTLBuffer {
        guard byteCount > 0 else { throw ExportError.render }
        if let buffer = slot, buffer.length >= byteCount { return buffer }
        guard let buffer = device.makeBuffer(length: byteCount, options: .storageModeShared) else { throw ExportError.render }
        pooledScratchBytes += buffer.length - (slot?.length ?? 0)
        slot = buffer
        scratchBufferAllocationCount += 1
        return buffer
    }

    private func maskBuffer(_ mask: Data) -> MTLBuffer? {
        let key = SHA256.hash(data: mask).map { String(format: "%02x", $0) }.joined()
        if let buffer = uploadedMasks[key] { return buffer }
        guard let buffer: MTLBuffer = mask.withUnsafeBytes({ (bytes: UnsafeRawBufferPointer) -> MTLBuffer? in
            guard let base = bytes.baseAddress else { return nil }
            return device.makeBuffer(bytes: base, length: bytes.count, options: .storageModeShared)
        }) else { return nil }
        uploadedMasks[key] = buffer
        maskOrder.append(key)
        if maskOrder.count > Self.maskCacheLimit {
            uploadedMasks.removeValue(forKey: maskOrder.removeFirst())
        }
        return buffer
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct BristlesUniforms {
        uint4 dimensions; // output width, height, tip side, filtering
        float4 originAndFlow; // tile origin x/y, unused
        uint4 counts; // dab count
        uint4 dispatchRect; // tile-local dispatch origin and dimensions
    };

    struct GrainDab {
        float4 shape;
        float4 modifiers;
        float4 grainOrigin;
        float4 grainTransform;
        float4 grainEffects;
    };

    static float grainPixel(device const uchar *grain, uint side, int x, int y) {
        int n = int(side);
        int wrappedX = (x % n + n) % n, wrappedY = (y % n + n) % n;
        return float(grain[uint(wrappedY) * side + uint(wrappedX)]) / 255.0f;
    }

    static float grainSample(device const uchar *grain, uint side, float u, float v, uint filtering) {
        float x = (u - floor(u)) * float(side), y = (v - floor(v)) * float(side);
        int ix = int(floor(x)), iy = int(floor(y));
        if (filtering == 0) return grainPixel(grain, side, ix, iy);
        float fx = x - float(ix), fy = y - float(iy);
        return (1-fy) * ((1-fx)*grainPixel(grain,side,ix,iy)+fx*grainPixel(grain,side,ix+1,iy))
            + fy * ((1-fx)*grainPixel(grain,side,ix,iy+1)+fx*grainPixel(grain,side,ix+1,iy+1));
    }

    static float tipSample(device const uchar *tip, uint side, float2 uv, uint filtering,
                           float hardness, float4 dab, float4 modifier) {
        if (side == 0) {
            float radius = length(uv);
            if (hardness < 1.0f) {
                float t = max(0.0f, (radius - hardness) / (1.0f - hardness));
                const float edge = exp(-2.5f);
                return t < 1.0f ? max(0.0f, (exp(-2.5f * t * t) - edge) / (1.0f - edge)) : 0.0f;
            }
            if (filtering == 0) return radius <= 1.0f ? 1.0f : 0.0f;
            float aa = max(0.000001f, (abs(uv.x * dab.z + uv.y * modifier.y)
                + abs(uv.x * modifier.x + uv.y * dab.w)) / max(radius, 0.000001f));
            return clamp((1.0f - radius) / aa + 0.5f, 0.0f, 1.0f);
        }
        if (any(abs(uv) > 1.0f + 2.0f / float(side))) return 0.0f;
        float2 position = (uv + 1.0f) * (float(side) * 0.5f) - 0.5f;
        if (filtering == 0) {
            int2 p = int2(floor(position + 0.5f));
            return all(p >= 0) && all(p < int2(side)) ? float(tip[uint(p.y) * side + uint(p.x)]) / 255.0f : 0.0f;
        }
        int2 p = int2(floor(position));
        float2 f = position - float2(p);
        float value = 0.0f;
        for (int dy = 0; dy <= 1; ++dy) for (int dx = 0; dx <= 1; ++dx) {
            int2 q = p + int2(dx, dy);
            float texel = all(q >= 0) && all(q < int2(side)) ? float(tip[uint(q.y) * side + uint(q.x)]) / 255.0f : 0.0f;
            value += (dx ? f.x : 1.0f - f.x) * (dy ? f.y : 1.0f - f.y) * texel;
        }
        return value;
    }

    kernel void bristlesBatch(device float *density [[buffer(0)]],
                              device const uchar *tip [[buffer(1)]],
                              device const GrainDab *dabs [[buffer(2)]],
                              constant BristlesUniforms &u [[buffer(3)]],
                              device float *caps [[buffer(5)]],
                              device const uchar *grain [[buffer(6)]],
                              constant uint4 &grainUniforms [[buffer(7)]],
                              device float *edges [[buffer(8)]],
                              uint2 dispatchPixel [[thread_position_in_grid]]) {
        if (dispatchPixel.x >= u.dispatchRect.z || dispatchPixel.y >= u.dispatchRect.w) return;
        const uint2 pixel = dispatchPixel + u.dispatchRect.xy;
        const uint side = u.dimensions.z;
        const uint outputIndex = pixel.y * u.dimensions.x + pixel.x;
        float accumulated = density[outputIndex];
        float cap = caps[outputIndex];
        for (uint i = 0; i < u.counts.x; ++i) {
            const GrainDab item = dabs[i];
            const float4 dab = item.shape;
            const float4 modifier = item.modifiers;
            const float2 uv = float2(dab.x + float(pixel.x) * dab.z + float(pixel.y) * modifier.x,
                                     dab.y + float(pixel.x) * modifier.y + float(pixel.y) * dab.w);
            float coverage = 0;
            const int samples = u.dimensions.w == 2 ? 4 : 1;
            for (int sample = 0; sample < samples; ++sample) {
                float2 sampleUV = uv;
                if (samples == 4) {
                    float sx = (sample & 1) ? 1.0f : -1.0f;
                    float sy = (sample & 2) ? 1.0f : -1.0f;
                    sampleUV += 0.25f * float2(sx * dab.z + sy * modifier.x,
                                               sx * modifier.y + sy * dab.w);
                }
                uint filter = u.dimensions.w == 0 ? 0 : 1;
                float sampleCoverage = tipSample(tip, side, sampleUV, filter, u.originAndFlow.z, dab, modifier);
                if (u.originAndFlow.w > 0.0f) {
                    float spread = 0.36f * u.originAndFlow.w;
                    // Match the CPU renderer's normalized five-tap watercolor filter.
                    float blurred = sampleCoverage * 4.0f;
                    blurred += tipSample(tip, side, sampleUV + float2(spread, 0), filter, u.originAndFlow.z, dab, modifier)
                        + tipSample(tip, side, sampleUV - float2(spread, 0), filter, u.originAndFlow.z, dab, modifier)
                        + tipSample(tip, side, sampleUV + float2(0, spread), filter, u.originAndFlow.z, dab, modifier)
                        + tipSample(tip, side, sampleUV - float2(0, spread), filter, u.originAndFlow.z, dab, modifier);
                    sampleCoverage = sampleCoverage * (1.0f - u.originAndFlow.w) + blurred * (u.originAndFlow.w / 8.0f);
                }
                coverage += sampleCoverage / float(samples);
            }
            if (coverage > 0) {
                float capStrength = modifier.w;
                if (grainUniforms.x > 0) {
                    float gu = item.grainOrigin.x + float(pixel.x) * item.grainOrigin.z + float(pixel.y) * item.grainOrigin.w;
                    float gv = item.grainOrigin.y + float(pixel.x) * item.grainTransform.x + float(pixel.y) * item.grainTransform.y;
                    float texture = grainSample(grain, grainUniforms.x, gu, gv, uint(max(0.0f, item.grainEffects.z)));
                    if (item.grainEffects.z == 2.0f) {
                        texture = 0;
                        for (int k = 0; k < 4; ++k) {
                            texture += 0.25f * grainSample(grain, grainUniforms.x,
                                gu + 0.25f * ((k & 1 ? 1 : -1) * item.grainOrigin.z + (k & 2 ? 1 : -1) * item.grainOrigin.w),
                                gv + 0.25f * ((k & 1 ? 1 : -1) * item.grainTransform.x + (k & 2 ? 1 : -1) * item.grainTransform.y), 1);
                        }
                    }
                    texture = clamp((texture - 0.5f) * (item.grainTransform.w >= 0 ? 1 + 3 * item.grainTransform.w : 1 + item.grainTransform.w)
                        + 0.5f + item.grainTransform.z, 0.0f, 1.0f);
                    float factor = item.grainEffects.x == 1.0f ? (1 + texture) * 0.5f
                        : item.grainEffects.x == 2.0f ? min(1.0f, 2 * texture)
                        : item.grainEffects.x == 3.0f ? 1 - texture : texture;
                    float grainCoverage = 1 - item.grainEffects.y + item.grainEffects.y * factor;
                    coverage *= grainCoverage;
                    if (item.grainEffects.w == 1.0f) capStrength *= grainCoverage;
                }
                if (coverage <= 0) continue;
                float gain = u.counts.y == 1 ? 0.35f : u.counts.y == 2 ? 0.5f
                    : u.counts.y == 3 ? 1.5f : u.counts.y == 4 ? 3.0f : 1.0f;
                float inkCoverage = modifier.z * coverage;
                float ink = -log(1.0f - min(0.999999f, inkCoverage)) * gain;
                accumulated = u.counts.y == 1 ? max(accumulated, ink) : accumulated + ink;
                cap = max(cap, capStrength);
                if (u.counts.z != 0) edges[outputIndex] = min(32.0f, edges[outputIndex] + modifier.z * 7.0f * coverage * (1.0f - coverage));
            }
        }
        density[outputIndex] = min(32.0f, accumulated);
        caps[outputIndex] = cap;
    }
    """
}
