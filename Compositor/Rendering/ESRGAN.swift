import Foundation
import Accelerate
import CoreGraphics
import Metal
import MetalPerformanceShadersGraph

nonisolated enum ESRGANError: LocalizedError {
    case unreadableModel(String), noGPU, render, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadableModel(let detail): "The upscaling model could not be read (\(detail)). Remove it and download it again."
        case .noGPU: "Enlarger needs a Metal GPU."
        case .render: "The image could not be upscaled."
        case .tooLarge: "The upscaled images exceed the 100-megapixel, 30,000-pixel-per-side limit."
        }
    }
}

/// The tensors of a PyTorch `.pth` checkpoint: an uncompressed zip holding a pickled state dict and one raw file per
/// storage. Reads what Real-ESRGAN's official checkpoints contain (float32, contiguous) without running Python.
nonisolated struct TorchCheckpoint {
    struct Tensor {
        let shape: [Int]
        let values: [Float]
    }
    let tensors: [String: Tensor]

    init(contentsOf url: URL) throws {
        try self.init(data: Data(contentsOf: url, options: .alwaysMapped))
    }

    init(data: Data) throws {
        // Only the small, fixed Real-ESRGAN network is supported. Bound untrusted metadata before parsing it.
        guard data.count <= 128 * 1024 * 1024 else { throw ESRGANError.unreadableModel("archive too large") }
        let files = try Self.zipEntries(data)
        guard let pickle = files.first(where: { $0.key.hasSuffix("/data.pkl") }), pickle.value.count <= 4 * 1024 * 1024
            else { throw ESRGANError.unreadableModel("no state dict") }
        let prefix = String(pickle.key.dropLast("data.pkl".count))
        var reader = PickleReader(data[pickle.value])
        let root = try reader.read()
        // Real-ESRGAN keeps the averaged generator weights under params_ema (params in older files).
        guard case .dict(let top) = root else { throw ESRGANError.unreadableModel("unexpected layout") }
        func value(for key: String) -> PickleReader.Value? {
            top.items.first(where: { $0.0 == .string(key) })?.1
        }
        guard let state = value(for: "params_ema") ?? value(for: "params"),
              case .dict(let entries) = state else { throw ESRGANError.unreadableModel("unexpected layout") }
        var tensors: [String: Tensor] = [:]
        for (key, value) in entries.items {
            guard case .string(let name) = key, case .tensor(let storage, let offset, let shape) = value,
                  let range = files[prefix + "data/" + storage] else { throw ESRGANError.unreadableModel("unexpected tensor") }
            guard !shape.isEmpty, shape.count <= 4, shape.allSatisfy({ $0 > 0 }), offset >= 0,
                  offset <= range.count / 4, tensors[name] == nil else { throw ESRGANError.unreadableModel("invalid tensor") }
            let available = range.count / 4 - offset
            var count = 1
            for extent in shape {
                guard count <= available / extent else { throw ESRGANError.unreadableModel("short tensor") }
                count *= extent
            }
            // Stored little-endian, as Apple hardware is: one copy instead of a load per value.
            var values = [Float](repeating: 0, count: count)
            data[range].withUnsafeBytes { raw in
                values.withUnsafeMutableBytes { $0.copyMemory(from: UnsafeRawBufferPointer(rebasing: raw[(offset * 4)..<((offset + count) * 4)])) }
            }
            #if _endian(big)
            values = values.map { Float(bitPattern: UInt32(littleEndian: $0.bitPattern)) }
            #endif
            tensors[name] = Tensor(shape: shape, values: values)
        }
        self.tensors = tensors
    }

    /// Stored (uncompressed) entries, as PyTorch writes them: name → byte range of the contents.
    private static func zipEntries(_ data: Data) throws -> [String: Range<Int>] {
        func u16(_ o: Int) -> Int { Int(data[o]) | Int(data[o + 1]) << 8 }
        func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
        guard data.count >= 22 else { throw ESRGANError.unreadableModel("not a zip archive") }
        guard let end = stride(from: data.count - 22, through: max(0, data.count - 65_557), by: -1)
            .first(where: { u32($0) == 0x0605_4b50 && $0 + 22 + u16($0 + 20) == data.count })
            else { throw ESRGANError.unreadableModel("not a zip archive") }
        var entries: [String: Range<Int>] = [:]
        var offset = u32(end + 16)
        let directoryEnd = offset + u32(end + 12)
        guard u16(end + 4) == 0, u16(end + 6) == 0, u16(end + 8) == u16(end + 10),
              directoryEnd <= end else { throw ESRGANError.unreadableModel("damaged archive") }
        for _ in 0..<u16(end + 10) {
            guard offset + 46 <= directoryEnd, u32(offset) == 0x0201_4b50 else { throw ESRGANError.unreadableModel("damaged archive") }
            let method = u16(offset + 10), size = u32(offset + 20), nameLength = u16(offset + 28)
            let extra = u16(offset + 30), comment = u16(offset + 32), local = u32(offset + 42)
            let next = offset + 46 + nameLength + extra + comment
            guard next <= directoryEnd, local + 30 <= data.count,
                  method == 0, u32(offset + 24) == size, u16(offset + 8) & 1 == 0,
                  u32(local) == 0x0403_4b50, u16(local + 8) == 0,
                  let name = String(data: data[(offset + 46)..<(offset + 46 + nameLength)], encoding: .utf8),
                  entries[name] == nil else { throw ESRGANError.unreadableModel("unsupported archive entry") }
            let start = local + 30 + u16(local + 26) + u16(local + 28)
            guard start + size <= u32(end + 16) else { throw ESRGANError.unreadableModel("damaged archive") }
            entries[name] = start..<(start + size)
            offset = next
        }
        guard offset == directoryEnd else { throw ESRGANError.unreadableModel("damaged archive") }
        return entries
    }
}

/// Just enough of Python's pickle (protocol 2) for a PyTorch state dict: dicts, tuples, strings, ints, globals,
/// persistent storage ids and tensor rebuilds. Nothing is executed; unknown callables become opaque values.
nonisolated private struct PickleReader {
    final class Dict { var items: [(Value, Value)] = [] }
    indirect enum Value: Equatable {
        case none, bool(Bool), int(Int), string(String), tuple([Value]), dict(Dict), global(String, String)
        case persistent([Value]), tensor(storage: String, offset: Int, shape: [Int]), mark, opaque
        static func == (lhs: Value, rhs: Value) -> Bool {
            switch (lhs, rhs) {
            case (.none, .none), (.mark, .mark), (.opaque, .opaque): true
            case let (.bool(a), .bool(b)): a == b
            case let (.int(a), .int(b)): a == b
            case let (.string(a), .string(b)): a == b
            case let (.tuple(a), .tuple(b)), let (.persistent(a), .persistent(b)): a == b
            case let (.dict(a), .dict(b)): a === b
            case let (.global(a, b), .global(c, d)): a == c && b == d
            case let (.tensor(a, b, c), .tensor(d, e, f)): a == d && b == e && c == f
            default: false
            }
        }
    }
    private let bytes: [UInt8]
    private var position = 0
    init(_ data: Data) { bytes = [UInt8](data) }

    private mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw ESRGANError.unreadableModel("truncated state dict") }
        defer { position += 1 }
        return bytes[position]
    }
    private mutating func integer(_ count: Int) throws -> Int {
        var value = 0
        for shift in 0..<count { value |= Int(try byte()) << (8 * shift) }
        return value
    }
    private mutating func line() throws -> String {
        var text: [UInt8] = []
        while true { let next = try byte(); if next == 0x0a { break }; text.append(next) }
        return String(decoding: text, as: UTF8.self)
    }

    mutating func read() throws -> Value {
        var stack: [Value] = [], memo: [Int: Value] = [:]
        func pop() throws -> Value {
            guard let value = stack.popLast() else { throw ESRGANError.unreadableModel("malformed state dict") }
            return value
        }
        func popToMark() throws -> [Value] {
            guard let mark = stack.lastIndex(of: .mark) else { throw ESRGANError.unreadableModel("malformed state dict") }
            let items = Array(stack[(mark + 1)...])
            stack.removeSubrange(mark...)
            return items
        }
        func setItems(_ items: [Value]) throws {
            guard case .dict(let dict) = stack.last, items.count.isMultiple(of: 2)
                else { throw ESRGANError.unreadableModel("malformed dictionary") }
            for index in stride(from: 0, to: items.count, by: 2) { dict.items.append((items[index], items[index + 1])) }
        }
        while true {
            switch try byte() {
            case 0x80:                                                 // PROTO
                guard try byte() == 2 else { throw ESRGANError.unreadableModel("unsupported pickle protocol") }
            case 0x2e: return try pop()                                 // STOP
            case 0x7d: stack.append(.dict(Dict()))                      // EMPTY_DICT
            case 0x29: stack.append(.tuple([]))                         // EMPTY_TUPLE
            case 0x28: stack.append(.mark)                              // MARK
            case 0x4e: stack.append(.none)                              // NONE
            case 0x88: stack.append(.bool(true))                        // NEWTRUE
            case 0x89: stack.append(.bool(false))                       // NEWFALSE
            case 0x4b: stack.append(.int(try integer(1)))               // BININT1
            case 0x4d: stack.append(.int(try integer(2)))               // BININT2
            case 0x4a: stack.append(.int(Int(Int32(truncatingIfNeeded: try integer(4)))))  // BININT
            case 0x58:                                                  // BINUNICODE
                let count = try integer(4)
                guard position + count <= bytes.count else { throw ESRGANError.unreadableModel("truncated state dict") }
                stack.append(.string(String(decoding: bytes[position..<(position + count)], as: UTF8.self)))
                position += count
            case 0x63: stack.append(.global(try line(), try line()))    // GLOBAL
            case 0x71: memo[try integer(1)] = stack.last                // BINPUT
            case 0x72: memo[try integer(4)] = stack.last                // LONG_BINPUT
            case 0x68: stack.append(memo[try integer(1)] ?? .opaque)    // BINGET
            case 0x6a: stack.append(memo[try integer(4)] ?? .opaque)    // LONG_BINGET
            case 0x74: stack.append(.tuple(try popToMark()))            // TUPLE
            case 0x85: stack.append(.tuple([try pop()]))                // TUPLE1
            case 0x86: let b = try pop(), a = try pop(); stack.append(.tuple([a, b]))           // TUPLE2
            case 0x87: let c = try pop(), b = try pop(), a = try pop(); stack.append(.tuple([a, b, c]))  // TUPLE3
            case 0x51:                                                  // BINPERSID
                guard case .tuple(let id) = try pop() else { throw ESRGANError.unreadableModel("unexpected storage") }
                stack.append(.persistent(id))
            case 0x52:                                                  // REDUCE
                let arguments = try pop(), callable = try pop()
                stack.append(try Self.reduce(callable, arguments))
            case 0x62: _ = try pop()                                    // BUILD: the state dict's metadata
            case 0x73: let value = try pop(), key = try pop(); try setItems([key, value])        // SETITEM
            case 0x75: try setItems(try popToMark())                    // SETITEMS
            case let code: throw ESRGANError.unreadableModel(String(format: "pickle opcode 0x%02x", code))
            }
        }
    }

    private static func reduce(_ callable: Value, _ arguments: Value) throws -> Value {
        guard case .global(let module, let name) = callable, case .tuple(let args) = arguments else { return .opaque }
        switch (module, name) {
        case ("collections", "OrderedDict"): return .dict(Dict())
        case ("torch._utils", "_rebuild_tensor_v2"):
            guard args.count >= 4, case .persistent(let id) = args[0], id.count >= 3,
                  case .global(_, "FloatStorage") = id[1], case .string(let storage) = id[2],
                  case .int(let offset) = args[1], case .tuple(let size) = args[2], case .tuple(let stride) = args[3] else {
                throw ESRGANError.unreadableModel("unsupported tensor")
            }
            let shape = try size.map { value -> Int in guard case .int(let n) = value else { throw ESRGANError.unreadableModel("shape") }; return n }
            let strides = try stride.map { value -> Int in guard case .int(let n) = value else { throw ESRGANError.unreadableModel("stride") }; return n }
            guard !shape.isEmpty, shape.count <= 4, strides.count == shape.count,
                  shape.allSatisfy({ $0 > 0 }), offset >= 0 else { throw ESRGANError.unreadableModel("invalid shape") }
            // Only contiguous (row-major) tensors, which is how state dicts are saved.
            var expected = 1
            for (dimension, extent) in shape.enumerated().reversed() {
                guard extent == 1 || strides[dimension] == expected else { throw ESRGANError.unreadableModel("strided tensor") }
                let (count, overflow) = expected.multipliedReportingOverflow(by: extent)
                guard !overflow else { throw ESRGANError.unreadableModel("oversized tensor") }
                expected = count
            }
            return .tensor(storage: storage, offset: offset, shape: shape)
        default: return .opaque
        }
    }
}

/// Real-ESRGAN x4plus (RRDBNet: 23 residual-in-residual dense blocks), by Xintao Wang et al., BSD-3-Clause, run on the
/// GPU with MPSGraph in half precision. Works on fixed tiles with overlapping margins, so any image size fits in memory.
nonisolated final class ESRGANUpscaler: @unchecked Sendable {
    /// Input pixels per tile side, and the overlap on each side that is computed but discarded.
    static let tile = 256
    static let margin = 16
    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let executable: MPSGraphExecutable
    private let lock = NSLock()

    init(checkpoint: TorchCheckpoint) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { throw ESRGANError.noGPU }
        self.device = device
        self.queue = queue
        let graph = MPSGraph()
        let tile = Self.tile
        let input = graph.placeholder(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float16, name: "input")
        let weights = checkpoint.tensors

        func half(_ values: [Float]) -> Data {
            var source = values, result = [UInt16](repeating: 0, count: values.count)
            source.withUnsafeMutableBufferPointer { from in
                result.withUnsafeMutableBufferPointer { to in
                    var src = vImage_Buffer(data: from.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * 4)
                    var dst = vImage_Buffer(data: to.baseAddress, height: 1, width: vImagePixelCount(values.count), rowBytes: values.count * 2)
                    _ = vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
                }
            }
            return result.withUnsafeBufferPointer { Data(buffer: $0) }
        }
        func conv(_ x: MPSGraphTensor, _ name: String) throws -> MPSGraphTensor {
            let channels = name == "conv_last" ? 3 : (name.contains(".rdb") && !name.hasSuffix(".conv5") ? 32 : 64)
            guard let w = weights[name + ".weight"], let b = weights[name + ".bias"],
                  let inputChannels = x.shape?[1].intValue, w.shape == [channels, inputChannels, 3, 3],
                  b.shape == [channels], w.values.count == channels * inputChannels * 9, b.values.count == channels,
                  w.values.allSatisfy({ $0.isFinite && abs($0) <= 65_504 }),
                  b.values.allSatisfy({ $0.isFinite && abs($0) <= 65_504 }),
                  let descriptor = MPSGraphConvolution2DOpDescriptor(strideInX: 1, strideInY: 1, dilationRateInX: 1, dilationRateInY: 1,
                      groups: 1, paddingLeft: 1, paddingRight: 1, paddingTop: 1, paddingBottom: 1, paddingStyle: .explicit,
                      dataLayout: .NCHW, weightsLayout: .OIHW) else { throw ESRGANError.unreadableModel(name) }
            let weight = graph.constant(half(w.values), shape: w.shape.map { NSNumber(value: $0) }, dataType: .float16)
            let bias = graph.constant(half(b.values), shape: [1, NSNumber(value: b.values.count), 1, 1], dataType: .float16)
            return graph.addition(graph.convolution2D(x, weights: weight, descriptor: descriptor, name: nil), bias, name: nil)
        }
        func lrelu(_ x: MPSGraphTensor) -> MPSGraphTensor { graph.leakyReLU(with: x, alpha: 0.2, name: nil) }
        let residualScale = graph.constant(0.2, dataType: .float16)
        func scaled(_ x: MPSGraphTensor, plus skip: MPSGraphTensor) -> MPSGraphTensor {
            graph.addition(graph.multiplication(x, residualScale, name: nil), skip, name: nil)
        }
        func denseBlock(_ x: MPSGraphTensor, _ name: String) throws -> MPSGraphTensor {
            var features = [x]
            for index in 1...4 {
                let joined = features.count == 1 ? x : graph.concatTensors(features, dimension: 1, name: nil)
                features.append(lrelu(try conv(joined, "\(name).conv\(index)")))
            }
            return scaled(try conv(graph.concatTensors(features, dimension: 1, name: nil), "\(name).conv5"), plus: x)
        }
        // Nearest-neighbour 2× as PyTorch's interpolate does it: every value repeated in a 2 × 2 block. Rank 5 at most
        // (the batch of one dropped), which every MPSGraph backend accepts.
        func upsample(_ x: MPSGraphTensor, size: Int) -> MPSGraphTensor {
            let s = NSNumber(value: size), d = NSNumber(value: size * 2)
            let spread = graph.broadcast(graph.reshape(x, shape: [64, s, 1, s, 1], name: nil), shape: [64, s, 2, s, 2], name: nil)
            return graph.reshape(spread, shape: [1, 64, d, d], name: nil)
        }
        let first = try conv(input, "conv_first")
        var body = first
        for block in 0..<23 {
            var x = body
            for dense in 1...3 { x = try denseBlock(x, "body.\(block).rdb\(dense)") }
            body = scaled(x, plus: body)
        }
        var features = graph.addition(first, try conv(body, "conv_body"), name: nil)
        features = lrelu(try conv(upsample(features, size: tile), "conv_up1"))
        features = lrelu(try conv(upsample(features, size: tile * 2), "conv_up2"))
        let result = try conv(lrelu(try conv(features, "conv_hr")), "conv_last")
        let output = graph.clamp(result, min: graph.constant(0, dataType: .float16), max: graph.constant(1, dataType: .float16), name: nil)
        // Compiled once for the GPU alone: the Neural Engine can't take this network, and trying costs time and log noise.
        let compilation = MPSGraphCompilationDescriptor()
        compilation.optimizationLevel = .level0
        executable = graph.compile(with: MPSGraphDevice(mtlDevice: device),
            feeds: [input: MPSGraphShapedType(shape: [1, 3, NSNumber(value: tile), NSNumber(value: tile)], dataType: .float16)],
            targetTensors: [output], targetOperations: nil, compilationDescriptor: compilation)
    }

    /// One tile: 3 × tile × tile unpremultiplied RGB in 0...1, planar; returns 3 × 4tile × 4tile.
    private func run(_ tile: [Float]) throws -> [Float] {
        // Keep the executable and its output readback together when different documents share the network.
        try lock.withLock { try runLocked(tile) }
    }

    private func runLocked(_ tile: [Float]) throws -> [Float] {
        let size = Self.tile, count = tile.count
        var source = tile, packed = [UInt16](repeating: 0, count: count)
        source.withUnsafeMutableBufferPointer { from in
            packed.withUnsafeMutableBufferPointer { to in
                var src = vImage_Buffer(data: from.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 4)
                var dst = vImage_Buffer(data: to.baseAddress, height: 1, width: vImagePixelCount(count), rowBytes: count * 2)
                _ = vImageConvert_PlanarFtoPlanar16F(&src, &dst, 0)
            }
        }
        let feed = MPSGraphTensorData(device: MPSGraphDevice(mtlDevice: device), data: packed.withUnsafeBufferPointer { Data(buffer: $0) },
                                      shape: [1, 3, NSNumber(value: size), NSNumber(value: size)], dataType: .float16)
        let results = executable.run(with: queue, inputs: [feed], results: nil, executionDescriptor: nil)
        guard let data = results.first else { throw ESRGANError.render }
        let outCount = 3 * size * size * 16
        var half = [UInt16](repeating: 0, count: outCount), values = [Float](repeating: 0, count: outCount)
        half.withUnsafeMutableBytes { data.mpsndarray().readBytes($0.baseAddress!, strideBytes: nil) }
        half.withUnsafeMutableBufferPointer { from in
            values.withUnsafeMutableBufferPointer { to in
                var src = vImage_Buffer(data: from.baseAddress, height: 1, width: vImagePixelCount(outCount), rowBytes: outCount * 2)
                var dst = vImage_Buffer(data: to.baseAddress, height: 1, width: vImagePixelCount(outCount), rowBytes: outCount * 4)
                _ = vImageConvert_Planar16FtoPlanarF(&src, &dst, 0)
            }
        }
        return values
    }

    /// Bounds are shared with the sheet so invalid sizes fail before loading the model or allocating raster buffers.
    static func outputSize(width: Int, height: Int, factor: Int) throws -> (width: Int, height: Int) {
        guard factor == 2 || factor == 4 else { throw ESRGANError.render }
        guard width > 0, height > 0, width <= 30_000 / factor, height <= 30_000 / factor
            else { throw ESRGANError.tooLarge }
        let result = (width: width * factor, height: height * factor)
        guard result.width * result.height <= 100_000_000 else { throw ESRGANError.tooLarge }
        return result
    }

    /// `image` enlarged `factor` (2 or 4) times. The network always enlarges 4×; for 2× each tile's result is averaged
    /// down 2 × 2. Alpha is resampled, not generated.
    /// `progress` receives the finished share, 0...1; `cancelled` is checked between tiles.
    func upscale(_ image: CGImage, factor: Int, progress: (Double) -> Void, cancelled: () -> Bool) throws -> CGImage {
        let width = image.width, height = image.height
        let output = try Self.outputSize(width: width, height: height, factor: factor)
        if cancelled() { throw CancellationError() }
        let source = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: source)
        let target = try BrushRaster.context(width: output.width, height: output.height, mask: false)
        guard let pixels = source.data?.assumingMemoryBound(to: UInt8.self),
              let result = target.data?.assumingMemoryBound(to: UInt8.self) else { throw ESRGANError.render }
        let sourceRow = source.bytesPerRow, targetRow = target.bytesPerRow
        let tile = Self.tile, margin = Self.margin, step = tile - 2 * margin, out = tile * 4, plane = tile * tile
        let opaque = esrgan_is_opaque(pixels, sourceRow, width, height) != 0
        let columns = (width + step - 1) / step, rows = (height + step - 1) / step
        var input = [Float](repeating: 0, count: 3 * plane)
        for row in 0..<rows {
            for column in 0..<columns {
                if cancelled() { throw CancellationError() }
                let left = column * step, top = row * step
                // The tile with its margin, edges repeated past the image.
                input.withUnsafeMutableBufferPointer {
                    esrgan_fill_tile(pixels, sourceRow, width, height, left - margin, top - margin, tile, $0.baseAddress)
                }
                let enlarged = try autoreleasepool { try run(input) }
                if cancelled() { throw CancellationError() }
                // Keep the tile's middle; for 2×, average each 2 × 2 block of the 4× result.
                let keepWidth = min(step, width - left), keepHeight = min(step, height - top)
                enlarged.withUnsafeBufferPointer {
                    esrgan_store_tile($0.baseAddress, out, margin * 4, keepWidth, keepHeight, factor,
                                      result, targetRow, left * factor, top * factor)
                }
                progress(Double(row * columns + column + 1) / Double(rows * columns))
            }
        }
        if cancelled() { throw CancellationError() }
        if !opaque {
            // Transparency is resampled smoothly and the enlarged color premultiplied by it.
            // Alpha-only storage saves three bytes per output pixel (300 MB at the canvas limit).
            guard let alpha = CGContext(data: nil, width: output.width, height: output.height, bitsPerComponent: 8,
                bytesPerRow: output.width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.alphaOnly.rawValue)
                else { throw ESRGANError.render }
            alpha.interpolationQuality = .high
            alpha.draw(image, in: CGRect(x: 0, y: 0, width: output.width, height: output.height))
            guard let coverage = alpha.data?.assumingMemoryBound(to: UInt8.self) else { throw ESRGANError.render }
            if cancelled() { throw CancellationError() }
            esrgan_apply_alpha(result, targetRow, coverage, alpha.bytesPerRow, output.width, output.height)
        }
        if cancelled() { throw CancellationError() }
        guard let upscaled = target.makeImage() else { throw ESRGANError.render }
        return upscaled
    }
}
