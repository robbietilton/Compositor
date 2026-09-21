import Foundation
import CoreGraphics
import Accelerate

nonisolated struct PSDImportedDocument: Sendable {
    let name: String
    let snapshot: ProjectSnapshot
}

/// What an import did beyond the happy path, composed into one user-facing message.
nonisolated struct PSDImportSummary: Sendable {
    var artboards = 0
    var emptyLayersSkipped = 0
    var zipLayersSkipped = 0
    var damagedLayersSkipped = 0
    var oversizeLayersSkipped = 0
    var masksSkipped = 0
    var oversizeArtboards: [String] = []
    var outOfArtboardLayers = 0
    var darkerColorLayers = 0
    var unknownBlendLayers = 0
    var droppedClipping = 0
    var groupOpacityClamped = 0
    var artboardMasksDropped = 0

    var text: String? {
        var lines = [String]()
        if artboards > 1 { lines.append("The PSD’s \(artboards) artboards were imported as separate documents.") }
        if !oversizeArtboards.isEmpty {
            lines.append("Skipped artboards beyond the 100-megapixel or 30,000-pixel budget: "
                + oversizeArtboards.joined(separator: ", ") + ".")
        }
        if emptyLayersSkipped > 0 {
            lines.append("\(emptyLayersSkipped) layer(s) held no pixels (typically adjustment layers such as Hue/Saturation) and were skipped.")
        }
        if zipLayersSkipped > 0 { lines.append("\(zipLayersSkipped) layer(s) use ZIP-compressed channels, which aren’t supported, and were skipped.") }
        if damagedLayersSkipped > 0 { lines.append("\(damagedLayersSkipped) layer(s) could not be decoded and were skipped.") }
        if oversizeLayersSkipped > 0 { lines.append("\(oversizeLayersSkipped) layer(s) exceeded the 100-megapixel or 30,000-pixel budget and were skipped.") }
        if masksSkipped > 0 { lines.append("\(masksSkipped) layer mask(s) exceeded the 100-megapixel mask budget and were dropped.") }
        if outOfArtboardLayers > 0 { lines.append("\(outOfArtboardLayers) layer(s) outside every artboard were skipped.") }
        if darkerColorLayers > 0 { lines.append("\(darkerColorLayers) layer(s) used Darker Color, which has no equivalent here; they now blend with Darken.") }
        if unknownBlendLayers > 0 { lines.append("\(unknownBlendLayers) layer(s) used blend modes this app doesn’t have; they now blend with Normal.") }
        if droppedClipping > 0 { lines.append("\(droppedClipping) clipped layer(s) had no usable base layer and were imported unclipped.") }
        if groupOpacityClamped > 0 { lines.append("\(groupOpacityClamped) group(s) were partly transparent, which groups here can’t be; they are now fully opaque.") }
        if artboardMasksDropped > 0 { lines.append("\(artboardMasksDropped) artboard mask(s) have no equivalent and were dropped.") }
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }
}

nonisolated struct PSDImportResult: Sendable {
    var documents: [PSDImportedDocument]
    var summary = PSDImportSummary()
}

/// One record's decoded pixels: the premultiplied RGBA image (nil for groups), and the user
/// mask with its placement when the mask sits apart from the layer's own grid.
nonisolated struct PSDLayerAsset: @unchecked Sendable {
    var image: ImportedImage?
    var mask: ImportedImage?
    var maskPlacement: LayerTransform?
}

/// A cheap sniff used to route a URL to the layered PSD path instead of the image importer.
nonisolated enum PSDProbe {
    static func isPSD(_ url: URL) -> Bool {
        guard url.pathExtension.lowercased() == "psd" else { return false }
        guard let handle = try? FileHandle(forReadingFrom: url),
              let magic = try? handle.read(upToCount: 4) else { return false }
        try? handle.close()
        return magic.elementsEqual(Data(PSDFormat.signature))
    }
}

/// One target document of an import: an artboard (or the whole canvas when there are none).
private struct PSDScope {
    let name: String
    let origin: CGPoint
    let width: Int
    let height: Int
    let children: [PSDNode]
    /// The canvas-absolute window layers rasterize into: the artboard, so a layer spanning the
    /// whole file (a background fill) still fits the budget. Nil for a whole-canvas document,
    /// which keeps every layer's full rectangle, off-canvas ink included.
    let crop: PSDRect?
    var rect: PSDRect { PSDRect(top: Int(origin.y), left: Int(origin.x),
                                bottom: Int(origin.y) + height, right: Int(origin.x) + width) }
    func clipped(_ rect: PSDRect) -> PSDRect {
        guard let crop else { return rect }
        return PSDRect(top: max(rect.top, crop.top), left: max(rect.left, crop.left),
                       bottom: min(rect.bottom, crop.bottom), right: min(rect.right, crop.right))
    }
}

/// Imports layered PSDs as Compositor documents. Files with artboards become one document per
/// artboard — the only workable mapping once a canvas passes the 100-megapixel budget; files
/// without artboards become a single document. Pixel layers, smart objects and text layers all
/// carry rendered channel data and rasterize alike; layers with empty channels (adjustment
/// layers) are skipped and counted in the summary.
actor PSDImporter {
    static let shared = PSDImporter()

    func importDocuments(at url: URL) throws -> PSDImportResult {
        var summary = PSDImportSummary()
        let parsed = try PSDReader.read(url: url)
        guard !parsed.records.isEmpty else { throw PSDImportError.nothingImported } // flattened-only; callers fall back

        var scopes = [PSDScope]()
        let artboards = parsed.roots.filter { $0.artboardRect?.isEmpty == false }
        if artboards.isEmpty {
            let width = parsed.header.width, height = parsed.header.height
            guard width <= 30_000, height <= 30_000, width * height <= 100_000_000 else {
                throw PSDImportError.canvasTooLarge(width: width, height: height)
            }
            scopes.append(PSDScope(name: url.deletingPathExtension().lastPathComponent, origin: .zero,
                                   width: width, height: height, children: parsed.roots, crop: nil))
        } else {
            summary.artboards = artboards.count
            for artboard in artboards {
                let record = parsed.records[artboard.recordIndex]
                if record.mask != nil, record.channel(-2)?.isEmpty == false { summary.artboardMasksDropped += 1 }
                let rect = artboard.artboardRect!
                guard rect.width <= 30_000, rect.height <= 30_000,
                      rect.width * rect.height <= 100_000_000 else {
                    summary.oversizeArtboards.append(record.name)
                    continue
                }
                scopes.append(PSDScope(name: record.name, origin: CGPoint(x: rect.left, y: rect.top),
                                       width: rect.width, height: rect.height, children: artboard.children, crop: rect))
            }
            for root in parsed.roots where root.artboardRect?.isEmpty != false {
                summary.outOfArtboardLayers += countLayers(root)
            }
        }

        // One slot per imported layer, laid out bottom-up exactly as the compositor nests folders.
        var slots = [LayerSlot]()
        var usedPixels = [Int: Int]()      // scope → layer pixels against the 100MP image budget
        var usedMaskPixels = [Int: Int]()  // masks budget separately, as saves do
        for (scopeIndex, scope) in scopes.enumerated() {
            var base: Int? = nil
            emitChildren(scope.children, into: &slots, scopeIndex: scopeIndex, scope: scope, parent: nil,
                         parsed: parsed, usedPixels: &usedPixels, usedMaskPixels: &usedMaskPixels, summary: &summary,
                         base: &base)
        }
        guard slots.contains(where: { !$0.isGroup }) else { throw PSDImportError.nothingImported }

        // Channel decode walks the file front to back, materializing one record at a time.
        var reader = try PSDFileReader(url: url)
        var assets = [Int: PSDLayerAsset]()
        let scopeByRecord = Dictionary(uniqueKeysWithValues:
            slots.filter { !$0.isGroup || parsed.records[$0.recordIndex].channel(-2)?.isEmpty == false }
                .map { ($0.recordIndex, $0.scope) })
        let wanted = Set(scopeByRecord.keys)
        for recordIndex in parsed.records.indices {
            let total = parsed.records[recordIndex].channels.reduce(UInt64(0)) { $0 + UInt64($1.length) }
            let crop = scopeByRecord[recordIndex].flatMap { scopes[$0].crop }
            guard wanted.contains(recordIndex) else {
                do { try reader.skip(total) }
                catch { break } // one lying channel length must not sink the whole import
                continue
            }
            try autoreleasepool {
                do { assets[recordIndex] = try Self.decode(record: parsed.records[recordIndex], crop: crop, reader: &reader) }
                catch PSDImportError.zipChannels { summary.zipLayersSkipped += 1 }
                catch PSDImportError.damaged { summary.damagedLayersSkipped += 1 }
            }
        }
        // A clipped layer whose base failed to decode cannot reference it.
        for index in slots.indices {
            if let source = slots[index].maskSourceRecord, assets[source] == nil {
                slots[index].maskSourceRecord = nil
                summary.droppedClipping += 1
            }
            if slots[index].suppressMask, assets[slots[index].recordIndex] != nil {
                assets[slots[index].recordIndex]!.mask = nil
                assets[slots[index].recordIndex]!.maskPlacement = nil
            }
        }
        let idByRecord = Dictionary(uniqueKeysWithValues: slots.filter { !$0.isGroup }.map { ($0.recordIndex, $0.id) })

        var result = PSDImportResult(documents: [])
        for (scopeIndex, scope) in scopes.enumerated() {
            var images = [UUID: ImportedImage]()
            var masks = [UUID: ImportedImage]()
            var layers = [ProjectLayerRecord]()
            for slot in slots where slot.scope == scopeIndex {
                let asset = assets[slot.recordIndex]
                guard slot.isGroup || asset?.image != nil else { continue }
                let mask = asset?.mask
                layers.append(ProjectLayerRecord(
                    id: slot.id, name: slot.name, isVisible: !slot.isHidden, transform: slot.transform,
                    imageFile: slot.isGroup ? nil : "\(slot.id.uuidString).png",
                    parentID: slot.parentID, isGroup: slot.isGroup,
                    opacity: slot.opacity, blendMode: slot.blendMode,
                    maskFile: mask != nil ? "\(slot.id.uuidString).mask.png" : nil,
                    maskEnabled: mask != nil ? !slot.maskDisabled : nil,
                    maskSourceID: slot.maskSourceRecord.flatMap { idByRecord[$0] },
                    adjustment: nil, maskPlacement: asset?.maskPlacement, maskLinked: nil))
                if let image = asset?.image { images[slot.id] = image }
                if let mask { masks[slot.id] = mask }
            }
            guard layers.contains(where: { $0.isGroup != true }) else { continue }
            let manifest = ProjectManifest(resolution: 72, documentID: UUID(), width: scope.width,
                                           height: scope.height, activeLayerID: layers.last?.id, layers: layers)
            result.documents.append(PSDImportedDocument(
                name: scope.name, snapshot: ProjectSnapshot(manifest: manifest, images: images, masks: masks)))
        }
        guard !result.documents.isEmpty else { throw PSDImportError.nothingImported }
        result.summary = summary
        return result
    }

    // MARK: tree → slots

    private struct LayerSlot {
        let recordIndex: Int
        let id = UUID()
        let scope: Int
        var parentID: UUID?
        let isGroup: Bool
        let name: String
        let transform: LayerTransform
        let opacity: Double
        let blendMode: LayerBlendMode
        let isHidden: Bool
        var maskDisabled = false
        var maskSourceRecord: Int?
        var suppressMask = false
    }

    /// What one emitted node became, for the clipping-chain bookkeeping around it.
    private struct Outcome {
        let slotIndex: Int?
        let recordIndex: Int
        let isGroup: Bool
        let isClipped: Bool
    }

    /// Emits siblings bottom-up, resolving the PSD clipping chain against the nearest
    /// non-clipped layer below: every clipped layer hangs off that base. The chain crosses
    /// group boundaries — a group's bottom child clips to whatever sat below the group —
    /// and an unclipped layer or folder resets it.
    private func emitChildren(_ children: [PSDNode], into slots: inout [LayerSlot], scopeIndex: Int, scope: PSDScope,
                              parent: UUID?, parsed: PSDDocument, usedPixels: inout [Int: Int],
                              usedMaskPixels: inout [Int: Int], summary: inout PSDImportSummary,
                              base: inout Int?) {
        for child in children {
            let outcome = emit(child, into: &slots, scopeIndex: scopeIndex, scope: scope, parent: parent,
                               parsed: parsed, usedPixels: &usedPixels, usedMaskPixels: &usedMaskPixels,
                               summary: &summary, base: &base)
            if outcome.isClipped, let slotIndex = outcome.slotIndex {
                if !outcome.isGroup, let base {
                    slots[slotIndex].maskSourceRecord = base
                } else {
                    summary.droppedClipping += 1 // a group can't clip here, and no base survived import
                }
            }
        }
    }

    private func countLayers(_ node: PSDNode) -> Int {
        node.kind == .layer ? 1 : node.children.reduce(0) { $0 + countLayers($1) }
    }

    /// Emits one node bottom-up: a group record followed by its subtree, matching how the
    /// compositor's flat layer list nests folders.
    private func emit(_ node: PSDNode, into slots: inout [LayerSlot], scopeIndex: Int, scope: PSDScope, parent: UUID?,
                      parsed: PSDDocument, usedPixels: inout [Int: Int], usedMaskPixels: inout [Int: Int],
                      summary: inout PSDImportSummary, base: inout Int?) -> Outcome {
        let record = parsed.records[node.recordIndex]
        let mapping = PSDFormat.blendMode(forPSDKey: record.blendKey)
        if node.kind == .layer {
            let visible = scope.clipped(record.rect)
            guard record.hasPixels, !record.rect.isEmpty else {
                summary.emptyLayersSkipped += 1
                return Outcome(slotIndex: nil, recordIndex: node.recordIndex, isGroup: false, isClipped: record.isClipped)
            }
            guard !visible.isEmpty else {
                // The layer lives elsewhere on the canvas; this artboard shows none of it.
                return Outcome(slotIndex: nil, recordIndex: node.recordIndex, isGroup: false, isClipped: record.isClipped)
            }
            guard let area = visible.area,
                  (usedPixels[scopeIndex] ?? 0) + area <= 100_000_000 else {
                summary.oversizeLayersSkipped += 1
                return Outcome(slotIndex: nil, recordIndex: node.recordIndex, isGroup: false, isClipped: record.isClipped)
            }
            usedPixels[scopeIndex] = (usedPixels[scopeIndex] ?? 0) + area
            if mapping.downgraded {
                if record.blendKey == "dkCl" { summary.darkerColorLayers += 1 } else { summary.unknownBlendLayers += 1 }
            }
            var slot = LayerSlot(recordIndex: node.recordIndex, scope: scopeIndex, parentID: parent, isGroup: false,
                                 name: record.name,
                                 transform: LayerTransform(origin: CGPoint(x: CGFloat(visible.left) - scope.origin.x,
                                                                           y: CGFloat(visible.top) - scope.origin.y),
                                                           size: CGSize(width: visible.width, height: visible.height)),
                                 opacity: Double(record.opacity) / 255, blendMode: mapping.mode, isHidden: record.isHidden)
            slot.maskDisabled = record.mask?.isDisabled ?? false
            if let maskVisible = croppedMaskRect(record, scope: scope) {
                if let area = maskVisible.area, (usedMaskPixels[scopeIndex] ?? 0) + area <= 100_000_000 {
                    usedMaskPixels[scopeIndex] = (usedMaskPixels[scopeIndex] ?? 0) + area
                } else {
                    slot.suppressMask = true; summary.masksSkipped += 1
                }
            }
            slots.append(slot)
            // An unclipped layer becomes the clipping base for what sits above it; a clipped
            // one leaves the base alone, and a skipped layer breaks the chain.
            if !record.isClipped { base = node.recordIndex }
            return Outcome(slotIndex: slots.count - 1, recordIndex: node.recordIndex, isGroup: false, isClipped: record.isClipped)
        }
        // Group header: one folder row, then its children. They start from the base below the
        // group (a clipped bottom child reaches across the boundary), and the group itself
        // ends whatever chain passed through it.
        if record.opacity != 255 { summary.groupOpacityClamped += 1 }
        var slot = LayerSlot(recordIndex: node.recordIndex, scope: scopeIndex, parentID: parent, isGroup: true,
                             name: record.name,
                             transform: LayerTransform(origin: .zero, size: CGSize(width: scope.width, height: scope.height)),
                             opacity: 1, blendMode: .normal, isHidden: record.isHidden)
        slot.maskDisabled = record.mask?.isDisabled ?? false
        if let maskVisible = croppedMaskRect(record, scope: scope) {
            if let area = maskVisible.area, (usedMaskPixels[scopeIndex] ?? 0) + area <= 100_000_000 {
                usedMaskPixels[scopeIndex] = (usedMaskPixels[scopeIndex] ?? 0) + area
            } else {
                slot.suppressMask = true; summary.masksSkipped += 1
            }
        }
        slots.append(slot)
        let slotIndex = slots.count - 1
        var innerBase = base
        emitChildren(node.children, into: &slots, scopeIndex: scopeIndex, scope: scope, parent: slot.id,
                     parsed: parsed, usedPixels: &usedPixels, usedMaskPixels: &usedMaskPixels, summary: &summary,
                     base: &innerBase)
        base = nil
        return Outcome(slotIndex: slotIndex, recordIndex: node.recordIndex, isGroup: true, isClipped: record.isClipped)
    }

    /// The mask's visible rectangle as this scope rasterizes it (cropped like the layer), when
    /// the record carries a real mask channel. Area math goes through `PSDRect.area`, so a
    /// rect whose sides overflow multiplication reads as over-budget, never as a crash.
    private func croppedMaskRect(_ record: PSDLayerRecord, scope: PSDScope) -> PSDRect? {
        guard let mask = record.mask, !mask.rect.isEmpty, record.channel(-2)?.isEmpty == false else { return nil }
        let visible = scope.clipped(mask.rect)
        return visible.isEmpty ? nil : visible
    }

    // MARK: channel decode

    /// Decodes one record's RGB(+alpha) channels into a premultiplied image, plus its user
    /// mask channel when present (groups carry only the mask). `crop` windows each plane to
    /// the artboard being imported, so a canvas-spanning layer never costs more than the
    /// artboard. The reader ends positioned after the record's last channel.
    static func decode(record: PSDLayerRecord, crop: PSDRect?, reader: inout PSDFileReader) throws -> PSDLayerAsset {
        var planes = [Int16: (plane: [UInt8], size: (width: Int, height: Int))]()
        // Walk channels in file order so the forward-only reader never rewinds.
        for channel in record.channels.sorted(by: { $0.offset < $1.offset }) {
            guard !channel.isEmpty else { continue }
            let source: PSDRect
            switch channel.id {
            case 0, 1, 2, -1: source = record.rect
            case -2:
                guard let mask = record.mask, !mask.rect.isEmpty else { continue }
                source = mask.rect
            default: continue
            }
            guard !source.isEmpty else { continue }
            let visible = crop.map { PSDRect(top: max(source.top, $0.top), left: max(source.left, $0.left),
                                             bottom: min(source.bottom, $0.bottom), right: min(source.right, $0.right)) } ?? source
            guard !visible.isEmpty else { continue }
            // The same budget the emit pass applies to layers, enforced before decodeChannel
            // allocates its plane: an unclamped rect (an artboard-less mask can span the whole
            // I32 range) would otherwise trap or attempt an astronomic allocation.
            guard let area = visible.area, area <= 100_000_000 else { continue }
            planes[channel.id] = (try decodeChannel(channel, source: source, visible: visible, reader: &reader),
                                  (visible.width, visible.height))
        }
        let recordEnd = record.channels.reduce(UInt64(0)) { max($0, $1.offset + UInt64($1.length)) }
        try reader.seek(to: recordEnd)

        var image: ImportedImage? = nil
        if let red = planes[0], let green = planes[1], let blue = planes[2] {
            let width = red.size.width, height = red.size.height
            let alpha = planes[-1]?.plane ?? [UInt8](repeating: 255, count: width * height)
            var rgba = [UInt8](repeating: 0, count: width * height * 4)
            rgba.withUnsafeMutableBufferPointer { interleaved in
                guard let target = interleaved.baseAddress else { return }
                red.plane.withUnsafeBufferPointer { r in
                    green.plane.withUnsafeBufferPointer { g in
                        blue.plane.withUnsafeBufferPointer { b in
                            alpha.withUnsafeBufferPointer { a in
                                guard let rp = r.baseAddress, let gp = g.baseAddress,
                                      let bp = b.baseAddress, let ap = a.baseAddress else { return }
                                var pixel = 0
                                for index in 0..<(width * height) {
                                    target[pixel] = rp[index]
                                    target[pixel + 1] = gp[index]
                                    target[pixel + 2] = bp[index]
                                    target[pixel + 3] = ap[index]
                                    pixel += 4
                                }
                            }
                        }
                    }
                }
            }
            var buffer = vImage_Buffer(data: &rgba, height: vImagePixelCount(height),
                                       width: vImagePixelCount(width), rowBytes: width * 4)
            vImagePremultiplyData_RGBA8888(&buffer, &buffer, vImage_Flags(kvImageNoFlags))
            image = try rgbaImage(rgba, width: width, height: height, name: record.name)
        }
        var mask: ImportedImage? = nil
        var placement: LayerTransform? = nil
        if let gray = planes[-2], let info = record.mask {
            // The decoded plane starts where the mask meets the crop, not at the raw mask
            // origin: a mask reaching past the artboard's top/left would otherwise place its
            // content shifted by the overhang (review finding).
            let originTop = crop.map { max(info.rect.top, $0.top) } ?? info.rect.top
            let originLeft = crop.map { max(info.rect.left, $0.left) } ?? info.rect.left
            let visible = PSDRect(top: originTop, left: originLeft, bottom: originTop + gray.size.height,
                                  right: originLeft + gray.size.width)
            mask = try grayImage(gray.plane, width: visible.width, height: visible.height, name: record.name)
            let layerVisible = crop.map { PSDRect(top: max(record.rect.top, $0.top), left: max(record.rect.left, $0.left),
                                                  bottom: min(record.rect.bottom, $0.bottom), right: min(record.rect.right, $0.right)) } ?? record.rect
            if visible != layerVisible {
                // Placements live in document space, artboard origin already subtracted.
                placement = LayerTransform(origin: CGPoint(x: CGFloat(visible.left) - CGFloat(crop?.left ?? 0),
                                                            y: CGFloat(visible.top) - CGFloat(crop?.top ?? 0)),
                                           size: CGSize(width: visible.width, height: visible.height))
            }
        }
        guard image != nil || mask != nil else { throw PSDImportError.damaged("layer “\(record.name)” has no pixel data") }
        return PSDLayerAsset(image: image, mask: mask, maskPlacement: placement)
    }

    /// Decodes the `visible` window of a channel whose full raster sits at `source`: PackBits
    /// rows before and after the window are skipped without unpacking, RAW bytes are skipped
    /// by seek counts — either way nothing outside the window is materialized.
    static func decodeChannel(_ channel: PSDChannelInfo, source: PSDRect, visible: PSDRect,
                              reader: inout PSDFileReader) throws -> [UInt8] {
        try reader.seek(to: channel.offset)
        let compression = try reader.readU16()
        let firstRow = visible.top - source.top
        let lastRow = visible.bottom - source.top
        let firstColumn = visible.left - source.left
        let outWidth = visible.width
        var plane = [UInt8](repeating: 0, count: outWidth * visible.height)
        if compression == 0 {
            // Raw: skip the rows above the window, then read each row's slice and skip its tail.
            try reader.skip(UInt64(firstRow) * UInt64(source.width) + UInt64(firstColumn))
            for row in 0..<visible.height {
                let slice = try reader.read(outWidth)
                plane.replaceSubrange(row * outWidth..<(row + 1) * outWidth, with: slice)
                try reader.skip(UInt64(source.width - firstColumn - outWidth))
            }
            return plane
        }
        guard compression == 1 else { throw PSDImportError.zipChannels }
        let body = try reader.read(Int(channel.length) - 2)
        var tableTotal = 0
        for row in 0..<source.height {
            guard 2 * row + 1 < body.count else { throw PSDImportError.damaged("a row table is truncated") }
            tableTotal += Int(body[2 * row]) << 8 | Int(body[2 * row + 1])
        }
        let rowsStart = 2 * source.height
        guard rowsStart + tableTotal == body.count else {
            throw PSDImportError.damaged("a row table does not match the channel length")
        }
        var cursor = rowsStart
        var row = [UInt8](repeating: 0, count: source.width)
        for index in 0..<source.height {
            let rowLength = Int(body[2 * index]) << 8 | Int(body[2 * index + 1])
            if index >= firstRow && index < lastRow {
                try PSDFormat.unpackRow(body[cursor..<cursor + rowLength], into: &row, at: 0, width: source.width)
                let target = (index - firstRow) * outWidth
                plane[target..<target + outWidth] = row[firstColumn..<firstColumn + outWidth]
            }
            cursor += rowLength
        }
        return plane
    }

    // MARK: images

    static func rgbaImage(_ pixels: [UInt8], width: Int, height: Int, name: String) throws -> ImportedImage {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue
                                      | CGBitmapInfo.byteOrder32Big.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let thumbnail = downscale(image, maximum: 96) else { throw PSDImportError.damaged("a layer could not be rasterized") }
        return ImportedImage(image: image, thumbnail: thumbnail, name: name)
    }

    static func grayImage(_ pixels: [UInt8], width: Int, height: Int, name: String) throws -> ImportedImage {
        let data = Data(pixels) as CFData
        guard let provider = CGDataProvider(data: data),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8,
                                  bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.none.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent),
              let thumbnail = downscale(image, maximum: 96) else { throw PSDImportError.damaged("a mask could not be rasterized") }
        return ImportedImage(image: image, thumbnail: thumbnail, name: name)
    }

    private static func downscale(_ image: CGImage, maximum: CGFloat) -> CGImage? {
        let scale = min(1, maximum / CGFloat(max(image.width, image.height)))
        guard scale < 1 else { return image }
        let width = max(1, (CGFloat(image.width) * scale).rounded(.up)), height = max(1, (CGFloat(image.height) * scale).rounded(.up))
        let mono = image.colorSpace?.model == .monochrome
        guard let context = CGContext(data: nil, width: Int(width), height: Int(height), bitsPerComponent: 8,
                                      bytesPerRow: 0,
                                      space: mono ? CGColorSpaceCreateDeviceGray() : CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: mono ? CGImageAlphaInfo.none.rawValue : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }
}
