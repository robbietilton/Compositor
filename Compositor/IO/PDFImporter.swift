import Foundation
import CoreGraphics

nonisolated enum PDFImportError: Error, LocalizedError {
    case unreadable, locked, invalidPages, invalidResolution, tooLarge
    var errorDescription: String? {
        switch self {
        case .unreadable: "The PDF could not be read. It may be damaged or unavailable."
        case .locked: "This PDF is password-protected. Save an unlocked copy before importing it."
        case .invalidPages: "Enter page numbers or ranges within this PDF, for example 1, 3–5. Leave blank for all pages."
        case .invalidResolution: "Resolution must be between 1 and 2400 DPI."
        case .tooLarge: "The PDF or selected pages exceed the image or memory limit. Use a smaller PDF, fewer pages, or a lower resolution."
        }
    }
}
nonisolated struct PDFImportOptions: Sendable {
    var pages: String = ""
    var dpi: Double = 300
}
nonisolated enum PDFPageSelection {
    static func parse(_ text: String, count: Int) throws -> [Int] {
        guard count > 0 else { throw PDFImportError.unreadable }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "–", with: "-").replacingOccurrences(of: "—", with: "-")
        if text.isEmpty { return Array(1...count) }
        var result = Set<Int>()
        for part in text.split(separator: ",", omittingEmptySubsequences: false) {
            let ends = part.split(separator: "-", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
            guard (1...2).contains(ends.count), let first = Int(ends[0]), (1...count).contains(first) else {
                throw PDFImportError.invalidPages
            }
            let last = ends.count == 2 ? Int(ends[1]) : first
            guard let last, (first...count).contains(last) else { throw PDFImportError.invalidPages }
            result.formUnion(first...last)
        }
        return result.sorted()
    }
}
nonisolated struct PDFPageInfo: Sendable {
    let number: Int
    let size: CGSize
}
nonisolated struct PDFPagePlan: Sendable {
    let number: Int
    let width: Int
    let height: Int
}
nonisolated struct PDFImportPlan: Sendable {
    let pages: [PDFPagePlan]
    var totalPixels: Int { pages.reduce(0) { $0 + $1.width * $1.height } }

    static func make(_ info: [PDFPageInfo], options: PDFImportOptions,
                     pixelBudget: Int = DocumentLimits.documentPixelBudget) throws -> Self {
        guard options.dpi.isFinite, (1...2400).contains(options.dpi) else { throw PDFImportError.invalidResolution }
        let numbers = try PDFPageSelection.parse(options.pages, count: info.count)
        var pages: [PDFPagePlan] = []
        var remaining = pixelBudget
        for number in numbers {
            let size = info[number - 1].size
            let w = ceil(size.width * options.dpi / 72), h = ceil(size.height * options.dpi / 72)
            guard w.isFinite, h.isFinite, w >= 1, h >= 1,
                  w <= Double(DocumentLimits.maxSide), h <= Double(DocumentLimits.maxSide),
                  w * h <= Double(DocumentLimits.maxSurfacePixels), w * h <= Double(remaining) else {
                throw PDFImportError.tooLarge
            }
            let page = PDFPagePlan(number: number, width: Int(w), height: Int(h))
            remaining -= page.width * page.height
            pages.append(page)
        }
        return Self(pages: pages)
    }
}
actor PDFImporter {
    static let shared = PDFImporter()

    func open(_ url: URL) throws -> PDFImportSource { try PDFImportSource(url) }

    func inspect(_ url: URL) async throws -> [PDFPageInfo] { try await open(url).inspect() }

    func plan(_ url: URL, options: PDFImportOptions, pixelBudget: Int = DocumentLimits.documentPixelBudget) async throws -> PDFImportPlan {
        try await open(url).plan(options: options, pixelBudget: pixelBudget)
    }

    func render(_ url: URL, page: Int, dpi: Double) async throws -> ImportedImage {
        try await open(url).render(page: page, dpi: dpi)
    }
}

/// One immutable snapshot for the dialog, budget check and every selected page.
/// PDF objects stay actor-isolated; an external save cannot change an import halfway through.
actor PDFImportSource {
    private static let maximumSourceBytes = 256 * 1024 * 1024
    private let document: CGPDFDocument
    private let info: [PDFPageInfo]
    private let name: String

    init(_ url: URL) throws {
        let data = try Self.readSnapshot(url)
        guard let provider = CGDataProvider(data: data as CFData),
              let document = CGPDFDocument(provider), document.numberOfPages > 0 else {
            throw PDFImportError.unreadable
        }
        guard !document.isEncrypted || document.isUnlocked else { throw PDFImportError.locked }
        self.document = document
        name = url.deletingPathExtension().lastPathComponent
        info = try (1...document.numberOfPages).map { number in
            guard let page = document.page(at: number) else { throw PDFImportError.unreadable }
            let box = page.getBoxRect(.cropBox)
            guard box.width.isFinite, box.height.isFinite, box.width > 0, box.height > 0 else {
                throw PDFImportError.unreadable
            }
            let sideways = abs(page.rotationAngle % 180) == 90
            return PDFPageInfo(number: number, size: sideways ? CGSize(width: box.height, height: box.width) : box.size)
        }
    }

    private nonisolated static func readSnapshot(_ url: URL) throws -> Data {
        guard url.isFileURL, let handle = try? FileHandle(forReadingFrom: url) else { throw PDFImportError.unreadable }
        defer { try? handle.close() }
        do {
            try Task.checkCancellation()
            let length = try handle.seekToEnd()
            guard length <= maximumSourceBytes else { throw PDFImportError.tooLarge }
            try handle.seek(toOffset: 0)
            var data = Data()
            data.reserveCapacity(Int(length))
            while true {
                try Task.checkCancellation()
                // Read at most one byte beyond the budget, even if the source grows after stat.
                let count = min(1024 * 1024, maximumSourceBytes - data.count + 1)
                guard let chunk = try handle.read(upToCount: count), !chunk.isEmpty else { break }
                guard chunk.count <= maximumSourceBytes - data.count else { throw PDFImportError.tooLarge }
                data.append(chunk)
            }
            return data
        } catch is CancellationError {
            throw CancellationError()
        } catch let error as PDFImportError {
            throw error
        } catch {
            throw PDFImportError.unreadable
        }
    }

    func inspect() -> [PDFPageInfo] { info }

    func plan(options: PDFImportOptions, pixelBudget: Int = DocumentLimits.documentPixelBudget) throws -> PDFImportPlan {
        try Task.checkCancellation()
        return try PDFImportPlan.make(info, options: options, pixelBudget: pixelBudget)
    }

    func render(page number: Int, dpi: Double) throws -> ImportedImage {
        try Task.checkCancellation()
        return try autoreleasepool {
            let plan = try plan(options: .init(pages: String(number), dpi: dpi))
            let size = plan.pages[0]
            guard let page = document.page(at: number),
                  let context = CGContext(data: nil, width: size.width, height: size.height, bitsPerComponent: 8,
                      bytesPerRow: size.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else {
                throw PDFImportError.unreadable
            }
            let rect = CGRect(x: 0, y: 0, width: size.width, height: size.height)
            context.setFillColor(CGColor(gray: 1, alpha: 1))
            context.fill(rect)
            // CGPDFPage's drawing transform handles crop origins and page rotation.
            context.concatenate(page.getDrawingTransform(.cropBox, rect: rect, rotate: 0, preserveAspectRatio: true))
            context.drawPDFPage(page)
            try Task.checkCancellation()
            guard let image = context.makeImage() else { throw PDFImportError.unreadable }
            return ImportedImage(image: image, thumbnail: try PixelAdjust.thumbnail(of: image),
                                 name: "\(name) — Page \(number)")
        }
    }
}
