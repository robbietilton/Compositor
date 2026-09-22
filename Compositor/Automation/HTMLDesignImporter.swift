import AppKit
import Foundation
import WebKit

nonisolated struct HTMLDesignSource: Equatable, Sendable {
    let html: String
    let css: String
    let width: Int
    let height: Int
    let name: String
}

nonisolated struct HTMLDesignImportResult: @unchecked Sendable {
    let snapshot: ProjectSnapshot
    let warnings: [String]
    /// The exact input is returned because ProjectSnapshot has no source-metadata field.
    let source: HTMLDesignSource
}

nonisolated enum HTMLDesignImportError: LocalizedError {
    case invalidDimensions
    case sourceTooLarge
    case pageTooComplex
    case loadFailed
    case timedOut
    case extractionFailed
    case renderFailed

    var errorDescription: String? {
        switch self {
        case .invalidDimensions:
            "HTML designs must be between 1 and 4,096 pixels on each side and at most 16 megapixels."
        case .sourceTooLarge:
            "The combined HTML and CSS source exceeds the 4 MB import limit."
        case .pageTooComplex:
            "The HTML contains more than 2,000 elements and cannot be imported safely."
        case .loadFailed:
            "The HTML design could not be loaded."
        case .timedOut:
            "The HTML design took too long to render."
        case .extractionFailed:
            "The rendered HTML could not be inspected."
        case .renderFailed:
            "The rendered HTML could not be converted into a Compositor layer."
        }
    }
}

/// Imports an untrusted HTML/CSS fragment through an ephemeral, network-isolated WKWebView.
/// Plain text and solid rectangles/ellipses remain editable. A design using a visual feature
/// that Compositor cannot reproduce faithfully is returned as one full-canvas raster layer.
@MainActor
enum HTMLDesignImporter {
    private static let maximumSide = 4_096
    private static let maximumCanvasPixels = 16_000_000
    private static let maximumSourceBytes = 4 * 1_024 * 1_024
    private static let maximumElements = 2_000
    private static let maximumNativeLayers = 256
    private static let maximumProjectPixels = 100_000_000

    static func importDesign(html: String, css: String, width: Int, height: Int, name: String) async throws -> HTMLDesignImportResult {
        try Task.checkCancellation()
        guard (1...maximumSide).contains(width), (1...maximumSide).contains(height),
              width <= maximumCanvasPixels / height else { throw HTMLDesignImportError.invalidDimensions }
        guard html.utf8.count <= maximumSourceBytes,
              css.utf8.count <= maximumSourceBytes - html.utf8.count else { throw HTMLDesignImportError.sourceTooLarge }

        let source = HTMLDesignSource(html: html, css: css, width: width, height: height, name: name)
        let renderer = HTMLDesignWebRenderer(width: width, height: height)
        try await renderer.load(document: document(html: html, css: css, width: width, height: height))
        try await renderer.settle()
        let inspection = try await renderer.inspect()
        try Task.checkCancellation()
        guard inspection.elementCount <= maximumElements else { throw HTMLDesignImportError.pageTooComplex }

        var warnings = securityWarnings(html: html, css: css)
        let nativePixelCost = inspection.primitives.reduce(0) { partial, primitive in
            let w = max(1, Int(primitive.width.rounded(.up)))
            let h = max(1, Int(primitive.height.rounded(.up)))
            return partial + (w > maximumProjectPixels / h ? maximumProjectPixels + 1 : w * h)
        }
        let mustFlatten = !inspection.unsupported.isEmpty
            || inspection.primitives.count > maximumNativeLayers
            || nativePixelCost > maximumProjectPixels

        let layers: [HTMLImportedLayer]
        if mustFlatten {
            let image = try await renderer.snapshot()
            let reason: String
            if inspection.primitives.count > maximumNativeLayers {
                reason = "it would require more than \(maximumNativeLayers) editable layers"
            } else if nativePixelCost > maximumProjectPixels {
                reason = "its editable layers would exceed Compositor's 100-megapixel project budget"
            } else {
                let features = inspection.unsupported.prefix(4).joined(separator: ", ")
                reason = "it uses \(features)"
            }
            warnings.append("Flattened the HTML into one raster layer because \(reason). Its appearance is preserved, but its individual elements are not editable.")
            layers = [try rasterLayer(image: image, name: normalizedName(name) + " — HTML render", width: width, height: height)]
        } else {
            var nativeWarnings: [String] = []
            var imported: [HTMLImportedLayer] = []
            for primitive in inspection.primitives {
                try Task.checkCancellation()
                imported.append(try await importedLayer(for: primitive, renderer: renderer, warnings: &nativeWarnings))
            }
            layers = imported
            warnings.append(contentsOf: nativeWarnings.uniqued())
        }

        try Task.checkCancellation()
        let snapshot = projectSnapshot(layers: layers, width: width, height: height)
        return HTMLDesignImportResult(snapshot: snapshot, warnings: warnings.uniqued(), source: source)
    }

    private static func normalizedName(_ value: String) -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "HTML Design" : String(cleaned.prefix(200))
    }

    private static func document(html: String, css: String, width: Int, height: Int) -> String {
        let encodedCSS = Data(css.utf8).base64EncodedString()
        // The CSP is intentionally redundant with `allowsContentJavaScript = false`: it also
        // blocks remote CSS, images, fonts, frames, media, forms and network APIs.
        return """
        <!doctype html>
        <html>
        <head>
          <meta charset="utf-8">
          <meta http-equiv="Content-Security-Policy" content="default-src 'none'; img-src data:; media-src data:; font-src data:; style-src 'unsafe-inline' data:; script-src 'none'; connect-src 'none'; object-src 'none'; frame-src 'none'; base-uri 'none'; form-action 'none'">
          <link rel="stylesheet" href="data:text/css;base64,\(encodedCSS)">
          <style>
            html { width: 100%; height: 100%; overflow: hidden !important; }
            body { min-height: 100%; }
            *, *::before, *::after { animation: none !important; transition: none !important; caret-color: transparent !important; }
          </style>
        </head>
        <body>\(html)</body>
        </html>
        """
    }

    private static func securityWarnings(html: String, css: String) -> [String] {
        let input = (html + "\n" + css).lowercased()
        var warnings: [String] = []
        if input.contains("<script") || input.range(of: #"\son[a-z]+\s*="#, options: .regularExpression) != nil
            || input.contains("javascript:") {
            warnings.append("Author JavaScript and HTML event handlers were disabled during import.")
        }
        if input.contains("http://") || input.contains("https://") || input.contains("file:") || input.contains("@import") {
            warnings.append("External network and file resources were blocked; embed required assets as data URLs.")
        }
        return warnings
    }

    private static func importedLayer(for primitive: HTMLPrimitive, renderer: HTMLDesignWebRenderer,
                                      warnings: inout [String]) async throws -> HTMLImportedLayer {
        let name = normalizedName(primitive.name)
        switch primitive.kind {
        case .shape:
            let color = try parsedColor(primitive.color)
            let kind: ShapeKind = primitive.radius >= min(primitive.width, primitive.height) / 2
                && abs(primitive.width - primitive.height) < 0.5 ? .ellipse : .rectangle
            let size = CGSize(width: max(1, ceil(primitive.width)), height: max(1, ceil(primitive.height)))
            let style = LayerShapeStyle(kind: kind, red: color.red, green: color.green, blue: color.blue,
                                        cornerRadius: kind == .ellipse ? 0 : primitive.radius)
            let image = try EditorSession.shapeImage(kind, size: size, color: style.color, cornerRadius: style.cornerRadius)
            let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)
            return HTMLImportedLayer(id: UUID(), name: name, asset: asset,
                transform: LayerTransform(origin: CGPoint(x: primitive.x, y: primitive.y), size: size),
                opacity: color.alpha, shape: style, text: nil)

        case .text:
            let color = try parsedColor(primitive.color)
            let font = resolvedFont(family: primitive.fontFamily, size: primitive.fontSize,
                                    weight: primitive.fontWeight, italic: primitive.italic)
            if font.substituted {
                warnings.append("Substituted an unavailable web font with a system font on one or more text layers.")
            }
            let padding = LayerTextStyle.padding
            let contentHeight = max(primitive.height, CGFloat(primitive.lineCount) * primitive.lineHeight)
            var style = LayerTextStyle(content: primitive.text, fontName: font.name, fontSize: primitive.fontSize,
                red: color.red, green: color.green, blue: color.blue, alignment: primitive.alignment,
                tracking: primitive.tracking, leading: primitive.lineHeight,
                boxSize: CGSize(width: max(16, ceil(primitive.width + padding * 2)),
                                height: max(16, ceil(contentHeight + padding * 2))))
            // A computed browser line height equal to the normal 1.2 multiplier maps to Compositor's Auto.
            if abs(style.leading - style.autoLeading) < 0.05 { style.leading = 0 }
            let image = try EditorSession.textImage(style)
            let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)
            let originY = primitive.inkTop.flatMap { inkTop in
                firstVisibleRow(in: image).map { inkTop - CGFloat($0) }
            } ?? (primitive.y - padding)
            return HTMLImportedLayer(id: UUID(), name: name, asset: asset,
                transform: LayerTransform(origin: CGPoint(x: primitive.x - padding, y: originY),
                                          size: CGSize(width: image.width, height: image.height)),
                opacity: color.alpha, shape: nil, text: style)

        case .raster:
            let image = try await renderer.snapshot(element: primitive.identifier, rect: primitive.rect,
                                                     includeContents: primitive.rasterContent)
            let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)
            return HTMLImportedLayer(id: UUID(), name: name, asset: asset,
                transform: LayerTransform(origin: CGPoint(x: primitive.x, y: primitive.y),
                                          size: CGSize(width: primitive.width, height: primitive.height)),
                opacity: 1, shape: nil, text: nil)
        }
    }

    private static func firstVisibleRow(in image: CGImage) -> Int? {
        guard image.bitsPerPixel == 32, image.alphaInfo != .none, image.alphaInfo != .noneSkipFirst,
              image.alphaInfo != .noneSkipLast, let data = image.dataProvider?.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let alphaOffset = image.alphaInfo == .premultipliedFirst || image.alphaInfo == .first ? 0 : 3
        for y in 0..<image.height {
            let row = y * image.bytesPerRow
            for x in 0..<image.width where bytes[row + x * 4 + alphaOffset] > 0 { return y }
        }
        return nil
    }

    private static func rasterLayer(image: CGImage, name: String, width: Int, height: Int) throws -> HTMLImportedLayer {
        let asset = ImportedImage(image: image, thumbnail: try PixelInvert.thumbnail(of: image), name: name)
        return HTMLImportedLayer(id: UUID(), name: name, asset: asset,
            transform: LayerTransform(origin: .zero, size: CGSize(width: width, height: height)),
            opacity: 1, shape: nil, text: nil)
    }

    private static func projectSnapshot(layers: [HTMLImportedLayer], width: Int, height: Int) -> ProjectSnapshot {
        var images: [UUID: ImportedImage] = [:]
        let records = layers.map { layer -> ProjectLayerRecord in
            images[layer.id] = layer.asset
            return ProjectLayerRecord(id: layer.id, name: layer.name, isVisible: true, transform: layer.transform,
                imageFile: "\(layer.id.uuidString).png", opacity: layer.opacity,
                shape: layer.shape, text: layer.text)
        }
        return ProjectSnapshot(manifest: ProjectManifest(documentID: UUID(), width: width, height: height,
            activeLayerID: layers.last?.id, layers: records), images: images)
    }

    private static func parsedColor(_ css: String) throws -> (red: CGFloat, green: CGFloat, blue: CGFloat, alpha: Double) {
        let numbers = css.split(whereSeparator: { !$0.isNumber && $0 != "." && $0 != "-" }).compactMap { Double($0) }
        guard numbers.count >= 3 else { throw HTMLDesignImportError.extractionFailed }
        return (CGFloat(min(255, max(0, numbers[0]))) / 255,
                CGFloat(min(255, max(0, numbers[1]))) / 255,
                CGFloat(min(255, max(0, numbers[2]))) / 255,
                min(1, max(0, numbers.count > 3 ? numbers[3] : 1)))
    }

    private static func resolvedFont(family: String, size: CGFloat, weight: Int, italic: Bool) -> (name: String, substituted: Bool) {
        let families = family.split(separator: ",").map {
            String($0).trimmingCharacters(in: CharacterSet(charactersIn: " \'\""))
        }.filter { !$0.isEmpty }
        let cssWeight = min(900, max(100, weight))
        let systemWeight = NSFont.Weight(CGFloat(cssWeight - 400) / 500)
        let manager = NSFontManager.shared
        var traits: NSFontTraitMask = []
        if cssWeight >= 600 { traits.insert(.boldFontMask) }
        if italic { traits.insert(.italicFontMask) }
        var font: NSFont?
        var foundRequested = false
        for requested in families {
            switch requested.lowercased() {
            case "system-ui", "-apple-system", "blinkmacsystemfont", "sans-serif":
                font = NSFont.systemFont(ofSize: size, weight: systemWeight)
            case "monospace":
                font = NSFont.monospacedSystemFont(ofSize: size, weight: systemWeight)
            case "serif":
                font = manager.font(withFamily: "Times New Roman", traits: traits,
                                    weight: max(0, min(15, (cssWeight - 100) * 14 / 800)), size: size)
                    ?? NSFont(name: "Times-Roman", size: size)
            default:
                font = manager.font(withFamily: requested, traits: traits,
                                    weight: max(0, min(15, (cssWeight - 100) * 14 / 800)), size: size)
                    ?? NSFont(name: requested, size: size).map { manager.convert($0, toHaveTrait: traits) }
                if font != nil { foundRequested = true }
            }
            if font != nil { break }
        }
        if font == nil { font = NSFont.systemFont(ofSize: size, weight: systemWeight) }
        if italic, let current = font, !manager.traits(of: current).contains(.italicFontMask) {
            font = manager.convert(current, toHaveTrait: .italicFontMask)
        }
        let namedRequests = families.filter { !["system-ui", "-apple-system", "blinkmacsystemfont", "sans-serif", "monospace", "serif"].contains($0.lowercased()) }
        return (font?.fontName ?? NSFont.systemFont(ofSize: size).fontName,
                !namedRequests.isEmpty && !foundRequested)
    }
}

private struct HTMLImportedLayer {
    let id: UUID
    let name: String
    let asset: ImportedImage
    let transform: LayerTransform
    let opacity: Double
    let shape: LayerShapeStyle?
    let text: LayerTextStyle?
}

private extension Array where Element: Hashable {
    func uniqued() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}

private struct HTMLInspection: Decodable {
    let elementCount: Int
    let primitives: [HTMLPrimitive]
    let unsupported: [String]
}

private struct HTMLPrimitive: Decodable {
    enum Kind: String, Decodable { case shape, text, raster }
    let kind: Kind
    let name: String
    let x: CGFloat
    let y: CGFloat
    let width: CGFloat
    let height: CGFloat
    let color: String
    let radius: CGFloat
    let text: String
    let fontFamily: String
    let fontSize: CGFloat
    let fontWeight: Int
    let italic: Bool
    let alignment: TextAlignment
    let tracking: CGFloat
    let lineHeight: CGFloat
    let identifier: Int
    let rasterContent: Bool
    let inkTop: CGFloat?
    let lineCount: Int
    var rect: CGRect { CGRect(x: x, y: y, width: width, height: height) }

    private enum CodingKeys: String, CodingKey {
        case kind, name, x, y, width, height, color, radius, text, fontFamily, fontSize, fontWeight
        case italic, alignment, tracking, lineHeight, identifier, rasterContent, inkTop, lineCount
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        kind = try values.decode(Kind.self, forKey: .kind)
        name = try values.decode(String.self, forKey: .name)
        x = try values.decode(CGFloat.self, forKey: .x)
        y = try values.decode(CGFloat.self, forKey: .y)
        width = try values.decode(CGFloat.self, forKey: .width)
        height = try values.decode(CGFloat.self, forKey: .height)
        color = try values.decode(String.self, forKey: .color)
        radius = try values.decodeIfPresent(CGFloat.self, forKey: .radius) ?? 0
        text = try values.decodeIfPresent(String.self, forKey: .text) ?? ""
        fontFamily = try values.decodeIfPresent(String.self, forKey: .fontFamily) ?? "Helvetica"
        fontSize = try values.decodeIfPresent(CGFloat.self, forKey: .fontSize) ?? 16
        fontWeight = try values.decodeIfPresent(Int.self, forKey: .fontWeight) ?? 400
        italic = try values.decodeIfPresent(Bool.self, forKey: .italic) ?? false
        alignment = TextAlignment(rawValue: try values.decodeIfPresent(String.self, forKey: .alignment)?.capitalized ?? "Left") ?? .left
        tracking = try values.decodeIfPresent(CGFloat.self, forKey: .tracking) ?? 0
        lineHeight = try values.decodeIfPresent(CGFloat.self, forKey: .lineHeight) ?? fontSize * 1.2
        identifier = try values.decodeIfPresent(Int.self, forKey: .identifier) ?? -1
        rasterContent = try values.decodeIfPresent(Bool.self, forKey: .rasterContent) ?? false
        inkTop = try values.decodeIfPresent(CGFloat.self, forKey: .inkTop)
        lineCount = max(1, try values.decodeIfPresent(Int.self, forKey: .lineCount) ?? 1)
    }
}

@MainActor
private final class HTMLAsyncGate<Value> {
    private var continuation: CheckedContinuation<Value, Error>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingResult: Result<Value, Error>?
    private var isFinished = false
    private let cancellationAction: () -> Void

    init(cancellationAction: @escaping () -> Void = {}) {
        self.cancellationAction = cancellationAction
    }

    @discardableResult
    func begin(continuation: CheckedContinuation<Value, Error>, timeout: Duration, error: Error) -> Bool {
        if let pendingResult {
            self.pendingResult = nil
            continuation.resume(with: pendingResult)
            return false
        }
        self.continuation = continuation
        timeoutTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(for: timeout) }
            catch { return }
            self?.interrupt(with: error)
        }
        return true
    }

    func finish(_ result: Result<Value, Error>) {
        guard !isFinished else { return }
        isFinished = true
        guard let continuation else {
            pendingResult = result
            return
        }
        self.continuation = nil
        timeoutTask?.cancel()
        timeoutTask = nil
        continuation.resume(with: result)
    }

    func cancel() {
        interrupt(with: CancellationError())
    }

    private func interrupt(with error: Error) {
        guard !isFinished else { return }
        cancellationAction()
        finish(.failure(error))
    }
}

@MainActor
private final class HTMLDesignWebRenderer: NSObject, WKNavigationDelegate {
    private let width: Int
    private let height: Int
    private let webView: WKWebView
    private var loadGate: HTMLAsyncGate<Void>?

    init(width: Int, height: Int) {
        self.width = width
        self.height = height
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        webView = WKWebView(frame: CGRect(x: 0, y: 0, width: width, height: height), configuration: configuration)
        webView.underPageBackgroundColor = .clear
        super.init()
        webView.navigationDelegate = self
    }

    func load(document: String) async throws {
        let gate = HTMLAsyncGate<Void>(cancellationAction: { [weak self] in self?.webView.stopLoading() })
        loadGate = gate
        defer { loadGate = nil }
        try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                guard gate.begin(continuation: continuation, timeout: .seconds(5), error: HTMLDesignImportError.timedOut) else { return }
                self.webView.loadHTMLString(document, baseURL: nil)
            }
        }, onCancel: {
            Task { @MainActor in gate.cancel() }
        })
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        finishLoading(.success(()))
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(HTMLDesignImportError.loadFailed))
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        finishLoading(.failure(HTMLDesignImportError.loadFailed))
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        let scheme = navigationAction.request.url?.scheme?.lowercased()
        decisionHandler(scheme == nil || scheme == "about" ? .allow : .cancel)
    }

    private func finishLoading(_ result: Result<Void, Error>) {
        loadGate?.finish(result)
    }

    func settle() async throws {
        let script = """
        if (document.readyState !== 'complete') {
          await new Promise(resolve => window.addEventListener('load', resolve, { once: true }));
        }
        if (document.fonts && document.fonts.ready) await document.fonts.ready;
        const images = Array.from(document.images);
        await Promise.all(images.map(async image => {
          if (!image.complete) await new Promise(resolve => {
            image.addEventListener('load', resolve, { once: true });
            image.addEventListener('error', resolve, { once: true });
          });
          if (image.decode) { try { await image.decode(); } catch (_) {} }
        }));
        // Reading layout synchronously commits loaded CSS and decoded intrinsic image sizes.
        void document.documentElement.getBoundingClientRect();
        return true;
        """
        let result: Any? = try await boundedCallAsyncJavaScript(script, timeout: .seconds(3))
        guard result as? Bool == true else { throw HTMLDesignImportError.timedOut }
    }

    func inspect() async throws -> HTMLInspection {
        let value = try await boundedJavaScript(Self.inspectionScript, timeout: .seconds(3))
        guard let json = value as? String, let data = json.data(using: .utf8) else {
            throw HTMLDesignImportError.extractionFailed
        }
        do { return try JSONDecoder().decode(HTMLInspection.self, from: data) }
        catch { throw HTMLDesignImportError.extractionFailed }
    }

    func snapshot() async throws -> CGImage {
        let transparent = try await rawSnapshot(rect: CGRect(x: 0, y: 0, width: width, height: height))
        guard let context = CGContext(data: nil, width: transparent.width, height: transparent.height,
            bitsPerComponent: 8, bytesPerRow: transparent.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
            throw HTMLDesignImportError.renderFailed
        }
        context.setFillColor(CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: transparent.width, height: transparent.height))
        context.draw(transparent, in: CGRect(x: 0, y: 0, width: transparent.width, height: transparent.height))
        guard let flattened = context.makeImage() else { throw HTMLDesignImportError.renderFailed }
        return flattened
    }

    func snapshot(element identifier: Int, rect: CGRect, includeContents: Bool) async throws -> CGImage {
        guard identifier >= 0, rect.width >= 0.5, rect.height >= 0.5 else { throw HTMLDesignImportError.extractionFailed }
        func isolated(over backdrop: NSColor, cssColor: String) async throws -> CGImage {
            webView.underPageBackgroundColor = backdrop
            let prepared = try await boundedJavaScript(
                Self.isolateScript(identifier: identifier, includeContents: includeContents, backdrop: cssColor), timeout: .seconds(2))
            guard prepared as? Bool == true else { throw HTMLDesignImportError.extractionFailed }
            do {
                let image = try await rawSnapshot(rect: rect)
                _ = try? await boundedJavaScript(Self.restoreScript, timeout: .seconds(1))
                return image
            } catch {
                _ = try? await boundedJavaScript(Self.restoreScript, timeout: .seconds(1))
                throw error
            }
        }
        defer { webView.underPageBackgroundColor = .clear }
        let black = try await isolated(over: .black, cssColor: "#000")
        let white = try await isolated(over: .white, cssColor: "#fff")
        return try Self.reconstructedAlpha(black: black, white: white)
    }

    /// WK snapshots are opaque even when the page underlay is clear. Rendering the isolated
    /// element over black and white recovers its premultiplied color and coverage exactly:
    /// whiteRGB - blackRGB = 1 - alpha.
    private static func reconstructedAlpha(black: CGImage, white: CGImage) throws -> CGImage {
        guard black.width == white.width, black.height == white.height else { throw HTMLDesignImportError.renderFailed }
        func normalized(_ image: CGImage) throws -> CGImage {
            let context = try BrushRaster.context(width: image.width, height: image.height, mask: false)
            BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height),
                             mask: false, context: context)
            guard let result = context.makeImage() else { throw HTMLDesignImportError.renderFailed }
            return result
        }
        let dark = try normalized(black), light = try normalized(white)
        guard let darkData = dark.dataProvider?.data, let lightData = light.dataProvider?.data,
              let darkBytes = CFDataGetBytePtr(darkData), let lightBytes = CFDataGetBytePtr(lightData) else {
            throw HTMLDesignImportError.renderFailed
        }
        let output = try BrushRaster.context(width: dark.width, height: dark.height, mask: false)
        guard let result = output.data?.assumingMemoryBound(to: UInt8.self) else { throw HTMLDesignImportError.renderFailed }
        for y in 0..<dark.height {
            let darkRow = y * dark.bytesPerRow, lightRow = y * light.bytesPerRow, outputRow = y * output.bytesPerRow
            for x in 0..<dark.width {
                let source = darkRow + x * 4, comparison = lightRow + x * 4, destination = outputRow + x * 4
                let backdrop = (Int(lightBytes[comparison]) - Int(darkBytes[source])
                    + Int(lightBytes[comparison + 1]) - Int(darkBytes[source + 1])
                    + Int(lightBytes[comparison + 2]) - Int(darkBytes[source + 2])) / 3
                result[destination] = darkBytes[source]
                result[destination + 1] = darkBytes[source + 1]
                result[destination + 2] = darkBytes[source + 2]
                result[destination + 3] = UInt8(max(0, min(255, 255 - backdrop)))
            }
        }
        guard let image = output.makeImage() else { throw HTMLDesignImportError.renderFailed }
        return image
    }

    private func rawSnapshot(rect: CGRect) async throws -> CGImage {
        let configuration = WKSnapshotConfiguration()
        configuration.rect = rect
        configuration.snapshotWidth = NSNumber(value: max(1, ceil(rect.width)))
        configuration.afterScreenUpdates = true
        let gate = HTMLAsyncGate<NSImage>()
        let image: NSImage = try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                guard gate.begin(continuation: continuation, timeout: .seconds(4), error: HTMLDesignImportError.timedOut) else { return }
                webView.takeSnapshot(with: configuration) { image, error in
                    if let image { gate.finish(.success(image)) }
                    else { gate.finish(.failure(error ?? HTMLDesignImportError.renderFailed)) }
                }
            }
        }, onCancel: {
            Task { @MainActor in gate.cancel() }
        })
        var rect = CGRect(origin: .zero, size: image.size)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw HTMLDesignImportError.renderFailed
        }
        return cgImage
    }

    private func boundedJavaScript(_ script: String, timeout: Duration) async throws -> Any? {
        let gate = HTMLAsyncGate<Any?>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                guard gate.begin(continuation: continuation, timeout: timeout, error: HTMLDesignImportError.timedOut) else { return }
                webView.evaluateJavaScript(script) { value, error in
                    if let error { gate.finish(.failure(error)) }
                    else { gate.finish(.success(value)) }
                }
            }
        }, onCancel: {
            Task { @MainActor in gate.cancel() }
        })
    }

    private func boundedCallAsyncJavaScript(_ script: String, timeout: Duration) async throws -> Any? {
        let gate = HTMLAsyncGate<Any?>()
        return try await withTaskCancellationHandler(operation: {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Any?, Error>) in
                guard gate.begin(continuation: continuation, timeout: timeout, error: HTMLDesignImportError.timedOut) else { return }
                webView.callAsyncJavaScript(script, arguments: [:], in: nil, in: .page, completionHandler: { result in
                    gate.finish(result.map(Optional.some))
                })
            }
        }, onCancel: {
            Task { @MainActor in gate.cancel() }
        })
    }

    private static func isolateScript(identifier: Int, includeContents: Bool, backdrop: String) -> String {
        """
        (() => {
          const target = document.querySelector('[data-compositor-import-id="\(identifier)"]');
          if (!target || window.__compositorRestore) return false;
          const all = Array.from(document.querySelectorAll('*'));
          window.__compositorRestore = all.map(element => [element, element.getAttribute('style')]);
          for (const element of all) element.style.setProperty('visibility', 'hidden', 'important');
          const ancestors = [];
          for (let current = target.parentElement; current; current = current.parentElement) ancestors.push(current);
          for (const element of ancestors) {
            element.style.setProperty('visibility', 'visible', 'important');
            element.style.setProperty('background', 'transparent', 'important');
            element.style.setProperty('border-color', 'transparent', 'important');
            element.style.setProperty('box-shadow', 'none', 'important');
          }
          // WKSnapshotConfiguration always returns an opaque NSImage. Put a known matte
          // behind the isolated target so two snapshots can recover its original alpha.
          if (target !== document.documentElement) {
            document.documentElement.style.setProperty('background', '\(backdrop)', 'important');
          }
          target.style.setProperty('visibility', 'visible', 'important');
          if (!\(includeContents ? "true" : "false")) {
            target.style.setProperty('color', 'transparent', 'important');
            target.style.setProperty('text-shadow', 'none', 'important');
            for (const child of target.querySelectorAll('*')) child.style.setProperty('visibility', 'hidden', 'important');
          } else {
            for (const child of target.querySelectorAll('*')) child.style.setProperty('visibility', 'visible', 'important');
          }
          return true;
        })()
        """
    }

    private static let restoreScript = """
    (() => {
      const saved = window.__compositorRestore;
      if (!saved) return false;
      for (const [element, style] of saved) {
        if (style === null) element.removeAttribute('style'); else element.setAttribute('style', style);
      }
      delete window.__compositorRestore;
      return true;
    })()
    """

    private static let inspectionScript = #"""
    (() => {
      const viewport = { width: window.innerWidth, height: window.innerHeight };
      const elements = Array.from(document.body.querySelectorAll('*'));
      if (elements.length > 2000) return JSON.stringify({ elementCount: elements.length, primitives: [], unsupported: [] });
      const roots = [document.documentElement, document.body];
      const all = roots.concat(elements);
      const primitives = [];
      const unsupported = new Set();
      const rasterSubtrees = [];
      let order = 0;
      const px = value => {
        const number = parseFloat(value);
        return Number.isFinite(number) ? number : 0;
      };
      const visibleRect = rect => {
        const x = Math.max(0, rect.left), y = Math.max(0, rect.top);
        const right = Math.min(viewport.width, rect.right), bottom = Math.min(viewport.height, rect.bottom);
        return { x, y, width: Math.max(0, right - x), height: Math.max(0, bottom - y) };
      };
      const hasInk = color => color && color !== 'rgba(0, 0, 0, 0)' && color !== 'transparent';
      const addUnsupported = reason => { if (unsupported.size < 20) unsupported.add(reason); };
      for (let identifier = 0; identifier < all.length; identifier++) {
        const element = all[identifier];
        element.setAttribute('data-compositor-import-id', String(identifier));
        if (rasterSubtrees.some(root => root !== element && root.contains(element))) continue;
        const style = getComputedStyle(element);
        const raw = element.getBoundingClientRect();
        const rect = visibleRect(raw);
        if (style.display === 'none' || style.visibility !== 'visible' || rect.width < .5 || rect.height < .5) continue;
        const tag = element.tagName.toLowerCase();
        if (['script', 'style', 'link', 'meta', 'title', 'head'].includes(tag)) continue;
        if (['img', 'svg', 'canvas', 'video'].includes(tag)) {
          primitives.push({ kind: 'raster', identifier, rasterContent: true, name: element.id || element.getAttribute('alt') || tag,
            x: rect.x, y: rect.y, width: rect.width, height: rect.height, color: 'rgba(0, 0, 0, 0)', radius: 0,
            text: '', fontFamily: '', fontSize: 0, fontWeight: 400, italic: false, alignment: 'left', tracking: 0,
            lineHeight: 0, z: parseInt(style.zIndex) || 0, order: order++ });
          rasterSubtrees.push(element);
          continue;
        }
        if (['audio', 'iframe', 'object', 'embed', 'input', 'textarea', 'select', 'button'].includes(tag)) {
          addUnsupported(tag + ' content');
          continue;
        }
        const before = getComputedStyle(element, '::before').content;
        const after = getComputedStyle(element, '::after').content;
        if ((before && before !== 'none' && before !== 'normal') || (after && after !== 'none' && after !== 'normal')) addUnsupported('generated content');
        if ((style.boxShadow && style.boxShadow !== 'none') || (style.textShadow && style.textShadow !== 'none')) addUnsupported('shadows');
        if ((style.transform && style.transform !== 'none') || (style.filter && style.filter !== 'none')
            || (style.backdropFilter && style.backdropFilter !== 'none')) addUnsupported('CSS transforms or filters');
        if ((style.clipPath && style.clipPath !== 'none') || (style.maskImage && style.maskImage !== 'none')) addUnsupported('clipping or masks');
        if ((style.mixBlendMode && style.mixBlendMode !== 'normal') || style.isolation === 'isolate') addUnsupported('CSS compositing');
        if (style.opacity !== '1') addUnsupported('element opacity');
        if (element !== document.documentElement && element !== document.body
            && style.overflow !== 'visible' && element.scrollHeight > element.clientHeight + 1) addUnsupported('clipped overflow');
        const border = px(style.borderTopWidth) + px(style.borderRightWidth) + px(style.borderBottomWidth) + px(style.borderLeftWidth);
        if ((style.textDecorationLine && style.textDecorationLine !== 'none') || px(style.webkitTextStrokeWidth) > 0) addUnsupported('decorated text');
        if (['ul', 'ol', 'li', 'table', 'thead', 'tbody', 'tfoot', 'tr', 'td', 'th'].includes(tag)) addUnsupported('lists or tables');

        const radii = [style.borderTopLeftRadius, style.borderTopRightRadius, style.borderBottomRightRadius, style.borderBottomLeftRadius];
        const radiusValues = radii.map(px);
        const complexRadius = radii.some(value => value.includes('%') || value.trim().split(/\s+/).length > 1)
          || Math.max(...radiusValues) - Math.min(...radiusValues) > .25;
        const rasterBackground = style.backgroundImage !== 'none' || border > 0 || complexRadius;
        if (rasterBackground && (style.backgroundImage !== 'none' || hasInk(style.backgroundColor) || border > 0)) {
          primitives.push({ kind: 'raster', identifier, name: element.id || element.getAttribute('aria-label') || tag,
            x: rect.x, y: rect.y, width: rect.width, height: rect.height, color: 'rgba(0, 0, 0, 0)', radius: complexRadius ? 0 : radiusValues[0],
            text: '', fontFamily: '', fontSize: 0, fontWeight: 400, italic: false, alignment: 'left', tracking: 0,
            lineHeight: 0, z: parseInt(style.zIndex) || 0, order: order++ });
        } else if (hasInk(style.backgroundColor)) {
          primitives.push({ kind: 'shape', identifier, name: element.id || element.getAttribute('aria-label') || tag,
            x: rect.x, y: rect.y, width: rect.width, height: rect.height, color: style.backgroundColor,
            radius: radiusValues[0], text: '', fontFamily: '', fontSize: 0, fontWeight: 400, italic: false,
            alignment: 'left', tracking: 0, lineHeight: 0, z: parseInt(style.zIndex) || 0, order: order++ });
        }

        const children = Array.from(element.children).filter(child => {
          const childStyle = getComputedStyle(child);
          return child.tagName.toLowerCase() !== 'br' && childStyle.display !== 'none' && childStyle.visibility === 'visible';
        });
        const directText = Array.from(element.childNodes).filter(node => node.nodeType === Node.TEXT_NODE).map(node => node.textContent).join('');
        if (children.length > 0 && directText.trim().length > 0) {
          addUnsupported('mixed inline text');
        } else if (children.length === 0 && directText.trim().length > 0) {
          const range = document.createRange();
          range.selectNodeContents(element);
          const textRect = visibleRect(range.getBoundingClientRect());
          if (textRect.width > .5 && textRect.height > .5) {
            let text = element.innerText;
            if (!/^(pre|pre-wrap|break-spaces)$/.test(style.whiteSpace)) {
              text = text.split('\n').map(line => line.replace(/[\t ]+/g, ' ').trim()).join('\n').trim();
            }
            // LayerTextStyle is intentionally capped so a project remains editable and saveable.
            // JavaScript's string length is UTF-16, matching Swift's `content.utf16.count` check.
            if (text.length > 100000) {
              addUnsupported('text content outside Compositor limits');
              continue;
            }
            const lineHeight = style.lineHeight === 'normal' ? px(style.fontSize) * 1.2 : px(style.lineHeight);
            if (px(style.fontSize) < 1 || px(style.fontSize) > 2000 || lineHeight < 0 || lineHeight > 5000
                || (style.letterSpacing !== 'normal' && (px(style.letterSpacing) < -100 || px(style.letterSpacing) > 1000))) {
              addUnsupported('text metrics outside Compositor limits');
              continue;
            }
            const inline = style.display.startsWith('inline');
            const horizontalInsets = px(style.borderLeftWidth) + px(style.paddingLeft) + px(style.paddingRight) + px(style.borderRightWidth);
            const textBox = inline ? textRect : { x: raw.left + px(style.borderLeftWidth) + px(style.paddingLeft), y: textRect.y,
              width: Math.max(1, raw.width - horizontalInsets), height: textRect.height };
            const clippedTextBox = visibleRect({ left: textBox.x, top: textBox.y, right: textBox.x + textBox.width, bottom: textBox.y + textBox.height });
            const canvas = document.createElement('canvas').getContext('2d');
            canvas.font = style.font;
            const metrics = canvas.measureText(text.split('\n')[0] || ' ');
            const ascentGap = Number.isFinite(metrics.fontBoundingBoxAscent) && Number.isFinite(metrics.actualBoundingBoxAscent)
              ? Math.max(0, metrics.fontBoundingBoxAscent - metrics.actualBoundingBoxAscent) : 0;
            const lineRects = Array.from(range.getClientRects()).filter(value => value.width > .25 && value.height > .25);
            const lineCount = Math.max(text.split('\n').length,
              new Set(lineRects.map(value => Math.round(value.top * 4) / 4)).size);
            primitives.push({ kind: 'text', identifier, name: (text.slice(0, 40) || tag), x: clippedTextBox.x, y: clippedTextBox.y,
              width: clippedTextBox.width, height: clippedTextBox.height, color: style.color, radius: 0, text,
              fontFamily: style.fontFamily, fontSize: px(style.fontSize), fontWeight: parseInt(style.fontWeight) || 400,
              italic: style.fontStyle !== 'normal', alignment: style.textAlign, tracking: style.letterSpacing === 'normal' ? 0 : px(style.letterSpacing),
              lineHeight, inkTop: textRect.y + ascentGap, lineCount, z: parseInt(style.zIndex) || 0, order: order++ });
          }
        }
      }
      // White is WebKit's default canvas color, even when html and body are transparent.
      primitives.unshift({ kind: 'shape', identifier: -1, name: 'Canvas background', x: 0, y: 0, width: viewport.width, height: viewport.height,
        color: 'rgb(255, 255, 255)', radius: 0, text: '', fontFamily: '', fontSize: 0, fontWeight: 400,
        italic: false, alignment: 'left', tracking: 0, lineHeight: 0, z: -2147483648, order: -1 });
      primitives.sort((a, b) => a.z - b.z || a.order - b.order);
      return JSON.stringify({ elementCount: elements.length, primitives, unsupported: Array.from(unsupported) });
    })()
    """#
}
