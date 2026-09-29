import CoreImage
import Metal

/// Add Noise and Grain on the GPU canvas: `NoisePixels.c`'s noise and `adjust_grain`, ported to Metal with the same
/// hashes, so the pattern is the one the CPU makes.
///
/// Both stay with the document as the canvas pans: noise is a value per frame pixel counted from the document's
/// corner (one per document pixel at 100%, as in export), and grain's size is in document pixels.
nonisolated enum GPUNoise {
    static func addNoise(to image: CIImage, mapping: CGAffineTransform, amount: Float, gaussian: Bool, monochromatic: Bool,
                         seed: UInt32) -> CIImage? {
        var parameters = NoiseParameters(amount: amount, gaussian: gaussian ? 1 : 0, monochromatic: monochromatic ? 1 : 0, seed: seed,
                                         corner: SIMD2(Int32(floor(-mapping.tx)), Int32(floor(-mapping.ty))))
        return run("add_noise", on: image, parameters: Data(bytes: &parameters, count: MemoryLayout<NoiseParameters>.stride))
    }

    static func addGrain(to image: CIImage, grain: GrainSettings, scale: CGFloat, mapping: CGAffineTransform) -> CIImage? {
        guard grain.amount > 0, scale > 0 else { return image }
        // A frame pixel's center, in document pixels, is its position less the mapping's offset, over the scale.
        var parameters = GrainParameters(
            strength: Float(min(1, grain.amount / 100)) * 0.35 * 255,
            roughness: Float(min(1, max(0, grain.roughness / 100))),
            size: Float(max(grain.size, 0.01)), detailSize: Float(max(0.5, grain.size * 0.35)),
            origin: SIMD2(Float(-mapping.tx / scale), Float(-mapping.ty / scale)), unitsPerPixel: Float(1 / scale),
            seed: grain.seed)
        return run("add_grain", on: image, parameters: Data(bytes: &parameters, count: MemoryLayout<GrainParameters>.stride))
    }

    private struct NoiseParameters {
        var amount: Float
        var gaussian: UInt32
        var monochromatic: UInt32
        var seed: UInt32
        /// Frame pixels to pixels counted from the document's corner.
        var corner: SIMD2<Int32>
    }
    private struct GrainParameters {
        var strength: Float
        var roughness: Float
        var size: Float
        var detailSize: Float
        var origin: SIMD2<Float>
        var unitsPerPixel: Float
        var seed: UInt32
    }

    private static func run(_ kernel: String, on image: CIImage, parameters: Data) -> CIImage? {
        let extent = image.extent
        guard !extent.isInfinite, !extent.isEmpty, pipelines != nil else { return nil }
        return try? NoiseKernel.apply(withExtent: extent.integral, inputs: [image],
                                      arguments: ["kernel": kernel, "parameters": parameters])
    }

    static let pipelines: [String: MTLComputePipelineState]? = {
        guard let device = MTLCreateSystemDefaultDevice(), let library = try? device.makeLibrary(source: source, options: nil)
        else { return nil }
        var result: [String: MTLComputePipelineState] = [:]
        for name in ["add_noise", "add_grain"] {
            guard let function = library.makeFunction(name: name),
                  let pipeline = try? device.makeComputePipelineState(function: function) else { return nil }
            result[name] = pipeline
        }
        return result
    }()

    /// Runs one of the kernels over the region Core Image asks for. Each pixel's own position in the frame picks its noise.
    private final class NoiseKernel: CIImageProcessorKernel {
        override class var outputFormat: CIFormat { .RGBAh }
        override class func formatForInput(at input: Int32) -> CIFormat { .RGBAh }
        override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

        override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                    output: CIImageProcessorOutput) throws {
            guard let input = inputs?.first, let source = input.metalTexture, let target = output.metalTexture,
                  let buffer = output.metalCommandBuffer, let name = arguments?["kernel"] as? String,
                  var parameters = arguments?["parameters"] as? Data, let pipeline = GPUNoise.pipelines?[name],
                  let encoder = buffer.makeComputeCommandEncoder() else { throw ExportError.render }
            // The textures hold their region top row first: the output's first row is its region's last y. Where that
            // pixel sits in the frame, and how far into the input its row and column are.
            var place = SIMD4<Int32>(Int32(output.region.minX), Int32(output.region.maxY - 1),
                                     Int32(output.region.minX - input.region.minX), Int32(input.region.maxY - output.region.maxY))
            encoder.setComputePipelineState(pipeline)
            encoder.setTexture(source, index: 0)
            encoder.setTexture(target, index: 1)
            parameters.withUnsafeMutableBytes { encoder.setBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.setBytes(&place, length: MemoryLayout<SIMD4<Int32>>.stride, index: 1)
            let size = MTLSize(width: 16, height: 16, depth: 1)
            encoder.dispatchThreadgroups(MTLSize(width: (target.width + 15) / 16, height: (target.height + 15) / 16, depth: 1),
                                         threadsPerThreadgroup: size)
            encoder.endEncoding()
        }
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct NoiseParameters { float amount; uint gaussian; uint monochromatic; uint seed; int2 corner; };
    struct GrainParameters { float strength; float roughness; float size; float detailSize; float2 origin; float unitsPerPixel; uint seed; };

    static inline uint mix32(uint x) {
        x ^= x >> 16; x *= 0x7feb352du;
        x ^= x >> 15; x *= 0x846ca68bu;
        x ^= x >> 16;
        return x;
    }
    static inline float unit(uint key) { return float(mix32(key) >> 8) * (1.0f / 16777216.0f); }

    kernel void add_noise(texture2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::write> target [[texture(1)]],
                          constant NoiseParameters &p [[buffer(0)]], constant int4 &place [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
        float4 color = source.read(uint2(int2(gid) + place.zw));
        float alpha = color.a * 255.0f;
        if (alpha <= 0.0f) { target.write(color, gid); return; }
        uint px = uint(place.x + int(gid.x) + p.corner.x), py = uint(place.y - int(gid.y) + p.corner.y);
        uint base = mix32(p.seed ^ mix32(px * 0x9e3779b9u ^ mix32(py * 0x85ebca6bu)));
        float spread = p.amount / 100.0f * 127.5f;
        float3 result;
        for (int c = 0; c < 3; ++c) {
            uint key = p.monochromatic ? base : base + uint(c) * 0x9e3779b9u;
            float n;
            if (p.gaussian) {
                float u1 = unit(key), u2 = unit(key ^ 0x68e31da4u);
                n = sqrt(-2.0f * log(1.0f - u1)) * cos(6.2831853f * u2) * spread * (2.0f / 3.0f);
            } else {
                n = (unit(key) * 2.0f - 1.0f) * spread;
            }
            float value = clamp(color[c] * 255.0f / color.a + n, 0.0f, 255.0f);
            result[c] = value / 255.0f * color.a;
        }
        target.write(float4(result, color.a), gid);
    }

    static inline float lattice(int ix, int iy, uint seed) {
        uint h = mix32(uint(ix) * 0x9E3779B1u ^ mix32(uint(iy) * 0x85EBCA77u ^ seed));
        return float(h & 0xFFFFu) / 65535.0f + float(h >> 16) / 65535.0f - 1.0f;
    }
    static inline float grain_field(float u, float v, float scale, uint seed) {
        float cellX = floor(u / scale), cellY = floor(v / scale);
        float tx = u / scale - cellX, ty = v / scale - cellY;
        tx = tx * tx * (3.0f - 2.0f * tx);
        ty = ty * ty * (3.0f - 2.0f * ty);
        int ix = int(cellX), iy = int(cellY);
        float n00 = lattice(ix, iy, seed), n10 = lattice(ix + 1, iy, seed);
        float n01 = lattice(ix, iy + 1, seed), n11 = lattice(ix + 1, iy + 1, seed);
        float top = n00 + (n10 - n00) * tx, bottom = n01 + (n11 - n01) * tx;
        return (top + (bottom - top) * ty) * 1.6f;
    }

    kernel void add_grain(texture2d<float, access::read> source [[texture(0)]],
                          texture2d<float, access::write> target [[texture(1)]],
                          constant GrainParameters &p [[buffer(0)]], constant int4 &place [[buffer(1)]],
                          uint2 gid [[thread_position_in_grid]]) {
        if (gid.x >= target.get_width() || gid.y >= target.get_height()) return;
        float4 color = source.read(uint2(int2(gid) + place.zw));
        if (color.a <= 0.0f) { target.write(color, gid); return; }
        float u = p.origin.x + (float(place.x + int(gid.x)) + 0.5f) * p.unitsPerPixel;
        float v = p.origin.y + (float(place.y - int(gid.y)) + 0.5f) * p.unitsPerPixel;
        float smooth = grain_field(u, v, p.size, p.seed);
        float fine = grain_field(u, v, p.detailSize, mix32(p.seed ^ 0xA511E9B3u));
        float noise = smooth + (fine - smooth) * p.roughness;
        float3 rgb = color.rgb / color.a * 255.0f;
        float level = min(1.0f, (0.2126f * rgb.r + 0.7152f * rgb.g + 0.0722f * rgb.b) / 255.0f);
        // Film grain shows most in the midtones.
        float delta = noise * p.strength * (0.4f + 2.4f * level * (1.0f - level));
        target.write(float4(clamp(rgb + delta, 0.0f, 255.0f) / 255.0f * color.a, color.a), gid);
    }
    """
}
