import AppKit

nonisolated enum LayerTextAlignment: String, CaseIterable, Codable, Sendable {
    case left, center, right

    var textAlignment: NSTextAlignment {
        switch self {
        case .left: .left
        case .center: .center
        case .right: .right
        }
    }
}

nonisolated enum LayerTextLayout: Codable, Equatable, Sendable {
    case point
    case box(width: CGFloat)
}

nonisolated struct LayerTextStyle: Codable, Equatable, Sendable {
    var content: String
    var fontPostScriptName: String
    var fontSizePoints: CGFloat
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
    var alpha: CGFloat
    var alignment: LayerTextAlignment
    var lineSpacingPoints: CGFloat
    var trackingPoints: CGFloat
    var layout: LayerTextLayout

    static let initial = LayerTextStyle(content: "", fontPostScriptName: "SourceHanSansSC-Regular",
        fontSizePoints: 36, red: 0, green: 0, blue: 0, alpha: 1, alignment: .left,
        lineSpacingPoints: 0, trackingPoints: 0, layout: .point)
}

nonisolated struct LayerText: Equatable, @unchecked Sendable {
    var style: LayerTextStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerTextStyle?, image: CGImage?) -> LayerText? {
        guard let style, let image else { return nil }
        return LayerText(style: style, image: image)
    }
}

extension ImageLayer {
    /// Text metadata remains editable only while it still describes this exact raster.
    var liveText: LayerText? {
        guard let text, let image = asset?.image, image === text.image else { return nil }
        return text
    }
}

struct TextRenderResult {
    let image: CGImage
    let naturalSize: CGSize
}

/// One TextKit stack is shared by native editing and raster output, so wrapping and glyph positions agree.
@MainActor
final class TextLayoutSession {
    let textStorage = NSTextStorage()
    let layoutManager = NSLayoutManager()
    let textContainer = NSTextContainer()
    private(set) var style: LayerTextStyle
    let resolution: CGFloat
    private weak var textView: NSTextView?

    init(style: LayerTextStyle, resolution: CGFloat) {
        self.style = style
        self.resolution = resolution
        textStorage.addLayoutManager(layoutManager)
        layoutManager.addTextContainer(textContainer)
        textContainer.lineFragmentPadding = 0
        update(style: style)
    }

    var string: String { textStorage.string }
    var fontIsAvailable: Bool { NSFont(name: style.fontPostScriptName, size: 12) != nil }

    func makeTextView() -> NSTextView {
        if let textView { return textView }
        let view = EditingTextView(frame: .zero, textContainer: textContainer)
        view.isRichText = false
        view.importsGraphics = false
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.allowsUndo = true
        view.setAccessibilityLabel("Text editor".localized)
        textView = view
        applyTypingAttributes(to: view)
        return view
    }

    func update(style: LayerTextStyle) {
        self.style = style
        if textStorage.string != style.content { textStorage.replaceCharacters(in: NSRange(location: 0, length: textStorage.length), with: style.content) }
        switch style.layout {
        case .point:
            applyAttributes(alignment: style.alignment)
            layoutPointContainer()
        case .box(let width):
            textContainer.containerSize = CGSize(width: max(1, width), height: 100_000)
            applyAttributes(alignment: style.alignment)
        }
        if let textView { applyTypingAttributes(to: textView) }
        layoutManager.ensureLayout(for: textContainer)
    }

    /// Native typing, including IME marked text, already carries the text view's typing attributes.
    /// Reflow only; replacing attributes here would destroy the input manager's marked range.
    func textDidChange() {
        style.content = textStorage.string
        if case .point = style.layout { layoutPointContainer() }
    }

    func currentStyle() -> LayerTextStyle {
        var value = style
        value.content = textStorage.string
        return value
    }

    func unmarkText() { textView?.unmarkText() }

    func naturalSize() -> CGSize {
        if case .point = style.layout { layoutPointContainer() }
        layoutManager.ensureLayout(for: textContainer)
        let used = layoutManager.usedRect(for: textContainer)
        let width: CGFloat
        switch style.layout {
        case .point: width = ceil(max(1, used.maxX))
        case .box(let fixed): width = ceil(max(1, fixed))
        }
        return CGSize(width: width, height: ceil(max(1, used.maxY)))
    }

    func render(targetSize: CGSize? = nil) throws -> TextRenderResult {
        let natural = naturalSize()
        let target = targetSize ?? natural
        let width = max(1, Int(target.width.rounded()))
        let height = max(1, Int(target.height.rounded()))
        guard width <= 30_000, height <= 30_000,
              width * height <= EditorSession.maxShapePixels else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: width, height: height, mask: false)
        context.scaleBy(x: CGFloat(width) / natural.width, y: CGFloat(height) / natural.height)
        let graphics = NSGraphicsContext(cgContext: context, flipped: true)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = graphics
        let range = layoutManager.glyphRange(for: textContainer)
        layoutManager.drawBackground(forGlyphRange: range, at: .zero)
        layoutManager.drawGlyphs(forGlyphRange: range, at: .zero)
        NSGraphicsContext.restoreGraphicsState()
        guard let image = context.makeImage() else { throw ExportError.render }
        return TextRenderResult(image: image, naturalSize: natural)
    }

    private var pixelsPerPoint: CGFloat { max(1, resolution) / 72 }
    private var font: NSFont {
        NSFont(name: style.fontPostScriptName, size: style.fontSizePoints * pixelsPerPoint)
            ?? NSFont(name: "SourceHanSansSC-Regular", size: style.fontSizePoints * pixelsPerPoint)
            ?? .systemFont(ofSize: style.fontSizePoints * pixelsPerPoint)
    }
    private func attributes(alignment: LayerTextAlignment? = nil) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = (alignment ?? style.alignment).textAlignment
        paragraph.lineSpacing = style.lineSpacingPoints * pixelsPerPoint
        return [.font: font,
                .foregroundColor: NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: style.alpha),
                .kern: style.trackingPoints * pixelsPerPoint,
                .paragraphStyle: paragraph]
    }
    private func applyAttributes(alignment: LayerTextAlignment) {
        let range = NSRange(location: 0, length: textStorage.length)
        if range.length > 0 { textStorage.setAttributes(attributes(alignment: alignment), range: range) }
        textContainer.widthTracksTextView = false
        textContainer.heightTracksTextView = false
    }

    private func layoutPointContainer() {
        // A wide measuring pass keeps point text unwrapped. lineFragmentUsedRect.width is
        // independent of center/right offsets, so this never touches IME marked-text attributes.
        textContainer.containerSize = CGSize(width: 100_000, height: 100_000)
        layoutManager.ensureLayout(for: textContainer)
        let glyphs = layoutManager.glyphRange(for: textContainer)
        var width: CGFloat = 1
        var index = glyphs.location
        while index < NSMaxRange(glyphs) {
            var line = NSRange()
            width = max(width, layoutManager.lineFragmentUsedRect(forGlyphAt: index, effectiveRange: &line).width)
            let next = NSMaxRange(line)
            guard next > index else { break }
            index = next
        }
        let isEmpty = textStorage.length == 0
        textContainer.containerSize = CGSize(width: isEmpty ? 160 : ceil(width), height: 100_000)
        layoutManager.ensureLayout(for: textContainer)
    }
    private func applyTypingAttributes(to textView: NSTextView) {
        let values = attributes()
        textView.typingAttributes = values
        textView.defaultParagraphStyle = values[.paragraphStyle] as? NSParagraphStyle
        textView.insertionPointColor = style.red + style.green + style.blue < 1.5 ? .white : .black
    }
}

struct TextPlacementDraft {
    let anchor: CGPoint
    var current: CGPoint
    var rect: CGRect {
        CGRect(x: min(anchor.x, current.x), y: min(anchor.y, current.y),
               width: abs(current.x - anchor.x), height: abs(current.y - anchor.y))
    }
}

@MainActor
final class TextDraft {
    let layerID: UUID?
    let original: ImageLayer?
    let origin: CGPoint
    let scale: CGSize
    let layout: TextLayoutSession

    init(layerID: UUID?, original: ImageLayer?, origin: CGPoint, scale: CGSize, layout: TextLayoutSession) {
        self.layerID = layerID
        self.original = original
        self.origin = origin
        self.scale = scale
        self.layout = layout
    }

    var transform: LayerTransform {
        let natural = layout.naturalSize()
        var value = original?.transform ?? LayerTransform(origin: origin, size: natural)
        value.origin = origin
        value.size = CGSize(width: natural.width * scale.width, height: natural.height * scale.height)
        if let original {
            let anchor = original.transform.point(.zero)
            let moved = value.point(.zero)
            value.origin.x += anchor.x - moved.x
            value.origin.y += anchor.y - moved.y
        }
        return value
    }
}

extension EditorSession {
    func beginText(at point: CGPoint) {
        guard tool == .text, textDraft == nil, canEditLayers, let document else { return }
        let visible = document.effectiveVisibleIDs
        if let layer = document.renderLayers.reversed().first(where: {
            visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(point)
        }) {
            beginEditingText(layer.id)
        } else {
            textPlacementDraft = TextPlacementDraft(anchor: point, current: point)
        }
    }

    func dragText(to point: CGPoint) { textPlacementDraft?.current = point }

    func finishTextPlacement() {
        guard let placement = textPlacementDraft, let document else { return }
        textPlacementDraft = nil
        var style = textStyle
        style.content = ""
        let rect = placement.rect
        style.layout = rect.width >= 2 ? .box(width: rect.width.rounded()) : .point
        let origin = rect.width >= 2 ? rect.origin : placement.anchor
        let layout = TextLayoutSession(style: style, resolution: document.resolution)
        textDraft = TextDraft(layerID: nil, original: nil, origin: origin, scale: CGSize(width: 1, height: 1), layout: layout)
        textRevision += 1
    }

    func beginEditingText(_ id: UUID) {
        guard textDraft == nil, canEditLayers, let document, let layer = document.layers.first(where: { $0.id == id }),
              let text = layer.liveText else { return }
        let layout = TextLayoutSession(style: text.style, resolution: document.resolution)
        let natural = layout.naturalSize()
        let scale = CGSize(width: layer.transform.size.width / natural.width,
                           height: layer.transform.size.height / natural.height)
        textStyle = text.style
        textDraft = TextDraft(layerID: id, original: layer, origin: layer.transform.origin, scale: scale,
                              layout: layout)
        activeLayerID = id
        textRevision += 1
    }

    func updateTextStyle(_ change: (inout LayerTextStyle) -> Void) {
        var style = textDraft?.layout.currentStyle() ?? textStyle
        change(&style)
        textStyle = style
        textDraft?.layout.update(style: style)
        textRevision += 1
    }

    func textDidChange() {
        guard let textDraft else { return }
        textDraft.layout.textDidChange()
        textStyle = textDraft.layout.currentStyle()
        textRevision += 1
    }

    @discardableResult
    func commitText() -> Bool {
        guard let draft = textDraft else { textPlacementDraft = nil; return true }
        draft.layout.unmarkText()
        var style = draft.layout.currentStyle()
        guard !style.content.isEmpty else { cancelText(); return true }
        textStyle = style
        let transform = draft.transform
        if let original = draft.original, original.liveText?.style == style, original.transform == transform {
            cancelText()
            return true
        }
        do {
            let result = try draft.layout.render(targetSize: transform.size)
            let image = result.image
            let thumbnail = try PixelInvert.thumbnail(of: image)
            style.content = draft.layout.string
            if let id = draft.layerID, let index = document?.layers.firstIndex(where: { $0.id == id }),
               var layer = document?.layers[index] {
                beginEdit("Edit Text")
                layer.asset = ImportedImage(image: image, thumbnail: thumbnail, name: layer.asset?.name ?? layer.name)
                layer.transform = transform
                layer.shape = nil
                layer.text = LayerText(style: style, image: image)
                document?.layers[index] = layer
                activeLayerID = id
                endEdit()
            } else {
                addPixelLayer(image, at: transform.origin, name: nextTextName(), editName: "Add Text",
                              dropsSelection: false, text: LayerText(style: style, image: image))
            }
            textDraft = nil
            textRevision += 1
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }

    func cancelText() {
        textPlacementDraft = nil
        textDraft = nil
        textRevision += 1
    }

    func nextTextName() -> String {
        let names = Set(document?.layers.map(\.name) ?? [])
        var number = 1
        while names.contains(String(localized: "Text \(number)")) { number += 1 }
        return String(localized: "Text \(number)")
    }

    func redrawText(at index: Int) {
        guard let layer = document?.layers[index], let text = layer.liveText, let asset = layer.asset else { return }
        let width = max(1, Int(layer.transform.size.width.rounded()))
        let height = max(1, Int(layer.transform.size.height.rounded()))
        guard width != asset.image.width || height != asset.image.height else { return }
        let layout = TextLayoutSession(style: text.style, resolution: document?.resolution ?? 72)
        guard let image = try? layout.render(targetSize: CGSize(width: width, height: height)).image,
              let thumbnail = try? PixelInvert.thumbnail(of: image) else { return }
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].text = LayerText(style: text.style, image: image)
    }
}
