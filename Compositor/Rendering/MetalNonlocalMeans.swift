import Metal

/// Reduce Noise's non-local means (and Camera Raw's Luminance noise reduction) on the GPU: the same matching as
/// `nonlocal_means` in AdjustPixels.c, which hands its work here through `adjust_nonlocal_means_gpu` and does it itself
/// only when this can't. Each group of threads keeps its block of pixels and the reach of their search around it in
/// fast shared memory, so each pixel's thousands of comparisons read from there rather than from the image.
nonisolated final class MetalNonlocalMeans: @unchecked Sendable {
    static let shared: MetalNonlocalMeans? = try? MetalNonlocalMeans()
    /// Points the C code at the GPU; touched before the noise reduction runs.
    static let installed: Void = {
        adjust_nonlocal_means_gpu = { luma, coverage, out, width, height, search, patch, h, sigma in
            guard let luma, let coverage, let out, let gpu = MetalNonlocalMeans.shared else { return 0 }
            return gpu.run(luma, coverage, out, width: width, height: height, search: Int(search), patch: Int(patch),
                           h: h, sigma: sigma) ? 1 : 0
        }
    }()
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    /// The block each group of threads works on, and how far past it the search and patches can reach (the kernel's
    /// `TILE` and `MARGIN`).
    private static let tile = 16, margin = 9
    /// Rows worked per command, so no one command runs long enough for the system to give up on it.
    private static let rowsPerCommand = 256

    private struct Parameters {
        var width: UInt32
        var height: UInt32
        var firstRow: UInt32
        var search: Int32
        var patch: Int32
        var inverseH2: Float
        var allowance: Float
        var area: Float
    }

    private init() throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ExportError.render }
        let library = try device.makeLibrary(source: Self.source, options: nil)
        guard let function = library.makeFunction(name: "nonlocalMeans") else { throw ExportError.render }
        self.device = device
        self.queue = queue
        pipeline = try device.makeComputePipelineState(function: function)
    }

    /// `luma` smoothed into `out` (both `width` × `height`, rows top-down), as `nonlocal_means` does. False if the GPU
    /// couldn't, or the search reaches past what the kernel holds.
    func run(_ luma: UnsafePointer<Float>, _ coverage: UnsafePointer<Float>, _ out: UnsafeMutablePointer<Float>,
             width: Int, height: Int, search: Int, patch: Int, h: Double, sigma: Double) -> Bool {
        guard width > 0, height > 0, search + patch <= Self.margin, patch <= 2, h > 0 else { return false }
        let count = width * height
        // Brightness and coverage side by side, each pixel's pair read together.
        guard let source = device.makeBuffer(length: count * MemoryLayout<SIMD2<Float>>.stride, options: .storageModeShared),
              let result = device.makeBuffer(length: count * MemoryLayout<Float>.stride, options: .storageModeShared) else { return false }
        let pairs = source.contents().bindMemory(to: SIMD2<Float>.self, capacity: count)
        for index in 0..<count { pairs[index] = SIMD2(luma[index], coverage[index]) }
        var commands: [MTLCommandBuffer] = []
        for firstRow in stride(from: 0, to: height, by: Self.rowsPerCommand) {
            let rows = min(Self.rowsPerCommand, height - firstRow)
            var parameters = Parameters(width: UInt32(width), height: UInt32(height), firstRow: UInt32(firstRow), search: Int32(search),
                                        patch: Int32(patch), inverseH2: Float(1 / (h * h)), allowance: Float(2 * sigma * sigma),
                                        area: Float((2 * patch + 1) * (2 * patch + 1)))
            guard let command = queue.makeCommandBuffer(), let encoder = command.makeComputeCommandEncoder() else { return false }
            encoder.setComputePipelineState(pipeline)
            encoder.setBuffer(source, offset: 0, index: 0)
            encoder.setBuffer(result, offset: 0, index: 1)
            encoder.setBytes(&parameters, length: MemoryLayout<Parameters>.stride, index: 2)
            // Whole blocks, so every thread of a group helps fill its shared memory; those past the image do nothing more.
            let groups = MTLSize(width: (width + Self.tile - 1) / Self.tile, height: (rows + Self.tile - 1) / Self.tile, depth: 1)
            encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: MTLSize(width: Self.tile, height: Self.tile, depth: 1))
            encoder.endEncoding()
            command.commit()
            commands.append(command)
        }
        for command in commands {
            command.waitUntilCompleted()
            guard command.status == .completed else { return false }
        }
        out.update(from: result.contents().bindMemory(to: Float.self, capacity: count), count: count)
        return true
    }

    // Compiled at launch by the system's Metal compiler, as the brush's is.
    private static let source = """
#include <metal_stdlib>
using namespace metal;

#define TILE 16
#define MARGIN 9
#define SPAN (TILE + 2 * MARGIN)
// The block and the widest patch's reach around it.
#define PATCHED (TILE + 4)

struct Parameters {
    uint width;
    uint height;
    uint firstRow;
    int search;
    int patch;
    float inverseH2;
    float allowance;
    float area;
};

kernel void nonlocalMeans(device const float2 *source [[buffer(0)]], device float *out [[buffer(1)]],
                          constant Parameters &p [[buffer(2)]],
                          uint2 local [[thread_position_in_threadgroup]], uint2 group [[threadgroup_position_in_grid]]) {
    // The block's pixels and MARGIN around them, edge pixels carried on past the image's sides.
    threadgroup float2 block[SPAN][SPAN];
    // For one offset at a time: the squared differences over the block and a patch around it, then those summed across
    // each patch's width; each thread then sums its patch's column. Every difference is worked out once, not once for
    // every patch it falls in.
    threadgroup float difference[PATCHED][PATCHED];
    threadgroup float across[PATCHED][TILE];
    uint member = local.y * TILE + local.x;
    int2 corner = int2(group.x * TILE, p.firstRow + group.y * TILE) - MARGIN;
    for (uint i = member; i < SPAN * SPAN; i += TILE * TILE) {
        int2 at = clamp(corner + int2(i % SPAN, i / SPAN), int2(0), int2(p.width - 1, p.height - 1));
        block[i / SPAN][i % SPAN] = source[at.y * p.width + at.x];
    }
    threadgroup_barrier(mem_flags::mem_threadgroup);
    uint2 pixel = uint2(group.x * TILE, p.firstRow + group.y * TILE) + local;
    int reach = p.patch * 2 + 1, size = TILE + 2 * p.patch, start = MARGIN - p.patch;
    float total = 0, weights = 0, strongest = 0;
    for (int dy = -p.search; dy <= p.search; ++dy) {
        for (int dx = -p.search; dx <= p.search; ++dx) {
            if (dx == 0 && dy == 0) continue;
            for (int i = member; i < size * size; i += TILE * TILE) {
                int y = start + i / size, x = start + i % size;
                float d = block[y][x].x - block[y + dy][x + dx].x;
                difference[i / size][i % size] = d * d;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            for (int i = member; i < size * TILE; i += TILE * TILE) {
                int y = i / TILE, x = i % TILE;
                float sum = 0;
                for (int k = 0; k < reach; ++k) sum += difference[y][x + k];
                across[y][x] = sum;
            }
            threadgroup_barrier(mem_flags::mem_threadgroup);
            float distance = 0;
            for (int k = 0; k < reach; ++k) distance += across[local.y + k][local.x];
            float scaled = max(distance / p.area - p.allowance, 0.0f) * p.inverseH2;
            if (scaled < 6) {
                float2 neighbor = block[local.y + MARGIN + dy][local.x + MARGIN + dx];
                float weight = exp(-scaled) * neighbor.y;
                total += weight * neighbor.x;
                weights += weight;
                strongest = max(strongest, weight);
            }
        }
    }
    // Every thread has helped with every offset; only those on the image write.
    if (pixel.x >= p.width || pixel.y >= p.height) return;
    float own = strongest > 0 ? strongest : 1;
    float center = block[local.y + MARGIN][local.x + MARGIN].x;
    out[pixel.y * p.width + pixel.x] = (total + own * center) / (weights + own);
}
"""
}
