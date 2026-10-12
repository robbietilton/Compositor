import AppKit
import Testing
@testable import Compositor

/// CMYK for print from RGB documents: the proof on the canvas and export in a profile's inks (`CMYK`).
struct CMYKTests {
    private func profile() throws -> CMYKProfile {
        try #require(CMYK.installed().first { $0.name == "Generic CMYK Profile" }, "macOS ships Generic CMYK")
    }

    /// A picture half saturated blue (beyond what ink can print) and half mid gray, as an export raster.
    private func raster() throws -> ExportRaster {
        let context = try BrushRaster.context(width: 40, height: 20, mask: false)
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 20, height: 20))
        context.setFillColor(CGColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        context.fill(CGRect(x: 20, y: 0, width: 20, height: 20))
        return ExportRaster(image: try #require(context.makeImage()), resolution: 300)
    }

    /// The file a CMYK export wrote: four ink channels, the profile embedded.
    private func expectCMYK(_ data: Data, _ type: String) throws {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let properties = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        #expect(properties[kCGImagePropertyColorModel] as? String == kCGImagePropertyColorModelCMYK as String, "\(type) in inks")
        #expect(properties[kCGImagePropertyProfileName] as? String != nil, "\(type) carries its profile")
        let image = try #require(CGImageSourceCreateImageAtIndex(source, 0, nil))
        #expect(image.colorSpace?.model == .cmyk)
    }

    @Test func jpegAndTIFFExportInInks() async throws {
        let profile = try profile(), raster = try raster()
        try expectCMYK(try await ImageExporter.shared.jpeg(raster, options: JPEGOptions(), cmyk: profile).data, "JPEG")
        try expectCMYK(try await ImageExporter.shared.tiffData(raster, cmyk: profile).data, "TIFF")
        // Without a profile, TIFF stays RGB with its transparency.
        let rgb = try await ImageExporter.shared.tiffData(raster)
        #expect(rgb.preview.colorSpace?.model == .rgb)
    }

    @Test func pdfExportsInInks() async throws {
        let data = try await ImageExporter.shared.pdfData(try raster(), background: nil, cmyk: try profile())
        let document = try #require(CGPDFDocument(CGDataProvider(data: data as CFData)!))
        #expect(document.numberOfPages == 1)
        // The page's image is a CMYK one: its color space names DeviceCMYK or an ICC profile with four components.
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.contains("/N 4") || text.contains("DeviceCMYK"), "CMYK image in the PDF")
    }

    /// The proof leaves a mid gray as it was, and dulls saturated blue (which ink can't reach); the gamut warning marks
    /// that blue gray.
    @Test func proofDullsWhatInkCantPrint() throws {
        let lookups = try #require(CMYK.proofLookups(try profile()))
        let n = CMYK.dimension
        func entry(_ data: Data, r: Int, g: Int, b: Int) -> [Float] {
            data.withUnsafeBytes { raw in
                let floats = raw.bindMemory(to: Float.self), i = ((b * n + g) * n + r) * 4
                return [floats[i], floats[i + 1], floats[i + 2]]
            }
        }
        let gray = entry(lookups.proof, r: 16, g: 16, b: 16)
        #expect(gray.allSatisfy { abs($0 - 0.5) < 0.04 }, "mid gray prints as it is: \(gray)")
        let blue = entry(lookups.proof, r: 0, g: 0, b: n - 1)
        #expect(blue[2] < 0.95 || blue[0] > 0.05, "saturated blue comes back duller: \(blue)")
        #expect(entry(lookups.warning, r: 0, g: 0, b: n - 1) == [0.5, 0.5, 0.5], "and the gamut warning marks it")
        #expect(entry(lookups.warning, r: 16, g: 16, b: 16) == gray, "mid gray isn't marked")
        // Without the proof, the warning marks the same blue on the document's own colors, which it leaves as they are.
        #expect(entry(lookups.marked, r: 0, g: 0, b: n - 1) == [0.5, 0.5, 0.5])
        #expect(entry(lookups.marked, r: n - 1, g: n - 1, b: n - 1) == [1, 1, 1], "white stays white")
    }
}
