import AppKit
import Testing
@testable import Compositor

@MainActor
struct HTMLDesignImportTests {
    private func color(_ image: CGImage, x: Int, y: Int) throws -> NSColor {
        let bitmap = NSBitmapImageRep(cgImage: image)
        return try #require(bitmap.colorAt(x: min(max(0, x), image.width - 1), y: min(max(0, y), image.height - 1))?.usingColorSpace(.sRGB))
    }

    private func hasVisiblePixels(_ image: CGImage, below yMinimum: Int = 0) -> Bool {
        let bitmap = NSBitmapImageRep(cgImage: image)
        let stepX = max(1, image.width / 64), stepY = max(1, image.height / 64)
        for y in stride(from: max(0, yMinimum), to: image.height, by: stepY) {
            for x in stride(from: 0, to: image.width, by: stepX) {
                if (bitmap.colorAt(x: x, y: y)?.alphaComponent ?? 0) > 0.02 { return true }
            }
        }
        return false
    }

    @Test func simpleSolidHTMLBecomesEditableShapeAndTextLayers() async throws {
        let result = try await HTMLDesignImporter.importDesign(
            html: #"<div id="card">Hello Compositor</div>"#,
            css: """
            #card {
              position: absolute;
              left: 20px;
              top: 30px;
              width: 220px;
              height: 90px;
              background: rgb(20, 80, 160);
              color: rgb(255, 255, 255);
              border-radius: 12px;
              font: 600 24px/30px Helvetica, sans-serif;
            }
            """,
            width: 320,
            height: 180,
            name: "Card"
        )

        #expect(result.source.name == "Card")
        #expect(result.snapshot.manifest.width == 320)
        #expect(result.snapshot.manifest.height == 180)
        #expect(result.snapshot.manifest.layers.contains { $0.shape != nil && $0.name == "card" })
        #expect(result.snapshot.manifest.layers.contains { $0.text?.content == "Hello Compositor" })
        #expect(!result.warnings.contains { $0.contains("Flattened") }, "Warnings: \(result.warnings)")
        #expect(result.snapshot.images.count == result.snapshot.manifest.layers.count)
        let card = try #require(result.snapshot.manifest.layers.first { $0.shape != nil && $0.name == "card" })
        let cardImage = try #require(result.snapshot.images[card.id]?.image)
        let cardColor = try color(cardImage, x: cardImage.width / 2, y: cardImage.height / 2)
        #expect(cardColor.blueComponent > 0.5 && cardColor.redComponent < 0.2 && cardColor.alphaComponent > 0.99)
        let text = try #require(result.snapshot.manifest.layers.first { $0.text?.content == "Hello Compositor" })
        #expect(hasVisiblePixels(try #require(result.snapshot.images[text.id]?.image)))
    }

    @Test func gradientImageAndBRTextImportAsHybridEditableLayers() async throws {
        let result = try await HTMLDesignImporter.importDesign(
            html: #"""
            <div id="gradient-card" class="card">
              <img src="data:image/svg+xml;base64,PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSIxMCIgaGVpZ2h0PSIxMCI+PHJlY3Qgd2lkdGg9IjEwIiBoZWlnaHQ9IjEwIiBmaWxsPSIjZmYwMDAwIi8+PC9zdmc+" alt="Photo">
              <h1>A real<br>card</h1>
            </div>
            """#,
            css: """
            .card {
              position: absolute; left: 20px; top: 20px; width: 200px; height: 120px;
              background: linear-gradient(135deg, #ff0066, #0044ff);
              border-radius: 20px; overflow: hidden;
            }
            img { position: absolute; left: 12px; top: 12px; width: 64px; height: 96px; object-fit: cover; }
            h1 {
              position: absolute; left: 88px; top: 18px; width: 100px; margin: 0;
              color: white;
              font: 700 26px/30px Helvetica, sans-serif;
            }
            """,
            width: 240,
            height: 160,
            name: "Gradient"
        )

        #expect(result.snapshot.manifest.layers.count >= 4) // canvas, gradient, photo, text
        #expect(result.snapshot.manifest.layers.filter { $0.shape == nil && $0.text == nil }.count >= 2)
        #expect(result.snapshot.manifest.layers.contains { $0.text?.content == "A real\ncard" })
        #expect(!result.warnings.contains { $0.contains("Flattened") }, "Warnings: \(result.warnings)")
        let gradient = try #require(result.snapshot.manifest.layers.first { $0.name == "gradient-card" })
        let gradientImage = try #require(result.snapshot.images[gradient.id]?.image)
        let left = try color(gradientImage, x: gradientImage.width / 4, y: gradientImage.height / 2)
        let right = try color(gradientImage, x: gradientImage.width * 3 / 4, y: gradientImage.height / 2)
        let corner = try color(gradientImage, x: 0, y: 0)
        #expect(left.alphaComponent > 0.9 && right.alphaComponent > 0.9)
        #expect(corner.alphaComponent < 0.05)
        #expect(abs(left.redComponent - right.redComponent) + abs(left.blueComponent - right.blueComponent) > 0.15)
        let photo = try #require(result.snapshot.manifest.layers.first { $0.name == "Photo" })
        let photoImage = try #require(result.snapshot.images[photo.id]?.image)
        let photoColor = try color(photoImage, x: photoImage.width / 2, y: photoImage.height / 2)
        #expect(photoColor.redComponent > 0.8 && photoColor.alphaComponent > 0.9, "photoColor=\(photoColor)")
        let text = try #require(result.snapshot.manifest.layers.first { $0.text?.content == "A real\ncard" })
        let textImage = try #require(result.snapshot.images[text.id]?.image)
        #expect(hasVisiblePixels(textImage))
        #expect(hasVisiblePixels(textImage, below: textImage.height / 2))
    }

    @Test func transparentDataURLImageKeepsTransparentCorners() async throws {
        let svg = "PHN2ZyB4bWxucz0iaHR0cDovL3d3dy53My5vcmcvMjAwMC9zdmciIHdpZHRoPSI0MCIgaGVpZ2h0PSI0MCI+PGNpcmNsZSBjeD0iMjAiIGN5PSIyMCIgcj0iMTIiIGZpbGw9InJlZCIvPjwvc3ZnPg=="
        let result = try await HTMLDesignImporter.importDesign(
            html: "<img id=alpha src=\"data:image/svg+xml;base64,\(svg)\">",
            css: "html, body { margin: 0; } #alpha { width: 40px; height: 40px; }",
            width: 40, height: 40, name: "Alpha SVG"
        )
        #expect(!result.warnings.contains { $0.contains("Flattened") }, "Warnings: \(result.warnings)")
        let layer = try #require(result.snapshot.manifest.layers.first { $0.name == "alpha" })
        let image = try #require(result.snapshot.images[layer.id]?.image)
        let corner = try color(image, x: 0, y: 0)
        let center = try color(image, x: image.width / 2, y: image.height / 2)
        #expect(corner.alphaComponent < 0.05)
        #expect(center.alphaComponent > 0.95 && center.redComponent > 0.9
            && center.redComponent - center.greenComponent > 0.7, "center=\(center)")
    }

    @Test func unsupportedCompositingFlattensWithAnExplicitWarning() async throws {
        let result = try await HTMLDesignImporter.importDesign(
            html: #"<div class="glow">Shadow</div>"#,
            css: ".glow { width: 180px; height: 100px; background: blue; box-shadow: 0 20px 50px black; color: white; }",
            width: 240, height: 160, name: "Shadow"
        )
        #expect(result.snapshot.manifest.layers.count == 1)
        #expect(result.warnings.contains { $0.contains("Flattened") && $0.contains("shadows") })
        let raster = try #require(result.snapshot.images[result.snapshot.manifest.layers[0].id]?.image)
        let fill = try color(raster, x: 150, y: 80)
        #expect(fill.blueComponent > 0.7 && fill.alphaComponent > 0.99)
    }

    @Test func unsafeDimensionsAndOversizedSourceAreRejectedBeforeRendering() async {
        await #expect(throws: HTMLDesignImportError.self) {
            _ = try await HTMLDesignImporter.importDesign(html: "", css: "", width: 0, height: 100, name: "Invalid")
        }
        let oversized = String(repeating: "x", count: 4 * 1_024 * 1_024 + 1)
        await #expect(throws: HTMLDesignImportError.self) {
            _ = try await HTMLDesignImporter.importDesign(html: oversized, css: "", width: 100, height: 100, name: "Large")
        }
    }

    @Test func cancelledImportDoesNotStartWebRendering() async {
        let task = Task { @MainActor in
            try await HTMLDesignImporter.importDesign(
                html: "<div>Cancelled</div>", css: "div { color: red; }",
                width: 100, height: 100, name: "Cancelled"
            )
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
    }

    @Test func authorControlledLayerNamesAreBoundedForValidProjects() async throws {
        let identifier = String(repeating: "layer", count: 4_000)
        let result = try await HTMLDesignImporter.importDesign(
            html: #"<div id="\#(identifier)" style="width: 20px; height: 20px; background: red"></div>"#,
            css: "html, body { margin: 0; }",
            width: 40, height: 40, name: "Long identifier"
        )

        let layer = try #require(result.snapshot.manifest.layers.first { $0.shape != nil && $0.name != "Canvas background" })
        #expect(layer.name.count == 200)
        #expect(layer.name.utf8.count <= 16_384)
    }

    @Test func textBeyondEditableProjectLimitFlattensExplicitly() async throws {
        let text = String(repeating: "a", count: 100_001)
        let result = try await HTMLDesignImporter.importDesign(
            html: "<div>\(text)</div>",
            css: "html, body { margin: 0; } div { position: absolute; font: 1px Helvetica; white-space: nowrap; }",
            width: 32, height: 32, name: "Long text"
        )

        #expect(result.snapshot.manifest.layers.count == 1)
        #expect(result.warnings.contains { $0.contains("Flattened") && $0.contains("text content") })
        #expect(result.snapshot.manifest.layers[0].text == nil)
    }
}
