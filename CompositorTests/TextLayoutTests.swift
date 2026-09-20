import AppKit
import Testing
@testable import Compositor

@MainActor
struct TextLayoutTests {
    private func style(_ content: String, layout: LayerTextLayout = .point) -> LayerTextStyle {
        LayerTextStyle(content: content, fontPostScriptName: "Helvetica", fontSizePoints: 20,
            red: 0.1, green: 0.3, blue: 0.8, alpha: 1, alignment: .left,
            lineSpacingPoints: 0, trackingPoints: 0, layout: layout)
    }

    @Test func chineseEnglishAndEmojiRenderToTransparentImages() throws {
        let session = TextLayoutSession(style: style("中文 Hello 👩🏽‍💻"), resolution: 72)
        let result = try session.render()
        #expect(result.image.width > 40 && result.image.height > 10)
        let bitmap = NSBitmapImageRep(cgImage: result.image)
        var opaque = 0, clear = 0
        for y in 0..<bitmap.pixelsHigh {
            for x in 0..<bitmap.pixelsWide {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0 { opaque += 1 } else { clear += 1 }
            }
        }
        #expect(opaque > 0 && clear > 0)
    }

    @Test func boxTextWrapsAtItsFixedWidthAndGrowsDownward() {
        let point = TextLayoutSession(style: style("one two three four five six"), resolution: 72)
        let box = TextLayoutSession(style: style("one two three four five six", layout: .box(width: 80)), resolution: 72)
        #expect(box.naturalSize().width == 80)
        #expect(box.naturalSize().height > point.naturalSize().height)
    }

    @Test func spacingTrackingAlignmentAndDPIUseDocumentPixels() {
        let base = style("First line\nSecond line")
        let at72 = TextLayoutSession(style: base, resolution: 72)
        var spaced = base
        spaced.lineSpacingPoints = 12
        spaced.trackingPoints = 4
        spaced.alignment = .right
        let changed = TextLayoutSession(style: spaced, resolution: 72)
        let at300 = TextLayoutSession(style: base, resolution: 300)
        #expect(changed.naturalSize().height > at72.naturalSize().height)
        #expect(changed.naturalSize().width > at72.naturalSize().width)
        #expect(at300.naturalSize().height > at72.naturalSize().height * 3)
        #expect((changed.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment == .right)
    }

    @Test func targetSizeRedrawsAtRequestedRasterDimensions() throws {
        let session = TextLayoutSession(style: style("Sharp text"), resolution: 72)
        let result = try session.render(targetSize: CGSize(width: 420, height: 96))
        #expect(result.image.width == 420 && result.image.height == 96)
    }

    @Test func centeredAndRightAlignedPointTextStayAtNaturalWidth() {
        let content = "short\na much longer line"
        var leftStyle = style(content)
        let left = TextLayoutSession(style: leftStyle, resolution: 72).naturalSize()
        for alignment in [LayerTextAlignment.center, .right] {
            leftStyle.alignment = alignment
            let layout = TextLayoutSession(style: leftStyle, resolution: 72)
            let size = layout.naturalSize()
            #expect(size.width < 300)
            #expect(abs(size.width - left.width) <= 1)
            #expect((layout.textStorage.attribute(.paragraphStyle, at: 0, effectiveRange: nil) as? NSParagraphStyle)?.alignment
                    == alignment.textAlignment)
        }
    }

    @Test func emptyPointDraftExpandsPastEditorWidthWithoutWrapping() {
        let content = String(repeating: "W", count: 30)
        let singleLineHeight = TextLayoutSession(style: style("W"), resolution: 72).naturalSize().height
        for alignment in [LayerTextAlignment.left, .center, .right] {
            var empty = style("")
            empty.alignment = alignment
            let layout = TextLayoutSession(style: empty, resolution: 72)
            let editor = layout.makeTextView()
            editor.insertText(content, replacementRange: NSRange(location: 0, length: 0))
            let marker = NSAttributedString.Key("CompositorTests.IME-marked-range")
            layout.textStorage.addAttribute(marker, value: true, range: NSRange(location: 5, length: 4))
            layout.textDidChange()
            let size = layout.naturalSize()
            #expect(size.width > 160)
            #expect(abs(size.height - singleLineHeight) <= 1)
            #expect(layout.textStorage.attribute(marker, at: 6, effectiveRange: nil) as? Bool == true)
        }
    }
}
