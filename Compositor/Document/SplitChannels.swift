import Accelerate
import CoreGraphics
import Foundation

extension ChannelPack {
    /// A layer's red, green, blue and alpha, each as an opaque gray image of the same size. The color is divided back
    /// out of the alpha it was stored multiplied by, so it can only be as fine as the alpha allows, and where alpha is 0
    /// it's gone, as Photoshop loses it when it opens a PNG.
    static func split(_ image: CGImage) throws -> [CGImage] {
        var format = vImage_CGImageFormat(bitsPerComponent: 8, bitsPerPixel: 32,
                                          colorSpace: Unmanaged.passUnretained(CGColorSpace(name: CGColorSpace.sRGB)!),
                                          bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                          version: 0, decode: nil, renderingIntent: .defaultIntent)
        var buffer = vImage_Buffer()
        guard vImageBuffer_InitWithCGImage(&buffer, &format, nil, image, vImage_Flags(kvImageNoFlags)) == kvImageNoError
        else { throw ExportError.render }
        defer { free(buffer.data) }
        let width = image.width, height = image.height
        return try (0..<4).map { channel in
            var gray = [UInt8](repeating: 255, count: width * height * 4)
            for y in 0..<height {
                let row = buffer.data.advanced(by: y * buffer.rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width {
                    let value = row[x * 4 + channel], out = (y * width + x) * 4
                    gray[out] = value; gray[out + 1] = value; gray[out + 2] = value
                }
            }
            return try Self.image(gray, width: width, height: height, opaque: true)
        }
    }
}

extension EditorSession {
    /// A layer with pixels of its own, alone in the selection: something to split.
    var canSplitChannels: Bool {
        guard canEditLayers, !isMaskSelected, selectedLayerIDs.count <= 1, let layer = activeLayer else { return false }
        return !layer.isGroup && layer.adjustment == nil && layer.asset != nil
    }

    /// Image › Split Channels: the active layer becomes a folder of four grayscale layers, Red, Green, Blue and Alpha
    /// (Red on top), in its place and at its size, the names Export As › Channel Pack fills its channels from. The
    /// layer's mask and effects aren't carried over.
    func splitChannels() {
        guard canSplitChannels, let document, let layer = activeLayer, let image = layer.asset?.image,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        do {
            let planes = try ChannelPack.split(image)
            var group = ImageLayer(name: layer.name, blankSize: document.size)
            group.isGroup = true
            group.parentID = layer.parentID
            var layers = document.layers
            layers[index] = group
            // Bottom to top: Alpha, Blue, Green, then Red, so they read top-down in the Layers panel as R, G, B, A.
            let children = try zip(ChannelPack.Channel.allCases, planes).reversed().map { channel, plane in
                var child = ImageLayer(asset: ImportedImage(image: plane, thumbnail: try PixelAdjust.thumbnail(of: plane),
                                                            name: channel.rawValue), origin: .zero)
                child.transform = layer.transform
                child.parentID = group.id
                return child
            }
            layers.insert(contentsOf: children, at: index + 1)
            guard (try? LayerHierarchy.validate(layers.map(\.hierarchyRecord))) != nil else { return }
            beginEdit("Split Channels")
            self.document?.layers = layers
            activeLayerID = children.last?.id
            collapsedGroupIDs.remove(group.id)
            endEdit()
        } catch { brushError = error.localizedDescription }
    }
}
