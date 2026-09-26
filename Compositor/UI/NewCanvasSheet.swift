import SwiftUI
import AppKit
import ImageIO

struct NewCanvasSheet: View {
    let session: EditorSession
    var onCreate: ((Int, Int) -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var width = "1920"
    @State private var height = "1080"
    @State private var presetCategory = CanvasPreset.Category.social
    @State private var selectedPresetID: String?
    @State private var showsPresets = false
    @State private var suggestedClipboardSize = false
    @FocusState private var focusedField: Field?
    private enum Field { case width, height }
    private var valid: Bool {
        CanvasDocument.validDimension(width) != nil && CanvasDocument.validDimension(height) != nil
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(alignment: .leading, spacing: 6) {
                Text("New canvas").font(.title2.weight(.semibold))
                Text("A blank space for your next composition.").foregroundStyle(.secondary)
            }
            HStack(spacing: 16) {
                dimension("Width", text: $width, field: .width)
                Image(systemName: "multiply").foregroundStyle(.tertiary).padding(.top, 20)
                dimension("Height", text: $height, field: .height)
            }
            Text(valid ? "Transparent canvas · sRGB" : "Enter whole numbers from 1 to \(DocumentLimits.maxSide.formatted()) pixels.")
                .font(.callout).foregroundStyle(valid ? Color.secondary : Color.orange)
            HStack(spacing: 10) {
                Button("Open project") { onOpen?() }.buttonStyle(.bordered)
                Button("Import image") { session.showsImporter = true }.buttonStyle(.bordered)
                Spacer()
                Button("Presets") { showsPresets = true }
                    .buttonStyle(.bordered).accessibilityIdentifier("openCanvasPresets")
                Button("Create canvas") {
                    createCanvas(width: width, height: height)
                }
                .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                .disabled(!valid).accessibilityIdentifier("createCanvas")
            }
        }
        .padding(28).frame(maxWidth: 560)
        .disabled(session.isImporting || session.showsBusy)
        .sheet(isPresented: $showsPresets) {
            presetsSheet
        }
        .onAppear {
            if !suggestedClipboardSize {
                suggestedClipboardSize = true
                if session.skipsInitialClipboardCanvasSize {
                    session.skipsInitialClipboardCanvasSize = false
                } else if let size = Self.clipboardDimensions() {
                    width = String(size.width)
                    height = String(size.height)
                }
            }
            focusedField = .width
        }
    }
    private var presetsSheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 5) {
                Text("Canvas presets").font(.title2.weight(.semibold))
                Text("Choose a common size, or close this window to enter custom dimensions.")
                    .font(.callout).foregroundStyle(.secondary)
            }

            Picker("Preset category", selection: $presetCategory) {
                ForEach(CanvasPreset.Category.allCases) { category in
                    Text(category.title).tag(category)
                }
            }
            .pickerStyle(.segmented)

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 10) {
                ForEach(CanvasPreset.presets(in: presetCategory)) { preset in
                    let selected = selectedPresetID == preset.id
                    Button {
                        selectedPresetID = preset.id
                    } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(preset.title).font(.callout.weight(.medium)).lineLimit(1)
                            Text("\(preset.width) × \(preset.height) px")
                                .font(.callout.monospacedDigit()).foregroundStyle(.secondary)
                            Text(preset.detail).font(.caption).foregroundStyle(.tertiary)
                        }
                        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
                        .padding(12)
                        .background(selected ? Color.accentColor.opacity(0.12) : Color.clear,
                                    in: RoundedRectangle(cornerRadius: 9))
                        .overlay {
                            RoundedRectangle(cornerRadius: 9)
                                .strokeBorder(selected ? Color.accentColor.opacity(0.7) : Color.secondary.opacity(0.2))
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("canvasPreset_\(preset.id)")
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }

            Spacer(minLength: 0)
            HStack {
                if let preset = CanvasPreset.all.first(where: { $0.id == selectedPresetID }) {
                    Text("\(preset.title) · \(preset.width) × \(preset.height) px")
                        .font(.callout).foregroundStyle(.secondary)
                } else {
                    Text("Select a size to continue.").font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { showsPresets = false }.buttonStyle(.bordered)
                Button("Create") {
                    guard let preset = CanvasPreset.all.first(where: { $0.id == selectedPresetID }) else { return }
                    createCanvas(width: String(preset.width), height: String(preset.height))
                    showsPresets = false
                }
                .buttonStyle(.borderedProminent)
                .accessibilityIdentifier("createCanvasFromPreset")
                .disabled(selectedPresetID == nil)
            }
        }
        .padding(24)
        .frame(width: 560, height: 440)
    }

    private func createCanvas(width: String, height: String) {
        guard let w = CanvasDocument.validDimension(width),
              let h = CanvasDocument.validDimension(height) else { return }
        if let onCreate { onCreate(w, h) }
        else { session.createDocument(width: w, height: h, emptyLayer: true) }
    }
    private struct CanvasPreset: Identifiable {
        enum Category: String, CaseIterable, Identifiable {
            case social, print, video
            var id: Self { self }
            var title: String {
                switch self {
                case .social: "Social"
                case .print: "Print"
                case .video: "Video"
                }
            }
        }

        let id: String
        let title: String
        let width: Int
        let height: Int
        let detail: String
        let category: Category

        static let all: [CanvasPreset] = [
            .init(id: "instagram-square", title: "Instagram post · Square", width: 1080, height: 1080, detail: "1:1", category: .social),
            .init(id: "instagram-portrait", title: "Instagram post · Portrait", width: 1080, height: 1350, detail: "4:5", category: .social),
            .init(id: "instagram-reel", title: "Instagram Reel / Story", width: 1080, height: 1920, detail: "9:16", category: .social),
            .init(id: "facebook-cover", title: "Facebook cover", width: 1640, height: 924, detail: "16:9", category: .social),
            .init(id: "a4", title: "A4", width: 2480, height: 3508, detail: "300 dpi", category: .print),
            .init(id: "a5", title: "A5", width: 1748, height: 2480, detail: "300 dpi", category: .print),
            .init(id: "letter", title: "US Letter", width: 2550, height: 3300, detail: "300 dpi", category: .print),
            .init(id: "full-hd", title: "Full HD", width: 1920, height: 1080, detail: "16:9", category: .video),
            .init(id: "4k", title: "4K UHD", width: 3840, height: 2160, detail: "16:9", category: .video),
            .init(id: "youtube-thumbnail", title: "YouTube thumbnail", width: 1280, height: 720, detail: "16:9", category: .video)
        ]

        static func presets(in category: Category) -> [CanvasPreset] {
            all.filter { $0.category == category }
        }
    }
    static func clipboardDimensions(_ pasteboard: NSPasteboard = .general) -> (width: Int, height: Int)? {
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type),
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  var width = properties[kCGImagePropertyPixelWidth] as? Int,
                  var height = properties[kCGImagePropertyPixelHeight] as? Int else { continue }
            if let orientation = properties[kCGImagePropertyOrientation] as? Int, (5...8).contains(orientation) {
                swap(&width, &height)
            }
            guard CanvasDocument.validDimension(String(width)) != nil,
                  CanvasDocument.validDimension(String(height)) != nil else { continue }
            return (width, height)
        }
        return nil
    }
    private func dimension(_ title: String, text: Binding<String>, field: Field) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.callout.weight(.medium))
            HStack {
                TextField(title, text: text).textFieldStyle(.plain)
                    .focused($focusedField, equals: field)
                    .accessibilityIdentifier(title.lowercased() + "Input")
                Text("px").foregroundStyle(.secondary)
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}
