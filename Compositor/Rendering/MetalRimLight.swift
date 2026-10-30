import CoreGraphics
import CoreImage
import Metal
import simd

/// Rim Light's lighting on the GPU (see `RimLighting`): at each pixel, how far in from the subject's edge it is, the
/// rounded surface's normal there with the photo's detail pressed in, and the light's share of it; past the edge, the
/// loose strands that stand out from the backdrop. Then all of it laid over the photo. Run inside a Core Image graph,
/// as `MetalFinishing` is.
nonisolated final class MetalRimLight: @unchecked Sendable {
    static let shared: MetalRimLight? = try? MetalRimLight()
    let pipeline: MTLComputePipelineState
    let combine: MTLComputePipelineState

    struct Parameters {
        /// The direction toward the light (x right, y up, z toward the camera), and its color times its strength, in
        /// linear light.
        var direction: SIMD4<Float> = .zero
        var color: SIMD4<Float> = .zero
        /// Where each input's texels sit against the output's: two inputs to a vector.
        var offsets: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero, .zero)
        /// How far in the light reaches and the outline's blur that measures it, in pixels, and the detail's height per
        /// unit of brightness.
        var width: Float = 1
        var reach: Float = 1
        var detailScale: Float = 0
        /// How the light ends on the inside, 0–1: 0 tails off softly from the edge, 1 holds it and ends it at `width`.
        var choke: Float = 0
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ExportError.render }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "rimLight"), let combine = library.makeFunction(name: "rimCombine")
        else { throw ExportError.render }
        pipeline = try device.makeComputePipelineState(function: function)
        self.combine = try device.makeComputePipelineState(function: combine)
    }

    /// The light `light` adds over `image`, alone (its alpha clear, to be added): `coverage` where the subject is,
    /// `outline` its hard outline blurred `reach` pixels, `fine` and `coarse` the photo's gray lightly and more blurred,
    /// `backdrop` how far each pixel differs from the backdrop behind it, `busy` how much that backdrop varies there
    /// (its colors' variance), and `near` the outline blurred wide, which says how close to the subject a pixel is and
    /// which way it lies.
    static func light(_ image: CIImage, coverage: CIImage, outline: CIImage, fine: CIImage, coarse: CIImage, backdrop: CIImage,
                      busy: CIImage, near: CIImage, width: CGFloat, reach: CGFloat, side: CGFloat, light: RimLight) throws -> CIImage {
        guard shared != nil else { throw ExportError.render }
        var parameters = Parameters()
        parameters.width = Float(width)
        parameters.reach = Float(reach)
        parameters.detailScale = Float(side / 250)
        parameters.choke = Float(light.choke / 100)
        let angle = light.angle * .pi / 180
        // From a little behind the subject, so it reaches only what turns away from the camera.
        parameters.direction = SIMD4(simd_normalize(SIMD3<Float>(Float(cos(angle)), Float(sin(angle)), -0.2)), 0)
        func linear(_ value: Double) -> Float { Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)) }
        let strength = Float(light.strength / 100 * RimLighting.fullStrength)
        parameters.color = SIMD4(linear(light.color.red) * strength, linear(light.color.green) * strength,
                                 linear(light.color.blue) * strength, 0)
        return try RimLightKernel.apply(withExtent: image.extent,
                                        inputs: [image, coverage, outline, fine, coarse, backdrop, near, busy],
                                        arguments: ["parameters": withUnsafeBytes(of: parameters) { Data($0) }])
    }

    /// `light` over `image` the way light builds up on a lit surface: a little adds almost as it is, a lot rolls off
    /// into the light's own color and white instead of clipping.
    static func combined(_ image: CIImage, light: CIImage) throws -> CIImage {
        guard shared != nil else { throw ExportError.render }
        return try RimLightKernel.apply(withExtent: image.extent, inputs: [image, light],
                                        arguments: ["parameters": withUnsafeBytes(of: Parameters()) { Data($0) }])
    }

    // Compiled at launch by the system's Metal compiler, as the brush's is.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    float4 direction;
    float4 color;
    float4 offsets[4];
    float width;
    float reach;
    float detailScale;
    float choke;
};

int2 offsetOf(constant Parameters &p, int input) {
    float4 pair = p.offsets[input / 2];
    return int2((input % 2 == 0) ? pair.xy : pair.zw);
}

float4 texel(texture2d<float, access::read> t, int2 at) {
    at = clamp(at, int2(0), int2(t.get_width() - 1, t.get_height() - 1));
    return t.read(uint2(at));
}

float readAt(texture2d<float, access::read> t, int2 at) { return texel(t, at).r; }

// Which way is inwards in a blurred outline, rows running down; zero where it's flat.
float2 inwardsIn(texture2d<float, access::read> t, int2 at) {
    float2 d = float2(readAt(t, at + int2(1, 0)) - readAt(t, at + int2(-1, 0)),
                      readAt(t, at + int2(0, -1)) - readAt(t, at + int2(0, 1)));
    return length(d) > 1e-6 ? normalize(d) : float2(0);
}

// The inverse of the error function (Giles's approximation), for how far into a blurred edge a level lies.
float inverseError(float x) {
    float w = -log((1.0 - x) * (1.0 + x)), p;
    if (w < 5.0) {
        w -= 2.5;
        p = 2.81022636e-08; p = 3.43273939e-07 + p * w; p = -3.5233877e-06 + p * w; p = -4.39150654e-06 + p * w;
        p = 0.00021858087 + p * w; p = -0.00125372503 + p * w; p = -0.00417768164 + p * w; p = 0.246640727 + p * w;
        p = 1.50140941 + p * w;
    } else {
        w = sqrt(w) - 3.0;
        p = -0.000200214257; p = 0.000100950558 + p * w; p = 0.00134934322 + p * w; p = -0.00367342844 + p * w;
        p = 0.00573950773 + p * w; p = -0.0076224613 + p * w; p = 0.00943887047 + p * w; p = 1.00167406 + p * w;
        p = 2.83297682 + p * w;
    }
    return p * x;
}

kernel void rimLight(texture2d<float, access::read> image [[texture(0)]],
                     texture2d<float, access::read> coverage [[texture(1)]],
                     texture2d<float, access::read> outline [[texture(2)]],
                     texture2d<float, access::read> fine [[texture(3)]],
                     texture2d<float, access::read> coarse [[texture(4)]],
                     texture2d<float, access::read> backdrop [[texture(5)]],
                     texture2d<float, access::read> near [[texture(6)]],
                     texture2d<float, access::read> busy [[texture(7)]],
                     texture2d<float, access::write> result [[texture(8)]],
                     constant Parameters &p [[buffer(0)]],
                     uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    int2 here = int2(pixel);
    int2 atImage = here + offsetOf(p, 0), atCoverage = here + offsetOf(p, 1), atOutline = here + offsetOf(p, 2);
    int2 atFine = here + offsetOf(p, 3), atCoarse = here + offsetOf(p, 4), atBackdrop = here + offsetOf(p, 5);
    int2 atNear = here + offsetOf(p, 6), atBusy = here + offsetOf(p, 7);
    float covered = readAt(coverage, atCoverage), closeness = readAt(near, atNear);
    if (covered <= 0.002 && closeness <= 0.002) { result.write(float4(0), pixel); return; }
    float4 color = texel(image, atImage);
    float3 albedo = color.a > 0 ? max(float3(0), color.rgb / color.a) : float3(0);
    float3 tint = p.color.rgb * (albedo * 0.7 + 0.45);

    // How far in from the edge: a hard edge blurred by `reach` is at half where the edge is, and its level tells
    // the distance from it.
    float level = clamp(readAt(outline, atOutline), 0.001, 0.999);
    float depth = p.reach * sqrt(2.0) * inverseError(2.0 * level - 1.0);
    // The edge's surface faces mostly sideways, outwards, which decides which edges face the light.
    float2 inwards = inwardsIn(outline, atOutline);
    float2 bumps = float2((readAt(fine, atFine + int2(1, 0)) - readAt(coarse, atCoarse + int2(1, 0)))
                              - (readAt(fine, atFine + int2(-1, 0)) - readAt(coarse, atCoarse + int2(-1, 0))),
                          (readAt(fine, atFine + int2(0, -1)) - readAt(coarse, atCoarse + int2(0, -1)))
                              - (readAt(fine, atFine + int2(0, 1)) - readAt(coarse, atCoarse + int2(0, 1)))) / 2.0;
    float3 surface = normalize(float3(-inwards * 2.75 - bumps * p.detailScale, 1.0));
    float lit = pow(max(0.0, dot(surface, p.direction.xyz)), 1.6);
    // How far in it reaches: at Choke 0 it tails off softly with no end, as light does; more holds it bright and ends
    // it crisply at `width`.
    float t = max(depth, 0.0) / p.width;
    float held = 1.0 - smoothstep(max(0.0, (p.choke - 0.3) / 0.7) * 0.95, 1.0, t);
    float tail = exp(-2.2 * t);
    // The distance is only told out to twice `width`: the tail is let go to nothing before then.
    float reaches = (p.choke < 0.3 ? mix(tail, held, p.choke / 0.3) : held) * (1.0 - smoothstep(1.5, 1.9, t));
    // Strands and edges brighter than around them catch more of it.
    float texture = readAt(fine, atFine) - readAt(coarse, atCoarse);
    float catches = clamp(1.0 + texture * 6.0, 0.3, 1.8);
    float inside = smoothstep(-1.5, 1.5, depth);
    float3 added = tint * lit * reaches * catches * covered * inside;

    // Past the edge, loose strands: whatever near the subject stands out from the backdrop behind it there by more than
    // that backdrop varies on its own, which a smooth backdrop's grain doesn't and a busy one's rocks or crowd don't
    // either. Thin, they're all edge, lit by how they face the light from the subject.
    float3 apart = texel(backdrop, atBackdrop).rgb, spread = texel(busy, atBusy).rgb;
    float differs = all(isfinite(apart)) ? max(apart.r, max(apart.g, apart.b)) : 0.0;
    float varies = all(isfinite(spread)) ? sqrt(max(0.0, max(spread.r, max(spread.g, spread.b)))) : 1.0;
    float strand = clamp((differs - 0.03 - 2.5 * varies) / 0.1, 0.0, 1.0) * smoothstep(0.0, 0.1, closeness) * (1.0 - inside);
    if (strand > 0) {
        float2 away = inwardsIn(near, atNear);
        float faces = pow(max(0.0, dot(normalize(float3(-away * 2.75, 1.0)), p.direction.xyz)), 1.6);
        added += tint * faces * strand;
    }
    result.write(float4(added * color.a, 0), pixel);
}

// The lights over the photo: each channel's light first eased so a lot of it approaches 1 rather than passing it, then
// screened over, so a bright edge rolls off into the light's color and white instead of clipping.
kernel void rimCombine(texture2d<float, access::read> image [[texture(0)]],
                       texture2d<float, access::read> light [[texture(1)]],
                       texture2d<float, access::write> result [[texture(2)]],
                       constant Parameters &p [[buffer(0)]],
                       uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    int2 here = int2(pixel);
    float4 color = texel(image, here + offsetOf(p, 0));
    float3 added = max(float3(0), texel(light, here + offsetOf(p, 1)).rgb);
    if (color.a <= 0) { result.write(color, pixel); return; }
    float3 base = clamp(color.rgb / color.a, 0.0, 1.0);
    float3 eased = 1.0 - exp(-added);
    result.write(float4((1.0 - (1.0 - base) * (1.0 - eased)) * color.a, color.a), pixel);
}
"""
}

/// Runs `MetalRimLight` inside a Core Image graph: its lighting, with eight inputs, or laying it over the photo, with
/// two. Inputs are read a texel to either side, for the normals.
final class RimLightKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        outputRect.insetBy(dx: -1, dy: -1)
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count == 8 || inputs.count == 2, let destination = output.metalTexture,
              let command = output.metalCommandBuffer, let gpu = MetalRimLight.shared,
              let data = arguments?["parameters"] as? Data, data.count >= MemoryLayout<MetalRimLight.Parameters>.size,
              let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        var parameters = data.withUnsafeBytes { $0.loadUnaligned(as: MetalRimLight.Parameters.self) }
        // Core Image hands over textures with their first row at the top of their region.
        var offsets = [Float](repeating: 0, count: 16)
        for (index, input) in inputs.enumerated() {
            offsets[index * 2] = Float(output.region.minX - input.region.minX)
            offsets[index * 2 + 1] = Float(input.region.maxY - output.region.maxY)
        }
        parameters.offsets = (SIMD4(offsets[0], offsets[1], offsets[2], offsets[3]),
                              SIMD4(offsets[4], offsets[5], offsets[6], offsets[7]),
                              SIMD4(offsets[8], offsets[9], offsets[10], offsets[11]),
                              SIMD4(offsets[12], offsets[13], offsets[14], offsets[15]))
        encoder.setComputePipelineState(inputs.count == 8 ? gpu.pipeline : gpu.combine)
        for (index, input) in inputs.enumerated() {
            guard let texture = input.metalTexture else { encoder.endEncoding(); throw ExportError.render }
            encoder.setTexture(texture, index: index)
        }
        encoder.setTexture(destination, index: inputs.count)
        encoder.setBytes(&parameters, length: MemoryLayout<MetalRimLight.Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
}
