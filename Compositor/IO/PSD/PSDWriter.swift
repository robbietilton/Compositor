import CoreGraphics
import Foundation

nonisolated enum PSDWriter {
    static func encode(_ snapshot: ProjectSnapshot, composite: CGImage) throws -> Data {
        let manifest = snapshot.manifest
        guard (1...30_000).contains(manifest.width), (1...30_000).contains(manifest.height),
              manifest.width * manifest.height <= 100_000_000, manifest.layers.count <= 10_000 else {
            throw PSDError.tooLarge
        }
        try LayerHierarchy.validate(manifest.layers)
        var file = PSDBuffer()
        file.fourCC(PSDFourCC.file)
        file.u16(1)
        file.append([UInt8](repeating: 0, count: 6))
        file.u16(3)
        file.u32(UInt32(manifest.height))
        file.u32(UInt32(manifest.width))
        file.u16(8)
        file.u16(3)
        file.u32(0) // Color mode data.
        writeResources(&file, snapshot)
        try writeLayers(&file, snapshot)
        try writeComposite(&file, composite)
        return file.data
    }

    private static func writeResources(_ file: inout PSDBuffer, _ snapshot: ProjectSnapshot) {
        let start = file.count
        file.u32(0)
        writeResource(&file, id: 1005) { resource in
            let fixed = Int32((snapshot.manifest.resolution ?? 72) * 65536)
            resource.i32(fixed)
            resource.u16(1)
            resource.u16(1)
            resource.i32(fixed)
            resource.u16(1)
            resource.u16(1)
        }
        writeResource(&file, id: 1024) { resource in
            let index = snapshot.manifest.layers.firstIndex(where: { $0.id == snapshot.manifest.activeLayerID }) ?? 0
            resource.u16(UInt16(min(index, Int(UInt16.max))))
        }
        file.patchU32(at: start, UInt32(file.count - start - 4))
    }

    private static func writeResource(_ file: inout PSDBuffer, id: UInt16, body: (inout PSDBuffer) -> Void) {
        file.fourCC(PSDFourCC.resource)
        file.u16(id)
        file.u8(0) // Empty Pascal name.
        file.u8(0) // Pad name to even.
        let start = file.count
        file.u32(0)
        var payload = PSDBuffer()
        body(&payload)
        file.append(payload.data)
        file.patchU32(at: start, UInt32(payload.count))
        if payload.count % 2 == 1 { file.u8(0) }
    }

    private struct WrittenLayer {
        var top, left, bottom, right: Int
        var name: String
        var visible: Bool
        var opacity: UInt8
        var clipped: Bool
        var blend: UInt32
        var section: UInt32? // 1 folder, 3 divider
        var adjustment: LayerAdjustment?
        var pixels: PSDPixels.RGBA?
        var mask: (plane: [UInt8], top: Int, left: Int, bottom: Int, right: Int, disabled: Bool)?
        var irrelevant: Bool
    }

    private static func writeLayers(_ file: inout PSDBuffer, _ snapshot: ProjectSnapshot) throws {
        let layers = try flatten(snapshot)
        guard layers.count <= 32_767 else { throw PSDError.tooLarge }
        let start = file.count
        file.u32(0)
        let infoStart = file.count
        file.u32(0)
        file.i16(Int16(layers.count))
        var channelData: [Data] = []
        channelData.reserveCapacity(layers.count)
        for layer in layers {
            let packed = try writeLayerRecord(&file, layer)
            channelData.append(packed)
        }
        for data in channelData { file.append(data) }
        if (file.count - infoStart - 4) % 2 == 1 { file.u8(0) }
        file.patchU32(at: infoStart, UInt32(file.count - infoStart - 4))
        file.u32(0) // Global layer mask.
        file.patchU32(at: start, UInt32(file.count - start - 4))
    }

    private static func flatten(_ snapshot: ProjectSnapshot) throws -> [WrittenLayer] {
        let children = Dictionary(grouping: snapshot.manifest.layers, by: \.parentID)
        var result: [WrittenLayer] = []
        func visit(_ parent: UUID?) throws {
            for record in children[parent] ?? [] {
                if record.isGroup == true {
                    result.append(WrittenLayer(top: 0, left: 0, bottom: 0, right: 0, name: "</Layer group>",
                        visible: true, opacity: 255, clipped: false, blend: PSDFourCC.code("norm"),
                        section: 3, adjustment: nil, pixels: nil, mask: nil, irrelevant: true))
                    try visit(record.id)
                    result.append(try written(record, snapshot, section: 1))
                } else {
                    result.append(try written(record, snapshot, section: nil))
                }
            }
        }
        try visit(nil)
        return result
    }

    private static func written(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot, section: UInt32?) throws -> WrittenLayer {
        let clipped = record.maskSourceID != nil
        if record.isGroup == true {
            var layer = WrittenLayer(top: 0, left: 0, bottom: 0, right: 0, name: record.name, visible: record.isVisible,
                opacity: 255, clipped: false, blend: PSDFourCC.code("pass"), section: section, adjustment: nil,
                pixels: nil, mask: nil, irrelevant: true)
            layer.mask = try maskChannel(record, snapshot)
            return layer
        }
        if let adjustment = record.adjustment {
            var layer = WrittenLayer(top: 0, left: 0, bottom: 0, right: 0, name: record.name, visible: record.isVisible,
                opacity: UInt8(((record.opacity ?? 1) * 255).rounded()), clipped: clipped,
                blend: PSDBlend.key(for: record.blendMode ?? .normal), section: nil, adjustment: adjustment,
                pixels: nil, mask: nil, irrelevant: true)
            layer.mask = try maskChannel(record, snapshot)
            return layer
        }
        let (pixels, left, top) = try raster(record, snapshot)
        var layer = WrittenLayer(top: top, left: left, bottom: top + (pixels?.height ?? 0), right: left + (pixels?.width ?? 0),
            name: record.name, visible: record.isVisible,
            opacity: UInt8(((record.opacity ?? 1) * 255).rounded()), clipped: clipped,
            blend: PSDBlend.key(for: record.blendMode ?? .normal), section: nil, adjustment: nil,
            pixels: pixels, mask: nil, irrelevant: false)
        layer.mask = try maskChannel(record, snapshot, fallback: pixels.map { (top, left, $0.width, $0.height) })
        return layer
    }

    private static func raster(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot) throws -> (pixels: PSDPixels.RGBA?, left: Int, top: Int) {
        guard let asset = snapshot.images[record.id] else { return (nil, 0, 0) }
        let image = asset.image
        let transform = record.transform
        let identity = transform.rotation == 0 && !transform.flipX && !transform.flipY
            && Int(transform.size.width.rounded()) == image.width
            && Int(transform.size.height.rounded()) == image.height
        if identity {
            return (try PSDPixels.rgba(from: image), Int(transform.origin.x.rounded()), Int(transform.origin.y.rounded()))
        }
        let corners = [CGPoint(x: 0, y: 0), CGPoint(x: 1, y: 0), CGPoint(x: 1, y: 1), CGPoint(x: 0, y: 1)].map(transform.point)
        let minX = Int(floor(corners.map(\.x).min() ?? 0))
        let minY = Int(floor(corners.map(\.y).min() ?? 0))
        let maxX = Int(ceil(corners.map(\.x).max() ?? 0))
        let maxY = Int(ceil(corners.map(\.y).max() ?? 0))
        let width = max(1, maxX - minX), height = max(1, maxY - minY)
        guard width <= 30_000, height <= 30_000, width * height <= 100_000_000 else { throw PSDError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.translateBy(x: CGFloat(-minX), y: CGFloat(-minY))
        LayerRenderer.draw(image, transform: transform, center: transform.center, opacity: 1, blendMode: .normal, in: context)
        guard let rendered = context.makeImage() else { throw PSDError.encode }
        return (try PSDPixels.rgba(from: rendered), minX, minY)
    }

    private static func maskChannel(_ record: ProjectLayerRecord, _ snapshot: ProjectSnapshot,
                                    fallback: (Int, Int, Int, Int)? = nil) throws -> (plane: [UInt8], top: Int, left: Int, bottom: Int, right: Int, disabled: Bool)? {
        guard let mask = snapshot.mask(for: record) else { return nil }
        let image = mask.asset.image
        if let placement = mask.placement {
            let top = Int(placement.origin.y.rounded()), left = Int(placement.origin.x.rounded())
            return (try PSDPixels.maskPlane(image), top, left, top + image.height, left + image.width, !mask.isEnabled)
        }
        let top: Int, left: Int, width: Int, height: Int
        if let fallback {
            (top, left, width, height) = fallback
        } else {
            top = Int(record.transform.origin.y.rounded())
            left = Int(record.transform.origin.x.rounded())
            width = max(1, Int(record.transform.size.width.rounded()))
            height = max(1, Int(record.transform.size.height.rounded()))
        }
        let context = try BrushRaster.context(width: width, height: height, mask: true)
        LayerMask.drawSmooth(image, in: CGRect(x: 0, y: 0, width: width, height: height), context: context)
        guard let stretched = context.makeImage() else { throw PSDError.encode }
        return (try PSDPixels.maskPlane(stretched), top, left, top + height, left + width, !mask.isEnabled)
    }

    private static func writeLayerRecord(_ file: inout PSDBuffer, _ layer: WrittenLayer) throws -> Data {
        file.i32(Int32(layer.top))
        file.i32(Int32(layer.left))
        file.i32(Int32(layer.bottom))
        file.i32(Int32(layer.right))
        var channels: [(Int16, Data)] = []
        if let pixels = layer.pixels {
            channels.append((-1, PSDPackBits.packPlane(pixels.a, width: pixels.width, height: pixels.height)))
            channels.append((0, PSDPackBits.packPlane(pixels.r, width: pixels.width, height: pixels.height)))
            channels.append((1, PSDPackBits.packPlane(pixels.g, width: pixels.width, height: pixels.height)))
            channels.append((2, PSDPackBits.packPlane(pixels.b, width: pixels.width, height: pixels.height)))
        } else {
            let empty = Data([0, 0])
            channels.append((-1, empty))
            channels.append((0, empty))
            channels.append((1, empty))
            channels.append((2, empty))
        }
        if let mask = layer.mask {
            let width = mask.right - mask.left, height = mask.bottom - mask.top
            channels.append((-2, PSDPackBits.packPlane(mask.plane, width: width, height: height)))
        }
        file.u16(UInt16(channels.count))
        for (id, data) in channels {
            file.i16(id)
            file.u32(UInt32(data.count))
        }
        file.fourCC(PSDFourCC.resource)
        file.u32(layer.blend)
        file.u8(layer.opacity)
        file.u8(layer.clipped ? 1 : 0)
        var flags: UInt8 = 0x08
        if !layer.visible { flags |= 0x02 }
        if layer.irrelevant { flags |= 0x18 }
        file.u8(flags)
        file.u8(0)
        let extraStart = file.count
        file.u32(0)
        if let mask = layer.mask {
            file.u32(20)
            file.i32(Int32(mask.top))
            file.i32(Int32(mask.left))
            file.i32(Int32(mask.bottom))
            file.i32(Int32(mask.right))
            file.u8(255)
            var maskFlags: UInt8 = 0
            if mask.disabled { maskFlags |= 0x02 }
            file.u8(maskFlags)
            file.u16(0)
        } else {
            file.u32(0)
        }
        file.u32(0) // Blending ranges.
        file.pascal(layer.name, paddedTo: 4)
        writeExtra(&file, key: "luni") { $0.unicode(layer.name) }
        if let section = layer.section {
            writeExtra(&file, key: "lsct") { extra in
                extra.u32(section)
                if section != 3 {
                    extra.fourCC(PSDFourCC.resource)
                    extra.u32(layer.blend)
                }
            }
        }
        if let adjustment = layer.adjustment {
            switch adjustment.kind {
            case .levels: writeExtra(&file, key: "levl") { writeLevels(&$0, adjustment.levels) }
            case .curves: writeExtra(&file, key: "curv") { writeCurves(&$0, adjustment.curves) }
            case .hsv: writeExtra(&file, key: "hue2") { writeHue(&$0, adjustment.resolvedHSV) }
            default: break
            }
        }
        file.patchU32(at: extraStart, UInt32(file.count - extraStart - 4))
        var payload = Data()
        for (_, data) in channels { payload.append(data) }
        return payload
    }

    private static func writeExtra(_ file: inout PSDBuffer, key: String, body: (inout PSDBuffer) -> Void) {
        file.fourCC(PSDFourCC.resource)
        file.fourCC(key)
        let start = file.count
        file.u32(0)
        var payload = PSDBuffer()
        body(&payload)
        file.append(payload.data)
        if payload.count % 2 == 1 { file.u8(0) }
        file.patchU32(at: start, UInt32(payload.count + payload.count % 2))
    }

    private static func writeLevels(_ file: inout PSDBuffer, _ settings: LevelsSettings) {
        file.u16(2)
        for i in 0..<29 {
            let range = i < 4 ? settings.ranges[i].normalized : LevelRange()
            file.u16(UInt16(range.black.rounded()))
            file.u16(UInt16(range.white.rounded()))
            file.u16(UInt16(range.outputBlack.rounded()))
            file.u16(UInt16(range.outputWhite.rounded()))
            file.u16(UInt16((range.gamma * 100).rounded()))
        }
    }

    private static func writeCurves(_ file: inout PSDBuffer, _ settings: CurvesSettings) {
        file.u16(4)
        file.u16(4)
        for channel in settings.channels.prefix(4) {
            let points = Array(channel.prefix(19))
            file.u16(UInt16(points.count))
            for point in points {
                file.u16(UInt16(point.y.rounded()))
                file.u16(UInt16(point.x.rounded()))
            }
        }
    }

    private static func writeHue(_ file: inout PSDBuffer, _ settings: HueSaturationSettings) {
        file.u16(2)
        file.u8(settings.colorize ? 1 : 0)
        file.u8(0)
        func triplet(_ hue: Double, _ saturation: Double, _ lightness: Double) {
            file.i16(Int16(hue.rounded()))
            file.i16(Int16(saturation.rounded()))
            file.i16(Int16(lightness.rounded()))
        }
        let master = settings.adjustments[.master] ?? RangeAdjustment()
        if settings.colorize {
            var hue = master.hue
            if hue > 180 { hue -= 360 }
            triplet(hue, master.saturation, master.lightness)
            triplet(0, 0, 0)
        } else {
            triplet(0, 0, 0)
            triplet(master.hue, master.saturation, master.lightness)
        }
        for range in [ColorRange.reds, .yellows, .greens, .cyans, .blues, .magentas] {
            let band = settings.bands[range] ?? range.defaultBand
            file.i16(Int16(band.falloffStart.rounded()))
            file.i16(Int16(band.rangeStart.rounded()))
            file.i16(Int16(band.rangeEnd.rounded()))
            file.i16(Int16(band.falloffEnd.rounded()))
            let values = settings.adjustments[range] ?? RangeAdjustment()
            triplet(values.hue, values.saturation, values.lightness)
        }
    }

    private static func writeComposite(_ file: inout PSDBuffer, _ image: CGImage) throws {
        let planes = try PSDPixels.rgba(from: image)
        file.u16(1)
        var counts = Data()
        var payload = Data()
        for plane in [planes.r, planes.g, planes.b] {
            for y in 0..<planes.height {
                let packed = PSDPackBits.pack(plane[(y * planes.width)..<((y + 1) * planes.width)])
                let count = UInt16(min(packed.count, Int(UInt16.max)))
                counts.append(UInt8(count >> 8))
                counts.append(UInt8(count & 0xff))
                payload.append(contentsOf: packed)
            }
        }
        file.append(counts)
        file.append(payload)
    }
}
