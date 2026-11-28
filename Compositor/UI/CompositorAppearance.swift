import AppKit
import SwiftUI

enum CompositorAppearance: String, CaseIterable {
    case auto = "Auto", dark = "Dark", amber = "Amber", light = "Light"

    static let defaultsKey = "compositorAppearance"
    private(set) static var applied = Self.dark
    static var saved: Self {
        UserDefaults.standard.string(forKey: defaultsKey).flatMap(Self.init(rawValue:)) ?? .dark
    }

    func apply() {
        Self.applied = self
        switch self {
        case .auto: NSApp.appearance = nil
        case .dark, .amber: NSApp.appearance = NSAppearance(named: .darkAqua)
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        }
        PanelTitleBar.refreshAppearance()
    }

    static let amberText = NSColor(srgbRed: 233.0 / 255, green: 173.0 / 255, blue: 65.0 / 255, alpha: 1)
    static let amberSecondary = NSColor(srgbRed: 178.0 / 255, green: 130.0 / 255, blue: 52.0 / 255, alpha: 1)
    static let amberAccent = NSColor(srgbRed: 229.0 / 255, green: 150.0 / 255, blue: 40.0 / 255, alpha: 1)
    static let amberForeground = Color(nsColor: amberText)
    static let amberMuted = Color(nsColor: amberSecondary)
    static let amberOnAccent = Color(nsColor: warmColor(37, 28, 17))
    static let amberEditor = Color(nsColor: warmColor(27, 22, 15))
    static let amberPanel = Color(nsColor: warmColor(25, 19, 12))
    static let amberHeader = warmColor(37, 28, 17)
    static let amberSurround = warmColor(19, 14, 9)
    static let amberButton = Color(nsColor: warmColor(47, 35, 22))
    static let amberInactiveTab = Color(nsColor: warmColor(38, 29, 18))
    static let amberPressedButton = Color(nsColor: warmColor(64, 46, 27))
    static let amberCheckerboard = (base: warmColor(68, 54, 39), alternate: warmColor(81, 66, 49))
    static var controlAccent: NSColor { applied == .amber ? amberAccent : .controlAccentColor }

    private static func warmColor(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat) -> NSColor {
        NSColor(srgbRed: red / 255, green: green / 255, blue: blue / 255, alpha: 1)
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
    static let darkCheckerboard: (base: CGFloat, alternate: CGFloat) = (0.30, 0.35)
    static let lightCheckerboard: (base: CGFloat, alternate: CGFloat) = (0.85, 0.92)

    static let ink = gray(dark: 1, light: 0)
    static let editorBackground = gray(dark: 0.14, light: lightEditorWhite)
    static let rulerBackground = gray(dark: 0.2, light: lightRulerWhite)
}

extension EnvironmentValues {
    @Entry var compositorAmber = false
}

extension View {
    func compositorChrome() -> some View { modifier(CompositorChrome()) }
}

private struct CompositorChrome: ViewModifier {
    @AppStorage(CompositorAppearance.defaultsKey) private var appearance = CompositorAppearance.dark

    func body(content: Content) -> some View {
        let amber = appearance == .amber
        let tint = amber ? Color(nsColor: CompositorAppearance.amberAccent) : nil
        content
            .environment(\.compositorAmber, amber)
            // The inherited foreground style also paints native separators and control surfaces.
            // Use the label color instead, and let the system supply it for the existing themes.
            .foregroundColor(amber ? CompositorAppearance.amberForeground : nil)
            .accentColor(tint)
            .tint(tint)
    }
}

struct CompositorCheckboxStyle: ToggleStyle {
    @Environment(\.compositorAmber) private var amber
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        if amber {
            Button {
                configuration.isOn.toggle()
            } label: {
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 4, style: .continuous)
                        .fill(configuration.isOn ? Color(nsColor: CompositorAppearance.amberAccent) : CompositorAppearance.amberButton)
                        .overlay {
                            if configuration.isOn {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(CompositorAppearance.amberOnAccent)
                            } else {
                                RoundedRectangle(cornerRadius: 4, style: .continuous)
                                    .strokeBorder(CompositorAppearance.amberMuted.opacity(0.4))
                            }
                        }
                        .frame(width: 16, height: 16)
                    configuration.label
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .opacity(enabled ? 1 : 0.45)
            .accessibilityRepresentation {
                Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.checkbox)
            }
        } else {
            CheckboxToggleStyle().makeBody(configuration: configuration)
        }
    }
}

struct CompositorProminentButtonStyle: PrimitiveButtonStyle {
    var nativeProminent = true
    @Environment(\.compositorAmber) private var amber

    func makeBody(configuration: Configuration) -> some View {
        if amber {
            Button(configuration).buttonStyle(AmberFilledButtonStyle())
        } else if nativeProminent {
            BorderedProminentButtonStyle().makeBody(configuration: configuration)
        } else {
            DefaultButtonStyle().makeBody(configuration: configuration)
        }
    }
}

struct CompositorAccentToggleStyle: ToggleStyle {
    @Environment(\.compositorAmber) private var amber

    func makeBody(configuration: Configuration) -> some View {
        if amber {
            Button { configuration.isOn.toggle() } label: { configuration.label }
                .buttonStyle(AmberFilledButtonStyle(selected: configuration.isOn))
                .accessibilityRepresentation {
                    Toggle(isOn: configuration.$isOn) { configuration.label }.toggleStyle(.button)
                }
        } else {
            ButtonToggleStyle().makeBody(configuration: configuration)
        }
    }
}

private struct AmberFilledButtonStyle: ButtonStyle {
    var selected = true
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(selected ? CompositorAppearance.amberOnAccent : CompositorAppearance.amberForeground)
            .padding(.horizontal, 12)
            .frame(minHeight: 24)
            .background(selected ? Color(nsColor: CompositorAppearance.amberAccent) : CompositorAppearance.amberButton, in: Capsule())
            .contentShape(Capsule())
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.45)
    }
}

struct CompositorAccentLabel: ViewModifier {
    let selected: Bool
    @Environment(\.compositorAmber) private var amber

    func body(content: Content) -> some View {
        if selected, amber { content.foregroundStyle(CompositorAppearance.amberOnAccent) }
        else { content }
    }
}

struct CompositorSegmentedPicker<Value: Hashable, Option: View>: View {
    let title: LocalizedStringKey
    @Binding var selection: Value
    let options: [Value]
    let showsLabel: Bool
    @ViewBuilder let option: (Value) -> Option
    @Environment(\.compositorAmber) private var amber
    @Environment(\.isEnabled) private var enabled

    init(_ title: LocalizedStringKey, selection: Binding<Value>, options: [Value], showsLabel: Bool = false,
         @ViewBuilder option: @escaping (Value) -> Option) {
        self.title = title
        _selection = selection
        self.options = options
        self.showsLabel = showsLabel
        self.option = option
    }

    var body: some View {
        if amber {
            HStack {
                if showsLabel { Text(title) }
                HStack(spacing: 0) {
                    ForEach(options, id: \.self) { value in
                        let selected = value == selection
                        Button { selection = value } label: {
                            option(value)
                                .foregroundStyle(selected ? CompositorAppearance.amberOnAccent : CompositorAppearance.amberForeground)
                                .padding(.horizontal, 10)
                                .frame(minHeight: 24)
                                .background(selected ? Color(nsColor: CompositorAppearance.amberAccent) : .clear, in: Capsule())
                                .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .background(CompositorAppearance.amberInactiveTab, in: Capsule())
                .accessibilityElement(children: .contain)
                .accessibilityLabel(title)
                .onMoveCommand { direction in
                    guard let index = options.firstIndex(of: selection) else { return }
                    let offset: Int
                    switch direction {
                    case .left: offset = -1
                    case .right: offset = 1
                    default: return
                    }
                    if options.indices.contains(index + offset) { selection = options[index + offset] }
                }
            }
            .opacity(enabled ? 1 : 0.45)
        } else if showsLabel {
            nativePicker
        } else {
            nativePicker.labelsHidden()
        }
    }

    private var nativePicker: some View {
        Picker(title, selection: $selection) {
            ForEach(options, id: \.self) { option($0).tag($0) }
        }
        .pickerStyle(.segmented)
    }
}
