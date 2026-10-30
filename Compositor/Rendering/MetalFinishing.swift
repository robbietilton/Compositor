import CoreGraphics
import CoreImage
import Metal

/// Vignette and Tonal Contrast adjustment layers on the canvas's GPU: the same arithmetic as the filters' C
/// (`adjust_colored_vignette`, `adjust_tonal_contrast`), run inside a Core Image graph so the canvas never leaves the GPU.
nonisolated final class MetalFinishing: @unchecked Sendable {
    static let shared: MetalFinishing? = try? MetalFinishing()
    let vignette: MTLComputePipelineState
    let tonal: MTLComputePipelineState

    struct Parameters {
        /// Vignette: the canvas in the image's coordinates, which the vignette frames.
        var canvasOrigin: SIMD2<Float> = .zero
        var canvasSize: SIMD2<Float> = SIMD2(1, 1)
        var amount: Float = 0
        var midpoint: Float = 50
        var roundness: Float = 100
        var feather: Float = 60
        var highlights: Float = 25
        var color: SIMD3<Float> = .zero
        /// Tonal Contrast's strengths.
        var shadows: Float = 0
        var midtones: Float = 0
        /// Where the first output texel's corner sits in the image's coordinates, and which way rows run in them.
        var outputOrigin: SIMD2<Float> = .zero
        var rowSign: Float = 1
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice() else { throw ExportError.render }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let vignette = library.makeFunction(name: "vignette"), let tonal = library.makeFunction(name: "tonalContrast")
        else { throw ExportError.render }
        self.vignette = try device.makeComputePipelineState(function: vignette)
        self.tonal = try device.makeComputePipelineState(function: tonal)
    }

    /// Vignette over `image`, framing `canvas` (in `image`'s coordinates).
    static func vignette(_ image: CIImage, canvas: CGRect, _ settings: VignetteLayerSettings) -> CIImage? {
        guard shared != nil, settings.amount > 0, canvas.width > 0, canvas.height > 0,
              !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        var parameters = Parameters()
        parameters.canvasOrigin = SIMD2(Float(canvas.minX), Float(canvas.minY))
        parameters.canvasSize = SIMD2(Float(canvas.width), Float(canvas.height))
        parameters.amount = Float(settings.amount); parameters.midpoint = Float(settings.midpoint)
        parameters.roundness = Float(settings.roundness); parameters.feather = Float(settings.feather)
        parameters.highlights = Float(settings.highlights)
        parameters.color = SIMD3(Float(settings.color.red), Float(settings.color.green), Float(settings.color.blue))
        return try? FinishingKernel.apply(withExtent: image.extent, inputs: [image],
                                          arguments: ["parameters": Self.data(parameters), "kernel": "vignette"])
    }

    /// Tonal Contrast over `image`, its local detail measured against `image` blurred `radius` pixels.
    static func tonalContrast(_ image: CIImage, radius: CGFloat, _ settings: TonalLayerSettings) -> CIImage? {
        guard shared != nil, settings.amount > 0, settings.shadows != 0 || settings.midtones != 0 || settings.highlights != 0,
              !image.extent.isInfinite, !image.extent.isEmpty else { return image }
        let blurred = image.clampedToExtent().applyingGaussianBlur(sigma: max(0.5, radius)).cropped(to: image.extent)
        var parameters = Parameters()
        parameters.amount = Float(settings.amount); parameters.shadows = Float(settings.shadows)
        parameters.midtones = Float(settings.midtones); parameters.highlights = Float(settings.highlights)
        return try? FinishingKernel.apply(withExtent: image.extent, inputs: [image, blurred],
                                          arguments: ["parameters": Self.data(parameters), "kernel": "tonal"])
    }

    private static func data(_ parameters: Parameters) -> Data { withUnsafeBytes(of: parameters) { Data($0) } }

    // Compiled at launch by the system's Metal compiler, as the brush's is.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

struct Parameters {
    float2 canvasOrigin;
    float2 canvasSize;
    float amount;
    float midpoint;
    float roundness;
    float feather;
    float highlights;
    float3 color;
    float shadows;
    float midtones;
    float2 outputOrigin;
    float rowSign;
};

float rec709(float3 c) { return dot(c, float3(0.2126, 0.7152, 0.0722)); }
float smooth01(float t) { t = clamp(t, 0.0, 1.0); return t * t * (3.0 - 2.0 * t); }
float3 straight(float4 p) { return p.a > 0 ? min(float3(1), p.rgb / p.a) : float3(0); }

kernel void vignette(texture2d<float, access::read> image [[texture(0)]],
                     texture2d<float, access::write> result [[texture(1)]],
                     constant Parameters &p [[buffer(0)]],
                     uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    float4 color = image.read(pixel);
    if (color.a <= 0) { result.write(color, pixel); return; }
    float2 at = p.outputOrigin + float2(float(pixel.x) + 0.5, p.rowSign * (float(pixel.y) + 0.5));
    float2 n = (at - p.canvasOrigin) / p.canvasSize * 2.0 - 1.0;
    float square = max(abs(n.x), abs(n.y));
    float circle = length(n) / sqrt(2.0);
    float dist = circle + (square - circle) * ((1.0 - p.roundness / 100.0) * 0.5);
    float soft = max(0.05, p.feather / 100.0);
    float mask = smooth01((dist - p.midpoint / 100.0 * 0.85) / soft);
    float3 c = straight(color);
    float bright = clamp((rec709(c) - 0.45) / 0.55, 0.0, 1.0);
    float effect = clamp(p.amount / 100.0, 0.0, 1.0) * mask * (1.0 - p.highlights / 100.0 * bright);
    // Only the pixels that are there change color; their coverage stays as it was.
    result.write(float4((c + (clamp(p.color, 0.0, 1.0) - c) * effect) * color.a, color.a), pixel);
}

kernel void tonalContrast(texture2d<float, access::read> image [[texture(0)]],
                          texture2d<float, access::read> blurred [[texture(1)]],
                          texture2d<float, access::write> result [[texture(2)]],
                          constant Parameters &p [[buffer(0)]],
                          uint2 pixel [[thread_position_in_grid]]) {
    if (pixel.x >= result.get_width() || pixel.y >= result.get_height()) return;
    float4 color = image.read(pixel), base = blurred.read(pixel);
    if (color.a <= 0 || base.a <= 0) { result.write(color, pixel); return; }
    float3 c = straight(color);
    float lum = rec709(c), baseLum = rec709(straight(base));
    float shadowWeight = 1.0 - smooth01((baseLum - 0.15) / 0.35);
    float highlightWeight = smooth01((baseLum - 0.5) / 0.35);
    float midtoneWeight = 1.0 - shadowWeight - highlightWeight;
    float weight = (p.shadows * shadowWeight + p.midtones * midtoneWeight + p.highlights * highlightWeight) / 100.0;
    float delta = 0.18 * tanh((lum - baseLum) * 6.0) * weight * (p.amount / 50.0) * (4.0 * lum * (1.0 - lum));
    result.write(float4(clamp(c + delta, 0.0, 1.0) * color.a, color.a), pixel);
}
"""
}

/// Runs `MetalFinishing`'s kernels inside a Core Image graph, as `DispersionKernel` runs RGB Split's.
final class FinishingKernel: CIImageProcessorKernel {
    /// Whether Core Image hands over textures with their first row at the top of their region.
    static let rowsTopDown = true

    override class func roi(forInput input: Int32, arguments: [String: Any]?, outputRect: CGRect) -> CGRect { outputRect }

    override class func process(with inputs: [CIImageProcessorInput]?, arguments: [String: Any]?,
                                output: CIImageProcessorOutput) throws {
        guard let inputs, let first = inputs.first?.metalTexture, let destination = output.metalTexture,
              let command = output.metalCommandBuffer, let gpu = MetalFinishing.shared,
              let data = arguments?["parameters"] as? Data, data.count >= MemoryLayout<MetalFinishing.Parameters>.size,
              let encoder = command.makeComputeCommandEncoder() else { throw ExportError.render }
        var parameters = data.withUnsafeBytes { $0.loadUnaligned(as: MetalFinishing.Parameters.self) }
        parameters.outputOrigin = SIMD2(Float(output.region.minX), Float(rowsTopDown ? output.region.maxY : output.region.minY))
        parameters.rowSign = rowsTopDown ? -1 : 1
        let tonal = arguments?["kernel"] as? String == "tonal"
        encoder.setComputePipelineState(tonal ? gpu.tonal : gpu.vignette)
        encoder.setTexture(first, index: 0)
        if tonal {
            guard inputs.count > 1, let blurred = inputs[1].metalTexture else { encoder.endEncoding(); throw ExportError.render }
            encoder.setTexture(blurred, index: 1)
            encoder.setTexture(destination, index: 2)
        } else {
            encoder.setTexture(destination, index: 1)
        }
        encoder.setBytes(&parameters, length: MemoryLayout<MetalFinishing.Parameters>.stride, index: 0)
        encoder.dispatchThreads(MTLSize(width: destination.width, height: destination.height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: 16, height: 16, depth: 1))
        encoder.endEncoding()
    }
}
