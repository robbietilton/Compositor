import CoreGraphics
import CoreImage
import Metal
import simd

/// Volumetric Light on the GPU (see `VolumetricLighting`): the beams, gathered at each pixel along the line back toward
/// the light, and then the beams and haze laid over the photo. Run inside a Core Image graph, as `MetalRimLight` is.
nonisolated final class MetalVolumetricLight: @unchecked Sendable {
    static let shared: MetalVolumetricLight? = try? MetalVolumetricLight()
    let beams: MTLComputePipelineState
    let combine: MTLComputePipelineState

    struct Parameters {
        /// The light's color times Intensity, in linear light, and its color alone.
        var color: SIMD4<Float> = .zero
        var tint: SIMD4<Float> = .zero
        /// Where each input's texels sit against the output's: two inputs to a vector.
        var offsets: (SIMD4<Float>, SIMD4<Float>, SIMD4<Float>) = (.zero, .zero, .zero)
        /// The light, in Core Image's coordinates until the kernel runs, then in the output's pixels (rows down).
        var light: SIMD2<Float> = .zero
        /// The image's longer side and the light's size, in pixels; how far toward the light each beam gathers, 0–1;
        /// how much the beams break into shafts, 0–1; and the haze, 0–1.
        var side: Float = 1
        var size: Float = 1
        var length: Float = 0.7
        var shafts: Float = 0.6
        var haze: Float = 0.4
        /// The image's height, and how far below its top the output's first row is, for how far away each row is.
        var height: Float = 1
        var top: Float = 0
        /// 1 when there's a depth map to go by, 0 to guess from where a pixel sits.
        var hasDepth: Float = 0
        /// Where the haze begins and where it's full, as distance (0 nearest, 1 farthest; see `VolumetricLighting.ramp`).
        var start: Float = 0
        var end: Float = 1
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ExportError.render }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let beams = library.makeFunction(name: "volumetricBeams"), let combine = library.makeFunction(name: "volumetricCombine")
        else { throw ExportError.render }
        self.beams = try device.makeComputePipelineState(function: beams)
        self.combine = try device.makeComputePipelineState(function: combine)
    }

    private static func parameters(_ settings: VolumetricLightSettings, light: CGPoint, side: CGFloat) -> Parameters {
        func linear(_ value: Double) -> Float { Float(value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)) }
        let tint = SIMD4(linear(settings.color.red), linear(settings.color.green), linear(settings.color.blue), 0)
        var parameters = Parameters()
        parameters.tint = tint
        parameters.color = tint * Float(settings.intensity / 100 * VolumetricLighting.fullIntensity)
        parameters.light = SIMD2(Float(light.x), Float(light.y))
        parameters.side = Float(side)
        parameters.size = Float(max(1, side * (0.02 + settings.size / 100 * 0.4)))
        parameters.length = Float(settings.length / 100)
        parameters.shafts = Float(settings.shafts / 100)
        parameters.haze = Float(settings.haze / 100 * VolumetricLighting.fullHaze)
        return parameters
    }

    /// The beams for `image` (at the size they're worked out at), gray: `subject` where the subject blocks the light,
    /// `peak` the image's brightest (a single pixel), `light` and `side` in `image`'s coordinates.
    static func beams(_ image: CIImage, subject: CIImage, peak: CIImage, light: CGPoint, side: CGFloat,
                      settings: VolumetricLightSettings) throws -> CIImage {
        guard shared != nil else { throw ExportError.render }
        let parameters = parameters(settings, light: light, side: side)
        return try VolumetricLightKernel.apply(withExtent: image.extent, inputs: [image, subject, peak],
                                               arguments: ["parameters": withUnsafeBytes(of: parameters) { Data($0) },
                                                           "extent": image.extent])
    }

    /// `beams` and the haze over `image`: `near` says how near the subject each pixel is, `glows` is the photo's own
    /// lights bloomed, `ambient` its light spread wide, and `depth` how near each part is (1 nearest), if it's known.
    static func combined(_ image: CIImage, beams: CIImage, near: CIImage, glows: CIImage, ambient: CIImage, depth: CIImage?,
                         ramp: (start: Float, end: Float), light: CGPoint, side: CGFloat, settings: VolumetricLightSettings) throws -> CIImage {
        guard shared != nil else { throw ExportError.render }
        var parameters = parameters(settings, light: light, side: side)
        parameters.start = ramp.start
        parameters.end = max(ramp.end, ramp.start + 0.01)
        parameters.height = Float(image.extent.height)
        parameters.hasDepth = depth == nil ? 0 : 1
        let depth = depth ?? CIImage.black.cropped(to: image.extent)
        return try VolumetricLightKernel.apply(withExtent: image.extent, inputs: [image, beams, near, glows, ambient, depth],
                                               arguments: ["parameters": withUnsafeBytes(of: parameters) { Data($0) },
                                                           "combine": true, "extent": image.extent])
    }

    // Compiled at launch by the system's Metal compiler, as the brush's is.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    float4 color;
    float4 tint;
    float4 offsets[3];
    float2 light;
    float side;
    float size;
    float length;
    float shafts;
    float haze;
    float height;
    float top;
    float hasDepth;
    float start;
    float end;
};

int2 offsetOf(constant Parameters &p, int input) {
    float4 pair = p.offsets[input / 2];
    return int2((input % 2 == 0) ? pair.xy : pair.zw);
}

float4 texel(texture2d<float, access::sample> t, int2 at) {
    at = clamp(at, int2(0), int2(t.get_width() - 1, t.get_height() - 1));
    return t.read(uint2(at));
}

float hash(float n) { return fract(sin(n * 12.9898) * 43758.5453); }

// Smooth noise around the light, one value per `cells` around the circle.
float around(float angle, float cells, float seed) {
    float u = (angle / 6.2831853 + 0.5) * cells;
    float i = floor(u), f = u - i;
    f = f * f * (3.0 - 2.0 * f);
    return mix(hash(fmod(i, cells) + seed), hash(fmod(i + 1.0, cells) + seed), f);
}

// What gives off light at `at` (the output's pixels): the light itself, a soft disc, mostly where the photo is light
// enough to let it through; and the photo's bright openings, more near the light. The subject blocks both, and the
// shafts break them up around the light, as dust and haze break a beam.
float emission(texture2d<float, access::sample> image, texture2d<float, access::sample> subject, float peak,
               constant Parameters &p, float2 at) {
    constexpr sampler linear(coord::pixel, filter::linear, address::clamp_to_edge);
    float4 color = image.sample(linear, at + float2(offsetOf(p, 0)));
    float bright = clamp(dot(color.rgb, float3(0.2126, 0.7152, 0.0722)) / peak, 0.0, 1.0);
    float blocked = subject.sample(linear, at + float2(offsetOf(p, 1))).r;
    float2 apart = at - p.light;
    float distance = length(apart);
    float open = clamp((bright - 0.08) / 0.3, 0.0, 1.0);
    float disc = exp(-2.0 * (distance / p.size) * (distance / p.size));
    float openings = clamp((bright - 0.45) / 0.45, 0.0, 1.0) * exp(-distance / (p.side * 0.5));
    float angle = atan2(apart.y, apart.x);
    float wave = 0.6 * around(angle, 97.0, 3.1) + 0.4 * around(angle, 251.0, 7.7);
    float broken = 1.0 - p.shafts + p.shafts * wave * wave * 1.8;
    return (disc * (0.25 + 0.75 * open) + openings) * (1.0 - blocked) * broken;
}

kernel void volumetricBeams(texture2d<float, access::sample> image [[texture(0)]],
                            texture2d<float, access::sample> subject [[texture(1)]],
                            texture2d<float, access::sample> peak [[texture(2)]],
                            texture2d<float, access::write> result [[texture(3)]],
                            constant Parameters &p [[buffer(0)]],
                            uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    float brightest = max(0.05, texel(peak, int2(0)).g);
    float2 here = float2(pixel) + 0.5;
    const int samples = 96;
    float2 step = (p.light - here) * p.length / float(samples);
    float jitter = hash(float(pixel.x) * 0.618 + float(pixel.y) * 1.414);
    float sum = 0.0, weight = 1.0;
    for (int i = 0; i < samples; i++) {
        sum += emission(image, subject, brightest, p, here + step * (float(i) + jitter)) * weight;
        weight *= 0.985;
    }
    float gathered = sum / float(samples) * 4.0;
    result.write(float4(gathered, gathered, gathered, 1.0), pixel);
}

// The haze: thicker the further away a pixel is, from the depth model once it's here (the subject held near by its
// mask), otherwise guessed from where it sits (the foot of the frame is the ground near the camera, higher up is
// further off) and the subject (nearer than what's behind it). It veils the
// photo in the air's color, lit by the scene itself and more toward the light, and the photo's own lights glow into
// it. Then the beams are screened over, a lot of them rolling off into the light's color and white rather than clipping.
kernel void volumetricCombine(texture2d<float, access::sample> image [[texture(0)]],
                              texture2d<float, access::sample> beams [[texture(1)]],
                              texture2d<float, access::sample> near [[texture(2)]],
                              texture2d<float, access::sample> glows [[texture(3)]],
                              texture2d<float, access::sample> ambient [[texture(4)]],
                              texture2d<float, access::sample> depth [[texture(5)]],
                              texture2d<float, access::write> result [[texture(6)]],
                              constant Parameters &p [[buffer(0)]],
                              uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    int2 here = int2(pixel);
    float4 color = texel(image, here + offsetOf(p, 0));
    if (color.a <= 0) { result.write(color, pixel); return; }
    float gathered = texel(beams, here + offsetOf(p, 1)).r;
    float front = clamp(texel(near, here + offsetOf(p, 2)).r, 0.0, 1.0);
    float3 bloom = max(float3(0), texel(glows, here + offsetOf(p, 3)).rgb);
    float3 air = max(float3(0), texel(ambient, here + offsetOf(p, 4)).rgb);
    float far;
    if (p.hasDepth > 0.5) {
        // The depth map, which already has the subject in it, edge and all (`VolumetricLighting.composedDepth`).
        far = 1.0 - clamp(texel(depth, here + offsetOf(p, 5)).r, 0.0, 1.0);
    } else {
        // No depth: guessed from where it sits (the foot of the frame is the ground near the camera) and the subject.
        float down = (p.top + float(pixel.y) + 0.5) / max(1.0, p.height);
        far = (1.0 - smoothstep(0.45, 1.05, down)) * (1.0 - 0.8 * front);
    }
    float glow = exp(-length(float2(pixel) + 0.5 - p.light) / (p.side * 0.35));
    // Clear nearer than where Distance starts the haze, building to full over a gentle stretch beyond.
    float ramp = smoothstep(p.start, p.end, far);
    // A little haze even in front: there's air between the camera and the nearest thing too.
    float fog = 1.0 - exp(-3.0 * p.haze * (0.12 + 0.88 * ramp));
    float3 fogColor = air * mix(float3(1.0), p.tint.rgb, 0.6) * 0.9 + p.tint.rgb * glow * 0.45;
    float3 base = max(float3(0), color.rgb / color.a);
    float3 veiled = mix(base, fogColor, fog) + bloom * p.haze * 1.6 * (0.3 + 0.7 * ramp);
    float3 added = p.color.rgb * gathered * 0.5 * (1.0 - 0.92 * front);
    float3 lit = 1.0 - (1.0 - min(veiled, float3(1.0))) * exp(-added);
    // Light past white in an HDR layer stays past it.
    lit = max(lit, veiled + (lit - min(veiled, float3(1.0))));
    result.write(float4(lit * color.a, color.a), pixel);
}
"""
}

/// Runs `MetalVolumetricLight` inside a Core Image graph: the beams, which read the whole image (`extent`) for every
/// pixel, or laying them and the haze over the photo, which reads each input where it is.
final class VolumetricLightKernel: CIImageProcessorKernel {
    override class var outputFormat: CIFormat { .RGBAf }
    override class func formatForInput(at input: Int32) -> CIFormat { .RGBAf }

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect {
        if arguments?["combine"] as? Bool == true { return outputRect }
        // The peak is a single pixel at the image's corner; the beams gather from anywhere on the image.
        if input == 2 { return CGRect(x: (arguments?["extent"] as? CGRect)?.minX ?? 0, y: (arguments?["extent"] as? CGRect)?.minY ?? 0, width: 1, height: 1) }
        return (arguments?["extent"] as? CGRect) ?? outputRect
    }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, inputs.count == 3 || inputs.count == 6, let destination = output.metalTexture,
              let command = output.metalCommandBuffer, let gpu = MetalVolumetricLight.shared,
              let data = arguments?["parameters"] as? Data, data.count >= MemoryLayout<MetalVolumetricLight.Parameters>.size,
              let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        var parameters = data.withUnsafeBytes { $0.loadUnaligned(as: MetalVolumetricLight.Parameters.self) }
        // Core Image hands over textures with their first row at the top of their region.
        var offsets = [Float](repeating: 0, count: 12)
        for (index, input) in inputs.enumerated() {
            offsets[index * 2] = Float(output.region.minX - input.region.minX)
            offsets[index * 2 + 1] = Float(input.region.maxY - output.region.maxY)
        }
        parameters.offsets = (SIMD4(offsets[0], offsets[1], offsets[2], offsets[3]), SIMD4(offsets[4], offsets[5], offsets[6], offsets[7]),
                              SIMD4(offsets[8], offsets[9], offsets[10], offsets[11]))
        // How far below the image's top this output starts.
        if let extent = arguments?["extent"] as? CGRect { parameters.top = Float(extent.maxY - output.region.maxY) }
        // The light into this output's pixels, rows running down.
        parameters.light = SIMD2(parameters.light.x - Float(output.region.minX), Float(output.region.maxY) - parameters.light.y)
        let combine = arguments?["combine"] as? Bool == true
        encoder.setComputePipelineState(combine ? gpu.combine : gpu.beams)
        for (index, input) in inputs.enumerated() {
            guard let texture = input.metalTexture else { encoder.endEncoding(); throw ExportError.render }
            encoder.setTexture(texture, index: index)
        }
        encoder.setTexture(destination, index: inputs.count)
        encoder.setBytes(&parameters, length: MemoryLayout<MetalVolumetricLight.Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
}
