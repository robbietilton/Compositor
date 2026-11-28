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
    static let lightSurroundWhite: CGFloat = 0.78
    static let lightRulerWhite: CGFloat = 0.90

    static let ink = gray(dark: 1, light: 0)
    static let editorBackground = gray(dark: 0.14, light: lightEditorWhite)
    static let rulerBackground = gray(dark: 0.2, light: lightRulerWhite)
}
