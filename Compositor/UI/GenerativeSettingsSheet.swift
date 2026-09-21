import SwiftUI

struct GenerativeSettingsSheet: View {
    @Bindable var settings: GenerativeSettings
    @State private var draft = ""
    @State private var saveError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Generative Fill, Remove and Generative Expand use Google’s Gemini image models with your own API key.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text("Gemini API key").font(.headline)
            HStack {
                SecureField(settings.hasKey ? "A key is saved. Paste a new one to replace it." : "Paste your key", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(save)
                Button("Save", action: save).disabled(draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            HStack(spacing: 8) {
                Button("Verify Key") { Task { await settings.verifyKey() } }
                    .disabled(!settings.hasKey || settings.keyState == .checking)
                Button("Remove Key") { draft = ""; store("") }.disabled(!settings.hasKey)
                Spacer()
                Link("Get a key…", destination: URL(string: "https://aistudio.google.com/apikey")!)
            }
            status
            Divider()
            Picker("Default model", selection: $settings.model) {
                ForEach(GenerativeModel.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            Text(settings.model.detail).font(.callout).foregroundStyle(.secondary)
            Divider()
            Text("When you generate, the selected part of your image with some of its surroundings, your prompt, and any reference images are sent to Google. Each generated image is charged to your Google account; image models have no free tier. The key is kept in your Mac’s keychain.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Done") { settings.close() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 460).fixedSize()
    }

    @ViewBuilder private var status: some View {
        // A fixed height: the panel is sized once, when it opens.
        Group {
            if let saveError { Text(saveError).foregroundStyle(.orange) }
            else {
                switch settings.keyState {
                case .unchecked: Text(settings.hasKey ? "A key is saved." : "No key saved.").foregroundStyle(.secondary)
                case .checking: HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking…").foregroundStyle(.secondary) }
                case .accepted: Label("The key works and can reach the image models.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                case .rejected(let reason): Text(reason).foregroundStyle(.orange)
                }
            }
        }
        .font(.callout).lineLimit(3).frame(height: 50, alignment: .topLeading)
    }

    private func save() {
        guard !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        store(draft)
        draft = ""
        if saveError == nil { Task { await settings.verifyKey() } }
    }
    private func store(_ key: String) {
        do { try settings.setKey(key); saveError = nil } catch { saveError = error.localizedDescription }
    }
}
