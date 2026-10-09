import SwiftUI
import AppKit
import ImageIO

/// The units New Canvas sizes can be typed in. Print units turn into pixels at the chosen DPI.
nonisolated enum NewCanvasUnit: String, CaseIterable, Sendable {
    case pixels = "px", inches = "in", centimeters = "cm", millimeters = "mm"

    /// The unit written out, for the summary line's pill.
    var name: String {
        switch self {
        case .pixels: "Pixels"
        case .inches: "Inches"
        case .centimeters: "Centimeters"
        case .millimeters: "Millimeters"
        }
    }
    /// The next unit, for the pill: px → in → cm → mm → px.
    var next: NewCanvasUnit { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    private var perInch: Double? {
        switch self {
        case .pixels: nil
        case .inches: 1
        case .centimeters: 2.54
        case .millimeters: 25.4
        }
    }
    /// Whole pixels for a typed size, or nil when it isn't a size a canvas can have.
    func pixels(_ text: String, resolution: Double) -> Int? {
        guard let value = Double(text.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: ",", with: ".")),
              value.isFinite, value > 0 else { return nil }
        let pixels = perInch.map { (value / $0 * resolution).rounded() } ?? value
        guard pixels == pixels.rounded(), (1...Double(DocumentLimits.maxSide)).contains(pixels) else { return nil }
        return Int(pixels)
    }
    /// A pixel size written in this unit: whole pixels, or print sizes to two decimals at most.
    func text(_ pixels: Int, resolution: Double) -> String {
        guard let perInch else { return String(pixels) }
        return (Double(pixels) / resolution * perInch).formatted(.number.precision(.fractionLength(0...2)).grouping(.never)
            .locale(Locale(identifier: "en_US_POSIX")))
    }
}

/// What a new canvas starts as: see-through, or a Background layer of white or black.
nonisolated enum NewCanvasBackground: String, CaseIterable, Sendable {
    case transparent, white, black
    var title: String {
        switch self {
        case .transparent: String(localized: "Transparent canvas")
        case .white: String(localized: "White canvas")
        case .black: String(localized: "Black canvas")
        }
    }
    var next: NewCanvasBackground { Self.allCases[(Self.allCases.firstIndex(of: self)! + 1) % Self.allCases.count] }
    var color: CGColor? {
        switch self {
        case .transparent: nil
        case .white: CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        case .black: CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1)
        }
    }
}

struct NewCanvasSheet: View {
    let session: EditorSession
    var onCreate: ((Int, Int, Double, CGColor?) -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    @State private var width = "1920"
    @State private var height = "1080"
    /// Always starting from the common case: remembered print settings turned the default 1920 × 1080 into inches,
    /// a canvas far too big to make.
    @State private var unit = NewCanvasUnit.pixels
    @State private var resolution = 72.0
    @State private var background = NewCanvasBackground.transparent
    @State private var suggestedClipboardSize = false
    @FocusState private var focusedField: Field?
    private enum Field { case width, height }
    private var pixelWidth: Int? { unit.pixels(width, resolution: resolution) }
    private var pixelHeight: Int? { unit.pixels(height, resolution: resolution) }
    private var valid: Bool { pixelWidth != nil && pixelHeight != nil }
    private var resolutionHelp: String {
        let size = unit != .pixels ? pixelWidth.flatMap { w in pixelHeight.map { h in String(localized: " · \(Int(resolution)) DPI: \(w) × \(h) pixels") } } : nil
        return String(localized: "Resolution: 72 for screens, 300 for print. Click to switch.") + (size ?? "")
    }
    /// Shows the sizes in another unit, the same canvas written differently.
    private func switchUnit(to new: NewCanvasUnit) {
        if let w = pixelWidth, let h = pixelHeight {
            width = new.text(w, resolution: resolution)
            height = new.text(h, resolution: resolution)
        }
        unit = new
    }
    /// Fills in a size given in pixels, written in the unit in use.
    private func setPixels(_ w: Int, _ h: Int) {
        width = unit.text(w, resolution: resolution)
        height = unit.text(h, resolution: resolution)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            VStack(spacing: 14) {
                HStack {
                    Text("New canvas").font(.title2.weight(.semibold))
                    Spacer()
                    // Preset sizes, tucked into a More button; the size in use is checked.
                    Menu {
                        Picker("Size", selection: preset) {
                            Text("Custom").tag(CanvasPreset?.none)
                            ForEach(CanvasPreset.groups.indices, id: \.self) { group in
                                Divider()
                                ForEach(CanvasPreset.groups[group]) { Text(L10n.string($0.title)).tag(CanvasPreset?.some($0)) }
                            }
                        }
                        .pickerStyle(.inline).labelsHidden()
                    } label: {
                        // Three dots drawn exactly (a rotated symbol keeps its sideways width), flush with the fields'
                        // right edge; the frame keeps it easy to click.
                        VStack(spacing: 2.5) { ForEach(0..<3, id: \.self) { _ in Circle().frame(width: 2.5, height: 2.5) } }
                            .foregroundStyle(.primary)
                            .frame(width: 28, height: 28, alignment: .trailing)
                            // Clickable a little past the dots on the right too, without moving them off the edge.
                            .padding(.trailing, 10)
                            .contentShape(Rectangle())
                            .padding(.trailing, -10)
                    }
                    .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                    .help("Preset sizes for screens and common formats")
                    .accessibilityLabel("Preset sizes")
                }
            }
            HStack(spacing: 16) {
                dimension("Width", text: $width, field: .width)
                Image(systemName: "multiply").foregroundStyle(.tertiary).padding(.top, 20)
                dimension("Height", text: $height, field: .height)
            }
            // The settings are pills, each changed the same way: click to step to the next choice.
            HStack(spacing: 4) {
                CyclePill(background.title, help: "Start see-through, or with a white or black Background layer. Click to switch.") {
                    background = background.next
                }
                .accessibilityIdentifier("canvasBackground")
                Text("·")
                CyclePill(unit.name, help: "Units: pixels, inches, centimeters or millimeters. Click to switch.") {
                    switchUnit(to: unit.next)
                }
                .accessibilityIdentifier("canvasUnit")
                Text("·")
                // In print units the pixels follow the DPI; in pixels, the DPI is just stored with the file. The pixel
                // size it makes is in the pill's hover text, out of the way until it's wanted.
                CyclePill("\(Int(resolution)) DPI", help: resolutionHelp) {
                    resolution = resolution == 300 ? 72 : 300
                }
                .accessibilityIdentifier("canvasResolution")
            }
            .font(.callout).foregroundStyle(.secondary)
            if !valid {
                Text(unit == .pixels ? String(localized: "Enter whole numbers from 1 to \(DocumentLimits.maxSide.formatted()) pixels.")
                                     : String(localized: "Enter a size up to \(DocumentLimits.maxSide.formatted()) pixels at this DPI."))
                    .font(.callout).foregroundStyle(.orange)
            }
            HStack(spacing: 10) {
                Button("Open project") { onOpen?() }.buttonStyle(.bordered)
                Button("Import image") { session.showsImporter = true }.buttonStyle(.bordered)
                Spacer()
                Button("Create canvas") {
                    guard let w = pixelWidth, let h = pixelHeight else { return }
                    if let onCreate { onCreate(w, h, resolution, background.color) }
                    else { session.createDocument(width: w, height: h, emptyLayer: true, resolution: resolution, background: background.color) }
                }
                .configuredNativeShortcut(.return).buttonStyle(.borderedProminent)
                .disabled(!valid).accessibilityIdentifier("createCanvas")
            }
        }
        .padding(28).frame(maxWidth: 500)
        .disabled(session.isImporting || session.showsBusy)
        .onAppear {
            if !suggestedClipboardSize {
                suggestedClipboardSize = true
                if session.skipsInitialClipboardCanvasSize {
                    session.skipsInitialClipboardCanvasSize = false
                } else if let size = Self.clipboardDimensions() {
                    setPixels(size.width, size.height)
                }
            }
            focusedField = .width
        }
    }
    /// The preset the fields match, or nil (Custom); choosing one fills them in, in the unit in use.
    private var preset: Binding<CanvasPreset?> {
        Binding(get: { CanvasPreset.all.first { $0.width == pixelWidth && $0.height == pixelHeight } },
                set: { if let chosen = $0 { setPixels(chosen.width, chosen.height) } })
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
            Text(L10n.string(title)).font(.callout.weight(.medium))
            HStack {
                TextField(L10n.string(title), text: text).textFieldStyle(.plain)
                    .focused($focusedField, equals: field)
                    .accessibilityIdentifier(title.lowercased() + "Input")
                Text(L10n.string(unit.rawValue)).foregroundStyle(.secondary)
            }
            .padding(12).background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 7))
        }
    }
}

/// A setting that steps through its few values when clicked, shown as plain text that gains a soft pill on hover.
private struct CyclePill: View {
    let title: String
    let help: String
    let action: () -> Void
    @State private var hovering = false
    init(_ title: String, help: String, action: @escaping () -> Void) { self.title = title; self.help = help; self.action = action }
    var body: some View {
        Button(action: action) {
            Text(L10n.string(title)).foregroundStyle(.secondary).monospacedDigit()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(.quaternary.opacity(hovering ? 1 : 0), in: Capsule())
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(L10n.string(help))
    }
}

/// New Canvas sizes: common screens and resolutions, in pixels, upright as the device is usually held.
struct CanvasPreset: Identifiable, Hashable {
    let title: String
    let width: Int
    let height: Int
    var id: String { title }
    /// Resolutions, Apple screens, then social formats; the menu divides them.
    static let groups: [[CanvasPreset]] = [
        [
            CanvasPreset(title: "4K", width: 3840, height: 2160),
            CanvasPreset(title: "1440p", width: 2560, height: 1440),
            CanvasPreset(title: "1080p", width: 1920, height: 1080),
        ],
        [
            CanvasPreset(title: "iPhone 18 Pro", width: 1206, height: 2622),
            CanvasPreset(title: "iPhone 18 Pro Max", width: 1320, height: 2868),
            CanvasPreset(title: "MacBook Pro 14\"", width: 3024, height: 1964),
            CanvasPreset(title: "MacBook Pro 16\"", width: 3456, height: 2234),
            CanvasPreset(title: "Studio Display", width: 5120, height: 2880),
        ],
        [
            CanvasPreset(title: "Instagram Square", width: 1080, height: 1080),
            CanvasPreset(title: "Instagram Portrait", width: 1080, height: 1350),
            CanvasPreset(title: "Instagram Story", width: 1080, height: 1920),
            CanvasPreset(title: "YouTube Thumb", width: 1080, height: 608),
        ],
    ]
    static let all = groups.flatMap { $0 }
}
