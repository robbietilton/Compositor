import CoreGraphics
import Foundation
@testable import Compositor

/// Builds tiny Photoshop files for reader tests. Not part of the app; Compositor does not write PSD.
nonisolated enum PSDFixture {
    static func data(_ document: PSDDocument, composite: CGImage, largeDocument: Bool = false,
                     extras: [UUID: [String: Data]] = [:]) throws -> Data {
        try data(document, composite: composite, largeDocument: largeDocument, additionalLayerInfo: nil, extras: extras)
    }

    struct AdditionalLayerInfo: Sendable {
        let key: String
        let payload: Data
    }

    static func data(_ document: PSDDocument, composite: CGImage, largeDocument: Bool, additionalLayerInfo: AdditionalLayerInfo?,
                     extras: [UUID: [String: Data]] = [:]) throws -> Data {
        let width = document.width, height = document.height
        guard (1...30_000).contains(width), (1...30_000).contains(height) else { throw ImageImportError.tooLarge }
        var file = PSDBuffer()
        file.string("8BPS")
        file.u16(largeDocument ? 2 : 1)
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
        let layers = try layerSection(document, largeDocument: largeDocument, additionalLayerInfo: additionalLayerInfo, extras: extras)
        if largeDocument { file.u64(UInt64(layers.count)) }
        else { file.u32(UInt32(layers.count)) }
        file.bytes(layers)
        try appendComposite(&file, composite, width: width, height: height, largeDocument: largeDocument)
        return file.data
    }

    private struct Prepared {
        var record: PSDRecord
        var isDivider: Bool
        var channels: [(id: Int16, payload: Data)]
        var top = 0, left = 0, bottom = 0, right = 0
        var maskTop = 0, maskLeft = 0, maskBottom = 0, maskRight = 0
        var extras: [String: Data] = [:]
    }

    private static func layerSection(_ document: PSDDocument, largeDocument: Bool, additionalLayerInfo: AdditionalLayerInfo?,
                                     extras: [UUID: [String: Data]]) throws -> Data {
        var prepared: [Prepared] = []
        func emit(_ parent: UUID?) throws {
            // File order is bottom-to-top. Photoshop groups are type 3, children, then type 1/2.
            for record in document.layers where record.parentID == parent {
                if record.isGroup {
                    prepared.append(try emptyLayer(name: "</Layer group>", blendKey: "norm", section: 3, parent: parent, largeDocument: largeDocument))
                    try emit(record.id)
                    prepared.append(try emptyLayer(name: record.name, blendKey: record.blendKey == "pass" ? "pass" : record.blendKey,
                                                   section: 1, visible: record.isVisible, opacity: record.opacity, parent: record.parentID, id: record.id, mask: record.mask, maskEnabled: record.maskEnabled, largeDocument: largeDocument))
                } else {
                    prepared.append(try layer(record, largeDocument: largeDocument, extras: extras[record.id] ?? [:]))
                }
            }
        }
        try emit(nil)
        guard prepared.count <= Int(Int16.max) else { throw ImageImportError.tooLarge }
        var records = PSDBuffer()
        records.i16(Int16(prepared.count))
        var payloads = PSDBuffer()
        for item in prepared {
            writeRecord(&records, item, largeDocument: largeDocument, additionalLayerInfo: additionalLayerInfo)
            for channel in item.channels { payloads.bytes(channel.payload) }
        }
        var info = PSDBuffer()
        if largeDocument { info.u64(0) }
        else { info.u32(0) }
        info.bytes(records.data)
        info.bytes(payloads.data)
        if info.data.count % 2 == 1 { info.u8(0) }
        let lengthFieldBytes = largeDocument ? 8 : 4
        let layerBytes = info.data.count - lengthFieldBytes
        var length = PSDBuffer()
        if largeDocument { length.u64(UInt64(layerBytes)) }
        else { length.u32(UInt32(layerBytes)) }
        info.data.replaceSubrange(0..<lengthFieldBytes, with: length.data)
        var section = PSDBuffer()
        section.bytes(info.data)
        section.u32(0)
        return section.data
    }

    private static func layer(_ record: PSDRecord, largeDocument: Bool, extras: [String: Data] = [:]) throws -> Prepared {
        let image = record.image
        let width = image?.width ?? 0
        let height = image?.height ?? 0
        let left = Int(record.bounds.minX.rounded())
        let top = Int(record.bounds.minY.rounded())
        var channels: [(id: Int16, payload: Data)] = []
        if let image, width > 0, height > 0 {
            let planes = try planes(from: image)
            for (id, plane) in [(-1, planes.alpha), (0, planes.red), (1, planes.green), (2, planes.blue)] as [(Int16, [UInt8])] {
                channels.append((id, channelPayload(plane, width: width, height: height, largeDocument: largeDocument)))
            }
        } else {
            channels = emptyChannels()
        }
        if let mask = record.mask {
            let plane = try grayPlane(from: mask)
            channels.append((-2, channelPayload(plane, width: mask.width, height: mask.height, largeDocument: largeDocument)))
        }
        return Prepared(record: record, isDivider: false, channels: channels,
                        top: top, left: left, bottom: top + height, right: left + width,
                        maskTop: top, maskLeft: left,
                        maskBottom: top + (record.mask?.height ?? 0), maskRight: left + (record.mask?.width ?? 0),
                        extras: extras)
    }

    private static func emptyLayer(name: String, blendKey: String, section: Int, visible: Bool = true, opacity: Double = 1, parent: UUID?, id: UUID? = nil, mask: CGImage? = nil, maskEnabled: Bool = true, largeDocument: Bool) throws -> Prepared {
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
            channels.append((-2, channelPayload(plane, width: mask.width, height: mask.height, largeDocument: largeDocument)))
            maskBottom = mask.height
            maskRight = mask.width
        }
        return Prepared(record: record, isDivider: section == 3, channels: channels,
                        maskBottom: maskBottom, maskRight: maskRight)
    }

    private static func emptyChannels() -> [(id: Int16, payload: Data)] {
        [(-1, Data([0, 0])), (0, Data([0, 0])), (1, Data([0, 0])), (2, Data([0, 0]))]
    }

    private static func channelPayload(_ plane: [UInt8], width: Int, height: Int, largeDocument: Bool) -> Data {
        let encoded = encode(plane, width: width, height: height, largeDocument: largeDocument)
        var data = Data([UInt8(encoded.compression >> 8), UInt8(encoded.compression & 0xff)])
        data.append(encoded.data)
        return data
    }

    private static func writeRecord(_ buffer: inout PSDBuffer, _ item: Prepared, largeDocument: Bool, additionalLayerInfo: AdditionalLayerInfo?) {
        let record = item.record
        buffer.i32(Int32(clamping: item.top))
        buffer.i32(Int32(clamping: item.left))
        buffer.i32(Int32(clamping: item.bottom))
        buffer.i32(Int32(clamping: item.right))
        buffer.u16(UInt16(item.channels.count))
        for channel in item.channels {
            buffer.i16(channel.id)
            if largeDocument { buffer.u64(UInt64(channel.payload.count)) }
            else { buffer.u32(UInt32(channel.payload.count)) }
        }
        buffer.string("8BIM")
        let key = (record.blendKey + "    ").prefix(4)
        buffer.string(String(key))
        buffer.u8(UInt8(clamping: Int((record.opacity * 255).rounded())))
        buffer.u8(record.clipping ? 1 : 0)
        buffer.u8(record.isVisible ? 0 : 2)
        buffer.u8(0)
        let extra = extraData(item, largeDocument: largeDocument, additionalLayerInfo: additionalLayerInfo, extras: item.extras)
        buffer.u32(UInt32(extra.count))
        buffer.bytes(extra)
    }

    private static func extraData(_ item: Prepared, largeDocument: Bool, additionalLayerInfo: AdditionalLayerInfo?, extras: [String: Data]) -> Data {
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
        if let additionalLayerInfo {
            writeAdditional(&extra, key: additionalLayerInfo.key, payload: additionalLayerInfo.payload, largeDocument: largeDocument)
        }
        writeAdditional(&extra, key: "luni", payload: luni(item.record.name), largeDocument: largeDocument)
        if item.record.isGroup || item.isDivider {
            let section: UInt32 = item.isDivider ? 3 : 1
            var payload = Data([0, 0, 0, UInt8(section)])
            payload.append(contentsOf: Array("8BIM".utf8))
            let blend = item.isDivider ? "norm" : ((item.record.blendKey == "pass" ? "pass" : item.record.blendKey) + "    ")
            payload.append(contentsOf: Array(blend.prefix(4).utf8))
            writeAdditional(&extra, key: "lsct", payload: payload, largeDocument: largeDocument)
        }
        for key in extras.keys.sorted() {
            if let payload = extras[key] { writeAdditional(&extra, key: key, payload: payload, largeDocument: largeDocument) }
        }
        return extra.data
    }

    private static func writeAdditional(_ buffer: inout PSDBuffer, key: String, payload: Data, largeDocument: Bool) {
        buffer.string("8BIM")
        buffer.string(key)
        if largeDocument && ["LMsk", "Lr16", "Lr32", "Layr", "Mt16", "Mt32", "Mtrn", "Alph", "FMsk", "lnk2", "FEid", "FXid", "PxSD"].contains(key) {
            buffer.u64(UInt64(payload.count))
        } else { buffer.u32(UInt32(payload.count)) }
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

    /// A Photoshop 6 `TySh` block. The descriptor layout matches Adobe’s type-tool object setting.
    static func tySh(text: String, font: String = "Helvetica", fontSize: Double = 24,
                     red: Double = 0, green: Double = 0, blue: Double = 0,
                     justification: Int = 0, tracking: Double = 0, leading: Double? = nil,
                     fauxBold: Bool = false, fauxItalic: Bool = false, vertical: Bool = false, warp: Bool = false,
                     secondSize: Double? = nil, secondLeading: Double? = nil,
                     secondHorizontalScale: Double? = nil, secondVerticalScale: Double? = nil,
                     tx: Double = 40, ty: Double = 50,
                     xx: Double = 1, xy: Double = 0, yx: Double = 0, yy: Double = 1,
                     bounds: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil,
                     glyphBounds: (CGFloat, CGFloat, CGFloat, CGFloat)? = nil) -> Data {
        var block = PSDBuffer()
        block.u16(1)
        for value in [xx, xy, yx, yy, tx, ty] { block.f64(value) }
        block.u16(50)
        var items: [(String, Data)] = [
            ("Txt ", textItem(text)),
            ("Ornt", enumItem(type: "Ornt", value: vertical ? "Vrtc" : "Hrzn"))
        ]
        if let bounds {
            items.append(("bounds", rectItem(bounds)))
        }
        if let glyphBounds {
            items.append(("boundingBox", rectItem(glyphBounds)))
        }
        items.append(("EngineData", rawItem(Data(engine(text: text, font: font, fontSize: fontSize, red: red, green: green, blue: blue, justification: justification, tracking: tracking, leading: leading, fauxBold: fauxBold, fauxItalic: fauxItalic, secondSize: secondSize, secondLeading: secondLeading, secondHorizontalScale: secondHorizontalScale, secondVerticalScale: secondVerticalScale).utf8))))
        block.descriptor(classID: "TxLr", items: items)
        block.u16(1)
        block.descriptor(classID: "warp", items: [("warpStyle", enumItem(type: "warpStyle", value: warp ? "warpArc" : "warpNone"))])
        return block.data
    }

    private static func engine(text: String, font: String, fontSize: Double, red: Double, green: Double, blue: Double, justification: Int, tracking: Double, leading: Double?, fauxBold: Bool, fauxItalic: Bool, secondSize: Double?, secondLeading: Double?, secondHorizontalScale: Double?, secondVerticalScale: Double?) -> String {
        let run = { (size: Double, runLeading: Double?, horizontal: Double, vertical: Double) in """
<<
/StyleSheet
<<
/StyleSheetData
<<
/Font 0
/FontSize \(size)
/FauxBold \(fauxBold)
/FauxItalic \(fauxItalic)
/AutoLeading \(runLeading == nil)
/Leading \(runLeading ?? size * 1.2)
/Tracking \(tracking)
/HorizontalScale \(horizontal)
/VerticalScale \(vertical)
/FillColor
<<
/Type 1
/Values [ 1.0 \(red) \(green) \(blue) ]
>>
>>
>>
>>
""" }
        let hasSecond = secondSize != nil || secondLeading != nil || secondHorizontalScale != nil || secondVerticalScale != nil
        let runs = hasSecond
            ? "\(run(fontSize, leading, 1, 1))\n\(run(secondSize ?? fontSize, secondLeading ?? leading, secondHorizontalScale ?? 1, secondVerticalScale ?? 1))"
            : run(fontSize, leading, 1, 1)
        return """
<<
/EngineDict
<<
/Editor
<<
/Text \(parenthesized(text))
>>
/ParagraphRun
<<
/RunArray
[
<<
/ParagraphSheet
<<
/Properties
<<
/Justification \(justification)
>>
>>
>>
]
>>
/StyleRun
<<
/RunArray
[
\(runs)
]
>>
>>
/ResourceDict
<<
/FontSet
[
<<
/Name \(parenthesized(font))
>>
]
>>
>>
"""
    }

    private static func parenthesized(_ text: String) -> String {
        var encoded = "("
        for byte in text.utf8 {
            if byte == UInt8(ascii: "\\") || byte == UInt8(ascii: "(") || byte == UInt8(ascii: ")") {
                encoded.append("\\")
            }
            encoded.append(Character(UnicodeScalar(byte)))
        }
        encoded.append(")")
        return encoded
    }

    private static func textItem(_ text: String) -> Data {
        var item = PSDBuffer()
        item.string("TEXT")
        item.utf16(text)
        return item.data
    }

    private static func enumItem(type: String, value: String) -> Data {
        var item = PSDBuffer()
        item.string("enum")
        item.id(type)
        item.id(value)
        return item.data
    }

    private static func rawItem(_ payload: Data) -> Data {
        var item = PSDBuffer()
        item.string("tdta")
        item.u32(UInt32(payload.count))
        item.bytes(payload)
        return item.data
    }

    private static func rectItem(_ box: (CGFloat, CGFloat, CGFloat, CGFloat)) -> Data {
        var item = PSDBuffer()
        item.string("Objc")
        item.u32(0)
        item.id("Rctn")
        item.u32(4)
        for (key, value) in [("Left", box.0), ("Top ", box.1), ("Rght", box.2), ("Btom", box.3)] {
            item.id(key)
            item.string("UntF")
            item.string("#Pnt")
            item.f64(Double(value))
        }
        return item.data
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

    private static func appendComposite(_ file: inout PSDBuffer, _ image: CGImage, width: Int, height: Int, largeDocument: Bool) throws {
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height), mask: false, context: context)
        guard let flattened = context.makeImage() else { throw ExportError.render }
        let planes = try planes(from: flattened)
        file.u16(1)
        var counts = Data()
        var packed = Data()
        for plane in [planes.red, planes.green, planes.blue, planes.alpha] {
            let encoded = encode(plane, width: width, height: height, largeDocument: largeDocument)
            let countBytes = height * (largeDocument ? 4 : 2)
            counts.append(encoded.data.prefix(countBytes))
            packed.append(encoded.data.dropFirst(countBytes))
        }
        file.bytes(counts)
        file.bytes(packed)
    }

    private static func encode(_ plane: [UInt8], width: Int, height: Int, largeDocument: Bool = false) -> (compression: UInt16, data: Data) {
        guard width > 0, height > 0, plane.count >= width * height else {
            return (0, Data())
        }
        var counts = Data()
        var packed = Data()
        counts.reserveCapacity(height * (largeDocument ? 4 : 2))
        for row in 0..<height {
            let slice = plane[row * width ..< (row + 1) * width]
            let encoded = packBits(Array(slice))
            if largeDocument {
                counts.append(UInt8(truncatingIfNeeded: encoded.count >> 24))
                counts.append(UInt8(truncatingIfNeeded: encoded.count >> 16))
            }
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
    mutating func u64(_ value: UInt64) { data.appendUInt64(value) }
    mutating func i32(_ value: Int32) { u32(UInt32(bitPattern: value)) }
    mutating func f64(_ value: Double) {
        var bits = value.bitPattern.bigEndian
        withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
    }
    mutating func bytes(_ value: Data) { data.append(value) }
    mutating func string(_ value: String) { data.append(contentsOf: Array(value.utf8)) }
    mutating func utf16(_ value: String) {
        let units = Array(value.utf16)
        u32(UInt32(units.count))
        for unit in units { u16(unit) }
    }
    mutating func id(_ value: String) {
        let bytes = Array(value.utf8)
        if bytes.count == 4 {
            u32(0)
            data.append(contentsOf: bytes)
        } else {
            u32(UInt32(bytes.count))
            data.append(contentsOf: bytes)
        }
    }
    mutating func descriptor(classID: String, items: [(String, Data)]) {
        u32(16)
        u32(0)
        id(classID)
        u32(UInt32(items.count))
        for (key, value) in items {
            id(key)
            bytes(value)
        }
    }
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
    fileprivate mutating func appendUInt64(_ value: UInt64) {
        append(UInt8(truncatingIfNeeded: value >> 56))
        append(UInt8(truncatingIfNeeded: value >> 48))
        append(UInt8(truncatingIfNeeded: value >> 40))
        append(UInt8(truncatingIfNeeded: value >> 32))
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
