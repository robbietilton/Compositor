import Foundation
import SwiftUI

nonisolated enum L10n {
    static var currentLocale: Locale {
        switch UserDefaults.standard.string(forKey: "app.language.v1") {
        case AppLanguage.english.rawValue: return Locale(identifier: "en")
        case AppLanguage.russian.rawValue: return Locale(identifier: "ru")
        default:
            return Locale.current.languageCode?.lowercased() == "ru"
                ? Locale(identifier: "ru") : Locale(identifier: "en")
        }
    }

    static func key(_ value: String) -> LocalizedStringKey {
        LocalizedStringKey(value)
    }

    static func text(_ key: String, locale: Locale = L10n.currentLocale) -> String {
        let bundle = localizedBundle(for: locale)
        return bundle.localizedString(forKey: key, value: key, table: "Localizable")
    }

    static func numbered(_ key: String, number: Int, locale: Locale = L10n.currentLocale) -> String {
        String(format: text("layer.numbered", locale: locale), text(key, locale: locale), number)
    }

    private static func localizedBundle(for locale: Locale) -> Bundle {
        guard let languageCode = locale.languageCode,
              let path = Bundle.main.path(forResource: languageCode, ofType: "lproj"),
              let bundle = Bundle(path: path) else {
            return Bundle.main
        }
        return bundle
    }

    @MainActor static func statusHint(for session: EditorSession, locale: Locale) -> String {
        switch session.tool {
        case .marquee: return text(session.marqueeKind == .ellipse ? "status.marquee.ellipse" : "status.marquee.rectangle", locale: locale)
        case .wand: return text(session.wandMode == .object ? "status.wand.object" : "status.wand.wand", locale: locale)
        case .lasso: return text(session.lassoKind == .freehand ? "status.lasso.freehand" : "status.lasso.polygonal", locale: locale)
        case .brush: return text(session.brushMode == .erase ? "status.brush.erase" : "status.brush.paint", locale: locale)
        case .blur:
            return text(session.blurMode == .blur ? "status.blur.blur" : session.blurMode == .smudge ? "status.blur.smudge" : "status.blur.liquify", locale: locale)
        case .cloneStamp: return text("status.cloneStamp", locale: locale)
        case .spotHealing: return text("status.spotHealing", locale: locale)
        case .type: return text("status.type", locale: locale)
        case .eyedropper: return text("Eyedropper", locale: locale)
        case .shape:
            switch session.shapeKind {
            case .line: return text("status.shape.line", locale: locale)
            case .rectangle: return text("status.shape.rectangle", locale: locale)
            case .ellipse: return text("status.shape.ellipse", locale: locale)
            }
        case .gradient: return text("status.gradient", locale: locale)
        case .crop: return text("status.crop", locale: locale)
        case .move: return text("status.move", locale: locale)
        case .hand: return text("status.hand", locale: locale)
        case .idle: return text("status.idle", locale: locale)
        case .zoom: return text("status.zoom", locale: locale)
        }
    }
}

extension FilterKind {
    var localizedName: String {
        localizedName(locale: L10n.currentLocale)
    }

    func localizedName(locale: Locale) -> String {
        L10n.text("filter.\(self.localizationKey)", locale: locale)
    }

    private var localizationKey: String {
        switch self {
        case .gaussianBlur: return "gaussianBlur"
        case .motionBlur: return "motionBlur"
        case .addNoise: return "addNoise"
        case .lensCorrection: return "lensCorrection"
        case .removeBackground: return "removeBackground"
        case .contentAwareFill: return "contentAwareFill"
        case .curves: return "curves"
        case .exposure: return "exposure"
        case .gradientMap: return "gradientMap"
        case .grain: return "grain"
        }
    }
}

extension AdjustmentKind {
    var localizedName: String {
        localizedName(locale: L10n.currentLocale)
    }

    func localizedName(locale: Locale) -> String {
        let key: String
        switch self {
        case .hsv: key = "hueSaturation"
        case .levels: key = "levels"
        case .curves: key = "curves"
        case .exposure: key = "exposure"
        case .gradientMap: key = "gradientMap"
        case .grain: key = "grain"
        }
        return L10n.text("adjustment.\(key)", locale: locale)
    }
}

extension LayerBlendMode {
    var localizedName: String {
        localizedName(locale: L10n.currentLocale)
    }

    func localizedName(locale: Locale) -> String {
        let key: String
        switch self {
        case .normal: key = "normal"
        case .multiply: key = "multiply"
        case .screen: key = "screen"
        case .overlay: key = "overlay"
        case .softLight: key = "softLight"
        case .darken: key = "darkening"
        case .lighten: key = "lightening"
        case .difference: key = "difference"
        case .colorDodge: key = "colorDodge"
        case .colorBurn: key = "colorBurn"
        case .hue: key = "hue"
        case .saturation: key = "saturation"
        case .color: key = "color"
        case .luminosity: key = "luminosity"
        }
        return L10n.text("blend.\(key)", locale: locale)
    }
}

extension LayerEffectKind {
    var localizedName: String {
        localizedName(locale: L10n.currentLocale)
    }

    func localizedName(locale: Locale) -> String {
        switch self {
        case .stroke: return L10n.text("Stroke", locale: locale)
        case .shadow: return L10n.text("Drop Shadow", locale: locale)
        case .colorOverlay: return L10n.text("Color Overlay", locale: locale)
        case .innerShadow: return L10n.text("Inner Shadow", locale: locale)
        case .outerGlow: return L10n.text("Outer Glow", locale: locale)
        }
    }
}

extension NavigationTool {
    func localizedLabel(locale: Locale) -> String {
        let key: String
        switch self {
        case .type: key = "toolLabel.type"
        case .eyedropper: key = "toolLabel.eyedropper"
        case .marquee: key = "toolLabel.marquee"
        case .lasso: key = "toolLabel.lasso"
        case .wand: key = "toolLabel.wand"
        case .brush: key = "toolLabel.brush"
        case .spotHealing: key = "toolLabel.spotHealing"
        case .cloneStamp: key = "toolLabel.cloneStamp"
        case .blur: key = "toolLabel.blur"
        case .gradient: key = "toolLabel.gradient"
        case .shape: key = "toolLabel.shape"
        case .crop: key = "toolLabel.crop"
        case .move: key = "toolLabel.move"
        case .hand: key = "toolLabel.hand"
        case .zoom: key = "toolLabel.zoom"
        case .idle: key = "toolLabel.idle"
        }
        return L10n.text(key, locale: locale)
    }
}

extension ColorPickerTarget {
    var localizedTitle: String {
        let picker = L10n.text("Color Picker")
        switch self {
        case .text: return picker + " (" + L10n.text("Text color") + ")"
        case .effect(let kind): return picker + " (" + kind.localizedName + " " + L10n.text("Color").lowercased() + ")"
        case .palette(let background): return picker + " (" + L10n.text(background ? "Background color" : "Foreground color") + ")"
        case .gradientMap(let highlights): return picker + " (" + L10n.text(highlights ? "Gradient Map highlights" : "Gradient Map shadows") + ")"
        }
    }
}

extension ShortcutDefinition {
    var localizedTitle: String { localizedTitle(locale: L10n.currentLocale) }

    func localizedTitle(locale: Locale) -> String {
        if title.hasSuffix(" by 10") {
            let base = String(title.dropLast(" by 10".count))
            return String(format: L10n.text("shortcuts.byTen", locale: locale), L10n.text(base, locale: locale))
        }
        if title.hasPrefix("Opacity digit "), let digit = title.dropFirst("Opacity digit ".count).first {
            return String(format: L10n.text("shortcuts.opacityDigit", locale: locale), String(digit))
        }
        for prefix in ["Nudge ", "Move selected pixels "] where title.hasPrefix(prefix) {
            let rest = String(title.dropFirst(prefix.count))
            let pieces = rest.split(separator: " ", maxSplits: 2).map(String.init)
            if pieces.count == 3, let distance = Int(pieces[1]) {
                let directionKey = ["Left": "shortcuts.direction.left", "Right": "shortcuts.direction.right",
                                    "Up": "shortcuts.direction.up", "Down": "shortcuts.direction.down"][pieces[0]] ?? pieces[0]
                let direction = L10n.text(directionKey, locale: locale)
                let key = prefix.hasPrefix("Nudge") ? "shortcuts.nudge" : "shortcuts.movePixels"
                return String(format: L10n.text(key, locale: locale), direction, distance)
            }
        }
        return L10n.text(title, locale: locale)
    }
}
