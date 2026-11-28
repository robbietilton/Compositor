import AppKit
import SwiftUI

enum CompositorAppearance: String, CaseIterable {
    case auto = "Auto", dark = "Dark", light = "Light"

    static let defaultsKey = "compositorAppearance"
    static var saved: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .dark
    }

    func apply() {
        switch self {
        case .auto: NSApp.appearance = nil
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
        PanelTitleBar.refreshAppearance()
    }

    static func isLight(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .aqua
    }

    /// Chrome that needs a custom fill keeps its original gray in Dark.
    static func gray(dark: CGFloat, light: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let value = isLight(appearance) ? light : dark
            return NSColor(srgbRed: value, green: value, blue: value, alpha: 1)
        })
    }

    static let lightEditorWhite: CGFloat = 0.94
    static let lightSurroundWhite: CGFloat = 0.86
    static let lightRulerWhite: CGFloat = 0.90
    static let darkCheckerboard: (base: CGFloat, alternate: CGFloat) = (0.30, 0.35)
    static let lightCheckerboard: (base: CGFloat, alternate: CGFloat) = (0.85, 0.92)

    static let ink = gray(dark: 1, light: 0)
    static let editorBackground = gray(dark: 0.14, light: lightEditorWhite)
    static let rulerBackground = gray(dark: 0.2, light: lightRulerWhite)
}

/// A segmented choice, its label hidden unless asked for.
struct CompositorSegmentedPicker<Value: Hashable, Option: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let showsLabel: Bool
    @ViewBuilder let option: (Value) -> Option

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [Value], showsLabel: Bool = false,
         @ViewBuilder option: @escaping (Value) -> Option) {
        self.title = title
        _selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.option = option
    }

    var body: some View {
        if showsLabel { picker } else { picker.labelsHidden() }
    }

    private var picker: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option($0).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
