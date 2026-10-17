import SwiftUI

struct PDFImportSheet: View {
    let name: String
    let pages: [PDFPageInfo]
    let finish: (PDFImportOptions?) -> Void
    @State private var selection = ""
    @State private var dpi = "300"

    private var options: PDFImportOptions { .init(pages: selection, dpi: Double(dpi) ?? .nan) }
    private var plan: Result<PDFImportPlan, Error> { Result { try PDFImportPlan.make(pages, options: options) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Import PDF").font(.title2.bold())
            Text(name).lineLimit(2)
            Text("\(pages.count) pages · Each selected page opens as an image in a separate tab.")
                .foregroundStyle(.secondary)
            HStack {
                Text("Pages").frame(width: 90, alignment: .leading)
                TextField("All pages, or 1, 3–5", text: $selection).accessibilityIdentifier("pdf.pages")
            }
            HStack {
                Text("Resolution").frame(width: 90, alignment: .leading)
                TextField("300", text: $dpi).frame(width: 85).accessibilityIdentifier("pdf.dpi")
                Text("DPI")
                Menu("Presets") {
                    ForEach([72, 150, 300, 600], id: \.self) { value in
                        Button("\(value) DPI") { dpi = String(value) }
                    }
                }.frame(width: 100)
            }
            Group {
                switch plan {
                case .success(let plan):
                    if let first = plan.pages.first {
                        Text("\(plan.pages.count) selected · First page: \(first.width) × \(first.height) pixels\nUncompressed pixels: \(ByteCountFormatter.string(fromByteCount: Int64(plan.totalPixels) * 4, countStyle: .memory))")
                            .foregroundStyle(.secondary)
                    }
                case .failure(let error): Text(error.localizedDescription).foregroundStyle(.red)
                }
            }.font(.callout).frame(minHeight: 45, alignment: .topLeading)
            Text("Text and vectors become pixels. The original PDF is not changed.")
                .font(.callout).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel") { finish(nil) }.keyboardShortcut(.cancelAction)
                Button("Import") { finish(options) }.keyboardShortcut(.defaultAction)
                    .disabled((try? plan.get()) == nil).accessibilityIdentifier("pdf.import")
            }
        }.padding(24).frame(width: 470).fixedSize(horizontal: false, vertical: true)
    }

    @MainActor static func choose(name: String, pages: [PDFPageInfo], over parent: NSWindow?) async -> PDFImportOptions? {
        await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Import PDF"
            sheet.contentViewController = NSHostingController(rootView: Self(name: name, pages: pages) { options in
                if let parent { parent.endSheet(sheet) }
                else { NSApp.stopModal() }
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            if let parent { parent.beginSheet(sheet) }
            else { sheet.center(); NSApp.runModal(for: sheet) }
        }
    }
}
