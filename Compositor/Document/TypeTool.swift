import AppKit
import CoreText

nonisolated enum TextAlignment: String, Codable, CaseIterable, Sendable {
    case left = "Left", center = "Center", right = "Right"
}

nonisolated enum TextOrientation: String, Codable, CaseIterable, Sendable {
    case horizontal = "Horizontal"
    case vertical = "Vertical"
}

/// A Pen path copied into a text layer. The nodes stay in unit coordinates so the letters follow the layer through
/// moves, transforms and reopening the project. `startOffset` is a fraction of one trip around the path.
nonisolated struct LayerTextPath: Codable, Equatable, Sendable {
    var nodes: [VectorPathNode]
    var closed: Bool
    var canvasSize: CGSize
    var startOffset: CGFloat

    var isValid: Bool {
        nodes.count >= (closed ? 3 : 2) && nodes.count <= 10_000
            && nodes.allSatisfy { node in
                node.isFinite && [node.anchor, node.inHandle, node.outHandle].allSatisfy {
                    (-0.000_001...1.000_001).contains($0.x) && (-0.000_001...1.000_001).contains($0.y)
                }
            }
            && canvasSize.width.isFinite && canvasSize.height.isFinite
            && (1...DocumentLimits.maxSideExtent).contains(canvasSize.width)
            && (1...DocumentLimits.maxSideExtent).contains(canvasSize.height)
            && canvasSize.width * canvasSize.height <= DocumentLimits.maxSurfaceExtent
            && startOffset.isFinite && (0...1).contains(startOffset)
            && hasDrawableSegment
    }

    /// Two different records are not enough: damaged metadata can repeat the same point thousands of times and
    /// otherwise produce a valid-looking but zero-length path whose editable text is permanently invisible.
    private var hasDrawableSegment: Bool {
        guard nodes.count >= 2 else { return false }
        let segmentCount = nodes.count - 1 + (closed ? 1 : 0)
        for index in 0..<segmentCount {
            let first = nodes[index], second = nodes[(index + 1) % nodes.count]
            if first.anchor != first.outHandle || first.anchor != second.inHandle
                || first.anchor != second.anchor { return true }
        }
        return false
    }

    func nodes(in rect: CGRect) -> [VectorPathNode] {
        nodes.map { node in
            func point(_ value: CGPoint) -> CGPoint {
                CGPoint(x: rect.minX + value.x * rect.width, y: rect.minY + value.y * rect.height)
            }
            return VectorPathNode(anchor: point(node.anchor), inHandle: point(node.inHandle),
                                  outHandle: point(node.outHandle))
        }
    }

    func path(in rect: CGRect) -> CGPath {
        LayerVectorPathStyle.path(nodes: nodes(in: rect), closed: closed)
    }
}

nonisolated struct LayerTextStyle: Codable, Equatable, Sendable {
    var content = "Text"
    var fontName = "Helvetica"
    var fontSize: CGFloat = 72
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alignment: TextAlignment = .left
    /// Missing in older projects and in horizontal text, whose layout predates the orientation field.
    var orientation: TextOrientation? = nil
    var resolvedOrientation: TextOrientation { orientation ?? .horizontal }
    var tracking: CGFloat = 0
    /// Baseline to baseline, in layer pixels, as Photoshop's Leading is. 0 is Auto: 120% of the font size.
    var leading: CGFloat = 0
    var autoLeading: CGFloat { fontSize * 1.2 }
    var lineHeight: CGFloat { leading > 0 ? leading : autoLeading }
    /// The gap between the text and its box, in layer pixels — the same for point text and a fixed box, so turning
    /// one into the other doesn't move the text, and wide enough to leave the box's edges easy to grab.
    static let padding: CGFloat = 12
    /// Fixed paragraph bounds in layer pixels. Nil supports older point-text layers.
    var boxSize: CGSize? = nil
    /// A copied Pen path for text-on-path. It is mutually exclusive with a paragraph box and vertical text.
    var textPath: LayerTextPath? = nil
    var textPathPadding: CGFloat { ceil(fontSize * 2 + 4) }
    var textPathCanvasSize: CGSize? {
        textPath.map { CGSize(width: $0.canvasSize.width + textPathPadding * 2,
                              height: $0.canvasSize.height + textPathPadding * 2) }
    }
    var textPathRect: CGRect? {
        textPath.map { CGRect(origin: CGPoint(x: textPathPadding, y: textPathPadding), size: $0.canvasSize) }
    }
    var boxIsValid: Bool {
        guard let boxSize else { return true }
        return boxSize.width.isFinite && boxSize.height.isFinite && (16...DocumentLimits.maxSideExtent).contains(boxSize.width)
            && (16...DocumentLimits.maxSideExtent).contains(boxSize.height) && boxSize.width * boxSize.height <= DocumentLimits.maxSurfaceExtent
    }
    /// Letters painted in a color other than `red`/`green`/`blue`, in UTF-16 offsets into `content`, sorted and not
    /// overlapping. Nil when the whole text is one color.
    var colorRuns: [LayerTextColorRun]? = nil
    /// Letters set in a face other than `fontName`, in the same offsets. Nil when the whole text is one face.
    var fontRuns: [LayerTextFontRun]? = nil
    var isValid: Bool {
        content.utf16.count <= 100_000 && boxIsValid
        && fontSize.isFinite && (1...2000).contains(fontSize)
        && [red, green, blue].allSatisfy { $0.isFinite && (0...1).contains($0) }
        && tracking.isFinite && (-100...1000).contains(tracking)
        && leading.isFinite && (0...5000).contains(leading)
        && (textPath?.isValid ?? true) && (textPath == nil || (boxSize == nil && resolvedOrientation == .horizontal))
        && textPathBoxIsValid
        && colorRunsAreValid && fontRunsAreValid
    }
    private var textPathBoxIsValid: Bool {
        guard let size = textPathCanvasSize else { return true }
        return size.width.isFinite && size.height.isFinite
            && size.width <= DocumentLimits.maxSideExtent && size.height <= DocumentLimits.maxSideExtent
            && size.width * size.height <= DocumentLimits.maxSurfaceExtent
    }
    private var colorRunsAreValid: Bool {
        guard let colorRuns else { return true }
        var end = 0
        for run in colorRuns {
            guard run.location >= end, run.length > 0, run.location <= Int.max - run.length,
                  [run.red, run.green, run.blue].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { return false }
            end = run.location + run.length
        }
        return !colorRuns.isEmpty && end <= content.utf16.count
    }
    private var fontRunsAreValid: Bool {
        guard let fontRuns else { return true }
        var end = 0
        for run in fontRuns {
            guard run.location >= end, run.length > 0, run.location <= Int.max - run.length,
                  !run.fontName.isEmpty, run.fontName.count <= 200, !run.fontName.contains(where: \.isNewline) else { return false }
            end = run.location + run.length
        }
        return !fontRuns.isEmpty && end <= content.utf16.count
    }

    /// The color of the UTF-16 unit at `index`.
    func color(at index: Int) -> PaletteColor {
        let run = colorRuns?.first { $0.location <= index && index < $0.location + $0.length }
        return run.map { PaletteColor(red: $0.red, green: $0.green, blue: $0.blue) } ?? PaletteColor(red: red, green: green, blue: blue)
    }

    /// Paints `range` in `color`. An empty range, or one covering the whole text, recolors all of it.
    mutating func setColor(_ color: PaletteColor, in range: NSRange) {
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if start == end || (start == 0 && end == count) {
            red = color.red; green = color.green; blue = color.blue
            colorRuns = nil
            return
        }
        var colors = unitColors
        for index in start..<end { colors[index] = color }
        setUnitColors(colors)
    }

    /// The face of the UTF-16 unit at `index`.
    func fontName(at index: Int) -> String {
        fontRuns?.first { $0.location <= index && index < $0.location + $0.length }?.fontName ?? fontName
    }

    /// The one face covering `range`, or nil when that range is empty or uses more than one.
    func uniformFontName(in range: NSRange) -> String? {
        let count = content.utf16.count
        let start = max(0, min(range.location, count))
        let end = max(start, min(range.location + range.length, count))
        guard end > start else { return nil }
        let face = fontName(at: start)
        var index = start
        for run in fontRuns ?? [] where run.location < end && run.location + run.length > index {
            if run.location > index, fontName != face { return nil }
            if run.fontName != face { return nil }
            index = min(end, max(index, run.location + run.length))
        }
        if index < end, fontName != face { return nil }
        return face
    }

    /// Sets the face of `range`. An empty range, or one covering the whole text, changes all of it.
    mutating func setFont(_ name: String, in range: NSRange) {
        guard !name.isEmpty, name.count <= 200, !name.contains(where: \.isNewline) else { return }
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if start == end || (start == 0 && end == count) {
            fontName = name
            fontRuns = nil
            return
        }
        var fonts = unitFonts
        for index in start..<end { fonts[index] = name }
        setUnitFonts(fonts)
    }

    /// Keeps each letter's color and face when `range` of `content` is replaced by `length` new UTF-16 units, which
    /// take them from the letter before, as typing does. Call before `content` changes.
    mutating func replaceCharacters(in range: NSRange, withLength length: Int) {
        let count = content.utf16.count
        let start = max(0, min(range.location, count)), end = max(start, min(range.location + range.length, count))
        if colorRuns != nil {
            var colors = unitColors
            let inherited = start > 0 ? colors[start - 1] : (end > start ? colors[start] : colors.first ?? PaletteColor(red: red, green: green, blue: blue))
            colors.replaceSubrange(start..<end, with: repeatElement(inherited, count: max(0, length)))
            setUnitColors(colors)
        }
        if fontRuns != nil {
            var fonts = unitFonts
            let inherited = start > 0 ? fonts[start - 1] : (end > start ? fonts[start] : fonts.first ?? fontName)
            fonts.replaceSubrange(start..<end, with: repeatElement(inherited, count: max(0, length)))
            setUnitFonts(fonts)
        }
    }

    private var unitColors: [PaletteColor] {
        let base = PaletteColor(red: red, green: green, blue: blue)
        var colors = Array(repeating: base, count: content.utf16.count)
        for run in colorRuns ?? [] {
            let color = PaletteColor(red: run.red, green: run.green, blue: run.blue)
            for index in max(0, run.location)..<min(colors.count, run.location + run.length) { colors[index] = color }
        }
        return colors
    }

    private mutating func setUnitColors(_ colors: [PaletteColor]) {
        let base = PaletteColor(red: red, green: green, blue: blue)
        var runs: [LayerTextColorRun] = []
        for (index, color) in colors.enumerated() where color != base {
            if let last = runs.last, last.location + last.length == index,
               PaletteColor(red: last.red, green: last.green, blue: last.blue) == color {
                runs[runs.count - 1].length += 1
            } else {
                runs.append(LayerTextColorRun(location: index, length: 1, red: color.red, green: color.green, blue: color.blue))
            }
        }
        colorRuns = runs.isEmpty ? nil : runs
    }

    private var unitFonts: [String] {
        var fonts = Array(repeating: fontName, count: content.utf16.count)
        for run in fontRuns ?? [] {
            for index in max(0, run.location)..<min(fonts.count, run.location + run.length) { fonts[index] = run.fontName }
        }
        return fonts
    }

    private mutating func setUnitFonts(_ fonts: [String]) {
        if let first = fonts.first, fonts.allSatisfy({ $0 == first }) {
            fontName = first
            fontRuns = nil
            return
        }
        var runs: [LayerTextFontRun] = []
        for (index, name) in fonts.enumerated() where name != fontName {
            if let last = runs.last, last.location + last.length == index, last.fontName == name {
                runs[runs.count - 1].length += 1
            } else {
                runs.append(LayerTextFontRun(location: index, length: 1, fontName: name))
            }
        }
        fontRuns = runs.isEmpty ? nil : runs
    }
}

nonisolated struct LayerTextColorRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var red: CGFloat
    var green: CGFloat
    var blue: CGFloat
}

nonisolated struct LayerTextFontRun: Codable, Equatable, Sendable {
    var location: Int
    var length: Int
    var fontName: String
}

/// The cached raster participates in the existing compositor. Pixel edits rasterize the layer;
/// transforms and masks keep the source text editable, just as shape layers keep their source.
nonisolated struct LayerText: Equatable, @unchecked Sendable {
    var style: LayerTextStyle
    let image: CGImage
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.style == rhs.style && lhs.image === rhs.image }
    static func loaded(_ style: LayerTextStyle?, image: CGImage?) -> LayerText? {
        guard let style, style.isValid, let image else { return nil }
        return LayerText(style: style, image: image)
    }
}

extension ImageLayer {
    var liveText: LayerText? {
        guard let text, let image = asset?.image, image === text.image else { return nil }
        return text
    }
}

struct TextDraft: Identifiable {
    let id = UUID()
    let documentID: UUID
    let layerID: UUID?
    var origin: CGPoint
    var transform: LayerTransform? = nil
    var style: LayerTextStyle
    /// What is selected in the on-canvas editor, in UTF-16 offsets into `style.content`. Color and font apply to it.
    var selection = NSRange(location: 0, length: 0)
}

/// A bounded polyline approximation used both for hit testing and glyph placement. Curves subdivide adaptively,
/// so straight paths stay cheap while tight bends remain smooth at native resolution.
nonisolated struct TextPathMetric {
    /// Enough for sub-pixel curves while keeping a hostile or accidental 10,000-node path bounded in memory.
    static let maximumSampleCount = 200_000
    struct Nearest {
        let distanceAlongPath: CGFloat
        let distanceFromPath: CGFloat
    }
    private struct Sample {
        let point: CGPoint
        let distance: CGFloat
    }
    private struct SampleBlock {
        /// Indices of the ending sample for every segment in this block.
        let segmentEnds: Range<Int>
        let bounds: CGRect
    }
    private var samples: [Sample] = []
    private var blocks: [SampleBlock] = []
    var length: CGFloat { samples.last?.distance ?? 0 }
    var sampleCount: Int { samples.count }

    init(nodes: [VectorPathNode], closed: Bool) {
        guard let first = nodes.first else { return }
        samples = [Sample(point: first.anchor, distance: 0)]
        let segmentCount = nodes.count - 1 + (closed ? 1 : 0)
        guard segmentCount > 0 else { return }
        for segment in 0..<segmentCount {
            let remaining = segmentCount - segment
            // Reserve at least one endpoint for every remaining segment. The old hard stop could exhaust the whole
            // budget halfway through a complex path and silently omit every segment after it.
            let allowance = max(1, (Self.maximumSampleCount - samples.count) / remaining)
            append(from: nodes[segment], to: nodes[(segment + 1) % nodes.count], budget: allowance)
        }
        buildBlocks()
    }

    func location(at distance: CGFloat, wrapping: Bool) -> (point: CGPoint, angle: CGFloat)? {
        guard samples.count >= 2, length > 0, distance.isFinite else { return nil }
        var target = distance
        if wrapping {
            target.formTruncatingRemainder(dividingBy: length)
            if target < 0 { target += length }
        } else if target < 0 || target > length { return nil }
        var low = 1, high = samples.count - 1
        while low < high {
            let middle = (low + high) / 2
            if samples[middle].distance < target { low = middle + 1 } else { high = middle }
        }
        let end = samples[low], start = samples[low - 1]
        let segment = end.distance - start.distance
        guard segment > 0 else { return (end.point, 0) }
        let amount = min(1, max(0, (target - start.distance) / segment))
        return (CGPoint(x: start.point.x + (end.point.x - start.point.x) * amount,
                        y: start.point.y + (end.point.y - start.point.y) * amount),
                atan2(end.point.y - start.point.y, end.point.x - start.point.x))
    }

    func nearest(to point: CGPoint) -> Nearest? {
        guard samples.count >= 2 else { return nil }
        var best: Nearest?
        func distance(from bounds: CGRect) -> CGFloat {
            let dx = point.x < bounds.minX ? bounds.minX - point.x
                : point.x > bounds.maxX ? point.x - bounds.maxX : 0
            let dy = point.y < bounds.minY ? bounds.minY - point.y
                : point.y > bounds.maxY ? point.y - bounds.maxY : 0
            return hypot(dx, dy)
        }
        func inspect(_ range: Range<Int>) {
            for index in range {
                let first = samples[index - 1], second = samples[index]
                let dx = second.point.x - first.point.x, dy = second.point.y - first.point.y
                let square = dx * dx + dy * dy
                guard square > 0 else { continue }
                let amount = min(1, max(0, ((point.x - first.point.x) * dx + (point.y - first.point.y) * dy) / square))
                let projected = CGPoint(x: first.point.x + dx * amount, y: first.point.y + dy * amount)
                let away = hypot(point.x - projected.x, point.y - projected.y)
                if best == nil || away < best!.distanceFromPath {
                    best = Nearest(distanceAlongPath: first.distance + sqrt(square) * amount, distanceFromPath: away)
                }
            }
        }
        guard !blocks.isEmpty else { inspect(1..<samples.count); return best }
        // Establish a tight distance from the closest block first, then discard every block whose bounds cannot
        // improve it. A mouse drag on a 200,000-sample path should not scan all 200,000 segments every frame.
        let seed = blocks.indices.min { distance(from: blocks[$0].bounds) < distance(from: blocks[$1].bounds) }!
        inspect(blocks[seed].segmentEnds)
        for index in blocks.indices where index != seed {
            if let best, distance(from: blocks[index].bounds) > best.distanceFromPath { continue }
            inspect(blocks[index].segmentEnds)
        }
        return best
    }

    private mutating func buildBlocks() {
        let blockSize = 64
        var start = 1
        while start < samples.count {
            let end = min(samples.count, start + blockSize)
            let first = samples[start - 1].point
            var minX = first.x, maxX = first.x, minY = first.y, maxY = first.y
            for index in start..<end {
                let point = samples[index].point
                minX = min(minX, point.x); maxX = max(maxX, point.x)
                minY = min(minY, point.y); maxY = max(maxY, point.y)
            }
            blocks.append(SampleBlock(segmentEnds: start..<end,
                bounds: CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)))
            start = end
        }
    }

    private mutating func append(from first: VectorPathNode, to second: VectorPathNode, budget: Int) {
        if first.outHandle == first.anchor && second.inHandle == second.anchor {
            append(second.anchor)
        } else {
            appendCubic(first.anchor, first.outHandle, second.inHandle, second.anchor, depth: 0, budget: budget)
        }
    }

    private mutating func appendCubic(_ start: CGPoint, _ control1: CGPoint, _ control2: CGPoint, _ end: CGPoint,
                                      depth: Int, budget: Int) {
        // Keep the endpoint rather than truncating the path when this segment uses its fair share of the budget.
        if budget <= 1 {
            append(end)
            return
        }
        let flatness = max(Self.distance(control1, fromLine: start, to: end),
                           Self.distance(control2, fromLine: start, to: end))
        if flatness <= 0.35 || depth >= 10 {
            append(end)
            return
        }
        let a = Self.middle(start, control1), b = Self.middle(control1, control2), c = Self.middle(control2, end)
        let d = Self.middle(a, b), e = Self.middle(b, c), middle = Self.middle(d, e)
        let firstBudget = budget / 2
        appendCubic(start, a, d, middle, depth: depth + 1, budget: firstBudget)
        appendCubic(middle, e, c, end, depth: depth + 1, budget: budget - firstBudget)
    }

    private mutating func append(_ point: CGPoint) {
        guard let last = samples.last else { samples = [Sample(point: point, distance: 0)]; return }
        let added = hypot(point.x - last.point.x, point.y - last.point.y)
        guard added > 0 else { return }
        samples.append(Sample(point: point, distance: last.distance + added))
    }

    private static func middle(_ first: CGPoint, _ second: CGPoint) -> CGPoint {
        CGPoint(x: (first.x + second.x) / 2, y: (first.y + second.y) / 2)
    }

    private static func distance(_ point: CGPoint, fromLine start: CGPoint, to end: CGPoint) -> CGFloat {
        let dx = end.x - start.x, dy = end.y - start.y
        let length = hypot(dx, dy)
        guard length > 0 else { return hypot(point.x - start.x, point.y - start.y) }
        return abs(dy * point.x - dx * point.y + end.x * start.y - end.y * start.x) / length
    }
}

/// Core Text's one-line coordinate system connected to a flattened path. The same mapping is used for drawing,
/// hit-testing characters and the on-canvas caret, so editing does not fall back to the invisible rectangular
/// NSTextView layout behind curved text.
struct TextPathLayout {
    let line: CTLine
    let metric: TextPathMetric
    let start: CGFloat
    let lineWidth: CGFloat
    let closed: Bool
    let stringLength: Int

    init?(attributed: NSAttributedString, path: LayerTextPath, alignment: TextAlignment, pathRect: CGRect) {
        let oneLine = NSMutableAttributedString(attributedString: attributed)
        oneLine.mutableString.replaceOccurrences(of: "\r", with: " ", range: NSRange(location: 0, length: oneLine.length))
        oneLine.mutableString.replaceOccurrences(of: "\n", with: " ", range: NSRange(location: 0, length: oneLine.length))
        line = CTLineCreateWithAttributedString(oneLine)
        lineWidth = CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil))
        metric = TextPathMetric(nodes: path.nodes(in: pathRect), closed: path.closed)
        guard metric.length > 0, lineWidth.isFinite else { return nil }
        let anchor = path.startOffset * metric.length
        switch alignment {
        case .left: start = anchor
        case .center: start = anchor - lineWidth / 2
        case .right: start = anchor - lineWidth
        }
        closed = path.closed
        stringLength = oneLine.length
    }

    func pathDistance(forStringIndex proposed: Int) -> CGFloat? {
        let index = min(stringLength, max(0, proposed))
        let travel = CTLineGetOffsetForStringIndex(line, index, nil)
        guard travel.isFinite, !closed || travel <= metric.length else { return nil }
        let distance = start + travel
        guard closed || (0...metric.length).contains(distance) else { return nil }
        return distance
    }

    func location(forStringIndex proposed: Int) -> (point: CGPoint, angle: CGFloat)? {
        guard let distance = pathDistance(forStringIndex: proposed) else { return nil }
        return metric.location(at: distance, wrapping: closed)
    }

    func stringIndex(nearest point: CGPoint) -> Int? {
        guard let nearest = metric.nearest(to: point) else { return nil }
        var travel = nearest.distanceAlongPath - start
        if closed {
            let visible = min(lineWidth, metric.length)
            travel.formTruncatingRemainder(dividingBy: metric.length)
            if travel < 0 { travel += metric.length }
            // The nearest point can sit in the empty remainder of a closed path. Pick the nearer end of the text.
            if travel > visible { travel = travel - visible < metric.length - travel ? visible : 0 }
        } else {
            // Alignment can put the beginning of a long line before the path. Clamp to the part of the Core Text
            // line that is actually visible, not merely to a path-length prefix of that line.
            let firstVisible = max(0, -start)
            let lastVisible = min(lineWidth, metric.length - start)
            guard firstVisible <= lastVisible else { return nil }
            travel = min(lastVisible, max(firstVisible, travel))
        }
        let index = CTLineGetStringIndexForPosition(line, CGPoint(x: travel, y: 0))
        return index == kCFNotFound ? nil : min(stringLength, max(0, index))
    }
}

extension EditorSession {
    func beginText(at point: CGPoint, newLayer: Bool = false) {
        guard canEditLayers, textDraft == nil, let document, point.x.isFinite, point.y.isFinite else { return }
        let visible = document.effectiveVisibleIDs
        let target = newLayer ? nil : document.layers.reversed().first {
            visible.contains($0.id) && $0.liveText != nil && $0.transform.contains(point)
        }
        if let target { selectLayer(target.id) }
        var style = target?.liveText?.style ?? textDefaults
        if target == nil {
            style.content = ""
            style.colorRuns = nil
            style.fontRuns = nil
            style.textPath = nil
            // New text starts in the foreground color, the same as every other tool that lays down color.
            if !isMaskSelected {
                style.red = foregroundColor.red; style.green = foregroundColor.green; style.blue = foregroundColor.blue
            }
            // A click makes point text: no box of its own, so what is typed decides how big the layer is. Dragging
            // a box out instead (beginText(in:)) sets boxSize, and so does resizing one by its handles.
            style.boxSize = nil
        }
        tool = .type
        // A click puts new text's first baseline on the pointer, starting at it, as Photoshop's does. A fixed line height leaves its
        // extra room above the letters, so the baseline sits the font's descent up from the bottom of the line.
        let descent = abs((Self.textAttributes(style)[.font] as? NSFont)?.descender ?? 0)
        let baseline = LayerTextStyle.padding + style.lineHeight - descent
        let start = style.resolvedOrientation == .vertical
            ? CGPoint(x: point.x - baseline, y: point.y - LayerTextStyle.padding)
            : CGPoint(x: point.x - LayerTextStyle.padding, y: point.y - baseline)
        let origin = target?.origin ?? start
        textDraft = TextDraft(documentID: document.id, layerID: target?.id, origin: origin, transform: target?.transform, style: style)
    }

    /// Starts editable text on the topmost visible Pen path near `point`. The path is copied into the new text layer,
    /// so deleting or reshaping its source later cannot silently change the text.
    @discardableResult
    func beginTextOnPath(at point: CGPoint, tolerance: CGFloat) -> Bool {
        guard canEditLayers, textDraft == nil, let document, point.x.isFinite, point.y.isFinite,
              tolerance.isFinite, tolerance > 0 else { return false }
        let visible = document.effectiveVisibleIDs
        for layer in document.layers.reversed() where visible.contains(layer.id) {
            guard let vector = layer.liveVectorPath, let asset = layer.asset else { continue }
            let unit = point.applying(layer.transform.unitToDocument.inverted())
            let coarseTolerance = tolerance / max(1, min(layer.transform.size.width, layer.transform.size.height))
            // Every saved Pen point and handle lies in the unit square. Reject distant layers before adaptively
            // flattening their curves; a document with many complex paths otherwise made one Type click very slow.
            guard (-coarseTolerance...1 + coarseTolerance).contains(unit.x),
                  (-coarseTolerance...1 + coarseTolerance).contains(unit.y) else { continue }
            let mapped = vector.style.nodes.map { node in
                VectorPathNode(anchor: node.anchor.applying(layer.transform.unitToDocument),
                               inHandle: node.inHandle.applying(layer.transform.unitToDocument),
                               outHandle: node.outHandle.applying(layer.transform.unitToDocument))
            }
            let documentMetric = TextPathMetric(nodes: mapped, closed: vector.style.closed)
            guard let nearest = documentMetric.nearest(to: point), nearest.distanceFromPath <= tolerance,
                  documentMetric.length > 0 else { continue }
            let size = CGSize(width: asset.image.width, height: asset.image.height)
            let copiedPath = LayerTextPath(nodes: vector.style.nodes, closed: vector.style.closed,
                                           canvasSize: size, startOffset: 0)
            let localMetric = TextPathMetric(nodes: copiedPath.nodes(in: CGRect(origin: .zero, size: size)),
                                             closed: vector.style.closed)
            let localPoint = CGPoint(x: unit.x * size.width, y: unit.y * size.height)
            guard let localNearest = localMetric.nearest(to: localPoint), localMetric.length > 0 else { continue }
            var style = textDefaults
            style.content = ""
            style.colorRuns = nil
            style.fontRuns = nil
            style.boxSize = nil
            style.orientation = nil
            style.textPath = LayerTextPath(nodes: vector.style.nodes, closed: vector.style.closed,
                canvasSize: size, startOffset: min(1, max(0, localNearest.distanceAlongPath / localMetric.length)))
            guard style.isValid, let textSize = style.textPathCanvasSize,
                  Self.resizedTextPathTransform(layer.transform, from: size, to: textSize).isValid else {
                brushError = "That path is too large for editable text at the current size."
                return false
            }
            if !isMaskSelected {
                style.red = foregroundColor.red; style.green = foregroundColor.green; style.blue = foregroundColor.blue
            }
            selectLayer(layer.id)
            tool = .type
            textDraft = TextDraft(documentID: document.id, layerID: nil, origin: layer.origin,
                                  transform: layer.transform, style: style)
            return true
        }
        return false
    }

    func editActiveText() {
        guard canEditLayers, textDraft == nil, let document, let layer = activeLayer, let text = layer.liveText else { return }
        tool = .type
        textDraft = TextDraft(documentID: document.id, layerID: layer.id, origin: layer.origin, transform: layer.transform, style: text.style)
    }

    @discardableResult
    func applyText(_ draft: TextDraft) -> Bool {
        guard document?.id == draft.documentID, draft.style.isValid else { return false }
        let pending = textDraft
        textDraft = nil
        guard canEditLayers else { textDraft = pending; return false }
        var succeeded = false
        defer { if !succeeded { textDraft = pending } }
        if draft.layerID == nil, draft.style.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            succeeded = true
            return true
        }
        do {
            let image = try Self.textImage(draft.style)
            let text = LayerText(style: draft.style, image: image)
            if let id = draft.layerID {
                guard let index = document?.layers.firstIndex(where: { $0.id == id }),
                      let layer = document?.layers[index], layer.liveText != nil, let asset = layer.asset else { return false }
                if layer.liveText?.style == draft.style && (draft.transform == nil || draft.transform == layer.transform) { succeeded = true; return true }
                let thumbnail = try PixelInvert.thumbnail(of: image)
                var transform = draft.transform ?? layer.transform
                // Keep the transformed upper-left corner and the user's scale, rotation and flips.
                let anchor = transform.point(.zero)
                if draft.style.textPath != nil {
                    transform = Self.resizedTextPathTransform(transform, from: CGSize(width: asset.image.width,
                        height: asset.image.height), to: CGSize(width: image.width, height: image.height))
                } else if draft.transform == nil || draft.style.boxSize == nil {
                    transform.size = CGSize(width: CGFloat(image.width) * transform.size.width / CGFloat(asset.image.width),
                                            height: CGFloat(image.height) * transform.size.height / CGFloat(asset.image.height))
                    let moved = transform.point(.zero)
                    transform.origin.x += anchor.x - moved.x
                    transform.origin.y += anchor.y - moved.y
                }
                guard transform.isValid else { throw ProjectError.tooLarge }
                beginEdit("Edit Text")
                if layer.mask?.placement == nil { document?.layers[index].mask?.placement = layer.maskTransform }
                document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
                document?.layers[index].text = text
                document?.layers[index].transform = transform
                endEdit()
            } else {
                var transform = draft.transform
                if let source = transform, let path = draft.style.textPath {
                    transform = Self.resizedTextPathTransform(source, from: path.canvasSize,
                        to: CGSize(width: image.width, height: image.height))
                }
                guard addPixelLayer(image, at: draft.origin, name: Self.layerName(for: draft.style.content),
                                    editName: "New Text Layer", dropsSelection: false, text: text,
                                    transform: transform) else { throw ExportError.render }
            }
            succeeded = true
            textDefaults = draft.style
            textDefaults.colorRuns = nil
            textDefaults.fontRuns = nil
            textDefaults.textPath = nil
            textDraft = nil
            canvasFocusRequest += 1
            return true
        } catch {
            brushError = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func finishText() -> Bool {
        guard let draft = textDraft else { return true }
        return applyText(draft)
    }

    func cancelText() { textDraft = nil; canvasFocusRequest += 1 }

    func beginText(in rect: CGRect) {
        guard canEditLayers, textDraft == nil, rect.width.isFinite, rect.height.isFinite else { return }
        var style = textDefaults
        style.boxSize = CGSize(width: max(16, rect.width.rounded()), height: max(16, rect.height.rounded()))
        guard style.boxIsValid else { brushError = "That text box exceeds the \(DocumentLimits.maxSide.formatted())-pixel or \(DocumentLimits.maxSurfaceMegapixels)-megapixel limit."; return }
        beginText(at: rect.origin, newLayer: true)
        // A dragged box is exactly where it was drawn.
        textDraft?.origin = rect.origin
        textDraft?.style.boxSize = style.boxSize
    }

    /// Paints a text layer's letters in `color`, keeping it editable text. Used by Fill with Foreground/Background;
    /// false when the layer isn't live text or its pixels couldn't be redrawn, so the caller fills as usual.
    @discardableResult
    func recolorText(_ id: UUID, to color: PaletteColor) -> Bool {
        guard canEditLayers, let index = document?.layers.firstIndex(where: { $0.id == id }),
              let layer = document?.layers[index], let text = layer.liveText, let asset = layer.asset else { return false }
        var style = text.style
        guard style.red != color.red || style.green != color.green || style.blue != color.blue || style.colorRuns != nil else { return true }
        style.setColor(color, in: NSRange(location: 0, length: 0))
        guard style.isValid, let image = try? Self.textImage(style), let thumbnail = try? PixelInvert.thumbnail(of: image) else { return false }
        finishOpacityEdit()
        beginEdit("Fill Text")
        document?.layers[index].asset = ImportedImage(image: image, thumbnail: thumbnail, name: asset.name)
        document?.layers[index].text = LayerText(style: style, image: image)
        endEdit()
        return true
    }

    var currentTextStyle: LayerTextStyle { textDraft?.style ?? activeLayer?.liveText?.style ?? textDefaults }

    nonisolated static func resizedTextPathTransform(_ transform: LayerTransform, from oldSize: CGSize,
                                                     to newSize: CGSize) -> LayerTransform {
        guard oldSize.width > 0, oldSize.height > 0 else { return transform }
        var result = transform
        let center = transform.center
        result.size = CGSize(width: newSize.width * transform.size.width / oldSize.width,
                             height: newSize.height * transform.size.height / oldSize.height)
        result.origin = CGPoint(x: center.x - result.size.width / 2, y: center.y - result.size.height / 2)
        return result
    }

    private func textPathTransformIsValid(for draft: TextDraft) -> Bool {
        guard let path = draft.style.textPath, let target = draft.style.textPathCanvasSize,
              let source = draft.transform else { return true }
        let current = draft.layerID.flatMap { id in
            document?.layers.first(where: { $0.id == id })?.asset.map {
                CGSize(width: $0.image.width, height: $0.image.height)
            }
        } ?? path.canvasSize
        return Self.resizedTextPathTransform(source, from: current, to: target).isValid
    }

    /// While the font menu is open, the text being edited shows the face under the pointer; `endFontPreview` puts it
    /// back. Only text already being edited: a selected text layer isn't opened for a preview.
    func previewFont(_ name: String) {
        guard var draft = textDraft else { return }
        let original = fontPreviewOriginal ?? draft.style
        fontPreviewOriginal = original
        var style = original
        style.setFont(name, in: draft.selection)
        guard style.isValid, style != draft.style else { return }
        draft.style = style
        textDraft = draft
    }
    /// The previewed face was chosen: keep the text as it shows, rather than putting it back and applying it again.
    func keepFontPreview() { fontPreviewOriginal = nil }
    func endFontPreview() {
        guard let original = fontPreviewOriginal else { return }
        fontPreviewOriginal = nil
        if var draft = textDraft, draft.style != original { draft.style = original; textDraft = draft }
    }

    func changeTextStyle(_ change: (inout LayerTextStyle) -> Void) {
        if textDraft == nil, activeLayer?.liveText != nil { editActiveText() }
        if var draft = textDraft {
            change(&draft.style)
            guard draft.style.isValid, textPathTransformIsValid(for: draft) else { return }
            textDraft = draft
        } else {
            var style = textDefaults
            change(&style)
            if style.isValid { textDefaults = style }
        }
    }

    /// A text layer's name: its first words on one line. Line breaks and runs of spaces become single spaces, so a
    /// paragraph never makes the row in the Layers panel taller than one line.
    static func layerName(for content: String) -> String {
        let flattened = content.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).joined(separator: " ")
        return flattened.isEmpty ? "Text" : String(flattened.prefix(40))
    }

    nonisolated static func textAttributes(_ style: LayerTextStyle) -> [NSAttributedString.Key: Any] {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = style.alignment == .left ? .left : style.alignment == .center ? .center : .right
        let font = NSFont(name: style.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
        // Leading is the line's whole height, so the lines close up (and eventually overlap) as it comes down,
        // exactly as Photoshop's does. Auto is 120% of the size.
        _ = font
        paragraph.minimumLineHeight = style.lineHeight
        paragraph.maximumLineHeight = style.lineHeight
        paragraph.lineBreakMode = .byWordWrapping
        var attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont(name: style.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize),
            .foregroundColor: NSColor(srgbRed: style.red, green: style.green, blue: style.blue, alpha: 1),
            .paragraphStyle: paragraph,
            .kern: style.tracking
        ]
        if style.resolvedOrientation == .vertical { attributes[.verticalGlyphForm] = 1 }
        return attributes
    }

    /// How big point text is: what it measures, plus its padding. A caret's worth of width so an empty line still
    /// has somewhere to type.
    static func textBoxSize(_ style: LayerTextStyle) -> CGSize {
        if let size = style.textPathCanvasSize { return size }
        if let boxSize = style.boxSize { return boxSize }
        let string = attributedText(style)
        let padding = LayerTextStyle.padding
        let measured: CGSize
        if style.resolvedOrientation == .vertical {
            let view = verticalTextView(string, frame: CGRect(x: 0, y: 0, width: 100_000, height: 100_000))
            if let container = view.textContainer, let layout = view.layoutManager {
                layout.ensureLayout(for: container)
                let used = layout.usedRect(for: container)
                // A vertical text view's layout coordinates are rotated relative to its frame.
                measured = CGSize(width: used.height, height: used.width)
            } else { measured = .zero }
        } else {
            measured = string.boundingRect(with: CGSize(width: 100_000, height: 100_000),
                                           options: [.usesLineFragmentOrigin, .usesFontLeading]).size
        }
        let line = ceil(style.lineHeight)
        if style.resolvedOrientation == .vertical {
            return CGSize(width: max(16, ceil(max(measured.width, line) + padding * 2)),
                          height: max(16, ceil(measured.height + padding * 2 + style.fontSize * 0.1)))
        }
        return CGSize(width: max(16, ceil(measured.width + padding * 2 + style.fontSize * 0.1)),
                      height: max(16, ceil(max(measured.height, line) + padding * 2)))
    }

    /// The text as it is drawn and measured, with each letter's own face and color.
    static func attributedText(_ style: LayerTextStyle) -> NSMutableAttributedString {
        let string = NSMutableAttributedString(string: style.content, attributes: textAttributes(style))
        for run in style.fontRuns ?? [] where Self.containsTextRun(run.location, run.length, in: string.length) {
            let font = NSFont(name: run.fontName, size: style.fontSize) ?? NSFont.systemFont(ofSize: style.fontSize)
            string.addAttribute(.font, value: font, range: NSRange(location: run.location, length: run.length))
        }
        for run in style.colorRuns ?? [] where Self.containsTextRun(run.location, run.length, in: string.length) {
            string.addAttribute(.foregroundColor, value: NSColor(srgbRed: run.red, green: run.green, blue: run.blue, alpha: 1),
                                range: NSRange(location: run.location, length: run.length))
        }
        return string
    }

    static func containsTextRun(_ location: Int, _ length: Int, in total: Int) -> Bool {
        length > 0 && location >= 0 && location <= total - length
    }

    static func textPathLayout(_ style: LayerTextStyle) -> TextPathLayout? {
        guard let path = style.textPath, let rect = style.textPathRect else { return nil }
        return TextPathLayout(attributed: attributedText(style), path: path,
                              alignment: style.alignment, pathRect: rect)
    }

    static func textImage(_ style: LayerTextStyle) throws -> CGImage {
        guard style.isValid else { throw ProjectError.invalid }
        let string = attributedText(style)
        let padding = LayerTextStyle.padding
        let size = textBoxSize(style)
        let width = ceil(size.width), height = ceil(size.height)
        guard width.isFinite, height.isFinite, width >= 1, height >= 1,
              width <= DocumentLimits.maxSideExtent, height <= DocumentLimits.maxSideExtent, width * height <= DocumentLimits.maxSurfaceExtent else { throw ProjectError.tooLarge }
        let context = try BrushRaster.context(width: Int(width), height: Int(height), mask: false)
        if let textPath = style.textPath {
            draw(string, on: textPath, alignment: style.alignment, in: context,
                 pathRect: style.textPathRect ?? CGRect(x: 0, y: 0, width: width, height: height))
            guard let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        if style.resolvedOrientation == .vertical {
            let root = NSView(frame: CGRect(x: 0, y: 0, width: width, height: height))
            let textFrame = root.bounds.insetBy(dx: padding, dy: padding)
            let view = verticalTextView(string, frame: textFrame)
            root.addSubview(view)
            NSGraphicsContext.saveGraphicsState()
            defer { NSGraphicsContext.restoreGraphicsState() }
            let graphics = NSGraphicsContext(cgContext: context, flipped: true)
            NSGraphicsContext.current = graphics
            root.displayIgnoringOpacity(root.bounds, in: graphics)
            guard let image = context.makeImage() else { throw ExportError.render }
            return image
        }
        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: true)
        let storage = NSTextStorage(attributedString: string)
        let layout = NSLayoutManager()
        let container = NSTextContainer(size: CGSize(width: max(1, width - 2 * padding), height: max(1, height - 2 * padding)))
        container.lineFragmentPadding = 0
        storage.addLayoutManager(layout)
        layout.addTextContainer(container)
        let glyphs = layout.glyphRange(for: container)
        layout.drawGlyphs(forGlyphRange: glyphs, at: CGPoint(x: padding, y: padding))
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }

    /// Core Text supplies shaped glyphs and advances; the path metric supplies a baseline point and tangent for the
    /// center of each glyph. Drawing glyphs individually keeps ligatures, font/color runs and kerning intact.
    private static func draw(_ attributed: NSAttributedString, on textPath: LayerTextPath,
                             alignment: TextAlignment, in context: CGContext, pathRect: CGRect) {
        guard attributed.length > 0 else { return }
        guard let layout = TextPathLayout(attributed: attributed, path: textPath,
                                          alignment: alignment, pathRect: pathRect) else { return }
        let line = layout.line, metric = layout.metric, start = layout.start
        context.saveGState()
        context.setShouldAntialias(true)
        context.setAllowsAntialiasing(true)
        context.textMatrix = .identity
        defer { context.restoreGState() }
        glyphRuns: for case let run as CTRun in CTLineGetGlyphRuns(line) as NSArray {
            let count = CTRunGetGlyphCount(run)
            guard count > 0 else { continue }
            var glyphs = Array(repeating: CGGlyph(), count: count)
            var positions = Array(repeating: CGPoint.zero, count: count)
            var advances = Array(repeating: CGSize.zero, count: count)
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(run, CFRange(location: 0, length: 0), &positions)
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            let attributes = CTRunGetAttributes(run) as NSDictionary
            guard let nativeFont = attributes[NSAttributedString.Key.font] as? NSFont else { continue }
            let font = nativeFont as CTFont
            if let color = attributes[NSAttributedString.Key.foregroundColor] as? NSColor {
                context.setFillColor(color.cgColor)
            }
            for index in 0..<count {
                let advance = max(0, abs(advances[index].width))
                let travel = positions[index].x + advance / 2
                // A closed path permits one complete circuit from the alignment anchor; extra text is clipped.
                if textPath.closed, travel > metric.length { break glyphRuns }
                guard let place = metric.location(at: start + travel, wrapping: textPath.closed) else { continue }
                context.saveGState()
                context.translateBy(x: place.point.x, y: place.point.y)
                context.rotate(by: place.angle)
                context.translateBy(x: -advance / 2, y: 0)
                // BrushRaster's user coordinates run downward; Core Text glyph outlines run upward.
                context.scaleBy(x: 1, y: -1)
                var glyph = glyphs[index]
                // Combining marks and scripts with vertical positioning carry a non-zero run offset. Dropping it
                // detached accents from their base glyphs once both were rotated onto the path.
                var origin = CGPoint(x: 0, y: positions[index].y)
                CTFontDrawGlyphs(font, &glyph, &origin, 1, context)
                context.restoreGState()
            }
        }
    }

    private static func verticalTextView(_ string: NSAttributedString, frame: CGRect) -> NSTextView {
        let view = NSTextView(frame: frame)
        view.drawsBackground = false
        view.isEditable = false
        view.isSelectable = false
        // Keep both dimensions finite. NSTextView otherwise gives its text container an effectively unlimited
        // cross-axis, so overflow columns participate in the committed raster even though the on-canvas editor
        // correctly clips them to the paragraph box.
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.textContainer?.heightTracksTextView = true
        view.setLayoutOrientation(.vertical)
        view.textStorage?.setAttributedString(string)
        return view
    }
}
