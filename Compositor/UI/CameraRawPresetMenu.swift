import SwiftUI

/// The Presets menu at the top of the Camera Raw panel: the person's saved looks, and Save, Rename and Delete.
struct CameraRawPresetMenu: View {
    @Bindable var session: EditorSession
    var store: CameraRawPresetStore = .shared

    /// What saving under a typed name does.
    enum SaveStep: Equatable {
        case invalidName
        case save(String)
        /// A preset of that name (ignoring case) exists: ask first, then save as `name`.
        case confirmReplace(existing: String, name: String)
    }

    static func saveStep(for typed: String, in store: CameraRawPresetStore) -> SaveStep {
        guard let name = CameraRawPresetStore.validName(typed) else { return .invalidName }
        if let existing = store.preset(named: name) { return .confirmReplace(existing: existing.name, name: name) }
        return .save(name)
    }

    private enum Naming: Equatable {
        case save
        case rename(String)
    }

    @State private var naming: Naming?
    @State private var typed = ""
    @State private var replacing: (existing: String, name: String)?
    @State private var deleting: String?
    @State private var failure: String?

    var body: some View {
        Menu {
            if store.presets.isEmpty { Text("No presets yet") }
            ForEach(store.presets) { preset in
                Button(preset.name) { Task { await session.applyCameraRawPreset(preset) } }
            }
            Divider()
            Button("Save Settings as Preset…") { typed = ""; naming = .save }
            if !store.presets.isEmpty {
                Menu("Rename") {
                    ForEach(store.presets) { preset in Button(preset.name) { typed = preset.name; naming = .rename(preset.name) } }
                }
                Menu("Delete") {
                    ForEach(store.presets) { preset in Button(preset.name) { deleting = preset.name } }
                }
            }
        } label: {
            Label("Presets", systemImage: "square.stack")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .help("Save these settings under a name, or apply a saved look")
        .disabled(session.filterEdit?.committing != false)
        .alert(namingTitle, isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField("Name", text: $typed)
            Button(naming == .save ? "Save" : "Rename") { finishNaming() }
            Button("Cancel", role: .cancel) {}
        }
        .alert("Replace “\(replacing?.existing ?? "")”?", isPresented: Binding(get: { replacing != nil }, set: { if !$0 { replacing = nil } })) {
            Button("Replace") { if let replacing { save(as: replacing.name) } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("A preset with that name already exists. Replacing it keeps these settings instead.") }
        .alert("Delete “\(deleting ?? "")”?", isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete", role: .destructive) { if let deleting { run { try store.delete(deleting) } } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This can't be undone.") }
        .alert("Couldn't change the presets", isPresented: Binding(get: { failure != nil }, set: { if !$0 { failure = nil } })) {
            Button("OK", role: .cancel) {}
        } message: { Text(failure ?? "") }
    }

    private var namingTitle: String {
        if case .rename(let name) = naming { return "Rename “\(name)”" }
        return "Save Settings as Preset"
    }

    private func finishNaming() {
        switch naming {
        case .save:
            switch Self.saveStep(for: typed, in: store) {
            case .invalidName: failure = CameraRawPresetError.invalidName.errorDescription
            case .save(let name): save(as: name)
            // Shown once the naming alert has gone.
            case .confirmReplace(let existing, let name): Task { replacing = (existing, name) }
            }
        case .rename(let old): run { try store.rename(old, to: typed) }
        case nil: break
        }
    }

    private func save(as name: String) {
        guard let settings = session.cameraRawPresetSettings else { return }
        run { try store.save(settings, as: name) }
    }

    private func run(_ change: () throws -> Void) {
        do { try change() } catch {
            let message = error.localizedDescription
            Task { failure = message }
        }
    }
}
