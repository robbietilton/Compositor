import Sparkle
import SwiftUI

struct CompositorSettingsView: View {
    private enum Page { case general, shortcuts, updates }

    let updater: SPUUpdater
    @State private var page = Page.general

    var body: some View {
        TabView(selection: $page) {
            Tab("General", systemImage: "gearshape", value: Page.general) { GeneralSettings() }
            Tab("Shortcuts", systemImage: "keyboard", value: Page.shortcuts) {
                KeyboardShortcutsSettings(settings: .shared)
            }
            Tab("Updates", systemImage: "arrow.down.circle", value: Page.updates) { UpdateSettings(updater: updater) }
        }
        .frame(width: 560, height: 580)
    }
}

private struct GeneralSettings: View {
    @AppStorage(CompositorAppearance.defaultsKey) private var appearance = CompositorAppearance.dark
    @AppStorage(MCPAccess.defaultsKey) private var access = MCPAccess.undecided
    private let mcpDescription = "Lets local MCP clients view and edit open projects."

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("General").font(.title2.weight(.semibold))
                SettingsCard {
                    Text("Appearance").font(.headline)
                    HStack(spacing: 12) {
                        ForEach(CompositorAppearance.allCases, id: \.self) { option in
                            appearanceButton(option)
                        }
                    }
                }
                SettingsCard {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Allow MCP control").font(.headline)
                            Text(mcpDescription).foregroundStyle(.secondary)
                        }
                        .accessibilityHidden(true)
                        Spacer()
                        Toggle("Allow MCP control", isOn: Binding(get: { access == .allowed }, set: {
                            access = $0 ? .allowed : .denied
                        }))
                        .toggleStyle(.switch)
                        .labelsHidden()
                        .accessibilityHint(mcpDescription)
                    }
                }
            }
            .padding(24)
        }
    }

    private func appearanceButton(_ option: CompositorAppearance) -> some View {
        let selected = appearance == option
        return Button {
            appearance = option
            option.apply()
        } label: {
            VStack(spacing: 7) {
                AppearancePreview(option: option)
                    .frame(height: 76)
                    .clipShape(.rect(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7).strokeBorder(
                            selected ? Color.accentColor : CompositorAppearance.ink.opacity(0.14),
                            lineWidth: selected ? 2 : 1
                        )
                    }
                    .accessibilityHidden(true)
                Text(option.rawValue)
                    .fontWeight(selected ? .semibold : .regular)
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

private struct AppearancePreview: View {
    let option: CompositorAppearance

    var body: some View {
        if option == .auto {
            editor(light: true).overlay {
                editor(light: false).mask {
                    HStack(spacing: 0) { Color.clear; Color.black }
                }
            }
        } else {
            editor(light: option == .light)
        }
    }

    private func editor(light: Bool) -> some View {
        let ink = light ? Color.black : Color.white
        return VStack(spacing: 0) {
            HStack(spacing: 3) {
                Capsule().fill(ink.opacity(0.25)).frame(width: 18, height: 3)
                Capsule().fill(ink.opacity(0.15)).frame(width: 12, height: 3)
                Spacer()
                Capsule().fill(ink.opacity(0.20)).frame(width: 12, height: 3)
            }
            .padding(6)
            .background(ink.opacity(0.06))
            HStack(spacing: 0) {
                VStack(spacing: 4) {
                    ForEach(0..<4) { tool in
                        RoundedRectangle(cornerRadius: 1).fill(ink.opacity(tool == 0 ? 0.46 : 0.22))
                            .frame(width: 5, height: 5)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 14)
                .padding(.top, 6)
                Rectangle().fill(Color(white: light ? CompositorAppearance.lightSurroundWhite : 0.105)).overlay {
                    RoundedRectangle(cornerRadius: 2).fill(Color(white: 0.57))
                        .aspectRatio(1.5, contentMode: .fit).padding(9)
                }
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<3) { layer in
                        Capsule().fill(ink.opacity(layer == 0 ? 0.34 : 0.18)).frame(width: 13, height: 3)
                    }
                    Spacer(minLength: 0)
                }
                .frame(width: 24)
                .padding(.top, 7)
            }
        }
        .background(Color(white: light ? CompositorAppearance.lightEditorWhite : 0.14))
    }
}

private struct UpdateSettings: View {
    let updater: SPUUpdater
    @Environment(\.openURL) private var openURL
    @State private var canCheck = false
    @State private var checksAutomatically = false
    @State private var lastChecked: Date?

    private var installedVersion: String {
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "Development"
        guard let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String else { return version }
        return "\(version) (\(build))"
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Updates").font(.title2.weight(.semibold))

                SettingsCard {
                    Text("Software Update").font(.headline)
                    detail("Installed version", value: installedVersion)
                    detail("Last checked", value: lastChecked?.formatted(date: .abbreviated, time: .shortened) ?? "Never")
                    Divider()
                    Toggle("Check for updates automatically", isOn: Binding(get: { checksAutomatically }, set: {
                        checksAutomatically = $0
                        updater.automaticallyChecksForUpdates = $0
                    }))
                    .toggleStyle(.checkbox)
                    Button {
                        updater.checkForUpdates()
                    } label: {
                        Text("Check for Updates…").padding(.horizontal, 14)
                    }
                    .buttonStyle(EditorToolbarPillStyle())
                    .disabled(!canCheck)
                }

                SettingsCard {
                    Text("Release Notes").font(.headline)
                    Text("Read what changed in each version on GitHub.")
                        .foregroundStyle(.secondary)
                    Button {
                        openURL(URL(string: "https://github.com/robbietilton/Compositor/releases")!)
                    } label: {
                        Text("View GitHub Releases").padding(.horizontal, 14)
                    }
                    .buttonStyle(EditorToolbarPillStyle())
                }
            }
            .padding(24)
        }
        .onReceive(updater.publisher(for: \.canCheckForUpdates)) { canCheck = $0 }
        .onReceive(updater.publisher(for: \.automaticallyChecksForUpdates)) { checksAutomatically = $0 }
        .onReceive(updater.publisher(for: \.lastUpdateCheckDate)) { lastChecked = $0 }
    }

    private func detail(_ label: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(label).foregroundStyle(.secondary)
            Text(value)
        }
    }
}

private struct SettingsCard<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            content
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(CompositorAppearance.ink.opacity(0.04), in: RoundedRectangle(cornerRadius: 12))
    }
}
