import SwiftUI
import UniformTypeIdentifiers

/// Used by View › Print Setup and Export As, so preview and output always use the same profile and matte.
struct PrintControls: View {
    @Bindable var session: EditorSession
    var showsPreviewControls = true
    @State private var choosingProfile = false
    @State private var error: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("CMYK Profile")
                Text(session.printSettings.profile?.name ?? "None selected").foregroundStyle(.secondary).lineLimit(1)
                    .help(session.printSettings.profile?.name ?? "Choose the ICC profile for your printing conditions")
                Spacer()
                Button("Choose ICC…") { choosingProfile = true }
            }
            Picker("Rendering Intent", selection: $session.printSettings.intent) {
                ForEach(CMYKIntent.allCases, id: \.self) { Text($0.rawValue).tag($0) }
            }
            HStack {
                Text("Background")
                DialogColorSwatch(title: "Print Background", color: $session.printSettings.background, session: session)
                Text("Fills transparent areas").foregroundStyle(.secondary)
            }
            if showsPreviewControls {
                Toggle("CMYK Print Preview", isOn: $session.showsPrintProof)
                    .disabled(session.printSettings.profile == nil)
                Toggle("Gamut Warning", isOn: $session.showsPrintGamutWarning)
                    .disabled(session.printSettings.profile?.supportsGamutWarning != true)
                    .help("Gray marks colors outside the selected profile’s gamut; it is never exported")
                if let profile = session.printSettings.profile, !profile.supportsGamutWarning {
                    Text("This profile does not supply gamut-warning data.").foregroundStyle(.secondary)
                }
            }
            Text("Preview simulates CMYK conversion. Paper color and black ink are not simulated. Use the profile supplied by your print provider.")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .fileImporter(isPresented: $choosingProfile,
                      allowedContentTypes: [UTType(filenameExtension: "icc") ?? .data]) { result in
            do {
                let url = try result.get()
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let profile = try CMYKProfile(data: Data(contentsOf: url))
                _ = try CMYKConversion(profile: profile, intent: session.printSettings.intent)
                session.printSettings.profile = profile
                session.showsPrintProof = true
                if !profile.supportsGamutWarning { session.showsPrintGamutWarning = false }
            } catch {
                if (error as NSError).code != NSUserCancelledError { self.error = error.localizedDescription }
            }
        }
        .alert("Couldn’t load CMYK profile", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("OK") { error = nil }
        } message: { Text(error ?? "") }
    }
}

struct PrintSetupSheet: View {
    let session: EditorSession
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Print Setup").font(.title2.bold())
            PrintControls(session: session)
            HStack {
                Spacer()
                Button("Done") { DialogColorSwatch.closePicker(session); dismiss() }.configuredNativeShortcut(.return)
            }
        }.padding(24).frame(width: 500).roundedControls()
    }
}

struct PrintSetupPresentation: ViewModifier {
    @Bindable var session: EditorSession
    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $session.showsPrintSetup) { PrintSetupSheet(session: session) }
            .alert("Print preview couldn’t finish", isPresented: Binding(
                get: { session.printProofError != nil }, set: { if !$0 { session.printProofError = nil } })) {
                    Button("OK") { session.printProofError = nil }
                } message: { Text(session.printProofError ?? "") }
    }
}

struct PrintProofBadge: View {
    let session: EditorSession
    var body: some View {
        if session.showsPrintProof, let profile = session.printSettings.profile, session.maskAloneLayer == nil {
            Text("CMYK Preview · \(profile.name)" + (session.showsPrintGamutWarning ? " · Gamut Warning" : ""))
                .font(.caption).padding(6).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 6))
                .padding(12).allowsHitTesting(false)
        }
    }
}
