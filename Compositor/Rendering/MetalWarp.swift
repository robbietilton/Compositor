import CoreImage
import Metal

/// Smudge and Liquify's working copy on the GPU: each dab is `WarpStroke`'s CPU dab ported one for one, run where the
/// canvas draws from, so the stroke never copies the whole document per pointer move — it used to make a new image of
/// it and upload that, which on a large document cost far more than the dabs. The pixels come back to the CPU once,
/// when the stroke ends (or for a frame the Core Graphics canvas draws).
@MainActor final class MetalWarp {
    let width: Int
    let height: Int
    let texture: MTLTexture
    private let renderer: GPUCanvasRenderer
    /// Smudge: the color the brush carries, a (2r+1)² square, in 0…255.
    private var carried: MTLTexture?
    /// Liquify: the dab's area as it was before the dab, which the dab samples from.
    private var scratch: MTLTexture?
    private var buffer: MTLCommandBuffer?
    private var encoder: MTLComputeCommandEncoder?
    private var last: MTLCommandBuffer?

    init?(pixels: CGContext) {
        guard let renderer = GPUCanvasRenderer.shared, Self.pipelines != nil, let data = pixels.data else { return nil }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .rgba8Unorm, width: pixels.width,
                                                                  height: pixels.height, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .shared
        guard let texture = renderer.device.makeTexture(descriptor: descriptor) else { return nil }
        // Top-left rows, as the document's: a point's row is its y.
        texture.replace(region: MTLRegionMake2D(0, 0, pixels.width, pixels.height), mipmapLevel: 0,
                        withBytes: data, bytesPerRow: pixels.bytesPerRow)
        self.renderer = renderer
        self.texture = texture
        width = pixels.width
        height = pixels.height
    }

    /// The working copy for the canvas to draw, as it stands once the dabs sent so far have run.
    var image: CIImage? { CIImage(mtlTexture: texture, options: [.colorSpace: renderer.space]) }

    /// The working copy's pixels, back in `pixels` (the same size), once every dab has run.
    func read(into pixels: CGContext) {
        commit()
        last?.waitUntilCompleted()
        guard let data = pixels.data else { return }
        texture.getBytes(data, bytesPerRow: pixels.bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
    }

    private struct Dab {
        var center: SIMD2<Int32>
        var radius: Int32
        var size: SIMD2<Int32>
        /// Liquify: the corner and size of the area the dab samples from.
        var origin: SIMD2<Int32>
        var area: SIMD2<Int32>
        var inverseRadius: Float
        var hardness: Float
        var keep: Float
        var move: SIMD2<Float>
    }

    private func texture(_ current: MTLTexture?, side: Int, format: MTLPixelFormat) -> MTLTexture? {
        if let current, current.width >= side, current.height >= side { return current }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: format, width: side, height: side, mipmapped: false)
        descriptor.usage = [.shaderRead, .shaderWrite]
        descriptor.storageMode = .private
        return renderer.device.makeTexture(descriptor: descriptor)
    }

    private func dispatch(_ name: String, _ dab: Dab, textures: [MTLTexture], threads: Int) {
        guard let pipeline = Self.pipelines?[name] else { return }
        if encoder == nil {
            buffer = renderer.queue.makeCommandBuffer()
            encoder = buffer?.makeComputeCommandEncoder()
        }
        guard let encoder else { return }
        var dab = dab
        // Each dab works on what the one before it left.
        encoder.memoryBarrier(scope: .textures)
        encoder.setComputePipelineState(pipeline)
        for (index, texture) in textures.enumerated() { encoder.setTexture(texture, index: index) }
        encoder.setBytes(&dab, length: MemoryLayout<Dab>.stride, index: 0)
        let group = MTLSize(width: 16, height: 16, depth: 1)
        encoder.dispatchThreadgroups(MTLSize(width: (threads + 15) / 16, height: (threads + 15) / 16, depth: 1),
                                     threadsPerThreadgroup: group)
    }

    /// Sends the dabs encoded so far. The canvas draws on the same queue, after them.
    func commit() {
        encoder?.endEncoding()
        buffer?.commit()
        if let buffer { last = buffer }
        encoder = nil
        buffer = nil
    }

    func pickUp(at center: CGPoint, radius: Int) {
        let side = 2 * radius + 1
        guard let carried = texture(carried, side: side, format: .rgba32Float) else { return }
        self.carried = carried
        dispatch("warp_pick_up", Dab(center: SIMD2(Int32(center.x.rounded()), Int32(center.y.rounded())), radius: Int32(radius),
                                     size: SIMD2(Int32(width), Int32(height)), origin: .zero, area: .zero,
                                     inverseRadius: 0, hardness: 0, keep: 0, move: .zero),
                 textures: [texture, carried], threads: side)
    }

    func smudge(at center: CGPoint, radius: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        guard let carried else { return }
        dispatch("warp_smudge", Dab(center: SIMD2(Int32(center.x.rounded()), Int32(center.y.rounded())), radius: Int32(radius),
                                    size: SIMD2(Int32(width), Int32(height)), origin: .zero, area: .zero,
                                    inverseRadius: 1 / Float(diameter / 2), hardness: Float(hardness), keep: Float(strength), move: .zero),
                 textures: [texture, carried], threads: 2 * radius + 1)
    }

    func push(from a: CGPoint, to b: CGPoint, radius r: Int, diameter: CGFloat, hardness: CGFloat, strength: CGFloat) {
        let move = SIMD2<Float>(Float(b.x - a.x), Float(b.y - a.y)) * Float(strength)
        let margin = Int(ceil(max(abs(move.x), abs(move.y)))) + 2
        let cx = Int(b.x.rounded()), cy = Int(b.y.rounded())
        let x0 = max(0, cx - r - margin), x1 = min(width - 1, cx + r + margin)
        let y0 = max(0, cy - r - margin), y1 = min(height - 1, cy + r + margin)
        guard x0 <= x1, y0 <= y1 else { return }
        let cw = x1 - x0 + 1, ch = y1 - y0 + 1
        guard let scratch = texture(scratch, side: max(cw, ch), format: .rgba8Unorm) else { return }
        self.scratch = scratch
        let dab = Dab(center: SIMD2(Int32(cx), Int32(cy)), radius: Int32(r), size: SIMD2(Int32(width), Int32(height)),
                      origin: SIMD2(Int32(x0), Int32(y0)), area: SIMD2(Int32(cw), Int32(ch)),
                      inverseRadius: 1 / Float(diameter / 2), hardness: Float(hardness), keep: 0, move: move)
        dispatch("warp_copy", dab, textures: [texture, scratch], threads: max(cw, ch))
        dispatch("warp_push", dab, textures: [texture, scratch], threads: 2 * r + 1)
    }

    static let pipelines: [String: MTLComputePipelineState]? = {
        guard let device = MTLCreateSystemDefaultDevice(), let library = try? device.makeLibrary(source: source, options: nil)
        else { return nil }
        var result: [String: MTLComputePipelineState] = [:]
        for name in ["warp_pick_up", "warp_smudge", "warp_copy", "warp_push"] {
            guard let function = library.makeFunction(name: name),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            result[name] = pipeline
        }
        return result
    }()

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct Dab {
        int2 center; int radius; int2 size; int2 origin; int2 area;
        float inverseRadius; float hardness; float keep; float2 move;
    };

    // How much a dab moves pixels at a distance u (0 center, 1 rim) from its center.
    static inline float weight(float u, float hardness) {
        if (u >= 1.0f) return 0.0f;
        if (u <= hardness) return 1.0f;
        float t = (1.0f - u) / (1.0f - hardness);
        return t * t * (3.0f - 2.0f * t);
    }

    kernel void warp_pick_up(texture2d<float, access::read> canvas [[texture(0)]],
                             texture2d<float, access::write> carried [[texture(1)]],
                             constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int side = 2 * d.radius + 1;
        if (int(gid.x) >= side || int(gid.y) >= side) return;
        int2 p = d.center + int2(gid) - d.radius;
        bool inside = p.x >= 0 && p.y >= 0 && p.x < d.size.x && p.y < d.size.y;
        carried.write(inside ? canvas.read(uint2(p)) * 255.0f : float4(0.0f), gid);
    }

    kernel void warp_smudge(texture2d<float, access::read_write> canvas [[texture(0)]],
                            texture2d<float, access::read_write> carried [[texture(1)]],
                            constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int side = 2 * d.radius + 1;
        if (int(gid.x) >= side || int(gid.y) >= side) return;
        int2 offset = int2(gid) - d.radius, p = d.center + offset;
        if (p.x < 0 || p.y < 0 || p.x >= d.size.x || p.y >= d.size.y) return;
        float w = weight(sqrt(float(offset.x * offset.x + offset.y * offset.y)) * d.inverseRadius, d.hardness);
        if (w <= 0.0f) return;
        float4 under = canvas.read(uint2(p)) * 255.0f, held = carried.read(gid);
        float4 painted = under + (held - under) * w;
        canvas.write(clamp(round(painted), 0.0f, 255.0f) / 255.0f, uint2(p));
        // The brush picks up some of what it just left, more the weaker the smudge.
        carried.write(painted + (held - painted) * d.keep, gid);
    }

    kernel void warp_copy(texture2d<float, access::read> canvas [[texture(0)]],
                          texture2d<float, access::write> scratch [[texture(1)]],
                          constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        if (int(gid.x) >= d.area.x || int(gid.y) >= d.area.y) return;
        scratch.write(canvas.read(uint2(d.origin + int2(gid))), gid);
    }

    // Forward warp: pixels under the brush move with it, most at its center, fading to none at its rim.
    kernel void warp_push(texture2d<float, access::write> canvas [[texture(0)]],
                          texture2d<float, access::read> scratch [[texture(1)]],
                          constant Dab &d [[buffer(0)]], uint2 gid [[thread_position_in_grid]]) {
        int side = 2 * d.radius + 1;
        if (int(gid.x) >= side || int(gid.y) >= side) return;
        int2 offset = int2(gid) - d.radius, p = d.center + offset;
        int2 last = d.origin + d.area - 1;
        if (p.x < d.origin.x || p.y < d.origin.y || p.x > last.x || p.y > last.y) return;
        float w = weight(sqrt(float(offset.x * offset.x + offset.y * offset.y)) * d.inverseRadius, d.hardness);
        if (w <= 0.0f) return;
        // Bilinear sample of the old pixels, from behind the brush's travel.
        float sx = min(float(d.area.x - 1), max(0.0f, float(p.x - d.origin.x) - d.move.x * w));
        float sy = min(float(d.area.y - 1), max(0.0f, float(p.y - d.origin.y) - d.move.y * w));
        int ix = min(d.area.x - 2, int(sx)), iy = min(d.area.y - 2, int(sy));
        if (ix < 0 || iy < 0) return;
        float fx = sx - float(ix), fy = sy - float(iy);
        float4 s00 = scratch.read(uint2(ix, iy)) * 255.0f, s10 = scratch.read(uint2(ix + 1, iy)) * 255.0f;
        float4 s01 = scratch.read(uint2(ix, iy + 1)) * 255.0f, s11 = scratch.read(uint2(ix + 1, iy + 1)) * 255.0f;
        float4 top = s00 + (s10 - s00) * fx, bottom = s01 + (s11 - s01) * fx;
        canvas.write(clamp(round(top + (bottom - top) * fy), 0.0f, 255.0f) / 255.0f, uint2(p));
    }
    """
}
