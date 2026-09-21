import CoreGraphics
import Foundation
@testable import Compositor

/// Builds tiny Photoshop files for reader tests. Not part of the app; Compositor does not write PSD.
nonisolated enum PSDFixture {
    static func data(_ document: PSDDocument, composite: CGImage) throws -> Data {
        let width = document.width, height = document.height
        guard (1...30_000).contains(width), (1...30_000).contains(height) else { throw ImageImportError.tooLarge }
        var file = PSDBuffer()
        file.string("8BPS")
        file.u16(1)
        file.bytes(Data(count: 6))
        file.u16(4)
        file.u32(UInt32(height))
        file.u32(UInt32(width))
        file.u16(8)
        file.u16(3)
        file.u32(0)
        let resources = resolutionResource(document.resolution)
        file.u32(UInt32(resources.count))
        file.bytes(resources)
        let layers = try layerSection(document)
        file.u32(UInt32(layers.count))
        file.bytes(layers)
        try appendComposite(&file, composite, width: width, height: height)
        return file.data
    }

    private struct Prepared {
        var record: PSDRecord
        var isDivider: Bool
        var channels: [(id: Int16, payload: Data)]
        var top = 0, left = 0, bottom = 0, right = 0
        var maskTop = 0, maskLeft = 0, maskBottom = 0, maskRight = 0
    }

    private static func layerSection(_ document: PSDDocument) throws -> Data {
        var prepared: [Prepared] = []
        func emit(_ parent: UUID?) throws {
            // File order is bottom-to-top. Photoshop groups are type 3, children, then type 1/2.
            for record in document.layers where record.parentID == parent {
                if record.isGroup {
                    prepared.append(try emptyLayer(name: "</Layer group>", blendKey: "norm", section: 3, parent: parent))
                    try emit(record.id)
                    prepared.append(try emptyLayer(name: record.name, blendKey: record.blendKey == "pass" ? "pass" : record.blendKey,
                                                   section: 1, visible: record.isVisible, opacity: record.opacity, parent: record.parentID, id: record.id, mask: record.mask, maskEnabled: record.maskEnabled))
                } else {
                    prepared.append(try layer(record))
                }
            }
        }
        try emit(nil)
        guard prepared.count <= Int(Int16.max) else { throw ImageImportError.tooLarge }
        var records = PSDBuffer()
        records.i16(Int16(prepared.count))
        var payloads = PSDBuffer()
        for item in prepared {
            writeRecord(&records, item)
            for channel in item.channels { payloads.bytes(channel.payload) }
        }
        var info = PSDBuffer()
        info.u32(0)
        info.bytes(records.data)
        info.bytes(payloads.data)
        if info.data.count % 2 == 1 { info.u8(0) }
        let layerBytes = info.data.count - 4
        info.data.replaceSubrange(0..<4, with: [
            UInt8(truncatingIfNeeded: layerBytes >> 24), UInt8(truncatingIfNeeded: layerBytes >> 16),
            UInt8(truncatingIfNeeded: layerBytes >> 8), UInt8(truncatingIfNeeded: layerBytes)
        ])
        var section = PSDBuffer()
        section.bytes(info.data)
        section.u32(0)
        return section.data
    }

    private static func layer(_ record: PSDRecord) throws -> Prepared {
        let image = record.image
        let width = image?.width ?? 0
        let height = image?.height ?? 0
        let left = Int(record.bounds.minX.rounded())
        let top = Int(record.bounds.minY.rounded())
        var channels: [(id: Int16, payload: Data)] = []
        if let image, width > 0, height > 0 {
            let planes = try planes(from: image)
            for (id, plane) in [(-1, planes.alpha), (0, planes.red), (1, planes.green), (2, planes.blue)] as [(Int16, [UInt8])] {
                channels.append((id, channelPayload(plane, width: width, height: height)))
            }
        } else {
            channels = emptyChannels()
        }
        if let mask = record.mask {
            let plane = try grayPlane(from: mask)
            channels.append((-2, channelPayload(plane, width: mask.width, height: mask.height)))
        }
        return Prepared(record: record, isDivider: false, channels: channels,
                        top: top, left: left, bottom: top + height, right: left + width,
                        maskTop: top, maskLeft: left,
                        maskBottom: top + (record.mask?.height ?? 0), maskRight: left + (record.mask?.width ?? 0))
    }

    private static func emptyLayer(name: String, blendKey: String, section: Int, visible: Bool = true, opacity: Double = 1, parent: UUID?, id: UUID? = nil, mask: CGImage? = nil, maskEnabled: Bool = true) throws -> Prepared {
        var record = PSDRecord(id: id ?? UUID(), parentID: parent, name: name)
        record.isGroup = section != 3
        record.isVisible = visible
        record.opacity = opacity
        record.blendKey = blendKey
        record.mask = mask
        record.maskEnabled = maskEnabled
        record.kind = .group
        var channels = emptyChannels()
        var maskBottom = 0, maskRight = 0
        if let mask {
            let plane = try grayPlane(from: mask)
            channels.append((-2, channelPayload(plane, width: mask.width, height: mask.height)))
            maskBottom = mask.height
            maskRight = mask.width
        }
        return Prepared(record: record, isDivider: section == 3, channels: channels,
                        maskBottom: maskBottom, maskRight: maskRight)
    }

    private static func emptyChannels() -> [(id: Int16, payload: Data)] {
        [(-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0]))]
    }

    private static func channelPayload(_ plane: [UInt8], width: Int, height: Int) -> Data {
        let encoded = encode(plane, width: width, height: height)
        var data = Data([UInt8(encoded.compression >> 8), UInt8(encoded.compression & 0xff)])
        data.append(encoded.data)
        return data
    }

    private static func writeRecord(_ buffer: inout PSDBuffer, _ item: Prepared) {
        let record = item.record
        buffer.i32(Int32(clamping: item.top))
        buffer.i32(Int32(clamping: item.left))
        buffer.i32(Int32(clamping: item.bottom))
        buffer.i32(Int32(clamping: item.right))
        buffer.u16(UInt16(item.channels.count))
        for channel in item.channels {
            buffer.i16(channel.id)
            buffer.u32(UInt32(channel.payload.count))
        }
        buffer.string("8BIM")
        let key = (record.blendKey + "    ").prefix(4)
        buffer.string(String(key))
        buffer.u8(UInt8(clamping: Int((record.opacity * 255).rounded())))
        buffer.u8(record.clipping ? 1 : 0)
        buffer.u8(record.isVisible ? 0 : 2)
        buffer.u8(0)
        let extra = extraData(item)
        buffer.u32(UInt32(extra.count))
        buffer.bytes(extra)
    }

    private static func extraData(_ item: Prepared) -> Data {
        var extra = PSDBuffer()
        if item.record.mask != nil, item.maskRight > item.maskLeft, item.maskBottom > item.maskTop {
            extra.u32(20)
            extra.i32(Int32(clamping: item.maskTop))
            extra.i32(Int32(clamping: item.maskLeft))
            extra.i32(Int32(clamping: item.maskBottom))
            extra.i32(Int32(clamping: item.maskRight))
            extra.u8(255)
            var flags: UInt8 = item.record.maskLinked ? 0 : 1
            if !item.record.maskEnabled { flags |= 2 }
            extra.u8(flags)
            extra.u16(0)
        } else {
            extra.u32(0)
        }
        extra.u32(0)
        let pascal = Array(item.record.name.utf8.prefix(255))
        extra.u8(UInt8(pascal.count))
        extra.bytes(Data(pascal))
        let nameBytes = 1 + pascal.count
        let pad = (4 - (nameBytes % 4)) % 4
        extra.bytes(Data(count: pad))
        writeAdditional(&extra, key: "luni", payload: luni(item.record.name))
        if item.record.isGroup || item.isDivider {
            let section: UInt32 = item.isDivider ? 3 : 1
            var payload = Data([0, 0, 0, UInt8(section)])
            payload.append(contentsOf: Array("8BIM".utf8))
            let blend = item.isDivider ? "norm" : ((item.record.blendKey == "pass" ? "pass" : item.record.blendKey) + "    ")
            payload.append(contentsOf: Array(blend.prefix(4).utf8))
            writeAdditional(&extra, key: "lsct", payload: payload)
        }
        return extra.data
    }

    private static func writeAdditional(_ buffer: inout PSDBuffer, key: String, payload: Data) {
        buffer.string("8BIM")
        buffer.string(key)
        buffer.u32(UInt32(payload.count))
        buffer.bytes(payload)
        if payload.count % 2 == 1 { buffer.u8(0) }
    }

    private static func luni(_ name: String) -> Data {
        let units = Array(name.utf16)
        let count = UInt32(units.count)
        var data = Data()
        data.appendUInt32(count)
        for unit in units {
            data.append(UInt8(truncatingIfNeeded: unit >> 8))
            data.append(UInt8(truncatingIfNeeded: unit))
        }
        return data
    }

    private static func resolutionResource(_ resolution: Double) -> Data {
        var resource = PSDBuffer()
        resource.string("8BIM")
        resource.u16(1005)
        resource.u8(0)
        resource.u8(0)
        resource.u32(16)
        let fixed = UInt32((min(9600, max(1, resolution)) * 65536).rounded())
        resource.u32(fixed)
        resource.u16(1)
        resource.u16(1)
        resource.u32(fixed)
        resource.u16(1)
        resource.u16(1)
        return resource.data
    }

    private static func appendComposite(_ file: inout PSDBuffer, _ image: CGImage, width: Int, height: Int) throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let flattened = context.makeImage() else { throw ExportError.render }
        let planes = try planes(from: flattened)
        file.u16(1)
        var counts = Data()
        var packed = Data()
        for plane in [planes.red, planes.green, planes.blue, planes.alpha] {
            let encoded = encode(plane, width: width, height: height)
            counts.append(encoded.data.prefix(height * 2))
            packed.append(encoded.data.dropFirst(height * 2))
        }
        file.bytes(counts)
        file.bytes(packed)
    }

    private static func encode(_ plane: [UInt8], width: Int, height: Int) -> (compression: UInt16, data: Data) {
        guard width > 0, height > 0, plane.count >= width * height else {
            return (0, Data())
        }
        var counts = Data()
        var packed = Data()
        counts.reserveCapacity(height * 2)
        for row in 0..<height {
            let slice = plane[row * width ..< (row + 1) * width]
            let encoded = packBits(Array(slice))
            counts.append(UInt8(truncatingIfNeeded: encoded.count >> 8))
            counts.append(UInt8(truncatingIfNeeded: encoded.count))
            packed.append(encoded)
        }
        var data = counts
        data.append(packed)
        return (1, data)
    }

    /// Premultiplied RGBA, first row at the top of the image.
    private static func planes(from image: CGImage) throws -> (red: [UInt8], green: [UInt8], blue: [UInt8], alpha: [UInt8]) {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var red = [UInt8](repeating: 0, count: width * height)
        var green = [UInt8](repeating: 0, count: width * height)
        var blue = [UInt8](repeating: 0, count: width * height)
        var alpha = [UInt8](repeating: 0, count: width * height)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width {
                let i = y * width + x
                let p = y * stride + x * 4
                let r = data[p], g = data[p + 1], b = data[p + 2], a = data[p + 3]
                alpha[i] = a
                if a == 0 {
                    red[i] = 0; green[i] = 0; blue[i] = 0
                } else {
                    red[i] = UInt8(min(255, (Int(r) * 255 + Int(a) / 2) / Int(a)))
                    green[i] = UInt8(min(255, (Int(g) * 255 + Int(a) / 2) / Int(a)))
                    blue[i] = UInt8(min(255, (Int(b) * 255 + Int(a) / 2) / Int(a)))
                }
            }
        }
        return (red, green, blue, alpha)
    }

    private static func grayPlane(from image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: true, context: context)
        guard let data = context.data?.assumingMemoryBound(to: UInt8.self) else { throw ExportError.render }
        var plane = [UInt8](repeating: 0, count: width * height)
        let stride = context.bytesPerRow
        for y in 0..<height {
            for x in 0..<width { plane[y * width + x] = data[y * stride + x] }
        }
        return plane
    }

    private static func packBits(_ row: [UInt8]) -> Data {
        var output = Data()
        var i = 0
        while i < row.count {
            if i + 1 < row.count, row[i] == row[i + 1] {
                var run = 2
                while i + run < row.count, row[i + run] == row[i], run < 128 { run += 1 }
                output.append(UInt8(bitPattern: Int8(1 - run)))
                output.append(row[i])
                i += run
            } else {
                let start = i
                i += 1
                while i < row.count, i - start < 128 {
                    if i + 1 < row.count, row[i] == row[i + 1] { break }
                    i += 1
                }
                output.append(UInt8(i - start - 1))
                output.append(contentsOf: row[start..<i])
            }
        }
        return output
    }
}

nonisolated private struct PSDBuffer: Sendable {
    var data = Data()
    mutating func u8(_ value: UInt8) { data.append(value) }
    mutating func u16(_ value: UInt16) { data.appendUInt16(value) }
    mutating func i16(_ value: Int16) { u16(UInt16(bitPattern: value)) }
    mutating func u32(_ value: UInt32) { data.appendUInt32(value) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func string(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
}

extension Data {
    fileprivate mutating func appendUInt16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
    fileprivate mutating func appendUInt32(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
